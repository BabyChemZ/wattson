import Foundation
import AppKit
import Darwin

/// Turns `top`'s process names into the names Activity Monitor shows.
///
/// `top` reports the executable, truncated to fifteen characters — "2.1.259",
/// "SkyComputerUseCl", "com.apple.WebKit". Those identify a process but tell a
/// person nothing. The readable name lives elsewhere: in the running
/// application for anything with a UI, and otherwise in the bundle that owns
/// the executable.
///
/// The raw name is still what baselines are keyed on. Renaming those would
/// orphan everything learned so far, so this only ever affects display.
enum ProcessNaming {
    private static let cache = NameCache()

    static func displayName(pid: Int32, fallback: String) -> String {
        cache.name(pid: pid, fallback: fallback)
    }

    /// Resolve once per process; the answer cannot change while it lives.
    fileprivate static func resolve(pid: Int32, fallback: String) -> String {
        // A GUI application knows its own display name, localised.
        if let app = NSRunningApplication(processIdentifier: pid),
           let name = app.localizedName, !name.isEmpty {
            return name
        }

        guard let path = executablePath(pid: pid) else { return fallback }

        // Helpers live inside a bundle: .../Foo.app/Contents/.../Foo Helper.
        // Name them for the app they belong to, keeping the helper's own role
        // so several helpers of one app stay distinguishable.
        let url = URL(fileURLWithPath: path)
        let executable = url.lastPathComponent
        if let bundle = enclosingAppName(for: url), bundle != executable {
            let role = helperRole(executable: executable, bundle: bundle)
            return role.isEmpty ? bundle : "\(bundle) \(role)"
        }
        return executable.isEmpty ? fallback : executable
    }

    private static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) },
                      as: UTF8.self)
    }

    /// The nearest enclosing .app, if the executable is inside one.
    private static func enclosingAppName(for url: URL) -> String? {
        var current = url
        while current.pathComponents.count > 1 {
            current = current.deletingLastPathComponent()
            if current.pathExtension == "app" {
                return current.deletingPathExtension().lastPathComponent
            }
        }
        return nil
    }

    /// "Google Chrome Helper (Renderer)" -> "Helper (Renderer)".
    private static func helperRole(executable: String, bundle: String) -> String {
        guard executable.hasPrefix(bundle) else { return executable }
        return String(executable.dropFirst(bundle.count))
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Resolution costs a syscall and a bundle lookup, so results are kept for the
/// life of the process.
private final class NameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [Int32: String] = [:]

    func name(pid: Int32, fallback: String) -> String {
        lock.lock()
        if let cached = names[pid] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = ProcessNaming.resolve(pid: pid, fallback: fallback)

        lock.lock()
        // PIDs are reused; a cache that only grows would eventually answer for
        // the wrong process.
        if names.count > 600 { names.removeAll(keepingCapacity: true) }
        names[pid] = resolved
        lock.unlock()
        return resolved
    }
}
