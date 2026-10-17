// Copyright © 2026 Kro. KroGram original materials.

import Foundation
import PhotosUI
import SwiftUI
import UIKit

struct CreateGroupView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var vm: ChatsViewModel
    let onCreated: (GroupCreationResult) -> Void

    @State private var title = ""
    @State private var searchText = ""
    @State private var selectedUserIDs = Set<Int64>()
    @State private var photoSelection: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var errorMessage: String?
    @State private var isCreating = false
    @State private var completedGroup: GroupCreationResult?
    @State private var showSetupWarning = false

    private var filteredContacts: [Contact] {
        guard !searchText.isEmpty else { return vm.contacts }
        return vm.contacts.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || ($0.username?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        Form {
            Section("group.details") {
                TextField("group.name", text: $title)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                HStack(spacing: 16) {
                    if let photoData, let image = UIImage(data: photoData) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(Circle())
                    } else {
                        Image(systemName: "person.2.circle.fill")
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
            Section {
                if vm.contactsLoading {
                    ProgressView()
                } else if filteredContacts.isEmpty {
                    Text("group.contacts.empty")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredContacts) { contact in
                        Button {
                            if selectedUserIDs.contains(contact.id) {
                                selectedUserIDs.remove(contact.id)
                            } else {
                                selectedUserIDs.insert(contact.id)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(contact.name)
                                        .foregroundStyle(.primary)
                                    if let username = contact.username {
                                        Text(verbatim: "@\(username)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: selectedUserIDs.contains(contact.id)
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selectedUserIDs.contains(contact.id)
                                                     ? .accentColor : Color(uiColor: .secondaryLabel))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                HStack {
                    Text("group.members")
                    Spacer()
                    Text(String(format: L("group.selectedCount"), selectedUserIDs.count))
                        .foregroundStyle(.secondary)
                }
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
            if let completedGroup {
                Section {
                    Button("group.openCreated") { onCreated(completedGroup) }
                }
            }
        }
        .navigationTitle("group.create")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: Text("chats.search.prompt"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("action.cancel") { dismiss() }
                    .disabled(isCreating)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("group.create.action", action: create)
                    .disabled(isCreating
                              || completedGroup != nil
                              || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .task { await loadContacts() }
        .onChange(of: photoSelection) { _, item in
            Task { await loadPhoto(item) }
        }
        .alert("group.create.partial", isPresented: $showSetupWarning, presenting: completedGroup) { result in
            Button("group.openCreated") { onCreated(result) }
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

    private func loadContacts() async {
        await vm.loadContacts()
        if vm.contacts.isEmpty, let message = vm.mediaError {
            errorMessage = message
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
                        throw TDError(code: -3, message: "GROUP_PHOTO_UNAVAILABLE")
                    }
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("KroGramGroup-\(UUID().uuidString).jpg")
                    try jpeg.write(to: url, options: .atomic)
                    photoPath = url.path
                }
                let result = try await vm.createGroup(
                    title: title,
                    memberIDs: Array(selectedUserIDs),
                    photoPath: photoPath
                )
                if result.warnings.isEmpty {
                    onCreated(result)
                } else {
                    completedGroup = result
                    showSetupWarning = true
                }
            } catch {
                errorMessage = TGErrors.message(for: error)
            }
        }
    }
}

struct GroupMemberPicker: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var vm: ChatsViewModel
    let excludedUserIDs: Set<Int64>
    let onAdd: ([Int64]) async throws -> Void

    @State private var searchText = ""
    @State private var selectedUserIDs = Set<Int64>()
    @State private var errorMessage: String?
    @State private var isSaving = false

    private var availableContacts: [Contact] {
        vm.contacts
            .filter { !excludedUserIDs.contains($0.id) }
            .filter {
                searchText.isEmpty
                    || $0.name.localizedCaseInsensitiveContains(searchText)
                    || ($0.username?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
    }

    var body: some View {
        List {
            if vm.contactsLoading {
                ProgressView()
            } else if availableContacts.isEmpty {
                Text("group.contacts.empty")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(availableContacts) { contact in
                    Button {
                        if selectedUserIDs.contains(contact.id) {
                            selectedUserIDs.remove(contact.id)
                        } else {
                            selectedUserIDs.insert(contact.id)
                        }
                    } label: {
                        HStack {
                            Text(contact.name).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: selectedUserIDs.contains(contact.id)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(selectedUserIDs.contains(contact.id)
                                                 ? .accentColor : Color(uiColor: .secondaryLabel))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
        }
        .navigationTitle("group.addMembers")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: Text("chats.search.prompt"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("action.cancel") { dismiss() }
                    .disabled(isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("group.addMembers.action", action: add)
                    .disabled(selectedUserIDs.isEmpty || isSaving)
            }
        }
        .task { await loadContacts() }
    }

    private func loadContacts() async {
        await vm.loadContacts()
        if vm.contacts.isEmpty, let message = vm.mediaError {
            errorMessage = message
        }
    }

    private func add() {
        guard !selectedUserIDs.isEmpty, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                try await onAdd(Array(selectedUserIDs))
                dismiss()
            } catch {
                errorMessage = TGErrors.message(for: error)
            }
        }
    }
}

struct GroupAdminRightsView: View {
    @Environment(\.dismiss) private var dismiss
    let member: GroupMember
    let onSave: (GroupAdminRights) async throws -> Void

    @State private var rights = GroupAdminRights()
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        Form {
            Section {
                Toggle("group.right.manageChat", isOn: $rights.canManageChat)
                Toggle("group.right.changeInfo", isOn: $rights.canChangeInfo)
                Toggle("group.right.invite", isOn: $rights.canInviteUsers)
                Toggle("group.right.restrict", isOn: $rights.canRestrictMembers)
                Toggle("group.right.pin", isOn: $rights.canPinMessages)
                Toggle("group.right.promote", isOn: $rights.canPromoteMembers)
            } footer: {
                Text("group.rights.note")
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle(member.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("action.cancel") { dismiss() }
                    .disabled(isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("action.save", action: save)
                    .disabled(isSaving)
            }
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                try await onSave(rights)
                dismiss()
            } catch {
                errorMessage = TGErrors.message(for: error)
            }
        }
    }
}
