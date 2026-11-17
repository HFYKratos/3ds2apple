//
//  GameViewGeometry.swift
//  3ds2apple
//
//  The one place that describes the box model of the running game screen, shared
//  by GameView and by the two layout editors.
//
//  The editors used to preview their layouts on abstract containers ("the pad
//  area" as a 1.6:1 box, landscape as 16:9). Those numbers are not what the game
//  view builds: the portrait pad is as wide as the screen minus the page
//  paddings and as high as 27% of the safe-area height (clamped to 220...300 pt),
//  and the landscape overlay is the whole safe-area box expanded sideways past
//  the notch. On a phone the difference is a few percent, on an iPad it is
//  enormous - which is why a layout that looked right in the editor felt wrong in
//  the game.
//
//  This file derives the real geometry from the live window scene with the same
//  rules GameView uses (screen size, safe area, paddings, spacing, pad height),
//  so the editors can draw and manipulate the exact boxes the runtime will use.
//  It also holds the control frame maths (one control's centre/size in container
//  points) and the snapping helpers both editors share.
//

import CoreGraphics
import Foundation
import SwiftUI
import UIKit

// MARK: - Game view layout constants

/// The paddings, spacings and sizes GameView lays the running game out with.
/// The editors build their preview from the same numbers, so a change here
/// moves the runtime and both previews together.
enum GameViewLayout {
    /// GameView.portraitContent horizontal padding.
    static let portraitHorizontalPadding: CGFloat = 12
    /// GameView.portraitContent top padding.
    static let portraitTopPadding: CGFloat = 8
    /// GameView.portraitContent bottom padding.
    static let portraitBottomPadding: CGFloat = 10
    /// Spacing of the portrait top bar / screens / control pad stack.
    static let portraitSpacing: CGFloat = 10
    /// Height of the portrait title bar (when a game is loaded).
    static let portraitTopBarHeight: CGFloat = 36
    /// The control pad's own horizontal padding (inside the page padding).
    static let controlPadHorizontalPadding: CGFloat = 2
    /// Control pad height as a fraction of the game view's height...
    static let controlPadHeightFraction: CGFloat = 0.27
    /// ...clamped to this range. Same numbers as the old inline formula.
    static let controlPadMinimumHeight: CGFloat = 220
    static let controlPadMaximumHeight: CGFloat = 300
    /// GameView.landscapeContent pads the picture stage by this much.
    static let landscapeStagePadding: CGFloat = 4

    /// The height of the portrait control pad for a game view of
    /// `gameViewHeight` points. GameView uses this; the controls editor previews it.
    static func portraitControlPadHeight(gameViewHeight: CGFloat) -> CGFloat {
        min(max(gameViewHeight * controlPadHeightFraction,
                controlPadMinimumHeight),
            controlPadMaximumHeight)
    }
}

// MARK: - Device metrics

/// Safe-area insets in the app's own terms (leading/trailing = left/right).
struct GameViewInsets: Equatable {
    var top: CGFloat
    var leading: CGFloat
    var bottom: CGFloat
    var trailing: CGFloat

    static let zero = GameViewInsets(top: 0, leading: 0, bottom: 0, trailing: 0)

    var horizontal: CGFloat { leading + trailing }
    var vertical: CGFloat { top + bottom }
}

/// The device screen and its safe areas, normalised to the portrait orientation
/// (width <= height) and measured in points. Captured from the active window
/// scene, so the editors use the real screen the user is holding.
struct GameViewDeviceMetrics: Equatable {
    /// Portrait-normalised screen size in points (e.g. 393 x 852).
    var screenSize: CGSize
    /// Safe-area insets in portrait (notch on top, home indicator at the bottom).
    var portraitInsets: GameViewInsets
    /// Safe-area insets in landscape (notch on one side, status bar typically
    /// hidden on iPhone).
    var landscapeInsets: GameViewInsets

    /// A notched iPhone shape used only when no window scene exists yet (for
    /// example a headless screenshot launch before the first window is up).
    static let fallback = GameViewDeviceMetrics(
        screenSize: CGSize(width: 393, height: 852),
        portraitInsets: GameViewInsets(top: 59, leading: 0, bottom: 34, trailing: 0),
        landscapeInsets: GameViewInsets(top: 0, leading: 59, bottom: 21, trailing: 59)
    )

