//
//  ScreenGeometry.swift
//  3ds2apple
//
//  Where the presented screens go inside the game view.
//
//  Two sizes are involved:
//
//  - the drawable the presenter renders into: the chosen screen arrangement at
//    the 3DS resolutions (400x480 for the stacked console, 720x240 side by side,
//    a single screen, or the whole arrangement turned a quarter turn), times the
//    render scale. This is the same number `zk_present_layout_size()` reports in
//    ios/zakuro-ios/src/presenter.rs, so the presenter's layout fills the
//    drawable instead of being letterboxed.
//  - the box SwiftUI gives the Metal view (and the touch surface over it), which
//    decides whether the picture is fitted (fit/4:3, with black bars), stretched
//    to fill, or snapped to whole console pixels (integer scaling).
//    CoreAnimation scales the layer into that box; the picture itself is only
//    distorted in the stretch mode.
//

import CoreGraphics
import Foundation

enum ScreenGeometry {
    /// The arrangement at the 3DS resolutions, before the render scale.
    static func nativePixelSize(layout: ScreenLayout, rotation: ScreenRotation) -> CGSize {
        let upright: CGSize
        switch layout {
        case .stacked: upright = CGSize(width: 400, height: 480)
        case .sideBySide: upright = CGSize(width: 720, height: 240)
        case .upperOnly: upright = CGSize(width: 400, height: 240)
        case .lowerOnly: upright = CGSize(width: 320, height: 240)
        }
        let quarterTurn = rotation == .clockwise || rotation == .counterClockwise
        return quarterTurn
            ? CGSize(width: upright.height, height: upright.width)
            : upright
    }

    /// Drawable size in pixels for the presenter: the arrangement's own pixels
    /// times the render scale (1x or 2x).
    static func drawablePixelSize(
        layout: ScreenLayout,
        rotation: ScreenRotation,
        renderScale: CGFloat
    ) -> CGSize {
        let native = nativePixelSize(layout: layout, rotation: rotation)
        let factor: CGFloat = renderScale >= 2 ? 2 : 1
        return CGSize(width: native.width * factor, height: native.height * factor)
    }

    /// Width / height of the arrangement: 400x480 stacked, 720x240 side by side,
    /// swapped by a quarter turn.
    static func contentAspect(layout: ScreenLayout, rotation: ScreenRotation) -> CGFloat {
        let native = nativePixelSize(layout: layout, rotation: rotation)
        guard native.height > 0 else { return 4.0 / 3.0 }
        return native.width / native.height
    }

    /// The size of the box the screens (and their touch surface) occupy inside
    /// `available`, centred there by the caller.
    ///
    /// - fit: the picture's own aspect, as large as fits;
    /// - 4:3: a 4:3 area fitted in the space, the picture fitted inside it (the
    ///   difference between the two shapes becomes black bars);
    /// - stretch: the whole available space (the picture is distorted);
    /// - integer scaling (fit and 4:3 only): the picture is snapped down to a
    ///   whole number of times its own console pixels, measured in device pixels.
    ///
    /// The box is always centred in the available space.
    static func contentSize(
        available: CGSize,
        layout: ScreenLayout,
        rotation: ScreenRotation,
        aspect: ScreenAspect,
        integerScale: Bool,
        displayScale: CGFloat
    ) -> CGSize {
        guard available.width > 0, available.height > 0 else { return .zero }
        let contentAspect = contentAspect(layout: layout, rotation: rotation)
        guard contentAspect > 0 else { return .zero }

        switch aspect {
        case .stretch:
            return available
        case .fit, .fourThree:
            let frameAspect: CGFloat = aspect == .fourThree ? 4.0 / 3.0 : contentAspect
            let frame = fittedSize(aspect: frameAspect, in: available)
            var content = fittedSize(aspect: contentAspect, in: frame)
            if integerScale {
                content = snappedToWholePixels(
                    content,
                    nativePixelSize: nativePixelSize(layout: layout, rotation: rotation),
                    displayScale: displayScale > 0 ? displayScale : 2
                )
            }
            return content
        }
    }

    /// `size` scaled (keeping `aspect`) as large as fits in `available`.
    static func fittedSize(aspect: CGFloat, in available: CGSize) -> CGSize {
        guard aspect > 0 else { return .zero }
        if available.width / available.height > aspect {
            let height = available.height
            return CGSize(width: height * aspect, height: height)
        }
        let width = available.width
        return CGSize(width: width, height: width / aspect)
    }

