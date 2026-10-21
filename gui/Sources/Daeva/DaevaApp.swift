import SwiftUI

@main
struct DaevaApp: App {
    @State private var backend = Backend()
    @State private var updater = Updater()

    var body: some Scene {
        Window("Daeva", id: "launcher") {
            LauncherView()
                .environment(backend)
                .environment(updater)
                .frame(minWidth: 960, idealWidth: 1120, minHeight: 600, idealHeight: 680)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1120, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await updater.check() } }
            }
            CommandMenu("Game") {
                Button("Play AION 2") { backend.play() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(backend.state != .ready)
                Button("Stop Game") { Task { await backend.stop() } }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(backend.state != .playing)
            }
        }
    }
}
