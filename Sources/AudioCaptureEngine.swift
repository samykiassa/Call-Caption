import Foundation
import CoreAudio
import AudioToolbox
@preconcurrency import AVFoundation
import Accelerate
import os
import Synchronization

public protocol AudioCaptureDelegate: AnyObject, Sendable {
    func audioCaptureDidOutputCallerAudio(pcmBuffer: AVAudioPCMBuffer)
    func audioCaptureDidOutputMicAudio(pcmBuffer: AVAudioPCMBuffer)
    func audioCaptureDidUpdateLevels(callerLevel: Float, micLevel: Float)
    func audioCaptureDidEncounterError(_ error: Error)
    func audioCaptureDidDetectDeniedTapPermission()
    func audioCaptureDidRestoreTapPermission()
}

public enum SpeechFloorOwner: String, Sendable, Equatable {
    case none
    case caller
    case user
}

public final class AudioCaptureEngine: NSObject, @unchecked Sendable {
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
        func write(samples: UnsafePointer<Float>, count: Int) -> Bool {
            guard count > 0, count <= capacity else { return false }
            let currentTail = tail.load(ordering: .relaxed)
            let currentHead = head.load(ordering: .acquiring)
            guard count <= (capacity &- (currentTail &- currentHead)) else { return false }

            let writeOffset = currentTail & mask
            let firstPart = min(count, capacity - writeOffset)
            buffer.advanced(by: writeOffset).update(from: samples, count: firstPart)
            let secondPart = count - firstPart
            if secondPart > 0 {
                buffer.update(from: samples.advanced(by: firstPart), count: secondPart)
            }
            tail.store(currentTail &+ count, ordering: .releasing)
            return true
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

    private final class MicScratchPool: @unchecked Sendable {
        let buffers: [AVAudioPCMBuffer]
        private let freeMask: Atomic<UInt32>

        init(monoFormat: AVAudioFormat, frameCapacity: AVAudioFrameCount, poolSize: Int = 16) {
            let clamped = min(31, max(1, poolSize))
            self.buffers = (0..<clamped).compactMap { _ in
                AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCapacity)
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

    public static let speechFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    private let stateLock = OSAllocatedUnfairLock()
    private let lifecycleLock = NSLock()
    private let micLifecycleLock = NSLock()
    public weak var delegate: AudioCaptureDelegate?

    private let callerQueue = DispatchQueue(label: "com.callcaption.callerAudio", qos: .userInteractive)
    private let callerQueueKey = DispatchSpecificKey<Void>()
    private let micQueue = DispatchQueue(label: "com.callcaption.micAudio", qos: .userInteractive)

    // CoreAudio System Tap state
    private var tapObjectID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ownProcessObjectID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var callerWakeSource: DispatchSourceUserDataAdd?
    private var callerRingBuffer: CallerAudioRingBuffer?
    private let callerTimestampAtomic = AtomicBox<Double>(0.0)
    private var callerReusableSrcPCM: AVAudioPCMBuffer?
    private var callerMonoFormat: AVAudioFormat?
    private var callerConverter: AVAudioConverter?

    private var aggFormatListenerBlock: AudioObjectPropertyListenerBlock?
    private var aggFormatListenerDeviceID: AudioObjectID = kAudioObjectUnknown
    private var tapFormatListenerBlock: AudioObjectPropertyListenerBlock?
    private var tapFormatListenerTapID: AudioObjectID = kAudioObjectUnknown
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?
    private var monitoredOutputDeviceID: AudioObjectID = kAudioObjectUnknown
    private var outputDataSourceListenerBlock: AudioObjectPropertyListenerBlock?
    private var isTornDownObservers = false

    private var _isRunning = false
    private var callerShouldBeEnabled = false
    private var captureGeneration: UInt64 = 0
    private var stopGeneration: UInt64 = 0
    private var isRebuildingTap = false
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
    private var callerConsecutiveVoiceFrames = 0
    private var lastCallerSpeechTime: TimeInterval = 0
    private var callerPreRoll: [AVAudioPCMBuffer] = []
    private var callerPreRollFrames: AVAudioFrameCount = 0

    // Mic Engine state
    private var micAudioEngine: AVAudioEngine?
    private var observedMicEngine: AVAudioEngine?
    private var micShouldBeEnabled = false
    private var _isMicRunning = false
    private var isStartingMic = false
    private var isRequestingMicPermission = false
    private var isRecoveringMic = false
    private var micRecoveryFailures = 0
    private var nextMicRecoveryTime: TimeInterval = 0
    private var micRecoveryWorkItem: DispatchWorkItem?
    private var micRecoveryGeneration: UInt64 = 0
    private var micSessionGeneration: UInt64 = 0
    private var micWatchdogTimer: DispatchSourceTimer?
    private var micConverter: AVAudioConverter?
    private var isMicActive = false
    private var micConsecutiveVoiceFrames = 0
    private var lastMicSpeechTime: TimeInterval = 0
    private var micPreRoll: [(buffer: AVAudioPCMBuffer, startTime: TimeInterval)] = []
    private var micPreRollFrames: AVAudioFrameCount = 0

    private let atomicIsMicRunning = Atomic<Bool>(false)
    private let atomicLastMicBufferTime = Atomic<Double>(0.0)
    private let atomicBestMicChannel = Atomic<Int>(0)

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
    private var lastLevelDispatchTime: TimeInterval = 0

    private static let callerSpeechThreshold: Float = 0.0055
    private static let micSpeechThreshold: Float = 0.009
    private static let callerHangover: TimeInterval = 0.70
    private static let micHangover: TimeInterval = 0.65
    private static let echoTailWindow: TimeInterval = 0.55
    private static let maxPreRollFrames: AVAudioFrameCount = 8000 // ~0.5s at 16kHz

    // Acoustic isolation cache
    private struct IsolationState {
        var overrideValue: Bool?
        var cached = false
        var primed = false
        var refreshing = false
    }
    private static let isolationState = OSAllocatedUnfairLock(initialState: IsolationState())
    private static let isolationQueue = DispatchQueue(label: "com.callcaption.isolation", qos: .utility)

    public static var overrideAcousticIsolation: Bool? {
        get { isolationState.withLock { $0.overrideValue } }
        set { isolationState.withLock { $0.overrideValue = newValue } }
    }

    public var isRunning: Bool { stateLock.withLock { _isRunning } }
    public var isMicRunning: Bool { atomicIsMicRunning.load(ordering: .relaxed) }
    public var speechFloorOwner: SpeechFloorOwner { stateLock.withLock { floorOwner } }

    public override init() {
        super.init()
        callerQueue.setSpecific(key: callerQueueKey, value: ())
        setupHardwareObservers()
    }

    deinit {
        teardownHardwareObservers()
        stop(isDeallocating: true)
    }

    public static func resolveFloorOwner(
        current: SpeechFloorOwner,
        isCallerActive: Bool,
        isUserActive: Bool
    ) -> SpeechFloorOwner {
        switch current {
        case .caller where isCallerActive: return .caller
        case .user where isUserActive: return .user
        default: break
        }
        if isCallerActive { return .caller }
        if isUserActive { return .user }
        return .none
    }

    public static func echoTailDecay(after elapsed: TimeInterval) -> Float {
        guard elapsed > 0 else { return 1.0 }
        return Float(exp(-elapsed / 0.25))
    }

    public static func computeRMS(samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0.0 }
        var rms: Float = 0.0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
        return rms.isFinite ? rms : 0.0
    }

    // MARK: - Lifecycle

    public func start(enableMic: Bool = false) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        let entryStopGen = stateLock.withLock { () -> UInt64 in
            callerShouldBeEnabled = true
            return stopGeneration
        }

        stopMicrophone()
        tearDownCallerTapOnly(isStoppingPermanently: false)

        guard stateLock.withLock({ stopGeneration == entryStopGen && callerShouldBeEnabled }) else { return }

        do {
            try startCallerTapPipeline(entryStopGen: entryStopGen)
        } catch {
            let keepWatchdog = stateLock.withLock { callerShouldBeEnabled && stopGeneration == entryStopGen }
            if keepWatchdog && PermissionHelper.shared.audioCaptureState != .deniedSilenceDetected {
                startCallerWatchdog()
            }
            throw error
        }

        if enableMic {
            setMicrophoneEnabled(true)
        }
    }

    public func stop() {
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
        stopMicrophone(isDeallocating: isDeallocating)
        tearDownCallerTapOnly(isStoppingPermanently: true, isDeallocating: isDeallocating)
    }

    public func setMicrophoneEnabled(_ enabled: Bool) {
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
                    recordMicFailure(reason: error.localizedDescription)
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
            throw NSError(domain: "AudioCaptureEngine", code: Int(pidStatus), userInfo: [NSLocalizedDescriptionKey: "Failed to resolve process ID for audio tap"])
        }

        let tapDesc = CATapDescription(monoGlobalTapButExcludeProcesses: [resolvedOwnObjID])
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
            }
            throw NSError(domain: "AudioCaptureEngine", code: Int(tapStatus), userInfo: [NSLocalizedDescriptionKey: "System Audio Recording permission required (OSStatus \(tapStatus))"])
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
            throw NSError(domain: "AudioCaptureEngine", code: Int(aggStatus), userInfo: [NSLocalizedDescriptionKey: "Failed to create audio aggregate device"])
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
              let avFormat = AVAudioFormat(streamDescription: &asbd),
              asbd.mFormatID == kAudioFormatLinearPCM,
              (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              asbd.mBitsPerChannel == 32,
              asbd.mChannelsPerFrame == 1,
              asbd.mBytesPerFrame == MemoryLayout<Float>.size else {
            _ = AudioHardwareDestroyAggregateDevice(newAggID)
            _ = AudioHardwareDestroyProcessTap(newTapID)
            throw NSError(domain: "AudioCaptureEngine", code: Int(formatStatus), userInfo: [NSLocalizedDescriptionKey: "Unsupported system audio tap format"])
        }

        let sampleRate = avFormat.sampleRate
        let ringBuffer = CallerAudioRingBuffer(capacityPowerOfTwo: max(4096, Int(sampleRate * 2.0)))
        let pendingGen = stateLock.withLock { () -> UInt64 in
            captureGeneration &+= 1
            return captureGeneration
        }

        let wakeSource = DispatchSource.makeUserDataAddSource(queue: callerQueue)
        let tsAtomic = callerTimestampAtomic
        wakeSource.setEventHandler { [weak self, ringBuffer] in
            self?.drainCallerRingBuffer(ringBuffer: ringBuffer, sampleRate: sampleRate, expectedGen: pendingGen)
        }

        var newProcID: AudioDeviceIOProcID?
        let bytesPerFrame = asbd.mBytesPerFrame > 0 ? asbd.mBytesPerFrame : 4
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, newAggID, nil) { _, inInputData, _, _, _ in
            tsAtomic.atomic.store(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9, ordering: .relaxed)
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard let first = abl.first, let src = first.mData else { return }
            let frameCount = Int(first.mDataByteSize) / Int(bytesPerFrame)
            guard frameCount > 0 else { return }
            _ = ringBuffer.write(samples: src.assumingMemoryBound(to: Float.self), count: frameCount)
            wakeSource.add(data: 1)
        }

