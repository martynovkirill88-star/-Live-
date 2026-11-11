import SwiftUI
import WebKit
import CoreText
import UniformTypeIdentifiers
import PhotosUI

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

private struct ServerError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

private func request<T: Decodable>(
    _ path: String, method: String = "GET", json: [String: Any]? = nil,
    bytes: Data? = nil, headers: [String: String] = [:]
) async throws -> T {
    guard let url = remote(path) else { throw URLError(.badURL) }
    var call = URLRequest(url: url)
    call.httpMethod = method
    call.timeoutInterval = 60
    if let json {
        call.httpBody = try JSONSerialization.data(withJSONObject: json)
        call.setValue("application/json", forHTTPHeaderField: "Content-Type")
    } else { call.httpBody = bytes }
    for (key, value) in headers { call.setValue(value, forHTTPHeaderField: key) }
    let (data, response) = try await URLSession.shared.data(for: call)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
        let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["error"]
        let message = status == 401 ? "Войдите через Telegram." :
            detail ?? (String(data: data.prefix(300), encoding: .utf8).flatMap { $0.contains("<") || $0.isEmpty ? nil : $0 } ?? "Ошибка сервера: \(status)")
        throw ServerError(status: status, message: message)
    }
    return try JSONDecoder().decode(T.self, from: data)
}
private func clock(_ seconds: Double) -> String {
    let value = seconds.isFinite ? Int(max(0, seconds)) : 0
    return String(format: "%d:%02d", value / 60, value % 60)
}

