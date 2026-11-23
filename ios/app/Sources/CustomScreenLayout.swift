//
//  CustomScreenLayout.swift
//  3ds2apple
//
//  User-defined positions and sizes for the two 3DS screens (requirement 8).
//
//  Every rectangle is stored relative to the picture stage the screens are
//  drawn in (0...1, origin at the top left), so one layout scales to any
//  iPhone/iPad. Two arrangements are kept, portrait and landscape, because the
//  stage shape is very different between them.
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
//  0.1.2 (archive version 2):
//  - Each placement remembers whether the editor keeps the console's screen
//    shape ("Lock screen ratio"). The shipped default uses the real screen
//    shapes (upper 400x240 = 5:3, lower 320x240 = 4:3) instead of the old rough
//    rectangles.
//  - Version 1 archives are migrated on read: a layout the user customised is
//    kept exactly as it was (rectangles, shown screens) and only gains the
//    ratio-lock flag (true); the old untouched default rectangles are upgraded
//    to the new native-aspect default, because those are not a user layout.
//
//  0.1.3 (still archive version 2; same Codable shape):
//  - The UI exposes only Default / Custom, so the editor no longer has presets
//    or "upper only" / "lower only": both screens are always shown and the
//    stored show flags are healed to true on read.
//  - The shipped landscape default became the large-top arrangement (the same
//    picture the Default choice shows) instead of side by side; an untouched
//    0.1.2 default is upgraded, a user layout is kept.
//

import CoreGraphics
import Foundation

/// One screen's rectangle inside the picture stage, normalised 0...1.
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

    /// The rectangle in stage points.
    func cgRect(in stage: CGSize) -> CGRect {
        CGRect(x: CGFloat(x) * stage.width,
               y: CGFloat(y) * stage.height,
               width: CGFloat(width) * stage.width,
               height: CGFloat(height) * stage.height)
    }

    /// Rebuilds a normalised rectangle from a point-space one.
    static func normalised(_ rect: CGRect, in stage: CGSize) -> ScreenRect {
        guard stage.width > 0, stage.height > 0 else {
            return ScreenRect(x: 0, y: 0, width: 0.5, height: 0.5)
        }
        return ScreenRect(
            x: Double(rect.minX / stage.width),
            y: Double(rect.minY / stage.height),
            width: Double(rect.width / stage.width),
            height: Double(rect.height / stage.height)
        ).clamped()
    }

    /// The same rectangle with the console screen's own pixel shape, keeping its
    /// centre (the width is the size the user set). `containerAspect` is the
    /// picture stage's width / height, `screenAspect` the 3DS screen's.
    func withNativeAspect(containerAspect: CGFloat, screenAspect: CGFloat) -> ScreenRect {
        guard containerAspect > 0, screenAspect > 0 else { return clamped() }
        var rect = clamped()
        let height = min(Double(containerAspect) / Double(screenAspect) * rect.width, 1.0)
        let centreX = rect.x + rect.width / 2
        let centreY = rect.y + rect.height / 2
        rect.height = height
        rect.x = centreX - rect.width / 2
        rect.y = centreY - height / 2
        return rect.clamped()
    }
}

/// The two screen rectangles plus which screens are shown, for one orientation.
struct CustomScreenPlacement: Codable, Equatable {
    var top: ScreenRect
    var bottom: ScreenRect
    var showsTop: Bool
    var showsBottom: Bool
    /// The editor's "Lock screen ratio": when on, dragging/resizing keeps the
    /// console screen's own shape. Defaults to on, including for archives that
    /// predate the switch.
    var keepsNativeAspect: Bool

    init(top: ScreenRect,
         bottom: ScreenRect,
         showsTop: Bool,
         showsBottom: Bool,
         keepsNativeAspect: Bool = true) {
        self.top = top
        self.bottom = bottom
        self.showsTop = showsTop
        self.showsBottom = showsBottom
        self.keepsNativeAspect = keepsNativeAspect
    }

    private enum CodingKeys: String, CodingKey {
        case top
        case bottom
        case showsTop
        case showsBottom
        case keepsNativeAspect
    }

