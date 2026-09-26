// Run: swift scripts/render-app-icon.swift
// Uses the same native heart.fill symbol and semibold weight as LaunchScreen.storyboard.
import AppKit
let application = NSApplication.shared

let size = 1024
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
NSColor(srgbRed: 1, green: 238.0/255, blue: 207.0/255, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()
let configuration = NSImage.SymbolConfiguration(pointSize: 640, weight: .semibold)
    .applying(.init(paletteColors: [NSColor(srgbRed: 219.0/255, green: 80.0/255, blue: 74.0/255, alpha: 1)]))
let heart = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)!.withSymbolConfiguration(configuration)!
let width: CGFloat = 700
let height = width * heart.size.height / heart.size.width
heart.draw(in: NSRect(x: (1024-width)/2, y: (1024-height)/2, width: width, height: height))
NSGraphicsContext.restoreGraphicsState()
let output = URL(fileURLWithPath: "SpeechSessionApp/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
