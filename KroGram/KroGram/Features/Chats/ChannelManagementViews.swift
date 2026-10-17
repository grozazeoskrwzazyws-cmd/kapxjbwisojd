// Copyright © 2026 Kro. KroGram original materials.

import PhotosUI
import SwiftUI
import UIKit

struct CreateChannelView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var vm: ChatsViewModel
    let onCreated: (ChannelCreationResult) -> Void

    @State private var title = ""
    @State private var description = ""
    @State private var photoSelection: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var errorMessage: String?
    @State private var isCreating = false
    @State private var completedChannel: ChannelCreationResult?
    @State private var showSetupWarning = false

    var body: some View {
        Form {
            Section("channel.details") {
                TextField("channel.name", text: $title)
                    .textInputAutocapitalization(.words)
                TextField("channel.description", text: $description, axis: .vertical)
                    .lineLimit(3...6)
                HStack(spacing: 16) {
                    if let photoData, let image = UIImage(data: photoData) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(Circle())
                    } else {
                        Image(systemName: "megaphone.circle.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 64, height: 64)
                            .foregroundStyle(.secondary)
                    }
                    PhotosPicker(selection: $photoSelection, matching: .images) {
                        Label("group.addPhoto", systemImage: "photo")
                    }
                }
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
            if let completedChannel {
                Section {
                    Button("channel.openCreated") { onCreated(completedChannel) }
                }
            }
        }
        .navigationTitle("channel.create")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("action.cancel") { dismiss() }
                    .disabled(isCreating)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("channel.create.action", action: create)
                    .disabled(isCreating || completedChannel != nil
                              || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onChange(of: photoSelection) { _, item in Task { await loadPhoto(item) } }
        .alert("group.create.partial", isPresented: $showSetupWarning, presenting: completedChannel) { result in
            Button("channel.openCreated") { onCreated(result) }
            Button("action.cancel", role: .cancel) {}
        } message: { result in
            Text(result.warnings.joined(separator: "\n"))
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            photoData = try await item.loadTransferable(type: Data.self)
            errorMessage = nil
        } catch {
            errorMessage = TGErrors.message(for: error)
        }
    }

    private func create() {
        guard !isCreating else { return }
        isCreating = true
        errorMessage = nil
        Task {
            defer { isCreating = false }
            do {
                var photoPath: String?
                if let photoData {
                    guard let image = UIImage(data: photoData),
                          let thumbnail = image.preparingThumbnail(of: CGSize(width: 512, height: 512)),
                          let jpeg = thumbnail.jpegData(compressionQuality: 0.88) else {
                        throw TDError(code: -3, message: "CHANNEL_PHOTO_UNAVAILABLE")
                    }
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("KroGramChannel-\(UUID().uuidString).jpg")
                    try jpeg.write(to: url, options: .atomic)
                    photoPath = url.path
                }
                let result = try await vm.createChannel(
                    title: title,
                    description: description,
                    photoPath: photoPath
                )
                if result.warnings.isEmpty {
                    onCreated(result)
                } else {
                    completedChannel = result
                    showSetupWarning = true
                }
            } catch {
                errorMessage = TGErrors.message(for: error)
            }
        }
    }
}

struct JoinChannelView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var vm: ChatsViewModel
    let onJoined: (Int64) -> Void

    @State private var identifier = ""
    @State private var errorMessage: String?
    @State private var isJoining = false

    var body: some View {
        Form {
            Section("channel.join") {
                TextField("channel.identifier", text: $identifier)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("channel.join")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("action.cancel") { dismiss() }
                    .disabled(isJoining)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("channel.join.action") { join() }
                    .disabled(isJoining || identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func join() {
        guard !isJoining else { return }
        isJoining = true
        errorMessage = nil
        Task {
            defer { isJoining = false }
            do {
                let chatID = try await vm.joinChannel(identifier: identifier)
                onJoined(chatID)
            } catch {
                errorMessage = TGErrors.message(for: error)
            }
        }
    }
}
