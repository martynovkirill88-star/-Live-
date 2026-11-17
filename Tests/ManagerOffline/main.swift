import Foundation
import AVFoundation
import Combine

setbuf(stdout, nil)
let id = "ee2e790d691f9f28424526c01108e703"
let mode = CommandLine.arguments.dropFirst().first ?? "download"
var subscription: AnyCancellable?
var finishing = false
var previousStatus = ""
func fail(_ text: String) -> Never { print("FAIL_MANAGER", text); exit(1) }

@MainActor func verify(_ library: OfflineLibrary) async {
    guard !finishing else { return }; finishing = true
    do {
        guard let record = library.records[id], record.status == "ready", record.bytes > 0,
              record.comments != nil, record.assetPath != nil, let local = library.assetURL(record) else { fail("ready snapshot or file missing") }
        let asset = AVURLAsset(url: local)
        guard try await asset.load(.isPlayable) else { fail("Local asset not playable") }
        let item = AVPlayerItem(asset: asset); let player = AVPlayer(playerItem: item)
        player.isMuted = true; player.play()
        for _ in 0..<120 {
            if item.status == .failed { throw item.error ?? NSError(domain: "manager-probe", code: 1) }
            if player.currentTime().seconds > 0.3 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard player.currentTime().seconds > 0.3 else { fail("Local playback stalled") }
        guard await player.seek(to: CMTime(seconds: 200, preferredTimescale: 600)) else { fail("Seek failed") }
        for _ in 0..<100 {
            if player.currentTime().seconds > 200.3 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard player.currentTime().seconds > 200.3 else { fail("Playback after seek stalled") }
        player.pause()
        print("PASS_ACTUAL_MANAGER", mode, record.status, record.bytes, "local playback and seek 200s")
        if mode == "delete" { library.remove(id); guard library.records[id] == nil else { fail("Delete failed") } }
        exit(0)
    } catch { fail(error.localizedDescription) }
}
Task { @MainActor in
    do {
        if mode == "download" {
            let video: Video = try await request("/api/media/" + id)
            try FileManager.default.createDirectory(at: OfflineLibrary.root, withIntermediateDirectories: true)
            var old = OfflineRecord(id: id, video: video)
            old.status = "paused"; old.error = "Не все фрагменты сохранены. Повторите загрузку."
            try JSONEncoder().encode([id: old]).write(to: OfflineLibrary.root.appendingPathComponent("index.json"), options: .atomic)
            let library = OfflineLibrary.shared
            subscription = library.$records.sink { values in
                if let record = values[id] {
                    if record.status != previousStatus { print("MANAGER_STATE", record.status, record.error); previousStatus = record.status }
                    if record.status == "ready" { Task { @MainActor in await verify(library) } }
                    if record.status == "paused" && record.generation != nil { fail(record.error) }
                }
            }
            // A canceled old preparation must not overwrite its immediate retry.
            library.start(video); library.remove(id); library.start(video)
        } else {
            let library = OfflineLibrary.shared
            try await Task.sleep(nanoseconds: 2_000_000_000)
            await verify(library)
        }
    } catch { fail(error.localizedDescription) }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 240) { fail("Manager download timed out") }
RunLoop.main.run()