    /// Version 1 archives have no `keepsNativeAspect`; it defaults to true so
    /// the upgraded layout still keeps the screens' real shape.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        top = try container.decode(ScreenRect.self, forKey: .top)
        bottom = try container.decode(ScreenRect.self, forKey: .bottom)
        showsTop = try container.decode(Bool.self, forKey: .showsTop)
        showsBottom = try container.decode(Bool.self, forKey: .showsBottom)
        keepsNativeAspect = try container.decodeIfPresent(Bool.self, forKey: .keepsNativeAspect) ?? true
    }

    func clamped() -> CustomScreenPlacement {
        CustomScreenPlacement(top: top.clamped(),
                              bottom: bottom.clamped(),
                              showsTop: showsTop,
                              showsBottom: showsBottom,
                              keepsNativeAspect: keepsNativeAspect)
    }

    /// The screen rectangle for one of the two screens.
    func rect(for kind: ScreenKind) -> ScreenRect {
        kind == .upper ? top : bottom
    }

    mutating func setRect(_ rect: ScreenRect, for kind: ScreenKind) {
        switch kind {
        case .upper: top = rect.clamped()
        case .lower: bottom = rect.clamped()
        }
    }

    /// Both rectangles with their console screen shape, keeping each centre.
    func withNativeAspect(containerAspect: CGFloat) -> CustomScreenPlacement {
        var placement = self
        placement.top = top.withNativeAspect(
            containerAspect: containerAspect,
            screenAspect: CustomScreenGeometry.nativeAspect(for: .upper)
        )
        placement.bottom = bottom.withNativeAspect(
            containerAspect: containerAspect,
            screenAspect: CustomScreenGeometry.nativeAspect(for: .lower)
        )
        return placement
    }
}

/// Both orientations of the custom screen layout, with a format version so an
/// older app can heal a newer saved profile (see `withDefaultsFilled`).
struct CustomScreenLayout: Codable, Equatable {
    /// Round 2: the shipped defaults are the placements measured from the
    /// reference screenshots (percentages of the game view), and archive v2's
    /// round-1 defaults are migrated to them.
    static let currentVersion = 3

    /// The picture-stage shapes the round-1 shipped defaults were calculated
    /// for. Kept only so the migration can recognise those untouched defaults;
    /// the round-2 defaults are explicit percentages.
    static let legacyReferencePortraitAspect: CGFloat = 0.756
    static let legacyReferenceLandscapeAspect: CGFloat = 2.319

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

    /// Every rectangle clamped into the stage. Missing fields cannot happen with
    /// synthesized Codable, so this only has to repair out-of-range values
    /// written by an older build or a bug.
    ///
    /// 0.1.3 no longer offers "upper only" / "lower only", so both screens are
    /// always shown here; 0.1.2 archives that hid one screen heal to both. The
    /// flags stay in the Codable shape so v2 archives keep decoding.
    func withDefaultsFilled() -> CustomScreenLayout {
        var layout = CustomScreenLayout(version: Self.currentVersion,
                                        portrait: portrait.clamped(),
                                        landscape: landscape.clamped())
        layout.portrait.showsTop = true
        layout.portrait.showsBottom = true
        layout.landscape.showsTop = true
        layout.landscape.showsBottom = true
        return layout
    }

    /// The shipped round-2 default archive (both directions).
    static func standard() -> CustomScreenLayout {
        CustomScreenLayout(
            portrait: defaultPlacement(for: .portrait),
            landscape: defaultPlacement(for: .landscape)
        )
    }

    /// The shipped round-2 default placement for one orientation, measured from
    /// the reference screenshots and expressed as percentages of the game view:
    /// - portrait: upper {0, 0, 74, 21}, lower {7, 22, 59, 21};
    /// - landscape: upper {0, 0, 35, 47}, lower {4, 46, 27, 45}.
    /// Both screens are shown and the numeric custom pages start from these
    /// values.
    static func defaultPlacement(for orientation: ControlLayoutOrientation) -> CustomScreenPlacement {
        switch orientation {
        case .portrait:
            return CustomScreenPlacement(
                top: ScreenRect(x: 0.00, y: 0.00, width: 0.74, height: 0.21),
                bottom: ScreenRect(x: 0.07, y: 0.22, width: 0.59, height: 0.21),
                showsTop: true,
                showsBottom: true,
                keepsNativeAspect: true
            )
        case .landscape:
            return CustomScreenPlacement(
                top: ScreenRect(x: 0.00, y: 0.00, width: 0.35, height: 0.47),
                bottom: ScreenRect(x: 0.04, y: 0.46, width: 0.27, height: 0.45),
                showsTop: true,
                showsBottom: true,
                keepsNativeAspect: true
            )
        }
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) -> CustomScreenLayout? {
        guard let decoded = try? JSONDecoder().decode(CustomScreenLayout.self, from: data) else {
            return nil
        }
        return decoded.migrated()
    }

