import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import AppKit
import os

public enum AudioSourceMode: String, CaseIterable {
    case bidirectional = "2-Way (Call + My Voice)"
    case callerOnly = "Caller Only (System Audio)"
    case micOnly = "My Voice Only (Mic)"
}

public protocol AudioCaptureDelegate: AnyObject {
    func audioCaptureDidOutputCallerAudio(sampleBuffer: CMSampleBuffer)
    func audioCaptureDidOutputCallerAudio(pcmBuffer: AVAudioPCMBuffer)
    func audioCaptureDidOutputMyAudio(pcmBuffer: AVAudioPCMBuffer)
    func audioCaptureDidUpdateCallerLevel(_ level: Float)
    func audioCaptureDidUpdateMyLevel(_ level: Float)
    func audioCaptureDidEncounterError(_ error: Error)
}

public extension AudioCaptureDelegate {
    func audioCaptureDidOutputCallerAudio(sampleBuffer: CMSampleBuffer) {}
    func audioCaptureDidOutputCallerAudio(pcmBuffer: AVAudioPCMBuffer) {}
}

public class AudioCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let stateLock = OSAllocatedUnfairLock()
    public weak var delegate: AudioCaptureDelegate?
    
    private var _currentMode: AudioSourceMode = .bidirectional
    public var currentMode: AudioSourceMode {
        stateLock.withLock { _currentMode }
    }
    
    private var _isRunning: Bool = false
    public var isRunning: Bool {
        stateLock.withLock { _isRunning }
    }
    
    // ScreenCaptureKit stream (Caller's voice via Call audio)
    private var scStream: SCStream?
    private let callerQueue = DispatchQueue(label: "com.callcaption.callerAudioQueue", qos: .userInteractive)
    
    // AVAudioEngine for your voice (Microphone)
    private var audioEngine: AVAudioEngine?
    
    // Smoothed audio meter levels
    private var smoothedCallerLevel: Float = 0.0
    private var smoothedMyLevel: Float = 0.0
    private var isStartingEngine: Bool = false
    
    // Recovery & watchdog for call connection / audio route transitions
    private var configurationObserver: NSObjectProtocol?
    private var audioRecoveryWorkItem: DispatchWorkItem?
    private var watchdogTimer: Timer?
    
    public override init() {
        super.init()
        setupConfigurationObserver()
    }
    
    deinit {
        if let obs = configurationObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        watchdogTimer?.invalidate()
    }
    
    // MARK: - CoreAudio Hardware Reconfiguration Listener (Call Connect/Disconnect)
    
    private func setupConfigurationObserver() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleAudioConfigurationChange()
        }
    }
    
    private func handleAudioConfigurationChange() {
        NSLog("[AudioCaptureEngine] Audio hardware reconfiguration detected (call started/ended or route changed).")
        guard isRunning, (currentMode == .bidirectional || currentMode == .micOnly) else { return }
        
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.isRunning else { return }
            do {
                NSLog("[AudioCaptureEngine] Re-attaching microphone tap with active call hardware format...")
                try self.restartMicrophoneAudio()
            } catch {
                NSLog("[AudioCaptureEngine] Microphone recovery error: \(error)")
            }
        }
        stateLock.withLock {
            audioRecoveryWorkItem?.cancel()
            audioRecoveryWorkItem = item
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }
    
    private func startWatchdog() {
        DispatchQueue.main.async { [weak self] in
            self?.watchdogTimer?.invalidate()
            self?.watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                guard let self = self, self.isRunning else { return }
                if self.currentMode == .bidirectional || self.currentMode == .micOnly {
                    let engine = self.stateLock.withLock { self.audioEngine }
                    if let engine = engine, !engine.isRunning {
                        NSLog("[AudioCaptureEngine] Watchdog: Engine stopped during call. Restarting microphone...")
                        try? self.restartMicrophoneAudio()
                    }
                }
            }
        }
    }
    
    private func stopWatchdog() {
        DispatchQueue.main.async { [weak self] in
            self?.watchdogTimer?.invalidate()
            self?.watchdogTimer = nil
        }
    }
    
    // MARK: - Permissions
    
    public static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
    
    public static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
    
    // MARK: - Start / Stop
    
    public func start(mode: AudioSourceMode = .bidirectional) async throws {
        let alreadyStarting = stateLock.withLock { () -> Bool in
            if isStartingEngine { return true }
            isStartingEngine = true
            return false
        }
        if alreadyStarting { return }
        
        defer {
            stateLock.withLock { isStartingEngine = false }
        }
        
        stop()
        
        stateLock.withLock { _currentMode = mode }
        
        var startedAny = false
        var errors: [String] = []
        
        // 1. Start Microphone (Your voice)
        if mode == .bidirectional || mode == .micOnly {
            do {
                try startMicrophoneAudio()
                startedAny = true
                stateLock.withLock { _isRunning = true }
                NSLog("[AudioCaptureEngine] Microphone audio started successfully")
            } catch {
                NSLog("[AudioCaptureEngine] Microphone audio failed: \(error)")
                errors.append("Mic: \(error.localizedDescription)")
            }
        }
        
        // 2. Start ScreenCaptureKit (Caller audio from call)
        if mode == .bidirectional || mode == .callerOnly {
            do {
                try await startScreenCaptureAudio()
                startedAny = true
                stateLock.withLock { _isRunning = true }
                NSLog("[AudioCaptureEngine] System Call Audio started successfully")
            } catch {
                NSLog("[AudioCaptureEngine] System Call Audio failed: \(error)")
                errors.append("Call Audio: \(error.localizedDescription)")
            }
        }
        
        if !startedAny && !errors.isEmpty {
            stateLock.withLock { _isRunning = false }
            let err = NSError(domain: "AudioCaptureEngine", code: -99, userInfo: [NSLocalizedDescriptionKey: errors.joined(separator: "\n")])
            throw err
        }
        
        stateLock.withLock { _isRunning = startedAny }
        
        if startedAny {
            startWatchdog()
        }
    }
    
    public func stop() {
        let (streamToStop, engineToStop, workItemToCancel) = stateLock.withLock { () -> (SCStream?, AVAudioEngine?, DispatchWorkItem?) in
            _isRunning = false
            let s = scStream
            scStream = nil
            let e = audioEngine
            audioEngine = nil
            let w = audioRecoveryWorkItem
            audioRecoveryWorkItem = nil
            return (s, e, w)
        }
        
        stopWatchdog()
        workItemToCancel?.cancel()
        
        // Stop ScreenCaptureKit
        if let stream = streamToStop {
            stream.stopCapture { _ in }
        }
        
        // Stop AVAudioEngine
        if let engine = engineToStop {
            if engine.isRunning {
                engine.stop()
            }
            engine.inputNode.removeTap(onBus: 0)
        }
        
        delegate?.audioCaptureDidUpdateCallerLevel(0)
        delegate?.audioCaptureDidUpdateMyLevel(0)
    }
    
    // MARK: - ScreenCaptureKit Implementation (Caller Audio)
    
    private func startScreenCaptureAudio() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            NSLog("[AudioCapture] SCShareableContent error: \(error)")
            throw error
        }
        
        guard let display = content.displays.first else {
            let err = NSError(domain: "AudioCaptureEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "No active display found"])
            throw err
        }
        
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.channelCount = 1
        config.sampleRate = 48000
        config.excludesCurrentProcessAudio = true
        config.width = 120
        config.height = 120
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: callerQueue)
        try? stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: callerQueue)
        
        try await stream.startCapture()
        
        stateLock.withLock { self.scStream = stream }
        
        NSLog("[AudioCapture] ScreenCaptureKit audio capture started successfully (Caller)")
    }
    
    // SCStreamOutput callback for caller audio
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        
        let level = calculateRMS(from: sampleBuffer)
        updateCallerAudioLevel(level)
        
        // Convert to high-fidelity AVAudioPCMBuffer for Speech Recognition
        if let pcm = AudioCaptureEngine.convertSampleBufferToPCM(sampleBuffer: sampleBuffer) {
            delegate?.audioCaptureDidOutputCallerAudio(pcmBuffer: pcm)
        } else {
            delegate?.audioCaptureDidOutputCallerAudio(sampleBuffer: sampleBuffer)
        }
    }
    
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[AudioCapture] SCStream stopped with error: \(error). Reconnecting...")
        
        let (running, mode) = stateLock.withLock { (_isRunning, _currentMode) }
        
        if running && (mode == .bidirectional || mode == .callerOnly) {
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                try? await self.startScreenCaptureAudio()
            }
        }
    }
    
    // MARK: - Microphone Implementation (Your Voice)
    
    public func restartMicrophoneAudio() throws {
        let engine = stateLock.withLock { audioEngine }
        
        if let engine = engine {
            if engine.isRunning {
                engine.stop()
            }
            engine.inputNode.removeTap(onBus: 0)
            engine.reset()
        }
        try startMicrophoneAudio()
    }
    
    private func startMicrophoneAudio() throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async {
                        try? self?.startMicrophoneAudio()
                    }
                }
            }
            return
        } else if status == .denied || status == .restricted {
            let err = NSError(domain: "AudioCaptureEngine", code: -3, userInfo: [NSLocalizedDescriptionKey: "Microphone permission is denied in System Settings"])
            throw err
        }

        let engine = stateLock.withLock { audioEngine ?? AVAudioEngine() }
        let inputNode = engine.inputNode
        
        // Remove any existing tap to avoid crash
        inputNode.removeTap(onBus: 0)
        
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            let err = NSError(domain: "AudioCaptureEngine", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid microphone audio format"])
            throw err
        }
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] (buffer, time) in
            guard let self = self, self.isRunning else { return }
            
            let level = self.calculateRMS(from: buffer)
            self.updateMyAudioLevel(level)
            
            self.delegate?.audioCaptureDidOutputMyAudio(pcmBuffer: buffer)
        }
        
        engine.prepare()
        if !engine.isRunning {
            try engine.start()
        }
        
        stateLock.withLock { self.audioEngine = engine }
        
        NSLog("[AudioCapture] Microphone audio capture active: \(format.sampleRate)Hz, \(format.channelCount)ch")
    }
    
    // MARK: - Buffer Conversion Helper
    
    public static func convertSampleBufferToPCM(sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return nil }
        var sbd = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &sbd) else { return nil }
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples)) else { return nil }
        pcm.frameLength = AVAudioFrameCount(numSamples)
        
        var abl = AudioBufferList()
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &block
        )
        if status == noErr, let src = abl.mBuffers.mData, let dst = pcm.floatChannelData?[0] {
            memcpy(dst, src, Int(abl.mBuffers.mDataByteSize))
            return pcm
        }
        return nil
    }
    
    // MARK: - Audio Level Calculations
    
    private func calculateRMS(from sampleBuffer: CMSampleBuffer) -> Float {
        var abl = AudioBufferList()
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &block
        )
        guard status == noErr, let src = abl.mBuffers.mData else { return 0 }
        let byteSize = Int(abl.mBuffers.mDataByteSize)
        let floatCount = byteSize / MemoryLayout<Float>.size
        guard floatCount > 0 else { return 0 }
        
        let floats = src.bindMemory(to: Float.self, capacity: floatCount)
        var sum: Float = 0
        let count = min(floatCount, 1024)
        for i in 0..<count {
            let sample = floats[i]
            sum += sample * sample
        }
        return sqrt(sum / Float(count))
    }
    
    private func calculateRMS(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        
        var sum: Float = 0
        let count = min(frameCount, 1024)
        for i in 0..<count {
            let sample = channelData[i]
            sum += sample * sample
        }
        return sqrt(sum / Float(count))
    }
    
    private func updateCallerAudioLevel(_ rawLevel: Float) {
        let boosted = min(1.0, rawLevel * 12.0)
        let newLevel = stateLock.withLock { () -> Float in
            smoothedCallerLevel = (smoothedCallerLevel * 0.7) + (boosted * 0.3)
            return smoothedCallerLevel
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            NotificationCenter.default.post(name: NSNotification.Name("CallerAudioLevelUpdated"), object: nil, userInfo: ["level": newLevel])
            self.delegate?.audioCaptureDidUpdateCallerLevel(newLevel)
        }
    }
    
    private func updateMyAudioLevel(_ rawLevel: Float) {
        let boosted = min(1.0, rawLevel * 12.0)
        let newLevel = stateLock.withLock { () -> Float in
            smoothedMyLevel = (smoothedMyLevel * 0.7) + (boosted * 0.3)
            return smoothedMyLevel
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.audioCaptureDidUpdateMyLevel(newLevel)
        }
    }
}
