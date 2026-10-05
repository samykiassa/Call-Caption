import Foundation
import Speech
import AVFoundation
import CoreMedia

public protocol BidirectionalSpeechDelegate: AnyObject {
    // Caller's speech (Spanish -> English for Mac user)
    func callerSpeechDidUpdate(partialOriginal: String, partialTranslated: String)
    func callerSpeechDidFinalize(original: String, translated: String)
    
    // Your speech (English -> Spanish for Mobile caller)
    func mySpeechDidUpdate(partialOriginal: String, partialTranslated: String)
    func mySpeechDidFinalize(original: String, translated: String)
    
    func speechRecognitionStatusChanged(_ isRecognizing: Bool)
    func speechRecognitionDidEncounterAuthError(message: String)
}

public class SingleSpeechChannel: NSObject, @unchecked Sendable {
    public let channelName: String
    public private(set) var sourceLocaleId: String
    public private(set) var targetLangCode: String
    
    public var onPartial: ((String, String) -> Void)?
    public var onFinal: ((String, String) -> Void)?
    public var onAuthError: ((String) -> Void)?
    
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    
    private let processingQueue: DispatchQueue
    private var pendingTranslationWorkItem: DispatchWorkItem?
    
    private var currentOriginal: String = ""
    private var currentTranslated: String = ""
    public private(set) var isRunning: Bool = false
    private var sessionStartTime: Date = Date()
    private var restartWorkItem: DispatchWorkItem?
    private var consecutiveErrors: Int = 0
    private var isStartingSession: Bool = false
    
    public init(name: String, sourceLocaleId: String, targetLangCode: String) {
        self.channelName = name
        self.sourceLocaleId = sourceLocaleId
        self.targetLangCode = targetLangCode
        self.processingQueue = DispatchQueue(label: "com.callcaption.\(name).queue", qos: .userInitiated)
        super.init()
    }
    
    public func start(sourceLocaleId: String, targetLangCode: String) {
        stop()
        self.sourceLocaleId = sourceLocaleId
        self.targetLangCode = targetLangCode
        self.isRunning = true
        self.consecutiveErrors = 0
        
        setupRecognizer()
        startNewSession()
    }
    
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
    
    public func updateLanguages(sourceLocaleId: String, targetLangCode: String) {
        self.sourceLocaleId = sourceLocaleId
        self.targetLangCode = targetLangCode
        if isRunning {
            start(sourceLocaleId: sourceLocaleId, targetLangCode: targetLangCode)
        }
    }
    
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

public class SpeechRecognitionManager: NSObject, @unchecked Sendable {
    public weak var delegate: BidirectionalSpeechDelegate?
    
    // Channel 1: Caller (Spanish -> English)
    public let callerChannel = SingleSpeechChannel(name: "caller", sourceLocaleId: "es-ES", targetLangCode: "en")
    
    // Channel 2: You (English -> Spanish)
    public let myChannel = SingleSpeechChannel(name: "me", sourceLocaleId: "en-US", targetLangCode: "es")
    
    public private(set) var isRunning: Bool = false
    
    public override init() {
        super.init()
        setupCallbacks()
    }
    
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
    
    public func stop() {
        isRunning = false
        callerChannel.stop()
        myChannel.stop()
        delegate?.speechRecognitionStatusChanged(false)
    }
    
    public func updateLanguages(callerLocaleId: String, myLocaleId: String) {
        let callerCode = callerLocaleId.components(separatedBy: "-").first ?? "es"
        let myCode = myLocaleId.components(separatedBy: "-").first ?? "en"
        
        callerChannel.updateLanguages(sourceLocaleId: callerLocaleId, targetLangCode: myCode)
        myChannel.updateLanguages(sourceLocaleId: myLocaleId, targetLangCode: callerCode)
    }
    
    public func feedCallerAudioBuffer(_ buffer: CMSampleBuffer) {
        callerChannel.appendAudioSampleBuffer(buffer)
    }
    
    public func feedCallerAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        callerChannel.appendPCMBuffer(buffer)
    }
    
    public func feedMyAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        myChannel.appendPCMBuffer(buffer)
    }
    
    // Direct speech input (e.g. from mobile phone web client)
    public func injectCallerSpeech(text: String, isFinal: Bool) {
        callerChannel.handleDirectText(text, isFinal: isFinal)
    }
}