@main
struct ChepushkaLiveApp: App {
    @UIApplicationDelegateAdaptor(OrientationDelegate.self) private var orientationDelegate
    @StateObject private var auth = LiveSession()
    init() {
        if let font = Bundle.main.url(forResource: "DelaGothicOne-Regular", withExtension: "ttf", subdirectory: "Player") {
            CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
        }
    }
    var body: some Scene {
        WindowGroup { Home().environmentObject(auth).preferredColorScheme(.dark).tint(lime).task { await auth.refresh() }.sheet(isPresented: $auth.showLogin) { TelegramSignIn().environmentObject(auth) } }
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
                if tab == "Профиль" { CreatorHome() } else {
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
                }
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
    @EnvironmentObject private var auth: LiveSession
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
                            guard auth.requireLogin() else { return }
                            if !subscribed { followed = (followed.isEmpty ? "" : followed + ",") + id }
                        }.buttonStyle(.borderedProminent).tint(subscribed ? surface : lime)
                            .foregroundStyle(subscribed ? lime : appBackground)
                        if subscribed {
                            Button("Отписаться") {
                                guard auth.requireLogin() else { return }
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

private struct WatchComments: Decodable {
    struct Entry: Decodable {
        let name: String
        let body: String
    }
    let items: [Entry]
    let total: Int
}

private struct WatchSocial: Decodable { let likes: Int }

private struct Watch: View {
    @EnvironmentObject private var auth: LiveSession
    @State private var draft = ""
    @State private var commentError = ""
    @State private var sending = false
    let video: Video
    var others: [Video] = []
    @AppStorage("savedVideos") private var saved = ""
    @AppStorage("followedChannels") private var followed = ""
    @AppStorage("likedVideos") private var liked = ""
    @AppStorage("dislikedVideos") private var disliked = ""
    @State private var comments: WatchComments?
    @State private var social: WatchSocial?
    @State private var subscribers: Int?
    @State private var commentsOpen = false
    @State private var commentsFailed = false

    private var hasLiked: Bool { contains(liked, video.id) }
    private var hasDisliked: Bool { contains(disliked, video.id) }
    private var isSaved: Bool { contains(saved, video.id) }

    private func contains(_ list: String, _ id: String) -> Bool {
        list.split(separator: ",").contains(Substring(id))
    }

    private func setting(_ list: String, _ id: String, enabled: Bool) -> String {
        var ids = list.split(separator: ",").map(String.init).filter { $0 != id }
        if enabled { ids.append(id) }
        return ids.joined(separator: ",")
    }

    private func actionLabel(_ icon: String, _ title: String? = nil, selected: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 16))
                .foregroundStyle(selected ? lime : .white)
            if let title { Text(title).font(.caption.weight(.medium)).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal, 4)
        .background(surface, in: RoundedRectangle(cornerRadius: 13))
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                guard auth.requireLogin() else { return }
                liked = setting(liked, video.id, enabled: !hasLiked)
                disliked = setting(disliked, video.id, enabled: false)
            } label: {
                let count = (social?.likes ?? 0) + (hasLiked ? 1 : 0)
                actionLabel(hasLiked ? "hand.thumbsup.fill" : "hand.thumbsup", count > 0 ? String(count) : nil, selected: hasLiked)
            }.accessibilityLabel("Нравится")
            Button {
                guard auth.requireLogin() else { return }
                disliked = setting(disliked, video.id, enabled: !hasDisliked)
                liked = setting(liked, video.id, enabled: false)
            } label: {
                actionLabel(hasDisliked ? "hand.thumbsdown.fill" : "hand.thumbsdown", selected: hasDisliked)
            }.accessibilityLabel("Не нравится")
            ShareLink(item: origin.appendingPathComponent("watch").appendingPathComponent(video.id)) {
                actionLabel("arrowshape.turn.up.right", "Поделиться").layoutPriority(1)
            }.fixedSize(horizontal: true, vertical: false)
            Button { if auth.requireLogin() { saved = setting(saved, video.id, enabled: !isSaved) } } label: {
                actionLabel(isSaved ? "bookmark.fill" : "bookmark", selected: isSaved)
            }.accessibilityLabel(isSaved ? "Убрать из избранного" : "В избранное")
        }.buttonStyle(.plain)
    }

    private func authorRow(_ id: String) -> some View {
        let subscribed = contains(followed, id)
        return HStack(spacing: 10) {
            NavigationLink(value: Route.channel(id)) {
                HStack(spacing: 10) {
                    Artwork(path: video.channel_avatar).frame(width: 40, height: 40).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(video.channel).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let subscribers {
                            Text("\(subscribers) подписчиков").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }.buttonStyle(.plain)
            Spacer(minLength: 0)
            Button {
                guard auth.requireLogin() else { return }
                followed = setting(followed, id, enabled: !subscribed)
            } label: {
                Text(subscribed ? "Вы подписаны" : "Подписаться")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(subscribed ? lime : appBackground)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 42)
                    .background(subscribed ? surface : lime, in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain)
        }
    }

    private var commentsCard: some View {
        Button { commentsOpen = true } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Комментарии").font(.subheadline.weight(.semibold))
                    if let comments { Text(String(comments.total)).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                if let first = comments?.items.first {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "person.crop.circle.fill").font(.title3).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(first.name).font(.caption2).foregroundStyle(.secondary)
                            Text(first.body).font(.caption).lineLimit(2)
                        }
                    }
                } else {
                    Text(commentsFailed ? "Не удалось загрузить комментарии" : comments == nil ? "Загрузка…" : "Пока нет комментариев")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(14).background(surface, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }

    private func sendComment() async {
        guard auth.requireLogin(), !sending else { return }
        sending = true
        commentError = ""
        defer { sending = false }
        do {
            let _: WriteResult = try await request("/api/media/" + video.id + "/comments",
                                                   method: "POST", json: ["body": draft])
            draft = ""
            await loadComments()
        } catch { commentError = error.localizedDescription }
    }

    private func loadComments() async {
        commentsFailed = false
        do { comments = try await request("/api/media/" + video.id + "/comments") }
        catch { commentsFailed = true }
    }
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
                if let id = video.channel_id { authorRow(id) }
                actionRow
                Divider().padding(.top, 6)
                commentsCard
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
        .task { await loadComments() }
        .task { social = try? await request("/api/media/" + video.id + "/social") }
        .task {
            if let id = video.channel_id {
                let channel: Channel? = try? await request("/api/channels/" + id)
                subscribers = channel?.subscribers
            }
        }
        .sheet(isPresented: $commentsOpen) {
            NavigationStack {

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if commentsFailed {
                            Button("Повторить загрузку") { Task { await loadComments() } }
                        } else if let comments {
                            if comments.items.isEmpty { Text("Пока нет комментариев").foregroundStyle(.secondary) }
                            ForEach(Array(comments.items.enumerated()), id: \.offset) { _, entry in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(entry.name).font(.caption).foregroundStyle(.secondary)
                                    Text(entry.body)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Divider()
                            }
                        } else {
                            ProgressView()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
                .background(appBackground.ignoresSafeArea())
                .safeAreaInset(edge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if auth.account != nil {
                            HStack {
                                TextField("Напишите комментарий", text: $draft, axis: .vertical)
                                    .textFieldStyle(.roundedBorder).lineLimit(1...4)
                                Button { Task { await sendComment() } } label: {
                                    Image(systemName: "paperplane.fill")
                                }
                                .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.count > 500)
                                .accessibilityLabel("Отправить комментарий")
                            }
                            if !commentError.isEmpty { Text(commentError).font(.caption) }
                        } else {
                            Button("Войти, чтобы написать комментарий") {
                                commentsOpen = false
                                auth.showLogin = true
                            }
                        }
                    }.padding(12).background(surface)
                }
                .navigationTitle("Комментарии")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { commentsOpen = false } } }
            }
        }
    }
}


