// Copyright © 2026 Kro. KroGram original materials.

import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var chats: ChatsViewModel

    var body: some View {
        Group {
            if chats.downloadQueue.isEmpty && chats.uploadQueue.isEmpty {
                ContentUnavailableView("downloads.empty", systemImage: "arrow.down.circle")
            } else {
                List {
                    if !chats.uploadQueue.isEmpty {
                        Section("downloads.uploads") {
                            ForEach(chats.uploadQueue) { item in
                                uploadRow(item)
                            }
                        }
                    }
                    if !chats.downloadQueue.isEmpty {
                        Section("downloads.title") {
                            ForEach(chats.downloadQueue) { item in
                                downloadRow(item)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("downloads.title")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func uploadRow(_ item: UploadRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).lineLimit(2)
                    Text(uploadStatusText(item.status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    chats.removeUploadRecord(fileID: item.fileID)
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel(Text("downloads.remove"))
            }
            if item.status == .uploading {
                if item.totalBytes > 0 {
                    ProgressView(value: Double(item.uploadedBytes), total: Double(item.totalBytes))
                    Text("\(ByteCountFormatter.string(fromByteCount: item.uploadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
                Button(role: .destructive) {
                    Task { await chats.cancelUpload(fileID: item.fileID) }
                } label: {
                    Label("downloads.cancelUpload", systemImage: "xmark")
                }
                .disabled(item.chatID == 0 || item.messageID == 0)
                .font(.footnote)
            }
        }
        .padding(.vertical, 6)
    }

    private func downloadRow(_ item: DownloadRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title.isEmpty ? "media.downloaded" : item.title)
                        .lineLimit(2)
                    Text(statusText(item.status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if item.status == .completed, let path = item.localPath {
                    ShareLink(item: URL(fileURLWithPath: path)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel(Text("action.share"))
                }
            }

            if item.status == .downloading || item.status == .paused {
                if item.totalBytes > 0 {
                    ProgressView(value: Double(item.downloadedBytes), total: Double(item.totalBytes))
                    Text("\(ByteCountFormatter.string(fromByteCount: item.downloadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }

            if let errorMessage = item.errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                if item.status == .downloading {
                    Button {
                        chats.pauseDownload(fileID: item.fileID)
                    } label: {
                        Label("downloads.pause", systemImage: "pause.fill")
                    }
                } else if [.queued, .paused, .failed].contains(item.status) {
                    Button {
                        chats.resumeDownload(fileID: item.fileID)
                    } label: {
                        Label("downloads.resume", systemImage: "arrow.clockwise")
                    }
                }
                Spacer()
                if [.queued, .downloading, .paused, .failed].contains(item.status) {
                    Button(role: .destructive) {
                        chats.cancelDownload(fileID: item.fileID)
                    } label: {
                        Label("downloads.cancel", systemImage: "xmark")
                    }
                }
                Button {
                    chats.removeDownload(fileID: item.fileID)
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel(Text("downloads.remove"))
            }
            .font(.footnote)
        }
        .padding(.vertical, 6)
    }

    private func statusText(_ status: DownloadStatus) -> LocalizedStringKey {
        switch status {
        case .queued: return "downloads.status.queued"
        case .downloading: return "downloads.status.downloading"
        case .paused: return "downloads.status.paused"
        case .completed: return "downloads.status.completed"
        case .failed: return "downloads.status.failed"
        case .cancelled: return "downloads.status.cancelled"
        }
    }

    private func uploadStatusText(_ status: UploadStatus) -> LocalizedStringKey {
        switch status {
        case .uploading: return "downloads.status.uploading"
        case .completed: return "downloads.status.completed"
        case .failed: return "downloads.status.failed"
        case .cancelled: return "downloads.status.cancelled"
        }
    }
}