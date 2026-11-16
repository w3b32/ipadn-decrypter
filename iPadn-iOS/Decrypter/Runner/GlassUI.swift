import SwiftUI
import UIKit

enum TDTheme {
    static let accent = Color(red: 196 / 255, green: 245 / 255, blue: 66 / 255)
    static let background = Color(red: 10 / 255, green: 10 / 255, blue: 10 / 255)
    static let line = Color(white: 0.15)
}

struct TDCanvas: View {
    var body: some View {
        TDTheme.background.ignoresSafeArea().accessibilityHidden(true)
    }
}

struct TDCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(white: 0.055))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(TDTheme.line, lineWidth: 1)
            }
    }
}

private struct TDActionStyle: ViewModifier {
    let prominent: Bool
    func body(content: Content) -> some View {
        content.buttonStyle(TDButtonStyle(prominent: prominent))
    }
}

private struct TDButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .monospaced, weight: .semibold))
            .foregroundStyle(prominent ? TDTheme.background : TDTheme.accent)
            .padding(.horizontal, 18).padding(.vertical, 14)
            .frame(minHeight: 48)
            .background(prominent ? TDTheme.accent : TDTheme.accent.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(TDTheme.accent.opacity(prominent ? 0 : 0.25), lineWidth: 1)
            }
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

extension View {
    func tdAction(prominent: Bool = false) -> some View {
        modifier(TDActionStyle(prominent: prominent))
            .controlSize(.large)
    }
}

struct TDHero: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        VStack(spacing: 14) {
            if let artwork = UIImage(named: "BrandIcon") {
                Image(uiImage: artwork)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.bottom, 8)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(TDTheme.accent)
                    .padding(.bottom, 8)
                    .accessibilityHidden(true)
            }
                Text(eyebrow.uppercased())
                    .font(.system(.caption2, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
            Text(title)
                .font(.system(.largeTitle, weight: .semibold))
                .tracking(-0.8)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 20).padding(.bottom, 12)
    }
}

struct TDStatus: View {
    let title: String
    let detail: String
    var running = false
    var failed = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if running {
                ProgressView().tint(TDTheme.accent).padding(.top, 3)
                    .accessibilityLabel("In progress")
            } else {
                Image(systemName: failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(failed ? Color.orange : TDTheme.accent)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct TDStep: View {
    let number: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(TDTheme.accent)
                .frame(width: 28, height: 28)
                .background(TDTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct TDActivityButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "text.alignleft").foregroundStyle(TDTheme.accent)
                Text("Activity log").font(.subheadline.weight(.medium))
                Spacer()
                Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Rectangle().fill(TDTheme.line).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(TDTheme.line).frame(height: 1) }
        .accessibilityLabel("Open activity log, \(count) entries")
    }
}

struct TDLogSheet: View {
    let lines: [String]
    let copied: Bool
    let logFile: URL?
    let copy: () -> Void
    let save: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if lines.isEmpty {
                        ContentUnavailableView("No activity yet", systemImage: "text.alignleft",
                                               description: Text("Your next run will appear here."))
                    }
                    ForEach(lines.indices, id: \.self) { index in
                        Text(lines[index])
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(lines[index].hasPrefix("ERROR:") ? Color.orange : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(20)
            }
            .background(TDTheme.background)
            .navigationTitle("Activity log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(action: copy) {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(lines.isEmpty)
                    Spacer()
                    Button(action: save) { Label("Save", systemImage: "square.and.arrow.down") }
                        .disabled(lines.isEmpty)
                    Spacer()
                    if let logFile {
                        ShareLink(item: logFile) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                }
            }
        }
        .tint(TDTheme.accent)
        .preferredColorScheme(.dark)
    }
}

struct TDBuildLabel: View {
    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let commit = Bundle.main.object(forInfoDictionaryKey: "TetherDecryptCommit") as? String ?? "local"
        Text("Decrypter \(version) · \(commit)")
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }
}
