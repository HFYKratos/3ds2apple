//
//  MetalScreenView.swift
//  3ds2apple
//
//  Presentation of the 3DS screens on a CAMetalLayer (A1).
//
//  Zakuro's Vulkan presenter shows the upper (3D) and lower (2D) screens by
//  drawing a swapchain image into a CAMetalLayer the app owns. On iOS the
//  Vulkan implementation is MoltenVK over Metal, so this view is also what the
//  system Metal Performance HUD (FPS / GPU / memory) can attach to; with the
//  pre-A1 `CGImage` path there is no Metal layer and that HUD never appeared.
//
//  The view's layer must be the CAMetalLayer itself: `raw-window-metal` (used
//  by Zakuro's presenter through `ash-window`) takes `[view layer]` and only
//  uses it when it already is a CAMetalLayer; otherwise it adds a sublayer of
//  its own, whose size nothing would keep in step with the screen.
//
//  The drawable is the chosen screen arrangement at the 3DS resolutions (see
//  ScreenGeometry.swift), not the iPhone's native pixel size: the presenter
//  renders at 400x480 for the stacked console, 720x240 side by side, or the
//  whole arrangement turned a quarter turn, and CoreAnimation scales that image
//  to the view's box. Rendering at the device resolution would make the GPU do
//  ~8x the work for no visible benefit; the Settings render resolution can raise
//  the drawable to one to four times the arrangement's pixels.
//
//  Drawable sizing (the CAMetalLayer drawableSize fix): CAMetalLayer.drawableSize
//  is not an independent property. Apple documents its default value as the
//  layer's bounds size multiplied by its contentsScale factor, and Core Animation
//  rewrites it whenever it lays the layer out (including every frame of a bounds
//  animation). The presenter needs the arrangement's own pixel size no matter
//  how SwiftUI sizes the picture box, so this view is *not* sized by SwiftUI:
//  MetalScreenContainerView gives it deliberately chosen bounds and scales it
//  with a transform. `bounds * contentsScale` therefore always equals the
//  presenter's drawable, so Core Animation has nothing to rewrite: no drawable
//  size resets, no swapchain rebuilds while a layout animates, and the picture
//  keeps the arrangement's pixels instead of being re-sampled from the view's
//  point size.
//
//  Threading: `UIView` objects are main-thread only, so the view, and the
//  presenter created from it, are created/resized on the main queue. The
//  presenter's per-frame `zk_present()` calls run on the runtime serial queue.
//

import QuartzCore
import SwiftUI
import UIKit

/// A `UIView` whose backing layer is a `CAMetalLayer`, sized for the presenter
/// that draws the 3DS screens into it.
///
/// The view is placed and scaled by `MetalScreenContainerView`, never by
/// SwiftUI. For a fixed screen arrangement its bounds are the drawable size in
/// points with `contentsScale` 1; for the custom full-stage layout its bounds
/// are the container's points with `contentsScale` equal to the screen scale.
/// Both cases keep `bounds * contentsScale` equal to what the presenter expects,
/// which is the invariant CAMetalLayer itself maintains.
final class MetalScreenView: UIView {
    /// The screen arrangement at the 3DS resolutions, in pixels, before the
    /// render scale: 400x480 for the stacked console, 720x240 side by side,
    /// 400x240 or 320x240 for a single screen, swapped by a quarter turn. Main
    /// queue only; changed through `setPresentedGeometry`.
    private var nativePixelSize = CGSize(width: 400, height: 480)

    /// 1 = the arrangement's own pixels ... 4 = four times them. Main queue
    /// only.
    private var renderScale: CGFloat = 1

    /// Round 0.1.6 custom GPU layouts: the drawable is the whole game-view stage
    /// at the display's native pixel size instead of a fixed arrangement. Main
    /// queue only; changed through `setCustomFill`.
    private var customFill = false

    /// Whole-console-pixel scaling: the layer is magnified with nearest-pixel
    /// filtering so each 3DS pixel stays a square block instead of a blurred
    /// edge. Main queue only; changed through `setPresentedGeometry`.
    private var integerScaling = false

    /// Drawable size in pixels the presenter must render at.
    var drawablePixelSize: CGSize {
        CGSize(width: nativePixelSize.width * renderScale,
               height: nativePixelSize.height * renderScale)
    }

