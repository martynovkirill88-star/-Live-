import SwiftUI
import AVFoundation
import Network

struct OfflineRecord: Codable, Identifiable {
    let id: String
    var video: Video
    var comments: WatchComments?
    var likes = 0
    var liked = false
    var savedAt = Date()
    var status = "preparing"
    var progress = 0.0
    var bytes: Int64 = 0
    var assetPath: String?
    var generation: String?
    var taskIdentifier: Int?
    var quality = ""
    var error = ""
    var isPrivate: Bool { video.publication_policy == "private" || video.published == false }
}

/// Native HLS packages stay in the application sandbox, never Photos or Files.
final class OfflineLibrary: NSObject, ObservableObject, AVAssetDownloadDelegate {
    static let shared = OfflineLibrary()
    @Published private(set) var records: [String: OfflineRecord] = [:]
    @Published private(set) var online = true
    @Published private(set) var untrackedBytes: Int64 = 0
    @Published private(set) var cleaningStorage = false
    private let monitor = NWPathMonitor()
    private var tasks: [String: AVAssetDownloadTask] = [:]
    private var preparations: [String: Task<Void, Never>] = [:]
    private var validations: [String: Task<Void, Never>] = [:]
    private var lastSaved = Date.distantPast
    private var backgroundEventsFinished = false
    var backgroundCompletion: (() -> Void)?
    static let sessionID = "fun.chepushkavpn.live.offline-hls"
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OfflineVideos", isDirectory: true)
    }
    private lazy var session: AVAssetDownloadURLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.allowsCellularAccess = true
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: self, delegateQueue: .main)
    }()
    private override init() {
        super.init()
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var folder = Self.root; try? folder.setResourceValues(excluded)
        if let data = try? Data(contentsOf: Self.root.appendingPathComponent("index.json")),
           let saved = try? JSONDecoder().decode([String: OfflineRecord].self, from: data) { records = saved }
        for (id, record) in records where record.status == "ready" && assetURL(record) == nil {
            mutate(id) { $0.status = "paused"; $0.error = "Файлы загрузки недоступны. Скачайте видео повторно." }
        }
        monitor.pathUpdateHandler = { [weak self] path in DispatchQueue.main.async { self?.online = path.status == .satisfied } }
        monitor.start(queue: DispatchQueue(label: "live.offline.network"))
        session.getAllTasks { [weak self] restored in DispatchQueue.main.async {
            guard let self else { return }
            var active = Set<String>()
            for case let task as AVAssetDownloadTask in restored {
                guard let id = self.recordID(for: task) else { task.cancel(); continue }
                active.insert(id); self.tasks[id] = task; task.resume()
            }
            active.formUnion(self.tasks.keys); active.formUnion(self.preparations.keys); active.formUnion(self.validations.keys)
            for (id, record) in self.records where ["preparing", "downloading", "checking"].contains(record.status) && !active.contains(id) {
                self.mutate(id) { $0.status = "paused"; $0.error = "Загрузка прервана. Нажмите «Повторить»." }
            }
            for (id, record) in self.records where record.status == "paused" && self.assetURL(record) != nil && !active.contains(id) {
                self.validate(id, generation: record.generation, taskID: record.taskIdentifier, knownComplete: false)
            }
            self.save(force: true)
        } }
    }
    var sorted: [OfflineRecord] { records.values.sorted { $0.savedAt > $1.savedAt } }
    var ready: [OfflineRecord] { sorted.filter { $0.status == "ready" } }
    static func valid(_ id: String) -> Bool { id.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil }
    private static func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    static func artwork(_ path: String?) -> URL? {
        guard let path, let url = URL(string: path), url.scheme == "offline", let id = url.host,
              valid(id), ["/poster.jpg", "/avatar.jpg"].contains(url.path) else { return nil }
        let file = folder(id).appendingPathComponent(String(url.path.dropFirst()))
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }
    func assetURL(_ record: OfflineRecord) -> URL? {
        guard let url = OfflineDownloadPolicy.resolve(record.assetPath) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    private func recordID(for task: URLSessionTask) -> String? {
        guard let description = task.taskDescription, let id = description.split(separator: "|").first.map(String.init),
              let record = records[id], OfflineDownloadPolicy.matches(description: description, taskID: task.taskIdentifier,
                id: id, generation: record.generation, expectedTaskID: record.taskIdentifier, preparing: record.status == "preparing") else { return nil }
        if let active = tasks[id], active.taskIdentifier != task.taskIdentifier { return nil }
        if let task = task as? AVAssetDownloadTask { tasks[id] = task }
        mutate(id) { $0.taskIdentifier = task.taskIdentifier }
        return id
    }
    private func mutate(_ id: String, _ change: (inout OfflineRecord) -> Void) {
        guard var record = records[id] else { return }; change(&record); records[id] = record
    }
    private func save(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastSaved) > 1 else { return }; lastSaved = Date()
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: Self.root.appendingPathComponent("index.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    }
    private struct Social: Decodable { let likes: Int; let liked: Bool }
    @MainActor func start(_ video: Video) {
        guard !cleaningStorage, Self.valid(video.id), !video.live, tasks[video.id] == nil, preparations[video.id] == nil, validations[video.id] == nil else { return }
        if records[video.id]?.status == "ready" { return }
        let id = video.id
        if records[id] != nil { remove(id) }
        records[id] = OfflineRecord(id: id, video: video)
        let generation = UUID().uuidString
        records[id]?.generation = generation
        save(force: true)
        preparations[id] = Task { @MainActor in
            defer { if records[id]?.generation == generation { preparations[id] = nil } }
            do {
                guard online else { throw ServerError(status: 0, message: "Для скачивания нужен интернет.") }
                let detail: Video = try await request("/api/media/" + id)
                guard !detail.live else { throw ServerError(status: 0, message: "Прямой эфир пока нельзя скачать.") }
                let comments: WatchComments = try await request("/api/media/" + id + "/comments")
                let social: Social = try await request("/api/media/" + id + "/social")
                try Task.checkCancellation()
                let folder = Self.folder(id)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(detail)) as! [String: Any]
                if let url = remote(detail.poster) {
                    let image = try await Self.image(url)
                    try Task.checkCancellation()
                    try image.write(to: folder.appendingPathComponent("poster.jpg"), options: .atomic)
                    object["poster"] = "offline://\(id)/poster.jpg"
                }
                if let url = remote(detail.channel_avatar), let image = try? await Self.image(url) {
                    try image.write(to: folder.appendingPathComponent("avatar.jpg"), options: .atomic)
                    object["channel_avatar"] = "offline://\(id)/avatar.jpg"
                }
                let qualities = (detail.qualities ?? []).sorted { $0.height < $1.height }
                let quality = qualities.last(where: { $0.height <= 720 }) ?? qualities.first
                let estimated = Int64((detail.duration ?? 0) * Double(quality?.bitrate ?? 2500) * 125 * 1.15)
                let space = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
                guard space > max(200 * 1024 * 1024, estimated + 150 * 1024 * 1024) else {
                    throw ServerError(status: 0, message: "Недостаточно места. Освободите память и повторите загрузку.")
                }
                guard let manifest = remote(detail.manifest), var parts = URLComponents(url: manifest, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
                if let quality { parts.queryItems = (parts.queryItems ?? []).filter { $0.name != "quality" } + [URLQueryItem(name: "quality", value: quality.code)] }
                guard let url = parts.url else { throw URLError(.badURL) }
                try Task.checkCancellation()
                guard records[id]?.generation == generation else { return }
                let localVideo = try JSONDecoder().decode(Video.self, from: JSONSerialization.data(withJSONObject: object))
                mutate(id) { $0.video = localVideo; $0.comments = comments; $0.likes = social.likes; $0.liked = social.liked; $0.quality = quality.map { "\($0.height)p" } ?? "" }
                let cookies = HTTPCookieStorage.shared.cookies(for: origin) ?? []
                let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: cookies])
                guard let task = session.makeAssetDownloadTask(asset: asset, assetTitle: detail.title, assetArtworkData: nil, options: nil) else {
                    throw ServerError(status: 0, message: "Это видео пока нельзя скачать для офлайн-просмотра.")
                }
                task.taskDescription = id + "|" + generation; tasks[id] = task
                mutate(id) { $0.status = "downloading"; $0.taskIdentifier = task.taskIdentifier }; save(force: true); task.resume()
            } catch {
                if records[id]?.generation == generation { mutate(id) { $0.status = "paused"; $0.error = OfflineDownloadPolicy.message(error) }; save(force: true) }
            }
        }
    }
    private static func image(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 12 * 1024 * 1024, UIImage(data: data) != nil else { throw URLError(.badServerResponse) }
        return data
    }
    func remove(_ id: String) {
        guard Self.valid(id) else { return }
        preparations.removeValue(forKey: id)?.cancel(); tasks.removeValue(forKey: id)?.cancel()
        validations.removeValue(forKey: id)?.cancel()
        if let record = records[id], let asset = assetURL(record), asset.pathExtension == "movpkg" { try? FileManager.default.removeItem(at: asset) }
        try? FileManager.default.removeItem(at: Self.folder(id))
        records.removeValue(forKey: id); save(force: true)
    }
    func clearPrivate() { for record in sorted where record.isPrivate { remove(record.id) } }
    @MainActor func refreshStorage() async {
        guard tasks.isEmpty && preparations.isEmpty && validations.isEmpty else { return }
        let found = await Task.detached(priority: .utility) { OfflineDownloadPolicy.packages() }.value
        guard tasks.isEmpty && preparations.isEmpty && validations.isEmpty else { return }
        let referenced = Set(records.values.compactMap(\.assetPath))
        untrackedBytes = found.filter { !referenced.contains($0.key) }.values.reduce(0, +)
        for (id, record) in records { if let path = record.assetPath, let bytes = found[path] { mutate(id) { $0.bytes = bytes } } }
        save(force: true)
    }
    @MainActor func clearUntracked() async {
        guard tasks.isEmpty && preparations.isEmpty && validations.isEmpty && !cleaningStorage else { return }
        cleaningStorage = true
        defer { cleaningStorage = false }
        let referenced = Set(records.values.compactMap(\.assetPath))
        await Task.detached(priority: .utility) {
            for path in OfflineDownloadPolicy.packages().keys where !referenced.contains(path) {
                if let url = OfflineDownloadPolicy.resolve(path) { try? FileManager.default.removeItem(at: url) }
            }
        }.value
        await refreshStorage()
    }
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        guard let id = recordID(for: assetDownloadTask) else { return }
        let expected = timeRangeExpectedToLoad.duration.seconds
        guard expected.isFinite && expected > 0 else { return }
        let loaded = loadedTimeRanges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        mutate(id) { $0.progress = min(0.99, max(0, loaded / expected)) }; save()
    }
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        saveLocation(location, task: assetDownloadTask)
    }
    // New iOS delivers the destination before download, rather than through the deprecated finish callback.
    @objc(URLSession:assetDownloadTask:willDownloadToURL:)
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL) {
        saveLocation(location, task: assetDownloadTask)
    }
    private func saveLocation(_ location: URL, task: AVAssetDownloadTask) {
        guard let path = OfflineDownloadPolicy.relativePath(location), let id = recordID(for: task) else { return }
        mutate(id) { $0.assetPath = path }; save(force: true)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = recordID(for: task), let record = records[id] else { return }
        if let error {
            tasks[id] = nil
            mutate(id) { $0.status = "paused"; $0.error = OfflineDownloadPolicy.message(error) }
        } else { validate(id, generation: record.generation, taskID: task.taskIdentifier, knownComplete: true) }
        save(force: true)
    }
    private func validate(_ id: String, generation: String?, taskID: Int?, knownComplete: Bool) {
        guard validations[id] == nil else { return }
        mutate(id) { $0.status = "checking"; $0.error = "" }
        validations[id] = Task { @MainActor in
            defer {
                if records[id]?.generation == generation && records[id]?.taskIdentifier == taskID { validations[id] = nil; tasks[id] = nil; save(force: true) }
                finishBackgroundEvents()
            }
            do {
                // Give legacy destination callbacks and AVFoundation's lazy metadata a chance to settle.
                var location: URL?
                for _ in 0..<4 {
                    try Task.checkCancellation()
                    guard let record = records[id], record.generation == generation, record.taskIdentifier == taskID else { return }
                    location = assetURL(record)
                    if location != nil { break }
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
                guard let location else { throw ServerError(status: 0, message: "Не удалось найти сохранённый файл. Нажмите «Повторить».") }
                let local = AVURLAsset(url: location)
                let playable = try await local.load(.isPlayable)
                let cached = local.assetCache?.isPlayableOffline == true
                let bytes = await Task.detached(priority: .utility) { OfflineDownloadPolicy.bytes(at: location) }.value
                try Task.checkCancellation()
                guard records[id]?.generation == generation, records[id]?.taskIdentifier == taskID else { return }
                guard playable && bytes > 0 && (knownComplete || cached) else {
                    throw ServerError(status: 0, message: "Не удалось проверить сохранённое видео. Нажмите «Повторить».")
                }
                mutate(id) { $0.status = "ready"; $0.progress = 1; $0.bytes = bytes; $0.error = "" }
            } catch {
                if records[id]?.generation == generation && records[id]?.taskIdentifier == taskID {
                    mutate(id) { $0.status = "paused"; $0.error = OfflineDownloadPolicy.message(error) }
                }
            }
        }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        backgroundEventsFinished = true
        finishBackgroundEvents()
    }
    private func finishBackgroundEvents() {
        guard backgroundEventsFinished && validations.isEmpty else { return }
        backgroundEventsFinished = false
        let completion = backgroundCompletion; backgroundCompletion = nil; completion?()
    }
}

