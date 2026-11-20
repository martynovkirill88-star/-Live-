import SwiftUI
import PhotosUI
import AVKit
import AVFoundation
import CoreImage

struct CaptureComposer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = ClipCamera()
    @State private var seconds = 15
    @State private var elapsed = 0
    @State private var recordingStarted: Date?
    @State private var attribution: String?
    @State private var panel: Panel?
    @State private var mask = CameraMask.none
    @State private var chosen: CameraTrack?
    @State private var sample: CameraTrack?
    @State private var sampling = false
    @State private var player: AVPlayer?
    @State private var movie: URL?
    @State private var gallery: PhotosPickerItem?
    @State private var working = false
    @State private var error: String?
    let onReady: (URL, String?) -> Void
    private enum Panel { case music, masks }
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    private let background = Color(red: 0.063, green: 0.071, blue: 0.075)

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                LinearGradient(colors: [Color(red: 0.13, green: 0.18, blue: 0.16),
                    Color(red: 0.23, green: 0.30, blue: 0.27), .black],
                    startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                if let movie {
                    VideoPlayer(player: player)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.bottom, 72)
                    reviewActions(movie)
                } else {
                    if camera.ready {
                        CameraSurface(session: camera.session, mask: mask, face: mask.tracksFace ? camera.face : nil)
                            .saturation(mask == .retro ? 0.72 : (mask == .neon ? 1.48 : 1))
                            .ignoresSafeArea()
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            LinearGradient(colors: [.clear, .black.opacity(0.83), .black],
                                startPoint: .top, endPoint: .bottom)
                                .frame(height: 220 + geometry.safeAreaInsets.bottom)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(.container, edges: .bottom)
                        .allowsHitTesting(false)
                    }
                    VStack(spacing: 16) {
                        topBar
                        if camera.recording { recordingTime }
                        Spacer()
                        if panel == nil { controls }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    if let panel {
                        Color.black.opacity(0.08).ignoresSafeArea().onTapGesture { closePanel() }
                        sheet(panel)
                            .frame(height: min(394, geometry.size.height * 0.62), alignment: .top)
                            .transition(.move(edge: .bottom))
                    }
                }
                if working {
                    ProgressView().tint(.white).padding(20).background(.black.opacity(0.7), in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .task { await camera.activate() }
        .task(id: gallery) {
            guard let gallery else { return }
            working = true
            defer { working = false }
            do {
                guard let file = try await gallery.loadTransferable(type: GalleryVideo.self) else {
                    throw URLError(.cannotDecodeContentData)
                }
                if Task.isCancelled { try? FileManager.default.removeItem(at: file.url); return }
                attribution = nil
                preview(file.url)
            } catch is CancellationError {} catch { self.error = "Не удалось открыть видео из галереи." }
        }
        .onReceive(timer) { _ in
            let duration = CMTimeGetSeconds(camera.output.recordedDuration)
            if camera.recording && duration.isFinite { elapsed = Int(duration) }
        }
        .onChange(of: camera.recording) { recordingStarted = $0 ? Date() : nil }
        .onChange(of: camera.issue) { issue in if let issue { error = issue } }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                if camera.recording { camera.stop() }
                player?.pause()
            }
        }
        .onDisappear { camera.shutdown(); player?.pause() }
        .alert("Камера", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("Понятно", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private var topBar: some View {
        HStack {
            round("xmark", label: "Закрыть") { dismiss() }
                .disabled(camera.recording || working)
            Spacer()
            HStack(spacing: 5) {
                Button {
                    sample = chosen
                    withAnimation(.easeInOut(duration: 0.22)) { panel = .music }
                } label: {
                    Label(chosen?.title ?? "Музыка", systemImage: "music.note")
                        .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        .frame(minWidth: panel == nil ? 116 : 98, maxWidth: 156, minHeight: 44)
                        .padding(.horizontal, 12)
                        .background(.black.opacity(0.54), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 1))
                }.buttonStyle(.plain)
                if chosen != nil {
                    round("xmark", label: "Убрать музыку") {
                        chosen = nil
                        sample = nil
                        player?.pause()
                        player = nil
                    }
                }
            }.disabled(camera.recording || working)
            Spacer()
            round("arrow.trianglehead.camera.rotate", label: "Переключить камеру") { camera.flip() }
                .disabled(camera.recording || working || !camera.ready)
        }.padding(.top, 6)
    }

    private func round(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon == "arrow.trianglehead.camera.rotate" ? "camera.rotate" : icon)
                .font(.system(size: 15, weight: .medium)).frame(width: 44, height: 44)
                .background(.black.opacity(0.55), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.26), lineWidth: 1))
        }.buttonStyle(.plain).accessibilityLabel(label)
    }

    private var recordingTime: some View {
        HStack(spacing: 7) {
            Circle().fill(Color(red: 1, green: 0.14, blue: 0.25)).frame(width: 7, height: 7)
            Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))
                .monospacedDigit().font(.system(size: 14, weight: .semibold))
        }.padding(.horizontal, 12).padding(.vertical, 7).background(.black.opacity(0.72), in: Capsule())
    }

    private var controls: some View {
        VStack(spacing: 13) {
            HStack(spacing: 0) {
                ForEach([15, 60, 120], id: \.self) { value in
                    Button { seconds = value } label: {
                        Text(value == 120 ? "2 мин" : "\(value) с")
                            .font(.system(size: 13, weight: seconds == value ? .semibold : .regular))
                            .frame(width: 70, height: 36)
                            .foregroundStyle(seconds == value ? .black : .white.opacity(camera.recording ? 0.42 : 1))
                            .background(seconds == value ? .white : .clear, in: Capsule())
                    }.buttonStyle(.plain)
                }
            }.padding(3).background(.black.opacity(0.60), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.17), lineWidth: 1))
                .disabled(camera.recording || working)
            HStack {
                PhotosPicker(selection: $gallery, matching: .videos) {
                    control("photo.on.rectangle", "Галерея")
                }.buttonStyle(.plain).opacity(camera.recording ? 0 : 1).disabled(camera.recording || working)
                Spacer()
                Button { capture() } label: {
                    ZStack {
                        Circle().strokeBorder(.white.opacity(camera.recording ? 0.38 : 1), lineWidth: 2)
                        if camera.recording {
                            TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                                let time = recordingStarted.map { context.date.timeIntervalSince($0) } ?? 0
                                Circle().trim(from: 0, to: min(1, max(0, time / Double(seconds))))
                                    .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                            }
                        }
                        RoundedRectangle(cornerRadius: camera.recording ? 8 : 36)
                            .fill(Color(red: 1, green: 0.14, blue: 0.24))
                            .frame(width: camera.recording ? 32 : 67, height: camera.recording ? 32 : 67)
                            .animation(.easeInOut(duration: 0.23), value: camera.recording)
                    }.frame(width: 77, height: 77)
                }.buttonStyle(.plain).disabled(!camera.ready || working)
                    .accessibilityLabel(camera.recording ? "Остановить запись" : "Начать запись")
                Spacer()
                Button { withAnimation(.easeInOut(duration: 0.22)) { panel = .masks } } label: {
                    control("face.smiling", "Маски")
                }.buttonStyle(.plain).opacity(camera.recording ? 0 : 1).disabled(camera.recording || working)
            }.padding(.horizontal, 28)
        }
    }

    private func control(_ image: String, _ title: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: image).font(.system(size: 19)).frame(width: 50, height: 50)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.24), lineWidth: 1))
            Text(title).font(.system(size: 13, weight: .medium))
        }.frame(width: 64)
    }

    private func sheet(_ current: Panel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule().fill(.white.opacity(0.29)).frame(width: 36, height: 4)
                .frame(maxWidth: .infinity).padding(.top, 10)
            HStack {
                Text(current == .masks ? "Маски" : "Музыка").font(.system(size: 23, weight: .semibold))
                Spacer()
                Button("Готово") {
                    if current == .music { chosen = sample }
                    closePanel()
                }.buttonStyle(.plain).font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 17).frame(height: 44)
                    .background(.white.opacity(0.09), in: Capsule())
            }
            if current == .masks {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(CameraMask.allCases) { item in
                        Button { mask = item } label: {
                            VStack(spacing: 2) {
                                cameraArtwork("mask-\(item.id)", fallback: item.icon).frame(width: 41, height: 39)
                                Text(item.title).font(.system(size: 12)).lineLimit(1)
                            }.frame(maxWidth: .infinity).frame(height: 85)
                                .background(Color(red: 29/255, green: 33/255, blue: 35/255), in: RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16)
                                    .strokeBorder(.white.opacity(mask == item ? 0.85 : 0), lineWidth: 1.5))
                        }.buttonStyle(.plain)
                    }
                }
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(CameraTrack.catalog) { track in
                            Button { sampleTrack(track) } label: {
                                HStack(spacing: 10) {
                                    cameraArtwork("art-\(track.id % 5)", fallback: "record.circle.fill")
                                        .frame(width: 42, height: 42)
                                        .overlay {
                                            if sampling && sample == track {
                                                Image(systemName: "pause.fill").shadow(radius: 3)
                                            }
                                        }.clipShape(RoundedRectangle(cornerRadius: 8))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(track.title).font(.system(size: 14, weight: .medium))
                                        if track.source != nil {
                                            Text("Kevin MacLeod · CC BY 4.0").font(.system(size: 11)).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text(track.duration).font(.system(size: 13)).foregroundStyle(.white.opacity(0.62))
                                }.padding(.horizontal, 7).frame(height: 52)
                                    .background(.white.opacity(sample == track ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: 13))
                            }.buttonStyle(.plain)
                        }
                    }
                }.scrollIndicators(.hidden)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 20)
            .background(background.clipShape(RoundedRectangle(cornerRadius: 28)).ignoresSafeArea(edges: .bottom))
    }

    private func cameraArtwork(_ name: String, fallback: String) -> some View {
        Group {
            if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "CameraMusic"),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable()
            } else {
                Image(systemName: fallback)
            }
        }.accessibilityHidden(true)
    }

    private func closePanel() {
        sampling = false
        player?.pause()
        player = nil
        withAnimation(.easeInOut(duration: 0.22)) { panel = nil }
    }

    private func sampleTrack(_ track: CameraTrack) {
        if sample == track && sampling {
            player?.pause()
            sampling = false
            return
        }
        guard let url = track.url else { error = "Трек недоступен."; return }
        sample = track
        sampling = true
        player = AVPlayer(url: url)
        player?.play()
    }

    private func capture() {
        if camera.recording { camera.stop(); return }
        let track = chosen
        let effectCredit = mask.artwork == nil ? nil : CameraMask.credit
        let music = track?.url
        let credits = [track?.attribution, effectCredit].compactMap { $0 }
        attribution = credits.isEmpty ? nil : credits.joined(separator: "\n\n")
        let effect = mask
        working = true
        elapsed = 0
        Task {
            do {
                try await camera.record(seconds: seconds, microphone: music == nil) { result in
                    player?.pause()
                    player = nil
                    working = true
                    Task {
                        defer { working = false }
                        do {
                            let url = try result.get()
                            let edited = try await CameraExport.prepare(url, music: music, mask: effect)
                            preview(edited)
                        } catch { self.error = "Не удалось сохранить запись. " + error.localizedDescription }
                    }
                }
                if let music {
                    player = AVPlayer(url: music)
                    player?.play()
                }
                working = false
            } catch {
                working = false
                self.error = error.localizedDescription
            }
        }
    }

    private func preview(_ url: URL) {
        camera.shutdown()
        movie = url
        player = AVPlayer(url: url)
        player?.play()
    }

    private func reviewActions(_ url: URL) -> some View {
        HStack(spacing: 12) {
            Button("Переснять") {
                player?.pause(); player = nil; movie = nil; gallery = nil
                try? FileManager.default.removeItem(at: url)
                Task { await camera.activate() }
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(.white.opacity(0.13), in: Capsule())
            Button("Готово") {
                player?.pause()
                onReady(url, attribution)
            }.frame(maxWidth: .infinity, minHeight: 46)
                .background(.white, in: Capsule()).foregroundStyle(.black)
        }.buttonStyle(.plain).font(.headline).padding(16)
    }
}

