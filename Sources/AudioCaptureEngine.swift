import Foundation
import CoreAudio
import AudioToolbox
@preconcurrency import AVFoundation
import Accelerate
import os
import Synchronization

public protocol AudioCaptureDelegate: AnyObject {
    func audioCaptureDidOutputCallerAudio(pcmBuffer: AVAudioPCMBuffer)
    func audioCaptureDidUpdateCallerLevel(_ level: Float)
    func audioCaptureDidOutputMicAudio(pcmBuffer: AVAudioPCMBuffer)
    func audioCaptureDidUpdateMicLevel(_ level: Float)
    func audioCaptureDidEncounterError(_ error: Error)
    func audioCaptureDidDetectDeniedTapPermission()
    func audioCaptureDidRestoreTapPermission()
}

public extension AudioCaptureDelegate {
    func audioCaptureDidRestoreTapPermission() {}
}

public enum SpeechFloorOwner: String, Sendable, Equatable {
    case none
    case caller
    case user
}

public enum AudioSignalCheckStatus: String, Sendable, Equatable {
    case inactive
    case permissionDenied
    case waitingForAudio
    case tooQuiet
    case optimal
    case tooLoud
    case highNoiseFloor
    case echoSuppressed

    public var badgeTitle: String {
        switch self {
        case .inactive: return "Off"
        case .permissionDenied: return "Denied"
        case .waitingForAudio: return "Listening"
        case .tooQuiet: return "Low Signal"
        case .optimal: return "Good Level"
        case .tooLoud: return "High Level"
        case .highNoiseFloor: return "Noisy Line"
        case .echoSuppressed: return "Echo Guard"
        }
    }

    public var isHealthy: Bool {
        switch self {
        case .optimal, .waitingForAudio, .echoSuppressed:
            return true
        case .inactive, .permissionDenied, .tooQuiet, .tooLoud, .highNoiseFloor:
            return false
        }
    }
}

public struct AudioChannelDiagnostics: Sendable, Equatable {
    public let isRunning: Bool
    public let hasPermission: Bool
    public let rawRMS: Float
    public let calibratedRMS: Float
    public let displayLevel: Float
    public let peakLevel: Float
    public let noiseFloorRMS: Float
    public let estimatedSpeechRMS: Float
    public let inputGain: Float
    public let agcGain: Float
    public let effectiveThreshold: Float
    public let isVoiceDetected: Bool
    public let status: AudioSignalCheckStatus

    public var effectiveTotalGain: Float {
        inputGain * agcGain
    }

    public var inputGainDecibels: Float {
        guard inputGain > 0.0001 else { return -60.0 }
        return 20.0 * log10(inputGain)
    }

    public var snrDecibels: Float {
        let safeGain = max(0.0001, inputGain.isFinite ? inputGain : 1.0)
        let floor = max(noiseFloorRMS * safeGain, 0.00005 * safeGain)
        let signal = max(estimatedSpeechRMS * safeGain, calibratedRMS, floor)
        return max(0.0, 20.0 * log10(signal / floor))
    }
}

public struct AudioCheckSnapshot: Sendable, Equatable {
    public let caller: AudioChannelDiagnostics
    public let mic: AudioChannelDiagnostics
    public let isAcousticallyIsolated: Bool
    public let isAutoGainEnabled: Bool
    public let isCalibrating: Bool
}

