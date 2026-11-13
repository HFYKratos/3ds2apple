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
//  20x the work for no visible benefit; the Settings render resolution can raise
//  the drawable to one to four times the arrangement's pixels.
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
final class MetalScreenView: UIView {
    /// The screen arrangement at the 3DS resolutions, in pixels, before the
    /// render scale: 400x480 for the stacked console, 720x240 side by side,
    /// 400x240 or 320x240 for a single screen, swapped by a quarter turn. Main
    /// queue only; changed through `setPresentedGeometry`.
    private var nativePixelSize = CGSize(width: 400, height: 480)

    /// 1 = the arrangement's own pixels ... 4 = four times them. Main queue
    /// only.
    private var renderScale: CGFloat = 1

    /// Whole-console-pixel scaling: the layer is magnified with nearest-pixel
    /// filtering so each 3DS pixel stays a square block instead of a blurred
    /// edge. Main queue only; changed through `setPresentedGeometry`.
    private var integerScaling = false

    /// Drawable size in pixels the presenter must render at.
    var drawablePixelSize: CGSize {
        CGSize(width: nativePixelSize.width * renderScale,
               height: nativePixelSize.height * renderScale)
    }

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
        // CoreAnimation stretches the drawable into the view's box: the box has
        // the picture's own shape for fit/4:3 (so this is a uniform scale) and
        // the whole available space in stretch mode (deliberate distortion).
        metalLayer.contentsGravity = .resize
        applyPictureFilters()
    }

    /// Gives the layer a drawable size before the view is in the window
    /// hierarchy, so the presenter can make its surface and first swapchain
    /// while the ROM loads. SwiftUI replaces the view's frame with the laid-out
    /// one; the drawable stays the arrangement's own pixels, so this only needs
    /// to run once. Main queue only.
    func prepareForPresentation() {
        if bounds.width < 1 || bounds.height < 1 {
            bounds = CGRect(origin: .zero, size: drawablePixelSize)
        }
        updateDrawableSize(force: true)
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
        updateDrawableSize(force: true)
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
    /// Settings → Developer → Graphics HUD on the device; otherwise there is
    /// nothing to show. Main queue only. `developerHUDProperties` is an iOS 16
    /// API, exactly the deployment target, so no availability check is needed.
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

    override func layoutSubviews() {
        super.layoutSubviews()
        updateScaleFromWindow()
        updateDrawableSize(force: false)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateScaleFromWindow()
        updateDrawableSize(force: false)
    }

    /// Keeps `contentsScale` and `drawableSize` in step with the window's screen
    /// (the presenter derives its swapchain extent from `drawableSize`).
    private func updateScaleFromWindow() {
        // The drawable is fixed at the arrangement's pixels; CoreAnimation
        // scales it to the view. Keep the layer's own scale at 1 so the
        // presenter's swapchain extent never follows the iPhone's native pixels.
        contentScaleFactor = 1.0
        if metalLayer.contentsScale != 1.0 {
            metalLayer.contentsScale = 1.0
        }
    }

    private func updateDrawableSize(force: Bool) {
        let pixels = drawablePixelSize
        // MoltenVK sets this again when it (re)builds the swapchain, and reads
        // it to pick the surface extent. Setting it here before the resize call
        // is what makes a layout/rotation/render-scale change take effect.
        if metalLayer.drawableSize != pixels {
            metalLayer.drawableSize = pixels
        }
        guard force || pixels != reportedDrawableSize else { return }
        reportedDrawableSize = pixels
        onDrawableSizeChanged?(pixels)
    }
}

/// Bridges `MetalScreenView` into SwiftUI. The session owns the view (and the
/// presenter drawing into it) for the app's lifetime; this representable only
/// places it in the layout, which is why it returns a pre-made view.
struct MetalScreenRepresentable: UIViewRepresentable {
    let view: MetalScreenView

    func makeUIView(context: Context) -> MetalScreenView {
        view
    }

    func updateUIView(_ uiView: MetalScreenView, context: Context) {}
}
