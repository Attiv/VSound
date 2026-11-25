import AppKit
import MusicCore
import SwiftUI

private final class LyricsPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DesktopLyricsController {
    private var panel: NSPanel?
    func update(model: AppModel) {
        let settings = model.preferences.desktopLyrics
        guard settings.enabled else { panel?.orderOut(nil); return }
        if panel == nil {
            let window = LyricsPanel(contentRect: NSRect(x: 180, y: 100, width: 720, height: 145),
                                     styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
            window.level = .floating
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
            window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.minSize = NSSize(width: 360, height: 80); window.maxSize = NSSize(width: 1600, height: 400)
            window.contentView = NSHostingView(rootView: DesktopLyricsView().environment(model))
            _ = window.setFrameAutosaveName("VSoundDesktopLyrics")
            panel = window
        }
        panel?.ignoresMouseEvents = settings.locked
        panel?.isMovableByWindowBackground = !settings.locked
        panel?.orderFrontRegardless()
    }
}

private struct DesktopLyricsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var text: String {
        guard let document = model.lyrics.document else { return model.currentTrack?.title ?? "维音 · 选择一首喜欢的歌" }
        if let id = document.activeLine(at: model.player.position - model.lyricsOffset), let line = document.lines.first(where: { $0.id == id }) {
            return line.text.isEmpty ? "♪" : line.text
        }
        return document.isSynced ? (model.currentTrack?.title ?? "♪") : document.plainText.components(separatedBy: .newlines).prefix(2).joined(separator: "\n")
    }
    var body: some View {
        let settings = model.preferences.desktopLyrics
        VStack(spacing: 8) {
            if !settings.locked {
                HStack(spacing: 12) {
                    Image(systemName: "hand.draw").accessibilityHidden(true)
                    Text("拖动空白处移动 · 拖动边缘调整大小").font(.system(size: 10))
                    Spacer()
                    Button { model.preferences.desktopLyrics.locked = true; model.updatePreferences() } label: { Image(systemName: "lock.open") }
                        .help("锁定歌词，点击穿透；可从工具菜单解锁").accessibilityLabel("锁定桌面歌词")
                    Button { model.preferences.desktopLyrics.enabled = false; model.updatePreferences() } label: { Image(systemName: "xmark") }
                        .help("关闭桌面歌词").accessibilityLabel("关闭桌面歌词")
                }.buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 12))
            }
            let visible = settings.showsTranslation ? text : String(text.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
            Text(visible).font(.system(size: settings.fontSize, weight: .semibold)).multilineTextAlignment(.center)
                .foregroundStyle(Theme.accent).shadow(color: .black.opacity(0.8), radius: 2, y: 1)
                .lineLimit(4).minimumScaleFactor(0.65).frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentTransition(.opacity).animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: visible)
                .allowsHitTesting(false)
        }.padding(.horizontal, 22).padding(.vertical, 12)
            .background(Theme.canvas.opacity(settings.opacity), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
    }
}