public final class AudioCaptureEngine: NSObject, @unchecked Sendable {
    private struct SendablePCMBuffer: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }

    private struct UncheckedSendableBox<Value>: @unchecked Sendable {
        let value: Value
    }

    private final class AtomicBox<Value: AtomicRepresentable>: @unchecked Sendable {
        let atomic: Atomic<Value>
        init(_ initialValue: Value) {
            self.atomic = Atomic<Value>(initialValue)
        }
    }

    /// Lock-free Single-Producer Single-Consumer ring buffer for CoreAudio IOProc -> callerQueue audio handoff.
    private final class CallerAudioRingBuffer: @unchecked Sendable {
        let capacity: Int
        private let mask: Int
        private let buffer: UnsafeMutablePointer<Float>
        private let head = Atomic<Int>(0)
        private let tail = Atomic<Int>(0)

        static func nextPowerOfTwo(atLeast minCount: Int) -> Int {
            var cap = 1024
            while cap < minCount {
                cap <<= 1
            }
            return cap
        }

        init(capacityPowerOfTwo: Int) {
            let cap = Self.nextPowerOfTwo(atLeast: capacityPowerOfTwo)
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
            let used = currentTail &- currentHead
            let freeSpace = capacity &- used
            guard count <= freeSpace else { return false }

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
            let currentHead = head.load(ordering: .relaxed)
            let currentTail = tail.load(ordering: .acquiring)
            let available = currentTail &- currentHead
            guard available > 0 else { return 0 }

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

    /// Immutable per-session scratch pool with lock-free atomic slot ownership tracking.
    private final class MicScratchPool: @unchecked Sendable {
        let monoFormat: AVAudioFormat
        let frameCapacity: AVAudioFrameCount
        let buffers: [AVAudioPCMBuffer]
        private let freeMask: Atomic<UInt32>

        init(monoFormat: AVAudioFormat, frameCapacity: AVAudioFrameCount, poolSize: Int) {
            self.monoFormat = monoFormat
            self.frameCapacity = frameCapacity
            let clampedSize = min(31, max(1, poolSize))
            var built: [AVAudioPCMBuffer] = []
            built.reserveCapacity(clampedSize)
            for _ in 0..<clampedSize {
                if let buf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCapacity) {
                    built.append(buf)
                }
            }
            self.buffers = built
            let initialMask: UInt32 = built.isEmpty ? 0 : ((UInt32(1) << built.count) - 1)
            self.freeMask = Atomic<UInt32>(initialMask)
        }

        @inline(__always)
        func acquireSlot() -> Int? {
            var current = freeMask.load(ordering: .acquiring)
            while current != 0 {
                let index = current.trailingZeroBitCount
                let bit = UInt32(1) << index
                let desired = current & ~bit
                let (exchanged, original) = freeMask.compareExchange(
                    expected: current,
                    desired: desired,
                    successOrdering: .acquiringAndReleasing,
                    failureOrdering: .acquiring
                )
                if exchanged {
                    return index
                }
                current = original
            }
            return nil
        }

        @inline(__always)
        func releaseSlot(_ index: Int) {
            guard index >= 0, index < buffers.count else { return }
            let bit = UInt32(1) << index
            _ = freeMask.bitwiseOr(bit, ordering: .releasing)
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

    private var tapObjectID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ownProcessObjectID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID? = nil
    private var streamFormat: AVAudioFormat?
    private var aggFormatListenerBlock: AudioObjectPropertyListenerBlock?
    private var aggFormatListenerDeviceID: AudioObjectID = kAudioObjectUnknown
    private var tapFormatListenerBlock: AudioObjectPropertyListenerBlock?
    private var tapFormatListenerTapID: AudioObjectID = kAudioObjectUnknown
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?
    private var monitoredOutputDeviceID: AudioObjectID = kAudioObjectUnknown
    private var outputDataSourceListenerBlock: AudioObjectPropertyListenerBlock?
    private var isTornDownHardwareObservers: Bool = false
    private var isRebuildingTap: Bool = false
    private var isExecutingTapRebuild: Bool = false
    private var hasPendingTapRebuildRequest: Bool = false
    private var tapRebuildDebounceCount: Int = 0
    private var tapRebuildGeneration: UInt64 = 0

    private var callerShouldBeEnabled: Bool = false
    private var tapRebuildRetryCount: Int = 0
    private var tapRebuildWorkItem: DispatchWorkItem? = nil

    private var cachedOtherProcessAudioActive: Bool = false
    private var lastOtherProcessQueryTime: TimeInterval = 0
    private var isQueryingOtherProcessAudio: Bool = false

    private var callerWakeSource: DispatchSourceUserDataAdd?
    private var callerRingBuffer: CallerAudioRingBuffer?
    private let callerTimestampAtomic = AtomicBox<Double>(0.0)
    private let callerDroppedAtomic = AtomicBox<UInt64>(0)
    private var lastCallerDropLogTime: TimeInterval = 0
    private var callerReusableSrcPCM: AVAudioPCMBuffer? = nil

    private var _isRunning: Bool = false
    public var isRunning: Bool {
        stateLock.withLock { _isRunning }
    }

    private var captureGeneration: UInt64 = 0
    private var stopGeneration: UInt64 = 0
    private var activeStartStopGeneration: UInt64 = 0
    private var activeStartToken: UUID? = nil
    private var pendingStartEnableMic: Bool = false
    private var callerWatchdogTimer: DispatchSourceTimer?
    private var nextAllowedCallerRecoveryTime: TimeInterval = 0
    private let callerQueue = DispatchQueue(label: "com.callcaption.callerAudioQueue", qos: .userInteractive)
    private let callerQueueKey = DispatchSpecificKey<Void>()
    private let micQueue = DispatchQueue(label: "com.callcaption.micAudioQueue", qos: .userInteractive)

    private var smoothedCallerLevel: Float = 0.0
    private var lastDispatchedCallerLevel: Float = 0.0
    private var rawCallerRMS: Float = 0.0
    private var callerPeakEnvelope: Float = 0.0
    private var lastCallerPeakTime: TimeInterval = 0
    private var lastCallerVoiceTimestamp: TimeInterval = 0
    private var lastCallerLevelDispatchTime: TimeInterval = 0
    private var isStartingEngine: Bool = false

    private var tapStartTime: TimeInterval = 0
    private var hasReceivedNonZeroCallerSignal: Bool = false
    private var hasEverReceivedNonZeroCallerSignal: Bool = false
    private var lastPermissionProbeTime: TimeInterval = 0
    private var silentWhileOutputActiveStartTime: TimeInterval = 0
    private var didReportDeniedTapPermission: Bool = false

    private var micAudioEngine: AVAudioEngine?
    private var observedMicConfigEngine: AVAudioEngine?
    private var _isMicRunning: Bool = false
    private var isStartingMic: Bool = false
    private var isRequestingMicPermission: Bool = false
    private var micShouldBeEnabled: Bool = false
    private var isMicAuthorized: Bool = false
    private var hasReceivedNonZeroMicSignal: Bool = false
    private var didAttemptZeroSignalRecovery: Bool = false
    private var micStartTime: TimeInterval = 0
    private var isRecoveringMic: Bool = false
    private var micRecoveryFailures: Int = 0
    private var nextAllowedMicRecoveryTime: TimeInterval = 0
    private var micRecoveryWorkItem: DispatchWorkItem? = nil
    private var micRecoveryGeneration: UInt64 = 0
    private var micSessionGeneration: UInt64 = 0
    private var didReportMicFailureAlert: Bool = false
    private var isMicCurrentlySpeaking: Bool = false
    private var isCallerCurrentlySpeaking: Bool = false
    /// Turn-taking state: whoever started speaking first keeps the floor until
    /// their own VAD hangover ends. Guarded by `stateLock`.
    private var floorOwner: SpeechFloorOwner = .none
    private var callerHoldsVoice: Bool = false
    private var userHoldsVoice: Bool = false
    private var micWatchdogTimer: DispatchSourceTimer?
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?

    private let atomicIsMicRunning = Atomic<Bool>(false)
    private let atomicLastMicBufferTime = Atomic<Double>(0.0)
    private let atomicSelectedMicCapsuleChannel = Atomic<Int>(0)
    private let atomicDroppedMicBuffers = Atomic<UInt64>(0)
    private var lastMicDropLogTime: TimeInterval = 0
    public static let micScratchPoolCapacity = 16
    public static let micScratchFrameCapacity: AVAudioFrameCount = 16384

    public var isMicRunning: Bool {
        atomicIsMicRunning.load(ordering: .relaxed)
    }

    /// True while the mic gate has accepted the signal as the user's own voice
    /// (not speaker echo). Used by the recognizer to hand the floor to the user.
    public var isUserSpeechActive: Bool {
        stateLock.withLock { isMicCurrentlySpeaking }
    }

    /// Who currently holds the speaking floor. The side that started talking
    /// first keeps it until its own hangover ends, so the other side cannot
    /// interrupt an in-progress caption.
    public var speechFloorOwner: SpeechFloorOwner {
        stateLock.withLock { floorOwner }
    }

    /// Floor arbitration: the current holder keeps the floor while it is still
    /// active; otherwise it passes to whichever side is active (caller wins a
    /// perfectly simultaneous start because system audio carries no echo).
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
        if current == .caller, isUserActive { return .user }
        if current == .user, isCallerActive { return .caller }
        if isCallerActive { return .caller }
        if isUserActive { return .user }
        return .none
    }

    /// Mic gate used while the user already holds the floor and the caller
    /// starts talking over them on open speakers. Instead of the strict echo
    /// gate (which cut the user off mid-sentence) the user's own speech level
    /// is used as reference: speaker echo is far quieter than a voice next to
    /// the mic, so the reply keeps flowing until the user actually stops.
    public static func userFloorHoldThreshold(
        micSpeechThreshold: Float,
        estimatedUserSpeechRMS: Float
    ) -> Float {
        let base = max(0.0, micSpeechThreshold.isFinite ? micSpeechThreshold : 0.0)
        guard estimatedUserSpeechRMS.isFinite, estimatedUserSpeechRMS > 0.0001 else {
            return base * 4.0
        }
        return max(base * 2.0, estimatedUserSpeechRMS * 0.35)
    }
    private var smoothedMicLevel: Float = 0.0
    private var lastDispatchedMicLevel: Float = 0.0
    private var lastMicLevelDispatchTime: TimeInterval = 0

    public static let defaultCallerSpeechThreshold: Float = 0.0014
    public static let defaultCallerBargeInThreshold: Float = 0.0075
    public static let defaultMicSpeechThreshold: Float = 0.0026
    public static let defaultTargetSpeechRMS: Float = 0.045
    private let callerSpeechThreshold: Float = AudioCaptureEngine.defaultCallerSpeechThreshold
    private let micSpeechThreshold: Float = AudioCaptureEngine.defaultMicSpeechThreshold
    private let callerHangoverDuration: TimeInterval = 0.70
    private let micHangoverDuration: TimeInterval = 1.00
    private let maxPreRollFrames: AVAudioFrameCount = 9600

    private var callerNoiseFloorRMS: Float = 0.0003
    private var callerEstimatedSpeechRMS: Float = 0.0
    private var callerCalibratedRMS: Float = 0.0
    private var callerSignalPeak: Float = 0.0
    private var callerEffectiveThreshold: Float = AudioCaptureEngine.defaultCallerSpeechThreshold
    private var callerLastAutoGainUpdateTime: TimeInterval = 0
    private var callerLatestAGCGain: Float = 1.0

    private var micNoiseFloorRMS: Float = 0.0005
    private var micEstimatedSpeechRMS: Float = 0.0
    private var micRawRMS: Float = 0.0
    private var micCalibratedRMS: Float = 0.0
    private var micSignalPeak: Float = 0.0
    private var micEffectiveThreshold: Float = AudioCaptureEngine.defaultMicSpeechThreshold
    private var micIsEchoSuppressedNow: Bool = false
    private var micLastAutoGainUpdateTime: TimeInterval = 0
    private var micLatestAGCGain: Float = 1.0

    private var isCalibratingPass: Bool = false
    private var calibrationGeneration: UInt64 = 0

    private var callerMonoFormat: AVAudioFormat? = nil
    private var callerConverter: AVAudioConverter? = nil
    private var isCallerActive: Bool = false
    private var callerConsecutiveVoiceFrames: Int = 0
    private var lastCallerSpeechTime: TimeInterval = 0
    private var callerPreRoll: [AVAudioPCMBuffer] = []
    private var callerPreRollFrames: AVAudioFrameCount = 0
    private var callerAGCGain: Float = 1.0

    private var cachedTapMonoFormat: AVAudioFormat? = nil
    private var micConverter: AVAudioConverter? = nil
    private var isMicActive: Bool = false
    private var micConsecutiveVoiceFrames: Int = 0
    private var lastMicSpeechTime: TimeInterval = 0
    private struct TimedPCMBuffer {
        let buffer: AVAudioPCMBuffer
        let startTime: TimeInterval
    }
    private var micPreRoll: [TimedPCMBuffer] = []
    private var micPreRollFrames: AVAudioFrameCount = 0
    private var micAGCGain: Float = 1.0

    public var callerLevel: Float {
        stateLock.withLock { smoothedCallerLevel }
    }

    public var micLevel: Float {
        stateLock.withLock { smoothedMicLevel }
    }

    public var isCalibrating: Bool {
        stateLock.withLock { isCalibratingPass }
    }

    public func diagnosticsSnapshot() -> AudioCheckSnapshot {
        let settings = AppSettings.shared
        let cGain = settings.callerInputGain
        let mGain = settings.micInputGain
        let autoGain = settings.isAutoGainEnabled
        let isolated = Self.isAudioOutputAcousticallyIsolated()

        let callerPermOK = PermissionHelper.shared.audioCaptureState != .deniedSilenceDetected
        let micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
        let micPermOK = (micAuth == .authorized) || (micAuth == .notDetermined && isMicRunning)

        return stateLock.withLock {
            let callerStatus = Self.classifySignalStatus(
                isRunning: _isRunning,
                hasPermission: callerPermOK,
                rawRMS: rawCallerRMS,
                calibratedRMS: callerCalibratedRMS,
                peakLevel: callerSignalPeak,
                noiseFloorRMS: callerNoiseFloorRMS * cGain,
                estimatedSpeechRMS: callerEstimatedSpeechRMS * cGain,
                baseThreshold: callerSpeechThreshold,
                isEchoSuppressed: false
            )
            let callerDiag = AudioChannelDiagnostics(
                isRunning: _isRunning,
                hasPermission: callerPermOK,
                rawRMS: rawCallerRMS,
                calibratedRMS: callerCalibratedRMS,
                displayLevel: smoothedCallerLevel,
                peakLevel: callerSignalPeak,
                noiseFloorRMS: callerNoiseFloorRMS,
                estimatedSpeechRMS: callerEstimatedSpeechRMS,
                inputGain: cGain,
                agcGain: callerLatestAGCGain,
                effectiveThreshold: callerEffectiveThreshold,
                isVoiceDetected: isCallerCurrentlySpeaking,
                status: callerStatus
            )

            let micRunning = _isMicRunning
            let micStatus = Self.classifySignalStatus(
                isRunning: micRunning,
                hasPermission: micPermOK && micAuth != .denied,
                rawRMS: micRawRMS,
                calibratedRMS: micCalibratedRMS,
                peakLevel: micSignalPeak,
                noiseFloorRMS: micNoiseFloorRMS * mGain,
                estimatedSpeechRMS: micEstimatedSpeechRMS * mGain,
                baseThreshold: micSpeechThreshold,
                isEchoSuppressed: micIsEchoSuppressedNow
            )
            let micDiag = AudioChannelDiagnostics(
                isRunning: micRunning,
                hasPermission: micPermOK && micAuth != .denied,
                rawRMS: micRawRMS,
                calibratedRMS: micCalibratedRMS,
                displayLevel: smoothedMicLevel,
                peakLevel: micSignalPeak,
                noiseFloorRMS: micNoiseFloorRMS,
                estimatedSpeechRMS: micEstimatedSpeechRMS,
                inputGain: mGain,
                agcGain: micLatestAGCGain,
                effectiveThreshold: micEffectiveThreshold,
                isVoiceDetected: isMicCurrentlySpeaking,
                status: micStatus
            )

            return AudioCheckSnapshot(
                caller: callerDiag,
                mic: micDiag,
                isAcousticallyIsolated: isolated,
                isAutoGainEnabled: autoGain,
                isCalibrating: isCalibratingPass
            )
        }
    }

    @discardableResult
    public func calibrateGainsNow() -> (callerGain: Float, micGain: Float) {
        let currentCallerGain = AppSettings.shared.callerInputGain
        let currentMicGain = AppSettings.shared.micInputGain

        let (cSpeech, cFloor, cPeak, mSpeech, mFloor, mPeak) = stateLock.withLock {
            let effectiveCSpeech = callerEstimatedSpeechRMS > 0.0004 ? callerEstimatedSpeechRMS : rawCallerRMS
            let effectiveMSpeech = micEstimatedSpeechRMS > 0.0004 ? micEstimatedSpeechRMS : micRawRMS
            return (
                effectiveCSpeech,
                callerNoiseFloorRMS,
                callerSignalPeak,
                effectiveMSpeech,
                micNoiseFloorRMS,
                micSignalPeak
            )
        }

        let newCallerGain = Self.computeCalibratedInputGain(
            currentGain: currentCallerGain,
            estimatedSpeechRMS: cSpeech,
            noiseFloorRMS: cFloor,
            peakLevel: cPeak,
            targetSpeechRMS: Self.defaultTargetSpeechRMS,
            baseThreshold: callerSpeechThreshold
        )
        let newMicGain = Self.computeCalibratedInputGain(
            currentGain: currentMicGain,
            estimatedSpeechRMS: mSpeech,
            noiseFloorRMS: mFloor,
            peakLevel: mPeak,
            targetSpeechRMS: Self.defaultTargetSpeechRMS,
            baseThreshold: micSpeechThreshold
        )

        AppSettings.shared.callerInputGain = newCallerGain
        AppSettings.shared.micInputGain = newMicGain
        return (newCallerGain, newMicGain)
    }

    public func startGuidedCalibration(
        duration: TimeInterval = 3.0,
        completion: (@Sendable (AudioCheckSnapshot) -> Void)? = nil
    ) {
        let gen = stateLock.withLock { () -> UInt64 in
            calibrationGeneration &+= 1
            isCalibratingPass = true
            return calibrationGeneration
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, duration)) { [weak self] in
            guard let self = self else { return }
            let isCurrent = self.stateLock.withLock { () -> Bool in
                guard self.calibrationGeneration == gen, self.isCalibratingPass else { return false }
                self.isCalibratingPass = false
                return true
            }
            guard isCurrent else { return }
            _ = self.calibrateGainsNow()
            let snapshot = self.diagnosticsSnapshot()
            completion?(snapshot)
        }
    }

    public func resetCalibrationState() {
        stateLock.withLock {
            calibrationGeneration &+= 1
            isCalibratingPass = false
            callerNoiseFloorRMS = 0.0003
            callerEstimatedSpeechRMS = 0.0
            callerCalibratedRMS = 0.0
            callerSignalPeak = 0.0
            callerEffectiveThreshold = callerSpeechThreshold
            callerLatestAGCGain = 1.0
            micNoiseFloorRMS = 0.0005
            micEstimatedSpeechRMS = 0.0
            micRawRMS = 0.0
            micCalibratedRMS = 0.0
            micSignalPeak = 0.0
            micEffectiveThreshold = micSpeechThreshold
            micIsEchoSuppressedNow = false
            micLatestAGCGain = 1.0
        }
        AppSettings.shared.resetAudioCalibration()
    }

    public override init() {
        super.init()
        callerQueue.setSpecific(key: callerQueueKey, value: ())
        setupHardwareObservers()
    }

    deinit {
        teardownHardwareObservers()
        stop(isDeallocating: true)
    }


    public static func computeRMS(samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0.0 }
        var rmsVal: Float = 0.0
        vDSP_rmsqv(samples, 1, &rmsVal, vDSP_Length(count))
        return rmsVal.isFinite ? rmsVal : 0.0
    }

    public static func computePeak(samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0.0 }
        var peakVal: Float = 0.0
        vDSP_maxmgv(samples, 1, &peakVal, vDSP_Length(count))
        return peakVal.isFinite ? peakVal : 0.0
    }

    @discardableResult
    public static func applyGainInPlace(
        _ buffer: AVAudioPCMBuffer,
        gain: Float,
        clipLimit: Float = 0.96
    ) -> (postRMS: Float, peak: Float) {
        guard let ptr = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
            return (0.0, 0.0)
        }
        let count = Int(buffer.frameLength)
        let vLen = vDSP_Length(count)
        let clampedGain = AppSettings.clampInputGain(gain)
        if abs(clampedGain - 1.0) > 0.005 {
            var g = clampedGain
            vDSP_vsmul(ptr, 1, &g, ptr, 1, vLen)
        }
        var peak = computePeak(samples: ptr, count: count)
        if peak > clipLimit {
            var low = -clipLimit
            var high = clipLimit
            vDSP_vclip(ptr, 1, &low, &high, ptr, 1, vLen)
            peak = computePeak(samples: ptr, count: count)
        }
        let rms = computeRMS(samples: ptr, count: count)
        return (rms, peak)
    }

    public static func updateNoiseFloorEstimate(
        currentFloor: Float,
        sampleRMS: Float,
        isVoiceDetected: Bool
    ) -> Float {
        guard sampleRMS.isFinite, sampleRMS > 0.000005 else {
            return max(0.0001, currentFloor)
        }
        let floor = max(0.0001, currentFloor.isFinite ? currentFloor : 0.0004)
        if sampleRMS <= floor {
            return max(0.0001, (floor * 0.80) + (sampleRMS * 0.20))
        }
        if !isVoiceDetected {
            let updated = (floor * 0.985) + (sampleRMS * 0.015)
            return min(0.025, max(0.0001, updated))
        }
        return floor
    }

    public static func adaptiveSpeechThreshold(
        baseThreshold: Float,
        noiseFloorRMS: Float
    ) -> Float {
        let safeBase = max(0.0005, baseThreshold)
        let safeFloor = max(0.0, noiseFloorRMS.isFinite ? noiseFloorRMS : 0.0)
        return min(safeBase * 4.5, max(safeBase, safeFloor * 3.0))
    }

    public static func computeCalibratedInputGain(
        currentGain: Float,
        estimatedSpeechRMS: Float,
        noiseFloorRMS: Float,
        peakLevel: Float,
        targetSpeechRMS: Float = AudioCaptureEngine.defaultTargetSpeechRMS,
        baseThreshold: Float = 0.0020
    ) -> Float {
        let safeCurrent = AppSettings.clampInputGain(currentGain)
        if peakLevel > 0.92 {
            return AppSettings.clampInputGain(safeCurrent * 0.82)
        }
        guard estimatedSpeechRMS.isFinite, estimatedSpeechRMS >= 0.0006 else {
            return safeCurrent
        }
        var desired = AppSettings.clampInputGain(targetSpeechRMS / estimatedSpeechRMS)
        if noiseFloorRMS.isFinite && noiseFloorRMS > 0.0002 {
            let maxGainForNoise = max(1.0, (max(baseThreshold, 0.0014) * 2.0) / noiseFloorRMS)
            if desired > maxGainForNoise {
                desired = maxGainForNoise
            }
        }
        let blended = (safeCurrent * 0.65) + (desired * 0.35)
        return AppSettings.clampInputGain(blended)
    }

    public static func classifySignalStatus(
        isRunning: Bool,
        hasPermission: Bool,
        rawRMS: Float,
        calibratedRMS: Float,
        peakLevel: Float,
        noiseFloorRMS: Float,
        estimatedSpeechRMS: Float,
        baseThreshold: Float,
        isEchoSuppressed: Bool = false
    ) -> AudioSignalCheckStatus {
        if !hasPermission {
            return .permissionDenied
        }
        if !isRunning {
            return .inactive
        }
        if isEchoSuppressed {
            return .echoSuppressed
        }
        if peakLevel > 0.88 || rawRMS > 0.22 {
            return .tooLoud
        }
        if noiseFloorRMS > baseThreshold * 2.2 && max(calibratedRMS, estimatedSpeechRMS) < noiseFloorRMS * 2.5 {
            return .highNoiseFloor
        }
        let effectiveSpeech = max(calibratedRMS, estimatedSpeechRMS)
        if rawRMS < baseThreshold * 0.45 && estimatedSpeechRMS < baseThreshold * 0.8 {
            return .waitingForAudio
        }
        if effectiveSpeech < 0.010 {
            return .tooQuiet
        }
        return .optimal
    }

    public static func nextAGCGain(
        currentRMS: Float,
        currentGain: Float,
        minRMSForBoost: Float,
        targetRMS: Float = 0.052
    ) -> Float {
        let safeCurrentGain = currentGain.isFinite ? max(1.0, min(10.0, currentGain)) : 1.0
        let safeMinRMS = max(0.00001, minRMSForBoost.isFinite ? minRMSForBoost : 0.00001)
        let desiredGain: Float
        if currentRMS.isFinite,
           currentRMS > 0.00001,
           targetRMS.isFinite,
           targetRMS > 0,
           currentRMS >= safeMinRMS,
           currentRMS < targetRMS {
            desiredGain = min(10.0, max(1.0, targetRMS / currentRMS))
        } else {
            desiredGain = 1.0
        }
        return (safeCurrentGain * 0.60) + (desiredGain * 0.40)
    }

    public static func backoffDelaySeconds(forAttempt attempt: Int) -> TimeInterval {
        let clampedExp = min(6, max(0, attempt - 1))
        return min(60.0, pow(2.0, Double(clampedExp)))
    }


    private func setupHardwareObservers() {
        stateLock.withLock {
            isTornDownHardwareObservers = false
        }

        var inputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let inputBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self else { return }
            let shouldRecover = self.stateLock.withLock { () -> Bool in
                self.didAttemptZeroSignalRecovery = false
                self.micRecoveryFailures = 0
                self.nextAllowedMicRecoveryTime = 0
                self.didReportMicFailureAlert = false
                return self.micShouldBeEnabled
            }
            if shouldRecover {
                AppLog.audio.info("Default input device changed; recovering microphone...")
                self.scheduleMicRecovery(after: 0.35, resetBackoff: true)
            }
        }
        let inputBox = UncheckedSendableBox(value: inputBlock)
        stateLock.withLock {
            defaultInputListenerBlock = inputBox.value
        }
        let addInStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &inputAddress,
            micQueue,
            inputBlock
        )
        if addInStatus != noErr {
            stateLock.withLock { defaultInputListenerBlock = nil }
        }

        var outputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let outputBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self else { return }
            self.refreshOutputDataSourceListenerAndIsolationAsync()
            let shouldRebuild = self.stateLock.withLock { self.callerShouldBeEnabled }
            if shouldRebuild {
                AppLog.audio.info("Default output device changed; scheduling system audio tap rebuild...")
                self.scheduleTapFormatRebuild(attempt: 0, initialDelay: 0.40)
            }
        }
        let outputBox = UncheckedSendableBox(value: outputBlock)
        stateLock.withLock {
            defaultOutputListenerBlock = outputBox.value
        }
        let addOutStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &outputAddress,
            callerQueue,
            outputBlock
        )
        if addOutStatus != noErr {
            stateLock.withLock { defaultOutputListenerBlock = nil }
        }

        refreshOutputDataSourceListenerAndIsolationAsync()
    }

    private func teardownHardwareObservers() {
        NotificationCenter.default.removeObserver(self)
        let (inBox, outBox, dsDevID, dsBox) = stateLock.withLock {
            () -> (
                UncheckedSendableBox<AudioObjectPropertyListenerBlock>?,
                UncheckedSendableBox<AudioObjectPropertyListenerBlock>?,
                AudioObjectID,
                UncheckedSendableBox<AudioObjectPropertyListenerBlock>?
            ) in
            isTornDownHardwareObservers = true
            observedMicConfigEngine = nil
            let i = defaultInputListenerBlock.map { UncheckedSendableBox(value: $0) }
            defaultInputListenerBlock = nil
            let o = defaultOutputListenerBlock.map { UncheckedSendableBox(value: $0) }
            defaultOutputListenerBlock = nil
            let dev = monitoredOutputDeviceID
            let ds = outputDataSourceListenerBlock.map { UncheckedSendableBox(value: $0) }
            monitoredOutputDeviceID = kAudioObjectUnknown
            outputDataSourceListenerBlock = nil
            return (i, o, dev, ds)
        }

        if let block = inBox?.value {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                micQueue,
                block
            )
        }
        if let block = outBox?.value {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                callerQueue,
                block
            )
        }
        if let dsBlock = dsBox?.value, dsDevID != kAudioObjectUnknown {
            var dsAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDataSource,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectRemovePropertyListenerBlock(
                dsDevID,
                &dsAddr,
                Self.acousticIsolationQueue,
                dsBlock
            )
        }
    }

    private func installTapFormatListeners(aggID: AudioObjectID, tapID: AudioObjectID, expectedGeneration: UInt64) {
        removeTapFormatListeners(aggID: aggID, tapID: tapID)

        var aggAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let aggBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self else { return }
            let isCurrent = self.stateLock.withLock {
                self._isRunning && self.captureGeneration == expectedGeneration
            }
            guard isCurrent else { return }
            AppLog.audio.info("Aggregate device stream format changed; rebuilding tap...")
            self.scheduleTapFormatRebuild()
        }
        let addAggStatus = AudioObjectAddPropertyListenerBlock(aggID, &aggAddr, callerQueue, aggBlock)
        if addAggStatus == noErr {
            let aggBox = UncheckedSendableBox(value: aggBlock)
            let keepAgg = stateLock.withLock { () -> Bool in
                guard _isRunning, captureGeneration == expectedGeneration else { return false }
                aggFormatListenerBlock = aggBox.value
                aggFormatListenerDeviceID = aggID
                return true
            }
            if !keepAgg {
                _ = AudioObjectRemovePropertyListenerBlock(aggID, &aggAddr, callerQueue, aggBlock)
                return
            }
        }

        var tapAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let tapBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self else { return }
            let isCurrent = self.stateLock.withLock {
                self._isRunning && self.captureGeneration == expectedGeneration
            }
            guard isCurrent else { return }
            AppLog.audio.info("Process tap format changed; rebuilding tap...")
            self.scheduleTapFormatRebuild()
        }
        let addTapStatus = AudioObjectAddPropertyListenerBlock(tapID, &tapAddr, callerQueue, tapBlock)
        if addTapStatus == noErr {
            let tapBox = UncheckedSendableBox(value: tapBlock)
            let keepTap = stateLock.withLock { () -> Bool in
                guard _isRunning, captureGeneration == expectedGeneration else { return false }
                tapFormatListenerBlock = tapBox.value
                tapFormatListenerTapID = tapID
                return true
            }
            if !keepTap {
                _ = AudioObjectRemovePropertyListenerBlock(tapID, &tapAddr, callerQueue, tapBlock)
            }
        }
    }

    private func removeTapFormatListeners(aggID: AudioObjectID, tapID: AudioObjectID) {
        let (oldAggID, aggBox, oldTapID, tapBox) = stateLock.withLock {
            () -> (
                AudioObjectID,
                UncheckedSendableBox<AudioObjectPropertyListenerBlock>?,
                AudioObjectID,
                UncheckedSendableBox<AudioObjectPropertyListenerBlock>?
            ) in
            let aID = aggFormatListenerDeviceID != kAudioObjectUnknown ? aggFormatListenerDeviceID : aggID
            let aBlock = aggFormatListenerBlock.map { UncheckedSendableBox(value: $0) }
            aggFormatListenerBlock = nil
            aggFormatListenerDeviceID = kAudioObjectUnknown

            let tID = tapFormatListenerTapID != kAudioObjectUnknown ? tapFormatListenerTapID : tapID
            let tBlock = tapFormatListenerBlock.map { UncheckedSendableBox(value: $0) }
            tapFormatListenerBlock = nil
            tapFormatListenerTapID = kAudioObjectUnknown

            return (aID, aBlock, tID, tBlock)
        }

        if let aggBlock = aggBox?.value, oldAggID != kAudioObjectUnknown {
            var aggAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamFormat,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectRemovePropertyListenerBlock(oldAggID, &aggAddr, callerQueue, aggBlock)
        }

        if let tapBlock = tapBox?.value, oldTapID != kAudioObjectUnknown {
            var tapAddr = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectRemovePropertyListenerBlock(oldTapID, &tapAddr, callerQueue, tapBlock)
        }
    }

    private func scheduleTapFormatRebuild(attempt: Int = 0, initialDelay: TimeInterval = 0.40) {
        let plan = stateLock.withLock { () -> (scheduledGen: UInt64, oldItem: UncheckedSendableBox<DispatchWorkItem>?, delay: TimeInterval)? in
            guard callerShouldBeEnabled || _isRunning else { return nil }
            if attempt == 0 {
                if isStartingEngine || isExecutingTapRebuild {
                    hasPendingTapRebuildRequest = true
                    return nil
                }
                if isRebuildingTap {
                    guard tapRebuildDebounceCount < 5 else { return nil }
                    tapRebuildDebounceCount += 1
                } else {
                    isRebuildingTap = true
                    tapRebuildDebounceCount = 0
                }
            } else {
                guard callerShouldBeEnabled else {
                    isRebuildingTap = false
                    tapRebuildDebounceCount = 0
                    return nil
                }
                isRebuildingTap = true
                tapRebuildDebounceCount = 0
            }

            tapRebuildGeneration &+= 1
            let gen = tapRebuildGeneration
            let previous = tapRebuildWorkItem.map { UncheckedSendableBox(value: $0) }
            tapRebuildWorkItem = nil

            let delay: TimeInterval
            if attempt == 0 {
                delay = initialDelay
            } else {
                let backoffSchedule: [TimeInterval] = [0.5, 1.0, 2.0]
                delay = backoffSchedule[min(attempt - 1, backoffSchedule.count - 1)]
            }
            return (gen, previous, delay)
        }
        guard let plan = plan else { return }
        plan.oldItem?.value.cancel()

        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let shouldProceed = self.stateLock.withLock { () -> Bool in
                guard self.tapRebuildGeneration == plan.scheduledGen,
                      self.callerShouldBeEnabled else {
                    return false
                }
                self.tapRebuildWorkItem = nil
                self.isExecutingTapRebuild = true
                return true
            }
            guard shouldProceed else { return }

            var rebuildSucceeded = false
            var rebuildError: Error? = nil
            do {
                try self.rebuildCallerTapOnly()
                rebuildSucceeded = self.stateLock.withLock { self.callerShouldBeEnabled && self._isRunning }
            } catch {
                rebuildError = error
            }

            self.stateLock.withLock {
                self.isExecutingTapRebuild = false
            }

            if let error = rebuildError {
                AppLog.audio.error("Audio tap rebuild attempt #\(attempt + 1) failed: \(error.localizedDescription, privacy: .public)")
                let stillEnabled = self.stateLock.withLock { self.callerShouldBeEnabled }
                if stillEnabled && attempt < 2 {
                    self.scheduleTapFormatRebuild(attempt: attempt + 1)
                } else {
                    let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9
                    self.stateLock.withLock {
                        self.isRebuildingTap = false
                        self.tapRebuildDebounceCount = 0
                        self.tapRebuildRetryCount = attempt >= 2 ? 3 : 0
                        self.nextAllowedCallerRecoveryTime = now + 10.0
                    }
                    if stillEnabled {
                        DispatchQueue.main.async { [weak self] in
                            self?.delegate?.audioCaptureDidEncounterError(error)
                        }
                    }
                }
                return
            }

            let rebuildDidSucceed = rebuildSucceeded
            let (didRebuild, followUpRebuild) = self.stateLock.withLock { () -> (Bool, Bool) in
                self.isRebuildingTap = false
                self.tapRebuildDebounceCount = 0
                if rebuildDidSucceed {
                    self.tapRebuildRetryCount = 0
                }
                let pending = self.hasPendingTapRebuildRequest && self.callerShouldBeEnabled && self._isRunning
                if pending {
                    self.hasPendingTapRebuildRequest = false
                }
                return (rebuildDidSucceed, pending)
            }
            if didRebuild {
                AppLog.audio.info("Audio tap rebuilt successfully after route change")
            }
            if followUpRebuild {
                self.scheduleTapFormatRebuild(attempt: 0, initialDelay: 0.25)
            }
        }

        let itemBox = UncheckedSendableBox(value: item)
        let installed = stateLock.withLock { () -> Bool in
            guard tapRebuildGeneration == plan.scheduledGen, callerShouldBeEnabled else { return false }
            tapRebuildWorkItem = itemBox.value
            return true
        }
        if installed {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + plan.delay, execute: item)
        } else {
            item.cancel()
        }
    }

    private func isOtherProcessAudioActiveThrottled(now: TimeInterval) -> Bool {
        let (cachedVal, shouldQuery) = stateLock.withLock { () -> (Bool, Bool) in
            let query = (now - lastOtherProcessQueryTime) >= 2.5 && !isQueryingOtherProcessAudio
            if query {
                isQueryingOtherProcessAudio = true
                lastOtherProcessQueryTime = now
            }
            return (cachedOtherProcessAudioActive, query)
        }

        if shouldQuery {
            let ownObj = stateLock.withLock { ownProcessObjectID }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let active = Self.isOtherProcessRunningAudioOutput(excludingProcessObjectID: ownObj)
                guard let self = self else { return }
                self.stateLock.withLock {
                    self.cachedOtherProcessAudioActive = active
                    self.isQueryingOtherProcessAudio = false
                }
            }
        }
        return cachedVal
    }

    private struct AcousticIsolationCacheState {
        var overrideValue: Bool? = nil
        var cachedIsIsolated: Bool = false
        var isPrimed: Bool = false
        var isRefreshing: Bool = false
    }

    private static let acousticIsolationState = OSAllocatedUnfairLock(initialState: AcousticIsolationCacheState())
    private static let acousticIsolationQueue = DispatchQueue(label: "com.callcaption.acousticIsolation", qos: .utility)

    public static var overrideAcousticIsolation: Bool? {
        get { acousticIsolationState.withLock { $0.overrideValue } }
        set { acousticIsolationState.withLock { $0.overrideValue = newValue } }
    }

    public static func isAudioOutputAcousticallyIsolated() -> Bool {
        let (overrideVal, cached, needsPrime) = acousticIsolationState.withLock { state -> (Bool?, Bool, Bool) in
            if let ov = state.overrideValue {
                return (ov, ov, false)
            }
            let kickoff = !state.isPrimed && !state.isRefreshing
            if kickoff {
                state.isRefreshing = true
            }
            return (nil, state.cachedIsIsolated, kickoff)
        }
        if let overrideVal = overrideVal {
            return overrideVal
        }
        if needsPrime {
            acousticIsolationQueue.async {
                Self.refreshAcousticIsolationCacheSync()
            }
        }
        return cached
    }

    @discardableResult
    private static func refreshAcousticIsolationCacheSync() -> AudioDeviceID {
        let (devID, isIsolated) = queryAcousticIsolationFromHAL()
        acousticIsolationState.withLock { state in
            state.cachedIsIsolated = isIsolated
            state.isPrimed = true
            state.isRefreshing = false
        }
        return devID
    }

    private func refreshOutputDataSourceListenerAndIsolationAsync() {
        Self.acousticIsolationQueue.async { [weak self] in
            let currentOutID = Self.refreshAcousticIsolationCacheSync()
            guard let self = self else { return }

            let action = self.stateLock.withLock {
                () -> (
                    tornDown: Bool,
                    removeDev: AudioObjectID,
                    removeBox: UncheckedSendableBox<AudioObjectPropertyListenerBlock>?,
                    needsInstall: Bool
                ) in
                if self.isTornDownHardwareObservers {
                    let dev = self.monitoredOutputDeviceID
                    let box = self.outputDataSourceListenerBlock.map { UncheckedSendableBox(value: $0) }
                    self.monitoredOutputDeviceID = kAudioObjectUnknown
                    self.outputDataSourceListenerBlock = nil
                    return (true, dev, box, false)
                }
                if self.monitoredOutputDeviceID == currentOutID && (currentOutID == kAudioObjectUnknown || self.outputDataSourceListenerBlock != nil) {
                    return (false, kAudioObjectUnknown, nil, false)
                }
                let prevDev = self.monitoredOutputDeviceID
                let prevBox = self.outputDataSourceListenerBlock.map { UncheckedSendableBox(value: $0) }
                self.monitoredOutputDeviceID = kAudioObjectUnknown
                self.outputDataSourceListenerBlock = nil
                return (false, prevDev, prevBox, currentOutID != kAudioObjectUnknown)
            }

            if let prevBlock = action.removeBox?.value, action.removeDev != kAudioObjectUnknown {
                var dsAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDataSource,
                    mScope: kAudioObjectPropertyScopeOutput,
                    mElement: kAudioObjectPropertyElementMain
                )
                _ = AudioObjectRemovePropertyListenerBlock(
                    action.removeDev,
                    &dsAddr,
                    Self.acousticIsolationQueue,
                    prevBlock
                )
            }

            guard !action.tornDown, action.needsInstall else { return }

            let dsBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard self != nil else { return }
                Self.refreshAcousticIsolationCacheSync()
            }
            var dsAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDataSource,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            let addStatus = AudioObjectAddPropertyListenerBlock(
                currentOutID,
                &dsAddr,
                Self.acousticIsolationQueue,
                dsBlock
            )
            guard addStatus == noErr else { return }

            let dsBox = UncheckedSendableBox(value: dsBlock)
            let keepInstalled = self.stateLock.withLock { () -> Bool in
                guard !self.isTornDownHardwareObservers else { return false }
                self.monitoredOutputDeviceID = currentOutID
                self.outputDataSourceListenerBlock = dsBox.value
                return true
            }
            if !keepInstalled {
                _ = AudioObjectRemovePropertyListenerBlock(
                    currentOutID,
                    &dsAddr,
                    Self.acousticIsolationQueue,
                    dsBlock
                )
            }
        }
    }

    private static func queryAcousticIsolationFromHAL() -> (deviceID: AudioDeviceID, isIsolated: Bool) {
        var defaultOutputDeviceID: AudioDeviceID = kAudioObjectUnknown
        var propSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propSize,
            &defaultOutputDeviceID
        )
        guard status == noErr, defaultOutputDeviceID != kAudioObjectUnknown else {
            return (kAudioObjectUnknown, false)
        }

        var transportType: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(defaultOutputDeviceID, &transportAddr, 0, nil, &transportSize, &transportType) == noErr {
            if transportType == kAudioDeviceTransportTypeBluetooth ||
               transportType == kAudioDeviceTransportTypeBluetoothLE ||
               transportType == kAudioDeviceTransportTypeAirPlay {
                return (defaultOutputDeviceID, true)
            }
        }

        var dataSource: UInt32 = 0
        var dsSize = UInt32(MemoryLayout<UInt32>.size)
        var dsAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(defaultOutputDeviceID, &dsAddr, 0, nil, &dsSize, &dataSource) == noErr {
            if dataSource == 0x6864706e {
                return (defaultOutputDeviceID, true)
            }
        }

        var nameRef: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let nameStatus = withUnsafeMutablePointer(to: &nameRef) { ptr in
            AudioObjectGetPropertyData(defaultOutputDeviceID, &nameAddr, 0, nil, &nameSize, ptr)
        }
        if nameStatus == noErr, let cfStr = nameRef?.takeRetainedValue() {
            let lower = (cfStr as String).lowercased()
            if lower.contains("headphone") || lower.contains("headset") ||
               lower.contains("airpod") || lower.contains("earpod") ||
               lower.contains("buds") || lower.contains("in-ear") {
                return (defaultOutputDeviceID, true)
            }
        }

        return (defaultOutputDeviceID, false)
    }

    @objc private func handleAudioEngineConfigChange(_ notification: Notification) {
        let senderID = (notification.object as AnyObject?).map(ObjectIdentifier.init)
        let shouldRecover = stateLock.withLock { () -> Bool in
            guard micShouldBeEnabled, let activeEngine = micAudioEngine else { return false }
            guard let senderID = senderID else { return false }
            return senderID == ObjectIdentifier(activeEngine)
        }
        guard shouldRecover else { return }
        AppLog.audio.info("AVAudioEngineConfigurationChange received; recovering mic pipeline...")
        scheduleMicRecovery(after: 0.35, resetBackoff: false)
    }


    public static func hasAvailableInputDevice() -> Bool {
        var devID: AudioDeviceID = kAudioObjectUnknown
        var propSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propSize,
            &devID
        )
        guard status == noErr, devID != kAudioObjectUnknown else { return false }

        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamSize: UInt32 = 0
        let streamStatus = AudioObjectGetPropertyDataSize(devID, &streamAddress, 0, nil, &streamSize)
        return streamStatus == noErr && streamSize > 0
    }

    private func scheduleMicRecovery(after delay: TimeInterval, resetBackoff: Bool = false) {
        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard authStatus != .denied && authStatus != .restricted else {
            stateLock.withLock {
                isMicAuthorized = false
                isRecoveringMic = false
            }
            stopMicWatchdog()
            return
        }

        let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9
        let plan = stateLock.withLock { () -> (gen: UInt64, oldItem: UncheckedSendableBox<DispatchWorkItem>?, waitDelay: TimeInterval)? in
            guard micShouldBeEnabled else { return nil }
            var previousItem: UncheckedSendableBox<DispatchWorkItem>? = nil
            if resetBackoff {
                micRecoveryFailures = 0
                nextAllowedMicRecoveryTime = 0
                previousItem = micRecoveryWorkItem.map { UncheckedSendableBox(value: $0) }
                micRecoveryWorkItem = nil
                isRecoveringMic = false
            } else {
                guard !isRecoveringMic, !isStartingMic, !isRequestingMicPermission else { return nil }
            }
            if now < nextAllowedMicRecoveryTime {
                return nil
            }
            micRecoveryGeneration &+= 1
            let gen = micRecoveryGeneration
            isRecoveringMic = true
            let backoff = micRecoveryFailures > 0 ? Self.backoffDelaySeconds(forAttempt: micRecoveryFailures) : delay
            return (gen, previousItem, max(delay, backoff))
        }
        guard let plan = plan else { return }
        plan.oldItem?.value.cancel()

        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let shouldRun = self.stateLock.withLock { () -> Bool in
                guard self.micRecoveryGeneration == plan.gen, self.micShouldBeEnabled else {
                    if self.micRecoveryGeneration == plan.gen {
                        self.isRecoveringMic = false
                        self.micRecoveryWorkItem = nil
                    }
                    return false
                }
                self.micRecoveryWorkItem = nil
                return true
            }
            guard shouldRun else { return }
            defer {
                self.stateLock.withLock {
                    if self.micRecoveryGeneration == plan.gen {
                        self.isRecoveringMic = false
                    }
                }
            }
            do {
                try self.startMicrophone()
            } catch {
                self.recordMicStartFailure(reason: error.localizedDescription)
            }
        }

        let itemBox = UncheckedSendableBox(value: item)
        let installed = stateLock.withLock { () -> Bool in
            guard micRecoveryGeneration == plan.gen, micShouldBeEnabled else { return false }
            micRecoveryWorkItem = itemBox.value
            return true
        }
        if installed {
            DispatchQueue.main.asyncAfter(deadline: .now() + plan.waitDelay, execute: item)
        } else {
            item.cancel()
        }
    }

    private func recordMicStartFailure(reason: String) {
        let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9
        let (failures, backoff, shouldAlert) = stateLock.withLock { () -> (Int, TimeInterval, Bool) in
            micRecoveryFailures += 1
            let b = Self.backoffDelaySeconds(forAttempt: micRecoveryFailures)
            nextAllowedMicRecoveryTime = now + b
            let alertNow = (micRecoveryFailures >= 4 && !didReportMicFailureAlert)
            if alertNow {
                didReportMicFailureAlert = true
            }
            return (micRecoveryFailures, b, alertNow)
        }
        AppLog.audio.warning("Mic start attempt #\(failures, privacy: .public) failed (\(reason, privacy: .public)); next retry in \(backoff, format: .fixed(precision: 1), privacy: .public)s")
        if shouldAlert {
            let err = NSError(
                domain: "AudioCaptureEngine",
                code: -1001,
                userInfo: [NSLocalizedDescriptionKey: L10n.tr("error.mic_unavailable", "Microphone unavailable or invalid audio format")]
            )
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.audioCaptureDidEncounterError(err)
            }
        }
    }

    private func startMicWatchdog() {
        stopMicWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: micQueue)
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let auth = AVCaptureDevice.authorizationStatus(for: .audio)
            if auth == .denied || auth == .restricted {
                self.stateLock.withLock { self.isMicAuthorized = false }
                self.stopMicWatchdog()
                return
            }
            guard auth == .authorized else { return }
            let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9
            let lastMicBuf = self.atomicLastMicBufferTime.load(ordering: .relaxed)
            let shouldRestart = self.stateLock.withLock { () -> Bool in
                guard self.micShouldBeEnabled, self.isMicAuthorized else { return false }
                guard now >= self.nextAllowedMicRecoveryTime,
                      !self.isRecoveringMic,
                      !self.isStartingMic,
                      !self.isRequestingMicPermission else { return false }
                let engineRunning = self.micAudioEngine?.isRunning ?? false
                let bufferStalled = (lastMicBuf > 0 && (now - lastMicBuf) > 2.2)
                let initialZeroStall = !self.hasReceivedNonZeroMicSignal && !self.didAttemptZeroSignalRecovery && self.micStartTime > 0 && (now - self.micStartTime) > 3.5
                if initialZeroStall {
                    self.didAttemptZeroSignalRecovery = true
                }
                return !self._isMicRunning || !engineRunning || bufferStalled || initialZeroStall
            }
            if shouldRestart {
                self.scheduleMicRecovery(after: 0.20, resetBackoff: false)
            }
        }
        timer.resume()
        let old = stateLock.withLock { () -> DispatchSourceTimer? in
            let prev = micWatchdogTimer
            micWatchdogTimer = timer
            return prev
        }
        old?.cancel()
    }

    private func stopMicWatchdog() {
        let oldTimer = stateLock.withLock { () -> DispatchSourceTimer? in
            let t = micWatchdogTimer
            micWatchdogTimer = nil
            return t
        }
        oldTimer?.cancel()
    }


    private func startCallerWatchdog() {
        stopCallerWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: callerQueue)
        timer.schedule(deadline: .now() + 3.0, repeating: 3.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard PermissionHelper.shared.audioCaptureState != .deniedSilenceDetected else { return }
            let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9
            let lastBuffer = self.callerTimestampAtomic.atomic.load(ordering: .relaxed)
            let (shouldBeEnabled, running, rebuilding, starting, startTime, nextAllowed) = self.stateLock.withLock {
                (self.callerShouldBeEnabled, self._isRunning, self.isRebuildingTap, self.isStartingEngine,
                 self.tapStartTime, self.nextAllowedCallerRecoveryTime)
            }
            guard shouldBeEnabled, !rebuilding, !starting, now >= nextAllowed else { return }

            if !running {
                AppLog.audio.warning("Caller capture should be running but is stopped; triggering recovery rebuild...")
                self.scheduleTapFormatRebuild(attempt: 0, initialDelay: 0.50)
                return
            }

            if lastBuffer > 0 {
                guard (now - lastBuffer) > 4.0 else { return }
            } else {
                guard (now - startTime) > 5.0 else { return }
            }
            guard self.isOtherProcessAudioActiveThrottled(now: now) else { return }
            let scheduled = self.stateLock.withLock { () -> Bool in
                guard self.callerShouldBeEnabled, self._isRunning, !self.isRebuildingTap, !self.isStartingEngine else { return false }
                self.nextAllowedCallerRecoveryTime = now + 15.0
                return true
            }
            if scheduled {
                AppLog.audio.warning("System audio tap appears stalled while output is active; rebuilding.")
                self.scheduleTapFormatRebuild(attempt: 0, initialDelay: 0.50)
            }
        }
        timer.resume()
        let old = stateLock.withLock { () -> DispatchSourceTimer? in
            let prev = callerWatchdogTimer
            callerWatchdogTimer = timer
            return prev
        }
        old?.cancel()
    }

    private func stopCallerWatchdog() {
        let oldTimer = stateLock.withLock { () -> DispatchSourceTimer? in
            let t = callerWatchdogTimer
            callerWatchdogTimer = nil
            return t
        }
        oldTimer?.cancel()
    }


    public func start(enableMic: Bool = false) throws {
        let startInfo = stateLock.withLock { () -> (UInt64, UUID)? in
            let currentGen = stopGeneration
            if isStartingEngine && activeStartStopGeneration == currentGen {
                self.callerShouldBeEnabled = true
                if enableMic {
                    self.pendingStartEnableMic = true
                }
                return nil
            }
            let token = UUID()
            self.isStartingEngine = true
            self.activeStartToken = token
            self.activeStartStopGeneration = currentGen
            self.callerShouldBeEnabled = true
            self.pendingStartEnableMic = enableMic
            return (currentGen, token)
        }
        guard let (entryStopGen, startToken) = startInfo else { return }

        lifecycleLock.lock()
        var ownsStartingFlag = false
        defer {
            let needsRebuildFromPending: Bool
            if ownsStartingFlag {
                needsRebuildFromPending = stateLock.withLock {
                    if self.activeStartToken == startToken {
                        self.isStartingEngine = false
                        self.activeStartToken = nil
                        self.pendingStartEnableMic = false
                        if self.hasPendingTapRebuildRequest && self.callerShouldBeEnabled && self._isRunning {
                            self.hasPendingTapRebuildRequest = false
                            return true
                        }
                    }
                    return false
                }
            } else {
                needsRebuildFromPending = false
            }
            lifecycleLock.unlock()
            if needsRebuildFromPending {
                self.scheduleTapFormatRebuild(attempt: 0, initialDelay: 0.25)
            }
        }

        let shouldContinue = stateLock.withLock { () -> Bool in
            guard self.stopGeneration == entryStopGen, self.activeStartToken == startToken else {
                if self.activeStartToken == startToken {
                    self.isStartingEngine = false
                    self.activeStartToken = nil
                    self.pendingStartEnableMic = false
                }
                return false
            }
            self.isStartingEngine = true
            self.callerShouldBeEnabled = true
            if enableMic {
                self.pendingStartEnableMic = true
            }
            return true
        }
        guard shouldContinue else { return }
        ownsStartingFlag = true

        stopMicrophone()
        tearDownCallerTapOnly(isStoppingPermanently: false)

        guard stateLock.withLock({ self.stopGeneration == entryStopGen && self.callerShouldBeEnabled }) else {
            return
        }

        do {
            try startCallerTapPipeline(entryStopGen: entryStopGen)
        } catch {
            let keepWatchdog = stateLock.withLock {
                self.callerShouldBeEnabled && self.stopGeneration == entryStopGen
            }
            if keepWatchdog && PermissionHelper.shared.audioCaptureState != .deniedSilenceDetected {
                startCallerWatchdog()
            }
            throw error
        }

        while true {
            let shouldEnableMic = stateLock.withLock { () -> Bool in
                guard self.stopGeneration == entryStopGen,
                      self.callerShouldBeEnabled,
                      self.pendingStartEnableMic else {
                    if self.stopGeneration == entryStopGen && !self.callerShouldBeEnabled {
                        self.pendingStartEnableMic = false
                        self.micShouldBeEnabled = false
                    }
                    return false
                }
                self.pendingStartEnableMic = false
                self.micShouldBeEnabled = true
                self.micRecoveryFailures = 0
                self.nextAllowedMicRecoveryTime = 0
                self.didReportMicFailureAlert = false
                return true
            }
            guard shouldEnableMic else { break }
            let auth = AVCaptureDevice.authorizationStatus(for: .audio)
            if auth == .authorized || auth == .notDetermined {
                startMicWatchdog()
            }
            do {
                try startMicrophone()
            } catch {
                recordMicStartFailure(reason: error.localizedDescription)
            }
        }
    }

    private func rebuildCallerTapOnly() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        let (entryStopGen, enabled) = stateLock.withLock { (stopGeneration, callerShouldBeEnabled) }
        guard enabled else { return }

        tearDownCallerTapOnly(isStoppingPermanently: false)

        guard stateLock.withLock({ self.callerShouldBeEnabled && self.stopGeneration == entryStopGen }) else {
            return
        }

        do {
            try startCallerTapPipeline(entryStopGen: entryStopGen)
        } catch {
            let keepWatchdog = stateLock.withLock {
                self.callerShouldBeEnabled && self.stopGeneration == entryStopGen
            }
            if keepWatchdog && PermissionHelper.shared.audioCaptureState != .deniedSilenceDetected {
                startCallerWatchdog()
            }
            throw error
        }
    }

    private func startCallerTapPipeline(entryStopGen: UInt64) throws {
        guard stateLock.withLock({ self.callerShouldBeEnabled && self.stopGeneration == entryStopGen }) else {
            return
        }

        var ownPID = ProcessInfo.processInfo.processIdentifier
        var resolvedOwnObjID: AudioObjectID = kAudioObjectUnknown
        var propSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let pidStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &ownPID,
            &propSize,
            &resolvedOwnObjID
        )
        guard pidStatus == noErr else {
            throw NSError(
                domain: "AudioCaptureEngine",
                code: Int(pidStatus),
                userInfo: [NSLocalizedDescriptionKey: "Failed to resolve process AudioObjectID for PID \(ownPID)"]
            )
        }

        let tapDesc = CATapDescription(monoGlobalTapButExcludeProcesses: [resolvedOwnObjID])
        tapDesc.name = "CallCaptionSystemAudioTap"
        tapDesc.uuid = UUID()
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .unmuted

        var newTapID: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &newTapID)
        guard tapStatus == noErr else {
            let isPermissionError = (tapStatus == OSStatus(kAudioDevicePermissionsError) || tapStatus == -60005)
            if isPermissionError {
                stateLock.withLock {
                    self.didReportDeniedTapPermission = true
                }
                PermissionHelper.shared.updateAudioCaptureState(.deniedSilenceDetected)
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.audioCaptureDidDetectDeniedTapPermission()
                }
                throw NSError(
                    domain: "AudioCaptureEngine",
                    code: Int(tapStatus),
                    userInfo: [NSLocalizedDescriptionKey: "System Audio Recording permission required (OSStatus \(tapStatus))"]
                )
            }
            throw NSError(
                domain: "AudioCaptureEngine",
                code: Int(tapStatus),
                userInfo: [NSLocalizedDescriptionKey: "AudioHardwareCreateProcessTap failed (OSStatus \(tapStatus))"]
            )
        }

        guard stateLock.withLock({ self.callerShouldBeEnabled && self.stopGeneration == entryStopGen }) else {
            _ = AudioHardwareDestroyProcessTap(newTapID)
            return
        }

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CallCaptionTapAggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapDesc.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var newAggID: AudioObjectID = kAudioObjectUnknown
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &newAggID)
        guard aggStatus == noErr else {
            _ = AudioHardwareDestroyProcessTap(newTapID)
            throw NSError(
                domain: "AudioCaptureEngine",
                code: Int(aggStatus),
                userInfo: [NSLocalizedDescriptionKey: "AudioHardwareCreateAggregateDevice failed with OSStatus \(aggStatus)"]
            )
        }

        var asbd = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let formatStatus = AudioObjectGetPropertyData(
            newAggID,
            &formatAddress,
            0,
            nil,
            &formatSize,
            &asbd
        )
        guard formatStatus == noErr, let avFormat = AVAudioFormat(streamDescription: &asbd) else {
            _ = AudioHardwareDestroyAggregateDevice(newAggID)
            _ = AudioHardwareDestroyProcessTap(newTapID)
            throw NSError(
                domain: "AudioCaptureEngine",
                code: Int(formatStatus),
                userInfo: [NSLocalizedDescriptionKey: "Failed to query stream format from aggregate device"]
            )
        }
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              asbd.mBitsPerChannel == 32,
              asbd.mChannelsPerFrame == 1,
              asbd.mBytesPerFrame == MemoryLayout<Float>.size else {
            _ = AudioHardwareDestroyAggregateDevice(newAggID)
            _ = AudioHardwareDestroyProcessTap(newTapID)
            throw NSError(
                domain: "AudioCaptureEngine",
                code: -1002,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported system audio tap format (expected 32-bit mono float)"]
            )
        }

        let sampleRate = avFormat.sampleRate
        let ringBuffer = CallerAudioRingBuffer(capacityPowerOfTwo: max(4096, Int(sampleRate * 2.0)))
        let pendingGen = stateLock.withLock { () -> UInt64 in
            self.captureGeneration &+= 1
            return self.captureGeneration
        }

        let wakeSource = DispatchSource.makeUserDataAddSource(queue: callerQueue)
        let droppedAtomic = self.callerDroppedAtomic
        let timestampAtomic = self.callerTimestampAtomic
        wakeSource.setEventHandler { [weak self, ringBuffer, droppedAtomic] in
            guard let self = self else { return }
            self.drainCallerRingBuffer(
                ringBuffer: ringBuffer,
                droppedCounter: droppedAtomic,
                sampleRate: sampleRate,
                expectedGeneration: pendingGen
            )
        }

        var newProcID: AudioDeviceIOProcID? = nil
        let bytesPerFrame = asbd.mBytesPerFrame > 0 ? asbd.mBytesPerFrame : 4

        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, newAggID, nil) { _, inInputData, _, _, _ in
            let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9
            timestampAtomic.atomic.store(now, ordering: .relaxed)

            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard let firstBuffer = abl.first, let srcData = firstBuffer.mData else { return }
            let byteSize = Int(firstBuffer.mDataByteSize)
            let frameCount = byteSize / Int(bytesPerFrame)
            guard frameCount > 0 else { return }
            let clampedBytes = min(byteSize, frameCount * MemoryLayout<Float>.size)
            let validSamples = clampedBytes / MemoryLayout<Float>.size
            guard validSamples > 0 else { return }

            let floatPtr = srcData.assumingMemoryBound(to: Float.self)
            if !ringBuffer.write(samples: floatPtr, count: validSamples) {
                _ = droppedAtomic.atomic.wrappingAdd(1, ordering: .relaxed)
            }
            wakeSource.add(data: 1)
        }

        guard ioStatus == noErr, let procID = newProcID else {
            wakeSource.setEventHandler {}
            wakeSource.cancel()
            wakeSource.resume()
            _ = AudioHardwareDestroyAggregateDevice(newAggID)
            _ = AudioHardwareDestroyProcessTap(newTapID)
            throw NSError(
                domain: "AudioCaptureEngine",
                code: Int(ioStatus),
                userInfo: [NSLocalizedDescriptionKey: "AudioDeviceCreateIOProcIDWithBlock failed with OSStatus \(ioStatus)"]
            )
        }

        timestampAtomic.atomic.store(0.0, ordering: .relaxed)
        _ = droppedAtomic.atomic.exchange(0, ordering: .relaxed)

        let startStatus = AudioDeviceStart(newAggID, procID)
        guard startStatus == noErr else {
            wakeSource.setEventHandler {}
            wakeSource.cancel()
            wakeSource.resume()
            _ = AudioDeviceDestroyIOProcID(newAggID, procID)
            _ = AudioHardwareDestroyAggregateDevice(newAggID)
            _ = AudioHardwareDestroyProcessTap(newTapID)
            throw NSError(
                domain: "AudioCaptureEngine",
                code: Int(startStatus),
                userInfo: [NSLocalizedDescriptionKey: "AudioDeviceStart failed with OSStatus \(startStatus)"]
            )
        }

        let finalTapID = newTapID
        let finalAggID = newAggID
        let finalOwnObjID = resolvedOwnObjID
        let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9

        let committed = stateLock.withLock { () -> Bool in
            guard self.callerShouldBeEnabled,
                  self.stopGeneration == entryStopGen,
                  self.captureGeneration == pendingGen else {
                return false
            }
            self.tapObjectID = finalTapID
            self.aggregateDeviceID = finalAggID
            self.ownProcessObjectID = finalOwnObjID
            self.ioProcID = procID
            self.streamFormat = avFormat
            self.callerWakeSource = wakeSource
            self.callerRingBuffer = ringBuffer
            self._isRunning = true
            self.callerShouldBeEnabled = true
            self.tapRebuildRetryCount = 0
            self.tapStartTime = now
            self.hasReceivedNonZeroCallerSignal = false
            self.lastPermissionProbeTime = now
            self.silentWhileOutputActiveStartTime = 0
            self.didReportDeniedTapPermission = false
            return true
        }

        guard committed else {
            wakeSource.setEventHandler {}
            wakeSource.cancel()
            wakeSource.resume()
            _ = AudioDeviceStop(finalAggID, procID)
            _ = AudioDeviceDestroyIOProcID(finalAggID, procID)
            _ = AudioHardwareDestroyAggregateDevice(finalAggID)
            _ = AudioHardwareDestroyProcessTap(finalTapID)
            return
        }

        wakeSource.resume()
        installTapFormatListeners(aggID: finalAggID, tapID: finalTapID, expectedGeneration: pendingGen)
        var verifiedASBD = AudioStreamBasicDescription()
        var verifiedSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioObjectGetPropertyData(finalAggID, &formatAddress, 0, nil, &verifiedSize, &verifiedASBD) == noErr,
           (verifiedASBD.mSampleRate != asbd.mSampleRate
            || verifiedASBD.mChannelsPerFrame != asbd.mChannelsPerFrame
            || verifiedASBD.mBitsPerChannel != asbd.mBitsPerChannel
            || (verifiedASBD.mFormatFlags & kAudioFormatFlagIsFloat) == 0) {
            scheduleTapFormatRebuild(attempt: 0, initialDelay: 0.15)
        }
        startCallerWatchdog()
        AppLog.audio.info("CoreAudio Process Tap started (AggID: \(finalAggID, privacy: .public), TapID: \(finalTapID, privacy: .public), rate: \(sampleRate, privacy: .public)Hz)")
    }


    public func startMicrophone() throws {
        guard stateLock.withLock({ micShouldBeEnabled }) else { return }

        micLifecycleLock.lock()
        defer { micLifecycleLock.unlock() }

        guard stateLock.withLock({ micShouldBeEnabled }) else { return }

        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if authStatus == .denied || authStatus == .restricted {
            stateLock.withLock {
                self.isMicAuthorized = false
                self.isStartingMic = false
            }
            stopMicWatchdog()
            return
        }
        if authStatus == .notDetermined {
            let shouldRequest = stateLock.withLock { () -> Bool in
                guard !self.isRequestingMicPermission else { return false }
                self.isRequestingMicPermission = true
                return true
            }
            if shouldRequest {
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        let stillEnabled = self.stateLock.withLock { () -> Bool in
                            self.isRequestingMicPermission = false
                            self.isMicAuthorized = granted
                            return self.micShouldBeEnabled
                        }
                        if !granted {
                            self.stopMicWatchdog()
                            return
                        }
                        if stillEnabled {
                            self.startMicWatchdog()
                            do {
                                try self.startMicrophone()
                            } catch {
                                self.recordMicStartFailure(reason: error.localizedDescription)
                            }
                        }
                    }
                }
            }
            return
        }
        guard authStatus == .authorized else {
            stateLock.withLock { isMicAuthorized = false }
            stopMicWatchdog()
            return
        }

        stateLock.withLock {
            self.isMicAuthorized = true
            self.isStartingMic = true
        }
        defer {
            stateLock.withLock { self.isStartingMic = false }
        }

        if stateLock.withLock({ micWatchdogTimer == nil }) {
            startMicWatchdog()
        }

        tearDownMicrophoneEngineOnly()

        guard Self.hasAvailableInputDevice() else {
            recordMicStartFailure(reason: "No audio input device available")
            return
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let busFormat = inputNode.outputFormat(forBus: 0)

        guard busFormat.sampleRate > 0 && busFormat.channelCount > 0 else {
            recordMicStartFailure(reason: "Invalid microphone format: sampleRate=\(busFormat.sampleRate), channels=\(busFormat.channelCount)")
            return
        }

        guard let precomputedMonoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: busFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            recordMicStartFailure(reason: "Failed to construct precomputedMonoFormat")
            return
        }
        let scratchCapacity = max(Self.micScratchFrameCapacity, AVAudioFrameCount(busFormat.sampleRate * 0.50))
        let scratchPool = MicScratchPool(
            monoFormat: precomputedMonoFormat,
            frameCapacity: scratchCapacity,
            poolSize: Self.micScratchPoolCapacity
        )
        let sessionGen = stateLock.withLock { () -> UInt64 in
            self.cachedTapMonoFormat = precomputedMonoFormat
            self.micSessionGeneration &+= 1
            return self.micSessionGeneration
        }

        atomicSelectedMicCapsuleChannel.store(0, ordering: .relaxed)
        _ = atomicDroppedMicBuffers.exchange(0, ordering: .relaxed)
        atomicIsMicRunning.store(true, ordering: .releasing)

        do {
            try AudioTapHelper.installTap(on: inputNode, bus: 0, bufferSize: 2048, format: nil) { [weak self, scratchPool] buffer, _ in
                guard let self = self, self.atomicIsMicRunning.load(ordering: .acquiring) else { return }
                let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9
                self.atomicLastMicBufferTime.store(now, ordering: .relaxed)

                guard let slotIdx = scratchPool.acquireSlot() else {
                    _ = self.atomicDroppedMicBuffers.wrappingAdd(1, ordering: .relaxed)
                    return
                }

                let scratch = scratchPool.buffers[slotIdx]
                guard self.convertAndCopyToMono(source: buffer, destination: scratch) else {
                    scratchPool.releaseSlot(slotIdx)
                    _ = self.atomicDroppedMicBuffers.wrappingAdd(1, ordering: .relaxed)
                    return
                }
                let sendable = SendablePCMBuffer(buffer: scratch)
                self.micQueue.async { [weak self, scratchPool] in
                    defer { scratchPool.releaseSlot(slotIdx) }
                    self?.handleIncomingMicAudio(buffer: sendable.buffer, expectedMicGeneration: sessionGen)
                }
            }
        } catch {
            atomicIsMicRunning.store(false, ordering: .releasing)
            stateLock.withLock {
                self.cachedTapMonoFormat = nil
            }
            throw error
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            atomicIsMicRunning.store(false, ordering: .releasing)
            inputNode.removeTap(onBus: 0)
            stateLock.withLock {
                self.cachedTapMonoFormat = nil
            }
            throw error
        }

        let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9
        let engineBox = UncheckedSendableBox(value: engine)
        atomicLastMicBufferTime.store(now, ordering: .relaxed)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioEngineConfigChange(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
        stateLock.withLock {
            self.micAudioEngine = engineBox.value
            self.observedMicConfigEngine = engineBox.value
            self._isMicRunning = true
            self.micStartTime = now
            self.hasReceivedNonZeroMicSignal = false
            self.micRecoveryFailures = 0
            self.nextAllowedMicRecoveryTime = 0
            self.didReportMicFailureAlert = false
        }

        AppLog.audio.info("Microphone capture started (\(busFormat.sampleRate, privacy: .public)Hz, \(busFormat.channelCount, privacy: .public)ch -> 1ch mono)")
    }

    private func tearDownMicrophoneEngineOnly(isDeallocating: Bool = false) {
        atomicIsMicRunning.store(false, ordering: .releasing)
        atomicLastMicBufferTime.store(0.0, ordering: .relaxed)
        atomicSelectedMicCapsuleChannel.store(0, ordering: .relaxed)

        let (oldEngineBox, oldObservedEngineBox) = stateLock.withLock {
            () -> (UncheckedSendableBox<AVAudioEngine>?, UncheckedSendableBox<AVAudioEngine>?) in
            micSessionGeneration &+= 1
            _isMicRunning = false
            isMicCurrentlySpeaking = false
            userHoldsVoice = false
            floorOwner = Self.resolveFloorOwner(current: floorOwner, isCallerActive: callerHoldsVoice, isUserActive: false)
            cachedTapMonoFormat = nil
            let e = micAudioEngine
            micAudioEngine = nil
            let observed = observedMicConfigEngine
            observedMicConfigEngine = nil
            return (
                e.map { UncheckedSendableBox(value: $0) },
                observed.map { UncheckedSendableBox(value: $0) }
            )
        }

        if let observed = oldObservedEngineBox?.value {
            NotificationCenter.default.removeObserver(
                self,
                name: .AVAudioEngineConfigurationChange,
                object: observed
            )
        }

        if let engine = oldEngineBox?.value {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning {
                engine.stop()
            }
        }

        guard !isDeallocating else { return }

        micQueue.async { [weak self] in
            guard let self = self else { return }
            self.micConverter = nil
            self.isMicActive = false
            self.micConsecutiveVoiceFrames = 0
            self.lastMicSpeechTime = 0
            self.micAGCGain = 1.0
            self.micPreRoll.removeAll(keepingCapacity: false)
            self.micPreRollFrames = 0
        }
    }

    public func stopMicrophone() {
        stopMicrophone(isDeallocating: false)
    }

    private func stopMicrophone(isDeallocating: Bool) {
        micLifecycleLock.lock()
        defer { micLifecycleLock.unlock() }

        let oldRecoveryItem = stateLock.withLock { () -> UncheckedSendableBox<DispatchWorkItem>? in
            micRecoveryGeneration &+= 1
            let item = micRecoveryWorkItem.map { UncheckedSendableBox(value: $0) }
            micRecoveryWorkItem = nil
            micShouldBeEnabled = false
            isRecoveringMic = false
            isStartingMic = false
            isMicCurrentlySpeaking = false
            userHoldsVoice = false
            floorOwner = Self.resolveFloorOwner(current: floorOwner, isCallerActive: callerHoldsVoice, isUserActive: false)
            didAttemptZeroSignalRecovery = false
            micRecoveryFailures = 0
            nextAllowedMicRecoveryTime = 0
            didReportMicFailureAlert = false
            smoothedMicLevel = 0.0
            lastDispatchedMicLevel = 0.0
            micRawRMS = 0.0
            micCalibratedRMS = 0.0
            micSignalPeak = 0.0
            micIsEchoSuppressedNow = false
            micLatestAGCGain = 1.0
            return item
        }
        oldRecoveryItem?.value.cancel()
        stopMicWatchdog()
        tearDownMicrophoneEngineOnly(isDeallocating: isDeallocating)

        guard !isDeallocating else { return }

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.audioCaptureDidUpdateMicLevel(0)
        }
    }

    public func setMicrophoneEnabled(_ enabled: Bool) {
        if enabled {
            stateLock.withLock {
                micShouldBeEnabled = true
                didAttemptZeroSignalRecovery = false
                micRecoveryFailures = 0
                nextAllowedMicRecoveryTime = 0
                didReportMicFailureAlert = false
            }
            if !isMicRunning {
                do {
                    try startMicrophone()
                } catch {
                    recordMicStartFailure(reason: error.localizedDescription)
                }
            } else if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                if stateLock.withLock({ micWatchdogTimer == nil }) {
                    startMicWatchdog()
                }
            }
        } else {
            stopMicrophone()
        }
    }

    public static func shouldActivateCallerSpeech(
        callerRMS: Float,
        isCallerActive: Bool,
        isMicCurrentlySpeaking: Bool,
        consecutiveCallerFrames: Int,
        callerSpeechThreshold: Float = AudioCaptureEngine.defaultCallerSpeechThreshold,
        callerBargeInThreshold: Float = AudioCaptureEngine.defaultCallerBargeInThreshold
    ) -> Bool {
        if !isCallerActive && isMicCurrentlySpeaking {
            guard callerRMS >= callerBargeInThreshold else { return false }
            return consecutiveCallerFrames >= 3
        }
        return callerRMS >= callerSpeechThreshold
    }

    public static func evaluateMicEchoState(
        rawCallerRMS: Float,
        callerPeakEnvelope: Float,
        isCallerCurrentlySpeaking: Bool,
        timeSinceLastCallerVoice: TimeInterval,
        isAcousticallyIsolated: Bool,
        isMicCurrentlySpeaking: Bool,
        micSpeechThreshold: Float = AudioCaptureEngine.defaultMicSpeechThreshold,
        callerSpeechThreshold: Float = AudioCaptureEngine.defaultCallerSpeechThreshold
    ) -> (isCallerSpeakingOrEchoing: Bool, effectiveThreshold: Float, requiredFrames: Int) {
        let callerEnergy = max(callerPeakEnvelope, rawCallerRMS)
        let isCallerSpeakingOrEchoing = !isAcousticallyIsolated && (
            isCallerCurrentlySpeaking
            || timeSinceLastCallerVoice < 0.55
            || (!isMicCurrentlySpeaking && rawCallerRMS >= callerSpeechThreshold)
        )

        let effectiveThreshold: Float
        let requiredFrames: Int
        if isCallerSpeakingOrEchoing {
            if timeSinceLastCallerVoice < Self.strictEchoWindow {
                // Caller is audibly talking through the speakers right now.
                effectiveThreshold = max(0.035, callerEnergy * 3.5)
                requiredFrames = 6
            } else {
                // Only the decaying room echo (or faint far-end noise) remains.
                // The old fixed 0.035 floor rejected normal conversational speech
                // on a laptop mic, so replies right after the caller were dropped.
                // The peak envelope holds the caller's loudest syllable for 0.4 s,
                // so it is scaled by the modelled reverb decay instead of being
                // used as-is (which blocked replies for ~0.5 s after loud callers).
                let residualEcho = callerEnergy * 3.5 * Self.echoTailDecay(after: timeSinceLastCallerVoice)
                effectiveThreshold = max(micSpeechThreshold * 4.0, rawCallerRMS * 3.5, residualEcho)
                requiredFrames = 3
            }
        } else {
            effectiveThreshold = micSpeechThreshold
            requiredFrames = isMicCurrentlySpeaking ? 1 : 2
        }
        return (isCallerSpeakingOrEchoing, effectiveThreshold, requiredFrames)
    }

    /// How long after the last detected caller voice the mic is treated as
    /// hearing direct speaker playback (strict gating). Mic audio that starts
    /// after this window is also eligible to be replayed from the pre-roll.
    public static let strictEchoWindow: TimeInterval = 0.25

    /// Conservative room reverberation time (RT60) used to model how quickly
    /// speaker echo fades from the mic once the caller stops talking.
    public static let echoTailReverbTime: TimeInterval = 0.6

    /// Amplitude factor of residual speaker echo `elapsed` seconds after the
    /// caller's last voiced frame (−60 dB per `echoTailReverbTime`).
    public static func echoTailDecay(after elapsed: TimeInterval) -> Float {
        guard elapsed.isFinite else { return 0 }
        let t = max(0, elapsed)
        return Float(pow(10.0, -3.0 * t / echoTailReverbTime))
    }

    private func handleIncomingMicAudio(buffer: AVAudioPCMBuffer, expectedMicGeneration: UInt64) {
        let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9

        let droppedMic = atomicDroppedMicBuffers.exchange(0, ordering: .relaxed)
        if droppedMic > 0 {
            let shouldLogDrop = stateLock.withLock { () -> Bool in
                if (now - self.lastMicDropLogTime) >= 2.0 {
                    self.lastMicDropLogTime = now
                    return true
                }
                return false
            }
            if shouldLogDrop {
                AppLog.audio.warning("Mic scratch pool saturated; dropped \(droppedMic, privacy: .public) audio buffers")
            }
        }

        let sessionValid = stateLock.withLock {
            self._isMicRunning && self.micSessionGeneration == expectedMicGeneration
        }
        guard sessionValid else { return }

        guard let converted = convertTo16kMono(
            buffer: buffer,
            cachedConverter: &micConverter,
            targetFormat: Self.speechFormat
        ) else { return }

        let rawMicVal: Float
        if let channelData = converted.floatChannelData?[0] {
            rawMicVal = Self.computeRMS(samples: channelData, count: Int(converted.frameLength))
        } else {
            rawMicVal = 0.0
        }

        let settings = AppSettings.shared
        let micGain = settings.micInputGain
        let autoGain = settings.isAutoGainEnabled
        let (calibratedMicVal, micPeakVal) = Self.applyGainInPlace(converted, gain: micGain)

        let (rawCaller, peakCaller, callerSpeaking, lastCallerVoice, micSpeaking, currentMicFloor, currentCallerFloor, currentFloorOwner, estimatedUserSpeech) = stateLock.withLock {
            if rawMicVal > 0.0000001 {
                hasReceivedNonZeroMicSignal = true
                micRecoveryFailures = 0
            }
            return (
                rawCallerRMS,
                callerPeakEnvelope,
                isCallerCurrentlySpeaking,
                lastCallerVoiceTimestamp,
                isMicCurrentlySpeaking,
                micNoiseFloorRMS,
                callerNoiseFloorRMS,
                floorOwner,
                micEstimatedSpeechRMS
            )
        }
        let isIsolated = Self.isAudioOutputAcousticallyIsolated()
        let timeSinceCallerVoice = lastCallerVoice > 0 ? (now - lastCallerVoice) : .greatestFiniteMagnitude
        let adaptivePreGainMicBase = Self.adaptiveSpeechThreshold(baseThreshold: micSpeechThreshold, noiseFloorRMS: currentMicFloor)
        let adaptivePreGainCallerBase = Self.adaptiveSpeechThreshold(baseThreshold: callerSpeechThreshold, noiseFloorRMS: currentCallerFloor)
        let postMicFloor = currentMicFloor * micGain
        let adaptivePostGainMicBase = max(
            Self.adaptiveSpeechThreshold(baseThreshold: micSpeechThreshold, noiseFloorRMS: postMicFloor),
            postMicFloor * 2.2
        )
        let (isCallerSpeakingOrEchoing, rawEffectiveThreshold, onsetFrames) = Self.evaluateMicEchoState(
            rawCallerRMS: rawCaller,
            callerPeakEnvelope: peakCaller,
            isCallerCurrentlySpeaking: callerSpeaking,
            timeSinceLastCallerVoice: timeSinceCallerVoice,
            isAcousticallyIsolated: isIsolated,
            isMicCurrentlySpeaking: micSpeaking,
            micSpeechThreshold: adaptivePreGainMicBase,
            callerSpeechThreshold: adaptivePreGainCallerBase
        )

        // The user was already talking when the caller started: keep the user's
        // turn alive instead of slamming the strict echo gate shut on them.
        let userHoldsFloor = !isIsolated && isMicActive && currentFloorOwner == .user

        // When the caller is actively speaking on speakers (strict window), test
        // against raw mic RMS so boosted input gain never amplifies speaker bleed
        // across the echo gate. Otherwise, use the gain-calibrated mic RMS.
        let levelForGate: Float
        let effectiveThreshold: Float
        if userHoldsFloor && isCallerSpeakingOrEchoing {
            levelForGate = rawMicVal
            effectiveThreshold = Self.userFloorHoldThreshold(
                micSpeechThreshold: adaptivePreGainMicBase,
                estimatedUserSpeechRMS: estimatedUserSpeech
            )
        } else if isCallerSpeakingOrEchoing && timeSinceCallerVoice < Self.strictEchoWindow {
            levelForGate = rawMicVal
            effectiveThreshold = rawEffectiveThreshold
        } else if isCallerSpeakingOrEchoing {
            levelForGate = calibratedMicVal
            let residualEcho = max(rawCaller * 3.5, max(peakCaller, rawCaller) * 3.5 * Self.echoTailDecay(after: timeSinceCallerVoice))
            effectiveThreshold = max(adaptivePostGainMicBase * 4.0, residualEcho * micGain)
        } else {
            levelForGate = calibratedMicVal
            effectiveThreshold = adaptivePostGainMicBase
        }

        if levelForGate >= effectiveThreshold {
            micConsecutiveVoiceFrames += 1
        } else {
            micConsecutiveVoiceFrames = 0
        }

        let requiredFrames = isMicActive ? 1 : onsetFrames
        let isVoiceDetected = (micConsecutiveVoiceFrames >= requiredFrames)

        normalizeSpeechBuffer(
            converted,
            currentRMS: calibratedMicVal,
            currentGain: &micAGCGain,
            minRMSForBoost: adaptivePostGainMicBase * 0.5,
            allowBoost: isVoiceDetected || isMicActive
        )

        let agcSnapshot = micAGCGain
        let maybeUpdatedMicGain: Float? = stateLock.withLock {
            micRawRMS = (micRawRMS * 0.55) + (rawMicVal * 0.45)
            micCalibratedRMS = (micCalibratedRMS * 0.55) + (calibratedMicVal * 0.45)
            micSignalPeak = max(micPeakVal, micSignalPeak * 0.88)
            micEffectiveThreshold = effectiveThreshold
            micIsEchoSuppressedNow = isCallerSpeakingOrEchoing && !isVoiceDetected
            micLatestAGCGain = agcSnapshot

            if !isCallerSpeakingOrEchoing {
                micNoiseFloorRMS = Self.updateNoiseFloorEstimate(
                    currentFloor: micNoiseFloorRMS,
                    sampleRMS: rawMicVal,
                    isVoiceDetected: isVoiceDetected
                )
                if isVoiceDetected && rawMicVal >= micSpeechThreshold * 0.4 {
                    micEstimatedSpeechRMS = micEstimatedSpeechRMS > 0.0001
                        ? (micEstimatedSpeechRMS * 0.82) + (rawMicVal * 0.18)
                        : rawMicVal
                }
            }

            if autoGain {
                let minInterval: TimeInterval = micPeakVal > 0.90 ? 0.35 : 1.0
                if (now - micLastAutoGainUpdateTime) >= minInterval,
                   (isVoiceDetected && !isCallerSpeakingOrEchoing) || micPeakVal > 0.90 {
                    let candidate = Self.computeCalibratedInputGain(
                        currentGain: micGain,
                        estimatedSpeechRMS: micEstimatedSpeechRMS,
                        noiseFloorRMS: micNoiseFloorRMS,
                        peakLevel: micSignalPeak,
                        targetSpeechRMS: Self.defaultTargetSpeechRMS,
                        baseThreshold: micSpeechThreshold
                    )
                    let minDelta = max(0.05, micGain * 0.04)
                    if abs(candidate - micGain) >= minDelta {
                        micLastAutoGainUpdateTime = now
                        return candidate
                    }
                }
            }
            return nil
        }
        if let newMicGain = maybeUpdatedMicGain {
            settings.micInputGain = newMicGain
        }

        let bufferStartTime = now - Double(converted.frameLength) / Self.speechFormat.sampleRate
        var buffersToOutput: [AVAudioPCMBuffer] = []
        var nextIsMicCurrentlySpeaking: Bool? = nil

        if isVoiceDetected {
            if !isMicActive {
                isMicActive = true
                // Replay the lead-in so the first syllables are not clipped, but
                // never audio that overlaps the caller's direct speaker playback.
                let echoCutoff = lastCallerVoice > 0 ? lastCallerVoice + Self.strictEchoWindow : -Double.greatestFiniteMagnitude
                for entry in micPreRoll where entry.startTime >= echoCutoff {
                    buffersToOutput.append(entry.buffer)
                }
                micPreRoll.removeAll(keepingCapacity: true)
                micPreRollFrames = 0
            }
            nextIsMicCurrentlySpeaking = true
            lastMicSpeechTime = now
            buffersToOutput.append(converted)
        } else {
            if isCallerSpeakingOrEchoing && !userHoldsFloor {
                isMicActive = false
                nextIsMicCurrentlySpeaking = false
                appendToMicPreRoll(converted, startTime: bufferStartTime)
            } else if isMicActive {
                let silenceElapsed = now - lastMicSpeechTime
                if silenceElapsed >= 0.45 {
                    nextIsMicCurrentlySpeaking = false
                }
                if silenceElapsed < micHangoverDuration {
                    buffersToOutput.append(converted)
                } else {
                    isMicActive = false
                    nextIsMicCurrentlySpeaking = false
                    appendToMicPreRoll(converted, startTime: bufferStartTime)
                }
            } else {
                appendToMicPreRoll(converted, startTime: bufferStartTime)
            }
        }

        let micActiveNow = isMicActive
        let nextMicSpeaking = nextIsMicCurrentlySpeaking
        stateLock.withLock {
            if let speaking = nextMicSpeaking {
                isMicCurrentlySpeaking = speaking
            }
            userHoldsVoice = micActiveNow
            floorOwner = Self.resolveFloorOwner(current: floorOwner, isCallerActive: callerHoldsVoice, isUserActive: micActiveNow)
        }

        for pcm in buffersToOutput {
            delegate?.audioCaptureDidOutputMicAudio(pcmBuffer: pcm)
        }

        if now - lastMicLevelDispatchTime >= 0.08 {
            lastMicLevelDispatchTime = now
            updateMicAudioLevel(isCallerSpeakingOrEchoing && !isVoiceDetected ? 0.0 : calibratedMicVal)
        }
    }

    private func updateMicAudioLevel(_ rawLevel: Float) {
        let boosted = min(1.0, rawLevel * 14.0)
        let shouldDispatchLevel: Float? = stateLock.withLock {
            let next = (smoothedMicLevel * 0.65) + (boosted * 0.35)
            smoothedMicLevel = next < 0.002 ? 0.0 : next
            let diff = abs(smoothedMicLevel - lastDispatchedMicLevel)
            if diff >= 0.008 || (smoothedMicLevel == 0.0 && lastDispatchedMicLevel != 0.0) {
                lastDispatchedMicLevel = smoothedMicLevel
                return smoothedMicLevel
            }
            return nil
        }

        if let newLevel = shouldDispatchLevel {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.audioCaptureDidUpdateMicLevel(newLevel)
            }
        }
    }


    public func stop() {
        stop(isDeallocating: false)
    }

    private func stop(isDeallocating: Bool) {
        let workItems = stateLock.withLock {
            () -> (UncheckedSendableBox<DispatchWorkItem>?, UncheckedSendableBox<DispatchWorkItem>?) in
            stopGeneration &+= 1
            captureGeneration &+= 1
            activeStartToken = nil
            callerShouldBeEnabled = false
            micShouldBeEnabled = false
            pendingStartEnableMic = false
            hasPendingTapRebuildRequest = false
            hasEverReceivedNonZeroCallerSignal = false
            isRebuildingTap = false
            tapRebuildDebounceCount = 0
            tapRebuildRetryCount = 0
            tapRebuildGeneration &+= 1
            micRecoveryGeneration &+= 1
            let tapItem = tapRebuildWorkItem.map { UncheckedSendableBox(value: $0) }
            tapRebuildWorkItem = nil
            let micItem = micRecoveryWorkItem.map { UncheckedSendableBox(value: $0) }
            micRecoveryWorkItem = nil
            return (tapItem, micItem)
        }
        workItems.0?.value.cancel()
        workItems.1?.value.cancel()

        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        stopInternal(isStoppingPermanently: true, isDeallocating: isDeallocating)
    }

    private func stopInternal(isStoppingPermanently: Bool, isDeallocating: Bool = false) {
        stopMicrophone(isDeallocating: isDeallocating)
        tearDownCallerTapOnly(isStoppingPermanently: isStoppingPermanently, isDeallocating: isDeallocating)
    }

    private func tearDownCallerTapOnly(isStoppingPermanently: Bool, isDeallocating: Bool = false) {
        stopCallerWatchdog()

        let (tapToDestroy, aggToDestroy, procToStop, oldWakeSource, oldTapRebuildItem) = stateLock.withLock {
            () -> (
                AudioObjectID,
                AudioObjectID,
                AudioDeviceIOProcID?,
                DispatchSourceUserDataAdd?,
                UncheckedSendableBox<DispatchWorkItem>?
            ) in
            captureGeneration &+= 1
            _isRunning = false
            var tapItem: UncheckedSendableBox<DispatchWorkItem>? = nil
            if isStoppingPermanently {
                callerShouldBeEnabled = false
                isRebuildingTap = false
                tapRebuildDebounceCount = 0
                tapRebuildRetryCount = 0
                tapRebuildGeneration &+= 1
                tapItem = tapRebuildWorkItem.map { UncheckedSendableBox(value: $0) }
                tapRebuildWorkItem = nil
            }
            rawCallerRMS = 0.0
            callerCalibratedRMS = 0.0
            callerSignalPeak = 0.0
            callerLatestAGCGain = 1.0
            callerPeakEnvelope = 0.0
            lastCallerPeakTime = 0
            lastCallerVoiceTimestamp = 0
            isCallerCurrentlySpeaking = false
            callerHoldsVoice = false
            floorOwner = Self.resolveFloorOwner(current: floorOwner, isCallerActive: false, isUserActive: userHoldsVoice)
            nextAllowedCallerRecoveryTime = 0
            smoothedCallerLevel = 0.0
            lastDispatchedCallerLevel = 0.0
            let tap = tapObjectID
            let agg = aggregateDeviceID
            let proc = ioProcID
            let wakeSrc = callerWakeSource
            tapObjectID = kAudioObjectUnknown
            aggregateDeviceID = kAudioObjectUnknown
            ownProcessObjectID = kAudioObjectUnknown
            ioProcID = nil
            streamFormat = nil
            callerWakeSource = nil
            callerRingBuffer = nil
            return (tap, agg, proc, wakeSrc, tapItem)
        }

        oldTapRebuildItem?.value.cancel()
        callerTimestampAtomic.atomic.store(0.0, ordering: .relaxed)
        _ = callerDroppedAtomic.atomic.exchange(0, ordering: .relaxed)

        removeTapFormatListeners(aggID: aggToDestroy, tapID: tapToDestroy)

        if let proc = procToStop, aggToDestroy != kAudioObjectUnknown {
            _ = AudioDeviceStop(aggToDestroy, proc)
            _ = AudioDeviceDestroyIOProcID(aggToDestroy, proc)
        }
        oldWakeSource?.cancel()
        if aggToDestroy != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggToDestroy)
        }
        if tapToDestroy != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapToDestroy)
        }

        guard !isDeallocating else { return }

        let resetCallerQueueState = {
            self.callerMonoFormat = nil
            self.callerReusableSrcPCM = nil
            self.callerConverter = nil
            self.isCallerActive = false
            self.callerConsecutiveVoiceFrames = 0
            self.lastCallerSpeechTime = 0
            self.callerAGCGain = 1.0
            self.callerPreRoll.removeAll(keepingCapacity: false)
            self.callerPreRollFrames = 0
            self.lastCallerDropLogTime = 0
        }

        if DispatchQueue.getSpecific(key: callerQueueKey) != nil {
            resetCallerQueueState()
        } else {
            callerQueue.sync {
                resetCallerQueueState()
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.audioCaptureDidUpdateCallerLevel(0)
        }
    }

    private func drainCallerRingBuffer(
        ringBuffer: CallerAudioRingBuffer,
        droppedCounter: AtomicBox<UInt64>,
        sampleRate: Double,
        expectedGeneration: UInt64
    ) {
        let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9
        let dropped = droppedCounter.atomic.exchange(0, ordering: .relaxed)
        if dropped > 0 && (now - lastCallerDropLogTime) >= 2.0 {
            lastCallerDropLogTime = now
            AppLog.audio.warning("Caller audio queue backlog exceeded; dropped \(dropped, privacy: .public) oldest buffers")
        }

        let chunkCapacity = AVAudioFrameCount(max(2048, min(8192, Int(sampleRate * 0.05))))
        if callerMonoFormat == nil || callerMonoFormat?.sampleRate != sampleRate {
            callerMonoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            )
            callerReusableSrcPCM = nil
        }
        if callerReusableSrcPCM == nil || (callerReusableSrcPCM?.frameCapacity ?? 0) < chunkCapacity {
            if let monoFormat = callerMonoFormat {
                callerReusableSrcPCM = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: chunkCapacity)
            }
        }
        guard let srcPCM = callerReusableSrcPCM,
              let dst = srcPCM.floatChannelData?[0] else {
            return
        }

        while ringBuffer.availableToRead() > 0 {
            let stillCurrent = stateLock.withLock {
                self._isRunning && self.captureGeneration == expectedGeneration
            }
            guard stillCurrent else { break }

            let readCount = ringBuffer.read(into: dst, maxCount: Int(chunkCapacity))
            guard readCount > 0 else { break }
            srcPCM.frameLength = AVAudioFrameCount(readCount)
            processCallerAudioOnQueue(srcPCM: srcPCM)
        }
    }

    private func processCallerAudioOnQueue(srcPCM: AVAudioPCMBuffer) {
        guard isRunning, srcPCM.frameLength > 0 else { return }

        guard let converted = convertTo16kMono(
            buffer: srcPCM,
            cachedConverter: &callerConverter,
            targetFormat: Self.speechFormat
        ) else { return }

        guard let channelData = converted.floatChannelData?[0] else { return }
        let rawRMS = Self.computeRMS(samples: channelData, count: Int(converted.frameLength))
        let now = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9

        checkAudioTapPermissionHealth(rmsVal: rawRMS, now: now)

        let settings = AppSettings.shared
        let callerGain = settings.callerInputGain
        let autoGain = settings.isAutoGainEnabled
        let (calibratedRMS, callerPeakVal) = Self.applyGainInPlace(converted, gain: callerGain)

        let (isMicSpeaking, currentCallerFloor) = stateLock.withLock {
            (isMicCurrentlySpeaking, callerNoiseFloorRMS)
        }
        let postCallerFloor = currentCallerFloor * callerGain
        let adaptiveCallerBase = max(
            Self.adaptiveSpeechThreshold(
                baseThreshold: callerSpeechThreshold,
                noiseFloorRMS: postCallerFloor
            ),
            postCallerFloor * 2.2
        )
        let bargeInFloor = max(Self.defaultCallerBargeInThreshold, adaptiveCallerBase * 2.0)
        let thresholdForCaller = (!isCallerActive && isMicSpeaking)
            ? bargeInFloor
            : adaptiveCallerBase

        if calibratedRMS >= thresholdForCaller {
            callerConsecutiveVoiceFrames += 1
        } else {
            callerConsecutiveVoiceFrames = 0
        }

        let isVoiceDetected = Self.shouldActivateCallerSpeech(
            callerRMS: calibratedRMS,
            isCallerActive: isCallerActive,
            isMicCurrentlySpeaking: isMicSpeaking,
            consecutiveCallerFrames: callerConsecutiveVoiceFrames,
            callerSpeechThreshold: adaptiveCallerBase,
            callerBargeInThreshold: bargeInFloor
        )

        normalizeSpeechBuffer(
            converted,
            currentRMS: calibratedRMS,
            currentGain: &callerAGCGain,
            minRMSForBoost: adaptiveCallerBase * 0.5,
            allowBoost: isVoiceDetected || isCallerActive
        )

        var buffersToOutput: [AVAudioPCMBuffer] = []

        if isVoiceDetected {
            if !isCallerActive {
                isCallerActive = true
                buffersToOutput.append(contentsOf: callerPreRoll)
                callerPreRoll.removeAll(keepingCapacity: true)
                callerPreRollFrames = 0
            }
            lastCallerSpeechTime = now
            buffersToOutput.append(converted)
        } else {
            if isCallerActive {
                if (now - lastCallerSpeechTime) < callerHangoverDuration {
                    buffersToOutput.append(converted)
                } else {
                    isCallerActive = false
                    appendToPreRoll(converted, preRoll: &callerPreRoll, totalFrames: &callerPreRollFrames, maxFrames: maxPreRollFrames)
                }
            } else {
                appendToPreRoll(converted, preRoll: &callerPreRoll, totalFrames: &callerPreRollFrames, maxFrames: maxPreRollFrames)
            }
        }

        let measuredRawRMS = rawRMS
        let callerCurrentlySpeaking = isCallerActive && ((now - lastCallerSpeechTime) < 0.55)
        let callerAGCSnapshot = callerAGCGain
        let maybeUpdatedCallerGain: Float? = stateLock.withLock {
            rawCallerRMS = (rawCallerRMS * 0.55) + (measuredRawRMS * 0.45)
            if isVoiceDetected {
                lastCallerVoiceTimestamp = now
            }
            if measuredRawRMS >= callerPeakEnvelope {
                callerPeakEnvelope = measuredRawRMS
                lastCallerPeakTime = now
            } else if (now - lastCallerPeakTime) > 0.40 {
                callerPeakEnvelope = max(measuredRawRMS, callerPeakEnvelope * 0.85)
            }
            isCallerCurrentlySpeaking = callerCurrentlySpeaking
            callerHoldsVoice = isCallerActive
            floorOwner = Self.resolveFloorOwner(current: floorOwner, isCallerActive: isCallerActive, isUserActive: userHoldsVoice)
            callerCalibratedRMS = (callerCalibratedRMS * 0.55) + (calibratedRMS * 0.45)
            callerSignalPeak = max(callerPeakVal, callerSignalPeak * 0.88)
            callerEffectiveThreshold = thresholdForCaller
            callerLatestAGCGain = callerAGCSnapshot

            callerNoiseFloorRMS = Self.updateNoiseFloorEstimate(
                currentFloor: callerNoiseFloorRMS,
                sampleRMS: measuredRawRMS,
                isVoiceDetected: isVoiceDetected
            )
            if isVoiceDetected && measuredRawRMS >= callerSpeechThreshold * 0.4 {
                callerEstimatedSpeechRMS = callerEstimatedSpeechRMS > 0.0001
                    ? (callerEstimatedSpeechRMS * 0.82) + (measuredRawRMS * 0.18)
                    : measuredRawRMS
            }

            if autoGain {
                let minInterval: TimeInterval = callerPeakVal > 0.90 ? 0.35 : 1.0
                if (now - callerLastAutoGainUpdateTime) >= minInterval,
                   isVoiceDetected || callerPeakVal > 0.90 {
                    let candidate = Self.computeCalibratedInputGain(
                        currentGain: callerGain,
                        estimatedSpeechRMS: callerEstimatedSpeechRMS,
                        noiseFloorRMS: callerNoiseFloorRMS,
                        peakLevel: callerSignalPeak,
                        targetSpeechRMS: Self.defaultTargetSpeechRMS,
                        baseThreshold: callerSpeechThreshold
                    )
                    let minDelta = max(0.05, callerGain * 0.04)
                    if abs(candidate - callerGain) >= minDelta {
                        callerLastAutoGainUpdateTime = now
                        return candidate
                    }
                }
            }
            return nil
        }
        if let newCallerGain = maybeUpdatedCallerGain {
            settings.callerInputGain = newCallerGain
        }

        for pcm in buffersToOutput {
            delegate?.audioCaptureDidOutputCallerAudio(pcmBuffer: pcm)
        }

        if now - lastCallerLevelDispatchTime >= 0.08 {
            lastCallerLevelDispatchTime = now
            updateCallerAudioLevel(calibratedRMS)
        }
    }


    private func checkAudioTapPermissionHealth(rmsVal: Float, now: TimeInterval) {
        if rmsVal > 0.0000001 {
            let (newlyActive, shouldNotifyRestored) = stateLock.withLock { () -> (Bool, Bool) in
                let wasSilent = !hasReceivedNonZeroCallerSignal
                let hadDenied = didReportDeniedTapPermission
                hasReceivedNonZeroCallerSignal = true
                hasEverReceivedNonZeroCallerSignal = true
                silentWhileOutputActiveStartTime = 0
                didReportDeniedTapPermission = false
                return (wasSilent, hadDenied)
            }
            let wasHelperDenied = PermissionHelper.shared.audioCaptureState == .deniedSilenceDetected
            if newlyActive || wasHelperDenied {
                PermissionHelper.shared.updateAudioCaptureState(.active)
            }
            if shouldNotifyRestored || wasHelperDenied {
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.audioCaptureDidRestoreTapPermission()
                }
            }
            return
        }

        let shouldProbe = stateLock.withLock { () -> Bool in
            guard !hasEverReceivedNonZeroCallerSignal,
                  !hasReceivedNonZeroCallerSignal,
                  !didReportDeniedTapPermission else { return false }
            guard tapStartTime > 0, (now - tapStartTime) >= 3.0 else { return false }
            guard (now - lastPermissionProbeTime) >= 1.0 else { return false }
            lastPermissionProbeTime = now
            return true
        }
        guard shouldProbe else { return }

        if isOtherProcessAudioActiveThrottled(now: now) {
            let shouldAlert = stateLock.withLock { () -> Bool in
                guard !hasEverReceivedNonZeroCallerSignal else { return false }
                if isMicCurrentlySpeaking {
                    silentWhileOutputActiveStartTime = 0
                    return false
                }
                if silentWhileOutputActiveStartTime == 0 {
                    silentWhileOutputActiveStartTime = now
                    return false
                }
                if (now - silentWhileOutputActiveStartTime) >= 3.0 && !didReportDeniedTapPermission {
                    didReportDeniedTapPermission = true
                    return true
                }
                return false
            }
            if shouldAlert {
                AppLog.audio.warning("Detected sustained exact digital silence from CoreAudio tap while other audio processes are active; AudioCapture permission likely denied.")
                PermissionHelper.shared.updateAudioCaptureState(.deniedSilenceDetected)
                DispatchQueue.main.async { [weak self] in
                    self?.delegate?.audioCaptureDidDetectDeniedTapPermission()
                }
            }
        } else {
            stateLock.withLock {
                silentWhileOutputActiveStartTime = 0
            }
        }
    }

    public static func isOtherProcessRunningAudioOutput(excludingProcessObjectID ownID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return false
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &processIDs) == noErr else {
            return false
        }

        var outAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for procObj in processIDs where procObj != ownID && procObj != kAudioObjectUnknown {
            var isRunningOut: UInt32 = 0
            var propSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(procObj, &outAddr, 0, nil, &propSize, &isRunningOut) == noErr,
               isRunningOut != 0 {
                return true
            }
        }
        return false
    }

    private func updateCallerAudioLevel(_ rawLevel: Float) {
        let boosted = min(1.0, rawLevel * 12.0)
        let shouldDispatchLevel: Float? = stateLock.withLock {
            let next = (smoothedCallerLevel * 0.65) + (boosted * 0.35)
            smoothedCallerLevel = next < 0.002 ? 0.0 : next
            let diff = abs(smoothedCallerLevel - lastDispatchedCallerLevel)
            if diff >= 0.008 || (smoothedCallerLevel == 0.0 && lastDispatchedCallerLevel != 0.0) {
                lastDispatchedCallerLevel = smoothedCallerLevel
                return smoothedCallerLevel
            }
            return nil
        }

        if let newLevel = shouldDispatchLevel {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.audioCaptureDidUpdateCallerLevel(newLevel)
            }
        }
    }


    private func normalizeSpeechBuffer(
        _ buffer: AVAudioPCMBuffer,
        currentRMS: Float,
        currentGain: inout Float,
        minRMSForBoost: Float,
        allowBoost: Bool
    ) {
        guard let ptr = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        guard allowBoost else {
            currentGain = max(1.0, (currentGain * 0.85) + 0.15)
            if currentGain < 1.01 {
                currentGain = 1.0
            }
            return
        }
        currentGain = Self.nextAGCGain(
            currentRMS: currentRMS,
            currentGain: currentGain,
            minRMSForBoost: minRMSForBoost
        )
        guard currentGain > 1.05 else { return }

        let count = vDSP_Length(buffer.frameLength)
        var g = currentGain
        vDSP_vsmul(ptr, 1, &g, ptr, 1, count)
        var low: Float = -0.95
        var high: Float = 0.95
        vDSP_vclip(ptr, 1, &low, &high, ptr, 1, count)
    }

    public func convertTo16kMonoBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        var converter: AVAudioConverter? = nil
        return convertTo16kMono(
            buffer: buffer,
            cachedConverter: &converter,
            targetFormat: Self.speechFormat
        )
    }

    private func convertTo16kMono(
        buffer: AVAudioPCMBuffer,
        cachedConverter: inout AVAudioConverter?,
        targetFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }

        if buffer.format.sampleRate == targetFormat.sampleRate &&
           buffer.format.channelCount == 1 &&
           buffer.format.commonFormat == .pcmFormatFloat32 {
            guard let srcData = buffer.floatChannelData?[0],
                  let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(buffer.frameLength, 1)),
                  let dstData = outputBuffer.floatChannelData?[0] else {
                return nil
            }
            outputBuffer.frameLength = buffer.frameLength
            memcpy(dstData, srcData, Int(buffer.frameLength) * MemoryLayout<Float>.size)
            return outputBuffer
        }

        if cachedConverter == nil || cachedConverter?.inputFormat != buffer.format {
            let newConv = AVAudioConverter(from: buffer.format, to: targetFormat)
            if let newConv = newConv, newConv.channelMap.contains(-1) {
                newConv.channelMap = [0]
            }
            cachedConverter = newConv
        }
        guard let converter = cachedConverter else { return nil }

        let sampleRateRatio = targetFormat.sampleRate / buffer.format.sampleRate
        let targetCapacity = AVAudioFrameCount(Double(buffer.frameLength) * sampleRateRatio + 16)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(targetCapacity, 1024)) else {
            return nil
        }

        var error: NSError?
        var haveSupplied = false
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if !haveSupplied {
                haveSupplied = true
                outStatus.pointee = .haveData
                return buffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        if status == .error || error != nil || outputBuffer.frameLength == 0 {
            return nil
        }
        return outputBuffer
    }

    private static func decodePacked24BitChannel(
        src: UnsafePointer<UInt8>,
        strideBytes: Int,
        frameCount: Int,
        dst: UnsafeMutablePointer<Float>
    ) {
        let scale: Float = 1.0 / 2147483648.0
        for i in 0..<frameCount {
            let offset = i * strideBytes
            let b0 = UInt32(src[offset])
            let b1 = UInt32(src[offset + 1])
            let b2 = UInt32(src[offset + 2])
            let val32 = Int32(bitPattern: (b2 << 24) | (b1 << 16) | (b0 << 8))
            dst[i] = Float(val32) * scale
        }
    }

    @discardableResult
    public func convertAndCopyToMono(source buffer: AVAudioPCMBuffer, destination monoCopy: AVAudioPCMBuffer) -> Bool {
        let frameLen = buffer.frameLength
        guard frameLen > 0 else { return false }
        guard monoCopy.frameCapacity >= frameLen else { return false }
        monoCopy.frameLength = frameLen
        guard let dst = monoCopy.floatChannelData?[0] else { return false }

        let channelCount = Int(max(1, buffer.format.channelCount))
        let frameCountInt = Int(frameLen)
        let vLen = vDSP_Length(frameLen)
        let chosenChannel = channelCount > 2
            ? min(channelCount - 1, max(0, atomicSelectedMicCapsuleChannel.load(ordering: .relaxed)))
            : 0
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))

        if !buffer.format.isInterleaved, let srcChannels = buffer.floatChannelData {
            let minBytes = frameCountInt * MemoryLayout<Float>.size
            guard abl.count >= channelCount else { return false }
            if channelCount == 1 {
                guard Int(abl[0].mDataByteSize) >= minBytes else { return false }
                memcpy(dst, srcChannels[0], minBytes)
                return true
            } else if channelCount == 2 {
                guard Int(abl[0].mDataByteSize) >= minBytes,
                      Int(abl[1].mDataByteSize) >= minBytes else { return false }
                let ch0 = srcChannels[0]
                let ch1 = srcChannels[1]
                var half: Float = 0.5
                vDSP_vasm(ch0, 1, ch1, 1, &half, dst, 1, vLen)
                return true
            } else {
                for ch in 0..<channelCount {
                    guard Int(abl[ch].mDataByteSize) >= minBytes else { return false }
                }
                var chosenRMS: Float = 0.0
                vDSP_rmsqv(srcChannels[chosenChannel], 1, &chosenRMS, vLen)
                var bestCh = chosenChannel
                var bestRMS = chosenRMS
                for ch in 0..<channelCount where ch != chosenChannel {
                    var chRMS: Float = 0.0
                    vDSP_rmsqv(srcChannels[ch], 1, &chRMS, vLen)
                    if chRMS > chosenRMS * 1.15 && chRMS > 0.0005 && chRMS > bestRMS {
                        bestRMS = chRMS
                        bestCh = ch
                    }
                }
                if bestCh != chosenChannel {
                    atomicSelectedMicCapsuleChannel.store(bestCh, ordering: .relaxed)
                }
                memcpy(dst, srcChannels[bestCh], minBytes)
                return true
            }
        }

        if buffer.format.isInterleaved, buffer.format.commonFormat == .pcmFormatFloat32,
           abl.count >= 1,
           let mData = abl[0].mData {
            let minBytes = frameCountInt * channelCount * MemoryLayout<Float>.size
            guard Int(abl[0].mDataByteSize) >= minBytes else { return false }
            let srcPtr = mData.assumingMemoryBound(to: Float.self)
            if channelCount == 1 {
                memcpy(dst, srcPtr, minBytes)
                return true
            } else if channelCount == 2 {
                var half: Float = 0.5
                vDSP_vasm(srcPtr, 2, srcPtr.advanced(by: 1), 2, &half, dst, 1, vLen)
                return true
            } else {
                let chStride = vDSP_Stride(channelCount)
                var chosenRMS: Float = 0.0
                vDSP_rmsqv(srcPtr.advanced(by: chosenChannel), chStride, &chosenRMS, vLen)
                var bestCh = chosenChannel
                var bestRMS = chosenRMS
                for ch in 0..<channelCount where ch != chosenChannel {
                    var chRMS: Float = 0.0
                    vDSP_rmsqv(srcPtr.advanced(by: ch), chStride, &chRMS, vLen)
                    if chRMS > chosenRMS * 1.15 && chRMS > 0.0005 && chRMS > bestRMS {
                        bestRMS = chRMS
                        bestCh = ch
                    }
                }
                if bestCh != chosenChannel {
                    atomicSelectedMicCapsuleChannel.store(bestCh, ordering: .relaxed)
                }
                var gain: Float = 1.0
                vDSP_vsmul(srcPtr.advanced(by: bestCh), chStride, &gain, dst, 1, vLen)
                return true
            }
        }

        if let int16Channels = buffer.int16ChannelData {
            var div: Float = 32768.0
            if buffer.format.isInterleaved {
                let minBytes = frameCountInt * channelCount * MemoryLayout<Int16>.size
                guard abl.count >= 1, Int(abl[0].mDataByteSize) >= minBytes else { return false }
                let srcInt16 = int16Channels[0]
                if channelCount == 1 {
                    vDSP_vflt16(srcInt16, 1, dst, 1, vLen)
                    vDSP_vsdiv(dst, 1, &div, dst, 1, vLen)
                    return true
                } else if channelCount == 2 {
                    let halfDiv: Float = 65536.0
                    for i in 0..<frameCountInt {
                        let s0 = Float(srcInt16[i * 2])
                        let s1 = Float(srcInt16[i * 2 + 1])
                        dst[i] = (s0 + s1) / halfDiv
                    }
                    return true
                } else {
                    let chStride = vDSP_Stride(channelCount)
                    vDSP_vflt16(srcInt16.advanced(by: chosenChannel), chStride, dst, 1, vLen)
                    vDSP_vsdiv(dst, 1, &div, dst, 1, vLen)
                    var chosenRMS: Float = 0.0
                    vDSP_rmsqv(dst, 1, &chosenRMS, vLen)
                    var bestCh = chosenChannel
                    var bestRMS = chosenRMS
                    var lastConvertedCh = chosenChannel
                    for ch in 0..<channelCount where ch != chosenChannel {
                        vDSP_vflt16(srcInt16.advanced(by: ch), chStride, dst, 1, vLen)
                        vDSP_vsdiv(dst, 1, &div, dst, 1, vLen)
                        lastConvertedCh = ch
                        var chRMS: Float = 0.0
                        vDSP_rmsqv(dst, 1, &chRMS, vLen)
                        if chRMS > chosenRMS * 1.15 && chRMS > 0.0005 && chRMS > bestRMS {
                            bestRMS = chRMS
                            bestCh = ch
                        }
                    }
                    if bestCh != chosenChannel {
                        atomicSelectedMicCapsuleChannel.store(bestCh, ordering: .relaxed)
                    }
                    if lastConvertedCh != bestCh {
                        vDSP_vflt16(srcInt16.advanced(by: bestCh), chStride, dst, 1, vLen)
                        vDSP_vsdiv(dst, 1, &div, dst, 1, vLen)
                    }
                    return true
                }
            } else {
                let minBytes = frameCountInt * MemoryLayout<Int16>.size
                guard abl.count >= channelCount else { return false }
                for ch in 0..<channelCount {
                    guard Int(abl[ch].mDataByteSize) >= minBytes else { return false }
                }
                if channelCount == 1 {
                    vDSP_vflt16(int16Channels[0], 1, dst, 1, vLen)
                    vDSP_vsdiv(dst, 1, &div, dst, 1, vLen)
                    return true
                } else if channelCount == 2 {
                    let ch0 = int16Channels[0]
                    let ch1 = int16Channels[1]
                    let halfDiv: Float = 65536.0
                    for i in 0..<frameCountInt {
                        dst[i] = (Float(ch0[i]) + Float(ch1[i])) / halfDiv
                    }
                    return true
                }
                vDSP_vflt16(int16Channels[chosenChannel], 1, dst, 1, vLen)
                vDSP_vsdiv(dst, 1, &div, dst, 1, vLen)
                var chosenRMS: Float = 0.0
                vDSP_rmsqv(dst, 1, &chosenRMS, vLen)
                var bestCh = chosenChannel
                var bestRMS = chosenRMS
                var lastConvertedCh = chosenChannel
                for ch in 0..<channelCount where ch != chosenChannel {
                    vDSP_vflt16(int16Channels[ch], 1, dst, 1, vLen)
                    vDSP_vsdiv(dst, 1, &div, dst, 1, vLen)
                    lastConvertedCh = ch
                    var chRMS: Float = 0.0
                    vDSP_rmsqv(dst, 1, &chRMS, vLen)
                    if chRMS > chosenRMS * 1.15 && chRMS > 0.0005 && chRMS > bestRMS {
                        bestRMS = chRMS
                        bestCh = ch
                    }
                }
                if bestCh != chosenChannel {
                    atomicSelectedMicCapsuleChannel.store(bestCh, ordering: .relaxed)
                }
                if lastConvertedCh != bestCh {
                    vDSP_vflt16(int16Channels[bestCh], 1, dst, 1, vLen)
                    vDSP_vsdiv(dst, 1, &div, dst, 1, vLen)
                }
                return true
            }
        }

        if let int32Channels = buffer.int32ChannelData {
            let bitsPerChannel = buffer.format.streamDescription.pointee.mBitsPerChannel
            let isAlignedHigh = (buffer.format.streamDescription.pointee.mFormatFlags & kAudioFormatFlagIsAlignedHigh) != 0
            var div: Float = (bitsPerChannel == 24 && !isAlignedHigh) ? 8388608.0 : 2147483648.0

            if buffer.format.isInterleaved {
                let minBytes = frameCountInt * channelCount * MemoryLayout<Int32>.size
                guard abl.count >= 1, Int(abl[0].mDataByteSize) >= minBytes else { return false }
                let srcInt32 = int32Channels[0]
                if channelCount == 1 {
                    vDSP_vflt32(srcInt32, 1, dst, 1, vLen)
                    vDSP_vsdiv(dst, 1, &div, dst, 1, vLen)
                    return true
                } else if channelCount == 2 {
                    let halfDiv = div * 2.0
                    for i in 0..<frameCountInt {
                        let s0 = Float(srcInt32[i * 2])
                        let s1 = Float(srcInt32[i * 2 + 1])
                        dst[i] = (s0 + s1) / halfDiv
                    }
                    return true
                } else {
                    let chStride = vDSP_Stride(channelCount)
                    vDSP_vflt32(srcInt32.advanced(by: chosenChannel), chStride, dst, 1, vLen)
                    vDSP_vsdiv(dst, 1, &div, dst, 1, vLen)
                    var chosenRMS: Float = 0.0
                    vDSP_rmsqv(dst, 1, &chosenRMS, vLen)
                    var bestCh = chosenChannel
                    var bestRMS = chosenRMS
                    var lastConvertedCh = chosenChannel
                    for ch in 0..<channelCount where ch != chosenChannel {
                        vDSP_vflt32(srcInt32.advanced(by: ch), chStride, dst, 1, vLen)
                        vDSP_vsdiv(dst, 1, &div, dst, 1, vLen)
                        lastConvertedCh = ch
                        var chRMS: Float = 0.0
                        vDSP_rmsqv(dst, 1, &chRMS, vLen)
                        if chRMS > chosenRMS * 1.15 && chRMS > 0.0005 && chRMS > bestRMS {
                            bestRMS = chRMS
                            bestCh = ch
                        }
                    }
                    if bestCh != chosenChannel {
                        atomicSelectedMicCapsuleChannel.store(bestCh, ordering: .relaxed)
                    }
                    if lastConvertedCh != bestCh {
                        vDSP_vflt32(srcInt32.advanced(by: bestCh), chStride, dst, 1, vLen)
                        vDSP_vsdiv(dst, 1, &div, dst, 1, vLen)
                    }
                    return true
                }
            } else {
                let minBytes = frameCountInt * MemoryLayout<Int32>.size
                guard abl.count >= channelCount else { return false }
                for ch in 0..<channelCount {
                    guard Int(abl[ch].mDataByteSize) >= minBytes else { return false }
                }
                if channelCount == 1 {
                    vDSP_vflt32(int32Channels[0], 1, dst, 1, vLen)
                    vDSP_vsdiv(dst, 1, &div, dst, 1, vLen)
                    return true
                } else if channelCount == 2 {
                    let ch0 = int32Channels[0]
                    let ch1 = int32Channels[1]
                    let halfDiv = div * 2.0
                    for i in 0..<frameCountInt {
                        dst[i] = (Float(ch0[i]) + Float(ch1[i])) / halfDiv
                    }
                    return true
                }
                vDSP_vflt32(int32Channels[chosenChannel], 1, dst, 1, vLen)
                vDSP_vsdiv(dst, 1, &div, dst, 1, vLen)
                var chosenRMS: Float = 0.0
                vDSP_rmsqv(dst, 1, &chosenRMS, vLen)
                var bestCh = chosenChannel
                var bestRMS = chosenRMS
                var lastConvertedCh = chosenChannel
                for ch in 0..<channelCount where ch != chosenChannel {
                    vDSP_vflt32(int32Channels[ch], 1, dst, 1, vLen)
                    vDSP_vsdiv(dst, 1, &div, dst, 1, vLen)
                    lastConvertedCh = ch
                    var chRMS: Float = 0.0
                    vDSP_rmsqv(dst, 1, &chRMS, vLen)
                    if chRMS > chosenRMS * 1.15 && chRMS > 0.0005 && chRMS > bestRMS {
                        bestRMS = chRMS
                        bestCh = ch
                    }
                }
                if bestCh != chosenChannel {
                    atomicSelectedMicCapsuleChannel.store(bestCh, ordering: .relaxed)
                }
                if lastConvertedCh != bestCh {
                    vDSP_vflt32(int32Channels[bestCh], 1, dst, 1, vLen)
                    vDSP_vsdiv(dst, 1, &div, dst, 1, vLen)
                }
                return true
            }
        }

        let asbd = buffer.format.streamDescription.pointee
        if asbd.mFormatID == kAudioFormatLinearPCM,
           asbd.mBitsPerChannel == 24,
           (asbd.mFormatFlags & kAudioFormatFlagIsFloat) == 0,
           (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) == 0 {
            if buffer.format.isInterleaved {
                let bytesPerFrame = Int(asbd.mBytesPerFrame > 0 ? asbd.mBytesPerFrame : UInt32(channelCount * 3))
                guard abl.count >= 1,
                      let mData = abl[0].mData,
                      bytesPerFrame >= channelCount * 3,
                      Int(abl[0].mDataByteSize) >= frameCountInt * bytesPerFrame else {
                    return false
                }
                let bytePtr = mData.assumingMemoryBound(to: UInt8.self)
                if channelCount == 1 {
                    Self.decodePacked24BitChannel(src: bytePtr, strideBytes: bytesPerFrame, frameCount: frameCountInt, dst: dst)
                    return true
                } else if channelCount == 2 {
                    let halfScale: Float = 0.5 / 2147483648.0
                    for i in 0..<frameCountInt {
                        let off0 = i * bytesPerFrame
                        let val0 = Int32(bitPattern: (UInt32(bytePtr[off0 + 2]) << 24) | (UInt32(bytePtr[off0 + 1]) << 16) | (UInt32(bytePtr[off0]) << 8))
                        let off1 = off0 + 3
                        let val1 = Int32(bitPattern: (UInt32(bytePtr[off1 + 2]) << 24) | (UInt32(bytePtr[off1 + 1]) << 16) | (UInt32(bytePtr[off1]) << 8))
                        dst[i] = (Float(val0) + Float(val1)) * halfScale
                    }
                    return true
                } else {
                    Self.decodePacked24BitChannel(
                        src: bytePtr.advanced(by: chosenChannel * 3),
                        strideBytes: bytesPerFrame,
                        frameCount: frameCountInt,
                        dst: dst
                    )
                    var chosenRMS: Float = 0.0
                    vDSP_rmsqv(dst, 1, &chosenRMS, vLen)
                    var bestCh = chosenChannel
                    var bestRMS = chosenRMS
                    var lastDecodedCh = chosenChannel
                    for ch in 0..<channelCount where ch != chosenChannel {
                        Self.decodePacked24BitChannel(
                            src: bytePtr.advanced(by: ch * 3),
                            strideBytes: bytesPerFrame,
                            frameCount: frameCountInt,
                            dst: dst
                        )
                        lastDecodedCh = ch
                        var chRMS: Float = 0.0
                        vDSP_rmsqv(dst, 1, &chRMS, vLen)
                        if chRMS > chosenRMS * 1.15 && chRMS > 0.0005 && chRMS > bestRMS {
                            bestRMS = chRMS
                            bestCh = ch
                        }
                    }
                    if bestCh != chosenChannel {
                        atomicSelectedMicCapsuleChannel.store(bestCh, ordering: .relaxed)
                    }
                    if lastDecodedCh != bestCh {
                        Self.decodePacked24BitChannel(
                            src: bytePtr.advanced(by: bestCh * 3),
                            strideBytes: bytesPerFrame,
                            frameCount: frameCountInt,
                            dst: dst
                        )
                    }
                    return true
                }
            } else {
                let bytesPerSample = Int(asbd.mBytesPerFrame > 0 ? asbd.mBytesPerFrame : 3)
                guard abl.count >= channelCount, bytesPerSample >= 3 else {
                    return false
                }
                let minBytes = frameCountInt * bytesPerSample
                for ch in 0..<channelCount {
                    guard abl[ch].mData != nil, Int(abl[ch].mDataByteSize) >= minBytes else {
                        return false
                    }
                }
                if channelCount == 1 {
                    let src0 = abl[0].mData!.assumingMemoryBound(to: UInt8.self)
                    Self.decodePacked24BitChannel(src: src0, strideBytes: bytesPerSample, frameCount: frameCountInt, dst: dst)
                    return true
                } else if channelCount == 2 {
                    let src0 = abl[0].mData!.assumingMemoryBound(to: UInt8.self)
                    let src1 = abl[1].mData!.assumingMemoryBound(to: UInt8.self)
                    let halfScale: Float = 0.5 / 2147483648.0
                    for i in 0..<frameCountInt {
                        let off = i * bytesPerSample
                        let val0 = Int32(bitPattern: (UInt32(src0[off + 2]) << 24) | (UInt32(src0[off + 1]) << 16) | (UInt32(src0[off]) << 8))
                        let val1 = Int32(bitPattern: (UInt32(src1[off + 2]) << 24) | (UInt32(src1[off + 1]) << 16) | (UInt32(src1[off]) << 8))
                        dst[i] = (Float(val0) + Float(val1)) * halfScale
                    }
                    return true
                } else {
                    let chosenPtr = abl[chosenChannel].mData!.assumingMemoryBound(to: UInt8.self)
                    Self.decodePacked24BitChannel(src: chosenPtr, strideBytes: bytesPerSample, frameCount: frameCountInt, dst: dst)
                    var chosenRMS: Float = 0.0
                    vDSP_rmsqv(dst, 1, &chosenRMS, vLen)
                    var bestCh = chosenChannel
                    var bestRMS = chosenRMS
                    var lastDecodedCh = chosenChannel
                    for ch in 0..<channelCount where ch != chosenChannel {
                        let chPtr = abl[ch].mData!.assumingMemoryBound(to: UInt8.self)
                        Self.decodePacked24BitChannel(src: chPtr, strideBytes: bytesPerSample, frameCount: frameCountInt, dst: dst)
                        lastDecodedCh = ch
                        var chRMS: Float = 0.0
                        vDSP_rmsqv(dst, 1, &chRMS, vLen)
                        if chRMS > chosenRMS * 1.15 && chRMS > 0.0005 && chRMS > bestRMS {
                            bestRMS = chRMS
                            bestCh = ch
                        }
                    }
                    if bestCh != chosenChannel {
                        atomicSelectedMicCapsuleChannel.store(bestCh, ordering: .relaxed)
                    }
                    if lastDecodedCh != bestCh {
                        let bestPtr = abl[bestCh].mData!.assumingMemoryBound(to: UInt8.self)
                        Self.decodePacked24BitChannel(src: bestPtr, strideBytes: bytesPerSample, frameCount: frameCountInt, dst: dst)
                    }
                    return true
                }
            }
        }

        return false
    }

    public func copyToMonoPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        copyToMonoPCMBuffer(buffer, preferredFormat: nil)
    }

    private func copyToMonoPCMBuffer(_ buffer: AVAudioPCMBuffer, preferredFormat: AVAudioFormat?) -> AVAudioPCMBuffer? {
        let frameLen = buffer.frameLength
        guard frameLen > 0 else { return nil }
        let sampleRate = buffer.format.sampleRate

        let format: AVAudioFormat
        if let preferredFormat = preferredFormat, preferredFormat.sampleRate == sampleRate {
            format = preferredFormat
        } else if let existing = stateLock.withLock({ cachedTapMonoFormat }), existing.sampleRate == sampleRate {
            format = existing
        } else {
            guard let created = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            ) else { return nil }
            format = created
        }

        guard let monoCopy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLen) else {
            return nil
        }
        guard convertAndCopyToMono(source: buffer, destination: monoCopy) else {
            return nil
        }
        return monoCopy
    }

    private func appendToPreRoll(
        _ buffer: AVAudioPCMBuffer,
        preRoll: inout [AVAudioPCMBuffer],
        totalFrames: inout AVAudioFrameCount,
        maxFrames: AVAudioFrameCount
    ) {
        preRoll.append(buffer)
        totalFrames += buffer.frameLength
        while totalFrames > maxFrames && preRoll.count > 1 {
            let removed = preRoll.removeFirst()
            totalFrames -= min(totalFrames, removed.frameLength)
        }
    }

    private func appendToMicPreRoll(_ buffer: AVAudioPCMBuffer, startTime: TimeInterval) {
        micPreRoll.append(TimedPCMBuffer(buffer: buffer, startTime: startTime))
        micPreRollFrames += buffer.frameLength
        while micPreRollFrames > maxPreRollFrames && micPreRoll.count > 1 {
            let removed = micPreRoll.removeFirst()
            micPreRollFrames -= min(micPreRollFrames, removed.buffer.frameLength)
        }
    }
}
