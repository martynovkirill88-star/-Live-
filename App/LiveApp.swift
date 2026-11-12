import SwiftUI
import WebKit
import CoreText
import UniformTypeIdentifiers
import PhotosUI
import CoreTransferable
import Speech
import AVFoundation

private let appBackground = Color(red: 0.047, green: 0.071, blue: 0.067)
private let surface = Color(red: 0.106, green: 0.161, blue: 0.145)
private let lime = Color(red: 0.792, green: 0.98, blue: 0.459)
private let origin = URL(string: "https://live.chepushkavpn.fun/")!

private enum VideoCategory: String, CaseIterable {
    case general, music, travel, kids

    var label: String {
        switch self {
        case .general: return "Общий"
        case .music: return "Музыка"
        case .travel: return "Путешествия"
        case .kids: return "Детский"
        }
    }
}

private struct Video: Decodable, Identifiable, Hashable {
    let category: String?
    struct Quality: Decodable, Hashable {
        let code: String
        let height: Int
    }
    let id, title, channel: String
    let channel_id, channel_avatar, poster, manifest, description: String?
    let status, moderation, publication_policy, moderation_note: String?
    let published: Bool?
    let publish_at: Double?
    let created: Double?
    let duration: Double?
    let views: Int?
    let live: Bool
    let qualities: [Quality]?
}
private struct Catalog: Decodable { let items: [Video] }
private struct Channel: Decodable {
    let is_owner: Bool?
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
        .allowsHitTesting(false)
    }
}

private struct Home: View {
    @EnvironmentObject private var auth: LiveSession
    @State private var ownerConsole = false
    @State private var videos: [Video] = []
    @State private var failure = false
    @State private var tab = "Главная"
    @GestureState private var dockDragX: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let dockTabs = ["Главная", "Эфиры", "Подписки", "Профиль"]
    @State private var filter = "Всё"
    @State private var search = false
    @State private var path: [Route] = []
    @AppStorage("followedChannels") private var followed = ""
    @AppStorage("savedVideos") private var saved = ""
    private var visible: [Video] {
        let filtered = videos.filter { video in
            let title = video.title + " " + (video.description ?? "")
            switch tab {
            case "Эфиры": return video.live
            case "Подписки": return followed.split(separator: ",").contains { String($0) == video.channel_id }
            case "Профиль": return saved.split(separator: ",").contains { String($0) == video.id }
            default:
                switch filter {
                case "В эфире": return video.live
                case "Общий": return !video.live && (video.category ?? "general") == "general"
                case "Музыка": return video.category == "music" || (video.category == nil && title.localizedCaseInsensitiveContains("музык"))
                case "Путешествия": return video.category == "travel" || (video.category == nil && title.localizedCaseInsensitiveContains("путешеств"))
                case "Детский": return video.category == "kids"
                default: return true
                }
            }
        }
        if tab == "Главная" && filter == "Всё" {
            return LocalDiscovery.rank(filtered, saved: Set(saved.split(separator: ",").map(String.init)), followed: Set(followed.split(separator: ",").map(String.init)))
        }
        return filtered
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                HStack {
                    Image("BrandMark").resizable().scaledToFit()
                        .frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                    Text("Чепушка Live").font(.custom("DelaGothicOne-Regular", size: 17))
                    Spacer()
                    if auth.account?.role == "admin" {
                        headerButton("gearshape", label: "Админ-панель") { ownerConsole = true }
                    }
                    headerButton("magnifyingglass", label: "Поиск") { search = true }
                }.padding(.horizontal, 16)
                if tab == "Профиль" { CreatorHome() } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if tab == "Главная" {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(["Всё", "В эфире", "Общий", "Музыка", "Путешествия", "Детский"], id: \.self) { value in
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
                            Button { path.append(.video(video)) } label: {
                                FeedCard(video: video).contentShape(Rectangle())
                            }
                                .buttonStyle(.plain)
                        }
                    }.padding(16)
                }.refreshable { await load() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                dock
                .padding(5)
                .chromeCapsule()
                .frame(maxWidth: 500)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
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
            .sheet(isPresented: $ownerConsole) { OwnerConsoleSheet() }
            .fullScreenCover(isPresented: $search) { CatalogSearch(videos: videos) }
        }
    }

    private var dock: some View {
        GeometryReader { geometry in
            let width = geometry.size.width / CGFloat(dockTabs.count)
            let selected = dockTabs.firstIndex(of: tab) ?? 0
            let offset = dockDragX.map { min(width * 3, max(0, $0 - width / 2)) } ?? CGFloat(selected) * width
            let highlighted = dockDragX.map { dockTabs[dockIndex(at: $0, width: geometry.size.width)] } ?? tab
            HStack(spacing: 0) {
                tabButton("Главная", "house", highlighted: highlighted)
                tabButton("Эфиры", "dot.radiowaves.left.and.right", highlighted: highlighted)
                tabButton("Подписки", "play.rectangle.on.rectangle", highlighted: highlighted)
                tabButton("Профиль", "person.crop.circle", highlighted: highlighted)
            }
            .background(alignment: .leading) {
                Capsule().fill(lime.opacity(0.15))
                    .frame(width: width, height: 48)
                    .offset(x: offset)
                    .animation(reduceMotion || dockDragX != nil ? nil : .spring(response: 0.28, dampingFraction: 0.8), value: offset)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(name: "tab-dock")
            .simultaneousGesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .named("tab-dock"))
                    .updating($dockDragX) { value, position, _ in
                        position = value.location.x
                    }
                    .onEnded { value in
                        selectTab(dockTabs[dockIndex(at: value.location.x, width: geometry.size.width)])
                    }
            )
        }.frame(height: 48)
    }

    private func dockIndex(at x: CGFloat, width: CGFloat) -> Int {
        guard width > 0 else { return 0 }
        return Int(min(CGFloat(dockTabs.count - 1), max(0, x / width * CGFloat(dockTabs.count))))
    }

    private func selectTab(_ title: String) {
        tab = title
    }

    @ViewBuilder
    private func headerButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                .frame(width: 28, height: 28)
        }.accessibilityLabel(label)
        if #available(iOS 26.0, *) {
            button.buttonStyle(.glass).buttonBorderShape(.circle).tint(.white)
                .frame(minWidth: 44, minHeight: 44)
        } else {
            button.buttonStyle(.plain).frame(width: 44, height: 44).chromeCapsule()
        }
    }

    private func tabButton(_ title: String, _ icon: String, highlighted: String) -> some View {
        Button { selectTab(title) } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 20))
                Text(title).font(.caption2.weight(tab == title ? .semibold : .regular))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }.frame(maxWidth: .infinity, minHeight: 44)
                .padding(.vertical, 2)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(highlighted == title ? lime : .secondary)
        .accessibilityAddTraits(tab == title ? .isSelected : [])
    }

    private func load() async {
        failure = false
        do { let catalog: Catalog = try await request("/api/catalog"); videos = catalog.items }
        catch { failure = true }
    }
}

private struct CatalogSearch: View {
    let videos: [Video]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focused: Bool
    @StateObject private var voice = LocalSearchSpeech()
    @State private var query = ""
    @State private var submitted: String?
    @State private var filter = "Всё"
    @AppStorage("catalogSearchCounts") private var storedCounts = Data()
    @AppStorage("catalogSearchHistory") private var storedHistory = Data()
    private let background = Color(red: 10/255, green: 16/255, blue: 17/255)
    private let panel = Color(red: 27/255, green: 40/255, blue: 37/255)
    private let muted = Color(red: 164/255, green: 179/255, blue: 175/255)
    private let accent = Color(red: 202/255, green: 250/255, blue: 117/255)
    private let topics = ["Путешествия", "Прямые эфиры", "Музыка", "Детский"]
    private var history: [String] { (try? JSONDecoder().decode([String].self, from: storedHistory)) ?? [] }
    private var counts: [String: Int] { (try? JSONDecoder().decode([String: Int].self, from: storedCounts)) ?? [:] }
    private var popular: [Video] { videos.sorted { ($0.views ?? 0) > ($1.views ?? 0) } }
    private var term: String { normalized(query) }
    private var showingResults: Bool { submitted.map { normalized($0) == term } ?? false }

