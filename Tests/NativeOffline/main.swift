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
        Task { @MainActor in
            do {
                guard let location, let relative = OfflineDownloadPolicy.relativePath(location),
                      let restored = OfflineDownloadPolicy.resolve(relative) else { fatalError("Native destination lost") }
                let local = AVURLAsset(url: restored)
                guard try await local.load(.isPlayable) else { fatalError("Completed local package is not playable") }
                let bytes = OfflineDownloadPolicy.bytes(at: restored)
                guard bytes > 0 else { fatalError("Completed package reports zero bytes") }
                let tracks = try await local.loadTracks(withMediaType: .video)
                let reader = try AVAssetReader(asset: local)
                reader.timeRange = CMTimeRange(start: CMTime(seconds: 200, preferredTimescale: 600), duration: CMTime(seconds: 2, preferredTimescale: 600))
                let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: nil)
                reader.add(output)
                guard reader.startReading(), output.copyNextSampleBuffer() != nil else { fatalError("Cannot seek and read local video") }
                reader.cancelReading()
                try FileManager.default.removeItem(at: restored)
                print("PASS native HLS download -> saved destination -> persisted relative path -> playable package -> nonzero bytes -> seek/read local media", bytes)
                exit(0)
            } catch { print("NATIVE_VALIDATION_FAILURE", error); exit(1) }
        }
    }
}
let probe = Probe()
probe.start()
DispatchQueue.main.asyncAfter(deadline: .now() + 180) { print("Native download timed out"); exit(1) }
RunLoop.main.run()
