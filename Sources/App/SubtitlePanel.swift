import AppKit
import SwiftUI

@MainActor
final class SubtitlePanelController: NSObject, NSWindowDelegate {
    private weak var model: BabelWaveModel?
    private var panel: NSPanel!
    private var pendingFrameSave: DispatchWorkItem?
    private static let frameKey = "BabelWaveSubtitleFrameSwiftUI"

    init(model: BabelWaveModel) {
        self.model = model
        super.init()

        let initialFrame = NSRect(x: 0, y: 0, width: 820, height: 168)
        panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .utilityWindow
        panel.preservesContentDuringLiveResize = true
        panel.minSize = NSSize(width: 480, height: 150)
        panel.maxSize = NSSize(width: 1_500, height: 440)
        panel.contentMinSize = NSSize(width: 480, height: 150)
        panel.contentMaxSize = NSSize(width: 1_500, height: 440)
        panel.title = "BabelWave Subtitles"

        let root = SubtitleOverlay(model: model)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = initialFrame
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 24
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        hosting.layerContentsRedrawPolicy = .duringViewResize
        panel.contentView = hosting

        restoreFrame()
        setInteractionLocked(model.isOverlayLocked)
    }

    func show() {
        panel.orderFrontRegardless()
        model?.isOverlayVisible = true
    }

    func hide() {
        panel.orderOut(nil)
        model?.isOverlayVisible = false
    }

    func resetPosition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let width = min(max(visible.width * 0.58, 680), 980)
        let height: CGFloat = 168
        let frame = NSRect(
            x: visible.midX - width / 2,
            y: visible.minY + visible.height * 0.105,
            width: width,
            height: height
        )
        panel.setFrame(frame, display: true)
        saveFrame()
    }

    func setInteractionLocked(_ locked: Bool) {
        guard panel != nil else { return }
        // Moving and resizing use separate explicit event surfaces. Never let
        // NSPanel interpret a resize drag as a background move.
        panel.isMovableByWindowBackground = false
    }

    private func restoreFrame() {
        guard let encoded = UserDefaults.standard.string(forKey: Self.frameKey) else {
            resetPosition()
            return
        }
        let frame = NSRectFromString(encoded)
        guard frame.width >= 480, frame.height >= 150 else {
            resetPosition()
            return
        }
        panel.setFrame(frame, display: false)
    }

    private func saveFrame() {
        pendingFrameSave?.cancel()
        pendingFrameSave = nil
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
    }

    private func scheduleFrameSave() {
        pendingFrameSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveFrame() }
        pendingFrameSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20, execute: work)
    }

    func windowDidMove(_ notification: Notification) { scheduleFrameSave() }
    func windowDidResize(_ notification: Notification) { scheduleFrameSave() }
}

private struct SubtitleOverlay: View {
    @ObservedObject var model: BabelWaveModel

    var body: some View {
        ZStack {
            GlassMaterial(opacity: 1 - model.backgroundTransparency)

            AdaptiveBilingualText(
                source: model.sourceText,
                translation: model.translationText,
                preferredScale: model.fontScale
            )
            .padding(.horizontal, 38)
            .padding(.top, 47)
            .padding(.bottom, 17)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack {
                HStack(alignment: .top) {
                    Spacer()
                    OverlayToolbar(model: model)
                }
                Spacer()
            }
            .padding(.top, 10)
            .padding(.trailing, 14)

            VStack {
                ZStack {
                    Capsule()
                        .fill(.tertiary)
                        .frame(width: 64, height: 4)
                        .opacity(model.isOverlayLocked ? 0.28 : 0.72)
                        .allowsHitTesting(false)

                    WindowMoveSurface(enabled: !model.isOverlayLocked)
                }
                .frame(width: 112, height: 28)
                .help(model.isOverlayLocked ? "Unlock to move" : "Drag subtitle window")
                Spacer()
            }
            .padding(.top, 7)

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    ZStack {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .opacity(model.isOverlayLocked ? 0.22 : 0.72)
                            .allowsHitTesting(false)
                    }
                    .frame(width: 44, height: 44)
                    .help(model.isOverlayLocked ? "Unlock to resize" : "Resize subtitle window")
                }
            }

