//
//  ScreenImage.swift
//  3ds2apple
//
//  I2-T2: turns a Zakuro RGBA8 screen buffer into a CGImage that SwiftUI can
//  display. Zakuro returns tightly packed RGBA8, row-major, top-left origin
//  (see ios/ZakuroBridge.h: zk_read_screen).
//
//  I3-T6: per-frame allocations removed. Instead of a fresh 384 KB / 307 KB
//  `Data` per screen per frame, pixel memory comes from a small reusable pool.
//  A buffer is handed to CoreGraphics through a CGDataProvider whose release
//  callback returns it to the pool, so a buffer is never written again while
//  an image still references it (no tearing, no use-after-free).
//

import CoreFoundation
import CoreGraphics
import Foundation

/// One reusable, tightly packed RGBA8 pixel buffer.
///
/// The memory is owned by this object (not by the pool) and stays valid for as
/// long as any CGImage built from it is alive: the provider's release box
/// retains the buffer and only hands it back to the pool on deinit.
final class ScreenFrameBuffer {
    let width: Int
    let height: Int
    let byteCount: Int

    private let storage: UnsafeMutableRawPointer

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.byteCount = width * height * 4
        // 64-byte alignment: one cache line; harmless for CGImage consumers.
        storage = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
    }

    deinit {
        storage.deallocate()
    }

    /// Base address for `zk_read_screen` and for the CGDataProvider.
    var address: UnsafeMutablePointer<UInt8> {
        storage.assumingMemoryBound(to: UInt8.self)
    }
}

/// Recycles RGBA8 screen buffers between frames.
///
/// `acquire` runs on the runtime serial queue; `recycle` runs on whichever
/// thread releases the last CGImage reference (normally the main thread), so
/// the free list is lock-protected. Buffers are per geometry (400x240,
/// 320x240) and capped: if the presentation layer still holds every buffer the
/// pool handed out, `acquire` returns nil and the caller falls back to a
/// transient allocation instead of growing memory without bound.
final class ScreenFrameBufferPool {
    private struct Geometry: Hashable {
        let width: Int
        let height: Int
    }

    /// Two buffers per screen cover the steady state (one being filled while
    /// the previous image is still on screen); the third absorbs a retained
    /// image. Beyond that we stop growing.
    private static let maximumBuffersPerGeometry = 3

    private let lock = NSLock()
    private var available: [Geometry: [ScreenFrameBuffer]] = [:]
    private var allocated: [Geometry: Int] = [:]

    /// Returns a free buffer, or a new one while the per-geometry cap allows.
    /// runtime serial queue only (the free-list itself is also locked).
    func acquire(width: Int, height: Int) -> ScreenFrameBuffer? {
        guard width > 0, height > 0 else { return nil }
        let geometry = Geometry(width: width, height: height)

        lock.lock()
        if var buffers = available[geometry], let buffer = buffers.popLast() {
            available[geometry] = buffers
            lock.unlock()
            return buffer
        }
        let count = allocated[geometry] ?? 0
        guard count < Self.maximumBuffersPerGeometry else {
            lock.unlock()
            return nil
        }
        allocated[geometry] = count + 1
        lock.unlock()

        // Allocate outside the lock: zeroing 300-400 KB must not stall the
        // audio thread if it happens to release an image at the same time.
        return ScreenFrameBuffer(width: width, height: height)
    }

    /// Returns a buffer to the free list. Safe from any thread.
    func recycle(_ buffer: ScreenFrameBuffer) {
        let geometry = Geometry(width: buffer.width, height: buffer.height)
        lock.lock()
        available[geometry, default: []].append(buffer)
        lock.unlock()
    }
}

/// Holds a `ScreenFrameBuffer` and returns it to the pool when the
/// CGDataProvider (and therefore the CGImage) is released.
private final class ScreenBufferProviderInfo {
    private let buffer: ScreenFrameBuffer
    private weak var pool: ScreenFrameBufferPool?

    init(buffer: ScreenFrameBuffer, pool: ScreenFrameBufferPool) {
        self.buffer = buffer
        self.pool = pool
    }

    deinit {
        pool?.recycle(buffer)
    }
}

enum ScreenImage {
    /// Device RGB, created once: CGColorSpace creation is expensive in a loop.
    private static let colorSpace = CGColorSpaceCreateDeviceRGB()

    /// Builds an image from `width * height * 4` bytes of RGBA8 pixels.
    ///
    /// Fallback path used only when the buffer pool has no buffer left (e.g.
    /// the presentation layer temporarily retains several old images); costs
    /// one allocation per frame, which is what pre-I3-T6 always did.
    static func makeImage(rgba pixels: Data, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        guard pixels.count >= bytesPerRow * height else { return nil }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return makeImage(provider: provider, width: width, height: height)
    }

    /// Builds an image that borrows `buffer` without copying it. The buffer is
    /// returned to `pool` when the image (and its provider) is released.
    ///
    /// On failure the buffer is already recycled (`CGDataProvider` creation
    /// failed) or is released with the provider (CGImage creation failed), so
    /// the caller must not recycle it again.
    static func makeImage(buffer: ScreenFrameBuffer,
                          pool: ScreenFrameBufferPool) -> CGImage? {
        let infoPointer = Unmanaged.passRetained(
            ScreenBufferProviderInfo(buffer: buffer, pool: pool)
        ).toOpaque()

        guard let provider = CGDataProvider(
            dataInfo: infoPointer,
            data: UnsafePointer(buffer.address),
            size: buffer.byteCount,
            releaseData: { info, _, _ in
                guard let info else { return }
                Unmanaged<ScreenBufferProviderInfo>.fromOpaque(info).release()
            }
        ) else {
            // The release callback is not called when creation fails.
            Unmanaged<ScreenBufferProviderInfo>.fromOpaque(infoPointer).release()
            return nil
        }

        return makeImage(provider: provider, width: buffer.width, height: buffer.height)
    }

    /// Shared CGImage construction: Zakuro frames are opaque RGBA8.
    private static func makeImage(provider: CGDataProvider,
                                  width: Int,
                                  height: Int) -> CGImage? {
        let bytesPerRow = width * 4
        // RGBA (alpha last). Zakuro's frames are opaque, so premultiplied and
        // straight alpha are equivalent here; premultiplied is the faster path.
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
