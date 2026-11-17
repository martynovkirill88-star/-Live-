import Foundation

func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() { fatalError(label) }
}
let manager = FileManager.default
let base = manager.temporaryDirectory.appendingPathComponent("offline-policy-" + UUID().uuidString)
let home = base.appendingPathComponent("home")
let package = home.appendingPathComponent("Library/UserManagedAssets/video.movpkg")
try manager.createDirectory(at: package, withIntermediateDirectories: true)
try Data(repeating: 7, count: 4096).write(to: package.appendingPathComponent("segment.ts"))
let alias = base.appendingPathComponent("home-alias")
try manager.createSymbolicLink(at: alias, withDestinationURL: home)
check(OfflineDownloadPolicy.relativePath(alias.appendingPathComponent("Library/UserManagedAssets/video.movpkg"), home: home) == "Library/UserManagedAssets/video.movpkg", "Symlink/private-var path alias rejected")
check(OfflineDownloadPolicy.relativePath(package, home: alias) == "Library/UserManagedAssets/video.movpkg", "Home alias rejected")
let noFollow = URL(fileURLWithPath: "/.nofollow" + package.path)
check(OfflineDownloadPolicy.relativePath(noFollow, home: home) == "Library/UserManagedAssets/video.movpkg", "Apple protected path rejected")
check(OfflineDownloadPolicy.resolve("Library/UserManagedAssets/video.movpkg", home: home, noFollow: true)?.path.hasPrefix("/.nofollow/") == true, "Protected path alias lost")
check(OfflineDownloadPolicy.relativePath(base.appendingPathComponent("other/Library/x.movpkg"), home: home) == nil, "External package accepted")
check(OfflineDownloadPolicy.resolve("Library/../../elsewhere.movpkg", home: home) == nil, "Traversal accepted")
check(OfflineDownloadPolicy.resolve("Library/", home: home) == nil, "Library itself accepted as package")
check(OfflineDownloadPolicy.bytes(at: package) >= 4096, "Completed package reports zero size")
check(OfflineDownloadPolicy.packages(home: home)["Library/UserManagedAssets/video.movpkg"] != nil, "Untracked old package cannot be found")
check(OfflineDownloadPolicy.matches(description: "a|new", taskID: 2, id: "a", generation: "new", expectedTaskID: 2, preparing: false), "Current callback rejected")
check(!OfflineDownloadPolicy.matches(description: "a|old", taskID: 1, id: "a", generation: "new", expectedTaskID: 2, preparing: false), "Stale cancellation can overwrite retry")
check(!OfflineDownloadPolicy.matches(description: "a|old", taskID: 1, id: "a", generation: "new", expectedTaskID: nil, preparing: true), "Canceled preparation can adopt new row")
check(OfflineDownloadPolicy.matches(description: "a", taskID: 1, id: "a", generation: nil, expectedTaskID: nil, preparing: false), "Legacy restored callback rejected")
check(OfflineDownloadPolicy.message(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)).contains("отменена"), "Raw English cancellation exposed")
check(offlineSize(0) == "0 МБ", "English Zero KB label")
try manager.removeItem(at: base)
print("PASS offline paths, aliases, occupied size, orphan discovery, task generations, legacy restore and cancellation text")
