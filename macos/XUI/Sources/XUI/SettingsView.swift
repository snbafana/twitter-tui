import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: ComposerModel
    var close: (() -> Void)?

    var body: some View {
        Form {
            Section("X OAuth App") {
                TextField("Client ID", text: $model.settings.clientID)
                    .textFieldStyle(.roundedBorder)

                SecureField("Client Secret (optional)", text: $model.clientSecret)
                    .textFieldStyle(.roundedBorder)

                Text("Client secret and OAuth tokens are stored in Keychain. Client ID and endpoint settings are stored in UserDefaults.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Endpoints") {
                TextField("API base URL", text: $model.settings.baseURL)
                    .textFieldStyle(.roundedBorder)
                TextField("Callback URL", text: $model.settings.callbackURL)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Check Login Strategy") {
                    model.prepareLogin()
                }

                Spacer()

                Button("Save") {
                    model.saveSettings()
                    close?()
                }

                Button("Log In") {
                    Task {
                        await model.login()
                    }
                }
                .disabled(model.isLoggingIn)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