            ResizeHitRegions(enabled: !model.isOverlayLocked)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.separator.opacity(model.isOverlayLocked ? 0.42 : 0.72), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct AdaptiveBilingualText: NSViewRepresentable {
    let source: String
    let translation: String
    let preferredScale: Double

    func makeNSView(context: Context) -> BilingualTextView {
        BilingualTextView()
    }

    func updateNSView(_ view: BilingualTextView, context: Context) {
        view.update(source: source, translation: translation, preferredScale: preferredScale)
    }
}

private final class BilingualTextView: NSView {
    private var sourceText = ""
    private var translationText = ""
    private var preferredScale: CGFloat = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func update(source: String, translation: String, preferredScale: Double) {
        sourceText = source
        translationText = translation
        self.preferredScale = CGFloat(preferredScale)
        setAccessibilityValue("\(source) \(translation)")
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 1, bounds.height > 1 else { return }

        let fitScale = largestFittingScale()
        let sourceFont = NSFont.systemFont(ofSize: 17 * preferredScale * fitScale, weight: .regular)
        let translationFont = NSFont.systemFont(ofSize: 28 * preferredScale * fitScale, weight: .medium)
        let gap = max(1, 5 * fitScale)
        let sourceHeight = measuredHeight(sourceText, font: sourceFont)
        let translationHeight = measuredHeight(translationText, font: translationFont)
        let totalHeight = sourceHeight + gap + translationHeight
        let top = max(0, (bounds.height - totalHeight) / 2)

        let drawingOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        (sourceText as NSString).draw(
            with: NSRect(x: 0, y: top, width: bounds.width, height: sourceHeight),
            options: drawingOptions,
            attributes: attributes(text: sourceText, font: sourceFont, color: .secondaryLabelColor)
        )
        (translationText as NSString).draw(
            with: NSRect(
                x: 0,
                y: top + sourceHeight + gap,
                width: bounds.width,
                height: translationHeight
            ),
            options: drawingOptions,
            attributes: attributes(text: translationText, font: translationFont, color: .labelColor)
        )
    }

    private func largestFittingScale() -> CGFloat {
        func fits(_ scale: CGFloat) -> Bool {
            let sourceFont = NSFont.systemFont(ofSize: 17 * preferredScale * scale, weight: .regular)
            let translationFont = NSFont.systemFont(ofSize: 28 * preferredScale * scale, weight: .medium)
            let height = measuredHeight(sourceText, font: sourceFont)
                + max(1, 5 * scale)
                + measuredHeight(translationText, font: translationFont)
            return height <= bounds.height
        }

        if fits(1) { return 1 }
        var low: CGFloat = 0.08
        var high: CGFloat = 1
        for _ in 0..<12 {
            let middle = (low + high) / 2
            if fits(middle) {
                low = middle
            } else {
                high = middle
            }
        }
        return low
    }

    private func measuredHeight(_ text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: bounds.width, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes(text: text, font: font, color: .labelColor)
        )
        return ceil(rect.height) + 1
    }

    private func attributes(
        text: String,
        font: NSFont,
        color: NSColor
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = wrappingMode(for: text)
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    private func wrappingMode(for text: String) -> NSLineBreakMode {
        // AppKit word wrapping can treat a long CJK clause as one word and
        // clip its tail. Character wrapping is the natural behavior for CJK;
        // Latin text keeps word wrapping for readability.
        text.unicodeScalars.contains { $0.value > 0x7f }
            ? .byCharWrapping
            : .byWordWrapping
    }
}

private struct OverlayToolbar: View {
    @ObservedObject var model: BabelWaveModel

