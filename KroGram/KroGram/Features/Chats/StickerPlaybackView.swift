// Copyright © 2026 Kro. KroGram original materials.

import CoreFoundation
import Darwin
import Gzip
import GLKit
import Libmpv
import Lottie
import SwiftUI
import UIKit

struct StickerPlaybackView: View {
    let format: StickerFormat
    let data: Data
    let url: URL
    let cacheKey: Int64

    @State private var animation: LottieAnimation?
    @State private var loadError: String?
    @State private var isPlaybackAllowed = false

    var body: some View {
        Group {
            switch format {
            case .webp:
                if let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    unavailable
                }
            case .tgs:
                if !isPlaybackAllowed {
                    unavailable
                } else if let animation {
                    LottieAnimationContainer(animation: animation)
                } else if loadError != nil {
                    unavailable
                } else {
                    ProgressView()
                        .task(id: cacheKey) { await loadAnimation() }
                }
            case .webm:
                if isPlaybackAllowed {
                    WebMStickerPlayer(url: url)
                } else {
                    unavailable
                }
            }
        }
        .accessibilityLabel(Text("sticker.animation"))
        .onAppear {
            isPlaybackAllowed = StickerPlaybackBudget.shared.acquire(id: instanceID, format: format)
        }
        .onDisappear {
            StickerPlaybackBudget.shared.release(id: instanceID)
            isPlaybackAllowed = false
        }
    }

    @State private var instanceID = UUID()

    private var unavailable: some View {
        Image(systemName: "face.smiling")
            .font(.title2)
            .foregroundStyle(.secondary)
    }

    @MainActor
    private final class StickerPlaybackBudget {
        static let shared = StickerPlaybackBudget()

        private var active: [UUID: StickerFormat] = [:]

        func acquire(id: UUID, format: StickerFormat) -> Bool {
            guard format != .webp else { return true }
            if active[id] != nil { return true }
            let activeCount = active.values.filter { $0 == format }.count
            let maximum = format == .webm ? 2 : 8
            guard activeCount < maximum else { return false }
            active[id] = format
            return true
        }

        func release(id: UUID) {
            active[id] = nil
        }
    }

    @MainActor
    private func loadAnimation() async {
        do {
            let json = try await TGSAnimationCache.shared.json(for: cacheKey, compressed: data)
            animation = try await Task.detached(priority: .userInitiated) {
                try LottieAnimation.from(data: json)
            }.value
        } catch {
            loadError = TGErrors.message(for: error)
        }
    }
}

@MainActor
private final class TGSAnimationCache {
    static let shared = TGSAnimationCache()

    private let maximumBytes = 8 * 1_024 * 1_024
    private var cachedJSON: [Int64: Data] = [:]
    private var leastRecentlyUsed: [Int64] = []
    private var cachedBytes = 0
    private var inflight: [Int64: Task<Data, Error>] = [:]

    func json(for id: Int64, compressed: Data) async throws -> Data {
        if let cached = cachedJSON[id] {
            leastRecentlyUsed.removeAll { $0 == id }
            leastRecentlyUsed.append(id)
            return cached
        }
        if let task = inflight[id] { return try await task.value }
        let task = Task.detached(priority: .userInitiated) {
            try compressed.gunzipped()
        }
        inflight[id] = task
        let decompressed: Data
        do {
            decompressed = try await task.value
            inflight[id] = nil
        } catch {
            inflight[id] = nil
            throw error
        }
        guard !decompressed.isEmpty, decompressed.count <= 4 * 1_024 * 1_024 else {
            throw TDError(code: -3, message: "INVALID_STICKER")
        }
        while cachedBytes + decompressed.count > maximumBytes, let oldest = leastRecentlyUsed.first {
            leastRecentlyUsed.removeFirst()
            cachedBytes -= cachedJSON.removeValue(forKey: oldest)?.count ?? 0
        }
        cachedJSON[id] = decompressed
        leastRecentlyUsed.append(id)
        cachedBytes += decompressed.count
        return decompressed
    }
}

private struct LottieAnimationContainer: UIViewRepresentable {
    let animation: LottieAnimation

    func makeUIView(context: Context) -> LottieAnimationView {
        let view = LottieAnimationView(animation: animation)
        view.contentMode = .scaleAspectFit
        view.loopMode = .loop
        view.backgroundBehavior = .pauseAndRestore
        view.play()
        return view
    }

    func updateUIView(_ view: LottieAnimationView, context: Context) {
        if view.animation !== animation {
            view.animation = animation
            view.currentProgress = 0
            view.play()
        }
    }
}

private struct WebMStickerPlayer: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> WebMStickerPlayerController {
        WebMStickerPlayerController(url: url)
    }

    func updateUIViewController(_ controller: WebMStickerPlayerController, context: Context) {
        controller.load(url)
    }

    static func dismantleUIViewController(
        _ controller: WebMStickerPlayerController,
        coordinator: ()
    ) {
        controller.releasePlayer()
    }
}

