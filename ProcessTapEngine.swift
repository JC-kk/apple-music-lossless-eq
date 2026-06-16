import Foundation
import AppKit
import CoreAudio
import OSLog

/// Inserts an EQ into Apple Music's audio without a driver or admin rights, using
/// the macOS 14.4+ Core Audio process-tap API.
///
/// Pipeline: a *muted* process tap on Music.app silences Music's normal output
/// and hands us its samples; a private aggregate device bundles that tap (as
/// input) with the real output device (as output); our IOProc copies tap →
/// (optional biquad EQ) → real device. Because Choritsu renders from a separate
/// process, there is no feedback loop.
///
/// This is the Phase 0 de-risking prototype: it defaults to passthrough so we
/// can first confirm the routing is glitch-free, then flip on the DSP. Runtime
/// behaviour (no clicks, acceptable latency, survives device/rate changes) can
/// only be confirmed on a real machine with Music playing.
// Control methods are serialized on `controlQueue`; render runs on the audio
// thread. That manual discipline is what `@unchecked Sendable` asserts here.
final class ProcessTapEngine: @unchecked Sendable {
    private let log = Logger(subsystem: "com.garykong.choritsu", category: "EQEngine")
    private let musicBundleID = "com.apple.Music"
    private let aggregateUID = "com.garykong.choritsu.eq-aggregate"

    private let processor = BiquadProcessor()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private(set) var sampleRate: Double = 48000
    private var currentProfile: PEQProfile = .flat

    /// Receives post-EQ output samples for the spectrum view (audio thread).
    weak var sampleSink: SpectrumAnalyzer?
    /// Fired on the main queue when the output device's sample rate changes.
    var onSampleRateChange: ((Double) -> Void)?

    private var rateListenerDevice = AudioObjectID(kAudioObjectUnknown)
    private var rateListenerBlock: AudioObjectPropertyListenerBlock?

    /// Serializes all engine control (start/stop/apply) and the rate-change
    /// listener off the main thread, so toggling the EQ never blocks the UI on
    /// Core Audio device creation.
    let controlQueue = DispatchQueue(label: "com.garykong.choritsu.eq.control")

    private(set) var isRunning = false
    private(set) var lastError: String?

    // MARK: - Lifecycle

    /// Start tapping Music and rendering to the current default output device.
    /// Returns false (and sets `lastError`) on the first step that fails.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        lastError = nil

        guard let processObject = musicProcessObject() else {
            return fail("Apple Music isn't running (no audio process to tap).")
        }
        guard let outputDevice = defaultOutputDeviceID() else {
            return fail("No default output device.")
        }
        guard let outputUID = deviceUID(outputDevice) else {
            return fail("Couldn't read the output device UID.")
        }
        sampleRate = nominalSampleRate(outputDevice) ?? 48000

        guard let tap = createTap(processObject: processObject) else {
            return fail("AudioHardwareCreateProcessTap failed.")
        }
        tapID = tap
        guard let tapUID = stringProperty(tap, selector: kAudioTapPropertyUID) else {
            stop()
            return fail("Couldn't read the tap UID.")
        }
        guard let aggregate = createAggregate(tapUID: tapUID, outputUID: outputUID) else {
            stop()
            return fail("AudioHardwareCreateAggregateDevice failed.")
        }
        aggregateID = aggregate

        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcID(aggregateID,
                                                     ioProc,
                                                     Unmanaged.passUnretained(self).toOpaque(),
                                                     &procID)
        guard createStatus == noErr, let procID else {
            stop()
            return fail("AudioDeviceCreateIOProcID failed (\(createStatus)).")
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            stop()
            return fail("AudioDeviceStart failed (\(startStatus)).")
        }

