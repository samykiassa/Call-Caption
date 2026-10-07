import Foundation
import Speech
import AVFoundation
import CoreMedia
import os

/// A protocol that defines the bidirectional communication of speech recognition and translation updates.
///
/// Conforming objects can receive real-time streaming updates for both partial (in-progress) and
/// final transcriptions, as well as status changes and authorization errors.
public protocol BidirectionalSpeechDelegate: AnyObject {
    /// Called when an ongoing speech utterance from the remote caller is updated.
    /// - Parameters:
    ///   - partialOriginal: The current partial transcription of the caller's speech.
    ///   - partialTranslated: The current partial translation of the caller's speech.
    func callerSpeechDidUpdate(partialOriginal: String, partialTranslated: String)
    
    /// Called when the remote caller has finished a speech utterance.
    /// - Parameters:
    ///   - original: The final transcription of the caller's speech.
    ///   - translated: The final translation of the caller's speech.
    func callerSpeechDidFinalize(original: String, translated: String)
    
    /// Called when an ongoing speech utterance from the local user is updated.
    /// - Parameters:
    ///   - partialOriginal: The current partial transcription of the local user's speech.
    ///   - partialTranslated: The current partial translation of the local user's speech.
    func mySpeechDidUpdate(partialOriginal: String, partialTranslated: String)
    
    /// Called when the local user has finished a speech utterance.
    /// - Parameters:
    ///   - original: The final transcription of the local user's speech.
    ///   - translated: The final translation of the local user's speech.
    func mySpeechDidFinalize(original: String, translated: String)
    
    /// Called when the active recognition state changes.
    /// - Parameter isRecognizing: A boolean indicating whether speech recognition is actively processing.
    func speechRecognitionStatusChanged(_ isRecognizing: Bool)
    
    /// Called when an authorization or permissions error prevents speech recognition.
    /// - Parameter message: A user-facing message detailing the error.
    func speechRecognitionDidEncounterAuthError(message: String)
}

