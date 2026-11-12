//
//  ScreenImage.swift
//  3ds2apple
//
//  I2-T2: turns a Zakuro RGBA8 screen buffer into a CGImage that SwiftUI can
//  display. Zakuro returns tightly packed RGBA8, row-major, top-left origin
//  (see ios/ZakuroBridge.h: zk_read_screen).
//

import CoreFoundation
import CoreGraphics
import Foundation

enum ScreenImage {
    /// Device RGB, created once: CGColorSpace creation is expensive in a loop.
    private static let colorSpace = CGColorSpaceCreateDeviceRGB()

    /// Builds an image from `width * height * 4` bytes of RGBA8 pixels.
    static func makeImage(rgba pixels: Data, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        guard pixels.count >= bytesPerRow * height else { return nil }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }

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
