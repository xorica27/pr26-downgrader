import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct Pr26DowngraderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = ConverterModel.shared

    var body: some Scene {
        Window("Pr26 Downgrader", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Pr26 Project…") { model.chooseInput() }
                    .keyboardShortcut("o")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Finder "Open With" and drops on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first(where: ConverterModel.isProject) {
            ConverterModel.shared.setInput(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - Model

@MainActor
final class ConverterModel: ObservableObject {
    static let shared = ConverterModel()

    struct Summary: Equatable {
        let title: String
        let detail: String
        let warnings: [String]
    }

    enum Phase: Equatable {
        case idle
        case running
        case succeeded(Summary)
        case failed(String)
    }

    @Published var inputURL: URL?
    @Published var referenceURL: URL?
    @Published var outputURL: URL?
    @Published var phase: Phase = .idle
    @Published var log = ""
    @Published var showDetails = false
    @Published var notice: String?

    private(set) var reportURL: URL?
    private(set) var finishedOutput: URL?

    let python: URL?
    let engine: URL?
    let schema: URL?
    let runtimeProblem: String?

    private init() {
        let res = Bundle.main.resourceURL
        let python = res?.appendingPathComponent("python/bin/python3")
        let engine = res?.appendingPathComponent("prproj_downgrade.py")
        let schema = res?.appendingPathComponent("schema42.json")
        let fm = FileManager.default
        if let python, fm.isExecutableFile(atPath: python.path),
           let engine, fm.fileExists(atPath: engine.path),
           let schema, fm.fileExists(atPath: schema.path) {
            self.python = python
            self.engine = engine
            self.schema = schema
            runtimeProblem = nil
        } else {
            self.python = nil
            self.engine = nil
            self.schema = nil
            runtimeProblem = "This copy of the app is incomplete: its built-in converter is missing. Download it again."
        }
    }

    static func isProject(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "prproj"
    }

    var isRunning: Bool { phase == .running }

    var canConvert: Bool {
        inputURL != nil && outputURL != nil && runtimeProblem == nil && !isRunning
    }

    var mode: String {
        referenceURL == nil ? "Schema downgrade" : "Reference transplant"
    }

    // MARK: Files

    func setInput(_ url: URL) {
        inputURL = url
        outputURL = Self.defaultOutput(for: url)
        resetResult()
    }

    func clearInput() {
        inputURL = nil
        outputURL = nil
        resetResult()
    }

    func setReference(_ url: URL?) {
        if let url, url == inputURL {
            notice = "The Pr24 version must be a different file from the Pr26 project."
            return
        }
        referenceURL = url
        resetResult()
    }

    private func resetResult() {
        phase = .idle
        finishedOutput = nil
        reportURL = nil
        notice = nil
    }

    static func defaultOutput(for input: URL) -> URL {
        let base = input.deletingPathExtension().lastPathComponent
        return input.deletingLastPathComponent().appendingPathComponent(base + "_Pr24.prproj")
    }

    private static var projectType: UTType {
        UTType(filenameExtension: "prproj") ?? .data
    }

    func chooseInput() {
        let panel = NSOpenPanel()
        panel.message = "Choose a Premiere Pro 26 project"
        panel.allowedContentTypes = [Self.projectType]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            self.setInput(url)
        }
    }

    func chooseReference() {
        let panel = NSOpenPanel()
        panel.message = "Choose the Premiere Pro 24 version of the same edit"
        panel.allowedContentTypes = [Self.projectType]
        if let dir = inputURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            self.setReference(url)
        }
    }

    func chooseOutput() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.projectType]
        panel.nameFieldStringValue = outputURL?.lastPathComponent ?? "Project_Pr24.prproj"
        panel.directoryURL = outputURL?.deletingLastPathComponent()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if url == self.inputURL || url == self.referenceURL {
                self.notice = "Choose a new file name. Originals are never overwritten."
                return
            }
            self.outputURL = url
            self.resetResult()
        }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                if Self.isProject(url) {
                    self.setInput(url)
                } else {
                    self.notice = "\(url.lastPathComponent) isn't a Premiere project (.prproj)."
                }
            }
        }
        return true
    }

    func revealOutput() {
        guard let finishedOutput else { return }
        NSWorkspace.shared.activateFileViewerSelecting([finishedOutput])
    }

    func openReport() {
        guard let reportURL else { return }
        NSWorkspace.shared.open(reportURL)
    }

    // MARK: Conversion

    func convert() {
        guard canConvert, let python, let engine, let schema,
              let input = inputURL, let output = outputURL else { return }

        let report = FileManager.default.temporaryDirectory
            .appendingPathComponent("prproj-report-\(UUID().uuidString).json")
        var args = ["-I", "-B", engine.path, input.path, output.path,
                    "--schema", schema.path, "--report", report.path]
        if let ref = referenceURL {
            args += ["--reference", ref.path]
        }

        resetResult()
        phase = .running
        log = "input:  \(input.path)\noutput: \(output.path)\nmode:   \(mode.lowercased())\n\n"

        let process = Process()
        process.executableURL = python
        process.arguments = args
        process.environment = ["LANG": "en_US.UTF-8", "PATH": "/usr/bin:/bin"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self.log += text }
        }

        process.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            let status = proc.terminationStatus
            Task { @MainActor in
                if !rest.isEmpty { self.log += String(decoding: rest, as: UTF8.self) }
                self.finish(status: status, output: output, report: report)
            }
        }

        do {
            try process.run()
        } catch {
            phase = .failed("Couldn't start the converter: \(error.localizedDescription)")
            showDetails = true
        }
    }

    private func finish(status: Int32, output: URL, report: URL) {
        if status == 0 {
            finishedOutput = output
            reportURL = FileManager.default.fileExists(atPath: report.path) ? report : nil
            let summary = Self.summarize(report)
            if !summary.warnings.isEmpty {
                log += "\nwarnings:\n" + summary.warnings.map { "  - \($0)" }.joined(separator: "\n") + "\n"
            }
            phase = .succeeded(summary)
        } else {
            phase = .failed(Self.failureMessage(status: status, log: log))
            showDetails = true
        }
    }

    private static func failureMessage(status: Int32, log: String) -> String {
        switch status {
        case 3:
            return "The Pr24 project doesn't match this edit, so it wasn't used. Remove it to run a schema downgrade instead."
        case 4:
            return "The converted file didn't pass verification and shouldn't be used."
        default:
            let line = log.split(separator: "\n").last { $0.hasPrefix("error:") }
            return line.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces).capitalizedFirst }
                ?? "Conversion failed (exit \(status)). See Details."
        }
    }

    private static func summarize(_ report: URL) -> Summary {
        guard let data = try? Data(contentsOf: report),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Summary(title: "Converted", detail: "Open it in Premiere Pro 24.1 or later and check it before use.", warnings: [])
        }
        if json["mode"] as? String == "reference-transplant" {
            return Summary(title: "Matched your Premiere Pro 24 project",
                           detail: "The edit is identical, so the 24.1 file was returned unchanged.",
                           warnings: [])
        }
        let changes = json["changes"] as? [String: Any] ?? [:]
        func total(_ key: String) -> Int {
            (changes[key] as? [String: Int])?.values.reduce(0, +) ?? 0
        }
        let classes = total("class_version_changes") + total("inner_version_changes")
        let added = total("added_elements")
        let removed = total("removed_elements")
        let warnings = changes["warnings"] as? [String] ?? []
        let detail = [
            "\(classes) versions reverted",
            "\(added) fields restored",
            "\(removed) Pr26-only fields removed",
        ].joined(separator: " · ")
        return Summary(title: "Saved as a Premiere Pro 24.1 project", detail: detail, warnings: warnings)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Views

