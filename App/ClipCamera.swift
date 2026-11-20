import SwiftUI
import AVFoundation
import CoreImage

final class ClipCamera: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    let output = AVCaptureMovieFileOutput()
    @Published private(set) var ready = false
    @Published private(set) var recording = false
    @Published private(set) var issue: String?
    private let queue = DispatchQueue(label: "live.capture")
    private var videoInput: AVCaptureDeviceInput?
    private var microphoneInput: AVCaptureDeviceInput?
    private var completion: ((Result<URL, Error>) -> Void)?
    private var position: AVCaptureDevice.Position = .back

    @MainActor func activate() async {
        guard await Self.authorized(for: .video) else {
            issue = "Разрешите доступ к камере в настройках iPhone или выберите видео из галереи."
            return
        }
        guard !Task.isCancelled else { return }
        queue.async {
            do {
                if self.videoInput == nil {
                    self.session.beginConfiguration()
                    defer { self.session.commitConfiguration() }
                    if self.session.canSetSessionPreset(.high) { self.session.sessionPreset = .high }
                    try self.installCamera(self.position)
                    guard self.session.canAddOutput(self.output) else { throw CameraError.unavailable }
                    self.session.addOutput(self.output)
                }
                if !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.async { self.ready = true }
            } catch {
                DispatchQueue.main.async { self.issue = error.localizedDescription }
            }
        }
    }

    private static func authorized(for kind: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: kind) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: kind)
        default: return false
        }
    }

    private func installCamera(_ next: AVCaptureDevice.Position) throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: next)
        else { throw CameraError.unavailable }
        let replacement = try AVCaptureDeviceInput(device: device)
        let previous = videoInput
        if let previous { session.removeInput(previous) }
        guard session.canAddInput(replacement) else {
            if let previous, session.canAddInput(previous) { session.addInput(previous) }
            throw CameraError.unavailable
        }
        session.addInput(replacement)
        videoInput = replacement
        position = next
    }

    func flip() {
        queue.async {
            guard self.session.isRunning, !self.output.isRecording else { return }
            self.session.beginConfiguration()
            defer { self.session.commitConfiguration() }
            do { try self.installCamera(self.position == .back ? .front : .back) }
            catch { DispatchQueue.main.async { self.issue = error.localizedDescription } }
        }
    }

    @MainActor func record(seconds: Int, microphone: Bool,
                           completion: @escaping (Result<URL, Error>) -> Void) async throws {
        if microphone {
            guard await Self.authorized(for: .audio) else { throw CameraError.microphone }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard self.session.isRunning, !self.output.isRecording, self.completion == nil
                    else { throw CameraError.unavailable }
                    try self.configureMicrophone(microphone)
                    guard let connection = self.output.connection(with: .video) else { throw CameraError.unavailable }
                    if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
                    if connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = self.position == .front
                    }
                    self.output.maxRecordedDuration = CMTime(seconds: Double(seconds), preferredTimescale: 600)
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
                    self.completion = completion
                    self.output.startRecording(to: url, recordingDelegate: self)
                    DispatchQueue.main.async { self.recording = true }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func configureMicrophone(_ on: Bool) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let microphoneInput {
            session.removeInput(microphoneInput)
            self.microphoneInput = nil
        }
        if on {
            guard let device = AVCaptureDevice.default(for: .audio) else { throw CameraError.microphone }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CameraError.microphone }
            session.addInput(input)
            microphoneInput = input
        }
    }

    func stop() {
        queue.async { if self.output.isRecording { self.output.stopRecording() } }
    }

    func shutdown() {
        ready = false
        queue.async {
            if self.output.isRecording { self.output.stopRecording() }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        queue.async {
            let completion = self.completion
            self.completion = nil
            DispatchQueue.main.async {
                self.recording = false
                if let error, (error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool != true {
                    try? FileManager.default.removeItem(at: url)
                    completion?(.failure(error))
                } else { completion?(.success(url)) }
            }
        }
    }
}

enum CameraError: LocalizedError {
    case unavailable, microphone, export
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Камера недоступна."
        case .microphone: return "Разрешите микрофон в настройках iPhone или выберите музыку."
        case .export: return "Не удалось обработать запись."
        }
    }
}

struct CameraSurface: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspectFill
        if view.preview.connection?.isVideoOrientationSupported == true {
            view.preview.connection?.videoOrientation = .portrait
        }
        return view
    }
    func updateUIView(_ uiView: Surface, context: Context) {}
    final class Surface: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

enum CameraExport {
    @MainActor static func prepare(_ url: URL, music: URL?, mask: CameraMask) async throws -> URL {
        guard music != nil || mask != .none else { return url }
        defer { try? FileManager.default.removeItem(at: url) }
        let source = AVURLAsset(url: url)
        let duration = try await source.load(.duration)
        let composition = AVMutableComposition()
        guard let original = try await source.loadTracks(withMediaType: .video).first,
              let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw CameraError.export }
        try video.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: original, at: .zero)
        video.preferredTransform = try await original.load(.preferredTransform)
        let audioAsset = music.map { AVURLAsset(url: $0) } ?? source
        if let originalAudio = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let audioRange = try await originalAudio.load(.timeRange)
            let audioDuration = CMTimeMinimum(audioRange.duration, duration)
            if audioDuration > .zero {
                try audio.insertTimeRange(CMTimeRange(start: audioRange.start, duration: audioDuration), of: originalAudio, at: .zero)
            }
        } else if music != nil { throw CameraError.export }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)
        else { throw CameraError.export }
        if mask != .none {
            let sticker = mask.symbol.flatMap(makeSticker)
            exporter.videoComposition = AVVideoComposition(asset: composition, applyingCIFiltersWithHandler: { request in
                let bounds = request.sourceImage.extent
                var image = request.sourceImage
                if mask == .retro { image = image.applyingFilter("CIPhotoEffectInstant").cropped(to: bounds) }
                if mask == .neon {
                    image = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.55]).cropped(to: bounds)
                }
                if let sticker {
                    let size = bounds.width * 0.19
                    let scaled = sticker.transformed(by: CGAffineTransform(scaleX: size / sticker.extent.width, y: size / sticker.extent.height))
                    let positioned = scaled.transformed(by: CGAffineTransform(translationX: bounds.midX - size / 2, y: bounds.midY - size / 2))
                    image = positioned.composited(over: image).cropped(to: bounds)
                }
                request.finish(with: image, context: nil)
            })
        }
        let final = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        exporter.outputURL = final
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        await exporter.export()
        guard exporter.status == .completed else {
            try? FileManager.default.removeItem(at: final)
            throw exporter.error ?? CameraError.export
        }
        return final
    }

    @MainActor private static func makeSticker(_ symbol: String) -> CIImage? {
        let size = CGSize(width: 120, height: 120)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            (symbol as NSString).draw(in: CGRect(x: 10, y: 10, width: 100, height: 100),
                withAttributes: [.font: UIFont.systemFont(ofSize: 78)])
        }
        return CIImage(image: image)
    }
}