private struct WebsitePlayer: UIViewRepresentable {
    let video: Video

    func makeCoordinator() -> Coordinator { Coordinator(video: video) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = false
        config.userContentController.add(context.coordinator, name: "playerOrientation")
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
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "playerOrientation")
        if coordinator.landscape { OrientationDelegate.rotate(false) }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var landscape = false
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let active = message.body as? Bool else { return }
            landscape = active
            OrientationDelegate.rotate(active)
        }
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





@MainActor
private final class OrientationDelegate: NSObject, UIApplicationDelegate {
    private static var mask: UIInterfaceOrientationMask = .portrait
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.mask
    }
    static func rotate(_ landscape: Bool) {
        mask = landscape ? .landscape : .portrait
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        var controller = scene.keyWindow?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        controller?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }
}

private struct WriteResult: Decodable { let ok: Bool? }

@MainActor
private final class LiveSession: ObservableObject {
    struct Account: Decodable { let name: String; let can_publish: Bool }
    struct Response: Decodable { let account: Account? }
    @Published var account: Account?
    @Published var showLogin = false
    func refresh() async {
        if let response: Response = try? await request("/api/session") { account = response.account }
    }
    func requireLogin() -> Bool {
        if account != nil { return true }
        showLogin = true
        return false
    }
}