        isRunning = true
        installRateListener(device: outputDevice)
        log.info("EQ engine started at \(self.sampleRate, privacy: .public) Hz")
        return true
    }

    func stop() {
        removeRateListener()
        if let ioProcID {
            if aggregateID != kAudioObjectUnknown {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        isRunning = false
        log.info("EQ engine stopped")
    }

    // MARK: - EQ control

    /// Turn DSP processing on or off. Coefficients are supplied separately via
    /// `apply(profile:)`; bypass = true is a true passthrough.
    func setActive(_ active: Bool) {
        processor.bypass = !active
    }

    /// Recompute coefficients for a profile at the current sample rate.
    /// Coefficients are sample-rate dependent, so this also runs automatically
    /// when the device rate changes (see `handleRateChange`).
    func apply(profile: PEQProfile) {
        currentProfile = profile
        let coefficients = profile.bands
            .filter { $0.isEnabled }
            .map { BiquadCoefficients(band: $0, sampleRate: sampleRate) }
        processor.setSections(coefficients, preampDB: profile.preampDB)
    }

    // MARK: - Render (audio thread)

    fileprivate func render(input: UnsafePointer<AudioBufferList>,
                            output: UnsafeMutablePointer<AudioBufferList>) {
        let inList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)
        let pairs = min(inList.count, outList.count)

        for i in 0..<pairs {
            let inBuffer = inList[i]
            let outBuffer = outList[i]
            guard let outData = outBuffer.mData else { continue }
            let outBytes = Int(outBuffer.mDataByteSize)

            guard let inData = inBuffer.mData else {
                memset(outData, 0, outBytes)
                continue
            }

            let copyBytes = min(Int(inBuffer.mDataByteSize), outBytes)
            memcpy(outData, inData, copyBytes)
            if outBytes > copyBytes {
                memset(outData.advanced(by: copyBytes), 0, outBytes - copyBytes)
            }

            // Canonical aggregate format is non-interleaved float32: one
            // mBuffer per channel, so buffer index == channel.
            let frameCount = copyBytes / MemoryLayout<Float>.size
            let floatData = outData.assumingMemoryBound(to: Float.self)
            if !processor.bypass {
                processor.process(floatData, frameCount: frameCount, channel: i)
            }
            if i == 0 {
                // Feed the (post-EQ) left channel to the spectrum analyzer.
                sampleSink?.append(floatData, count: frameCount)
            }
        }

        for i in pairs..<outList.count {
            if let data = outList[i].mData {
                memset(data, 0, Int(outList[i].mDataByteSize))
            }
        }
    }

    // MARK: - Core Audio setup

    private func createTap(processObject: AudioObjectID) -> AudioObjectID? {
        let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
        description.name = "Choritsu EQ Tap"
        description.isPrivate = true
        description.muteBehavior = .muted   // silence Music's own output; we re-render
        var tap = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else {
            log.error("AudioHardwareCreateProcessTap failed: \(status)")
            return nil
        }
        return tap
    }

    private func createAggregate(tapUID: String, outputUID: String) -> AudioObjectID? {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Choritsu EQ",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputUID],
            ],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapDriftCompensationKey as String: true,
                    kAudioSubTapUIDKey as String: tapUID,
                ],
            ],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard status == noErr, aggregate != kAudioObjectUnknown else {
            log.error("AudioHardwareCreateAggregateDevice failed: \(status)")
            return nil
        }
        return aggregate
    }

    // MARK: - Sample-rate following

    /// Watch the output device's nominal sample rate. Choritsu auto-switches it
    /// per track (44.1 → 192 kHz); when it moves we recompute coefficients at
    /// the new rate so the EQ curve stays correct and keeps processing.
    private func installRateListener(device: AudioObjectID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleRateChange()
        }
        let status = AudioObjectAddPropertyListenerBlock(device, &address, controlQueue, block)
        if status == noErr {
            rateListenerDevice = device
            rateListenerBlock = block
        }
    }

    private func removeRateListener() {
        guard let block = rateListenerBlock, rateListenerDevice != kAudioObjectUnknown else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(rateListenerDevice, &address, controlQueue, block)
        rateListenerBlock = nil
        rateListenerDevice = kAudioObjectUnknown
    }

    private func handleRateChange() {
        guard rateListenerDevice != kAudioObjectUnknown,
              let rate = nominalSampleRate(rateListenerDevice),
              abs(rate - sampleRate) > 0.5 else { return }
        sampleRate = rate
        apply(profile: currentProfile)
        processor.reset()
        log.info("Output rate changed to \(rate, privacy: .public) Hz; EQ recomputed")
        onSampleRateChange?(rate)
    }

    // MARK: - Property helpers

    private func musicProcessObject() -> AudioObjectID? {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: musicBundleID).first else {
            return nil
        }
        var pid = app.processIdentifier
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &object)
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    private func defaultOutputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private func deviceUID(_ device: AudioObjectID) -> String? {
        stringProperty(device, selector: kAudioDevicePropertyDeviceUID)
    }

    private func nominalSampleRate(_ device: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        guard status == noErr, rate > 0 else { return nil }
        return rate
    }

    private func stringProperty(_ object: AudioObjectID,
                                selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    @discardableResult
    private func fail(_ message: String) -> Bool {
        lastError = message
        log.error("\(message, privacy: .public)")
        return false
    }
}

// Top-level C-compatible IOProc; recovers the engine from the client-data pointer.
private func ioProc(_ device: AudioObjectID,
                    _ now: UnsafePointer<AudioTimeStamp>,
                    _ inputData: UnsafePointer<AudioBufferList>,
                    _ inputTime: UnsafePointer<AudioTimeStamp>,
                    _ outputData: UnsafeMutablePointer<AudioBufferList>,
                    _ outputTime: UnsafePointer<AudioTimeStamp>,
                    _ clientData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let clientData else { return noErr }
    let engine = Unmanaged<ProcessTapEngine>.fromOpaque(clientData).takeUnretainedValue()
    engine.render(input: inputData, output: outputData)
    return noErr
}
