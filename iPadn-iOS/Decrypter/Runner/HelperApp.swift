//
//  HelperApp.swift
//  DecryptHelper
//
//  Prepared helper. Encrypted binaries live as resources in
//  EmbeddedPayload/Target inside the installed app bundle. The helper validates
//  its prepared inventory before asking FairPlay to decrypt those files.
//

import SwiftUI
import UIKit

@main
struct DecryptHelperApp: App {
    var body: some Scene {
        WindowGroup { HelperView() }
    }
}

struct HelperLogLine: Identifiable {
    let id = UUID()
    let text: String
}

final class HelperModel: ObservableObject {
    @Published var lines: [HelperLogLine] = []
    @Published var running = false
    @Published var output: URL?
    @Published var summary: String?
    @Published var logFile: URL?
    @Published var copied = false
    @Published var errorText: String?
    @Published var activity = "Checking the prepared payload…"
    @Published var verifiedCount = 0

    private let fm = FileManager.default

    var logText: String {
        var out = "Decrypter runner log\n"
        out += "device: \(UIDevice.current.model) · iOS \(UIDevice.current.systemVersion)\n"
        out += "build: \(Bundle.main.object(forInfoDictionaryKey: "TetherDecryptCommit") as? String ?? "local")\n"
        out += "exported: \(ISO8601DateFormatter().string(from: Date()))\n----\n"
        out += lines.map(\.text).joined(separator: "\n") + "\n"
        return out
    }

    func publish(_ mutate: @escaping () -> Void) {
        if Thread.isMainThread { mutate() } else { DispatchQueue.main.async(execute: mutate) }
    }

    func append(_ text: String) {
        publish {
            self.lines.append(HelperLogLine(text: text))
            if text.hasPrefix("Decrypting ") {
                let relative = String(text.dropFirst("Decrypting ".count)).components(separatedBy: " (").first ?? ""
                self.activity = "Decrypting \((relative as NSString).lastPathComponent)…"
            } else if text.hasPrefix("Validating the installed helper") {
                self.activity = "Checking the installed runner…"
            } else if text.hasPrefix("Verified ") {
                self.verifiedCount += 1
                self.activity = "Verifying and preparing your export…"
            }
        }
    }

    func copyLog() {
        UIPasteboard.general.string = logText
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.copied = false }
    }

    func saveLog() {
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let url = docs.appendingPathComponent("Helper-log-\(fmt.string(from: Date())).txt")
        do {
            try logText.write(to: url, atomically: true, encoding: .utf8)
            logFile = url
            append("Log saved as \(url.lastPathComponent).")
        } catch {
            append("Could not write log: \(error.localizedDescription)")
        }
    }

    func start() {
        guard !running else { return }
        running = true
        lines.removeAll()
        output = nil
        summary = nil
        errorText = nil
        activity = "Checking the prepared payload…"
        verifiedCount = 0
        copied = false
        logFile = nil

        append("Opening the prepared helper and its payload manifest…")

        DispatchQueue.global(qos: .userInitiated).async {
            let decryptor = Decryptor { [weak self] message in self?.append(message) }
            do {
                let report = try decryptor.runEmbedded()
                self.publish {
                    self.output = report.output
                    self.summary = "\(report.decrypted) decrypted · \(report.alreadyPlain) already plain · 0 failures"
                    self.running = false
                    self.saveLog()
                }
            } catch {
                self.publish {
                    self.errorText = error.localizedDescription
                    self.append("ERROR: \(error.localizedDescription)")
                    self.running = false
                    self.saveLog()
                }
            }
        }
    }
}

struct HelperView: View {
    @StateObject private var model = HelperModel()
    @State private var showingLog = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "TetherDecryptPreparedFor") as? String ?? "your app"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "TetherDecryptPreparedVersion") as? String ?? ""
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    TDHero(eyebrow: "DECRYPTER / RUNNER",
                           title: model.output == nil ? "Ready to decrypt." : "All done.",
                           subtitle: "Prepared for \(appName) \(appVersion).", symbol: model.output == nil ? "lock.open" : "checkmark.seal")

                    TDCard {
                        VStack(alignment: .leading, spacing: 22) {
                            if model.running {
                                TDStatus(title: "Decrypting your app", detail: model.activity, running: true)
                                if model.verifiedCount > 0 {
                                    Label("\(model.verifiedCount) binaries verified", systemImage: "checkmark.shield")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                                Text("Keep this runner open until the export is ready.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            } else if let output = model.output {
                                TDStatus(title: "Your IPA is ready", detail: model.summary ?? "All binaries verified.")
                                HStack(spacing: 10) {
                                    Image(systemName: "doc.zipper").foregroundStyle(TDTheme.accent)
                                    Text(output.lastPathComponent).font(.subheadline).textSelection(.enabled)
                                }
                                Text("Re-sign the exported IPA before installing it.")
                                    .font(.footnote).foregroundStyle(.secondary)
                                ShareLink(item: output) {
                                    Label("Share decrypted IPA", systemImage: "square.and.arrow.up")
                                        .frame(maxWidth: .infinity, minHeight: 24)
                                }
                                .tdAction(prominent: true)
                            } else if let error = model.errorText {
                                TDStatus(title: "Decryption stopped", detail: error, failed: true)
                                Button { model.start() } label: {
                                    Label("Try again", systemImage: "arrow.clockwise")
                                        .frame(maxWidth: .infinity, minHeight: 24)
                                }
                                .tdAction(prominent: true)
                            } else {
                                HStack(spacing: 14) {
                                    Image(systemName: "app.badge.checkmark")
                                        .font(.title2).foregroundStyle(TDTheme.accent)
                                        .frame(width: 52, height: 52)
                                        .background(TDTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(appName).font(.headline)
                                        Text("Installed runner").font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                                Text("We’ll check the payload, decrypt its binaries, and export the verified IPA.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button { model.start() } label: {
                                    Label("Start decryption", systemImage: "lock.open")
                                        .frame(maxWidth: .infinity, minHeight: 24)
                                }
                                .tdAction(prominent: true)
                            }
                        }
                    }

                    if model.output == nil && !model.running {
                        Label {
                            Text("Keep the Apple account that owns this IPA signed into your iPhone’s App Store.")
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "person.crop.circle")
                        }
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                    }
                    TDActivityButton(count: model.lines.count) { showingLog = true }
                    TDBuildLabel()
                }
                .padding(.horizontal, 22)
                .padding(.top, 12)
                .padding(.bottom, 20)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .background { TDCanvas() }
            .navigationTitle("Decrypter Runner")
            .toolbar(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: model.running)
            .sheet(isPresented: $showingLog) {
                TDLogSheet(lines: model.lines.map(\.text), copied: model.copied,
                           logFile: model.logFile, copy: model.copyLog, save: model.saveLog)
            }
        }
        .tint(TDTheme.accent)
        .preferredColorScheme(.dark)
    }
}
