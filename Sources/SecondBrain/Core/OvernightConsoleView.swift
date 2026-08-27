import SwiftUI
import AppKit

/// Live overnight worker console: Start/Stop plus a terminal-style tail of
/// the Shared drop logs so you can see the agent actually pick up a job.
@MainActor
final class OvernightMonitor: ObservableObject {
    @Published var production: OvernightControl.Lane
    @Published var development: OvernightControl.Lane
    @Published var log: String = ""
    @Published var focusDev = false
    @Published var lastCtl = ""

    private var timer: Timer?

    init() {
        production = OvernightControl.snapshot(
            drop: OvernightControl.productionDrop, name: "Production",
            agent: "secondbrain-agent", daemon: "com.dao.secondbrain.overnight")
        development = OvernightControl.snapshot(
            drop: OvernightControl.developmentDrop, name: "Development",
            agent: "secondbrain-dev", daemon: "com.dao.secondbrain.overnight-dev")
        refresh()
    }

    var lane: OvernightControl.Lane { focusDev ? development : production }

    func startPolling() {
        timer?.invalidate()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        production = OvernightControl.snapshot(
            drop: OvernightControl.productionDrop, name: "Production",
            agent: "secondbrain-agent", daemon: "com.dao.secondbrain.overnight")
        development = OvernightControl.snapshot(
            drop: OvernightControl.developmentDrop, name: "Development",
            agent: "secondbrain-dev", daemon: "com.dao.secondbrain.overnight-dev")
        log = OvernightControl.logText(for: lane)
    }

    func start() {
        lastCtl = OvernightControl.runCtl("start").trimmingCharacters(in: .whitespacesAndNewlines)
        refresh()
    }

    func stop() {
        lastCtl = OvernightControl.runCtl("stop").trimmingCharacters(in: .whitespacesAndNewlines)
        refresh()
    }
}

struct OvernightConsoleView: View {
    @StateObject private var monitor = OvernightMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            statusRow
            Divider()
            logPane
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear { monitor.startPolling() }
        .onDisappear { monitor.stopPolling() }
        .onChange(of: monitor.focusDev) { monitor.refresh() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Overnight worker")
                .font(.system(size: 16, weight: .semibold))
            Picker("", selection: $monitor.focusDev) {
                Text("Production").tag(false)
                Text("Development").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            Spacer()
            Button("Stop") { monitor.stop() }
                .disabled(monitor.production.stopped && monitor.development.stopped)
            Button("Start") { monitor.start() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 10, height: 10)
                Text(monitor.lane.headline)
                    .font(.system(size: 13, weight: .medium))
            }
            if monitor.lane.working {
                ProgressView(value: monitor.lane.progressValue)
                    .progressViewStyle(.linear)
                Text(monitor.lane.progressLabel.isEmpty ? "Waiting on local Qwen…" : monitor.lane.progressLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            if !monitor.lastCtl.isEmpty {
                Text(monitor.lastCtl)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
            Text("Start runs overnight as you (no admin). While Qwen thinks, the bar moves and logs get a heartbeat every 5s.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var dotColor: Color {
        let lane = monitor.lane
        if lane.stopped { return .secondary }
        if lane.working || lane.runnerAlive || lane.pidAlive { return .green }
        if !lane.daemonLoaded { return .yellow }
        return .yellow
    }

    private var logPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(monitor.log.isEmpty ? "No logs yet. Press Start." : monitor.log)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .id("log-end")
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: monitor.log) {
                proxy.scrollTo("log-end", anchor: .bottom)
            }
        }
    }
}

@MainActor
final class OvernightConsoleController: NSObject, NSWindowDelegate {
    static let shared = OvernightConsoleController()
    private var window: NSWindow?

    func present() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Overnight worker"
        window.contentView = NSHostingView(rootView: OvernightConsoleView())
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 760, height: 520))
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