@MainActor
private final class WebMStickerPlayerController: GLKViewController, GLKViewDelegate {
    private let url: URL
    private var glContext: EAGLContext?
    private var player: OpaquePointer?
    private var renderContext: OpaquePointer?
    private var framebuffer: GLint = 0
    private var loadedURL: URL?

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        guard let context = EAGLContext(api: .openGLES2) else {
            view = UIView(frame: .zero)
            return
        }
        glContext = context
        let glView = GLKView(frame: .zero, context: context)
        glView.delegate = self
        glView.isOpaque = false
        view = glView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredFramesPerSecond = 30
        configurePlayer()
        load(url)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setPaused(false)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        setPaused(true)
    }

    func load(_ url: URL) {
        guard loadedURL != url, player != nil else { return }
        loadedURL = url
        issue(["loadfile", url.path, "replace"])
    }

    func releasePlayer() {
        guard let player else { return }
        if let glContext { EAGLContext.setCurrent(glContext) }
        if let renderContext {
            mpv_render_context_set_update_callback(renderContext, nil, nil)
            mpv_render_context_free(renderContext)
            self.renderContext = nil
        }
        mpv_terminate_destroy(player)
        self.player = nil
    }

    private func configurePlayer() {
        guard let glContext, EAGLContext.setCurrent(glContext) else { return }
        guard let player = mpv_create() else { return }
        self.player = player
        _ = mpv_set_option_string(player, "vo", "libmpv")
        _ = mpv_set_option_string(player, "hwdec", "no")
        _ = mpv_set_option_string(player, "loop-file", "inf")
        _ = mpv_set_option_string(player, "audio", "no")
        guard mpv_initialize(player) >= 0 else {
            releasePlayer()
            return
        }

        var initParameters = mpv_opengl_init_params(
            get_proc_address: { _, name in
                Self.openGLFunction(named: name)
            },
            get_proc_address_ctx: nil
        )
        let apiName = MPV_RENDER_API_TYPE_OPENGL as NSString
        let apiType = UnsafeMutableRawPointer(mutating: apiName.utf8String)
        withUnsafeMutablePointer(to: &initParameters) { initPointer in
            var parameters = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: apiType),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: initPointer),
                mpv_render_param()
            ]
            guard mpv_render_context_create(&renderContext, player, &parameters) >= 0 else {
                releasePlayer()
                return
            }
        }
        guard let renderContext, let glView = view as? GLKView else { return }
        mpv_render_context_set_update_callback(
            renderContext,
            { opaque in
                guard let opaque else { return }
                let view = Unmanaged<GLKView>.fromOpaque(opaque).takeUnretainedValue()
                DispatchQueue.main.async { view.display() }
            },
            Unmanaged.passUnretained(glView).toOpaque()
        )
    }

    func glkView(_ view: GLKView, drawIn rect: CGRect) {
        guard let renderContext else { return }
        glClearColor(0, 0, 0, 0)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &framebuffer)
        var viewport = [GLint](repeating: 0, count: 4)
        viewport.withUnsafeMutableBufferPointer {
            glGetIntegerv(GLenum(GL_VIEWPORT), $0.baseAddress)
        }
        var target = mpv_opengl_fbo(
            fbo: Int32(framebuffer),
            w: Int32(viewport[2]),
            h: Int32(viewport[3]),
            internal_format: 0
        )
        var flip: CInt = 1
        withUnsafeMutablePointer(to: &target) { targetPointer in
            withUnsafeMutablePointer(to: &flip) { flipPointer in
                var parameters = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: targetPointer),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPointer),
                    mpv_render_param()
                ]
                mpv_render_context_render(renderContext, &parameters)
            }
        }
    }

    private func setPaused(_ paused: Bool) {
        guard let player else { return }
        var value: Int32 = paused ? 1 : 0
        _ = mpv_set_property(player, "pause", MPV_FORMAT_FLAG, &value)
    }

    private func issue(_ strings: [String]) {
        guard let player else { return }
        let allocated = strings.map { strdup($0) }
        defer { allocated.forEach { free($0) } }
        var arguments: [UnsafePointer<CChar>?] = allocated.map { pointer in
            pointer.map { UnsafePointer<CChar>($0) }
        }
        arguments.append(nil)
        arguments.withUnsafeMutableBufferPointer {
            _ = mpv_command(player, $0.baseAddress)
        }
    }

    private static func openGLFunction(named name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
        guard let name,
              let symbol = CFStringCreateWithCString(
                kCFAllocatorDefault,
                name,
                CFStringBuiltInEncodings.ASCII.rawValue
              ),
              let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengles" as CFString) else {
            return nil
        }
        return CFBundleGetFunctionPointerForName(bundle, symbol)
    }
}
