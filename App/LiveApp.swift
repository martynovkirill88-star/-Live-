import SwiftUI
import AVKit

private let background = Color(red: 0.047, green: 0.071, blue: 0.067)
private let surface = Color(red: 0.106, green: 0.161, blue: 0.145)
private let lime = Color(red: 0.792, green: 0.98, blue: 0.459)
private let origin = URL(string: "https://live.chepushkavpn.fun/")!

private struct Video: Decodable, Identifiable, Hashable {
    struct Quality: Decodable, Hashable {
        let code: String
        let height: Int
    }
    let id, title, channel: String
    let channel_id, channel_avatar, poster, manifest, description: String?
    let duration: Double?
    let views: Int?
    let live: Bool
    let qualities: [Quality]?
}
private struct Catalog: Decodable { let items: [Video] }
private struct Channel: Decodable {
    struct Profile: Decodable { let name: String; let avatar, about: String? }
    let profile: Profile
    let subscribers: Int
    let videos: [Video]
}
private enum Route: Hashable { case video(Video), channel(String) }

private func remote(_ path: String?) -> URL? {
    guard let path, !path.isEmpty, let url = URL(string: path, relativeTo: origin)?.absoluteURL,
          url.scheme == "https", url.host == origin.host else { return nil }
    return url
}

private func request<T: Decodable>(_ path: String) async throws -> T {
    guard let url = remote(path) else { throw URLError(.badURL) }
    let (data, response) = try await URLSession.shared.data(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    return try JSONDecoder().decode(T.self, from: data)
}

private func clock(_ seconds: Double) -> String {
    let value = seconds.isFinite ? Int(max(0, seconds)) : 0
    return String(format: "%d:%02d", value / 60, value % 60)
}

@main
struct ChepushkaLiveApp: App {
    var body: some Scene {
        WindowGroup { Home().preferredColorScheme(.dark).tint(lime) }
    }
}

private struct Artwork: View {
    let path: String?
    var body: some View {
        GeometryReader { geometry in
            AsyncImage(url: remote(path)) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    surface.overlay(Image(systemName: "play.rectangle").foregroundStyle(.secondary))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .accessibilityHidden(true)
    }
}

private struct Home: View {
    @State private var videos: [Video] = []
    @State private var failure = false
    @State private var tab = "Главная"
    @State private var filter = "Всё"
    @State private var search = false
    @State private var query = ""
    @State private var path: [Route] = []
    @AppStorage("followedChannels") private var followed = ""
    @AppStorage("savedVideos") private var saved = ""
    private var visible: [Video] {
        videos.filter { video in
            let title = video.title + " " + (video.description ?? "")
            if !query.isEmpty && !title.localizedCaseInsensitiveContains(query) { return false }
            switch tab {
            case "Эфиры": return video.live
            case "Подписки": return followed.split(separator: ",").contains { String($0) == video.channel_id }
            case "Профиль": return saved.split(separator: ",").contains { String($0) == video.id }
            default:
                switch filter {
                case "В эфире": return video.live
                case "Музыка": return title.localizedCaseInsensitiveContains("музык")
                case "Путешествия": return title.localizedCaseInsensitiveContains("путешеств")
                default: return true
                }
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                HStack {
                    Text("C").font(.title3.bold()).foregroundStyle(background)
                        .frame(width: 34, height: 34).background(lime, in: Circle())
                    Text("Чепушка Live").font(.headline.weight(.black))
                    Spacer()
                    Button { search.toggle(); if !search { query = "" } } label: {
                        Image(systemName: "magnifyingglass").frame(width: 44, height: 44)
                    }.accessibilityLabel("Поиск")
                }.padding(.horizontal, 16)
                if search {
                    TextField("Поиск видео", text: $query).textFieldStyle(.roundedBorder).padding(16)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if tab == "Главная" {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(["Всё", "В эфире", "Музыка", "Путешествия"], id: \.self) { value in
                                        Button { filter = value } label: {
                                            Text(value).font(.subheadline).padding(.horizontal, 14)
                                                .padding(.vertical, 9)
                                                .foregroundStyle(filter == value ? background : .white)
                                                .background(filter == value ? lime : surface, in: RoundedRectangle(cornerRadius: 10))
                                        }
                                    }
                                }
                            }
                        }
                        Text(tab == "Главная" ? "Для вас" : tab == "Профиль" ? "Сохранённое" : tab)
                            .font(.title2.weight(.black))
                        if failure {
                            Button("Не удалось загрузить каталог. Повторить") { Task { await load() } }
                        } else if visible.isEmpty {
                            Text(videos.isEmpty ? "Загружаем каталог…" : "Здесь пока нет видео").foregroundStyle(.secondary)
                        }
                        ForEach(visible) { video in
                            NavigationLink(value: Route.video(video)) { FeedCard(video: video) }
                                .buttonStyle(.plain)
                        }
                    }.padding(16)
                }.refreshable { await load() }
                HStack {
                    tabButton("Главная", "house")
                    tabButton("Эфиры", "dot.radiowaves.left.and.right")
                    tabButton("Подписки", "play.rectangle.on.rectangle")
                    tabButton("Профиль", "person.crop.circle")
                }.padding(.vertical, 8).background(surface)
            }
            .background(background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .video(let video): Watch(video: video, others: videos.filter { $0.id != video.id })
                case .channel(let id): ChannelScreen(id: id)
                }
            }
            .task { await load() }
        }
    }

    private func tabButton(_ title: String, _ icon: String) -> some View {
        Button { tab = title; query = ""; search = false } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 20))
                Text(title).font(.caption2)
            }.frame(maxWidth: .infinity, minHeight: 44)
        }.foregroundStyle(tab == title ? lime : .secondary)
    }

    private func load() async {
        failure = false
        do { let catalog: Catalog = try await request("/api/catalog"); videos = catalog.items }
        catch { failure = true }
    }
}