    private func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru"))
    }

    private var suggestions: [String] {
        let counts = counts
        let candidates = topics + history + popular.flatMap { [$0.title, $0.channel] }
        var seen = Set<String>()
        let matches = candidates.filter {
            let key = normalized($0)
            return !key.isEmpty && key.contains(term) && seen.insert(key).inserted
        }
        return Array(matches.enumerated().sorted { a, b in
            let left = normalized(a.element), right = normalized(b.element)
            if left.hasPrefix(term) != right.hasPrefix(term) { return left.hasPrefix(term) }
            if counts[left, default: 0] != counts[right, default: 0] {
                return counts[left, default: 0] > counts[right, default: 0]
            }
            return a.offset < b.offset
        }.prefix(term.isEmpty ? 4 : 8).map(\.element))
    }

    private func results(_ text: String) -> [Video] {
        let key = normalized(text)
        let categories = ["путешествия": "travel", "музыка": "music", "детский": "kids"]
        return popular.filter { video in
            if key == "прямые эфиры" { return video.live }
            if let category = categories[key], video.category == category { return true }
            return normalized(video.title + " " + video.channel + " " + (video.description ?? "")).contains(key)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchHeader
                if voice.active || !voice.message.isEmpty {
                    Text(voice.active ? "Слушаю…" : voice.message).font(.footnote)
                        .foregroundStyle(muted).padding(.horizontal, 16).padding(.top, 8)
                }
                ScrollView {
                    if showingResults { resultContent }
                    else { suggestionContent }
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .padding(.top, 8)
            .background(background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .video(let video): Watch(video: video, others: videos.filter { $0.id != video.id })
                case .channel(let id): ChannelScreen(id: id)
                }
            }
        }
        .onDisappear { voice.stop() }
        .onChange(of: scenePhase) { phase in if phase == .background { voice.stop() } }
    }

    private var searchHeader: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 15, weight: .medium))
                    .frame(width: 24, height: 48).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Назад")
            HStack(spacing: 8) {
                if query.isEmpty { Image(systemName: "magnifyingglass").foregroundStyle(muted) }
                TextField("Видео, каналы, эфиры", text: $query, prompt: Text("Видео, каналы, эфиры").foregroundColor(muted))
                    .font(.system(size: 13)).focused($focused).submitLabel(.search)
                    .onSubmit { submit(query) }
                if !query.isEmpty {
                    Button {
                        voice.stop()
                        query = ""
                        submitted = nil
                        focused = true
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(muted).frame(width: 36, height: 48)
                    }.buttonStyle(.plain).accessibilityLabel("Очистить поиск")
                }
            }.padding(.leading, 12).padding(.trailing, 6).frame(height: 48)
                .background(panel, in: RoundedRectangle(cornerRadius: 13))
            Button {
                if voice.active { voice.stop(); return }
                focused = false
                submitted = nil
                voice.start(hints: suggestions) { query = $0 }
            } label: {
                Image(systemName: voice.active ? "stop.fill" : "mic")
                    .font(.system(size: 21, weight: .medium)).foregroundStyle(background)
                    .frame(width: 44, height: 48).background(accent, in: RoundedRectangle(cornerRadius: 13))
            }.buttonStyle(.plain).accessibilityLabel(voice.active ? "Остановить запись" : "Голосовой поиск")
        }.padding(.horizontal, 16)
    }

    private var suggestionContent: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            Text(term.isEmpty ? "Популярные запросы" : "Подсказки")
                .font(.custom("DelaGothicOne-Regular", size: 20))
            if term.isEmpty {
                Text("Вдохновение начинается с поиска").font(.system(size: 13))
                    .foregroundStyle(muted).padding(.top, 5).padding(.bottom, 16)
            } else {
                suggestionRow(query, index: nil, icon: "magnifyingglass")
                    .padding(.top, 8)
            }
            ForEach(Array(suggestions.enumerated()), id: \.element) { index, title in
                if term.isEmpty || normalized(title) != term {
                    suggestionRow(title, index: index + 1, icon: nil)
                }
            }
            if term.isEmpty {
                if !history.isEmpty {
                    Rectangle().fill(panel).frame(height: 1).padding(.vertical, 18)
                    HStack {
                        Text("Недавние").font(.system(size: 16, weight: .semibold))
                        Spacer()
                        Button("Очистить") { storedHistory = Data(); storedCounts = Data() }
                            .font(.system(size: 12)).foregroundStyle(accent).padding(.trailing, 18)
                    }.padding(.bottom, 10)
                    ForEach(Array(history.prefix(2)), id: \.self) { title in
                        suggestionRow(title, index: nil, icon: "clock")
                    }
                }
                if !popular.isEmpty {
                    Text("Вам может понравиться").font(.system(size: 16, weight: .semibold))
                        .padding(.top, 28).padding(.bottom, 18)
                    ForEach(Array(popular.prefix(4))) { video in
                        videoRow(video, compact: true).padding(.bottom, 18)
                    }
                }
            }
        }.padding(.horizontal, 16).padding(.top, 28).padding(.bottom, 16)
    }

    private func suggestionRow(_ title: String, index: Int?, icon: String?) -> some View {
        Button { submit(title) } label: {
            HStack(spacing: 14) {
                Group {
                    if let index { Text(String(format: "%02d", index)).font(.system(size: 12, weight: .semibold)).foregroundStyle(accent) }
                    else if let icon { Image(systemName: icon).foregroundStyle(muted) }
                }.frame(width: 20, alignment: .leading)
                Text(title).font(.system(size: 15)).lineLimit(1)
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 14)).foregroundStyle(muted)
            }.padding(.trailing, 8).frame(height: 46).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var resultContent: some View {
        let matches = results(submitted ?? "")
        let channels = matchedChannels(in: matches)
        return VStack(alignment: .leading, spacing: 0) {
            if matches.isEmpty && channels.isEmpty {
                emptyContent
            } else {
                HStack(spacing: 8) {
                    ForEach(["Всё", "Видео", "Каналы", "Эфиры"], id: \.self) { value in
                        Button { filter = value } label: { chip(value, selected: filter == value) }
                            .buttonStyle(.plain).accessibilityAddTraits(filter == value ? .isSelected : [])
                    }
                }.padding(.top, 18)
                Text("По запросу «\(submitted ?? "")»")
                    .font(.system(size: 15, weight: .semibold)).padding(.top, 22)
                Text(resultSummary(matches: matches, channels: channels))
                    .font(.system(size: 12)).foregroundStyle(muted).padding(.top, 6)
                if filter == "Всё" || filter == "Каналы" {
                    ForEach(channels, id: \.id) { channel in
                        SearchChannelCard(id: channel.id, name: channel.video.channel, avatar: channel.video.channel_avatar,
                                          fallbackCount: videos.filter { $0.channel_id == channel.id }.count, panel: panel, muted: muted)
                            .padding(.top, 16)
                    }
                }
                let visible = matches.filter { filter == "Всё" || (filter == "Видео" && !$0.live) || (filter == "Эфиры" && $0.live) }
                if !visible.isEmpty {
                    Text(filter == "Эфиры" ? "Эфиры" : "Видео").font(.system(size: 18, weight: .semibold))
                        .padding(.top, 24).padding(.bottom, 18)
                    ForEach(visible) { video in videoRow(video, compact: false).padding(.bottom, 24) }
                } else if filter != "Всё" && (filter != "Каналы" || channels.isEmpty) {
                    Text("В этом разделе ничего нет").font(.system(size: 14)).foregroundStyle(muted).padding(.top, 24)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 20)
    }

    private func matchedChannels(in matches: [Video]) -> [(id: String, video: Video)] {
        var seen = Set<String>()
        return (videos.filter { normalized($0.channel).contains(term) } + matches).compactMap { video in
            guard let id = video.channel_id, !id.isEmpty, seen.insert(id).inserted else { return nil }
            return (id, video)
        }
    }

    private func resultSummary(matches: [Video], channels: [(id: String, video: Video)]) -> String {
        let parts = [channels.isEmpty ? nil : channels.count == 1 ? "Канал" : "Каналы: \(channels.count)",
                     matches.isEmpty ? nil : "\(matches.count) видео"].compactMap { $0 }
        return parts.joined(separator: " и ")
    }

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                Image(systemName: "magnifyingglass").font(.system(size: 21))
                    .frame(width: 72, height: 72).background(panel, in: Circle())
                Text("Ничего не найдено").font(.custom("DelaGothicOne-Regular", size: 20))
                    .padding(.top, 24)
                Text("По запросу «\(submitted ?? "")»\nпока нет видео или каналов.")
                    .font(.system(size: 14)).foregroundStyle(muted).padding(.top, 14)
                Text("Проверьте написание или попробуйте\nболее короткий запрос.")
                    .font(.system(size: 13)).foregroundStyle(muted).padding(.top, 20)
            }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.top, 72)
            Button {
                submitted = nil
                focused = true
            } label: {
                Text("Изменить запрос").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(background).frame(maxWidth: .infinity).frame(height: 46)
                    .background(accent, in: RoundedRectangle(cornerRadius: 13))
            }.buttonStyle(.plain).padding(.top, 28)
            Rectangle().fill(panel).frame(height: 1).padding(.top, 38).padding(.bottom, 24)
            Text("Попробуйте поискать").font(.system(size: 17, weight: .semibold)).padding(.bottom, 18)
            let alternatives = [topics[0], topics[1], topics[2], popular.first?.channel ?? topics[3]]
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<2) { row in
                    HStack(spacing: 8) {
                        ForEach(0..<2) { column in
                            let value = alternatives[row * 2 + column]
                            Button { submit(value) } label: { chip(value, horizontalPadding: 20) }.buttonStyle(.plain)
                        }
                    }
                }
            }
            Text("Ищите по названию видео, теме\nили имени автора.")
                .font(.system(size: 12)).foregroundStyle(muted).padding(.top, 42)
        }
    }

    private func chip(_ title: String, selected: Bool = false, horizontalPadding: CGFloat = 14) -> some View {
        Text(title).font(.system(size: 13)).lineLimit(1)
            .padding(.horizontal, horizontalPadding).frame(height: 34)
            .foregroundStyle(selected ? background : .white)
            .background(selected ? accent : panel, in: RoundedRectangle(cornerRadius: 10))
    }

    private func videoRow(_ video: Video, compact: Bool) -> some View {
        NavigationLink(value: Route.video(video)) {
            HStack(alignment: .top, spacing: 12) {
                Artwork(path: video.poster)
                    .frame(width: compact ? 128 : 144, height: compact ? 72 : 81)
                    .overlay(alignment: .bottomTrailing) {
                        if !compact, !video.live, let duration = video.duration, duration > 0 {
                            Text(clock(duration)).font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 5).padding(.vertical, 3)
                                .background(background, in: RoundedRectangle(cornerRadius: 4)).padding(5)
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 5) {
                    Text(video.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    if !compact { Spacer(minLength: 3) }
                    if compact {
                        Text(video.channel + (video.live ? " · Прямой эфир" : " · \(video.views ?? 0) просмотров"))
                            .font(.system(size: 11)).foregroundStyle(muted).lineLimit(1)
                    } else {
                        Text(video.channel).font(.system(size: 11)).foregroundStyle(muted).lineLimit(1)
                    }
                    if video.live {
                        Text("В ЭФИРЕ").font(.system(size: 10, weight: .medium)).foregroundStyle(accent)
                    } else if compact, let duration = video.duration, duration > 0 {
                        Text(clock(duration)).font(.system(size: 10)).foregroundStyle(muted)
                    } else if !compact {
                        Text(videoMetadata(video)).font(.system(size: 10)).foregroundStyle(muted).lineLimit(1)
                    }
                }.frame(height: compact ? 72 : 81, alignment: .topLeading).padding(.top, 3)
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func videoMetadata(_ video: Video) -> String {
        let views = "\(video.views ?? 0) просмотров"
        guard let created = video.created else { return views }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ru")
        return views + " · " + formatter.localizedString(for: Date(timeIntervalSince1970: created), relativeTo: Date())
    }

    private func submit(_ text: String) {
        let key = normalized(text)
        guard !key.isEmpty else { return }
        voice.stop()
        focused = false
        query = text
        submitted = text
        filter = "Всё"
        var nextCounts = counts
        if nextCounts.count >= 100 && nextCounts[key] == nil,
           let leastUsed = nextCounts.min(by: { $0.value < $1.value })?.key {
            nextCounts.removeValue(forKey: leastUsed)
        }
        nextCounts[key, default: 0] += 1
        if let encoded = try? JSONEncoder().encode(nextCounts) { storedCounts = encoded }
        let nextHistory = Array(([text] + history.filter { normalized($0) != key }).prefix(20))
        if let encoded = try? JSONEncoder().encode(nextHistory) { storedHistory = encoded }
    }
}

private struct SearchChannelCard: View {
    let id: String
    let name: String
    let avatar: String?
    let fallbackCount: Int
    let panel: Color
    let muted: Color
    @State private var details: Channel?

    var body: some View {
        NavigationLink(value: Route.channel(id)) {
            HStack(spacing: 12) {
                Artwork(path: details?.profile.avatar ?? avatar).frame(width: 52, height: 52).clipShape(Circle())
                VStack(alignment: .leading, spacing: 6) {
                    Text(details?.profile.name ?? name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(details.map { "\($0.subscribers) подписчиков · \($0.videos.count) видео" } ?? "\(fallbackCount) видео")
                        .font(.system(size: 11)).foregroundStyle(muted)
                }
                Spacer()
            }.padding(12).frame(height: 76)
                .background(panel, in: RoundedRectangle(cornerRadius: 13))
        }.buttonStyle(.plain)
            .task(id: id) { details = try? await request("/api/channels/" + id) }
    }
}

@MainActor
private final class LocalSearchSpeech: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var message = ""
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private let engine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?
    private var timeout: Task<Void, Never>?
    private var generation = UUID()
    private var hasTap = false
    private var audioActive = false

    func start(hints: [String], onText: @escaping (String) -> Void) {
        guard !active else { return }
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            message = "Локальное распознавание русского языка недоступно на этом iPhone."
            return
        }
        message = ""
        active = true
        let id = generation
        Task {
            let speech: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard id == generation else { return }
            guard speech == .authorized else { fail("Разреши распознавание речи в настройках iPhone."); return }
            let microphone: Bool = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard id == generation else { return }
            guard microphone else { fail("Разреши доступ к микрофону в настройках iPhone."); return }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .measurement)
                try session.setActive(true)
                audioActive = true
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.channelCount > 0, format.sampleRate > 0 else {
                    fail("Микрофон сейчас недоступен.")
                    return
                }
                let request = SFSpeechAudioBufferRecognitionRequest()
                request.requiresOnDeviceRecognition = true
                request.shouldReportPartialResults = true
                request.contextualStrings = hints
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
                hasTap = true
                engine.prepare()
                try engine.start()
                task = recognizer.recognitionTask(with: request) { result, error in
                    let text = result?.bestTranscription.formattedString
                    let final = result?.isFinal == true
                    let failed = error != nil
                    Task { @MainActor in
                        guard id == self.generation else { return }
                        if let text, !text.isEmpty { onText(text) }
                        if final { self.stop() }
                        else if failed { self.fail("Не удалось распознать речь. Попробуй ещё раз.") }
                    }
                }
                timeout = Task {
                    try? await Task.sleep(for: .seconds(15))
                    if !Task.isCancelled, id == generation { stop() }
                }
            } catch { fail("Не удалось включить микрофон.") }
        }
    }

    private func fail(_ text: String) {
        stop()
        message = text
    }

    func stop() {
        generation = UUID()
        timeout?.cancel()
        timeout = nil
        task?.cancel()
        task = nil
        if engine.isRunning { engine.stop() }
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        if audioActive {
            let session = AVAudioSession.sharedInstance()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? session.setCategory(.playback)
            audioActive = false
        }
        active = false
    }
}

