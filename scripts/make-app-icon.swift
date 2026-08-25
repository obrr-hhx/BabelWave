#!/usr/bin/env swift

import AppKit
import Foundation

private struct IconRepresentation {
    let type: String
    let pixels: Int
}

private let representations = [
    IconRepresentation(type: "icp4", pixels: 16),
    IconRepresentation(type: "icp5", pixels: 32),
    IconRepresentation(type: "icp6", pixels: 64),
    IconRepresentation(type: "ic07", pixels: 128),
    IconRepresentation(type: "ic08", pixels: 256),
    IconRepresentation(type: "ic09", pixels: 512),
    IconRepresentation(type: "ic10", pixels: 1024),
]

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-app-icon.swift INPUT.png OUTPUT.icns\n".utf8))
    exit(2)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let source = NSImage(contentsOf: inputURL) else {
    FileHandle.standardError.write(Data("could not read \(inputURL.path)\n".utf8))
    exit(1)
}

func pngData(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    source.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero,
        operation: .copy,
        fraction: 1
    )
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

func bigEndian(_ value: UInt32) -> Data {
    var value = value.bigEndian
    return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
}

var chunks = Data()
for representation in representations {
    let png = try pngData(pixels: representation.pixels)
    chunks.append(Data(representation.type.utf8))
    chunks.append(bigEndian(UInt32(png.count + 8)))
    chunks.append(png)
}

var icns = Data("icns".utf8)
icns.append(bigEndian(UInt32(chunks.count + 8)))
icns.append(chunks)
try icns.write(to: outputURL, options: .atomic)
