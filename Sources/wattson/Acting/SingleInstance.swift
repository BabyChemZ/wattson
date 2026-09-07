import Foundation

/// Guarantees one engine per machine.
///
/// The login agent was launching the CLI while the app ran its own engine, so
/// two processes sampled independently, each kept its own idea of when the user
/// was away, and both wrote the same files — producing away sessions that
/// recorded nothing and, with interventions enabled, two watchdogs acting on
/// the same processes without knowing about each other.
enum SingleInstance {
    /// Written once, from whichever thread starts the engine first.
    nonisolated(unsafe) private static var lockDescriptor: Int32 = -1

    /// Take the lock, or report that someone else holds it. The descriptor is
    /// deliberately never closed: the lock lives as long as the process.
    static func acquire() -> Bool {
        guard lockDescriptor < 0 else { return true }
        try? FileManager.default.createDirectory(at: Config.directory,
                                                 withIntermediateDirectories: true)
        let path = Config.directory.appendingPathComponent("engine.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }

        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            close(descriptor)
            return false
        }
        lockDescriptor = descriptor
        return true
    }
}
