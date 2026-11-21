import SwiftUI
import AVFoundation
import Combine
import Photos

struct ClipsFeed: View {
    let videos: [Video]
    let goHome: () -> Void
    let openCamera: (() -> Void)?
    let signedIn: Bool
    let requireLogin: () -> Bool
    let ownedChannelID: String?
    var cameraPresented = false
    var initialClipID: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedClipID: String?
    @State private var pagingForward = true
    @State private var replyTo: WatchComments.Entry?
    @State private var savingVideo = false
    @State private var shareNotice: String?
    @State private var player: AVPlayer?
    @State private var playbackClipID: String?
    @State private var pausedByUser = false
    @State private var viewedClipID: String?
    @State private var viewCount: Int?
    @State private var progress = 0.0
    @State private var comments: WatchComments?
    @State private var showingComments = false
    @State private var reaction: Reaction?
    @State private var reacting = false
    @State private var draft = ""
    @State private var message = ""
    @State private var sending = false
    private let ticker = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()
    private var clipIndex: Int {
        videos.firstIndex { $0.id == (selectedClipID ?? initialClipID) } ?? 0
    }
    private var clip: Video? { videos.isEmpty ? nil : videos[clipIndex] }
    private struct Reaction: Decodable { let liked: Bool; let likes: Int }
    private struct WriteReceipt: Decodable { let ok: Bool? }
    private struct ViewReceipt: Decodable { let views: Int }

