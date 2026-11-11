import SwiftUI
import WebKit
import CoreText

private let appBackground = Color(red: 0.047, green: 0.071, blue: 0.067)
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
    init() {
        if let font = Bundle.main.url(forResource: "DelaGothicOne-Regular", withExtension: "ttf", subdirectory: "Player") {
            CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
        }
    }
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
                    Text("C").font(.title3.bold()).foregroundStyle(appBackground)
                        .frame(width: 34, height: 34).background(lime, in: Circle())
                    Text("Чепушка Live").font(.custom("DelaGothicOne-Regular", size: 17))
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
                                                .foregroundStyle(filter == value ? appBackground : .white)
                                                .background(filter == value ? lime : surface, in: RoundedRectangle(cornerRadius: 10))
                                        }
                                    }
                                }
                            }
                        }
                        Text(tab == "Главная" ? "Для вас" : tab == "Профиль" ? "Сохранённое" : tab)
                            .font(.custom("DelaGothicOne-Regular", size: 23))
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
            .background(appBackground.ignoresSafeArea())
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
                        .foregroundStyle(video.live ? appBackground : .white)
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
                    Text(channel.profile.name).font(.custom("DelaGothicOne-Regular", size: 24))
                    Text("\(channel.subscribers) подписчиков · \(channel.videos.count) видео")
                        .font(.subheadline).foregroundStyle(lime)
                    if let text = channel.profile.about, !text.isEmpty {
                        Text(text).foregroundStyle(.secondary).font(.subheadline)
                    }
                    HStack {
                        Button(subscribed ? "✓  Вы подписаны" : "Подписаться") {
                            if !subscribed { followed = (followed.isEmpty ? "" : followed + ",") + id }
                        }.buttonStyle(.borderedProminent).tint(subscribed ? surface : lime)
                            .foregroundStyle(subscribed ? lime : appBackground)
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
        .background(appBackground.ignoresSafeArea())
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
    @State private var expandedDescription = false
    var body: some View {
        ScrollView {
            WebsitePlayer(video: video).aspectRatio(16 / 9, contentMode: .fit)
            VStack(alignment: .leading, spacing: 14) {
                Text(video.title).font(.title2.bold())
                Text(video.live ? "Прямой эфир" : "\(video.views ?? 0) просмотров").font(.caption).foregroundStyle(.secondary)
                if let description = video.description, !description.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(expandedDescription ? nil : 2)
                        if description.count > 56 || description.contains("\n") {
                            Button(expandedDescription ? "Свернуть" : "Ещё") {
                                expandedDescription.toggle()
                            }.font(.subheadline.weight(.semibold))
                        }
                    }
                }
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
                    NavigationLink(value: Route.video(next)) {
                        HStack(alignment: .top, spacing: 12) {
                            Artwork(path: next.poster)
                                .frame(width: 132, height: 74)
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(next.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                Text(next.channel).font(.caption).foregroundStyle(.secondary)
                                Text("\(next.views ?? 0) просмотров").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }.buttonStyle(.plain)
                }
            }.padding(16)
        }
        .background(appBackground.ignoresSafeArea())
        .navigationTitle("Сейчас смотрите")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
}


private struct WebsitePlayer: UIViewRepresentable {
    let video: Video

    func makeCoordinator() -> Coordinator { Coordinator(video: video) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        if #available(iOS 16.0, *) {
            config.preferences.isElementFullscreenEnabled = true
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        if let page = Bundle.main.url(forResource: "player", withExtension: "html", subdirectory: "Player") {
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        } else {
            webView.loadHTMLString("<p>Не удалось загрузить плеер.</p>", baseURL: nil)
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.evaluateJavaScript("window.activePlayer?.destroy()", completionHandler: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let video: Video

        init(video: Video) { self.video = video }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard webView.url?.isFileURL == true else { return }
            guard let manifest = remote(video.manifest) else {
                webView.evaluateJavaScript("document.getElementById('player').textContent='Видео пока недоступно';document.body.style.color='white';", completionHandler: nil)
                return
            }
            let item: [String: Any] = [
                "id": video.id,
                "manifest": manifest.absoluteString,
                "poster": remote(video.poster)?.absoluteString ?? "",
                "origin": "https://live.chepushkavpn.fun",
                "live": video.live,
                "duration": video.duration ?? 0,
                "qualities": (video.qualities ?? []).map { ["code": $0.code, "height": $0.height] as [String: Any] }
            ]
            webView.callAsyncJavaScript("window.mountBundledPlayer(item)", arguments: ["item": item],
                                        in: nil, in: .page) { result in
                if case .failure = result {
                    webView.evaluateJavaScript("document.getElementById('player').textContent='Не удалось запустить плеер';document.body.style.color='white';", completionHandler: nil)
                }
            }
        }
    }
}

