import Foundation
import AppKit
import SwiftUI
import AVFoundation
import CoreAudio
import Accelerate
import Speech
import JavaScriptCore
import Compression
import os

@MainActor
private struct TestSuite {
    static var passed = 0
    static var failed = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #fileID, line: Int = #line) {
        if condition() {
            passed += 1
        } else {
            failed += 1
            fputs("FAIL [\(file):\(line)]: \(message)\n", stderr)
        }
    }

    static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, file: String = #fileID, line: Int = #line) {
        if actual == expected {
            passed += 1
        } else {
            failed += 1
            fputs("FAIL [\(file):\(line)]: \(message) — expected '\(expected)', got '\(actual)'\n", stderr)
        }
    }

    /// Polls `condition` every ~5ms until it holds (fast exit) or `timeout` elapses.
    @discardableResult
    static func waitUntil(timeout: TimeInterval = 3.0, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    /// Asserts that `condition` becomes true within `timeout` (bounded polling, fast exit on success).
    static func expectEventually(
        _ message: String,
        timeout: TimeInterval = 3.0,
        file: String = #fileID,
        line: Int = #line,
        _ condition: () -> Bool
    ) async {
        let ok = await waitUntil(timeout: timeout, condition)
        expect(ok, message, file: file, line: line)
    }

    /// Drains already-enqueued main-queue work (several hops) without fixed wall-clock sleeps.
    static func settleMain(hops: Int = 3) async {
        for _ in 0..<hops {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { c.resume() }
            }
        }
    }

    /// Short, explicit grace period used only for NEGATIVE assertions ("nothing else happens").
    static func graceWindow(milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    private typealias PasteboardSnapshot = [[NSPasteboard.PasteboardType: Data]]

    private static func snapshotPasteboard() -> PasteboardSnapshot {
        let items = NSPasteboard.general.pasteboardItems ?? []
        return items.map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        }
    }

    private static func restorePasteboard(_ snapshot: PasteboardSnapshot) {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard !snapshot.isEmpty else { return }
        let restored: [NSPasteboardItem] = snapshot.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(restored)
    }

    static func runAll() async -> Int32 {
        print("Running minimal Call Caption unit test suite...")
        // copyTranscript()/copyString() write to NSPasteboard.general; never clobber the developer's clipboard.
        let pasteboardBackup = snapshotPasteboard()
        defer { restorePasteboard(pasteboardBackup) }

        testLanguageModelsAndRTL()
        testLiveShareSecurityAndCrypto()
        testLiveShareSSHKnownHostsAndTunnelParsing()
        await testLiveShareHTTPAndSSELifecycle()
        await testAdversarialLiveShareHighThroughputBroadcast()
        await testTranslationEngineConcurrencyCancellationAndCache()
        testAudioCapturePCMAndDSPFloorArbitration()
        testSingleSpeechChannelAndManagerLifecycle()
        await testCaptionCoordinatorAndViewModelMinimalFlow()
        await testAdversarialCaptionCoordinatorStress()
        testWave2LayoutAndLanguageLocalization()
        await testWave2CoordinatorStateAlertsAndL10n()
        await testWave2LiveShareAndWebUIContracts()
        await testStage2BugFixesAndRegressionGuards()
        await testStage3ComprehensiveAuditFixesAndParity()
        await testPublicTunnelCRLFAndGzip()
        await testDuringLiveCallMicDetectionAndFloor()
        await testPhase1RegressionAudio()
        await testPhase1RegressionSpeechAndTranslation()
        await testPhase1RegressionLiveShare()
        await testPhase1RegressionCoordinatorAndUI()
        await testPerformanceAndArchitectureOptimizations()

        print("Results: \(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }

    // MARK: - 1. Language Models & Permissions

    static func testLanguageModelsAndRTL() {
        expectEqual(SupportedLanguages.all.count, 20, "SupportedLanguages should contain 20 core languages")
        let uniqueCodes = Set(SupportedLanguages.all.map(\.code))
        expectEqual(uniqueCodes.count, SupportedLanguages.all.count, "Language codes must be unique")

        expect(SupportedLanguages.isRTL(languageCode: "ar"), "Arabic ('ar') must be RTL")
        expect(SupportedLanguages.isRTL(languageCode: "ar-SA"), "Regional Arabic ('ar-SA') must be RTL")
        expect(SupportedLanguages.isRTL(languageCode: "he"), "Hebrew ('he') must be RTL")
        expect(SupportedLanguages.isRTL(languageCode: "fa"), "Persian ('fa') must be RTL")
        expect(SupportedLanguages.isRTL(languageCode: "ur"), "Urdu ('ur') must be RTL")
        expect(!SupportedLanguages.isRTL(languageCode: "en"), "English ('en') must be LTR")
        expect(!SupportedLanguages.isRTL(languageCode: "es"), "Spanish ('es') must be LTR")

        expectEqual(SupportedLanguages.baseCode(from: "pt-BR"), "pt", "baseCode strips region")
        expectEqual(SupportedLanguages.baseCode(from: "es_MX"), "es", "baseCode normalizes underscores")
        expectEqual(SupportedLanguages.translationCode(from: "zh-TW"), "zh-hant", "zh-TW maps to zh-hant")
        expectEqual(SupportedLanguages.translationCode(from: "zh-CN"), "zh-hans", "zh-CN maps to zh-hans")
        expectEqual(SupportedLanguages.translationCode(from: "zh"), "zh-hans", "bare zh maps to zh-hans")
        expect(SupportedLanguages.bestLocale(forCode: "es").identifier.lowercased().hasPrefix("es"), "bestLocale(es) resolves Spanish")

        let prevState = PermissionHelper.shared.audioCaptureState
        defer { PermissionHelper.shared.updateAudioCaptureState(prevState) }
        PermissionHelper.shared.updateAudioCaptureState(.deniedSilenceDetected)
        expectEqual(PermissionHelper.shared.audioCaptureState, .deniedSilenceDetected, "PermissionHelper tracks denied state")
        PermissionHelper.shared.updateAudioCaptureState(.active)
        expectEqual(PermissionHelper.shared.audioCaptureState, .active, "PermissionHelper tracks active state")
    }

    // MARK: - 2. Live Share Security & Crypto

    static func testLiveShareSecurityAndCrypto() {
        let token1 = LiveShareManager.generateSessionToken()
        let token2 = LiveShareManager.generateSessionToken()
        expectEqual(token1.count, 32, "Session token should be 32 hex chars")
        expect(token1 != token2, "Session tokens must be unique")

        expect(LiveShareManager.isAllowedHost("127.0.0.1", localIP: "192.168.1.25", allowLAN: false, tunnelHost: nil), "Loopback IPv4 allowed")
        expect(LiveShareManager.isAllowedHost("localhost", localIP: "192.168.1.25", allowLAN: false, tunnelHost: nil), "localhost allowed")
        expect(LiveShareManager.isAllowedHost("[::1]", localIP: "192.168.1.25", allowLAN: false, tunnelHost: nil), "IPv6 loopback allowed")
        expect(!LiveShareManager.isAllowedHost("evil.com", localIP: "192.168.1.25", allowLAN: false, tunnelHost: nil), "Arbitrary Host rejected")
        expect(LiveShareManager.isAllowedHost("abc.lhr.life", localIP: "192.168.1.25", allowLAN: false, tunnelHost: "abc.lhr.life"), "Active tunnel host allowed")
        expect(!LiveShareManager.isAllowedHost("other.lhr.life", localIP: "192.168.1.25", allowLAN: false, tunnelHost: "abc.lhr.life"), "Unmatched tunnel host rejected")
        expect(!LiveShareManager.isAllowedHost("192.168.1.25", localIP: "192.168.1.25", allowLAN: false, tunnelHost: nil), "LAN rejected when allowLAN is false")
        expect(LiveShareManager.isAllowedHost("192.168.1.25", localIP: "192.168.1.25", allowLAN: true, tunnelHost: nil), "LAN allowed when allowLAN is true")

        let viewerReq = LiveShareManager.parseHTTPRequest("GET /s/\(token1) HTTP/1.1\r\nHost: 127.0.0.1:54321\r\n\r\n")!
        expectEqual(LiveShareManager.evaluateRoute(request: viewerReq, sessionToken: token1, localIP: "192.168.1.25", allowLAN: false, tunnelHost: nil), .serveHTML, "Viewer HTML route")

        let sseReq = LiveShareManager.parseHTTPRequest("GET /s/\(token1)/events?t=1 HTTP/1.1\r\nHost: 127.0.0.1:54321\r\n\r\n")!
        expectEqual(LiveShareManager.evaluateRoute(request: sseReq, sessionToken: token1, localIP: "192.168.1.25", allowLAN: false, tunnelHost: nil), .serveSSE, "SSE route")

        let stateReq = LiveShareManager.parseHTTPRequest("GET /s/\(token1)/api/state HTTP/1.1\r\nHost: 127.0.0.1:54321\r\n\r\n")!
        expectEqual(LiveShareManager.evaluateRoute(request: stateReq, sessionToken: token1, localIP: "192.168.1.25", allowLAN: false, tunnelHost: nil), .serveAPIState, "State route")

        let postReq = LiveShareManager.parseHTTPRequest("POST /s/\(token1) HTTP/1.1\r\nHost: 127.0.0.1:54321\r\n\r\n")!
        expectEqual(LiveShareManager.evaluateRoute(request: postReq, sessionToken: token1, localIP: "192.168.1.25", allowLAN: false, tunnelHost: nil), .methodNotAllowed, "POST rejected with 405")

        let wrongToken = LiveShareManager.parseHTTPRequest("GET /s/\(token2)/events HTTP/1.1\r\nHost: 127.0.0.1:54321\r\n\r\n")!
        expectEqual(LiveShareManager.evaluateRoute(request: wrongToken, sessionToken: token1, localIP: "192.168.1.25", allowLAN: false, tunnelHost: nil), .notFound, "Mismatched token rejected with 404")

        let rebind = LiveShareManager.parseHTTPRequest("GET /s/\(token1) HTTP/1.1\r\nHost: attacker.com\r\n\r\n")!
        expectEqual(LiveShareManager.evaluateRoute(request: rebind, sessionToken: token1, localIP: "192.168.1.25", allowLAN: false, tunnelHost: nil), .forbidden, "Rebind host rejected with 403")

        // Crypto round-trip & tamper checks
        let crypto = LiveShareCrypto()
        expect(crypto.keyFragment.hasPrefix("k="), "Key fragment uses k=")
        let rawKey = String(crypto.keyFragment.dropFirst(2))
        expect(!rawKey.contains("+") && !rawKey.contains("/") && !rawKey.contains("="), "Base64url without padding")
        expect(LiveShareCrypto(keyFragment: crypto.keyFragment) != nil, "Fragment roundtrips")

        guard let sealed = try? crypto.seal(Data("{\"ok\":true}".utf8), type: "state", sequence: 7) else {
            expect(false, "Seal should succeed")
            return
        }
        expectEqual(try? crypto.open(sealed, expectedType: "state"), Data("{\"ok\":true}".utf8), "Open recovers payload")
        expect((try? crypto.open(sealed, expectedType: "caption")) == nil, "Mismatched expectedType fails closed")
        expect((try? LiveShareCrypto().open(sealed)) == nil, "Wrong key fails closed")
        expect((try? crypto.openWithMetadata(sealed, expectedType: "state", minimumSequence: 8)) == nil, "Replay/stale sequence fails closed")

        if var obj = (try? JSONSerialization.jsonObject(with: sealed)) as? [String: Any],
           let d = obj["d"] as? String,
           var cipher = LiveShareCrypto.base64URLDecode(d) {
            cipher[cipher.count - 1] ^= 0xFF
            obj["d"] = LiveShareCrypto.base64URLEncode(cipher)
            if let tampered = try? JSONSerialization.data(withJSONObject: obj) {
                expect((try? crypto.open(tampered, expectedType: "state")) == nil, "Tampered ciphertext fails closed")
            } else {
                expect(false, "Tampered envelope must be re-serializable for the tamper check")
            }
        } else {
            expect(false, "Sealed envelope must parse as JSON with a base64url 'd' payload for the tamper check")
        }
        if let rawObj = (try? JSONSerialization.jsonObject(with: sealed)) as? [String: Any] {
            for (k, v) in [("v", true as Any), ("v", 2 as Any), ("s", true as Any)] {
                var bad = rawObj
                bad[k] = v
                if let data = try? JSONSerialization.data(withJSONObject: bad) {
                    expect((try? crypto.open(data, expectedType: "state")) == nil, "Invalid header \(k)=\(v) fails closed")
                } else {
                    expect(false, "Mutated header \(k)=\(v) must be serializable for the header check")
                }
            }
        } else {
            expect(false, "Sealed envelope must parse as a JSON object for the header-validation checks")
        }
    }

    // MARK: - 3. SSH Tunnel Pinning & Private Storage

    static func testLiveShareSSHKnownHostsAndTunnelParsing() {
        let pinned = LiveShareManager.pinnedSSHKnownHosts
        expect(pinned.contains("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILVqOuSMnyeGDVO1lG6EaG5In/dXABCchhmHKkuRU2s9"), "Pinned ED25519 key present")

        guard let testDirPath = ProcessInfo.processInfo.environment["CALLCAPTION_TEST_DIR"], !testDirPath.isEmpty else {
            expect(false, "CALLCAPTION_TEST_DIR must be set")
            return
        }
        let testDir = URL(fileURLWithPath: testDirPath, isDirectory: true)
        let knownHostsURL = testDir.appendingPathComponent("priv/ssh_known_hosts")

        do {
            try LiveShareManager.ensureSSHKnownHostsPopulated(at: knownHostsURL)
            expect(FileManager.default.fileExists(atPath: knownHostsURL.path), "ensureSSHKnownHostsPopulated creates file")
            if let attrs = try? FileManager.default.attributesOfItem(atPath: knownHostsURL.path),
               let perm = attrs[.posixPermissions] as? NSNumber {
                expectEqual(perm.intValue & 0o777, 0o600, "known_hosts permissions must be 0600")
            }

            let custom = "other.example.com ssh-ed25519 AAAAOtherKey\n"
            try custom.write(to: knownHostsURL, atomically: true, encoding: .utf8)
            try LiveShareManager.ensureSSHKnownHostsPopulated(at: knownHostsURL)
            let updated = try String(contentsOf: knownHostsURL, encoding: .utf8)
            expect(!updated.contains("other.example.com") && updated.contains("localhost.run"), "Unpinned/custom keys overwritten by exact pinned keys")

            let linkURL = testDir.appendingPathComponent("symlink_dir")
            let targetURL = testDir.appendingPathComponent("real_dir")
            try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
            var symlinkRejected = false
            do {
                try LiveShareManager.ensurePrivateDirectory(linkURL)
            } catch {
                symlinkRejected = true
            }
            expect(symlinkRejected, "ensurePrivateDirectory must refuse symlink directories")
        } catch {
            expect(false, "Private storage check threw unexpected error: \(error)")
        }

        let dummyHosts = URL(fileURLWithPath: "/tmp/Application Support/CallCaption/ssh_known_hosts")
        let args = LiveShareManager.buildSSHTunnelArguments(port: 54321, knownHostsURL: dummyHosts)
        expect(!args.contains("-N"), "SSH args must omit -N so banner URL streams")
        expect(args.contains("-T"), "SSH args include -T")
        expect(args.contains("StrictHostKeyChecking=yes"), "SSH enforces StrictHostKeyChecking=yes")
        expect(args.contains("UserKnownHostsFile=\"/tmp/Application Support/CallCaption/ssh_known_hosts\""), "Known hosts path quoted for spaces")
        expect(args.contains("80:127.0.0.1:54321"), "Reverse forward specifies bound port")

        for valid in ["https://499635bbf3da46.lhr.life", "https://my-session.lhr.rocks", "Welcome https://demo.localhost.run."] {
            expect(LiveShareManager.extractTunnelURL(from: valid) != nil, "Valid tunnel output parses: \(valid)")
        }
        for invalid in ["http://499635bbf3da46.lhr.life", "https://fake.lhr.life.evil.com", "https://admin.localhost.run", "https://lhr.life"] {
            expect(LiveShareManager.extractTunnelURL(from: invalid) == nil, "Invalid tunnel URL rejected: \(invalid)")
        }
    }

    // MARK: - 4. Live Share Loopback HTTP/SSE Server

    static func testLiveShareHTTPAndSSELifecycle() async {
        let manager = LiveShareManager.shared
        manager.stopSharingSynchronously()
        manager.clearHistoryForPrivacy()

        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpMaximumConnectionsPerHost = 32
        cfg.timeoutIntervalForRequest = 4.0
        let session = URLSession(configuration: cfg)
        var fds: [Int32] = []

        func cleanup() {
            for fd in fds { Darwin.close(fd) }
            fds.removeAll()
            session.invalidateAndCancel()
            manager.stopSharingSynchronously()
            manager.clearHistoryForPrivacy()
        }
        defer { cleanup() }

        manager.startSharing(
            allowLAN: false,
            useExternalTunnel: false,
            shareBothSpeakers: true,
            foreignLanguageCode: "es",
            mainLanguageCode: "en"
        )

        var localURL: URL? = nil
        _ = await waitUntil(timeout: 3.0) {
            if let url = manager.localShareURL, manager.isSharing {
                localURL = url
                return true
            }
            return false
        }

        guard let url = localURL,
              let host = url.host,
              let port = url.port,
              let fragment = url.fragment,
              let crypto = LiveShareCrypto(keyFragment: fragment) else {
            expect(false, "LiveShareManager failed to start loopback listener")
            return
        }

        let token = url.path.split(separator: "/").last.map(String.init) ?? ""
        manager.broadcastCaption(
            speaker: "Caller",
            original: "Prueba loopback",
            translated: "Loopback caller line",
            sourceLangCode: "es",
            targetLangCode: "en",
            isFinal: true
        )
        manager.broadcastCaption(
            speaker: "You",
            original: "Host reply",
            translated: "Respuesta del host",
            sourceLangCode: "en",
            targetLangCode: "es",
            isFinal: true
        )

        do {
            let (htmlData, htmlResp) = try await session.data(from: URL(string: "http://\(host):\(port)/s/\(token)")!)
            expectEqual((htmlResp as? HTTPURLResponse)?.statusCode ?? 0, 200, "GET /s/<token> returns 200")
            let html = String(data: htmlData, encoding: .utf8) ?? ""
            expect(html.contains("/s/\(token)") && html.contains("/events?viewer="), "Receiver HTML contains token & SSE endpoint with ?viewer=")
            expect(html.contains(".speaker-host { color: var(--accent-green); }") && html.contains(".speaker-caller { color: var(--accent-blue); }"), "Receiver HTML aligns Host=Green and Caller=Blue with native UI")
            expect(html.contains("prefers-color-scheme: light") && html.contains("prefers-reduced-motion: reduce"), "Receiver HTML supports Light Mode and Reduced Motion")
            expect(html.contains("id=\"sr-live-announcer\"") && html.contains("id=\"copy-transcript-btn\""), "Receiver HTML includes dedicated screen-reader live region and Copy Transcript button")

            let (stateData, stateResp) = try await session.data(from: URL(string: "http://\(host):\(port)/s/\(token)/api/state")!)
            expectEqual((stateResp as? HTTPURLResponse)?.statusCode ?? 0, 200, "GET /api/state returns 200")
            let decrypted = try crypto.open(stateData, expectedType: "state")
            let json = String(data: decrypted, encoding: .utf8) ?? ""
            expect(json.contains("Loopback caller line") && json.contains("Respuesta del host"), "Both speakers present in /api/state")

            // Switching to host-only strips caller entries for privacy
            manager.configure(shareBothSpeakers: false)
            let (stateAfterData, _) = try await session.data(from: URL(string: "http://\(host):\(port)/s/\(token)/api/state")!)
            let jsonAfter = String(data: try crypto.open(stateAfterData, expectedType: "state"), encoding: .utf8) ?? ""
            expect(!jsonAfter.contains("Loopback caller line") && jsonAfter.contains("Respuesta del host"), "Host-only strips caller captions")
        } catch {
            expect(false, "Loopback HTTP failed: \(error)")
        }

        @Sendable func openLoopbackHTTP(path: String, keepOpen: Bool) -> (fd: Int32, status: Int)? {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            let tv = timeval(tv_sec: 3, tv_usec: 0)
            withUnsafePointer(to: tv) {
                _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
                _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
            }
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            addr.sin_addr = in_addr(s_addr: UInt32(0x7f000001).bigEndian)
            let connected = withUnsafePointer(to: addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { Darwin.close(fd); return nil }

            let req = "GET \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: \(keepOpen ? "keep-alive" : "close")\r\n\r\n"
            let sent = req.withCString { cStr in
                let total = strlen(cStr)
                var offset = 0
                while offset < total {
                    let n = Darwin.send(fd, cStr.advanced(by: offset), total - offset, 0)
                    if n <= 0 { return false }
                    offset += n
                }
                return true
            }
            guard sent else { Darwin.close(fd); return nil }

            var buf = [UInt8](repeating: 0, count: 1024)
            let readN = buf.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            guard readN > 0 else { Darwin.close(fd); return nil }
            let header = String(decoding: buf.prefix(readN), as: UTF8.self)
            guard let line1 = header.components(separatedBy: "\r\n").first else { Darwin.close(fd); return nil }
            let parts = line1.split(separator: " ")
            guard parts.count >= 2, let code = Int(parts[1]) else { Darwin.close(fd); return nil }
            if !keepOpen {
                Darwin.close(fd)
                return (-1, code)
            }
            return (fd, code)
        }

        for _ in 0..<20 {
            if let opened = await Task.detached(operation: { openLoopbackHTTP(path: "/s/\(token)/events", keepOpen: true) }).value {
                if opened.fd >= 0 { fds.append(opened.fd) }
                expectEqual(opened.status, 200, "First 20 SSE connections get 200 OK")
            } else {
                expect(false, "Failed to open SSE socket")
            }
        }
        await expectEventually("All 20 SSE viewers registered", timeout: 2.0) {
            manager.activeClientCount == 20
        }
        let overflowStatus = await Task.detached { openLoopbackHTTP(path: "/s/\(token)/events", keepOpen: false)?.status }.value
        expectEqual(overflowStatus ?? 0, 503, "21st SSE client returns 503")
        let stateUnderLoad = await Task.detached { openLoopbackHTTP(path: "/s/\(token)/api/state", keepOpen: false)?.status }.value
        expectEqual(stateUnderLoad ?? 0, 200, "/api/state remains responsive while SSE cap full")
    }

    // MARK: - 5. High-Throughput Concurrent Live Share Broadcast

    static func testAdversarialLiveShareHighThroughputBroadcast() async {
        let manager = LiveShareManager.shared
        manager.stopSharingSynchronously()
        manager.clearHistoryForPrivacy()
        manager.startSharing(allowLAN: false, useExternalTunnel: false, shareBothSpeakers: true)
        await expectEventually("LiveShareManager starts loopback listener for stress test", timeout: 3.0) {
            manager.isSharing && manager.localShareURL != nil
        }

        await withTaskGroup(of: Void.self) { group in
            for t in 0..<8 {
                group.addTask {
                    for i in 0..<25 {
                        manager.broadcastCaption(
                            speaker: t % 2 == 0 ? "Caller" : "You",
                            original: "Stress \(t)-\(i)",
                            translated: "Trans \(t)-\(i)",
                            sourceLangCode: "en",
                            targetLangCode: "es",
                            isFinal: i % 3 == 0,
                            utteranceID: UUID()
                        )
                        if i % 10 == 0 {
                            manager.broadcastPauseState(i % 20 == 0)
                            manager.clearHistoryForPrivacy()
                        }
                    }
                }
            }
        }
        manager.stopSharingSynchronously()
        manager.clearHistoryForPrivacy()
        expect(!manager.isSharing, "LiveShareManager survives concurrent broadcast stress cleanly")
    }

    // MARK: - 6. TranslationEngine Concurrency, Timeout & Cache Eviction

    static func testTranslationEngineConcurrencyCancellationAndCache() async {
        let engine = TranslationEngine.shared
        await engine.resetForTesting()

        expectEqual(await engine.translate(text: "   \n ", sourceCode: "es", targetCode: "en"), "", "Whitespace returns empty string")
        expectEqual(await engine.translate(text: "Hello", sourceCode: "en", targetCode: "en"), "Hello", "Identity translation returns trimmed text")

        // Timeout must not deadlock mutex
        let slowStarted = OSAllocatedUnfairLock(initialState: false)
        await engine.setTimeoutForTesting(0.05)
        await engine.setTranslatorForTesting { text, _, _, _ in
            if text == "SLOW" {
                slowStarted.withLock { $0 = true }
                try await Task.sleep(for: .milliseconds(400))
                return "NEVER"
            }
            return "TR_\(text)"
        }
        let timedOut = await engine.translate(text: "SLOW", sourceCode: "es", targetCode: "en", isFinal: true)
        expect(slowStarted.withLock { $0 }, "Mock translator ran for slow input")
        expect(timedOut == nil, "Timed-out translation returns nil cleanly")

        // After clearing cooldown, next request on same pair succeeds immediately
        await engine.resetForTesting()
        let count = OSAllocatedUnfairLock(initialState: 0)
        await engine.setTranslatorForTesting { text, _, _, _ in
            count.withLock { $0 += 1 }
            return "MOCK_\(text)"
        }

        // Fill beyond 512 capacity and check eviction
        for i in 0..<520 {
            let out = await engine.translate(text: "item_\(i)", sourceCode: "es", targetCode: "en", isFinal: true)
            if i == 0 || i == 519 {
                expectEqual(out, "MOCK_item_\(i)", "Mock translation matches")
            }
        }
        expectEqual(await engine.cachedEntryCountForTesting(), 512, "Final cache caps at 512 entries")

        count.withLock { $0 = 0 }
        _ = await engine.translate(text: "item_519", sourceCode: "es", targetCode: "en", isFinal: true)
        expectEqual(count.withLock { $0 }, 0, "Recent entry hits cache without re-invoking translator")

        _ = await engine.translate(text: "item_0", sourceCode: "es", targetCode: "en", isFinal: true)
        expectEqual(count.withLock { $0 }, 1, "Evicted oldest entry item_0 re-invokes translator")

        // Concurrent storm
        await engine.resetForTesting()
        await engine.setTranslatorForTesting { text, src, tgt, _ in
            try? await Task.sleep(for: .milliseconds(5))
            return "[\(src)->\(tgt)] \(text)"
        }
        await withTaskGroup(of: String?.self) { group in
            for i in 0..<24 {
                group.addTask {
                    await engine.translate(text: "msg \(i % 6)", sourceCode: i % 2 == 0 ? "es" : "fr", targetCode: "en", isFinal: i % 3 == 0)
                }
            }
            for await res in group {
                expect(res == nil || res?.isEmpty == false, "Concurrent translation yields nil or non-empty string")
            }
        }
        await engine.resetForTesting()
    }

    // MARK: - 7. AudioCaptureEngine PCM Conversion & Floor Arbitration

    static func testAudioCapturePCMAndDSPFloorArbitration() {
        let engine = AudioCaptureEngine()
        guard let monoFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false),
              let monoOut = AVAudioPCMBuffer(pcmFormat: monoFmt, frameCapacity: 128) else {
            expect(false, "Failed to allocate Float32 mono format")
            return
        }

        // Stereo Float32 downmix
        if let stereoFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false),
           let stereoBuf = AVAudioPCMBuffer(pcmFormat: stereoFmt, frameCapacity: 128) {
            stereoBuf.frameLength = 128
            if let ch = stereoBuf.floatChannelData {
                for i in 0..<128 {
                    ch[0][i] = 0.8
                    ch[1][i] = 0.2
                }
            }
            expect(engine.convertAndCopyToMono(source: stereoBuf, destination: monoOut), "Float32 stereo downmix succeeds")
            let sample = monoOut.floatChannelData?[0][0] ?? 0
            expect(abs(sample - 0.5) < 0.001, "Stereo downmix averages channels to 0.5 (got \(sample))")
        }

        // Int32 non-interleaved stereo conversion (asymmetric L/R: AUDIO-5 must keep Channel 1 / Right in the downmix)
        if let fmt32 = AVAudioFormat(commonFormat: .pcmFormatInt32, sampleRate: 48000, channels: 2, interleaved: false),
           let buf32 = AVAudioPCMBuffer(pcmFormat: fmt32, frameCapacity: 128) {
            buf32.frameLength = 128
            if let i32 = buf32.int32ChannelData {
                for i in 0..<128 {
                    i32[0][i] = 0                  // L = 0.0
                    i32[1][i] = 1_717_986_918      // R ≈ 0.8
                }
            }
            expect(engine.convertAndCopyToMono(source: buf32, destination: monoOut), "Int32 stereo converts to Float32 mono")
            expectEqual(monoOut.frameLength, 128, "Frame length preserved")
            let rightOnly = monoOut.floatChannelData?[0][64] ?? 0
            expect(rightOnly > 0.2, "Right-only Int32 stereo input is NOT discarded by the downmix (got \(rightOnly))")
            expect(abs(rightOnly - 0.4) < 0.06, "Right-only Int32 stereo downmixes to ~0.4 (got \(rightOnly))")

            // Reusing the cached converter for the same format must give a stable result (no per-buffer reset artifacts).
            for _ in 0..<3 {
                monoOut.frameLength = 0
                expect(engine.convertAndCopyToMono(source: buf32, destination: monoOut), "Cached Int32 converter converts repeatedly")
                let again = monoOut.floatChannelData?[0][64] ?? 0
                expect(abs(again - rightOnly) < 0.01, "Repeated Int32 downmix remains stable (got \(again) vs \(rightOnly))")
            }

            if let i32 = buf32.int32ChannelData {
                for i in 0..<128 {
                    i32[0][i] = 1_717_986_918      // L ≈ 0.8
                    i32[1][i] = 0                  // R = 0.0
                }
            }
            monoOut.frameLength = 0
            expect(engine.convertAndCopyToMono(source: buf32, destination: monoOut), "Int32 left-only stereo converts")
            let leftOnly = monoOut.floatChannelData?[0][64] ?? 0
            expect(abs(leftOnly - 0.4) < 0.06, "Left-only Int32 stereo downmixes to ~0.4 (got \(leftOnly))")
        } else {
            expect(false, "Failed to allocate Int32 stereo test buffer")
        }

        // Float32 non-interleaved stereo with Right-only content (fast path)
        if let stereoFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false),
           let rBuf = AVAudioPCMBuffer(pcmFormat: stereoFmt, frameCapacity: 128) {
            rBuf.frameLength = 128
            if let ch = rBuf.floatChannelData {
                for i in 0..<128 { ch[0][i] = 0; ch[1][i] = 0.8 }
            }
            expect(engine.convertAndCopyToMono(source: rBuf, destination: monoOut), "Float32 right-only stereo downmix succeeds")
            let s = monoOut.floatChannelData?[0][0] ?? 0
            expect(abs(s - 0.4) < 0.001, "Float32 right-only stereo downmixes to 0.4 (got \(s))")
        } else {
            expect(false, "Failed to allocate Float32 stereo test buffer")
        }

        // Float32 INTERLEAVED stereo with Right-only content (AVAudioConverter fallback path)
        if let ilFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true),
           let ilBuf = AVAudioPCMBuffer(pcmFormat: ilFmt, frameCapacity: 128) {
            ilBuf.frameLength = 128
            if let ptr = ilBuf.floatChannelData?[0] {
                for i in 0..<128 { ptr[2 * i] = 0; ptr[2 * i + 1] = 0.8 }
            }
            monoOut.frameLength = 0
            expect(engine.convertAndCopyToMono(source: ilBuf, destination: monoOut), "Float32 interleaved stereo converts")
            let s = monoOut.floatChannelData?[0][64] ?? 0
            expect(abs(s - 0.4) < 0.06, "Float32 interleaved right-only stereo keeps Channel 1 (got \(s))")
        } else {
            expect(false, "Failed to allocate Float32 interleaved stereo test buffer")
        }

        // computeRMS & echoTailDecay
        let samples = [Float](repeating: 0.5, count: 64)
        let rms = samples.withUnsafeBufferPointer { ptr in
            AudioCaptureEngine.computeRMS(samples: ptr.baseAddress!, count: 64)
        }
        expect(abs(rms - 0.5) < 0.001, "computeRMS calculates DC 0.5 correctly")

        expectEqual(AudioCaptureEngine.echoTailDecay(after: -1), 1.0, "Negative elapsed clamps to 1.0")
        expect(AudioCaptureEngine.echoTailDecay(after: 0.2) > AudioCaptureEngine.echoTailDecay(after: 0.8), "Echo tail decays monotonically")
        expect(AudioCaptureEngine.echoTailDecay(after: 2.0) < 0.001, "Echo tail decays below 0.001 by 2.0s")

        // Floor arbitration (microphone speaker prioritized before caller)
        expectEqual(AudioCaptureEngine.resolveFloorOwner(current: .none, isCallerActive: false, isUserActive: true), .user, "User takes idle floor")
        expectEqual(AudioCaptureEngine.resolveFloorOwner(current: .none, isCallerActive: true, isUserActive: true), .user, "User prioritized before caller on simultaneous start")
        expectEqual(AudioCaptureEngine.resolveFloorOwner(current: .user, isCallerActive: true, isUserActive: true), .user, "User keeps floor during caller bleed")
        expectEqual(AudioCaptureEngine.resolveFloorOwner(current: .caller, isCallerActive: true, isUserActive: true), .user, "Microphone speaker takes floor priority over caller during overlap")
        expectEqual(AudioCaptureEngine.resolveFloorOwner(current: .user, isCallerActive: true, isUserActive: false), .caller, "Handoff to caller when user stops")
        expectEqual(AudioCaptureEngine.resolveFloorOwner(current: .caller, isCallerActive: false, isUserActive: false), .none, "Floor releases when idle")

        let origOverride = AudioCaptureEngine.overrideAcousticIsolation
        defer { AudioCaptureEngine.overrideAcousticIsolation = origOverride }
        AudioCaptureEngine.overrideAcousticIsolation = true
        expect(AudioCaptureEngine.isAudioOutputAcousticallyIsolated(), "Acoustic isolation override honored")
        AudioCaptureEngine.overrideAcousticIsolation = false
        expect(!AudioCaptureEngine.isAudioOutputAcousticallyIsolated(), "False acoustic isolation override honored")
    }

    // MARK: - 8. Speech Recognition Channel & Manager Lifecycle

    static func testSingleSpeechChannelAndManagerLifecycle() {
        let ch = SingleSpeechChannel(name: "test", sourceLocaleId: "en-US", targetLangCode: "es")
        expect(!ch.isRunning && !ch.isSuspended, "Channel starts idle")
        ch.start(sourceLocaleId: "en-US", targetLangCode: "es")
        expect(ch.isRunning, "Channel isRunning after start")
        ch.discardInFlight()
        expect(ch.isRunning, "discardInFlight keeps channel running")

        let uID = UUID()
        var finalizedID: UUID?
        var finalizedText = ""
        ch.onFinalWithLanguages = { id, orig, _, _, _, _ in
            finalizedID = id
            finalizedText = orig
        }
        ch.commitSentenceForTesting(utteranceID: uID, original: "Hello caller")
        expectEqual(finalizedID, uID, "commitSentence preserves utterance UUID")
        expectEqual(finalizedText, "Hello caller", "commitSentence delivers original text")

        expect(SingleSpeechChannel.isLikelyInverseTextNormalizationForTesting(previous: "call me at five", updated: "call me at 5"), "ITN detected cleanly")
        expect(!SingleSpeechChannel.isLikelyInverseTextNormalizationForTesting(previous: "a completely different long sentence", updated: "no"), "Sudden collapse rejected as ITN")

        ch.stop()
        expect(!ch.isRunning, "Channel stops cleanly")

        // Manager floor priority
        let mgr = SpeechRecognitionManager()
        mgr.start(callerLocaleId: "es-ES", targetLangCode: "en", micLocaleId: "en-US", micTargetLangCode: "es", isMicEnabled: true)
        defer { mgr.stop() }
        mgr.isAcousticallyIsolated = false
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 160) else {
            expect(false, "Failed to allocate 16k PCM buffer")
            return
        }
        buf.frameLength = 160

        mgr.feedCallerAudioBuffer(buf, userHasFloor: false)
        expect(mgr.micChannel.isSuspended, "Open speaker suspends mic when caller speaks")
        mgr.feedMicAudioBuffer(buf, isUserSpeaking: true)
        expect(!mgr.micChannel.isSuspended, "Confirmed user speech unsuspends mic immediately")
        expect(mgr.callerChannel.isSuspended, "Microphone speaker priority suspends caller channel on open speakers")
        mgr.feedCallerAudioBuffer(buf, userHasFloor: true)
        expect(!mgr.micChannel.isSuspended, "User floor prevents caller bleed from suspending mic")
        expect(mgr.callerChannel.isSuspended, "Caller channel remains suspended while user holds floor")
        mgr.isAcousticallyIsolated = true
        mgr.feedCallerAudioBuffer(buf, userHasFloor: false)
        expect(!mgr.micChannel.isSuspended && !mgr.callerChannel.isSuspended, "Headphones allow simultaneous caller + mic recognition")
    }

    // MARK: - 9. CaptionCoordinator, ViewModel & SwiftUI Popover

    static func testCaptionCoordinatorAndViewModelMinimalFlow() async {
        let suiteName = "com.callcaption.test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            expect(false, "Failed to create isolated UserDefaults suite")
            return
        }
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let coordinator = CaptionCoordinator(defaults: defaults, liveShareManager: LiveShareManager.shared)
        defer { coordinator.stop() }

        let vm = coordinator.viewModel
        expectEqual(vm.callerLanguageCode, "es", "Default caller language is Spanish")
        expectEqual(vm.myLanguageCode, "en", "Default user language is English")
        expect(!vm.isConversationalMode, "Default mode is system audio only (Transcribed Caption)")
        expect(vm.showOriginalText, "Original text shown by default")
        expect(!vm.isPinned, "Popover unpinned by default")
        expectEqual(vm.captionFontSize, CaptionCoordinator.defaultCaptionFontSize, "Default caption font size is 15pt")
        expectEqual(vm.appearanceMode, .system, "Default appearance mode respects System")

        // Language picker HIG names exclude country flags
        for item in SupportedLanguages.all {
            expect(!item.localizedPickerName.contains(item.flag), "localizedPickerName omits country flag for \(item.code)")
            expect(!item.localizedPickerName.isEmpty, "localizedPickerName non-empty for \(item.code)")
        }

        // SwiftUI hosting check (popover + detached HUD)
        let popoverView = CaptionPopoverView(viewModel: vm, onQuit: {})
        let hosting = NSHostingController(rootView: popoverView)
        expect(hosting.view.fittingSize.width >= 400 && hosting.view.fittingSize.height >= 500, "CaptionPopoverView lays out with non-trivial dimensions")

        let detachedView = CaptionPopoverView(viewModel: vm, isDetached: true, onToggleDetach: {}, onQuit: {})
        let detachedHosting = NSHostingController(rootView: detachedView)
        expect(detachedHosting.view.fittingSize.width >= 360 && detachedHosting.view.fittingSize.height >= 260, "Detached CaptionPopoverView supports compact minimum size")

        // Font size scaling bounds & appearance mode persistence
        coordinator.increaseFontSize()
        expectEqual(vm.captionFontSize, 17.0, "increaseFontSize increments by 2pt")
        for _ in 0..<10 { coordinator.increaseFontSize() }
        expectEqual(vm.captionFontSize, CaptionCoordinator.maxCaptionFontSize, "captionFontSize clamps at max")
        for _ in 0..<10 { coordinator.decreaseFontSize() }
        expectEqual(vm.captionFontSize, CaptionCoordinator.minCaptionFontSize, "captionFontSize clamps at min")
        coordinator.resetFontSize()
        expectEqual(vm.captionFontSize, CaptionCoordinator.defaultCaptionFontSize, "resetFontSize restores default")

        let appearanceNotified = OSAllocatedUnfairLock(initialState: false)
        let appObs = NotificationCenter.default.addObserver(forName: CaptionCoordinator.appearanceDidChangeNotification, object: coordinator, queue: nil) { _ in
            appearanceNotified.withLock { $0 = true }
        }
        coordinator.setAppearanceMode(.light)
        expectEqual(vm.appearanceMode, .light, "Appearance mode switches to light")
        expect(appearanceNotified.withLock { $0 }, "Appearance change posts notification")
        NotificationCenter.default.removeObserver(appObs)
        coordinator.setAppearanceMode(.system)

        // Level metering visibility resets levels
        coordinator.audioCaptureDidUpdateLevels(callerLevel: 0.4, micLevel: 0.2)
        await settleMain()
        coordinator.setLevelMeteringVisible(false)
        await settleMain()
        expectEqual(vm.callerLevel, 0, "Hiding level metering zeroes callerLevel")
        expectEqual(vm.micLevel, 0, "Hiding level metering zeroes micLevel")
        coordinator.setLevelMeteringVisible(true)

        // Swap & persistence
        coordinator.setCallerLanguage("fr")
        coordinator.setMyLanguage("de")
        expectEqual(vm.callerLanguageCode, "fr", "Caller language updates to fr")
        expectEqual(vm.myLanguageCode, "de", "My language updates to de")
        coordinator.swapLanguages()
        expectEqual(vm.callerLanguageCode, "de", "swapLanguages flips caller to de")
        expectEqual(vm.myLanguageCode, "fr", "swapLanguages flips my to fr")

        // Modes
        coordinator.setConversationalMode(true)
        expect(coordinator.isConversationalMode && vm.isConversationalMode, "Conversational mode toggles on")
        coordinator.setShowOriginalText(false)
        expect(!vm.showOriginalText, "showOriginalText toggles off")
        coordinator.setPinned(true)
        expect(coordinator.isPinned && vm.isPinned, "isPinned toggles on")

        // Utterance upsert & copy/clear
        let u1 = UUID()
        coordinator.callerSpeechDidUpdate(utteranceID: u1, partialOriginal: "Hola", partialTranslated: "Hi", sourceLangCode: "es", targetLangCode: "en", isUntranslated: false)
        await expectEventually("Partial entry inserted", timeout: 1.0) { vm.entries.count == 1 }
        expectEqual(vm.entries.first?.isFinal, false, "Partial marked not final")

        coordinator.callerSpeechDidFinalize(utteranceID: u1, original: "Hola mundo", translated: "Hello world", sourceLangCode: "es", targetLangCode: "en", isUntranslated: false)
        await expectEventually("Final replaces partial in-place with same UUID", timeout: 1.0) {
            vm.entries.count == 1 && vm.entries.first?.isFinal == true
        }
        expectEqual(vm.entries.first?.translated, "Hello world", "Final translation updated")

        let u2 = UUID()
        coordinator.micSpeechDidFinalize(utteranceID: u2, original: "Hi back", translated: "Hola de vuelta", sourceLangCode: "en", targetLangCode: "es", isUntranslated: false)
        await expectEventually("Second speaker utterance appended", timeout: 1.0) { vm.entries.count == 2 }

        coordinator.setShowOriginalText(true)
        let exported = coordinator.copyTranscript()
        expect(exported.contains("[Caller] Hello world") && exported.contains("(Hola mundo)"), "Transcript export formats speaker + original")
        expect(exported.contains("[You] Hola de vuelta"), "Transcript export includes user reply")

        coordinator.clearTranscript()
        await expectEventually("clearTranscript removes all captions", timeout: 1.0) { vm.entries.isEmpty }

        // Alert prioritization & notification delivery
        let alertNotifCount = OSAllocatedUnfairLock(initialState: 0)
        let alertObs = NotificationCenter.default.addObserver(forName: CaptionCoordinator.alertStateDidChangeNotification, object: coordinator, queue: nil) { _ in
            alertNotifCount.withLock { $0 += 1 }
        }
        coordinator.speechRecognitionDidEncounterAuthError(channelName: "caller", message: "Speech Recognition access required")
        coordinator.audioCaptureDidDetectDeniedTapPermission()
        await expectEventually("Audio capture alert outranks speech alert", timeout: 1.0) {
            vm.alertAction == .audioCapture
        }
        expect(alertNotifCount.withLock { $0 >= 1 }, "Alert change posts alertStateDidChangeNotification")
        coordinator.dismissPresentedAlert()
        await expectEventually("Dismissing audio capture reveals lower-priority speech alert", timeout: 1.0) {
            vm.alertAction == .speechRecognition
        }
        coordinator.speechRecognitionDidClearAuthError(channelName: "caller")
        await expectEventually("Clearing speech alert clears banner", timeout: 1.0) {
            vm.alertMessage == nil
        }
        NotificationCenter.default.removeObserver(alertObs)

        // Pause / Auto-pause
        coordinator.pause()
        expect(coordinator.isPaused && vm.isPaused, "Explicit pause updates coordinator and viewModel")
        coordinator.autoResumeAfterSystem()
        expect(coordinator.isPaused, "Manual pause is not auto-resumed by wake event")
    }

    // MARK: - 10. Adversarial Coordinator Concurrency Stress

    static func testAdversarialCaptionCoordinatorStress() async {
        let suiteName = "com.callcaption.stress.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let coordinator = CaptionCoordinator(defaults: defaults, liveShareManager: LiveShareManager.shared)
        defer { coordinator.stop() }
        _ = coordinator.viewModel

        await withTaskGroup(of: Void.self) { group in
            for w in 0..<12 {
                group.addTask {
                    for iter in 0..<30 {
                        switch (w + iter) % 6 {
                        case 0:
                            coordinator.pause()
                        case 1:
                            coordinator.togglePauseResume()
                        case 2:
                            coordinator.autoPauseForSystem()
                            coordinator.autoResumeAfterSystem()
                        case 3:
                            coordinator.audioCaptureDidUpdateLevels(callerLevel: Float(iter) / 50.0, micLevel: Float(iter) / 80.0)
                        case 4:
                            let id = UUID()
                            coordinator.callerSpeechDidUpdate(utteranceID: id, partialOriginal: "Hola \(iter)", partialTranslated: "Hi \(iter)", isUntranslated: false)
                            if iter % 4 == 0 {
                                coordinator.callerSpeechDidFinalize(utteranceID: id, original: "Hola \(iter)", translated: "Hi \(iter)", isUntranslated: false)
                            }
                        default:
                            coordinator.setConversationalMode(iter % 2 == 0)
                            if iter % 10 == 0 {
                                coordinator.clearTranscript()
                            }
                        }
                    }
                }
            }
        }
        coordinator.stop()
        expect(!coordinator.isPaused, "Coordinator stopped cleanly after stress")
    }

    // MARK: - 11. Wave 2: Layout, Localization, Plurals & ViewModel Contracts

    static func testWave2LayoutAndLanguageLocalization() {
        let suiteName = "com.callcaption.wave2.layout.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            expect(false, "Failed to create isolated UserDefaults suite")
            return
        }
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let manager = LiveShareManager.shared
        manager.stopSharingSynchronously()
        manager.clearHistoryForPrivacy()
        defer {
            manager.stopSharingSynchronously()
            manager.clearHistoryForPrivacy()
        }

        let coordinator = CaptionCoordinator(defaults: defaults, liveShareManager: manager)
        defer { coordinator.stop() }
        let vm = coordinator.viewModel

        expect(vm.isStartingUp, "ViewModel starts in isStartingUp == true before start")
        expect(!vm.isAudioCapturing, "ViewModel starts with isAudioCapturing == false")
        expect(!vm.showAlertRetryAction, "ViewModel starts with showAlertRetryAction == false")
        expect(!vm.sharePublicLinkRotated, "ViewModel starts with sharePublicLinkRotated == false")
        expect(!vm.shareLANIPUnavailable, "ViewModel starts with shareLANIPUnavailable == false")

        // AppL10n plural formatting fallback contract
        expectEqual(
            AppL10n.plural("share.viewers.a11y", fallbackSingular: "%ld active viewer", fallbackPlural: "%ld active viewers", count: 0),
            "0 active viewers",
            "AppL10n.plural formats 0 with plural rule"
        )
        expectEqual(
            AppL10n.plural("share.viewers.a11y", fallbackSingular: "%ld active viewer", fallbackPlural: "%ld active viewers", count: 1),
            "1 active viewer",
            "AppL10n.plural formats 1 with singular rule"
        )
        expectEqual(
            AppL10n.plural("share.viewers.a11y", fallbackSingular: "%ld active viewer", fallbackPlural: "%ld active viewers", count: 3),
            "3 active viewers",
            "AppL10n.plural formats 3 with plural rule"
        )

        // Language ordering & Turkish-locale native capitalization
        expectEqual(SupportedLanguages.all.first?.code, "en", "SupportedLanguages.all keeps English first")
        let sorted = SupportedLanguages.sortedByLocalizedName
        expectEqual(sorted.count, SupportedLanguages.all.count, "sortedByLocalizedName preserves all languages")
        expectEqual(Set(sorted.map(\.code)), Set(SupportedLanguages.all.map(\.code)), "sortedByLocalizedName preserves exact language set")
        for idx in 1..<sorted.count {
            let cmp = sorted[idx - 1].localizedName.localizedStandardCompare(sorted[idx].localizedName)
            expect(cmp != .orderedDescending, "sortedByLocalizedName is non-descending at index \(idx)")
        }
        if let trItem = SupportedLanguages.item(forCode: "tr") {
            let nativeTr = Locale(identifier: "tr").localizedString(forLanguageCode: "tr")?.capitalized(with: Locale(identifier: "tr"))
            expectEqual(nativeTr, "Türkçe", "Turkish native name capitalizes with Turkish locale")
            expect(trItem.localizedPickerName.contains("Türkçe"), "Turkish localizedPickerName includes native Turkish name")
        } else {
            expect(false, "Expected Turkish language item")
        }
        for item in SupportedLanguages.all where item.code != "tr" {
            expect(!item.localizedPickerName.contains("İ"), "Non-Turkish language \(item.code) does not use Turkish dotted-I capitalization")
        }

        // Constrained popover (430x540) and detached (360x300) SwiftUI layout with long Spanish strings + all banners visible
        vm.isSharing = true
        vm.showShareOptions = true
        vm.shareStatus = .connectingTunnel(
            localURL: URL(string: "http://192.168.1.42:54321/s/tok#frag"),
            statusText: "Conectando enlace público temporal mediante túnel cifrado de extremo a extremo…"
        )
        vm.shareLANIPUnavailable = true
        vm.sharePublicLinkRotated = true
        vm.alertMessage = "El permiso de Grabación de Audio del Sistema está desactivado. Activa Call Caption en Ajustes del Sistema para continuar."
        vm.alertAction = .audioCapture
        vm.showAlertRetryAction = true
        vm.entries = [
            CaptionEntry(
                id: UUID(),
                speaker: "Caller",
                original: "Mensaje largo de prueba para comprobar el ajuste de líneas sin desbordamiento horizontal.",
                translated: "Long test message to verify line wrapping without horizontal overflow in compact panes.",
                sourceLangCode: "es",
                targetLangCode: "en",
                isFinal: true
            )
        ]

        let popoverHosting = NSHostingController(
            rootView: CaptionPopoverView(viewModel: vm, isDetached: false, onToggleDetach: {}, onQuit: {})
        )
        popoverHosting.view.frame = NSRect(x: 0, y: 0, width: 430, height: 540)
        popoverHosting.view.layoutSubtreeIfNeeded()
        expect(
            popoverHosting.view.fittingSize.width <= 430.5 && popoverHosting.view.fittingSize.height <= 540.5,
            "Popover CaptionPopoverView fits within 430x540 with banners and alerts active (got \(popoverHosting.view.fittingSize))"
        )

        let detachedConstrainedHosting = NSHostingController(
            rootView: CaptionPopoverView(viewModel: vm, isDetached: true, onToggleDetach: {}, onQuit: {})
                .frame(width: 360, height: 300)
        )
        detachedConstrainedHosting.view.frame = NSRect(x: 0, y: 0, width: 360, height: 300)
        detachedConstrainedHosting.view.layoutSubtreeIfNeeded()
        expect(
            detachedConstrainedHosting.view.fittingSize.width <= 360.5 && detachedConstrainedHosting.view.fittingSize.height <= 300.5,
            "Detached CaptionPopoverView fits within 360x300 with banners and alerts active (got \(detachedConstrainedHosting.view.fittingSize))"
        )

        // ViewModel action helpers
        vm.dismissShareRotationNotice()
        vm.dismissAlert()
        coordinator.speechRecognitionDidEncounterIssue(
            channelName: "caller",
            kind: .speechPermissionDenied,
            message: "Speech permission required"
        )
        expectEqual(vm.alertAction, .speechRecognition, "Alert action reflects speech permission")
        vm.retryAlertAction() // Safe no-op when !isStarted, verifies ViewModel forwarding compiles & runs cleanly
    }

    // MARK: - 12. Wave 2: Coordinator State Machine, Scoped Alerts & Speech/Audio Errors

    static func testWave2CoordinatorStateAlertsAndL10n() async {
        let suiteName = "com.callcaption.wave2.state.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            expect(false, "Failed to create isolated UserDefaults suite")
            return
        }
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let manager = LiveShareManager.shared
        manager.stopSharingSynchronously()
        defer {
            manager.stopSharingSynchronously()
            PermissionHelper.shared.updateAudioCaptureState(.unknown)
        }

        let coordinator = CaptionCoordinator(defaults: defaults, liveShareManager: manager)
        defer { coordinator.stop() }
        let vm = coordinator.viewModel

        // 1. Silent-tap deniedSilenceDetected alert preserved across recoverEnginesIfNeeded() until restored
        PermissionHelper.shared.updateAudioCaptureState(.deniedSilenceDetected)
        coordinator.audioCaptureDidDetectDeniedTapPermission()
        await expectEventually("Denied tap raises .audioCapture alert", timeout: 1.0) {
            vm.alertAction == .audioCapture
        }
        expect(vm.showAlertRetryAction, "Denied tap alert offers retry")
        expect(!coordinator.isAudioCapturing && !vm.isAudioCapturing, "Denied tap marks audio capturing off")

        coordinator.recoverEnginesIfNeeded()
        await settleMain()
        expectEqual(vm.alertAction, .audioCapture, "recoverEnginesIfNeeded preserves deniedSilenceDetected tap alert")
        expect(!vm.isAudioCapturing, "recoverEnginesIfNeeded keeps isAudioCapturing == false while tap denied")

        coordinator.audioCaptureDidRecoverTap()
        await settleMain()
        expectEqual(vm.alertAction, .audioCapture, "audioCaptureDidRecoverTap preserves alert while PermissionHelper stays deniedSilenceDetected")

        PermissionHelper.shared.updateAudioCaptureState(.active)
        coordinator.audioCaptureDidRestoreTapPermission()
        await expectEventually("audioCaptureDidRestoreTapPermission clears tap alert", timeout: 1.0) {
            vm.alertMessage == nil
        }
        expectEqual(vm.alertAction, .none, "Alert action resets to .none after tap restore")
        expect(!vm.showAlertRetryAction, "Retry action clears with tap alert")

        coordinator.audioCaptureDidRecoverTap()
        await settleMain()
        expect(!coordinator.isAudioCapturing && !vm.isAudioCapturing, "audioCaptureDidRecoverTap reconciles isAudioCapturing cleanly")

        // 2. Scope isolation: .systemAudioCapture vs .microphoneCapture
        coordinator.audioCaptureDidDetectDeniedMicPermission()
        await expectEventually("Denied mic raises .microphone alert", timeout: 1.0) {
            vm.alertAction == .microphone
        }
        expect(vm.showAlertRetryAction, "Denied mic alert offers retry")

        coordinator.audioCaptureDidRestoreTapPermission()
        await settleMain()
        expectEqual(vm.alertAction, .microphone, "Restoring tap permission does NOT clear .microphoneCapture scope")

        coordinator.audioCaptureDidDetectDeniedTapPermission()
        await expectEventually(".systemAudioCapture outranks .microphoneCapture", timeout: 1.0) {
            vm.alertAction == .audioCapture
        }

        coordinator.audioCaptureDidRestoreMic()
        await settleMain()
        expectEqual(vm.alertAction, .audioCapture, "Restoring mic does NOT clear .systemAudioCapture scope")

        coordinator.audioCaptureDidRestoreTapPermission()
        await expectEventually("No stale mic or tap alert remains after both scopes restore", timeout: 1.0) {
            vm.alertMessage == nil
        }

        coordinator.audioCaptureDidEncounterMicError(AudioCaptureError.microphoneUnavailable(reason: "Busy"))
        await expectEventually("Mic error routes through .microphoneCapture with .microphone action", timeout: 1.0) {
            vm.alertAction == .microphone
        }
        expect(vm.alertMessage?.contains("Busy") == true, "Mic error preserves reason string")
        coordinator.audioCaptureDidRestoreMic()
        await expectEventually("audioCaptureDidRestoreMic clears mic error scope", timeout: 1.0) {
            vm.alertMessage == nil
        }

        // AudioCaptureError classification & localization
        let micErrors: [AudioCaptureError] = [
            .microphonePermissionDenied,
            .microphoneUnavailable(reason: nil),
            .microphoneUnavailable(reason: "Hardware busy")
        ]
        for err in micErrors {
            expect(err.isMicrophoneError, "Expected isMicrophoneError == true for \(err)")
            expect(!err.localizedDescription.isEmpty, "Non-empty description for \(err)")
        }
        let sysErrors: [AudioCaptureError] = [
            .pidResolutionFailed(-1),
            .tapPermissionRequired(-60005),
            .aggregateDeviceFailed(-1),
            .unsupportedTapFormat(-1),
            .ioProcCreationFailed(-1),
            .deviceStartFailed(-1)
        ]
        for err in sysErrors {
            expect(!err.isMicrophoneError, "Expected isMicrophoneError == false for \(err)")
            expect(!err.localizedDescription.isEmpty, "Non-empty description for \(err)")
        }

        // 3. .speechAuth clearing on mic disable / language change & .unsupported non-retryable alert
        coordinator.setConversationalMode(true)
        coordinator.speechRecognitionDidEncounterIssue(
            channelName: "mic",
            kind: .speechPermissionDenied,
            message: "Mic speech denied"
        )
        await expectEventually("Speech permission issue raises .speechRecognition", timeout: 1.0) {
            vm.alertAction == .speechRecognition
        }
        expect(vm.showAlertRetryAction, "Speech permission issue allows retry")

        coordinator.setConversationalMode(false)
        await expectEventually("Disabling conversational mode clears mic .speechAuth alert", timeout: 1.0) {
            vm.alertMessage == nil
        }

        coordinator.speechRecognitionDidEncounterIssue(
            channelName: "caller",
            kind: .dictationDisabled,
            message: "Enable Dictation in Keyboard settings"
        )
        await expectEventually("Dictation issue routes to .dictation action", timeout: 1.0) {
            vm.alertAction == .dictation
        }
        expect(vm.showAlertRetryAction, "Dictation issue allows retry")

        coordinator.setCallerLanguage("fr")
        await expectEventually("Changing caller language clears stale caller .speechAuth alert", timeout: 1.0) {
            vm.alertMessage == nil
        }

        coordinator.speechRecognitionDidEncounterIssue(
            channelName: "caller",
            kind: .unsupportedLocale,
            message: "Selected language pair is unsupported"
        )
        await expectEventually("Unsupported locale still displays informational alert message", timeout: 1.0) {
            vm.alertMessage != nil
        }
        expectEqual(vm.alertAction, .none, "Unsupported locale sets actionType to .none")
        expect(!vm.showAlertRetryAction, "Unsupported locale disables retry button (showAlertRetryAction == false)")
        coordinator.speechRecognitionDidClearAuthError(channelName: "caller")
        await expectEventually("Clearing caller speech auth dismisses unsupported locale alert", timeout: 1.0) {
            vm.alertMessage == nil
        }
    }

    // MARK: - 13. Wave 2: Live Share Manager States & Web Receiver HTML Contracts

    static func testWave2LiveShareAndWebUIContracts() async {
        let manager = LiveShareManager.shared
        manager.stopSharingSynchronously()
        manager.clearHistoryForPrivacy()
        defer {
            manager.stopSharingSynchronously()
            manager.clearHistoryForPrivacy()
        }

        // retryTunnel() when !isSharing must keep isTunnelStarting == false
        manager.retryTunnel()
        await settleMain()
        await graceWindow(milliseconds: 25)
        expect(!manager.isSharing, "retryTunnel does not start sharing when !isSharing")
        expect(!manager.isTunnelStarting, "retryTunnel leaves isTunnelStarting == false when !isSharing")
        expect(manager.serverError == nil, "serverError defaults to nil when idle")
        expect(!manager.lanIPUnavailable, "lanIPUnavailable defaults to false when idle")
        expect(!manager.publicLinkRotated, "publicLinkRotated defaults to false when idle")
        manager.acknowledgePublicLinkRotation()
        expect(!manager.publicLinkRotated, "acknowledgePublicLinkRotation keeps publicLinkRotated == false when idle")

        // Start loopback Live Share session and verify ReceiverWebAppHTML + ?viewer= polling
        manager.startSharing(
            allowLAN: false,
            useExternalTunnel: false,
            shareBothSpeakers: true,
            foreignLanguageCode: "ar",
            mainLanguageCode: "en"
        )

        var localURL: URL? = nil
        _ = await waitUntil(timeout: 3.0) {
            if let url = manager.localShareURL, manager.isSharing {
                localURL = url
                return true
            }
            return false
        }

        guard let url = localURL,
              let host = url.host,
              let port = url.port,
              let fragment = url.fragment,
              let crypto = LiveShareCrypto(keyFragment: fragment) else {
            expect(false, "LiveShareManager failed to start loopback session for Wave 2 tests")
            return
        }

        let token = url.path.split(separator: "/").last.map(String.init) ?? ""
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4.0
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        do {
            let (htmlData, htmlResp) = try await session.data(from: URL(string: "http://\(host):\(port)/s/\(token)")!)
            expectEqual((htmlResp as? HTTPURLResponse)?.statusCode ?? 0, 200, "Receiver HTML request returns 200")
            let html = String(data: htmlData, encoding: .utf8) ?? ""

            expect(html.contains("viewport-fit=cover"), "Receiver HTML enables viewport-fit=cover")
            expect(html.contains("env(safe-area-inset-bottom"), "Receiver HTML applies safe-area-inset-bottom")
            expect(html.contains("function fallbackCopyText(") && html.contains("document.execCommand('copy')"), "Receiver HTML includes execCommand copy fallback")
            expect(html.contains("/api/state?viewer="), "Receiver HTML polling appends ?viewer= viewer ID")
            expect(html.contains("addEventListener('ended'") && html.contains("handleSessionEnded()"), "Receiver HTML handles ended SSE & session end")
            expect(html.contains("dir=\"ltr\"") || html.contains("dir=\"rtl\""), "Receiver HTML sets explicit document dir attribute")
            expect(html.contains("RTL_LANGS.has(base) ? 'rtl' : 'ltr'"), "Receiver HTML includes RTL direction resolution helper")
            expect(
                html.contains("\"statusSessionEnded\"")
                    && html.contains("\"viewersOne\"")
                    && html.contains("\"viewersOther\"")
                    && html.contains("\"speakerHost\""),
                "Receiver HTML injects localized web.* L10N JSON payload"
            )

            // Plain /api/state must not increment activeClientCount
            expectEqual(manager.activeClientCount, 0, "Initial activeClientCount is 0 before clients connect")
            let (plainData, plainResp) = try await session.data(from: URL(string: "http://\(host):\(port)/s/\(token)/api/state")!)
            expectEqual((plainResp as? HTTPURLResponse)?.statusCode ?? 0, 200, "Plain /api/state returns 200")
            _ = try crypto.open(plainData, expectedType: "state")
            expectEqual(manager.activeClientCount, 0, "Plain /api/state without ?viewer= keeps activeClientCount at 0")

            // ?viewer= polling request registers polling viewer cleanly
            let (pollData, pollResp) = try await session.data(from: URL(string: "http://\(host):\(port)/s/\(token)/api/state?viewer=poll_viewer_1")!)
            expectEqual((pollResp as? HTTPURLResponse)?.statusCode ?? 0, 200, "?viewer= polling /api/state returns 200")
            _ = try crypto.open(pollData, expectedType: "state")
            expectEqual(manager.activeClientCount, 1, "Polling /api/state?viewer= registers active viewer")

            // Invalid viewer query value is ignored safely
            let (_, badViewerResp) = try await session.data(from: URL(string: "http://\(host):\(port)/s/\(token)/api/state?viewer=bad%20id%21")!)
            expectEqual((badViewerResp as? HTTPURLResponse)?.statusCode ?? 0, 200, "Invalid ?viewer= still serves /api/state safely")
            expectEqual(manager.activeClientCount, 1, "Invalid ?viewer= does not increment activeClientCount")
        } catch {
            expect(false, "Wave 2 Live Share loopback HTTP check threw error: \(error)")
        }

        manager.stopSharingSynchronously()
        expect(!manager.isSharing && !manager.isTunnelStarting, "stopSharingSynchronously resets LiveShareManager state")
        expectEqual(manager.activeClientCount, 0, "stopSharingSynchronously clears activeClientCount")
        expect(!manager.lanIPUnavailable && !manager.publicLinkRotated, "stopSharingSynchronously resets share flags")

        // CaptionViewModel.retryShare() starts share when idle
        let suiteName = "com.callcaption.wave2.sharevm.\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: suiteName) {
            defaults.set(false, forKey: "shareAllowLAN")
            defaults.set(false, forKey: "shareUseTunnel")
            let coordinator = CaptionCoordinator(defaults: defaults, liveShareManager: manager)
            defer {
                coordinator.stop()
                UserDefaults().removePersistentDomain(forName: suiteName)
            }
            coordinator.viewModel.retryShare()
            await expectEventually("CaptionViewModel.retryShare() starts sharing when previously idle", timeout: 3.0) {
                manager.isSharing
            }
            manager.stopSharingSynchronously()
        } else {
            expect(false, "Failed to create isolated UserDefaults suite for retryShare test")
        }
    }

    // MARK: - 14. Stage 2 Bug Fixes & Regression Guards

    static func testStage2BugFixesAndRegressionGuards() async {
        // 1. Localization (EN/ES .strings, .stringsdict 'many', %ld specifiers, effectiveUILocale, copyTranscript, web HTML)
        let originalResourceBundle = AppL10n.resourceBundle
        let tempEsBundleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CallCaptionSpanishTest-\(UUID().uuidString).bundle", isDirectory: true)
        defer {
            AppL10n.setTestingBundle(nil)
            try? FileManager.default.removeItem(at: tempEsBundleRoot)
        }

        if let esLprojURL = originalResourceBundle.url(forResource: "es", withExtension: "lproj") {
            do {
                let resourcesDir = tempEsBundleRoot
                    .appendingPathComponent("Contents/Resources", isDirectory: true)
                try FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(
                    at: esLprojURL,
                    to: resourcesDir.appendingPathComponent("es.lproj", isDirectory: true)
                )
                if let esBundle = Bundle(url: tempEsBundleRoot) {
                    AppL10n.setTestingBundle(esBundle)
                    expectEqual(
                        AppL10n.string("status.mic_off", fallback: "Mic off"),
                        "Micrófono apagado",
                        "Spanish .strings loads status.mic_off"
                    )
                    expectEqual(
                        AppL10n.format("footer.level_percent.a11y", fallback: "%ld percent", 75),
                        "75 por ciento",
                        "Spanish %ld format renders footer.level_percent.a11y"
                    )
                    expectEqual(
                        AppL10n.plural("share.viewers.a11y", fallbackSingular: "%ld active viewer", fallbackPlural: "%ld active viewers", count: 1),
                        "1 espectador activo",
                        "Spanish .stringsdict formats singular"
                    )
                    let manyStr = AppL10n.plural("share.viewers.a11y", fallbackSingular: "%ld active viewer", fallbackPlural: "%ld active viewers", count: 1_000_000)
                    expect(
                        manyStr.contains("espectadores activos") && !manyStr.contains("%ld"),
                        "Spanish .stringsdict 'many' rule resolves cleanly (got '\(manyStr)')"
                    )
                    let englishNameInEs = SupportedLanguages.item(forCode: "en")?.localizedName ?? ""
                    expect(
                        englishNameInEs.localizedCaseInsensitiveContains("inglés"),
                        "LanguageItem.localizedName uses effectiveUILocale in Spanish (got '\(englishNameInEs)')"
                    )

                    let esSuite = "com.callcaption.stage2.es.\(UUID().uuidString)"
                    if let esDefaults = UserDefaults(suiteName: esSuite) {
                        defer { UserDefaults().removePersistentDomain(forName: esSuite) }
                        let esCoordinator = CaptionCoordinator(defaults: esDefaults, liveShareManager: LiveShareManager.shared)
                        defer { esCoordinator.stop() }
                        esCoordinator.setConversationalMode(true)
                        esCoordinator.callerSpeechDidFinalize(
                            utteranceID: UUID(),
                            original: "Hello",
                            translated: "Hola",
                            isUntranslated: false
                        )
                        esCoordinator.micSpeechDidFinalize(
                            utteranceID: UUID(),
                            original: "Buenos días",
                            translated: "Good morning",
                            isUntranslated: false
                        )
                        await expectEventually("Spanish coordinator receives finalized entries before copyTranscript", timeout: 1.0) {
                            esCoordinator.viewModel.entries.count == 2
                        }
                        let transcript = esCoordinator.copyTranscript()
                        expect(
                            transcript.contains("[Interlocutor] Hola") && transcript.contains("[Tú] Good morning"),
                            "copyTranscript localizes speaker tags in Spanish (got '\(transcript)')"
                        )
                    } else {
                        expect(false, "Failed to create isolated UserDefaults suite for Spanish localization check")
                    }
                } else {
                    expect(false, "Failed to instantiate temporary Spanish Bundle at \(tempEsBundleRoot.path)")
                }
            } catch {
                expect(false, "Failed to prepare temporary Spanish test bundle: \(error)")
            }
        } else {
            expect(false, "Expected es.lproj resource directory in AppL10n.resourceBundle")
        }
        AppL10n.setTestingBundle(nil)

        // 2. Coordinator resume when unstarted, degraded mic tracking, alert dedup, dismissShareError
        let manager = LiveShareManager.shared
        manager.stopSharingSynchronously()
        manager.clearHistoryForPrivacy()
        defer {
            manager.stopSharingSynchronously()
            manager.clearHistoryForPrivacy()
        }

        let suiteName = "com.callcaption.stage2.coord.\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: suiteName) {
            defer { UserDefaults().removePersistentDomain(forName: suiteName) }
            let coordinator = CaptionCoordinator(defaults: defaults, liveShareManager: manager)
            defer { coordinator.stop() }

            // pause/resume on unstarted coordinator must NOT force-start audio engines
            coordinator.pause()
            coordinator.resume()
            expect(!coordinator.isPaused, "resume() clears isPaused flag")
            expect(!coordinator.hasStarted && !coordinator.isAudioCapturing, "resume() preserves unstarted state without force-starting capture")

            // Unstarted coordinator ignores tap recovery and keeps isMicCapturing false when not in conversational mode
            coordinator.setConversationalMode(false)
            coordinator.audioCaptureDidRecoverTap()
            coordinator.audioCaptureDidRestoreMic()
            expect(!coordinator.isAudioCapturing && !coordinator.isMicCapturing, "Unstarted coordinator ignores spurious tap/mic recovery callbacks")

            // Alert dismissal deduplication & change reset
            coordinator.speechRecognitionDidEncounterAuthError(message: "Auth denied")
            await expectEventually("Alert presents on first error", timeout: 1.0) {
                coordinator.viewModel.alertMessage != nil
            }
            coordinator.dismissPresentedAlert()
            await expectEventually("dismissPresentedAlert() clears alertMessage", timeout: 1.0) {
                coordinator.viewModel.alertMessage == nil
            }
            coordinator.speechRecognitionDidEncounterAuthError(message: "Auth denied")
            await settleMain()
            expect(coordinator.viewModel.alertMessage == nil, "Identical alert stays suppressed after dismiss until state resets or message changes")
            coordinator.speechRecognitionDidEncounterAuthError(message: "Dictation is disabled in System Settings")
            await expectEventually("Different alert message replaces suppressed dismissal cleanly", timeout: 1.0) {
                coordinator.viewModel.alertMessage != nil
            }
        } else {
            expect(false, "Failed to create isolated UserDefaults suite for Stage 2 coordinator check")
        }

        // 3. LiveShareManager: displayLANURL vs effectiveShareURL, SSE+polling viewer dedup, partial ID mismatch, HTML contracts
        // Under CALLCAPTION_TEST=1, launchSSHTunnelOnQueue skips spawning /usr/bin/ssh while preserving tunnel-starting state.
        manager.startSharing(
            allowLAN: false,
            useExternalTunnel: true,
            shareBothSpeakers: true,
            foreignLanguageCode: "es",
            mainLanguageCode: "en"
        )
        await expectEventually("LiveShareManager starts loopback listener with tunnel pending under CALLCAPTION_TEST=1", timeout: 3.0) {
            manager.localShareURL != nil && manager.isSharing
        }
        expect(manager.isTunnelStarting, "isTunnelStarting is true while waiting for tunnel under CALLCAPTION_TEST=1")
        expect(manager.publicShareURL == nil, "publicShareURL remains nil without spawning /usr/bin/ssh under CALLCAPTION_TEST=1")
        expect(manager.displayLANURL == nil, "displayLANURL is nil when allowLAN == false")
        expect(manager.effectiveShareURL == nil, "effectiveShareURL is nil while waiting for tunnel when allowLAN == false && useExternalTunnel == true")
        manager.stopSharingSynchronously()
        expect(!manager.isSharing && !manager.isTunnelStarting, "stopSharingSynchronously cleanly stops tunnel-pending session")

        manager.startSharing(
            allowLAN: false,
            useExternalTunnel: false,
            shareBothSpeakers: true,
            foreignLanguageCode: "es",
            mainLanguageCode: "en"
        )
        var localOnlyURL: URL? = nil
        _ = await waitUntil(timeout: 3.0) {
            if let u = manager.localShareURL, manager.isSharing {
                localOnlyURL = u
                return true
            }
            return false
        }
        expect(manager.displayLANURL == nil, "displayLANURL stays nil for loopback-only session")
        expectEqual(manager.effectiveShareURL, localOnlyURL, "effectiveShareURL exposes loopback localURL when tunnel is disabled")

        if let url = localOnlyURL,
           let host = url.host,
           let port = url.port,
           let fragment = url.fragment,
           let crypto = LiveShareCrypto(keyFragment: fragment) {
            let token = url.path.split(separator: "/").last.map(String.init) ?? ""
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 4.0
            let session = URLSession(configuration: cfg)
            defer { session.invalidateAndCancel() }

            // Check HTML regression fixes
            if let (htmlData, _) = try? await session.data(from: URL(string: "http://\(host):\(port)/s/\(token)")!) {
                let html = String(data: htmlData, encoding: .utf8) ?? ""
                expect(html.contains("<h1 class=\"brand-title\">"), "Web UI uses semantic <h1> for brand title")
                expect(html.contains("<h2 class=\"empty-state-title\">"), "Web UI uses semantic <h2> for empty state")
                expect(html.contains("class=\"status-pill connecting\""), "Initial status pill starts in connecting state rather than live green")
                expect(html.contains("overflow-x: clip;") && !html.contains("overflow-y: auto;"), "Sticky header CSS avoids overflow-y: auto on html/body")
                expect(html.contains("prefers-contrast: more"), "Web UI defines high-contrast media query")
                expect(html.contains("errorCryptoUnavailable") && html.contains("copyCopiedAnnouncement"), "Web UI injects WebCrypto and copy announcement strings")
                expect(!html.contains("MAX_CONSECUTIVE_POLL_FAILURES"), "Web polling recovers across transient blips instead of terminating permanently")
                expect(
                    html.contains("lines.join('\\n\\n')") && html.contains("`[${speaker}] ${trans}\\n(${orig})`"),
                    "Web copy script preserves escaped JS newlines in emitted HTML"
                )
                if let scriptStart = html.range(of: "<script>"),
                   let scriptEnd = html.range(of: "</script>", range: scriptStart.upperBound..<html.endIndex),
                   let jsContext = JSContext() {
                    let scriptBody = String(html[scriptStart.upperBound..<scriptEnd.lowerBound])
                    var syntaxError: String?
                    jsContext.exceptionHandler = { _, exc in
                        syntaxError = exc?.toString()
                    }
                    _ = jsContext.objectForKeyedSubscript("Function")?.construct(withArguments: [scriptBody])
                    expect(syntaxError == nil, "Rendered Live Share inline script parses without JS SyntaxError (got: \(syntaxError ?? "none"))")
                } else {
                    expect(false, "Rendered Live Share HTML contains parseable inline <script>")
                }
            } else {
                expect(false, "Failed to fetch Stage 2 HTML over loopback")
            }

            // Connect raw SSE socket with ?viewer=dup_viewer_1 and verify polling with same ID does not double-count
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            if fd >= 0 {
                defer { Darwin.close(fd) }
                let tv = timeval(tv_sec: 3, tv_usec: 0)
                var mTv = tv
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &mTv, socklen_t(MemoryLayout<timeval>.size))
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = in_port_t(UInt16(port).bigEndian)
                inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
                let connected = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                    }
                }
                if connected {
                    let req = "GET /s/\(token)/events?viewer=dup_viewer_1 HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: keep-alive\r\n\r\n"
                    _ = req.withCString { ptr in Darwin.send(fd, ptr, Int(strlen(ptr)), 0) }
                    await expectEventually("SSE ?viewer=dup_viewer_1 registers 1 viewer", timeout: 2.0) {
                        manager.activeClientCount == 1
                    }
                    _ = try? await session.data(from: URL(string: "http://\(host):\(port)/s/\(token)/api/state?viewer=dup_viewer_1")!)
                    expectEqual(manager.activeClientCount, 1, "Polling same ?viewer=dup_viewer_1 deduplicates against active SSE client")
                    _ = try? await session.data(from: URL(string: "http://\(host):\(port)/s/\(token)/api/state?viewer=other_viewer_2")!)
                    expectEqual(manager.activeClientCount, 2, "Separate polling ?viewer=other_viewer_2 increments count to 2")
                } else {
                    expect(false, "Failed to connect raw loopback SSE socket for ?viewer= dedup check")
                }
            } else {
                expect(false, "Failed to allocate raw loopback socket for ?viewer= dedup check")
            }

            // Partial ID mismatch guard: finalizing idA must not wipe active partial idB
            let idA = UUID()
            let idB = UUID()
            manager.broadcastCaption(
                speaker: "Caller",
                original: "Partial A",
                translated: "Partial A",
                sourceLangCode: "en",
                targetLangCode: "en",
                isFinal: false,
                utteranceID: idA
            )
            manager.broadcastCaption(
                speaker: "Caller",
                original: "Partial B",
                translated: "Partial B",
                sourceLangCode: "en",
                targetLangCode: "en",
                isFinal: false,
                utteranceID: idB
            )
            manager.broadcastCaption(
                speaker: "Caller",
                original: "Final A",
                translated: "Final A",
                sourceLangCode: "en",
                targetLangCode: "en",
                isFinal: true,
                utteranceID: idA
            )
            if let (stateData, _) = try? await session.data(from: URL(string: "http://\(host):\(port)/s/\(token)/api/state")!),
               let plain = try? crypto.open(stateData, expectedType: "state"),
               let json = String(data: plain, encoding: .utf8) {
                expect(json.contains(idB.uuidString) && json.contains("Final A"), "Finalizing utterance A preserves newer live partial B")
            } else {
                expect(false, "Failed to fetch and decrypt /api/state for partial ID mismatch guard")
            }
        } else {
            expect(false, "Failed to start loopback-only LiveShareManager session for Stage 2 checks")
        }
        manager.stopSharingSynchronously()

        // 4. TranslationEngine non-blocking timeout & final cache preservation across partial clears
        let engine = TranslationEngine.shared
        await engine.resetForTesting()
        await engine.setTimeoutForTesting(0.06)
        await engine.setTranslatorForTesting { text, _, _, _ in
            if text == "hang" {
                try? await Task.sleep(for: .seconds(1.2))
            }
            return "TX_\(text)"
        }
        let start = Date()
        let timedOut = await engine.translate(text: "hang", sourceCode: "es", targetCode: "en", isFinal: false)
        let elapsed = Date().timeIntervalSince(start)
        expect(timedOut == nil && elapsed < 0.75, "Translation timeout returns promptly without waiting for 1.2s hung task (elapsed \(String(format: "%.2f", elapsed))s)")
        // Reset cooldown for es->en and immediately verify mutex is unlocked even while "hang" detached task still sleeps (1.2s)
        await engine.resetFailureCooldown(sourceCode: "es", targetCode: "en")
        let fastStart = Date()
        let quickResult = await engine.translate(text: "fast", sourceCode: "es", targetCode: "en", isFinal: true)
        let fastElapsed = Date().timeIntervalSince(fastStart)
        expectEqual(quickResult, "TX_fast", "Mutex is immediately unlocked for subsequent translation after timeout")
        expect(fastElapsed < 0.75, "Subsequent translation did not block behind 1.2s timed-out task (elapsed \(String(format: "%.2f", fastElapsed))s)")
        await engine.clearCache(invalidateFinals: false)
        expectEqual(await engine.cachedEntryCountForTesting(), 1, "clearCache(invalidateFinals: false) preserves final cache entries")
        await engine.clearCache(invalidateFinals: true)
        expectEqual(await engine.cachedEntryCountForTesting(), 0, "clearCache(invalidateFinals: true) clears final cache entries")
        await engine.resetForTesting()

        // 5. SingleSpeechChannel Spanish/multilingual ITN guard & AudioCaptureError
        expect(
            SingleSpeechChannel.isLikelyInverseTextNormalizationForTesting(
                previous: "ciento veintitrés",
                updated: "123"
            ),
            "Spanish number ITN rewrite recognized cleanly"
        )
        expect(
            !SingleSpeechChannel.isLikelyInverseTextNormalizationForTesting(
                previous: "ciento veintitrés",
                updated: "adios amigo"
            ),
            "Non-numeric Spanish rewrite rejected by ITN guard"
        )
        let tapErr = AudioCaptureError.processTapFailed(-50)
        expect(
            !tapErr.localizedDescription.isEmpty && !tapErr.localizedDescription.contains("%d") && !tapErr.localizedDescription.contains("%ld"),
            "AudioCaptureError.processTapFailed formats localized message without raw format specifiers"
        )

        // 6. Regional speech locale fallback (e.g. es-CO installed while es-ES is not)
        let mockEsMap: [String: Locale] = [
            "es-419": Locale(identifier: "es-419"),
            "es-cl": Locale(identifier: "es-CL"),
            "es-co": Locale(identifier: "es-CO"),
            "es-es": Locale(identifier: "es-ES"),
            "es-mx": Locale(identifier: "es-MX")
        ]
        let esCandidatesDefault = SupportedLanguages.candidateLocales(
            forNormalizedCode: "es",
            base: "es",
            defaultLocaleId: "es-ES",
            preferredLanguages: ["en-US"],
            currentRegion: "US",
            availableLocaleMap: mockEsMap
        )
        let chosenCO = SupportedLanguages.selectBestLocale(candidates: esCandidatesDefault) { loc in
            let id = loc.identifier.lowercased()
            return (supported: true, onDevice: id == "es-co" || id == "es-419", available: id == "es-co" || id == "es-419")
        }
        expectEqual(chosenCO?.identifier, "es-CO", "Falls back to installed es-CO when es-ES lacks on-device support")

        let esCandidatesStaleES = SupportedLanguages.candidateLocales(
            forNormalizedCode: "es-es",
            base: "es",
            defaultLocaleId: "es-ES",
            preferredLanguages: ["en-US"],
            currentRegion: nil,
            availableLocaleMap: mockEsMap
        )
        let chosenFromStale = SupportedLanguages.selectBestLocale(candidates: esCandidatesStaleES) { loc in
            let id = loc.identifier.lowercased()
            return (supported: true, onDevice: id == "es-co", available: id == "es-co")
        }
        expectEqual(chosenFromStale?.identifier, "es-CO", "Revalidating stale es-ES resolves installed sibling es-CO")

        let esCandidatesPrefMX = SupportedLanguages.candidateLocales(
            forNormalizedCode: "es",
            base: "es",
            defaultLocaleId: "es-ES",
            preferredLanguages: ["en-US", "es-MX"],
            currentRegion: "US",
            availableLocaleMap: mockEsMap
        )
        let chosenPrefMX = SupportedLanguages.selectBestLocale(candidates: esCandidatesPrefMX) { loc in
            let id = loc.identifier.lowercased()
            return (supported: true, onDevice: id == "es-co" || id == "es-mx", available: true)
        }
        expectEqual(chosenPrefMX?.identifier, "es-MX", "Prefers user's preferred dialect es-MX when installed")

        let mockZhMap: [String: Locale] = [
            "zh-cn": Locale(identifier: "zh-CN"),
            "zh-tw": Locale(identifier: "zh-TW")
        ]
        let zhTWCandidates = SupportedLanguages.candidateLocales(
            forNormalizedCode: "zh-tw",
            base: "zh",
            defaultLocaleId: "zh-CN",
            preferredLanguages: ["zh-CN"],
            currentRegion: "CN",
            availableLocaleMap: mockZhMap
        )
        expect(
            !zhTWCandidates.contains(where: { $0.identifier.lowercased() == "zh-cn" }),
            "Explicit Traditional Chinese zh-tw does not fall back to Simplified zh-cn"
        )

        // Verify live host resolution: if any Spanish dialect on this Mac supports on-device recognition, bestLocale("es") picks one with on-device support
        let anySpanishOnDevice = SFSpeechRecognizer.supportedLocales().contains { loc in
            loc.identifier.lowercased().hasPrefix("es")
                && (SFSpeechRecognizer(locale: loc)?.supportsOnDeviceRecognition == true)
        }
        if anySpanishOnDevice {
            SupportedLanguages.invalidateLocaleResolutionCache()
            let resolvedEs = SupportedLanguages.bestLocale(forCode: "es")
            let resolvedRec = SFSpeechRecognizer(locale: resolvedEs)
            expect(
                resolvedRec?.supportsOnDeviceRecognition == true,
                "bestLocale(\"es\") resolves an on-device supported Spanish dialect (resolved: \(resolvedEs.identifier))"
            )
        }
    }

    // MARK: - 15. Stage 3: Comprehensive Audit Fixes, L10n Parity & Web Receiver Behavioral JS Tests

    static func extractFormatSpecifiers(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:ld|d|@|f|s)") else {
            return []
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    static func testStage3ComprehensiveAuditFixesAndParity() async {
        // 1. Automated full EN/ES localization parity test
        let resBundle = AppL10n.resourceBundle
        let enStringsURL = resBundle.url(forResource: "en", withExtension: "lproj")?.appendingPathComponent("Localizable.strings")
            ?? URL(fileURLWithPath: "Resources/en.lproj/Localizable.strings")
        let esStringsURL = resBundle.url(forResource: "es", withExtension: "lproj")?.appendingPathComponent("Localizable.strings")
            ?? URL(fileURLWithPath: "Resources/es.lproj/Localizable.strings")

        let enDict = (NSDictionary(contentsOf: enStringsURL) as? [String: String]) ?? [:]
        let esDict = (NSDictionary(contentsOf: esStringsURL) as? [String: String]) ?? [:]

        expect(enDict.count >= 195, "English Localizable.strings loads all expected keys (got \(enDict.count))")
        expectEqual(enDict.count, esDict.count, "EN and ES Localizable.strings have identical key counts")
        let enKeys = Set(enDict.keys)
        let esKeys = Set(esDict.keys)
        let missingInEs = enKeys.subtracting(esKeys).sorted()
        let missingInEn = esKeys.subtracting(enKeys).sorted()
        expect(missingInEs.isEmpty, "No keys missing in es.lproj/Localizable.strings (missing: \(missingInEs))")
        expect(missingInEn.isEmpty, "No extra/unmatched keys in es.lproj/Localizable.strings (extra: \(missingInEn))")

        var emptyValueKeys: [String] = []
        var specifierMismatches: [String] = []
        for key in enKeys.intersection(esKeys).sorted() {
            let enVal = (enDict[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let esVal = (esDict[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if enVal.isEmpty || esVal.isEmpty {
                emptyValueKeys.append(key)
            }
            let enSpecs = extractFormatSpecifiers(from: enVal)
            let esSpecs = extractFormatSpecifiers(from: esVal)
            if enSpecs != esSpecs {
                specifierMismatches.append("\(key): en=\(enSpecs) vs es=\(esSpecs)")
            }
        }
        expect(emptyValueKeys.isEmpty, "All EN and ES localized strings are non-empty (empty: \(emptyValueKeys))")
        expect(specifierMismatches.isEmpty, "All EN and ES localized strings have identical format specifiers (mismatches: \(specifierMismatches))")
        expectEqual(enDict["status.tunnel_error"], "Link Error", "EN status.tunnel_error updated to Link Error")
        expectEqual(esDict["status.tunnel_error"], "Error de enlace", "ES status.tunnel_error updated to Error de enlace")
        expect(
            enDict["web.empty.link_error"]?.contains("#k=") == true && esDict["web.empty.link_error"]?.contains("#k=") == true,
            "EN and ES web.empty.link_error reference #k= key fragment"
        )

        // 2. TranslationEngine runWithTimeout: onCancel fires 0 times on success, 1 time on timeout
        let engine = TranslationEngine.shared
        await engine.resetForTesting()
        let successCancelCount = OSAllocatedUnfairLock(initialState: 0)
        let successOut = await engine.testRunWithTimeoutForTesting(
            seconds: 0.04,
            onCancel: {
                successCancelCount.withLock { $0 += 1 }
            },
            operation: {
                return "OK_FAST"
            }
        )
        // Sleep past the 40ms timer deadline to prove cancelled timerTask never triggers onCancel
        await graceWindow(milliseconds: 80)
        expectEqual(successOut, "OK_FAST", "testRunWithTimeoutForTesting returns operation result on success")
        expectEqual(successCancelCount.withLock { $0 }, 0, "onCancel fires 0 times when operation succeeds before timeout")

        let timeoutCancelCount = OSAllocatedUnfairLock(initialState: 0)
        let timeoutOut: String? = await engine.testRunWithTimeoutForTesting(
            seconds: 0.05,
            onCancel: {
                timeoutCancelCount.withLock { $0 += 1 }
            },
            operation: {
                try await Task.sleep(for: .milliseconds(500))
                return "LATE"
            }
        )
        expect(timeoutOut == nil, "testRunWithTimeoutForTesting returns nil when operation times out")
        expectEqual(timeoutCancelCount.withLock { $0 }, 1, "onCancel fires exactly 1 time when operation times out")
        await engine.resetForTesting()

        // 3. SupportedLanguages: item(forCode: "nonexistent") == nil, script-tagged Chinese locale resolution, zh-MO -> zh-hant
        expect(SupportedLanguages.item(forCode: "nonexistent") == nil, "SupportedLanguages.item(forCode: \"nonexistent\") returns nil")
        expect(SupportedLanguages.item(forCode: "") == nil, "SupportedLanguages.item(forCode: \"\") returns nil")
        expectEqual(SupportedLanguages.translationCode(from: "zh-MO"), "zh-hant", "SupportedLanguages.translationCode maps zh-MO to zh-hant")
        expectEqual(SupportedLanguages.translationCode(from: "zh-Hant-MO"), "zh-hant", "SupportedLanguages.translationCode maps zh-Hant-MO to zh-hant")

        let mockChineseMap: [String: Locale] = [
            "zh-cn": Locale(identifier: "zh-CN"),
            "zh-tw": Locale(identifier: "zh-TW"),
            "zh-hk": Locale(identifier: "zh-HK")
        ]
        let zhHantTWCandidates = SupportedLanguages.candidateLocales(
            forCode: "zh-Hant-TW",
            preferredLanguages: ["en-US"],
            currentRegion: "US",
            availableLocaleMap: mockChineseMap
        )
        expectEqual(zhHantTWCandidates.first?.identifier, "zh-TW", "zh-Hant-TW resolves zh-TW first")

        let zhHantUSCandidates = SupportedLanguages.candidateLocales(
            forCode: "zh-Hant-US",
            preferredLanguages: ["en-US"],
            currentRegion: "US",
            availableLocaleMap: mockChineseMap
        )
        expectEqual(zhHantUSCandidates.first?.identifier, "zh-TW", "zh-Hant-US resolves zh-TW first")

        let zhHantHKCandidates = SupportedLanguages.candidateLocales(
            forCode: "zh-Hant-HK",
            preferredLanguages: ["en-US"],
            currentRegion: "US",
            availableLocaleMap: mockChineseMap
        )
        expectEqual(zhHantHKCandidates.first?.identifier, "zh-HK", "zh-Hant-HK resolves zh-HK first")

        let zhPrefHantTWCandidates = SupportedLanguages.candidateLocales(
            forCode: "zh",
            preferredLanguages: ["zh-Hant-TW", "en-US"],
            currentRegion: "US",
            availableLocaleMap: mockChineseMap
        )
        expectEqual(zhPrefHantTWCandidates.first?.identifier, "zh-TW", "Bare zh with preferredLanguage zh-Hant-TW resolves zh-TW first")

        // 4. CaptionCoordinator: multi-reason system auto-pause & swapLanguages() no-op when callerLanguageCode == myLanguageCode
        let coordSuite = "com.callcaption.stage3.coord.\(UUID().uuidString)"
        if let defaults = UserDefaults(suiteName: coordSuite) {
            defer { UserDefaults().removePersistentDomain(forName: coordSuite) }
            let coordinator = CaptionCoordinator(defaults: defaults, liveShareManager: LiveShareManager.shared)
            defer { coordinator.stop() }

            expect(!coordinator.isPaused, "Coordinator starts unpaused")
            coordinator.autoPauseForSystem(reason: .sessionResigned)
            expect(coordinator.isPaused, "autoPauseForSystem(reason: .sessionResigned) pauses coordinator")
            coordinator.autoPauseForSystem(reason: .systemSleep)
            expect(coordinator.isPaused, "Adding .systemSleep keeps coordinator paused")
            coordinator.autoResumeAfterSystem(reason: .systemSleep)
            expect(coordinator.isPaused, "Clearing .systemSleep alone keeps coordinator paused while .sessionResigned remains active")
            coordinator.autoResumeAfterSystem(reason: .sessionResigned)
            expect(!coordinator.isPaused, "Clearing remaining .sessionResigned reason auto-resumes coordinator")

            // swapLanguages() no-op when callerLanguageCode == myLanguageCode
            coordinator.setCallerLanguage("es")
            coordinator.setMyLanguage("es")
            expectEqual(coordinator.viewModel.callerLanguageCode, "es", "Caller language set to es")
            expectEqual(coordinator.viewModel.myLanguageCode, "es", "My language set to es")
            coordinator.speechRecognitionDidEncounterAuthError(channelName: "caller", message: "Test auth alert")
            await expectEventually("Pre-swap alert present", timeout: 1.0) {
                coordinator.viewModel.alertMessage != nil
            }
            coordinator.swapLanguages()
            expectEqual(coordinator.viewModel.callerLanguageCode, "es", "swapLanguages no-op preserves callerLanguageCode")
            expectEqual(coordinator.viewModel.myLanguageCode, "es", "swapLanguages no-op preserves myLanguageCode")
            expect(coordinator.viewModel.alertMessage != nil, "swapLanguages no-op does not clear alerts or reconfigure")
        } else {
            expect(false, "Failed to create isolated UserDefaults suite for Stage 3 coordinator check")
        }

        // 5. LiveShareCrypto.openWithMetadata: expectedType == nil with non-nil minimumSequence rejects unsequenced v1 envelope
        let crypto = LiveShareCrypto()
        if let unsequenced = try? crypto.seal(Data("{\"unseq\":true}".utf8)) {
            expect(
                (try? crypto.openWithMetadata(unsequenced, expectedType: nil, minimumSequence: 1)) == nil,
                "openWithMetadata(expectedType: nil, minimumSequence: 1) rejects unsequenced v1 envelope"
            )
            expect(
                (try? crypto.openWithMetadata(unsequenced, expectedType: nil, minimumSequence: 0)) == nil,
                "openWithMetadata(expectedType: nil, minimumSequence: 0) rejects unsequenced v1 envelope"
            )
            expectEqual(
                try? crypto.openWithMetadata(unsequenced, expectedType: nil, minimumSequence: nil).data,
                Data("{\"unseq\":true}".utf8),
                "openWithMetadata(expectedType: nil, minimumSequence: nil) opens unsequenced v1 envelope"
            )
        } else {
            expect(false, "LiveShareCrypto.seal failed for unsequenced envelope")
        }

        // 6. Behavioral JSContext / DOM tests for the embedded web receiver
        let esHTML = ReceiverWebAppHTML.html(
            forToken: "tok_es_test",
            encryptPayloads: false,
            acceptLanguage: "es-MX,es;q=0.9,en;q=0.8"
        )
        expect(esHTML.contains("<html lang=\"es\" dir=\"ltr\">"), "Accept-Language: es renders <html lang=\"es\" dir=\"ltr\">")
        expect(esHTML.contains("Los subtítulos están en pausa"), "Accept-Language: es injects Spanish emptyPaused string")
        expect(esHTML.contains("La sesión de enlace en vivo finalizó"), "Accept-Language: es injects Spanish emptySessionEnded string")

        if let scriptStart = esHTML.range(of: "<script>"),
           let scriptEnd = esHTML.range(of: "</script>", range: scriptStart.upperBound..<esHTML.endIndex),
           let jsContext = JSContext() {
            let scriptBody = String(esHTML[scriptStart.upperBound..<scriptEnd.lowerBound])
            var jsErrors: [String] = []
            jsContext.exceptionHandler = { _, exc in
                if let msg = exc?.toString() {
                    jsErrors.append(msg)
                }
            }

            let domHarness = """
            function makeClassList(el) {
                return {
                    _set: new Set((el._className || '').split(/\\s+/).filter(Boolean)),
                    _sync() { el._className = Array.from(this._set).join(' '); },
                    add(c) { this._set.add(c); this._sync(); },
                    remove(c) { this._set.delete(c); this._sync(); },
                    toggle(c, force) {
                        const shouldAdd = (force !== undefined) ? !!force : !this._set.has(c);
                        if (shouldAdd) this._set.add(c); else this._set.delete(c);
                        this._sync();
                        return shouldAdd;
                    },
                    contains(c) { return this._set.has(c); }
                };
            }
            function makeElement(tag, id, className) {
                const el = {
                    tagName: (tag || 'DIV').toUpperCase(),
                    id: id || '',
                    _className: className || '',
                    textContent: '',
                    value: '',
                    disabled: false,
                    checked: true,
                    hidden: false,
                    offsetHeight: 0,
                    parentNode: null,
                    children: [],
                    attributes: {},
                    _listeners: {},
                    style: {
                        display: '',
                        position: '',
                        top: '',
                        left: '',
                        width: '',
                        height: '',
                        fontSize: '',
                        opacity: '',
                        _props: {},
                        setProperty(k, v) { this._props[k] = String(v); },
                        getPropertyValue(k) { return this._props[k] || ''; }
                    },
                    setAttribute(k, v) { this.attributes[k] = String(v); },
                    getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attributes, k) ? this.attributes[k] : null; },
                    removeAttribute(k) { delete this.attributes[k]; },
                    appendChild(child) {
                        if (child.parentNode) child.parentNode.removeChild(child);
                        child.parentNode = this;
                        this.children.push(child);
                        return child;
                    },
                    insertBefore(newNode, refNode) {
                        if (newNode.parentNode) newNode.parentNode.removeChild(newNode);
                        newNode.parentNode = this;
                        const idx = this.children.indexOf(refNode);
                        if (idx >= 0) this.children.splice(idx, 0, newNode);
                        else this.children.push(newNode);
                        return newNode;
                    },
                    removeChild(child) {
                        const idx = this.children.indexOf(child);
                        if (idx >= 0) {
                            this.children.splice(idx, 1);
                            child.parentNode = null;
                        }
                        return child;
                    },
                    remove() {
                        if (this.parentNode) this.parentNode.removeChild(this);
                    },
                    contains(target) {
                        if (this === target) return true;
                        for (let i = 0; i < this.children.length; i++) {
                            if (this.children[i].contains(target)) return true;
                        }
                        return false;
                    },
                    matchesSelector(sel) {
                        if (sel.startsWith('.')) return this.classList.contains(sel.slice(1));
                        if (sel === '[data-speaker="Caller"]') return this.getAttribute('data-speaker') === 'Caller';
                        return false;
                    },
                    querySelectorAll(sel) {
                        const out = [];
                        function walk(node) {
                            for (let i = 0; i < node.children.length; i++) {
                                const ch = node.children[i];
                                if (ch.matchesSelector(sel)) out.push(ch);
                                walk(ch);
                            }
                        }
                        walk(this);
                        return out;
                    },
                    querySelector(sel) {
                        return this.querySelectorAll(sel)[0] || null;
                    },
                    addEventListener(type, fn) {
                        if (!this._listeners[type]) this._listeners[type] = [];
                        this._listeners[type].push(fn);
                    },
                    click() {
                        if (this.disabled) return;
                        const list = this._listeners['click'] || [];
                        list.forEach(fn => fn({ stopPropagation() {}, target: this }));
                    },
                    focus() {},
                    select() {},
                    setSelectionRange() {},
                    getBoundingClientRect() { return { top: 0 }; }
                };
                el.classList = makeClassList(el);
                Object.defineProperty(el, 'className', {
                    get() { return this._className; },
                    set(v) { this._className = String(v || ''); this.classList = makeClassList(this); }
                });
                Object.defineProperty(el, 'innerHTML', {
                    get() { return ''; },
                    set(v) {
                        if (v === '') {
                            this.children.forEach(c => { c.parentNode = null; });
                            this.children = [];
                        }
                    }
                });
                Object.defineProperty(el, 'firstElementChild', {
                    get() { return this.children[0] || null; }
                });
                Object.defineProperty(el, 'nextElementSibling', {
                    get() {
                        if (!this.parentNode) return null;
                        const siblings = this.parentNode.children;
                        const idx = siblings.indexOf(this);
                        return (idx >= 0 && idx + 1 < siblings.length) ? siblings[idx + 1] : null;
                    }
                });
                return el;
            }

            const elementsById = {};
            function registerEl(tag, id, className) {
                const el = makeElement(tag, id, className);
                elementsById[id] = el;
                return el;
            }

            const docEl = makeElement('HTML', '', '');
            const bodyEl = makeElement('BODY', '', 'show-orig');
            docEl.appendChild(bodyEl);

            const emptyStateEl = registerEl('DIV', 'empty-state', 'empty-state');
            const emptyTitleEl = makeElement('H2', '', 'empty-state-title');
            emptyTitleEl.textContent = 'Escuchando…';
            emptyStateEl.appendChild(emptyTitleEl);
            bodyEl.appendChild(emptyStateEl);

            bodyEl.appendChild(registerEl('DIV', 'caption-stream', 'caption-stream'));
            bodyEl.appendChild(registerEl('DIV', 'sr-live-announcer', 'sr-only'));
            bodyEl.appendChild(registerEl('DIV', 'conn-pill', 'status-pill connecting'));
            bodyEl.appendChild(registerEl('SPAN', 'conn-label', ''));
            bodyEl.appendChild(registerEl('SPAN', 'viewer-count', 'viewer-count'));
            bodyEl.appendChild(registerEl('DIV', 'autoscroll-pill', 'floating-bottom'));
            bodyEl.appendChild(registerEl('INPUT', 'autoscroll-toggle', ''));
            bodyEl.appendChild(registerEl('BUTTON', 'jump-latest-btn', 'jump-latest-btn'));
            bodyEl.appendChild(registerEl('BUTTON', 'copy-transcript-btn', 'btn'));
            bodyEl.appendChild(registerEl('BUTTON', 'view-mode-btn', 'btn'));
            bodyEl.appendChild(registerEl('BUTTON', 'orig-toggle-btn', 'btn active'));
            bodyEl.appendChild(registerEl('BUTTON', 'font-dec-btn', 'btn'));
            bodyEl.appendChild(registerEl('BUTTON', 'font-inc-btn', 'btn'));

            const storageMap = {};
            var window = globalThis;
            window.scrollY = 0;
            window.innerHeight = 800;
            window.location = { hash: '' };
            window.performance = { now() { return 1000; } };
            window.localStorage = {
                getItem(k) { return Object.prototype.hasOwnProperty.call(storageMap, k) ? storageMap[k] : null; },
                setItem(k, v) { storageMap[k] = String(v); }
            };
            window.matchMedia = function() { return { matches: true }; };
            window.scrollTo = function() {};
            window.addEventListener = function() {};
            window.requestAnimationFrame = function(cb) { cb(); return 1; };
            window.setTimeout = function() { return 1; };
            window.clearTimeout = function() {};
            window.navigator = {};
            window.EventSource = function(url) {
                this.url = url;
                this.readyState = 1;
                this.addEventListener = function() {};
                this.close = function() { this.readyState = 2; };
            };
            window.EventSource.CONNECTING = 0;
            window.EventSource.OPEN = 1;
            window.EventSource.CLOSED = 2;

            var location = window.location;
            var performance = window.performance;
            var navigator = window.navigator;
            var EventSource = window.EventSource;
            var requestAnimationFrame = window.requestAnimationFrame;
            var setTimeout = window.setTimeout;
            var clearTimeout = window.clearTimeout;

            var document = {
                documentElement: docEl,
                scrollingElement: docEl,
                body: bodyEl,
                visibilityState: 'visible',
                getElementById(id) { return elementsById[id] || null; },
                createElement(tag) { return makeElement(tag, '', ''); },
                addEventListener() {},
                getSelection() { return { rangeCount: 0, removeAllRanges() {}, addRange() {} }; },
                execCommand() { return true; }
            };
            """

            _ = jsContext.evaluateScript(domHarness)
            _ = jsContext.evaluateScript(scriptBody)
            expect(jsErrors.isEmpty, "Receiver script executes in DOM harness without errors (errors: \(jsErrors))")

            // Verify initial Spanish empty state
            let initialEmpty = jsContext.evaluateScript("emptyStateLabel.textContent")?.toString() ?? ""
            expectEqual(initialEmpty, "Escuchando…", "Initial receiver empty state localized to Spanish")

            // Test clearEpoch strict monotonicity: advance to 5, render a card, then reject stale clearEpoch 3 (< 5)
            _ = jsContext.evaluateScript("""
                handleCaptionEvent({ id: 'u1', speaker: 'Caller', originalText: 'Hola', translatedText: 'Hello', isFinal: true });
            """)
            expectEqual(jsContext.evaluateScript("streamContainer.children.length")?.toInt32() ?? -1, 1, "1 card rendered before clearEpoch=5")

            _ = jsContext.evaluateScript("handleStatusEvent({ clearEpoch: 5 });")
            expectEqual(jsContext.evaluateScript("lastClearEpoch")?.toInt32() ?? -1, 5, "lastClearEpoch advances to 5")
            expectEqual(jsContext.evaluateScript("streamContainer.children.length")?.toInt32() ?? -1, 0, "clearEpoch=5 clears rendered cards")

            _ = jsContext.evaluateScript("""
                handleCaptionEvent({ id: 'u2', speaker: 'Caller', originalText: 'Dos', translatedText: 'Two', isFinal: true });
            """)
            expectEqual(jsContext.evaluateScript("streamContainer.children.length")?.toInt32() ?? -1, 1, "New card rendered at epoch 5")

            _ = jsContext.evaluateScript("handleStatusEvent({ clearEpoch: 3 });")
            expectEqual(jsContext.evaluateScript("lastClearEpoch")?.toInt32() ?? -1, 5, "Stale clearEpoch=3 (< 5) is rejected")
            expectEqual(jsContext.evaluateScript("streamContainer.children.length")?.toInt32() ?? -1, 1, "Stale clearEpoch=3 does not wipe existing cards")

            _ = jsContext.evaluateScript("handleStatusEvent({ clearEpoch: 5 });")
            expectEqual(jsContext.evaluateScript("streamContainer.children.length")?.toInt32() ?? -1, 1, "Duplicate clearEpoch=5 does not wipe cards")

            // Clear cards with clearEpoch=6 and test emptyPaused & emptySessionEnded states + live card removal on pause (SHARE-8)
            _ = jsContext.evaluateScript("""
                handleCaptionEvent({ id: 'live1', speaker: 'Caller', originalText: 'En curso', translatedText: 'In progress', isFinal: false });
            """)
            expectEqual(jsContext.evaluateScript("liveSlots['Caller'] !== null && liveSlots['Caller'].classList.contains('live')")?.toBool() ?? false, true, "Live slot has .live class before pause")
            expectEqual(jsContext.evaluateScript("streamContainer.children.length")?.toInt32() ?? -1, 2, "Stream has finalized card + live partial card before pause")
            _ = jsContext.evaluateScript("handleStatusEvent({ paused: true });")
            expectEqual(jsContext.evaluateScript("liveSlots['Caller'] === null")?.toBool() ?? false, true, "SHARE-8: pause clears liveSlots['Caller'] to null")
            expectEqual(jsContext.evaluateScript("streamContainer.children.length")?.toInt32() ?? -1, 1, "SHARE-8: pause removes live partial card from DOM while keeping finalized card")

            _ = jsContext.evaluateScript("handleStatusEvent({ clearEpoch: 6 });")
            expectEqual(jsContext.evaluateScript("emptyStateLabel.textContent")?.toString() ?? "", "Los subtítulos están en pausa", "Empty state shows emptyPaused when hostPaused is true")

            _ = jsContext.evaluateScript("handleStatusEvent({ paused: false });")
            expectEqual(jsContext.evaluateScript("emptyStateLabel.textContent")?.toString() ?? "", "Escuchando…", "Resuming restores emptyListening")

            // Test A-/A+ even-step bounds (14..30)
            expectEqual(jsContext.evaluateScript("currentFontSize")?.toInt32() ?? 0, 18, "Default font size starts at 18px")
            _ = jsContext.evaluateScript("for (let i = 0; i < 10; i++) fontDecBtn.click();")
            expectEqual(jsContext.evaluateScript("currentFontSize")?.toInt32() ?? 0, 14, "A- clamps at minimum even bound 14")
            expectEqual(jsContext.evaluateScript("fontDecBtn.disabled")?.toBool() ?? false, true, "A- button disables at 14px")
            expectEqual(jsContext.evaluateScript("fontIncBtn.disabled")?.toBool() ?? true, false, "A+ button remains enabled at 14px")

            _ = jsContext.evaluateScript("fontIncBtn.click(); fontIncBtn.click();")
            expectEqual(jsContext.evaluateScript("currentFontSize")?.toInt32() ?? 0, 18, "Two A+ clicks from 14px return cleanly to 18px")

            _ = jsContext.evaluateScript("for (let i = 0; i < 15; i++) fontIncBtn.click();")
            expectEqual(jsContext.evaluateScript("currentFontSize")?.toInt32() ?? 0, 30, "A+ clamps at maximum even bound 30")
            expectEqual(jsContext.evaluateScript("fontIncBtn.disabled")?.toBool() ?? false, true, "A+ button disables at 30px")
            expectEqual(jsContext.evaluateScript("fontDecBtn.disabled")?.toBool() ?? true, false, "A- button remains enabled at 30px")

            // Test emptySessionEnded empty state
            _ = jsContext.evaluateScript("handleSessionEnded();")
            expectEqual(jsContext.evaluateScript("emptyStateLabel.textContent")?.toString() ?? "", "La sesión de enlace en vivo finalizó", "handleSessionEnded displays Spanish emptySessionEnded")
            expect(jsErrors.isEmpty, "Receiver script encountered no uncaught JS errors across behavioral assertions (errors: \(jsErrors))")
        } else {
            expect(false, "Failed to extract inline <script> from Spanish ReceiverWebAppHTML")
        }
    }

    static func testPublicTunnelCRLFAndGzip() async {
        // 1. CRLF tunnel output line splitting (including \r and \n split across pipe reads)
        var pending = ""
        let lines1 = LiveShareManager.drainCompleteLines(
            from: &pending,
            appending: "Welcome to localhost.run!\r\nhttps://admin.localhost.run/\r\n555d57cc579d01.app.lhr.life tunneled with tls termination, https://555d57cc579d01.app.lhr.life\r"
        )
        expectEqual(lines1.count, 2, "drainCompleteLines extracts 2 complete CRLF lines before trailing \\r")
        expectEqual(lines1[0], "Welcome to localhost.run!", "First CRLF line trimmed cleanly")
        expectEqual(lines1[1], "https://admin.localhost.run/", "Second CRLF line trimmed cleanly")

        let lines2 = LiveShareManager.drainCompleteLines(
            from: &pending,
            appending: "\nOpen your tunnel address:\r\n"
        )
        expectEqual(lines2.count, 2, "drainCompleteLines completes line when \\n arrives in next chunk")
        expectEqual(
            LiveShareManager.extractTunnelURL(from: lines2[0])?.absoluteString,
            "https://555d57cc579d01.app.lhr.life",
            "extractTunnelURL extracts tunnel URL from CRLF-split localhost.run line"
        )
        expectEqual(pending, "", "No leftover partial line remains after trailing CRLF")

        // 2. Accept-Encoding gzip header parsing
        let reqGzip = LiveShareManager.parseHTTPRequest(
            "GET /s/tok HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept-Encoding: br, gzip, deflate\r\n\r\n"
        )
        expect(reqGzip?.acceptsGzip == true, "parseHTTPRequest enables acceptsGzip when gzip is offered")

        let reqNoGzip = LiveShareManager.parseHTTPRequest(
            "GET /s/tok HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept-Encoding: gzip;q=0, br\r\n\r\n"
        )
        expect(reqNoGzip?.acceptsGzip == false, "parseHTTPRequest respects gzip;q=0 opt-out")

        // 3. Gzip compression ratio & lossless round-trip verification on ReceiverWebAppHTML
        let html = ReceiverWebAppHTML.html(forToken: "tok_gz", encryptPayloads: true)
        let rawHTML = Data(html.utf8)
        if let gz = LiveShareManager.gzipCompress(rawHTML) {
            expect(gz.count > 18 && gz.count < 25000, "gzipCompress shrinks 65KB+ ReceiverWebAppHTML under 25KB (actual: \(gz.count))")
            expect(gz[0] == 0x1F && gz[1] == 0x8B && gz[2] == 0x08, "gzip header magic bytes valid")
            let deflateSlice = gz.subdata(in: 10..<(gz.count - 8))
            var decoded = [UInt8](repeating: 0, count: rawHTML.count + 64)
            let decodedCount = deflateSlice.withUnsafeBytes { buf -> Int in
                guard let base = buf.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(&decoded, decoded.count, base, deflateSlice.count, nil, COMPRESSION_ZLIB)
            }
            expectEqual(decodedCount, rawHTML.count, "gzip raw deflate stream decodes back to exact original length")
            expectEqual(Data(decoded.prefix(decodedCount)), rawHTML, "gzip payload round-trips losslessly")
        } else {
            expect(false, "LiveShareManager.gzipCompress returned nil")
        }
    }

    static func testDuringLiveCallMicDetectionAndFloor() async {
        // 1. VPIO 3-channel raw MEMS makeup gain bounds (1ch/2ch and normal line level remain 1.0)
        expectEqual(
            AudioCaptureEngine.computeMultiChannelMakeupGain(noiseFloor: 0.00003, peak: 0.0001, sourceChannels: 1),
            1.0,
            "1ch normal/post-call input never gets makeup gain"
        )
        expectEqual(
            AudioCaptureEngine.computeMultiChannelMakeupGain(noiseFloor: 0.00003, peak: 0.0001, sourceChannels: 2),
            1.0,
            "2ch stereo input never gets makeup gain"
        )
        expectEqual(
            AudioCaptureEngine.computeMultiChannelMakeupGain(noiseFloor: 0.002, peak: 0.05, sourceChannels: 4),
            1.0,
            "Multi-channel interface with normal floor stays at 1.0x"
        )
        let vpioGain = AudioCaptureEngine.computeMultiChannelMakeupGain(noiseFloor: 0.00003, peak: 0.0001, sourceChannels: 3)
        expect(abs(vpioGain - 20.0) < 0.01, "3ch VPIO raw MEMS low floor applies 20x makeup gain (got \(vpioGain))")
        let clampedGain = AudioCaptureEngine.computeMultiChannelMakeupGain(noiseFloor: 0.00003, peak: 0.1, sourceChannels: 3)
        expect(clampedGain <= 6.51, "3ch makeup gain clamps cleanly below peak ceiling to avoid clipping (got \(clampedGain))")

        func make16kMonoTone(rmsAmplitude: Float, frames: AVAudioFrameCount = 1600) -> AVAudioPCMBuffer {
            let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
            buf.frameLength = frames
            let peak = rmsAmplitude * sqrt(2.0)
            if let ch = buf.floatChannelData?[0] {
                for i in 0..<Int(frames) {
                    ch[i] = peak * sin(Float(i) * (2.0 * Float.pi * 440.0 / 16000.0))
                }
            }
            return buf
        }

        final class SpyCaptureDelegate: AudioCaptureDelegate, @unchecked Sendable {
            let lock = OSAllocatedUnfairLock(initialState: (callerCount: 0, micCount: 0, lastMicRMS: Float(0)))
            func audioCaptureDidOutputCallerAudio(pcmBuffer: AVAudioPCMBuffer) {
                lock.withLock { $0.callerCount += 1 }
            }
            func audioCaptureDidOutputMicAudio(pcmBuffer: AVAudioPCMBuffer) {
                let n = Int(pcmBuffer.frameLength)
                var rms: Float = 0
                if let ptr = pcmBuffer.floatChannelData?[0], n > 0 {
                    rms = AudioCaptureEngine.computeRMS(samples: ptr, count: n)
                }
                let finalRMS = rms
                lock.withLock {
                    $0.micCount += 1
                    $0.lastMicRMS = finalRMS
                }
            }
            func audioCaptureDidEncounterError(_ error: Error) {}
            func audioCaptureDidUpdateLevels(callerLevel: Float, micLevel: Float) {}
            func audioCaptureDidDetectDeniedTapPermission() {}
            func audioCaptureDidRestoreTapPermission() {}
        }

        // 2. Open-speaker live call overlap: echo rejected, conversational voice (0.015 RMS) passes while caller speaks
        AudioCaptureEngine.overrideAcousticIsolation = false
        defer { AudioCaptureEngine.overrideAcousticIsolation = nil }

        let cap = AudioCaptureEngine()
        let spy = SpyCaptureDelegate()
        cap.delegate = spy

        let callerTone = make16kMonoTone(rmsAmplitude: 0.04)
        for _ in 0..<3 {
            cap.processBuffersForTesting(callerBuffer: callerTone, micBuffer: make16kMonoTone(rmsAmplitude: 0.005))
        }
        let afterEcho = spy.lock.withLock { $0 }
        expect(afterEcho.callerCount > 0, "Caller audio emitted in open-speaker call")
        expectEqual(afterEcho.micCount, 0, "Coupled caller echo (0.005 RMS) rejected during active caller speech")
        expectEqual(cap.speechFloorOwner, .caller, "Caller owns initial floor")
        expect(!cap.isUserSpeaking, "isUserSpeaking false on rejected echo")

        for _ in 0..<3 {
            cap.processBuffersForTesting(callerBuffer: callerTone, micBuffer: make16kMonoTone(rmsAmplitude: 0.015))
        }
        let afterUserOverlap = spy.lock.withLock { $0 }
        expect(afterUserOverlap.micCount > 0, "Conversational mic voice (0.015 RMS) breaks through during active open-speaker call")
        expect(cap.isUserSpeaking, "isUserSpeaking reports true while user speaks over active caller")
        expectEqual(cap.speechFloorOwner, .user, "Overlap prioritizes microphone speaker (.user) before caller (.caller)")

        cap.stop()

        // 3. External VPIO 3ch raw MEMS mode: silence stays quiet, soft raw voice (0.0012 RMS) is boosted & detected
        let vpioCap = AudioCaptureEngine()
        let vpioSpy = SpyCaptureDelegate()
        vpioCap.delegate = vpioSpy

        for _ in 0..<3 {
            vpioCap.processBuffersForTesting(callerBuffer: nil, micBuffer: make16kMonoTone(rmsAmplitude: 0.00003), sourceChannels: 3)
        }
        expectEqual(vpioSpy.lock.withLock { $0.micCount }, 0, "3ch quiescent VPIO noise floor (0.00003) does not false-trigger")
        vpioCap.processBuffersForTesting(callerBuffer: nil, micBuffer: make16kMonoTone(rmsAmplitude: 0.0012), sourceChannels: 3)
        let afterVpioVoice = vpioSpy.lock.withLock { $0 }
        expect(afterVpioVoice.micCount > 0, "3ch VPIO raw MEMS spoken voice (0.0012 RMS) triggers detection after makeup gain")
        expect(afterVpioVoice.lastMicRMS > 0.015, "3ch VPIO boosted buffer reaches healthy speech RMS (\(afterVpioVoice.lastMicRMS))")
        expect(vpioCap.isUserSpeaking, "3ch VPIO voice marks isUserSpeaking")
        vpioCap.stop()

        // 4. Coordinator floor handoff + buffer retention across caller hangover (>0.85s)
        let suiteName = "com.callcaption.tests.livecall.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let coord = CaptionCoordinator(defaults: testDefaults)
        let coordCap = coord.audioCaptureEngine
        let speechMgr = coord.speechRecognitionManager
        defer { coord.stop() }
        speechMgr.isAcousticallyIsolated = false
        coord.setConversationalMode(true)
        speechMgr.start(callerLocaleId: "es-ES", targetLangCode: "en", micLocaleId: "en-US", micTargetLangCode: "es", isMicEnabled: true)

        // Caller takes floor -> mic suspends cleanly
        for _ in 0..<2 {
            coordCap.processBuffersForTesting(callerBuffer: callerTone, micBuffer: nil)
            coord.audioCaptureDidOutputCallerAudio(pcmBuffer: callerTone)
        }
        expect(speechMgr.micChannel.isSuspended, "Idle mic suspends while caller has floor on open speakers")

        // Confirmed user speech arrives -> coordinator passes isUserSpeaking=true and subsequent caller overlap keeps mic unsuspended while suspending callerChannel
        let userTone = make16kMonoTone(rmsAmplitude: 0.015)
        coordCap.processBuffersForTesting(callerBuffer: callerTone, micBuffer: userTone)
        expect(coordCap.isUserSpeaking, "Capture engine marks isUserSpeaking during overlap")
        expectEqual(coordCap.speechFloorOwner, .user, "Capture engine hands floor priority to microphone speaker during overlap")
        coord.audioCaptureDidOutputMicAudio(pcmBuffer: userTone)
        expect(!speechMgr.micChannel.isSuspended, "Mic unsuspends immediately when confirmed user speech arrives")
        expect(speechMgr.callerChannel.isSuspended, "Caller channel suspends for microphone speaker priority")
        coord.audioCaptureDidOutputCallerAudio(pcmBuffer: callerTone)
        expect(!speechMgr.micChannel.isSuspended, "Caller overlap does NOT ping-pong suspend active user micChannel")
        expect(speechMgr.callerChannel.isSuspended, "Caller channel stays suspended while microphone speaker holds floor")

        // Suspended buffer retention across 1.10s (> 0.85s old cutoff, spanning caller hangover + release)
        speechMgr.stop()
        speechMgr.start(callerLocaleId: "es-ES", targetLangCode: "en", micLocaleId: "en-US", micTargetLangCode: "es", isMicEnabled: true)
        _ = speechMgr.micChannel.suspendForMicPriority()
        expect(speechMgr.micChannel.isSuspended, "micChannel suspended for hangover retention check")
        speechMgr.micChannel.appendPCMBuffer(userTone)
        try? await Task.sleep(for: .milliseconds(1100))
        speechMgr.micChannel.resumeAfterMicPriority()
        expectEqual(speechMgr.micChannel.pendingBufferCountForTesting(), 1, "Queued user speech survives 1.1s caller hangover without premature echo-buffer purge")
        coord.stop()
    }

    // MARK: - 16. Phase 1 Regression Tests: Audio (AUDIO-1, AUDIO-3, AUDIO-5, AUDIO-6)

    static func testPhase1RegressionAudio() async {
        func make16kMonoTone(rmsAmplitude: Float, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
            let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
            buf.frameLength = frames
            let peak = rmsAmplitude * sqrt(2.0)
            if let ch = buf.floatChannelData?[0] {
                for i in 0..<Int(frames) {
                    ch[i] = peak * sin(Float(i) * (2.0 * Float.pi * 440.0 / 16000.0))
                }
            }
            return buf
        }

        final class CountingAudioDelegate: AudioCaptureDelegate, @unchecked Sendable {
            let counts = OSAllocatedUnfairLock(initialState: (caller: 0, mic: 0))
            func audioCaptureDidOutputCallerAudio(pcmBuffer: AVAudioPCMBuffer) {
                counts.withLock { $0.caller += 1 }
            }
            func audioCaptureDidOutputMicAudio(pcmBuffer: AVAudioPCMBuffer) {
                counts.withLock { $0.mic += 1 }
            }
            func audioCaptureDidEncounterError(_ error: Error) {}
            func audioCaptureDidUpdateLevels(callerLevel: Float, micLevel: Float) {}
            func audioCaptureDidDetectDeniedTapPermission() {}
            func audioCaptureDidRestoreTapPermission() {}
        }

        // AUDIO-1: stop() / stopMicrophone() clears user speech & floor state cleanly
        let origIso = AudioCaptureEngine.overrideAcousticIsolation
        AudioCaptureEngine.overrideAcousticIsolation = false
        defer { AudioCaptureEngine.overrideAcousticIsolation = origIso }

        let cap = AudioCaptureEngine()
        let spy = CountingAudioDelegate()
        cap.delegate = spy
        let loudTone = make16kMonoTone(rmsAmplitude: 0.04, frames: 1600)
        for _ in 0..<2 {
            cap.processBuffersForTesting(callerBuffer: nil, micBuffer: loudTone)
        }
        expect(cap.isUserSpeaking, "AUDIO-1 setup: mic speech marks isUserSpeaking == true")
        expectEqual(cap.speechFloorOwner, .user, "AUDIO-1 setup: mic speech claims .user floor")
        cap.stopMicrophone()
        expect(!cap.isUserSpeaking, "AUDIO-1: stopMicrophone() resets isUserSpeaking to false")
        expectEqual(cap.speechFloorOwner, .none, "AUDIO-1: stopMicrophone() releases .user floor owner")

        for _ in 0..<2 {
            cap.processBuffersForTesting(callerBuffer: loudTone, micBuffer: nil)
        }
        expectEqual(cap.speechFloorOwner, .caller, "AUDIO-1 setup: caller speech claims .caller floor")
        cap.stop()
        expect(!cap.isUserSpeaking && cap.speechFloorOwner == .none, "AUDIO-1: stop() clears active floor and speaking state")

        // AUDIO-3: AudioHALListenerToken matches block identity on remove and releases captured block immediately
        final class ListenerSentinel: @unchecked Sendable {
            let onDeinit: @Sendable () -> Void
            init(onDeinit: @escaping @Sendable () -> Void) { self.onDeinit = onDeinit }
            deinit { onDeinit() }
        }
        let sentinelDeinited = OSAllocatedUnfairLock(initialState: false)
        let listenerQueue = DispatchQueue(label: "com.callcaption.test.hal.listener")
        weak var weakSentinel: ListenerSentinel?
        var listenerToken: AudioHALListenerToken?
        var addStatus: OSStatus = -1
        autoreleasepool {
            let sentinel = ListenerSentinel {
                sentinelDeinited.withLock { $0 = true }
            }
            weakSentinel = sentinel
            var outAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            listenerToken = AudioTapHelper.addPropertyListener(
                onObject: AudioObjectID(kAudioObjectSystemObject),
                address: &outAddr,
                queue: listenerQueue,
                block: { _, _ in _ = sentinel },
                status: &addStatus
            )
        }
        if let token = listenerToken {
            expectEqual(addStatus, noErr, "AUDIO-3: addPropertyListener returns noErr")
            expect(token.isActive, "AUDIO-3: newly registered AudioHALListenerToken is active")
            expectEqual(token.objectID, AudioObjectID(kAudioObjectSystemObject), "AUDIO-3: token records target AudioObjectID")
            expect(weakSentinel != nil, "AUDIO-3: active CoreAudio listener retains captured block sentinel")

            let removeStatus = autoreleasepool {
                AudioTapHelper.removePropertyListener(token)
            }
            expectEqual(removeStatus, noErr, "AUDIO-3: removePropertyListener succeeds with noErr")
            expect(!token.isActive, "AUDIO-3: token marks isActive == false after removal")
            expectEqual(AudioTapHelper.removePropertyListener(token), noErr, "AUDIO-3: repeated removal is idempotent")
            await expectEventually("AUDIO-3: removing CoreAudio listener releases captured block without leaking", timeout: 1.0) {
                sentinelDeinited.withLock { $0 } && weakSentinel == nil
            }
        } else {
            expect(false, "AUDIO-3: AudioTapHelper.addPropertyListener failed (status=\(addStatus))")
        }

        // AUDIO-5: Int16 interleaved right-only stereo fallback also preserves Channel 1 via downmix
        if let monoFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false),
           let monoOut = AVAudioPCMBuffer(pcmFormat: monoFmt, frameCapacity: 128),
           let fmt16 = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: true),
           let buf16 = AVAudioPCMBuffer(pcmFormat: fmt16, frameCapacity: 128) {
            buf16.frameLength = 128
            if let ptr = buf16.int16ChannelData?[0] {
                for i in 0..<128 {
                    ptr[2 * i] = 0          // L = 0.0
                    ptr[2 * i + 1] = 26214  // R ≈ 0.8
                }
            }
            let convEngine = AudioCaptureEngine()
            expect(convEngine.convertAndCopyToMono(source: buf16, destination: monoOut), "AUDIO-5: Int16 interleaved right-only stereo converts")
            let sample = monoOut.floatChannelData?[0][64] ?? 0
            expect(sample > 0.2 && abs(sample - 0.4) < 0.06, "AUDIO-5: Int16 interleaved right-only stereo downmixes to ~0.4 (got \(sample))")
        } else {
            expect(false, "AUDIO-5: Failed to allocate Int16 interleaved stereo buffer")
        }

        // AUDIO-6: Strict sample-count onset gating (sub-35ms / <560 samples caller burst does not trigger even across multiple tiny buffers)
        let onsetCap = AudioCaptureEngine()
        let onsetSpy = CountingAudioDelegate()
        onsetCap.delegate = onsetSpy
        defer { onsetCap.stop() }
        let short200 = make16kMonoTone(rmsAmplitude: 0.04, frames: 200) // 12.5ms each
        onsetCap.processBuffersForTesting(callerBuffer: short200, micBuffer: nil)
        onsetCap.processBuffersForTesting(callerBuffer: short200, micBuffer: nil) // 400 samples < 560 onset
        expectEqual(onsetSpy.counts.withLock { $0.caller }, 0, "AUDIO-6: 400-sample (25ms) caller burst across 2 buffers stays below 560-sample onset")
        onsetCap.processBuffersForTesting(callerBuffer: short200, micBuffer: nil) // 600 samples >= 560 onset
        expect(onsetSpy.counts.withLock { $0.caller } > 0, "AUDIO-6: reaching 600 samples (>= 560 onset) triggers caller audio output")
    }

    // MARK: - 17. Phase 1 Regression Tests: Speech & Translation (SPEECH-1, SPEECH-2, SPEECH-3, SPEECH-11)

    static func testPhase1RegressionSpeechAndTranslation() async {
        let engine = TranslationEngine.shared
        await engine.resetForTesting()

        // SPEECH-1: clearCache(invalidateFinals: false) preserves finals + CancellationError retries once and recovers
        let retryAttempts = OSAllocatedUnfairLock(initialState: 0)
        await engine.setTranslatorForTesting { text, _, _, _ in
            if text == "Cancelar una vez" {
                let n = retryAttempts.withLock { count -> Int in
                    count += 1
                    return count
                }
                if n == 1 {
                    throw CancellationError()
                }
                return "Recovered once"
            }
            return "TR:\(text)"
        }
        let recovered = await engine.translate(text: "Cancelar una vez", sourceCode: "es", targetCode: "en", isFinal: true)
        expectEqual(recovered, "Recovered once", "SPEECH-1: TranslationEngine retries once on CancellationError and succeeds")
        expectEqual(retryAttempts.withLock { $0 }, 2, "SPEECH-1: CancellationError recovery performs exactly 2 attempts")

        await engine.clearCache(invalidateFinals: false)
        expectEqual(await engine.cachedEntryCountForTesting(), 1, "SPEECH-1: clearCache(invalidateFinals: false) preserves final cache")

        // Partial -> final cache promotion without re-invoking translator
        let promoCalls = OSAllocatedUnfairLock(initialState: 0)
        await engine.resetForTesting()
        await engine.setTranslatorForTesting { text, _, _, _ in
            promoCalls.withLock { $0 += 1 }
            return "PROMO:\(text)"
        }
        let partialRes = await engine.translate(text: "Hola promo", sourceCode: "es", targetCode: "en", isFinal: false)
        expectEqual(partialRes, "PROMO:Hola promo", "SPEECH-1/3: partial translation populates partialCache")
        expectEqual(promoCalls.withLock { $0 }, 1, "Partial translation called translator once")
        let finalPromoRes = await engine.translate(text: "Hola promo", sourceCode: "es", targetCode: "en", isFinal: true)
        expectEqual(finalPromoRes, "PROMO:Hola promo", "SPEECH-3: final translate reuses exact partialCache match")
        expectEqual(promoCalls.withLock { $0 }, 1, "SPEECH-3: final translate did not re-invoke translator on partialCache hit")
        expectEqual(await engine.cachedEntryCountForTesting(), 1, "SPEECH-3: partialCache hit promoted into final cache")

        // SPEECH-3: commitSentenceForTesting reuses matching partial translation (0 extra translator calls) and promotes into final cache
        await engine.resetForTesting()
        let speechMockCalls = OSAllocatedUnfairLock(initialState: 0)
        await engine.setTranslatorForTesting { text, _, _, _ in
            speechMockCalls.withLock { $0 += 1 }
            if text == "Primero lento" {
                try await Task.sleep(for: .milliseconds(160))
                return "First-Slow"
            }
            if text == "Segundo rapido" {
                return "Second-Fast"
            }
            if text == "Sin traduccion" {
                return nil
            }
            return "MOCK:\(text)"
        }

        let ch = SingleSpeechChannel(name: "caller", sourceLocaleId: "es-ES", targetLangCode: "en")
        ch.start(sourceLocaleId: "es-ES", targetLangCode: "en")
        defer { ch.stop() }

        let receivedFinals = OSAllocatedUnfairLock(initialState: [(id: UUID, orig: String, trans: String, untrans: Bool)]())
        ch.onFinalWithLanguages = { id, orig, trans, _, _, untrans in
            receivedFinals.withLock { $0.append((id, orig, trans, untrans)) }
        }

        let uReuse = UUID()
        ch.commitSentenceForTesting(
            utteranceID: uReuse,
            original: "Buenos días",
            fallbackTranslated: "Good morning",
            fallbackUntranslated: false,
            fallbackTranslatedSource: "Buenos días"
        )
        let reuseEvents = receivedFinals.withLock { $0.filter { $0.id == uReuse } }
        expectEqual(reuseEvents.count, 1, "SPEECH-3: matching partial translation commits immediately in a single emission")
        expectEqual(reuseEvents.first?.trans, "Good morning", "SPEECH-3: matching partial translation is preserved")
        expectEqual(reuseEvents.first?.untrans, false, "SPEECH-3: matching partial translation is marked translated")
        expectEqual(speechMockCalls.withLock { $0 }, 0, "SPEECH-3: matching partial translation skips redundant final TranslationEngine call")
        // Poll async actor property for storeFinalCache Task completion
        let promotedDeadline = Date().addingTimeInterval(1.0)
        var promotedCount = 0
        while Date() < promotedDeadline {
            promotedCount = await engine.cachedEntryCountForTesting()
            if promotedCount >= 1 { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        expectEqual(promotedCount, 1, "SPEECH-3: storeFinalCache promoted reused partial translation into final cache")

        // SPEECH-2: out-of-order final revisions for same utteranceID — newer fast revision wins and slow earlier revision never overwrites
        let uRace = UUID()
        ch.commitSentenceForTesting(utteranceID: uRace, original: "Primero lento")
        ch.commitSentenceForTesting(utteranceID: uRace, original: "Segundo rapido")
        await expectEventually("SPEECH-2: newer final revision translates and delivers Second-Fast", timeout: 1.5) {
            receivedFinals.withLock { list in
                list.contains { $0.id == uRace && $0.trans == "Second-Fast" && !$0.untrans }
            }
        }
        // Wait past the 160ms slow task completion to confirm stale First-Slow is dropped
        await graceWindow(milliseconds: 220)
        let raceEvents = receivedFinals.withLock { $0.filter { $0.id == uRace } }
        expect(!raceEvents.contains { $0.trans == "First-Slow" }, "SPEECH-2: superseded slow final translation never overwrites newer revision")
        expectEqual(raceEvents.last?.trans, "Second-Fast", "SPEECH-2: latest revision remains final delivered translation")

        // SPEECH-3: failed final refinement (nil) does not emit a second downgrade callback
        let uNil = UUID()
        ch.commitSentenceForTesting(utteranceID: uNil, original: "Sin traduccion")
        await graceWindow(milliseconds: 60)
        let nilEvents = receivedFinals.withLock { $0.filter { $0.id == uNil } }
        expectEqual(nilEvents.count, 1, "SPEECH-3: nil final translation does not emit redundant downgrade callback")

        // SPEECH-11: Chinese script-subtag precedence in translationCode & candidateLocales
        expectEqual(SupportedLanguages.translationCode(from: "zh-Hans-HK"), "zh-hans", "SPEECH-11: zh-Hans-HK maps to zh-hans (explicit script beats HK region)")
        expectEqual(SupportedLanguages.translationCode(from: "zh-Hans-TW"), "zh-hans", "SPEECH-11: zh-Hans-TW maps to zh-hans (explicit script beats TW region)")
        expectEqual(SupportedLanguages.translationCode(from: "zh-Hans-MO"), "zh-hans", "SPEECH-11: zh-Hans-MO maps to zh-hans (explicit script beats MO region)")
        expectEqual(SupportedLanguages.translationCode(from: "zh-Hant-HK"), "zh-hant", "SPEECH-11: zh-Hant-HK maps to zh-hant")
        expectEqual(SupportedLanguages.translationCode(from: "zh-Hant-TW"), "zh-hant", "SPEECH-11: zh-Hant-TW maps to zh-hant")
        expectEqual(SupportedLanguages.translationCode(from: "zh-Hant-MO"), "zh-hant", "SPEECH-11: zh-Hant-MO maps to zh-hant")
        expectEqual(SupportedLanguages.translationCode(from: "zh-MY"), "zh-hans", "SPEECH-11: zh-MY maps to zh-hans (no bare zh)")
        expectEqual(SupportedLanguages.translationCode(from: "zh-SG"), "zh-hans", "SPEECH-11: zh-SG maps to zh-hans")
        expectEqual(SupportedLanguages.translationCode(from: "zh"), "zh-hans", "SPEECH-11: bare zh maps to zh-hans")

        let mockZhMap: [String: Locale] = [
            "zh-cn": Locale(identifier: "zh-CN"),
            "zh-tw": Locale(identifier: "zh-TW"),
            "zh-hk": Locale(identifier: "zh-HK")
        ]
        let zhHansHKCandidates = SupportedLanguages.candidateLocales(
            forCode: "zh-Hans-HK",
            preferredLanguages: ["en-US"],
            currentRegion: "US",
            availableLocaleMap: mockZhMap
        )
        expectEqual(zhHansHKCandidates.first?.identifier, "zh-CN", "SPEECH-11: zh-Hans-HK selects zh-CN first")
        expect(
            !zhHansHKCandidates.contains(where: { $0.identifier.lowercased() == "zh-hk" || $0.identifier.lowercased() == "zh-tw" }),
            "SPEECH-11: zh-Hans-HK excludes Traditional locales zh-HK/zh-TW"
        )

        await engine.resetForTesting()
    }

    // MARK: - 18. Phase 1 Regression Tests: Live Share (SHARE-1, 2, 6, 7, 8, 9, 10, 11)

    static func testPhase1RegressionLiveShare() async {
        // Shared DOM harness builder for JSContext tests of SHARE-1, SHARE-6, SHARE-7, SHARE-8
        func buildDOMHarness(encrypted: Bool) -> String {
            """
            const __windowListeners = {};
            const __docListeners = {};
            let __eventSourceCount = 0;
            let __lastEventSource = null;
            let __rafQueue = [];
            let __rafScheduleCount = 0;
            let __scrollToCalls = 0;
            let __lastScrollToBehavior = '';
            let __offsetHeightReads = 0;
            let __fakeNow = 100000;
            let __resolveImportKey = null;
            Date.now = function() { return __fakeNow; };

            function atob(b64) {
                const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
                let str = String(b64).replace(/=+$/, '');
                let out = '';
                for (let bc = 0, bs = 0, buffer, i = 0; (buffer = str.charAt(i++)); ) {
                    buffer = chars.indexOf(buffer);
                    if (buffer === -1) continue;
                    bs = bc % 4 ? bs * 64 + buffer : buffer;
                    if (bc++ % 4) out += String.fromCharCode(255 & (bs >> ((-2 * bc) & 6)));
                }
                return out;
            }

            function makeClassList(el) {
                return {
                    _set: new Set((el._className || '').split(/\\s+/).filter(Boolean)),
                    _sync() { el._className = Array.from(this._set).join(' '); },
                    add(c) { this._set.add(c); this._sync(); },
                    remove(c) { this._set.delete(c); this._sync(); },
                    toggle(c, force) {
                        const shouldAdd = (force !== undefined) ? !!force : !this._set.has(c);
                        if (shouldAdd) this._set.add(c); else this._set.delete(c);
                        this._sync();
                        return shouldAdd;
                    },
                    contains(c) { return this._set.has(c); }
                };
            }
            function makeElement(tag, id, className) {
                const el = {
                    tagName: (tag || 'DIV').toUpperCase(),
                    id: id || '',
                    _className: className || '',
                    textContent: '',
                    value: '',
                    disabled: false,
                    checked: true,
                    hidden: false,
                    scrollHeight: 800,
                    parentNode: null,
                    children: [],
                    attributes: {},
                    _listeners: {},
                    style: {
                        display: '',
                        _props: {},
                        setProperty(k, v) { this._props[k] = String(v); },
                        getPropertyValue(k) { return this._props[k] || ''; }
                    },
                    setAttribute(k, v) { this.attributes[k] = String(v); },
                    getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attributes, k) ? this.attributes[k] : null; },
                    removeAttribute(k) { delete this.attributes[k]; },
                    appendChild(child) {
                        if (child.parentNode) child.parentNode.removeChild(child);
                        child.parentNode = this;
                        this.children.push(child);
                        return child;
                    },
                    insertBefore(newNode, refNode) {
                        if (newNode.parentNode) newNode.parentNode.removeChild(newNode);
                        newNode.parentNode = this;
                        const idx = this.children.indexOf(refNode);
                        if (idx >= 0) this.children.splice(idx, 0, newNode);
                        else this.children.push(newNode);
                        return newNode;
                    },
                    removeChild(child) {
                        const idx = this.children.indexOf(child);
                        if (idx >= 0) {
                            this.children.splice(idx, 1);
                            child.parentNode = null;
                        }
                        return child;
                    },
                    remove() { if (this.parentNode) this.parentNode.removeChild(this); },
                    contains(target) {
                        if (this === target) return true;
                        for (let i = 0; i < this.children.length; i++) {
                            if (this.children[i].contains(target)) return true;
                        }
                        return false;
                    },
                    matchesSelector(sel) {
                        if (sel.startsWith('.')) return this.classList.contains(sel.slice(1));
                        if (sel === '[data-speaker="Caller"]') return this.getAttribute('data-speaker') === 'Caller';
                        return false;
                    },
                    querySelectorAll(sel) {
                        const out = [];
                        function walk(node) {
                            for (let i = 0; i < node.children.length; i++) {
                                const ch = node.children[i];
                                if (ch.matchesSelector(sel)) out.push(ch);
                                walk(ch);
                            }
                        }
                        walk(this);
                        return out;
                    },
                    querySelector(sel) { return this.querySelectorAll(sel)[0] || null; },
                    addEventListener(type, fn) {
                        if (!this._listeners[type]) this._listeners[type] = [];
                        this._listeners[type].push(fn);
                    },
                    getBoundingClientRect() { return { top: -100 }; }
                };
                el.classList = makeClassList(el);
                Object.defineProperty(el, 'className', {
                    get() { return this._className; },
                    set(v) { this._className = String(v || ''); this.classList = makeClassList(this); }
                });
                Object.defineProperty(el, 'innerHTML', {
                    get() { return ''; },
                    set(v) {
                        if (v === '') {
                            this.children.forEach(c => { c.parentNode = null; });
                            this.children = [];
                        }
                    }
                });
                Object.defineProperty(el, 'firstElementChild', { get() { return this.children[0] || null; } });
                Object.defineProperty(el, 'nextElementSibling', {
                    get() {
                        if (!this.parentNode) return null;
                        const siblings = this.parentNode.children;
                        const idx = siblings.indexOf(this);
                        return (idx >= 0 && idx + 1 < siblings.length) ? siblings[idx + 1] : null;
                    }
                });
                if (id === 'caption-stream') {
                    Object.defineProperty(el, 'offsetHeight', {
                        get() { __offsetHeightReads += 1; return this.children.length * 40; }
                    });
                } else {
                    el.offsetHeight = 0;
                }
                return el;
            }

            const elementsById = {};
            function registerEl(tag, id, className) {
                const el = makeElement(tag, id, className);
                elementsById[id] = el;
                return el;
            }
            const docEl = makeElement('HTML', '', '');
            const bodyEl = makeElement('BODY', '', 'show-orig');
            docEl.appendChild(bodyEl);
            const emptyStateEl = registerEl('DIV', 'empty-state', 'empty-state');
            const emptyTitleEl = makeElement('H2', '', 'empty-state-title');
            emptyStateEl.appendChild(emptyTitleEl);
            bodyEl.appendChild(emptyStateEl);
            bodyEl.appendChild(registerEl('DIV', 'caption-stream', 'caption-stream'));
            bodyEl.appendChild(registerEl('DIV', 'sr-live-announcer', 'sr-only'));
            bodyEl.appendChild(registerEl('DIV', 'conn-pill', 'status-pill connecting'));
            bodyEl.appendChild(registerEl('SPAN', 'conn-label', ''));
            bodyEl.appendChild(registerEl('SPAN', 'viewer-count', 'viewer-count'));
            bodyEl.appendChild(registerEl('DIV', 'autoscroll-pill', 'floating-bottom'));
            bodyEl.appendChild(registerEl('INPUT', 'autoscroll-toggle', ''));
            bodyEl.appendChild(registerEl('BUTTON', 'jump-latest-btn', 'jump-latest-btn'));
            bodyEl.appendChild(registerEl('BUTTON', 'copy-transcript-btn', 'btn'));
            bodyEl.appendChild(registerEl('BUTTON', 'view-mode-btn', 'btn'));
            bodyEl.appendChild(registerEl('BUTTON', 'orig-toggle-btn', 'btn active'));
            bodyEl.appendChild(registerEl('BUTTON', 'font-dec-btn', 'btn'));
            bodyEl.appendChild(registerEl('BUTTON', 'font-inc-btn', 'btn'));

            const storageMap = {};
            var window = globalThis;
            window.scrollY = 0;
            window.innerHeight = 800;
            window.location = { hash: \(encrypted ? "'#k=' + 'A'.repeat(43)" : "''") };
            window.performance = { now() { return 1000; } };
            window.localStorage = {
                getItem(k) { return Object.prototype.hasOwnProperty.call(storageMap, k) ? storageMap[k] : null; },
                setItem(k, v) { storageMap[k] = String(v); }
            };
            window.matchMedia = function() { return { matches: false }; };
            window.scrollTo = function(opts) {
                __scrollToCalls += 1;
                __lastScrollToBehavior = (opts && opts.behavior) ? opts.behavior : '';
            };
            window.addEventListener = function(type, fn) {
                if (!__windowListeners[type]) __windowListeners[type] = [];
                __windowListeners[type].push(fn);
            };
            window.__dispatchWindow = function(type, evt) {
                (__windowListeners[type] || []).forEach(fn => fn(evt || {}));
            };
            window.requestAnimationFrame = function(cb) {
                __rafScheduleCount += 1;
                __rafQueue.push(cb);
                return __rafScheduleCount;
            };
            window.__flushRAF = function() {
                const copy = __rafQueue.slice();
                __rafQueue = [];
                copy.forEach(cb => cb());
            };
            let __timerId = 0;
            window.setTimeout = function() { __timerId += 1; return __timerId; };
            window.clearTimeout = function() {};
            window.navigator = {};
            window.crypto = {
                subtle: {
                    importKey() {
                        return new Promise((resolve) => { __resolveImportKey = resolve; });
                    }
                }
            };
            window.EventSource = function(url) {
                __eventSourceCount += 1;
                this.url = url;
                this.readyState = 1;
                this.addEventListener = function() {};
                this.close = function() { this.readyState = 2; };
                __lastEventSource = this;
            };
            window.EventSource.CONNECTING = 0;
            window.EventSource.OPEN = 1;
            window.EventSource.CLOSED = 2;
            window.fetch = function() {
                return Promise.resolve({
                    ok: true,
                    status: 200,
                    json() {
                        return Promise.resolve({ isPaused: false, clearEpoch: 0, viewerCount: 1, history: [] });
                    }
                });
            };
            var location = window.location;
            var performance = window.performance;
            var navigator = window.navigator;
            var EventSource = window.EventSource;
            var requestAnimationFrame = window.requestAnimationFrame;
            var setTimeout = window.setTimeout;
            var clearTimeout = window.clearTimeout;
            var fetch = window.fetch;
            var document = {
                documentElement: docEl,
                scrollingElement: docEl,
                body: bodyEl,
                visibilityState: 'visible',
                getElementById(id) { return elementsById[id] || null; },
                createElement(tag) { return makeElement(tag, '', ''); },
                addEventListener(type, fn) {
                    if (!__docListeners[type]) __docListeners[type] = [];
                    __docListeners[type].push(fn);
                },
                getSelection() { return { rangeCount: 0, removeAllRanges() {}, addRange() {} }; },
                execCommand() { return true; }
            };
            """
        }

        // 1. SHARE-1: appInitialized gate & pageshow e.persisted gate (with pending WebCrypto importKey)
        let encHTML = ReceiverWebAppHTML.html(forToken: "tok_share1", encryptPayloads: true, acceptLanguage: "en-US")
        if let s1 = encHTML.range(of: "<script>"),
           let e1 = encHTML.range(of: "</script>", range: s1.upperBound..<encHTML.endIndex),
           let ctx1 = JSContext() {
            var errs1: [String] = []
            ctx1.exceptionHandler = { _, exc in if let m = exc?.toString() { errs1.append(m) } }
            _ = ctx1.evaluateScript(buildDOMHarness(encrypted: true))
            _ = ctx1.evaluateScript(String(encHTML[s1.upperBound..<e1.lowerBound]))

            expectEqual(ctx1.evaluateScript("appInitialized")?.toBool() ?? true, false, "SHARE-1: appInitialized stays false while initSessionCrypto awaits importKey")
            expectEqual(ctx1.evaluateScript("__eventSourceCount")?.toInt32() ?? -1, 0, "SHARE-1: no EventSource opened before initSessionCrypto completes")

            _ = ctx1.evaluateScript("window.__dispatchWindow('pageshow', { persisted: true }); window.__dispatchWindow('online');")
            expectEqual(ctx1.evaluateScript("__eventSourceCount")?.toInt32() ?? -1, 0, "SHARE-1: foreground/online/pageshow before appInitialized does not open SSE prematurely")
            expectEqual(ctx1.evaluateScript("isPollingActive")?.toBool() ?? true, false, "SHARE-1: foreground/online before appInitialized does not start polling prematurely")

            // Complete WebCrypto key import -> appInitialized becomes true and initial connectSSE runs
            _ = ctx1.evaluateScript("__resolveImportKey({});")
            expectEqual(ctx1.evaluateScript("appInitialized")?.toBool() ?? false, true, "SHARE-1: appInitialized flips true after crypto init")
            expectEqual(ctx1.evaluateScript("__eventSourceCount")?.toInt32() ?? -1, 1, "SHARE-1: initial connectSSE opens exactly 1 EventSource")

            // Simulate closed socket + normal initial pageshow (persisted: false) -> must NOT trigger handleForegroundOrOnline
            _ = ctx1.evaluateScript("__lastEventSource.readyState = EventSource.CLOSED; window.__dispatchWindow('pageshow', { persisted: false });")
            expectEqual(ctx1.evaluateScript("__eventSourceCount")?.toInt32() ?? -1, 1, "SHARE-1: pageshow with persisted:false does NOT reconnect")

            // bfcache restore pageshow (persisted: true) -> DOES reconnect
            _ = ctx1.evaluateScript("window.__dispatchWindow('pageshow', { persisted: true });")
            expectEqual(ctx1.evaluateScript("__eventSourceCount")?.toInt32() ?? -1, 2, "SHARE-1: pageshow with persisted:true reconnects cleanly")
            expect(errs1.isEmpty, "SHARE-1 JSContext had no errors (errors: \(errs1))")
        } else {
            expect(false, "SHARE-1: Failed to extract inline <script> from encrypted HTML")
        }

        // 2. SHARE-6 (SSE fallback status + exponential backoff), SHARE-7 (rAF coalescing + <=80 eviction guard), SHARE-8 (pause card removal)
        let plainHTML = ReceiverWebAppHTML.html(forToken: "tok_share678", encryptPayloads: false, acceptLanguage: "en-US")
        if let s2 = plainHTML.range(of: "<script>"),
           let e2 = plainHTML.range(of: "</script>", range: s2.upperBound..<plainHTML.endIndex),
           let ctx2 = JSContext() {
            var errs2: [String] = []
            ctx2.exceptionHandler = { _, exc in if let m = exc?.toString() { errs2.append(m) } }
            _ = ctx2.evaluateScript(buildDOMHarness(encrypted: false))
            _ = ctx2.evaluateScript(String(plainHTML[s2.upperBound..<e2.lowerBound]))

            // SHARE-6a: SSE onerror during healthy polling preserves live pill instead of flashing Reconnecting
            _ = ctx2.evaluateScript("""
                setConnectionState(true, L10N.statusLive);
                isPollingActive = true;
                consecutivePollFailures = 0;
                eventSource.onerror();
            """)
            expectEqual(ctx2.evaluateScript("connPill.className")?.toString() ?? "", "status-pill", "SHARE-6: SSE error while polling is healthy keeps live pill class")
            expectEqual(ctx2.evaluateScript("connLabel.textContent")?.toString() ?? "", ctx2.evaluateScript("L10N.statusLive")?.toString() ?? "Live", "SHARE-6: SSE error while polling is healthy keeps Live status label")

            _ = ctx2.evaluateScript("consecutivePollFailures = 1; eventSource.onerror();")
            expectEqual(ctx2.evaluateScript("connPill.className")?.toString() ?? "", "status-pill offline", "SHARE-6: SSE error with failed polling switches pill to offline")

            // SHARE-6b: Exponential SSE reconnect backoff (5s -> 10s -> 20s -> 40s -> 60s cap) + reset on onopen / foreground
            expectEqual(ctx2.evaluateScript("sseReconnectDelayMs")?.toInt32() ?? 0, 5000, "SHARE-6: initial SSE reconnect backoff starts at 5000ms")
            _ = ctx2.evaluateScript("""
                isPollingActive = true;
                pollCycleToken = 42;
                consecutivePollFailures = 0;
                eventSource.readyState = EventSource.CLOSED;
                lastSSEAttemptMs = __fakeNow;
                __fakeNow += 5000;
                pollState(42);
            """)
            expectEqual(ctx2.evaluateScript("sseReconnectDelayMs")?.toInt32() ?? 0, 10000, "SHARE-6: first SSE retry doubles backoff to 10000ms")
            let countAfterFirst = ctx2.evaluateScript("__eventSourceCount")?.toInt32() ?? 0

            // Only 5000ms elapsed (< 10000ms backoff) -> must NOT retry yet
            _ = ctx2.evaluateScript("eventSource.readyState = EventSource.CLOSED; __fakeNow += 5000; pollState(42);")
            expectEqual(ctx2.evaluateScript("__eventSourceCount")?.toInt32() ?? 0, countAfterFirst, "SHARE-6: SSE retry respects 10s backoff before reconnecting")

            // Advance remaining 5s -> 20s, then 20s -> 40s, then 40s -> 60s, then 60s -> still capped at 60s
            _ = ctx2.evaluateScript("eventSource.readyState = EventSource.CLOSED; __fakeNow += 5000; pollState(42);")
            expectEqual(ctx2.evaluateScript("sseReconnectDelayMs")?.toInt32() ?? 0, 20000, "SHARE-6: second SSE retry doubles backoff to 20000ms")
            _ = ctx2.evaluateScript("eventSource.readyState = EventSource.CLOSED; __fakeNow += 20000; pollState(42);")
            expectEqual(ctx2.evaluateScript("sseReconnectDelayMs")?.toInt32() ?? 0, 40000, "SHARE-6: third SSE retry doubles backoff to 40000ms")
            _ = ctx2.evaluateScript("eventSource.readyState = EventSource.CLOSED; __fakeNow += 40000; pollState(42);")
            expectEqual(ctx2.evaluateScript("sseReconnectDelayMs")?.toInt32() ?? 0, 60000, "SHARE-6: fourth SSE retry caps backoff at 60000ms")
            _ = ctx2.evaluateScript("eventSource.readyState = EventSource.CLOSED; __fakeNow += 60000; pollState(42);")
            expectEqual(ctx2.evaluateScript("sseReconnectDelayMs")?.toInt32() ?? 0, 60000, "SHARE-6: backoff remains capped at 60000ms")

            _ = ctx2.evaluateScript("eventSource.onopen();")
            expectEqual(ctx2.evaluateScript("sseReconnectDelayMs")?.toInt32() ?? 0, 5000, "SHARE-6: eventSource.onopen resets backoff to 5000ms")
            _ = ctx2.evaluateScript("sseReconnectDelayMs = 40000; handleForegroundOrOnline();")
            expectEqual(ctx2.evaluateScript("sseReconnectDelayMs")?.toInt32() ?? 0, 5000, "SHARE-6: handleForegroundOrOnline resets backoff to 5000ms")

            // SHARE-7: rAF scroll coalescing & <=80 eviction layout-read guard
            _ = ctx2.evaluateScript("""
                docEl.scrollHeight = 2000;
                bodyEl.scrollHeight = 2000;
                window.scrollY = 0;
                autoScroll = true;
                __rafQueue = [];
                __rafScheduleCount = 0;
                __scrollToCalls = 0;
                __lastScrollToBehavior = '';
                scrollScheduled = false;
                pendingScrollInstant = false;
                scrollToBottom(false);
                scrollToBottom(false);
                scrollToBottom(true);
            """)
            expectEqual(ctx2.evaluateScript("__rafScheduleCount")?.toInt32() ?? -1, 1, "SHARE-7: burst of 3 scrollToBottom calls coalesces into 1 requestAnimationFrame")
            expectEqual(ctx2.evaluateScript("__scrollToCalls")?.toInt32() ?? -1, 0, "SHARE-7: scrollTo deferred until rAF fires")
            _ = ctx2.evaluateScript("window.__flushRAF();")
            expectEqual(ctx2.evaluateScript("__scrollToCalls")?.toInt32() ?? -1, 1, "SHARE-7: single scrollTo runs when rAF flushes")
            expectEqual(ctx2.evaluateScript("__lastScrollToBehavior")?.toString() ?? "", "auto", "SHARE-7: coalesced instant=true flag uses auto scroll behavior")

            _ = ctx2.evaluateScript("""
                clearRenderedCards();
                autoScroll = false;
                __offsetHeightReads = 0;
                for (let i = 0; i < 10; i++) {
                    handleCaptionEvent({ id: 'c_' + i, speaker: 'Caller', originalText: 'O' + i, translatedText: 'T' + i, isFinal: true }, true);
                }
                evictOldCardsIfNeeded();
            """)
            expectEqual(ctx2.evaluateScript("__offsetHeightReads")?.toInt32() ?? -1, 0, "SHARE-7: evictOldCardsIfNeeded does 0 forced layout reads when cards <= 80")

            _ = ctx2.evaluateScript("""
                for (let i = 10; i < 85; i++) {
                    handleCaptionEvent({ id: 'c_' + i, speaker: 'Caller', originalText: 'O' + i, translatedText: 'T' + i, isFinal: true }, true);
                }
            """)
            expectEqual(ctx2.evaluateScript("streamContainer.children.length")?.toInt32() ?? -1, 80, "SHARE-7: cards above 80 are evicted down to 80")
            expect((ctx2.evaluateScript("__offsetHeightReads")?.toInt32() ?? 0) > 0, "SHARE-7: scroll compensation reads layout only when evicting > 80 cards")

            // SHARE-8: pause removes both Caller and You live partial cards from DOM and clears liveSlots
            _ = ctx2.evaluateScript("""
                clearRenderedCards();
                handleCaptionEvent({ id: 'f1', speaker: 'Caller', originalText: 'F', translatedText: 'Final', isFinal: true }, false);
                handleCaptionEvent({ id: 'p_c', speaker: 'Caller', originalText: 'PC', translatedText: 'LiveC', isFinal: false }, false);
                handleCaptionEvent({ id: 'p_y', speaker: 'You', originalText: 'PY', translatedText: 'LiveY', isFinal: false }, false);
            """)
            expectEqual(ctx2.evaluateScript("streamContainer.children.length")?.toInt32() ?? -1, 3, "SHARE-8 setup: 1 final + 2 live cards in DOM")
            _ = ctx2.evaluateScript("handleStatusEvent({ paused: true });")
            expectEqual(ctx2.evaluateScript("liveSlots['Caller'] === null && liveSlots['You'] === null")?.toBool() ?? false, true, "SHARE-8: pause clears both Caller and You liveSlots")
            expectEqual(ctx2.evaluateScript("streamContainer.children.length")?.toInt32() ?? -1, 1, "SHARE-8: pause removes both live cards while keeping finalized card")
            expect(errs2.isEmpty, "SHARE-6/7/8 JSContext had no errors (errors: \(errs2))")
        } else {
            expect(false, "SHARE-6/7/8: Failed to extract inline <script> from plain HTML")
        }

        // Raw loopback HTTP helper that respects Content-Length so requests finish in <1ms without waiting for graceClose
        @Sendable func rawLoopbackHTTP(port: Int, rawRequest: String) -> (status: Int, headers: String, body: Data)? {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { Darwin.close(fd) }
            let tv = timeval(tv_sec: 3, tv_usec: 0)
            withUnsafePointer(to: tv) {
                _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
                _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
            }
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            addr.sin_addr = in_addr(s_addr: UInt32(0x7f000001).bigEndian)
            let ok = withUnsafePointer(to: addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            guard ok else { return nil }
            let sent = rawRequest.withCString { cStr -> Bool in
                let total = strlen(cStr)
                var offset = 0
                while offset < total {
                    let n = Darwin.send(fd, cStr.advanced(by: offset), total - offset, 0)
                    if n <= 0 { return false }
                    offset += n
                }
                return true
            }
            guard sent else { return nil }

            var response = Data()
            var buf = [UInt8](repeating: 0, count: 8192)
            let separator = Data([13, 10, 13, 10])
            var headerEnd: Data.Index?
            var expectedBodyLen: Int?

            while true {
                let n = buf.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
                if n <= 0 { break }
                response.append(buf, count: n)
                if headerEnd == nil, let sepRange = response.range(of: separator) {
                    headerEnd = sepRange.upperBound
                    let headerStr = String(decoding: response[..<sepRange.lowerBound], as: UTF8.self)
                    for line in headerStr.components(separatedBy: "\r\n") {
                        if line.lowercased().hasPrefix("content-length:") {
                            let val = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                            expectedBodyLen = Int(val)
                        }
                    }
                }
                if let hEnd = headerEnd, let bodyLen = expectedBodyLen {
                    if response.count - hEnd >= bodyLen { break }
                }
            }
            guard let hEnd = headerEnd else { return nil }
            let headersStr = String(decoding: response[..<(hEnd - 4)], as: UTF8.self)
            guard let firstLine = headersStr.components(separatedBy: "\r\n").first else { return nil }
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2, let code = Int(parts[1]) else { return nil }
            let bodyData = response.subdata(in: hEnd..<response.count)
            return (code, headersStr, bodyData)
        }

        let manager = LiveShareManager.shared
        manager.stopSharingSynchronously()
        manager.clearHistoryForPrivacy()
        defer {
            manager.stopSharingSynchronously()
            manager.clearHistoryForPrivacy()
        }

        // 3. SHARE-2: Rapid stopSharing() (deferred teardown) -> immediate startSharing() does not kill Session 2
        manager.startSharing(allowLAN: false, useExternalTunnel: false, shareBothSpeakers: true)
        var url1: URL?
        _ = await waitUntil(timeout: 3.0) {
            if let u = manager.localShareURL, manager.isSharing { url1 = u; return true }
            return false
        }
        if let u1 = url1, let port1 = u1.port {
            let tok1 = u1.path.split(separator: "/").last.map(String.init) ?? ""
            // Open an SSE connection so stopSharing() enters the 350ms deferred teardown path
            let sseFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            if sseFD >= 0 {
                defer { Darwin.close(sseFD) }
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = UInt16(port1).bigEndian
                addr.sin_addr = in_addr(s_addr: UInt32(0x7f000001).bigEndian)
                let connected = withUnsafePointer(to: addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(sseFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                    }
                }
                if connected {
                    let req = "GET /s/\(tok1)/events?viewer=share2_sse HTTP/1.1\r\nHost: 127.0.0.1:\(port1)\r\nConnection: keep-alive\r\n\r\n"
                    _ = req.withCString { Darwin.send(sseFD, $0, Int(strlen($0)), 0) }
                    _ = await waitUntil(timeout: 1.5) { manager.activeClientCount >= 1 }
                }
            }

            // Trigger async deferred teardown and IMMEDIATELY start Session 2
            manager.stopSharing()
            manager.startSharing(allowLAN: false, useExternalTunnel: false, shareBothSpeakers: true)
            var url2: URL?
            _ = await waitUntil(timeout: 3.0) {
                if let u = manager.localShareURL, manager.isSharing, u != u1 { url2 = u; return true }
                return false
            }
            if let u2 = url2, let port2 = u2.port {
                let tok2 = u2.path.split(separator: "/").last.map(String.init) ?? ""
                expect(tok2 != tok1, "SHARE-2: Session 2 generates fresh session token")
                // Wait past Session 1's 350ms deferred teardown timer to verify Session 2 is untouched
                await graceWindow(milliseconds: 420)
                expect(manager.isSharing, "SHARE-2: Session 2 remains active after Session 1 deferred teardown window")
                let probe = await Task.detached {
                    rawLoopbackHTTP(port: port2, rawRequest: "GET /s/\(tok2) HTTP/1.1\r\nHost: 127.0.0.1:\(port2)\r\nConnection: close\r\n\r\n")
                }.value
                expectEqual(probe?.status ?? 0, 200, "SHARE-2: Session 2 still serves 200 OK after Session 1 deferred teardown")
            } else {
                expect(false, "SHARE-2: Session 2 failed to start immediately after async stopSharing()")
            }
            manager.stopSharing()
            manager.stopSharingSynchronously()
            expect(!manager.isSharing && manager.activeClientCount == 0, "SHARE-2: stopSharing -> stopSharingSynchronously leaves clean state")
        } else {
            expect(false, "SHARE-2: Session 1 failed to start")
        }

        // 4. SHARE-9: retryTunnel() while sharing with tunnel enabled clears URLs and keeps isTunnelStarting == true
        manager.startSharing(allowLAN: false, useExternalTunnel: true, shareBothSpeakers: true)
        await expectEventually("SHARE-9: tunnel-enabled session starts locally", timeout: 3.0) {
            manager.isSharing && manager.localShareURL != nil
        }
        manager.retryTunnel()
        await expectEventually("SHARE-9: retryTunnel keeps isTunnelStarting == true and publicShareURL == nil", timeout: 1.5) {
            manager.isSharing && manager.isTunnelStarting && manager.publicShareURL == nil
        }
        manager.stopSharingSynchronously()
        expect(!manager.isSharing && !manager.isTunnelStarting, "SHARE-9: stopSharingSynchronously clears tunnel state")

        // 5. SHARE-10 (fail-closed spoofed Host / proxy header) & SHARE-11 (HTML/gzip response cache + teardown invalidation)
        manager.startSharing(allowLAN: false, useExternalTunnel: false, shareBothSpeakers: true)
        var cacheURL1: URL?
        _ = await waitUntil(timeout: 3.0) {
            if let u = manager.localShareURL, manager.isSharing { cacheURL1 = u; return true }
            return false
        }
        if let u = cacheURL1, let port = u.port {
            let tok = u.path.split(separator: "/").last.map(String.init) ?? ""

            // SHARE-10: Loopback request spoofing a non-loopback LAN Host (and with X-Forwarded-For) must fail closed with 403
            let spoofResp = await Task.detached {
                rawLoopbackHTTP(port: port, rawRequest: "GET /s/\(tok) HTTP/1.1\r\nHost: 192.168.1.99:\(port)\r\nConnection: close\r\n\r\n")
            }.value
            expectEqual(spoofResp?.status ?? 0, 403, "SHARE-10: loopback request with spoofed LAN Host returns 403 Forbidden")

            let proxySpoofResp = await Task.detached {
                rawLoopbackHTTP(port: port, rawRequest: "GET /s/\(tok) HTTP/1.1\r\nHost: 192.168.1.99:\(port)\r\nX-Forwarded-For: 203.0.113.10\r\nConnection: close\r\n\r\n")
            }.value
            expectEqual(proxySpoofResp?.status ?? 0, 403, "SHARE-10: proxy-header request with spoofed LAN Host returns 403 Forbidden")

            // SHARE-11: HTML & gzip cache hit returns identical bytes; language variants stay separated; teardown clears cache
            let plain1 = await Task.detached {
                rawLoopbackHTTP(port: port, rawRequest: "GET /s/\(tok) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAccept-Language: en-US\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n")
            }.value
            let plain2 = await Task.detached {
                rawLoopbackHTTP(port: port, rawRequest: "GET /s/\(tok) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAccept-Language: en-US\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n")
            }.value
            expectEqual(plain1?.status ?? 0, 200, "SHARE-11: first plain HTML request returns 200")
            expectEqual(plain1?.body, plain2?.body, "SHARE-11: second plain HTML request returns byte-identical cached HTML")

            let gz1 = await Task.detached {
                rawLoopbackHTTP(port: port, rawRequest: "GET /s/\(tok) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAccept-Language: en-US\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n")
            }.value
            let gz2 = await Task.detached {
                rawLoopbackHTTP(port: port, rawRequest: "GET /s/\(tok) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAccept-Language: en-US\r\nAccept-Encoding: gzip\r\nConnection: close\r\n\r\n")
            }.value
            expect(gz1?.headers.lowercased().contains("content-encoding: gzip") == true, "SHARE-11: gzip request returns Content-Encoding: gzip")
            expectEqual(gz1?.body, gz2?.body, "SHARE-11: repeated gzip request returns byte-identical cached compressed body")

            let esResp = await Task.detached {
                rawLoopbackHTTP(port: port, rawRequest: "GET /s/\(tok) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAccept-Language: es-ES\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n")
            }.value
            let esBody = esResp.map { String(decoding: $0.body, as: UTF8.self) } ?? ""
            expect(esBody.contains("<html lang=\"es\""), "SHARE-11: Spanish Accept-Language caches separately from English")

            // Restart session and confirm HTML cache was cleared on teardown
            manager.stopSharingSynchronously()
            manager.startSharing(allowLAN: false, useExternalTunnel: false, shareBothSpeakers: true)
            var cacheURL2: URL?
            _ = await waitUntil(timeout: 3.0) {
                if let u2 = manager.localShareURL, manager.isSharing { cacheURL2 = u2; return true }
                return false
            }
            if let u2 = cacheURL2, let port2 = u2.port {
                let tok2 = u2.path.split(separator: "/").last.map(String.init) ?? ""
                let nextHTML = await Task.detached {
                    rawLoopbackHTTP(port: port2, rawRequest: "GET /s/\(tok2) HTTP/1.1\r\nHost: 127.0.0.1:\(port2)\r\nAccept-Language: en-US\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n")
                }.value
                let nextStr = nextHTML.map { String(decoding: $0.body, as: UTF8.self) } ?? ""
                expect(nextStr.contains("/s/\(tok2)") && !nextStr.contains("/s/\(tok)"), "SHARE-11: new session serves fresh HTML without stale cached token")
            } else {
                expect(false, "SHARE-11: failed to start second session for cache teardown check")
            }
        } else {
            expect(false, "SHARE-10/11: failed to start loopback session")
        }
        manager.stopSharingSynchronously()
    }

    // MARK: - 19. Phase 1 Regression Tests: Coordinator & UI (COORD-1, 4, 5, 7, UI-1, UI-2)

    static func testPhase1RegressionCoordinatorAndUI() async {
        final class SpeechCountDelegate: CaptionCoordinatorDelegate {
            var receiveCount = 0
            func coordinatorDidRequestShowAlert(message: String, actionType: SystemAlertActionType) {}
            func coordinatorDidRequestClearAlert() {}
            func coordinatorDidReceiveSpeech(
                utteranceID: UUID,
                speaker: String,
                original: String,
                translated: String,
                sourceLangCode: String,
                targetLangCode: String,
                isFinal: Bool,
                isUntranslated: Bool
            ) {
                receiveCount += 1
            }
            func coordinatorDidUpdateAudioLevels(callerLevel: Float, micLevel: Float) {}
        }

        let suiteName = "com.callcaption.phase1.coordui.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            expect(false, "Failed to create isolated UserDefaults suite for Phase 1 Coordinator/UI tests")
            return
        }
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        let coordinator = CaptionCoordinator(defaults: defaults, liveShareManager: LiveShareManager.shared)
        defer { coordinator.stop() }
        let vm = coordinator.viewModel
        let spyDelegate = SpeechCountDelegate()
        coordinator.delegate = spyDelegate

        // COORD-1 & UI-1: hasEntries transitions, CaptionEntry equality, duplicate update dedup, and translated final never downgraded
        let ts = Date()
        let entryID = UUID()
        let entryA = CaptionEntry(id: entryID, speaker: "Caller", original: "Hola", translated: "Hello", sourceLangCode: "es", targetLangCode: "en", timestamp: ts, isFinal: false, isUntranslated: false)
        let entryB = CaptionEntry(id: entryID, speaker: "Caller", original: "Hola", translated: "Hello", sourceLangCode: "es", targetLangCode: "en", timestamp: ts, isFinal: false, isUntranslated: false)
        let entryFinal = CaptionEntry(id: entryID, speaker: "Caller", original: "Hola", translated: "Hello", sourceLangCode: "es", targetLangCode: "en", timestamp: ts, isFinal: true, isUntranslated: false)
        expectEqual(entryA, entryB, "UI-1: identical CaptionEntry values compare equal for Equatable row diffing")
        expect(entryA != entryFinal, "UI-1: CaptionEntry detects isFinal state change")
        expect(!vm.hasEntries, "UI-1: CaptionViewModel.hasEntries starts false")

        let u1 = UUID()
        coordinator.callerSpeechDidUpdate(
            utteranceID: u1,
            partialOriginal: "Hola",
            partialTranslated: "Hello",
            sourceLangCode: "es",
            targetLangCode: "en",
            isUntranslated: false
        )
        await expectEventually("UI-1: hasEntries becomes true on first caption", timeout: 1.0) {
            vm.hasEntries && vm.entries.count == 1
        }
        let countAfterFirst = spyDelegate.receiveCount
        expectEqual(countAfterFirst, 1, "UI-1: first caption notifies delegate once")

        // Identical duplicate partial must be deduplicated by deliverOnMain
        coordinator.callerSpeechDidUpdate(
            utteranceID: u1,
            partialOriginal: "Hola",
            partialTranslated: "Hello",
            sourceLangCode: "es",
            targetLangCode: "en",
            isUntranslated: false
        )
        await settleMain()
        expectEqual(spyDelegate.receiveCount, countAfterFirst, "UI-1: identical duplicate caption does not trigger redundant delegate delivery")

        // Finalize translated entry, then attempt untranslated downgrade -> must be ignored (COORD-1)
        coordinator.callerSpeechDidFinalize(
            utteranceID: u1,
            original: "Hola mundo",
            translated: "Hello world",
            sourceLangCode: "es",
            targetLangCode: "en",
            isUntranslated: false
        )
        await expectEventually("COORD-1: finalized translated entry recorded", timeout: 1.0) {
            vm.entries.first?.isFinal == true && vm.entries.first?.translated == "Hello world"
        }
        let countAfterFinal = spyDelegate.receiveCount
        coordinator.callerSpeechDidFinalize(
            utteranceID: u1,
            original: "Hola mundo",
            translated: "Hola mundo",
            sourceLangCode: "es",
            targetLangCode: "en",
            isUntranslated: true
        )
        await settleMain()
        expectEqual(vm.entries.first?.translated, "Hello world", "COORD-1: untranslated final cannot overwrite already-translated final")
        expectEqual(vm.entries.first?.isUntranslated, false, "COORD-1: isUntranslated stays false after rejected downgrade")
        expectEqual(spyDelegate.receiveCount, countAfterFinal, "COORD-1: rejected untranslated downgrade emits no delegate notification")

        // Appending a second entry keeps hasEntries == true; clearTranscript resets hasEntries == false
        coordinator.callerSpeechDidFinalize(
            utteranceID: UUID(),
            original: "Adiós",
            translated: "Goodbye",
            sourceLangCode: "es",
            targetLangCode: "en",
            isUntranslated: false
        )
        await expectEventually("UI-1: second entry appended while hasEntries remains true", timeout: 1.0) {
            vm.entries.count == 2 && vm.hasEntries
        }
        coordinator.clearTranscript()
        await expectEventually("UI-1: clearTranscript resets hasEntries to false", timeout: 1.0) {
            !vm.hasEntries && vm.entries.isEmpty
        }

        // UI-2: compactFloatingHUDDidChangeNotification posts only on change and persists to defaults
        let compactNotifCount = OSAllocatedUnfairLock(initialState: 0)
        let compactObs = NotificationCenter.default.addObserver(
            forName: CaptionCoordinator.compactFloatingHUDDidChangeNotification,
            object: coordinator,
            queue: nil
        ) { _ in
            compactNotifCount.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(compactObs) }

        expect(!coordinator.isCompactFloatingHUD && !vm.isCompactFloatingHUD, "UI-2: compactFloatingHUD defaults to false")
        coordinator.setCompactFloatingHUD(true)
        await settleMain()
        expect(coordinator.isCompactFloatingHUD && vm.isCompactFloatingHUD, "UI-2: setCompactFloatingHUD(true) updates coordinator and ViewModel")
        expect(defaults.bool(forKey: "isCompactFloatingHUD"), "UI-2: setCompactFloatingHUD persists to UserDefaults")
        expectEqual(compactNotifCount.withLock { $0 }, 1, "UI-2: toggling compactFloatingHUD posts notification once")

        // Compact floating HUD hosting layout check (detached compact minHeight = 180)
        let compactHosting = NSHostingController(
            rootView: CaptionPopoverView(viewModel: vm, isDetached: true, onToggleDetach: {}, onQuit: {})
                .frame(width: 360, height: 200)
        )
        compactHosting.view.frame = NSRect(x: 0, y: 0, width: 360, height: 200)
        compactHosting.view.layoutSubtreeIfNeeded()
        expect(
            compactHosting.view.fittingSize.width <= 360.5 && compactHosting.view.fittingSize.height <= 200.5,
            "UI-1/UI-2: detached compact HUD fits cleanly in 360x200 (got \(compactHosting.view.fittingSize))"
        )

        coordinator.setCompactFloatingHUD(true)
        await settleMain()
        expectEqual(compactNotifCount.withLock { $0 }, 1, "UI-2: setting same compactFloatingHUD value does not re-post notification")
        coordinator.setCompactFloatingHUD(false)
        await settleMain()
        expect(!coordinator.isCompactFloatingHUD && !vm.isCompactFloatingHUD, "UI-2: setCompactFloatingHUD(false) restores full HUD")
        expectEqual(compactNotifCount.withLock { $0 }, 2, "UI-2: disabling compactFloatingHUD posts notification")

        // COORD-7: syncViewModelBasicState posts captureStateDidChangeNotification only when basic state actually changes
        coordinator.audioCaptureDidRestoreMic() // Establishes baseline lastPostedBasicState on main
        await settleMain()
        let captureNotifCount = OSAllocatedUnfairLock(initialState: 0)
        let captureObs = NotificationCenter.default.addObserver(
            forName: CaptionCoordinator.captureStateDidChangeNotification,
            object: coordinator,
            queue: nil
        ) { _ in
            captureNotifCount.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(captureObs) }

        coordinator.audioCaptureDidRestoreMic()
        coordinator.audioCaptureDidRestoreTapPermission()
        await settleMain()
        expectEqual(captureNotifCount.withLock { $0 }, 0, "COORD-7: redundant basic-state syncs with unchanged snapshot emit 0 notifications")

        coordinator.pause()
        await settleMain()
        expectEqual(captureNotifCount.withLock { $0 }, 1, "COORD-7: real pause transition emits captureStateDidChangeNotification once")

        coordinator.pause() // Redundant pause while already paused
        await settleMain()
        expectEqual(captureNotifCount.withLock { $0 }, 1, "COORD-7: redundant pause emits 0 additional captureStateDidChangeNotification posts")
        coordinator.resume()
        await settleMain()
        expectEqual(captureNotifCount.withLock { $0 }, 2, "COORD-7: resume transition emits captureStateDidChangeNotification once")

        // COORD-4: pause() followed immediately by resume() cancels epoch-guarded pause cache clear without disrupting TranslationEngine
        let engine = TranslationEngine.shared
        await engine.resetForTesting()
        await engine.setTranslatorForTesting { text, _, _, _ in "C4_\(text)" }
        _ = await engine.translate(text: "persist", sourceCode: "es", targetCode: "en", isFinal: true)
        expectEqual(await engine.cachedEntryCountForTesting(), 1, "COORD-4 setup: final cache seeded")
        coordinator.pause()
        coordinator.resume()
        await settleMain()
        await graceWindow(milliseconds: 30)
        expect(!coordinator.isPaused && !vm.isPaused, "COORD-4: rapid pause->resume leaves coordinator unpaused")
        expectEqual(await engine.cachedEntryCountForTesting(), 1, "COORD-4: final cache remains intact after pause->resume")
        let postResumeTrans = await engine.translate(text: "after", sourceCode: "es", targetCode: "en", isFinal: false)
        expectEqual(postResumeTrans, "C4_after", "COORD-4: translation succeeds cleanly after rapid pause->resume")
        await engine.resetForTesting()

        // COORD-5: system auto-pause invoked BEFORE start() is preserved across start() and auto-resumes on wake
        let sleepSuite = "com.callcaption.phase1.coord5.\(UUID().uuidString)"
        if let sleepDefaults = UserDefaults(suiteName: sleepSuite) {
            defer { UserDefaults().removePersistentDomain(forName: sleepSuite) }
            let sleepCoord = CaptionCoordinator(defaults: sleepDefaults, liveShareManager: LiveShareManager.shared)
            defer { sleepCoord.stop() }
            // Keep same language + mic off so wake reconfiguration stays completely offline/in-memory
            sleepCoord.setConversationalMode(false)
            sleepCoord.setCallerLanguage("en")
            sleepCoord.setMyLanguage("en")

            sleepCoord.autoPauseForSystem(reason: .systemSleep)
            expect(sleepCoord.isPaused, "COORD-5 setup: autoPauseForSystem before start() pauses coordinator")
            sleepCoord.start()
            expect(sleepCoord.hasStarted, "COORD-5: start() marks coordinator as started")
            expect(sleepCoord.isPaused, "COORD-5: start() preserves pre-existing system auto-pause")

            // Mark capture engine running in-memory so wake-time reconfigure avoids touching CoreAudio hardware in tests
            sleepCoord.audioCaptureEngine.processBuffersForTesting(callerBuffer: nil, micBuffer: nil)
            sleepCoord.autoResumeAfterSystem(reason: .systemSleep)
            expect(!sleepCoord.isPaused, "COORD-5: autoResumeAfterSystem(.systemSleep) resumes because start() preserved autoPausedForSystem")
            sleepCoord.stop()
        } else {
            expect(false, "COORD-5: failed to create isolated UserDefaults suite")
        }
    }

    static func testPerformanceAndArchitectureOptimizations() async {
        print("[Suite] Performance and architecture optimizations")

        // 1. RingBuffer wrap-around, suffix, removeFirst, removeAll(where:) & LRUCache recency promotion
        var ring = RingBuffer<Int>()
        for v in 1...8 { ring.append(v) }
        expectEqual(ring.popFirst(), 1, "OPT-1: popFirst returns oldest element")
        expectEqual(ring.popFirst(), 2, "OPT-1: popFirst advances head (2)")
        expectEqual(ring.popFirst(), 3, "OPT-1: popFirst advances head (3)")
        ring.append(9)
        ring.append(10)
        ring.append(11)
        expectEqual(ring.toArray(), [4, 5, 6, 7, 8, 9, 10, 11], "OPT-1: wrap-around preserves logical order")
        ring.append(12)
        expectEqual(ring.toArray(), [4, 5, 6, 7, 8, 9, 10, 11, 12], "OPT-1: growth after wrap-around preserves order")
        expectEqual(ring.suffix(3), [10, 11, 12], "OPT-1: suffix(3) across wrapped storage")
        ring.removeFirst(2)
        expectEqual(ring.toArray(), [6, 7, 8, 9, 10, 11, 12], "OPT-1: removeFirst(2) advances head")
        ring.removeAll { $0 % 2 == 1 }
        expectEqual(ring.toArray(), [6, 8, 10, 12], "OPT-1: in-place removeAll(where:) filters elements")

        var lru = LRUCache<String, Int>(maxCapacity: 3)
        lru.put("a", value: 1)
        lru.put("b", value: 2)
        lru.put("c", value: 3)
        expectEqual(lru.get("a"), 1, "OPT-1: get(a) promotes a to MRU")
        lru.put("d", value: 4)
        expectEqual(lru.get("b"), nil, "OPT-1: LRU element b evicted after promoting a")
        expectEqual(lru.get("a"), 1, "OPT-1: promoted key a survives eviction")
        expectEqual(lru.get("c"), 3, "OPT-1: c survives eviction")
        expectEqual(lru.get("d"), 4, "OPT-1: d present")

        // 2. LiveShareCrypto single-pass Base64URL & direct JSON envelope construction
        for len in 0...35 {
            let bytes = Data((0..<len).map { UInt8(($0 * 37 + 13) & 0xFF) })
            let encoded = LiveShareCrypto.base64URLEncode(bytes)
            expect(!encoded.contains("+") && !encoded.contains("/") && !encoded.contains("="), "OPT-2: url-safe encoding for len=\(len)")
            expectEqual(LiveShareCrypto.base64URLDecode(encoded), bytes, "OPT-2: Base64URL round-trip len=\(len)")
        }
        expectEqual(LiveShareCrypto.base64URLDecode("TQ=="), Data("M".utf8), "OPT-2: padded base64 TQ==")
        expectEqual(LiveShareCrypto.base64URLDecode("SGk="), Data("Hi".utf8), "OPT-2: padded base64 SGk=")
        expectEqual(LiveShareCrypto.base64URLDecode("A"), nil, "OPT-2: rejects single leftover char")
        expectEqual(LiveShareCrypto.base64URLDecode("A==="), nil, "OPT-2: rejects triple padding")
        expectEqual(LiveShareCrypto.base64URLDecode("ab$d"), nil, "OPT-2: rejects invalid base64 char")

        let crypto = LiveShareCrypto()
        let samplePayload = Data("{\"hello\":\"world\"}".utf8)
        do {
            let basicEnvelope = try crypto.seal(samplePayload)
            let jsonObj = try JSONSerialization.jsonObject(with: basicEnvelope) as? [String: Any]
            expectEqual(jsonObj?["v"] as? Int, 1, "OPT-2: direct seal() writes v=1")
            expect(jsonObj?["d"] is String, "OPT-2: direct seal() writes d string")
            expectEqual(try crypto.open(basicEnvelope), samplePayload, "OPT-2: direct seal() round-trips")

            let typedEnvelope = try crypto.seal(samplePayload, type: "caption", sequence: 42)
            let typedJSON = try JSONSerialization.jsonObject(with: typedEnvelope) as? [String: Any]
            expectEqual(typedJSON?["t"] as? String, "caption", "OPT-2: direct typed seal() writes type")
            expectEqual((typedJSON?["s"] as? NSNumber)?.uint64Value, 42, "OPT-2: direct typed seal() writes sequence")
            let opened = try crypto.openWithMetadata(typedEnvelope, expectedType: "caption", minimumSequence: 42)
            expectEqual(opened.data, samplePayload, "OPT-2: direct typed seal() round-trips")
            expectEqual(opened.type, "caption", "OPT-2: direct typed seal() preserves type")
            expectEqual(opened.sequence, 42, "OPT-2: direct typed seal() preserves sequence")

            let fallbackEnvelope = try crypto.seal(samplePayload, type: "caption\"quoted\\é", sequence: 99)
            let fallbackOpened = try crypto.openWithMetadata(fallbackEnvelope, expectedType: "caption\"quoted\\é", minimumSequence: 99)
            expectEqual(fallbackOpened.data, samplePayload, "OPT-2: escaped fallback type round-trips")
        } catch {
            expect(false, "OPT-2: LiveShareCrypto seal/open threw \(error)")
        }

        // 3. AudioCaptureEngine sustained digital silence fast path & immediate speech onset
        final class OptAudioSpy: AudioCaptureDelegate, @unchecked Sendable {
            let lock = OSAllocatedUnfairLock(initialState: 0)
            func audioCaptureDidOutputCallerAudio(pcmBuffer: AVAudioPCMBuffer) {
                lock.withLock { $0 += 1 }
            }
            func audioCaptureDidOutputMicAudio(pcmBuffer: AVAudioPCMBuffer) {}
            func audioCaptureDidEncounterError(_ error: Error) {}
            func audioCaptureDidUpdateLevels(callerLevel: Float, micLevel: Float) {}
            func audioCaptureDidDetectDeniedTapPermission() {}
            func audioCaptureDidRestoreTapPermission() {}
        }
        AudioCaptureEngine.overrideAcousticIsolation = false
        defer { AudioCaptureEngine.overrideAcousticIsolation = nil }

        let optEngine = AudioCaptureEngine()
        let optSpy = OptAudioSpy()
        optEngine.delegate = optSpy
        guard let optFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let silentBuf = AVAudioPCMBuffer(pcmFormat: optFmt, frameCapacity: 1024),
              let loudBuf = AVAudioPCMBuffer(pcmFormat: optFmt, frameCapacity: 1024) else {
            expect(false, "OPT-3: failed to create test 16k mono buffers")
            return
        }
        silentBuf.frameLength = 1024
        if let sPtr = silentBuf.floatChannelData?[0] {
            for i in 0..<1024 { sPtr[i] = 0 }
        }
        loudBuf.frameLength = 1024
        if let lPtr = loudBuf.floatChannelData?[0] {
            for i in 0..<1024 { lPtr[i] = 0.05 }
        }
        for _ in 0..<15 {
            optEngine.processBuffersForTesting(callerBuffer: silentBuf, micBuffer: nil)
        }
        expectEqual(optSpy.lock.withLock { $0 }, 0, "OPT-3: sustained silence emits zero caller buffers")
        optEngine.processBuffersForTesting(callerBuffer: loudBuf, micBuffer: nil)
        expect(optSpy.lock.withLock { $0 } >= 1, "OPT-3: immediate speech onset exits silence fast path")
        optEngine.stop()

        // 4. CaptionViewModel split finalized/live slots & SurfaceVisibilityState gating
        let optSuite = "com.callcaption.tests.opt.\(UUID().uuidString)"
        if let optDefaults = UserDefaults(suiteName: optSuite) {
            defer { optDefaults.removePersistentDomain(forName: optSuite) }
            let coord = CaptionCoordinator(defaults: optDefaults, liveShareManager: LiveShareManager.shared)
            let vm = coord.viewModel
            let uCaller = UUID()
            let uMic = UUID()

            coord.callerSpeechDidUpdate(utteranceID: uCaller, partialOriginal: "Hola", partialTranslated: "Hi", sourceLangCode: "es", targetLangCode: "en", isUntranslated: false)
            await expectEventually("OPT-4: partial caller enters liveCallerEntry without mutating finalizedEntries", timeout: 1.0) {
                vm.liveCallerEntry?.id == uCaller && vm.finalizedEntries.isEmpty && vm.entries.count == 1
            }

            coord.micSpeechDidUpdate(utteranceID: uMic, partialOriginal: "Hello", partialTranslated: "Hola", sourceLangCode: "en", targetLangCode: "es", isUntranslated: false)
            await expectEventually("OPT-4: partial mic enters liveMicEntry without mutating finalizedEntries", timeout: 1.0) {
                vm.liveMicEntry?.id == uMic && vm.finalizedEntries.isEmpty && vm.entries.count == 2
            }

            coord.callerSpeechDidFinalize(utteranceID: uCaller, original: "Hola amigos", translated: "Hi friends", sourceLangCode: "es", targetLangCode: "en", isUntranslated: false)
            await expectEventually("OPT-4: finalized caller moves from liveCallerEntry to finalizedEntries", timeout: 1.0) {
                vm.liveCallerEntry == nil && vm.finalizedEntries.count == 1 && vm.entries.count == 2
            }

            let visibility = SurfaceVisibilityState(isVisible: false)
            let hiddenHost = NSHostingController(
                rootView: CaptionPopoverView(viewModel: vm, onQuit: {}, surfaceVisibility: visibility)
                    .frame(width: 400, height: 480)
            )
            hiddenHost.view.frame = NSRect(x: 0, y: 0, width: 400, height: 480)
            hiddenHost.view.layoutSubtreeIfNeeded()
            visibility.isVisible = true
            await settleMain(hops: 2)
            hiddenHost.view.layoutSubtreeIfNeeded()
            let shownSize = hiddenHost.view.fittingSize
            expect(shownSize.width >= 320 && shownSize.width <= 460, "OPT-4: SurfaceVisibilityState restores constrained fittingSize (\(shownSize))")
        } else {
            expect(false, "OPT-4: failed to create isolated UserDefaults suite")
        }

        // 5. ReceiverWebAppHTML compiled template & cached JS DOM card references
        let html = ReceiverWebAppHTML.html(forToken: "tok123", encryptPayloads: true, acceptLanguage: "es-MX, en;q=0.8")
        expect(html.contains("/s/tok123"), "OPT-5: rendered HTML injects token path")
        expect(html.contains("<html lang=\"es\""), "OPT-5: rendered HTML injects resolved lang attribute")
        let remainingTokens = ["__SESSION_BASE_PATH__", "__PAYLOAD_ENCRYPTED__", "__HTML_LANG__", "__HTML_DIR__", "__WEB_TITLE__", "__WEB_L10N_JSON__"]
        for tok in remainingTokens {
            expect(!html.contains(tok), "OPT-5: compiled template substituted \(tok)")
        }

        if let sStart = html.range(of: "<script>"),
           let sEnd = html.range(of: "</script>", range: sStart.upperBound..<html.endIndex),
           let jsCtx = JSContext() {
            let scriptBody = String(html[sStart.upperBound..<sEnd.lowerBound])
            var jsErrors: [String] = []
            jsCtx.exceptionHandler = { _, exc in
                if let msg = exc?.toString() { jsErrors.append(msg) }
            }
            let harness = """
            function makeClassList(el) {
                return {
                    _set: new Set((el._className || '').split(/\\s+/).filter(Boolean)),
                    _sync() { el._className = Array.from(this._set).join(' '); },
                    add(c) { this._set.add(c); this._sync(); },
                    remove(c) { this._set.delete(c); this._sync(); },
                    toggle(c, force) { const a = (force !== undefined) ? !!force : !this._set.has(c); if (a) this._set.add(c); else this._set.delete(c); this._sync(); return a; },
                    contains(c) { return this._set.has(c); }
                };
            }
            function makeElement(tag, id, className) {
                const el = {
                    tagName: (tag || 'DIV').toUpperCase(),
                    id: id || '',
                    _className: className || '',
                    textContent: '',
                    value: '',
                    disabled: false,
                    checked: true,
                    offsetHeight: 0,
                    parentNode: null,
                    children: [],
                    attributes: {},
                    _listeners: {},
                    style: { setProperty(k, v) { this[k] = v; }, removeProperty(k) { delete this[k]; } },
                    setAttribute(k, v) { this.attributes[k] = String(v); },
                    getAttribute(k) { return Object.prototype.hasOwnProperty.call(this.attributes, k) ? this.attributes[k] : null; },
                    removeAttribute(k) { delete this.attributes[k]; },
                    addEventListener(type, fn) { (this._listeners[type] = this._listeners[type] || []).push(fn); },
                    appendChild(child) { child.parentNode = this; this.children.push(child); return child; },
                    insertBefore(newNode, refNode) { newNode.parentNode = this; const idx = this.children.indexOf(refNode); if (idx >= 0) this.children.splice(idx, 0, newNode); else this.children.push(newNode); return newNode; },
                    removeChild(child) { const idx = this.children.indexOf(child); if (idx >= 0) { this.children.splice(idx, 1); child.parentNode = null; } return child; },
                    contains(target) { if (this === target) return true; for (let i = 0; i < this.children.length; i++) { if (this.children[i].contains(target)) return true; } return false; },
                    getBoundingClientRect() { return { top: 0 }; },
                    querySelectorAll(sel) {
                        const out = [];
                        (function walk(node) {
                            for (let i = 0; i < node.children.length; i++) {
                                const ch = node.children[i];
                                if (sel.startsWith('.') && ch.classList.contains(sel.slice(1))) out.push(ch);
                                else if (sel === '[data-speaker="Caller"]' && ch.getAttribute('data-speaker') === 'Caller') out.push(ch);
                                walk(ch);
                            }
                        })(this);
                        return out;
                    },
                    querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
                };
                el.classList = makeClassList(el);
                Object.defineProperty(el, 'className', { get() { return this._className; }, set(v) { this._className = String(v || ''); this.classList = makeClassList(this); } });
                Object.defineProperty(el, 'innerHTML', { get() { return ''; }, set() { this.children.forEach(c => { c.parentNode = null; }); this.children = []; } });
                Object.defineProperty(el, 'firstElementChild', { get() { return this.children[0] || null; } });
                Object.defineProperty(el, 'nextElementSibling', { get() { if (!this.parentNode) return null; const s = this.parentNode.children; const i = s.indexOf(this); return (i >= 0 && i + 1 < s.length) ? s[i + 1] : null; } });
                return el;
            }
            const elementsById = {};
            function reg(tag, id, cls) { const e = makeElement(tag, id, cls); elementsById[id] = e; return e; }
            const docEl = makeElement('HTML', '', ''), bodyEl = makeElement('BODY', '', 'show-orig');
            docEl.appendChild(bodyEl);
            const esEl = reg('DIV', 'empty-state', 'empty-state');
            esEl.appendChild(makeElement('H2', '', 'empty-state-title'));
            bodyEl.appendChild(esEl);
            bodyEl.appendChild(reg('DIV', 'caption-stream', 'caption-stream'));
            bodyEl.appendChild(reg('DIV', 'sr-live-announcer', 'sr-only'));
            bodyEl.appendChild(reg('DIV', 'conn-pill', 'status-pill connecting'));
            bodyEl.appendChild(reg('SPAN', 'conn-label', ''));
            bodyEl.appendChild(reg('SPAN', 'viewer-count', 'viewer-count'));
            bodyEl.appendChild(reg('DIV', 'autoscroll-pill', 'floating-bottom'));
            bodyEl.appendChild(reg('INPUT', 'autoscroll-toggle', ''));
            bodyEl.appendChild(reg('BUTTON', 'jump-latest-btn', 'jump-latest-btn'));
            bodyEl.appendChild(reg('BUTTON', 'copy-transcript-btn', 'btn'));
            bodyEl.appendChild(reg('BUTTON', 'view-mode-btn', 'btn'));
            bodyEl.appendChild(reg('BUTTON', 'orig-toggle-btn', 'btn active'));
            bodyEl.appendChild(reg('BUTTON', 'font-dec-btn', 'btn'));
            bodyEl.appendChild(reg('BUTTON', 'font-inc-btn', 'btn'));
            var window = globalThis;
            window.scrollY = 0; window.innerHeight = 800; window.location = { hash: '' };
            window.performance = { now() { return 1000; } };
            window.localStorage = { getItem() { return null; }, setItem() {} };
            window.matchMedia = () => ({ matches: true });
            window.scrollTo = () => {}; window.addEventListener = () => {};
            window.requestAnimationFrame = cb => { cb(); return 1; };
            window.setTimeout = () => 1; window.clearTimeout = () => {};
            window.navigator = {};
            window.EventSource = function(url) { this.url = url; this.readyState = 1; this.addEventListener = () => {}; this.close = () => { this.readyState = 2; }; };
            var location = window.location, performance = window.performance, navigator = window.navigator, EventSource = window.EventSource, requestAnimationFrame = window.requestAnimationFrame, setTimeout = window.setTimeout, clearTimeout = window.clearTimeout;
            var document = { documentElement: docEl, scrollingElement: docEl, body: bodyEl, visibilityState: 'visible', getElementById(id) { return elementsById[id] || null; }, createElement(t) { return makeElement(t, '', ''); }, addEventListener() {}, getSelection() { return { rangeCount: 0, removeAllRanges() {}, addRange() {} }; }, execCommand() { return true; } };
            """
            _ = jsCtx.evaluateScript(harness)
            _ = jsCtx.evaluateScript(scriptBody)
            _ = jsCtx.evaluateScript("""
                handleCaptionEvent({ id: 'opt1', speaker: 'Caller', originalText: 'Hola', translatedText: 'Hello', isFinal: false });
                handleCaptionEvent({ id: 'opt2', speaker: 'You', originalText: 'Hi', translatedText: 'Hola', isFinal: true });
            """)
            expect(jsErrors.isEmpty, "OPT-5: receiver JS executed cleanly (errors: \(jsErrors))")
            expectEqual(jsCtx.evaluateScript("liveSlots['Caller'] && !!liveSlots['Caller']._transEl && !!liveSlots['Caller']._origEl && !!liveSlots['Caller']._timeEl && !!liveSlots['Caller']._untransBadge")?.toBool() ?? false, true, "OPT-5: card attaches cached child refs")
            expectEqual(jsCtx.evaluateScript("liveSlots['Caller']?._speaker")?.toString() ?? "", "Caller", "OPT-5: cached _speaker set")
            expectEqual(jsCtx.evaluateScript("liveSlots['Caller']?._hasText")?.toBool() ?? false, true, "OPT-5: cached _hasText set")
            expectEqual(jsCtx.evaluateScript("getVisibleCards().length")?.toInt32() ?? -1, 2, "OPT-5: getVisibleCards returns 2 cards before host filter")
            _ = jsCtx.evaluateScript("hostFocusMode = true; applySpeakerFilter();")
            expectEqual(jsCtx.evaluateScript("getVisibleCards().length")?.toInt32() ?? -1, 1, "OPT-5: hostFocusMode hides Caller card")
            expectEqual(jsCtx.evaluateScript("getVisibleCards()[0]?._speaker")?.toString() ?? "", "You", "OPT-5: remaining visible card is Host (You)")
        } else {
            expect(false, "OPT-5: failed to extract inline script or create JSContext")
        }
    }
}

@main
struct CallCaptionTestMain {
    static func main() async {
        let code = await TestSuite.runAll()
        exit(code)
    }
}