        guard ioStatus == noErr, let procID = newProcID else {
            wakeSource.setEventHandler {}
            wakeSource.cancel()
            wakeSource.resume()
            _ = AudioHardwareDestroyAggregateDevice(newAggID)
            _ = AudioHardwareDestroyProcessTap(newTapID)
            throw NSError(domain: "AudioCaptureEngine", code: Int(ioStatus), userInfo: [NSLocalizedDescriptionKey: "Failed to start audio IO proc"])
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
            throw NSError(domain: "AudioCaptureEngine", code: Int(startStatus), userInfo: [NSLocalizedDescriptionKey: "AudioDeviceStart failed (OSStatus \(startStatus))"])
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

        let (tapID, aggID, procID, wakeSource, rebuildItem) = stateLock.withLock {
            () -> (AudioObjectID, AudioObjectID, AudioDeviceIOProcID?, DispatchSourceUserDataAdd?, Box<DispatchWorkItem>?) in
            captureGeneration &+= 1
            _isRunning = false
            var rItem: Box<DispatchWorkItem>?
            if isStoppingPermanently {
                callerShouldBeEnabled = false
                isRebuildingTap = false
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
            let t = tapObjectID; tapObjectID = kAudioObjectUnknown
            let a = aggregateDeviceID; aggregateDeviceID = kAudioObjectUnknown
            ownProcessObjectID = kAudioObjectUnknown
            let p = ioProcID; ioProcID = nil
            let w = callerWakeSource; callerWakeSource = nil
            callerRingBuffer = nil
            return (t, a, p, w, rItem)
        }

        rebuildItem?.value.cancel()
        callerTimestampAtomic.atomic.store(0.0, ordering: .relaxed)
        removeTapFormatListeners(aggID: aggID, tapID: tapID)

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
            self.isCallerActive = false
            self.callerConsecutiveVoiceFrames = 0
            self.lastCallerSpeechTime = 0
            self.callerPreRoll.removeAll(keepingCapacity: false)
            self.callerPreRollFrames = 0
        }
        if DispatchQueue.getSpecific(key: callerQueueKey) != nil {
            resetQueueState()
        } else {
            callerQueue.sync(execute: resetQueueState)
        }
    }