struct DownloadedVideosView: View {
    @ObservedObject private var library = OfflineLibrary.shared
    @State private var deleting: OfflineRecord?
    @State private var clearUntracked = false
    var embedded = false
    private var size: String { offlineSize(library.sorted.reduce(library.untrackedBytes) { $0 + $1.bytes }) }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text("Скачанные видео").font(.custom("DelaGothicOne-Regular", size: 23))
                Text(library.online ? "Видео хранятся только внутри приложения." : "Нет соединения. Эти видео можно смотреть без интернета.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    if library.untrackedBytes > 0 {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Остатки незавершённых загрузок · " + offlineSize(library.untrackedBytes)).font(.caption).foregroundStyle(.secondary)
                            Button(library.cleaningStorage ? "Очищаем…" : "Освободить место") { clearUntracked = true }.font(.subheadline).disabled(library.cleaningStorage)
                        }
                    }
                if library.sorted.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "arrow.down.to.line").font(.system(size: 38)).foregroundStyle(lime)
                        Text("Пока нет скачанных видео").font(.headline)
                        Text("Откройте видео с интернетом и нажмите значок скачивания под плеером.").font(.subheadline).foregroundStyle(.secondary)
                    }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 50)
                } else {
                    Text("На устройстве · \(size)").font(.caption).foregroundStyle(.secondary)
                    ForEach(library.sorted) { record in
                        HStack(alignment: .top, spacing: 10) {
                            if record.status == "ready" {
                                NavigationLink { Watch(video: record.video, offlineRecord: record) } label: { row(record) }.buttonStyle(.plain)
                            } else { row(record) }
                            VStack(spacing: 0) {
                                if record.status == "paused" {
                                    Button { library.start(record.video) } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
                                        .disabled(!library.online || library.cleaningStorage).accessibilityLabel("Повторить загрузку")
                                }
                                Button(role: .destructive) { deleting = record } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
                                    .accessibilityLabel(record.status == "ready" ? "Удалить скачанное видео" : "Отменить загрузку")
                            }.buttonStyle(.plain)
                        }
                        Divider()
                    }
                }
            }.padding(16)
        }
        .background(appBackground.ignoresSafeArea())
        .task { await library.refreshStorage() }
        .navigationTitle(embedded ? "" : "Скачанные видео").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Удалить загрузку с устройства?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { record in
            Button(record.status == "ready" ? "Удалить загрузку" : "Отменить скачивание", role: .destructive) { library.remove(record.id) }
            Button("Оставить", role: .cancel) {}
        } message: { _ in Text("Видео останется на сайте. Файлы на этом устройстве будут удалены.") }
        .confirmationDialog("Удалить остатки незавершённых загрузок?", isPresented: $clearUntracked, titleVisibility: .visible) {
            Button("Освободить место", role: .destructive) { Task { await library.clearUntracked() } }
            Button("Оставить", role: .cancel) {}
        } message: { Text("Удалятся только старые файлы, не связанные с текущими загрузками. Готовые видео останутся.") }
    }
    private func row(_ record: OfflineRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Artwork(path: record.video.poster).frame(width: 110, height: 62).clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 5) {
                Text(record.video.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(record.video.channel).font(.caption2).foregroundStyle(.secondary)
                if record.status == "ready" {
                    Text(offlineSize(record.bytes) + (record.quality.isEmpty ? "" : " · " + record.quality)).font(.caption2).foregroundStyle(.secondary)
                } else if record.status == "paused" { Text(record.error).font(.caption2).foregroundStyle(.secondary) }
                else { ProgressView(value: record.progress); Text(record.status == "preparing" ? "Подготовка…" : record.status == "checking" ? "Проверяем загрузку…" : "Скачано \(Int(record.progress * 100))%").font(.caption2).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
}

private final class OfflinePlayback: ObservableObject {
    let player: AVPlayer
    @Published var position = 0.0
    @Published var duration = 0.0
    @Published var playing = false
    @Published var failure = ""
    var dragging = false
    private var observer: Any?
    private var status: NSKeyValueObservation?
    private var ready: NSKeyValueObservation?
    private let key: String
    init(url: URL, id: String) {
        key = "offline-position-" + id
        player = AVPlayer(url: url)
        let resume = UserDefaults.standard.double(forKey: key)
        if resume > 0 { player.seek(to: CMTime(seconds: resume, preferredTimescale: 600)) }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.3, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self else { return }
            if !self.dragging { self.position = max(0, time.seconds.isFinite ? time.seconds : 0) }
            let duration = self.player.currentItem?.duration.seconds ?? 0
            if duration.isFinite { self.duration = max(0, duration) }
            if self.position > 0 { UserDefaults.standard.set(self.position >= self.duration - 1 ? 0 : self.position, forKey: self.key) }
        }
        status = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in DispatchQueue.main.async {
            self?.playing = player.timeControlStatus == .playing
            UIApplication.shared.isIdleTimerDisabled = player.timeControlStatus == .playing
        } }
        ready = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in DispatchQueue.main.async {
            if item.status == .failed { self?.failure = "Не удалось открыть загрузку. Удалите её и скачайте видео повторно." }
        } }
    }
    func toggle() {
        if playing { player.pause() }
        else { try? AVAudioSession.sharedInstance().setCategory(.playback); try? AVAudioSession.sharedInstance().setActive(true); player.play() }
    }
    func seek() { player.seek(to: CMTime(seconds: position, preferredTimescale: 600)); dragging = false }
    func stop() { player.pause(); UIApplication.shared.isIdleTimerDisabled = false }
    deinit { if let observer { player.removeTimeObserver(observer) } }
}
private struct OfflineVideoLayer: UIViewRepresentable {
    final class Host: UIView { override class var layerClass: AnyClass { AVPlayerLayer.self } }
    let player: AVPlayer
    func makeUIView(context: Context) -> Host { let view = Host(); (view.layer as? AVPlayerLayer)?.player = player; (view.layer as? AVPlayerLayer)?.videoGravity = .resizeAspect; return view }
    func updateUIView(_ view: Host, context: Context) { (view.layer as? AVPlayerLayer)?.player = player }
}
struct OfflineNativePlayer: View {
    @StateObject private var playback: OfflinePlayback
    @State private var fullscreen = false
    @State private var controls = true
    @State private var hide: Task<Void, Never>?
    @Environment(\.scenePhase) private var scene
    init(url: URL, id: String) { _playback = StateObject(wrappedValue: OfflinePlayback(url: url, id: id)) }
    var body: some View {
        Group { if fullscreen { Color.black } else { canvas(expanded: false) } }
            .aspectRatio(16 / 9, contentMode: .fit)
            .fullScreenCover(isPresented: $fullscreen, onDismiss: { OrientationDelegate.rotate(false) }) {
                canvas(expanded: true).ignoresSafeArea().statusBarHidden()
                    .onAppear { OrientationDelegate.rotate(true) }
                    .overlay(alignment: .topLeading) { Button { fullscreen = false } label: { Image(systemName: "xmark").padding(16).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14)) }.padding(16).accessibilityLabel("Закрыть полноэкранный режим") }
            }
            .onChange(of: playback.playing) { _ in scheduleHide() }
            .onChange(of: scene) { if $0 != .active { playback.stop(); controls = true } }
            .onDisappear { if !fullscreen { playback.stop(); hide?.cancel() } }
    }
    private func scheduleHide() {
        hide?.cancel()
        if playback.playing { hide = Task { @MainActor in try? await Task.sleep(nanoseconds: 3_000_000_000); if !Task.isCancelled && !playback.dragging { controls = false } } }
        else { controls = true }
    }
    private func canvas(expanded: Bool) -> some View {
        ZStack {
            Color.black
            OfflineVideoLayer(player: playback.player).onTapGesture { controls.toggle(); if controls { scheduleHide() } }
            if !playback.failure.isEmpty { Text(playback.failure).font(.caption).multilineTextAlignment(.center).padding(24) }
            else if controls {
                Button { playback.toggle(); scheduleHide() } label: { Image(systemName: playback.playing ? "pause.fill" : "play.fill").font(.system(size: 34)).padding(22) }.accessibilityLabel(playback.playing ? "Пауза" : "Воспроизвести")
                VStack(spacing: 5) {
                    Spacer()
                    Slider(value: $playback.position, in: 0...max(1, playback.duration), onEditingChanged: { editing in playback.dragging = editing; hide?.cancel(); if !editing { playback.seek(); scheduleHide() } }).tint(lime).accessibilityLabel("Позиция воспроизведения")
                    HStack(spacing: 12) {
                        Button { playback.toggle() } label: { Image(systemName: playback.playing ? "pause.fill" : "play.fill").frame(width: 32, height: 32) }
                        Text(clock(playback.position) + " / " + clock(playback.duration)).font(.caption.monospacedDigit())
                        Spacer()
                        Text("Скачано").font(.caption2)
                        Button { fullscreen = !expanded; controls = true } label: { Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").frame(width: 36, height: 36) }.accessibilityLabel("Полный экран")
                    }
                }.padding(.horizontal, 12).padding(.bottom, expanded ? 22 : 8).background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .center, endPoint: .bottom))
            }
        }.foregroundStyle(.white).buttonStyle(.plain)
    }
}
