import Foundation

public enum AppPaths {
    public static var isTestEnvironment: Bool {
        ProcessInfo.processInfo.environment["CALLCAPTION_TEST"] == "1"
    }

    public static var testRoot: URL? {
        guard isTestEnvironment,
              let path = ProcessInfo.processInfo.environment["CALLCAPTION_TEST_DIR"],
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    public static var applicationSupportDirectory: URL {
        if let testRoot {
            return testRoot.appendingPathComponent("Application Support", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("CallCaption", isDirectory: true)
    }

    public static var transcriptsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Transcripts", isDirectory: true)
    }

    public static var autosaveFileURL: URL {
        transcriptsDirectory.appendingPathComponent("latest_session.json")
    }

    public static var sshKnownHostsURL: URL {
        applicationSupportDirectory.appendingPathComponent("ssh_known_hosts")
    }

    public static func ensureDirectory(_ url: URL, permissions: Int = 0o700) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path
        )
    }

    public static func writePrivateData(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }
}
