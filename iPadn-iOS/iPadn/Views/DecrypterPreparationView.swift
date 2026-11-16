import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@available(iOS 17.4, *)
@MainActor
final class DecrypterPreparationModel: ObservableObject {
    @Published private(set) var isPreparing = false
    @Published private(set) var resultURL: URL?
    @Published private(set) var resultAppName: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var activityLog = ""

    static var preparationBusy = false

    let source: URL

    init(source: URL) {
        self.source = source
        activityLog = "Target: \(source.lastPathComponent)\n"
    }

    var sourceFilename: String { source.lastPathComponent }
    var canPrepare: Bool { !isPreparing }
    var canDismiss: Bool { !isPreparing }
    var displayedLog: String {
        Self.trimmedLog(activityLog)
    }

    func produceLogLine(_ line: String) {
        // Appends are serialized by the @MainActor isolation of this model.
        activityLog += line + "\n"
        if activityLog.count > 200_000 {
            activityLog = Self.trimmedLog(activityLog)
        }
    }

    private static func trimmedLog(_ text: String) -> String {
        let limit = 160_000
        guard text.count > limit else { return text }
        let suffix = String(text.suffix(limit))
        return "…\n" + suffix
    }

    func prepare() {
        guard canPrepare else { return }
        guard !Self.preparationBusy else {
            errorMessage = AppText.text("Another runner is being prepared. Try again when it finishes.")
            return
        }
        Self.preparationBusy = true
        isPreparing = true
        errorMessage = nil
        let source = self.source
        produceLogLine("Starting preparation for \(source.lastPathComponent)…")

        let owner = self
        Task.detached(priority: .userInitiated) {
            let decryptor = Decryptor { line in
                DispatchQueue.main.async { owner.produceLogLine(line) }
            }
            let outcome: Result<(URL, String), Error>
            do {
                try DecrypterEligibility.validatePackage(source)
                let prepared = try decryptor.prepareHelper(ipaAt: source)
                outcome = .success((prepared.url, prepared.appName))
            } catch {
                outcome = .failure(error)
            }
            // The C callback and completion use the same FIFO queue, so the
            // final status cannot overtake pending progress messages.
            DispatchQueue.main.async { owner.finish(outcome: outcome) }
        }
    }

    private func finish(outcome: Result<(URL, String), Error>) {
        DecrypterPreparationModel.preparationBusy = false
        isPreparing = false
        switch outcome {
        case .success(let pair):
            resultURL = pair.0
            resultAppName = pair.1
            errorMessage = nil
            produceLogLine("Prepared runner: \(pair.0.lastPathComponent)")
        case .failure(let error):
            // Keep any earlier successful output visible; never claim it is
            // the result of this failed attempt.
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorMessage = message
            produceLogLine("Preparation failed: \(message)")
        }
    }
}

@available(iOS 17.4, *)
struct DecrypterPreparationView: View {
    @StateObject private var model: DecrypterPreparationModel
    @Environment(\.dismiss) private var dismiss
    @State private var shareLogURL: URL?
    @State private var copiedLog = false

    init(source: URL) {
        _model = StateObject(wrappedValue: DecrypterPreparationModel(source: source))
    }

    var body: some View {
        Form {
            workflowSection
            actionSection
            if !model.isPreparing && model.errorMessage == nil, let result = model.resultURL {
                resultSection(result: result)
            }
            if let message = model.errorMessage {
                errorSection(message: message)
            }
            logSection
        }
        .toolPage()
        .navigationTitle(Text("Prepare Decryption Runner"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.isPreparing)
        .interactiveDismissDisabled(!model.canDismiss)
        .onChange(of: model.isPreparing) { running in if !running { writeLogFile() } }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(role: .cancel) {
                    dismiss()
                } label: {
                    Text("Close")
                }
                .disabled(!model.canDismiss)
            }
        }
    }

    private var workflowSection: some View {
        Section {
            LabeledContent("Source IPA") {
                Text(verbatim: model.sourceFilename)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("A signed, installed runner is required.")
                    .font(.footnote.weight(.semibold))
                Text("Prepare a runner, sign and install it on this iPhone, then open the runner to decrypt. Keep the App Store account that owns the IPA signed in.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("The original IPA is preserved. Share the runner to your signer, install it, then open it to decrypt.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("How it works")
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                model.prepare()
            } label: {
                HStack(spacing: 8) {
                    if model.isPreparing {
                        ProgressView()
                    }
                    Text(LocalizedStringKey(model.isPreparing ? "Preparing runner…" : "Prepare runner"))
                }
            }
            .disabled(!model.canPrepare)
        }
    }

    private func resultSection(result: URL) -> some View {
        Section {
            LabeledContent("Runner file") {
                Text(verbatim: result.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let name = model.resultAppName, !name.isEmpty {
                LabeledContent("App") {
                    Text(verbatim: name)
                }
            }
            ShareLink(item: result) {
                Label {
                    Text("Share runner IPA")
                } icon: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            Text("Share the runner IPA to a signing tool, then install the signed copy. Opening this file elsewhere does not decrypt anything by itself.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Prepared runner")
        }
    }

    private func errorSection(message: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text("Preparation failed")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.red)
                Text(verbatim: message)
                    .font(.footnote)
                    .textSelection(.enabled)
            }
        }
    }

    private var logSection: some View {
        Section {
            ScrollView {
                Text(verbatim: model.displayedLog)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 120, maxHeight: 260)

            HStack(spacing: 12) {
                Button {
                    copyLog()
                } label: {
                    Label {
                        Text(LocalizedStringKey(copiedLog ? "Copied" : "Copy log"))
                    } icon: {
                        Image(systemName: "doc.on.doc")
                    }
                }
                .buttonStyle(.borderless)
                if let shareLogURL {
                    ShareLink(item: shareLogURL) {
                        Label {
                            Text("Share log")
                        } icon: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
            }
        } header: {
            Text("Activity log")
        }
    }

    private func copyLog() {
#if canImport(UIKit)
        UIPasteboard.general.string = model.displayedLog
#endif
        writeLogFile()
        copiedLog = true
    }

    private func writeLogFile() {
        guard let documents = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        let dir = documents.appendingPathComponent("Decrypter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = dir.appendingPathComponent("Prepare-Log-\(stamp).txt")
        do {
            try model.displayedLog.write(to: file, atomically: true, encoding: .utf8)
            shareLogURL = file
        } catch {
            shareLogURL = nil
        }
    }
}
