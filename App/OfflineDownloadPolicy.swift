import Foundation

/// Pure rules shared by native delegates and regression tests.
enum OfflineDownloadPolicy {
    static func relativePath(_ location: URL, home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> String? {
        guard location.isFileURL else { return nil }
        let base = home.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let path = location.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard path.starts(with: base), path.count > base.count + 1 else { return nil }
        let relative = Array(path.dropFirst(base.count))
        guard relative.first == "Library", location.pathExtension == "movpkg", !relative.contains("..") else { return nil }
        return relative.joined(separator: "/")
    }
    static func resolve(_ path: String?, home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> URL? {
        guard let path, path.hasPrefix("Library/"), !path.split(separator: "/").contains("..") else { return nil }
        let url = home.appendingPathComponent(path)
        guard relativePath(url, home: home) != nil else { return nil }
        return url
    }
    static func matches(description: String?, taskID: Int, id: String, generation: String?, expectedTaskID: Int?, preparing: Bool) -> Bool {
        guard let description, !preparing, expectedTaskID == nil || expectedTaskID == taskID else { return false }
        let parts = description.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.first.map(String.init) == id else { return false }
        if let generation { return parts.count == 2 && parts[1] == Substring(generation) }
        return parts.count == 1
    }
    static func bytes(at url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var result: Int64 = 0
        for case let file as URL in files {
            if let value = try? file.resourceValues(forKeys: keys), value.isRegularFile == true {
                result += Int64(max(value.fileSize ?? 0, value.totalFileAllocatedSize ?? value.fileAllocatedSize ?? 0))
            }
        }
        return result
    }
    static func message(_ error: Error) -> String {
        let value = error as NSError
        if error is CancellationError || (value.domain == NSURLErrorDomain && value.code == NSURLErrorCancelled) ||
            (value.domain == NSCocoaErrorDomain && value.code == NSUserCancelledError) {
            return "Загрузка отменена. Нажмите «Повторить», чтобы скачать видео."
        }
        if value.domain == NSURLErrorDomain && [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut].contains(value.code) {
            return "Соединение прервалось. Подключитесь к интернету и повторите загрузку."
        }
        return error.localizedDescription
    }
    static func packages(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [String: Int64] {
        let library = home.appendingPathComponent("Library", isDirectory: true)
        guard let files = FileManager.default.enumerator(at: library, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants]) else { return [:] }
        var result: [String: Int64] = [:]
        for case let file as URL in files where file.pathExtension == "movpkg" {
            files.skipDescendants()
            if let path = relativePath(file, home: home) { result[path] = bytes(at: file) }
        }
        return result
    }
}

func offlineSize(_ bytes: Int64) -> String {
    let value = max(0, Double(bytes))
    if value >= 1_073_741_824 { return String(format: "%.1f ГБ", locale: Locale(identifier: "ru_RU"), value / 1_073_741_824) }
    if value >= 1_048_576 { return String(format: "%.1f МБ", locale: Locale(identifier: "ru_RU"), value / 1_048_576) }
    return value == 0 ? "0 МБ" : String(format: "%.0f КБ", locale: Locale(identifier: "ru_RU"), value / 1024)
}