    /// The CAMetalLayer's drawable size as Core Animation currently reports it.
    /// Diagnostics only (main queue): it must equal `drawablePixelSize` (fixed
    /// arrangement) or the custom layout's stage pixels.
    var actualDrawableSize: CGSize { metalLayer.drawableSize }

    /// How many times Core Animation rewrote `drawableSize` and the value had to
    /// be re-asserted. A correct container layout leaves this at 0; a growing
    /// count means the bounds x contentsScale invariant is broken again.
    private(set) var drawableSizeCorrections = 0

    /// Called on the main queue after layout when the drawable size in pixels
    /// changes, so the runtime can resize its swapchain to match.
    var onDrawableSizeChanged: ((CGSize) -> Void)?

    /// Last reported drawable size, to avoid resize calls on every layout pass.
    private var reportedDrawableSize = CGSize.zero

    override class var layerClass: AnyClass { CAMetalLayer.self }

    /// The view's layer, already a `CAMetalLayer`.
    var metalLayer: CAMetalLayer {
        // `layerClass` guarantees the type.
        guard let metalLayer = layer as? CAMetalLayer else {
            preconditionFailure("MetalScreenView's layer must be a CAMetalLayer")
        }
        return metalLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        // Black behind the presented image (letterboxing, first frame).
        isOpaque = true
        backgroundColor = .black
        isUserInteractionEnabled = true
        contentScaleFactor = 1.0
        metalLayer.contentsScale = 1.0
        metalLayer.isOpaque = true
        // The presenter only renders into the drawable; reading it back as a
        // texture is not needed.
        metalLayer.framebufferOnly = true
        // Presentation path, stated explicitly (0.1.2): MoltenVK already makes a
        // three-image swapchain for this layer (the device log says "Created 3
        // swapchain images", the iOS default of three drawables), so the
        // emulated GPU's command walk gets one more frame of headroom before a
        // present has to wait for CoreAnimation. Keep the transaction-less
        // present path: `presentsWithTransaction = false` lets a present land
        // without waiting for the next commit. Nothing here is written per
        // frame, and `drawableSize` is only set when the layout or the render
        // scale changes (see `publishDrawableSize`), so the frame loop does no
        // CAMetalLayer property work.
        metalLayer.maximumDrawableCount = 3
        metalLayer.presentsWithTransaction = false
        // The container transforms the layer into the picture box; the drawable
        // itself is never resized to the box, so this gravity is only a safe
        // default when the layer's own aspect and its bounds differ by rounding.
        metalLayer.contentsGravity = .resize
        applyPictureFilters()
    }

    // MARK: - Sizing from the container

    /// Gives the layer a drawable size before the view is in the window
    /// hierarchy, so the presenter can make its surface and first swapchain
    /// while the ROM loads. The container keeps the layer's bounds at this size;
    /// SwiftUI only ever sizes the container. Main queue only.
    func prepareForPresentation() {
        let displayScale = window?.screen.scale ?? UIScreen.main.scale
        let scale = desiredContentsScale(displayScale: displayScale)
        if metalLayer.contentsScale != scale {
            metalLayer.contentsScale = scale
        }
        // The presenter reads the layer while it makes its surface: give it the
        // new geometry's drawable size directly. The container re-applies the
        // same size on its next layout pass (this view is reused across loads and
        // the layout preset or the render scale may have changed meanwhile).
        let points = desiredLayerPoints()
        let target = CGSize(width: max(points.width, 1), height: max(points.height, 1))
        if customFill {
            nativePixelSize = CGSize(width: target.width * scale,
                                     height: target.height * scale)
            renderScale = 1
        }
        if bounds.size != target {
            bounds = CGRect(origin: .zero, size: target)
        }
        syncDrawableSize()
        publishDrawableSize(force: true)
    }