    private var clipTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(insertion: .move(edge: pagingForward ? .bottom : .top),
                           removal: .move(edge: pagingForward ? .top : .bottom))
    }

    var body: some View {
        ZStack {
            Color.black
            if let clip {
                ZStack {
                    if let poster = remote(clip.poster) {
                        GeometryReader { geometry in
                            AsyncImage(url: poster) { image in image.resizable().scaledToFill() }
                                placeholder: { Color.black }
                                .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        }
                    }
                    if let player, playbackClipID == clip.id { ClipVideoSurface(player: player) }
                    LinearGradient(colors: [.black.opacity(0.48), .clear, .clear, .black.opacity(0.88)],
                                   startPoint: .top, endPoint: .bottom).allowsHitTesting(false)
                    if let player, playbackClipID == clip.id {
                        Button {
                            pausedByUser.toggle()
                            updatePlayback(player)
                        } label: {
                            Color.clear.overlay {
                                if pausedByUser {
                                    Image(systemName: "play.fill").font(.system(size: 27, weight: .semibold))
                                        .frame(width: 64, height: 64)
                                        .background(.black.opacity(0.56), in: Circle())
                                }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityLabel(pausedByUser ? "Продолжить клип" : "Поставить клип на паузу")
                    }
                    VStack {
                        header
                        Spacer()
                        HStack(alignment: .bottom) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(clip.channel).font(.headline)
                                Text(clip.title).font(.subheadline).lineLimit(2)
                                ClipViewsLabel(count: viewCount ?? clip.views ?? 0).font(.caption)
                                Label("Звук видео", systemImage: "music.note").font(.caption2.bold())
                            }
                            Spacer()
                            actions(clip).padding(.bottom, 42)
                        }
                        ProgressView(value: progress).tint(.white)
                    }.padding(16)
                }
                .id(clip.id)
                .transition(clipTransition)
            } else {
                VStack {
                    header
                    Spacer()
                    Text("Коротких видео пока нет").foregroundStyle(.secondary)
                    Spacer()
                }.padding(16)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 35).onEnded { gesture in
            let y = gesture.translation.height
            guard abs(y) > abs(gesture.translation.width), abs(y) > 45 else { return }
            let next = clipIndex + (y < 0 ? 1 : -1)
            guard videos.indices.contains(next) else { return }
            pagingForward = y < 0
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.28)) {
                selectedClipID = videos[next].id
            }
        })
        .task(id: clip?.id) {
            player?.pause()
            playbackClipID = nil
            progress = 0
            pausedByUser = false
            viewedClipID = nil
            viewCount = nil
            comments = nil
            reaction = nil
            draft = ""
            replyTo = nil
            message = ""
            guard let clip, let quality = clip.portraitQuality, let manifest = remote(clip.manifest),
                  var url = URLComponents(url: manifest, resolvingAgainstBaseURL: false) else {
                player = nil
                return
            }
            selectedClipID = clip.id
            url.queryItems = [URLQueryItem(name: "quality", value: quality.code)]
            guard let stream = url.url else { player = nil; return }
            let current = AVPlayer(url: stream)
            player = current
            playbackClipID = clip.id
            updatePlayback(current)
            async let social: Reaction? = try? request(endpoint(clip) + "/social")
            async let thread: WatchComments? = try? request(endpoint(clip) + "/comments")
            let (latestReaction, latestComments) = await (social, thread)
            if !Task.isCancelled {
                if reaction == nil { reaction = latestReaction }
                if comments == nil { comments = latestComments }
            }
        }
        .onReceive(ticker) { _ in
            guard let player, let item = player.currentItem else { return }
            let duration = item.duration.seconds, elapsed = player.currentTime().seconds
            if duration.isFinite && duration > 0 && elapsed.isFinite { progress = min(1, max(0, elapsed / duration)) }
            if elapsed.isFinite, elapsed > 0, let clip, playbackClipID == clip.id, viewedClipID == nil {
                viewedClipID = clip.id
            }
        }
        .task(id: viewedClipID) {
            guard let clip, viewedClipID == clip.id else { return }
            let receipt: ViewReceipt? = try? await request(endpoint(clip) + "/view", method: "POST", json: [:])
            if !Task.isCancelled, viewedClipID == clip.id { viewCount = receipt?.views }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notice in
            if let player, let item = notice.object as? AVPlayerItem, item === player.currentItem {
                player.seek(to: .zero)
                updatePlayback(player)
            }
        }
        .onChange(of: cameraPresented) { _ in
            if let player { updatePlayback(player) }
        }
        .onDisappear { player?.pause() }
        .alert("Поделиться", isPresented: Binding(
            get: { shareNotice != nil }, set: { if !$0 { shareNotice = nil } }
        )) {
            Button("OK") { shareNotice = nil }
        } message: { Text(shareNotice ?? "") }
        .sheet(isPresented: $showingComments) {
            if let clip {
                commentPanel(clip)
                    .presentationDetents([.fraction(0.59), .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private func updatePlayback(_ player: AVPlayer) {
        if pausedByUser || cameraPresented { player.pause() }
        else { player.play() }
    }

    private var header: some View {
        HStack {
            Button(action: goHome) { Image(systemName: "house").frame(width: 30, height: 44) }
                .accessibilityLabel("Главная")
            Text("Лента").font(.title.bold())
            Spacer()
            if let openCamera {
                Button(action: openCamera) { Image(systemName: "video").frame(width: 44, height: 44) }
                    .accessibilityLabel("Снять видео")
            }
        }.buttonStyle(.plain)
    }

    private func actions(_ clip: Video) -> some View {
        VStack(spacing: 14) {
            Button {
                guard requireLogin(), !reacting else { return }
                reacting = true
                Task {
                    defer { reacting = false }
                    let result: Reaction? = try? await request(endpoint(clip) + "/like", method: "POST", json: [:])
                    if self.clip?.id == clip.id, let result { reaction = result }
                }
            } label: {
                actionLabel(reaction?.liked == true ? "heart.fill" : "heart", reaction?.likes)
            }.accessibilityLabel("Нравится")
            Button { showingComments = true } label: {
                actionLabel("bubble", comments?.total)
            }.accessibilityLabel("Комментарии")
            let link = origin.appendingPathComponent("watch").appendingPathComponent(clip.id)
            if let channel = clip.channel_id, ownedChannelID == channel {
                Menu {
                    Button {
                        UIPasteboard.general.url = link
                        shareNotice = "Ссылка скопирована."
                    } label: { Label("Копировать ссылку", systemImage: "link") }
                    Button {
                        Task { await saveVideo(clip) }
                    } label: { Label("Скачать видео", systemImage: "arrow.down.to.line") }
                        .disabled(savingVideo)
                } label: {
                    if savingVideo { ProgressView().frame(width: 52, height: 48) }
                    else { actionLabel("square.and.arrow.up", nil) }
                }.accessibilityLabel("Поделиться")
            } else {
                ShareLink(item: link) { actionLabel("square.and.arrow.up", nil) }
                    .accessibilityLabel("Поделиться")
            }
        }.buttonStyle(.plain)
    }

    @MainActor private func saveVideo(_ clip: Video) async {
        guard !savingVideo, let url = remote("/api/admin/media/" + clip.id + "/download-clip") else { return }
        savingVideo = true
        defer { savingVideo = false }
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            shareNotice = "Разрешите приложению добавлять видео в «Фото» в настройках iPhone."
            return
        }
        do {
            let request = URLRequest(url: url, timeoutInterval: 300)
            let (download, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.mimeType == "video/mp4" else {
                throw ServerError(status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                                  message: "Не удалось скачать клип. Проверьте вход и повторите.")
            }
            let movie = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
            try FileManager.default.moveItem(at: download, to: movie)
            defer { try? FileManager.default.removeItem(at: movie) }
            do {
                try await addToPhotos(movie)
            } catch {
                let conventional = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + ".mov")
                defer { try? FileManager.default.removeItem(at: conventional) }
                guard let export = AVAssetExportSession(asset: AVURLAsset(url: movie),
                                                         presetName: AVAssetExportPresetPassthrough) else { throw error }
                export.outputURL = conventional
                export.outputFileType = .mov
                await export.export()
                guard export.status == .completed else { throw export.error ?? error }
                try await addToPhotos(conventional)
            }
            shareNotice = "Клип сохранён в «Фото»."
        } catch {
            shareNotice = error.localizedDescription
        }
    }

    private func addToPhotos(_ movie: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: movie)
        }
    }

    private func actionLabel(_ icon: String, _ count: Int?) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 29, weight: .semibold))
            if let count { Text(count.formatted()).font(.caption2.bold()) }
        }.frame(minWidth: 52, minHeight: 48).contentShape(Rectangle())
    }

    private func commentPanel(_ clip: Video) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Комментарии").font(.headline)
                if let comments { Text(comments.total.formatted()).font(.caption.bold()).foregroundStyle(.secondary) }
                Spacer()
                Button { showingComments = false } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 36)
                }.buttonStyle(.plain).accessibilityLabel("Закрыть комментарии")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let comments, comments.items.isEmpty { Text("Пока нет комментариев").foregroundStyle(.secondary) }
                    ForEach(comments?.items ?? []) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            Text(String(entry.name.prefix(1)).uppercased()).font(.caption.bold())
                                .frame(width: 34, height: 34).background(.white.opacity(0.15), in: Circle())
                            VStack(alignment: .leading, spacing: 3) {
                                CommentAuthorLine(entry: entry)
                                Text(entry.body).font(.subheadline)
                                if comments?.enabled != false && clip.comments_enabled != false {
                                    Button("Ответить") { replyTo = entry }.font(.caption)
                                }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            if comments?.enabled != false && clip.comments_enabled != false {
                if let replyTo {
                    HStack {
                        Text("Ответ для " + replyTo.name).font(.caption)
                        Spacer()
                        Button("Отменить") { self.replyTo = nil }.font(.caption)
                    }
                }
                HStack(spacing: 10) {
                    TextField("Написать комментарий…", text: $draft)
                    Button {
                        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !body.isEmpty, !sending else { return }
                        if !signedIn { showingComments = false; _ = requireLogin(); return }
                        sending = true
                        Task {
                            defer { sending = false }
                            do {
                                var payload: [String: Any] = ["body": body]
                                if let replyTo { payload["parent_id"] = replyTo.id }
                                let _: WriteReceipt = try await request(endpoint(clip) + "/comments", method: "POST", json: payload)
                                draft = ""
                                replyTo = nil
                                comments = try await request(endpoint(clip) + "/comments")
                            } catch { message = error.localizedDescription }
                        }
                    } label: { Image(systemName: "arrow.up").tint(.red) }
                        .accessibilityLabel("Отправить комментарий")
                        .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(12).background(.white.opacity(0.09), in: Capsule())
            }
        }
        .padding(16)
        .background(Color(red: 0.06, green: 0.075, blue: 0.08).ignoresSafeArea())
        .task {
            do { comments = try await request(endpoint(clip) + "/comments") }
            catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }

    private func endpoint(_ clip: Video) -> String { "/api/media/" + clip.id }
}

struct ClipViewsLabel: View {
    let count: Int

    var body: some View {
        Label {
            Text(count.formatted())
        } icon: {
            Image(systemName: "eye")
        }.accessibilityLabel("Просмотры: \(count.formatted())")
    }
}

private struct ClipVideoSurface: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ view: Surface, context: Context) { view.playerLayer.player = player }
    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}


struct CommentAuthorLine: View {
    let entry: WatchComments.Entry

    var body: some View {
        HStack(spacing: 6) {
            Text(entry.name).font(.caption.bold())
            if entry.is_author == true {
                Text("Автор").font(.caption2.bold())
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.white.opacity(0.12), in: Capsule())
            }
        }
        if let name = entry.reply_to {
            Text("Ответ для " + name).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