private struct TelegramSignIn: View {
    struct Ticket: Decodable { let session_id, poll_token, code: String; let url: URL; let expires_in: Int }
    struct Poll: Decodable { let status: String }
    @EnvironmentObject private var auth: LiveSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var ticket: Ticket?
    @State private var status = ""
    @State private var progressMessage = ""
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 16) {
            Text("Вход через Telegram").font(.title2.bold())
            if let ticket {
                Text("Сравните этот код с кодом в боте.")
                Text(ticket.code).font(.largeTitle.monospacedDigit().bold())
                if ticket.url.scheme == "https", ticket.url.host == "t.me" {
                    Link("Открыть Telegram", destination: ticket.url).buttonStyle(.borderedProminent)
                }
            } else if status.isEmpty { ProgressView() }
            if !progressMessage.isEmpty { Text(progressMessage).font(.subheadline).multilineTextAlignment(.center) }
            if !status.isEmpty {
                Text(status).multilineTextAlignment(.center)
                Button("Начать заново") { attempt += 1 }
            }
            Button("Закрыть") { auth.showLogin = false }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(appBackground.ignoresSafeArea())
        .task(id: attempt) { await signIn() }
    }

    @MainActor
    private func signIn() async {
        ticket = nil
        status = ""
        progressMessage = ""
        defer { progressMessage = "" }
        do {
            let login: Ticket = try await request("/api/auth/telegram/start", method: "POST", json: ["purpose": "creator"])
            ticket = login
            let expiry = Date().addingTimeInterval(Double(login.expires_in))
            var shouldCheckSession = false
            var confirmed = false
            while Date() < expiry {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                guard scenePhase == .active else { continue }
                if shouldCheckSession || confirmed {
                    await auth.refresh()
                    try Task.checkCancellation()
                    if auth.account != nil {
                        auth.showLogin = false
                        return
                    }
                    if confirmed {
                        progressMessage = "Telegram подтвердил вход. Загружаем профиль…"
                        continue
                    }
                }
                do {
                    let reply: Poll = try await request("/api/auth/telegram/poll", method: "POST",
                        json: ["session_id": login.session_id, "poll_token": login.poll_token])
                    confirmed = reply.status == "authorized"
                    shouldCheckSession = false
                    progressMessage = confirmed ? "Загружаем профиль…" : ""
                } catch let error as URLError where [
                    .networkConnectionLost, .notConnectedToInternet, .timedOut,
                    .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .cancelled
                ].contains(error.code) {
                    try Task.checkCancellation()
                    shouldCheckSession = true
                    progressMessage = "Связь прервалась. Повторяем проверку входа…"
                } catch let error as ServerError where error.status == 410 {
                    // A lost response can still leave the session cookie on the device.
                    await auth.refresh()
                    try Task.checkCancellation()
                    if auth.account != nil { auth.showLogin = false }
                    else { status = "Не удалось восстановить подтверждение. Начните вход заново." }
                    return
                } catch let error as ServerError where error.status >= 500 || error.status == 429 {
                    shouldCheckSession = true
                    progressMessage = "Сервер временно недоступен. Повторяем проверку…"
                }
            }
            status = confirmed ? "Профиль не загрузился. Начните вход заново." : "Код истёк. Начните вход заново."
        } catch is CancellationError {
        } catch let error as URLError {
            if !Task.isCancelled {
                status = error.code == .notConnectedToInternet ? "Нет подключения к интернету." : "Не удалось связаться с сервером. Начните вход заново."
            }
        } catch {
            if !Task.isCancelled { status = error.localizedDescription }
        }
    }
}