private struct FeedCard: View {
    let video: Video
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Artwork(path: video.poster).aspectRatio(16 / 9, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) {
                    Text(video.live ? "В ЭФИРЕ" : clock(video.duration ?? 0))
                        .font(.caption.bold()).padding(6)
                        .foregroundStyle(video.live ? background : .white)
                        .background(video.live ? lime : .black.opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
                        .padding(9)
                }.clipShape(RoundedRectangle(cornerRadius: 15))
            HStack(alignment: .top, spacing: 12) {
                Artwork(path: video.channel_avatar).frame(width: 36, height: 36).clipShape(Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.title).font(.headline)
                    Text("\(video.channel) · \(video.views ?? 0) просмотров")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ChannelScreen: View {
    let id: String
    @State private var channel: Channel?
    @State private var failure = false
    @State private var about = false
    @AppStorage("followedChannels") private var followed = ""
    private var subscribed: Bool { followed.split(separator: ",").contains(Substring(id)) }

    var body: some View {
        ScrollView {
            if let channel {
                VStack(alignment: .leading, spacing: 14) {
                    Artwork(path: channel.videos.first?.poster).frame(height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(alignment: .bottomLeading) {
                            Artwork(path: channel.profile.avatar).frame(width: 64, height: 64)
                                .clipShape(Circle()).offset(x: 14, y: 30)
                        }.padding(.bottom, 28)
                    Text(channel.profile.name).font(.title.weight(.black))
                    Text("\(channel.subscribers) подписчиков · \(channel.videos.count) видео")
                        .font(.subheadline).foregroundStyle(lime)
                    if let text = channel.profile.about, !text.isEmpty {
                        Text(text).foregroundStyle(.secondary).font(.subheadline)
                    }
                    HStack {
                        Button(subscribed ? "✓  Вы подписаны" : "Подписаться") {
                            if !subscribed { followed = (followed.isEmpty ? "" : followed + ",") + id }
                        }.buttonStyle(.borderedProminent).tint(subscribed ? surface : lime)
                            .foregroundStyle(subscribed ? lime : background)
                        if subscribed {
                            Button("Отписаться") {
                                followed = followed.split(separator: ",").filter { $0 != Substring(id) }.joined(separator: ",")
                            }.buttonStyle(.bordered)
                        }
                    }
                    HStack(spacing: 24) {
                        Button("Видео") { about = false }.foregroundStyle(about ? .secondary : lime)
                        Button("О канале") { about = true }.foregroundStyle(about ? lime : .secondary)
                    }.padding(.vertical, 8)
                    Divider()
                    if about {
                        Text(channel.profile.about ?? "Описание пока не добавлено.")
                    } else {
                        ForEach(channel.videos) { video in
                            NavigationLink(value: Route.video(video)) {
                                HStack(alignment: .top) {
                                    Artwork(path: video.poster).frame(width: 110, height: 62)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(video.title).font(.subheadline.bold()).lineLimit(2)
                                        Text("\(video.views ?? 0) просмотров").font(.caption).foregroundStyle(.secondary)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(16)
            } else if failure {
                Button("Не удалось открыть канал. Повторить") { Task { await load() } }.padding()
            } else { ProgressView().padding() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background.ignoresSafeArea())
        .navigationTitle(channel?.profile.name ?? "Канал")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await load() }
    }
    private func load() async {
        failure = false
        do { channel = try await request("/api/channels/" + id) }
        catch { failure = true }
    }
}

private struct Watch: View {
    let video: Video
    var others: [Video] = []
    @AppStorage("savedVideos") private var saved = ""
    @State private var liked = false
    var body: some View {
        ScrollView {
            LocalPlayer(video: video)
            VStack(alignment: .leading, spacing: 14) {
                Text(video.title).font(.title2.bold())
                Text(video.live ? "Прямой эфир" : "\(video.views ?? 0) просмотров").font(.caption).foregroundStyle(.secondary)
                if let description = video.description { Text(description).font(.subheadline).foregroundStyle(.secondary) }
                if let id = video.channel_id {
                    NavigationLink(value: Route.channel(id)) {
                        HStack {
                            Artwork(path: video.channel_avatar).frame(width: 40, height: 40).clipShape(Circle())
                            Text(video.channel).font(.headline)
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                    }.buttonStyle(.plain)
                }
                HStack {
                    Button { liked.toggle() } label: {
                        Label("Нравится", systemImage: liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                    }
                    ShareLink(item: origin.appendingPathComponent("watch").appendingPathComponent(video.id)) {
                        Label("Поделиться", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        var ids = saved.split(separator: ",").map(String.init)
                        if let index = ids.firstIndex(of: video.id) { ids.remove(at: index) }
                        else { ids.append(video.id) }
                        saved = ids.joined(separator: ",")
                    } label: {
                        Image(systemName: saved.split(separator: ",").contains(Substring(video.id)) ? "bookmark.fill" : "bookmark")
                    }.accessibilityLabel("Сохранить")
                }.buttonStyle(.bordered)
                if !others.isEmpty { Text("Далее").font(.headline) }
                ForEach(others) { next in
                    NavigationLink(value: Route.video(next)) { FeedCard(video: next) }.buttonStyle(.plain)
                }
            }.padding(16)
        }
        .background(background.ignoresSafeArea())
        .navigationTitle("Сейчас смотрите")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}

private struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
    }
    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        view.backgroundColor = .black
        (view.layer as? AVPlayerLayer)?.player = player
        return view
    }
    func updateUIView(_ view: Surface, context: Context) {
        (view.layer as? AVPlayerLayer)?.player = player
    }
}

private struct LocalPlayer: View {
    let video: Video
    @State private var player = AVPlayer()
    @State private var started = false
    @State private var playing = false
    @State private var muted = false
    @State private var position = 0.0
    @State private var editing = false
    @State private var full = false
    @State private var quality = "auto"
    @State private var error = false
    private let ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        controls.aspectRatio(16 / 9, contentMode: .fit)
            .fullScreenCover(isPresented: $full) {
                controls.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.ignoresSafeArea())
            }
            .onReceive(ticker) { _ in
                if !editing {
                    let time = player.currentTime().seconds
                    if time.isFinite { position = min(max(time, 0), max(video.duration ?? 0, 1)) }
                }
                if player.currentItem?.status == .failed { error = true; playing = false }
                if !video.live, let duration = video.duration, duration > 0,
                   position >= duration - 0.25, player.timeControlStatus == .paused {
                    playing = false
                }
            }
            .onDisappear { if !full { player.pause(); playing = false } }
    }

    private var controls: some View {
        ZStack {
            if started { PlayerSurface(player: player) }
            else { Artwork(path: video.poster) }
            if playing && player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                ProgressView().offset(y: -42)
            }
            if error {
                Button("Повторить загрузку") { load(autoplay: true) }
                    .buttonStyle(.borderedProminent)
            } else {
                HStack(spacing: 22) {
                    if !video.live { control("gobackward.10", "Назад на 10 секунд") { seek(position - 10) } }
                    control(playing ? "pause.fill" : "play.fill", playing ? "Пауза" : "Смотреть") {
                        if !started { load(autoplay: true) }
                        else if playing { player.pause(); playing = false }
                        else { player.play(); playing = true }
                    }
                    if !video.live { control("goforward.10", "Вперёд на 10 секунд") { seek(position + 10) } }
                }
            }
            VStack {
                Spacer()
                HStack {
                    Text(video.live ? "Прямой эфир" : "\(clock(position)) / \(clock(video.duration ?? 0))")
                        .font(.caption.monospacedDigit())
                    Spacer()
                    Button {
                        muted.toggle()
                        player.isMuted = muted
                    } label: {
                        Image(systemName: muted ? "speaker.slash" : "speaker.wave.2")
                    }.accessibilityLabel("Звук")
                    Menu {
                        Button("Авто") { selectQuality("auto") }
                        ForEach((video.qualities ?? []).sorted { $0.height > $1.height }, id: \.code) { option in
                            Button("\(option.height)p") { selectQuality(option.code) }
                        }
                    } label: {
                        Text(quality == "auto" ? "Авто" : "\(video.qualities?.first { $0.code == quality }?.height ?? 0)p")
                    }.accessibilityLabel("Качество")
                    Button { full.toggle() } label: {
                        Image(systemName: full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }.accessibilityLabel(full ? "Закрыть полный экран" : "Полный экран")
                }.padding(.bottom, 5)
                if !video.live, let duration = video.duration, duration > 0 {
                    Slider(value: $position, in: 0...duration) { active in
                        editing = active
                        if !active { seek(position) }
                    }.accessibilityLabel("Позиция видео")
                }
            }.padding(12).background(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            }
        }.foregroundStyle(.white).background(.black)
    }

    private func control(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(width: 48, height: 48).background(.black.opacity(0.62), in: Circle())
        }.accessibilityLabel(label)
    }

    private func selectQuality(_ value: String) {
        quality = value
        if started { load(autoplay: playing) }
    }

    private func load(autoplay: Bool) {
        guard let url = remote(video.manifest), var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            error = true
            return
        }
        parts.queryItems = (parts.queryItems ?? []).filter { $0.name != "quality" } + [URLQueryItem(name: "quality", value: quality)]
        guard let source = parts.url else { error = true; return }
        error = false
        started = true
        player.replaceCurrentItem(with: AVPlayerItem(url: source))
        if !video.live && position > 0 { seek(position) }
        playing = autoplay
        if autoplay { player.play() }
    }

    private func seek(_ time: Double) {
        position = min(max(time, 0), video.duration ?? 0)
        if started { player.seek(to: CMTime(seconds: position, preferredTimescale: 600)) }
    }
}