    // MARK: - Version migration

    /// Upgrades an archive to the current version. The round-2 defaults replace
    /// the round-1 (and older) shipped defaults, so an install that still has an
    /// untouched old default gets the measured reference placements; a layout the
    /// user moved is kept exactly. The Codable rectangle shape is unchanged, so
    /// an older build can still decode a v3 archive (it heals it to its own
    /// version and keeps the rectangles).
    func migrated() -> CustomScreenLayout {
        var layout = self
        if version < Self.currentVersion {
            if Self.matchesLegacyShippedDefault(layout.portrait, orientation: .portrait) {
                layout.portrait = Self.defaultPlacement(for: .portrait)
            }
            if Self.matchesLegacyShippedDefault(layout.landscape, orientation: .landscape) {
                layout.landscape = Self.defaultPlacement(for: .landscape)
            }
        }
        layout.version = CustomScreenLayout.currentVersion
        return layout.withDefaultsFilled()
    }

    /// True when a placement is exactly one of the shipped defaults of an older
    /// build: 0.1.1/0.1.2 (side by side in landscape) or the round-1 large-top
    /// and stacked defaults. A layout the user moved never matches.
    private static func matchesLegacyShippedDefault(
        _ placement: CustomScreenPlacement,
        orientation: ControlLayoutOrientation
    ) -> Bool {
        guard placement.showsTop, placement.showsBottom else { return false }
        for expected in legacyShippedDefaults(for: orientation) {
            if matches(placement.top, expected.top) && matches(placement.bottom, expected.bottom) {
                return true
            }
        }
        return false
    }

    /// The shipped defaults of the builds before round 2, for one direction.
    private static func legacyShippedDefaults(
        for orientation: ControlLayoutOrientation
    ) -> [CustomScreenPlacement] {
        switch orientation {
        case .portrait:
            return [version1PortraitDefault, roundOnePortraitDefault]
        case .landscape:
            return [version1LandscapeDefault,
                    version2LandscapeSideBySideDefault,
                    roundOneLandscapeDefault]
        }
    }

    /// The rectangles CustomScreenLayout.standard() shipped in 0.1.1 (portrait).
    private static let version1PortraitDefault = CustomScreenPlacement(
        top: ScreenRect(x: 0.06, y: 0.02, width: 0.88, height: 0.38),
        bottom: ScreenRect(x: 0.14, y: 0.44, width: 0.72, height: 0.39),
        showsTop: true,
        showsBottom: true
    )

    /// The rectangles CustomScreenLayout.standard() shipped in 0.1.1/0.1.2
    /// (landscape).
    private static let version1LandscapeDefault = CustomScreenPlacement(
        top: ScreenRect(x: 0.03, y: 0.21, width: 0.40, height: 0.58),
        bottom: ScreenRect(x: 0.46, y: 0.50, width: 0.18, height: 0.33),
        showsTop: true,
        showsBottom: true
    )

    /// The landscape default 0.1.1 and 0.1.2 shipped: the two screens side by
    /// side at their native shapes.
    private static let version2LandscapeSideBySideDefault: CustomScreenPlacement = {
        let margin = 0.02
        let gap = 0.02
        let height = 0.88
        let upperAspect = Double(CustomScreenGeometry.nativeAspect(for: .upper))
        let lowerAspect = Double(CustomScreenGeometry.nativeAspect(for: .lower))
        let landscapeAspect = Double(CustomScreenLayout.legacyReferenceLandscapeAspect)
        var topWidth = height * upperAspect / landscapeAspect
        var bottomWidth = height * lowerAspect / landscapeAspect
        let available = max(1 - margin * 2 - gap, 0.2)
        var scale = 1.0
        if topWidth + bottomWidth > available {
            scale = available / (topWidth + bottomWidth)
            topWidth *= scale
            bottomWidth *= scale
        }
        let placedHeight = height * scale
        return CustomScreenPlacement(
            top: ScreenRect(x: margin,
                            y: (1 - placedHeight) / 2,
                            width: topWidth,
                            height: placedHeight),
            bottom: ScreenRect(x: 1 - margin - bottomWidth,
                               y: (1 - placedHeight) / 2,
                               width: bottomWidth,
                               height: placedHeight),
            showsTop: true,
            showsBottom: true
        )
    }()