private struct CreatorHome: View {
    @State private var avatarSelection: PhotosPickerItem?
    struct Profile: Decodable {
        let id, name, about: String
        let avatar: String?
    }
    @EnvironmentObject private var auth: LiveSession
    @State private var profile: Profile?
    @State private var videos: [Video] = []
    @State private var editing = false
    @State private var publishing = false
    @State private var name = ""
    @State private var about = ""
    @State private var error = ""
    @State private var saving = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Мой канал").font(.headline)
                    Spacer()
                    if let profile {
                        Button {
                            name = profile.name
                            about = profile.about
                            error = ""
                            editing = true
                        } label: { Label("Изменить", systemImage: "pencil") }
                    }
                }
                if let profile {
                    Artwork(path: videos.first?.poster).frame(height: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(alignment: .bottomLeading) {
                            Artwork(path: profile.avatar).frame(width: 64, height: 64)
                                .clipShape(Circle()).offset(x: 14, y: 26)
                        }.padding(.bottom, 20)
                    Text(profile.name).font(.custom("DelaGothicOne-Regular", size: 23))
                    if !profile.about.isEmpty { Text(profile.about).font(.subheadline).foregroundStyle(.secondary) }
                    Button { publishing = true } label: {
                        Label("Опубликовать видео", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 36)
                    }.buttonStyle(.borderedProminent).foregroundStyle(appBackground)
                    Text("Ваши видео").font(.headline)
                    if videos.isEmpty { Text("Опубликованных видео пока нет.").foregroundStyle(.secondary) }
                    ForEach(videos) { video in
                        NavigationLink(value: Route.video(video)) {
                            HStack {
                                Artwork(path: video.poster).frame(width: 108, height: 61)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading) {
                                    Text(video.title).lineLimit(2)
                                    Text("Опубликовано").font(.caption).foregroundStyle(lime)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                } else if auth.account == nil {
                    Text("Создайте канал, чтобы публиковать видео.").foregroundStyle(.secondary)
                    Button("Создать канал") { auth.showLogin = true }.buttonStyle(.borderedProminent)
                } else if auth.account?.can_publish == false {
                    Button("Создать канал через Telegram") { auth.showLogin = true }.buttonStyle(.borderedProminent)
                } else if error.isEmpty {
                    ProgressView()
                } else {
                    Text(error)
                    Button("Повторить") { Task { await load() } }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
        .task(id: auth.account?.name) { await load() }
        .sheet(isPresented: $editing) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Artwork(path: profile?.avatar).frame(width: 92, height: 92).clipShape(Circle())
                            .frame(maxWidth: .infinity)
                        PhotosPicker(selection: $avatarSelection, matching: .images) {
                            Label("Изменить фото", systemImage: "camera")
                                .frame(maxWidth: .infinity)
                        }.disabled(saving)
                        Text("Название канала").font(.caption).foregroundStyle(.secondary)
                        TextField("Название", text: $name).textFieldStyle(.roundedBorder)
                        Text("Описание").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $about).frame(minHeight: 120)
                        if !error.isEmpty { Text(error).font(.caption) }
                        Button {
                            Task {
                                saving = true
                                defer { saving = false }
                                do {
                                    profile = try await request("/api/admin/channel/profile", method: "PUT",
                                                                json: ["name": name, "about": about])
                                    editing = false
                                } catch { self.error = error.localizedDescription }
                            }
                        } label: { Text("Сохранить").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).disabled(saving)
                    }.padding(16)
                }.background(appBackground.ignoresSafeArea()).navigationTitle("Изменить канал")
                    .navigationBarTitleDisplayMode(.inline)
                    .task(id: avatarSelection) {
                        guard let selection = avatarSelection else { return }
                        saving = true
                        defer { saving = false }
                        do {
                            let jpeg = try await jpegImage(selection, maximum: 512)
                            profile = try await request("/api/admin/channel/avatar", method: "PUT", bytes: jpeg,
                                                        headers: ["Content-Type": "image/jpeg"])
                        } catch { self.error = error.localizedDescription }
                    }
            }
        }
        .sheet(isPresented: $publishing) { PublishVideo(channel: profile?.name ?? "") }
    }

    private func load() async {
        profile = nil
        videos = []
        error = ""
        guard auth.account?.can_publish == true else { return }
        do {
            let owner: Profile = try await request("/api/admin/channel/profile")
            profile = owner
            if let channel: Channel = try? await request("/api/channels/" + owner.id) { videos = channel.videos }
        } catch { self.error = error.localizedDescription }
    }
}