    private func drainCallerRingBuffer(ringBuffer: CallerAudioRingBuffer, sampleRate: Double, expectedGen: UInt64) {
        let chunkCapacity = AVAudioFrameCount(max(2048, min(8192, Int(sampleRate * 0.05))))
        if callerMonoFormat == nil || callerMonoFormat?.sampleRate != sampleRate {
            callerMonoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
            callerReusableSrcPCM = nil
        }
        if callerReusableSrcPCM == nil || (callerReusableSrcPCM?.frameCapacity ?? 0) < chunkCapacity, let fmt = callerMonoFormat {
            callerReusableSrcPCM = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunkCapacity)
        }
        guard let srcPCM = callerReusableSrcPCM, let dst = srcPCM.floatChannelData?[0] else { return }

        while ringBuffer.availableToRead() > 0 {
            guard stateLock.withLock({ _isRunning && captureGeneration == expectedGen }) else { break }
            let count = ringBuffer.read(into: dst, maxCount: Int(chunkCapacity))
            guard count > 0 else { break }
            srcPCM.frameLength = AVAudioFrameCount(count)
            processCallerAudioOnQueue(srcPCM)
        }
    }

    private func processCallerAudioOnQueue(_ srcPCM: AVAudioPCMBuffer) {
        guard isRunning, srcPCM.frameLength > 0,
              let converted = convertTo16kMono(srcPCM, converter: &callerConverter),
              let samples = converted.floatChannelData?[0] else { return }

        let rms = Self.computeRMS(samples: samples, count: Int(converted.frameLength))
        let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9
        checkTapPermissionHealth(rms: rms, now: now)

        let isMicSpeaking = stateLock.withLock { isMicCurrentlySpeaking }
        let threshold = (!isCallerActive && isMicSpeaking) ? Self.callerSpeechThreshold * 2.0 : Self.callerSpeechThreshold
        if rms >= threshold {
            callerConsecutiveVoiceFrames += 1
        } else {
            callerConsecutiveVoiceFrames = 0
        }

        let voiceDetected = callerConsecutiveVoiceFrames >= (isCallerActive ? 1 : 2)
        var outputs: [AVAudioPCMBuffer] = []

        if voiceDetected {
            if !isCallerActive {
                isCallerActive = true
                outputs.append(contentsOf: callerPreRoll)
                callerPreRoll.removeAll(keepingCapacity: true)
                callerPreRollFrames = 0
            }
            lastCallerSpeechTime = now
            outputs.append(converted)
        } else if isCallerActive && (now - lastCallerSpeechTime) < Self.callerHangover {
            outputs.append(converted)
        } else {
            isCallerActive = false
            appendPreRoll(converted, into: &callerPreRoll, totalFrames: &callerPreRollFrames)
        }

        let speakingNow = isCallerActive && ((now - lastCallerSpeechTime) < 0.55)
        let callerHeld = isCallerActive
        stateLock.withLock {
            rawCallerRMS = (rawCallerRMS * 0.55) + (rms * 0.45)
            if voiceDetected { lastCallerVoiceTime = now }
            isCallerCurrentlySpeaking = speakingNow
            callerHoldsVoice = callerHeld
            floorOwner = Self.resolveFloorOwner(current: floorOwner, isCallerActive: callerHeld, isUserActive: userHoldsVoice)
        }

        for pcm in outputs {
            delegate?.audioCaptureDidOutputCallerAudio(pcmBuffer: pcm)
        }
        dispatchSmoothedLevels(callerRMS: rms, micRMS: nil, now: now)
    }

    // MARK: - Microphone Capture (Conversational Mode)

    public func startMicrophone() throws {
        guard stateLock.withLock({ micShouldBeEnabled }) else { return }
        micLifecycleLock.lock()
        defer { micLifecycleLock.unlock() }
        guard stateLock.withLock({ micShouldBeEnabled }) else { return }

        let auth = AVCaptureDevice.authorizationStatus(for: .audio)
        if auth == .denied || auth == .restricted {
            stopMicWatchdog()
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
                    DispatchQueue.main.async {
                        guard let self else { return }
                        let keepEnabled = self.stateLock.withLock { () -> Bool in
                            self.isRequestingMicPermission = false
                            return self.micShouldBeEnabled
                        }
                        if granted && keepEnabled {
                            self.startMicWatchdog()
                            try? self.startMicrophone()
                        } else if !granted {
                            self.stopMicWatchdog()
                        }
                    }
                }
            }
            return
        }

        stateLock.withLock { isStartingMic = true }
        defer { stateLock.withLock { isStartingMic = false } }

        tearDownMicrophoneEngineOnly()
        guard Self.hasAvailableInputDevice() else {
            recordMicFailure(reason: "No audio input device available")
            return
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let busFormat = inputNode.outputFormat(forBus: 0)
        guard busFormat.sampleRate > 0, busFormat.channelCount > 0,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: busFormat.sampleRate, channels: 1, interleaved: false) else {
            recordMicFailure(reason: "Invalid microphone format")
            return
        }

        let scratchCap = max(AVAudioFrameCount(16384), AVAudioFrameCount(busFormat.sampleRate * 0.5))
        let pool = MicScratchPool(monoFormat: monoFormat, frameCapacity: scratchCap)
        let sessionGen = stateLock.withLock { () -> UInt64 in
            micSessionGeneration &+= 1
            return micSessionGeneration
        }

        atomicBestMicChannel.store(0, ordering: .relaxed)
        atomicIsMicRunning.store(true, ordering: .releasing)

        do {
            try AudioTapHelper.installTap(on: inputNode, bus: 0, bufferSize: 2048, format: nil) { [weak self, pool] buffer, _ in
                guard let self, self.atomicIsMicRunning.load(ordering: .acquiring) else { return }
                self.atomicLastMicBufferTime.store(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9, ordering: .relaxed)
                guard let slot = pool.acquireSlot() else { return }
                let scratch = pool.buffers[slot]
                guard self.convertAndCopyToMono(source: buffer, destination: scratch) else {
                    pool.releaseSlot(slot)
                    return
                }
                let box = SendablePCMBuffer(buffer: scratch)
                self.micQueue.async { [weak self, pool] in
                    defer { pool.releaseSlot(slot) }
                    self?.processMicAudioOnQueue(box.buffer, expectedGen: sessionGen)
                }
            }
        } catch {
            atomicIsMicRunning.store(false, ordering: .releasing)
            throw error
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            atomicIsMicRunning.store(false, ordering: .releasing)
            inputNode.removeTap(onBus: 0)
            throw error
        }

        let engineBox = Box(value: engine)
        atomicLastMicBufferTime.store(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9, ordering: .relaxed)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioEngineConfigChange(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
        stateLock.withLock {
            micAudioEngine = engineBox.value
            observedMicEngine = engineBox.value
            _isMicRunning = true
            micRecoveryFailures = 0
            nextMicRecoveryTime = 0
        }
        AppLog.audio.info("Microphone capture started (\(busFormat.sampleRate, privacy: .public)Hz, \(busFormat.channelCount, privacy: .public)ch)")
    }

    public func stopMicrophone() {
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
            isMicCurrentlySpeaking = false
            userHoldsVoice = false
            floorOwner = Self.resolveFloorOwner(current: floorOwner, isCallerActive: callerHoldsVoice, isUserActive: false)
            micRecoveryFailures = 0
            nextMicRecoveryTime = 0
            smoothedMicLevel = 0.0
            return item
        }
        oldItem?.value.cancel()
        stopMicWatchdog()
        tearDownMicrophoneEngineOnly(isDeallocating: isDeallocating)
    }

    private func tearDownMicrophoneEngineOnly(isDeallocating: Bool = false) {
        atomicIsMicRunning.store(false, ordering: .releasing)
        atomicLastMicBufferTime.store(0.0, ordering: .relaxed)

        let (engBox, obsBox) = stateLock.withLock { () -> (Box<AVAudioEngine>?, Box<AVAudioEngine>?) in
            micSessionGeneration &+= 1
            _isMicRunning = false
            isMicCurrentlySpeaking = false
            userHoldsVoice = false
            floorOwner = Self.resolveFloorOwner(current: floorOwner, isCallerActive: callerHoldsVoice, isUserActive: false)
            let e = micAudioEngine.map { Box(value: $0) }
            let o = observedMicEngine.map { Box(value: $0) }
            micAudioEngine = nil
            observedMicEngine = nil
            return (e, o)
        }

        if let observed = obsBox?.value {
            NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: observed)
        }
        if let engine = engBox?.value {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
        }
        guard !isDeallocating else { return }
        micQueue.async { [weak self] in
            guard let self else { return }
            self.micConverter = nil
            self.isMicActive = false
            self.micConsecutiveVoiceFrames = 0
            self.lastMicSpeechTime = 0
            self.micPreRoll.removeAll(keepingCapacity: false)
            self.micPreRollFrames = 0
        }
    }

    private func processMicAudioOnQueue(_ srcPCM: AVAudioPCMBuffer, expectedGen: UInt64) {
        let valid = stateLock.withLock { micShouldBeEnabled && _isMicRunning && micSessionGeneration == expectedGen }
        guard valid, srcPCM.frameLength > 0,
              let converted = convertTo16kMono(srcPCM, converter: &micConverter),
              let samples = converted.floatChannelData?[0] else { return }

        let rms = Self.computeRMS(samples: samples, count: Int(converted.frameLength))
        let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9

        let (callerRMS, callerSpeaking, lastCallerVoice, userHasFloor) = stateLock.withLock {
            (rawCallerRMS, isCallerCurrentlySpeaking, lastCallerVoiceTime, floorOwner == .user)
        }

        let isolated = Self.isAudioOutputAcousticallyIsolated()
        let timeSinceCaller = lastCallerVoice > 0 ? max(0, now - lastCallerVoice) : Double.greatestFiniteMagnitude
        let callerOrEchoActive = !isolated && (callerSpeaking || timeSinceCaller < Self.echoTailWindow)

        let effectiveThreshold: Float
        if callerOrEchoActive && !userHasFloor {
            let decay = Self.echoTailDecay(after: timeSinceCaller)
            effectiveThreshold = max(Self.micSpeechThreshold * 3.0, callerRMS * 3.5 * decay)
        } else if callerOrEchoActive && userHasFloor {
            effectiveThreshold = max(Self.micSpeechThreshold, callerRMS * 1.4)
        } else {
            effectiveThreshold = Self.micSpeechThreshold
        }

        if rms >= effectiveThreshold {
            micConsecutiveVoiceFrames += 1
        } else {
            micConsecutiveVoiceFrames = 0
        }

        let voiceDetected = micConsecutiveVoiceFrames >= (isMicActive ? 1 : (callerOrEchoActive ? 3 : 2))
        let bufStartTime = now - Double(converted.frameLength) / Self.speechFormat.sampleRate
        var outputs: [AVAudioPCMBuffer] = []
        var nextSpeaking: Bool?

        if voiceDetected {
            if !isMicActive {
                isMicActive = true
                let cutoff = lastCallerVoice > 0 ? lastCallerVoice + 0.25 : -Double.greatestFiniteMagnitude
                for entry in micPreRoll where entry.startTime >= cutoff || isolated {
                    outputs.append(entry.buffer)
                }
                micPreRoll.removeAll(keepingCapacity: true)
                micPreRollFrames = 0
            }
            nextSpeaking = true
            lastMicSpeechTime = now
            outputs.append(converted)
        } else if callerOrEchoActive && !userHasFloor {
            isMicActive = false
            nextSpeaking = false
            appendMicPreRoll(converted, startTime: bufStartTime)
        } else if isMicActive {
            let elapsed = now - lastMicSpeechTime
            if elapsed >= 0.45 { nextSpeaking = false }
            if elapsed < Self.micHangover {
                outputs.append(converted)
            } else {
                isMicActive = false
                nextSpeaking = false
                appendMicPreRoll(converted, startTime: bufStartTime)
            }
        } else {
            appendMicPreRoll(converted, startTime: bufStartTime)
        }

        let micActiveNow = isMicActive
        let speakingUpdate = nextSpeaking
        stateLock.withLock {
            if let speakingUpdate { isMicCurrentlySpeaking = speakingUpdate }
            userHoldsVoice = micActiveNow
            floorOwner = Self.resolveFloorOwner(current: floorOwner, isCallerActive: callerHoldsVoice, isUserActive: micActiveNow)
        }

        for pcm in outputs {
            delegate?.audioCaptureDidOutputMicAudio(pcmBuffer: pcm)
        }
        dispatchSmoothedLevels(callerRMS: nil, micRMS: (callerOrEchoActive && !voiceDetected) ? 0.0 : rms, now: now)
    }

    // MARK: - Helpers, Watchdogs & Hardware Observers

    private func appendPreRoll(_ buf: AVAudioPCMBuffer, into array: inout [AVAudioPCMBuffer], totalFrames: inout AVAudioFrameCount) {
        array.append(buf)
        totalFrames += buf.frameLength
        while totalFrames > Self.maxPreRollFrames, !array.isEmpty {
            totalFrames -= array.removeFirst().frameLength
        }
    }

    private func appendMicPreRoll(_ buf: AVAudioPCMBuffer, startTime: TimeInterval) {
        micPreRoll.append((buf, startTime))
        micPreRollFrames += buf.frameLength
        while micPreRollFrames > Self.maxPreRollFrames, !micPreRoll.isEmpty {
            micPreRollFrames -= micPreRoll.removeFirst().buffer.frameLength
        }
    }

    private func dispatchSmoothedLevels(callerRMS: Float?, micRMS: Float?, now: TimeInterval) {
        let levels = stateLock.withLock { () -> (Float, Float)? in
            if let c = callerRMS {
                let next = (smoothedCallerLevel * 0.65) + (min(1.0, c * 12.0) * 0.35)
                smoothedCallerLevel = next < 0.005 ? 0.0 : next
            }
            if let m = micRMS {
                let next = (smoothedMicLevel * 0.65) + (min(1.0, m * 14.0) * 0.35)
                smoothedMicLevel = next < 0.005 ? 0.0 : next
            }
            guard (now - lastLevelDispatchTime) >= 0.1 else { return nil }
            lastLevelDispatchTime = now
            return (smoothedCallerLevel, smoothedMicLevel)
        }
        if let (c, m) = levels {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.audioCaptureDidUpdateLevels(callerLevel: c, micLevel: m)
            }
        }
    }

    private func checkTapPermissionHealth(rms: Float, now: TimeInterval) {
        if rms > 0.0000001 {
            let (newlyActive, restored) = stateLock.withLock { () -> (Bool, Bool) in
                let first = !hasReceivedNonZeroCallerSignal
                let wasDenied = didReportDeniedTapPermission
                hasReceivedNonZeroCallerSignal = true
                hasEverReceivedNonZeroCallerSignal = true
                silentOutputStartTime = 0
                didReportDeniedTapPermission = false
                return (first, wasDenied)
            }
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
            guard !hasEverReceivedNonZeroCallerSignal, !didReportDeniedTapPermission,
                  tapStartTime > 0, (now - tapStartTime) >= 3.0,
                  (now - lastPermissionProbeTime) >= 1.0 else { return false }
            lastPermissionProbeTime = now
            return true
        }
        guard shouldProbe, isOtherProcessAudioActiveThrottled(now: now) else { return }

        let shouldAlert = stateLock.withLock { () -> Bool in
            guard !hasEverReceivedNonZeroCallerSignal, !isMicCurrentlySpeaking else {
                silentOutputStartTime = 0
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

    public static func isOtherProcessRunningAudioOutput(excludingProcessObjectID ownID: AudioObjectID) -> Bool {
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

    public static func isAudioOutputAcousticallyIsolated() -> Bool {
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

    @discardableResult
    private static func refreshIsolationCache() -> AudioDeviceID {
        let (devID, isolated) = queryAcousticIsolation()
        isolationState.withLock { state in
            state.cached = isolated
            state.primed = true
            state.refreshing = false
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

        var transport: UInt32 = 0
        var tSize = UInt32(MemoryLayout<UInt32>.size)
        var tAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(outID, &tAddr, 0, nil, &tSize, &transport) == noErr {
            if transport == kAudioDeviceTransportTypeBluetooth ||
               transport == kAudioDeviceTransportTypeBluetoothLE ||
               transport == kAudioDeviceTransportTypeAirPlay {
                return (outID, true)
            }
        }

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
            if ["headphone", "headset", "airpod", "earpod", "buds", "in-ear"].contains(where: { lower.contains($0) }) {
                return (outID, true)
            }
        }
        return (outID, false)
    }

    public static func hasAvailableInputDevice() -> Bool {
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

    private func setupHardwareObservers() {
        var inAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let inBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            if self.stateLock.withLock({ self.micShouldBeEnabled }) {
                self.scheduleMicRecovery(after: 0.35, resetBackoff: true)
            }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &inAddr, micQueue, inBlock) == noErr {
            let box = Box(value: inBlock)
            stateLock.withLock { defaultInputListenerBlock = box.value }
        }

        var outAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let outBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Self.isolationQueue.async { _ = Self.refreshIsolationCache() }
            if self.stateLock.withLock({ self.callerShouldBeEnabled }) {
                self.scheduleTapRebuild(attempt: 0, delay: 0.4)
            }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &outAddr, callerQueue, outBlock) == noErr {
            let box = Box(value: outBlock)
            stateLock.withLock { defaultOutputListenerBlock = box.value }
        }
        Self.isolationQueue.async { _ = Self.refreshIsolationCache() }
    }

    private func teardownHardwareObservers() {
        NotificationCenter.default.removeObserver(self)
        let (inBox, outBox) = stateLock.withLock { () -> (Box<AudioObjectPropertyListenerBlock>?, Box<AudioObjectPropertyListenerBlock>?) in
            isTornDownObservers = true
            let i = defaultInputListenerBlock.map { Box(value: $0) }
            let o = defaultOutputListenerBlock.map { Box(value: $0) }
            defaultInputListenerBlock = nil
            defaultOutputListenerBlock = nil
            return (i, o)
        }
        if let block = inBox?.value {
            var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, micQueue, block)
        }
        if let block = outBox?.value {
            var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, callerQueue, block)
        }
    }

    private func installTapFormatListeners(aggID: AudioObjectID, tapID: AudioObjectID, expectedGen: UInt64) {
        removeTapFormatListeners(aggID: aggID, tapID: tapID)
        var aggAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        let aggBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.stateLock.withLock({ self._isRunning && self.captureGeneration == expectedGen }) else { return }
            self.scheduleTapRebuild(attempt: 0, delay: 0.4)
        }
        if AudioObjectAddPropertyListenerBlock(aggID, &aggAddr, callerQueue, aggBlock) == noErr {
            let box = Box(value: aggBlock)
            let keep = stateLock.withLock { () -> Bool in
                guard _isRunning, captureGeneration == expectedGen else { return false }
                aggFormatListenerBlock = box.value
                aggFormatListenerDeviceID = aggID
                return true
            }
            if !keep { _ = AudioObjectRemovePropertyListenerBlock(aggID, &aggAddr, callerQueue, aggBlock) }
        }

        var tapAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let tapBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.stateLock.withLock({ self._isRunning && self.captureGeneration == expectedGen }) else { return }
            self.scheduleTapRebuild(attempt: 0, delay: 0.4)
        }
        if AudioObjectAddPropertyListenerBlock(tapID, &tapAddr, callerQueue, tapBlock) == noErr {
            let box = Box(value: tapBlock)
            let keep = stateLock.withLock { () -> Bool in
                guard _isRunning, captureGeneration == expectedGen else { return false }
                tapFormatListenerBlock = box.value
                tapFormatListenerTapID = tapID
                return true
            }
            if !keep { _ = AudioObjectRemovePropertyListenerBlock(tapID, &tapAddr, callerQueue, tapBlock) }
        }
    }

    private func removeTapFormatListeners(aggID: AudioObjectID, tapID: AudioObjectID) {
        let (aID, aBox, tID, tBox) = stateLock.withLock { () -> (AudioObjectID, Box<AudioObjectPropertyListenerBlock>?, AudioObjectID, Box<AudioObjectPropertyListenerBlock>?) in
            let aid = aggFormatListenerDeviceID != kAudioObjectUnknown ? aggFormatListenerDeviceID : aggID
            let ab = aggFormatListenerBlock.map { Box(value: $0) }
            aggFormatListenerBlock = nil
            aggFormatListenerDeviceID = kAudioObjectUnknown
            let tid = tapFormatListenerTapID != kAudioObjectUnknown ? tapFormatListenerTapID : tapID
            let tb = tapFormatListenerBlock.map { Box(value: $0) }
            tapFormatListenerBlock = nil
            tapFormatListenerTapID = kAudioObjectUnknown
            return (aid, ab, tid, tb)
        }
        if let ab = aBox?.value, aID != kAudioObjectUnknown {
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectRemovePropertyListenerBlock(aID, &a, callerQueue, ab)
        }
        if let tb = tBox?.value, tID != kAudioObjectUnknown {
            var t = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectRemovePropertyListenerBlock(tID, &t, callerQueue, tb)
        }
    }

    private func scheduleTapRebuild(attempt: Int, delay: TimeInterval = 0.5) {
        let plan = stateLock.withLock { () -> (UInt64, Box<DispatchWorkItem>?, TimeInterval)? in
            guard callerShouldBeEnabled else { return nil }
            if attempt == 0 && isRebuildingTap { return nil }
            isRebuildingTap = true
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
            let (stopGen, enabled) = self.stateLock.withLock { (self.stopGeneration, self.callerShouldBeEnabled) }
            var rebuildErr: Error?
            if enabled {
                self.tearDownCallerTapOnly(isStoppingPermanently: false)
                do {
                    try self.startCallerTapPipeline(entryStopGen: stopGen)
                } catch {
                    rebuildErr = error
                }
            }
            self.lifecycleLock.unlock()
            self.stateLock.withLock { self.isRebuildingTap = false }

            if let err = rebuildErr {
                if attempt < 2 && self.stateLock.withLock({ self.callerShouldBeEnabled }) {
                    self.scheduleTapRebuild(attempt: attempt + 1)
                } else {
                    self.stateLock.withLock { self.nextCallerRecoveryTime = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9 + 10.0 }
                    DispatchQueue.main.async { [weak self] in
                        self?.delegate?.audioCaptureDidEncounterError(err)
                    }
                }
            }
        }
        let itemBox = Box(value: item)
        stateLock.withLock { if tapRebuildGeneration == gen { tapRebuildWorkItem = itemBox.value } }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + waitDelay, execute: item)
    }

    @objc private func handleAudioEngineConfigChange(_ notification: Notification) {
        let matches = stateLock.withLock { micShouldBeEnabled && micAudioEngine != nil }
        if matches { scheduleMicRecovery(after: 0.35, resetBackoff: false) }
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
            } else if isRecoveringMic || isStartingMic || isRequestingMicPermission || now < nextMicRecoveryTime {
                return nil
            }
            micRecoveryGeneration &+= 1
            isRecoveringMic = true
            let backoff = micRecoveryFailures > 0 ? min(10.0, 0.5 * pow(2.0, Double(micRecoveryFailures - 1))) : delay
            return (micRecoveryGeneration, prev, max(delay, backoff))
        }
        guard let (gen, prevItem, waitDelay) = plan else { return }
        prevItem?.value.cancel()

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.stateLock.withLock({ self.micRecoveryGeneration == gen && self.micShouldBeEnabled }) else {
                self.stateLock.withLock { if self.micRecoveryGeneration == gen { self.isRecoveringMic = false } }
                return
            }
            defer { self.stateLock.withLock { if self.micRecoveryGeneration == gen { self.isRecoveringMic = false } } }
            do { try self.startMicrophone() } catch { self.recordMicFailure(reason: error.localizedDescription) }
        }
        let box = Box(value: item)
        stateLock.withLock { if micRecoveryGeneration == gen { micRecoveryWorkItem = box.value } }
        DispatchQueue.main.asyncAfter(deadline: .now() + waitDelay, execute: item)
    }

    private func recordMicFailure(reason: String) {
        let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9
        let (failures, shouldAlert) = stateLock.withLock { () -> (Int, Bool) in
            micRecoveryFailures += 1
            nextMicRecoveryTime = now + min(10.0, 0.5 * pow(2.0, Double(micRecoveryFailures - 1)))
            return (micRecoveryFailures, micRecoveryFailures == 4)
        }
        AppLog.audio.warning("Mic failure #\(failures, privacy: .public): \(reason, privacy: .public)")
        if shouldAlert {
            let err = NSError(domain: "AudioCaptureEngine", code: -1001, userInfo: [NSLocalizedDescriptionKey: "Microphone unavailable"])
            DispatchQueue.main.async { [weak self] in self?.delegate?.audioCaptureDidEncounterError(err) }
        }
    }

    private func startCallerWatchdog() {
        stopCallerWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: callerQueue)
        timer.schedule(deadline: .now() + 3.0, repeating: 3.0)
        timer.setEventHandler { [weak self] in
            guard let self, PermissionHelper.shared.audioCaptureState != .deniedSilenceDetected else { return }
            let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9
            let lastBuf = self.callerTimestampAtomic.atomic.load(ordering: .relaxed)
            let (enabled, running, rebuilding, startTime, nextAllowed) = self.stateLock.withLock {
                (self.callerShouldBeEnabled, self._isRunning, self.isRebuildingTap, self.tapStartTime, self.nextCallerRecoveryTime)
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
        timer.resume()
        let old = stateLock.withLock { () -> DispatchSourceTimer? in
            let p = callerWatchdogTimer; callerWatchdogTimer = timer; return p
        }
        old?.cancel()
    }

    private func stopCallerWatchdog() {
        stateLock.withLock { let t = callerWatchdogTimer; callerWatchdogTimer = nil; return t }?.cancel()
    }

    private func startMicWatchdog() {
        stopMicWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: micQueue)
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
            let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9
            let lastMicBuf = self.atomicLastMicBufferTime.load(ordering: .relaxed)
            let needsRestart = self.stateLock.withLock { () -> Bool in
                guard self.micShouldBeEnabled, now >= self.nextMicRecoveryTime,
                      !self.isRecoveringMic, !self.isStartingMic, !self.isRequestingMicPermission else { return false }
                let engRunning = self.micAudioEngine?.isRunning ?? false
                let stalled = lastMicBuf > 0 && (now - lastMicBuf) > 2.2
                return !self._isMicRunning || !engRunning || stalled
            }
            if needsRestart { self.scheduleMicRecovery(after: 0.2, resetBackoff: false) }
        }
        timer.resume()
        let old = stateLock.withLock { () -> DispatchSourceTimer? in
            let p = micWatchdogTimer; micWatchdogTimer = timer; return p
        }
        old?.cancel()
    }

    private func stopMicWatchdog() {
        stateLock.withLock { let t = micWatchdogTimer; micWatchdogTimer = nil; return t }?.cancel()
    }

    // MARK: - Audio Conversion

    private func convertTo16kMono(_ buffer: AVAudioPCMBuffer, converter: inout AVAudioConverter?) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        let target = Self.speechFormat
        if buffer.format.sampleRate == target.sampleRate && buffer.format.channelCount == 1 && buffer.format.commonFormat == .pcmFormatFloat32 {
            guard let src = buffer.floatChannelData?[0],
                  let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: buffer.frameLength),
                  let dst = out.floatChannelData?[0] else { return nil }
            out.frameLength = buffer.frameLength
            memcpy(dst, src, Int(buffer.frameLength) * MemoryLayout<Float>.size)
            return out
        }
        if converter == nil || converter?.inputFormat != buffer.format {
            let conv = AVAudioConverter(from: buffer.format, to: target)
            if let conv, conv.channelMap.contains(-1) { conv.channelMap = [0] }
            converter = conv
        }
        guard let conv = converter else { return nil }
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * (target.sampleRate / buffer.format.sampleRate) + 16)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: max(cap, 1024)) else { return nil }
        var err: NSError?
        var supplied = false
        let status = conv.convert(to: out, error: &err) { _, outStatus in
            if !supplied { supplied = true; outStatus.pointee = .haveData; return buffer }
            outStatus.pointee = .noDataNow
            return nil
        }
        return (status == .error || err != nil || out.frameLength == 0) ? nil : out
    }

    @discardableResult
    public func convertAndCopyToMono(source buffer: AVAudioPCMBuffer, destination mono: AVAudioPCMBuffer) -> Bool {
        let frames = buffer.frameLength
        guard frames > 0, mono.frameCapacity >= frames, let dst = mono.floatChannelData?[0] else { return false }
        mono.frameLength = frames
        let channels = Int(max(1, buffer.format.channelCount))
        let countInt = Int(frames)
        let vLen = vDSP_Length(frames)
        let preferredCh = channels > 2 ? min(channels - 1, max(0, atomicBestMicChannel.load(ordering: .relaxed))) : 0

        if !buffer.format.isInterleaved, let src = buffer.floatChannelData {
            let bytes = countInt * MemoryLayout<Float>.size
            if channels == 1 {
                memcpy(dst, src[0], bytes)
                return true
            } else if channels == 2 {
                var half: Float = 0.5
                vDSP_vasm(src[0], 1, src[1], 1, &half, dst, 1, vLen)
                return true
            } else {
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

        guard let floatMono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: buffer.format, to: floatMono) else { return false }
        if conv.channelMap.contains(-1) { conv.channelMap = [0] }
        var err: NSError?
        var supplied = false
        let status = conv.convert(to: mono, error: &err) { _, outStatus in
            if !supplied { supplied = true; outStatus.pointee = .haveData; return buffer }
            outStatus.pointee = .noDataNow
            return nil
        }
        return status != .error && err == nil && mono.frameLength > 0
    }
}
