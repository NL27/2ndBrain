import SwiftUI
import AppKit

/// First-run window: shows this Mac's requirements, Python, and AI models, then
/// installs every engine so the app keeps working with the network off.
struct SetupView: View {
    @ObservedObject var manager: SetupManager
    var onClose: () -> Void

    @State private var showLog = false
    @State private var report: MachineReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    machineSection
                    stepList
                }
                .padding(.vertical, 8)
            }
            .frame(height: 460)
            if showLog { Divider(); logPane }
            Divider()
            footer
        }
        .frame(width: 600)
        .task {
            DisplayAdvisor.applyRecommendedSettingsIfNeeded()
            await refreshReport()
            if manager.phase == .idle {
                await manager.check()
                await refreshReport()
                if !manager.isReady { await manager.installMissing() }
                await refreshReport()
            }
        }
        .onChange(of: manager.phase) {
            if manager.phase == .done { Task { await refreshReport() } }
        }
        .onChange(of: manager.includeLocalAI) {
            guard !manager.isBusy else { return }
            if manager.includeLocalAI { Task { await manager.check() } }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 18)).foregroundColor(.accentColor)
                Text("Set Up \(AppInfo.name)").font(.system(size: 16, weight: .semibold))
            }
            Text("Everything runs on this Mac. Setup checks your hardware, then downloads the engines and models once — after that, transcription and local AI work with the network off.")
                .font(.system(size: 12)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    // MARK: - Machine report

    @ViewBuilder private var machineSection: some View {
        if let report {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("This Mac")
                VStack(alignment: .leading, spacing: 4) {
                    labeled("Chip", report.chipName)
                    labeled("Cores", "\(report.physicalCores)")
                    labeled("Memory", String(format: "%.0f GB", report.memoryGB))
                    labeled("Free disk", String(format: "%.0f GB", report.freeDiskGB))
                    labeled("macOS", report.osVersion)
                    if let py = report.pythonVersion {
                        labeled("Python", "\(py)\(report.pythonPath.map { "  ·  \($0)" } ?? "")")
                    } else {
                        labeled("Python", "Not found — setup will install 3.12")
                    }
                    if report.displays.isEmpty {
                        labeled("Display", "None reported")
                    } else {
                        ForEach(report.displays) { screen in
                            labeled("Display", screen.summary)
                        }
                    }
                    Text(report.captureTuningBlurb)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 16)

                sectionTitle("Local AI models")
                Text(report.recommendationBlurb)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(report.models) { model in
                        HStack(spacing: 8) {
                            Image(systemName: model.installed ? "checkmark.circle.fill" : "arrow.down.circle")
                                .foregroundColor(model.installed ? .green : .secondary)
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(model.name).font(.system(size: 12, weight: .medium))
                                    if model.recommended {
                                        Text("Recommended")
                                            .font(.system(size: 9, weight: .semibold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(Capsule().fill(Color.accentColor))
                                    }
                                }
                                Text(model.source + (model.installed ? " · installed" : " · not installed yet"))
                                    .font(.system(size: 10)).foregroundColor(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            Divider().padding(.top, 8)
        } else {
            HStack {
                ProgressView().controlSize(.small)
                Text("Reading this Mac…").font(.system(size: 12)).foregroundColor(.secondary)
            }
            .padding(16)
            Divider()
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 4)
    }

    private func labeled(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).font(.system(size: 12)).foregroundColor(.secondary).frame(width: 72, alignment: .leading)
            Text(value).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func refreshReport() async {
        report = await Task.detached(priority: .userInitiated) { MachineReport.gather() }.value
    }

    // MARK: - Install steps

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Install")
            ForEach(manager.steps) { step in
                HStack(alignment: .top, spacing: 10) {
                    icon(for: step.state).frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(step.title).font(.system(size: 12, weight: .medium))
                            if step.id == SetupManager.Step.ollamaID && !manager.includeLocalAI {
                                Text("optional")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                        }
                        Text(message(for: step)).font(.system(size: 11))
                            .foregroundColor(color(for: step.state))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if step.id == SetupManager.Step.ollamaID {
                        Toggle("", isOn: $manager.includeLocalAI)
                            .toggleStyle(.switch).controlSize(.mini)
                            .disabled(manager.isBusy)
                            .help("Also install Ollama + Qwen 3.5 4B and Qwen 2.5 Coder 7B (~8 GB)")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 7)
            }
        }
    }

    @ViewBuilder private func icon(for state: SetupManager.StepState) -> some View {
        switch state {
        case .ready:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .missing:
            Image(systemName: "arrow.down.circle").foregroundColor(.secondary)
        case .needsYou:
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
        case .skipped:
            Image(systemName: "minus.circle").foregroundColor(.secondary)
        case .checking, .installing:
            ProgressView().controlSize(.small)
        case .unknown:
            Image(systemName: "circle.dotted").foregroundColor(.secondary)
        }
    }

    private func message(for step: SetupManager.Step) -> String {
        switch step.state {
        case .unknown:                return step.purpose
        case .checking:               return "Checking…"
        case .installing:             return "Installing…"
        case .ready:                  return step.purpose
        case .missing(let detail):    return detail
        case .needsYou(let detail):   return detail
        case .skipped(let detail):    return detail
        }
    }

    private func color(for state: SetupManager.StepState) -> Color {
        if case .needsYou = state { return .orange }
        return .secondary
    }

    private var logPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(manager.log.isEmpty ? "No output yet." : manager.log)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .id("log-end")
            }
            .frame(height: 140)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .onChange(of: manager.log) { proxy.scrollTo("log-end", anchor: .bottom) }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(showLog ? "Hide Details" : "Show Details") { showLog.toggle() }
                .buttonStyle(.link)
            if !manager.summary.isEmpty {
                Text(manager.summary).font(.system(size: 11)).foregroundColor(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if manager.isBusy {
                Button("Cancel") { manager.cancel() }
            } else if manager.isReady {
                Button("Done") { onClose() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Skip for Now") { onClose() }
                Button("Install missing") {
                    Task { await manager.installMissing() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}

/// Hosts `SetupView` in a real window — the app has no dock icon, so it has
/// to activate itself for the window to come forward.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    static let shared = SetupWindowController()
    private var window: NSWindow?

    func present() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            if !SetupManager.shared.isBusy {
                Task { await SetupManager.shared.check() }
            }
            return
        }

        let view = SetupView(manager: SetupManager.shared) { [weak self] in self?.close() }
        let window = NSWindow(contentRect: .zero,
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "\(AppInfo.name) Setup"
        window.contentView = NSHostingView(rootView: view)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if SetupManager.shared.isReady {
            Settings.shared.setupCompletedVersion = AppInfo.version
            Task { try? await HeedSupervisor.shared.ensureRunning { _ in } }
        }
    }
}
