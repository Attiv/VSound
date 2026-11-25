import AppKit
import Carbon
import MediaPlayer
import MusicCore
import Observation
import SwiftUI

enum HotKeyAction: String, CaseIterable, Identifiable {
    case playPause, previous, next
    var id: String { rawValue }
    var number: UInt32 { switch self { case .playPause: 1; case .previous: 2; case .next: 3 } }
    var title: String { switch self { case .playPause: "播放 / 暂停"; case .previous: "上一首"; case .next: "下一首" } }
    var defaultBinding: HotKeyBinding {
        .init(keyCode: self == .playPause ? 49 : self == .previous ? 123 : 124,
              modifiers: UInt32(controlKey | optionKey | cmdKey),
              label: self == .playPause ? "⌃⌥⌘ Space" : self == .previous ? "⌃⌥⌘ ←" : "⌃⌥⌘ →")
    }
}

@MainActor @Observable
final class HotKeyManager {
    var errors: [String: String] = [:]
    var onAction: ((HotKeyAction) -> Void)?
    @ObservationIgnored private var references: [String: EventHotKeyRef] = [:]
    @ObservationIgnored private var handler: EventHandlerRef?

    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr else { return result }
            let number = identifier.id
            let manager = Unmanaged<HotKeyManager>.fromOpaque(pointer).takeUnretainedValue()
            Task { @MainActor in
                if let action = HotKeyAction.allCases.first(where: { $0.number == number }) { manager.onAction?(action) }
            }
            return noErr
        }, 1, &type, context, &handler)
    }

    deinit {
        for reference in references.values { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }

    func registerAll(_ bindings: [String: HotKeyBinding]) {
        unregisterAll()
        for action in HotKeyAction.allCases { _ = register(action, binding: bindings[action.rawValue] ?? action.defaultBinding) }
    }

    @discardableResult
    func register(_ action: HotKeyAction, binding: HotKeyBinding) -> Bool {
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: 0x5955594E, id: action.number)
        let result = RegisterEventHotKey(binding.keyCode, binding.modifiers, identifier,
                                         GetApplicationEventTarget(), 0, &reference)
        guard result == noErr, let reference else {
            errors[action.rawValue] = "快捷键被占用或不可用（\(result)），请选择其他组合。"
            return false
        }
        if let old = references[action.rawValue] { UnregisterEventHotKey(old) }
        references[action.rawValue] = reference
        errors.removeValue(forKey: action.rawValue)
        return true
    }

    func unregisterAll() {
        for reference in references.values { UnregisterEventHotKey(reference) }
        references = [:]; errors = [:]
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let label: String
    let onRecord: (HotKeyBinding) -> Void
    func makeNSView(context: Context) -> RecorderButton { RecorderButton() }
    func updateNSView(_ button: RecorderButton, context: Context) {
        button.bindingLabel = label
        if !button.recording { button.title = label }
        button.onRecord = onRecord
    }
}

final class RecorderButton: NSButton {
    var bindingLabel = ""
    var recording = false
    var onRecord: ((HotKeyBinding) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 170, height: 28))
        bezelStyle = .rounded
        target = self; action = #selector(beginRecording)
        setAccessibilityLabel("录制全局快捷键")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func beginRecording() {
        recording = true; title = "按下组合键…"; window?.makeFirstResponder(self)
    }
    override func resignFirstResponder() -> Bool {
        recording = false; title = bindingLabel
        return super.resignFirstResponder()
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; title = bindingLabel; return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty else { title = "请同时按住 ⌘ / ⌥ / ⌃"; return }
        var modifiers: UInt32 = 0, prefix = ""
        for (flag, carbon, text) in [(NSEvent.ModifierFlags.control, controlKey, "⌃"), (.option, optionKey, "⌥"),
                                      (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")] {
            if flags.contains(flag) { modifiers |= UInt32(carbon); prefix += text }
        }
        let special: [UInt16: String] = [49: "Space", 123: "←", 124: "→", 125: "↓", 126: "↑", 36: "↩", 48: "⇥", 51: "⌫"]
        let key = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        recording = false
        onRecord?(.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: prefix + " " + key))
        title = bindingLabel
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
}

@MainActor
final class RemoteControl {
    private weak var model: AppModel?
    private var targets: [(MPRemoteCommand, Any)] = []
    init(model: AppModel) {
        self.model = model
        let center = MPRemoteCommandCenter.shared()
        bind(center.playCommand) { [weak model] in if model?.player.isPlaying == false { model?.togglePlayback() } }
        bind(center.pauseCommand) { [weak model] in if model?.player.isPlaying == true { model?.togglePlayback() } }
        bind(center.togglePlayPauseCommand) { [weak model] in model?.togglePlayback() }
        bind(center.nextTrackCommand) { [weak model] in model?.next() }
        bind(center.previousTrackCommand) { [weak model] in model?.previous() }
        let token = center.changePlaybackPositionCommand.addTarget { [weak model] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = event.positionTime
            Task { @MainActor in model?.seek(time) }
            return .success
        }
        targets.append((center.changePlaybackPositionCommand, token))
        update()
    }
    deinit { for (command, target) in targets { command.removeTarget(target) } }
    private func bind(_ command: MPRemoteCommand, action: @escaping @MainActor () -> Void) {
        let token = command.addTarget { _ in Task { @MainActor in action() }; return .success }
        targets.append((command, token))
    }
    func update() {
        guard let model else { return }
        let center = MPRemoteCommandCenter.shared()
        let available = !model.tracks.isEmpty
        center.playCommand.isEnabled = available
        center.pauseCommand.isEnabled = model.player.isPlaying
        center.togglePlayPauseCommand.isEnabled = available
        center.nextTrackCommand.isEnabled = model.currentTrack != nil
        center.previousTrackCommand.isEnabled = model.currentTrack != nil
        center.changePlaybackPositionCommand.isEnabled = model.currentTrack != nil
        guard let track = model.currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }
        var info: [String: Any] = [MPMediaItemPropertyTitle: track.title,
                                   MPMediaItemPropertyArtist: track.artist,
                                   MPMediaItemPropertyAlbumTitle: track.album,
                                   MPMediaItemPropertyPlaybackDuration: model.player.duration,
                                   MPNowPlayingInfoPropertyElapsedPlaybackTime: model.player.position,
                                   MPNowPlayingInfoPropertyPlaybackRate: model.player.isPlaying ? 1.0 : 0.0]
        if let path = track.artworkPath, let image = NSImage(contentsOfFile: path) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = model.player.isPlaying ? .playing : .paused
    }
}
