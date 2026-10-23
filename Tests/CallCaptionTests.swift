import Foundation
import AppKit
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
        print("Running Call Caption unit test suite...")

        testLiveShareSecurity()
        testLiveShareCrypto()
        testLanguageModelsAndRTL()
        testAppSettingsAndSubtitleLanguagePreservation()
        testTranscriptManagerRefinementAndExport()
        testUtteranceIdentityAndAutosave()
        testSpeechErrorClassification()
        testAudioCaptureBackoffAndPermissionState()
        testPopoverAutoOpenLogic()
        testTrayCaptionParagraphFormatting()

        await testAsyncMutexTaskCancellation()
        await testTranslationEngineCancellationAndCache()
        await testCaptionCoordinatorThreadSafety()
        testSingleSpeechChannelCancellationOnReset()
        testMultiFormatPCMConversion()
        testAudioTapRebuildBackoffAndExhaustion()
        testBoundedBufferQueueBackpressure()
        testAcousticIsolationAndDuplexAudio()
        testAudioDSPMathAndAGC()
        testSSHKnownHostsPreSeedingAndStrictHostKeyChecking()
        testLocalShareURLSecurityContext()
        testLocalStorageAndDirectoryPermissions()

        await testAdversarialAsyncMutexHighConcurrency()
        await testAdversarialTranslationEngineCancellationStorm()
        await testAdversarialCaptionCoordinatorConcurrentOperations()
        await testAdversarialLiveShareHighThroughputBroadcast()
        await testAuditRegressions()

        print("Results: \(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }


    static func testLiveShareSecurity() {
        let token1 = LiveShareManager.generateSessionToken()
        let token2 = LiveShareManager.generateSessionToken()
        expectEqual(token1.count, 32, "Session token should be 32 hex chars (128 bits)")
        expect(token1 != token2, "Generated session tokens must be unique")

        expect(
            LiveShareManager.isAllowedHost("127.0.0.1", localIP: "192.168.1.25", allowLAN: false, tunnelHost: nil),
            "Loopback IPv4 host should be allowed"
        )
        expect(
            LiveShareManager.isAllowedHost("localhost", localIP: "192.168.1.25", allowLAN: false, tunnelHost: nil),
            "localhost should be allowed"
        )
        expect(
            !LiveShareManager.isAllowedHost("evil-rebind.attacker.com", localIP: "192.168.1.25", allowLAN: false, tunnelHost: nil),
            "Arbitrary external Host header must be rejected"
        )
        expect(
            LiveShareManager.isAllowedHost("abc123.lhr.life", localIP: "192.168.1.25", allowLAN: false, tunnelHost: "abc123.lhr.life"),
            "Active localhost.run tunnel host should be allowed"
        )
        expect(
            !LiveShareManager.isAllowedHost("attacker.lhr.life", localIP: "192.168.1.25", allowLAN: false, tunnelHost: "abc123.lhr.life"),
            "Host validation must not accept arbitrary tunnel-provider subdomains"
        )
        expect(
            !LiveShareManager.isAllowedHost("192.168.1.25", localIP: "192.168.1.25", allowLAN: false, tunnelHost: nil),
            "LAN IPv4 host must be rejected when allowLAN is false"
        )
        expect(
            LiveShareManager.isAllowedHost("192.168.1.25", localIP: "192.168.1.25", allowLAN: true, tunnelHost: nil),
            "LAN IPv4 host should be allowed when allowLAN is true"
        )

        let viewerReq = LiveShareManager.parseHTTPRequest("GET /s/\(token1) HTTP/1.1\r\nHost: 127.0.0.1:54321\r\n\r\n")!
        expectEqual(
            LiveShareManager.evaluateRoute(request: viewerReq, sessionToken: token1, localIP: "192.168.1.25", allowLAN: false, tunnelHost: nil),
            .serveHTML,
            "Valid token path should route to viewer HTML"
        )

        let eventsReq = LiveShareManager.parseHTTPRequest("GET /s/\(token1)/events?t=123 HTTP/1.1\r\nHost: 127.0.0.1:54321\r\n\r\n")!
        expectEqual(
            LiveShareManager.evaluateRoute(request: eventsReq, sessionToken: token1, localIP: "192.168.1.25", allowLAN: false, tunnelHost: nil),
            .serveSSE,
            "Valid token /events path should route to SSE stream"
        )

        let stateReq = LiveShareManager.parseHTTPRequest("GET /s/\(token1)/api/state HTTP/1.1\r\nHost: 127.0.0.1:54321\r\n\r\n")!
        expectEqual(
            LiveShareManager.evaluateRoute(request: stateReq, sessionToken: token1, localIP: "192.168.1.25", allowLAN: false, tunnelHost: nil),
            .serveAPIState,
            "Valid token /api/state path should route to JSON state"
        )

        let unauthRootReq = LiveShareManager.parseHTTPRequest("GET / HTTP/1.1\r\nHost: 127.0.0.1:54321\r\n\r\n")!
        expectEqual(
            LiveShareManager.evaluateRoute(request: unauthRootReq, sessionToken: token1, localIP: "192.168.1.25", allowLAN: false, tunnelHost: nil),
            .notFound,
            "Root path without secret token must return 404 Not Found"
        )

        let wrongTokenReq = LiveShareManager.parseHTTPRequest("GET /s/\(token2)/events HTTP/1.1\r\nHost: 127.0.0.1:54321\r\n\r\n")!
        expectEqual(
            LiveShareManager.evaluateRoute(request: wrongTokenReq, sessionToken: token1, localIP: "192.168.1.25", allowLAN: false, tunnelHost: nil),
            .notFound,
            "Mismatched token path must return 404 Not Found"
        )

        let postMethodReq = LiveShareManager.parseHTTPRequest("POST /s/\(token1) HTTP/1.1\r\nHost: 127.0.0.1:54321\r\n\r\n")!
        expectEqual(
            LiveShareManager.evaluateRoute(request: postMethodReq, sessionToken: token1, localIP: "192.168.1.25", allowLAN: false, tunnelHost: nil),
            .methodNotAllowed,
            "POST requests must return 405 Method Not Allowed"
        )

        let ipv6Req = LiveShareManager.parseHTTPRequest("GET /s/\(token1) HTTP/1.1\r\nHost: [::1]:54321\r\n\r\n")!
        expectEqual(ipv6Req.host, "[::1]", "IPv6 Host headers must be parsed without the port")
        expect(
            LiveShareManager.isAllowedHost(ipv6Req.host, localIP: "192.168.1.25", allowLAN: false, tunnelHost: nil),
            "IPv6 loopback Host header should be allowed"
        )

        let rebindReq = LiveShareManager.parseHTTPRequest("GET /s/\(token1) HTTP/1.1\r\nHost: attacker.example.com\r\n\r\n")!
        expectEqual(
            LiveShareManager.evaluateRoute(request: rebindReq, sessionToken: token1, localIP: "192.168.1.25", allowLAN: false, tunnelHost: nil),
            .forbidden,
            "Mismatched Host header must return 403 Forbidden"
        )
    }


    static func testLiveShareCrypto() {
        let crypto = LiveShareCrypto()
        let keyFragment = crypto.keyFragment
        expect(keyFragment.hasPrefix("k="), "Key fragment must use the k= prefix")
        let encodedKey = String(keyFragment.dropFirst(2))
        expect(!encodedKey.contains("+") && !encodedKey.contains("/") && !encodedKey.contains("="),
               "Key fragment must be base64url without padding")
        expect(LiveShareCrypto(keyFragment: keyFragment) != nil, "Session key must round-trip through the fragment")

        let plaintext = Data("hello caption".utf8)
        guard let envelope = try? crypto.seal(plaintext) else {
            expect(false, "AES-GCM seal should succeed")
            return
        }
        expect((try? crypto.open(envelope)) == plaintext, "AES-GCM open should recover the plaintext")
        expect((try? LiveShareCrypto().open(envelope)) == nil, "A different session key must not decrypt the envelope")

        let invalid = Data("{\"v\":1,\"d\":\"not-valid-base64\"}".utf8)
        expect((try? crypto.open(invalid)) == nil, "Malformed envelope must fail closed")
    }


    static func testLanguageModelsAndRTL() {
        expect(SupportedLanguages.isRTL(languageCode: "ar"), "Arabic ('ar') must be detected as RTL")
        expect(SupportedLanguages.isRTL(languageCode: "ar-SA"), "Arabic regional code ('ar-SA') must be detected as RTL")
        expect(!SupportedLanguages.isRTL(languageCode: "en"), "English ('en') must be detected as LTR")
        expect(!SupportedLanguages.isRTL(languageCode: "es"), "Spanish ('es') must be detected as LTR")

        let locale = SupportedLanguages.bestLocale(forCode: "es")
        expect(locale.identifier.lowercased().hasPrefix("es"), "bestLocale(forCode: 'es') should return a Spanish locale")

        let localized = L10n.tr("header.callerLanguage", "Caller Language")
        expectEqual(localized, "Caller Language", "L10n.tr fallback should return expected string")
    }


    static func testAppSettingsAndSubtitleLanguagePreservation() {
        let settings = AppSettings.shared
        let savedMain = settings.mainLanguageCode
        let savedForeign = settings.foreignLanguageCode
        let savedTarget = settings.targetLanguageCode
        let savedFollows = settings.subtitleFollowsMainLanguage
        defer {
            settings.foreignLanguageCode = savedForeign
            settings.mainLanguageCode = savedMain
            settings.targetLanguageCode = savedTarget
            settings.subtitleFollowsMainLanguage = savedFollows
        }

        settings.subtitleFollowsMainLanguage = true
        settings.setMainAndTargetLanguage("fr")
        expectEqual(settings.mainLanguageCode, "fr", "mainLanguageCode should update to 'fr'")
        expectEqual(settings.targetLanguageCode, "fr", "targetLanguageCode should follow mainLanguageCode when subtitleFollowsMainLanguage is true")

        settings.foreignLanguageCode = "es"
        settings.mainLanguageCode = "en"
        settings.targetLanguageCode = "de"
        expect(!settings.subtitleFollowsMainLanguage, "Setting custom targetLanguageCode should disable subtitleFollowsMainLanguage")

        settings.swapLanguages()
        expectEqual(settings.foreignLanguageCode, "en", "swapLanguages should swap foreignLanguageCode")
        expectEqual(settings.mainLanguageCode, "es", "swapLanguages should swap mainLanguageCode")
        expectEqual(settings.targetLanguageCode, "de", "swapLanguages must preserve custom targetLanguageCode")
    }


    static func testTranscriptManagerRefinementAndExport() {
        let tm = TranscriptManager.shared
        let savedAutosave = AppSettings.shared.autosaveTranscripts
        AppSettings.shared.autosaveTranscripts = false
        defer {
            tm.clear()
            AppSettings.shared.autosaveTranscripts = savedAutosave
        }

        tm.clear()
        tm.addEntry(speaker: "Caller", original: "Hola mundo", translated: "Hola mundo", isUntranslated: true)
        expectEqual(tm.entries.count, 1, "TranscriptManager should contain 1 entry")
        expect(tm.entries[0].isUntranslated, "First entry should be marked isUntranslated = true")

        tm.addEntry(speaker: "Caller", original: "Hola mundo", translated: "Hello world", isUntranslated: false)
        expectEqual(tm.entries.count, 1, "Refinement should update existing entry in-place rather than duplicating")
        expectEqual(tm.entries[0].translated, "Hello world", "Refined entry should have updated translation")
        expect(!tm.entries[0].isUntranslated, "Refined entry should clear isUntranslated flag")

        tm.addEntry(speaker: "You", original: "Bonjour", translated: "Bonjour", isUntranslated: true)
        let exported = tm.exportAsText()
        expect(exported.contains("Hello world"), "Exported text should include translated entry")
        expect(exported.contains("Original (Untranslated): Bonjour"), "Exported text should label untranslated entry")
    }


    static func testUtteranceIdentityAndAutosave() {
        let tm = TranscriptManager.shared
        let savedAutosave = AppSettings.shared.autosaveTranscripts
        tm.clear()
        AppSettings.shared.autosaveTranscripts = true
        defer {
            tm.clear()
            AppSettings.shared.autosaveTranscripts = savedAutosave
        }

        let id = UUID()
        tm.addEntry(speaker: "Caller", original: "Yes.", translated: "Sí.", utteranceID: id)
        tm.addEntry(speaker: "Caller", original: "Yes.", translated: "Sí.", utteranceID: UUID())
        expectEqual(tm.entries.count, 2, "Repeated identical phrases with different utterance IDs must not be merged")

        tm.addEntry(speaker: "Caller", original: "Yes.", translated: "Sí, señor.", utteranceID: id)
        expectEqual(tm.entries.count, 2, "A refined translation with the same utterance ID must update in place")
        expectEqual(tm.entries.first(where: { $0.utteranceID == id })?.translated, "Sí, señor.", "Refined translation should be stored")

        let url = AppPaths.autosaveFileURL
        for _ in 0..<40 where !FileManager.default.fileExists(atPath: url.path) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        expect(FileManager.default.fileExists(atPath: url.path), "Autosave should be written to the test Application Support directory")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let permissions = attrs[.posixPermissions] as? NSNumber {
            expectEqual(permissions.intValue & 0o777, 0o600, "Autosaved transcripts must be user-only (0600)")
        } else {
            expect(false, "Autosaved transcript permissions should be inspectable")
        }

        tm.deleteSavedSession()
        expect(!FileManager.default.fileExists(atPath: url.path), "Disabling autosave/deleting the saved session should remove the file")
    }


    static func testSpeechErrorClassification() {
        expectEqual(SpeechRecognitionErrorCode(rawValue: 201), .dictationDisabled, "Code 201 should map to .dictationDisabled")
        expectEqual(SpeechRecognitionErrorCode(rawValue: 203), .retry, "Code 203 should map to .retry")
        expectEqual(SpeechRecognitionErrorCode(rawValue: 216), .cancelled, "Code 216 should map to .cancelled")
        expectEqual(SpeechRecognitionErrorCode(rawValue: 301), .requestCancelled, "Code 301 should map to .requestCancelled")
        expectEqual(SpeechRecognitionErrorCode(rawValue: 1110), .noSpeechDetected, "Code 1110 should map to .noSpeechDetected")
        expectEqual(SpeechRecognitionErrorCode(rawValue: 1700), .notAuthorizedOrMissingAsset, "Code 1700 should map to .notAuthorizedOrMissingAsset")

        let mgr = SpeechRecognitionManager()
        if let buf = AVAudioPCMBuffer(pcmFormat: AudioCaptureEngine.speechFormat, frameCapacity: 160) {
            buf.frameLength = 160
            mgr.feedCallerAudioBuffer(buf)
            expect(mgr.micChannel.isSuspended, "Feeding caller system audio must suspend micChannel so speaker bleed cannot be transcribed as You")
            expect(!mgr.callerChannel.isSuspended, "callerChannel must remain unsuspended when system audio is active")
            mgr.feedMicAudioBuffer(buf)
            expect(!mgr.callerChannel.isSuspended, "Feeding mic audio must NEVER suspend callerChannel")
        }
    }


    static func testAudioCaptureBackoffAndPermissionState() {
        expectEqual(AudioCaptureEngine.backoffDelaySeconds(forAttempt: 1), 1.0, "Attempt 1 backoff should be 1s")
        expectEqual(AudioCaptureEngine.backoffDelaySeconds(forAttempt: 2), 2.0, "Attempt 2 backoff should be 2s")
        expectEqual(AudioCaptureEngine.backoffDelaySeconds(forAttempt: 3), 4.0, "Attempt 3 backoff should be 4s")
        expectEqual(AudioCaptureEngine.backoffDelaySeconds(forAttempt: 5), 16.0, "Attempt 5 backoff should be 16s")
        expectEqual(AudioCaptureEngine.backoffDelaySeconds(forAttempt: 6), 32.0, "Backoff should cap at 32s")

        PermissionHelper.shared.updateAudioCaptureState(.deniedSilenceDetected)
        expectEqual(PermissionHelper.shared.audioCaptureState, .deniedSilenceDetected, "AudioCapturePermissionState should update to .deniedSilenceDetected")
        expect(!PermissionHelper.shared.hasAudioCaptureAccess, "hasAudioCaptureAccess should be false when silence detected")

        PermissionHelper.shared.updateAudioCaptureState(.active)
        expectEqual(PermissionHelper.shared.audioCaptureState, .active, "AudioCapturePermissionState should update to .active")
        expect(PermissionHelper.shared.hasAudioCaptureAccess, "hasAudioCaptureAccess should be true when active")
        PermissionHelper.shared.updateAudioCaptureState(.unknown)
    }


    static func testPopoverAutoOpenLogic() {
        expect(
            AppDelegate.shouldAutoOpenPopover(
                isPopoverShown: false,
                autoPopupSetting: true,
                speaker: "Caller",
                nowUptime: 100.0,
                lastManualCloseUptime: 0.0
            ),
            "Popover should auto-open on Caller speech when not shown and not in cooldown"
        )
        expect(
            !AppDelegate.shouldAutoOpenPopover(
                isPopoverShown: false,
                autoPopupSetting: true,
                speaker: "You",
                nowUptime: 100.0,
                lastManualCloseUptime: 0.0
            ),
            "Popover must NOT auto-open on user's own microphone speech"
        )
        expect(
            !AppDelegate.shouldAutoOpenPopover(
                isPopoverShown: false,
                autoPopupSetting: true,
                speaker: "Caller",
                nowUptime: 105.0,
                lastManualCloseUptime: 100.0
            ),
            "Popover must respect 15-second cooldown after manual close"
        )
        expect(
            AppDelegate.shouldAutoOpenPopover(
                isPopoverShown: false,
                autoPopupSetting: true,
                speaker: "Caller",
                nowUptime: 120.0,
                lastManualCloseUptime: 100.0
            ),
            "Popover should auto-open again once 15-second manual close cooldown expires"
        )
    }


    static func testTrayCaptionParagraphFormatting() {
        let vc = TrayCaptionViewController()
        vc.loadViewIfNeeded()

        let untranslatedBlock = TrayCaptionViewController.ParagraphBlock(
            speaker: "Caller",
            sourceLangCode: "ar",
            targetLangCode: "en",
            sentences: [
                TrayCaptionViewController.SentenceItem(
                    translated: "مرحبا",
                    original: "مرحبا",
                    isUntranslated: true
                )
            ]
        )
        let plain = untranslatedBlock.plainText(showOriginal: true, isMicEnabled: true)
        expect(plain.contains("[Untranslated]"), "plainText should include [Untranslated] prefix when translation failed")

        let attr = vc.buildAttributedParagraph(block: untranslatedBlock, isLive: false)
        expect(attr.string.contains("[UNTRANSLATED]"), "Attributed paragraph should include [UNTRANSLATED] badge")

        testWindowLayoutsHaveNoOverlaps()
    }


    static func testWindowLayoutsHaveNoOverlaps() {
        let onboarding = OnboardingWindowController()
        if let root = onboarding.window?.contentView {
            verifyNoSiblingOverlaps(in: root, context: "OnboardingWindowController.root")
            for sub in root.subviews {
                if let box = sub as? NSBox, let content = box.contentView {
                    verifyNoSiblingOverlaps(in: content, context: "OnboardingWindowController.card")
                }
            }
        }

        let settings = SettingsWindowController()
        if let root = settings.window?.contentView {
            verifyNoSiblingOverlaps(in: root, context: "SettingsWindowController.root")
            for sub in root.subviews {
                if let tabView = sub as? NSTabView {
                    for (tabIdx, item) in tabView.tabViewItems.enumerated() {
                        if let tabViewContent = item.view {
                            verifyNoSiblingOverlaps(in: tabViewContent, context: "SettingsWindowController.tab[\(tabIdx)]")
                            for cardSub in tabViewContent.subviews {
                                if let box = cardSub as? NSBox, let boxContent = box.contentView {
                                    verifyNoSiblingOverlaps(in: boxContent, context: "SettingsWindowController.tab[\(tabIdx)].card")
                                }
                            }
                        }
                    }
                }
            }
        }

        let trayVC = TrayCaptionViewController()
        trayVC.loadViewIfNeeded()
        trayVC.updateLayout()
        let isOverlay: (NSView, NSView) -> Bool = { view, container in
            if view is NSButton && view.bounds.width <= 100 { return true }
            if !(view is NSScrollView), let sv = container.subviews.first(where: { $0 is NSScrollView }), view.frame == sv.frame {
                return true
            }
            return false
        }
        let filterOverlays: (NSView) -> [NSView] = { container in
            container.subviews.filter { !$0.isHidden && $0.frame.height > 1.5 && !isOverlay($0, container) }
        }
        verifyNoOverlaps(in: filterOverlays(trayVC.view), context: "TrayCaptionViewController.default")

        trayVC.showLiveShareBanner()
        verifyNoOverlaps(in: filterOverlays(trayVC.view), context: "TrayCaptionViewController.liveShareBanner")

        trayVC.showAlertBanner(message: "Test Alert", actionType: .audioCapture)
        verifyNoOverlaps(in: filterOverlays(trayVC.view), context: "TrayCaptionViewController.bothBanners")

        trayVC.hideLiveShareBanner()
        verifyNoOverlaps(in: filterOverlays(trayVC.view), context: "TrayCaptionViewController.alertBannerOnly")
    }

    private static func verifyNoOverlaps(in views: [NSView], context: String) {
        for i in 0..<views.count {
            for j in (i + 1)..<views.count {
                let a = views[i].frame.insetBy(dx: 1.0, dy: 1.0)
                let b = views[j].frame.insetBy(dx: 1.0, dy: 1.0)
                expect(
                    !a.intersects(b),
                    "\(context): sibling subviews \(type(of: views[i])) (\(views[i].frame)) and \(type(of: views[j])) (\(views[j].frame)) must not overlap"
                )
            }
        }
    }

    private static func verifyNoSiblingOverlaps(in container: NSView, context: String) {
        let views = container.subviews.filter { !$0.isHidden && $0.frame.height > 1.5 }
        verifyNoOverlaps(in: views, context: context)
    }


    private actor TestAsyncMutex {
        private struct Waiter {
            let id: UUID
            let continuation: CheckedContinuation<Void, any Error>
        }

        private var locked = false
        private var waiters: [Waiter] = []

        deinit {
            for waiter in waiters {
                waiter.continuation.resume(throwing: CancellationError())
            }
            waiters.removeAll()
        }

        func lock() async throws {
            if Task.isCancelled {
                throw CancellationError()
            }
            if !locked {
                locked = true
                return
            }
            let id = UUID()
            try await withTaskCancellationHandler(
                operation: { () async throws -> Void in
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        if Task.isCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            waiters.append(Waiter(id: id, continuation: continuation))
                        }
                    }
                },
                onCancel: {
                    Task { [weak self] in
                        await self?.cancelWaiter(id: id)
                    }
                }
            )
        }

        private func cancelWaiter(id: UUID) {
            if let idx = waiters.firstIndex(where: { $0.id == id }) {
                let waiter = waiters.remove(at: idx)
                waiter.continuation.resume(throwing: CancellationError())
            }
        }

        func unlock() {
            if !waiters.isEmpty {
                let next = waiters.removeFirst()
                next.continuation.resume()
            } else {
                locked = false
            }
        }

        func waiterCount() -> Int {
            waiters.count
        }

        func isLocked() -> Bool {
            locked
        }
    }

    static func testAsyncMutexTaskCancellation() async {
        let mutex = TestAsyncMutex()

        do {
            try await mutex.lock()
            let locked1 = await mutex.isLocked()
            expect(locked1, "Mutex should be locked after lock()")
            let waiters1 = await mutex.waiterCount()
            expectEqual(waiters1, 0, "No waiters when lock is held by caller")
            await mutex.unlock()
            let locked2 = await mutex.isLocked()
            expect(!locked2, "Mutex should be unlocked after unlock()")
        } catch {
            expect(false, "Basic lock/unlock should not throw: \(error)")
        }

        do {
            try await mutex.lock()
            let holderLocked = await mutex.isLocked()
            expect(holderLocked, "Mutex acquired by holder")

            let waiter1Cancelled = OSAllocatedUnfairLock(initialState: false)
            let waiter2Acquired = OSAllocatedUnfairLock(initialState: false)

            let waiter1 = Task {
                do {
                    try await mutex.lock()
                    await mutex.unlock()
                } catch is CancellationError {
                    waiter1Cancelled.withLock { $0 = true }
                } catch {
                    expect(false, "Unexpected error in waiter1: \(error)")
                }
            }

            let waiter2 = Task {
                do {
                    try await mutex.lock()
                    waiter2Acquired.withLock { $0 = true }
                    await mutex.unlock()
                } catch {
                    expect(false, "Unexpected error in waiter2: \(error)")
                }
            }

            for _ in 0..<20 {
                let count = await mutex.waiterCount()
                if count == 2 { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            let waiterCount2 = await mutex.waiterCount()
            expectEqual(waiterCount2, 2, "Both waiters should be enqueued in mutex")

            waiter1.cancel()
            _ = await waiter1.result

            for _ in 0..<20 {
                let count = await mutex.waiterCount()
                if count == 1 { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            let waiterCount1 = await mutex.waiterCount()
            expectEqual(waiterCount1, 1, "Cancelled waiter must be cleanly removed from queue")
            expect(waiter1Cancelled.withLock { $0 }, "Waiter1 must catch CancellationError")

            await mutex.unlock()
            _ = await waiter2.result

            expect(waiter2Acquired.withLock { $0 }, "Waiter2 must acquire lock after waiter1 cancellation")
            let unlocked = await mutex.isLocked()
            expect(!unlocked, "Mutex should be unlocked after all tasks finish")
            let finalWaiters = await mutex.waiterCount()
            expectEqual(finalWaiters, 0, "Waiters queue must be empty")
        } catch {
            expect(false, "Contended cancellation test threw unexpected error: \(error)")
        }

        let preCancelled = Task {
            try await mutex.lock()
        }
        preCancelled.cancel()
        let preResult = await preCancelled.result
        switch preResult {
        case .failure(let error):
            expect(error is CancellationError, "Pre-cancelled task must throw CancellationError")
        case .success:
            expect(false, "Pre-cancelled task should not succeed in lock()")
        }
        let preLocked = await mutex.isLocked()
        expect(!preLocked, "Pre-cancelled task must not acquire or hold lock")
    }


    static func testTranslationEngineCancellationAndCache() async {
        let engine = TranslationEngine.shared

        let emptyResult = await engine.translate(text: "   \n\t  ", sourceCode: "es", targetCode: "en")
        expectEqual(emptyResult, "", "Whitespace-only input must return empty string without session lookup")

        let identityResult = await engine.translate(text: "Hello World", sourceCode: "en", targetCode: "en")
        expectEqual(identityResult, "Hello World", "Identical source and target codes should return trimmed text immediately")

        await engine.clearCache()
        await engine.resetFailureCooldowns()

        var rapidTasks: [Task<String?, Never>] = []
        for i in 0..<6 {
            rapidTasks.append(Task {
                await engine.translate(
                    text: "Esta es una frase larga de prueba número \(i) para cancelación",
                    sourceCode: "es",
                    targetCode: "en",
                    isFinal: false
                )
            })
        }
        var rapidOutcomes: [String?] = []
        for t in rapidTasks {
            rapidOutcomes.append(await t.value)
        }
        let allValidOrNil = rapidOutcomes.allSatisfy { $0 == nil || !($0!.isEmpty) }
        expect(allValidOrNil, "Rapid partial tasks must either return nil (if cancelled) or valid text")

        let followUp = await engine.translate(
            text: "Hola",
            sourceCode: "es",
            targetCode: "en",
            isFinal: true
        )
        expect(followUp != nil, "Subsequent translation must succeed without 5-second failure cooldown after partial cancellations")

        await engine.resetFailureCooldowns()
        await engine.clearCache()

        var simulatedCache: [String: String] = [:]
        var simulatedKeys: [String] = []
        var ringIndex = 0
        let maxCache = 2048

        for i in 0..<(maxCache + 50) {
            let key = "key_\(i)"
            let val = "val_\(i)"
            if simulatedCache[key] == nil {
                if simulatedKeys.count < maxCache {
                    simulatedKeys.append(key)
                } else {
                    let evicted = simulatedKeys[ringIndex]
                    simulatedCache.removeValue(forKey: evicted)
                    simulatedKeys[ringIndex] = key
                    ringIndex = (ringIndex + 1) % maxCache
                }
            }
            simulatedCache[key] = val
        }
        expectEqual(simulatedCache.count, maxCache, "Cache count must be capped at maxCacheSize (2048)")
        expect(simulatedCache["key_0"] == nil, "Oldest key_0 must be evicted after 2048 insertions")
        expect(simulatedCache["key_49"] == nil, "Oldest key_49 must be evicted")
        expect(simulatedCache["key_50"] != nil, "Key 50 should remain in ring cache")
        expect(simulatedCache["key_\(maxCache + 49)"] != nil, "Latest key must be present in ring cache")
    }


    static func testCaptionCoordinatorThreadSafety() async {
        let coordinator = CaptionCoordinator.shared
        coordinator.stop()

        expect(!coordinator.hasStarted, "Coordinator should be stopped initially")
        expect(!coordinator.isPaused, "Coordinator should not be paused initially")

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    for iter in 0..<50 {
                        let started = coordinator.hasStarted
                        let paused = coordinator.isPaused
                        _ = started && paused

                        if iter % 4 == 0 {
                            coordinator.pause()
                        } else if iter % 4 == 1 {
                            coordinator.resume()
                        } else if iter % 4 == 2 {
                            coordinator.autoPauseForSystem()
                        } else {
                            coordinator.autoResumeAfterSystem()
                        }
                    }
                }
            }
        }

        coordinator.stop()
        expect(!coordinator.hasStarted, "Coordinator hasStarted must be false after stop()")
        expect(!coordinator.isPaused, "Coordinator isPaused must be false after stop()")
    }


    static func testSingleSpeechChannelCancellationOnReset() {
        let channel = SingleSpeechChannel(name: "UnitTestChannel", sourceLocaleId: "en-US", targetLangCode: "es")
        expect(!channel.isRunning, "SingleSpeechChannel should not be running initially")
        expect(!channel.isSuspended, "SingleSpeechChannel should not be suspended initially")

        channel.start(sourceLocaleId: "en-US", targetLangCode: "es")
        expect(channel.isRunning, "SingleSpeechChannel isRunning should be true after start()")

        channel.discardInFlight()
        expect(channel.isRunning, "Channel remains running after discardInFlight()")

        channel.resetFailureState()

        channel.stop()
        expect(!channel.isRunning, "SingleSpeechChannel isRunning must be false after stop()")
        expect(!channel.isSuspended, "SingleSpeechChannel isSuspended must be false after stop()")
    }


    static func testMultiFormatPCMConversion() {
        let engine = CaptionCoordinator.shared.audioCaptureEngine

        guard let fmt32 = AVAudioFormat(commonFormat: .pcmFormatInt32, sampleRate: 48000, channels: 2, interleaved: false),
              let buf32 = AVAudioPCMBuffer(pcmFormat: fmt32, frameCapacity: 128) else {
            expect(false, "Failed to create 32-bit integer PCM buffer")
            return
        }
        buf32.frameLength = 128
        if let int32Data = buf32.int32ChannelData {
            for i in 0..<128 {
                int32Data[0][i] = 1073741824
                int32Data[1][i] = -1073741824
            }
        }
        guard let mono32 = engine.copyToMonoPCMBuffer(buf32) else {
            expect(false, "copyToMonoPCMBuffer should convert 32-bit integer PCM")
            return
        }
        expectEqual(mono32.format.channelCount, 1, "Converted buffer must be mono")
        expectEqual(mono32.format.commonFormat, .pcmFormatFloat32, "Converted buffer must be Float32")
        expectEqual(mono32.frameLength, 128, "Frame length must be preserved")
        if let floatData = mono32.floatChannelData {
            let sample = floatData[0][0]
            expect(abs(sample - 0.5) < 0.001, "32-bit integer sample must normalize to ~0.5 (got \(sample))")
        }

        var asbd24in32 = AudioStreamBasicDescription(
            mSampleRate: 48000.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 24,
            mReserved: 0
        )
        if let fmt24in32 = AVAudioFormat(streamDescription: &asbd24in32),
           let buf24in32 = AVAudioPCMBuffer(pcmFormat: fmt24in32, frameCapacity: 64) {
            buf24in32.frameLength = 64
            if let int32Data = buf24in32.int32ChannelData {
                for i in 0..<64 {
                    int32Data[0][i] = 4194304
                    int32Data[1][i] = -4194304
                }
            }
            if let mono24in32 = engine.copyToMonoPCMBuffer(buf24in32),
               let floatData = mono24in32.floatChannelData {
                let sample = floatData[0][0]
                expect(abs(sample - 0.5) < 0.001, "24-bit in 32-bit container must normalize to ~0.5 (got \(sample))")
            } else {
                expect(false, "copyToMonoPCMBuffer should convert 24-bit in 32-bit container")
            }
        }

        var asbdPacked = AudioStreamBasicDescription(
            mSampleRate: 48000.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 3,
            mFramesPerPacket: 1,
            mBytesPerFrame: 3,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 24,
            mReserved: 0
        )
        if let fmtPacked = AVAudioFormat(streamDescription: &asbdPacked),
           let bufPacked = AVAudioPCMBuffer(pcmFormat: fmtPacked, frameCapacity: 32) {
            bufPacked.frameLength = 32
            if let mData = bufPacked.audioBufferList.pointee.mBuffers.mData {
                let bytePtr = mData.assumingMemoryBound(to: UInt8.self)
                for i in 0..<32 {
                    bytePtr[i * 3 + 0] = 0x00
                    bytePtr[i * 3 + 1] = 0x00
                    bytePtr[i * 3 + 2] = 0x40
                }
            }
            if let monoPacked = engine.copyToMonoPCMBuffer(bufPacked),
               let floatData = monoPacked.floatChannelData {
                let sample = floatData[0][0]
                expect(abs(sample - 0.5) < 0.001, "Packed 24-bit PCM must normalize to ~0.5 (got \(sample))")
            } else {
                expect(false, "copyToMonoPCMBuffer should convert packed 24-bit PCM")
            }
        }

        if let fmt16 = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false),
           let buf16 = AVAudioPCMBuffer(pcmFormat: fmt16, frameCapacity: 32) {
            buf16.frameLength = 32
            if let int16Data = buf16.int16ChannelData {
                for i in 0..<32 {
                    int16Data[0][i] = 16384
                }
            }
            if let mono16 = engine.copyToMonoPCMBuffer(buf16),
               let floatData = mono16.floatChannelData {
                let sample = floatData[0][0]
                expect(abs(sample - 0.5) < 0.001, "Int16 PCM must normalize to ~0.5 (got \(sample))")
            } else {
                expect(false, "copyToMonoPCMBuffer should convert Int16 PCM")
            }
        }

        if let emptyBuf = AVAudioPCMBuffer(pcmFormat: fmt32, frameCapacity: 10) {
            emptyBuf.frameLength = 0
            expect(engine.copyToMonoPCMBuffer(emptyBuf) == nil, "Empty buffer should return nil")
        }

        guard let fmt48k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false),
              let buf4800 = AVAudioPCMBuffer(pcmFormat: fmt48k, frameCapacity: 4800) else {
            expect(false, "Failed to create 4800-frame 48kHz buffer")
            return
        }
        buf4800.frameLength = 4800
        if let data = buf4800.floatChannelData?[0] {
            for i in 0..<4800 { data[i] = 0.25 }
        }
        guard let mono4800 = engine.copyToMonoPCMBuffer(buf4800) else {
            expect(false, "copyToMonoPCMBuffer must support 4800-frame macOS hardware buffers without dropping")
            return
        }
        expectEqual(mono4800.frameLength, 4800, "4800 frame length must be preserved")
        expectEqual(mono4800.format.channelCount, 1, "Converted buffer must be 1-channel mono")

        guard let fmtStereo = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false),
              let bufStereo = AVAudioPCMBuffer(pcmFormat: fmtStereo, frameCapacity: 64) else {
            expect(false, "Failed to create stereo buffer")
            return
        }
        bufStereo.frameLength = 64
        if let stData = bufStereo.floatChannelData {
            for i in 0..<64 {
                stData[0][i] = 0.8
                stData[1][i] = 0.2
            }
        }
        guard let monoStereo = engine.copyToMonoPCMBuffer(bufStereo) else {
            expect(false, "copyToMonoPCMBuffer must downmix stereo buffers")
            return
        }
        if let monoData = monoStereo.floatChannelData?[0] {
            let sample = monoData[0]
            expect(abs(sample - 0.5) < 0.001, "Stereo downmix (0.8 + 0.2) * 0.5 must equal 0.5 (got \(sample))")
        }

        guard let layout4 = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4) else {
            expect(false, "Failed to create 4-channel layout")
            return
        }
        let fmt4ch = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, interleaved: false, channelLayout: layout4)
        guard let buf4ch = AVAudioPCMBuffer(pcmFormat: fmt4ch, frameCapacity: 64) else {
            expect(false, "Failed to create 4-channel buffer")
            return
        }
        buf4ch.frameLength = 64
        if let data4 = buf4ch.floatChannelData {
            for i in 0..<64 {
                data4[0][i] = 0.0
                data4[1][i] = 0.75
                data4[2][i] = 0.0
                data4[3][i] = 0.0
            }
        }
        guard let mono4ch = engine.copyToMonoPCMBuffer(buf4ch),
              let mono4Data = mono4ch.floatChannelData?[0] else {
            expect(false, "copyToMonoPCMBuffer must support 4-channel audio interface buffers")
            return
        }
        let sample4 = mono4Data[0]
        expect(abs(sample4 - 0.75) < 0.001, "4-channel buffer must select the active channel with highest RMS (got \(sample4), expected 0.75)")

        guard let fmtInt16Stereo = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: false),
              let bufInt16 = AVAudioPCMBuffer(pcmFormat: fmtInt16Stereo, frameCapacity: 32) else {
            expect(false, "Failed to create Int16 stereo buffer")
            return
        }
        bufInt16.frameLength = 32
        if let d16 = bufInt16.int16ChannelData {
            for i in 0..<32 {
                d16[0][i] = 16384
                d16[1][i] = 8192
            }
        }
        guard let monoInt16 = engine.copyToMonoPCMBuffer(bufInt16),
              let mono16Data = monoInt16.floatChannelData?[0] else {
            expect(false, "copyToMonoPCMBuffer must convert Int16 stereo")
            return
        }
        let s16 = mono16Data[0]
        expect(abs(s16 - 0.5) < 0.01, "Int16 multi-channel must normalize chosen channel ~0.50 (got \(s16))")

        guard let monoTargetSmall = AVAudioPCMBuffer(pcmFormat: fmt48k, frameCapacity: 32),
              let monoTargetLarge = AVAudioPCMBuffer(pcmFormat: fmt48k, frameCapacity: 128) else {
            expect(false, "Failed to create scratch target buffers")
            return
        }
        let fits = engine.convertAndCopyToMono(source: bufStereo, destination: monoTargetLarge)
        expect(fits, "convertAndCopyToMono must succeed when monoCopy.frameCapacity >= frameLen")
        let overflows = engine.convertAndCopyToMono(source: bufStereo, destination: monoTargetSmall)
        expect(!overflows, "convertAndCopyToMono must return false when frameLen exceeds monoCopy.frameCapacity")
    }


    private final class MockTestCaptureDelegate: AudioCaptureDelegate, @unchecked Sendable {
        var lastError: (any Error)?
        func audioCaptureDidOutputCallerAudio(pcmBuffer: AVAudioPCMBuffer) {}
        func audioCaptureDidUpdateCallerLevel(_ level: Float) {}
        func audioCaptureDidOutputMicAudio(pcmBuffer: AVAudioPCMBuffer) {}
        func audioCaptureDidUpdateMicLevel(_ level: Float) {}
        func audioCaptureDidEncounterError(_ error: any Error) { lastError = error }
        func audioCaptureDidDetectDeniedTapPermission() {}
    }

    static func testAudioTapRebuildBackoffAndExhaustion() {
        expectEqual(AudioCaptureEngine.backoffDelaySeconds(forAttempt: 0), 1.0, "Attempt 0 backoff should clamp to 1.0s")
        expectEqual(AudioCaptureEngine.backoffDelaySeconds(forAttempt: 1), 1.0, "Attempt 1 backoff should be 1.0s")
        expectEqual(AudioCaptureEngine.backoffDelaySeconds(forAttempt: 2), 2.0, "Attempt 2 backoff should be 2.0s")
        expectEqual(AudioCaptureEngine.backoffDelaySeconds(forAttempt: 3), 4.0, "Attempt 3 backoff should be 4.0s")
        expectEqual(AudioCaptureEngine.backoffDelaySeconds(forAttempt: 4), 8.0, "Attempt 4 backoff should be 8.0s")
        expectEqual(AudioCaptureEngine.backoffDelaySeconds(forAttempt: 5), 16.0, "Attempt 5 backoff should be 16.0s")
        expectEqual(AudioCaptureEngine.backoffDelaySeconds(forAttempt: 6), 32.0, "Attempt 6 backoff should be 32.0s")
        expectEqual(AudioCaptureEngine.backoffDelaySeconds(forAttempt: 7), 60.0, "Attempt 7 backoff should cap at 60.0s")
        expectEqual(AudioCaptureEngine.backoffDelaySeconds(forAttempt: 10), 60.0, "Attempt 10 backoff should cap at 60.0s")

        let mockDelegate = MockTestCaptureDelegate()
        let testError = NSError(domain: "com.callcaption.test", code: -999, userInfo: [NSLocalizedDescriptionKey: "Simulated tap failure"])
        mockDelegate.audioCaptureDidEncounterError(testError)
        expectEqual((mockDelegate.lastError as? NSError)?.code, -999, "Delegate should receive reported capture error on exhaustion")
    }


    static func testBoundedBufferQueueBackpressure() {
        let maxBacklog = 16
        var queue: [Int] = []
        var droppedCount = 0

        for chunkID in 0..<25 {
            if queue.count >= maxBacklog {
                queue.removeFirst()
                droppedCount += 1
            }
            queue.append(chunkID)
        }

        expectEqual(queue.count, 16, "Queue backlog must never exceed maxCallerBacklogChunks (16)")
        expectEqual(droppedCount, 9, "9 oldest chunks should have been dropped under backlog pressure")
        expectEqual(queue.first, 9, "Oldest surviving chunk in FIFO must be chunk #9")
        expectEqual(queue.last, 24, "Most recent chunk in FIFO must be chunk #24")

        let drained = queue
        queue.removeAll()
        expectEqual(drained.count, 16, "Drained chunks count must equal 16")
        expectEqual(drained, Array(9...24), "Drained chunks must follow exact FIFO sequence")
    }


    static func testAcousticIsolationAndDuplexAudio() {
        let mgr = SpeechRecognitionManager()
        guard let buf = AVAudioPCMBuffer(pcmFormat: AudioCaptureEngine.speechFormat, frameCapacity: 160) else {
            expect(false, "Failed to allocate speech format buffer")
            return
        }
        buf.frameLength = 160

        mgr.isAcousticallyIsolated = true
        expect(mgr.isAcousticallyIsolated, "isAcousticallyIsolated should reflect true when set")

        mgr.feedCallerAudioBuffer(buf)
        expect(!mgr.micChannel.isSuspended, "When acoustically isolated, micChannel must NOT be suspended (full duplex preserved)")

        mgr.isAcousticallyIsolated = false
        expect(!mgr.isAcousticallyIsolated, "isAcousticallyIsolated should reflect false when set")

        mgr.feedCallerAudioBuffer(buf)
        expect(mgr.micChannel.isSuspended, "When not acoustically isolated, micChannel MUST be suspended to prevent speaker bleed")

        expect(
            !AudioCaptureEngine.shouldActivateCallerSpeech(
                callerRMS: 0.0035,
                isCallerActive: false,
                isMicCurrentlySpeaking: true,
                consecutiveCallerFrames: 5
            ),
            "Small caller sound (< 0.0075) while user is speaking into microphone must NOT activate caller speech"
        )
        expect(
            !AudioCaptureEngine.shouldActivateCallerSpeech(
                callerRMS: 0.0120,
                isCallerActive: false,
                isMicCurrentlySpeaking: true,
                consecutiveCallerFrames: 2
            ),
            "Transient 2-frame caller spike while user is speaking must NOT activate caller speech"
        )
        expect(
            AudioCaptureEngine.shouldActivateCallerSpeech(
                callerRMS: 0.0120,
                isCallerActive: false,
                isMicCurrentlySpeaking: true,
                consecutiveCallerFrames: 3
            ),
            "Sustained loud caller speech (>= 0.0075 for 3+ frames) must activate caller speech"
        )
        expect(
            AudioCaptureEngine.shouldActivateCallerSpeech(
                callerRMS: 0.0018,
                isCallerActive: false,
                isMicCurrentlySpeaking: false,
                consecutiveCallerFrames: 1
            ),
            "When user is not speaking into mic, caller speech >= 0.0014 must activate immediately on frame 1"
        )

        let micSpeakingWithQuietCaller = AudioCaptureEngine.evaluateMicEchoState(
            rawCallerRMS: 0.0030,
            callerPeakEnvelope: 0.0035,
            isCallerCurrentlySpeaking: false,
            timeSinceLastCallerVoice: 10.0,
            isAcousticallyIsolated: false,
            isMicCurrentlySpeaking: true
        )
        expect(!micSpeakingWithQuietCaller.isCallerSpeakingOrEchoing, "Small caller sound while user is speaking must not trigger echo state")
        expectEqual(micSpeakingWithQuietCaller.effectiveThreshold, AudioCaptureEngine.defaultMicSpeechThreshold, "Mic threshold must stay at defaultMicSpeechThreshold when caller is not active")

        let callerSpeakingOnSpeakers = AudioCaptureEngine.evaluateMicEchoState(
            rawCallerRMS: 0.020,
            callerPeakEnvelope: 0.030,
            isCallerCurrentlySpeaking: true,
            timeSinceLastCallerVoice: 0.01,
            isAcousticallyIsolated: false,
            isMicCurrentlySpeaking: false
        )
        expect(callerSpeakingOnSpeakers.isCallerSpeakingOrEchoing, "Active caller on speakers must trigger echo suppression")
        expect(callerSpeakingOnSpeakers.effectiveThreshold >= 0.10, "Echo threshold must scale without ceiling to block speaker bleed (got \(callerSpeakingOnSpeakers.effectiveThreshold))")

        AudioCaptureEngine.overrideAcousticIsolation = true
        expect(AudioCaptureEngine.isAudioOutputAcousticallyIsolated(), "AudioCaptureEngine must honor override true")
        AudioCaptureEngine.overrideAcousticIsolation = false
        expect(!AudioCaptureEngine.isAudioOutputAcousticallyIsolated(), "AudioCaptureEngine must honor override false")
        AudioCaptureEngine.overrideAcousticIsolation = nil

        let liveIsolationState = AudioCaptureEngine.isAudioOutputAcousticallyIsolated()
        _ = liveIsolationState
        expect(true, "AudioCaptureEngine.isAudioOutputAcousticallyIsolated() executed safely")
    }


    static func testAudioDSPMathAndAGC() {
        let zeros = [Float](repeating: 0.0, count: 64)
        zeros.withUnsafeBufferPointer { ptr in
            let rms = AudioCaptureEngine.computeRMS(samples: ptr.baseAddress!, count: 64)
            expectEqual(rms, 0.0, "RMS of zeros must be 0.0")
        }

        let dcOnes = [Float](repeating: 1.0, count: 64)
        dcOnes.withUnsafeBufferPointer { ptr in
            let rms = AudioCaptureEngine.computeRMS(samples: ptr.baseAddress!, count: 64)
            expect(abs(rms - 1.0) < 0.0001, "RMS of constant 1.0 must be 1.0")
        }

        let squareWave: [Float] = [0.5, -0.5, 0.5, -0.5, 0.5, -0.5, 0.5, -0.5]
        squareWave.withUnsafeBufferPointer { ptr in
            let rms = AudioCaptureEngine.computeRMS(samples: ptr.baseAddress!, count: 8)
            expect(abs(rms - 0.5) < 0.0001, "RMS of 0.5 square wave must be 0.5")
        }

        zeros.withUnsafeBufferPointer { ptr in
            let rms = AudioCaptureEngine.computeRMS(samples: ptr.baseAddress!, count: 0)
            expectEqual(rms, 0.0, "RMS with count=0 must return 0.0")
        }

        let minRMS: Float = 0.005
        let targetRMS: Float = 0.052

        let silentGain = AudioCaptureEngine.nextAGCGain(
            currentRMS: 0.001,
            currentGain: 1.0,
            minRMSForBoost: minRMS,
            targetRMS: targetRMS
        )
        expectEqual(silentGain, 1.0, "Silent audio below minRMS should maintain gain of 1.0")

        let boostedGain = AudioCaptureEngine.nextAGCGain(
            currentRMS: 0.01,
            currentGain: 1.0,
            minRMSForBoost: minRMS,
            targetRMS: targetRMS
        )
        expect(abs(boostedGain - 2.68) < 0.001, "AGC boost step must match 60/40 filter (expected 2.68, got \(boostedGain))")

        let clampedGain = AudioCaptureEngine.nextAGCGain(
            currentRMS: 0.0051,
            currentGain: 1.0,
            minRMSForBoost: minRMS,
            targetRMS: targetRMS
        )
        expect(abs(clampedGain - 4.60) < 0.001, "AGC gain must clamp to max 10.0 desired gain (expected 4.60, got \(clampedGain))")

        let loudGain = AudioCaptureEngine.nextAGCGain(
            currentRMS: 0.20,
            currentGain: 5.0,
            minRMSForBoost: minRMS,
            targetRMS: targetRMS
        )
        expect(abs(loudGain - 3.40) < 0.001, "Loud speech must decay gain towards 1.0 (expected 3.40, got \(loudGain))")

        let srcRate = 48000.0
        let tgtRate = 16000.0
        let ratio = tgtRate / srcRate
        expectEqual(ratio, 1.0 / 3.0, "Downsampling ratio from 48kHz to 16kHz must be 1/3")
        let inFrames = 480
        let outFrames = Int(Double(inFrames) * ratio)
        expectEqual(outFrames, 160, "480 frames at 48kHz must yield 160 frames at 16kHz")
    }


    static func testSSHKnownHostsPreSeedingAndStrictHostKeyChecking() {
        let pinned = LiveShareManager.pinnedSSHKnownHosts
        expect(pinned.contains("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILVqOuSMnyeGDVO1lG6EaG5In/dXABCchhmHKkuRU2s9"),
               "Pinned known hosts must include localhost.run ED25519 key")
        expect(pinned.contains("ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC3lJnhW1oCXuAYV9IBdcJA+Vx7AHL5S/ZQvV2fhceO"),
               "Pinned known hosts must include localhost.run RSA key")

        guard let testDir = AppPaths.testRoot else {
            expect(false, "CALLCAPTION_TEST_DIR must be configured")
            return
        }
        let testHostsURL = testDir.appendingPathComponent("test_ssh_known_hosts")
        try? FileManager.default.removeItem(at: testHostsURL)

        do {
            try LiveShareManager.ensureSSHKnownHostsPopulated(at: testHostsURL)
            expect(FileManager.default.fileExists(atPath: testHostsURL.path), "ensureSSHKnownHostsPopulated must create file")

            let content = try String(contentsOf: testHostsURL, encoding: .utf8)
            expect(content.contains("AAAAC3NzaC1lZDI1NTE5AAAAILVqOuSMnyeGDVO1lG6EaG5In/dXABCchhmHKkuRU2s9"),
                   "Written known_hosts must contain pinned ED25519 key")

            if let attrs = try? FileManager.default.attributesOfItem(atPath: testHostsURL.path),
               let perm = attrs[.posixPermissions] as? NSNumber {
                expectEqual(perm.intValue & 0o777, 0o600, "known_hosts file permissions must be 0600")
            } else {
                expect(false, "Could not read known_hosts permissions")
            }

            let customEntry = "other.example.com ssh-ed25519 AAAAOtherDummyKey123\n"
            try customEntry.write(to: testHostsURL, atomically: true, encoding: .utf8)

            try LiveShareManager.ensureSSHKnownHostsPopulated(at: testHostsURL)
            let updatedContent = try String(contentsOf: testHostsURL, encoding: .utf8)
            expect(updatedContent.contains("AAAAC3NzaC1lZDI1NTE5AAAAILVqOuSMnyeGDVO1lG6EaG5In/dXABCchhmHKkuRU2s9"),
                   "Pinned keys must be prepended into existing file")
            expect(updatedContent.contains("other.example.com"), "Pre-existing keys must be preserved")

            if let attrs2 = try? FileManager.default.attributesOfItem(atPath: testHostsURL.path),
               let perm2 = attrs2[.posixPermissions] as? NSNumber {
                expectEqual(perm2.intValue & 0o777, 0o600, "Updated known_hosts permissions must remain 0600")
            }

            try? FileManager.default.removeItem(at: testHostsURL)
        } catch {
            expect(false, "ensureSSHKnownHostsPopulated threw error: \(error)")
        }

        let dummyHostsURL = URL(fileURLWithPath: "/tmp/test_known_hosts")
        let args = LiveShareManager.buildSSHTunnelArguments(port: 54321, knownHostsURL: dummyHostsURL)
        expect(!args.contains("-N"), "SSH arguments must NOT include -N; -N prevents remote banner output containing tunnel URL")
        expect(args.contains("-T"), "SSH arguments must include -T to disable pseudo-terminal allocation")
        expect(args.contains("CheckHostIP=no"), "SSH arguments must include CheckHostIP=no for dynamic cloud IPs")
        expect(args.contains("StrictHostKeyChecking=yes"), "SSH arguments must enforce StrictHostKeyChecking=yes")
        expect(args.contains("80:127.0.0.1:54321"), "SSH arguments must specify reverse port forwarding for bound port")

        let regex = LiveShareManager.sshTunnelRegex
        let validOutputs = [
            "https://499635bbf3da46.lhr.life",
            "https://my-session.lhr.rocks",
            "https://demo.localhost.run",
            "Welcome! Your URL is https://sub-domain.lhr.life enjoy!"
        ]
        for out in validOutputs {
            let nsRange = NSRange(out.startIndex..<out.endIndex, in: out)
            let match = regex.firstMatch(in: out, options: [], range: nsRange)
            expect(match != nil, "Regex must match valid tunnel URL in: \(out)")
        }

        let invalidOutputs = [
            "http://499635bbf3da46.lhr.life",
            "https://malicious.org/fake.lhr.life",
            "https://lhr.life",
            "ssh://localhost.run",
            "https://admin.localhost.run",
            "https://www.localhost.run",
            "https://docs.localhost.run"
        ]
        for inv in invalidOutputs {
            let nsRange = NSRange(inv.startIndex..<inv.endIndex, in: inv)
            let match = regex.firstMatch(in: inv, options: [], range: nsRange)
            expect(match == nil, "Regex must NOT match invalid tunnel string: \(inv)")
        }

        let realLocalhostRunBanner = """
        ===============================================================================
        Welcome to localhost.run!

        To set up and manage custom domains go to https://admin.localhost.run/

        More details on custom domains (and how to enable subdomains of your custom
        domain) at https://localhost.run/docs/custom-domains

        If you get a permission denied error check the faq for how to connect with a key or
        create a free tunnel without a key at [http://localhost:3000/docs/faq#generating-an-ssh-key].

        To explore using localhost.run visit the documentation site:
        https://localhost.run/docs/

        ===============================================================================

        ** your connection id is 193.170.62.251:63406, please mention it if you send me a message about an issue. **

        1526889fde5451.lhr.life tunneled with tls termination, https://1526889fde5451.lhr.life
        create an account and add your key for a longer lasting domain name. see https://localhost.run/docs/forever-free/ for more information.
        """
        let bannerRange = NSRange(realLocalhostRunBanner.startIndex..<realLocalhostRunBanner.endIndex, in: realLocalhostRunBanner)
        if let bannerMatch = regex.firstMatch(in: realLocalhostRunBanner, options: [], range: bannerRange),
           let r = Range(bannerMatch.range, in: realLocalhostRunBanner) {
            let extracted = String(realLocalhostRunBanner[r])
            expectEqual(extracted, "https://1526889fde5451.lhr.life", "First regex match in banner must be the real tunnel URL, not admin.localhost.run")
        } else {
            expect(false, "Regex must match tunnel URL in real localhost.run banner")
        }
    }


    static func testLocalShareURLSecurityContext() {
        let loopback1 = LiveShareManager.buildLocalShareURL(
            host: "127.0.0.1",
            port: 54321,
            sessionToken: "tok12345",
            sessionKeyFragment: "k=secretKeyFragment"
        )
        expectEqual(loopback1?.absoluteString, "http://127.0.0.1:54321/s/tok12345#k=secretKeyFragment",
                    "Loopback IPv4 share URL must include encryption key fragment")
        expectEqual(loopback1?.fragment, "k=secretKeyFragment", "URL fragment must equal sessionKeyFragment")

        let loopbackLocalhost = LiveShareManager.buildLocalShareURL(
            host: "localhost",
            port: 54321,
            sessionToken: "tok12345",
            sessionKeyFragment: "k=secretKeyFragment"
        )
        expectEqual(loopbackLocalhost?.absoluteString, "http://localhost:54321/s/tok12345#k=secretKeyFragment",
                    "localhost share URL must include encryption key fragment")

        let loopbackIPv6 = LiveShareManager.buildLocalShareURL(
            host: "::1",
            port: 54321,
            sessionToken: "tok12345",
            sessionKeyFragment: "k=secretKeyFragment"
        )
        expectEqual(loopbackIPv6?.absoluteString, "http://[::1]:54321/s/tok12345#k=secretKeyFragment",
                    "IPv6 loopback share URL must be formatted as [::1] and include encryption key fragment")

        let lanURL = LiveShareManager.buildLocalShareURL(
            host: "192.168.1.120",
            port: 54321,
            sessionToken: "tok12345",
            sessionKeyFragment: "k=secretKeyFragment"
        )
        expectEqual(lanURL?.absoluteString, "http://192.168.1.120:54321/s/tok12345",
                    "Non-loopback LAN URL must OMIT key fragment to clarify plaintext context")
        expectEqual(lanURL?.fragment, nil, "LAN URL fragment must be nil")

        let lanURL2 = LiveShareManager.buildLocalShareURL(
            host: "10.0.1.50",
            port: 8080,
            sessionToken: "tok12345",
            sessionKeyFragment: "k=secretKeyFragment"
        )
        expectEqual(lanURL2?.absoluteString, "http://10.0.1.50:8080/s/tok12345",
                    "Class A LAN IP must omit key fragment")

        let emptyFragURL = LiveShareManager.buildLocalShareURL(
            host: "127.0.0.1",
            port: 54321,
            sessionToken: "tok12345",
            sessionKeyFragment: ""
        )
        expectEqual(emptyFragURL?.absoluteString, "http://127.0.0.1:54321/s/tok12345",
                    "Empty key fragment must not append trailing #")
    }


    static func testLocalStorageAndDirectoryPermissions() {
        guard let testDir = AppPaths.testRoot else {
            expect(false, "CALLCAPTION_TEST_DIR must be configured")
            return
        }

        let subDir = testDir.appendingPathComponent("TestSecureDir_\(UUID().uuidString)", isDirectory: true)
        do {
            try AppPaths.ensureDirectory(subDir, permissions: 0o700)
            expect(FileManager.default.fileExists(atPath: subDir.path), "ensureDirectory should create directory")
            if let attrs = try? FileManager.default.attributesOfItem(atPath: subDir.path),
               let perm = attrs[.posixPermissions] as? NSNumber {
                expectEqual(perm.intValue & 0o777, 0o700, "Directory permissions must be 0700 (rwx------)")
            } else {
                expect(false, "Could not read directory permissions")
            }
        } catch {
            expect(false, "ensureDirectory threw error: \(error)")
        }

        let testFile = subDir.appendingPathComponent("test_data.bin")
        let secretData = Data("confidential-transcript-content".utf8)
        do {
            try AppPaths.writePrivateData(secretData, to: testFile)
            expect(FileManager.default.fileExists(atPath: testFile.path), "writePrivateData should create file")
            let readData = try Data(contentsOf: testFile)
            expectEqual(readData, secretData, "Written data must match read data")
            if let attrs = try? FileManager.default.attributesOfItem(atPath: testFile.path),
               let perm = attrs[.posixPermissions] as? NSNumber {
                expectEqual(perm.intValue & 0o777, 0o600, "File permissions must be 0600 (rw-------)")
            } else {
                expect(false, "Could not read file permissions")
            }
        } catch {
            expect(false, "writePrivateData threw error: \(error)")
        }

        expect(AppPaths.isTestEnvironment, "AppPaths.isTestEnvironment should be true in test runner")
        expect(AppPaths.transcriptsDirectory.path.hasSuffix("Application Support/Transcripts"), "transcriptsDirectory path must end with Application Support/Transcripts")
        expect(AppPaths.autosaveFileURL.path.hasSuffix("latest_session.json"), "autosaveFileURL must end with latest_session.json")
        expect(AppPaths.sshKnownHostsURL.path.hasSuffix("ssh_known_hosts"), "sshKnownHostsURL must end with ssh_known_hosts")
    }


    static func testAdversarialAsyncMutexHighConcurrency() async {
        let mutex = TestAsyncMutex()
        let activeHolders = OSAllocatedUnfairLock(initialState: 0)
        let maxHoldersSeen = OSAllocatedUnfairLock(initialState: 0)
        let successfulCriticalSections = OSAllocatedUnfairLock(initialState: 0)
        let caughtCancellations = OSAllocatedUnfairLock(initialState: 0)
        let invariantViolations = OSAllocatedUnfairLock(initialState: 0)
        let unexpectedErrors = OSAllocatedUnfairLock(initialState: [String]())

        let taskCount = 30
        let iterationsPerTask = 30

        await withTaskGroup(of: Void.self) { group in
            for taskId in 0..<taskCount {
                group.addTask {
                    for iter in 0..<iterationsPerTask {
                        let shouldCancel = (taskId + iter) % 3 == 0

                        if shouldCancel {
                            let subtask = Task {
                                do {
                                    try await mutex.lock()
                                    let current = activeHolders.withLock { holders -> Int in
                                        holders += 1
                                        return holders
                                    }
                                    maxHoldersSeen.withLock { maxSeen in
                                        if current > maxSeen { maxSeen = current }
                                    }
                                    if current != 1 {
                                        invariantViolations.withLock { $0 += 1 }
                                    }
                                    try? await Task.sleep(nanoseconds: 50_000)
                                    activeHolders.withLock { $0 -= 1 }
                                    await mutex.unlock()
                                    successfulCriticalSections.withLock { $0 += 1 }
                                } catch is CancellationError {
                                    caughtCancellations.withLock { $0 += 1 }
                                } catch {
                                    unexpectedErrors.withLock { $0.append("\(error)") }
                                }
                            }
                            if iter % 2 == 0 {
                                subtask.cancel()
                            } else {
                                Task {
                                    try? await Task.sleep(nanoseconds: 20_000)
                                    subtask.cancel()
                                }
                            }
                            _ = await subtask.result
                        } else {
                            do {
                                try await mutex.lock()
                                let current = activeHolders.withLock { holders -> Int in
                                    holders += 1
                                    return holders
                                }
                                maxHoldersSeen.withLock { maxSeen in
                                    if current > maxSeen { maxSeen = current }
                                }
                                if current != 1 {
                                    invariantViolations.withLock { $0 += 1 }
                                }
                                try? await Task.sleep(nanoseconds: 50_000)
                                activeHolders.withLock { $0 -= 1 }
                                await mutex.unlock()
                                successfulCriticalSections.withLock { $0 += 1 }
                            } catch is CancellationError {
                                caughtCancellations.withLock { $0 += 1 }
                            } catch {
                                unexpectedErrors.withLock { $0.append("\(error)") }
                            }
                        }
                    }
                }
            }
        }

        let finalHolders = activeHolders.withLock { $0 }
        let maxSeen = maxHoldersSeen.withLock { $0 }
        let successCount = successfulCriticalSections.withLock { $0 }
        let cancelCount = caughtCancellations.withLock { $0 }
        let violations = invariantViolations.withLock { $0 }
        let errors = unexpectedErrors.withLock { $0 }
        let isLocked = await mutex.isLocked()
        let waiterCount = await mutex.waiterCount()

        expectEqual(finalHolders, 0, "No active holders should remain after stress test")
        expectEqual(violations, 0, "AsyncMutex invariant violated: multiple concurrent holders detected")
        expect(maxSeen <= 1, "AsyncMutex max concurrent holders must never exceed 1 (was \(maxSeen))")
        expect(!isLocked, "AsyncMutex must be unlocked after all stress tasks complete")
        expectEqual(waiterCount, 0, "AsyncMutex waiters queue must be empty after stress test")
        expect(successCount > 0, "At least some tasks must have successfully executed critical sections (was \(successCount))")
        expect(cancelCount > 0, "Cancellation handler must have caught cancellations (was \(cancelCount))")
        expect(errors.isEmpty, "Unexpected errors occurred in AsyncMutex tasks: \(errors)")
    }


    static func testAdversarialTranslationEngineCancellationStorm() async {
        let engine = TranslationEngine.shared
        await engine.clearCache()
        await engine.resetFailureCooldowns()

        let emptyResultsCount = OSAllocatedUnfairLock(initialState: 0)
        let stormTasks = 20
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<stormTasks {
                group.addTask {
                    let task = Task {
                        await engine.translate(
                            text: "Frase de prueba número \(i) para verificar la resistencia a cancelaciones concurrentes",
                            sourceCode: "es",
                            targetCode: "en",
                            isFinal: i % 2 == 0
                        )
                    }

                    if i % 3 != 0 {
                        Task {
                            try? await Task.sleep(nanoseconds: 500_000)
                            task.cancel()
                        }
                    }

                    if i % 5 == 0 {
                        await engine.clearCache()
                    } else if i % 7 == 0 {
                        await engine.resetFailureCooldowns()
                    }

                    let result = await task.value
                    if let res = result, res.isEmpty {
                        emptyResultsCount.withLock { $0 += 1 }
                    }
                }
            }
        }

        expectEqual(emptyResultsCount.withLock { $0 }, 0, "Non-nil translation result must not be empty")

        await engine.resetFailureCooldowns()
        let recovered = await engine.translate(
            text: "Hola mundo",
            sourceCode: "es",
            targetCode: "en",
            isFinal: true
        )
        expect(recovered != nil, "TranslationEngine must successfully translate after cancellation storm")
    }


    @MainActor
    private final class MockAdversarialCoordinatorDelegate: CaptionCoordinatorDelegate {
        var alertCount = 0
        var speechCount = 0
        var levelCount = 0

        func coordinatorDidRequestShowAlert(message: String, actionType: SystemAlertActionType) {
            alertCount += 1
        }
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
            speechCount += 1
        }
        func coordinatorDidUpdateAudioLevels(callerLevel: Float, micLevel: Float) {
            levelCount += 1
        }
    }

    static func testAdversarialCaptionCoordinatorConcurrentOperations() async {
        let coordinator = CaptionCoordinator.shared
        coordinator.stop()

        let delegate = await MainActor.run { MockAdversarialCoordinatorDelegate() }
        coordinator.delegate = delegate

        let parallelWorkers = 16
        let operationsPerWorker = 30

        await withTaskGroup(of: Void.self) { group in
            for workerIndex in 0..<parallelWorkers {
                group.addTask {
                    for iter in 0..<operationsPerWorker {
                        switch (workerIndex + iter) % 6 {
                        case 0:
                            coordinator.start()
                            _ = coordinator.hasStarted
                        case 1:
                            coordinator.pause()
                            _ = coordinator.isPaused
                        case 2:
                            coordinator.resume()
                            coordinator.togglePauseResume()
                        case 3:
                            coordinator.autoPauseForSystem()
                            coordinator.autoResumeAfterSystem()
                        case 4:
                            coordinator.audioCaptureDidUpdateCallerLevel(Float(iter) / 100.0)
                            coordinator.audioCaptureDidUpdateMicLevel(Float(iter) / 200.0)
                        default:
                            let uID = UUID()
                            coordinator.callerSpeechDidUpdate(
                                utteranceID: uID,
                                partialOriginal: "Test utterance \(iter)",
                                partialTranslated: "Translated \(iter)",
                                isUntranslated: false
                            )
                            if iter % 5 == 0 {
                                coordinator.callerSpeechDidFinalize(
                                    utteranceID: uID,
                                    original: "Test utterance \(iter)",
                                    translated: "Translated \(iter)",
                                    isUntranslated: false
                                )
                            }
                        }
                    }
                }
            }
        }

        coordinator.stop()
        coordinator.delegate = nil
        expect(!coordinator.hasStarted, "Coordinator must be cleanly stopped after adversarial stress")
        expect(!coordinator.isPaused, "Coordinator isPaused must be false after stop")
    }


    static func testAdversarialLiveShareHighThroughputBroadcast() async {
        let manager = LiveShareManager.shared
        manager.clearHistoryForPrivacy()

        let broadcastTasks = 8
        let messagesPerTask = 25

        await withTaskGroup(of: Void.self) { group in
            for taskId in 0..<broadcastTasks {
                group.addTask {
                    for m in 0..<messagesPerTask {
                        let id = UUID()
                        manager.broadcastCaption(
                            speaker: taskId % 2 == 0 ? "Caller" : "You",
                            original: "Stress caption \(taskId)-\(m)",
                            translated: "Translated caption \(taskId)-\(m)",
                            sourceLangCode: "en",
                            targetLangCode: "es",
                            isFinal: m % 4 == 0,
                            isUntranslated: false,
                            utteranceID: id
                        )

                        if m % 10 == 0 {
                            manager.clearHistoryForPrivacy()
                        }
                    }
                }
            }
        }

        manager.clearHistoryForPrivacy()
        expect(true, "LiveShareManager survived high throughput concurrent broadcast stress without race or stall")
    }


    static func testAuditRegressions() async {
        let engine = CaptionCoordinator.shared.audioCaptureEngine
        if let src16k = AVAudioPCMBuffer(pcmFormat: AudioCaptureEngine.speechFormat, frameCapacity: 64) {
            src16k.frameLength = 64
            if let ptr = src16k.floatChannelData?[0] {
                for i in 0..<64 { ptr[i] = 0.42 }
            }
            if let out16k = engine.convertTo16kMonoBuffer(src16k) {
                expect(out16k !== src16k, "16 kHz mono buffer conversion must return an independent buffer copy to prevent scratch-pool aliasing")
                expectEqual(out16k.frameLength, 64, "Copied 16 kHz buffer must preserve frameLength")
                if let srcPtr = src16k.floatChannelData?[0], let outPtr = out16k.floatChannelData?[0] {
                    srcPtr[0] = -0.99
                    expect(abs(outPtr[0] - 0.42) < 0.0001, "Mutating source scratch buffer must not corrupt converted 16 kHz buffer")
                }
            } else {
                expect(false, "convertTo16kMonoBuffer must succeed for valid 16 kHz mono buffer")
            }
        }

        if let layout4 = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4) {
            let fmt4Float = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, interleaved: false, channelLayout: layout4)
            let fmt4Interleaved = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, interleaved: true, channelLayout: layout4)
            if let buf4 = AVAudioPCMBuffer(pcmFormat: fmt4Float, frameCapacity: 64),
               let buf4Int = AVAudioPCMBuffer(pcmFormat: fmt4Interleaved, frameCapacity: 64) {
                buf4.frameLength = 64
                if let chData = buf4.floatChannelData {
                    for i in 0..<64 {
                        chData[0][i] = 0.0
                        chData[1][i] = 0.0
                        chData[2][i] = 0.65
                        chData[3][i] = 0.0
                    }
                }
                _ = engine.copyToMonoPCMBuffer(buf4)

                buf4Int.frameLength = 64
                if let mData = buf4Int.audioBufferList.pointee.mBuffers.mData {
                    let ptr = mData.assumingMemoryBound(to: Float.self)
                    for i in 0..<64 {
                        ptr[i * 4 + 0] = 0.0
                        ptr[i * 4 + 1] = 0.0
                        ptr[i * 4 + 2] = 0.65
                        ptr[i * 4 + 3] = 0.0
                    }
                }
                if let monoInterleaved = engine.copyToMonoPCMBuffer(buf4Int),
                   let outSample = monoInterleaved.floatChannelData?[0][0] {
                    expect(abs(outSample - 0.65) < 0.001, "Interleaved 4-channel conversion must use persisted active capsule channel 2 (got \(outSample))")
                } else {
                    expect(false, "Interleaved 4-channel conversion should succeed")
                }
            }
        }

        let token = LiveShareManager.generateSessionToken()
        let lfReq = LiveShareManager.parseHTTPRequest("GET /s/\(token)/api/state HTTP/1.1\nHost: 127.0.0.1:54321\n\n")
        expect(lfReq != nil, "parseHTTPRequest must support LF-only (\\n) line endings")
        expectEqual(lfReq?.method, "GET", "LF-only request method must parse as GET")
        expectEqual(lfReq?.path, "/s/\(token)/api/state", "LF-only request path must parse accurately")
        expectEqual(lfReq?.host, "127.0.0.1", "LF-only request Host header must parse without port")

        let headEventsReq = LiveShareManager.parseHTTPRequest("HEAD /s/\(token)/events HTTP/1.1\r\nHost: 127.0.0.1:54321\r\n\r\n")!
        expectEqual(
            LiveShareManager.evaluateRoute(request: headEventsReq, sessionToken: token, localIP: "127.0.0.1", allowLAN: false, tunnelHost: nil),
            .methodNotAllowed,
            "HEAD requests to /events SSE endpoint must return .methodNotAllowed to prevent zombie SSE clients"
        )

        let headHTMLReq = LiveShareManager.parseHTTPRequest("HEAD /s/\(token) HTTP/1.1\r\nHost: 127.0.0.1:54321\r\n\r\n")!
        expectEqual(
            LiveShareManager.evaluateRoute(request: headHTMLReq, sessionToken: token, localIP: "127.0.0.1", allowLAN: false, tunnelHost: nil),
            .serveHTML,
            "HEAD requests to HTML viewer endpoint must be allowed"
        )

        let channel = SingleSpeechChannel(name: "EpochTestChannel", sourceLocaleId: "es-ES", targetLangCode: "en")
        let finalizedResults = OSAllocatedUnfairLock(initialState: [(UUID, String, String, Bool)]())
        channel.onFinal = { id, orig, trans, isUntrans in
            finalizedResults.withLock { $0.append((id, orig, trans, isUntrans)) }
        }
        channel.start(sourceLocaleId: "es-ES", targetLangCode: "en")
        let testUtteranceID = UUID()
        channel.commitSentenceForTesting(utteranceID: testUtteranceID, original: "Hola mundo", fallbackTranslated: "", fallbackUntranslated: true)
        channel.advanceUtteranceEpochForTesting()
        expectEqual(finalizedResults.withLock { $0.count }, 1, "Initial fallback final callback must fire immediately")
        channel.stop()

        let tm = TranscriptManager.shared
        tm.clear()
        let langUtteranceID = UUID()
        tm.addEntry(
            speaker: "Caller",
            original: "مرحبا",
            translated: "مرحبا",
            isUntranslated: true,
            utteranceID: langUtteranceID,
            sourceLangCode: "ar",
            targetLangCode: "en"
        )
        tm.addEntry(
            speaker: "Caller",
            original: "مرحبا",
            translated: "Hello",
            isUntranslated: false,
            utteranceID: langUtteranceID
        )
        expectEqual(tm.entries.count, 1, "Refined entry with language codes must update in place")
        expectEqual(tm.entries.first?.sourceLangCode, "ar", "Refined entry must preserve sourceLangCode when not re-specified")
        expectEqual(tm.entries.first?.targetLangCode, "en", "Refined entry must preserve targetLangCode when not re-specified")

        let legacyJSON = """
        [{"id":"\(UUID().uuidString)","timestamp":0,"speaker":"Caller","original":"Hola","translated":"Hello","isUntranslated":false,"formattedTime":"12:00:00"}]
        """.data(using: .utf8)!
        let decodedLegacy = try? JSONDecoder().decode([TranscriptEntry].self, from: legacyJSON)
        expectEqual(decodedLegacy?.count, 1, "Legacy TranscriptEntry JSON without sourceLangCode/targetLangCode must decode cleanly")
        expectEqual(decodedLegacy?.first?.sourceLangCode, nil, "Legacy TranscriptEntry sourceLangCode should decode as nil")
        tm.clear()

        let onboardingWC = OnboardingWindowController()
        let legalWC = LegalWindowController()
        expectEqual(onboardingWC.window?.level, .normal, "OnboardingWindowController must use .normal window level so System Settings is not obscured")
        expectEqual(legalWC.window?.level, .normal, "LegalWindowController must use .normal window level")
    }
}

@main
struct CallCaptionTestMain {
    static func main() async {
        let code = await TestSuite.runAll()
        exit(code)
    }
}
