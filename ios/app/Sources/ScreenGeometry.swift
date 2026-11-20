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
        case .largeTop: upright = CGSize(width: 560, height: 240)
        case .upperOnly: upright = CGSize(width: 400, height: 240)
        case .lowerOnly: upright = CGSize(width: 320, height: 240)
        }
        let quarterTurn = rotation == .clockwise || rotation == .counterClockwise
        return quarterTurn
            ? CGSize(width: upright.height, height: upright.width)
            : upright
    }

    /// Drawable size in pixels for the presenter: the arrangement's own pixels
    /// times the render scale (1x through 4x).
    static func drawablePixelSize(
        layout: ScreenLayout,
        rotation: ScreenRotation,
        renderScale: CGFloat
    ) -> CGSize {
        let native = nativePixelSize(layout: layout, rotation: rotation)
        let factor = min(max(renderScale.rounded(), 1), 4)
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
        case .largeTop: arrangement = CGSize(width: topWidth + 160, height: 240)
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
        case .largeTop:
            // Half the top screen's scale, at its lower right (mirrors the
            // presenter's LargeTop layout in ios/zakuro-ios).
            let small = scale * 0.5
            bottom = CGRect(
                x: topWidth * scale,
                y: 240 * scale - 240 * small,
                width: 320 * small,
                height: 240 * small
            )
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

// MARK: - Preset readback placement

/// The screen placements the presets need when the Metal presenter cannot draw
/// them, plus `custom`:
/// - `large` in portrait: a large upper screen at the top, the lower screen
///   small in the bottom-right corner;
/// - `hybrid` in both directions: a large upper screen with the lower screen
///   below it;
/// - `custom`: the user's hand-placed rectangles.
///
/// The placements are normalised `CustomScreenPlacement` rectangles, so the
/// readback path, the lower-screen touch surface and the layout editors all use
/// one geometry - including the screen rotation and integer scaling handling in
/// `CustomScreenGeometry`.
enum PresetScreenGeometry {
    /// The placement of one preset in a picture stage of `stage` points, or nil
    /// when the preset uses one of the presenter's fixed arrangements.
    static func placement(
        preset: ScreenLayoutPreset,
        customLayout: CustomScreenLayout,
        orientation: ControlLayoutOrientation,
        stage: CGSize
    ) -> CustomScreenPlacement? {
        switch preset {
        case .custom:
            return customLayout.placement(for: orientation)
        case .large:
            guard orientation == .portrait else { return nil }
            return largePlacement(stage: stage)
        case .hybrid:
            return hybridPlacement(stage: stage)
        case .original, .single, .side:
            return nil
        }
    }

    /// The readback viewports of a preset direction, or nil when that direction
    /// uses the presenter's fixed arrangement.
    static func readbackViewports(
        preset: ScreenLayoutPreset,
        customLayout: CustomScreenLayout,
        orientation: ControlLayoutOrientation,
        stage: CGSize,
        rotation: ScreenRotation,
        displayScale: CGFloat,
        integerScale: Bool
    ) -> (top: CGRect?, bottom: CGRect?)? {
        guard let placement = placement(preset: preset,
                                        customLayout: customLayout,
                                        orientation: orientation,
                                        stage: stage) else {
            return nil
        }
        return CustomScreenGeometry.viewports(
            available: stage,
            placement: placement,
            rotation: rotation,
            displayScale: displayScale,
            integerScale: integerScale
        )
    }

    /// `large` in portrait: the upper screen large and centred at the top, the
    /// lower screen at about 40% of the stage width in the bottom-right corner.
    /// Both keep the console's native screen shapes.
    private static func largePlacement(stage: CGSize) -> CustomScreenPlacement {
        let containerAspect = stage.width / max(stage.height, 1)
        let margin = 0.03
        var topWidth = 0.94
        var bottomWidth = 0.40
        var topHeight = heightFraction(width: topWidth,
                                       containerAspect: containerAspect,
                                       screen: .upper)
        var bottomHeight = heightFraction(width: bottomWidth,
                                          containerAspect: containerAspect,
                                          screen: .lower)
        // Never let a screen leave the stage on a very tall box.
        let maximumHeight = max(1 - margin * 2, 0.2)
        if topHeight > maximumHeight {
            let scale = maximumHeight / topHeight
            topWidth *= scale
            topHeight *= scale
        }
        if bottomHeight > maximumHeight {
            let scale = maximumHeight / bottomHeight
            bottomWidth *= scale
            bottomHeight *= scale
        }
        let top = ScreenRect(x: (1 - topWidth) / 2,
                             y: margin,
                             width: topWidth,
                             height: topHeight)
        let bottom = ScreenRect(x: 1 - margin - bottomWidth,
                                y: 1 - margin - bottomHeight,
                                width: bottomWidth,
                                height: bottomHeight)
        return CustomScreenPlacement(top: top, bottom: bottom,
                                     showsTop: true, showsBottom: true,
                                     keepsNativeAspect: true)
    }

    /// `hybrid`: the upper screen large and centred, the lower screen below it
    /// at about 58% of the upper screen's width. The pair is scaled down to fit
    /// and centred vertically, so it also works in a wide, short landscape box.
    private static func hybridPlacement(stage: CGSize) -> CustomScreenPlacement {
        let containerAspect = stage.width / max(stage.height, 1)
        let gap = 0.02
        // The lower screen is about 55-60% of the large screen's width.
        let bottomRatio = 0.58
        var topWidth = 0.94
        var bottomWidth = topWidth * bottomRatio
        var topHeight = heightFraction(width: topWidth,
                                       containerAspect: containerAspect,
                                       screen: .upper)
        var bottomHeight = heightFraction(width: bottomWidth,
                                          containerAspect: containerAspect,
                                          screen: .lower)
        let available = max(1 - gap, 0.2)
        let total = topHeight + bottomHeight
        if total > available {
            let scale = available / total
            topWidth *= scale
            bottomWidth *= scale
            topHeight *= scale
            bottomHeight *= scale
        }
        let groupHeight = topHeight + bottomHeight + gap
        let topY = max((1 - groupHeight) / 2, 0)
        let top = ScreenRect(x: (1 - topWidth) / 2,
                             y: topY,
                             width: topWidth,
                             height: topHeight)
        let bottom = ScreenRect(x: (1 - bottomWidth) / 2,
                                y: topY + topHeight + gap,
                                width: bottomWidth,
                                height: bottomHeight)
        return CustomScreenPlacement(top: top, bottom: bottom,
                                     showsTop: true, showsBottom: true,
                                     keepsNativeAspect: true)
    }

    /// Height fraction of a native-aspect screen with a given width fraction,
    /// from the stage's own aspect (width / height).
    private static func heightFraction(width: Double,
                                       containerAspect: CGFloat,
                                       screen: ScreenKind) -> Double {
        let screenAspect = CustomScreenGeometry.nativeAspect(for: screen)
        guard containerAspect > 0, screenAspect > 0 else { return width }
        return width * Double(containerAspect) / Double(screenAspect)
    }
}