    /// Reads the live window scene. The orientation the app is in at this moment
    /// gives the exact insets for that orientation; the other orientation's
    /// insets are the same values moved to the edges iOS moves them to
    /// (notch -> side in landscape, home indicator 34 pt -> 21 pt).
    static func current() -> GameViewDeviceMetrics {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else {
            return .fallback
        }
        let bounds = scene.screen.bounds
        let screenSize = CGSize(width: min(bounds.width, bounds.height),
                                height: max(bounds.width, bounds.height))
        let window = scene.keyWindow ?? scene.windows.first
        let insets = window?.safeAreaInsets ?? .zero
        let isLandscape = scene.interfaceOrientation == .landscapeLeft
            || scene.interfaceOrientation == .landscapeRight
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        if isLandscape {
            let landscape = GameViewInsets(top: insets.top,
                                           leading: insets.left,
                                           bottom: insets.bottom,
                                           trailing: insets.right)
            return GameViewDeviceMetrics(
                screenSize: screenSize,
                portraitInsets: portraitInsets(fromLandscape: landscape, isPad: isPad),
                landscapeInsets: landscape
            )
        }
        let portrait = GameViewInsets(top: insets.top,
                                      leading: insets.left,
                                      bottom: insets.bottom,
                                      trailing: insets.right)
        return GameViewDeviceMetrics(
            screenSize: screenSize,
            portraitInsets: portrait,
            landscapeInsets: landscapeInsets(fromPortrait: portrait, isPad: isPad)
        )
    }

    /// The physical screen size in points for an orientation.
    func screenPointSize(for orientation: ControlLayoutOrientation) -> CGSize {
        switch orientation {
        case .portrait: return screenSize
        case .landscape: return CGSize(width: screenSize.height, height: screenSize.width)
        }
    }

    /// The safe-area insets for an orientation.
    func insets(for orientation: ControlLayoutOrientation) -> GameViewInsets {
        switch orientation {
        case .portrait: return portraitInsets
        case .landscape: return landscapeInsets
        }
    }

    /// The size of the game view's safe-area box: what GameView's GeometryReader
    /// reports for an orientation.
    func gameViewSize(for orientation: ControlLayoutOrientation) -> CGSize {
        let screen = screenPointSize(for: orientation)
        let insets = insets(for: orientation)
        return CGSize(width: screen.width - insets.horizontal,
                      height: screen.height - insets.vertical)
    }

    private static func portraitInsets(fromLandscape landscape: GameViewInsets,
                                       isPad: Bool) -> GameViewInsets {
        if isPad {
            return GameViewInsets(top: landscape.top, leading: 0,
                                  bottom: landscape.bottom, trailing: 0)
        }
        // iPhone: the notch/Dynamic Island is on one long side in landscape and
        // becomes the top inset in portrait; the home indicator is 21 pt in
        // landscape and 34 pt in portrait.
        let notch = max(landscape.leading, landscape.trailing)
        let bottom: CGFloat = landscape.bottom >= 20 ? 34 : 0
        return GameViewInsets(top: notch, leading: 0, bottom: bottom, trailing: 0)
    }

    private static func landscapeInsets(fromPortrait portrait: GameViewInsets,
                                        isPad: Bool) -> GameViewInsets {
        if isPad {
            // iPad keeps its status bar in landscape; the home indicator is 20 pt
            // in both orientations.
            return GameViewInsets(top: portrait.top, leading: 0,
                                  bottom: portrait.bottom, trailing: 0)
        }
        // iPhone hides the status bar in landscape; the notch moves to the sides.
        let side: CGFloat = portrait.top > 24 ? portrait.top : 0
        let bottom: CGFloat = portrait.bottom >= 34 ? 21 : portrait.bottom
        return GameViewInsets(top: 0, leading: side, bottom: bottom, trailing: side)
    }
}

extension GameViewDeviceMetrics {
    /// The direction the interface is in right now. The layout editors open for
    /// this direction and edit only its layout, because portrait and landscape
    /// keep separate rectangles/profiles.
    static var currentLayoutOrientation: ControlLayoutOrientation {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else {
            return .portrait
        }
        switch scene.interfaceOrientation {
        case .landscapeLeft, .landscapeRight:
            return .landscape
        default:
            return .portrait
        }
    }
}

// MARK: - Preview geometry

/// The pieces of the running game screen the layout editors draw, in device
/// points: the physical screen, the game view's safe-area box, the 3DS picture
/// stage and the box the on-screen controls are drawn in.
struct GameViewPreviewGeometry: Equatable {
    var orientation: ControlLayoutOrientation
    /// Full physical screen rectangle in points, origin (0, 0).
    var screenSize: CGSize
    /// The game view's safe-area box inside the screen.
    var gameViewRect: CGRect
    /// The 3DS picture stage (GameView.screenStage) inside the game view.
    var screenStageRect: CGRect
    /// The box the runtime gives VirtualControlsView.
    var controlContainerRect: CGRect
    /// The portrait title bar; nil in landscape.
    var topBarRect: CGRect?

