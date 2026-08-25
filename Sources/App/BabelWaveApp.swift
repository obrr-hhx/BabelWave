import AppKit
import SwiftUI

@main
struct BabelWaveApp: App {
    @NSApplicationDelegateAdaptor(BabelWaveAppDelegate.self) private var appDelegate
    @StateObject private var model = BabelWaveModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(model)
        } label: {
            HStack(spacing: 3) {
                Image(nsImage: BabelWaveBrand.menuBarIcon)
                if model.isCapturing {
                    Circle()
                        .fill(.primary)
                        .frame(width: 4, height: 4)
                }
            }
                .accessibilityLabel(model.isCapturing ? "BabelWave is listening" : "BabelWave")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class BabelWaveAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = BabelWaveBrand.logo
        BabelWaveModel.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        BabelWaveModel.shared.shutdown()
    }
}

private struct MenuBarPanel: View {
    @EnvironmentObject private var model: BabelWaveModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: BabelWaveBrand.logo)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 25, height: 25)
                VStack(alignment: .leading, spacing: 1) {
                    Text("BabelWave")
                        .font(.headline)
                    Text(model.serviceStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Circle()
                    .fill(model.isCapturing ? Color.green : Color.secondary.opacity(0.45))
                    .frame(width: 7, height: 7)
            }

            Button {
                model.toggleCapture()
            } label: {
                Label(
                    model.isCapturing ? "Stop System Audio" : "Start System Audio",
                    systemImage: model.isCapturing ? "stop.fill" : "waveform"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.captureAvailable)

            VStack(alignment: .leading, spacing: 7) {
                StatusRow(title: "Recognition", value: model.modelStatus)
                StatusRow(title: "Translation", value: model.translationStatus)
                HStack(alignment: .center, spacing: 10) {
                    Text("Source Language")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("Source Language", selection: $model.recognitionLanguage) {
                        ForEach(RecognitionLanguage.allCases) { language in
                            Text(language.rawValue).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                .font(.caption)
            }

            HStack(spacing: 8) {
                Toggle("Debug Transcript Log", isOn: $model.debugLoggingEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Locally logs ASR text and raw model output. Off by default.")
                Spacer()
                if model.debugLoggingEnabled {
                    Button("Reveal") { model.revealDebugLog() }
                        .buttonStyle(.borderless)
                }
            }
            .font(.caption)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Subtitle Window")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button(model.isOverlayVisible ? "Hide" : "Show") {
                        model.toggleOverlay()
                    }
                    .buttonStyle(.borderless)
                }

                HStack(spacing: 8) {
                    Button {
                        model.toggleOverlayLock()
                    } label: {
                        Label(model.isOverlayLocked ? "Unlock" : "Lock",
                              systemImage: model.isOverlayLocked ? "pin.fill" : "pin.slash")
                    }

                    Spacer()

                    Button { model.decreaseFontSize() } label: {
                        Image(systemName: "textformat.size.smaller")
                    }
                    .help("Decrease subtitle text")

                    Button { model.increaseFontSize() } label: {
                        Image(systemName: "textformat.size.larger")
                    }
                    .help("Increase subtitle text")

                    Button { model.resetOverlayPosition() } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .help("Reset subtitle position")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Label("Background Transparency", systemImage: "circle.lefthalf.filled")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(model.backgroundTransparency, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $model.backgroundTransparency, in: 0.20...0.90)
                        .controlSize(.small)
                        .accessibilityLabel("Subtitle background transparency")
                }
            }

            if !model.lastTranscript.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.lastTranscript)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Button("Copy Last Transcript") {
                        model.copyLastTranscript()
                    }
                    .buttonStyle(.borderless)
                }
            }

            Divider()

            HStack {
                Text("Local models only")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
                    .buttonStyle(.borderless)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

private enum BabelWaveBrand {
    static let logo: NSImage = loadImage(
        named: "BabelWaveLogo",
        extension: "png",
        template: false,
        size: nil
    )
    static let menuBarIcon: NSImage = loadImage(
        named: "MenuBarIconTemplate",
        extension: "pdf",
        template: true,
        size: NSSize(width: 18, height: 18)
    )

    private static func loadImage(
        named name: String,
        extension fileExtension: String,
        template: Bool,
        size: NSSize?
    ) -> NSImage {
        let image = Bundle.main.url(forResource: name, withExtension: fileExtension)
            .flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "BabelWave")!
        image.isTemplate = template
        if let size {
            image.size = size
        }
        return image
    }
}

private struct StatusRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
    }
}