    var body: some View {
        HStack(spacing: 0) {
            OverlayIconButton(
                symbol: model.isOverlayLocked ? "pin.fill" : "pin.slash",
                help: model.isOverlayLocked ? "Unlock subtitle window" : "Lock subtitle window"
            ) { model.toggleOverlayLock() }

            Divider().frame(height: 14)

            OverlayIconButton(symbol: "minus", help: "Decrease subtitle text") {
                model.decreaseFontSize()
            }
            OverlayIconButton(symbol: "plus", help: "Increase subtitle text") {
                model.increaseFontSize()
            }

            Divider().frame(height: 14)

            OverlayIconButton(symbol: "xmark", help: "Close subtitle window", danger: true) {
                model.hideOverlay()
            }
        }
        .padding(3)
        .background(.thinMaterial, in: Capsule())
        .overlay {
            Capsule().stroke(.separator.opacity(0.45), lineWidth: 0.5)
        }
    }
}

private struct OverlayIconButton: View {
    let symbol: String
    let help: String
    var danger = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
                .foregroundStyle(danger && hovering ? Color.white : Color.primary.opacity(0.78))
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(danger && hovering
                              ? Color.red.opacity(0.88)
                              : Color.primary.opacity(hovering ? 0.10 : 0))
                }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct GlassMaterial: NSViewRepresentable {
    let opacity: Double

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 24
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.alphaValue = min(max(opacity, 0.10), 0.80)
    }
}

private struct ResizeEdges: OptionSet {
    let rawValue: Int

    static let left = ResizeEdges(rawValue: 1 << 0)
    static let right = ResizeEdges(rawValue: 1 << 1)
    static let top = ResizeEdges(rawValue: 1 << 2)
    static let bottom = ResizeEdges(rawValue: 1 << 3)
}

private struct WindowMoveSurface: NSViewRepresentable {
    let enabled: Bool

    func makeNSView(context: Context) -> WindowMoveView {
        let view = WindowMoveView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.handle)
        view.setAccessibilityLabel("Move subtitle window")
        return view
    }

    func updateNSView(_ view: WindowMoveView, context: Context) {
        view.enabled = enabled
    }
}

private final class WindowMoveView: NSView {
    var enabled = true {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    private var initialOrigin = NSPoint.zero
    private var initialPointerScreen = NSPoint.zero
    private var lastAppliedEventTime: TimeInterval = 0

    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: enabled ? .openHand : .arrow)
    }

    override func mouseDown(with event: NSEvent) {
        guard enabled, let window else { return }
        initialOrigin = window.frame.origin
        initialPointerScreen = window.convertPoint(toScreen: event.locationInWindow)
        lastAppliedEventTime = event.timestamp - (1.0 / 60.0)
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        updateWindowOrigin(with: event, force: false)
    }

    override func mouseUp(with event: NSEvent) {
        updateWindowOrigin(with: event, force: true)
        (enabled ? NSCursor.openHand : NSCursor.arrow).set()
    }

    private func updateWindowOrigin(with event: NSEvent, force: Bool) {
        guard enabled, let window else { return }
        let pointerScreen = window.convertPoint(toScreen: event.locationInWindow)
        let scale = max(window.backingScaleFactor, 1)
        func aligned(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let origin = NSPoint(
            x: aligned(initialOrigin.x + pointerScreen.x - initialPointerScreen.x),
            y: aligned(initialOrigin.y + pointerScreen.y - initialPointerScreen.y)
        )
        guard origin != window.frame.origin else { return }
        guard force || event.timestamp - lastAppliedEventTime >= 1.0 / 60.0 else { return }
        lastAppliedEventTime = event.timestamp
        window.setFrameOrigin(origin)
    }
}

