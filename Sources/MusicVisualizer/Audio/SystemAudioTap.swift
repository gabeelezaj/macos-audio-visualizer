import AudioToolbox
import CoreAudio
import Foundation

/// Captures whatever the computer is playing through its speakers.
///
/// Uses a Core Audio *process tap* (macOS 14.2+): the tap is bound to a private
/// aggregate device whose input stream carries the mixed output of either every
/// process or a chosen subset. No virtual audio driver (BlackHole/Loopback) and no
/// screen-recording permission — just the "System Audio Recording" TCC prompt.
/// Marked `@unchecked Sendable` so the engine can start it off the main thread; all
/// control calls are funnelled through one serial queue there, and the audio path
/// itself lives in `TapSink`.
final class SystemAudioTap: @unchecked Sendable {
    enum Target: Sendable {
        case entireSystem
        /// Core Audio process object IDs (see `AudioProcessLister`).
        case processes([AudioObjectID])
    }

    private let sink = TapSink(ring: AudioRingBuffer())
    var ring: AudioRingBuffer { sink.ring }
    private(set) var sampleRate: Double = 48_000
    private(set) var isRunning = false
    /// Human-readable description of the device chain, for diagnostics.
    private(set) var routeDescription = "not started"
    /// IO callbacks received since the tap started. Zero after a second or two of
    /// running means macOS is refusing to deliver audio at all.
    var callbackCount: Int { sink.callbackCount }

    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "com.visualizer.audio.io", qos: .userInteractive)

    /// Called on a background queue whenever the default output device changes.
    var onDefaultDeviceChange: (() -> Void)?
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?

    // MARK: - Lifecycle

    func start(target: Target) throws {
        stop()

        let outputDevice = try AudioObjectID.defaultOutputDevice()
        guard outputDevice.isValid else { throw AudioError.noOutputDevice }
        let outputUID = outputDevice.deviceUID
        guard !outputUID.isEmpty else { throw AudioError.noOutputDevice }

        // 1. Describe the tap. A "global tap excluding nothing" is the whole system mix.
        let description: CATapDescription
        switch target {
        case .entireSystem:
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        case .processes(let objects):
            description = CATapDescription(stereoMixdownOfProcesses: objects)
        }
        description.name = "Music Visualizer Tap"
        description.uuid = UUID()
        description.isPrivate = true          // invisible in other apps' device lists
        description.muteBehavior = .unmuted    // keep the user's speakers playing

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID.isValid else {
            throw AudioError.tapCreationFailed(status)
        }

        // 2. The tap's own format tells us the sample rate to analyse at.
        if let asbd = try? tapID.read(kAudioTapPropertyFormat,
                                      default: AudioStreamBasicDescription()),
           asbd.mSampleRate > 0 {
            sampleRate = asbd.mSampleRate
        } else {
            sampleRate = (try? outputDevice.read(kAudioDevicePropertyNominalSampleRate, default: 48_000.0)) ?? 48_000
        }

        // 3. A private aggregate device is the only way to run an IO proc on a tap.
        let aggregateUID = UUID().uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Music Visualizer Aggregate",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString
            ]]
        ]
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID.isValid else {
            cleanUpTap()
            throw AudioError.coreAudio(status, "aggregate device creation")
        }

        // 4. Pull the tap's audio. This block runs on a real-time thread: no allocation,
        //    no Swift runtime calls beyond the ring buffer's memcpy. It captures the
        //    sink strongly so the audio path can't be torn out from under it.
        sink.resetStatistics()
        let sink = self.sink
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) {
            _, inputData, _, _, _ in
            sink.receive(inputData)
        }
        guard status == noErr, let ioProcID else {
            cleanUpAggregate()
            cleanUpTap()
            throw AudioError.coreAudio(status, "IO proc creation")
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            cleanUpAggregate()
            cleanUpTap()
            throw AudioError.coreAudio(status, "device start")
        }

        routeDescription = "tap \(tapID) → aggregate \(aggregateID) on \(outputDevice.deviceName) [\(outputUID)]"
        installDefaultDeviceListener()
        isRunning = true
    }

    func stop() {
        removeDefaultDeviceListener()
        if aggregateID.isValid, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        cleanUpAggregate()
        cleanUpTap()
        isRunning = false
        ring.clear()
    }

    deinit { stop() }

    private func cleanUpAggregate() {
        if aggregateID.isValid { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = .unknown
    }

    private func cleanUpTap() {
        if tapID.isValid { AudioHardwareDestroyProcessTap(tapID) }
        tapID = .unknown
    }

    // MARK: - Output device changes

    private func installDefaultDeviceListener() {
        var address = AudioObjectID.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onDefaultDeviceChange?()
        }
        deviceListenerBlock = block
        AudioObjectAddPropertyListenerBlock(.system, &address, ioQueue, block)
    }

    private func removeDefaultDeviceListener() {
        guard let deviceListenerBlock else { return }
        var address = AudioObjectID.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        AudioObjectRemovePropertyListenerBlock(.system, &address, ioQueue, deviceListenerBlock)
        self.deviceListenerBlock = nil
    }
}

extension AudioError {
    static func tapCreationFailed(_ status: OSStatus) -> AudioError {
        // Core Audio reports a missing TCC grant as a generic "not permitted".
        status == OSStatus(kAudioHardwareIllegalOperationError) ? .permissionDenied
                                                                 : .coreAudio(status, "process tap creation")
    }
}
