import Foundation
import AppKit

public protocol TunnelManagerDelegate: AnyObject {
    func tunnelDidUpdateURL(_ url: String)
    func tunnelDidFail(error: String)
}

public class TunnelManager {
    public static let shared = TunnelManager()
    public static let tunnelURLNotification = Notification.Name("CallCaptionTunnelDidUpdateURL")
    
    public weak var delegate: TunnelManagerDelegate?
    public private(set) var publicURL: String?
    public private(set) var isRunning: Bool = false
    
    private var tunnelProcess: Process?
    private var outPipe: Pipe?
    private var errPipe: Pipe?
    private let queue = DispatchQueue(label: "com.callcaption.tunnel", qos: .utility)
    private var currentPort: UInt16 = 8765
    
    private init() {}
    
    public func start(localPort: UInt16 = 8765) {
        if isRunning { return }
        isRunning = true
        self.currentPort = localPort
        
        queue.async { [weak self] in
            self?.runTunnel(localPort: localPort)
        }
    }
    
    public func stop() {
        isRunning = false
        publicURL = nil
        tunnelProcess?.terminate()
        tunnelProcess = nil
        outPipe?.fileHandleForReading.readabilityHandler = nil
        errPipe?.fileHandleForReading.readabilityHandler = nil
        outPipe = nil
        errPipe = nil
    }
    
    /// Finds or creates a valid ed25519 SSH key to authenticate tunnel connections without password prompts.
    private func resolveSSHKeyPath() -> String {
        let fileManager = FileManager.default
        
        // 1. Check in Bundle Resources
        if let bundleKey = Bundle.main.path(forResource: "tunnel_key", ofType: nil),
           fileManager.fileExists(atPath: bundleKey) {
            fixKeyPermissions(bundleKey)
            return bundleKey
        }
        
        // 2. Check in working directory Resources/tunnel_key
        let relativeProjectKey = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/tunnel_key").path
        if fileManager.fileExists(atPath: relativeProjectKey) {
            fixKeyPermissions(relativeProjectKey)
            return relativeProjectKey
        }
        
        // 3. Fallback to Application Support / CallCaption / tunnel_key
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CallCaption")
        try? fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let fallbackKey = appSupport.appendingPathComponent("tunnel_key").path
        
        if !fileManager.fileExists(atPath: fallbackKey) {
            NSLog("[TunnelManager] Generating dedicated tunnel SSH key at \(fallbackKey)...")
            let genProc = Process()
            genProc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            genProc.arguments = ["-t", "ed25519", "-N", "", "-f", fallbackKey, "-q"]
            try? genProc.run()
            genProc.waitUntilExit()
        }
        
        fixKeyPermissions(fallbackKey)
        return fallbackKey
    }
    
    private func fixKeyPermissions(_ path: String) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
    
    private func runTunnel(localPort: UInt16) {
        let keyPath = resolveSSHKeyPath()
        NSLog("[TunnelManager] Starting primary tunnel via localhost.run with key: \(keyPath)")
        
        // Try localhost.run first (stable zero-config HTTPS tunnel)
        startSSHTunnel(
            command: "/usr/bin/ssh",
            arguments: [
                "-T",
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "ServerAliveInterval=20",
                "-o", "ServerAliveCountMax=3",
                "-i", keyPath,
                "-R", "80:localhost:\(localPort)",
                "nokey@localhost.run"
            ],
            isFallback: false
        )
    }
    
    private func startPinggyFallback(localPort: UInt16) {
        let keyPath = resolveSSHKeyPath()
        NSLog("[TunnelManager] Attempting fallback tunnel via pinggy.io with key: \(keyPath)")
        
        startSSHTunnel(
            command: "/usr/bin/ssh",
            arguments: [
                "-T",
                "-p", "443",
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "ServerAliveInterval=20",
                "-o", "ServerAliveCountMax=3",
                "-i", keyPath,
                "-R0:localhost:\(localPort)",
                "a.pinggy.io"
            ],
            isFallback: true
        )
    }
    
    private func startSSHTunnel(command: String, arguments: [String], isFallback: Bool) {
        tunnelProcess?.terminate()
        tunnelProcess = nil
        outPipe?.fileHandleForReading.readabilityHandler = nil
        errPipe?.fileHandleForReading.readabilityHandler = nil
        outPipe = nil
        errPipe = nil
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        
        let outP = Pipe()
        let errP = Pipe()
        process.standardOutput = outP
        process.standardError = errP
        
        self.tunnelProcess = process
        self.outPipe = outP
        self.errPipe = errP
        
        outP.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            NSLog("[TunnelManager] SSH STDOUT: \(output)")
            self?.parseTunnelOutput(output)
        }
        
        errP.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            NSLog("[TunnelManager] SSH STDERR: \(output)")
            self?.parseTunnelOutput(output)
        }
        
        process.terminationHandler = { [weak self] proc in
            NSLog("[TunnelManager] Tunnel terminated with code: \(proc.terminationStatus)")
            guard let self = self, self.isRunning else { return }
            
            if !isFallback && self.publicURL == nil {
                // If localhost.run closed without discovering URL, fall back to pinggy immediately
                self.queue.asyncAfter(deadline: .now() + 1.0) {
                    if self.isRunning && self.publicURL == nil {
                        self.startPinggyFallback(localPort: self.currentPort)
                    }
                }
            } else if isFallback && self.publicURL == nil {
                DispatchQueue.main.async {
                    self.delegate?.tunnelDidFail(error: "Tunnel service unreachable. Using local Wi-Fi link.")
                }
            }
        }
        
        do {
            try process.run()
            NSLog("[TunnelManager] SSH tunnel started: \(arguments.joined(separator: " "))")
        } catch {
            NSLog("[TunnelManager] Failed to start SSH process: \(error)")
            if !isFallback {
                startPinggyFallback(localPort: self.currentPort)
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.tunnelDidFail(error: error.localizedDescription)
                }
            }
        }
    }
    
    private func parseTunnelOutput(_ text: String) {
        // Match HTTPS URLs generated by localhost.run, pinggy, trycloudflare, or localtunnel
        let patterns = [
            "https://[a-zA-Z0-9.-]+\\.lhr\\.life",
            "https://[a-zA-Z0-9.-]+\\.free\\.pinggy\\.net",
            "https://[a-zA-Z0-9.-]+\\.run\\.pinggy-free\\.link",
            "https://[a-zA-Z0-9.-]+\\.a\\.pinggy\\.link",
            "https://[a-zA-Z0-9.-]+\\.pinggy\\.net",
            "https://[a-zA-Z0-9.-]+\\.pinggy-free\\.link",
            "https://[a-zA-Z0-9.-]+\\.trycloudflare\\.com",
            "https://[a-zA-Z0-9.-]+\\.loca\\.lt"
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)) {
                if let range = Range(match.range, in: text) {
                    let foundURL = String(text[range])
                    if self.publicURL != foundURL {
                        NSLog("[TunnelManager] ✅ Discovered Public HTTPS URL: \(foundURL)")
                        DispatchQueue.main.async { [weak self] in
                            self?.publicURL = foundURL
                            self?.delegate?.tunnelDidUpdateURL(foundURL)
                            NotificationCenter.default.post(
                                name: TunnelManager.tunnelURLNotification,
                                object: nil,
                                userInfo: ["url": foundURL]
                            )
                        }
                    }
                    return
                }
            }
        }
    }
}