private struct PublishVideo: View {
    @State private var cover: PhotosPickerItem?
    struct Transfer: Decodable { let id: String; let offset, chunk_size: Int }
    let channel: String
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false
    @State private var file: URL?
    @State private var title = ""
    @State private var description = ""
    @State private var busy = false
    @State private var progress = 0.0
    @State private var status = ""
    @State private var transfer: Transfer?
    @State private var submitted = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(file == nil ? "01 / ВЫБОР ВИДЕО" : "02 / ОФОРМЛЕНИЕ").font(.caption.bold()).foregroundStyle(lime)
                    Divider()
                    if let file {
                        Label(file.lastPathComponent, systemImage: "doc").lineLimit(1)
                        Text("Название видео").font(.caption)
                        TextField("Название", text: $title).textFieldStyle(.roundedBorder)
                        Text("Описание").font(.caption)
                        TextEditor(text: $description).frame(minHeight: 96)
                        PhotosPicker(selection: $cover, matching: .images) {
                            Label(cover == nil ? "Загрузить обложку" : "Обложка выбрана", systemImage: "photo")
                        }.disabled(busy || submitted)
                        Label("Доступ для всех после модерации", systemImage: "globe")
                        if busy { ProgressView(value: progress) }
                        if !status.isEmpty { Text(status).font(.subheadline) }
                        Button {
                            if submitted { dismiss() }
                            else { Task { await upload(file) } }
                        } label: {
                            Text(submitted ? "Готово" : "Отправить на модерацию").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        Text("Поделитесь своей историей").font(.custom("DelaGothicOne-Regular", size: 25))
                        Text("Выберите видео, затем добавьте название и описание.").foregroundStyle(.secondary)
                        VStack(spacing: 16) {
                            Image(systemName: "square.and.arrow.up").font(.largeTitle).foregroundStyle(lime)
                            Text("Выберите видео").font(.headline)
                            Button("Выбрать файл") { choosing = true }.buttonStyle(.borderedProminent)
                        }.frame(maxWidth: .infinity).padding(32).background(surface, in: RoundedRectangle(cornerRadius: 18))
                        Label("Публикация на канале «\(channel)»", systemImage: "person.crop.circle")
                        if !status.isEmpty { Text(status) }
                    }
                }.padding(16)
            }
            .background(appBackground.ignoresSafeArea())
            .navigationTitle("Новое видео").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() }.disabled(busy) } }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.mpeg4Movie, .quickTimeMovie]) { result in
                switch result {
                case .success(let url):
                    file = url
                    title = String(url.deletingPathExtension().lastPathComponent.prefix(100))
                case .failure(let error): status = error.localizedDescription
                }
            }
        }.interactiveDismissDisabled(busy)
    }

    private func upload(_ file: URL) async {
        busy = true
        status = ""
        let accessed = file.startAccessingSecurityScopedResource()
        defer { if accessed { file.stopAccessingSecurityScopedResource() }; busy = false }
        do {
            guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size <= 2 * 1024 * 1024 * 1024 else {
                throw ServerError(status: 400, message: "Выберите видео размером до 2 ГБ.")
            }
            let coverData: Data?
            if let cover { coverData = try await jpegImage(cover, maximum: 1280) }
            else { coverData = nil }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let endpoint = "/api/admin/uploads"
            var state: Transfer
            if let previous = transfer { state = try await request(endpoint + "/" + previous.id) }
            else { state = try await request(endpoint, method: "POST", json: ["size": size]) }
            transfer = state
            let uploadPath = endpoint + "/" + state.id
            while state.offset < size {
                try handle.seek(toOffset: UInt64(state.offset))
                guard let bytes = try handle.read(upToCount: min(state.chunk_size, size - state.offset)), !bytes.isEmpty else {
                    throw URLError(.cannotDecodeContentData)
                }
                let next: Transfer = try await request(uploadPath, method: "PUT", bytes: bytes,
                    headers: ["Content-Type": "application/octet-stream", "Upload-Offset": String(state.offset)])
                guard next.offset > state.offset else { throw URLError(.badServerResponse) }
                state = next
                progress = Double(state.offset) / Double(size)
            }
            let _: WriteResult = try await request(uploadPath + "/complete", method: "POST",
                json: ["title": title, "description": description, "published": true])
            submitted = true
            status = "Видео отправлено на модерацию."
            if let coverData {
                do {
                    let _: WriteResult = try await request("/api/admin/media/" + state.id + "/cover",
                        method: "PUT", bytes: coverData, headers: ["Content-Type": "image/jpeg"])
                } catch { status += " Обложку сохранить не удалось." }
            }
        } catch { status = error.localizedDescription }
    }
}


@MainActor
private func jpegImage(_ selection: PhotosPickerItem, maximum: CGFloat) async throws -> Data {
    guard let data = try await selection.loadTransferable(type: Data.self), let source = UIImage(data: data),
          source.size.width > 0, source.size.height > 0 else {
        throw URLError(.cannotDecodeContentData)
    }
    let ratio = min(1, maximum / max(source.size.width, source.size.height))
    let size = CGSize(width: max(1, source.size.width * ratio), height: max(1, source.size.height * ratio))
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.8) { _ in
        source.draw(in: CGRect(origin: .zero, size: size))
    }
}

