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
}

public final class AudioCaptureEngine: NSObject, @unchecked Sendable {
    private struct SendablePCMBuffer: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }

    private struct UncheckedSendableBox<Value>: @unchecked Sendable {
        let value: Value
    }

    private final class OnceFlag: @unchecked Sendable {
        var used = false
    }

    public static let speechFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    private let stateLock = OSAllocatedUnfairLock()
    public weak var delegate: AudioCaptureDelegate?

    private var tapObjectID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ownProcessObjectID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID? = nil
    private var streamFormat: AVAudioFormat?
    private var aggFormatListenerBlock: AudioObjectPropertyListenerBlock?
    private var tapFormatListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?
    private var isRebuildingTap: Bool = false

    private var callerShouldBeEnabled: Bool = false
    private var tapRebuildRetryCount: Int = 0
    private var tapRebuildWorkItem: DispatchWorkItem? = nil

    private var cachedOtherProcessAudioActive: Bool = false
    private var lastOtherProcessQueryTime: TimeInterval = 0
    private var isQueryingOtherProcessAudio: Bool = false

    private struct CallerAudioChunk: @unchecked Sendable {
        let rawData: Data
        let frameCount: UInt32
        let sampleRate: Double
    }
    private let callerBacklogLock = OSAllocatedUnfairLock()
    private var callerPendingChunks: [CallerAudioChunk] = []
    private static let maxCallerBacklogChunks = 16
    private var callerDroppedChunksCount: Int = 0
    private var lastCallerDropLogTime: TimeInterval = 0
    private var isDrainingCallerQueue: Bool = false

    private var _isRunning: Bool = false
    public var isRunning: Bool {
        stateLock.withLock { _isRunning }
    }

    private var captureGeneration: UInt64 = 0
    private var callerWatchdogTimer: DispatchSourceTimer?
    private var lastCallerBufferTime: TimeInterval = 0
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
    private var lastPermissionProbeTime: TimeInterval = 0
    private var silentWhileOutputActiveStartTime: TimeInterval = 0
    private var didReportDeniedTapPermission: Bool = false

    private var micAudioEngine: AVAudioEngine?
    private var _isMicRunning: Bool = false
    private var micShouldBeEnabled: Bool = false
    private var isMicAuthorized: Bool = false
    private var lastMicBufferTime: TimeInterval = 0
    private var hasReceivedNonZeroMicSignal: Bool = false
    private var didAttemptZeroSignalRecovery: Bool = false
    private var micStartTime: TimeInterval = 0
    private var isRecoveringMic: Bool = false
    private var micRecoveryFailures: Int = 0
    private var nextAllowedMicRecoveryTime: TimeInterval = 0
    private var didReportMicFailureAlert: Bool = false
    private var isMicCurrentlySpeaking: Bool = false
    private var isCallerCurrentlySpeaking: Bool = false
    private var micWatchdogTimer: DispatchSourceTimer?
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?

    private let atomicIsMicRunning = Atomic<Bool>(false)
    private let atomicLastMicBufferTime = Atomic<Double>(0.0)
    private let atomicSelectedMicCapsuleChannel = Atomic<Int>(0)
    private let micScratchLock = OSAllocatedUnfairLock()
    public static let micScratchPoolCapacity = 16
    public static let micScratchFrameCapacity: AVAudioFrameCount = 16384
    private var micScratchBuffers: [SendablePCMBuffer] = []
    private let atomicMicScratchIndex = Atomic<UInt64>(0)

    public var isMicRunning: Bool {
        atomicIsMicRunning.load(ordering: .relaxed)
    }
    private var smoothedMicLevel: Float = 0.0
    private var lastDispatchedMicLevel: Float = 0.0
    private var lastMicLevelDispatchTime: TimeInterval = 0

    public static let defaultCallerSpeechThreshold: Float = 0.0014
    public static let defaultCallerBargeInThreshold: Float = 0.0075
    public static let defaultMicSpeechThreshold: Float = 0.0026
    private let callerSpeechThreshold: Float = AudioCaptureEngine.defaultCallerSpeechThreshold
    private let micSpeechThreshold: Float = AudioCaptureEngine.defaultMicSpeechThreshold
    private let callerHangoverDuration: TimeInterval = 0.70
    private let micHangoverDuration: TimeInterval = 1.00
    private let maxPreRollFrames: AVAudioFrameCount = 9600

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
    private var micPreRoll: [AVAudioPCMBuffer] = []
    private var micPreRollFrames: AVAudioFrameCount = 0
    private var micAGCGain: Float = 1.0

    public var callerLevel: Float {
        stateLock.withLock { smoothedCallerLevel }
    }

    public var micLevel: Float {
        stateLock.withLock { smoothedMicLevel }
    }

    public override init() {
        super.init()
        callerQueue.setSpecific(key: callerQueueKey, value: ())
        setupHardwareObservers()
    }

    deinit {
        teardownHardwareObservers()
        stop()
    }


    public static func computeRMS(samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0.0 }
        var rmsVal: Float = 0.0
        vDSP_rmsqv(samples, 1, &rmsVal, vDSP_Length(count))
        return rmsVal.isFinite ? rmsVal : 0.0
    }

    public static func nextAGCGain(
        currentRMS: Float,
        currentGain: Float,
        minRMSForBoost: Float,
        targetRMS: Float = 0.052
    ) -> Float {
        let desiredGain: Float
        if currentRMS >= minRMSForBoost && currentRMS < targetRMS {
            desiredGain = min(10.0, max(1.0, targetRMS / currentRMS))
        } else {
            desiredGain = 1.0
        }
        return (currentGain * 0.60) + (desiredGain * 0.40)
    }

    public static func backoffDelaySeconds(forAttempt attempt: Int) -> TimeInterval {
        let clampedExp = min(6, max(0, attempt - 1))
        return min(60.0, pow(2.0, Double(clampedExp)))
    }


    private func setupHardwareObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioEngineConfigChange(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: nil
        )

        var inputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let inputBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self else { return }
            let shouldRecover = self.stateLock.withLock { () -> Bool in
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
        defaultInputListenerBlock = inputBlock
        _ = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &inputAddress,
            micQueue,
            inputBlock
        )

        var outputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let outputBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self else { return }
            let shouldRebuild = self.stateLock.withLock { self.callerShouldBeEnabled }
            if shouldRebuild {
                AppLog.audio.info("Default output device changed; scheduling system audio tap rebuild...")
                self.scheduleTapFormatRebuild(attempt: 0, initialDelay: 0.40)
            }
        }
        defaultOutputListenerBlock = outputBlock
        _ = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &outputAddress,
            callerQueue,
            outputBlock
        )
    }

    private func teardownHardwareObservers() {
        NotificationCenter.default.removeObserver(self)
        if let block = defaultInputListenerBlock {
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
            defaultInputListenerBlock = nil
        }
        if let block = defaultOutputListenerBlock {
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
            defaultOutputListenerBlock = nil
        }
    }

    private func installTapFormatListeners(aggID: AudioObjectID, tapID: AudioObjectID) {
        removeTapFormatListeners(aggID: aggID, tapID: tapID)

        var aggAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let aggBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self, self.isRunning else { return }
            AppLog.audio.info("Aggregate device stream format changed; rebuilding tap...")
            self.scheduleTapFormatRebuild()
        }
        aggFormatListenerBlock = aggBlock
        _ = AudioObjectAddPropertyListenerBlock(aggID, &aggAddr, callerQueue, aggBlock)

        var tapAddr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let tapBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self = self, self.isRunning else { return }
            AppLog.audio.info("Process tap format changed; rebuilding tap...")
            self.scheduleTapFormatRebuild()
        }
        tapFormatListenerBlock = tapBlock
        _ = AudioObjectAddPropertyListenerBlock(tapID, &tapAddr, callerQueue, tapBlock)
    }

    private func removeTapFormatListeners(aggID: AudioObjectID, tapID: AudioObjectID) {
        if let aggBlock = aggFormatListenerBlock, aggID != kAudioObjectUnknown {
            var aggAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamFormat,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectRemovePropertyListenerBlock(aggID, &aggAddr, callerQueue, aggBlock)
        }
        aggFormatListenerBlock = nil

        if let tapBlock = tapFormatListenerBlock, tapID != kAudioObjectUnknown {
            var tapAddr = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectRemovePropertyListenerBlock(tapID, &tapAddr, callerQueue, tapBlock)
        }
        tapFormatListenerBlock = nil
    }

    private func scheduleTapFormatRebuild(attempt: Int = 0, initialDelay: TimeInterval = 0.40) {
        let shouldSchedule = stateLock.withLock { () -> Bool in
            guard callerShouldBeEnabled || _isRunning else { return false }
            if attempt == 0 {
                guard !isRebuildingTap && !isStartingEngine else { return false }
                isRebuildingTap = true
            }
            return true
        }
        guard shouldSchedule else { return }

        tapRebuildWorkItem?.cancel()

        let delay: TimeInterval
        if attempt == 0 {
            delay = initialDelay
        } else {
            let backoffSchedule: [TimeInterval] = [0.5, 1.0, 2.0]
            delay = backoffSchedule[min(attempt - 1, backoffSchedule.count - 1)]
        }

        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let (shouldRebuild, micEnabled) = self.stateLock.withLock { () -> (Bool, Bool) in
                (self.callerShouldBeEnabled, self.micShouldBeEnabled)
            }
            guard shouldRebuild else {
                self.stateLock.withLock {
                    self.isRebuildingTap = false
                    self.tapRebuildRetryCount = 0
                }
                return
            }

            do {
                try self.start(enableMic: micEnabled)
                self.stateLock.withLock {
                    self.isRebuildingTap = false
                    self.tapRebuildRetryCount = 0
                }
                AppLog.audio.info("Audio tap rebuilt successfully after route change")
            } catch {
                AppLog.audio.error("Audio tap rebuild attempt #\(attempt + 1) failed: \(error.localizedDescription, privacy: .public)")
                if attempt < 2 {
                    self.scheduleTapFormatRebuild(attempt: attempt + 1)
                } else {
                    let now = ProcessInfo.processInfo.systemUptime
                    self.stateLock.withLock {
                        self.isRebuildingTap = false
                        self.tapRebuildRetryCount = 3
                        self.nextAllowedCallerRecoveryTime = now + 10.0
                    }
                    DispatchQueue.main.async { [weak self] in
                        self?.delegate?.audioCaptureDidEncounterError(error)
                    }
                }
            }
        }
        tapRebuildWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
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

    private static let acousticIsolationState = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    public static var overrideAcousticIsolation: Bool? {
        get { acousticIsolationState.withLock { $0 } }
        set { acousticIsolationState.withLock { $0 = newValue } }
    }

    public static func isAudioOutputAcousticallyIsolated() -> Bool {
        if let overridden = overrideAcousticIsolation {
            return overridden
        }
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
            return false
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
                return true
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
                return true
            }
        }

        var nameVal: CFString?
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let nameStatus = withUnsafeMutablePointer(to: &nameVal) { ptr in
            AudioObjectGetPropertyData(defaultOutputDeviceID, &nameAddr, 0, nil, &nameSize, ptr)
        }
        if nameStatus == noErr, let str = nameVal as String? {
            let lower = str.lowercased()
            if lower.contains("headphone") || lower.contains("headset") ||
               lower.contains("airpod") || lower.contains("earpod") ||
               lower.contains("buds") || lower.contains("in-ear") {
                return true
            }
        }

        return false
    }

    @objc private func handleAudioEngineConfigChange(_ notification: Notification) {
        let shouldRecover = stateLock.withLock { micShouldBeEnabled }
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
        let now = ProcessInfo.processInfo.systemUptime
        let effectiveDelay: TimeInterval? = stateLock.withLock { () -> TimeInterval? in
            guard micShouldBeEnabled, !isRecoveringMic else { return nil }
            if resetBackoff {
                micRecoveryFailures = 0
                nextAllowedMicRecoveryTime = 0
            }
            if now < nextAllowedMicRecoveryTime {
                return nil
            }
            isRecoveringMic = true
            let backoff = micRecoveryFailures > 0 ? Self.backoffDelaySeconds(forAttempt: micRecoveryFailures) : delay
            return max(delay, backoff)
        }
        guard let waitDelay = effectiveDelay else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + waitDelay) { [weak self] in
            guard let self = self else { return }
            self.stateLock.withLock { self.isRecoveringMic = false }
            let stillEnabled = self.stateLock.withLock { self.micShouldBeEnabled }
            guard stillEnabled else { return }
            do {
                try self.startMicrophone()
            } catch {
                self.recordMicStartFailure(reason: error.localizedDescription)
            }
        }
    }

    private func recordMicStartFailure(reason: String) {
        let now = ProcessInfo.processInfo.systemUptime
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
            let now = ProcessInfo.processInfo.systemUptime
            let shouldRestart = self.stateLock.withLock { () -> Bool in
                guard self.micShouldBeEnabled, self.isMicAuthorized else { return false }
                guard now >= self.nextAllowedMicRecoveryTime, !self.isRecoveringMic else { return false }
                let engineRunning = self.micAudioEngine?.isRunning ?? false
                let bufferStalled = (self.lastMicBufferTime > 0 && (now - self.lastMicBufferTime) > 2.2)
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
        stateLock.withLock {
            micWatchdogTimer = timer
        }
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
            let now = ProcessInfo.processInfo.systemUptime
            let (shouldBeEnabled, running, rebuilding, starting, lastBuffer, startTime, nextAllowed) = self.stateLock.withLock {
                (self.callerShouldBeEnabled, self._isRunning, self.isRebuildingTap, self.isStartingEngine,
                 self.lastCallerBufferTime, self.tapStartTime, self.nextAllowedCallerRecoveryTime)
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
        stateLock.withLock {
            callerWatchdogTimer = timer
        }
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
        let alreadyStarting = stateLock.withLock { () -> Bool in
            if isStartingEngine { return true }
            isStartingEngine = true
            return false
        }
        if alreadyStarting { return }

        defer {
            stateLock.withLock { isStartingEngine = false }
        }

        stopInternal(isStoppingPermanently: false)
        stateLock.withLock {
            self.callerShouldBeEnabled = true
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
            PermissionHelper.shared.updateAudioCaptureState(.deniedSilenceDetected)
            throw NSError(
                domain: "AudioCaptureEngine",
                code: Int(tapStatus),
                userInfo: [NSLocalizedDescriptionKey: "System Audio Recording permission required (OSStatus \(tapStatus))"]
            )
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

        var newProcID: AudioDeviceIOProcID? = nil
        let bytesPerFrame = asbd.mBytesPerFrame > 0 ? asbd.mBytesPerFrame : 4
        let sampleRate = avFormat.sampleRate

        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, newAggID, callerQueue) { [weak self] _, inInputData, _, _, _ in
            guard let self = self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.stateLock.withLock {
                self.lastCallerBufferTime = now
            }
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard let firstBuffer = abl.first, let srcData = firstBuffer.mData else { return }
            let byteSize = Int(firstBuffer.mDataByteSize)
            let frameCount = UInt32(byteSize) / bytesPerFrame
            guard frameCount > 0 else { return }
            let copyByteCount = min(byteSize, Int(frameCount) * MemoryLayout<Float>.size)
            let rawCopy = Data(bytes: srcData, count: copyByteCount)

            let chunk = CallerAudioChunk(rawData: rawCopy, frameCount: frameCount, sampleRate: sampleRate)
            let shouldScheduleDrain = self.callerBacklogLock.withLock { () -> Bool in
                if self.callerPendingChunks.count >= Self.maxCallerBacklogChunks {
                    self.callerPendingChunks.removeFirst()
                    self.callerDroppedChunksCount += 1
                    if (now - self.lastCallerDropLogTime) >= 2.0 {
                        let dropped = self.callerDroppedChunksCount
                        self.lastCallerDropLogTime = now
                        self.callerDroppedChunksCount = 0
                        AppLog.audio.warning("Caller audio queue backlog exceeded; dropped \(dropped, privacy: .public) oldest buffers")
                    }
                }
                self.callerPendingChunks.append(chunk)
                if !self.isDrainingCallerQueue {
                    self.isDrainingCallerQueue = true
                    return true
                }
                return false
            }

            if shouldScheduleDrain {
                self.callerQueue.async { [weak self] in
                    self?.drainCallerAudioQueue()
                }
            }
        }

        guard ioStatus == noErr, let procID = newProcID else {
            _ = AudioHardwareDestroyAggregateDevice(newAggID)
            _ = AudioHardwareDestroyProcessTap(newTapID)
            throw NSError(
                domain: "AudioCaptureEngine",
                code: Int(ioStatus),
                userInfo: [NSLocalizedDescriptionKey: "AudioDeviceCreateIOProcIDWithBlock failed with OSStatus \(ioStatus)"]
            )
        }

        let startStatus = AudioDeviceStart(newAggID, procID)
        guard startStatus == noErr else {
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
        let now = ProcessInfo.processInfo.systemUptime
        stateLock.withLock {
            self.tapObjectID = finalTapID
            self.aggregateDeviceID = finalAggID
            self.ownProcessObjectID = finalOwnObjID
            self.ioProcID = procID
            self.streamFormat = avFormat
            self._isRunning = true
            self.callerShouldBeEnabled = true
            self.tapRebuildRetryCount = 0
            self.tapStartTime = now
            self.lastCallerBufferTime = 0
            self.hasReceivedNonZeroCallerSignal = false
            self.lastPermissionProbeTime = now
            self.silentWhileOutputActiveStartTime = 0
            self.didReportDeniedTapPermission = false
            self.captureGeneration &+= 1
        }

        installTapFormatListeners(aggID: finalAggID, tapID: finalTapID)
        startCallerWatchdog()
        AppLog.audio.info("CoreAudio Process Tap started (AggID: \(finalAggID, privacy: .public), TapID: \(finalTapID, privacy: .public), rate: \(sampleRate, privacy: .public)Hz)")

        stateLock.withLock {
            self.micShouldBeEnabled = enableMic
            self.micRecoveryFailures = 0
            self.nextAllowedMicRecoveryTime = 0
            self.didReportMicFailureAlert = false
        }
        if enableMic {
            startMicWatchdog()
            do {
                try startMicrophone()
            } catch {
                recordMicStartFailure(reason: error.localizedDescription)
            }
        }
    }


    public func startMicrophone() throws {
        guard stateLock.withLock({ micShouldBeEnabled }) else { return }
        stateLock.withLock {
            self.micShouldBeEnabled = true
        }
        if stateLock.withLock({ micWatchdogTimer == nil }) {
            startMicWatchdog()
        }

        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if authStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    guard granted else {
                        self.stateLock.withLock { self.isMicAuthorized = false }
                        return
                    }
                    let stillEnabled = self.stateLock.withLock { self.micShouldBeEnabled }
                    if stillEnabled {
                        try? self.startMicrophone()
                    }
                }
            }
            return
        }
        guard authStatus == .authorized else {
            stateLock.withLock { isMicAuthorized = false }
            return
        }
        stateLock.withLock { isMicAuthorized = true }

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
        let newScratchBuffers = (0..<Self.micScratchPoolCapacity).compactMap { _ in
            AVAudioPCMBuffer(pcmFormat: precomputedMonoFormat, frameCapacity: scratchCapacity).map { SendablePCMBuffer(buffer: $0) }
        }
        micScratchLock.withLock {
            self.cachedTapMonoFormat = precomputedMonoFormat
            self.micScratchBuffers = newScratchBuffers
        }

        AudioTapHelper.installTap(on: inputNode, bus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            guard let self = self, self.atomicIsMicRunning.load(ordering: .relaxed) else { return }
            let now = ProcessInfo.processInfo.systemUptime
            self.atomicLastMicBufferTime.store(now, ordering: .relaxed)

            let scratchIdx = Int(self.atomicMicScratchIndex.wrappingAdd(1, ordering: .relaxed).oldValue % UInt64(Self.micScratchPoolCapacity))
            let scratch = self.micScratchLock.withLock {
                scratchIdx < self.micScratchBuffers.count ? self.micScratchBuffers[scratchIdx] : nil
            }?.buffer

            let pcmToProcess: AVAudioPCMBuffer?
            if let scratch = scratch, self.convertAndCopyToMono(source: buffer, destination: scratch) {
                pcmToProcess = scratch
            } else {
                pcmToProcess = self.copyToMonoPCMBuffer(buffer)
            }
            guard let validBuffer = pcmToProcess else { return }
            let sendable = SendablePCMBuffer(buffer: validBuffer)
            self.micQueue.async { [weak self] in
                self?.handleIncomingMicAudio(buffer: sendable.buffer)
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            micScratchLock.withLock {
                micScratchBuffers.removeAll()
                cachedTapMonoFormat = nil
            }
            throw error
        }

        let now = ProcessInfo.processInfo.systemUptime
        let engineBox = UncheckedSendableBox(value: engine)
        atomicIsMicRunning.store(true, ordering: .relaxed)
        atomicLastMicBufferTime.store(now, ordering: .relaxed)
        atomicSelectedMicCapsuleChannel.store(0, ordering: .relaxed)
        stateLock.withLock {
            self.micAudioEngine = engineBox.value
            self._isMicRunning = true
            self.lastMicBufferTime = now
            self.micStartTime = now
            self.hasReceivedNonZeroMicSignal = false
            self.didAttemptZeroSignalRecovery = false
            self.micRecoveryFailures = 0
            self.nextAllowedMicRecoveryTime = 0
            self.didReportMicFailureAlert = false
        }

        AppLog.audio.info("Microphone capture started (\(busFormat.sampleRate, privacy: .public)Hz, \(busFormat.channelCount, privacy: .public)ch -> 1ch mono)")
    }

    private func tearDownMicrophoneEngineOnly() {
        atomicIsMicRunning.store(false, ordering: .relaxed)
        atomicLastMicBufferTime.store(0.0, ordering: .relaxed)
        atomicSelectedMicCapsuleChannel.store(0, ordering: .relaxed)

        let oldEngineBox = stateLock.withLock { () -> UncheckedSendableBox<AVAudioEngine>? in
            _isMicRunning = false
            isMicCurrentlySpeaking = false
            lastMicBufferTime = 0
            let e = micAudioEngine
            micAudioEngine = nil
            return e.map { UncheckedSendableBox(value: $0) }
        }

        if let engine = oldEngineBox?.value {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning {
                engine.stop()
            }
        }

        micScratchLock.withLock {
            micScratchBuffers.removeAll()
            cachedTapMonoFormat = nil
        }

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
        stateLock.withLock {
            micShouldBeEnabled = false
            isMicCurrentlySpeaking = false
            didAttemptZeroSignalRecovery = false
            micRecoveryFailures = 0
            nextAllowedMicRecoveryTime = 0
            didReportMicFailureAlert = false
            smoothedMicLevel = 0.0
            lastDispatchedMicLevel = 0.0
        }
        stopMicWatchdog()
        tearDownMicrophoneEngineOnly()

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.audioCaptureDidUpdateMicLevel(0)
        }
    }

    public func setMicrophoneEnabled(_ enabled: Bool) {
        stateLock.withLock {
            micShouldBeEnabled = enabled
            if enabled {
                micRecoveryFailures = 0
                nextAllowedMicRecoveryTime = 0
                didReportMicFailureAlert = false
            }
        }
        if enabled {
            startMicWatchdog()
            if !isMicRunning {
                do {
                    try startMicrophone()
                } catch {
                    recordMicStartFailure(reason: error.localizedDescription)
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
            effectiveThreshold = max(0.035, callerEnergy * 3.5)
            requiredFrames = 6
        } else {
            effectiveThreshold = micSpeechThreshold
            requiredFrames = isMicCurrentlySpeaking ? 1 : 2
        }
        return (isCallerSpeakingOrEchoing, effectiveThreshold, requiredFrames)
    }

    private func handleIncomingMicAudio(buffer: AVAudioPCMBuffer) {
        guard isMicRunning else { return }

        guard let converted = convertTo16kMono(
            buffer: buffer,
            cachedConverter: &micConverter,
            targetFormat: Self.speechFormat
        ) else { return }

        var rmsVal: Float = 0.0
        if let channelData = converted.floatChannelData?[0] {
            rmsVal = Self.computeRMS(samples: channelData, count: Int(converted.frameLength))
        }

        let now = ProcessInfo.processInfo.systemUptime
        if rmsVal > 0.0000001 {
            stateLock.withLock {
                self.hasReceivedNonZeroMicSignal = true
                self.micRecoveryFailures = 0
            }
        }

        let (rawCaller, peakCaller, callerSpeaking, lastCallerVoice, micSpeaking) = stateLock.withLock {
            (rawCallerRMS, callerPeakEnvelope, isCallerCurrentlySpeaking, lastCallerVoiceTimestamp, isMicCurrentlySpeaking)
        }
        let isIsolated = Self.isAudioOutputAcousticallyIsolated()
        let timeSinceCallerVoice = lastCallerVoice > 0 ? (now - lastCallerVoice) : .greatestFiniteMagnitude
        let (isCallerSpeakingOrEchoing, effectiveThreshold, _) = Self.evaluateMicEchoState(
            rawCallerRMS: rawCaller,
            callerPeakEnvelope: peakCaller,
            isCallerCurrentlySpeaking: callerSpeaking,
            timeSinceLastCallerVoice: timeSinceCallerVoice,
            isAcousticallyIsolated: isIsolated,
            isMicCurrentlySpeaking: micSpeaking,
            micSpeechThreshold: micSpeechThreshold,
            callerSpeechThreshold: callerSpeechThreshold
        )

        if rmsVal >= effectiveThreshold {
            micConsecutiveVoiceFrames += 1
        } else {
            micConsecutiveVoiceFrames = 0
        }

        let requiredFrames: Int
        if isCallerSpeakingOrEchoing {
            requiredFrames = isMicActive ? 1 : 6
        } else {
            requiredFrames = isMicActive ? 1 : 2
        }
        let isVoiceDetected = (micConsecutiveVoiceFrames >= requiredFrames)

        normalizeSpeechBuffer(
            converted,
            currentRMS: rmsVal,
            currentGain: &micAGCGain,
            minRMSForBoost: micSpeechThreshold * 0.5
        )

        var buffersToOutput: [AVAudioPCMBuffer] = []

        if isVoiceDetected {
            if !isMicActive {
                isMicActive = true
                if !isCallerSpeakingOrEchoing {
                    buffersToOutput.append(contentsOf: micPreRoll)
                }
                micPreRoll.removeAll(keepingCapacity: true)
                micPreRollFrames = 0
            }
            stateLock.withLock { isMicCurrentlySpeaking = true }
            lastMicSpeechTime = now
            buffersToOutput.append(converted)
        } else {
            if isCallerSpeakingOrEchoing {
                isMicActive = false
                stateLock.withLock { isMicCurrentlySpeaking = false }
                micPreRoll.removeAll(keepingCapacity: true)
                micPreRollFrames = 0
            } else if isMicActive {
                let silenceElapsed = now - lastMicSpeechTime
                if silenceElapsed >= 0.45 {
                    stateLock.withLock { isMicCurrentlySpeaking = false }
                }
                if silenceElapsed < micHangoverDuration {
                    buffersToOutput.append(converted)
                } else {
                    isMicActive = false
                    stateLock.withLock { isMicCurrentlySpeaking = false }
                    appendToPreRoll(converted, preRoll: &micPreRoll, totalFrames: &micPreRollFrames, maxFrames: maxPreRollFrames)
                }
            } else {
                appendToPreRoll(converted, preRoll: &micPreRoll, totalFrames: &micPreRollFrames, maxFrames: maxPreRollFrames)
            }
        }

        for pcm in buffersToOutput {
            delegate?.audioCaptureDidOutputMicAudio(pcmBuffer: pcm)
        }

        if now - lastMicLevelDispatchTime >= 0.08 {
            lastMicLevelDispatchTime = now
            updateMicAudioLevel(isCallerSpeakingOrEchoing && !isVoiceDetected ? 0.0 : rmsVal)
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
        tapRebuildWorkItem?.cancel()
        tapRebuildWorkItem = nil
        stopInternal(isStoppingPermanently: true)
    }

    private func stopInternal(isStoppingPermanently: Bool) {
        stopMicrophone()
        stopCallerWatchdog()

        let (tapToDestroy, aggToDestroy, procToStop) = stateLock.withLock { () -> (AudioObjectID, AudioObjectID, AudioDeviceIOProcID?) in
            captureGeneration &+= 1
            _isRunning = false
            if isStoppingPermanently {
                callerShouldBeEnabled = false
                isRebuildingTap = false
                tapRebuildRetryCount = 0
            }
            rawCallerRMS = 0.0
            callerPeakEnvelope = 0.0
            lastCallerPeakTime = 0
            lastCallerVoiceTimestamp = 0
            isCallerCurrentlySpeaking = false
            lastCallerBufferTime = 0
            nextAllowedCallerRecoveryTime = 0
            smoothedCallerLevel = 0.0
            lastDispatchedCallerLevel = 0.0
            let tap = tapObjectID
            let agg = aggregateDeviceID
            let proc = ioProcID
            tapObjectID = kAudioObjectUnknown
            aggregateDeviceID = kAudioObjectUnknown
            ownProcessObjectID = kAudioObjectUnknown
            ioProcID = nil
            streamFormat = nil
            return (tap, agg, proc)
        }

        callerBacklogLock.withLock {
            callerPendingChunks.removeAll(keepingCapacity: false)
            callerDroppedChunksCount = 0
            isDrainingCallerQueue = false
        }

        removeTapFormatListeners(aggID: aggToDestroy, tapID: tapToDestroy)

        if let proc = procToStop, aggToDestroy != kAudioObjectUnknown {
            _ = AudioDeviceStop(aggToDestroy, proc)
            _ = AudioDeviceDestroyIOProcID(aggToDestroy, proc)
        }
        if aggToDestroy != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggToDestroy)
        }
        if tapToDestroy != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapToDestroy)
        }

        if DispatchQueue.getSpecific(key: callerQueueKey) != nil {
            callerMonoFormat = nil
            callerConverter = nil
            isCallerActive = false
            callerConsecutiveVoiceFrames = 0
            lastCallerSpeechTime = 0
            callerAGCGain = 1.0
            callerPreRoll.removeAll(keepingCapacity: false)
            callerPreRollFrames = 0
        } else {
            callerQueue.sync {
                callerMonoFormat = nil
                callerConverter = nil
                isCallerActive = false
                callerConsecutiveVoiceFrames = 0
                lastCallerSpeechTime = 0
                callerAGCGain = 1.0
                callerPreRoll.removeAll(keepingCapacity: false)
                callerPreRollFrames = 0
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.audioCaptureDidUpdateCallerLevel(0)
        }
    }

    private func drainCallerAudioQueue() {
        while true {
            let nextChunk = callerBacklogLock.withLock { () -> CallerAudioChunk? in
                if callerPendingChunks.isEmpty {
                    isDrainingCallerQueue = false
                    return nil
                }
                return callerPendingChunks.removeFirst()
            }
            guard let chunk = nextChunk else { break }
            processCallerAudioOnQueue(rawData: chunk.rawData, frameCount: chunk.frameCount, sampleRate: chunk.sampleRate)
        }
    }

    private func processCallerAudioOnQueue(rawData: Data, frameCount: UInt32, sampleRate: Double) {
        guard isRunning, frameCount > 0 else { return }

        if callerMonoFormat == nil || callerMonoFormat?.sampleRate != sampleRate {
            callerMonoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            )
        }
        guard let monoFormat = callerMonoFormat,
              let srcPCM = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCount) else { return }
        srcPCM.frameLength = frameCount

        guard let dst = srcPCM.floatChannelData?[0] else { return }
        rawData.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            memcpy(dst, base, min(rawData.count, Int(frameCount) * MemoryLayout<Float>.size))
        }

        guard let converted = convertTo16kMono(
            buffer: srcPCM,
            cachedConverter: &callerConverter,
            targetFormat: Self.speechFormat
        ) else { return }

        guard let channelData = converted.floatChannelData?[0] else { return }
        let rmsVal = Self.computeRMS(samples: channelData, count: Int(converted.frameLength))
        let now = ProcessInfo.processInfo.systemUptime

        checkAudioTapPermissionHealth(rmsVal: rmsVal, now: now)

        let isMicSpeaking = stateLock.withLock { isMicCurrentlySpeaking }
        let thresholdForCaller = (!isCallerActive && isMicSpeaking)
            ? Self.defaultCallerBargeInThreshold
            : callerSpeechThreshold

        if rmsVal >= thresholdForCaller {
            callerConsecutiveVoiceFrames += 1
        } else {
            callerConsecutiveVoiceFrames = 0
        }

        let isVoiceDetected = Self.shouldActivateCallerSpeech(
            callerRMS: rmsVal,
            isCallerActive: isCallerActive,
            isMicCurrentlySpeaking: isMicSpeaking,
            consecutiveCallerFrames: callerConsecutiveVoiceFrames,
            callerSpeechThreshold: callerSpeechThreshold,
            callerBargeInThreshold: Self.defaultCallerBargeInThreshold
        )

        normalizeSpeechBuffer(
            converted,
            currentRMS: rmsVal,
            currentGain: &callerAGCGain,
            minRMSForBoost: callerSpeechThreshold * 0.5
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

        let measuredRMS = rmsVal
        let callerCurrentlySpeaking = isCallerActive && ((now - lastCallerSpeechTime) < 0.55)
        stateLock.withLock {
            if isCallerActive || !isMicSpeaking || isVoiceDetected {
                rawCallerRMS = (rawCallerRMS * 0.55) + (measuredRMS * 0.45)
                if isVoiceDetected {
                    lastCallerVoiceTimestamp = now
                }
                if measuredRMS >= callerPeakEnvelope {
                    callerPeakEnvelope = measuredRMS
                    lastCallerPeakTime = now
                } else if (now - lastCallerPeakTime) > 0.40 {
                    callerPeakEnvelope = max(measuredRMS, callerPeakEnvelope * 0.85)
                }
            }
            isCallerCurrentlySpeaking = callerCurrentlySpeaking
        }

        for pcm in buffersToOutput {
            delegate?.audioCaptureDidOutputCallerAudio(pcmBuffer: pcm)
        }

        if now - lastCallerLevelDispatchTime >= 0.08 {
            lastCallerLevelDispatchTime = now
            updateCallerAudioLevel(rmsVal)
        }
    }


    private func checkAudioTapPermissionHealth(rmsVal: Float, now: TimeInterval) {
        if rmsVal > 0.0000001 {
            let newlyActive = stateLock.withLock { () -> Bool in
                let wasSilent = !hasReceivedNonZeroCallerSignal
                hasReceivedNonZeroCallerSignal = true
                silentWhileOutputActiveStartTime = 0
                return wasSilent
            }
            if newlyActive {
                PermissionHelper.shared.updateAudioCaptureState(.active)
            }
            return
        }

        let shouldProbe = stateLock.withLock { () -> Bool in
            guard !hasReceivedNonZeroCallerSignal, !didReportDeniedTapPermission else { return false }
            guard (now - lastPermissionProbeTime) >= 1.0 else { return false }
            lastPermissionProbeTime = now
            return true
        }
        guard shouldProbe else { return }

        if isOtherProcessAudioActiveThrottled(now: now) {
            let shouldAlert = stateLock.withLock { () -> Bool in
                if silentWhileOutputActiveStartTime == 0 {
                    silentWhileOutputActiveStartTime = now
                    return false
                }
                if (now - silentWhileOutputActiveStartTime) >= 2.5 && !didReportDeniedTapPermission {
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
        minRMSForBoost: Float
    ) {
        guard let ptr = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
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
        let haveSupplied = OnceFlag()
        let inputBox = UncheckedSendableBox(value: buffer)
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if !haveSupplied.used {
                haveSupplied.used = true
                outStatus.pointee = .haveData
                return inputBox.value
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

        if !buffer.format.isInterleaved, let srcChannels = buffer.floatChannelData {
            if channelCount == 1 {
                let byteCount = frameCountInt * MemoryLayout<Float>.size
                memcpy(dst, srcChannels[0], byteCount)
                return true
            } else if channelCount == 2 {
                let ch0 = srcChannels[0]
                let ch1 = srcChannels[1]
                var half: Float = 0.5
                vDSP_vasm(ch0, 1, ch1, 1, &half, dst, 1, vLen)
                return true
            } else {
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
                let byteCount = frameCountInt * MemoryLayout<Float>.size
                memcpy(dst, srcChannels[bestCh], byteCount)
                if channelCount == 3 {
                    var boost: Float = 2.0
                    vDSP_vsmul(dst, 1, &boost, dst, 1, vLen)
                }
                return true
            }
        }

        if buffer.format.isInterleaved, buffer.format.commonFormat == .pcmFormatFloat32,
           let mData = buffer.audioBufferList.pointee.mBuffers.mData {
            let srcPtr = mData.assumingMemoryBound(to: Float.self)
            if channelCount == 1 {
                let byteCount = frameCountInt * MemoryLayout<Float>.size
                memcpy(dst, srcPtr, byteCount)
                return true
            } else if channelCount == 2 {
                for i in 0..<frameCountInt {
                    dst[i] = (srcPtr[i * 2] + srcPtr[i * 2 + 1]) * 0.5
                }
                return true
            } else {
                for i in 0..<frameCountInt {
                    dst[i] = srcPtr[i * channelCount + chosenChannel]
                }
                return true
            }
        }

        if let int16Channels = buffer.int16ChannelData {
            var div: Float = 32768.0
            if buffer.format.isInterleaved {
                let srcInt16 = int16Channels[0]
                if channelCount == 1 {
                    vDSP_vflt16(srcInt16, 1, dst, 1, vLen)
                    vDSP_vsdiv(dst, 1, &div, dst, 1, vLen)
                    return true
                } else {
                    let chPtr = srcInt16.advanced(by: chosenChannel)
                    vDSP_vflt16(chPtr, vDSP_Stride(channelCount), dst, 1, vLen)
                    vDSP_vsdiv(dst, 1, &div, dst, 1, vLen)
                    return true
                }
            } else {
                var bestCh = chosenChannel
                if channelCount > 2 {
                    let chosenPtr = int16Channels[chosenChannel]
                    let chosenSilent = !(0..<frameCountInt).contains(where: { chosenPtr[$0] != 0 })
                    if chosenSilent {
                        for ch in 0..<channelCount where ch != chosenChannel {
                            let chPtr = int16Channels[ch]
                            if (0..<frameCountInt).contains(where: { chPtr[$0] != 0 }) {
                                bestCh = ch
                                atomicSelectedMicCapsuleChannel.store(ch, ordering: .relaxed)
                                break
                            }
                        }
                    }
                }
                vDSP_vflt16(int16Channels[bestCh], 1, dst, 1, vLen)
                vDSP_vsdiv(dst, 1, &div, dst, 1, vLen)
                return true
            }
        }

        if let int32Channels = buffer.int32ChannelData {
            let bitsPerChannel = buffer.format.streamDescription.pointee.mBitsPerChannel
            let isAlignedHigh = (buffer.format.streamDescription.pointee.mFormatFlags & kAudioFormatFlagIsAlignedHigh) != 0
            var div: Float = (bitsPerChannel == 24 && !isAlignedHigh) ? 8388608.0 : 2147483648.0

            if buffer.format.isInterleaved {
                let srcInt32 = int32Channels[0]
                if channelCount == 1 {
                    vDSP_vflt32(srcInt32, 1, dst, 1, vLen)
                    vDSP_vsdiv(dst, 1, &div, dst, 1, vLen)
                    return true
                } else {
                    let chPtr = srcInt32.advanced(by: chosenChannel)
                    vDSP_vflt32(chPtr, vDSP_Stride(channelCount), dst, 1, vLen)
                    vDSP_vsdiv(dst, 1, &div, dst, 1, vLen)
                    return true
                }
            } else {
                var bestCh = chosenChannel
                if channelCount > 2 {
                    let chosenPtr = int32Channels[chosenChannel]
                    let chosenSilent = !(0..<frameCountInt).contains(where: { chosenPtr[$0] != 0 })
                    if chosenSilent {
                        for ch in 0..<channelCount where ch != chosenChannel {
                            let chPtr = int32Channels[ch]
                            if (0..<frameCountInt).contains(where: { chPtr[$0] != 0 }) {
                                bestCh = ch
                                atomicSelectedMicCapsuleChannel.store(ch, ordering: .relaxed)
                                break
                            }
                        }
                    }
                }
                vDSP_vflt32(int32Channels[bestCh], 1, dst, 1, vLen)
                vDSP_vsdiv(dst, 1, &div, dst, 1, vLen)
                return true
            }
        }

        let asbd = buffer.format.streamDescription.pointee
        if asbd.mBitsPerChannel == 24,
           let mData = buffer.audioBufferList.pointee.mBuffers.mData {
            let bytePtr = mData.assumingMemoryBound(to: UInt8.self)
            let bytesPerFrame = Int(asbd.mBytesPerFrame > 0 ? asbd.mBytesPerFrame : UInt32(channelCount * 3))
            if channelCount == 2 {
                for i in 0..<frameCountInt {
                    let off0 = i * bytesPerFrame
                    let val0 = Int32(bitPattern: (UInt32(bytePtr[off0 + 2]) << 24) | (UInt32(bytePtr[off0 + 1]) << 16) | (UInt32(bytePtr[off0]) << 8))
                    let off1 = off0 + 3
                    let val1 = Int32(bitPattern: (UInt32(bytePtr[off1 + 2]) << 24) | (UInt32(bytePtr[off1 + 1]) << 16) | (UInt32(bytePtr[off1]) << 8))
                    dst[i] = (Float(val0) + Float(val1)) * 0.5 / 2147483648.0
                }
                return true
            } else {
                for i in 0..<frameCountInt {
                    let offset = (i * bytesPerFrame) + (chosenChannel * 3)
                    let b0 = UInt32(bytePtr[offset])
                    let b1 = UInt32(bytePtr[offset + 1])
                    let b2 = UInt32(bytePtr[offset + 2])
                    let val32 = Int32(bitPattern: (b2 << 24) | (b1 << 16) | (b0 << 8))
                    dst[i] = Float(val32) / 2147483648.0
                }
                return true
            }
        }

        return false
    }

    public func copyToMonoPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frameLen = buffer.frameLength
        guard frameLen > 0 else { return nil }
        let sampleRate = buffer.format.sampleRate

        let format: AVAudioFormat
        let cachedFormat = micScratchLock.withLock { cachedTapMonoFormat }
        if let existing = cachedFormat, existing.sampleRate == sampleRate {
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
}
