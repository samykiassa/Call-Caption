import Foundation
import CoreAudio
import AudioToolbox
@preconcurrency import AVFoundation
import Accelerate
import os
import Synchronization

enum AudioCaptureError: LocalizedError, Sendable {
    case pidResolutionFailed(OSStatus)
    case tapPermissionRequired(OSStatus)
    case processTapFailed(OSStatus)
    case aggregateDeviceFailed(OSStatus)
    case unsupportedTapFormat(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case microphonePermissionDenied
    case microphoneUnavailable(reason: String?)

    var isMicrophoneError: Bool {
        switch self {
        case .microphonePermissionDenied, .microphoneUnavailable:
            return true
        case .pidResolutionFailed, .tapPermissionRequired, .processTapFailed, .aggregateDeviceFailed,
             .unsupportedTapFormat, .ioProcCreationFailed, .deviceStartFailed:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .pidResolutionFailed:
            return AppL10n.string("audio.error.pid_resolve", fallback: "Could not initialize system audio capture")
        case .tapPermissionRequired(let status):
            return AppL10n.format(
                "audio.error.tap_permission_status",
                fallback: "System Audio Recording permission required (code %ld)",
                Int(status)
            )
        case .processTapFailed(let status):
            return AppL10n.format(
                "audio.error.process_tap",
                fallback: "Could not start system audio capture (code %ld)",
                Int(status)
            )
        case .aggregateDeviceFailed:
            return AppL10n.string("audio.error.aggregate_create", fallback: "Could not configure system audio device")
        case .unsupportedTapFormat:
            return AppL10n.string("audio.error.tap_format", fallback: "Unsupported system audio format")
        case .ioProcCreationFailed:
            return AppL10n.string("audio.error.io_proc", fallback: "Could not start system audio stream")
        case .deviceStartFailed(let status):
            return AppL10n.format(
                "audio.error.device_start",
                fallback: "Could not start audio device (code %ld)",
                Int(status)
            )
        case .microphonePermissionDenied:
            return AppL10n.string(
                "alert.mic_permission",
                fallback: "Microphone permission is off. Enable Call Caption under Microphone in System Settings."
            )
        case .microphoneUnavailable(let reason):
            if let reason, !reason.isEmpty {
                return AppL10n.format("audio.error.mic_unavailable_reason", fallback: "Microphone unavailable (%@)", reason)
            }
            return AppL10n.string("audio.error.mic_unavailable", fallback: "Microphone unavailable")
        }
    }
}

protocol AudioCaptureDelegate: AnyObject, Sendable {
    func audioCaptureDidOutputCallerAudio(pcmBuffer: AVAudioPCMBuffer)
    func audioCaptureDidOutputMicAudio(pcmBuffer: AVAudioPCMBuffer)
    func audioCaptureDidUpdateLevels(callerLevel: Float, micLevel: Float)
    func audioCaptureDidEncounterError(_ error: Error)
    func audioCaptureDidDetectDeniedTapPermission()
    func audioCaptureDidRestoreTapPermission()
    func audioCaptureDidRecoverTap()
    func audioCaptureDidDetectDeniedMicPermission()
    func audioCaptureDidEncounterMicError(_ error: Error)
    func audioCaptureDidRestoreMic()
}

extension AudioCaptureDelegate {
    func audioCaptureDidRecoverTap() {}
    func audioCaptureDidDetectDeniedMicPermission() {}
    func audioCaptureDidEncounterMicError(_ error: Error) {
        audioCaptureDidEncounterError(error)
    }
    func audioCaptureDidRestoreMic() {}
}

enum SpeechFloorOwner: String, Sendable, Equatable {
    case none
    case caller
    case user
}

final class AudioCaptureEngine: NSObject, @unchecked Sendable {
    private struct SendablePCMBuffer: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }

    private struct Box<Value>: @unchecked Sendable {
        let value: Value
    }

    private final class AtomicBox<Value: AtomicRepresentable>: @unchecked Sendable {
        let atomic: Atomic<Value>
        init(_ initialValue: Value) { self.atomic = Atomic<Value>(initialValue) }
    }

    /// Lock-free Single-Producer Single-Consumer ring buffer for CoreAudio IOProc -> callerQueue handoff.
    private final class CallerAudioRingBuffer: @unchecked Sendable {
        let capacity: Int
        private let mask: Int
        private let buffer: UnsafeMutablePointer<Float>
        private let head = Atomic<Int>(0)
        private let tail = Atomic<Int>(0)

        init(capacityPowerOfTwo minCount: Int) {
            var cap = 1024
            while cap < minCount { cap <<= 1 }
            self.capacity = cap
            self.mask = cap - 1
            self.buffer = UnsafeMutablePointer<Float>.allocate(capacity: cap)
            self.buffer.initialize(repeating: 0.0, count: cap)
        }

        deinit {
            buffer.deinitialize(count: capacity)
            buffer.deallocate()
        }

        @inline(__always)
        func write(samples: UnsafePointer<Float>, count: Int) -> (wrote: Bool, buffered: Int) {
            guard count > 0, count <= capacity else { return (false, 0) }
            let currentTail = tail.load(ordering: .relaxed)
            let currentHead = head.load(ordering: .acquiring)
            let currentlyBuffered = currentTail &- currentHead
            guard count <= (capacity &- currentlyBuffered) else { return (false, currentlyBuffered) }

            let writeOffset = currentTail & mask
            let firstPart = min(count, capacity - writeOffset)
            buffer.advanced(by: writeOffset).update(from: samples, count: firstPart)
            let secondPart = count - firstPart
            if secondPart > 0 {
                buffer.update(from: samples.advanced(by: firstPart), count: secondPart)
            }
            let newTail = currentTail &+ count
            tail.store(newTail, ordering: .releasing)
            return (true, currentlyBuffered &+ count)
        }

        @inline(__always)
        func availableToRead() -> Int {
            let currentHead = head.load(ordering: .relaxed)
            let currentTail = tail.load(ordering: .acquiring)
            return currentTail &- currentHead
        }

        @inline(__always)
        func read(into dst: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
            guard maxCount > 0 else { return 0 }
            let available = availableToRead()
            guard available > 0 else { return 0 }
            let currentHead = head.load(ordering: .relaxed)
            let count = min(available, maxCount)
            let readOffset = currentHead & mask
            let firstPart = min(count, capacity - readOffset)
            dst.update(from: buffer.advanced(by: readOffset), count: firstPart)
            let secondPart = count - firstPart
            if secondPart > 0 {
                dst.advanced(by: firstPart).update(from: buffer, count: secondPart)
            }
            head.store(currentHead &+ count, ordering: .releasing)
            return count
        }
    }

    private final class RawFloatScratch: @unchecked Sendable {
        let ptr: UnsafeMutablePointer<Float>
        let capacity: Int

        init(capacity: Int) {
            let cap = max(1, capacity)
            self.capacity = cap
            self.ptr = UnsafeMutablePointer<Float>.allocate(capacity: cap)
            self.ptr.initialize(repeating: 0.0, count: cap)
        }

        deinit {
            ptr.deinitialize(count: capacity)
            ptr.deallocate()
        }
    }

    private final class MicScratchPool: @unchecked Sendable {
        let buffers: [AVAudioPCMBuffer]
        private let freeMask: Atomic<UInt32>

        init(format: AVAudioFormat, frameCapacity: AVAudioFrameCount, poolSize: Int = 16) {
            let clamped = min(31, max(1, poolSize))
            self.buffers = (0..<clamped).compactMap { _ in
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)
            }
            let mask: UInt32 = buffers.isEmpty ? 0 : ((UInt32(1) << buffers.count) - 1)
            self.freeMask = Atomic<UInt32>(mask)
        }

        @inline(__always)
        func acquireSlot() -> Int? {
            var current = freeMask.load(ordering: .acquiring)
            while current != 0 {
                let index = current.trailingZeroBitCount
                let (exchanged, original) = freeMask.compareExchange(
                    expected: current,
                    desired: current & ~(UInt32(1) << index),
                    successOrdering: .acquiringAndReleasing,
                    failureOrdering: .acquiring
                )
                if exchanged { return index }
                current = original
            }
            return nil
        }

