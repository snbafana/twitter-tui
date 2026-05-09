import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @ObservedObject var model: ComposerModel
    var openSettings: () -> Void = {}
    @State private var showingImageImporter = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tools
            Divider()
            editor
            Divider()
            footer
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task {
            composerFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("XUI")
                    .font(.system(.title2, design: .serif, weight: .semibold))
                Text(model.account.map { "@\($0.username)" } ?? "Bring your own X auth")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Settings") {
                openSettings()
            }

            Button("Log In") {
                Task {
                    await model.login()
                }
            }
            .disabled(model.isLoggingIn)

            Button("Send") {
                Task {
                    await model.send()
                }
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!model.canSend)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var tools: some View {
        HStack(spacing: 8) {
            Button("B") {
                model.applyTextStyle(.bold)
            }
            .font(.system(.callout, weight: .bold))
            .help("Style draft as Unicode bold text")

            Button("I") {
                model.applyTextStyle(.italic)
            }
            .font(.system(.callout).italic())
            .help("Style draft as Unicode italic text")

            Button("Serif") {
                model.applyTextStyle(.serif)
            }
            .font(.system(.callout, design: .serif))
            .help("Style draft as Unicode serif text")

            Divider()
                .frame(height: 18)

            Button(model.attachedImage == nil ? "Image" : "Replace Image") {
                showingImageImporter = true
            }

            if let image = model.attachedImage {
                Text("\(image.filename) · \(image.sizeLabel)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Button("Remove") {
                    model.removeImage()
                }
            }

            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .fileImporter(isPresented: $showingImageImporter, allowedContentTypes: [.image]) { result in
            switch result {
            case let .success(url):
                model.attachImage(from: url)
            case let .failure(error):
                model.status = .failure(error.localizedDescription)
            }
        }
    }

    private var editor: some View {
        TextEditor(text: $model.text)
            .font(.system(.title3, design: .serif))
            .lineSpacing(4)
            .scrollContentBackground(.hidden)
            .padding(18)
            .focused($composerFocused)
            .overlay(alignment: .topLeading) {
                if model.text.isEmpty {
                    Text("Write the post.")
                        .font(.system(.title3, design: .serif))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 26)
                        .allowsHitTesting(false)
                }
            }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(model.status.message)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Text(model.counterLabel)
                .monospacedDigit()
                .foregroundStyle(model.remaining < 0 ? .red : .secondary)

            Button("Clear") {
                model.clear()
            }
            .disabled(model.text.isEmpty)
        }
        .font(.callout)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var statusColor: Color {
        switch model.status {
        case .idle:
            .secondary
        case .working:
            .yellow
        case .warning:
            .orange
        case .failure:
            .red
        case .success:
            .green
        }
    }
}

#Preview {
    ComposerView(model: ComposerModel())
}