/// A class that manages a single, unidirectional channel of speech recognition and translation.
///
/// `SingleSpeechChannel` handles the underlying `SFSpeechRecognizer` session, manages audio buffer
/// ingestion, and translates finalized or partial text using the `TranslationEngine`. It also features
/// automatic session cycling and error backoff to ensure reliable, long-running transcription.
public class SingleSpeechChannel: NSObject, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    
    /// The unique name identifying this channel (e.g., "caller" or "me").
    public let channelName: String
    
    /// The BCP-47 language tag identifying the source spoken language.
    public private(set) var sourceLocaleId: String
    
    /// The ISO language code representing the target translation language.
    public private(set) var targetLangCode: String
    
    /// A closure called repeatedly as partial speech transcription and translation progress.
    public var onPartial: ((String, String) -> Void)?
    
    /// A closure called when a speech utterance has completed and final transcription/translation are available.
    public var onFinal: ((String, String) -> Void)?
    
    /// A closure called when an authorization or initialization error occurs.
    public var onAuthError: ((String) -> Void)?
    
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    
    private let processingQueue: DispatchQueue
    private var pendingTranslationWorkItem: DispatchWorkItem?
    
    private var currentOriginal: String = ""
    private var currentTranslated: String = ""
    
    /// Indicates whether the channel is currently capturing and recognizing speech.
    public private(set) var isRunning: Bool = false
    
    private var sessionStartTime: Date = Date()
    private var restartWorkItem: DispatchWorkItem?
    private var consecutiveErrors: Int = 0
    private var isStartingSession: Bool = false
    
    /// Initializes a new speech channel with the specified configurations.
    /// - Parameters:
    ///   - name: A descriptive identifier for this channel.
    ///   - sourceLocaleId: The locale of the incoming speech.
    ///   - targetLangCode: The desired target language code for translation.
    public init(name: String, sourceLocaleId: String, targetLangCode: String) {
        self.channelName = name
        self.sourceLocaleId = sourceLocaleId
        self.targetLangCode = targetLangCode
        self.processingQueue = DispatchQueue(label: "com.callcaption.\(name).queue", qos: .userInitiated)
        super.init()
    }
    
    /// Starts the speech recognition channel with new language settings.
    /// - Parameters:
    ///   - sourceLocaleId: The expected locale of the incoming speech audio.
    ///   - targetLangCode: The language code to which recognized text should be translated.
    public func start(sourceLocaleId: String, targetLangCode: String) {
        stop()
        self.sourceLocaleId = sourceLocaleId
        self.targetLangCode = targetLangCode
        self.isRunning = true
        self.consecutiveErrors = 0
        
        setupRecognizer()
        startNewSession()
    }
    
    /// Stops the speech recognition channel, halting all audio processing and pending translation tasks.
    public func stop() {
        isRunning = false
        restartWorkItem?.cancel()
        restartWorkItem = nil
        finalizeUtterance()
        
        let oldReq = request
        let oldTask = task
        request = nil
        task = nil
        
        oldReq?.endAudio()
        oldTask?.cancel()
    }
    
    /// Updates the source and target languages, restarting the session if it is currently running.
    /// - Parameters:
    ///   - sourceLocaleId: The new expected locale of the incoming speech audio.
    ///   - targetLangCode: The new language code to which recognized text should be translated.
    public func updateLanguages(sourceLocaleId: String, targetLangCode: String) {
        self.sourceLocaleId = sourceLocaleId
        self.targetLangCode = targetLangCode
        if isRunning {
            start(sourceLocaleId: sourceLocaleId, targetLangCode: targetLangCode)
        }
    }
    
    /// Appends a video/audio sample buffer to the recognition request.
    /// - Parameter buffer: The sample buffer containing audio data.
    public func appendAudioSampleBuffer(_ buffer: CMSampleBuffer) {
        guard isRunning else { return }
        if let pcm = AudioCaptureEngine.convertSampleBufferToPCM(sampleBuffer: buffer) {
            appendPCMBuffer(pcm)
        } else {
            guard let req = request else {
                // Quickly ensure a session is active if audio is arriving
                if restartWorkItem == nil && !isStartingSession {
                    scheduleRestart(after: 0.1)
                }
                return
            }
            req.appendAudioSampleBuffer(buffer)
            checkSessionAge()
        }
    }
    
    /// Appends a PCM audio buffer directly to the recognition request.
    /// - Parameter buffer: The PCM buffer containing audio data.
    public func appendPCMBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRunning else { return }
        guard let req = request else {
            // Quickly ensure a session is active if audio is arriving
            if restartWorkItem == nil && !isStartingSession {
                scheduleRestart(after: 0.1)
            }
            return
        }
        req.append(buffer)
        checkSessionAge()
    }
    
    private func setupRecognizer() {
        let loc = Locale(identifier: sourceLocaleId)
        recognizer = SFSpeechRecognizer(locale: loc)
        if recognizer == nil {
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        }
    }
    
    /// Explicitly initializes and begins a new underlying `SFSpeechRecognitionTask`.
    ///
    /// This method handles tearing down the old request, setting up a new audio buffer recognition
    /// request, and appropriately routing the text results and error codes to handle API limits,
    /// silences, and standard stream cycling.
    public func startNewSession() {
        guard isRunning else { return }
        if isStartingSession { return }
        isStartingSession = true
        defer { isStartingSession = false }
        
        restartWorkItem?.cancel()
        restartWorkItem = nil
        
        // Ensure recognizer exists
        if recognizer == nil {
            setupRecognizer()
        }
        
        guard let recognizer = recognizer else { return }
        
        if !recognizer.isAvailable {
            NSLog("[\(channelName)] Recognizer for \(sourceLocaleId) not yet available. Retrying in 2s...")
            scheduleRestart(after: 2.0)
            return
        }
        
        let oldReq = request
        let oldTask = task
        request = nil
        task = nil
        
        oldReq?.endAudio()
        oldTask?.cancel()
        
        let newReq = SFSpeechAudioBufferRecognitionRequest()
        newReq.shouldReportPartialResults = true
        
        // Use on-device recognition if available; otherwise use system speech recognition
        if #available(macOS 10.15, *), recognizer.supportsOnDeviceRecognition {
            newReq.requiresOnDeviceRecognition = true
        } else {
            newReq.requiresOnDeviceRecognition = false
        }
        
        self.request = newReq
        self.sessionStartTime = Date()
        
        task = recognizer.recognitionTask(with: newReq) { [weak self, weak newReq] (result, error) in
            guard let self = self else { return }
            guard let activeReq = newReq, self.request === activeReq else {
                // Ignore callbacks from stale/cancelled tasks
                return
            }
            
            if let error = error {
                let nsError = error as NSError
                print("[\(self.channelName)] Recognition event code \(nsError.code), domain=\(nsError.domain): \(error.localizedDescription)")
                fflush(stdout)
                
                self.request = nil
                self.task = nil
                
                if nsError.code == 1700 {
                    if SFSpeechRecognizer.authorizationStatus() == .denied {
                        DispatchQueue.main.async {
                            self.onAuthError?("Speech Recognition access denied in macOS System Settings")
                        }
                    } else {
                        let langCode = self.sourceLocaleId.components(separatedBy: "-").first ?? ""
                        let langName = SupportedLanguages.item(forCode: langCode)?.name ?? self.sourceLocaleId
                        DispatchQueue.main.async {
                            self.onAuthError?("To transcribe \(langName), add \(langName) in System Settings ➔ Keyboard ➔ Dictation.")
                        }
                        if self.isRunning {
                            self.scheduleRestart(after: 5.0)
                        }
                    }
                    return
                }
                
                if nsError.code == 201 || nsError.domain == "kLSRErrorDomain" {
                    // Siri & Dictation disabled in macOS settings
                    print("[\(self.channelName)] Siri and Dictation disabled (Code 201).")
                    fflush(stdout)
                    DispatchQueue.main.async {
                        self.onAuthError?("Dictation is disabled in macOS. Please enable Dictation in System Settings ➔ Keyboard ➔ Dictation.")
                    }
                    return
                }
                
                if nsError.code == 203 || nsError.code == 202 {
                    // Apple speech API quota limit reached - back off
                    print("[\(self.channelName)] Apple Speech API quota reached (code \(nsError.code)). Backing off for 10s...")
                    fflush(stdout)
                    if self.isRunning {
                        self.scheduleRestart(after: 10.0)
                    }
                    return
                }
                
                if nsError.code == 216 {
                    // Normal utterance boundary / completion
                    self.consecutiveErrors = 0
                    if self.isRunning {
                        self.scheduleRestart(after: 0.1)
                    }
                    return
                }
                
                if nsError.code == 1110 {
                    // Silence / no speech detected in audio window
                    if self.isRunning {
                        self.scheduleRestart(after: 0.2)
                    }
                    return
                }
                
                // For other errors, apply progressive backoff (1s, 2s, 3s... max 10s)
                self.consecutiveErrors += 1
                let delay = min(10.0, 1.0 * Double(self.consecutiveErrors))
                if self.isRunning {
                    self.scheduleRestart(after: delay)
                }
                return
            }
            
            guard let result = result else { return }
            self.consecutiveErrors = 0
            let text = result.bestTranscription.formattedString
            print("[\(self.channelName)] HEARD: '\(text)' (isFinal: \(result.isFinal))")
            fflush(stdout)
            self.handleText(text, isFinal: result.isFinal)
        }
    }
    
    private func scheduleRestart(after delay: TimeInterval) {
        guard isRunning else { return }
        restartWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.finalizeUtterance()
            self.startNewSession()
        }
        restartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
    
    /// Processes and translates raw text as if it were recognized speech input.
    ///
    /// Useful for injecting direct text strings (e.g., from an external web client).
    /// - Parameters:
    ///   - text: The transcribed text string.
    ///   - isFinal: A boolean indicating if this is the final completed utterance.
    public func handleDirectText(_ text: String, isFinal: Bool) {
        handleText(text, isFinal: isFinal)
    }
    
    private func handleText(_ text: String, isFinal: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        currentOriginal = trimmed
        let src = sourceLocaleId.components(separatedBy: "-").first ?? "es"
        let tgt = targetLangCode
        
        pendingTranslationWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            
            Task {
                let translated = await TranslationEngine.shared.translate(
                    text: trimmed,
                    sourceCode: src,
                    targetCode: tgt
                )
                
                DispatchQueue.main.async {
                    self.currentTranslated = translated
                    self.onPartial?(trimmed, translated)
                    
                    if isFinal {
                        self.finalizeUtterance()
                    }
                }
            }
        }
        pendingTranslationWorkItem = workItem
        processingQueue.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }
    
    private func finalizeUtterance() {
        let orig = currentOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
        let trans = currentTranslated.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !orig.isEmpty || !trans.isEmpty {
            onFinal?(orig, trans.isEmpty ? orig : trans)
        }
        
        currentOriginal = ""
        currentTranslated = ""
    }
    
    private func checkSessionAge() {
        guard isRunning else { return }
        // Apple SFSpeechAudioBufferRecognitionRequest is most stable when cycled every 45-60s
        if Date().timeIntervalSince(sessionStartTime) > 55.0 {
            sessionStartTime = Date()
            scheduleRestart(after: 0.05)
        }
    }
}