enum CameraMask: Int, CaseIterable, Identifiable {
    case none, sparkles, hearts, cat, space, neon, clouds, retro, butterflies
    var id: Int { rawValue }
    var title: String { ["Без маски", "Искры", "Сердечки", "Кошка", "Космос", "Неон", "Облака", "Ретро", "Бабочки"][rawValue] }
    var icon: String { ["nosign", "sparkles", "heart", "cat", "globe", "bolt", "cloud", "film", "wand.and.stars"][rawValue] }
    static let credit = "Эффекты: Twemoji — Twitter, Inc. и авторы проекта. Графика наложена на видео. CC BY 4.0: https://creativecommons.org/licenses/by/4.0/ • https://github.com/jdecked/twemoji"
    var tracksFace: Bool { [.cat, .sparkles, .hearts, .butterflies].contains(self) }
    private static let artworkByID: [Int: UIImage] = Dictionary(uniqueKeysWithValues: allCases.compactMap { mask in
        guard let url = Bundle.main.url(forResource: "effect-\(mask.id)", withExtension: "png", subdirectory: "CameraMusic"),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        return (mask.id, image)
    })
    var artwork: UIImage? { Self.artworkByID[id] }

    func placement(in viewport: CGRect, face: CGRect?, yIncreasesUp: Bool) -> CGRect? {
        guard !tracksFace || face != nil else { return nil }
        var center = CGPoint(x: viewport.midX, y: viewport.midY)
        var size = viewport.width * 0.19
        if let face, tracksFace {
            let scale = max(face.width, face.height)
            if self == .cat {
                center = CGPoint(x: face.midX, y: face.midY)
                size = scale * 1.2
            } else {
                let left = self == .hearts
                let up: CGFloat = yIncreasesUp ? 1 : -1
                center = CGPoint(x: face.midX + face.width * (left ? -0.55 : 0.55),
                                 y: face.midY + face.height * 0.48 * up)
                size = scale * 0.55
            }
        }
        return CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
    }
}

private struct CameraTrack: Identifiable, Equatable {
    let id: Int
    let title: String
    let duration: String
    var source: String? = nil
    static let catalog = zip(
        ["Медленный свет", "После дождя", "Высота", "Держи ритм", "В этом городе"],
        ["2:48", "3:16", "2:37", "3:04", "2:59"]
    ).enumerated().map { CameraTrack(id: $0.offset, title: $0.element.0, duration: $0.element.1) } + [
        CameraTrack(id: 5, title: "Carefree", duration: "3:25", source: "USUAN1400037"),
        CameraTrack(id: 6, title: "Sneaky Snitch", duration: "2:17", source: "USUAN1100772"),
        CameraTrack(id: 7, title: "Sneaky", duration: "2:31", source: "USUAN1100750")
    ]
    var attribution: String? {
        guard let source else { return nil }
        return "Музыка: \(title) — Kevin MacLeod (incompetech.com). Фрагмент синхронизирован с видео. CC BY 4.0: https://creativecommons.org/licenses/by/4.0/\nhttps://incompetech.com/music/royalty-free/index.html?isrc=\(source)"
    }
    var url: URL? { Bundle.main.url(forResource: "track-\(id)", withExtension: "m4a", subdirectory: "CameraMusic") }
}
