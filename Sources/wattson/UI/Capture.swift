import SwiftUI
import AppKit

/// Drives the running application through every page so the documentation can
/// be captured from real windows.
///
/// The offscreen renderer this exists alongside builds its images from a view
/// tree that was never attached to a window, with invented data. Both parts
/// matter: those images cannot show that the window has stopped accepting
/// clicks — which happened, and survived for days precisely because the
/// screenshots looked correct — and they show numbers no machine ever
/// produced. Here the engine is running, the readings are this machine's, and
/// the capture is of the window the window server actually composited.
///
/// Guarded by an environment variable, so it costs a single `environment`
/// lookup at launch in ordinary use.
@MainActor
enum CaptureDriver {
    private static var timer: Timer?
    private static var lastInstruction = ""

    struct Instruction: Decodable {
        var page: String
        var appearance: String?
        var language: String?
    }

    static func startIfRequested(model: AppModel) {
        guard let path = ProcessInfo.processInfo
                .environment["WATTSON_CAPTURE_CONTROL"] else { return }

        model.openMainWindow()
        // Polling a file rather than taking a command line argument: restarting
        // the app for each of twenty-six images would mean waiting for the
        // engine to collect real readings twenty-six times over.
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            Task { @MainActor in apply(from: path, to: model) }
        }
    }

    private static func apply(from path: String, to model: AppModel) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              text != lastInstruction,
              let data = text.data(using: .utf8),
              let instruction = try? JSONDecoder().decode(Instruction.self, from: data)
        else { return }
        lastInstruction = text

        if let language = instruction.language {
            activeLanguage = language == "zh" ? .chinese : .english
        }
        if let appearance = instruction.appearance {
            NSApp.appearance = NSAppearance(
                named: appearance == "light" ? .aqua : .darkAqua)
        }
        if let page = Page(rawValue: instruction.page) {
            model.page = page
        }
        model.objectWillChange.send()
    }
}
