import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @ObservedObject var model: ComposerModel
    var openSettings: () -> Void = {}
    @State private var showingImageImporter = false
    @State private var isDroppingImage = false
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

            Button(model.attachedImages.isEmpty ? "Image" : "Add Image") {
                showingImageImporter = true
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
        VStack(spacing: 0) {
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

            if !model.attachedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(model.attachedImages) { image in
                            imageTile(image)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
                }
            }
        }
        .background(isDroppingImage ? Color.accentColor.opacity(0.08) : Color.clear)
        .onDrop(of: [.image, .fileURL], isTargeted: $isDroppingImage, perform: handleImageDrop)
        .overlay {
            if isDroppingImage {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(8)
                Text("Drop image")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
            }
        }
    }

    private func imageTile(_ image: AttachedImage) -> some View {
        ZStack(alignment: .topTrailing) {
            if let preview = NSImage(data: image.data) {
                Image(nsImage: preview)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.18))
                    .overlay(Text("Image").foregroundStyle(.secondary))
            }

            Button {
                model.removeImage(image)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(.black.opacity(0.72), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(5)
            .help("Remove image")
        }
        .frame(width: 112, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomLeading) {
            Text(image.sizeLabel)
                .font(.caption2)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.58), in: Capsule())
                .padding(5)
        }
    }

    private func handleImageDrop(_ providers: [NSItemProvider]) -> Bool {
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil)
                else {
                    return
                }
                Task { @MainActor in
                    model.attachImage(from: url)
                }
            }
            return true
        }

        if let provider = providers.first(where: { $0.canLoadObject(ofClass: NSImage.self) }) {
            provider.loadObject(ofClass: NSImage.self) { image, _ in
                guard let image = image as? NSImage else {
                    return
                }
                Task { @MainActor in
                    model.attachDroppedImage(image)
                }
            }
            return true
        }

        return false
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
