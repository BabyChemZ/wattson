import Foundation

/// Installs the watchdog as a per-user launchd agent.
///
/// A user agent, not a root daemon, on purpose: everything the tool reads and
/// every action it takes works on your own processes without elevation, so
/// asking for root would buy nothing and cost the user's trust.
enum Install {
    static let label = "com.wattson.agent"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func install() {
        let binary = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().path
        let logs = Config.directory.path

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binary)</string>
                <string>watch</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>ProcessType</key><string>Background</string>
            <key>StandardOutPath</key><string>\(logs)/agent.out.log</string>
            <key>StandardErrorPath</key><string>\(logs)/agent.err.log</string>
        </dict>
        </plist>
        """

        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: Config.directory, withIntermediateDirectories: true)
            try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        } catch {
            print("could not write \(plistURL.path): \(error.localizedDescription)")
            return
        }

        let domain = "gui/\(getuid())"
        // Replace any previous registration; bootout on a missing label is
        // harmless and keeps reinstalls idempotent.
        Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"], timeout: 10)
        guard Shell.run("/bin/launchctl",
                        ["bootstrap", domain, plistURL.path], timeout: 10) != nil else {
            print("launchctl bootstrap failed — plist written to \(plistURL.path)")
            return
        }

        print("""
        installed. wattson now starts at login and keeps running in the background.

          logs      \(Config.directory.path)/wattson.log
          config    \(Config.path.path)

        It is in observe-only mode: for the next while it will learn what each
        program on this machine normally does, and report what it *would* have
        done without touching anything. Check in with `wattson status` in a day
        or two, and set "dryRun": false when the verdicts look right to you.
        """)
    }

    static func uninstall() {
        Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"], timeout: 10)
        try? FileManager.default.removeItem(at: plistURL)
        print("uninstalled. learned baselines are kept at \(Config.directory.path)")
    }
}
