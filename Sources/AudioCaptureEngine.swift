import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import AppKit

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
    public weak var delegate: AudioCaptureDelegate?
    public private(set) var currentMode: AudioSourceMode = .bidirectional
    public private(set) var isRunning: Bool = false
    
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
        
        audioRecoveryWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self, self.isRunning else { return }
            do {
                NSLog("[AudioCaptureEngine] Re-attaching microphone tap with active call hardware format...")
                try self.restartMicrophoneAudio()
            } catch {
                NSLog("[AudioCaptureEngine] Microphone recovery error: \(error)")
            }
        }
        audioRecoveryWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }
    
    private func startWatchdog() {
        DispatchQueue.main.async { [weak self] in
            self?.watchdogTimer?.invalidate()
            self?.watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                guard let self = self, self.isRunning else { return }
                if self.currentMode == .bidirectional || self.currentMode == .micOnly {
                    if let engine = self.audioEngine, !engine.isRunning {
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
        if isStartingEngine { return }
        isStartingEngine = true
        defer { isStartingEngine = false }
        
        stop()
        self.currentMode = mode
        
        var startedAny = false
        var errors: [String] = []
        
        // 1. Start Microphone (Your voice)
        if mode == .bidirectional || mode == .micOnly {
            do {
                try startMicrophoneAudio()
                startedAny = true
                self.isRunning = true
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
                self.isRunning = true
                NSLog("[AudioCaptureEngine] System Call Audio started successfully")
            } catch {
                NSLog("[AudioCaptureEngine] System Call Audio failed: \(error)")
                errors.append("Call Audio: \(error.localizedDescription)")
            }
        }
        
        if !startedAny && !errors.isEmpty {
            self.isRunning = false
            let err = NSError(domain: "AudioCaptureEngine", code: -99, userInfo: [NSLocalizedDescriptionKey: errors.joined(separator: "\n")])
            throw err
        }
        
        self.isRunning = startedAny
        if startedAny {
            startWatchdog()
        }
    }
    
    public func stop() {
        isRunning = false
        stopWatchdog()
        audioRecoveryWorkItem?.cancel()
        
        // Stop ScreenCaptureKit
        if let stream = scStream {
            stream.stopCapture { _ in }
            scStream = nil
        }
        
        // Stop AVAudioEngine
        if let engine = audioEngine {
            if engine.isRunning {
                engine.stop()
            }
            engine.inputNode.removeTap(onBus: 0)
            audioEngine = nil
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
        self.scStream = stream
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
        if isRunning && (currentMode == .bidirectional || currentMode == .callerOnly) {
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                try? await self.startScreenCaptureAudio()
            }
        }
    }
    
    // MARK: - Microphone Implementation (Your Voice)
    
    public func restartMicrophoneAudio() throws {
        if let engine = audioEngine {
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

        let engine = audioEngine ?? AVAudioEngine()
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
        self.audioEngine = engine
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
        smoothedCallerLevel = (smoothedCallerLevel * 0.7) + (boosted * 0.3)
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.audioCaptureDidUpdateCallerLevel(self.smoothedCallerLevel)
        }
    }
    
    private func updateMyAudioLevel(_ rawLevel: Float) {
        let boosted = min(1.0, rawLevel * 12.0)
        smoothedMyLevel = (smoothedMyLevel * 0.7) + (boosted * 0.3)
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.audioCaptureDidUpdateMyLevel(self.smoothedMyLevel)
        }
    }
}
