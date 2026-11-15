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
        testAudioCheckerAndAutomaticGainCalibration()
        testSSHKnownHostsPreSeedingAndStrictHostKeyChecking()
        testLocalShareURLSecurityContext()
        testLocalStorageAndDirectoryPermissions()

        await testAdversarialAsyncMutexHighConcurrency()
        await testAdversarialTranslationEngineCancellationStorm()
        await testAdversarialCaptionCoordinatorConcurrentOperations()
        await testAdversarialLiveShareHighThroughputBroadcast()
        await testAuditRegressions()
        testSpeechAssetDownloaderAndDictationModelCaching()

        await testTranslationEngineRealHooksAndEviction()
        await testLiveShareHTTPAndSSELifecycle()
        testAudioCaptureSafetyAndDiagnostics()
        testAppSettingsAndPathsSecurity()
        await testLanguageModelsAndDownloaderEdgeCases()
        await testDeterministicSpanishDialectResolution()
        await testUIControllersAndLocalizationRegressions()
        await testAuditRound2Regressions()

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

        expectEqual(L10n.tr("header.callerLanguage", "Caller Language", language: "es"), "Idioma del interlocutor", "Spanish header.callerLanguage should match")
        expectEqual(L10n.tr("menu.settings", "Settings…", language: "es"), "Ajustes…", "Spanish menu.settings should match")
        expectEqual(L10n.tr("menu.showCaptions", "Show Captions", language: "es"), "Mostrar subtítulos", "Spanish menu.showCaptions should match")

        let savedAppLang = AppSettings.shared.appLanguageCode
        defer { AppSettings.shared.appLanguageCode = savedAppLang }

        AppSettings.shared.appLanguageCode = "es"
        expectEqual(AppSettings.shared.appLanguageCode, "es", "appLanguageCode should switch to 'es'")
        expectEqual(L10n.tr("menu.appLanguage", "App Language"), "Idioma de la aplicación", "Spanish app language menu title should match")
        expectEqual(SupportedLanguages.item(forCode: "es")?.localizedName, "Español", "Spanish language localizedName should be Español")
        expectEqual(SupportedLanguages.item(forCode: "en")?.localizedName, "Inglés", "English language localizedName in Spanish UI should be Inglés")

        AppSettings.shared.appLanguageCode = "en"
        expectEqual(AppSettings.shared.appLanguageCode, "en", "appLanguageCode should restore to 'en'")
        expectEqual(L10n.tr("header.callerLanguage", "Caller Language"), "Caller Language", "Restored English header.callerLanguage should match")
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
        tm.flushPersistence()
        expect(FileManager.default.fileExists(atPath: url.path), "Autosave should be written to the test Application Support directory")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let permissions = attrs[.posixPermissions] as? NSNumber {
            expectEqual(permissions.intValue & 0o777, 0o600, "Autosaved transcripts must be user-only (0600)")
        } else {
            expect(false, "Autosaved transcript permissions should be inspectable")
        }

        tm.deleteSavedSession()
        tm.flushPersistence()
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
        let settings = SettingsWindowController()
        if let root = settings.window?.contentView {
            verifyNoSiblingOverlaps(in: root, context: "SettingsWindowController.root")
            verifyControlsFitWidth(in: root, context: "SettingsWindowController.root")
            for sub in root.subviews {
                if let tabView = sub as? NSTabView {
                    for (tabIdx, item) in tabView.tabViewItems.enumerated() {
                        if let tabViewContent = item.view {
                            verifyNoSiblingOverlaps(in: tabViewContent, context: "SettingsWindowController.tab[\(tabIdx)]")
                            verifyControlsFitWidth(in: tabViewContent, context: "SettingsWindowController.tab[\(tabIdx)]")
                            for cardSub in tabViewContent.subviews {
                                if let box = cardSub as? NSBox, let boxContent = box.contentView {
                                    verifyNoSiblingOverlaps(in: boxContent, context: "SettingsWindowController.tab[\(tabIdx)].card")
                                    verifyControlsFitWidth(in: boxContent, context: "SettingsWindowController.tab[\(tabIdx)].card")
                                }
                            }
                        }
                    }
                }
            }
        }
        let enOnboarding = OnboardingWindowController()
        if let root = enOnboarding.window?.contentView {
            verifyNoSiblingOverlaps(in: root, context: "OnboardingWindowController.root")
            verifyControlsFitWidth(in: root, context: "OnboardingWindowController.root")
            for sub in root.subviews {
                if let box = sub as? NSBox, let content = box.contentView {
                    verifyNoSiblingOverlaps(in: content, context: "OnboardingWindowController.card")
                    verifyControlsFitWidth(in: content, context: "OnboardingWindowController.card")
                }
            }
        }
        let enLegal = LegalWindowController()
        if let root = enLegal.window?.contentView {
            verifyNoSiblingOverlaps(in: root, context: "LegalWindowController.root")
            verifyControlsFitWidth(in: root, context: "LegalWindowController.root")
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
        if let header = trayVC.view.subviews.first(where: { $0.subviews.contains(where: { $0.identifier?.rawValue == "trayAppLanguageButton" }) }) {
            verifyNoSiblingOverlaps(in: header, context: "TrayCaptionViewController.header")
        } else {
            expect(false, "TrayCaptionViewController header must contain trayAppLanguageButton")
        }

        trayVC.showLiveShareBanner()
        verifyNoOverlaps(in: filterOverlays(trayVC.view), context: "TrayCaptionViewController.liveShareBanner")

        trayVC.showAlertBanner(message: "Test Alert", actionType: .audioCapture)
        verifyNoOverlaps(in: filterOverlays(trayVC.view), context: "TrayCaptionViewController.bothBanners")

        trayVC.hideLiveShareBanner()
        verifyNoOverlaps(in: filterOverlays(trayVC.view), context: "TrayCaptionViewController.alertBannerOnly")

        let savedAppLang = AppSettings.shared.appLanguageCode
        defer { AppSettings.shared.appLanguageCode = savedAppLang }

        AppSettings.shared.appLanguageCode = "en"
        if let appLangBtn = trayVC.view.subviews
            .flatMap({ $0.subviews })
            .first(where: { $0.identifier?.rawValue == "trayAppLanguageButton" }) as? NSButton {
            expect(!appLangBtn.isHidden, "Tray app language selector must be visible")
            expect(appLangBtn.action != nil, "Tray app language selector must have an action")
            expect(appLangBtn.fittingSize.width <= appLangBtn.frame.width, "Tray app language selector ('\(appLangBtn.title)') fittingWidth \(appLangBtn.fittingSize.width) must fit in frame width \(appLangBtn.frame.width)")
            expectEqual(appLangBtn.title, "🇬🇧 EN ▾", "Tray app language selector title in English")
            expectEqual(appLangBtn.toolTip, "App Language: English", "Tray app language selector tooltip in English")

            AppSettings.shared.appLanguageCode = "es"
            expectEqual(appLangBtn.title, "🇪🇸 ES ▾", "Tray app language selector should update live to Spanish")
            expect(appLangBtn.fittingSize.width <= appLangBtn.frame.width, "Tray app language selector ('\(appLangBtn.title)') fittingWidth \(appLangBtn.fittingSize.width) must fit in frame width \(appLangBtn.frame.width)")
            expect((appLangBtn.toolTip ?? "").contains("Español"), "Tray app language selector tooltip should update live to Spanish")
        }

        AppSettings.shared.appLanguageCode = "es"
        do {
            let esOnboarding = OnboardingWindowController()
            if let root = esOnboarding.window?.contentView {
                verifyNoSiblingOverlaps(in: root, context: "OnboardingWindowController(es).root")
                verifyControlsFitWidth(in: root, context: "OnboardingWindowController(es).root")
                for sub in root.subviews {
                    if let box = sub as? NSBox, let content = box.contentView {
                        verifyNoSiblingOverlaps(in: content, context: "OnboardingWindowController(es).card")
                        verifyControlsFitWidth(in: content, context: "OnboardingWindowController(es).card")
                    }
                }
            }
            let esLegal = LegalWindowController()
            if let root = esLegal.window?.contentView {
                verifyNoSiblingOverlaps(in: root, context: "LegalWindowController(es).root")
                verifyControlsFitWidth(in: root, context: "LegalWindowController(es).root")
            }
            let esSettings = SettingsWindowController()
            if let root = esSettings.window?.contentView {
                verifyNoSiblingOverlaps(in: root, context: "SettingsWindowController(es).root")
                verifyControlsFitWidth(in: root, context: "SettingsWindowController(es).root")
                for sub in root.subviews {
                    if let tabView = sub as? NSTabView {
                        for (tabIdx, item) in tabView.tabViewItems.enumerated() {
                            if let tabViewContent = item.view {
                                verifyNoSiblingOverlaps(in: tabViewContent, context: "SettingsWindowController(es).tab[\(tabIdx)]")
                                verifyControlsFitWidth(in: tabViewContent, context: "SettingsWindowController(es).tab[\(tabIdx)]")
                                for cardSub in tabViewContent.subviews {
                                    if let box = cardSub as? NSBox, let boxContent = box.contentView {
                                        verifyNoSiblingOverlaps(in: boxContent, context: "SettingsWindowController(es).tab[\(tabIdx)].card")
                                        verifyControlsFitWidth(in: boxContent, context: "SettingsWindowController(es).tab[\(tabIdx)].card")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            let esTrayVC = TrayCaptionViewController()
            esTrayVC.loadViewIfNeeded()
            esTrayVC.updateLayout()
            verifyNoOverlaps(in: filterOverlays(esTrayVC.view), context: "TrayCaptionViewController(es).default")
            if let header = esTrayVC.view.subviews.first(where: { $0.subviews.contains(where: { $0.identifier?.rawValue == "trayAppLanguageButton" }) }) {
                verifyNoSiblingOverlaps(in: header, context: "TrayCaptionViewController(es).header")
            }
        }
    }

    private static func verifyControlsFitWidth(in container: NSView, context: String) {
        for view in container.subviews where !view.isHidden {
            if let btn = view as? NSButton, !(view is NSPopUpButton), btn.bezelStyle == .rounded, !btn.title.isEmpty {
                expect(
                    btn.fittingSize.width <= btn.frame.width + 1.0,
                    "\(context): NSButton '\(btn.title)' fittingSize.width (\(btn.fittingSize.width)) exceeds frame.width (\(btn.frame.width))"
                )
            } else if let seg = view as? NSSegmentedControl {
                expect(
                    seg.fittingSize.width <= seg.frame.width + 1.0,
                    "\(context): NSSegmentedControl fittingSize.width (\(seg.fittingSize.width)) exceeds frame.width (\(seg.frame.width))"
                )
            }
        }
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


    static func testAsyncMutexTaskCancellation() async {
        let mutex = AsyncMutex()

        do {
            try await mutex.lock()
            let locked1 = await mutex.isLocked
            expect(locked1, "Mutex should be locked after lock()")
            let waiters1 = await mutex.waiterCount
            expectEqual(waiters1, 0, "No waiters when lock is held by caller")
            await mutex.unlock()
            let locked2 = await mutex.isLocked
            expect(!locked2, "Mutex should be unlocked after unlock()")
        } catch {
            expect(false, "Basic lock/unlock should not throw: \(error)")
        }

        do {
            try await mutex.lock()
            let holderLocked = await mutex.isLocked
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
                let count = await mutex.waiterCount
                if count == 2 { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            let waiterCount2 = await mutex.waiterCount
            expectEqual(waiterCount2, 2, "Both waiters should be enqueued in mutex")

            waiter1.cancel()
            _ = await waiter1.result

            for _ in 0..<20 {
                let count = await mutex.waiterCount
                if count == 1 { break }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            let waiterCount1 = await mutex.waiterCount
            expectEqual(waiterCount1, 1, "Cancelled waiter must be cleanly removed from queue")
            expect(waiter1Cancelled.withLock { $0 }, "Waiter1 must catch CancellationError")

            await mutex.unlock()
            _ = await waiter2.result

            expect(waiter2Acquired.withLock { $0 }, "Waiter2 must acquire lock after waiter1 cancellation")
            let unlocked = await mutex.isLocked
            expect(!unlocked, "Mutex should be unlocked after all tasks finish")
            let finalWaiters = await mutex.waiterCount
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
        let preLocked = await mutex.isLocked
        expect(!preLocked, "Pre-cancelled task must not acquire or hold lock")
    }


    static func testTranslationEngineCancellationAndCache() async {
        let engine = TranslationEngine.shared
        await engine.resetForTesting()

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

        // Test real TranslationEngine 2048-entry ring buffer cache eviction using #if CALLCAPTION_TESTING mock hook
        await engine.resetForTesting()
        await engine.setTranslatorForTesting { text, _, _, _ in
            "tr_\(text)"
        }
        let maxCache = 2048
        for i in 0..<(maxCache + 50) {
            let res = await engine.translate(
                text: "ring_item_\(i)",
                sourceCode: "es",
                targetCode: "en",
                isFinal: true
            )
            if i == 0 || i == maxCache + 49 {
                expectEqual(res, "tr_ring_item_\(i)", "Mock translator output must match")
            }
        }
        expectEqual(await engine.cachedEntryCountForTesting(), maxCache, "Real TranslationEngine final cache count must cap at 2048")
        expectEqual(await engine.cachedValueForTesting(text: "ring_item_0", sourceCode: "es", targetCode: "en"), nil, "Oldest entry ring_item_0 must be evicted")
        expectEqual(await engine.cachedValueForTesting(text: "ring_item_49", sourceCode: "es", targetCode: "en"), nil, "Oldest entry ring_item_49 must be evicted")
        expectEqual(await engine.cachedValueForTesting(text: "ring_item_50", sourceCode: "es", targetCode: "en"), "tr_ring_item_50", "Entry ring_item_50 must survive eviction")
        expectEqual(await engine.cachedValueForTesting(text: "ring_item_\(maxCache + 49)", sourceCode: "es", targetCode: "en"), "tr_ring_item_\(maxCache + 49)", "Latest entry must remain cached")

        await engine.resetForTesting()
    }


    static func testCaptionCoordinatorThreadSafety() async {
        let coordinator = CaptionCoordinator.shared
        let savedOnboarding = AppSettings.shared.hasCompletedOnboarding
        let savedMicEnabled = AppSettings.shared.isMicEnabled
        AppSettings.shared.hasCompletedOnboarding = true
        AppSettings.shared.isMicEnabled = false
        defer {
            coordinator.stop()
            AppSettings.shared.isMicEnabled = savedMicEnabled
            AppSettings.shared.hasCompletedOnboarding = savedOnboarding
        }

        coordinator.stop()

        expect(!coordinator.hasStarted, "Coordinator should be stopped initially")
        expect(!coordinator.isPaused, "Coordinator should not be paused initially")

        coordinator.start()
        expect(coordinator.hasStarted, "Coordinator must start when hasCompletedOnboarding is true")

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
                int32Data[0][i] = 1_717_986_918 // ~+0.8
                int32Data[1][i] = 429_496_730   // ~+0.2 -> stereo downmix ~0.5
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
            expect(abs(sample - 0.5) < 0.001, "32-bit integer stereo downmix (0.8 + 0.2) * 0.5 must normalize to ~0.5 (got \(sample))")
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
        expect(abs(s16 - 0.375) < 0.01, "Int16 stereo downmix (0.50 + 0.25) * 0.5 must normalize to ~0.375 (got \(s16))")

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
        let mgr = SpeechRecognitionManager()
        mgr.start(
            callerLocaleId: "es-ES",
            targetLangCode: "en",
            micLocaleId: "en-US",
            micTargetLangCode: "es",
            isMicEnabled: true
        )
        defer { mgr.stop() }

        guard let buf = AVAudioPCMBuffer(pcmFormat: AudioCaptureEngine.speechFormat, frameCapacity: 320),
              let ptr = buf.floatChannelData?[0] else {
            expect(false, "Failed to allocate PCM buffer for backpressure test")
            return
        }
        buf.frameLength = 320
        for i in 0..<320 { ptr[i] = 0.05 }

        // Exceed SingleSpeechChannel's bounded backlog limit (16 buffers) rapidly across caller and mic paths
        mgr.isAcousticallyIsolated = false
        for _ in 0..<30 {
            mgr.feedCallerAudioBuffer(buf, userHasFloor: false)
            mgr.feedMicAudioBuffer(buf, isUserSpeaking: false)
        }
        expect(mgr.micChannel.isSuspended, "Mic channel must stay suspended when caller holds floor under backlog pressure")

        mgr.stop()
        expect(!mgr.micChannel.isSuspended, "Stopping SpeechRecognitionManager must cleanly drain and unsuspend channels")
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

        mgr.feedMicAudioBuffer(buf)
        expect(mgr.micChannel.isSuspended, "Ungated/echo mic audio must not take the floor from the caller")

        mgr.feedMicAudioBuffer(buf, isUserSpeaking: true)
        expect(!mgr.micChannel.isSuspended, "Confirmed user speech must take the floor immediately instead of waiting for the caller hangover")

        mgr.feedCallerAudioBuffer(buf, userHasFloor: true)
        expect(!mgr.micChannel.isSuspended, "Caller hangover audio must not tear down the user's in-progress reply")

        mgr.feedCallerAudioBuffer(buf, userHasFloor: false)
        expect(mgr.micChannel.isSuspended, "Caller must regain the floor once the user stops speaking")
        mgr.micChannel.resumeAfterMicPriority()

        // Turn-taking: whoever started speaking first keeps the floor.
        expectEqual(
            AudioCaptureEngine.resolveFloorOwner(current: .none, isCallerActive: false, isUserActive: true),
            .user, "User starting first must take the floor"
        )
        expectEqual(
            AudioCaptureEngine.resolveFloorOwner(current: .user, isCallerActive: true, isUserActive: true),
            .user, "Caller starting while the user talks must NOT steal the floor"
        )
        expectEqual(
            AudioCaptureEngine.resolveFloorOwner(current: .caller, isCallerActive: true, isUserActive: true),
            .caller, "User starting while the caller talks must NOT steal the floor"
        )
        expectEqual(
            AudioCaptureEngine.resolveFloorOwner(current: .user, isCallerActive: true, isUserActive: false),
            .caller, "Floor passes to the caller once the user's turn ends"
        )
        expectEqual(
            AudioCaptureEngine.resolveFloorOwner(current: .caller, isCallerActive: false, isUserActive: true),
            .user, "Floor passes to the user once the caller's turn ends"
        )
        expectEqual(
            AudioCaptureEngine.resolveFloorOwner(current: .caller, isCallerActive: false, isUserActive: false),
            SpeechFloorOwner.none, "Floor is released when nobody is speaking"
        )
        let holdThreshold = AudioCaptureEngine.userFloorHoldThreshold(
            micSpeechThreshold: AudioCaptureEngine.defaultMicSpeechThreshold,
            estimatedUserSpeechRMS: 0.04
        )
        expect(holdThreshold < 0.035, "Floor-hold gate must accept the user's normal speech level (got \(holdThreshold))")
        expect(holdThreshold > AudioCaptureEngine.defaultMicSpeechThreshold, "Floor-hold gate must stay above the idle mic threshold")
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

        let replyAfterCallerFinished = AudioCaptureEngine.evaluateMicEchoState(
            rawCallerRMS: 0.0015,
            callerPeakEnvelope: 0.0020,
            isCallerCurrentlySpeaking: true,
            timeSinceLastCallerVoice: 0.35,
            isAcousticallyIsolated: false,
            isMicCurrentlySpeaking: false
        )
        expect(replyAfterCallerFinished.isCallerSpeakingOrEchoing, "Echo tail after caller voice must still be treated as echo")
        expect(replyAfterCallerFinished.effectiveThreshold < 0.02, "Echo-tail threshold must allow normal conversational speech (got \(replyAfterCallerFinished.effectiveThreshold))")
        expect(replyAfterCallerFinished.effectiveThreshold >= AudioCaptureEngine.defaultMicSpeechThreshold * 4.0, "Echo-tail threshold must stay above the idle mic threshold")
        expectEqual(replyAfterCallerFinished.requiredFrames, 3, "Echo-tail onset should require fewer frames than active echo")

        let loudCallerTail = AudioCaptureEngine.evaluateMicEchoState(
            rawCallerRMS: 0.030,
            callerPeakEnvelope: 0.040,
            isCallerCurrentlySpeaking: true,
            timeSinceLastCallerVoice: 0.30,
            isAcousticallyIsolated: false,
            isMicCurrentlySpeaking: false
        )
        expect(loudCallerTail.effectiveThreshold >= 0.08, "Echo-tail threshold must still scale with loud caller energy (got \(loudCallerTail.effectiveThreshold))")

        let replyAfterLoudCaller = AudioCaptureEngine.evaluateMicEchoState(
            rawCallerRMS: 0.0010,
            callerPeakEnvelope: 0.080,
            isCallerCurrentlySpeaking: true,
            timeSinceLastCallerVoice: 0.30,
            isAcousticallyIsolated: false,
            isMicCurrentlySpeaking: false
        )
        expect(replyAfterLoudCaller.effectiveThreshold < 0.03, "A held peak from a loud caller must decay in the echo tail so a reply 0.3 s later is accepted (got \(replyAfterLoudCaller.effectiveThreshold))")

        let earlyTail = AudioCaptureEngine.evaluateMicEchoState(
            rawCallerRMS: 0.0010,
            callerPeakEnvelope: 0.080,
            isCallerCurrentlySpeaking: true,
            timeSinceLastCallerVoice: 0.26,
            isAcousticallyIsolated: false,
            isMicCurrentlySpeaking: false
        )
        expect(earlyTail.effectiveThreshold >= replyAfterLoudCaller.effectiveThreshold, "Echo-tail threshold must decrease monotonically over time")
        expect(AudioCaptureEngine.echoTailDecay(after: 0) == 1.0, "Echo decay must start at unity")
        expect(AudioCaptureEngine.echoTailDecay(after: .greatestFiniteMagnitude) == 0, "Echo decay must vanish for long silence")

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

        let dummyHostsURL = URL(fileURLWithPath: "/tmp/Application Support/CallCaption/ssh_known_hosts")
        let args = LiveShareManager.buildSSHTunnelArguments(port: 54321, knownHostsURL: dummyHostsURL)
        expect(!args.contains("-N"), "SSH arguments must NOT include -N; -N prevents remote banner output containing tunnel URL")
        expect(args.contains("-T"), "SSH arguments must include -T to disable pseudo-terminal allocation")
        expect(args.contains("CheckHostIP=no"), "SSH arguments must include CheckHostIP=no for dynamic cloud IPs")
        expect(args.contains("StrictHostKeyChecking=yes"), "SSH arguments must enforce StrictHostKeyChecking=yes")
        expect(
            args.contains("UserKnownHostsFile=\"/tmp/Application Support/CallCaption/ssh_known_hosts\""),
            "SSH UserKnownHostsFile option must quote paths containing spaces so OpenSSH reads Application Support paths properly"
        )
        expect(args.contains("80:127.0.0.1:54321"), "SSH arguments must specify reverse port forwarding for bound port")

        let regex = LiveShareManager.sshTunnelRegex
        let validOutputs = [
            "https://499635bbf3da46.lhr.life",
            "https://7087b485ca79bc.app.lhr.life",
            "https://my-session.lhr.rocks",
            "https://eu.sub.lhr.rocks",
            "https://demo.localhost.run",
            "https://sub.demo.localhost.run",
            "Welcome! Your URL is https://sub-domain.lhr.life enjoy!",
            "Your URL is https://7087b485ca79bc.app.lhr.life."
        ]
        for out in validOutputs {
            let nsRange = NSRange(out.startIndex..<out.endIndex, in: out)
            let match = regex.firstMatch(in: out, options: [], range: nsRange)
            expect(match != nil, "Regex must match valid tunnel URL in: \(out)")
            expect(LiveShareManager.extractTunnelURL(from: out) != nil, "extractTunnelURL must parse: \(out)")
        }

        let invalidOutputs = [
            "http://499635bbf3da46.lhr.life",
            "http://7087b485ca79bc.app.lhr.life",
            "https://malicious.org/fake.lhr.life",
            "https://fake.lhr.life.evil.com",
            "https://fake.lhr.life-evil.com",
            "https://localhost.run/docs/custom-domains",
            "https://lhr.life",
            "ssh://localhost.run",
            "https://admin.localhost.run",
            "https://admin.app.lhr.life",
            "https://www.localhost.run",
            "https://docs.localhost.run",
            "https://api.lhr.life"
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
        expectEqual(
            LiveShareManager.extractTunnelURL(from: realLocalhostRunBanner)?.absoluteString,
            "https://1526889fde5451.lhr.life",
            "Banner extractor must recover single-label lhr.life tunnel URL, not admin.localhost.run"
        )

        let qrNoise = String(repeating: "\u{1b}[7m  \u{1b}[0m", count: 2000) // ~22 KB ANSI QR code burst
        let multiLabelLocalhostRunBanner = """
        Welcome to localhost.run!
        https://admin.localhost.run/
        https://localhost.run/docs/forever-free/
        7087b485ca79bc.app.lhr.life tunneled with tls termination, https://7087b485ca79bc.app.lhr.life
        Open your tunnel address on your mobile with this QR:
        \(qrNoise)
        For a long-lived, stable domain, get a custom domain plan at [https://admin.localhost.run/].
        """
        expectEqual(
            LiveShareManager.extractTunnelURL(from: multiLabelLocalhostRunBanner)?.absoluteString,
            "https://7087b485ca79bc.app.lhr.life",
            "Banner extractor must recover multi-label *.app.lhr.life tunnel URL even alongside large QR output"
        )

        let rotatedBanner = multiLabelLocalhostRunBanner + "\nrotated.app.lhr.life tunneled with tls termination, https://99aabbcc112233.app.lhr.life\n"
        expectEqual(
            LiveShareManager.extractTunnelURL(from: rotatedBanner)?.absoluteString,
            "https://99aabbcc112233.app.lhr.life",
            "Banner extractor must prefer the most recently emitted rotated tunnel URL"
        )
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
        let mutex = AsyncMutex()
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
        let isLocked = await mutex.isLocked
        let waiterCount = await mutex.waiterCount

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
        let savedOnboarding = AppSettings.shared.hasCompletedOnboarding
        let savedMicEnabled = AppSettings.shared.isMicEnabled
        AppSettings.shared.hasCompletedOnboarding = true
        AppSettings.shared.isMicEnabled = false
        defer {
            coordinator.stop()
            coordinator.delegate = nil
            AppSettings.shared.isMicEnabled = savedMicEnabled
            AppSettings.shared.hasCompletedOnboarding = savedOnboarding
        }
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
        let settings = AppSettings.shared
        let savedTunnel = settings.liveShareUseExternalTunnel
        let savedLAN = settings.allowLANShare
        settings.liveShareUseExternalTunnel = false
        settings.allowLANShare = false

        let manager = LiveShareManager.shared
        manager.stopSharingSynchronously()
        manager.clearHistoryForPrivacy()
        manager.startSharing()
        for _ in 0..<40 {
            if manager.isSharing && manager.localShareURL != nil { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }

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

        manager.stopSharingSynchronously()
        manager.clearHistoryForPrivacy()
        settings.allowLANShare = savedLAN
        settings.liveShareUseExternalTunnel = savedTunnel
        expect(!manager.isSharing, "LiveShareManager survived high throughput active-server concurrent broadcast stress cleanly")
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

    static func testAudioCheckerAndAutomaticGainCalibration() {
        let settings = AppSettings.shared
        settings.resetAudioCalibration()
        expectEqual(settings.callerInputGain, 1.0, "Default callerInputGain must be 1.0")
        expectEqual(settings.micInputGain, 1.0, "Default micInputGain must be 1.0")
        expect(settings.isAutoGainEnabled, "Default isAutoGainEnabled must be true")

        settings.callerInputGain = 50.0
        expectEqual(settings.callerInputGain, AppSettings.maxInputGain, "callerInputGain must clamp to maxInputGain (8.0)")
        settings.micInputGain = 0.01
        expectEqual(settings.micInputGain, AppSettings.minInputGain, "micInputGain must clamp to minInputGain (0.25)")
        settings.isAutoGainEnabled = false
        expect(!settings.isAutoGainEnabled, "isAutoGainEnabled must persist false")

        settings.resetAudioCalibration()
        expectEqual(settings.callerInputGain, 1.0, "resetAudioCalibration must restore callerInputGain to 1.0")
        expectEqual(settings.micInputGain, 1.0, "resetAudioCalibration must restore micInputGain to 1.0")
        expect(settings.isAutoGainEnabled, "resetAudioCalibration must restore isAutoGainEnabled to true")

        // Pre-gain and clipping protection
        if let pcm = AVAudioPCMBuffer(pcmFormat: AudioCaptureEngine.speechFormat, frameCapacity: 64),
           let ptr = pcm.floatChannelData?[0] {
            pcm.frameLength = 64
            for i in 0..<64 {
                ptr[i] = (i % 2 == 0) ? 0.30 : -0.30
            }
            let (boostedRMS, boostedPeak) = AudioCaptureEngine.applyGainInPlace(pcm, gain: 2.0)
            expect(abs(boostedRMS - 0.60) < 0.01, "applyGainInPlace(2.0x) on 0.30 square wave must yield ~0.60 RMS (got \(boostedRMS))")
            expect(abs(boostedPeak - 0.60) < 0.01, "applyGainInPlace(2.0x) on 0.30 square wave must yield ~0.60 peak (got \(boostedPeak))")

            let (_, clippedPeak) = AudioCaptureEngine.applyGainInPlace(pcm, gain: 4.0, clipLimit: 0.96)
            expect(abs(clippedPeak - 0.96) < 0.005, "applyGainInPlace must hard-limit peaks at clipLimit 0.96 (got \(clippedPeak))")
        }

        // Noise floor tracking and adaptive speech threshold
        var floor: Float = 0.0005
        for _ in 0..<40 {
            floor = AudioCaptureEngine.updateNoiseFloorEstimate(currentFloor: floor, sampleRMS: 0.0020, isVoiceDetected: false)
        }
        expect(floor > 0.0010 && floor <= 0.0021, "Noise floor must adapt upward during sustained unvoiced background hum (got \(floor))")

        let floorBeforeSpeech = floor
        for _ in 0..<20 {
            floor = AudioCaptureEngine.updateNoiseFloorEstimate(currentFloor: floor, sampleRMS: 0.060, isVoiceDetected: true)
        }
        expectEqual(floor, floorBeforeSpeech, "Voiced speech frames must not inflate the ambient noise floor estimate")

        for _ in 0..<25 {
            floor = AudioCaptureEngine.updateNoiseFloorEstimate(currentFloor: floor, sampleRMS: 0.0002, isVoiceDetected: false)
        }
        expect(floor < 0.0005, "Noise floor must decay quickly when quiet returns (got \(floor))")

        let quietAdaptive = AudioCaptureEngine.adaptiveSpeechThreshold(baseThreshold: 0.0014, noiseFloorRMS: 0.0002)
        expectEqual(quietAdaptive, 0.0014, "Quiet noise floor must preserve base threshold")

        let noisyAdaptive = AudioCaptureEngine.adaptiveSpeechThreshold(baseThreshold: 0.0014, noiseFloorRMS: 0.0015)
        expect(noisyAdaptive >= 0.0044 && noisyAdaptive <= 0.0046, "Elevated noise floor must raise adaptive threshold to 3x floor (got \(noisyAdaptive))")

        let extremeNoisyAdaptive = AudioCaptureEngine.adaptiveSpeechThreshold(baseThreshold: 0.0014, noiseFloorRMS: 0.020)
        expect(abs(extremeNoisyAdaptive - (0.0014 * 4.5)) < 0.0001, "Adaptive threshold must cap at 4.5x baseThreshold so speech remains reachable")

        // Automatic gain calibration math
        let quietGain = AudioCaptureEngine.computeCalibratedInputGain(
            currentGain: 1.0,
            estimatedSpeechRMS: 0.015,
            noiseFloorRMS: 0.0003,
            peakLevel: 0.12
        )
        expect(quietGain > 1.5, "Quiet speech (0.015 RMS) must automatically calibrate input gain upward (got \(quietGain))")

        let clippingGain = AudioCaptureEngine.computeCalibratedInputGain(
            currentGain: 2.0,
            estimatedSpeechRMS: 0.080,
            noiseFloorRMS: 0.0004,
            peakLevel: 0.95
        )
        expect(clippingGain < 1.70, "Clipping peaks (> 0.92) must step input gain down immediately (got \(clippingGain))")

        let noisyGain = AudioCaptureEngine.computeCalibratedInputGain(
            currentGain: 1.0,
            estimatedSpeechRMS: 0.008,
            noiseFloorRMS: 0.0030,
            peakLevel: 0.10,
            baseThreshold: 0.0026
        )
        expect(noisyGain < 2.2, "High noise floor must cap auto-gain boost so ambient noise is not amplified into false triggers (got \(noisyGain))")

        // Signal status classification
        expectEqual(
            AudioCaptureEngine.classifySignalStatus(
                isRunning: false,
                hasPermission: true,
                rawRMS: 0.0,
                calibratedRMS: 0.0,
                peakLevel: 0.0,
                noiseFloorRMS: 0.0003,
                estimatedSpeechRMS: 0.0,
                baseThreshold: 0.0014
            ),
            .inactive,
            "Stopped channel must classify as .inactive"
        )
        expectEqual(
            AudioCaptureEngine.classifySignalStatus(
                isRunning: true,
                hasPermission: false,
                rawRMS: 0.0,
                calibratedRMS: 0.0,
                peakLevel: 0.0,
                noiseFloorRMS: 0.0003,
                estimatedSpeechRMS: 0.0,
                baseThreshold: 0.0014
            ),
            .permissionDenied,
            "Unpermitted channel must classify as .permissionDenied"
        )
        expectEqual(
            AudioCaptureEngine.classifySignalStatus(
                isRunning: true,
                hasPermission: true,
                rawRMS: 0.035,
                calibratedRMS: 0.045,
                peakLevel: 0.32,
                noiseFloorRMS: 0.0004,
                estimatedSpeechRMS: 0.045,
                baseThreshold: 0.0014
            ),
            .optimal,
            "Healthy speech level must classify as .optimal"
        )
        expectEqual(
            AudioCaptureEngine.classifySignalStatus(
                isRunning: true,
                hasPermission: true,
                rawRMS: 0.002,
                calibratedRMS: 0.003,
                peakLevel: 0.02,
                noiseFloorRMS: 0.0003,
                estimatedSpeechRMS: 0.003,
                baseThreshold: 0.0014
            ),
            .tooQuiet,
            "Weak voiced signal (< 0.010) must classify as .tooQuiet"
        )
        expectEqual(
            AudioCaptureEngine.classifySignalStatus(
                isRunning: true,
                hasPermission: true,
                rawRMS: 0.25,
                calibratedRMS: 0.30,
                peakLevel: 0.92,
                noiseFloorRMS: 0.0004,
                estimatedSpeechRMS: 0.25,
                baseThreshold: 0.0014
            ),
            .tooLoud,
            "Hot clipping signal must classify as .tooLoud"
        )

        let engine = CaptionCoordinator.shared.audioCaptureEngine
        engine.resetCalibrationState()
        let snap = engine.diagnosticsSnapshot()
        expectEqual(snap.caller.inputGain, 1.0, "Engine diagnosticsSnapshot must report current caller input gain")
        expectEqual(snap.mic.inputGain, 1.0, "Engine diagnosticsSnapshot must report current mic input gain")
        engine.resetCalibrationState()

        let settingsWC = SettingsWindowController()
        settingsWC.selectTab(3)
        settingsWC.refreshAudioDiagnostics()
        settingsWC.updateAudioLevels(callerLevel: 0.42, micLevel: 0.58)
    }

    static func testSpeechAssetDownloaderAndDictationModelCaching() {
        let downloader = SpeechAssetDownloader.shared
        downloader._resetStateForTesting()

        expect(!downloader.isDownloading(forCode: "de"), "Should not be downloading initially")
        expectEqual(downloader.progressPercent(forCode: "de"), 0, "Initial progress percent should be 0")

        downloader._setStatusForTesting(.downloading(progress: 0.47), forCode: "de")
        expectEqual(downloader.status(forCode: "de"), .downloading(progress: 0.47), "Status should report .downloading(0.47)")
        expect(downloader.isDownloading(forCode: "de"), "isDownloading should be true when status is .downloading")
        expectEqual(downloader.progressPercent(forCode: "de"), 47, "progressPercent should round 0.47 to 47")

        downloader._setStatusForTesting(.installed, forCode: "de")
        expect(!downloader.isDownloading(forCode: "de"), "isDownloading should be false when status is .installed")
        expectEqual(downloader.progressPercent(forCode: "de"), 100, "progressPercent should be 100 when installed")

        downloader._setStatusForTesting(.failed(message: "Network unavailable"), forCode: "xh")
        expectEqual(downloader.status(forCode: "xh"), .failed(message: "Network unavailable"), "Failed status should preserve reason")
        expectEqual(downloader.progressPercent(forCode: "xh"), 0, "progressPercent should be 0 when failed")

        SupportedLanguages.invalidateCache(forCode: "de")
        let locale = SupportedLanguages.bestLocale(forCode: "de")
        expect(locale.identifier.lowercased().hasPrefix("de"), "bestLocale(forCode: 'de') must resolve a German locale")

        let trayVC = TrayCaptionViewController()
        _ = trayVC.view
        downloader._setStatusForTesting(.downloading(progress: 0.35), forCode: "fr")
        trayVC.showAlertBanner(
            message: "Downloading French dictation model… 35%",
            actionType: .dictationDownload("fr")
        )
        downloader._setStatusForTesting(.failed(message: "Retry needed"), forCode: "fr")
        trayVC.showAlertBanner(
            message: "Dictation model for French not ready",
            actionType: .dictationDownload("fr")
        )
        trayVC.clearAlertBanner()

        // Regional variants (e.g. Spanish Spain vs Colombia vs Mexico)
        let esVariants = SupportedLanguages.variants(forCode: "es")
        expect(esVariants.count >= 5, "Spanish should have multiple regional variants")
        expect(esVariants.contains(where: { $0.localeId == "es-ES" && $0.regionName == "Spain" }), "Spanish variants must include Spain (es-ES)")
        expect(esVariants.contains(where: { $0.localeId == "es-CO" && $0.regionName == "Colombia" }), "Spanish variants must include Colombia (es-CO)")
        expect(esVariants.contains(where: { $0.localeId == "es-MX" && $0.regionName == "Mexico" }), "Spanish variants must include Mexico (es-MX)")

        AppSettings.shared.setPreferredSpeechLocale("es-CO", forCode: "es")
        expectEqual(AppSettings.shared.preferredSpeechLocale(forCode: "es"), "es-CO", "Preferred speech locale for Spanish should be es-CO")
        expectEqual(SupportedLanguages.bestLocale(forCode: "es").identifier.replacingOccurrences(of: "_", with: "-"), "es-CO", "bestLocale(forCode: 'es') should honor preferred regional variant es-CO")
        expectEqual(SupportedLanguages.activeVariant(forCode: "es")?.regionName, "Colombia", "activeVariant(forCode: 'es') should report Colombia")

        // Delete downloaded dictation model
        downloader.deleteDownloadedAsset(forCode: "es", localeId: "es-CO")
        expect(downloader.isLocaleMarkedDeleted("es-CO"), "es-CO should be marked deleted after deleteDownloadedAsset")
        expect(!SupportedLanguages.isLocaleDownloaded("es-CO"), "isLocaleDownloaded('es-CO') should be false after deletion")
        downloader.deleteDownloadedAsset(forCode: "es")
        expectEqual(downloader.status(forCode: "es"), .notInstalled, "Status for 'es' should be .notInstalled after deleting all 'es' assets")

        // Re-downloading clears the deleted mark
        downloader.ensureDownloaded(forCode: "es", preferredLocaleId: "es-ES", force: true)
        expect(!downloader.isLocaleMarkedDeleted("es-ES"), "ensureDownloaded should clear deleted mark for es-ES")
        expectEqual(AppSettings.shared.preferredSpeechLocale(forCode: "es"), "es-ES", "ensureDownloaded(preferredLocaleId:) should update preferred locale to es-ES")

        AppSettings.shared.setPreferredSpeechLocale(nil, forCode: "es")
        downloader._resetStateForTesting()
    }

    private static func findSubviews<T: NSView>(ofType _: T.Type, in root: NSView) -> [T] {
        var result: [T] = []
        if let match = root as? T {
            result.append(match)
        }
        for sub in root.subviews {
            result.append(contentsOf: findSubviews(ofType: T.self, in: sub))
        }
        return result
    }

    static func testTranslationEngineRealHooksAndEviction() async {
        let engine = TranslationEngine.shared
        await engine.resetForTesting()

        // 1. Timeout cancellation must fail cleanly without deadlocking AsyncMutex
        let slowStarted = OSAllocatedUnfairLock(initialState: false)
        await engine.setTranslationTimeoutForTesting(0.05)
        await engine.setTranslatorForTesting { text, _, _, _ in
            if text == "SLOW_TIMEOUT_TRIGGER" {
                slowStarted.withLock { $0 = true }
                try await Task.sleep(nanoseconds: 500_000_000)
                return "should never return"
            }
            return "MOCK_\(text)"
        }

        let timedOut = await engine.translate(
            text: "SLOW_TIMEOUT_TRIGGER",
            sourceCode: "es",
            targetCode: "en",
            isFinal: true
        )
        expect(slowStarted.withLock { $0 }, "Mock translator must be invoked for slow translation")
        expect(timedOut == nil, "Timed-out translation must return nil cleanly")
        let esCooldownArmed = await engine.isInFailureCooldownForTesting(sourceCode: "es", targetCode: "en")
        expect(
            esCooldownArmed,
            "Timed-out translation must arm failure cooldown for the language pair"
        )

        await engine.resetFailureCooldowns()
        let recoveredAfterTimeout = await engine.translate(
            text: "NEXT_AFTER_TIMEOUT",
            sourceCode: "es",
            targetCode: "en",
            isFinal: true
        )
        expectEqual(
            recoveredAfterTimeout,
            "MOCK_NEXT_AFTER_TIMEOUT",
            "AsyncMutex must remain unlocked after timeout so subsequent translations succeed"
        )

        // 2. Failure cooldown must be enforced even under CALLCAPTION_TEST=1
        let cooldownInvocations = OSAllocatedUnfairLock(initialState: 0)
        await engine.setTranslatorForTesting { text, _, _, _ in
            cooldownInvocations.withLock { $0 += 1 }
            return "MOCK_\(text)"
        }
        await engine.setFailureCooldownForTesting(sourceCode: "fr", targetCode: "en")
        let frCooldownActive = await engine.isInFailureCooldownForTesting(sourceCode: "fr", targetCode: "en")
        expect(
            frCooldownActive,
            "setFailureCooldownForTesting must activate cooldown for fr->en"
        )
        let blockedDuringCooldown = await engine.translate(
            text: "Bonjour",
            sourceCode: "fr",
            targetCode: "en",
            isFinal: true
        )
        expect(blockedDuringCooldown == nil, "Translation during active cooldown must return nil even in test environment")
        expectEqual(
            cooldownInvocations.withLock { $0 },
            0,
            "Translator handler must not run while pair is in cooldown"
        )

        let expiredUptime = max(0, ProcessInfo.processInfo.systemUptime - 10.0)
        await engine.setFailureCooldownForTesting(sourceCode: "fr", targetCode: "en", systemUptime: expiredUptime)
        let frCooldownStillActive = await engine.isInFailureCooldownForTesting(sourceCode: "fr", targetCode: "en")
        expect(
            !frCooldownStillActive,
            "Expired cooldown (> 5s old) must clear cleanly"
        )
        let afterExpiry = await engine.translate(
            text: "Bonjour",
            sourceCode: "fr",
            targetCode: "en",
            isFinal: true
        )
        expectEqual(afterExpiry, "MOCK_Bonjour", "Translation must succeed once cooldown expires")
        expectEqual(cooldownInvocations.withLock { $0 }, 1, "Translator should execute once after cooldown expires")

        // 3. In-flight partial superseding leaves zero leaked tasks
        await engine.setTranslationTimeoutForTesting(0.5)
        await engine.setTranslatorForTesting { text, _, _, _ in
            try await Task.sleep(nanoseconds: 25_000_000)
            return "OUT_\(text)"
        }
        let partial1 = Task { await engine.translate(text: "uno", sourceCode: "de", targetCode: "en", isFinal: false) }
        let partial2 = Task { await engine.translate(text: "dos", sourceCode: "de", targetCode: "en", isFinal: false) }
        _ = await (partial1.value, partial2.value)
        let counts = await engine.inFlightTaskCountsForTesting()
        expectEqual(counts.partials, 0, "All partial tasks must drain after completion")
        expectEqual(counts.finals, 0, "All final tasks must drain after completion")
        expectEqual(counts.preparing, 0, "No preparing tasks should linger under mock translator")

        await engine.resetForTesting()
    }

    static func testLiveShareHTTPAndSSELifecycle() async {
        // 1. LiveShareCrypto AAD, tamper detection, and strict JSON type validation
        let crypto = LiveShareCrypto()
        guard let sealedState = try? crypto.seal(Data("{\"ok\":true}".utf8), type: "state", sequence: 7) else {
            expect(false, "Authenticated AES-GCM seal with type/sequence must succeed")
            return
        }
        expectEqual(
            try? crypto.open(sealedState, expectedType: "state"),
            Data("{\"ok\":true}".utf8),
            "Authenticated AES-GCM open must recover payload when expectedType matches"
        )
        expect(
            (try? crypto.open(sealedState, expectedType: "caption")) == nil,
            "Mismatched expectedType must fail closed"
        )

        if var obj = (try? JSONSerialization.jsonObject(with: sealedState)) as? [String: Any],
           let encoded = obj["d"] as? String,
           var cipherData = LiveShareCrypto.base64URLDecode(encoded) {
            cipherData[cipherData.count - 1] ^= 0xFF
            obj["d"] = LiveShareCrypto.base64URLEncode(cipherData)
            if let tampered = try? JSONSerialization.data(withJSONObject: obj) {
                expect((try? crypto.open(tampered, expectedType: "state")) == nil, "Tampered GCM tag must fail open")
            }
        } else {
            expect(false, "Failed to prepare tampered GCM envelope")
        }

        if let rawObj = (try? JSONSerialization.jsonObject(with: sealedState)) as? [String: Any] {
            var boolVerObj = rawObj
            boolVerObj["v"] = true
            if let data = try? JSONSerialization.data(withJSONObject: boolVerObj) {
                expect((try? crypto.open(data, expectedType: "state")) == nil, "Boolean 'v': true must fail closed")
            }

            var wrongVerObj = rawObj
            wrongVerObj["v"] = 2
            if let data = try? JSONSerialization.data(withJSONObject: wrongVerObj) {
                expect((try? crypto.open(data, expectedType: "state")) == nil, "Unsupported 'v': 2 must fail closed")
            }

            var boolSeqObj = rawObj
            boolSeqObj["s"] = true
            if let data = try? JSONSerialization.data(withJSONObject: boolSeqObj) {
                expect((try? crypto.open(data, expectedType: "state")) == nil, "Boolean 's': true must fail closed")
            }

            var missingSeqObj = rawObj
            missingSeqObj.removeValue(forKey: "s")
            if let data = try? JSONSerialization.data(withJSONObject: missingSeqObj) {
                expect((try? crypto.open(data, expectedType: "state")) == nil, "Missing sequence 's' when 't' is present must fail closed")
            }
        }

        if let seqZero = try? crypto.seal(Data("seq0".utf8), type: "caption", sequence: 0) {
            expectEqual(
                try? crypto.open(seqZero, expectedType: "caption"),
                Data("seq0".utf8),
                "Numeric sequence 0 must be accepted and not misclassified as boolean"
            )
        } else {
            expect(false, "Seal with sequence 0 should succeed")
        }

        // 2. Real LiveShareManager loopback server + HTTP routes + 20 SSE cap without starving /api/state
        let settings = AppSettings.shared
        let savedAllowLAN = settings.allowLANShare
        let savedTunnel = settings.liveShareUseExternalTunnel
        settings.allowLANShare = false
        settings.liveShareUseExternalTunnel = false

        let manager = LiveShareManager.shared
        manager.stopSharingSynchronously()
        manager.clearHistoryForPrivacy()

        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpMaximumConnectionsPerHost = 32
        cfg.timeoutIntervalForRequest = 4.0
        cfg.timeoutIntervalForResource = 10.0
        let session = URLSession(configuration: cfg)
        var sseSocketFDs: [Int32] = []

        func cleanupLiveShare() {
            for fd in sseSocketFDs {
                Darwin.close(fd)
            }
            sseSocketFDs.removeAll()
            session.invalidateAndCancel()
            manager.stopSharingSynchronously()
            manager.clearHistoryForPrivacy()
            settings.allowLANShare = savedAllowLAN
            settings.liveShareUseExternalTunnel = savedTunnel
        }

        manager.startSharing()
        var shareURL: URL? = nil
        for _ in 0..<60 {
            if let candidate = manager.localShareURL, manager.isSharing {
                shareURL = candidate
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        guard let localURL = shareURL,
              let host = localURL.host,
              let port = localURL.port,
              let fragment = localURL.fragment,
              let sessionCrypto = LiveShareCrypto(keyFragment: fragment) else {
            expect(false, "LiveShareManager must start loopback listener and expose localURL with key fragment")
            cleanupLiveShare()
            return
        }

        let pathParts = localURL.path.split(separator: "/")
        let token = pathParts.last.map(String.init) ?? ""
        expect(!token.isEmpty, "Share URL must contain non-empty session token")

        manager.broadcastCaption(
            speaker: "Caller",
            original: "Prueba loopback",
            translated: "Loopback test passed",
            sourceLangCode: "es",
            targetLangCode: "en",
            isFinal: true,
            isUntranslated: false,
            utteranceID: UUID()
        )

        let htmlURL = URL(string: "http://\(host):\(port)/s/\(token)")!
        let stateURL = URL(string: "http://\(host):\(port)/s/\(token)/api/state")!
        let badURL = URL(string: "http://\(host):\(port)/s/invalid_token_0000")!

        do {
            let (htmlData, htmlResp) = try await session.data(from: htmlURL)
            let statusCode = (htmlResp as? HTTPURLResponse)?.statusCode ?? 0
            expectEqual(statusCode, 200, "GET /s/<token> must return 200 OK")
            let htmlText = String(data: htmlData, encoding: .utf8) ?? ""
            expect(
                htmlText.contains("<html") && htmlText.contains("/s/\(token)") && htmlText.contains("'/events'"),
                "Viewer HTML must reference session SSE path"
            )

            let (stateData, stateResp) = try await session.data(from: stateURL)
            expectEqual((stateResp as? HTTPURLResponse)?.statusCode ?? 0, 200, "GET /api/state must return 200 OK")
            let decrypted = try sessionCrypto.open(stateData, expectedType: "state")
            let decryptedJSON = String(data: decrypted, encoding: .utf8) ?? ""
            expect(decryptedJSON.contains("Loopback test passed"), "Decrypted /api/state payload must include broadcast caption")

            let (_, badResp) = try await session.data(from: badURL)
            expectEqual((badResp as? HTTPURLResponse)?.statusCode ?? 0, 404, "Wrong token path must return 404 Not Found")
        } catch {
            expect(false, "Loopback HTTP check failed: \(error)")
        }

        // Open 20 active SSE connections (maxSSEClients = 20) and verify 21st gets 503 while /api/state still returns 200
        @Sendable func openLoopbackHTTP(path: String, keepOpen: Bool) -> (fd: Int32, status: Int)? {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }

            let timeout = timeval(tv_sec: 3, tv_usec: 0)
            withUnsafePointer(to: timeout) { ptr in
                _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
                _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
            }

            var mutableAddr = sockaddr_in()
            mutableAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            mutableAddr.sin_family = sa_family_t(AF_INET)
            mutableAddr.sin_port = UInt16(port).bigEndian
            mutableAddr.sin_addr = in_addr(s_addr: UInt32(0x7f000001).bigEndian)
            let resolvedAddr = mutableAddr

            let connResult = withUnsafePointer(to: resolvedAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    Darwin.connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connResult == 0 else {
                Darwin.close(fd)
                return nil
            }

            let connHeader = keepOpen ? "keep-alive" : "close"
            let request = "GET \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: \(connHeader)\r\n\r\n"
            let sentAll: Bool = request.withCString { cStr in
                let total = strlen(cStr)
                var offset = 0
                while offset < total {
                    let n = Darwin.send(fd, cStr.advanced(by: offset), total - offset, 0)
                    if n <= 0 { return false }
                    offset += n
                }
                return true
            }
            guard sentAll else {
                Darwin.close(fd)
                return nil
            }

            var buffer = [UInt8](repeating: 0, count: 1024)
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuf in
                Darwin.recv(fd, rawBuf.baseAddress, rawBuf.count, 0)
            }
            guard bytesRead > 0 else {
                Darwin.close(fd)
                return nil
            }
            let headerPrefix = String(decoding: buffer.prefix(bytesRead), as: UTF8.self)
            guard let firstLine = headerPrefix.components(separatedBy: "\r\n").first else {
                Darwin.close(fd)
                return nil
            }
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2, let code = Int(parts[1]) else {
                Darwin.close(fd)
                return nil
            }
            if !keepOpen {
                Darwin.close(fd)
                return (fd: -1, status: code)
            }
            return (fd: fd, status: code)
        }

        for _ in 0..<20 {
            if let opened = await Task.detached(operation: { openLoopbackHTTP(path: "/s/\(token)/events", keepOpen: true) }).value {
                if opened.fd >= 0 {
                    sseSocketFDs.append(opened.fd)
                }
                expectEqual(opened.status, 200, "Each of the first 20 SSE connections must receive 200 OK")
            } else {
                expect(false, "Failed to open loopback SSE socket")
            }
        }

        for _ in 0..<40 {
            if manager.activeClientCount == 20 { break }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        expectEqual(manager.activeClientCount, 20, "All 20 allowed SSE clients should be registered concurrently")

        let extraSSEStatus = await Task.detached { openLoopbackHTTP(path: "/s/\(token)/events", keepOpen: false)?.status }.value
        expectEqual(extraSSEStatus ?? 0, 503, "21st SSE client must receive 503 Service Unavailable")

        let stateWhileFullStatus = await Task.detached { openLoopbackHTTP(path: "/s/\(token)/api/state", keepOpen: false)?.status }.value
        expectEqual(stateWhileFullStatus ?? 0, 200, "/api/state must remain responsive when SSE cap is full")

        let htmlWhileFullStatus = await Task.detached { openLoopbackHTTP(path: "/s/\(token)", keepOpen: false)?.status }.value
        expectEqual(htmlWhileFullStatus ?? 0, 200, "/s/<token> must remain responsive when SSE cap is full")

        cleanupLiveShare()
        expect(!manager.isSharing, "LiveShareManager must report isSharing == false after stopSharingSynchronously")
    }

    static func testAudioCaptureSafetyAndDiagnostics() {
        let engine = CaptionCoordinator.shared.audioCaptureEngine

        // 1. Packed 24-bit non-interleaved bounds safety (undersized buffer must return false, valid succeeds)
        var asbd24 = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 3,
            mFramesPerPacket: 1,
            mBytesPerFrame: 3,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 24,
            mReserved: 0
        )
        if let fmt24 = AVAudioFormat(streamDescription: &asbd24),
           let mono48Fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false),
           let buf24 = AVAudioPCMBuffer(pcmFormat: fmt24, frameCapacity: 32),
           let dstMono = AVAudioPCMBuffer(pcmFormat: mono48Fmt, frameCapacity: 32) {
            buf24.frameLength = 32
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buf24.audioBufferList))
            if abl.count == 2, let m0 = abl[0].mData, let m1 = abl[1].mData {
                let p0 = m0.assumingMemoryBound(to: UInt8.self)
                let p1 = m1.assumingMemoryBound(to: UInt8.self)
                for i in 0..<32 {
                    p0[i * 3 + 0] = 0x00
                    p0[i * 3 + 1] = 0x00
                    p0[i * 3 + 2] = 0x40 // ~+0.5
                    p1[i * 3 + 0] = 0x00
                    p1[i * 3 + 1] = 0x00
                    p1[i * 3 + 2] = 0x40
                }
                let savedByteSize = abl[1].mDataByteSize
                abl[1].mDataByteSize = UInt32(32 * 3 - 1)
                let rejectedUndersized = engine.convertAndCopyToMono(source: buf24, destination: dstMono)
                expect(!rejectedUndersized, "Undersized 24-bit non-interleaved buffer must return false without over-reading")

                abl[1].mDataByteSize = savedByteSize
                let acceptedValid = engine.convertAndCopyToMono(source: buf24, destination: dstMono)
                expect(acceptedValid, "Valid 24-bit non-interleaved buffer must convert cleanly")
                if let outPtr = dstMono.floatChannelData?[0] {
                    expect(abs(outPtr[0] - 0.5) < 0.01, "Converted 24-bit sample must preserve normalized amplitude (got \(outPtr[0]))")
                }
            }
        } else {
            expect(false, "Failed to construct 24-bit non-interleaved AVAudioFormat for bounds test")
        }

        // 2. Interleaved >2-channel Int16 & Int32 active-channel RMS selection
        if let layout4 = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4),
           let mono48Fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false),
           let dstMono = AVAudioPCMBuffer(pcmFormat: mono48Fmt, frameCapacity: 64) {
            let fmt4Int16 = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, interleaved: true, channelLayout: layout4)
            let fmt4Int32 = AVAudioFormat(commonFormat: .pcmFormatInt32, sampleRate: 48000, interleaved: true, channelLayout: layout4)

            if let bufInt16 = AVAudioPCMBuffer(pcmFormat: fmt4Int16, frameCapacity: 64) {
                bufInt16.frameLength = 64
                if let mData = bufInt16.audioBufferList.pointee.mBuffers.mData {
                    let ptr = mData.assumingMemoryBound(to: Int16.self)
                    for i in 0..<64 {
                        ptr[i * 4 + 0] = 0
                        ptr[i * 4 + 1] = 0
                        ptr[i * 4 + 2] = 0
                        ptr[i * 4 + 3] = 16384 // active capsule on ch 3 (~0.5)
                    }
                }
                let ok16 = engine.convertAndCopyToMono(source: bufInt16, destination: dstMono)
                expect(ok16, "Interleaved 4-channel Int16 conversion must succeed")
                if let out0 = dstMono.floatChannelData?[0][0] {
                    expect(abs(out0 - 0.5) < 0.01, "Interleaved 4-channel Int16 must switch to loudest active channel 3 (got \(out0))")
                }
            }

            if let bufInt32 = AVAudioPCMBuffer(pcmFormat: fmt4Int32, frameCapacity: 64) {
                bufInt32.frameLength = 64
                if let mData = bufInt32.audioBufferList.pointee.mBuffers.mData {
                    let ptr = mData.assumingMemoryBound(to: Int32.self)
                    for i in 0..<64 {
                        ptr[i * 4 + 0] = 0
                        ptr[i * 4 + 1] = Int32(1_073_741_824) // switch active capsule to ch 1 (~0.5)
                        ptr[i * 4 + 2] = 0
                        ptr[i * 4 + 3] = 0
                    }
                }
                let ok32 = engine.convertAndCopyToMono(source: bufInt32, destination: dstMono)
                expect(ok32, "Interleaved 4-channel Int32 conversion must succeed")
                if let out0 = dstMono.floatChannelData?[0][0] {
                    expect(abs(out0 - 0.5) < 0.01, "Interleaved 4-channel Int32 must switch to loudest active channel 1 (got \(out0))")
                }
            }
        }

        // 3. AudioChannelDiagnostics gain-scaled snrDecibels invariance across manual inputGain
        let unityDiag = AudioChannelDiagnostics(
            isRunning: true,
            hasPermission: true,
            rawRMS: 0.02,
            calibratedRMS: 0.02,
            displayLevel: 0.4,
            peakLevel: 0.1,
            noiseFloorRMS: 0.001,
            estimatedSpeechRMS: 0.02,
            inputGain: 1.0,
            agcGain: 1.0,
            effectiveThreshold: 0.003,
            isVoiceDetected: true,
            status: .optimal
        )
        let boostedDiag = AudioChannelDiagnostics(
            isRunning: true,
            hasPermission: true,
            rawRMS: 0.02,
            calibratedRMS: 0.08,
            displayLevel: 0.7,
            peakLevel: 0.4,
            noiseFloorRMS: 0.001,
            estimatedSpeechRMS: 0.02,
            inputGain: 4.0,
            agcGain: 1.0,
            effectiveThreshold: 0.003,
            isVoiceDetected: true,
            status: .optimal
        )
        expect(
            abs(unityDiag.snrDecibels - boostedDiag.snrDecibels) < 0.05,
            "snrDecibels must scale noiseFloorRMS by inputGain so manual gain does not artificially inflate SNR (unity=\(unityDiag.snrDecibels), boosted=\(boostedDiag.snrDecibels))"
        )
    }

    static func testAppSettingsAndPathsSecurity() {
        let settings = AppSettings.shared
        let savedCallerGain = settings.callerInputGain
        let savedMicGain = settings.micInputGain
        let savedMain = settings.mainLanguageCode
        let savedForeign = settings.foreignLanguageCode
        let savedTarget = settings.targetLanguageCode
        let savedFollows = settings.subtitleFollowsMainLanguage
        defer {
            settings.callerInputGain = savedCallerGain
            settings.micInputGain = savedMicGain
            settings.foreignLanguageCode = savedForeign
            settings.mainLanguageCode = savedMain
            settings.targetLanguageCode = savedTarget
            settings.subtitleFollowsMainLanguage = savedFollows
        }

        // 1. Gain changes fire audioGainDidChangeNotification without triggering full AppSettings.didChangeNotification
        let generalCount = OSAllocatedUnfairLock(initialState: 0)
        let gainCount = OSAllocatedUnfairLock(initialState: 0)
        let nc = NotificationCenter.default
        let genObs = nc.addObserver(forName: AppSettings.didChangeNotification, object: nil, queue: nil) { _ in
            generalCount.withLock { $0 += 1 }
        }
        let gainObs = nc.addObserver(forName: AppSettings.audioGainDidChangeNotification, object: nil, queue: nil) { _ in
            gainCount.withLock { $0 += 1 }
        }
        defer {
            nc.removeObserver(genObs)
            nc.removeObserver(gainObs)
        }

        settings.callerInputGain = 2.75
        settings.micInputGain = 1.65
        expect(gainCount.withLock { $0 } >= 2, "Audio gain changes must post audioGainDidChangeNotification")
        expectEqual(generalCount.withLock { $0 }, 0, "Audio gain slider adjustments must NOT fire AppSettings.didChangeNotification")

        // 2. subtitleFollowsMain pre-registration / persistence check
        let suiteName = ProcessInfo.processInfo.environment["CALLCAPTION_TEST_SUITE"] ?? "com.callcaption.tests"
        settings.mainLanguageCode = "en"
        settings.targetLanguageCode = "fr"
        expect(!settings.subtitleFollowsMainLanguage, "Setting divergent targetLanguageCode must persist subtitleFollowsMainLanguage == false")
        if let suiteDefaults = UserDefaults(suiteName: suiteName) {
            settings.flushPersistence()
            expect(
                suiteDefaults.object(forKey: "cc_subtitle_follows_main") != nil,
                "cc_subtitle_follows_main default must be registered or stored in UserDefaults"
            )
            expectEqual(
                suiteDefaults.bool(forKey: "cc_subtitle_follows_main"),
                false,
                "cc_subtitle_follows_main must persist false after custom target choice"
            )
        }

        // 3. Atomic overwrite with AppPaths.writePrivateData preserves 0600 even over pre-existing permissive file
        guard let testRoot = AppPaths.testRoot else {
            expect(false, "CALLCAPTION_TEST_DIR must be set")
            return
        }
        let targetFile = testRoot.appendingPathComponent("atomic_overwrite_test.json")
        try? FileManager.default.removeItem(at: targetFile)
        try? Data("old-public-placeholder".utf8).write(to: targetFile)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: targetFile.path)

        do {
            let newPayload = Data("new-private-payload".utf8)
            try AppPaths.writePrivateData(newPayload, to: targetFile)
            expectEqual(try Data(contentsOf: targetFile), newPayload, "Atomic overwrite must replace file contents cleanly")
            if let attrs = try? FileManager.default.attributesOfItem(atPath: targetFile.path),
               let perm = attrs[.posixPermissions] as? NSNumber {
                expectEqual(perm.intValue & 0o777, 0o600, "Atomic overwrite must enforce 0600 permissions")
            } else {
                expect(false, "Could not inspect permissions after atomic overwrite")
            }
        } catch {
            expect(false, "writePrivateData overwrite failed: \(error)")
        }
        try? FileManager.default.removeItem(at: targetFile)
    }

    static func testLanguageModelsAndDownloaderEdgeCases() async {
        // 1. Complete RTL language coverage (ar, he, fa, ur) including regional tags
        for code in ["ar", "ar-SA", "he", "he-IL", "fa", "fa-IR", "ur", "ur-PK"] {
            expect(SupportedLanguages.isRTL(languageCode: code), "Language '\(code)' must be identified as RTL")
        }
        for code in ["en", "es", "fr-CA", "ja", "ko"] {
            expect(!SupportedLanguages.isRTL(languageCode: code), "Language '\(code)' must be identified as LTR")
        }

        let downloader = SpeechAssetDownloader.shared
        downloader._resetStateForTesting()

        // 2. Variant deletion scoping vs full language deletion
        downloader.deleteDownloadedAsset(forCode: "es", localeId: "es-CO")
        expect(downloader.isLocaleMarkedDeleted("es-CO"), "Exact variant deletion must mark es-CO deleted")
        expect(!downloader.isLocaleMarkedDeleted("es-ES"), "Variant deletion for es-CO must not mark sibling es-ES deleted")
        expect(!SupportedLanguages.isLocaleDownloaded("es-CO"), "Deleted es-CO variant must report isLocaleDownloaded == false")

        downloader.deleteDownloadedAsset(forCode: "es", localeId: nil)
        for variant in SupportedLanguages.variants(forCode: "es") {
            expect(downloader.isLocaleMarkedDeleted(variant.localeId), "Full language delete must mark variant \(variant.localeId) deleted")
        }

        // 3. Draining pending download completions cleanly on deletion
        let drainedResult = OSAllocatedUnfairLock(initialState: [Bool]())
        let deletedResult = OSAllocatedUnfairLock(initialState: [Bool]())
        downloader.ensureDownloaded(forCode: "it", preferredLocaleId: "it-IT", force: true) { ok in
            drainedResult.withLock { $0.append(ok) }
        }
        downloader.deleteDownloadedAsset(forCode: "it") { ok in
            deletedResult.withLock { $0.append(ok) }
        }
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 15_000_000)
            if !drainedResult.withLock({ $0.isEmpty }) && !deletedResult.withLock({ $0.isEmpty }) {
                break
            }
        }
        expectEqual(drainedResult.withLock { $0 }, [false], "Deleting while download is queued must drain pending completion with false")
        expectEqual(deletedResult.withLock { $0 }, [true], "deleteDownloadedAsset completion must report true")

        // 4. Stale/reset state leaves no active download
        downloader._resetStateForTesting()
        expect(!downloader.isDownloading(forCode: "it"), "Downloader must have no active download after _resetStateForTesting")
    }

    static func testUIControllersAndLocalizationRegressions() async {
        let savedAppLang = AppSettings.shared.appLanguageCode
        let savedAutosave = AppSettings.shared.autosaveTranscripts
        let savedOnboarding = AppSettings.shared.hasCompletedOnboarding
        let tm = TranscriptManager.shared
        tm.clear()
        AppSettings.shared.autosaveTranscripts = false
        defer {
            tm.clear()
            AppSettings.shared.autosaveTranscripts = savedAutosave
            AppSettings.shared.appLanguageCode = savedAppLang
            AppSettings.shared.hasCompletedOnboarding = savedOnboarding
            SpeechAssetDownloader.shared._resetStateForTesting()
        }

        // 1. TrayCaptionViewController: hidden-window deferral -> flush, incremental merge & 60->50 trim, empty placeholder, restored banner clear
        do {
            let vc = TrayCaptionViewController()
            _ = vc.view
            let textViews = findSubviews(ofType: NSTextView.self, in: vc.view)
            expectEqual(textViews.count, 1, "TrayCaptionViewController must host one NSTextView")
            let tv = textViews.first

            vc.updateCaption(
                utteranceID: UUID(),
                speaker: "Caller",
                translated: "Deferred line one",
                original: "Linea diferida",
                isFinal: true
            )
            expectEqual(tv?.textStorage?.length ?? -1, 0, "updateCaption while view.window == nil must defer NSTextStorage layout")

            vc.flushPendingRenderIfNeeded(force: true)
            let rendered = tv?.string ?? ""
            expect(rendered.contains("Deferred line one"), "flushPendingRenderIfNeeded(force: true) must render deferred caption")

            // Mount onto offscreen window (without ordering front / stealing focus) to exercise live incremental merge & 60->50 trim
            let hostWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            hostWindow.isReleasedWhenClosed = false
            hostWindow.contentView = vc.view
            vc.flushPendingRenderIfNeeded(force: true)

            vc.clearCaptionsUI()
            vc.updateCaption(utteranceID: UUID(), speaker: "Caller", translated: "Alpha", original: "Alfa", isFinal: true)
            vc.updateCaption(utteranceID: UUID(), speaker: "Caller", translated: "Beta", original: "Beta", isFinal: true)
            let mergedText = tv?.string ?? ""
            expect(mergedText.contains("Alpha Beta"), "Consecutive short finalized sentences from same speaker must merge incrementally")

            for idx in 0..<61 {
                let speaker = (idx % 2 == 0) ? "Caller" : "You"
                vc.updateCaption(
                    utteranceID: UUID(),
                    speaker: speaker,
                    translated: "Block_\(idx)",
                    original: "Orig_\(idx)",
                    isFinal: true
                )
            }
            let trimmedText = tv?.string ?? ""
            expect(!trimmedText.contains("Block_0 "), "Oldest block should be trimmed when finalized block count exceeds 60")
            expect(trimmedText.contains("Block_60"), "Latest block must remain rendered after 60->50 trim")

            // Empty placeholder refresh on appLanguageCode change
            vc.clearCaptionsUI()
            AppSettings.shared.appLanguageCode = "es"
            let labelsES = findSubviews(ofType: NSTextField.self, in: vc.view).map(\.stringValue).joined(separator: "\n")
            expect(labelsES.contains("Escuchando") || labelsES.contains("Listo") || labelsES.contains("Traducci"), "Placeholder must re-localize when app language switches to Spanish")
            AppSettings.shared.appLanguageCode = "en"

            // .clearRestoredTranscript banner action clears TranscriptManager & captions
            tm.addEntry(speaker: "Caller", original: "Old entry", translated: "Old entry")
            expectEqual(tm.entries.count, 1, "Precondition: TranscriptManager has 1 entry")
            vc.showAlertBanner(message: "Restored", actionType: .clearRestoredTranscript)
            let clearButtons = findSubviews(ofType: NSButton.self, in: vc.view).filter {
                $0.title == L10n.tr("header.clear", "Clear") && !$0.isHidden
            }
            if let clearBtn = clearButtons.first, let action = clearBtn.action {
                NSApp.sendAction(action, to: clearBtn.target, from: clearBtn)
            } else {
                expect(false, "Alert banner Clear button must exist for .clearRestoredTranscript")
            }
            expectEqual(tm.entries.count, 0, "Clicking Clear on restored transcript banner must clear TranscriptManager")
            expectEqual(tv?.string ?? "nonempty", "", "Clicking Clear on restored transcript banner must clear Tray UI")

            hostWindow.contentView = nil
            hostWindow.close()
        }

        // 2. TranscriptManager 2500-entry cap & TranscriptWindowController search + windowWillClose
        do {
            tm.clear()
            for i in 0..<2505 {
                tm.addEntry(speaker: i % 2 == 0 ? "Caller" : "You", original: "orig_\(i)", translated: "trans_\(i)")
            }
            expectEqual(tm.entries.count, 2500, "TranscriptManager must cap entries at 2500")
            expectEqual(tm.entries.first?.translated, "trans_5", "Oldest entries beyond 2500 must be evicted")
            expectEqual(tm.entries.last?.translated, "trans_2504", "Newest entry must be retained")

            let transcriptWC = TranscriptWindowController()
            if let root = transcriptWC.window?.contentView,
               let sf = findSubviews(ofType: NSSearchField.self, in: root).first,
               let tv = findSubviews(ofType: NSTextView.self, in: root).first {
                transcriptWC.window?.orderBack(nil)
                transcriptWC.showWindow(nil)
                sf.stringValue = "trans_2504"
                if let action = sf.action {
                    NSApp.sendAction(action, to: sf.target, from: sf)
                }
                expect(tv.string.contains("trans_2504"), "TranscriptWindowController search filter must show matching entry")
                expect(!tv.string.contains("trans_10\n"), "TranscriptWindowController search filter must hide non-matching entries")
                transcriptWC.window?.close()
                expectEqual(tv.textStorage?.length ?? -1, 0, "TranscriptWindowController windowWillClose must release textStorage contents")
            } else {
                expect(false, "TranscriptWindowController must expose search field and text view")
            }
            tm.clear()
        }

        // 3. SettingsWindowController timer leak-safety / tab switch / gain slider 8.0x / failed & unsupported dictation status
        do {
            let savedForeign = AppSettings.shared.foreignLanguageCode
            AppSettings.shared.foreignLanguageCode = "pl"
            SpeechAssetDownloader.shared.deleteDownloadedAsset(forCode: "pl")
            defer {
                SpeechAssetDownloader.shared._resetStateForTesting()
                AppSettings.shared.foreignLanguageCode = savedForeign
            }

            weak var weakSettings: SettingsWindowController?
            var settingsWC: SettingsWindowController?
            autoreleasepool {
                let wc = SettingsWindowController()
                weakSettings = wc
                settingsWC = wc
                wc.selectTab(3)
                if let root = wc.window?.contentView {
                    let sliders = findSubviews(ofType: NSSlider.self, in: root)
                    expect(sliders.contains(where: { abs($0.maxValue - Double(AppSettings.maxInputGain)) < 0.001 }), "Audio gain sliders must allow up to maxInputGain (8.0x)")
                }
                wc.window?.orderBack(nil)
                wc.showWindow(nil)
                wc.selectTab(3)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
            autoreleasepool {
                settingsWC?.selectTab(0)
                SpeechAssetDownloader.shared.setStatusForTesting(.failed(message: "Disk full"), forCode: "pl")
            }
            for _ in 0..<100 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                var found = false
                autoreleasepool {
                    if let root = settingsWC?.window?.contentView {
                        let texts = findSubviews(ofType: NSTextField.self, in: root).map(\.stringValue)
                        if texts.contains(where: { $0.contains("Disk full") }) { found = true }
                    }
                }
                if found { break }
            }
            autoreleasepool {
                if let root = settingsWC?.window?.contentView {
                    let texts = findSubviews(ofType: NSTextField.self, in: root).map(\.stringValue).joined(separator: "\n")
                    expect(texts.contains("Disk full"), "Settings dictation status must display failure reason for .failed status")
                }
                SpeechAssetDownloader.shared.setStatusForTesting(.unsupported, forCode: "pl")
            }
            let expectedUnsupported = L10n.tr("status.unsupported", "Unsupported")
            for _ in 0..<100 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                var found = false
                autoreleasepool {
                    if let root = settingsWC?.window?.contentView {
                        let badges = findSubviews(ofType: StatusBadgeView.self, in: root).map(\.title)
                        if badges.contains(expectedUnsupported) { found = true }
                    }
                }
                if found { break }
            }
            autoreleasepool {
                if let root = settingsWC?.window?.contentView {
                    let badges = findSubviews(ofType: StatusBadgeView.self, in: root).map(\.title)
                    expect(badges.contains(expectedUnsupported), "Settings dictation badge must display Unsupported for .unsupported status")
                }
                settingsWC?.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: settingsWC?.window))
                settingsWC?.window?.close()
                settingsWC = nil
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            expect(weakSettings == nil, "SettingsWindowController must deallocate cleanly after close without timer retain cycle")
        }

        // 4. OnboardingWindowController consent gating & live Spanish relocalization
        do {
            AppSettings.shared.hasCompletedOnboarding = false
            AppSettings.shared.appLanguageCode = "en"
            let onboardingWC = OnboardingWindowController()
            if let root = onboardingWC.window?.contentView {
                let consentTitle = L10n.tr("onboarding.consentCheckbox", "I understand and will comply with call recording/transcription consent laws")
                let startTitle = L10n.tr("onboarding.startListening", "Start Listening")
                let consentBtn = findSubviews(ofType: NSButton.self, in: root).first(where: { $0.title == consentTitle })
                let startBtn = findSubviews(ofType: NSButton.self, in: root).first(where: { $0.title == startTitle })
                expect(consentBtn != nil && startBtn != nil, "OnboardingWindowController must contain consent checkbox and Start Listening button")
                if let consentBtn, let startBtn {
                    expect(!startBtn.isEnabled, "Start Listening must initially be disabled without consent")
                    consentBtn.state = .on
                    if let act = consentBtn.action {
                        NSApp.sendAction(act, to: consentBtn.target, from: consentBtn)
                    }
                    expect(startBtn.isEnabled, "Checking consent checkbox must enable Start Listening")
                    consentBtn.state = .off
                    if let act = consentBtn.action {
                        NSApp.sendAction(act, to: consentBtn.target, from: consentBtn)
                    }
                    expect(!startBtn.isEnabled, "Unchecking consent checkbox must disable Start Listening")
                }
            }
            AppSettings.shared.appLanguageCode = "es"
            onboardingWC.window?.orderBack(nil)
            onboardingWC.showWindow(nil)
            expectEqual(
                onboardingWC.window?.title,
                L10n.tr("onboarding.title", "Welcome to Call Caption", language: "es"),
                "OnboardingWindowController must rebuild localized Spanish title on showWindow"
            )
            onboardingWC.window?.close()
            AppSettings.shared.appLanguageCode = "en"
        }

        // 5. LegalWindowController segment switching and live app-language reload
        do {
            AppSettings.shared.appLanguageCode = "en"
            let legalWC = LegalWindowController()
            legalWC.select(document: .privacy)
            expectEqual(legalWC.window?.title, L10n.tr("legal.privacyPolicy", "Privacy Policy"), "Legal window title should match Privacy Policy")
            if let root = legalWC.window?.contentView,
               let seg = findSubviews(ofType: NSSegmentedControl.self, in: root).first,
               let act = seg.action {
                seg.selectedSegment = 1
                NSApp.sendAction(act, to: seg.target, from: seg)
                expectEqual(legalWC.window?.title, L10n.tr("legal.termsOfUse", "Terms of Use"), "Segmented control must switch to Terms of Use")
            } else {
                expect(false, "LegalWindowController must contain NSSegmentedControl")
            }

            AppSettings.shared.appLanguageCode = "es"
            legalWC.select(document: .terms)
            expectEqual(
                legalWC.window?.title,
                L10n.tr("legal.termsOfUse", "Terms of Use", language: "es"),
                "LegalWindowController must reload Spanish document title after language change"
            )
            legalWC.window?.close()
            AppSettings.shared.appLanguageCode = "en"
        }
    }

    static func testAuditRound2Regressions() async {
        // 1. SpeechRecognitionManager: ITN rewrite vs dramatic shrink, activeTranslationTaskId backpressure, suspendForMicPriority discardEpoch
        do {
            expect(
                SingleSpeechChannel.isLikelyInverseTextNormalizationForTesting(
                    previous: "one two three four five six seven",
                    updated: "1234567"
                ),
                "Spoken digits rewritten by ITN must be recognized as ITN rather than a dramatic shrink"
            )
            expect(
                !SingleSpeechChannel.isLikelyInverseTextNormalizationForTesting(
                    previous: "This is a completely unrelated long sentence",
                    updated: "Wait"
                ),
                "Unrelated short rewrite without ITN pattern must trigger dramatic shrink split"
            )

            let engine = TranslationEngine.shared
            await engine.resetForTesting()
            await engine.setTranslatorForTesting { text, _, _, _ in
                "tr_\(text)"
            }

            let finalizedIDs = OSAllocatedUnfairLock<[UUID]>(initialState: [])
            let channel = SingleSpeechChannel(name: "AuditR2Speech", sourceLocaleId: "en-US", targetLangCode: "es")
            channel.onFinal = { utteranceID, _, _, _ in
                finalizedIDs.withLock { $0.append(utteranceID) }
            }
            defer { channel.stop() }

            channel.start(sourceLocaleId: "en-US", targetLangCode: "es")
            channel.processRecognizedTextForTesting("one two three four five", isFinal: false)
            let itnID1 = channel.activeUtteranceStateForTesting().utteranceID
            channel.processRecognizedTextForTesting("12345", isFinal: false)
            let itnID2 = channel.activeUtteranceStateForTesting().utteranceID
            expect(itnID1 != nil && itnID1 == itnID2, "ITN rewrite must keep the same utteranceID instead of splitting")
            expectEqual(finalizedIDs.withLock { $0.count }, 0, "ITN rewrite must not falsely commit a dramatic-shrink sentence")

            channel.processRecognizedTextForTesting("This is a completely different long phrase here", isFinal: false)
            let beforeShrinkID = channel.activeUtteranceStateForTesting().utteranceID
            channel.processRecognizedTextForTesting("Wait", isFinal: false)
            let afterShrinkID = channel.activeUtteranceStateForTesting().utteranceID
            expect(beforeShrinkID != nil && afterShrinkID != nil && afterShrinkID != beforeShrinkID, "Dramatic shrink must rotate to a new utteranceID")
            expect(finalizedIDs.withLock { $0.count } >= 1, "Dramatic shrink must commit the previous sentence cleanly")

            // pumpTranslationLoop activeTranslationTaskId isolation across advanceUtteranceEpochForTesting()
            channel.stop()
            finalizedIDs.withLock { $0.removeAll() }
            await engine.setTranslatorForTesting { text, _, _, _ in
                if text == "slow_first" {
                    try await Task.sleep(nanoseconds: 60_000_000)
                } else if text == "slower_second" {
                    try await Task.sleep(nanoseconds: 180_000_000)
                }
                return "tr_\(text)"
            }

            channel.start(sourceLocaleId: "es-ES", targetLangCode: "en")
            channel.processRecognizedTextForTesting("slow_first", isFinal: false)
            let taskAState = channel.activeUtteranceStateForTesting()
            expect(taskAState.isTranslating && taskAState.activeTranslationTaskId != nil, "First partial translation must record activeTranslationTaskId")

            channel.advanceUtteranceEpochForTesting()
            channel.processRecognizedTextForTesting("slower_second", isFinal: false)
            let taskBState = channel.activeUtteranceStateForTesting()
            expect(taskBState.isTranslating && taskBState.activeTranslationTaskId != nil && taskBState.activeTranslationTaskId != taskAState.activeTranslationTaskId, "New utterance must assign distinct activeTranslationTaskId")

            try? await Task.sleep(nanoseconds: 100_000_000)
            let midState = channel.activeUtteranceStateForTesting()
            expectEqual(midState.activeTranslationTaskId, taskBState.activeTranslationTaskId, "Completing stale task A must not clear activeTranslationTaskId for live task B")
            expect(midState.isTranslating, "isTranslating must remain true while task B is still running")

            for _ in 0..<40 {
                if !channel.activeUtteranceStateForTesting().isTranslating { break }
                try? await Task.sleep(nanoseconds: 15_000_000)
            }
            expect(!channel.activeUtteranceStateForTesting().isTranslating, "Task B must eventually finish cleanly")

            // suspendForMicPriority discardEpoch guard
            await engine.setTranslatorForTesting { text, _, _, _ in "tr_\(text)" }
            let countBeforeSuspend = finalizedIDs.withLock { $0.count }
            channel.processRecognizedTextForTesting("Unsent partial words pending", isFinal: false)
            _ = channel.suspendForMicPriority()
            channel.discardInFlight()
            await MainActor.run {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            expectEqual(
                finalizedIDs.withLock { $0.count },
                countBeforeSuspend,
                "discardInFlight after suspendForMicPriority must abort queued main-queue commit via discardEpoch"
            )
            channel.stop()
            await engine.resetForTesting()
        }

        // 2. TranslationEngine: clearEpoch late-write block & partialCache clear
        do {
            let engine = TranslationEngine.shared
            await engine.resetForTesting()

            await engine.setTranslatorForTesting { text, _, _, _ in
                if text == "stale_after_clear" {
                    try await Task.sleep(nanoseconds: 80_000_000)
                }
                return "OUT_\(text)"
            }
            let partial = await engine.translate(text: "hola parcial", sourceCode: "es", targetCode: "en", isFinal: false)
            expectEqual(partial, "OUT_hola parcial", "Partial translation must succeed")
            let partialCacheCount = await engine.partialCachedEntryCountForTesting()
            expect(partialCacheCount >= 1, "Partial translation must populate partialCache")

            let lateTask = Task {
                await engine.translate(text: "stale_after_clear", sourceCode: "es", targetCode: "en", isFinal: true)
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
            await engine.clearCache()
            let clearedPartialCount = await engine.partialCachedEntryCountForTesting()
            expectEqual(clearedPartialCount, 0, "clearCache must empty partialCache immediately")
            _ = await lateTask.value
            let cachedAfterClear = await engine.cachedValueForTesting(text: "stale_after_clear", sourceCode: "es", targetCode: "en")
            expectEqual(
                cachedAfterClear,
                nil,
                "clearEpoch increment must prevent pre-clear in-flight translation from writing back to cache"
            )
            await engine.resetForTesting()
        }

        // 3. TranscriptManager: mid-session autosaveTranscripts = true persists existing entries
        do {
            let tm = TranscriptManager.shared
            let settings = AppSettings.shared
            let savedAutosave = settings.autosaveTranscripts
            defer {
                settings.autosaveTranscripts = savedAutosave
                tm.clear()
                if let url = TranscriptManager.autosaveFileURL {
                    try? FileManager.default.removeItem(at: url)
                }
            }

            settings.autosaveTranscripts = false
            tm.clear()
            if let url = TranscriptManager.autosaveFileURL {
                try? FileManager.default.removeItem(at: url)
            }
            tm.addEntry(speaker: "Caller", original: "Mid-session orig", translated: "Mid-session trans")
            tm.flushPersistence()
            if let url = TranscriptManager.autosaveFileURL {
                expect(!FileManager.default.fileExists(atPath: url.path), "Autosave file must not be written while autosaveTranscripts is false")
            }

            settings.autosaveTranscripts = true
            tm.flushPersistence()
            if let url = TranscriptManager.autosaveFileURL {
                expect(FileManager.default.fileExists(atPath: url.path), "Enabling autosaveTranscripts mid-session must schedule save of existing entries")
                let data = try? Data(contentsOf: url)
                let content = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                expect(content.contains("Mid-session trans"), "Persisted autosave file must include pre-existing transcript entries")
            } else {
                expect(false, "autosaveFileURL must exist in test environment")
            }
        }

        // 4. AppSettings: gain clamping, gain flush, and distinct language pair
        do {
            let settings = AppSettings.shared
            let savedCallerGain = settings.callerInputGain
            let savedMicGain = settings.micInputGain
            defer {
                settings.callerInputGain = savedCallerGain
                settings.micInputGain = savedMicGain
                settings.flushPersistence()
            }

            expect(
                settings.mainLanguageCode != settings.foreignLanguageCode,
                "AppSettings must keep distinct default/configured main and foreign language codes"
            )
            settings.callerInputGain = 99.0
            settings.micInputGain = -4.0
            expect(settings.callerInputGain == AppSettings.maxInputGain, "callerInputGain must clamp to maxInputGain (\(AppSettings.maxInputGain))")
            expect(settings.micInputGain == AppSettings.minInputGain, "micInputGain must clamp to minInputGain (\(AppSettings.minInputGain))")

            settings.callerInputGain = 2.35
            settings.micInputGain = 1.65
            settings.flushPersistence()
            let suiteName = ProcessInfo.processInfo.environment["CALLCAPTION_TEST_SUITE"] ?? "com.callcaption.tests"
            if let suiteDefaults = UserDefaults(suiteName: suiteName) {
                expect(abs(suiteDefaults.double(forKey: "cc_caller_input_gain") - 2.35) < 0.001, "flushPersistence must flush callerInputGain synchronously")
                expect(abs(suiteDefaults.double(forKey: "cc_mic_input_gain") - 1.65) < 0.001, "flushPersistence must flush micInputGain synchronously")
            }
        }

        // 5. AudioCaptureEngine: stereo Int16/Int32 downmix, NaN AGC guard, echoTailDecay
        do {
            let engine = AudioCaptureEngine()
            guard let mono48Fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false),
                  let dstMono = AVAudioPCMBuffer(pcmFormat: mono48Fmt, frameCapacity: 64) else {
                expect(false, "Failed to allocate destination mono buffer")
                return
            }

            if let stereoInt16Inter = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: true),
               let src = AVAudioPCMBuffer(pcmFormat: stereoInt16Inter, frameCapacity: 64) {
                src.frameLength = 64
                if let ptr = src.int16ChannelData?[0] {
                    for i in 0..<64 {
                        ptr[i * 2] = 16384
                        ptr[i * 2 + 1] = 0
                    }
                }
                expect(engine.convertAndCopyToMono(source: src, destination: dstMono), "Stereo interleaved Int16 downmix must succeed")
                if let out = dstMono.floatChannelData?[0] {
                    expect(abs(out[0] - 0.25) < 0.001, "Stereo interleaved Int16 (0.5, 0.0) must downmix to ~0.25 (got \(out[0]))")
                }
            }

            if let stereoInt16NonInter = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 2, interleaved: false),
               let src = AVAudioPCMBuffer(pcmFormat: stereoInt16NonInter, frameCapacity: 64) {
                src.frameLength = 64
                if let ch = src.int16ChannelData {
                    for i in 0..<64 {
                        ch[0][i] = 16384
                        ch[1][i] = -16384
                    }
                }
                expect(engine.convertAndCopyToMono(source: src, destination: dstMono), "Stereo non-interleaved Int16 downmix must succeed")
                if let out = dstMono.floatChannelData?[0] {
                    expect(abs(out[0]) < 0.001, "Stereo non-interleaved Int16 (+0.5, -0.5) must downmix to ~0.0 (got \(out[0]))")
                }
            }

            if let stereoInt32Inter = AVAudioFormat(commonFormat: .pcmFormatInt32, sampleRate: 48000, channels: 2, interleaved: true),
               let src = AVAudioPCMBuffer(pcmFormat: stereoInt32Inter, frameCapacity: 64) {
                src.frameLength = 64
                if let ptr = src.int32ChannelData?[0] {
                    for i in 0..<64 {
                        ptr[i * 2] = 1_073_741_824
                        ptr[i * 2 + 1] = 0
                    }
                }
                expect(engine.convertAndCopyToMono(source: src, destination: dstMono), "Stereo interleaved Int32 downmix must succeed")
                if let out = dstMono.floatChannelData?[0] {
                    expect(abs(out[0] - 0.25) < 0.001, "Stereo interleaved Int32 (0.5, 0.0) must downmix to ~0.25 (got \(out[0]))")
                }
            }

            if let stereoInt32NonInter = AVAudioFormat(commonFormat: .pcmFormatInt32, sampleRate: 48000, channels: 2, interleaved: false),
               let src = AVAudioPCMBuffer(pcmFormat: stereoInt32NonInter, frameCapacity: 64) {
                src.frameLength = 64
                if let ch = src.int32ChannelData {
                    for i in 0..<64 {
                        ch[0][i] = 1_073_741_824
                        ch[1][i] = 1_073_741_824
                    }
                }
                expect(engine.convertAndCopyToMono(source: src, destination: dstMono), "Stereo non-interleaved Int32 downmix must succeed")
                if let out = dstMono.floatChannelData?[0] {
                    expect(abs(out[0] - 0.5) < 0.001, "Stereo non-interleaved Int32 (+0.5, +0.5) must downmix to ~0.5 (got \(out[0]))")
                }
            }

            let nanGain = AudioCaptureEngine.nextAGCGain(
                currentRMS: .nan,
                currentGain: .infinity,
                minRMSForBoost: .nan,
                targetRMS: .nan
            )
            expect(nanGain.isFinite && abs(nanGain - 1.0) < 0.0001, "nextAGCGain must stay finite 1.0 on NaN/Infinity inputs")
            expectEqual(AudioCaptureEngine.echoTailDecay(after: .nan), 0, "echoTailDecay(.nan) must safely return 0")
            expect(AudioCaptureEngine.echoTailDecay(after: 0.0) > AudioCaptureEngine.echoTailDecay(after: 0.3), "echoTailDecay must decay over time")
        }

        // 6. LiveShareManager & LiveShareCrypto: host/proxy header hardening & envelope metadata validation
        do {
            let token = LiveShareManager.generateSessionToken()
            expect(LiveShareManager.isLoopbackHost("127.0.0.1"), "127.0.0.1 must be classified as loopback")
            expect(LiveShareManager.isLoopbackHost("localhost"), "localhost must be classified as loopback")
            expect(LiveShareManager.isLoopbackHost("[::1]"), "[::1] must be classified as loopback")
            expect(!LiveShareManager.isLoopbackHost("192.168.1.50"), "LAN IP must not be classified as loopback")

            let bareCR = LiveShareManager.parseHTTPRequest("GET /s/\(token) HTTP/1.1\r\nHost: 127.0.0.1\r\r\n")
            expect(bareCR == nil, "parseHTTPRequest must reject bare-CR empty header framing smuggling")

            let dupHost = LiveShareManager.parseHTTPRequest("GET /s/\(token) HTTP/1.1\r\nHost: 127.0.0.1\r\nHost: evil.example\r\n\r\n")
            expect(dupHost == nil, "parseHTTPRequest must reject duplicate Host headers")

            let proxied = LiveShareManager.parseHTTPRequest("GET /s/\(token) HTTP/1.1\r\nHost: 192.168.1.50\r\nX-Forwarded-Host: evil.example\r\n\r\n")
            expect(proxied?.hasProxyHeaders == true, "parseHTTPRequest must flag proxy forwarding headers")

            if let lanReq = LiveShareManager.parseHTTPRequest("GET /s/\(token) HTTP/1.1\r\nHost: 192.168.1.50\r\n\r\n") {
                expectEqual(
                    LiveShareManager.evaluateRoute(request: lanReq, sessionToken: token, localIP: "192.168.1.50", allowLAN: false, tunnelHost: nil),
                    .forbidden,
                    "LAN Host header must be forbidden when allowLAN is false"
                )
            }

            let crypto = LiveShareCrypto()
            var colonRejected = false
            do {
                _ = try crypto.seal(Data("{}".utf8), type: "bad:type", sequence: 1)
            } catch {
                colonRejected = true
            }
            expect(colonRejected, "LiveShareCrypto.seal must reject ':' in AAD type")

            if let sealed = try? crypto.seal(Data("{\"v\":1}".utf8), type: "caption", sequence: 5),
               let validMeta = try? crypto.openWithMetadata(sealed, expectedType: "caption", minimumSequence: 5) {
                expectEqual(validMeta.sequence, 5, "openWithMetadata must recover exact sequence")

                var staleRejected = false
                do {
                    _ = try crypto.openWithMetadata(sealed, expectedType: "caption", minimumSequence: 6)
                } catch {
                    staleRejected = true
                }
                expect(staleRejected, "openWithMetadata must reject sequence below minimumSequence")
            } else {
                expect(false, "Valid seal/openWithMetadata must succeed")
            }

            let floatVersionEnvelope = Data("{\"v\":1.5,\"d\":\"AAAA\"}".utf8)
            var floatVersionRejected = false
            do {
                _ = try crypto.openWithMetadata(floatVersionEnvelope, expectedType: "caption")
            } catch {
                floatVersionRejected = true
            }
            expect(floatVersionRejected, "openWithMetadata must reject fractional version numbers")

            if let sealedZero = try? crypto.seal(Data("{\"hello\":1}".utf8), type: "caption", sequence: 0),
               let rawJSON = String(data: sealedZero, encoding: .utf8),
               var obj = (try? JSONSerialization.jsonObject(with: sealedZero)) as? [String: Any] {
                let floatJSONStr = rawJSON.replacingOccurrences(of: "\"v\":1", with: "\"v\":1.0")
                if let forgedFloatData = floatJSONStr.data(using: .utf8), floatJSONStr != rawJSON {
                    var rejectedFloatV = false
                    do { _ = try crypto.openWithMetadata(forgedFloatData, expectedType: "caption") } catch { rejectedFloatV = true }
                    expect(rejectedFloatV, "openWithMetadata must reject float representation even when numerically equal to 1.0")
                }

                obj["v"] = 1
                obj["s"] = 1.5
                if let floatSeqData = try? JSONSerialization.data(withJSONObject: obj) {
                    var rejectedFloatSeq = false
                    do { _ = try crypto.openWithMetadata(floatSeqData, expectedType: "caption") } catch { rejectedFloatSeq = true }
                    expect(rejectedFloatSeq, "openWithMetadata must reject float sequence numbers")
                }

                obj["s"] = -1
                if let negSeqData = try? JSONSerialization.data(withJSONObject: obj) {
                    var rejectedNegSeq = false
                    do { _ = try crypto.openWithMetadata(negSeqData, expectedType: "caption") } catch { rejectedNegSeq = true }
                    expect(rejectedNegSeq, "openWithMetadata must reject negative signed sequence numbers")
                }
            }
        }

        // 7. CaptionCoordinator: dismissPresentedAlert promotes lower-priority alert and unblocks repeats
        do {
            @MainActor
            final class AlertSpyDelegate: CaptionCoordinatorDelegate {
                var shownAlerts: [(message: String, actionType: SystemAlertActionType)] = []
                var clearCount = 0
                func coordinatorDidRequestShowAlert(message: String, actionType: SystemAlertActionType) {
                    shownAlerts.append((message, actionType))
                }
                func coordinatorDidRequestClearAlert() { clearCount += 1 }
                func coordinatorDidReceiveSpeech(utteranceID: UUID, speaker: String, original: String, translated: String, sourceLangCode: String, targetLangCode: String, isFinal: Bool, isUntranslated: Bool) {}
                func coordinatorDidUpdateAudioLevels(callerLevel: Float, micLevel: Float) {}
            }

            let coordinator = CaptionCoordinator.shared
            coordinator.stop()
            let spy = AlertSpyDelegate()
            coordinator.delegate = spy
            defer {
                coordinator.stop()
                coordinator.delegate = nil
            }

            coordinator.speechRecognitionDidEncounterAuthError(channelName: "Caller", message: "Speech auth alert")
            await MainActor.run { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            expectEqual(spy.shownAlerts.last?.message, "Speech auth alert", "Speech auth alert should present first")

            coordinator.audioCaptureDidDetectDeniedTapPermission()
            await MainActor.run { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            let afterDeniedCount = spy.shownAlerts.count
            expect(afterDeniedCount >= 2, "Higher-priority audioCapture alert must supersede speechAuth alert")

            coordinator.dismissPresentedAlert()
            await MainActor.run { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            expectEqual(spy.shownAlerts.last?.message, "Speech auth alert", "Dismissing higher-priority alert must restore lower-priority active alert")

            coordinator.dismissPresentedAlert()
            await MainActor.run { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            expect(spy.clearCount >= 1, "Dismissing last active alert must clear alert banner")

            let preRepeatCount = spy.shownAlerts.count
            coordinator.speechRecognitionDidEncounterAuthError(channelName: "Caller", message: "Speech auth alert")
            await MainActor.run { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
            expectEqual(spy.shownAlerts.count, preRepeatCount + 1, "Dismissed alert must be re-presentable if condition recurs")
        }

        // 8. TrayCaptionViewController viewDidDisappear deferral & LegalWindowController cached reload
        do {
            let vc = TrayCaptionViewController()
            vc.loadViewIfNeeded()
            let hostWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            hostWindow.isReleasedWhenClosed = false
            hostWindow.contentView = vc.view
            defer { hostWindow.contentView = nil }

            let tv = findSubviews(ofType: NSTextView.self, in: vc.view).first
            vc.updateCaption(utteranceID: UUID(), speaker: "Caller", translated: "Visible line", original: "Orig", isFinal: true)
            expect((tv?.string ?? "").contains("Visible line"), "Offscreen test window before viewDidDisappear must render immediately")

            vc.clearCaptionsUI()
            vc.viewDidDisappear()
            vc.updateCaption(utteranceID: UUID(), speaker: "Caller", translated: "Hidden while closed", original: "Orig", isFinal: true)
            expectEqual(tv?.textStorage?.length ?? -1, 0, "After viewDidDisappear, closed popover must defer text layout")

            vc.viewWillAppear()
            expect((tv?.string ?? "").contains("Hidden while closed"), "viewWillAppear must flush captions deferred while disappeared")

            let legalWC = LegalWindowController()
            legalWC.select(document: .privacy)
            let firstTitle = legalWC.window?.title
            legalWC.select(document: .terms)
            let secondTitle = legalWC.window?.title
            expect(firstTitle != secondTitle, "LegalWindowController must update title when switching documents")
            if let root = legalWC.window?.contentView,
               let seg = findSubviews(ofType: NSSegmentedControl.self, in: root).first {
                expect(seg.autoresizingMask.contains(.width), "LegalWindowController segmented control must preserve width autoresizing")
            }
            legalWC.window?.close()
        }
    }

    static func testDeterministicSpanishDialectResolution() async {
        // 1. DictationTranscriber backing locale resolution must be 100% deterministic
        // regardless of Set<Locale> iteration order (regression for es-CO randomly resolving
        // to es_ES / es_MX / es_US across launches).
        let esOrders: [[Locale]] = [
            ["es_ES", "es_MX", "es_CL", "es_US"].map { Locale(identifier: $0) },
            ["es_MX", "es_ES", "es_US", "es_CL"].map { Locale(identifier: $0) },
            ["es_CL", "es_US", "es_MX", "es_ES"].map { Locale(identifier: $0) },
            ["es_US", "es_CL", "es_ES", "es_MX"].map { Locale(identifier: $0) }
        ]

        for order in esOrders {
            let coResolved = SpeechAssetDownloader.resolveDictationTranscriberLocale(
                for: Locale(identifier: "es-CO"),
                cleanCode: "es",
                supportedLocales: order,
                preferredSystemLocales: ["es-CO"]
            )
            expectEqual(
                coResolved?.identifier.replacingOccurrences(of: "_", with: "-").lowercased(),
                "es-us",
                "es-CO must deterministically resolve to es-US backing asset regardless of Set order"
            )

            let coUnderscore = SpeechAssetDownloader.resolveDictationTranscriberLocale(
                for: Locale(identifier: "es_CO"),
                cleanCode: "es",
                supportedLocales: order,
                preferredSystemLocales: ["es-CO"]
            )
            expectEqual(
                coUnderscore?.identifier.replacingOccurrences(of: "_", with: "-").lowercased(),
                "es-us",
                "es_CO must deterministically resolve to es-US backing asset"
            )

            let latamResolved = SpeechAssetDownloader.resolveDictationTranscriberLocale(
                for: Locale(identifier: "es-419"),
                cleanCode: "es",
                supportedLocales: order,
                preferredSystemLocales: ["es-CO"]
            )
            expectEqual(
                latamResolved?.identifier.replacingOccurrences(of: "_", with: "-").lowercased(),
                "es-us",
                "es-419 must deterministically resolve to es-US backing asset"
            )

            for exactId in ["es-ES", "es-MX", "es-CL", "es-US"] {
                let exactResolved = SpeechAssetDownloader.resolveDictationTranscriberLocale(
                    for: Locale(identifier: exactId),
                    cleanCode: "es",
                    supportedLocales: order,
                    preferredSystemLocales: ["es-CO"]
                )
                expectEqual(
                    exactResolved?.identifier.replacingOccurrences(of: "_", with: "-").lowercased(),
                    exactId.lowercased(),
                    "Explicit supported Spanish dialect \(exactId) must match itself exactly"
                )
            }

            let arWithCoSysPref = SpeechAssetDownloader.resolveDictationTranscriberLocale(
                for: Locale(identifier: "es-AR"),
                cleanCode: "es",
                supportedLocales: order,
                preferredSystemLocales: ["es-CO"]
            )
            expectEqual(
                arWithCoSysPref?.identifier.replacingOccurrences(of: "_", with: "-").lowercased(),
                "es-us",
                "Unknown es-AR with system dictation es-CO must deterministically follow system backing asset"
            )
        }

        // 2. Target locale resolution respects explicit > saved > system dictation pref > default item locale
        expectEqual(
            SpeechAssetDownloader.resolveTargetLocaleId(
                forCode: "es",
                preferredLocaleId: "es-CO",
                savedPreferredLocaleId: "es-ES",
                systemPreferredLocales: ["es-MX"]
            ),
            "es-CO",
            "Explicit preferredLocaleId must take highest precedence"
        )
        expectEqual(
            SpeechAssetDownloader.resolveTargetLocaleId(
                forCode: "es",
                preferredLocaleId: nil,
                savedPreferredLocaleId: "es-CO",
                systemPreferredLocales: ["es-ES"]
            ),
            "es-CO",
            "Saved preferred speech locale must win over system prefs and default"
        )
        expectEqual(
            SpeechAssetDownloader.resolveTargetLocaleId(
                forCode: "es",
                preferredLocaleId: nil,
                savedPreferredLocaleId: nil,
                systemPreferredLocales: ["es-CO"]
            ),
            "es-CO",
            "System dictation preference es-CO must win over default es-ES when no explicit pref is saved"
        )
        expectEqual(
            SpeechAssetDownloader.resolveTargetLocaleId(
                forCode: "es",
                preferredLocaleId: nil,
                savedPreferredLocaleId: nil,
                systemPreferredLocales: []
            ),
            "es-ES",
            "Default es-ES fallback applies only when no explicit, saved, or system preference exists"
        )

        // 3. Deletion / download state isolation for Colombia (es-CO) vs Spain (es-ES)
        let settings = AppSettings.shared
        let origForeign = settings.foreignLanguageCode
        let origPrefEs = settings.preferredSpeechLocale(forCode: "es")
        let downloader = SpeechAssetDownloader.shared
        downloader.resetForTesting()
        defer {
            downloader.resetForTesting()
            settings.setPreferredSpeechLocale(origPrefEs, forCode: "es")
            settings.foreignLanguageCode = origForeign
            SupportedLanguages.invalidateCache(forCode: "es")
        }

        settings.setPreferredSpeechLocale("es-CO", forCode: "es")
        SupportedLanguages.invalidateCache(forCode: "es")
        expectEqual(
            SupportedLanguages.bestLocale(forCode: "es").identifier.replacingOccurrences(of: "_", with: "-").lowercased(),
            "es-co",
            "bestLocale for es must preserve Colombia preference"
        )

        downloader.deleteDownloadedAsset(forCode: "es", localeId: "es-CO")
        expect(downloader.isLocaleMarkedDeleted("es-CO"), "Deleting es-CO must mark es-CO deleted")
        expect(!downloader.isLocaleMarkedDeleted("es-ES"), "Deleting es-CO must not mark es-ES deleted")
        expect(!SupportedLanguages.isLocaleDownloaded("es-CO"), "Deleted es-CO must report not downloaded")

        downloader.ensureDownloaded(forCode: "es", preferredLocaleId: "es-CO", force: true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        expect(!downloader.isLocaleMarkedDeleted("es-CO"), "Re-downloading es-CO must clear es-CO deleted marker")
        expect(!downloader.isLocaleMarkedInstalled("es-ES"), "Downloading es-CO must never mark es-ES installed")
        expect(!downloader.isLocaleMarkedInstalled("es-MX"), "Downloading es-CO must never mark es-MX installed")
    }
}

@main
struct CallCaptionTestMain {
    static func main() async {
        let code = await TestSuite.runAll()
        exit(code)
    }
}
