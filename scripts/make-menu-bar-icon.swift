#!/usr/bin/env swift

import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-menu-bar-icon.swift OUTPUT.pdf\n".utf8))
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
var mediaBox = CGRect(x: 0, y: 0, width: 18, height: 18)

guard let consumer = CGDataConsumer(url: outputURL),
      let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
    FileHandle.standardError.write(Data("could not create menu bar PDF\n".utf8))
    exit(1)
}

func wavePath() -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 8, y: 46))
    path.addCurve(to: CGPoint(x: 20, y: 33), control1: CGPoint(x: 8, y: 38), control2: CGPoint(x: 13, y: 33))
    path.addCurve(to: CGPoint(x: 33, y: 37), control1: CGPoint(x: 25, y: 33), control2: CGPoint(x: 28, y: 37))
    path.addCurve(to: CGPoint(x: 46, y: 22), control1: CGPoint(x: 39, y: 37), control2: CGPoint(x: 41, y: 29))
    path.addCurve(to: CGPoint(x: 66, y: 12), control1: CGPoint(x: 51, y: 14), control2: CGPoint(x: 58, y: 10))
    path.addCurve(to: CGPoint(x: 82, y: 29), control1: CGPoint(x: 74, y: 14), control2: CGPoint(x: 78, y: 22))
    path.addCurve(to: CGPoint(x: 94, y: 35), control1: CGPoint(x: 85, y: 34), control2: CGPoint(x: 89, y: 36))
    path.addCurve(to: CGPoint(x: 80, y: 45), control1: CGPoint(x: 91, y: 41), control2: CGPoint(x: 86, y: 45))
    path.addCurve(to: CGPoint(x: 64, y: 35), control1: CGPoint(x: 72, y: 45), control2: CGPoint(x: 68, y: 39))
    path.addCurve(to: CGPoint(x: 52, y: 31), control1: CGPoint(x: 60, y: 31), control2: CGPoint(x: 56, y: 29))
    path.addCurve(to: CGPoint(x: 43, y: 48), control1: CGPoint(x: 46, y: 34), control2: CGPoint(x: 43, y: 41))
    path.addCurve(to: CGPoint(x: 51, y: 62), control1: CGPoint(x: 43, y: 54), control2: CGPoint(x: 46, y: 59))
    path.addCurve(to: CGPoint(x: 35, y: 61), control1: CGPoint(x: 46, y: 65), control2: CGPoint(x: 40, y: 65))
    path.addCurve(to: CGPoint(x: 24, y: 58), control1: CGPoint(x: 30, y: 57), control2: CGPoint(x: 28, y: 55))
    path.addCurve(to: CGPoint(x: 10, y: 55), control1: CGPoint(x: 19, y: 62), control2: CGPoint(x: 13, y: 60))
    path.addCurve(to: CGPoint(x: 8, y: 46), control1: CGPoint(x: 8, y: 52), control2: CGPoint(x: 7, y: 49))
    path.closeSubpath()
    return path
}

context.beginPDFPage(nil)
context.translateBy(x: 0, y: 18)
context.scaleBy(x: 0.18, y: -0.18)
context.setFillColor(CGColor(gray: 0, alpha: 1))
context.addPath(wavePath())
context.fillPath()

context.saveGState()
context.translateBy(x: 100, y: 100)
context.rotate(by: .pi)
context.addPath(wavePath())
context.fillPath()
context.restoreGState()

context.endPDFPage()
context.closePDF()
