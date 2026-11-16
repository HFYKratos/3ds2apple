//
//  CustomScreenLayout.swift
//  3ds2apple
//
//  User-defined positions and sizes for the two 3DS screens (requirement 8).
//
//  Every rectangle is stored relative to the container the screens are drawn in
//  (0...1, origin at the top left), so one layout scales to any iPhone/iPad. Two
//  arrangements are kept, portrait and landscape, because the container shape is
//  very different between them.
//
//  Where does this apply?
//  - The readback (CGImage) path places the two screen images exactly at these
//    rectangles; touch input on the lower screen keeps working because the same
//    geometry reports its viewport (ScreenGeometry.swift's presenter geometry
//    cannot do arbitrary rectangles: the upstream Zakuro presenter only knows
//    its own five arrangements, see ios/app/README.md).
//  - Because the Metal presenter cannot place one screen independently, a custom
//    layout runs on the readback path: ROMSession skips the presenter while the
//    custom layout is on, so both the picture and the touch mapping come from
//    this single geometry. The tradeoff is documented in the Settings hint and
//    in ios/app/README.md; extending the Zakuro presenter with a custom
//    arrangement is the follow-up that removes it.
//
//  Rotation, integer scaling and the aspect setting are honoured by
//  `CustomScreenGeometry.viewports`: the whole container is turned with the
//  screen rotation (each screen's picture is turned by GameView's readback
//  rendering), and whole-pixel scaling snaps each screen to whole console
//  pixels.
//

import CoreGraphics
import Foundation

/// One screen's rectangle inside the screens container, normalised 0...1.
struct ScreenRect: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Smallest allowed side, so a screen cannot be shrunk to nothing.
    static let minimumSize = 0.08

    func clamped() -> ScreenRect {
        var rect = self
        rect.width = min(max(width, ScreenRect.minimumSize), 1.0)
        rect.height = min(max(height, ScreenRect.minimumSize), 1.0)
        rect.x = min(max(x, 0.0), 1.0 - rect.width)
        rect.y = min(max(y, 0.0), 1.0 - rect.height)
        return rect
    }

    /// The rectangle in container points.
    func cgRect(in container: CGSize) -> CGRect {
        CGRect(x: CGFloat(x) * container.width,
               y: CGFloat(y) * container.height,
               width: CGFloat(width) * container.width,
               height: CGFloat(height) * container.height)
    }

    /// Rebuilds a normalised rectangle from a point-space one.
    static func normalised(_ rect: CGRect, in container: CGSize) -> ScreenRect {
        guard container.width > 0, container.height > 0 else {
            return ScreenRect(x: 0, y: 0, width: 0.5, height: 0.5)
        }
        return ScreenRect(
            x: Double(rect.minX / container.width),
            y: Double(rect.minY / container.height),
            width: Double(rect.width / container.width),
            height: Double(rect.height / container.height)
        ).clamped()
    }
}

/// The two screen rectangles plus which screens are shown, for one orientation.
struct CustomScreenPlacement: Codable, Equatable {
    var top: ScreenRect
    var bottom: ScreenRect
    var showsTop: Bool
    var showsBottom: Bool

    func clamped() -> CustomScreenPlacement {
        CustomScreenPlacement(top: top.clamped(),
                              bottom: bottom.clamped(),
                              showsTop: showsTop,
                              showsBottom: showsBottom)
    }
}

/// Both orientations of the custom screen layout, with a format version so an
/// older app can heal a newer saved profile (see `withDefaultsFilled`).
struct CustomScreenLayout: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var portrait: CustomScreenPlacement
    var landscape: CustomScreenPlacement

    init(version: Int = CustomScreenLayout.currentVersion,
         portrait: CustomScreenPlacement,
         landscape: CustomScreenPlacement) {
        self.version = version
        self.portrait = portrait
        self.landscape = landscape
    }

    func placement(for orientation: ControlLayoutOrientation) -> CustomScreenPlacement {
        switch orientation {
        case .portrait: return portrait
        case .landscape: return landscape
        }
    }

    mutating func setPlacement(_ placement: CustomScreenPlacement,
                               for orientation: ControlLayoutOrientation) {
        switch orientation {
        case .portrait: portrait = placement.clamped()
        case .landscape: landscape = placement.clamped()
        }
    }

    /// Every rectangle clamped into the container. Missing fields cannot happen
    /// with synthesized Codable, so this only has to repair out-of-range values
    /// written by an older build or a bug.
    func withDefaultsFilled() -> CustomScreenLayout {
        CustomScreenLayout(version: Self.currentVersion,
                           portrait: portrait.clamped(),
                           landscape: landscape.clamped())
    }

    /// The shipped default custom layout: a bigger upper screen above a smaller
    /// lower one in portrait, a large-left/small-right pair in landscape (the
    /// shapes the normal presets use, so switching custom on does not jump).
    static func standard() -> CustomScreenLayout {
        CustomScreenLayout(
            portrait: CustomScreenPlacement(
                top: ScreenRect(x: 0.06, y: 0.02, width: 0.88, height: 0.38),
                bottom: ScreenRect(x: 0.14, y: 0.44, width: 0.72, height: 0.39),
                showsTop: true,
                showsBottom: true
            ),
            landscape: CustomScreenPlacement(
                top: ScreenRect(x: 0.03, y: 0.21, width: 0.40, height: 0.58),
                bottom: ScreenRect(x: 0.46, y: 0.50, width: 0.18, height: 0.33),
                showsTop: true,
                showsBottom: true
            )
        )
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) -> CustomScreenLayout? {
        guard let decoded = try? JSONDecoder().decode(CustomScreenLayout.self, from: data) else {
            return nil
        }
        return decoded.withDefaultsFilled()
    }
}