/// An overarching coordinator for bidirectional speech recognition.
///
/// `SpeechRecognitionManager` manages two distinct `SingleSpeechChannel` instances:
/// one for the remote caller, and one for the local user. It consolidates audio feeds,
/// language configurations, and lifecycle events, forwarding recognized and translated
/// text events to its delegate.
public class SpeechRecognitionManager: NSObject, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    
    /// The delegate to receive all speech transcription and translation events.
    public weak var delegate: BidirectionalSpeechDelegate?
    
    /// The speech recognition channel dedicated to processing the remote caller's audio.
    public let callerChannel = SingleSpeechChannel(name: "caller", sourceLocaleId: "es-ES", targetLangCode: "en")
    
    /// The speech recognition channel dedicated to processing the local user's audio.
    public let myChannel = SingleSpeechChannel(name: "me", sourceLocaleId: "en-US", targetLangCode: "es")
    
    /// A boolean indicating whether the bidirectional manager is actively running.
    public private(set) var isRunning: Bool = false
    
    /// Initializes a new bidirectional speech recognition manager.
    public override init() {
        super.init()
        setupCallbacks()
    }
    
    /// Asks the user for permission to perform speech recognition.
    /// - Parameter completion: A closure called on the main thread with the resulting authorization status.
    public static func requestAuthorization(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }
    
    private func setupCallbacks() {
        // Caller callbacks
        callerChannel.onPartial = { [weak self] orig, trans in
            self?.delegate?.callerSpeechDidUpdate(partialOriginal: orig, partialTranslated: trans)
        }
        callerChannel.onFinal = { [weak self] orig, trans in
            self?.delegate?.callerSpeechDidFinalize(original: orig, translated: trans)
        }
        callerChannel.onAuthError = { [weak self] msg in
            self?.delegate?.speechRecognitionDidEncounterAuthError(message: msg)
        }
        
        // My voice callbacks
        myChannel.onPartial = { [weak self] orig, trans in
            self?.delegate?.mySpeechDidUpdate(partialOriginal: orig, partialTranslated: trans)
        }
        myChannel.onFinal = { [weak self] orig, trans in
            self?.delegate?.mySpeechDidFinalize(original: orig, translated: trans)
        }
        myChannel.onAuthError = { [weak self] msg in
            self?.delegate?.speechRecognitionDidEncounterAuthError(message: msg)
        }
    }
    
    /// Starts both caller and user recognition channels with the specified locales.
    /// - Parameters:
    ///   - callerLocaleId: The locale identifier for the caller's speech.
    ///   - myLocaleId: The locale identifier for the local user's speech.
    public func start(
        callerLocaleId: String,
        myLocaleId: String
    ) {
        stop()
        self.isRunning = true
        
        let callerCode = callerLocaleId.components(separatedBy: "-").first ?? "es"
        let myCode = myLocaleId.components(separatedBy: "-").first ?? "en"
        
        callerChannel.start(sourceLocaleId: callerLocaleId, targetLangCode: myCode)
        myChannel.start(sourceLocaleId: myLocaleId, targetLangCode: callerCode)
        
        delegate?.speechRecognitionStatusChanged(true)
    }
    
    /// Stops both recognition channels.
    public func stop() {
        isRunning = false
        callerChannel.stop()
        myChannel.stop()
        delegate?.speechRecognitionStatusChanged(false)
    }
    
    /// Updates the expected languages for both channels dynamically.
    /// - Parameters:
    ///   - callerLocaleId: The new locale identifier for the caller's speech.
    ///   - myLocaleId: The new locale identifier for the local user's speech.
    public func updateLanguages(callerLocaleId: String, myLocaleId: String) {
        let callerCode = callerLocaleId.components(separatedBy: "-").first ?? "es"
        let myCode = myLocaleId.components(separatedBy: "-").first ?? "en"
        
        callerChannel.updateLanguages(sourceLocaleId: callerLocaleId, targetLangCode: myCode)
        myChannel.updateLanguages(sourceLocaleId: myLocaleId, targetLangCode: callerCode)
    }
    
    /// Feeds standard CMSampleBuffer audio from the remote caller into the caller channel.
    /// - Parameter buffer: The audio sample buffer to process.
    public func feedCallerAudioBuffer(_ buffer: CMSampleBuffer) {
        callerChannel.appendAudioSampleBuffer(buffer)
    }
    
    /// Feeds PCM audio from the remote caller into the caller channel.
    /// - Parameter buffer: The PCM audio buffer to process.
    public func feedCallerAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        callerChannel.appendPCMBuffer(buffer)
    }
    
    /// Feeds PCM audio from the local user's microphone into the local user channel.
    /// - Parameter buffer: The PCM audio buffer to process.
    public func feedMyAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        myChannel.appendPCMBuffer(buffer)
    }
    
    /// Injects plain text directly into the caller channel as an alternative to audio recognition.
    /// - Parameters:
    ///   - text: The text to process and translate.
    ///   - isFinal: Indicates whether the text is a completed utterance.
    public func injectCallerSpeech(text: String, isFinal: Bool) {
        callerChannel.handleDirectText(text, isFinal: isFinal)
    }
}