    /// The round-1 portrait default: the stacked screens at their native shapes.
    private static let roundOnePortraitDefault: CustomScreenPlacement = {
        let margin = 0.02
        let gap = 0.02
        let upperAspect = Double(CustomScreenGeometry.nativeAspect(for: .upper))
        let lowerAspect = Double(CustomScreenGeometry.nativeAspect(for: .lower))
        let portraitAspect = Double(CustomScreenLayout.legacyReferencePortraitAspect)
        var topWidth = 0.94
        var bottomWidth = 0.84
        var topHeight = topWidth * portraitAspect / upperAspect
        var bottomHeight = bottomWidth * portraitAspect / lowerAspect
        let available = max(1 - margin * 2 - gap, 0.2)
        if topHeight + bottomHeight > available {
            let scale = available / (topHeight + bottomHeight)
            topWidth *= scale
            bottomWidth *= scale
            topHeight *= scale
            bottomHeight *= scale
        }
        return CustomScreenPlacement(
            top: ScreenRect(x: (1 - topWidth) / 2, y: margin,
                            width: topWidth, height: topHeight),
            bottom: ScreenRect(x: (1 - bottomWidth) / 2,
                               y: 1 - margin - bottomHeight,
                               width: bottomWidth, height: bottomHeight),
            showsTop: true,
            showsBottom: true
        )
    }()

    /// The round-1 landscape default: the large upper screen with the small
    /// lower screen at its lower right.
    private static let roundOneLandscapeDefault: CustomScreenPlacement = {
        let margin = 0.03
        let upperAspect = Double(CustomScreenGeometry.nativeAspect(for: .upper))
        let lowerAspect = Double(CustomScreenGeometry.nativeAspect(for: .lower))
        let landscapeAspect = Double(CustomScreenLayout.legacyReferenceLandscapeAspect)
        let topWidth = 0.50
        let bottomWidth = 0.20
        let topHeight = topWidth * landscapeAspect / upperAspect
        let bottomHeight = bottomWidth * landscapeAspect / lowerAspect
        return CustomScreenPlacement(
            top: ScreenRect(x: (1 - topWidth) / 2, y: margin,
                            width: topWidth, height: topHeight),
            bottom: ScreenRect(x: 1 - margin - bottomWidth,
                               y: 1 - margin - bottomHeight,
                               width: bottomWidth, height: bottomHeight),
            showsTop: true,
            showsBottom: true
        )
    }()

    private static func matches(_ lhs: ScreenRect, _ rhs: ScreenRect) -> Bool {
        abs(lhs.x - rhs.x) < 0.001
            && abs(lhs.y - rhs.y) < 0.001
            && abs(lhs.width - rhs.width) < 0.001
            && abs(lhs.height - rhs.height) < 0.001
    }
}

/// Exactly where the two screens go, in view points. Single source of truth for
/// the custom layout's picture placement and its touch mapping.
enum CustomScreenGeometry {
    static let topNativeSize = CGSize(width: 400, height: 240)
    static let bottomNativeSize = CGSize(width: 320, height: 240)

    /// Aspect ratio (width / height) of the console's own screen pixels.
    static func nativeAspect(for screen: ScreenKind) -> CGFloat {
        switch screen {
        case .upper: return topNativeSize.width / topNativeSize.height
        case .lower: return bottomNativeSize.width / bottomNativeSize.height
        }
    }

    /// The height a rectangle needs so its picture keeps the console's shape,
    /// given the stage's own aspect (width / height) and the rect's width.
    static func heightKeepingNativeAspect(width: Double,
                                          containerAspect: CGFloat,
                                          screenAspect: CGFloat) -> Double {
        guard screenAspect > 0, containerAspect > 0 else { return width }
        return width * Double(containerAspect) / Double(screenAspect)
    }