    /// Lays the layer out inside the container that SwiftUI sized: the layer gets
    /// its presenter-sized bounds, the container animates its transform, and the
    /// drawable never follows the picture box. Main queue only.
    func layoutInContainer(_ containerBounds: CGRect, displayScale: CGFloat) {
        guard containerBounds.width >= 1, containerBounds.height >= 1 else { return }
        let scale = desiredContentsScale(displayScale: displayScale)
        var points: CGSize
        if customFill {
            // The custom layout draws into the whole stage at native device
            // pixels: container points x contentsScale is exactly that size.
            nativePixelSize = CGSize(width: containerBounds.width * scale,
                                     height: containerBounds.height * scale)
            renderScale = 1
            points = containerBounds.size
        } else {
            // A fixed arrangement: the layer's own bounds are the drawable in
            // pixels (contentsScale 1), whatever the picture box is.
            points = drawablePixelSize
        }
        let target = CGSize(width: max(points.width, 1), height: max(points.height, 1))
        if bounds.size != target {
            bounds = CGRect(origin: .zero, size: target)
        }
        if metalLayer.contentsScale != scale {
            metalLayer.contentsScale = scale
        }
        contentScaleFactor = scale
        // CoreAnimation scales the layer into the container. For a fixed
        // arrangement this is the old contentsGravity .resize behaviour, now
        // expressed as a transform so the layer's own bounds never change while
        // SwiftUI animates the picture box (rotation, keyboard, transitions).
        transform = CGAffineTransform(
            scaleX: containerBounds.width / target.width,
            y: containerBounds.height / target.height
        )
        center = CGPoint(x: containerBounds.midX, y: containerBounds.midY)
        syncDrawableSize()
        publishDrawableSize(force: false)
    }

    /// Switches between a fixed presenter arrangement (false) and the custom GPU
    /// layout's full-stage fill (true). Main queue only.
    func setCustomFill(_ enabled: Bool) {
        if enabled {
            customFill = true
            renderScale = 1
            integerScaling = false
            applyPictureFilters()
            let displayScale = window?.screen.scale ?? UIScreen.main.scale
            let stage = superview?.bounds.size ?? UIScreen.main.bounds.size
            nativePixelSize = CGSize(width: max(stage.width * displayScale, 1),
                                     height: max(stage.height * displayScale, 1))
            updateContainerLayout()
            publishDrawableSize(force: true)
        } else {
            customFill = false
        }
    }

    /// Sets the arrangement the presenter draws and the layer holds: the native
    /// pixel size comes from `ScreenGeometry`, `renderScale` is 1 through 4 and
    /// `integerScaling` selects nearest-pixel magnification. The drawable size
    /// change reaches the runtime through `onDrawableSizeChanged`, which resizes
    /// the swapchain to match. Main queue only.
    func setPresentedGeometry(
        nativePixelSize: CGSize,
        renderScale: CGFloat,
        integerScaling: Bool
    ) {
        let factor = min(max(renderScale.rounded(), 1), 4)
        // A fixed arrangement leaves the custom full-stage mode.
        customFill = false
        let size = CGSize(
            width: max(nativePixelSize.width, 1),
            height: max(nativePixelSize.height, 1)
        )
        guard size != self.nativePixelSize
                || factor != self.renderScale
                || integerScaling != self.integerScaling else {
            return
        }
        self.nativePixelSize = size
        self.renderScale = factor
        self.integerScaling = integerScaling
        applyPictureFilters()
        updateContainerLayout()
        publishDrawableSize(force: true)
    }

    /// Nearest-pixel magnification for integer scaling, smooth filtering
    /// otherwise.
    private func applyPictureFilters() {
        metalLayer.magnificationFilter = integerScaling ? .nearest : .linear
        metalLayer.minificationFilter = .linear
    }

    /// Shows or hides the system Metal Performance HUD for this layer.
    ///
    /// `CAMetalLayer.developerHUDProperties` is the documented runtime switch
    /// (iOS 16+): `mode` takes "default" / "main" to show the HUD and
    /// "disabled" to hide it. The build must also enable the HUD, through
    /// `MetalHudEnabled` in Info.plist (the packaged test IPAs do) or
    /// Settings -> Developer -> Graphics HUD on the device; otherwise there is
    /// nothing to show. Main queue only.
    func applySystemMetalHUD(enabled: Bool) {
        // The variable has to be in the environment before Metal creates the
        // device (App.init does that); the layer property below is the part
        // that can be flipped without a relaunch. Documented keys for iOS 16+:
        // "mode" is "default" / "main" to show the HUD, "disabled" to hide it.
        MetalHUD.apply(enabled: enabled)
        var properties = metalLayer.developerHUDProperties ?? [AnyHashable: Any]()
        properties[AnyHashable("mode")] = enabled ? "default" : "disabled"
        metalLayer.developerHUDProperties = properties
        AppLog.log("[3ds2apple] metal hud layer: %@ (%@)",
                   enabled ? "on" : "off", MetalHUD.diagnosticsLine)
    }

    // MARK: - Drawable bookkeeping

