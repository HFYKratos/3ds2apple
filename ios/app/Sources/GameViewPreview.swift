//
//  GameViewPreview.swift
//  3ds2apple
//
//  Synthetic screen images for the ROM-free game-view preview
//  (`-previewGameView`, see DebugLaunch.swift and ios/app/README.md).
//
//  The images are the console's own screen sizes (upper 400x240, lower 320x240),
//  drawn with a gradient, a 1 px grid and a clear TOP / BOTTOM label, so a
//  headless screenshot proves which screen landed where in every screen layout
//  preset. They are built once and used only by the preview launch: the normal
//  game path always shows the runtime's frames.
//

import CoreGraphics
import Foundation
import UIKit

enum DebugPreviewScreens {
    /// The upper-screen test image (400x240), built once.
    static let upper: CGImage? = makeImage(
        width: 400,
        height: 240,
        label: "TOP 400×240",
        start: UIColor(red: 0.10, green: 0.36, blue: 0.62, alpha: 1.0),
        end: UIColor(red: 0.03, green: 0.09, blue: 0.20, alpha: 1.0)
    )

    /// The lower-screen test image (320x240), built once.
    static let lower: CGImage? = makeImage(
        width: 320,
        height: 240,
        label: "BOTTOM 320×240",
        start: UIColor(red: 0.48, green: 0.20, blue: 0.56, alpha: 1.0),
        end: UIColor(red: 0.13, green: 0.05, blue: 0.21, alpha: 1.0)
    )

    private static func makeImage(width: Int,
                                  height: Int,
                                  label: String,
                                  start: UIColor,
                                  end: UIColor) -> CGImage? {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            let cg = context.cgContext
            let colors = [start.cgColor, end.cgColor] as CFArray
            let locations: [CGFloat] = [0, 1]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors,
                                         locations: locations) {
                cg.drawLinearGradient(gradient,
                                      start: .zero,
                                      end: CGPoint(x: size.width, y: size.height),
                                      options: [])
            }
            // 1 px grid: visible at every layout scale and on every display.
            cg.setStrokeColor(UIColor.white.withAlphaComponent(0.20).cgColor)
            cg.setLineWidth(1)
            let step: CGFloat = 20
            var x: CGFloat = 0
            while x <= size.width {
                cg.move(to: CGPoint(x: x + 0.5, y: 0))
                cg.addLine(to: CGPoint(x: x + 0.5, y: size.height))
                x += step
            }
            var y: CGFloat = 0
            while y <= size.height {
                cg.move(to: CGPoint(x: 0, y: y + 0.5))
                cg.addLine(to: CGPoint(x: size.width, y: y + 0.5))
                y += step
            }
            cg.strokePath()
            // A clear label so a screenshot proves which screen is which.
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 26, weight: .bold),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]
            let text = label as NSString
            let textSize = text.size(withAttributes: attributes)
            let textRect = CGRect(x: 0,
                                  y: (size.height - textSize.height) / 2,
                                  width: size.width,
                                  height: textSize.height)
            text.draw(in: textRect, withAttributes: attributes)
        }
        return image.cgImage
    }
}