    // MARK: - Readback layout

    /// Where the two screens go inside a readback area of `available` pixels,
    /// in the same arrangement and rotation the presenter uses. Used only by the
    /// `CGImage` fallback (no presenter), so it mirrors the Rust `layout()`
    /// helper: the screens keep their own aspect, the arrangement is scaled
    /// uniformly to fit and centred, and a quarter turn rotates the whole
    /// arrangement and every screen's picture. A screen that is not shown has no
    /// rectangle.
    static func layoutViewports(
        available: CGSize,
        layout: ScreenLayout,
        rotation: ScreenRotation
    ) -> (top: CGRect?, bottom: CGRect?) {
        guard available.width > 0, available.height > 0 else { return (nil, nil) }
        let topWidth: CGFloat = 400
        let arrangement: CGSize
        switch layout {
        case .stacked: arrangement = CGSize(width: max(topWidth, 320), height: 480)
        case .sideBySide: arrangement = CGSize(width: topWidth + 320, height: 240)
        case .upperOnly: arrangement = CGSize(width: topWidth, height: 240)
        case .lowerOnly: arrangement = CGSize(width: 320, height: 240)
        }
        let quarterTurn = rotation == .clockwise || rotation == .counterClockwise
        let total = quarterTurn
            ? CGSize(width: arrangement.height, height: arrangement.width)
            : arrangement
        let scale = min(available.width / total.width, available.height / total.height)
        guard scale > 0 else { return (nil, nil) }

        let top: CGRect? = layout == .lowerOnly
            ? nil
            : CGRect(x: 0, y: 0, width: topWidth * scale, height: 240 * scale)
        let bottom: CGRect?
        switch layout {
        case .stacked:
            bottom = CGRect(
                x: (arrangement.width - 320) / 2 * scale,
                y: 240 * scale,
                width: 320 * scale,
                height: 240 * scale
            )
        case .sideBySide:
            bottom = CGRect(x: topWidth * scale, y: 0, width: 320 * scale, height: 240 * scale)
        case .upperOnly:
            bottom = nil
        case .lowerOnly:
            bottom = CGRect(x: 0, y: 0, width: 320 * scale, height: 240 * scale)
        }

        let canvasWidth = arrangement.width * scale
        let canvasHeight = arrangement.height * scale
        func rotate(_ rect: CGRect) -> CGRect {
            switch rotation {
            case .upright:
                return rect
            case .clockwise:
                return CGRect(
                    x: canvasHeight - rect.minY - rect.height,
                    y: rect.minX,
                    width: rect.height,
                    height: rect.width
                )
            case .upsideDown:
                return CGRect(
                    x: canvasWidth - rect.minX - rect.width,
                    y: canvasHeight - rect.minY - rect.height,
                    width: rect.width,
                    height: rect.height
                )
            case .counterClockwise:
                return CGRect(
                    x: rect.minY,
                    y: canvasWidth - rect.minX - rect.width,
                    width: rect.height,
                    height: rect.width
                )
            }
        }
        let offsetX = (available.width - total.width * scale) / 2
        let offsetY = (available.height - total.height * scale) / 2
        func place(_ rect: CGRect?) -> CGRect? {
            guard let rect else { return nil }
            let turned = rotate(rect)
            return turned.offsetBy(dx: offsetX, dy: offsetY)
        }
        return (place(top), place(bottom))
    }

    /// Snaps a fitted size down to a whole multiple of the console's pixels,
    /// measured in device pixels so each 3DS pixel lands on whole screen pixels.
    private static func snappedToWholePixels(
        _ fitted: CGSize,
        nativePixelSize: CGSize,
        displayScale: CGFloat
    ) -> CGSize {
        guard nativePixelSize.width > 0, nativePixelSize.height > 0 else { return fitted }
        let pixelWidth = fitted.width * displayScale
        let pixelHeight = fitted.height * displayScale
        let multiple = max(
            1,
            floor(min(pixelWidth / nativePixelSize.width, pixelHeight / nativePixelSize.height))
        )
        return CGSize(
            width: nativePixelSize.width * multiple / displayScale,
            height: nativePixelSize.height * multiple / displayScale
        )
    }
}