    static func make(orientation: ControlLayoutOrientation,
                     metrics: GameViewDeviceMetrics,
                     showsTopBar: Bool = true) -> GameViewPreviewGeometry {
        switch orientation {
        case .portrait:
            let screen = metrics.screenPointSize(for: .portrait)
            let insets = metrics.portraitInsets
            let gameRect = CGRect(x: insets.leading,
                                  y: insets.top,
                                  width: screen.width - insets.horizontal,
                                  height: screen.height - insets.vertical)
            let contentX = gameRect.minX + GameViewLayout.portraitHorizontalPadding
            let contentY = gameRect.minY + GameViewLayout.portraitTopPadding
            let contentWidth = max(gameRect.width - GameViewLayout.portraitHorizontalPadding * 2, 1)
            let contentHeight = max(gameRect.height
                                    - GameViewLayout.portraitTopPadding
                                    - GameViewLayout.portraitBottomPadding, 1)
            let topBar: CGRect? = showsTopBar
                ? CGRect(x: contentX, y: contentY,
                         width: contentWidth, height: GameViewLayout.portraitTopBarHeight)
                : nil
            let padHeight = GameViewLayout.portraitControlPadHeight(gameViewHeight: gameRect.height)
            let gapCount: CGFloat = showsTopBar ? 2 : 1
            let stageY = contentY
                + (showsTopBar ? GameViewLayout.portraitTopBarHeight + GameViewLayout.portraitSpacing : 0)
            let stageHeight = max(contentHeight
                                  - (showsTopBar ? GameViewLayout.portraitTopBarHeight : 0)
                                  - padHeight
                                  - GameViewLayout.portraitSpacing * gapCount, 1)
            let stage = CGRect(x: contentX, y: stageY,
                               width: contentWidth, height: stageHeight)
            let pad = CGRect(x: contentX + GameViewLayout.controlPadHorizontalPadding,
                             y: stage.maxY + GameViewLayout.portraitSpacing,
                             width: max(contentWidth - GameViewLayout.controlPadHorizontalPadding * 2, 1),
                             height: padHeight)
            return GameViewPreviewGeometry(orientation: .portrait,
                                           screenSize: screen,
                                           gameViewRect: gameRect,
                                           screenStageRect: stage,
                                           controlContainerRect: pad,
                                           topBarRect: topBar)
        case .landscape:
            let screen = metrics.screenPointSize(for: .landscape)
            let insets = metrics.landscapeInsets
            // GameView.landscapeContent ignores the safe area horizontally: the
            // overlay is the full screen width and the safe-area height.
            let control = CGRect(x: 0,
                                 y: insets.top,
                                 width: screen.width,
                                 height: screen.height - insets.vertical)
            let stage = control.insetBy(dx: GameViewLayout.landscapeStagePadding,
                                        dy: GameViewLayout.landscapeStagePadding)
            return GameViewPreviewGeometry(orientation: .landscape,
                                           screenSize: screen,
                                           gameViewRect: CGRect(x: insets.leading,
                                                                y: insets.top,
                                                                width: screen.width - insets.horizontal,
                                                                height: screen.height - insets.vertical),
                                           screenStageRect: stage,
                                           controlContainerRect: control,
                                           topBarRect: nil)
        }
    }
}

/// Maps device points into a scaled preview box (letterboxed, centred).
struct GameViewPreviewScaler {
    let scale: CGFloat
    /// The physical screen rectangle in preview coordinates.
    let screenRect: CGRect

    init(available: CGSize,
         metrics: GameViewDeviceMetrics,
         orientation: ControlLayoutOrientation,
         padding: CGFloat = 10) {
        let screen = metrics.screenPointSize(for: orientation)
        let usable = CGSize(width: max(available.width - padding * 2, 1),
                            height: max(available.height - padding * 2, 1))
        let fit = min(usable.width / max(screen.width, 1),
                      usable.height / max(screen.height, 1))
        let factor = max(fit, 0.01)
        scale = factor
        let drawn = CGSize(width: screen.width * factor, height: screen.height * factor)
        screenRect = CGRect(x: (available.width - drawn.width) / 2,
                            y: (available.height - drawn.height) / 2,
                            width: drawn.width, height: drawn.height)
    }

    func length(_ value: CGFloat) -> CGFloat { value * scale }
    func point(_ point: CGPoint) -> CGPoint {
        CGPoint(x: screenRect.minX + point.x * scale,
                y: screenRect.minY + point.y * scale)
    }
    func rect(_ rect: CGRect) -> CGRect {
        CGRect(x: screenRect.minX + rect.minX * scale,
               y: screenRect.minY + rect.minY * scale,
               width: rect.width * scale,
               height: rect.height * scale)
    }
}

