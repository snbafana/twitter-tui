import SwiftUI

@main
struct XUIApp: App {
    @StateObject private var model = ComposerModel()

    var body: some Scene {
        WindowGroup {
            ComposerView(model: model)
                .frame(minWidth: 620, minHeight: 420)
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
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}
