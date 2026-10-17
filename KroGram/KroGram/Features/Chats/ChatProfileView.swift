// Copyright © 2026 Kro. KroGram original materials.

import SwiftUI
import UIKit

struct ChatProfileView: View {
    let chatID: Int64
    let onGroupLeft: () -> Void
    @EnvironmentObject private var vm: ChatsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var profile: ChatProfile?
    @State private var image: UIImage?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var managedChatID: Int64
    @State private var groupInfo: GroupManagementInfo?
    @State private var channelInfo: ChannelManagementInfo?
    @State private var isLoadingGroup = false
    @State private var groupActionError: String?
    @State private var showAddMembers = false
    @State private var adminTarget: GroupMember?
    @State private var requestedMemberAction: PendingGroupMemberAction?
    @State private var showMemberConfirmation = false
    @State private var showLeaveConfirmation = false
    @State private var showLeaveChannelConfirmation = false
    @State private var showUpgradeConfirmation = false
    @State private var isPerformingGroupAction = false
    @State private var isLoadingMoreMembers = false
    @State private var showUpgradeSuccess = false

    init(chatID: Int64, onGroupLeft: @escaping () -> Void = {}) {
        self.chatID = chatID
        self.onGroupLeft = onGroupLeft
        _managedChatID = State(initialValue: chatID)
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let profile {
                profileContent(profile)
            } else {
                ContentUnavailableView("profile.unavailable", systemImage: "person.crop.circle")
            }
        }
        .navigationTitle("profile.title")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func profileContent(_ profile: ChatProfile) -> some View {
        List {
            Section {
                VStack(spacing: KroSpacing.md) {
                    AvatarView(
                        name: profile.title,
                        seed: Int(truncatingIfNeeded: profile.chatID),
                        size: 92,
                        image: image
                    )
                    Text(profile.title).kro(.title2, weight: .semibold)
                    if let username = profile.username {
                        Text(verbatim: "@\(username)").foregroundStyle(.secondary)
                    } else if let status = profile.status {
                        Text(LocalizedStringKey(statusKey(status))).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, KroSpacing.lg)
                .listRowBackground(Color.clear)
            }
            Section {
                if let phoneNumber = profile.phoneNumber {
                    LabeledContent("profile.phone", value: phoneNumber.isEmpty ? "—" : phoneNumber)
                }
                if let memberCount = profile.memberCount {
                    LabeledContent("profile.members", value: "\(memberCount)")
                }
                if !profile.description.isEmpty {
                    Text(profile.description).textSelection(.enabled)
                }
            }
            if profile.kind == .group {
                groupManagementSections
            } else if profile.kind == .channel {
                channelManagementSections
            }
            Section("profile.sharedMedia") {
                Text("profile.sharedMediaUnavailable")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showAddMembers) {
            NavigationStack {
                GroupMemberPicker(
                    excludedUserIDs: Set(groupInfo?.members.map(\.userID) ?? [])
                ) { userIDs in
                    try await vm.addGroupMembers(chatID: managedChatID, userIDs: userIDs)
                    await reloadGroupInfo()
                }
            }
        }
        .sheet(item: $adminTarget) { member in
            NavigationStack {
                GroupAdminRightsView(member: member) { rights in
                    try await vm.updateGroupMember(
                        chatID: managedChatID,
                        userID: member.userID,
                        status: .administrator,
                        adminRights: rights
                    )
                    await reloadGroupInfo()
                }
                .id(member.userID)
            }
        }
        .confirmationDialog(
            "group.member.confirm",
            isPresented: $showMemberConfirmation,
            presenting: requestedMemberAction
        ) { action in
            Button(LocalizedStringKey(action.titleKey), role: .destructive) {
                Task { await applyMemberAction(action) }
            }
            Button("action.cancel", role: .cancel) {}
        } message: { action in
            Text(action.member.name + "\n" + L(action.messageKey))
        }
        .confirmationDialog("group.leave.confirm", isPresented: $showLeaveConfirmation) {
            Button("group.leave", role: .destructive) { Task { await leaveGroup() } }
            Button("action.cancel", role: .cancel) {}
        }
        .confirmationDialog("channel.leave.confirm", isPresented: $showLeaveChannelConfirmation) {
            Button("channel.leave", role: .destructive) { Task { await leaveChannel() } }
            Button("action.cancel", role: .cancel) {}
        }
        .confirmationDialog("group.upgrade.confirm", isPresented: $showUpgradeConfirmation) {
            Button("group.upgrade") { Task { await upgradeGroup() } }
            Button("action.cancel", role: .cancel) {}
        }
        .alert("group.upgrade", isPresented: $showUpgradeSuccess) {
            Button("action.done", role: .cancel) {}
        } message: {
            Text("group.upgrade.success")
        }
    }

    @ViewBuilder
    private var channelManagementSections: some View {
        if isLoadingGroup {
            Section("channel.info") { ProgressView() }
        } else if let channelInfo {
            Section("channel.info") {
                LabeledContent(
                    "channel.subscribers",
                    value: "\(channelInfo.subscriberCount)"
                )
                LabeledContent(
                    "channel.permission",
                    value: L(channelInfo.canPostMessages ? "channel.permission.admin" : "channel.permission.readOnly")
                )
                if let inviteLink = channelInfo.inviteLink, channelInfo.canInviteUsers {
                    ShareLink(item: inviteLink) {
                        Label("channel.invite.share", systemImage: "square.and.arrow.up")
                    }
                }
                if channelInfo.isMember {
                    Button("channel.leave", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        showLeaveChannelConfirmation = true
                    }
                    .disabled(isPerformingGroupAction)
                }
            }
        } else {
            Section("channel.info") {
                if let groupActionError {
                    Text(groupActionError).foregroundStyle(.red)
                } else {
                    Text("channel.info.unavailable").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var groupManagementSections: some View {
        if let groupInfo {
            Section {
                if isLoadingGroup {
                    ProgressView()
                } else if !groupInfo.canViewMembers {
                    Text("group.members.unavailable")
                        .foregroundStyle(.secondary)
                } else if groupInfo.members.isEmpty {
                    Text("group.members.empty")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(groupInfo.members) { member in
                        memberRow(member)
                    }
                }
                if groupInfo.hasMoreMembers {
                    Button {
                        Task { await loadMoreMembers() }
                    } label: {
                        if isLoadingMoreMembers {
                            ProgressView()
                        } else {
                            Text("group.members.more")
                        }
                    }
                    .disabled(isLoadingMoreMembers || isPerformingGroupAction)
                }
                if groupInfo.canInviteMembers {
                    Button {
                        showAddMembers = true
                    } label: {
                        Label("group.addMembers", systemImage: "person.badge.plus")
                    }
                    .disabled(isPerformingGroupAction)
                }
            } header: {
                HStack {
                    Text("group.members")
                    Spacer()
                    Text(String(format: L("group.memberCount"), groupInfo.memberCount))
                        .foregroundStyle(.secondary)
                }
            }
            if groupInfo.inviteLink != nil || groupInfo.canCreateInviteLink {
                Section("group.invite") {
                    if let inviteLink = groupInfo.inviteLink {
                        ShareLink(item: inviteLink) {
                            Label("group.invite.share", systemImage: "square.and.arrow.up")
                        }
                    } else if groupInfo.canCreateInviteLink {
                        Button {
                            Task { await createInviteLink() }
                        } label: {
                            Label("group.invite.create", systemImage: "link")
                        }
                        .disabled(isPerformingGroupAction)
                    }
                }
            }
            if groupInfo.isBasicGroup && groupInfo.isCreator {
                Section {
                    Button {
                        showUpgradeConfirmation = true
                    } label: {
                        Label("group.upgrade", systemImage: "arrow.up.right.circle")
                    }
                    .disabled(isPerformingGroupAction)
                    Text("group.upgrade.note")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button("group.leave", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    showLeaveConfirmation = true
                }
                .disabled(isPerformingGroupAction)
            }
        } else if isLoadingGroup {
            Section("group.members") { ProgressView() }
        } else {
            Section("group.members") {
                Text("group.members.unavailable")
                    .foregroundStyle(.secondary)
            }
        }
        if let groupActionError {
            Section { Text(groupActionError).foregroundStyle(.red) }
        }
    }

    @ViewBuilder
    private func memberRow(_ member: GroupMember) -> some View {
        HStack(spacing: KroSpacing.sm) {
            AvatarView(
                name: member.name,
                seed: Int(truncatingIfNeeded: member.userID),
                size: 38
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(member.name)
                    .lineLimit(1)
                Text(LocalizedStringKey(memberStatusKey(member.status)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if hasMemberActions(for: member) {
                Menu {
                    if member.status == .member, groupInfo?.canPromoteMembers == true {
                        Button("group.promote") { adminTarget = member }
                    }
                    if member.status == .administrator, groupInfo?.canPromoteMembers == true {
                        Button("group.demote", role: .destructive) {
                            requestMemberAction(member, status: .member)
                        }
                    }
                    if groupInfo?.canRestrictMembers == true {
                        if member.status == .member {
                            Button("group.restrict", role: .destructive) {
                                requestMemberAction(member, status: .restricted)
                            }
                        } else if member.status == .restricted {
                            Button("group.unrestrict") {
                                requestMemberAction(member, status: .member)
                            }
                        } else if member.status == .banned {
                            Button("group.unban") {
                                requestMemberAction(member, status: .left)
                            }
                        }
                        if member.status == .member || member.status == .restricted {
                            Button("group.ban", role: .destructive) {
                                requestMemberAction(member, status: .banned)
                            }
                            Button("group.remove", role: .destructive) {
                                requestMemberAction(member, status: .left)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .disabled(isPerformingGroupAction)
            }
        }
    }

    private func hasMemberActions(for member: GroupMember) -> Bool {
        guard member.status != .creator else { return false }
        let canPromote = groupInfo?.canPromoteMembers == true
            && (member.status == .member || member.status == .administrator)
        let canRestrict = groupInfo?.canRestrictMembers == true
            && (member.status == .member || member.status == .restricted || member.status == .banned)
        return canPromote || canRestrict
    }

    private func memberStatusKey(_ status: GroupMemberStatus) -> String {
        switch status {
        case .creator: return "group.status.creator"
        case .administrator: return "group.status.administrator"
        case .member: return "group.status.member"
        case .restricted: return "group.status.restricted"
        case .left: return "group.status.left"
        case .banned: return "group.status.banned"
        }
    }

    private func requestMemberAction(_ member: GroupMember, status: GroupMemberStatus) {
        requestedMemberAction = PendingGroupMemberAction(member: member, status: status)
        showMemberConfirmation = true
    }

    private func applyMemberAction(_ action: PendingGroupMemberAction) async {
        guard !isPerformingGroupAction else { return }
        isPerformingGroupAction = true
        defer { isPerformingGroupAction = false }
        do {
            try await vm.updateGroupMember(
                chatID: managedChatID,
                userID: action.member.userID,
                status: action.status,
                adminRights: nil
            )
            await reloadGroupInfo()
        } catch {
            groupActionError = TGErrors.message(for: error)
        }
    }

    private func createInviteLink() async {
        guard !isPerformingGroupAction else { return }
        isPerformingGroupAction = true
        defer { isPerformingGroupAction = false }
        do {
            let link = try await vm.createGroupInviteLink(chatID: managedChatID)
            groupInfo?.inviteLink = link
            groupActionError = nil
        } catch {
            groupActionError = TGErrors.message(for: error)
        }
    }

    private func leaveGroup() async {
        guard !isPerformingGroupAction else { return }
        isPerformingGroupAction = true
        defer { isPerformingGroupAction = false }
        do {
            try await vm.leaveGroup(chatID: managedChatID)
            dismiss()
            onGroupLeft()
        } catch {
            groupActionError = TGErrors.message(for: error)
        }
    }

    private func leaveChannel() async {
        guard !isPerformingGroupAction else { return }
        isPerformingGroupAction = true
        defer { isPerformingGroupAction = false }
        do {
            try await vm.leaveChannel(chatID: managedChatID)
            dismiss()
            onGroupLeft()
        } catch {
            groupActionError = TGErrors.message(for: error)
        }
    }

    private func upgradeGroup() async {
        guard !isPerformingGroupAction else { return }
        isPerformingGroupAction = true
        defer { isPerformingGroupAction = false }
        do {
            managedChatID = try await vm.upgradeBasicGroup(chatID: managedChatID)
            await loadProfile()
            showUpgradeSuccess = true
        } catch {
            groupActionError = TGErrors.message(for: error)
        }
    }

    private func reloadGroupInfo() async {
        isLoadingGroup = true
        defer { isLoadingGroup = false }
        do {
            groupInfo = try await vm.loadGroupManagementInfo(chatID: managedChatID)
            groupActionError = nil
        } catch {
            groupInfo = nil
            groupActionError = TGErrors.message(for: error)
        }
    }

    private func loadMoreMembers() async {
        guard var currentInfo = groupInfo, currentInfo.hasMoreMembers, !isLoadingMoreMembers else { return }
        isLoadingMoreMembers = true
        defer { isLoadingMoreMembers = false }
        do {
            let page = try await vm.loadMoreGroupMembers(
                chatID: managedChatID,
                offset: currentInfo.nextMemberOffset
            )
            let existingIDs = Set(currentInfo.members.map(\.userID))
            currentInfo.members.append(contentsOf: page.members.filter { !existingIDs.contains($0.userID) })
            currentInfo.members.sort {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            currentInfo.nextMemberOffset = page.nextOffset
            currentInfo.hasMoreMembers = page.hasMore
            groupInfo = currentInfo
            groupActionError = nil
        } catch {
            groupActionError = TGErrors.message(for: error)
        }
    }

    private func statusKey(_ status: String) -> String {
        switch status {
        case "userStatusOnline": return "profile.status.online"
        case "userStatusOffline": return "profile.status.offline"
        default: return "profile.status.recently"
        }
    }

    @MainActor
    private func load() async {
        await loadProfile()
        isLoading = false
    }

    @MainActor
    private func loadProfile() async {
        do {
            profile = try await vm.loadChatProfile(chatID: managedChatID)
            image = nil
            if let fileID = profile?.avatarFileID {
                do {
                    let data = try await vm.downloadFile(fileID: fileID, limit: 2 * 1_024 * 1_024)
                    image = UIImage(data: data)
                } catch {
                    errorMessage = TGErrors.message(for: error)
                }
            }
            if profile?.kind == .group {
                await reloadGroupInfo()
            } else if profile?.kind == .channel {
                isLoadingGroup = true
                defer { isLoadingGroup = false }
                do {
                    channelInfo = try await vm.loadChannelManagementInfo(chatID: managedChatID)
                    groupActionError = nil
                } catch {
                    channelInfo = nil
                    groupActionError = TGErrors.message(for: error)
                }
            } else {
                groupInfo = nil
                channelInfo = nil
            }
        } catch {
            errorMessage = TGErrors.message(for: error)
        }
    }
}

private struct PendingGroupMemberAction: Identifiable {
    let member: GroupMember
    let status: GroupMemberStatus

    var id: String { "\(member.userID)-\(status.rawValue)" }
    var titleKey: String {
        switch status {
        case .member:
            return member.status == .administrator ? "group.demote" : "group.unrestrict"
        case .restricted: return "group.restrict"
        case .left: return member.status == .banned ? "group.unban" : "group.remove"
        case .banned: return "group.ban"
        case .creator, .administrator: return "group.member.confirm"
        }
    }

    var messageKey: String {
        switch status {
        case .restricted: return "group.restrict.confirm"
        case .banned: return "group.ban.confirm"
        case .left:
            return member.status == .banned ? "group.unban.confirm" : "group.remove.confirm"
        default: return "group.member.confirm"
        }
    }
}
