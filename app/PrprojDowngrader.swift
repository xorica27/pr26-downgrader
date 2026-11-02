import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct PrprojDowngraderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @State private var inputURL: URL?
    @State private var referenceURL: URL?
    @State private var outputURL: URL?
    @State private var useReference = true
    @State private var isRunning = false
    @State private var log = "Choose a Premiere Pro 2026 .prproj to begin.\n"
    @State private var isDropTarget = false
    @State private var alertMessage: String?
    @State private var showAlert = false
    @State private var finishedOutput: URL?

    private var defaultOutput: URL? {
        guard let input = inputURL else { return nil }
        return makeDefaultOutput(input)
    }

    private var effectiveOutput: URL? {
        outputURL ?? defaultOutput
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Premiere 2026 → 2024")
                    .font(.system(size: 24, weight: .bold))
                Text("Down-saves a .prproj from project schema v45 to the Premiere Pro 2024 schema (v42). Originals are never modified.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    fileRow("2026 project", url: inputURL, choose: chooseInput)
                    fileRow("2024 reference (optional)", url: referenceURL, choose: chooseReference)
                    Toggle("Require content match against reference (safest)", isOn: $useReference)
                        .disabled(referenceURL == nil)
                    fileRow("Output", url: effectiveOutput, choose: chooseOutput)
                }
                .padding(6)
            }

            HStack(spacing: 12) {
                Button(isRunning ? "Converting…" : "Convert") {
                    runConversion()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(inputURL == nil || isRunning)

                if isRunning {
                    ProgressView().scaleEffect(0.6)
                }

                Spacer()

                Button("Reveal output") { revealOutput() }
                    .disabled(finishedOutput == nil)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Log").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(log)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 190)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Text("The result must be opened and checked in Premiere Pro 2024 before you rely on it. Premiere has no official down-save; this tool reconstructs the older schema.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(minWidth: 640, minHeight: 600)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isDropTarget ? Color.accentColor : Color.clear, lineWidth: 3)
                .padding(4)
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget) { providers in
            handleDrop(providers)
        }
        .alert("Premiere Downgrader", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    @ViewBuilder
    private func fileRow(_ title: String, url: URL?, choose: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 180, alignment: .leading)
            Text(url?.path ?? "—")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(url == nil ? .secondary : .primary)
                .help(url?.path ?? "")
            Spacer()
            Button("Choose…", action: choose)
        }
    }

    private func makeDefaultOutput(_ input: URL) -> URL {
        let dir = input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent
        return dir.appendingPathComponent(base + "_CC2024.prproj")
    }

    private func prprojType() -> UTType {
        UTType(filenameExtension: "prproj") ?? .data
    }

    private func chooseInput() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [prprojType()]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            inputURL = url
            outputURL = makeDefaultOutput(url)
        }
    }

    private func chooseReference() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [prprojType()]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            referenceURL = url
        }
    }

    private func chooseOutput() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [prprojType()]
        panel.nameFieldStringValue = effectiveOutput?.lastPathComponent ?? "output_CC2024.prproj"
        if let dir = effectiveOutput?.deletingLastPathComponent() {
            panel.directoryURL = dir
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            outputURL = url
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let nsurl = item as? NSURL {
                url = nsurl as URL
            }
            guard let dropped = url, dropped.pathExtension.lowercased() == "prproj" else { return }
            DispatchQueue.main.async {
                inputURL = dropped
                outputURL = makeDefaultOutput(dropped)
            }
        }
        return true
    }

    private func bundleResource(_ name: String, _ ext: String) -> String? {
        Bundle.main.path(forResource: name, ofType: ext)
    }

    private func runConversion() {
        guard let input = inputURL else { return }
        guard let output = effectiveOutput else { return }
        guard let engine = bundleResource("prproj_downgrade", "py") else {
            alertMessage = "Converter engine (prproj_downgrade.py) is missing from the app bundle."
            showAlert = true
            return
        }
        guard let schema = bundleResource("schema42", "json") else {
            alertMessage = "Schema profile (schema42.json) is missing from the app bundle."
            showAlert = true
            return
        }

        var args = [engine, input.path, output.path, "--schema", schema]
        if useReference, let ref = referenceURL {
            args += ["--reference", ref.path]
        }
        let report = output.path + ".report.json"
        args += ["--report", report]

        log = "Converting…\ninput:  \(input.path)\noutput: \(output.path)\n" +
              (useReference && referenceURL != nil ? "mode:   reference transplant\n" : "mode:   schema downgrade\n") + "\n"

        isRunning = true
        finishedOutput = nil

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3"] + args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                log += text
            }
        }

        process.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                isRunning = false
                if proc.terminationStatus == 0 {
                    finishedOutput = output
                    log += "\nDone. Open the output in Premiere Pro 2024 and verify it before use.\n"
                } else {
                    log += "\nFailed with exit code \(proc.terminationStatus).\n"
                    alertMessage = "Conversion failed (exit \(proc.terminationStatus)). See the log for details."
                    showAlert = true
                }
            }
        }

        do {
            try process.run()
        } catch {
            isRunning = false
            alertMessage = "Could not start Python: \(error.localizedDescription)"
            showAlert = true
        }
    }

    private func revealOutput() {
        guard let output = finishedOutput else { return }
        NSWorkspace.shared.activateFileViewerSelecting([output])
    }
}
