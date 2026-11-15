import Foundation
import AppKit
import SwiftUI
import AVFoundation
import Accelerate
import Speech
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

    static func runAll() async -> Int32 {
        print("Running minimal Call Caption unit test suite...")

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
            }
        }
        if let rawObj = (try? JSONSerialization.jsonObject(with: sealed)) as? [String: Any] {
            for (k, v) in [("v", true as Any), ("v", 2 as Any), ("s", true as Any)] {
                var bad = rawObj
                bad[k] = v
                if let data = try? JSONSerialization.data(withJSONObject: bad) {
                    expect((try? crypto.open(data, expectedType: "state")) == nil, "Invalid header \(k)=\(v) fails closed")
                }
            }
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
            expect(updated.contains("other.example.com") && updated.contains("localhost.run"), "Existing keys preserved alongside pinned keys")

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
        for _ in 0..<60 {
            if let url = manager.localShareURL, manager.isSharing {
                localURL = url
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
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
            expect(html.contains("/s/\(token)") && html.contains("'/events'"), "Receiver HTML contains token & SSE endpoint")

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
        for _ in 0..<40 {
            if manager.activeClientCount == 20 { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        expectEqual(manager.activeClientCount, 20, "All 20 SSE viewers registered")
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
        for _ in 0..<40 {
            if manager.isSharing && manager.localShareURL != nil { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
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

        // Int32 non-interleaved stereo conversion
        if let fmt32 = AVAudioFormat(commonFormat: .pcmFormatInt32, sampleRate: 48000, channels: 2, interleaved: false),
           let buf32 = AVAudioPCMBuffer(pcmFormat: fmt32, frameCapacity: 128) {
            buf32.frameLength = 128
            if let i32 = buf32.int32ChannelData {
                for i in 0..<128 {
                    i32[0][i] = 1_073_741_824 // 0.5
                    i32[1][i] = 1_073_741_824 // 0.5
                }
            }
            expect(engine.convertAndCopyToMono(source: buf32, destination: monoOut), "Int32 stereo converts to Float32 mono")
            expectEqual(monoOut.frameLength, 128, "Frame length preserved")
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

        // Floor arbitration
        expectEqual(AudioCaptureEngine.resolveFloorOwner(current: .none, isCallerActive: false, isUserActive: true), .user, "User takes idle floor")
        expectEqual(AudioCaptureEngine.resolveFloorOwner(current: .user, isCallerActive: true, isUserActive: true), .user, "User keeps floor during caller bleed")
        expectEqual(AudioCaptureEngine.resolveFloorOwner(current: .caller, isCallerActive: true, isUserActive: true), .caller, "Caller keeps floor during overlap")
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
        mgr.feedCallerAudioBuffer(buf, userHasFloor: true)
        expect(!mgr.micChannel.isSuspended, "User floor prevents caller bleed from suspending mic")
        mgr.isAcousticallyIsolated = true
        mgr.feedCallerAudioBuffer(buf, userHasFloor: false)
        expect(!mgr.micChannel.isSuspended, "Headphones allow simultaneous caller + mic recognition")
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

        // SwiftUI hosting check
        let popoverView = CaptionPopoverView(viewModel: vm, onQuit: {})
        let hosting = NSHostingController(rootView: popoverView)
        expect(hosting.view.fittingSize.width >= 400 && hosting.view.fittingSize.height >= 500, "CaptionPopoverView lays out with non-trivial dimensions")

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
        try? await Task.sleep(for: .milliseconds(30))
        expectEqual(vm.entries.count, 1, "Partial entry inserted")
        expectEqual(vm.entries.first?.isFinal, false, "Partial marked not final")

        coordinator.callerSpeechDidFinalize(utteranceID: u1, original: "Hola mundo", translated: "Hello world", sourceLangCode: "es", targetLangCode: "en", isUntranslated: false)
        try? await Task.sleep(for: .milliseconds(30))
        expectEqual(vm.entries.count, 1, "Final replaces partial in-place with same UUID")
        expectEqual(vm.entries.first?.isFinal, true, "Entry marked finalized")
        expectEqual(vm.entries.first?.translated, "Hello world", "Final translation updated")

        let u2 = UUID()
        coordinator.micSpeechDidFinalize(utteranceID: u2, original: "Hi back", translated: "Hola de vuelta", sourceLangCode: "en", targetLangCode: "es", isUntranslated: false)
        try? await Task.sleep(for: .milliseconds(30))
        expectEqual(vm.entries.count, 2, "Second speaker utterance appended")

        coordinator.setShowOriginalText(true)
        let exported = coordinator.copyTranscript()
        expect(exported.contains("[Caller] Hello world") && exported.contains("(Hola mundo)"), "Transcript export formats speaker + original")
        expect(exported.contains("[You] Hola de vuelta"), "Transcript export includes user reply")

        coordinator.clearTranscript()
        try? await Task.sleep(for: .milliseconds(30))
        expectEqual(vm.entries.count, 0, "clearTranscript removes all captions")

        // Alert prioritization
        coordinator.speechRecognitionDidEncounterAuthError(channelName: "caller", message: "Speech Recognition access required")
        coordinator.audioCaptureDidDetectDeniedTapPermission()
        try? await Task.sleep(for: .milliseconds(30))
        expectEqual(vm.alertAction, .audioCapture, "Audio capture alert outranks speech alert")
        coordinator.dismissPresentedAlert()
        try? await Task.sleep(for: .milliseconds(30))
        expectEqual(vm.alertAction, .speechRecognition, "Dismissing audio capture reveals lower-priority speech alert")
        coordinator.speechRecognitionDidClearAuthError(channelName: "caller")
        try? await Task.sleep(for: .milliseconds(30))
        expect(vm.alertMessage == nil, "Clearing speech alert clears banner")

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
}

@main
struct CallCaptionTestMain {
    static func main() async {
        let code = await TestSuite.runAll()
        exit(code)
    }
}
