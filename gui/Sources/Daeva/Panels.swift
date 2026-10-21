import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct PanelCard<Content: View>: View {
    let title: String
    let close: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.title3.weight(.semibold))
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .keyboardShortcut(.cancelAction)
            }
            .padding(18)
            content
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }
}

private struct Row<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.05)))
    }
}

// MARK: - setup

struct SetupPanel: View {
    @Environment(Backend.self) private var backend
    let close: () -> Void

    var body: some View {
        PanelCard(title: "Setup", close: close) {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(backend.steps) { StepRow(step: $0) }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)

            if backend.state == .needsSetup {
                Button { Task { await backend.setUp() } } label: {
                    Text("Run Setup").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(backend.busyStep != nil)
                .padding([.horizontal, .bottom], 16)
            }
        }
    }
}

private struct StepRow: View {
    @Environment(Backend.self) private var backend
    let step: SetupStep

    var body: some View {
        Row {
            HStack(alignment: .top, spacing: 10) {
                icon.frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title).font(.callout.weight(.medium))
                    Text(busy ? (backend.progress ?? "Working…") : step.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if !step.ok { action }
            }
        }
    }

    private var busy: Bool { backend.busyStep == step.id }

    @ViewBuilder private var icon: some View {
        if busy {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: step.ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(step.ok ? .green : .orange)
        }
    }

    @ViewBuilder private var action: some View {
        if step.id == "gptk" {
            HStack(spacing: 6) {
                if let url = step.open { Button("Download") { backend.open(url) } }
                Button("Import…") { chooseDMG() }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        } else if step.can_run {
            Button("Fix") { Task { await backend.run(step: step.id) } }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(backend.busyStep != nil)
        } else if let url = step.open {
            Button("Open Steam") { backend.open(url) }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
    }

    private func chooseDMG() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "dmg") ?? .diskImage]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url {
            Task { await backend.run(step: "gptk", dmg: url) }
        }
    }
}

// MARK: - settings

struct SettingsPanel: View {
    @Environment(Backend.self) private var backend
    let close: () -> Void

    var body: some View {
        PanelCard(title: "Settings", close: close) {
            VStack(spacing: 6) {
                toggle("Metal HUD", "Show frame rate and GPU stats in game.", \.metal_hud)
                toggle("Msync", "Mach-based synchronization. Can improve frame pacing.", \.msync)
                toggle("CPUID fix", "Required for NC Guard under Rosetta.", \.cpuid_fix)
                if DiscordPresence.available {
                    toggle("Discord status", "Show AION 2 as your Discord activity.", \.discord)
                }
                toggle("Log DLL loads", "For troubleshooting.", \.loaddll)

                HStack(spacing: 8) {
                    Button("Open Logs Folder") { NSWorkspace.shared.open(Backend.logsDir) }
                    Button("Force Stop") { Task { await backend.stop() } }
                }
                .buttonStyle(.glass)
                .padding(.top, 8)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
    }

    private func toggle(_ title: String, _ detail: String, _ key: WritableKeyPath<LaunchSettings, Bool>) -> some View {
        let binding = Binding<Bool>(
            get: { backend.settings[keyPath: key] },
            set: { v in
                var s = backend.settings
                s[keyPath: key] = v
                Task { await backend.update(s) }
            })
        return Row {
            Toggle(isOn: binding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
        }
    }
}

// MARK: - logs

struct LogsPanel: View {
    @Environment(Backend.self) private var backend
    let close: () -> Void
    @State private var text = ""

    var body: some View {
        PanelCard(title: "Logs", close: close) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? "No logs yet." : text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.3)))
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
                .task {
                    while !Task.isCancelled {
                        text = backend.latestLog()
                        proxy.scrollTo("end", anchor: .bottom)
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
            }
        }
    }
}
