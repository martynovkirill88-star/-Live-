import Foundation
import AVFoundation

final class Probe: NSObject, AVAssetDownloadDelegate {
    var location: URL?
    var session: AVAssetDownloadURLSession!
    func start() {
        let config = URLSessionConfiguration.background(withIdentifier: "live-offline-probe-" + UUID().uuidString)
        config.isDiscretionary = false
        session = AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: self, delegateQueue: .main)
        let asset = AVURLAsset(url: URL(string: "https://live.chepushkavpn.fun/api/media/ee2e790d691f9f28424526c01108e703/manifest?quality=144p")!)
        guard let task = session.makeAssetDownloadTask(asset: asset, assetTitle: "Offline regression", assetArtworkData: nil, options: nil) else { fatalError("Native task could not be created") }
        task.resume()
    }
    @objc(URLSession:assetDownloadTask:willDownloadToURL:)
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL) {
        self.location = location; print("Received modern destination callback")
    }
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        self.location = location; print("Received legacy destination callback")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { print("NATIVE_DOWNLOAD_FAILURE", error); exit(1) }
        print("HOME", NSHomeDirectory(), "DESTINATION", location?.absoluteString ?? "nil", "IS_FILE", location?.isFileURL ?? false)
        Task { @MainActor in
            do {
                guard let location, let relative = OfflineDownloadPolicy.relativePath(location),
                      let restored = OfflineDownloadPolicy.resolve(relative, noFollow: OfflineDownloadPolicy.usesNoFollow(location)) else { fatalError("Native destination lost") }
                let local = AVURLAsset(url: restored)
                guard try await local.load(.isPlayable) else { fatalError("Completed local package is not playable") }
                let bytes = OfflineDownloadPolicy.bytes(at: restored)
                guard bytes > 0 else { fatalError("Completed package reports zero bytes") }
                // HLS doesn't expose useful AVAsset duration/tracks until an AVPlayerItem opens it.
                let item = AVPlayerItem(asset: local)
                let player = AVPlayer(playerItem: item)
                player.isMuted = true; player.play()
                for _ in 0..<120 {
                    if item.status == .failed { throw item.error ?? NSError(domain: "probe", code: 1) }
                    if player.currentTime().seconds > 0.3 { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard player.currentTime().seconds > 0.3 else { fatalError("Local HLS playback did not advance") }
                let seeked = await player.seek(to: CMTime(seconds: 200, preferredTimescale: 600))
                guard seeked else { fatalError("Offline seek failed") }
                for _ in 0..<100 {
                    if item.status == .failed { throw item.error ?? NSError(domain: "probe", code: 2) }
                    if player.currentTime().seconds > 200.3 { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard player.currentTime().seconds > 200.3 else { fatalError("Local HLS playback after seek did not advance") }
                player.pause()
                try FileManager.default.removeItem(at: restored)
                print("PASS native HLS download -> saved destination -> persisted relative path -> local playback -> seek 200s -> playback advances, bytes", bytes)
                exit(0)
            } catch { print("NATIVE_VALIDATION_FAILURE", error); exit(1) }
        }
    }
}
let probe = Probe()
setbuf(stdout, nil)
probe.start()
DispatchQueue.main.asyncAfter(deadline: .now() + 180) { print("Native download timed out"); exit(1) }
RunLoop.main.run()
