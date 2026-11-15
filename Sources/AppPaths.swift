import Foundation
import Darwin

public enum AppPaths {
    public static let isTestEnvironment: Bool = {
        ProcessInfo.processInfo.environment["CALLCAPTION_TEST"] == "1"
    }()

    public static let testRoot: URL? = {
        guard isTestEnvironment,
              let path = ProcessInfo.processInfo.environment["CALLCAPTION_TEST_DIR"],
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }()

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
        let standardizedURL = url.standardizedFileURL
        let appSupportURL = applicationSupportDirectory.standardizedFileURL
        if standardizedURL != appSupportURL,
           standardizedURL.path.hasPrefix(appSupportURL.path + "/") {
            try ensureDirectory(appSupportURL, permissions: 0o700)
        }

        var st = Darwin.stat()
        if Darwin.lstat(standardizedURL.path, &st) == 0 {
            let fileType = st.st_mode & S_IFMT
            if fileType == S_IFLNK {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(ELOOP),
                    userInfo: [NSLocalizedDescriptionKey: "Refusing symlink directory at \(standardizedURL.path)"]
                )
            }
            if fileType == S_IFDIR {
                if (Int(st.st_mode) & 0o777) == permissions {
                    return
                }
                let fd = Darwin.open(standardizedURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                if fd >= 0 {
                    defer { Darwin.close(fd) }
                    if Darwin.fchmod(fd, mode_t(permissions)) == 0 {
                        return
                    }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
                }
            }
        }

        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: permissions)]
        )
        let fd = Darwin.open(standardizedURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
        }
        defer { Darwin.close(fd) }
        guard Darwin.fchmod(fd, mode_t(permissions)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
        }
    }

    public static func writePrivateData(_ data: Data, to url: URL) throws {
        let parentURL = url.deletingLastPathComponent().standardizedFileURL
        var st = Darwin.stat()
        let needsEnsure: Bool
        if Darwin.lstat(parentURL.path, &st) == 0 {
            let fileType = st.st_mode & S_IFMT
            needsEnsure = (fileType != S_IFDIR) || ((Int(st.st_mode) & 0o777) != 0o700)
        } else {
            needsEnsure = true
        }
        if needsEnsure {
            try ensureDirectory(parentURL, permissions: 0o700)
        }

        let tempURL = parentURL.appendingPathComponent(".\(url.lastPathComponent).tmp.\(UUID().uuidString)")
        let fd = Darwin.open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        if fd < 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var fdOpen = true
        var moved = false
        defer {
            if fdOpen {
                _ = Darwin.close(fd)
            }
            if !moved {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        _ = Darwin.fchmod(fd, mode_t(0o600))

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress, !rawBuffer.isEmpty else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(fd, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                offset += written
            }
        }

        fdOpen = false
        if Darwin.close(fd) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        if Darwin.rename(tempURL.path, url.path) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        moved = true
    }
}