private struct ResizeHitRegions: View {
    let enabled: Bool

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                WindowResizeSurface(enabled: enabled, edges: [.top])
                    .frame(height: 7)
                Spacer(minLength: 0)
                WindowResizeSurface(enabled: enabled, edges: [.bottom])
                    .frame(height: 7)
            }

            HStack(spacing: 0) {
                WindowResizeSurface(enabled: enabled, edges: [.left])
                    .frame(width: 7)
                Spacer(minLength: 0)
                WindowResizeSurface(enabled: enabled, edges: [.right])
                    .frame(width: 7)
            }

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    WindowResizeSurface(enabled: enabled, edges: [.top, .left])
                        .frame(width: 12, height: 12)
                    Spacer(minLength: 0)
                    WindowResizeSurface(enabled: enabled, edges: [.top, .right])
                        .frame(width: 12, height: 12)
                }
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: 0) {
                    WindowResizeSurface(enabled: enabled, edges: [.bottom, .left])
                        .frame(width: 20, height: 20)
                    Spacer(minLength: 0)
                    WindowResizeSurface(enabled: enabled, edges: [.bottom, .right])
                        .frame(width: 44, height: 44)
                }
            }
        }
        .allowsHitTesting(enabled)
    }
}

private struct WindowResizeSurface: NSViewRepresentable {
    let enabled: Bool
    let edges: ResizeEdges

    func makeNSView(context: Context) -> WindowResizeView {
        let view = WindowResizeView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.handle)
        view.setAccessibilityLabel("Resize subtitle window")
        return view
    }

    func updateNSView(_ view: WindowResizeView, context: Context) {
        view.enabled = enabled
        view.edges = edges
    }
}

private final class WindowResizeView: NSView {
    var enabled = true {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    var edges: ResizeEdges = [] {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    private var initialFrame = NSRect.zero
    private var initialPointerScreen = NSPoint.zero
    private var lastAppliedEventTime: TimeInterval = 0

    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        let horizontal = edges.contains(.left) || edges.contains(.right)
        let vertical = edges.contains(.top) || edges.contains(.bottom)
        let cursor: NSCursor
        if !enabled {
            cursor = .arrow
        } else if horizontal && vertical {
            cursor = .crosshair
        } else if vertical {
            cursor = .resizeUpDown
        } else {
            cursor = .resizeLeftRight
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        guard enabled, let window else { return }
        initialFrame = window.frame
        initialPointerScreen = window.convertPoint(toScreen: event.locationInWindow)
        lastAppliedEventTime = event.timestamp - (1.0 / 60.0)
    }

    override func mouseDragged(with event: NSEvent) {
        updateWindowFrame(with: event, force: false)
    }

    override func mouseUp(with event: NSEvent) {
        updateWindowFrame(with: event, force: true)
    }

    private func updateWindowFrame(with event: NSEvent, force: Bool) {
        guard enabled, let window else { return }
        let pointerScreen = window.convertPoint(toScreen: event.locationInWindow)
        let delta = CGSize(
            width: pointerScreen.x - initialPointerScreen.x,
            height: pointerScreen.y - initialPointerScreen.y
        )
        var frame = initialFrame

        if edges.contains(.left) {
            let width = min(max(initialFrame.width - delta.width, 480), 1_500)
            frame.origin.x = initialFrame.maxX - width
            frame.size.width = width
        } else if edges.contains(.right) {
            frame.size.width = min(max(initialFrame.width + delta.width, 480), 1_500)
        }

        if edges.contains(.bottom) {
            let height = min(max(initialFrame.height - delta.height, 150), 440)
            frame.origin.y = initialFrame.maxY - height
            frame.size.height = height
        } else if edges.contains(.top) {
            frame.size.height = min(max(initialFrame.height + delta.height, 150), 440)
        }

        let alignedFrame = alignedToBackingPixels(frame, in: window)
        guard alignedFrame != window.frame else { return }
        guard force || event.timestamp - lastAppliedEventTime >= 1.0 / 60.0 else { return }
        lastAppliedEventTime = event.timestamp
        window.setFrame(alignedFrame, display: true, animate: false)
    }

    private func alignedToBackingPixels(_ frame: NSRect, in window: NSWindow) -> NSRect {
        let scale = max(window.backingScaleFactor, 1)
        func aligned(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded() / scale
        }
        return NSRect(
            x: aligned(frame.origin.x),
            y: aligned(frame.origin.y),
            width: aligned(frame.width),
            height: aligned(frame.height)
        )
    }
}
