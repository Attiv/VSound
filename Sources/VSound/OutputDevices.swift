import AudioToolbox
import CoreAudio
import Foundation
import Observation

struct AudioOutputDevice: Identifiable {
    let id: String
    let systemID: AudioDeviceID
    let name: String
}

@MainActor @Observable
final class OutputDevices {
    private(set) var devices: [AudioOutputDevice] = []
    private(set) var activeUID: String?
    private(set) var preferredUID: String?
    @ObservationIgnored var onChange: ((AudioOutputDevice) -> Void)?
    @ObservationIgnored private var listener: AudioObjectPropertyListenerBlock?
    init() {
        refresh()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        self.listener = listener
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
    }
    deinit {
        if let listener {
            for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
                var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
            }
        }
    }
    func select(_ uid: String?) { preferredUID = uid; refresh(force: true) }
    private func refresh(force: Bool = false) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioDeviceID>.size else { devices = []; activeUID = nil; return }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
        let code = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
        guard code == noErr else { return }
        devices = ids.compactMap { id in
            guard Self.hasOutput(id), let uid = Self.string(id, kAudioDevicePropertyDeviceUID), let name = Self.string(id, kAudioObjectPropertyName) else { return nil }
            return AudioOutputDevice(id: uid, systemID: id, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var defaultID: AudioDeviceID = 0
        size = UInt32(MemoryLayout<AudioDeviceID>.size)
        address.mSelector = kAudioHardwarePropertyDefaultOutputDevice
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &defaultID)
        let selected = preferredUID.flatMap { uid in devices.first { $0.id == uid } } ?? devices.first { $0.systemID == defaultID }
        guard let selected else { activeUID = nil; return }
        if selected.id != activeUID || force { activeUID = selected.id; onChange?(selected) }
    }
    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
    private static func hasOutput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size >= MemoryLayout<AudioBufferList>.size else { return false }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, memory) == noErr else { return false }
        return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self)).contains { $0.mNumberChannels > 0 }
    }
}
