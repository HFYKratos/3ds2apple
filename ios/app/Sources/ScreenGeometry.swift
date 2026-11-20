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

/// The screen placements of the presets the Metal presenter cannot draw, in the
/// round-2 proportions measured from the reference screenshots
/// (docs/azahar-shot, local only):
/// - landscape `large`: the 400x240 upper screen on the left and the lower
///   screen at 1/2.25 of its height on the right, top-aligned, with the whole
///   arrangement fitted and centred;
/// - landscape `hybrid`: the upper 5:3 screen on the left and the lower 4:3
///   screen on the right, both nearly full height with a small gap;
/// - portrait `topFullWidth`: the upper screen full width with the lower screen
///   below it (the two screens scaled together), fitted by width and top-aligned
///   under the safe area;
/// - `custom`: the user's rectangles from the numeric custom pages.
///
/// The result is a normalised `CustomScreenPlacement` in the upright canvas, so
/// the readback drawing, the lower-screen touch surface and the layout editors
/// all share one geometry - including the screen rotation and the integer
/// scaling handling in `CustomScreenGeometry`.
enum PresetScreenGeometry {
    /// The readback viewports of the active choice for one direction, or nil
    /// when that direction uses the presenter's fixed arrangement.
    static func readbackViewports(
        settings: AppSettings,
        orientation: ControlLayoutOrientation,
        stage: CGSize,
        rotation: ScreenRotation,
        displayScale: CGFloat,
        integerScale: Bool
    ) -> (top: CGRect?, bottom: CGRect?)? {
        guard let placement = placement(settings: settings,
                                        orientation: orientation,
                                        stage: stage,
                                        rotation: rotation) else {
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

    /// The normalised placement of the active choice in `stage` points, or nil
    /// when the presenter draws it.
    static func placement(
        settings: AppSettings,
        orientation: ControlLayoutOrientation,
        stage: CGSize,
        rotation: ScreenRotation
    ) -> CustomScreenPlacement? {
        let canvas = uprightCanvas(stage: stage, rotation: rotation)
        switch orientation {
        case .landscape:
            switch settings.landscapeScreenLayout {
            case .large:
                return largePlacement(canvas: canvas)
            case .hybrid:
                return hybridPlacement(canvas: canvas)
            case .custom:
                return settings.customScreenLayout.placement(for: .landscape)
            case .original, .single, .side:
                return nil
            }
        case .portrait:
            switch settings.portraitScreenLayout {
            case .topFullWidth:
                return topFullWidthPlacement(canvas: canvas)
            case .custom:
                return settings.customScreenLayout.placement(for: .portrait)
            case .original:
                return nil
            }
        }
    }

    /// The canvas a placement is defined in: a quarter-turn screen rotation
    /// swaps the stage's sides.
    private static func uprightCanvas(stage: CGSize, rotation: ScreenRotation) -> CGSize {
        let quarterTurn = rotation == .clockwise || rotation == .counterClockwise
        return quarterTurn
            ? CGSize(width: stage.height, height: stage.width)
            : stage
    }

    /// Landscape `large`: the upper 400x240 screen and the lower 320x240 screen
    /// scaled to 1/2.25 of the upper screen's height, placed immediately to its
    /// right and top-aligned. The arrangement (400 + 142.2 x 240) is fitted into
    /// the canvas and centred.
    private static func largePlacement(canvas: CGSize) -> CustomScreenPlacement {
        guard canvas.width >= 1, canvas.height >= 1 else {
            return fullStagePlacement()
        }
        let lowerAspect = CustomScreenGeometry.nativeAspect(for: .lower)
        let proportion: CGFloat = 2.25
        let largeWidth = CustomScreenGeometry.topNativeSize.width      // 400
        let largeHeight = CustomScreenGeometry.topNativeSize.height    // 240
        let smallHeight = largeHeight / proportion                     // 106.7
        let smallWidth = smallHeight * lowerAspect                     // 142.2
        let arrangement = CGSize(width: largeWidth + smallWidth, height: largeHeight)
        let scale = min(canvas.width / arrangement.width,
                        canvas.height / arrangement.height)
        let offsetX = (canvas.width - arrangement.width * scale) / 2
        let offsetY = (canvas.height - arrangement.height * scale) / 2
        func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> ScreenRect {
            ScreenRect(x: Double((offsetX + x * scale) / canvas.width),
                       y: Double((offsetY + y * scale) / canvas.height),
                       width: Double(width * scale / canvas.width),
                       height: Double(height * scale / canvas.height))
        }
        let top = rect(0, 0, largeWidth, largeHeight)
        let bottom = rect(largeWidth, 0, smallWidth, smallHeight)
        return CustomScreenPlacement(top: top, bottom: bottom,
                                     showsTop: true, showsBottom: true,
                                     keepsNativeAspect: true)
    }

    /// Landscape `hybrid`: the upper 5:3 screen on the left and the lower 4:3
    /// screen on the right, both starting near the top and sized by their own
    /// aspects to fill most of the canvas height.
    private static func hybridPlacement(canvas: CGSize) -> CustomScreenPlacement {
        let canvasAspect = canvas.width / max(canvas.height, 1)
        let topX: Double = 0.0
        let bottomX: Double = 0.565
        let topY: Double = 0.124
        let bottomY: Double = 0.145
        var topWidth: Double = 0.562
        var bottomWidth: Double = 0.426
        var topHeight = nativeHeightFraction(width: topWidth,
                                             canvasAspect: canvasAspect,
                                             screen: .upper)
        var bottomHeight = nativeHeightFraction(width: bottomWidth,
                                                canvasAspect: canvasAspect,
                                                screen: .lower)
        // Both screens start at the same height, so each one has to fit above
        // the bottom edge on its own.
        let available = max(1 - topY, 0.2)
        if topHeight > available {
            let scale = available / topHeight
            topWidth *= scale
            topHeight *= scale
        }
        if bottomHeight > available {
            let scale = available / bottomHeight
            bottomWidth *= scale
            bottomHeight *= scale
        }
        let top = ScreenRect(x: topX, y: topY, width: topWidth, height: topHeight)
        let bottom = ScreenRect(x: bottomX, y: bottomY,
                                width: bottomWidth, height: bottomHeight)
        return CustomScreenPlacement(top: top, bottom: bottom,
                                     showsTop: true, showsBottom: true,
                                     keepsNativeAspect: true)
    }

    /// Portrait `topFullWidth`: the upper 400x240 screen above the lower screen
    /// scaled to the same width (400x300), fitted by width and top-aligned.
    private static func topFullWidthPlacement(canvas: CGSize) -> CustomScreenPlacement {
        guard canvas.width >= 1, canvas.height >= 1 else {
            return fullStagePlacement()
        }
        let arrangementWidth = CustomScreenGeometry.topNativeSize.width       // 400
        let upperHeight = CustomScreenGeometry.topNativeSize.height            // 240
        let bottomNative = CustomScreenGeometry.bottomNativeSize
        let lowerHeight = arrangementWidth * bottomNative.height / bottomNative.width // 300
        let arrangementHeight = upperHeight + lowerHeight                      // 540
        let scale = min(canvas.width / arrangementWidth,
                        canvas.height / arrangementHeight)
        let offsetX = (canvas.width - arrangementWidth * scale) / 2
        func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> ScreenRect {
            ScreenRect(x: Double((offsetX + x * scale) / canvas.width),
                       y: Double((y * scale) / canvas.height),
                       width: Double(width * scale / canvas.width),
                       height: Double(height * scale / canvas.height))
        }
        let top = rect(0, 0, arrangementWidth, upperHeight)
        let bottom = rect(0, upperHeight, arrangementWidth, lowerHeight)
        return CustomScreenPlacement(top: top, bottom: bottom,
                                     showsTop: true, showsBottom: true,
                                     keepsNativeAspect: true)
    }

    /// A full-stage placement used only for a degenerate (zero-size) stage.
    private static func fullStagePlacement() -> CustomScreenPlacement {
        CustomScreenPlacement(top: ScreenRect(x: 0, y: 0, width: 1, height: 1),
                              bottom: ScreenRect(x: 0, y: 0, width: 1, height: 1),
                              showsTop: true,
                              showsBottom: true,
                              keepsNativeAspect: true)
    }

    /// Height fraction of a native-aspect screen with a given width fraction,
    /// from the canvas's own aspect (width / height).
    private static func nativeHeightFraction(width: Double,
                                             canvasAspect: CGFloat,
                                             screen: ScreenKind) -> Double {
        let screenAspect = CustomScreenGeometry.nativeAspect(for: screen)
        guard canvasAspect > 0, screenAspect > 0 else { return width }
        return width * Double(canvasAspect) / Double(screenAspect)
    }
}
