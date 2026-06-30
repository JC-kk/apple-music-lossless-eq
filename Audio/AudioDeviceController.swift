import Foundation
import CoreAudio

struct OutputDeviceInfo {
    let id: AudioDeviceID?
    let name: String
    let sampleRate: Double?
    let iconName: String
}

struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let iconName: String
}

struct OutputVolumeInfo {
    let volume: Float
    let settable: Bool
}

final class AudioDeviceController {
    func defaultOutputDeviceInfo() -> OutputDeviceInfo {
        guard let deviceID = defaultOutputDeviceID() else {
            return OutputDeviceInfo(id: nil, name: "Unknown", sampleRate: nil, iconName: "speaker.wave.2.fill")
        }

        let name = stringProperty(objectID: deviceID,
                                  selector: kAudioObjectPropertyName) ?? "Unknown"
        let sampleRate = doubleProperty(objectID: deviceID,
                                        selector: kAudioDevicePropertyNominalSampleRate)

        return OutputDeviceInfo(id: deviceID,
                                name: name,
                                sampleRate: sampleRate,
                                iconName: transportIconName(deviceID: deviceID))
    }

    func outputDevices() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceIDs) == noErr else {
            return []
        }

        return deviceIDs
            .filter { hasOutputStreams(deviceID: $0) }
            .map { deviceID in
                AudioOutputDevice(id: deviceID,
                                  name: stringProperty(objectID: deviceID,
                                                       selector: kAudioObjectPropertyName) ?? "Unknown",
                                  iconName: transportIconName(deviceID: deviceID))
            }
    }

    func setDefaultOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var newID = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                          &address, 0, nil, size, &newID) == noErr
    }

    func availableSampleRates(deviceID: AudioDeviceID) -> [Double] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return []
        }

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &ranges) == noErr else {
            return []
        }

        let standardRates: [Double] = [8000, 11025, 16000, 22050, 32000,
                                       44100, 48000, 88200, 96000,
                                       176400, 192000, 352800, 384000,
                                       705600, 768000]
        var rates = Set<Double>()
        for range in ranges {
            if range.mMinimum == range.mMaximum {
                rates.insert(range.mMinimum)
            } else {
                for rate in standardRates
                where rate >= range.mMinimum - 0.5 && rate <= range.mMaximum + 0.5 {
                    rates.insert(rate)
                }
            }
        }

        return rates.sorted()
    }

    private func hasOutputStreams(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return false
        }

        return size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    func outputVolumeInfo() -> OutputVolumeInfo? {
        guard let deviceID = defaultOutputDeviceID(),
              let (selector, elements) = volumeAddress(deviceID: deviceID) else {
            return nil
        }

        var values: [Float] = []
        var settable = false
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )

            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
                continue
            }

            values.append(value)
            var isSettable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr, isSettable.boolValue {
                settable = true
            }
        }

        guard !values.isEmpty else {
            return nil
        }

        return OutputVolumeInfo(volume: values.reduce(0, +) / Float(values.count), settable: settable)
    }

    func setOutputVolume(_ volume: Float) -> Bool {
        guard let deviceID = defaultOutputDeviceID(),
              let (selector, elements) = volumeAddress(deviceID: deviceID) else {
            return false
        }

        let clamped = min(max(volume, 0), 1)
        var success = false
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )

            var isSettable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr,
                  isSettable.boolValue else {
                continue
            }

            var value = Float32(clamped)
            let size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value) == noErr {
                success = true
            }
        }

        return success
    }

    private func volumeAddress(deviceID: AudioDeviceID) -> (selector: AudioObjectPropertySelector, elements: [AudioObjectPropertyElement])? {
        // 'vmvc' — virtual main volume synthesized by the HAL for devices
        // without a settable hardware main volume.
        let virtualMainVolume = AudioObjectPropertySelector(0x766D_7663)
        let candidates: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]

        for selector in [kAudioDevicePropertyVolumeScalar, virtualMainVolume] {
            let present = candidates.filter { element in
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: element
                )
                return AudioObjectHasProperty(deviceID, &address)
            }

            if present.contains(kAudioObjectPropertyElementMain) {
                return (selector, [kAudioObjectPropertyElementMain])
            }

            if !present.isEmpty {
                return (selector, present)
            }
        }

        return nil
    }

    private func transportIconName(deviceID: AudioDeviceID) -> String {
        guard let transport = uint32Property(objectID: deviceID,
                                             selector: kAudioDevicePropertyTransportType) else {
            return "speaker.wave.2.fill"
        }

        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeBuiltIn:
            return "laptopcomputer"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt,
             kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypePCI:
            return "hifispeaker.fill"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "tv"
        case kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeVirtual:
            return "waveform"
        default:
            return "speaker.wave.2.fill"
        }
    }

    func setDefaultOutputSampleRate(_ sampleRate: Double) -> Bool {
        guard let deviceID = defaultOutputDeviceID() else {
            return false
        }

        guard let targetRate = nearestSupportedSampleRate(sampleRate, deviceID: deviceID) else {
            return false
        }

        var settable: DarwinBoolean = false
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }

        let status = AudioObjectIsPropertySettable(deviceID, &address, &settable)
        guard status == noErr, settable.boolValue else {
            return false
        }

        var rate = targetRate
        let size = UInt32(MemoryLayout<Double>.size)
        let setStatus = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &rate)
        guard setStatus == noErr else {
            return false
        }

        let lockedQuickly = waitForSampleRateLock(targetRate,
                                                  deviceID: deviceID,
                                                  timeout: 0.25,
                                                  requiredStableReadings: 2)
        if !lockedQuickly {
            verifySampleRateLockInBackground(targetRate, deviceID: deviceID)
        }
        return true
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address,
                                                0,
                                                nil,
                                                &size,
                                                &deviceID)
        guard status == noErr, deviceID != 0 else {
            return nil
        }

        return deviceID
    }

    private func stringProperty(objectID: AudioObjectID,
                                selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(objectID, &address) else {
            return nil
        }

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr else {
            return nil
        }

        var cfString: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &cfString)
        guard status == noErr, let cfString else {
            return nil
        }

        return cfString.takeRetainedValue() as String
    }

    private func uint32Property(objectID: AudioObjectID,
                                selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(objectID, &address) else {
            return nil
        }

        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else {
            return nil
        }

        return value
    }

    private func doubleProperty(objectID: AudioObjectID,
                                selector: AudioObjectPropertySelector) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(objectID, &address) else {
            return nil
        }

        var value = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else {
            return nil
        }

        return value
    }

    @discardableResult
    private func waitForSampleRateLock(_ targetRate: Double,
                                       deviceID: AudioDeviceID,
                                       timeout: TimeInterval = 3.0,
                                       requiredStableReadings: Int = 5) -> Bool {
        let tolerance = 2.0
        let interval: TimeInterval = 0.05
        let deadline = Date().addingTimeInterval(timeout)
        var stableReadings = 0

        while Date() < deadline {
            if let actualRate = actualOrNominalSampleRate(deviceID: deviceID),
               abs(actualRate - targetRate) <= tolerance {
                stableReadings += 1
                if stableReadings >= requiredStableReadings {
                    return true
                }
            } else {
                stableReadings = 0
            }
            Thread.sleep(forTimeInterval: interval)
        }

        return false
    }

    private func verifySampleRateLockInBackground(_ targetRate: Double,
                                                  deviceID: AudioDeviceID) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = self?.waitForSampleRateLock(targetRate,
                                            deviceID: deviceID,
                                            timeout: 3.0,
                                            requiredStableReadings: 5)
        }
    }

    private func actualOrNominalSampleRate(deviceID: AudioDeviceID) -> Double? {
        if let actual = doublePropertyIfPresent(objectID: deviceID,
                                                selector: kAudioDevicePropertyActualSampleRate) {
            return actual
        }
        return doubleProperty(objectID: deviceID,
                              selector: kAudioDevicePropertyNominalSampleRate)
    }

    private func doublePropertyIfPresent(objectID: AudioObjectID,
                                         selector: AudioObjectPropertySelector) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(objectID, &address) else {
            return nil
        }
        return doubleProperty(objectID: objectID, selector: selector)
    }

    private func nearestSupportedSampleRate(_ desired: Double,
                                            deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return desired
        }

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return desired
        }

        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = Array(repeating: AudioValueRange(), count: count)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &ranges) == noErr else {
            return desired
        }

        for range in ranges {
            if desired >= range.mMinimum - 0.5 && desired <= range.mMaximum + 0.5 {
                return desired
            }
        }

        var closest: Double?
        var minDiff = Double.greatestFiniteMagnitude
        for range in ranges {
            let candidates = [range.mMinimum, range.mMaximum]
            for candidate in candidates {
                let diff = abs(desired - candidate)
                if diff < minDiff {
                    minDiff = diff
                    closest = candidate
                }
            }
        }

        return closest
    }
}
