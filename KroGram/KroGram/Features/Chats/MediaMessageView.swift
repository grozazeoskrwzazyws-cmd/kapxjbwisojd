// Copyright © 2026 Kro. KroGram original materials.

import AVKit
import SwiftUI
import UIKit

struct MediaMessageView: View {
    let media: MessageMedia
    var onOpen: () -> Void = {}
    @EnvironmentObject private var vm: ChatsViewModel
    @State private var data: Data?
    @State private var localURL: URL?
    @State private var player: AVPlayer?

    private let maxDownloadBytes: Int64 = 1_073_741_824

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if media.kind == .sticker,
               let data,
               let localURL,
               let format = media.stickerFormat,
               format != .webp {
                StickerPlaybackView(format: format, data: data, url: localURL, cacheKey: media.fileID)
                    .frame(width: 160, height: 160)
            } else if let data, [.photo, .sticker].contains(media.kind), let image = UIImage(data: data) {
                Button(action: onOpen) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260, maxHeight: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            } else if let player, [.video, .animation, .videoNote].contains(media.kind) {
                ZStack(alignment: .topTrailing) {
                    VideoPlayer(player: player)
                        .frame(maxWidth: 260)
                        .frame(height: 210)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Button(action: onOpen) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption.weight(.semibold))
                            .padding(8)
                            .background(.black.opacity(0.65), in: Circle())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                }
            } else if localURL != nil, [.audio, .voice].contains(media.kind) {
                Button {
                    if player?.timeControlStatus == .playing {
                        player?.pause()
                    } else {
                        player?.play()
                    }
                } label: {
                    Label("media.playAudio", systemImage: player?.timeControlStatus == .playing ? "pause.fill" : "play.fill")
                }
            } else if let localURL {
                ShareLink(item: localURL) {
                    Label(media.fileName ?? L("media.downloaded"), systemImage: "square.and.arrow.up")
                }
            } else {
                downloadControl
            }
        }
        .task {
            if let cached = vm.cachedFileData(fileID: media.fileID) {
                do {
                    try displayDownloaded(cached)
                } catch {
                    vm.setMediaError(TGErrors.message(for: error))
                }
            } else if vm.shouldAutoDownload(media) {
                await download(shouldOpen: false)
            }
        }
        .onDisappear { player?.pause() }
    }

    @ViewBuilder
    private var downloadControl: some View {
        if let progress = vm.mediaProgress[media.fileID] {
            HStack(spacing: 8) {
                if progress.total > 0 {
                    ProgressView(value: Double(progress.downloaded), total: Double(progress.total))
                } else {
                    ProgressView()
                }
                Button("media.cancel") { vm.cancelFileDownload(fileID: media.fileID) }
                    .font(.caption)
            }
            .frame(maxWidth: 200)
        } else {
            Button {
                Task { await download() }
            } label: {
                if let fileName = media.fileName {
                    Label(fileName, systemImage: symbol)
                } else {
                    Label(labelKey, systemImage: symbol)
                }
            }
            .font(.footnote)
        }
    }

    private var labelKey: LocalizedStringKey {
        switch media.kind {
        case .photo: return "msg.photo"
        case .video, .videoNote: return "msg.video"
        case .animation: return "msg.gif"
        case .audio, .voice: return "msg.audio"
        case .sticker: return "msg.sticker"
        case .document: return "msg.file"
        }
    }

    private var labelString: String {
        switch media.kind {
        case .photo: return L("msg.photo")
        case .video, .videoNote: return L("msg.video")
        case .animation: return L("msg.gif")
        case .audio, .voice: return L("msg.audio")
        case .sticker: return L("msg.sticker")
        case .document: return L("msg.file")
        }
    }

    private var symbol: String {
        switch media.kind {
        case .photo: return "photo"
        case .video, .videoNote, .animation: return "play.rectangle"
        case .audio, .voice: return "waveform"
        case .sticker: return "face.smiling"
        case .document: return "doc"
        }
    }

    @MainActor
    private func download(shouldOpen: Bool = true) async {
        do {
            let url = try await vm.downloadFileURL(
                fileID: media.fileID,
                title: media.fileName ?? labelString,
                fileSize: media.fileSize,
                mediaKind: media.kind,
                limit: maxDownloadBytes
            )
            localURL = url
            let size = (try? url.resourceValues(forKeys: [URLResourceKey.fileSizeKey]).fileSize)
                .map(Int64.init) ?? 0
            if [.photo, .sticker].contains(media.kind), size <= 25 * 1_024 * 1_024 {
                data = try Data(contentsOf: url, options: .mappedIfSafe)
            }
            if [.video, .animation, .videoNote, .audio, .voice].contains(media.kind) {
                player = AVPlayer(url: url)
            }
            if shouldOpen && [.photo, .video].contains(media.kind) { onOpen() }
        } catch {
            vm.setMediaError(TGErrors.message(for: error))
        }
    }

    @MainActor
    private func displayDownloaded(_ downloaded: Data) throws {
        data = downloaded
        let url = try vm.cacheFileURL(
            fileID: media.fileID,
            data: downloaded,
            fileName: media.kind == .sticker
                ? "sticker.\((media.stickerFormat ?? .webp).fileExtension)"
                : media.fileName,
            mimeType: media.kind == .sticker
                ? media.mimeType ?? (media.stickerFormat ?? .webp).mimeType
                : media.mimeType
        )
        localURL = url
        if [.video, .animation, .videoNote, .audio, .voice].contains(media.kind) {
            player = AVPlayer(url: url)
        }
    }
}
