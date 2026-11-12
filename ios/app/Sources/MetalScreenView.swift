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
    /// Native pixel size of the two 3DS screens side by side: 400x240 (upper)
    /// above 320x240 (lower) is 400x480. The presenter renders at this size and
    /// Metal/CoreAnimation scales it to the view; rendering at the iPhone's
    /// native drawable size (e.g. 2226x2671) makes the GPU do 20x the work for
    /// no visible benefit. The Settings page can raise the factor to 2 for a
    /// sharper 800x960 presentation on fast devices.
    private static let consolePixelSize = CGSize(width: 400, height: 480)

    /// 1 = native 400x480 drawable, 2 = 800x960. Main queue only.
    private var renderScale: CGFloat = 1.0

    /// Drawable size in pixels the presenter must render at.
    var drawablePixelSize: CGSize {
        CGSize(width: Self.consolePixelSize.width * renderScale,
               height: Self.consolePixelSize.height * renderScale)
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
    }

    /// Gives the layer a drawable size before the view is in the window
    /// hierarchy, so the presenter can make its surface and first swapchain
    /// while the ROM loads. `provisionalSize` is in pixels (the same units the
    /// presenter takes); SwiftUI replaces the view's frame with the laid-out
    /// one and `onDrawableSizeChanged` then resizes the swapchain.
    /// Main queue only.
    func prepareForPresentation(provisionalSize: CGSize) {
        if bounds.width < 1 || bounds.height < 1 {
            bounds = CGRect(origin: .zero, size: Self.consolePixelSize)
        }
        updateDrawableSize(force: true)
    }

    /// Changes the resolution the presenter renders at: 1 = native 400x480,
    /// 2 = 800x960. The layer's drawable size and the runtime's swapchain follow
    /// through `onDrawableSizeChanged`. Main queue only.
    func setRenderScale(_ scale: CGFloat) {
        let factor: CGFloat = scale >= 2 ? 2 : 1
        guard factor != renderScale else { return }
        renderScale = factor
        updateDrawableSize(force: true)
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
        // The drawable is fixed at the 3DS resolution; CoreAnimation scales it
        // to the view. Keep the layer's own scale at 1 so the presenter's
        // swapchain extent never follows the iPhone's native pixels.
        contentScaleFactor = 1.0
        if metalLayer.contentsScale != 1.0 {
            metalLayer.contentsScale = 1.0
        }
    }

    private func updateDrawableSize(force: Bool) {
        let pixels = drawablePixelSize
        // MoltenVK sets this again when it (re)builds the swapchain, and reads
        // it to pick the surface extent. Setting it here before the resize call
        // is what makes a rotation/new layout take effect.
        if metalLayer.drawableSize != pixels {
            metalLayer.drawableSize = pixels
        }
        guard force || pixels != reportedDrawableSize else { return }
        reportedDrawableSize = pixels
        onDrawableSizeChanged?(pixels)
    }

    /// Points-to-pixels scale: the window's screen once the view is attached,
    /// the trait collection (the device's scale) before that. Main queue only,
    /// like all `UIView` access.
    private func currentDisplayScale() -> CGFloat {
        if let scale = window?.screen.nativeScale, scale > 0 {
            return scale
        }
        let traitScale = traitCollection.displayScale
        if traitScale > 0 {
            return traitScale
        }
        if contentScaleFactor > 0 {
            return contentScaleFactor
        }
        return 2.0
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
