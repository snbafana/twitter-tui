import SwiftUI

@main
struct XUIApp: App {
    @StateObject private var model = ComposerModel()
    @State private var showingSettings = false

    var body: some Scene {
        WindowGroup {
            ComposerView(model: model) {
                showingSettings = true
            }
                .frame(minWidth: 620, minHeight: 420)
                .sheet(isPresented: $showingSettings) {
                    SettingsView(model: model) {
                        showingSettings = false
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Post") {
                Button("Send") {
                    Task {
                        await model.send()
                    }
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!model.canSend)

                Button("Clear") {
                    model.clear()
                }
                .keyboardShortcut("l", modifiers: [.command])

                Divider()

                Button("Settings") {
                    showingSettings = true
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}