        @inline(__always)
        func releaseSlot(_ index: Int) {
            guard index >= 0, index < buffers.count else { return }
            _ = freeMask.bitwiseOr(UInt32(1) << index, ordering: .releasing)
        }
    }

    static let speechFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    private let stateLock = OSAllocatedUnfairLock()
    private let lifecycleLock = NSLock()
    private let micLifecycleLock = NSLock()
    private weak var _delegate: AudioCaptureDelegate?
    var delegate: AudioCaptureDelegate? {
        get { stateLock.withLock { _delegate } }
        set { stateLock.withLock { _delegate = newValue } }
    }

    private let callerQueue = DispatchQueue(label: "com.callcaption.callerAudio", qos: .userInitiated)
    private let callerQueueKey = DispatchSpecificKey<Void>()
    private let micQueue = DispatchQueue(label: "com.callcaption.micAudio", qos: .userInitiated)

    // CoreAudio System Tap state
    private var tapObjectID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ownProcessObjectID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var callerWakeSource: DispatchSourceUserDataAdd?
    private var callerRingBuffer: CallerAudioRingBuffer?
    private let callerTimestampAtomic = AtomicBox<Double>(0.0)
    private let callerIdleSilentFastPath = AtomicBox<Bool>(false)
    private var callerReusableSrcPCM: AVAudioPCMBuffer?
    private var callerMonoFormat: AVAudioFormat?
    private var callerConverter: AVAudioConverter?
    private var callerSpare16kBuffers: [AVAudioPCMBuffer] = []

    private var aggFormatListenerToken: AudioHALListenerToken?
    private var tapFormatListenerToken: AudioHALListenerToken?
    private var defaultOutputListenerToken: AudioHALListenerToken?
    private var defaultInputListenerToken: AudioHALListenerToken?
    private var serviceRestartedListenerToken: AudioHALListenerToken?
    private var monitoredOutputDeviceID: AudioObjectID = kAudioObjectUnknown
    private var outputDataSourceListenerToken: AudioHALListenerToken?
    private var isTornDownObservers = false

    private var _isRunning = false
    private var callerShouldBeEnabled = false
    private var captureGeneration: UInt64 = 0
    private var stopGeneration: UInt64 = 0
    private var isRebuildingTap = false
    private var tapRebuildPending = false
    private var tapRebuildGeneration: UInt64 = 0
    private var tapRebuildWorkItem: DispatchWorkItem?
    private var callerWatchdogTimer: DispatchSourceTimer?
    private var nextCallerRecoveryTime: TimeInterval = 0

    // Silence permission detection
    private var tapStartTime: TimeInterval = 0
    private var hasReceivedNonZeroCallerSignal = false
    private var hasEverReceivedNonZeroCallerSignal = false
    private var lastPermissionProbeTime: TimeInterval = 0
    private var silentOutputStartTime: TimeInterval = 0
    private var didReportDeniedTapPermission = false
    private var cachedOtherProcessAudioActive = false
    private var lastOtherProcessQueryTime: TimeInterval = 0
    private var isQueryingOtherProcessAudio = false

    // Caller VAD & pre-roll (callerQueue)
    private var isCallerActive = false
    private var callerConsecutiveVoiceSamples = 0
    private var lastCallerSpeechTime: TimeInterval = 0
    private var callerPreRoll = RingBuffer<AVAudioPCMBuffer>()
    private var callerPreRollFrames: AVAudioFrameCount = 0
    private var callerSilentPreRollFrames: AVAudioFrameCount = 0

    // Mic Engine state
    private var micAudioEngine: AVAudioEngine?
    private var observedMicEngine: AVAudioEngine?
    private var micWakeSource: DispatchSourceUserDataAdd?
    private var micRingBuffer: CallerAudioRingBuffer?
    private var micReusableSrcPCM: AVAudioPCMBuffer?
    private var micMonoFormat: AVAudioFormat?
    private var micSpare16kBuffers: [AVAudioPCMBuffer] = []
    private var micShouldBeEnabled = false
    private var _isMicRunning = false
    private var isStartingMic = false
    private var isRequestingMicPermission = false
    private var isRecoveringMic = false
    private var pendingMicConfigChange = false
    private var micRecoveryFailures = 0
    private var nextMicRecoveryTime: TimeInterval = 0
    private var micStartTime: TimeInterval = 0
    private var micRecoveryWorkItem: DispatchWorkItem?
    private var micRecoveryGeneration: UInt64 = 0
    private var micSessionGeneration: UInt64 = 0
    private var micWatchdogTimer: DispatchSourceTimer?
    private var micConverter: AVAudioConverter?
    private var isMicActive = false
    private var micConsecutiveVoiceSamples = 0
    private var lastMicSpeechTime: TimeInterval = 0
    private var micPreRoll = RingBuffer<(buffer: AVAudioPCMBuffer, startTime: TimeInterval)>()
    private var micPreRollFrames: AVAudioFrameCount = 0
    private var micSilentPreRollFrames: AVAudioFrameCount = 0
    private var micRawNoiseFloor: Float = 0
    private var micNoiseFloorGen: UInt64 = 0

    private let atomicMicTapArmed = AtomicBox<Bool>(false)
    private let atomicIsMicRunning = Atomic<Bool>(false)
    private let atomicLastMicBufferTime = AtomicBox<Double>(0.0)
    private let atomicBestMicChannel = AtomicBox<Int>(0)

    private struct FallbackConverterCache: @unchecked Sendable {
        var converter: AVAudioConverter?
        var inputFormat: AVAudioFormat?
        var outputFormat: AVAudioFormat?
        var preferredChannel: Int = 0
    }
    private let fallbackConverterLock = OSAllocatedUnfairLock(initialState: FallbackConverterCache())

    // Cross-channel echo & floor state (stateLock)
    private var rawCallerRMS: Float = 0.0
    private var lastCallerVoiceTime: TimeInterval = 0
    private var isCallerCurrentlySpeaking = false
    private var isMicCurrentlySpeaking = false
    private var callerHoldsVoice = false
    private var userHoldsVoice = false
    private var floorOwner: SpeechFloorOwner = .none
    private var smoothedCallerLevel: Float = 0.0
    private var smoothedMicLevel: Float = 0.0
    private var lastDispatchedCallerLevel: Float = -1
    private var lastDispatchedMicLevel: Float = -1
    private var lastLevelDispatchTime: TimeInterval = 0
    private var levelMeteringVisible: Bool = true

    private static let callerSpeechThreshold: Float = 0.0055
    private static let micSpeechThreshold: Float = 0.009
    private static let callerHangover: TimeInterval = 0.70
    private static let micHangover: TimeInterval = 0.65
    private static let echoTailWindow: TimeInterval = 0.55
    private static let maxPreRollFrames: AVAudioFrameCount = 8000 // ~0.5s at 16kHz
    private static let callerOnsetSamples: Int = 560       // 35ms at 16kHz
    private static let micNormalOnsetSamples: Int = 640    // 40ms at 16kHz
    private static let micHeavyEchoOnsetSamples: Int = 960 // 60ms at 16kHz

    // Acoustic isolation & output volume cache
    private struct IsolationState {
        var overrideValue: Bool?
        var cached = false
        var primed = false
        var refreshing = false
        var outputVolume: Float = 0.5
        var lastVolumeRefreshTime: TimeInterval = 0
        var refreshingVolume = false
    }
    private static let isolationState = OSAllocatedUnfairLock(initialState: IsolationState())
    private static let isolationQueue = DispatchQueue(label: "com.callcaption.isolation", qos: .utility)

    static var overrideAcousticIsolation: Bool? {
        get { isolationState.withLock { $0.overrideValue } }
        set { isolationState.withLock { $0.overrideValue = newValue } }
    }

    var isRunning: Bool { stateLock.withLock { _isRunning } }
    var isMicRunning: Bool { atomicIsMicRunning.load(ordering: .relaxed) }
    var speechFloorOwner: SpeechFloorOwner { stateLock.withLock { floorOwner } }
    var isUserSpeaking: Bool { stateLock.withLock { isMicCurrentlySpeaking || userHoldsVoice || floorOwner == .user } }

    override init() {
        super.init()
        callerQueue.setSpecific(key: callerQueueKey, value: ())
    }

    deinit {
        teardownHardwareObservers()
        stop(isDeallocating: true)
    }

    static func resolveFloorOwner(
        current: SpeechFloorOwner,
        isCallerActive: Bool,
        isUserActive: Bool
    ) -> SpeechFloorOwner {
        if isUserActive { return .user }
        if isCallerActive { return .caller }
        return .none
    }

    static func echoTailDecay(after elapsed: TimeInterval) -> Float {
        guard elapsed > 0 else { return 1.0 }
        return Float(exp(-elapsed / 0.25))
    }

    static func computeRMS(samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0.0 }
        var rms: Float = 0.0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
        return rms.isFinite ? rms : 0.0
    }

    // MARK: - Lifecycle

    func start(enableMic: Bool = false) throws {
        let initialRebuild = stateLock.withLock { () -> Box<DispatchWorkItem>? in
            tapRebuildGeneration &+= 1
            isRebuildingTap = false
            tapRebuildPending = false
            let item = tapRebuildWorkItem.map { Box(value: $0) }
            tapRebuildWorkItem = nil
            return item
        }
        initialRebuild?.value.cancel()

        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        let (entryStopGen, pendingRebuild) = stateLock.withLock { () -> (UInt64, Box<DispatchWorkItem>?) in
            callerShouldBeEnabled = true
            tapRebuildGeneration &+= 1
            isRebuildingTap = false
            tapRebuildPending = false
            lastDispatchedCallerLevel = -1
            lastDispatchedMicLevel = -1
            let item = tapRebuildWorkItem.map { Box(value: $0) }
            tapRebuildWorkItem = nil
            return (stopGeneration, item)
        }
        pendingRebuild?.value.cancel()

        stopMicrophone()
        tearDownCallerTapOnly(isStoppingPermanently: false)

        guard stateLock.withLock({ stopGeneration == entryStopGen && callerShouldBeEnabled }) else { return }

        ensureHardwareObserversInstalled()

        do {
            try startCallerTapPipeline(entryStopGen: entryStopGen)
        } catch {
            let keepWatchdog = stateLock.withLock { callerShouldBeEnabled && stopGeneration == entryStopGen }
            if keepWatchdog && PermissionHelper.shared.audioCaptureState != .deniedSilenceDetected {
                startCallerWatchdog()
            } else if !keepWatchdog {
                pauseHardwareObservers(permanently: false)
            }
            throw error
        }

        if enableMic {
            setMicrophoneEnabled(true)
        }
    }

    func stop() {
        stop(isDeallocating: false)
    }

    private func stop(isDeallocating: Bool) {
        let items = stateLock.withLock { () -> (Box<DispatchWorkItem>?, Box<DispatchWorkItem>?) in
            stopGeneration &+= 1
            captureGeneration &+= 1
            callerShouldBeEnabled = false
            micShouldBeEnabled = false
            hasEverReceivedNonZeroCallerSignal = false
            isRebuildingTap = false
            tapRebuildPending = false
            pendingMicConfigChange = false
            lastDispatchedCallerLevel = -1
            lastDispatchedMicLevel = -1
            tapRebuildGeneration &+= 1
            micRecoveryGeneration &+= 1
            let t = tapRebuildWorkItem.map { Box(value: $0) }
            let m = micRecoveryWorkItem.map { Box(value: $0) }
            tapRebuildWorkItem = nil
            micRecoveryWorkItem = nil
            return (t, m)
        }
        items.0?.value.cancel()
        items.1?.value.cancel()

        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        stateLock.withLock {
            stopGeneration &+= 1
            captureGeneration &+= 1
            callerShouldBeEnabled = false
            micShouldBeEnabled = false
            isRebuildingTap = false
            tapRebuildPending = false
            pendingMicConfigChange = false
            lastDispatchedCallerLevel = -1
            lastDispatchedMicLevel = -1
        }
        stopMicrophone(isDeallocating: isDeallocating)
        tearDownCallerTapOnly(isStoppingPermanently: true, isDeallocating: isDeallocating)
        pauseHardwareObservers(permanently: isDeallocating)
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        if enabled {
            let shouldStart = stateLock.withLock { () -> Bool in
                guard callerShouldBeEnabled else { return false }
                micShouldBeEnabled = true
                micRecoveryFailures = 0
                nextMicRecoveryTime = 0
                return true
            }
            guard shouldStart else { return }
            if auth == .authorized || auth == .notDetermined {
                startMicWatchdog()
            }
            if !isMicRunning {
                do {
                    try startMicrophone()
                } catch {
                    recordMicFailure(reason: error.localizedDescription, notifyImmediately: true)
                }
            }
        } else {
            stopMicrophone()
        }
    }

    // MARK: - CoreAudio System Audio Tap

    private func startCallerTapPipeline(entryStopGen: UInt64) throws {
        guard stateLock.withLock({ callerShouldBeEnabled && stopGeneration == entryStopGen }) else { return }

        var ownPID = ProcessInfo.processInfo.processIdentifier
        var resolvedOwnObjID: AudioObjectID = kAudioObjectUnknown
        var propSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var pidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let pidStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &pidAddr,
            UInt32(MemoryLayout<pid_t>.size),
            &ownPID,
            &propSize,
            &resolvedOwnObjID
        )
        guard pidStatus == noErr else {
            throw AudioCaptureError.pidResolutionFailed(pidStatus)
        }

        let excludedProcesses: [AudioObjectID] = resolvedOwnObjID != kAudioObjectUnknown ? [resolvedOwnObjID] : []
        let tapDesc = CATapDescription(monoGlobalTapButExcludeProcesses: excludedProcesses)
        tapDesc.name = "CallCaptionSystemAudioTap"
        tapDesc.uuid = UUID()
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .unmuted

        var newTapID: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &newTapID)
        guard tapStatus == noErr else {
            if tapStatus == OSStatus(kAudioDevicePermissionsError) || tapStatus == -60005 {
                stateLock.withLock { didReportDeniedTapPermission = true }
                PermissionHelper.shared.updateAudioCaptureState(.deniedSilenceDetected)
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.audioCaptureDidDetectDeniedTapPermission()
                }
                throw AudioCaptureError.tapPermissionRequired(tapStatus)
            }
            throw AudioCaptureError.processTapFailed(tapStatus)
        }

        guard stateLock.withLock({ callerShouldBeEnabled && stopGeneration == entryStopGen }) else {
            _ = AudioHardwareDestroyProcessTap(newTapID)
            return
        }

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CallCaptionTapAggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]

        var newAggID: AudioObjectID = kAudioObjectUnknown
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &newAggID)
        guard aggStatus == noErr else {
            _ = AudioHardwareDestroyProcessTap(newTapID)
            throw AudioCaptureError.aggregateDeviceFailed(aggStatus)
        }

        var asbd = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let formatStatus = AudioObjectGetPropertyData(newAggID, &formatAddress, 0, nil, &formatSize, &asbd)
        guard formatStatus == noErr,
              asbd.mSampleRate.isFinite,
              asbd.mSampleRate > 0,
              let avFormat = AVAudioFormat(streamDescription: &asbd),
              avFormat.sampleRate.isFinite,
              avFormat.sampleRate > 0,
              asbd.mFormatID == kAudioFormatLinearPCM,
              (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              asbd.mBitsPerChannel == 32,
              asbd.mChannelsPerFrame == 1,
              asbd.mBytesPerFrame == MemoryLayout<Float>.size else {
            _ = AudioHardwareDestroyAggregateDevice(newAggID)
            _ = AudioHardwareDestroyProcessTap(newTapID)
            throw AudioCaptureError.unsupportedTapFormat(formatStatus)
        }

        let sampleRate = avFormat.sampleRate
        let ringBuffer = CallerAudioRingBuffer(capacityPowerOfTwo: max(4096, Int(sampleRate * 2.0)))
        let wakeBatchFrames = max(256, min(4096, Int(sampleRate * 0.03))) // ~30ms batch coalescing
        let pendingGen = stateLock.withLock { () -> UInt64 in
            captureGeneration &+= 1
            return captureGeneration
        }

        let wakeSource = DispatchSource.makeUserDataAddSource(queue: callerQueue)
        let tsAtomic = callerTimestampAtomic
        let idleFastPathAtomic = callerIdleSilentFastPath
        idleFastPathAtomic.atomic.store(false, ordering: .releasing)
        wakeSource.setEventHandler { [weak self, ringBuffer] in
            self?.drainCallerRingBuffer(
                ringBuffer: ringBuffer,
                sampleRate: sampleRate,
                expectedGen: pendingGen,
                minBatchFrames: wakeBatchFrames
            )
        }

        var newProcID: AudioDeviceIOProcID?
        let bytesPerFrame = asbd.mBytesPerFrame > 0 ? asbd.mBytesPerFrame : 4
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, newAggID, nil) { _, inInputData, _, _, _ in
            tsAtomic.atomic.store(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9, ordering: .relaxed)
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard let first = abl.first, let src = first.mData else { return }
            let frameCount = Int(first.mDataByteSize) / Int(bytesPerFrame)
            guard frameCount > 0 else { return }
            let floatPtr = src.assumingMemoryBound(to: Float.self)
            if idleFastPathAtomic.atomic.load(ordering: .relaxed) {
                var peak: Float = 0.0
                vDSP_maxmgv(floatPtr, 1, &peak, vDSP_Length(frameCount))
                if peak <= 1e-6 {
                    return
                }
                idleFastPathAtomic.atomic.store(false, ordering: .relaxed)
            }
            let (wrote, buffered) = ringBuffer.write(samples: floatPtr, count: frameCount)
            if !wrote || buffered >= wakeBatchFrames {
                wakeSource.add(data: 1)
            }
        }

        guard ioStatus == noErr, let procID = newProcID else {
            wakeSource.setEventHandler {}
            wakeSource.cancel()
            wakeSource.resume()
            _ = AudioHardwareDestroyAggregateDevice(newAggID)
            _ = AudioHardwareDestroyProcessTap(newTapID)
            throw AudioCaptureError.ioProcCreationFailed(ioStatus)
        }

        tsAtomic.atomic.store(0.0, ordering: .relaxed)
        let startStatus = AudioDeviceStart(newAggID, procID)
        guard startStatus == noErr else {
            wakeSource.setEventHandler {}
            wakeSource.cancel()
            wakeSource.resume()
            _ = AudioDeviceDestroyIOProcID(newAggID, procID)
            _ = AudioHardwareDestroyAggregateDevice(newAggID)
            _ = AudioHardwareDestroyProcessTap(newTapID)
            throw AudioCaptureError.deviceStartFailed(startStatus)
        }

        let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9
        let committedTapID = newTapID
        let committedAggID = newAggID
        let committedOwnObjID = resolvedOwnObjID
        let committed = stateLock.withLock { () -> Bool in
            guard callerShouldBeEnabled, stopGeneration == entryStopGen, captureGeneration == pendingGen else { return false }
            tapObjectID = committedTapID
            aggregateDeviceID = committedAggID
            ownProcessObjectID = committedOwnObjID
            ioProcID = procID
            callerWakeSource = wakeSource
            callerRingBuffer = ringBuffer
            _isRunning = true
            tapStartTime = now
            hasReceivedNonZeroCallerSignal = false
            lastPermissionProbeTime = now
            silentOutputStartTime = 0
            didReportDeniedTapPermission = false
            return true
        }

        guard committed else {
            wakeSource.setEventHandler {}
            wakeSource.cancel()
            wakeSource.resume()
            _ = AudioDeviceStop(newAggID, procID)
            _ = AudioDeviceDestroyIOProcID(newAggID, procID)
            _ = AudioHardwareDestroyAggregateDevice(newAggID)
            _ = AudioHardwareDestroyProcessTap(newTapID)
            return
        }

        wakeSource.resume()
        installTapFormatListeners(aggID: newAggID, tapID: newTapID, expectedGen: pendingGen)
        startCallerWatchdog()
        AppLog.audio.info("System audio tap started (\(sampleRate, privacy: .public)Hz)")
    }

    private func tearDownCallerTapOnly(isStoppingPermanently: Bool, isDeallocating: Bool = false) {
        stopCallerWatchdog()

        let (tapID, aggID, procID, wakeSource, rebuildItem, teardownGen) = stateLock.withLock {
            () -> (AudioObjectID, AudioObjectID, AudioDeviceIOProcID?, DispatchSourceUserDataAdd?, Box<DispatchWorkItem>?, UInt64) in
            captureGeneration &+= 1
            let gen = captureGeneration
            _isRunning = false
            var rItem: Box<DispatchWorkItem>?
            if isStoppingPermanently {
                callerShouldBeEnabled = false
                isRebuildingTap = false
                tapRebuildPending = false
                tapRebuildGeneration &+= 1
                rItem = tapRebuildWorkItem.map { Box(value: $0) }
                tapRebuildWorkItem = nil
            }
            rawCallerRMS = 0.0
            lastCallerVoiceTime = 0
            isCallerCurrentlySpeaking = false
            callerHoldsVoice = false
            floorOwner = Self.resolveFloorOwner(current: floorOwner, isCallerActive: false, isUserActive: userHoldsVoice)
            nextCallerRecoveryTime = 0
            smoothedCallerLevel = 0.0
            lastDispatchedCallerLevel = -1
            let t = tapObjectID; tapObjectID = kAudioObjectUnknown
            let a = aggregateDeviceID; aggregateDeviceID = kAudioObjectUnknown
            ownProcessObjectID = kAudioObjectUnknown
            let p = ioProcID; ioProcID = nil
            let w = callerWakeSource; callerWakeSource = nil
            callerRingBuffer = nil
            return (t, a, p, w, rItem, gen)
        }

        rebuildItem?.value.cancel()
        callerTimestampAtomic.atomic.store(0.0, ordering: .relaxed)
        callerIdleSilentFastPath.atomic.store(false, ordering: .releasing)
        removeTapFormatListeners()

        if let p = procID, aggID != kAudioObjectUnknown {
            _ = AudioDeviceStop(aggID, p)
            _ = AudioDeviceDestroyIOProcID(aggID, p)
        }
        wakeSource?.cancel()
        if aggID != kAudioObjectUnknown { _ = AudioHardwareDestroyAggregateDevice(aggID) }
        if tapID != kAudioObjectUnknown { _ = AudioHardwareDestroyProcessTap(tapID) }

        guard !isDeallocating else { return }
        let resetQueueState = {
            self.callerMonoFormat = nil
            self.callerReusableSrcPCM = nil
            self.callerConverter = nil
            self.callerSpare16kBuffers.removeAll(keepingCapacity: false)
            self.isCallerActive = false
            self.callerConsecutiveVoiceSamples = 0
            self.lastCallerSpeechTime = 0
            self.callerPreRoll.removeAll(keepingCapacity: false)
            self.callerPreRollFrames = 0
            self.callerSilentPreRollFrames = 0
            self.stateLock.withLock {
                guard self.captureGeneration == teardownGen, !self._isRunning else { return }
                self.rawCallerRMS = 0.0
                self.lastCallerVoiceTime = 0
                self.isCallerCurrentlySpeaking = false
                self.callerHoldsVoice = false
                self.floorOwner = Self.resolveFloorOwner(
                    current: self.floorOwner,
                    isCallerActive: false,
                    isUserActive: self.userHoldsVoice
                )
                self.smoothedCallerLevel = 0.0
                self.lastDispatchedCallerLevel = -1
            }
        }
        if DispatchQueue.getSpecific(key: callerQueueKey) != nil {
            resetQueueState()
        } else {
            callerQueue.sync(execute: resetQueueState)
        }
    }

    private func drainCallerRingBuffer(
        ringBuffer: CallerAudioRingBuffer,
        sampleRate: Double,
        expectedGen: UInt64,
        minBatchFrames: Int
    ) {
        let chunkCapacity = AVAudioFrameCount(max(2048, min(8192, Int(sampleRate * 0.05))))
        if callerMonoFormat == nil || callerMonoFormat?.sampleRate != sampleRate {
            callerMonoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
            callerReusableSrcPCM = nil
        }
        if callerReusableSrcPCM == nil || (callerReusableSrcPCM?.frameCapacity ?? 0) < chunkCapacity, let fmt = callerMonoFormat {
            callerReusableSrcPCM = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunkCapacity)
        }
        guard let srcPCM = callerReusableSrcPCM, let dst = srcPCM.floatChannelData?[0] else { return }

        while ringBuffer.availableToRead() >= minBatchFrames {
            let count = ringBuffer.read(into: dst, maxCount: Int(chunkCapacity))
            guard count > 0 else { break }
            srcPCM.frameLength = AVAudioFrameCount(count)
            guard processCallerAudioOnQueue(srcPCM, expectedGen: expectedGen) else { break }
        }
    }

    @discardableResult
    private func processCallerAudioOnQueue(_ srcPCM: AVAudioPCMBuffer, expectedGen: UInt64) -> Bool {
        let (entryValid, isMicSpeaking) = stateLock.withLock {
            (_isRunning && captureGeneration == expectedGen,
             isMicCurrentlySpeaking || userHoldsVoice || floorOwner == .user)
        }
        guard entryValid else { return false }
        guard srcPCM.frameLength > 0 else { return true }

        let srcChannels = Int(srcPCM.format.channelCount)
        if srcChannels == 1,
           !srcPCM.format.isInterleaved,
           srcPCM.format.commonFormat == .pcmFormatFloat32,
           let rawSamples = srcPCM.floatChannelData?[0] {
            var rawPeak: Float = 0.0
            vDSP_maxmgv(rawSamples, 1, &rawPeak, vDSP_Length(srcPCM.frameLength))
            if rawPeak.isFinite && rawPeak <= 1e-6 && !isCallerActive && callerConsecutiveVoiceSamples == 0 && callerSilentPreRollFrames >= Self.maxPreRollFrames {
                let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9
                let dt = Double(srcPCM.frameLength) / max(1.0, srcPCM.format.sampleRate)
                checkTapPermissionHealth(rms: 0.0, now: now, expectedGen: expectedGen)
                let emaAlpha = Float(min(1.0, max(0.05, dt / 0.04)))
                let (committed, levelsToDispatch, shouldArmIdleFastPath) = stateLock.withLock {
                    () -> (Bool, (Float, Float)?, Bool) in
                    guard _isRunning, captureGeneration == expectedGen else { return (false, nil, false) }
                    let decayed = rawCallerRMS * (1.0 - emaAlpha)
                    rawCallerRMS = decayed < 1e-7 ? 0.0 : decayed
                    isCallerCurrentlySpeaking = false
                    callerHoldsVoice = false
                    floorOwner = Self.resolveFloorOwner(current: floorOwner, isCallerActive: false, isUserActive: userHoldsVoice)
                    let levels = updateSmoothedLevelsLocked(callerRMS: 0.0, micRMS: nil, now: now)
                    let armIdle = (rawCallerRMS == 0.0 && smoothedCallerLevel == 0.0 && (hasEverReceivedNonZeroCallerSignal || didReportDeniedTapPermission))
                    return (true, levels, armIdle)
                }
                guard committed else { return false }
                if shouldArmIdleFastPath {
                    callerConverter?.reset()
                    callerIdleSilentFastPath.atomic.store(true, ordering: .releasing)
                }
                if let (c, m) = levelsToDispatch {
                    DispatchQueue.main.async { [weak self] in
                        self?.delegate?.audioCaptureDidUpdateLevels(callerLevel: c, micLevel: m)
                    }
                }
                return true
            }
        }

        guard let converted = convertTo16kMono(srcPCM, converter: &callerConverter, sparePool: &callerSpare16kBuffers),
              let samples = converted.floatChannelData?[0] else { return true }

        let samplesRead = Int(converted.frameLength)
        let dt = Double(samplesRead) / Self.speechFormat.sampleRate
        let rms = Self.computeRMS(samples: samples, count: samplesRead)
        let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9
        checkTapPermissionHealth(rms: rms, now: now, expectedGen: expectedGen)

        let isolated = Self.isAudioOutputAcousticallyIsolated()
        let threshold = (!isolated && isMicSpeaking) ? Self.callerSpeechThreshold * 2.0 : Self.callerSpeechThreshold

        let subFrameSize = 320 // 20ms at 16kHz
        var voiceDetected = false
        var offset = 0
        while offset < samplesRead {
            let subCount = min(subFrameSize, samplesRead - offset)
            let subRMS = (offset == 0 && subCount == samplesRead)
                ? rms
                : Self.computeRMS(samples: samples.advanced(by: offset), count: subCount)
            if subRMS >= threshold {
                callerConsecutiveVoiceSamples += subCount
                if isCallerActive || callerConsecutiveVoiceSamples >= Self.callerOnsetSamples {
                    voiceDetected = true
                }
            } else {
                callerConsecutiveVoiceSamples = 0
            }
            offset += subCount
        }

        var outputs: [AVAudioPCMBuffer] = []

        if voiceDetected {
            callerSilentPreRollFrames = 0
            if !isCallerActive {
                isCallerActive = true
                callerPreRoll.forEachEnumerated { _, buf in
                    outputs.append(buf)
                }
                callerPreRoll.removeAll(keepingCapacity: true)
                callerPreRollFrames = 0
            }
            lastCallerSpeechTime = now
            outputs.append(converted)
        } else if isCallerActive && (now - lastCallerSpeechTime) < Self.callerHangover {
            callerSilentPreRollFrames = 0
            outputs.append(converted)
        } else {
            isCallerActive = false
            appendPreRoll(converted, into: &callerPreRoll, totalFrames: &callerPreRollFrames, sparePool: &callerSpare16kBuffers)
            if rms <= 1e-6 && callerConsecutiveVoiceSamples == 0 {
                callerSilentPreRollFrames = min(Self.maxPreRollFrames, callerSilentPreRollFrames + converted.frameLength)
            } else {
                callerSilentPreRollFrames = 0
            }
        }

        let didDetectVoice = voiceDetected
        let speakingNow = isCallerActive && ((now - lastCallerSpeechTime) < 0.35)
        let callerHeld = didDetectVoice || (isCallerActive && ((now - lastCallerSpeechTime) < 0.20))
        let emaAlpha = Float(min(1.0, max(0.05, dt / 0.04)))
        let (committed, levelsToDispatch, currentDelegate) = stateLock.withLock {
            () -> (Bool, (Float, Float)?, AudioCaptureDelegate?) in
            guard _isRunning, captureGeneration == expectedGen else { return (false, nil, nil) }
            rawCallerRMS = (rawCallerRMS * (1.0 - emaAlpha)) + (rms * emaAlpha)
            if didDetectVoice { lastCallerVoiceTime = now }
            isCallerCurrentlySpeaking = speakingNow
            callerHoldsVoice = callerHeld
            floorOwner = Self.resolveFloorOwner(current: floorOwner, isCallerActive: callerHeld, isUserActive: userHoldsVoice)
            let levels = updateSmoothedLevelsLocked(callerRMS: rms, micRMS: nil, now: now)
            return (true, levels, _delegate)
        }
        guard committed else { return false }

        for pcm in outputs {
            currentDelegate?.audioCaptureDidOutputCallerAudio(pcmBuffer: pcm)
        }
        if let (c, m) = levelsToDispatch {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.audioCaptureDidUpdateLevels(callerLevel: c, micLevel: m)
            }
        }
        return true
    }

    // MARK: - Microphone Capture (Conversational Mode)

    func startMicrophone() throws {
        guard stateLock.withLock({ micShouldBeEnabled }) else { return }
        micLifecycleLock.lock()
        defer { micLifecycleLock.unlock() }
        guard stateLock.withLock({ micShouldBeEnabled }) else { return }

        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        if auth == .denied || auth == .restricted {
            stopMicWatchdog()
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.audioCaptureDidDetectDeniedMicPermission()
            }
            return
        }
        if auth == .notDetermined {
            let shouldAsk = stateLock.withLock { () -> Bool in
                guard !isRequestingMicPermission else { return false }
                isRequestingMicPermission = true
                return true
            }
            if shouldAsk {
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        guard let self else { return }
                        let keepEnabled = self.stateLock.withLock { () -> Bool in
                            self.isRequestingMicPermission = false
                            return self.micShouldBeEnabled
                        }
                        if granted && keepEnabled {
                            self.startMicWatchdog()
                            do {
                                try self.startMicrophone()
                            } catch {
                                self.recordMicFailure(reason: error.localizedDescription)
                            }
                        } else if !granted && keepEnabled {
                            self.stopMicWatchdog()
                            DispatchQueue.main.async { [weak self] in
                                self?.delegate?.audioCaptureDidDetectDeniedMicPermission()
                            }
                        } else if !granted {
                            self.stopMicWatchdog()
                        }
                    }
                }
            }
            return
        }

        stateLock.withLock { isStartingMic = true }
        defer {
            let retryPending = stateLock.withLock { () -> Bool in
                isStartingMic = false
                if pendingMicConfigChange && micShouldBeEnabled && !isRecoveringMic && !isRequestingMicPermission {
                    pendingMicConfigChange = false
                    return true
                }
                return false
            }
            if retryPending {
                scheduleMicRecovery(after: 0.35, resetBackoff: false)
            }
        }

        tearDownMicrophoneEngineOnly()
        guard Self.hasAvailableInputDevice() else {
            recordMicFailure(
                reason: AppL10n.string("audio.error.mic_no_input", fallback: "No audio input device available"),
                notifyImmediately: true
            )
            return
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let busFormat = inputNode.outputFormat(forBus: 0)
        guard busFormat.sampleRate.isFinite, busFormat.sampleRate > 0, busFormat.channelCount > 0,
              AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: busFormat.sampleRate, channels: 1, interleaved: false) != nil else {
            recordMicFailure(
                reason: AppL10n.string("audio.error.mic_invalid_format", fallback: "Invalid microphone format"),
                notifyImmediately: true
            )
            return
        }

        let canFastPathBus = !busFormat.isInterleaved && busFormat.commonFormat == .pcmFormatFloat32
        let scratchCap = max(AVAudioFrameCount(16384), AVAudioFrameCount(busFormat.sampleRate * 0.5))
        let rawChannelCount = Int(busFormat.channelCount)
        let busSampleRate = busFormat.sampleRate
        let sessionGen = stateLock.withLock { () -> UInt64 in
            micSessionGeneration &+= 1
            return micSessionGeneration
        }

        let fallbackPool: MicScratchPool? = canFastPathBus ? nil : MicScratchPool(format: busFormat, frameCapacity: scratchCap)
        let ringBuffer: CallerAudioRingBuffer?
        let downmixScratch: RawFloatScratch?
        let wakeSource: DispatchSourceUserDataAdd?
        let wakeBatchFrames = max(256, min(4096, Int(busSampleRate * 0.03)))
        if canFastPathBus {
            let rb = CallerAudioRingBuffer(capacityPowerOfTwo: max(8192, Int(busSampleRate * 2.0)))
            let ws = DispatchSource.makeUserDataAddSource(queue: micQueue)
            ws.setEventHandler { [weak self, rb] in
                self?.drainMicRingBuffer(
                    ringBuffer: rb,
                    sampleRate: busSampleRate,
                    expectedGen: sessionGen,
                    minBatchFrames: wakeBatchFrames,
                    sourceChannels: rawChannelCount
                )
            }
            ws.resume()
            ringBuffer = rb
            downmixScratch = RawFloatScratch(capacity: Int(scratchCap))
            wakeSource = ws
        } else {
            ringBuffer = nil
            downmixScratch = nil
            wakeSource = nil
        }

        let engineBox = Box(value: engine)
        let tapArmedBox = atomicMicTapArmed
        let lastMicTimeBox = atomicLastMicBufferTime
        let bestChannelBox = atomicBestMicChannel
        bestChannelBox.atomic.store(0, ordering: .relaxed)
        lastMicTimeBox.atomic.store(0.0, ordering: .relaxed)
        atomicIsMicRunning.store(false, ordering: .releasing)
        tapArmedBox.atomic.store(true, ordering: .releasing)

        do {
            try AudioTapHelper.installTap(on: inputNode, bus: 0, bufferSize: 2048, format: nil) { [weak self, fallbackPool] buffer, _ in
                guard tapArmedBox.atomic.load(ordering: .acquiring) else { return }
                lastMicTimeBox.atomic.store(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9, ordering: .relaxed)

                if let ring = ringBuffer,
                   let wake = wakeSource,
                   let scratch = downmixScratch,
                   !buffer.format.isInterleaved,
                   buffer.format.commonFormat == .pcmFormatFloat32,
                   abs(buffer.format.sampleRate - busSampleRate) < 1e-6,
                   buffer.frameLength > 0,
                   Int(buffer.frameLength) <= scratch.capacity,
                   buffer.format.channelCount > 0,
                   let src = buffer.floatChannelData {
                    let frames = buffer.frameLength
                    let countInt = Int(frames)
                    let channels = Int(buffer.format.channelCount)
                    let wroteResult: (wrote: Bool, buffered: Int)
                    if channels == 1 {
                        wroteResult = ring.write(samples: src[0], count: countInt)
                    } else if channels == 2 {
                        var half: Float = 0.5
                        vDSP_vasm(src[0], 1, src[1], 1, &half, scratch.ptr, 1, vDSP_Length(frames))
                        wroteResult = ring.write(samples: scratch.ptr, count: countInt)
                    } else {
                        let preferredCh = min(channels - 1, max(0, bestChannelBox.atomic.load(ordering: .relaxed)))
                        var bestCh = preferredCh
                        var bestRMS = Self.computeRMS(samples: src[bestCh], count: countInt)
                        for ch in 0..<channels where ch != preferredCh {
                            let r = Self.computeRMS(samples: src[ch], count: countInt)
                            if r > bestRMS * 1.15 && r > 0.0005 { bestRMS = r; bestCh = ch }
                        }
                        if bestCh != preferredCh { bestChannelBox.atomic.store(bestCh, ordering: .relaxed) }
                        wroteResult = ring.write(samples: src[bestCh], count: countInt)
                    }
                    if !wroteResult.wrote || wroteResult.buffered >= wakeBatchFrames {
                        wake.add(data: 1)
                    }
                    return
                }

                guard let self else { return }
                if let pool = fallbackPool, let slot = pool.acquireSlot() {
                    let scratch = pool.buffers[slot]
                    if Self.copyRawPCMBuffer(source: buffer, destination: scratch) {
                        let box = SendablePCMBuffer(buffer: scratch)
                        self.micQueue.async { [weak self, pool] in
                            defer { pool.releaseSlot(slot) }
                            _ = self?.processMicAudioOnQueue(box.buffer, expectedGen: sessionGen, sourceChannels: rawChannelCount)
                        }
                        return
                    }
                    pool.releaseSlot(slot)
                }

                // Mid-route-switch format mismatch or non-fast-path fallback: raw-copy only, deferring AVAudioConverter onto micQueue.
                guard let cloned = Self.cloneRawPCMBuffer(buffer) else { return }
                let box = SendablePCMBuffer(buffer: cloned)
                let bufferChannels = Int(buffer.format.channelCount)
                self.micQueue.async { [weak self] in
                    _ = self?.processMicAudioOnQueue(box.buffer, expectedGen: sessionGen, sourceChannels: bufferChannels)
                }
            }
        } catch {
            tapArmedBox.atomic.store(false, ordering: .releasing)
            atomicIsMicRunning.store(false, ordering: .releasing)
            wakeSource?.setEventHandler {}
            wakeSource?.cancel()
            let fallbackMsg = AppL10n.string(
                "audio.error.mic_tap_install",
                fallback: "Failed to install microphone audio tap"
            )
            throw NSError(
                domain: "AudioTapHelper",
                code: -1004,
                userInfo: [NSLocalizedDescriptionKey: fallbackMsg]
            )
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioEngineConfigChange(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
        stateLock.withLock {
            micAudioEngine = engineBox.value
            observedMicEngine = engineBox.value
            micWakeSource = wakeSource
            micRingBuffer = ringBuffer
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            tapArmedBox.atomic.store(false, ordering: .releasing)
            atomicIsMicRunning.store(false, ordering: .releasing)
            NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: engine)
            stateLock.withLock {
                micSessionGeneration &+= 1
                if micAudioEngine === engineBox.value { micAudioEngine = nil }
                if observedMicEngine === engineBox.value { observedMicEngine = nil }
                if micWakeSource === wakeSource { micWakeSource = nil }
                if micRingBuffer === ringBuffer { micRingBuffer = nil }
            }
            inputNode.removeTap(onBus: 0)
            wakeSource?.setEventHandler {}
            wakeSource?.cancel()
            throw error
        }

        let startedAt = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9
        let committed = stateLock.withLock { () -> Bool in
            guard micShouldBeEnabled, micSessionGeneration == sessionGen else { return false }
            _isMicRunning = true
            micStartTime = startedAt
            micRecoveryFailures = 0
            nextMicRecoveryTime = 0
            return true
        }
        guard committed else {
            tearDownMicrophoneEngineOnly()
            return
        }
        atomicIsMicRunning.store(true, ordering: .releasing)
        AppLog.audio.info("Microphone capture started (\(busFormat.sampleRate, privacy: .public)Hz, \(busFormat.channelCount, privacy: .public)ch)")
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.audioCaptureDidRestoreMic()
        }
    }

    func stopMicrophone() {
        stopMicrophone(isDeallocating: false)
    }

    private func stopMicrophone(isDeallocating: Bool) {
        micLifecycleLock.lock()
        defer { micLifecycleLock.unlock() }

        let oldItem = stateLock.withLock { () -> Box<DispatchWorkItem>? in
            micRecoveryGeneration &+= 1
            let item = micRecoveryWorkItem.map { Box(value: $0) }
            micRecoveryWorkItem = nil
            micShouldBeEnabled = false
            isRecoveringMic = false
            isStartingMic = false
            pendingMicConfigChange = false
            isMicCurrentlySpeaking = false
            userHoldsVoice = false
            floorOwner = Self.resolveFloorOwner(current: floorOwner, isCallerActive: callerHoldsVoice, isUserActive: false)
            micRecoveryFailures = 0
            nextMicRecoveryTime = 0
            smoothedMicLevel = 0.0
            lastDispatchedMicLevel = -1
            return item
        }
        oldItem?.value.cancel()
        stopMicWatchdog()
        tearDownMicrophoneEngineOnly(isDeallocating: isDeallocating)
    }

    private func tearDownMicrophoneEngineOnly(isDeallocating: Bool = false) {
        atomicMicTapArmed.atomic.store(false, ordering: .releasing)
        atomicIsMicRunning.store(false, ordering: .releasing)
        atomicLastMicBufferTime.atomic.store(0.0, ordering: .relaxed)

        let (engBox, obsBox, wakeSource, teardownGen) = stateLock.withLock { () -> (Box<AVAudioEngine>?, Box<AVAudioEngine>?, DispatchSourceUserDataAdd?, UInt64) in
            micSessionGeneration &+= 1
            let gen = micSessionGeneration
            _isMicRunning = false
            micStartTime = 0
            isMicCurrentlySpeaking = false
            userHoldsVoice = false
            floorOwner = Self.resolveFloorOwner(current: floorOwner, isCallerActive: callerHoldsVoice, isUserActive: false)
            smoothedMicLevel = 0.0
            lastDispatchedMicLevel = -1
            let e = micAudioEngine.map { Box(value: $0) }
            let o = observedMicEngine.map { Box(value: $0) }
            let w = micWakeSource
            micAudioEngine = nil
            observedMicEngine = nil
            micWakeSource = nil
            micRingBuffer = nil
            return (e, o, w, gen)
        }

        if let observed = obsBox?.value {
            NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: observed)
        }
        if let engine = engBox?.value {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
        }
        wakeSource?.setEventHandler {}
        wakeSource?.cancel()
        guard !isDeallocating else { return }
        micQueue.async { [weak self] in
            guard let self else { return }
            self.micMonoFormat = nil
            self.micReusableSrcPCM = nil
            self.micConverter = nil
            self.micSpare16kBuffers.removeAll(keepingCapacity: false)
            self.isMicActive = false
            self.micConsecutiveVoiceSamples = 0
            self.lastMicSpeechTime = 0
            self.micPreRoll.removeAll(keepingCapacity: false)
            self.micPreRollFrames = 0
            self.micSilentPreRollFrames = 0
            self.micRawNoiseFloor = 0
            self.micNoiseFloorGen = 0
            self.stateLock.withLock {
                guard self.micSessionGeneration == teardownGen, !self._isMicRunning else { return }
                self.isMicCurrentlySpeaking = false
                self.userHoldsVoice = false
                self.floorOwner = Self.resolveFloorOwner(
                    current: self.floorOwner,
                    isCallerActive: self.callerHoldsVoice,
                    isUserActive: false
                )
                self.smoothedMicLevel = 0.0
                self.lastDispatchedMicLevel = -1
            }
        }
    }

    private func drainMicRingBuffer(
        ringBuffer: CallerAudioRingBuffer,
        sampleRate: Double,
        expectedGen: UInt64,
        minBatchFrames: Int,
        sourceChannels: Int
    ) {
        let chunkCapacity = AVAudioFrameCount(max(2048, min(8192, Int(sampleRate * 0.05))))
        if micMonoFormat == nil || micMonoFormat?.sampleRate != sampleRate {
            micMonoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
            micReusableSrcPCM = nil
        }
        if micReusableSrcPCM == nil || (micReusableSrcPCM?.frameCapacity ?? 0) < chunkCapacity, let fmt = micMonoFormat {
            micReusableSrcPCM = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunkCapacity)
        }
        guard let srcPCM = micReusableSrcPCM, let dst = srcPCM.floatChannelData?[0] else { return }

        while ringBuffer.availableToRead() >= minBatchFrames {
            let count = ringBuffer.read(into: dst, maxCount: Int(chunkCapacity))
            guard count > 0 else { break }
            srcPCM.frameLength = AVAudioFrameCount(count)
            guard processMicAudioOnQueue(srcPCM, expectedGen: expectedGen, sourceChannels: sourceChannels) else { break }
        }
    }

    /// Computes bounded makeup gain for raw multi-channel MEMS capture (>2ch, activated when
    /// another app uses VPIO during a live call and macOS HAL drops un-boosted capsule levels).
    /// Unconditionally returns 1.0 for 1ch/2ch input so normal and post-call sensitivity stay identical.
    static func computeMultiChannelMakeupGain(
        noiseFloor: Float,
        peak: Float,
        sourceChannels: Int
    ) -> Float {
        guard sourceChannels > 2, noiseFloor > 0, noiseFloor < 0.00045 else { return 1.0 }
        let targetFloor: Float = 0.0008
        let desiredGain = min(20.0, max(1.0, targetFloor / max(noiseFloor, 1e-5)))
        guard desiredGain > 1.05 else { return 1.0 }
        if peak > 0 {
            return max(1.0, min(desiredGain, 0.65 / peak))
        }
        return desiredGain
    }

    /// Feeds synthetic 16kHz mono buffers through the production caller/mic VAD,
    /// echo gate, VPIO multi-channel normalization, and floor arbitration queues for tests.
    func processBuffersForTesting(
        callerBuffer: AVAudioPCMBuffer?,
        micBuffer: AVAudioPCMBuffer?,
        sourceChannels: Int = 1
    ) {
        let hasMic = micBuffer != nil
        let (callerGen, micGen) = stateLock.withLock { () -> (UInt64, UInt64) in
            _isRunning = true
            if hasMic {
                micShouldBeEnabled = true
                _isMicRunning = true
            }
            return (captureGeneration, micSessionGeneration)
        }
        if let micBuffer {
            let micBox = SendablePCMBuffer(buffer: micBuffer)
            micQueue.sync {
                _ = self.processMicAudioOnQueue(micBox.buffer, expectedGen: micGen, sourceChannels: sourceChannels)
            }
        }
        if let callerBuffer {
            let callerBox = SendablePCMBuffer(buffer: callerBuffer)
            callerQueue.sync {
                _ = self.processCallerAudioOnQueue(callerBox.buffer, expectedGen: callerGen)
            }
        }
    }

    @discardableResult
    private func processMicAudioOnQueue(_ srcPCM: AVAudioPCMBuffer, expectedGen: UInt64, sourceChannels: Int = 1) -> Bool {
        let valid = stateLock.withLock {
            micShouldBeEnabled && micSessionGeneration == expectedGen && (_isMicRunning || isStartingMic)
        }
        guard valid else { return false }
        guard srcPCM.frameLength > 0 else { return true }

        if micNoiseFloorGen != expectedGen {
            micNoiseFloorGen = expectedGen
            micRawNoiseFloor = 0
            micSilentPreRollFrames = 0
        }

        let silenceThreshold: Float = sourceChannels > 2 ? 1e-7 : 1e-6
        if srcPCM.format.channelCount == 1,
           !srcPCM.format.isInterleaved,
           srcPCM.format.commonFormat == .pcmFormatFloat32,
           let rawSamples = srcPCM.floatChannelData?[0] {
            var rawPeak: Float = 0.0
            vDSP_maxmgv(rawSamples, 1, &rawPeak, vDSP_Length(srcPCM.frameLength))
            if rawPeak.isFinite && rawPeak <= silenceThreshold && !isMicActive && micConsecutiveVoiceSamples == 0 && micSilentPreRollFrames >= Self.maxPreRollFrames {
                let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9
                let (committed, levelsToDispatch) = stateLock.withLock {
                    () -> (Bool, (Float, Float)?) in
                    guard micShouldBeEnabled, micSessionGeneration == expectedGen, (_isMicRunning || isStartingMic) else {
                        return (false, nil)
                    }
                    isMicCurrentlySpeaking = false
                    userHoldsVoice = false
                    floorOwner = Self.resolveFloorOwner(current: floorOwner, isCallerActive: callerHoldsVoice, isUserActive: false)
                    let levels = updateSmoothedLevelsLocked(callerRMS: nil, micRMS: 0.0, now: now)
                    return (true, levels)
                }
                guard committed else { return false }
                if let (c, m) = levelsToDispatch {
                    DispatchQueue.main.async { [weak self] in
                        self?.delegate?.audioCaptureDidUpdateLevels(callerLevel: c, micLevel: m)
                    }
                }
                return true
            }
        }

        let preferredCh = srcPCM.format.channelCount > 2
            ? min(Int(srcPCM.format.channelCount) - 1, max(0, atomicBestMicChannel.atomic.load(ordering: .relaxed)))
            : 0
        guard let converted = convertTo16kMono(srcPCM, converter: &micConverter, sparePool: &micSpare16kBuffers, preferredChannel: preferredCh),
              let samples = converted.floatChannelData?[0] else { return true }

        let totalFrames = Int(converted.frameLength)
        let bufferDuration = Double(totalFrames) / Self.speechFormat.sampleRate
        var rms = Self.computeRMS(samples: samples, count: totalFrames)
        if sourceChannels > 2 {
            if !isMicActive && rms > 1e-7 && rms < 0.0006 {
                if micRawNoiseFloor <= 0 {
                    micRawNoiseFloor = rms
                } else if rms < micRawNoiseFloor {
                    micRawNoiseFloor = (rms * 0.35) + (micRawNoiseFloor * 0.65)
                } else {
                    micRawNoiseFloor = (rms * 0.05) + (micRawNoiseFloor * 0.95)
                }
            }
            var peak: Float = 0
            vDSP_maxmgv(samples, 1, &peak, vDSP_Length(totalFrames))
            let gain = Self.computeMultiChannelMakeupGain(
                noiseFloor: micRawNoiseFloor,
                peak: peak,
                sourceChannels: sourceChannels
            )
            if gain > 1.01 {
                var mutableGain = gain
                vDSP_vsmul(samples, 1, &mutableGain, samples, 1, vDSP_Length(totalFrames))
                rms = min(1.0, rms * gain)
            }
        }
        let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9

        let (callerRMS, callerSpeaking, lastCallerVoice, userHasFloor) = stateLock.withLock {
            (rawCallerRMS, isCallerCurrentlySpeaking, lastCallerVoiceTime, floorOwner == .user)
        }

        let isolated = Self.isAudioOutputAcousticallyIsolated()
        let timeSinceCaller = lastCallerVoice > 0 ? max(0, now - lastCallerVoice) : Double.greatestFiniteMagnitude
        let callerOrEchoActive = !isolated && (callerSpeaking || timeSinceCaller < Self.echoTailWindow)

        let outputVolume = Self.currentOutputVolumeScalar(now: now)
        let acousticCoupling: Float = 0.35 * max(0.15, outputVolume)
        let coupledCallerRMS = callerRMS * acousticCoupling

        let effectiveThreshold: Float
        if callerOrEchoActive && !(userHasFloor || isMicActive) {
            let decay = Self.echoTailDecay(after: timeSinceCaller)
            let floorScalar = Float(1.0 + 0.45 * decay)
            let echoScaledThreshold = min(0.16, max(Self.micSpeechThreshold * floorScalar, coupledCallerRMS * 1.8 * decay))
            effectiveThreshold = echoScaledThreshold
        } else if callerOrEchoActive && (userHasFloor || isMicActive) {
            let echoScaledThreshold = min(0.08, max(Self.micSpeechThreshold, coupledCallerRMS * 0.85))
            effectiveThreshold = echoScaledThreshold
        } else {
            effectiveThreshold = Self.micSpeechThreshold
        }

        // Slice 100-400ms macOS tap buffers into 20ms (320-frame) sub-frames so short replies
        // ("Yes", "No", "Okay") spanning >= 40ms in quiet/soft echo (or >= 60ms during heavy echo)
        // trigger voiceDetected strictly by cumulative sample duration without sub-frame bypass.
        let subFrameSize = 320
        let heavyEchoGate = callerOrEchoActive && !(userHasFloor || isMicActive) && effectiveThreshold > (Self.micSpeechThreshold * 1.6)
        let requiredOnsetSamples = heavyEchoGate ? Self.micHeavyEchoOnsetSamples : Self.micNormalOnsetSamples
        var voiceDetected = false
        var peakSubRMS: Float = rms
        var offset = 0
        while offset < totalFrames {
            let subCount = min(subFrameSize, totalFrames - offset)
            let subRMS = (offset == 0 && subCount == totalFrames)
                ? rms
                : Self.computeRMS(samples: samples.advanced(by: offset), count: subCount)
            if subRMS > peakSubRMS { peakSubRMS = subRMS }
            if subRMS >= effectiveThreshold {
                micConsecutiveVoiceSamples += subCount
                if isMicActive || micConsecutiveVoiceSamples >= requiredOnsetSamples {
                    voiceDetected = true
                }
            } else {
                micConsecutiveVoiceSamples = 0
            }
            offset += subCount
        }

        let alpha = Float(min(1.0, bufferDuration / 0.04))
        let effectiveMeterRMS = (1.0 - alpha) * rms + alpha * peakSubRMS
        let bufStartTime = now - bufferDuration
        var outputs: [AVAudioPCMBuffer] = []
        var nextSpeaking: Bool?

        if voiceDetected {
            micSilentPreRollFrames = 0
            if !isMicActive {
                isMicActive = true
                let cutoff = lastCallerVoice > 0 ? lastCallerVoice + 0.15 : -Double.greatestFiniteMagnitude
                let preRollCount = micPreRoll.count
                micPreRoll.forEachEnumerated { idx, entry in
                    let entryEndTime = entry.startTime + Double(entry.buffer.frameLength) / Self.speechFormat.sampleRate
                    let isCurrentOnsetBuffer = (idx == preRollCount - 1) && (entryEndTime >= cutoff || (now - entryEndTime) <= 0.15)
                    if isolated || entry.startTime >= cutoff || isCurrentOnsetBuffer {
                        outputs.append(entry.buffer)
                    }
                }
                micPreRoll.removeAll(keepingCapacity: true)
                micPreRollFrames = 0
            }
            nextSpeaking = true
            lastMicSpeechTime = now
            outputs.append(converted)
        } else if isMicActive {
            micSilentPreRollFrames = 0
            let elapsed = now - lastMicSpeechTime
            if elapsed >= 0.45 { nextSpeaking = false }
            if elapsed <= Self.micHangover {
                outputs.append(converted)
            } else {
                isMicActive = false
                nextSpeaking = false
                appendMicPreRoll(converted, startTime: bufStartTime)
            }
        } else if callerOrEchoActive && !userHasFloor {
            isMicActive = false
            nextSpeaking = false
            appendMicPreRoll(converted, startTime: bufStartTime)
            if rms <= silenceThreshold && micConsecutiveVoiceSamples == 0 {
                micSilentPreRollFrames = min(Self.maxPreRollFrames, micSilentPreRollFrames + converted.frameLength)
            } else {
                micSilentPreRollFrames = 0
            }
        } else {
            appendMicPreRoll(converted, startTime: bufStartTime)
            if rms <= silenceThreshold && micConsecutiveVoiceSamples == 0 {
                micSilentPreRollFrames = min(Self.maxPreRollFrames, micSilentPreRollFrames + converted.frameLength)
            } else {
                micSilentPreRollFrames = 0
            }
        }

        let micActiveNow = isMicActive
        let speakingUpdate = nextSpeaking
        let meterRMS: Float = (callerOrEchoActive && !voiceDetected && !micActiveNow) ? 0.0 : effectiveMeterRMS
        let (committed, levelsToDispatch, currentDelegate) = stateLock.withLock {
            () -> (Bool, (Float, Float)?, AudioCaptureDelegate?) in
            guard micShouldBeEnabled, micSessionGeneration == expectedGen, (_isMicRunning || isStartingMic) else {
                return (false, nil, nil)
            }
            if let speakingUpdate { isMicCurrentlySpeaking = speakingUpdate }
            userHoldsVoice = micActiveNow
            floorOwner = Self.resolveFloorOwner(current: floorOwner, isCallerActive: callerHoldsVoice, isUserActive: micActiveNow)
            let levels = updateSmoothedLevelsLocked(callerRMS: nil, micRMS: meterRMS, now: now)
            return (true, levels, _delegate)
        }
        guard committed else { return false }

        for pcm in outputs {
            currentDelegate?.audioCaptureDidOutputMicAudio(pcmBuffer: pcm)
        }
        if let (c, m) = levelsToDispatch {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.audioCaptureDidUpdateLevels(callerLevel: c, micLevel: m)
            }
        }
        return true
    }

    // MARK: - Helpers, Watchdogs & Hardware Observers

    private func appendPreRoll(
        _ buf: AVAudioPCMBuffer,
        into queue: inout RingBuffer<AVAudioPCMBuffer>,
        totalFrames: inout AVAudioFrameCount,
        sparePool: inout [AVAudioPCMBuffer]
    ) {
        queue.append(buf)
        totalFrames += buf.frameLength
        while totalFrames > Self.maxPreRollFrames, let dropped = queue.popFirst() {
            totalFrames -= dropped.frameLength
            if sparePool.count < 24 {
                sparePool.append(dropped)
            }
        }
    }

    private func appendMicPreRoll(_ buf: AVAudioPCMBuffer, startTime: TimeInterval) {
        micPreRoll.append((buf, startTime))
        micPreRollFrames += buf.frameLength
        while micPreRollFrames > Self.maxPreRollFrames, let dropped = micPreRoll.popFirst() {
            micPreRollFrames -= dropped.buffer.frameLength
            if micSpare16kBuffers.count < 24 {
                micSpare16kBuffers.append(dropped.buffer)
            }
        }
    }

    func setLevelMeteringVisible(_ visible: Bool) {
        let immediateLevels = stateLock.withLock { () -> (Float, Float)? in
            guard levelMeteringVisible != visible else { return nil }
            levelMeteringVisible = visible
            lastLevelDispatchTime = 0
            let next: (Float, Float) = visible ? (smoothedCallerLevel, smoothedMicLevel) : (0, 0)
            lastDispatchedCallerLevel = next.0
            lastDispatchedMicLevel = next.1
            return next
        }
        if let (c, m) = immediateLevels {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.audioCaptureDidUpdateLevels(callerLevel: c, micLevel: m)
            }
        }
    }

    private func updateSmoothedLevelsLocked(callerRMS: Float?, micRMS: Float?, now: TimeInterval) -> (Float, Float)? {
        if let c = callerRMS {
            let next = (smoothedCallerLevel * 0.60) + (min(1.0, c * 12.0) * 0.40)
            smoothedCallerLevel = next < 0.005 ? 0.0 : next
        }
        if let m = micRMS {
            let next = (smoothedMicLevel * 0.60) + (min(1.0, m * 14.0) * 0.40)
            smoothedMicLevel = next < 0.005 ? 0.0 : next
        }
        guard levelMeteringVisible, (now - lastLevelDispatchTime) >= 0.05 else { return nil }
        let c = smoothedCallerLevel
        let m = smoothedMicLevel
        if abs(c - lastDispatchedCallerLevel) < 0.001 && abs(m - lastDispatchedMicLevel) < 0.001 {
            lastLevelDispatchTime = now
            return nil
        }
        lastLevelDispatchTime = now
        lastDispatchedCallerLevel = c
        lastDispatchedMicLevel = m
        return (c, m)
    }

    private func checkTapPermissionHealth(rms: Float, now: TimeInterval, expectedGen: UInt64) {
        if rms > 0.0000001 {
            let (stillValid, newlyActive, restored) = stateLock.withLock { () -> (Bool, Bool, Bool) in
                guard _isRunning, captureGeneration == expectedGen else { return (false, false, false) }
                let first = !hasReceivedNonZeroCallerSignal
                let wasDenied = didReportDeniedTapPermission
                hasReceivedNonZeroCallerSignal = true
                hasEverReceivedNonZeroCallerSignal = true
                silentOutputStartTime = 0
                didReportDeniedTapPermission = false
                return (true, first, wasDenied)
            }
            guard stillValid else { return }
            let helperDenied = PermissionHelper.shared.audioCaptureState == .deniedSilenceDetected
            if newlyActive || helperDenied {
                PermissionHelper.shared.updateAudioCaptureState(.active)
            }
            if restored || helperDenied {
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.audioCaptureDidRestoreTapPermission()
                }
            }
            return
        }

        let shouldProbe = stateLock.withLock { () -> Bool in
            guard _isRunning, captureGeneration == expectedGen,
                  !hasEverReceivedNonZeroCallerSignal, !didReportDeniedTapPermission,
                  tapStartTime > 0, (now - tapStartTime) >= 3.0,
                  (now - lastPermissionProbeTime) >= 1.0 else { return false }
            lastPermissionProbeTime = now
            return true
        }
        guard shouldProbe else { return }
        guard isOtherProcessAudioActiveThrottled(now: now) else {
            stateLock.withLock {
                if _isRunning && captureGeneration == expectedGen {
                    silentOutputStartTime = 0
                }
            }
            return
        }

        let shouldAlert = stateLock.withLock { () -> Bool in
            guard _isRunning, captureGeneration == expectedGen,
                  !hasEverReceivedNonZeroCallerSignal, !isMicCurrentlySpeaking else {
                if _isRunning && captureGeneration == expectedGen {
                    silentOutputStartTime = 0
                }
                return false
            }
            if silentOutputStartTime == 0 {
                silentOutputStartTime = now
                return false
            }
            if (now - silentOutputStartTime) >= 3.0 && !didReportDeniedTapPermission {
                didReportDeniedTapPermission = true
                return true
            }
            return false
        }
        if shouldAlert {
            AppLog.audio.warning("Detected sustained silence while other processes are playing audio; AudioCapture permission likely denied.")
            PermissionHelper.shared.updateAudioCaptureState(.deniedSilenceDetected)
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.audioCaptureDidDetectDeniedTapPermission()
            }
        }
    }

    private func isOtherProcessAudioActiveThrottled(now: TimeInterval) -> Bool {
        let (cached, query) = stateLock.withLock { () -> (Bool, Bool) in
            let q = (now - lastOtherProcessQueryTime) >= 2.5 && !isQueryingOtherProcessAudio
            if q { isQueryingOtherProcessAudio = true; lastOtherProcessQueryTime = now }
            return (cachedOtherProcessAudioActive, q)
        }
        if query {
            let ownObj = stateLock.withLock { ownProcessObjectID }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let active = Self.isOtherProcessRunningAudioOutput(excludingProcessObjectID: ownObj)
                self.stateLock.withLock {
                    self.cachedOtherProcessAudioActive = active
                    self.isQueryingOtherProcessAudio = false
                }
            }
        }
        return cached
    }

    static func isOtherProcessRunningAudioOutput(excludingProcessObjectID ownID: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        var procIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &procIDs) == noErr else {
            return false
        }
        var outAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for obj in procIDs where obj != ownID && obj != kAudioObjectUnknown {
            var running: UInt32 = 0
            var pSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(obj, &outAddr, 0, nil, &pSize, &running) == noErr, running != 0 {
                return true
            }
        }
        return false
    }

    static func isAudioOutputAcousticallyIsolated() -> Bool {
        let (ov, cached, needPrime) = isolationState.withLock { state -> (Bool?, Bool, Bool) in
            if let o = state.overrideValue { return (o, o, false) }
            let prime = !state.primed && !state.refreshing
            if prime { state.refreshing = true }
            return (nil, state.cached, prime)
        }
        if let ov { return ov }
        if needPrime { isolationQueue.async { _ = Self.refreshIsolationCache() } }
        return cached
    }

    private static func currentOutputVolumeScalar(now: TimeInterval) -> Float {
        let (vol, needRefresh) = isolationState.withLock { state -> (Float, Bool) in
            let shouldRefresh = !state.refreshing && !state.refreshingVolume && (now - state.lastVolumeRefreshTime) >= 1.5
            if shouldRefresh { state.refreshingVolume = true }
            return (state.outputVolume, shouldRefresh)
        }
        if needRefresh {
            isolationQueue.async {
                let freshVol = Self.queryOutputVolumeScalar()
                let t = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9
                Self.isolationState.withLock { state in
                    state.outputVolume = freshVol
                    state.lastVolumeRefreshTime = t
                    state.refreshingVolume = false
                }
            }
        }
        return vol
    }

    private static func queryOutputVolumeScalar(deviceID: AudioDeviceID = kAudioObjectUnknown) -> Float {
        var outID = deviceID
        if outID == kAudioObjectUnknown {
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &outID) == noErr,
                  outID != kAudioObjectUnknown else {
                return 0.5
            }
        }

        var mute: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(outID, &muteAddr, 0, nil, &muteSize, &mute) == noErr, mute != 0 {
            return 0.0
        }

        var vol: Float32 = 0.5
        var volSize = UInt32(MemoryLayout<Float32>.size)
        var vmvAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(outID, &vmvAddr, 0, nil, &volSize, &vol) == noErr, vol.isFinite {
            return min(1.0, max(0.0, vol))
        }

        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            var scalar: Float32 = 0.5
            var sSize = UInt32(MemoryLayout<Float32>.size)
            var sAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            if AudioObjectGetPropertyData(outID, &sAddr, 0, nil, &sSize, &scalar) == noErr, scalar.isFinite {
                return min(1.0, max(0.0, scalar))
            }
        }
        return 0.5
    }

    @discardableResult
    private static func refreshIsolationCache() -> AudioDeviceID {
        let (devID, isolated) = queryAcousticIsolation()
        let vol = queryOutputVolumeScalar(deviceID: devID)
        let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9
        isolationState.withLock { state in
            state.cached = isolated
            state.outputVolume = vol
            state.lastVolumeRefreshTime = now
            state.primed = true
            state.refreshing = false
            state.refreshingVolume = false
        }
        return devID
    }

    private static func queryAcousticIsolation() -> (AudioDeviceID, Bool) {
        var outID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &outID) == noErr,
              outID != kAudioObjectUnknown else { return (kAudioObjectUnknown, false) }

        // 1. Built-in 3.5mm headphone jack data source ('hdpn' == 0x6864706e)
        var dataSource: UInt32 = 0
        var dsSize = UInt32(MemoryLayout<UInt32>.size)
        var dsAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(outID, &dsAddr, 0, nil, &dsSize, &dataSource) == noErr, dataSource == 0x6864706e {
            return (outID, true)
        }

        // 2. Check localized device name for headphone/headset/earbud terms
        let headphoneKeywords = [
            "headphone", "headset", "airpod", "earpod", "buds", "in-ear",
            "auriculares", "audífonos", "audifonos", "cascos",
            "écouteurs", "ecouteurs", "kopfhörer"
        ]
        var nameIndicatesHeadphones = false
        var nameRef: Unmanaged<CFString>?
        var nSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if withUnsafeMutablePointer(to: &nameRef, { AudioObjectGetPropertyData(outID, &nAddr, 0, nil, &nSize, $0) }) == noErr,
           let str = nameRef?.takeRetainedValue() as String? {
            let lower = str.lowercased()
            if headphoneKeywords.contains(where: { lower.contains($0) }) {
                nameIndicatesHeadphones = true
            }
        }

        // 3. Inspect output streams' kAudioStreamPropertyTerminalType ('term')
        var streamsAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamsSize: UInt32 = 0
        var hasExplicitSpeakerTerminal = false
        if AudioObjectGetPropertyDataSize(outID, &streamsAddr, 0, nil, &streamsSize) == noErr,
           streamsSize >= UInt32(MemoryLayout<AudioStreamID>.size) {
            let streamCount = Int(streamsSize) / MemoryLayout<AudioStreamID>.size
            var streamIDs = [AudioStreamID](repeating: kAudioObjectUnknown, count: streamCount)
            if AudioObjectGetPropertyData(outID, &streamsAddr, 0, nil, &streamsSize, &streamIDs) == noErr {
                var termAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioStreamPropertyTerminalType,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                for streamID in streamIDs where streamID != kAudioObjectUnknown {
                    var termType: UInt32 = 0
                    var termSize = UInt32(MemoryLayout<UInt32>.size)
                    if AudioObjectGetPropertyData(streamID, &termAddr, 0, nil, &termSize, &termType) == noErr {
                        switch termType {
                        case kAudioStreamTerminalTypeHeadphones,
                             kAudioStreamTerminalTypeHeadsetMicrophone,
                             kAudioStreamTerminalTypeReceiverSpeaker,
                             kAudioStreamTerminalTypeReceiverMicrophone,
                             0x0302, // USB Audio Terminal Type: Headphones
                             0x0401, // USB Audio Terminal Type: Handset
                             0x0402: // USB Audio Terminal Type: Headset
                            return (outID, true)
                        case kAudioStreamTerminalTypeSpeaker,
                             kAudioStreamTerminalTypeLFESpeaker,
                             kAudioStreamTerminalTypeHDMI,
                             kAudioStreamTerminalTypeDisplayPort,
                             0x0301, // USB Audio Terminal Type: Speaker
                             0x0304, // USB Audio Terminal Type: Desktop speaker
                             0x0305, // USB Audio Terminal Type: Room speaker
                             0x0306, // USB Audio Terminal Type: Communication speaker
                             0x0307: // USB Audio Terminal Type: LFE speaker
                            hasExplicitSpeakerTerminal = true
                        default:
                            break
                        }
                    }
                }
            }
        }

        if nameIndicatesHeadphones {
            return (outID, true)
        }
        if hasExplicitSpeakerTerminal {
            return (outID, false)
        }

        // 4. Transport type fallback (Bluetooth / Bluetooth LE without explicit speaker terminal; AirPlay excluded)
        var transport: UInt32 = 0
        var tSize = UInt32(MemoryLayout<UInt32>.size)
        var tAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(outID, &tAddr, 0, nil, &tSize, &transport) == noErr {
            if transport == kAudioDeviceTransportTypeBluetooth ||
               transport == kAudioDeviceTransportTypeBluetoothLE {
                return (outID, true)
            }
        }

        return (outID, false)
    }

    static func hasAvailableInputDevice() -> Bool {
        var devID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID) == noErr,
              devID != kAudioObjectUnknown else { return false }
        var streamAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamSize: UInt32 = 0
        return AudioObjectGetPropertyDataSize(devID, &streamAddr, 0, nil, &streamSize) == noErr && streamSize > 0
    }

    private func ensureHardwareObserversInstalled() {
        let missing = stateLock.withLock { () -> (inMissing: Bool, outMissing: Bool, restartMissing: Bool, dsMissing: Bool) in
            isTornDownObservers = false
            return (
                defaultInputListenerToken == nil,
                defaultOutputListenerToken == nil,
                serviceRestartedListenerToken == nil,
                outputDataSourceListenerToken == nil
            )
        }
        guard missing.inMissing || missing.outMissing || missing.restartMissing || missing.dsMissing else { return }

        if missing.inMissing {
            var inAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if let token = AudioTapHelper.addPropertyListener(
                onObject: AudioObjectID(kAudioObjectSystemObject),
                address: &inAddr,
                queue: micQueue,
                block: { [weak self] _, _ in
                    guard let self else { return }
                    if self.stateLock.withLock({ self.micShouldBeEnabled }) {
                        self.scheduleMicRecovery(after: 0.35, resetBackoff: true)
                    }
                },
                status: nil
            ) {
                let (keep, previous) = stateLock.withLock { () -> (Bool, AudioHALListenerToken?) in
                    guard !isTornDownObservers else { return (false, nil) }
                    let old = defaultInputListenerToken
                    defaultInputListenerToken = token
                    return (true, old)
                }
                if let previous { _ = AudioTapHelper.removePropertyListener(previous) }
                if !keep { _ = AudioTapHelper.removePropertyListener(token) }
            }
        }

        if missing.outMissing {
            var outAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if let token = AudioTapHelper.addPropertyListener(
                onObject: AudioObjectID(kAudioObjectSystemObject),
                address: &outAddr,
                queue: callerQueue,
                block: { [weak self] _, _ in
                    guard let self else { return }
                    Self.isolationQueue.async { [weak self] in
                        let devID = Self.refreshIsolationCache()
                        self?.updateMonitoredOutputDataSourceListener(for: devID)
                    }
                    if self.stateLock.withLock({ self.callerShouldBeEnabled }) {
                        self.scheduleTapRebuild(attempt: 0, delay: 0.4)
                    }
                },
                status: nil
            ) {
                let (keep, previous) = stateLock.withLock { () -> (Bool, AudioHALListenerToken?) in
                    guard !isTornDownObservers else { return (false, nil) }
                    let old = defaultOutputListenerToken
                    defaultOutputListenerToken = token
                    return (true, old)
                }
                if let previous { _ = AudioTapHelper.removePropertyListener(previous) }
                if !keep { _ = AudioTapHelper.removePropertyListener(token) }
            }
        }

        if missing.restartMissing {
            var restartAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyServiceRestarted,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if let token = AudioTapHelper.addPropertyListener(
                onObject: AudioObjectID(kAudioObjectSystemObject),
                address: &restartAddr,
                queue: callerQueue,
                block: { [weak self] _, _ in
                    guard let self else { return }
                    AppLog.audio.warning("CoreAudio HAL service restarted; re-registering observers and rebuilding active audio pipelines.")
                    Self.isolationQueue.async { [weak self] in
                        let devID = Self.refreshIsolationCache()
                        guard let self else { return }
                        let staleToken = self.stateLock.withLock { () -> AudioHALListenerToken? in
                            let old = self.outputDataSourceListenerToken
                            self.monitoredOutputDeviceID = kAudioObjectUnknown
                            self.outputDataSourceListenerToken = nil
                            return old
                        }
                        if let staleToken {
                            _ = AudioTapHelper.removePropertyListener(staleToken)
                        }
                        self.updateMonitoredOutputDataSourceListener(for: devID)
                    }
                    let (rebuildCaller, rebuildMic) = self.stateLock.withLock {
                        (self.callerShouldBeEnabled, self.micShouldBeEnabled)
                    }
                    if rebuildCaller {
                        self.scheduleTapRebuild(attempt: 0, delay: 0.5)
                    }
                    if rebuildMic {
                        self.scheduleMicRecovery(after: 0.5, resetBackoff: true)
                    }
                },
                status: nil
            ) {
                let (keep, previous) = stateLock.withLock { () -> (Bool, AudioHALListenerToken?) in
                    guard !isTornDownObservers else { return (false, nil) }
                    let old = serviceRestartedListenerToken
                    serviceRestartedListenerToken = token
                    return (true, old)
                }
                if let previous { _ = AudioTapHelper.removePropertyListener(previous) }
                if !keep { _ = AudioTapHelper.removePropertyListener(token) }
            }
        }

        Self.isolationQueue.async { [weak self] in
            let devID = Self.refreshIsolationCache()
            self?.updateMonitoredOutputDataSourceListener(for: devID)
        }
    }

    private func pauseHardwareObservers(permanently: Bool) {
        if permanently {
            NotificationCenter.default.removeObserver(self)
        }
        let (inToken, outToken, restartToken, dsToken) = stateLock.withLock {
            () -> (AudioHALListenerToken?, AudioHALListenerToken?, AudioHALListenerToken?, AudioHALListenerToken?) in
            isTornDownObservers = true
            let i = defaultInputListenerToken
            let o = defaultOutputListenerToken
            let r = serviceRestartedListenerToken
            let d = outputDataSourceListenerToken
            defaultInputListenerToken = nil
            defaultOutputListenerToken = nil
            serviceRestartedListenerToken = nil
            monitoredOutputDeviceID = kAudioObjectUnknown
            outputDataSourceListenerToken = nil
            return (i, o, r, d)
        }
        if let inToken { _ = AudioTapHelper.removePropertyListener(inToken) }
        if let outToken { _ = AudioTapHelper.removePropertyListener(outToken) }
        if let restartToken { _ = AudioTapHelper.removePropertyListener(restartToken) }
        if let dsToken { _ = AudioTapHelper.removePropertyListener(dsToken) }
        if !permanently {
            Self.isolationState.withLock {
                $0.primed = false
                $0.lastVolumeRefreshTime = 0
            }
        }
    }

    private func updateMonitoredOutputDataSourceListener(for deviceID: AudioObjectID) {
        let prevToken = stateLock.withLock { () -> AudioHALListenerToken? in
            guard !isTornDownObservers else {
                let pToken = outputDataSourceListenerToken
                monitoredOutputDeviceID = kAudioObjectUnknown
                outputDataSourceListenerToken = nil
                return pToken
            }
            if monitoredOutputDeviceID == deviceID && outputDataSourceListenerToken != nil {
                return nil
            }
            let pToken = outputDataSourceListenerToken
            monitoredOutputDeviceID = kAudioObjectUnknown
            outputDataSourceListenerToken = nil
            return pToken
        }
        if let prevToken {
            _ = AudioTapHelper.removePropertyListener(prevToken)
        }
        guard deviceID != kAudioObjectUnknown,
              stateLock.withLock({ !isTornDownObservers && (monitoredOutputDeviceID != deviceID || outputDataSourceListenerToken == nil) }) else {
            return
        }
        var dsAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if let token = AudioTapHelper.addPropertyListener(
            onObject: deviceID,
            address: &dsAddr,
            queue: callerQueue,
            block: { _, _ in
                Self.isolationQueue.async { _ = Self.refreshIsolationCache() }
            },
            status: nil
        ) {
            let (keep, replaced) = stateLock.withLock { () -> (Bool, AudioHALListenerToken?) in
                guard !isTornDownObservers else { return (false, nil) }
                let old = outputDataSourceListenerToken
                monitoredOutputDeviceID = deviceID
                outputDataSourceListenerToken = token
                return (true, old)
            }
            if let replaced { _ = AudioTapHelper.removePropertyListener(replaced) }
            if !keep { _ = AudioTapHelper.removePropertyListener(token) }
        }
    }

    private func teardownHardwareObservers() {
        pauseHardwareObservers(permanently: true)
    }

    private func installTapFormatListeners(aggID: AudioObjectID, tapID: AudioObjectID, expectedGen: UInt64) {
        removeTapFormatListeners()
        var aggAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        if let token = AudioTapHelper.addPropertyListener(
            onObject: aggID,
            address: &aggAddr,
            queue: callerQueue,
            block: { [weak self] _, _ in
                guard let self, self.stateLock.withLock({ self._isRunning && self.captureGeneration == expectedGen }) else { return }
                self.scheduleTapRebuild(attempt: 0, delay: 0.4)
            },
            status: nil
        ) {
            let (keep, previous) = stateLock.withLock { () -> (Bool, AudioHALListenerToken?) in
                guard _isRunning, captureGeneration == expectedGen else { return (false, nil) }
                let old = aggFormatListenerToken
                aggFormatListenerToken = token
                return (true, old)
            }
            if let previous { _ = AudioTapHelper.removePropertyListener(previous) }
            if !keep { _ = AudioTapHelper.removePropertyListener(token) }
        }

        var tapAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if let token = AudioTapHelper.addPropertyListener(
            onObject: tapID,
            address: &tapAddr,
            queue: callerQueue,
            block: { [weak self] _, _ in
                guard let self, self.stateLock.withLock({ self._isRunning && self.captureGeneration == expectedGen }) else { return }
                self.scheduleTapRebuild(attempt: 0, delay: 0.4)
            },
            status: nil
        ) {
            let (keep, previous) = stateLock.withLock { () -> (Bool, AudioHALListenerToken?) in
                guard _isRunning, captureGeneration == expectedGen else { return (false, nil) }
                let old = tapFormatListenerToken
                tapFormatListenerToken = token
                return (true, old)
            }
            if let previous { _ = AudioTapHelper.removePropertyListener(previous) }
            if !keep { _ = AudioTapHelper.removePropertyListener(token) }
        }
    }

    private func removeTapFormatListeners() {
        let (aggToken, tapToken) = stateLock.withLock { () -> (AudioHALListenerToken?, AudioHALListenerToken?) in
            let a = aggFormatListenerToken
            let t = tapFormatListenerToken
            aggFormatListenerToken = nil
            tapFormatListenerToken = nil
            return (a, t)
        }
        if let aggToken { _ = AudioTapHelper.removePropertyListener(aggToken) }
        if let tapToken { _ = AudioTapHelper.removePropertyListener(tapToken) }
    }

    private func scheduleTapRebuild(attempt: Int, delay: TimeInterval = 0.5) {
        let plan = stateLock.withLock { () -> (UInt64, Box<DispatchWorkItem>?, TimeInterval)? in
            guard callerShouldBeEnabled else { return nil }
            if attempt == 0 && isRebuildingTap {
                tapRebuildPending = true
                return nil
            }
            isRebuildingTap = true
            tapRebuildPending = false
            tapRebuildGeneration &+= 1
            let prev = tapRebuildWorkItem.map { Box(value: $0) }
            tapRebuildWorkItem = nil
            return (tapRebuildGeneration, prev, attempt == 0 ? delay : TimeInterval(1 << (attempt - 1)) * 0.5)
        }
        guard let (gen, prevItem, waitDelay) = plan else { return }
        prevItem?.value.cancel()

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.stateLock.withLock({ self.tapRebuildGeneration == gen && self.callerShouldBeEnabled }) else { return }
            self.lifecycleLock.lock()
            let (stopGen, shouldProceed) = self.stateLock.withLock {
                (self.stopGeneration, self.tapRebuildGeneration == gen && self.callerShouldBeEnabled)
            }
            guard shouldProceed else {
                self.lifecycleLock.unlock()
                return
            }
            var rebuildErr: Error?
            var didRecoverTap = false
            self.tearDownCallerTapOnly(isStoppingPermanently: false)
            do {
                try self.startCallerTapPipeline(entryStopGen: stopGen)
                didRecoverTap = self.stateLock.withLock { self._isRunning && self.callerShouldBeEnabled && self.stopGeneration == stopGen }
            } catch {
                rebuildErr = error
            }
            self.lifecycleLock.unlock()

            let shouldSchedulePending = self.stateLock.withLock { () -> Bool in
                guard self.tapRebuildGeneration == gen else { return false }
                self.isRebuildingTap = false
                if self.tapRebuildPending && self.callerShouldBeEnabled {
                    self.tapRebuildPending = false
                    return true
                }
                return false
            }

            if shouldSchedulePending {
                self.scheduleTapRebuild(attempt: 0, delay: 0.4)
                return
            }

            if let err = rebuildErr {
                if case AudioCaptureError.tapPermissionRequired = err {
                    return
                }
                if attempt < 2 && self.stateLock.withLock({ self.tapRebuildGeneration == gen && self.callerShouldBeEnabled }) {
                    self.scheduleTapRebuild(attempt: attempt + 1)
                } else {
                    let (matchesGen, keepWatchdog) = self.stateLock.withLock { () -> (Bool, Bool) in
                        guard self.tapRebuildGeneration == gen else { return (false, false) }
                        self.nextCallerRecoveryTime = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9 + 10.0
                        return (true, self.callerShouldBeEnabled)
                    }
                    if matchesGen {
                        if keepWatchdog && PermissionHelper.shared.audioCaptureState != .deniedSilenceDetected {
                            self.startCallerWatchdog()
                        }
                        DispatchQueue.main.async { [weak self] in
                            self?.delegate?.audioCaptureDidEncounterError(err)
                        }
                    }
                }
            } else if didRecoverTap {
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.audioCaptureDidRecoverTap()
                }
            }
        }
        let itemBox = Box(value: item)
        stateLock.withLock { if tapRebuildGeneration == gen { tapRebuildWorkItem = itemBox.value } }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + waitDelay, execute: item)
    }

    @objc private func handleAudioEngineConfigChange(_ notification: Notification) {
        // Dispatch asynchronously off AVAudioEngine's internal notification queue so we never
        // acquire stateLock synchronously while AVAudioEngine holds its internal lock.
        let changedEngineBox = (notification.object as? AVAudioEngine).map { Box(value: $0) }
        micQueue.async { [weak self] in
            guard let self else { return }
            let shouldRecover = self.stateLock.withLock { () -> Bool in
                guard self.micShouldBeEnabled else { return false }
                if let changed = changedEngineBox?.value,
                   let current = self.micAudioEngine,
                   changed !== current {
                    return false
                }
                if self.isStartingMic || self.isRecoveringMic || self.isRequestingMicPermission {
                    self.pendingMicConfigChange = true
                    return false
                }
                return self.micAudioEngine != nil || self._isMicRunning
            }
            if shouldRecover {
                self.scheduleMicRecovery(after: 0.35, resetBackoff: false)
            }
        }
    }

    private func scheduleMicRecovery(after delay: TimeInterval, resetBackoff: Bool) {
        let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9
        let plan = stateLock.withLock { () -> (UInt64, Box<DispatchWorkItem>?, TimeInterval)? in
            guard micShouldBeEnabled else { return nil }
            var prev: Box<DispatchWorkItem>?
            if resetBackoff {
                micRecoveryFailures = 0
                nextMicRecoveryTime = 0
                prev = micRecoveryWorkItem.map { Box(value: $0) }
                micRecoveryWorkItem = nil
                isRecoveringMic = false
                if isStartingMic || isRequestingMicPermission {
                    pendingMicConfigChange = true
                    return nil
                }
            } else if isRecoveringMic || isStartingMic || isRequestingMicPermission {
                pendingMicConfigChange = true
                return nil
            }
            pendingMicConfigChange = false
            micRecoveryGeneration &+= 1
            isRecoveringMic = true
            let remainingBackoff = max(0.0, nextMicRecoveryTime - now)
            return (micRecoveryGeneration, prev, max(delay, remainingBackoff))
        }
        guard let (gen, prevItem, waitDelay) = plan else { return }
        prevItem?.value.cancel()

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.stateLock.withLock({ self.micRecoveryGeneration == gen && self.micShouldBeEnabled }) else {
                self.stateLock.withLock { if self.micRecoveryGeneration == gen { self.isRecoveringMic = false } }
                return
            }
            defer {
                let (retryPending, retryDelay) = self.stateLock.withLock { () -> (Bool, TimeInterval) in
                    if self.micRecoveryGeneration == gen {
                        self.isRecoveringMic = false
                    }
                    if self.pendingMicConfigChange && self.micShouldBeEnabled && !self.isStartingMic && !self.isRecoveringMic && !self.isRequestingMicPermission {
                        self.pendingMicConfigChange = false
                        let nowTime = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9
                        let wait = max(0.35, self.nextMicRecoveryTime - nowTime)
                        return (true, wait)
                    }
                    return (false, 0.35)
                }
                if retryPending {
                    self.scheduleMicRecovery(after: retryDelay, resetBackoff: false)
                }
            }
            do { try self.startMicrophone() } catch { self.recordMicFailure(reason: error.localizedDescription) }
        }
        let box = Box(value: item)
        stateLock.withLock { if micRecoveryGeneration == gen { micRecoveryWorkItem = box.value } }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + waitDelay, execute: item)
    }

    private func recordMicFailure(reason: String, notifyImmediately: Bool = false) {
        let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9
        let (failures, shouldAlert) = stateLock.withLock { () -> (Int, Bool) in
            micRecoveryFailures += 1
            let expPower = Double(min(10, micRecoveryFailures - 1))
            nextMicRecoveryTime = now + min(10.0, 0.5 * pow(2.0, expPower))
            let alertNow = notifyImmediately ? (micRecoveryFailures == 1 || micRecoveryFailures == 2) : (micRecoveryFailures == 2)
            return (micRecoveryFailures, alertNow)
        }
        AppLog.audio.warning("Mic failure #\(failures, privacy: .public): \(reason, privacy: .public)")
        if shouldAlert {
            let err = AudioCaptureError.microphoneUnavailable(reason: reason)
            DispatchQueue.main.async { [weak self] in self?.delegate?.audioCaptureDidEncounterMicError(err) }
        }
    }

    private func startCallerWatchdog() {
        stopCallerWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: callerQueue)
        timer.schedule(deadline: .now() + 3.0, repeating: 3.0, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self, PermissionHelper.shared.audioCaptureState != .deniedSilenceDetected else { return }
            let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9
            let lastBuf = self.callerTimestampAtomic.atomic.load(ordering: .relaxed)
            let (enabled, running, rebuilding, startTime, nextAllowed, gen, needsPermCheck) = self.stateLock.withLock {
                (self.callerShouldBeEnabled, self._isRunning, self.isRebuildingTap, self.tapStartTime, self.nextCallerRecoveryTime, self.captureGeneration,
                 self._isRunning && !self.hasEverReceivedNonZeroCallerSignal && !self.didReportDeniedTapPermission)
            }
            if needsPermCheck {
                self.checkTapPermissionHealth(rms: 0.0, now: now, expectedGen: gen)
            }
            guard enabled, !rebuilding, now >= nextAllowed else { return }
            if !running {
                self.scheduleTapRebuild(attempt: 0, delay: 0.5)
                return
            }
            let stalled = lastBuf > 0 ? (now - lastBuf) > 4.0 : (now - startTime) > 5.0
            if stalled && self.isOtherProcessAudioActiveThrottled(now: now) {
                self.stateLock.withLock { self.nextCallerRecoveryTime = now + 15.0 }
                self.scheduleTapRebuild(attempt: 0, delay: 0.5)
            }
        }
        let (installed, old) = stateLock.withLock { () -> (Bool, DispatchSourceTimer?) in
            let p = callerWatchdogTimer
            guard callerShouldBeEnabled else {
                callerWatchdogTimer = nil
                return (false, p)
            }
            callerWatchdogTimer = timer
            return (true, p)
        }
        old?.cancel()
        timer.resume()
        if !installed {
            timer.cancel()
        }
    }

    private func stopCallerWatchdog() {
        stateLock.withLock { let t = callerWatchdogTimer; callerWatchdogTimer = nil; return t }?.cancel()
    }

    private func startMicWatchdog() {
        stopMicWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: micQueue)
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
            let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9
            let lastMicBuf = self.atomicLastMicBufferTime.atomic.load(ordering: .relaxed)
            let snapshot = self.stateLock.withLock {
                () -> (shouldCheck: Bool, immediateRestart: Bool, isRunningFlag: Bool, startTime: TimeInterval, engineBox: Box<AVAudioEngine>?) in
                guard self.micShouldBeEnabled, now >= self.nextMicRecoveryTime,
                      !self.isRecoveringMic, !self.isStartingMic, !self.isRequestingMicPermission else {
                    return (false, false, false, 0, nil)
                }
                if self.pendingMicConfigChange {
                    self.pendingMicConfigChange = false
                    return (true, true, self._isMicRunning, self.micStartTime, nil)
                }
                return (true, false, self._isMicRunning, self.micStartTime, self.micAudioEngine.map { Box(value: $0) })
            }
            guard snapshot.shouldCheck else { return }
            let needsRestart: Bool
            if snapshot.immediateRestart {
                needsRestart = true
            } else {
                // Query AVAudioEngine.isRunning outside stateLock to prevent AB-BA deadlock
                // with AVAudioEngine's internal lock during configuration change notifications.
                let engRunning = snapshot.engineBox?.value.isRunning ?? false
                let stalled: Bool
                if lastMicBuf > 0 {
                    stalled = (now - lastMicBuf) > 3.5
                } else if snapshot.startTime > 0 {
                    stalled = (now - snapshot.startTime) > 5.0
                } else {
                    stalled = false
                }
                needsRestart = !snapshot.isRunningFlag || !engRunning || stalled
            }
            if needsRestart { self.scheduleMicRecovery(after: 0.2, resetBackoff: false) }
        }
        let (installed, old) = stateLock.withLock { () -> (Bool, DispatchSourceTimer?) in
            let p = micWatchdogTimer
            guard micShouldBeEnabled else {
                micWatchdogTimer = nil
                return (false, p)
            }
            micWatchdogTimer = timer
            return (true, p)
        }
        old?.cancel()
        timer.resume()
        if !installed {
            timer.cancel()
        }
    }

    private func stopMicWatchdog() {
        stateLock.withLock { let t = micWatchdogTimer; micWatchdogTimer = nil; return t }?.cancel()
    }

    // MARK: - Audio Conversion

    private static func dequeueOrAllocate16kBuffer(
        capacity: AVAudioFrameCount,
        targetFormat: AVAudioFormat,
        sparePool: inout [AVAudioPCMBuffer]
    ) -> AVAudioPCMBuffer? {
        while let candidate = sparePool.popLast() {
            if candidate.format == targetFormat && candidate.frameCapacity >= capacity {
                candidate.frameLength = 0
                return candidate
            }
        }
        return AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
    }

    private func convertTo16kMono(
        _ buffer: AVAudioPCMBuffer,
        converter: inout AVAudioConverter?,
        sparePool: inout [AVAudioPCMBuffer],
        preferredChannel: Int = 0
    ) -> AVAudioPCMBuffer? {
        let srcRate = buffer.format.sampleRate
        guard buffer.frameLength > 0, buffer.format.channelCount > 0, srcRate.isFinite, srcRate > 0 else { return nil }
        let target = Self.speechFormat
        if srcRate == target.sampleRate && buffer.format.channelCount == 1 && buffer.format.commonFormat == .pcmFormatFloat32 {
            guard let src = buffer.floatChannelData?[0],
                  let out = Self.dequeueOrAllocate16kBuffer(capacity: buffer.frameLength, targetFormat: target, sparePool: &sparePool),
                  let dst = out.floatChannelData?[0] else { return nil }
            out.frameLength = buffer.frameLength
            memcpy(dst, src, Int(buffer.frameLength) * MemoryLayout<Float>.size)
            return out
        }
        let srcChannels = Int(buffer.format.channelCount)
        let clampedChannel = min(max(0, preferredChannel), max(0, srcChannels - 1))
        if converter == nil || converter?.inputFormat != buffer.format {
            let conv = AVAudioConverter(from: buffer.format, to: target)
            if let conv {
                if srcChannels == 2 {
                    conv.downmix = true
                } else if srcChannels > 2 || conv.channelMap.contains(-1) {
                    conv.channelMap = [NSNumber(value: clampedChannel)]
                }
            }
            converter = conv
        }
        guard let conv = converter else { return nil }
        let estimated = ceil(Double(buffer.frameLength) * (target.sampleRate / srcRate)) + 32.0
        guard estimated.isFinite, estimated > 0 else { return nil }
        let maxCap = Double(UInt32.max - 1)
        let cap = AVAudioFrameCount(min(maxCap, max(64.0, estimated)))
        guard let out = Self.dequeueOrAllocate16kBuffer(capacity: cap, targetFormat: target, sparePool: &sparePool) else { return nil }
        var err: NSError?
        var supplied = false
        let status = conv.convert(to: out, error: &err) { _, outStatus in
            if !supplied { supplied = true; outStatus.pointee = .haveData; return buffer }
            outStatus.pointee = .noDataNow
            return nil
        }
        if status == .error || err != nil {
            conv.reset()
            if sparePool.count < 24 {
                sparePool.append(out)
            }
            return nil
        }
        if out.frameLength == 0 {
            if sparePool.count < 24 {
                sparePool.append(out)
            }
            return nil
        }
        return out
    }

    private static func copyFastFloat32ToMono(
        source buffer: AVAudioPCMBuffer,
        destination mono: AVAudioPCMBuffer,
        atomicBestMicChannel: borrowing Atomic<Int>
    ) -> Bool {
        let frames = buffer.frameLength
        let srcFormat = buffer.format
        let srcRate = srcFormat.sampleRate
        let dstRate = mono.format.sampleRate
        guard frames > 0,
              srcFormat.channelCount > 0,
              mono.format.channelCount == 1,
              srcRate.isFinite, srcRate > 0,
              dstRate.isFinite, dstRate > 0,
              abs(srcRate - dstRate) < 1e-6,
              !srcFormat.isInterleaved,
              mono.frameCapacity >= frames,
              let dst = mono.floatChannelData?[0],
              let src = buffer.floatChannelData else { return false }

        let channels = Int(srcFormat.channelCount)
        let countInt = Int(frames)
        let vLen = vDSP_Length(frames)
        mono.frameLength = frames
        let bytes = countInt * MemoryLayout<Float>.size
        if channels == 1 {
            memcpy(dst, src[0], bytes)
            return true
        } else if channels == 2 {
            var half: Float = 0.5
            vDSP_vasm(src[0], 1, src[1], 1, &half, dst, 1, vLen)
            return true
        } else {
            let preferredCh = min(channels - 1, max(0, atomicBestMicChannel.load(ordering: .relaxed)))
            var bestCh = preferredCh
            var bestRMS = Self.computeRMS(samples: src[bestCh], count: countInt)
            for ch in 0..<channels where ch != preferredCh {
                let r = Self.computeRMS(samples: src[ch], count: countInt)
                if r > bestRMS * 1.15 && r > 0.0005 { bestRMS = r; bestCh = ch }
            }
            if bestCh != preferredCh { atomicBestMicChannel.store(bestCh, ordering: .relaxed) }
            memcpy(dst, src[bestCh], bytes)
            return true
        }
    }

    private static func copyRawPCMBuffer(source: AVAudioPCMBuffer, destination: AVAudioPCMBuffer) -> Bool {
        let frames = source.frameLength
        guard frames > 0,
              frames <= destination.frameCapacity,
              source.format == destination.format else { return false }
        let srcList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let dstList = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard srcList.count == dstList.count, !srcList.isEmpty else { return false }
        destination.frameLength = frames
        for i in 0..<srcList.count {
            let byteCount = Int(srcList[i].mDataByteSize)
            guard byteCount <= Int(dstList[i].mDataByteSize),
                  let srcData = srcList[i].mData,
                  let dstData = dstList[i].mData else { return false }
            if byteCount > 0 {
                memcpy(dstData, srcData, byteCount)
            }
        }
        return true
    }

    private static func cloneRawPCMBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = source.frameLength
        guard frames > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: frames) else { return nil }
        return copyRawPCMBuffer(source: source, destination: copy) ? copy : nil
    }

    @discardableResult
    func convertAndCopyToMono(source buffer: AVAudioPCMBuffer, destination mono: AVAudioPCMBuffer) -> Bool {
        let frames = buffer.frameLength
        let srcFormat = buffer.format
        let srcRate = srcFormat.sampleRate
        let dstRate = mono.format.sampleRate
        guard frames > 0,
              srcFormat.channelCount > 0,
              mono.format.channelCount == 1,
              srcRate.isFinite, srcRate > 0,
              dstRate.isFinite, dstRate > 0 else { return false }

        let rawExpectedOut = ceil(Double(frames) * (dstRate / srcRate))
        guard rawExpectedOut.isFinite, rawExpectedOut > 0, rawExpectedOut <= Double(mono.frameCapacity) else {
            return false
        }

        if Self.copyFastFloat32ToMono(
            source: buffer,
            destination: mono,
            atomicBestMicChannel: atomicBestMicChannel.atomic
        ) {
            return true
        }

        let channels = Int(srcFormat.channelCount)
        let preferredCh = channels > 2 ? min(channels - 1, max(0, atomicBestMicChannel.atomic.load(ordering: .relaxed))) : 0
        let targetFormat = mono.format
        let srcBox = SendablePCMBuffer(buffer: buffer)
        let dstBox = SendablePCMBuffer(buffer: mono)
        let srcFmtBox = Box(value: srcFormat)
        let tgtFmtBox = Box(value: targetFormat)
        return fallbackConverterLock.withLock { cache in
            let conv: AVAudioConverter
            if let existing = cache.converter,
               cache.inputFormat == srcFmtBox.value,
               cache.outputFormat == tgtFmtBox.value {
                conv = existing
                if channels > 2 && cache.preferredChannel != preferredCh {
                    conv.channelMap = [NSNumber(value: preferredCh)]
                    cache.preferredChannel = preferredCh
                }
            } else {
                guard let created = AVAudioConverter(from: srcFmtBox.value, to: tgtFmtBox.value) else { return false }
                if channels == 2 {
                    created.downmix = true
                } else if channels > 2 || created.channelMap.contains(-1) {
                    created.channelMap = [NSNumber(value: preferredCh)]
                }
                cache.converter = created
                cache.inputFormat = srcFmtBox.value
                cache.outputFormat = tgtFmtBox.value
                cache.preferredChannel = preferredCh
                conv = created
            }
            dstBox.buffer.frameLength = 0
            var err: NSError?
            var supplied = false
            let status = conv.convert(to: dstBox.buffer, error: &err) { _, outStatus in
                if !supplied { supplied = true; outStatus.pointee = .haveData; return srcBox.buffer }
                outStatus.pointee = .noDataNow
                return nil
            }
            if status == .error || err != nil {
                conv.reset()
                return false
            }
            return dstBox.buffer.frameLength > 0
        }
    }
}