/// Exactly where the two screens go, in view points. Single source of truth for
/// the custom layout's picture placement and its touch mapping.
enum CustomScreenGeometry {
    static let topNativeSize = CGSize(width: 400, height: 240)
    static let bottomNativeSize = CGSize(width: 320, height: 240)

    /// Aspect ratio (width / height) of the console's own screen pixels.
    static func nativeAspect(for orientation: ScreenKind) -> CGFloat {
        switch orientation {
        case .upper: return topNativeSize.width / topNativeSize.height
        case .lower: return bottomNativeSize.width / bottomNativeSize.height
        }
    }

    /// The height a rectangle needs so its picture keeps the console's shape,
    /// given the container's own aspect (width / height) and the rect's width.
    static func heightKeepingNativeAspect(width: Double,
                                          containerAspect: CGFloat,
                                          screenAspect: CGFloat) -> Double {
        guard screenAspect > 0, containerAspect > 0 else { return width }
        return width * Double(containerAspect) / Double(screenAspect)
    }

    /// Viewport rectangles for the custom layout inside `available` points.
    /// - The container is exactly `available` (rotation swaps its dimensions so
    ///   the layout is defined in the upright orientation, then every rectangle
    ///   is turned and centred, exactly like `ScreenGeometry.layoutViewports`).
    /// - With `integerScale` each screen is snapped down to a whole multiple of
    ///   its own console pixels (measured in device pixels), keeping its centre.
    static func viewports(
        available: CGSize,
        placement: CustomScreenPlacement,
        rotation: ScreenRotation,
        displayScale: CGFloat,
        integerScale: Bool
    ) -> (top: CGRect?, bottom: CGRect?) {
        guard available.width >= 1, available.height >= 1 else { return (nil, nil) }
        let quarterTurn = rotation == .clockwise || rotation == .counterClockwise
        let canvas = quarterTurn
            ? CGSize(width: available.height, height: available.width)
            : available

        func rect(_ source: ScreenRect, isUpper: Bool) -> CGRect {
            var placed = source.cgRect(in: canvas)
            guard placed.width > 0, placed.height > 0 else { return .zero }
            if integerScale, displayScale > 0 {
                let native = isUpper ? topNativeSize : bottomNativeSize
                let pixelWidth = placed.width * displayScale
                let pixelHeight = placed.height * displayScale
                let multiple = floor(min(pixelWidth / native.width,
                                         pixelHeight / native.height))
                if multiple >= 1 {
                    let snapped = CGSize(width: native.width * multiple / displayScale,
                                         height: native.height * multiple / displayScale)
                    placed = CGRect(x: placed.midX - snapped.width / 2,
                                    y: placed.midY - snapped.height / 2,
                                    width: snapped.width,
                                    height: snapped.height)
                }
            }
            return placed
        }

        var top = placement.showsTop ? rect(placement.top, isUpper: true) : nil
        var bottom = placement.showsBottom ? rect(placement.bottom, isUpper: false) : nil

        let canvasWidth = canvas.width
        let canvasHeight = canvas.height
        func rotate(_ source: CGRect) -> CGRect {
            switch rotation {
            case .upright:
                return source
            case .clockwise:
                return CGRect(x: canvasHeight - source.minY - source.height,
                              y: source.minX,
                              width: source.height,
                              height: source.width)
            case .upsideDown:
                return CGRect(x: canvasWidth - source.minX - source.width,
                              y: canvasHeight - source.minY - source.height,
                              width: source.width,
                              height: source.height)
            case .counterClockwise:
                return CGRect(x: source.minY,
                              y: canvasWidth - source.minX - source.width,
                              width: source.height,
                              height: source.width)
            }
        }

        let turnedCanvas = quarterTurn
            ? CGSize(width: canvas.height, height: canvas.width)
            : canvas
        let offsetX = (available.width - turnedCanvas.width) / 2
        let offsetY = (available.height - turnedCanvas.height) / 2
        func place(_ source: CGRect?) -> CGRect? {
            guard let source, source.width > 0, source.height > 0 else { return nil }
            return rotate(source).offsetBy(dx: offsetX, dy: offsetY)
        }
        top = place(top)
        bottom = place(bottom)
        return (top, bottom)
    }
}

/// The two 3DS screens, for code that needs to talk about one of them.
enum ScreenKind {
    case upper
    case lower
}