// MARK: - Screen contents of the preview

extension GameViewPreviewGeometry {
    /// Where the two 3DS screens go inside the picture stage, mirroring what
    /// GameView draws (readback geometry; the Metal presenter lays the same
    /// arrangement out in its drawable). Used by the editors to draw the screens
    /// behind the controls / around the custom screen layout.
    static func screenViewports(in stage: CGSize,
                                settings: AppSettings,
                                orientation: ControlLayoutOrientation,
                                displayScale: CGFloat) -> (top: CGRect?, bottom: CGRect?) {
        guard stage.width >= 1, stage.height >= 1 else { return (nil, nil) }
        if settings.usesCustomScreenLayout {
            return CustomScreenGeometry.viewports(
                available: stage,
                placement: settings.customScreenLayout.placement(for: orientation),
                rotation: settings.screenRotation,
                displayScale: displayScale,
                integerScale: settings.integerScale
            )
        }
        let layout = settings.effectiveScreenLayout(isLandscape: orientation == .landscape)
        let stretch = settings.screenAspect == .stretch
        let arrangementAspect = ScreenGeometry.contentAspect(layout: layout,
                                                             rotation: settings.screenRotation)
        let box: CGSize
        if stretch {
            box = ScreenGeometry.fittedSize(aspect: arrangementAspect, in: stage)
        } else {
            box = ScreenGeometry.contentSize(available: stage,
                                             layout: layout,
                                             rotation: settings.screenRotation,
                                             aspect: settings.screenAspect,
                                             integerScale: settings.integerScale,
                                             displayScale: displayScale)
        }
        let viewports = ScreenGeometry.layoutViewports(available: box,
                                                       layout: layout,
                                                       rotation: settings.screenRotation)
        guard stretch, box.width >= 1, box.height >= 1 else { return viewports }
        let scaleX = stage.width / box.width
        let scaleY = stage.height / box.height
        func stretched(_ rect: CGRect?) -> CGRect? {
            guard let rect else { return nil }
            return CGRect(x: rect.minX * scaleX, y: rect.minY * scaleY,
                          width: rect.width * scaleX, height: rect.height * scaleY)
        }
        return (stretched(viewports.top), stretched(viewports.bottom))
    }
}

// MARK: - Control frames

/// One control's point geometry inside the runtime overlay container.
struct ControlFrame: Equatable {
    var center: CGPoint
    var diameter: CGFloat
    var width: CGFloat

    var height: CGFloat { diameter }
    var bounds: CGRect {
        CGRect(x: center.x - width / 2, y: center.y - height / 2,
               width: width, height: height)
    }

    /// Keeps the whole control inside the container.
    func clampedCenter(_ proposed: CGPoint, in container: CGSize) -> CGPoint {
        let halfWidth = width / 2
        let halfHeight = height / 2
        return CGPoint(
            x: min(max(proposed.x, halfWidth), max(container.width - halfWidth, halfWidth)),
            y: min(max(proposed.y, halfHeight), max(container.height - halfHeight, halfHeight))
        )
    }
}

extension ControlElement {
    /// The control's drawn width relative to its diameter: the shoulder buttons
    /// and Start/Select are wide capsules, everything else is round/square.
    var widthRatio: CGFloat {
        switch self {
        case .buttonL, .buttonR, .buttonZL, .buttonZR: return 1.65
        case .buttonStart, .buttonSelect: return 1.55
        default: return 1.0
        }
    }

    /// The minimum drawn diameter the runtime and the editors share.
    static let minimumDiameter: CGFloat = 18

    /// The control's point frame in a container. VirtualControlsView draws with
    /// this exact frame and the controls editor manipulates it, so a drag in the
    /// editor lands where the runtime draws the control.
    func frame(for placement: ControlPlacement, in container: CGSize) -> ControlFrame {
        let shortSide = min(container.width, container.height)
        let diameter = max(shortSide * CGFloat(placement.size), ControlElement.minimumDiameter)
        let center = CGPoint(x: container.width * CGFloat(placement.x),
                             y: container.height * CGFloat(placement.y))
        return ControlFrame(center: center, diameter: diameter, width: diameter * widthRatio)
    }
}

// MARK: - Control snapping

/// Snapping for the controls editor: the dragged control jumps to the
/// container's edges/centre and to the other controls' centres/edges, and the
/// editor draws a guide line at the aligned coordinate.
enum ControlLayoutSnapping {
    /// Snapping distance in container points. The preview scales this with the
    /// preview, so the feel is the same on a phone and an iPad.
    static let threshold: CGFloat = 8