private extension View {
    @ViewBuilder
    func chromeCapsule() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: Capsule())
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(.white.opacity(0.12)).allowsHitTesting(false) }
        }
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
                    if channel.is_owner != true && auth.ownedChannelID != id {
                        HStack {
                            Button(subscribed ? "✓  Вы подписаны" : "Подписаться") {
                                guard auth.requireLogin(), auth.ownedChannelID != id, channel.is_owner != true else { return }
                                if !subscribed { followed = (followed.isEmpty ? "" : followed + ",") + id }
                            }.buttonStyle(.borderedProminent).tint(subscribed ? surface : lime)
                                .foregroundStyle(subscribed ? lime : appBackground)
                            if subscribed {
                                Button("Отписаться") {
                                    guard auth.requireLogin(), auth.ownedChannelID != id, channel.is_owner != true else { return }
                                    followed = followed.split(separator: ",").filter { $0 != Substring(id) }.joined(separator: ",")
                                }.buttonStyle(.bordered)
                            }
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
    struct Entry: Decodable, Identifiable {
        let id: Int
        let can_delete: Bool?
        let name: String
        let body: String
    }
    let items: [Entry]
    let total: Int
    let enabled: Bool?
}


private struct Watch: View {
    private struct Likes: Decodable {
        let liked: Bool
        let likes: Int
    }
    @EnvironmentObject private var auth: LiveSession
    @State private var draft = ""
    @State private var commentError = ""
    @State private var sending = false
    let video: Video
    var others: [Video] = []
    @AppStorage("savedVideos") private var saved = ""
    @AppStorage("followedChannels") private var followed = ""
    @AppStorage("dislikedVideos") private var disliked = ""
    @State private var likes: Likes?
    @State private var changingLike = false
    @State private var likeError = ""
    @State private var comments: WatchComments?
    @State private var commentToDelete: WatchComments.Entry?
    @State private var deletingComment = false
    @State private var subscribers: Int?
    @State private var authorIsOwner: Bool?
    @State private var commentsOpen = false
    @State private var commentsFailed = false

    private var hasLiked: Bool { likes?.liked == true }
    private var hasDisliked: Bool { !hasLiked && contains(disliked, video.id) }
    private var isSaved: Bool { contains(saved, video.id) }

    private func contains(_ list: String, _ id: String) -> Bool {
        list.split(separator: ",").contains(Substring(id))
    }

    private func setting(_ list: String, _ id: String, enabled: Bool) -> String {
        var ids = list.split(separator: ",").map(String.init).filter { $0 != id }
        if enabled { ids.append(id) }
        return ids.joined(separator: ",")
    }

    private func actionLabel(_ icon: String, selected: Bool = false, count: Int? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 20))
            if let count { Text(count.formatted()).font(.caption.monospacedDigit()) }
        }
            .foregroundStyle(selected ? lime : .white)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
    }

    private func loadLikes() async {
        let response: Likes? = try? await request("/api/media/" + video.id + "/social")
        if !Task.isCancelled && !changingLike, let response { likes = response }
    }

    private func changeLike(dislike: Bool = false) async {
        guard !changingLike else { return }
        changingLike = true
        likeError = ""
        defer { changingLike = false }
        do {
            let route = "/api/media/" + video.id
            let current: Likes = try await request(route + "/social")
            let wasDisliked = !current.liked && contains(disliked, video.id)
            if !dislike || current.liked {
                likes = try await request(route + "/like", method: "POST", json: [:])
            } else { likes = current }
            disliked = setting(disliked, video.id, enabled: dislike && !wasDisliked)
        } catch {
            likeError = error.localizedDescription
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                guard auth.requireLogin() else { return }
                Task { await changeLike() }
            } label: {
                actionLabel(hasLiked ? "hand.thumbsup.fill" : "hand.thumbsup", selected: hasLiked, count: likes?.likes)
            }.accessibilityLabel(hasLiked ? "Убрать лайк" : "Нравится")
                .accessibilityValue(likes.map { String($0.likes) } ?? "")
                .disabled(changingLike)
            Button {
                guard auth.requireLogin() else { return }
                Task { await changeLike(dislike: true) }
            } label: {
                actionLabel(hasDisliked ? "hand.thumbsdown.fill" : "hand.thumbsdown", selected: hasDisliked)
            }.accessibilityLabel("Не нравится").disabled(changingLike)
            ShareLink(item: origin.appendingPathComponent("watch").appendingPathComponent(video.id)) {
                actionLabel("arrowshape.turn.up.right")
            }.accessibilityLabel("Поделиться")
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
            if auth.ownedChannelID != id && (auth.account?.can_publish != true || authorIsOwner == false) {
                Button {
                    guard auth.requireLogin(), auth.ownedChannelID != id, authorIsOwner == false else { return }
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
                    Text(comments?.enabled == false ? "Комментарии отключены автором" : commentsFailed ? "Не удалось загрузить комментарии" : comments == nil ? "Загрузка…" : "Пока нет комментариев")
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

    private func deleteComment(_ entry: WatchComments.Entry) async {
        guard !deletingComment else { return }
        deletingComment = true
        commentError = ""
        defer { deletingComment = false }
        do {
            let _: WriteResult = try await request("/api/media/" + video.id + "/comments/" + String(entry.id), method: "DELETE")
            if let current = comments {
                comments = WatchComments(items: current.items.filter { $0.id != entry.id },
                                         total: max(0, current.total - 1), enabled: current.enabled)
            }
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
                if !likeError.isEmpty { Text(likeError).font(.caption).foregroundStyle(.secondary) }
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
        .task(id: auth.account?.name) { await loadLikes() }
        .task {
            if let id = video.channel_id {
                let channel: Channel? = try? await request("/api/channels/" + id)
                subscribers = channel?.subscribers
                authorIsOwner = channel?.is_owner
                if channel?.is_owner == true { auth.setOwnedChannel(id) }
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
                            ForEach(comments.items) { entry in
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(entry.name).font(.caption).foregroundStyle(.secondary)
                                        Text(entry.body)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    if entry.can_delete == true {
                                        Button(role: .destructive) { commentToDelete = entry } label: {
                                            Image(systemName: "trash").frame(width: 44, height: 44).contentShape(Rectangle())
                                        }.buttonStyle(.plain).disabled(deletingComment)
                                            .accessibilityLabel("Удалить свой комментарий")
                                    }
                                }
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
                        if comments?.enabled == false {
                            Text("Комментарии отключены автором.").font(.caption)
                        } else if auth.account != nil {
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
                .confirmationDialog("Удалить комментарий?", isPresented: Binding(
                    get: { commentToDelete != nil },
                    set: { if !$0 { commentToDelete = nil } }
                ), titleVisibility: .visible, presenting: commentToDelete) { entry in
                    Button("Удалить", role: .destructive) { Task { await deleteComment(entry) } }
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

    func makeUIView(context: Context) -> UIView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback = true
        config.allowsAirPlayForMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = false
        config.userContentController.add(context.coordinator, name: "playerOrientation")
        config.userContentController.add(context.coordinator, name: "playerWatched")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        if let page = Bundle.main.url(forResource: "player", withExtension: "html", subdirectory: "Player") {
            if video.publication_policy == "private", let html = Self.embeddedPlayer(page) {
                Task { @MainActor in
                    for cookie in HTTPCookieStorage.shared.cookies(for: origin) ?? [] {
                        await config.websiteDataStore.httpCookieStore.setCookie(cookie)
                    }
                    webView.loadHTMLString(html, baseURL: origin)
                }
            } else {
                webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
            }
        } else {
            webView.loadHTMLString("<p>Не удалось загрузить плеер.</p>", baseURL: nil)
        }
        let host = UIView()
        host.backgroundColor = .black
        context.coordinator.host = host
        context.coordinator.player = webView
        context.coordinator.attachPlayer(to: host)
        return host
    }

    private static func embeddedPlayer(_ page: URL) -> String? {
        guard var html = try? String(contentsOf: page, encoding: .utf8) else { return nil }
        for name in ["app.css", "refine.css", "platform.css"] {
            guard let css = try? String(contentsOf: page.deletingLastPathComponent().appendingPathComponent(name), encoding: .utf8) else { return nil }
            html = html.replacingOccurrences(of: "<link rel=\"stylesheet\" href=\"\(name)\">", with: "<style>\(css)</style>")
        }
        for name in ["lottie-light.min.js", "loading-data.js", "bridge.js", "player-v2.js"] {
            guard let js = try? String(contentsOf: page.deletingLastPathComponent().appendingPathComponent(name), encoding: .utf8) else { return nil }
            html = html.replacingOccurrences(of: "<script src=\"\(name)\" defer></script>",
                with: "<script>\(js.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive))</script>")
        }
        return html
    }

    func updateUIView(_ host: UIView, context: Context) {}

    static func dismantleUIView(_ host: UIView, coordinator: Coordinator) {
        coordinator.closeFullscreen()
        coordinator.player?.evaluateJavaScript("window.activePlayer?.destroy()", completionHandler: nil)
        coordinator.player?.configuration.userContentController.removeScriptMessageHandler(forName: "playerOrientation")
        coordinator.player?.configuration.userContentController.removeScriptMessageHandler(forName: "playerWatched")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var host: UIView?
        weak var player: WKWebView?
        private weak var fullscreen: UIViewController?

        func attachPlayer(to container: UIView) {
            guard let player else { return }
            player.removeFromSuperview()
            player.translatesAutoresizingMaskIntoConstraints = true
            player.frame = container.bounds
            player.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(player)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame else { return }
            if message.name == "playerWatched" { LocalDiscovery.record(video.id); return }
            if fullscreen != nil { closeFullscreen(); return }
            guard let presenter = host?.window?.rootViewController else { return }
            var top = presenter
            while let presented = top.presentedViewController { top = presented }
            let screen = UIViewController()
            screen.view.backgroundColor = .black
            screen.modalPresentationStyle = .fullScreen
            screen.modalPresentationCapturesStatusBarAppearance = true
            let close = UIButton(type: .system)
            close.setImage(UIImage(systemName: "xmark"), for: .normal)
            close.tintColor = .white
            close.backgroundColor = UIColor(white: 0.1, alpha: 0.85)
            close.layer.cornerRadius = 14
            close.accessibilityLabel = "Закрыть полноэкранный режим"
            close.addAction(UIAction { [weak self] _ in self?.closeFullscreen() }, for: .touchUpInside)
            close.translatesAutoresizingMaskIntoConstraints = false
            fullscreen = screen
            attachPlayer(to: screen.view)
            screen.view.addSubview(close)
            NSLayoutConstraint.activate([
                close.leadingAnchor.constraint(equalTo: screen.view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
                close.topAnchor.constraint(equalTo: screen.view.safeAreaLayoutGuide.topAnchor, constant: 12),
                close.widthAnchor.constraint(equalToConstant: 48),
                close.heightAnchor.constraint(equalToConstant: 44)
            ])
            player?.evaluateJavaScript("document.body.classList.add('app-fullscreen')", completionHandler: nil)
            top.present(screen, animated: false) { OrientationDelegate.rotate(true) }
        }

        func closeFullscreen() {
            guard let screen = fullscreen else { return }
            fullscreen = nil
            if let host { attachPlayer(to: host) }
            player?.evaluateJavaScript("document.body.classList.remove('app-fullscreen')", completionHandler: nil)
            screen.dismiss(animated: false) { OrientationDelegate.rotate(false) }
        }
        let video: Video

        init(video: Video) { self.video = video }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard webView.url?.isFileURL == true || video.publication_policy == "private" else { return }
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
    struct Account: Decodable { let name: String; let can_publish: Bool; let role: String? }
    struct Response: Decodable { let account: Account? }
    @Published var account: Account?
    @Published var showLogin = false
    @Published private(set) var ownedChannelID: String?
    private struct OwnerProfile: Decodable { let id: String }
    func refresh() async {
        guard let response: Response = try? await request("/api/session") else { return }
        account = response.account
        if response.account?.can_publish == true {
            let profile: OwnerProfile? = try? await request("/api/admin/channel/profile")
            if let profile { setOwnedChannel(profile.id) }
        } else {
            ownedChannelID = nil
        }
    }

    func setOwnedChannel(_ id: String) {
        ownedChannelID = id
        let defaults = UserDefaults.standard
        let channels = defaults.string(forKey: "followedChannels") ?? ""
        let cleaned = channels.split(separator: ",").filter { $0 != Substring(id) }.joined(separator: ",")
        if channels != cleaned { defaults.set(cleaned, forKey: "followedChannels") }
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var editingVideo: Video?
    @State private var deletingVideo: Video?
    @State private var rejectedVideo: Video?
    @State private var managementError = ""
    @State private var avatarSelection: PhotosPickerItem?
    struct Profile: Decodable {
        let id, name, about: String
        let avatar: String?
    }
    @EnvironmentObject private var auth: LiveSession
    @State private var profile: Profile?
    @State private var videos: [Video] = []
    @State private var subscribers: Int?
    @State private var editing = false
    @State private var publishing = false
    @State private var name = ""
    @State private var about = ""
    @State private var error = ""
    @State private var saving = false

    var body: some View {
        if editing { editor } else { channelPage }
    }
    private var channelPage: some View {
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
                            avatarSelection = nil
                            editing = true
                        } label: { Label("Изменить", systemImage: "pencil").padding(.horizontal, 8).frame(minHeight: 44).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(lime)
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
                    if let subscribers { Text("\(subscribers) подписчиков · \(videos.count) видео").font(.caption).foregroundStyle(lime) }
                    if !profile.about.isEmpty { Text(profile.about).font(.subheadline).foregroundStyle(.secondary) }
                    Button { publishing = true } label: {
                        Label("Опубликовать видео", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 36)
                    }.buttonStyle(.borderedProminent).foregroundStyle(appBackground)
                    Text("Ваши видео").font(.custom("DelaGothicOne-Regular", size: 19))
                    if videos.isEmpty { Text("На канале пока нет видео.").foregroundStyle(.secondary) }
                    ForEach(videos) { video in
                        HStack(spacing: 10) {
                            if video.moderation == "rejected" {
                                Button { rejectedVideo = video } label: {
                                    ownerVideoRow(video)
                                }.buttonStyle(.plain)
                            } else {
                                NavigationLink(value: Route.video(video)) {
                                    ownerVideoRow(video)
                                }.buttonStyle(.plain).disabled(video.status != "ready" && video.status != "live")
                            }
                            if !video.live && video.status != "scheduled" && video.status != "starting" {
                                Menu {
                                    Button { editingVideo = video } label: { Label("Изменить видео", systemImage: "pencil") }
                                        .disabled(video.status != "ready")
                                    Button(role: .destructive) { deletingVideo = video } label: {
                                        Label("Удалить видео", systemImage: "trash")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                                }.accessibilityLabel("Управление видео")
                            }
                        }
                    }
                    if !managementError.isEmpty { Text(managementError).font(.caption) }
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
        .task(id: auth.account?.name) {
            await load()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch { return }
                if scenePhase == .active && !publishing { await refreshVideos() }
            }
        }
        .refreshable { await refreshVideos() }
        .sheet(item: $editingVideo, onDismiss: { Task { await refreshVideos() } }) { video in
            EditPublishedVideo(video: video)
        }
        .confirmationDialog("Удалить видео?", isPresented: Binding(
            get: { deletingVideo != nil },
            set: { if !$0 { deletingVideo = nil } }
        ), titleVisibility: .visible, presenting: deletingVideo) { video in
            Button("Удалить", role: .destructive) { Task { await removeVideo(video) } }
        } message: { video in
            Text("«\(video.title)» будет удалено без возможности восстановления.")
        }
        .alert("Видео отклонено", isPresented: Binding(
            get: { rejectedVideo != nil },
            set: { if !$0 { rejectedVideo = nil } }
        ), presenting: rejectedVideo) { _ in
            Button("Понятно", role: .cancel) {}
        } message: { video in
            let reason = video.moderation_note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Text(reason.isEmpty ? "Модератор не указал причину." : reason)
        }
        .fullScreenCover(isPresented: $publishing, onDismiss: { Task { await refreshVideos() } }) {
            PublishVideo(channel: profile?.name ?? "")
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            creatorHeader("Изменить канал", icon: "chevron.left", disabled: saving) { editing = false }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PhotosPicker(selection: $avatarSelection, matching: .images) {
                        VStack(spacing: 14) {
                            Artwork(path: profile?.avatar).frame(width: 88, height: 88).clipShape(Circle())
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: "camera").font(.caption).padding(6)
                                        .foregroundStyle(appBackground).background(lime, in: Circle())
                                }
                            Text("Изменить фото").font(.footnote.weight(.semibold)).foregroundStyle(lime)
                            Text("Фото канала видно рядом с вашими видео").font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(.plain).disabled(saving).padding(.vertical, 20)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Название канала").font(.caption).foregroundStyle(.secondary)
                        TextField("Название", text: $name).padding(14).creatorField()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Описание").font(.caption).foregroundStyle(.secondary)
                        VStack(alignment: .trailing, spacing: 4) {
                            TextEditor(text: $about).scrollContentBackground(.hidden).frame(height: 86)
                            Text("\(about.count) / 1000").font(.caption2).foregroundStyle(.secondary)
                        }.padding(10).creatorField()
                    }
                    Text("Эти данные будут видны всем зрителям на странице вашего канала.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !error.isEmpty { Text(error).font(.caption) }
                }.padding(16)
            }
            Divider()
            creatorButton("Сохранить") { Task { await saveProfile() } }
                .disabled(saving || !(2...80).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).count) || about.count > 1000)
                .padding(16)
        }
        .background(appBackground)
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

    private func saveProfile() async {
        saving = true
        error = ""
        defer { saving = false }
        do {
            profile = try await request("/api/admin/channel/profile", method: "PUT",
                                        json: ["name": name, "about": about])
            editing = false
        } catch { self.error = error.localizedDescription }
    }

    private func ownerVideoRow(_ video: Video) -> some View {
        HStack(spacing: 10) {
            Artwork(path: video.poster).frame(width: 108, height: 61)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading) {
                Text(video.title).lineLimit(2)
                Text(publicationStatus(video)).font(.caption)
                    .foregroundStyle(video.moderation == "rejected" ? Color.orange : lime)
            }
            Spacer(minLength: 0)
            if video.moderation == "rejected" {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
        }.contentShape(Rectangle())
    }
    private func publicationStatus(_ video: Video) -> String {
        if video.status == "error" { return "Ошибка обработки" }
        if video.status == "queued" || video.status == "processing" { return "Обрабатывается" }
        if video.publication_policy == "private" { return "Только я" }
        if video.moderation == "pending" { return "На модерации" }
        if video.moderation == "rejected" { return "Отклонено" }
        if video.published == true { return "Опубликовано" }
        if let date = video.publish_at {
            return Date(timeIntervalSince1970: date).formatted(date: .abbreviated, time: .shortened)
        }
        return "Скрыто"
    }
    private func refreshVideos() async {
        guard let id = profile?.id else { return }
        guard let studio: Catalog = try? await request("/api/admin/media"),
              !Task.isCancelled, profile?.id == id else { return }
        videos = studio.items.filter { $0.channel_id == id }
    }

    private func removeVideo(_ video: Video) async {
        deletingVideo = nil
        managementError = ""
        do {
            let _: WriteResult = try await request("/api/admin/media/" + video.id, method: "DELETE")
            videos.removeAll { $0.id == video.id }
            await refreshVideos()
        } catch { managementError = error.localizedDescription }
    }
    private func load() async {
        profile = nil
        videos = []
        error = ""
        guard auth.account?.can_publish == true else { return }
        do {
            let owner: Profile = try await request("/api/admin/channel/profile")
            profile = owner
            auth.setOwnedChannel(owner.id)
            if let channel: Channel = try? await request("/api/channels/" + owner.id) {
                videos = channel.videos
                subscribers = channel.subscribers
            }
            await refreshVideos()
        } catch { self.error = error.localizedDescription }
    }
}

private struct EditPublishedVideo: View {
    let video: Video
    @Environment(\.dismiss) private var dismiss
    @State private var category: VideoCategory
    @State private var title: String
    @State private var description: String
    @State private var error = ""
    @State private var busy = false

    init(video: Video) {
        self.video = video
        _category = State(initialValue: VideoCategory(rawValue: video.category ?? "") ?? .general)
        _title = State(initialValue: video.title)
        _description = State(initialValue: video.description ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            creatorHeader("Изменить видео", icon: "chevron.left", disabled: busy) { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Название видео").font(.caption).foregroundStyle(.secondary)
                    TextField("Название", text: $title).padding(12).creatorField()
                    Text("Описание").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $description).scrollContentBackground(.hidden)
                        .frame(minHeight: 120).padding(8).creatorField()
                    Picker("Раздел", selection: $category) {
                        ForEach(VideoCategory.allCases, id: \.self) { item in Text(item.label).tag(item) }
                    }
                    if video.moderation == "rejected", let reason = video.moderation_note, !reason.isEmpty {
                        Label(reason, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
                    }
                    if video.publication_policy != "private" {
                        Label("После сохранения видео снова отправится на модерацию.", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !error.isEmpty { Text(error).font(.caption) }
                }.padding(16).disabled(busy)
            }
            creatorButton(busy ? "Сохраняем…" : "Сохранить") { Task { await save() } }
                .disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          (title == video.title && description == (video.description ?? "") && category.rawValue == (video.category ?? "general")))
                .padding(16)
        }
        .background(appBackground.ignoresSafeArea())
        .interactiveDismissDisabled(busy)
    }

    private func save() async {
        busy = true
        error = ""
        defer { busy = false }
        do {
            let _: WriteResult = try await request("/api/admin/media/" + video.id + "/owner-edit",
                method: "PATCH", json: ["title": title, "description": description, "category": category.rawValue])
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct PublishVideo: View {
    private struct Capabilities: Decodable { let publication_settings: Bool; let video_categories: Bool? }
    @State private var category: VideoCategory = .general
    @State private var privateVideo = false
    @State private var commentsEnabled = true
    @State private var scheduled = false
    @State private var publishDate = Date().addingTimeInterval(3600)
    @State private var cover: PhotosPickerItem?
    @State private var coverPreview: UIImage?
    struct Transfer: Decodable { let id: String; let offset, chunk_size: Int }
    let channel: String
    @Environment(\.dismiss) private var dismiss
    @State private var selection: PhotosPickerItem?
    @State private var importing = false
    @State private var file: URL?
    @State private var title = ""
    @State private var description = ""
    @State private var busy = false
    @State private var progress = 0.0
    @State private var uploadPhase = "Подготавливаем видео…"
    @State private var status = ""
    @State private var transfer: Transfer?
    @State private var submitted = false
    @EnvironmentObject private var auth: LiveSession
    @State private var linkAvailable = false
    @State private var videoLink = ""
    @State private var linkPreview: LinkPreview?
    private let sourceEndpoint = "/api/admin/publication-source"
    private struct SourceCapability: Decodable { let available: Bool }
    private struct LinkPreview: Decodable { let title, description: String; let thumbnail: URL }
    private struct ImportJob: Decodable { let status: String; let error: String? }
    private var hasVideo: Bool { file != nil || linkPreview != nil }

    var body: some View {
        VStack(spacing: 0) {
            creatorHeader("Новое видео", icon: !hasVideo ? "xmark" : "chevron.left", disabled: busy || importing) {
                if !hasVideo || submitted { clearMovie(); dismiss() }
                else {
                    clearMovie()
                    selection = nil
                    transfer = nil
                    progress = 0
                    cover = nil
                    status = ""
                }
            }
            if busy {
                uploadProgress
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(!hasVideo ? "01 / ВЫБОР ВИДЕО" : "02 / ОФОРМЛЕНИЕ")
                            .font(.caption2.bold()).foregroundStyle(lime)
                        HStack(spacing: 8) {
                            Capsule().fill(lime).frame(height: 2)
                            Capsule().fill(!hasVideo ? surface : lime).frame(height: 2)
                        }
                        if hasVideo { details(file?.lastPathComponent ?? "YouTube") } else { picker }
                        if !status.isEmpty { Text(status).font(.caption) }
                    }.padding(16)
                }
                Divider()
                if hasVideo {
                    creatorButton(submitted ? "Готово" : "Опубликовать") {
                        if submitted { clearMovie(); dismiss() }
                        else if let file { Task { await upload(file) } }
                        else { Task { await publishLink() } }
                    }.disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .padding(16)
                } else {
                    VStack(spacing: 6) {
                        Text("Далее — оформление видео").font(.subheadline)
                        Text("Название, описание, обложка и доступ").font(.caption2)
                    }.foregroundStyle(.secondary).padding(16)
                }
            }
        }
        .background(appBackground.ignoresSafeArea())
        .interactiveDismissDisabled(busy || importing)
        .task(id: auth.account?.role) {
            linkAvailable = false
            guard auth.account?.role == "admin" else { return }
            let capability: SourceCapability? = try? await request(sourceEndpoint)
            if !Task.isCancelled { linkAvailable = capability?.available == true }
        }
        .task(id: selection) {
            guard let selection else { return }
            importing = true
            status = ""
            defer { importing = false }
            do {
                guard let movie = try await selection.loadTransferable(type: GalleryVideo.self) else {
                    throw URLError(.cannotDecodeContentData)
                }
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: movie.url)
                    return
                }
                file = movie.url
                title = String(movie.url.deletingPathExtension().lastPathComponent.prefix(100))
            } catch is CancellationError {} catch { status = "Не удалось загрузить видео из медиатеки. " + error.localizedDescription }
        }
    }

    private var uploadProgress: some View {
        VStack(spacing: 18) {
            Image(systemName: "arrow.up.circle").font(.system(size: 54)).foregroundStyle(lime)
            Text(linkPreview == nil ? "Загрузка видео" : "Импорт видео").font(.title2.bold())
            Text(title).font(.subheadline).lineLimit(2).foregroundStyle(.secondary)
            if linkPreview == nil {
                ProgressView(value: progress).tint(lime)
                Text(progress.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
            } else {
                ProgressView().tint(lime)
            }
            Text(uploadPhase).font(.subheadline).foregroundStyle(.secondary)
        }.multilineTextAlignment(.center).padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Поделитесь\nсвоей историей")
                .font(.custom("DelaGothicOne-Regular", size: 25))
            Text("Загрузите видео, а затем добавьте название, обложку и настройки.")
                .font(.subheadline).foregroundStyle(.secondary)
            VStack(spacing: 16) {
                Image(systemName: "square.and.arrow.up").font(.title2).foregroundStyle(lime)
                    .frame(width: 62, height: 62).background(lime.opacity(0.1), in: Circle())
                Text("Выберите видео").font(.headline)
                Text("MP4 или MOV · до 2 ГБ").font(.caption2).foregroundStyle(.secondary)
                if importing { ProgressView("Загружаем из медиатеки…") }
                else {
                    PhotosPicker(selection: $selection, matching: .videos) {
                        Label("Выбрать видео", systemImage: "photo.on.rectangle")
                            .font(.subheadline.weight(.semibold)).padding(.horizontal, 22)
                            .frame(height: 44).foregroundStyle(appBackground)
                            .background(lime, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                }
            }.frame(maxWidth: .infinity).padding(.vertical, 26)
                .background(creatorSurface, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(lime.opacity(0.22), style: StrokeStyle(dash: [5, 5])))
            if linkAvailable {
                TextField("Ссылка на YouTube", text: $videoLink)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(12).creatorField().disabled(importing)
                creatorButton("Далее") { Task { await loadLink() } }
                    .disabled(importing || videoLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Публикация на канале").font(.caption2).foregroundStyle(.secondary)
                Text(channel).font(.subheadline.weight(.semibold))
            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                .background(creatorSurface, in: RoundedRectangle(cornerRadius: 12))
            Label("Видео появится на канале после одобрения модератором.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func details(_ filename: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "doc")
                VStack(alignment: .leading, spacing: 4) {
                    Text(filename).lineLimit(1)
                    Text(submitted ? (linkPreview == nil ? "Отправлено на модерацию" : "Передано на обработку") : "Видео выбрано")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark").foregroundStyle(lime)
            }.font(.subheadline).padding(12)
                .background(creatorSurface, in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Text("Название видео")
                Spacer()
                Text("\(title.count) / 100")
            }.font(.caption).foregroundStyle(.secondary)
            TextField("Название", text: $title).padding(12).creatorField()
            Text("Описание").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $description).scrollContentBackground(.hidden)
                .frame(height: 65).padding(8).creatorField()
            Text("Обложка видео").font(.caption).foregroundStyle(.secondary)
            PhotosPicker(selection: $cover, matching: .images) {
                HStack(spacing: 12) {
                    Group {
                        if let coverPreview { Image(uiImage: coverPreview).resizable().scaledToFill() }
                        else if let linkPreview {
                            AsyncImage(url: linkPreview.thumbnail) { image in image.resizable().scaledToFill() }
                                placeholder: { surface.overlay(Image(systemName: "photo")) }
                        }
                        else { surface.overlay(Image(systemName: "photo")) }
                    }.frame(width: 136, height: 76).clipShape(RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(cover == nil ? "Загрузить обложку" : "Заменить обложку")
                            .font(.caption.bold()).foregroundStyle(lime)
                        Text("JPG или PNG · 16:9").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.background(creatorSurface, in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain).disabled(busy || submitted)
            Text("Настройки публикации").font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                Menu {
                    Button("Для всех") { privateVideo = false }
                    Button("Только я") { privateVideo = true; scheduled = false }
                } label: {
                    publicationRow("Доступ", icon: "globe", value: privateVideo ? "Только я" : "Для всех")
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider().padding(.leading, 34)
                Menu {
                    ForEach(VideoCategory.allCases, id: \.self) { item in
                        Button(item.label) { category = item }
                    }
                } label: {
                    publicationRow("Раздел", icon: "square.grid.2x2", value: category.label)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider().padding(.leading, 34)
                Toggle(isOn: $commentsEnabled) { Label("Комментарии", systemImage: "bubble") }
                    .font(.subheadline).frame(minHeight: 45)
                Divider().padding(.leading, 34)
                Menu {
                    Button("После модерации") { scheduled = false }
                    Button("Выбрать дату и время") {
                        publishDate = Date().addingTimeInterval(3600)
                        scheduled = true
                    }
                } label: {
                    publicationRow("Публикация", icon: "clock", value: privateVideo ? "Личное видео" : scheduled ? "По расписанию" : "После модерации")
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(privateVideo)
                if scheduled && !privateVideo {
                    DatePicker("Дата и время", selection: $publishDate, in: Date()...Date().addingTimeInterval(365 * 86400))
                        .font(.subheadline).padding(.vertical, 6)
                }
            }.padding(.horizontal, 12).background(creatorSurface, in: RoundedRectangle(cornerRadius: 12))
            if busy { ProgressView(value: progress) }
        }
        .disabled(submitted || busy)
        .task(id: cover) {
            coverPreview = nil
            if let cover, let data = try? await cover.loadTransferable(type: Data.self), !Task.isCancelled {
                coverPreview = UIImage(data: data)
            }
        }
    }

    private func publicationRow(_ title: String, icon: String, value: String) -> some View {
        HStack {
            Image(systemName: icon).frame(width: 20)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }.font(.subheadline).frame(minHeight: 45)
    }

    private func clearMovie() {
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
        linkPreview = nil
        coverPreview = nil
    }

    private func loadLink() async {
        guard !importing else { return }
        importing = true
        status = "Получаем сведения о видео…"
        defer { importing = false }
        do {
            let preview: LinkPreview = try await request(sourceEndpoint + "/preview", method: "POST",
                json: ["url": videoLink], headers: ["X-Live-Publication": "1"])
            title = preview.title
            description = preview.description
            linkPreview = preview
            status = ""
        } catch { status = error.localizedDescription }
    }

    private func publishLink() async {
        busy = true
        status = ""
        uploadPhase = "Сервер скачивает видео…"
        progress = 0
        defer { busy = false }
        do {
            var settings: [String: Any] = [
                "url": videoLink, "title": title, "description": description,
                "publication_policy": privateVideo ? "private" : "public",
                "comments_enabled": commentsEnabled, "category": category.rawValue
            ]
            if scheduled && !privateVideo { settings["publish_at"] = publishDate.timeIntervalSince1970 }
            if let cover { settings["cover"] = try await jpegImage(cover, maximum: 1280).base64EncodedString() }
            var job: ImportJob = try await request(sourceEndpoint + "/publish", method: "POST",
                json: settings, headers: ["X-Live-Publication": "1"])
            while job.status == "downloading" {
                try await Task.sleep(for: .seconds(2))
                job = try await request(sourceEndpoint + "/status")
            }
            guard job.status == "queued" else {
                throw ServerError(status: 502, message: job.error ?? "Импорт был прерван.")
            }
            submitted = true
            status = "Видео передано в очередь обработки."
        } catch { status = error.localizedDescription }
    }

    private func upload(_ file: URL) async {
        busy = true
        uploadPhase = "Подготавливаем видео…"
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
            let capabilities: Capabilities = try await request("/api/admin/publication-capabilities")
            guard capabilities.publication_settings, capabilities.video_categories == true else { throw URLError(.badServerResponse) }
            let endpoint = "/api/admin/uploads"
            var state: Transfer
            if let previous = transfer { state = try await request(endpoint + "/" + previous.id) }
            else { state = try await request(endpoint, method: "POST", json: ["size": size]) }
            transfer = state
            progress = Double(state.offset) / Double(size)
            uploadPhase = "Передаём файл на сервер…"
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
            uploadPhase = "Файл передан. Добавляем в очередь обработки…"
            var settings: [String: Any] = [
                "title": title, "description": description, "published": !privateVideo,
                "publication_policy": privateVideo ? "private" : "public", "comments_enabled": commentsEnabled,
                "category": category.rawValue
            ]
            if scheduled && !privateVideo { settings["publish_at"] = publishDate.timeIntervalSince1970 }
            let _: WriteResult = try await request(uploadPath + "/complete", method: "POST", json: settings)
            submitted = true
            status = privateVideo ? "Личное видео отправлено на обработку." : "Видео отправлено на модерацию."
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





private let creatorSurface = Color(red: 0.071, green: 0.114, blue: 0.102)

private extension View {
    func creatorField() -> some View {
        background(creatorSurface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(surface))
    }
}

private func creatorHeader(_ title: String, icon: String, disabled: Bool, close: @escaping () -> Void) -> some View {
    HStack(spacing: 2) {
        Button(action: close) {
            Image(systemName: icon).frame(width: 44, height: 48).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(disabled).accessibilityLabel("Назад")
        Text(title).font(.subheadline.weight(.semibold))
        Spacer()
    }.padding(.trailing, 16)
}

private func creatorButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(title).font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 47)
            .foregroundStyle(appBackground)
            .background(lime, in: RoundedRectangle(cornerRadius: 12))
    }.buttonStyle(.plain)
}

private struct GalleryVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}










private enum LocalDiscovery {
    static let key = "chepushka.discovery.v1"
    static func record(_ id: String) {
        var recent = history()
        recent[id] = Date().timeIntervalSince1970
        let entries = recent.sorted { $0.value > $1.value }.prefix(100)
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) }), forKey: key)
    }
    private static func history() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
    }
    static func rank(_ videos: [Video], saved: Set<String>, followed: Set<String>) -> [Video] {
        let recent = history()
        let now = Date().timeIntervalSince1970
        var channels: [String: Double] = [:]
        var categories: [String: Double] = [:]
        for video in videos {
            let age = (now - (recent[video.id] ?? 0)) / 86400
            let weight = (age <= 45 ? exp(-age / 18) : 0) + (saved.contains(video.id) ? 2 : 0)
            if let channel = video.channel_id { channels[channel, default: 0] += weight }
            if let category = video.category, category != "general" { categories[category, default: 0] += weight }
        }
        func score(_ video: Video) -> Double {
            let channel = video.channel_id ?? ""
            let freshness = max(0, 1 - (now - (video.created ?? 0)) / 2592000)
            return (channels[channel] ?? 0) * 2 + (categories[video.category ?? ""] ?? 0) * 3
                + (followed.contains(channel) ? 2 : 0) + freshness
                + log1p(Double(video.views ?? 0)) * 0.12 - (recent[video.id] == nil ? 0 : 4)
        }
        var ranked = videos.sorted { a, b in
            let left = score(a), right = score(b)
            return left == right ? (a.created ?? 0) > (b.created ?? 0) : left > right
        }
        for index in ranked.indices.dropFirst(2) {
            guard let channel = ranked[index].channel_id, ranked[index - 1].channel_id == channel,
                  ranked[index - 2].channel_id == channel,
                  let next = ranked.indices.dropFirst(index + 1).first(where: { ranked[$0].channel_id != channel }) else { continue }
            let alternate = ranked.remove(at: next)
            ranked.insert(alternate, at: index)
        }
        return ranked
    }
}

private struct OwnerConsoleSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            OwnerConsoleBrowser().navigationTitle("Админ-панель").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
    }
}

private struct OwnerConsoleBrowser: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Keep the server-issued owner cookies across launches of the studio.
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.load(URLRequest(url: origin.appendingPathComponent("api/owner-studio/console")))
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url,
               url.scheme == "https", url.host == "t.me" {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(action.request.url?.host == origin.host && action.request.url?.scheme == "https" ? .allow : .cancel)
        }
        private func presenter(_ view: WKWebView) -> UIViewController? {
            var top = view.window?.rootViewController
            while let presented = top?.presentedViewController { top = presented }
            return top
        }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            guard let top = presenter(webView) else { completionHandler(false); return }
            let alert = UIAlertController(title: message, message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "Продолжить", style: .destructive) { _ in completionHandler(true) })
            top.present(alert, animated: true)
        }
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            guard let top = presenter(webView) else { completionHandler(nil); return }
            let alert = UIAlertController(title: prompt, message: nil, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: "Готово", style: .default) { [weak alert] _ in completionHandler(alert?.textFields?.first?.text) })
            top.present(alert, animated: true)
        }
    }
}
