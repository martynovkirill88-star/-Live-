import SwiftUI
import AVFoundation
import Combine

struct ClipsFeed: View {
    let videos: [Video]
    let goHome: () -> Void
    let openCamera: () -> Void
    @EnvironmentObject private var auth: LiveSession
    @State private var index = 0
    @State private var player: AVPlayer?
    @State private var progress = 0.0
    @State private var comments: WatchComments?
    @State private var showingComments = false
    @State private var reaction: Reaction?
    @State private var reacting = false
    @State private var draft = ""
    @State private var message = ""
    @State private var sending = false
    private let ticker = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()
    private var clip: Video? { videos.isEmpty ? nil : videos[min(index, videos.count - 1)] }
    private struct Reaction: Decodable { let liked: Bool; let likes: Int }
    private struct WriteReceipt: Decodable { let ok: Bool? }

    var body: some View {
        ZStack {
            Color.black
            if let clip {
                if let poster = remote(clip.poster) {
                    GeometryReader { geometry in
                        AsyncImage(url: poster) { image in image.resizable().scaledToFill() }
                            placeholder: { Color.black }
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    }
                }
                if let player { ClipVideoSurface(player: player) }
                LinearGradient(colors: [.black.opacity(0.48), .clear, .clear, .black.opacity(0.88)],
                               startPoint: .top, endPoint: .bottom).allowsHitTesting(false)
                VStack {
                    header
                    Spacer()
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(clip.channel).font(.headline)
                            Text(clip.title).font(.subheadline).lineLimit(2)
                            Label("Звук видео", systemImage: "music.note").font(.caption2.bold())
                        }
                        Spacer()
                        actions(clip)
                    }
                    ProgressView(value: progress).tint(.white)
                }.padding(16)
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
        .gesture(DragGesture(minimumDistance: 35).onEnded { gesture in
            let y = gesture.translation.height
            guard abs(y) > abs(gesture.translation.width), abs(y) > 45 else { return }
            index = max(0, min(max(0, videos.count - 1), index + (y < 0 ? 1 : -1)))
        })
        .task(id: clip?.id) {
            player?.pause()
            progress = 0
            comments = nil
            reaction = nil
            draft = ""
            message = ""
            guard let clip, let url = remote(clip.manifest) else { player = nil; return }
            let current = AVPlayer(url: url)
            player = current
            current.play()
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
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notice in
            if let item = notice.object as? AVPlayerItem, item === player?.currentItem {
                player?.seek(to: .zero)
                player?.play()
            }
        }
        .onDisappear { player?.pause() }
        .sheet(isPresented: $showingComments) {
            if let clip {
                commentPanel(clip)
                    .presentationDetents([.fraction(0.59), .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var header: some View {
        HStack {
            Button(action: goHome) { Image(systemName: "house").frame(width: 30, height: 44) }
                .accessibilityLabel("Главная")
            Text("Лента").font(.title.bold())
            Spacer()
            Button(action: openCamera) { Image(systemName: "video").frame(width: 44, height: 44) }
                .accessibilityLabel("Снять видео")
        }.buttonStyle(.plain)
    }

    private func actions(_ clip: Video) -> some View {
        VStack(spacing: 14) {
            Button {
                guard auth.requireLogin(), !reacting else { return }
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
            ShareLink(item: origin.appendingPathComponent("watch").appendingPathComponent(clip.id)) {
                actionLabel("square.and.arrow.up", nil)
            }.accessibilityLabel("Поделиться")
        }.buttonStyle(.plain)
    }

    private func actionLabel(_ icon: String, _ count: Int?) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 24))
            if let count { Text(count.formatted()).font(.caption2.bold()) }
        }.frame(minWidth: 44, minHeight: 38)
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
                                Text(entry.name).font(.caption.bold())
                                Text(entry.body).font(.subheadline)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            if comments?.enabled != false && clip.comments_enabled != false {
                HStack(spacing: 10) {
                    TextField("Написать комментарий…", text: $draft)
                    Button {
                        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !body.isEmpty, !sending else { return }
                        if auth.account == nil { showingComments = false; _ = auth.requireLogin(); return }
                        sending = true
                        Task {
                            defer { sending = false }
                            do {
                                let _: WriteReceipt = try await request(endpoint(clip) + "/comments", method: "POST", json: ["body": body])
                                draft = ""
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