    /// The layer's bounds in points for the current mode, before the container
    /// is known (the load-time presenter creation reads the layer directly).
    private func desiredLayerPoints() -> CGSize {
        if customFill {
            let stage = superview?.bounds.size ?? UIScreen.main.bounds.size
            return CGSize(width: max(stage.width, 1), height: max(stage.height, 1))
        }
        return drawablePixelSize
    }

    /// 1 for a fixed arrangement (bounds are pixels); the screen scale for the
    /// custom full-stage layout (bounds are points, the drawable is native pixels).
    private func desiredContentsScale(displayScale: CGFloat) -> CGFloat {
        customFill ? max(displayScale, 1) : 1
    }

    /// The drawable size the presenter expects for the current bounds and scale.
    private var desiredDrawableSize: CGSize {
        CGSize(width: (bounds.width * metalLayer.contentsScale).rounded(),
               height: (bounds.height * metalLayer.contentsScale).rounded())
    }

    /// Re-asserts the drawable size if Core Animation rewrote it and counts the
    /// correction (diagnostics; a correct layout never needs this).
    private func syncDrawableSize() {
        let expected = desiredDrawableSize
        guard expected.width >= 1, expected.height >= 1 else { return }
        let found = metalLayer.drawableSize
        guard found != expected else { return }
        metalLayer.drawableSize = expected
        drawableSizeCorrections += 1
        if drawableSizeCorrections == 1 {
            AppLog.log(
                "[3ds2apple] CAMetalLayer drawableSize was rewritten to %@ (expected %@); re-asserting the presenter size",
                "\(Int(found.width))x\(Int(found.height))",
                "\(Int(expected.width))x\(Int(expected.height))"
            )
        }
    }

    /// Hands a changed drawable size to the session so it can resize the
    /// presenter's swapchain. Main queue only.
    private func publishDrawableSize(force: Bool) {
        let pixels = desiredDrawableSize
        guard pixels.width >= 1, pixels.height >= 1 else { return }
        if metalLayer.drawableSize != pixels {
            metalLayer.drawableSize = pixels
        }
        guard force || pixels != reportedDrawableSize else { return }
        reportedDrawableSize = pixels
        onDrawableSizeChanged?(pixels)
    }

    /// Re-runs the container layout immediately after a geometry change, so the
    /// layer, transform and presenter size all change together. Main queue only.
    private func updateContainerLayout() {
        guard let container = superview else { return }
        container.setNeedsLayout()
        container.layoutIfNeeded()
    }

    // MARK: - UIView layout

    override func layoutSubviews() {
        super.layoutSubviews()
        // Core Animation re-derives drawableSize from bounds * contentsScale; the
        // container keeps both equal to the presenter size, so this is only a
        // safety net and a diagnostic hook.
        syncDrawableSize()
        publishDrawableSize(force: false)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateContainerLayout()
        syncDrawableSize()
        publishDrawableSize(force: false)
    }
}

/// The view SwiftUI actually lays out. It only carries the long-lived
/// `MetalScreenView`: the container takes the picture-box size SwiftUI gives it
/// and lays the Metal layer out at its presenter size with a transform, so the
/// CAMetalLayer drawable never follows the animated picture box.
final class MetalScreenContainerView: UIView {
    let metalView: MetalScreenView

    init(metalView: MetalScreenView) {
        self.metalView = metalView
        super.init(frame: .zero)
        backgroundColor = .black
        isOpaque = true
        if metalView.superview !== self {
            metalView.removeFromSuperview()
        }
        addSubview(metalView)
    }

    required init?(coder: NSCoder) {
        fatalError("MetalScreenContainerView is created by MetalScreenRepresentable")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let displayScale = window?.screen.scale ?? UIScreen.main.scale
        metalView.layoutInContainer(bounds, displayScale: displayScale)
    }
}

/// Bridges `MetalScreenView` into SwiftUI. The session owns the Metal view (and
/// the presenter drawing into it) for the app's lifetime; the representable
/// creates the container that sizes it, which is why it returns a pre-made
/// view.
struct MetalScreenRepresentable: UIViewRepresentable {
    let view: MetalScreenView

    func makeUIView(context: Context) -> MetalScreenContainerView {
        // Re-inserting the same representable reuses the container that already
        // holds the long-lived Metal view.
        if let container = view.superview as? MetalScreenContainerView {
            return container
        }
        return MetalScreenContainerView(metalView: view)
    }

    func updateUIView(_ uiView: MetalScreenContainerView, context: Context) {
        uiView.setNeedsLayout()
    }
}
