import MusicCore
import SwiftUI

struct EqualizerView: View {
    @Environment(AppModel.self) private var model
    @State private var presetName = ""
    @State private var showSave = false
    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(text: "FIND YOUR FREQUENCY")
                    Text("让声音，合你心意。").font(.system(size: 29, weight: .semibold))
                    Text("\(model.currentPresetName) · 10 段均衡器").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Toggle("启用均衡器", isOn: $model.equalizer.enabled)
                    .toggleStyle(.switch).controlSize(.small).onChange(of: model.equalizer.enabled) { _, _ in model.updateEQ() }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 5), spacing: 9) {
                ForEach(EQPreset.builtIn) { preset in
                    Button { model.choosePreset(id: preset.id, gains: preset.gains) } label: {
                        HStack(spacing: 7) {
                            Image(systemName: preset.symbol).font(.system(size: 11)).frame(width: 15)
                            Text(preset.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 0)
                        }.foregroundStyle(model.equalizer.presetID == preset.id ? Theme.accent : Color.secondary)
                            .padding(.horizontal, 11).padding(.vertical, 12)
                            .background(model.equalizer.presetID == preset.id ? Theme.accent.opacity(0.1) : Theme.surface,
                                        in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(model.equalizer.presetID == preset.id ? Theme.accent.opacity(0.4) : Theme.line))
                    }.buttonStyle(.plain).help(preset.subtitle)
                }
                Button { showSave = true } label: {
                    Label("保存预设", systemImage: "plus").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4])))
                }.buttonStyle(.plain)
            }
            if !model.customPresets.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.customPresets) { preset in
                            Button(preset.name) { model.choosePreset(id: preset.id, gains: preset.gains) }
                                .buttonStyle(.bordered).tint(model.equalizer.presetID == preset.id ? Theme.accent : Color.gray)
                                .contextMenu { Button("删除预设", role: .destructive) { model.deletePreset(preset.id) } }
                        }
                    }
                }.frame(height: 30)
            }
            VStack(spacing: 0) {
                EQCurve(gains: model.equalizer.gains).frame(height: 60).padding(.horizontal, 34).padding(.top, 15)
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(EQSettings.labels.enumerated()), id: \.element) { index, label in
                        VStack(spacing: 9) {
                            Text(String(format: "%+.1f", model.equalizer.gains[index]))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.accent).frame(height: 14)
                            Slider(value: Binding(get: { Double(model.equalizer.gains[index]) },
                                                  set: { model.setBand(index, gain: Float($0)) }), in: -12...12)
                                .frame(width: 150).rotationEffect(.degrees(-90)).frame(width: 42, height: 156)
                                .accessibilityLabel("\(label) 赫兹均衡器").accessibilityValue("\(model.equalizer.gains[index]) 分贝")
                            Text(label).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
                        }.frame(maxWidth: .infinity)
                    }
                }.padding(.horizontal, 18).padding(.vertical, 17)
            }.background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
                .opacity(model.equalizer.enabled ? 1 : 0.5)
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("自动预留增益空间", isOn: $model.equalizer.autoHeadroom)
                        .font(.system(size: 11)).onChange(of: model.equalizer.autoHeadroom) { _, _ in model.updateEQ() }
                    Text("降低 EQ 提升带来的削波风险；开启音效后音量可能变小。")
                        .font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text("前级 \(String(format: "%.1f", model.equalizer.effectivePreamp)) dB")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
                    if !model.equalizer.autoHeadroom {
                        Slider(value: Binding(get: { Double(model.equalizer.preamp) }, set: {
                            model.equalizer.preamp = Float($0); model.updateEQ()
                        }), in: -24...0).frame(width: 150).accessibilityLabel("前级增益")
                    }
                }
                Button("恢复原声") { model.choosePreset(id: "flat", gains: Array(repeating: 0, count: 10)) }
                    .buttonStyle(.bordered)
            }
            Text("“哈曼卡顿风格”为自主设计的听感模拟预设，非品牌官方调音或 Logic 7 / Clari-Fi 算法。")
                .font(.system(size: 10)).foregroundStyle(Theme.muted.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(30).frame(width: 850).background(Theme.canvas)
        .alert("保存当前均衡器", isPresented: $showSave) {
            TextField("预设名称", text: $presetName)
            Button("取消", role: .cancel) {}
            Button("保存") { model.savePreset(presetName); presetName = "" }
                .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { Text("保存 10 个频段的当前设置。") }
    }
}

private struct EQCurve: View {
    let gains: [Float]
    var body: some View {
        Canvas { context, size in
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height / 2))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(baseline, with: .color(.white.opacity(0.08)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            guard gains.count > 1 else { return }
            let points = gains.enumerated().map { index, gain in
                CGPoint(x: size.width * Double(index) / Double(gains.count - 1), y: size.height * (0.5 - Double(gain) / 30))
            }
            var path = Path(); path.move(to: points[0])
            for index in 1..<points.count {
                let previous = points[index - 1], next = points[index]
                let mid = (previous.x + next.x) / 2
                path.addCurve(to: next, control1: CGPoint(x: mid, y: previous.y), control2: CGPoint(x: mid, y: next.y))
            }
            var fill = path
            fill.addLine(to: CGPoint(x: size.width, y: size.height)); fill.addLine(to: CGPoint(x: 0, y: size.height)); fill.closeSubpath()
            context.fill(fill, with: .linearGradient(Gradient(colors: [Theme.accent.opacity(0.18), .clear]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(path, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }.accessibilityLabel("均衡器频段增益示意曲线")
    }
}