    struct Result: Equatable {
        var center: CGPoint
        /// Vertical guide (container x) to draw; nil when not snapped.
        var guideX: CGFloat?
        /// Horizontal guide (container y) to draw; nil when not snapped.
        var guideY: CGFloat?
    }

    static func snap(center: CGPoint,
                     frame: ControlFrame,
                     container: CGSize,
                     others: [(element: ControlElement, frame: ControlFrame)]) -> Result {
        let halfWidth = frame.width / 2
        let halfHeight = frame.height / 2

        var xCandidates: [(target: CGFloat, guide: CGFloat)] = [
            (halfWidth, 0),
            (container.width / 2, container.width / 2),
            (container.width - halfWidth, container.width)
        ]
        var yCandidates: [(target: CGFloat, guide: CGFloat)] = [
            (halfHeight, 0),
            (container.height / 2, container.height / 2),
            (container.height - halfHeight, container.height)
        ]
        for other in others {
            let bounds = other.frame.bounds
            xCandidates.append((other.frame.center.x, other.frame.center.x))
            xCandidates.append((bounds.minX + halfWidth, bounds.minX))
            xCandidates.append((bounds.maxX - halfWidth, bounds.maxX))
            yCandidates.append((other.frame.center.y, other.frame.center.y))
            yCandidates.append((bounds.minY + halfHeight, bounds.minY))
            yCandidates.append((bounds.maxY - halfHeight, bounds.maxY))
        }

        var snappedX = center.x
        var guideX: CGFloat?
        var bestX = threshold
        for candidate in xCandidates {
            let distance = abs(center.x - candidate.target)
            if distance <= bestX {
                bestX = distance
                snappedX = candidate.target
                guideX = candidate.guide
            }
        }
        var snappedY = center.y
        var guideY: CGFloat?
        var bestY = threshold
        for candidate in yCandidates {
            let distance = abs(center.y - candidate.target)
            if distance <= bestY {
                bestY = distance
                snappedY = candidate.target
                guideY = candidate.guide
            }
        }
        return Result(center: CGPoint(x: snappedX, y: snappedY),
                      guideX: guideX, guideY: guideY)
    }
}

// MARK: - Screen rectangle snapping

/// Snapping for the custom screen layout editor: a dragged/resized screen snaps to
/// the picture stage edges and to the other screen, with guide lines.
enum ScreenLayoutSnapping {
    /// Snapping distance in picture-stage points.
    static let threshold: CGFloat = 8

    struct Result: Equatable {
        var rect: CGRect
        var guidesX: [CGFloat]
        var guidesY: [CGFloat]
    }

    /// Snaps a canvas-point rectangle. `other` is the other screen's rectangle
    /// in the same canvas (nil when it is hidden).
    static func snap(rect: CGRect, canvas: CGSize, other: CGRect?) -> Result {
        var guidesX: [CGFloat] = []
        var guidesY: [CGFloat] = []
        var originX = rect.origin.x
        var originY = rect.origin.y

        var xTargets: [(origin: CGFloat, guide: CGFloat)] = [
            (0, 0),
            (canvas.width / 2 - rect.width / 2, canvas.width / 2),
            (canvas.width - rect.width, canvas.width)
        ]
        var yTargets: [(origin: CGFloat, guide: CGFloat)] = [
            (0, 0),
            (canvas.height / 2 - rect.height / 2, canvas.height / 2),
            (canvas.height - rect.height, canvas.height)
        ]
        if let other {
            xTargets.append((other.minX, other.minX))
            xTargets.append((other.midX - rect.width / 2, other.midX))
            xTargets.append((other.maxX - rect.width, other.maxX))
            yTargets.append((other.minY, other.minY))
            yTargets.append((other.midY - rect.height / 2, other.midY))
            yTargets.append((other.maxY - rect.height, other.maxY))
        }

        var bestX = threshold
        for target in xTargets {
            let distance = abs(rect.minX - target.origin)
            if distance <= bestX {
                bestX = distance
                originX = target.origin
                guidesX = [target.guide]
            }
        }
        var bestY = threshold
        for target in yTargets {
            let distance = abs(rect.minY - target.origin)
            if distance <= bestY {
                bestY = distance
                originY = target.origin
                guidesY = [target.guide]
            }
        }
        return Result(rect: CGRect(x: originX, y: originY,
                                   width: rect.width, height: rect.height),
                      guidesX: guidesX, guidesY: guidesY)
    }
}