struct ContentView: View {
    @EnvironmentObject private var model: ConverterModel
    @State private var isDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeaderView()

            if let problem = model.runtimeProblem {
                Banner(symbol: "exclamationmark.triangle.fill", tint: .orange, text: problem)
            }

            DropZone(isTargeted: isDropTarget)

            OptionsCard()

            if let notice = model.notice {
                Banner(symbol: "info.circle.fill", tint: .secondary, text: notice)
            }

            ActionBar()

            DetailsSection()

            Text("Premiere has no official down-save. Always open the result in Premiere Pro 24.1 or later and check it before relying on it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 600)
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { model.handleDrop($0) }
        .animation(.easeOut(duration: 0.15), value: model.phase)
        .animation(.easeOut(duration: 0.15), value: model.inputURL)
        .animation(.easeOut(duration: 0.15), value: model.notice)
    }
}

struct HeaderView: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pr26 Downgrader")
                    .font(.title2.weight(.semibold))
                Text("Converts Premiere Pro 26.0 projects to 24.1")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Text("Pr26")
                Image(systemName: "arrow.right")
                    .font(.caption2.weight(.bold))
                Text("Pr24")
            }
            .font(.callout.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .foregroundStyle(Color.accentColor)
            .help("Premiere Pro 26.0 (project version 45) → 24.1 (project version 42)")
        }
    }
}

struct DropZone: View {
    @EnvironmentObject private var model: ConverterModel
    let isTargeted: Bool