    /// The upright canvas a layout is defined in, for a displayed box and a
    /// screen rotation. A quarter turn swaps width and height.
    static func canvasSize(available: CGSize, rotation: ScreenRotation) -> CGSize {
        let quarterTurn = rotation == .clockwise || rotation == .counterClockwise
        return quarterTurn
            ? CGSize(width: available.height, height: available.width)
            : available
    }

    /// Turns one rectangle of the upright canvas into the displayed box. The
    /// result is in the turned canvas' own coordinates (same size as the
    /// displayed box for a quarter turn), so callers only have to centre it.
    static func rotateToDisplay(_ rect: CGRect,
                                rotation: ScreenRotation,
                                canvas: CGSize) -> CGRect {
        switch rotation {
        case .upright:
            return rect
        case .clockwise:
            return CGRect(x: canvas.height - rect.minY - rect.height,
                          y: rect.minX,
                          width: rect.height,
                          height: rect.width)
        case .upsideDown:
            return CGRect(x: canvas.width - rect.minX - rect.width,
                          y: canvas.height - rect.minY - rect.height,
                          width: rect.width,
                          height: rect.height)
        case .counterClockwise:
            return CGRect(x: rect.minY,
                          y: canvas.width - rect.minX - rect.width,
                          width: rect.height,
                          height: rect.width)
        }
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
        let canvas = canvasSize(available: available, rotation: rotation)

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

        let turnedCanvas = rotation == .clockwise || rotation == .counterClockwise
            ? CGSize(width: canvas.height, height: canvas.width)
            : canvas
        let offsetX = (available.width - turnedCanvas.width) / 2
        let offsetY = (available.height - turnedCanvas.height) / 2
        func place(_ source: CGRect?) -> CGRect? {
            guard let source, source.width > 0, source.height > 0 else { return nil }
            return rotateToDisplay(source, rotation: rotation, canvas: canvas)
                .offsetBy(dx: offsetX, dy: offsetY)
        }
        top = place(top)
        bottom = place(bottom)
        return (top, bottom)
    }

    /// The custom GPU presenter's viewports: each native picture is aspect-fitted
    /// and centred inside the user's rectangle, then normalised to the drawable
    /// (0..1, top-left origin). Only used for the upright rotation; the custom
    /// layout falls back to readback for any other rotation.
    /// Inversely rotates a normalised display point into the upright canvas the
    /// custom-touch helper expects (the presenter rotates the pictures for the
    /// screen-rotation setting).
    static func inverseRotatedNormalisedPoint(_ point: CGPoint,
                                              rotation: ScreenRotation) -> CGPoint {
        switch rotation {
        case .upright:
            return point
        case .clockwise:
            return CGPoint(x: point.y, y: 1 - point.x)
        case .upsideDown:
            return CGPoint(x: 1 - point.x, y: 1 - point.y)
        case .counterClockwise:
            return CGPoint(x: 1 - point.y, y: point.x)
        }
    }

    static func presenterNormalisedViewports(
        available: CGSize,
        placement: CustomScreenPlacement
    ) -> (top: CGRect, bottom: CGRect) {
        guard available.width >= 1, available.height >= 1 else { return (.zero, .zero) }
        func fitted(_ source: ScreenRect, native: CGSize) -> CGRect {
            let placed = source.cgRect(in: available)
            guard placed.width > 0, placed.height > 0 else { return .zero }
            let scale = min(placed.width / native.width, placed.height / native.height)
            let size = CGSize(width: native.width * scale, height: native.height * scale)
            return CGRect(x: placed.midX - size.width / 2,
                          y: placed.midY - size.height / 2,
                          width: size.width,
                          height: size.height)
        }
        func normalised(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX / available.width,
                   y: rect.minY / available.height,
                   width: rect.width / available.width,
                   height: rect.height / available.height)
        }
        return (normalised(fitted(placement.top, native: topNativeSize)),
                normalised(fitted(placement.bottom, native: bottomNativeSize)))
    }
}

/// The two 3DS screens, for code that needs to talk about one of them.
enum ScreenKind: Hashable {
    case upper
    case lower
}