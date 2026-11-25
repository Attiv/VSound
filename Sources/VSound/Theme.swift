import AppKit
import MusicCore
import SwiftUI

enum Theme {
    static let canvas = Color(red: 0.070, green: 0.076, blue: 0.087)
    static let sidebar = Color(red: 0.052, green: 0.057, blue: 0.067)
    static let surface = Color(red: 0.105, green: 0.113, blue: 0.128)
    static let elevated = Color(red: 0.145, green: 0.153, blue: 0.169)
    static let accent = Color(red: 0.94, green: 0.69, blue: 0.35)
    static let muted = Color(red: 0.57, green: 0.59, blue: 0.63)
    static let line = Color.white.opacity(0.075)
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? Theme.sidebar : Color.primary)
            .padding(.horizontal, 17).padding(.vertical, 10)
            .background(prominent ? Theme.accent : Theme.elevated, in: RoundedRectangle(cornerRadius: 10))
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct IconButton: View {
    let symbol: String
    let label: String
    var active = false
    var size: CGFloat = 15
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .medium))
                .foregroundStyle(active ? Theme.accent : Color.secondary)
                .frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

@MainActor private enum ArtworkCache {
    static let images = NSCache<NSString, NSImage>()
    static func image(at path: String) -> NSImage? {
        if let cached = images.object(forKey: path as NSString) { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        images.countLimit = 160
        images.setObject(image, forKey: path as NSString)
        return image
    }
}

struct CoverArt: View {
    var track: Track?
    var radius: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
        GeometryReader { geometry in
            if let path = track?.artworkPath, let image = ArtworkCache.image(at: path) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
            } else {
                let seed = track?.title.utf8.reduce(0) { ($0 + Int($1)) % 6 } ?? 0
                let shades: [Color] = [Color(red: 0.35, green: 0.26, blue: 0.18), Color(red: 0.22, green: 0.31, blue: 0.31),
                                       Color(red: 0.31, green: 0.23, blue: 0.30), Color(red: 0.22, green: 0.27, blue: 0.38),
                                       Color(red: 0.37, green: 0.24, blue: 0.21), Color(red: 0.29, green: 0.31, blue: 0.22)]
                ZStack {
                    LinearGradient(colors: [shades[seed], Theme.sidebar], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Circle().fill(Color.black.opacity(0.48)).padding(geometry.size.width * 0.12)
                    ForEach(0..<5, id: \.self) { index in
                        Circle().stroke(Color.white.opacity(0.055), lineWidth: 1)
                            .padding(geometry.size.width * (0.15 + Double(index) * 0.047))
                    }
                    Circle().fill(Theme.accent.opacity(0.9)).frame(width: geometry.size.width * 0.22)
                    Circle().fill(Theme.sidebar).frame(width: max(3, geometry.size.width * 0.035))
                    LinearGradient(colors: [.clear, .white.opacity(0.07), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
        }
        .id(track?.id ?? "empty-artwork")
        .transition(.opacity)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: track?.id)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.white.opacity(0.06)))
        .accessibilityHidden(true)
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(2.5).foregroundStyle(Theme.accent)
    }
}