    var body: some View {
        Group {
            if let url = model.inputURL {
                loaded(url)
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 132)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isTargeted ? Color.accentColor : Color.primary.opacity(0.18),
                              style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.5,
                                                 dash: model.inputURL == nil ? [7, 5] : []))
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { if model.inputURL == nil { model.chooseInput() } }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text("Drop a Premiere Pro 26 project here")
                .font(.headline)
            Text("or click to choose a .prproj file")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func loaded(_ url: URL) -> some View {
        HStack(spacing: 14) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(url.deletingLastPathComponent().path.abbreviatingHome)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(url.path)
            }
            Spacer()
            Button("Change…") { model.chooseInput() }
            Button {
                model.clearInput()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(.horizontal, 20)
    }
}

struct OptionsCard: View {
    @EnvironmentObject private var model: ConverterModel

    var body: some View {
        VStack(spacing: 0) {
            OptionRow(
                symbol: "checkmark.shield",
                title: "Premiere Pro 24 version of this edit",
                subtitle: model.referenceURL.map { $0.lastPathComponent }
                    ?? "Optional. If you still have it, its content is checked and it's returned as-is — the safest result.",
                isSet: model.referenceURL != nil
            ) {
                if model.referenceURL != nil {
                    Button("Remove") { model.setReference(nil) }
                }
                Button(model.referenceURL == nil ? "Choose…" : "Change…") { model.chooseReference() }
            }

            Divider().padding(.leading, 46)

            OptionRow(
                symbol: "square.and.arrow.down",
                title: "Save as",
                subtitle: model.outputURL.map { $0.path.abbreviatingHome } ?? "Chosen after you add a project",
                isSet: model.outputURL != nil
            ) {
                Button("Change…") { model.chooseOutput() }
                    .disabled(model.inputURL == nil)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct OptionRow<Buttons: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    let isSet: Bool
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(isSet ? Color.accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            buttons()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }
}

struct ActionBar: View {
    @EnvironmentObject private var model: ConverterModel

    private var succeeded: Bool {
        if case .succeeded = model.phase { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ResultCard()
            HStack(spacing: 12) {
                status
                Spacer(minLength: 12)
                if succeeded {
                    Button("Convert Again") { model.convert() }
                        .controlSize(.large)
                        .disabled(!model.canConvert)
                    Button {
                        model.revealOutput()
                    } label: {
                        Text("Show in Finder").frame(minWidth: 96)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button {
                        model.convert()
                    } label: {
                        Text(model.isRunning ? "Converting…" : "Convert").frame(minWidth: 96)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canConvert)
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .idle:
            Label(model.inputURL == nil ? "Add a project to begin" : "Ready · \(model.mode.lowercased())",
                  systemImage: model.inputURL == nil ? "circle.dashed" : "circle")
                .foregroundStyle(.secondary)
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Converting…").foregroundStyle(.secondary)
            }
        case .succeeded, .failed:
            EmptyView()
        }
    }
}

struct ResultCard: View {
    @EnvironmentObject private var model: ConverterModel

    var body: some View {
        switch model.phase {
        case .succeeded(let summary):
            card(symbol: "checkmark.circle.fill", tint: .green) {
                Text(summary.title).fontWeight(.semibold)
                Text(summary.detail).font(.callout).foregroundStyle(.secondary)
                if !summary.warnings.isEmpty {
                    Text("\(summary.warnings.count) warning\(summary.warnings.count == 1 ? "" : "s") — see Details")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        case .failed(let message):
            card(symbol: "xmark.octagon.fill", tint: .red) {
                Text("Conversion failed").fontWeight(.semibold)
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
        case .idle, .running:
            EmptyView()
        }
    }

    private func card<Content: View>(symbol: String, tint: Color,
                                     @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) { content() }
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.25)))
    }
}

struct DetailsSection: View {
    @EnvironmentObject private var model: ConverterModel

    var body: some View {
        DisclosureGroup(isExpanded: $model.showDetails) {
            VStack(alignment: .trailing, spacing: 6) {
                ScrollView {
                    Text(model.log.isEmpty ? "Nothing yet." : model.log)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(model.log.isEmpty ? Color.secondary : Color.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 150)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))

                if case .succeeded = model.phase, model.reportURL != nil {
                    Button("Open JSON report") { model.openReport() }
                        .controlSize(.small)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Details")
                .foregroundStyle(.secondary)
                .onTapGesture { model.showDetails.toggle() }
        }
    }
}

struct Banner: View {
    let symbol: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.1)))
    }
}

private extension String {
    var abbreviatingHome: String { (self as NSString).abbreviatingWithTildeInPath }
}
