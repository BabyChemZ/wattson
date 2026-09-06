import Foundation

/// Delivers incident reports. Every channel is optional and failures are
/// swallowed: a watchdog that dies because a webhook was unreachable is worse
/// than one that quietly keeps watching.
struct Notifier {
    var config: Config

    func send(title: String, body: String) {
        if config.localNotifications { sendLocal(title: title, body: body) }
        if let topic = config.ntfyTopicURL { sendNtfy(topic, title: title, body: body) }
        if let hook = config.wecomWebhookURL { sendWeCom(hook, title: title, body: body) }
    }

    private func sendLocal(title: String, body: String) {
        // AppleScript string literals need quotes and backslashes escaped, or a
        // process name containing either would break the script.
        func escaped(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let script = "display notification \"\(escaped(body))\" with title \"\(escaped(title))\""
        Shell.run("/usr/bin/osascript", ["-e", script], timeout: 10)
    }

    private func sendNtfy(_ topic: String, title: String, body: String) {
        guard let url = URL(string: topic) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // ntfy takes the title from a header and the body as the raw payload.
        request.setValue(title, forHTTPHeaderField: "Title")
        request.httpBody = body.data(using: .utf8)
        post(request)
    }

    private func sendWeCom(_ webhook: String, title: String, body: String) {
        guard let url = URL(string: webhook) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "msgtype": "markdown",
            "markdown": ["content": "**\(title)**\n\(body)"],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        post(request)
    }

    /// Fire and wait briefly. The daemon loop is synchronous, and a hung network
    /// call must not stall the next sample.
    private func post(_ request: URLRequest) {
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 10)
    }
}
