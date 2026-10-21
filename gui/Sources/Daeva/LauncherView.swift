import SwiftUI
import UniformTypeIdentifiers

enum Panel: Equatable { case none, setup, settings, logs }

struct LauncherView: View {
    @Environment(Backend.self) private var backend
    @Environment(Updater.self) private var updater
    @State private var panel: Panel = .none
    @State private var dropTargeted = false

    var body: some View {
        ZStack {
            Backdrop(hero: backend.hero)

            VStack(spacing: 0) {
                TopBar(panel: $panel)
                Spacer()
                if let logo = backend.logo {
                    Image(nsImage: logo)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 340, maxHeight: 190)
                }
                Spacer()
                HStack(alignment: .bottom, spacing: 24) {
                    NewsCard()
                    Spacer()
                    LaunchControls(openSetup: { show(.setup) })
                }
                .padding(24)
            }

            if panel != .none {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture { show(.none) }
                    .transition(.opacity)
                HStack {
                    Spacer()
                    Group {
                        switch panel {
                        case .setup: SetupPanel(close: { show(.none) })
                        case .settings: SettingsPanel(close: { show(.none) })
                        case .logs: LogsPanel(close: { show(.none) })
                        case .none: EmptyView()
                        }
                    }
                    .frame(width: panel == .logs ? 600 : 420)
                    .padding(16)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if dropTargeted { DropHint() }
        }
        .ignoresSafeArea()
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { importDMG($0) }
        .task {
            await backend.refresh()
            if backend.state == .needsSetup { show(.setup) }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(backend.state == .launching ? 2 : 5))
                if backend.busyStep == nil { await backend.refresh() }
            }
        }
        .task {
            while !Task.isCancelled {
                await backend.loadNews()
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
        .task {
            while !Task.isCancelled {
                await updater.check()
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    private func show(_ p: Panel) { withAnimation(.snappy) { panel = p } }

    private func importDMG(_ providers: [NSItemProvider]) -> Bool {
        guard let item = providers.first else { return false }
        _ = item.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.pathExtension.lowercased() == "dmg" else { return }
            Task { @MainActor in
                show(.setup)
                await backend.run(step: "gptk", dmg: url)
            }
        }
        return true
    }
}

private struct Backdrop: View {
    let hero: NSImage?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color(white: 0.04)
                if let hero {
                    Image(nsImage: hero)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                        .clipped()
                }
                LinearGradient(stops: [.init(color: .clear, location: 0.45),
                                       .init(color: .black.opacity(0.75), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

private struct TopBar: View {
    @Environment(Backend.self) private var backend
    @Binding var panel: Panel

    var body: some View {
        HStack {
            Spacer()
            UpdatePill()
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    IconButton(symbol: "checklist", help: "Setup", badge: !backend.pending.isEmpty) { toggle(.setup) }
                    IconButton(symbol: "gearshape", help: "Settings") { toggle(.settings) }
                    IconButton(symbol: "doc.text", help: "Logs") { toggle(.logs) }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func toggle(_ p: Panel) { withAnimation(.snappy) { panel = panel == p ? .none : p } }
}

private struct UpdatePill: View {
    @Environment(Updater.self) private var updater
    @Environment(Backend.self) private var backend

    var body: some View {
        if let rel = updater.available {
            Button { Task { await updater.install() } } label: {
                HStack(spacing: 6) {
                    switch updater.phase {
                    case .downloading(let f):
                        ProgressView(value: f).progressViewStyle(.circular).controlSize(.mini)
                        Text("Downloading \(rel.version)")
                    case .installing:
                        ProgressView().controlSize(.mini)
                        Text("Installing…")
                    case .failed(let why):
                        Image(systemName: "exclamationmark.triangle")
                        Text(why).lineLimit(1)
                    case .idle:
                        Image(systemName: "arrow.down.circle")
                        Text("Update to \(rel.version)")
                    }
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .frame(height: 32)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .disabled(backend.state == .playing || updater.phase == .installing || isDownloading)
            .help(backend.state == .playing ? "Quit the game to update" : "Install \(rel.version) and relaunch")
            .padding(.trailing, 8)
        }
    }

    private var isDownloading: Bool {
        if case .downloading = updater.phase { return true }
        return false
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    var badge = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 32, height: 32)
                .overlay(alignment: .topTrailing) {
                    if badge { Circle().fill(.orange).frame(width: 7, height: 7).offset(x: -5, y: 5) }
                }
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(help)
    }
}

private struct NewsCard: View {
    @Environment(Backend.self) private var backend

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("News")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)
            if backend.news.isEmpty {
                Text("No news right now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                ForEach(backend.news.prefix(5)) { item in NewsRow(item: item) }
            }
        }
        .padding(.bottom, 8)
        .frame(width: 400, alignment: .leading)
        .background(.black.opacity(0.25), in: .rect(cornerRadius: 20))
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

private struct NewsRow: View {
    @Environment(Backend.self) private var backend
    let item: NewsItem
    @State private var hover = false

    var body: some View {
        Button { backend.open(item.url) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.parts.tag ?? "")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
                Text(item.parts.title)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(item.published, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(hover ? Color.white.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct LaunchControls: View {
    @Environment(Backend.self) private var backend
    let openSetup: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 7, height: 7)
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 360, alignment: .trailing)

            Button(action: tap) {
                HStack(spacing: 8) {
                    if backend.state == .launching || backend.busyStep != nil {
                        ProgressView().controlSize(.small)
                    }
                    Text(label).font(.title3.weight(.semibold))
                }
                .frame(width: 180, height: 32)
            }
            .buttonStyle(.glassProminent)
            .tint(backend.state == .playing ? .red : Color(red: 0.85, green: 0.68, blue: 0.38))
            .controlSize(.extraLarge)
            .disabled(backend.state == .checking || backend.state == .launching || backend.busyStep != nil)
        }
    }

    private func tap() {
        switch backend.state {
        case .ready: backend.play()
        case .needsSetup: openSetup(); Task { await backend.setUp() }
        case .playing: Task { await backend.stop() }
        default: break
        }
    }

    private var label: String {
        switch backend.state {
        case .ready, .checking: "Play"
        case .needsSetup: "Set Up"
        case .launching: "Starting"
        case .playing: "Stop"
        }
    }

    private var status: String {
        if let e = backend.lastError { return e }
        if let p = backend.progress { return p }
        switch backend.state {
        case .checking: return "Checking…"
        case .needsSetup: return "\(backend.pending.count) setup step\(backend.pending.count == 1 ? "" : "s") remaining"
        case .ready: return "Ready"
        case .launching: return "Starting through Steam"
        case .playing: return "Running"
        }
    }

    private var dot: Color {
        if backend.lastError != nil { return .red }
        switch backend.state {
        case .ready, .playing: return .green
        case .needsSetup: return .orange
        default: return .secondary
        }
    }
}

private struct DropHint: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.circle").font(.system(size: 36, weight: .light))
                Text("Import Game Porting Toolkit").font(.headline)
            }
            .padding(32)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
