import SwiftUI
import AVFoundation
import CoreImage

final class ClipCamera: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate, AVCaptureMetadataOutputObjectsDelegate {
    let session = AVCaptureSession()
    let output = AVCaptureMovieFileOutput()
    private let faces = AVCaptureMetadataOutput()
    @Published private(set) var face: AVMetadataFaceObject?
    @Published private(set) var ready = false
    @Published private(set) var recording = false
    @Published private(set) var issue: String?
    private let queue = DispatchQueue(label: "live.capture")
    private var videoInput: AVCaptureDeviceInput?
    private var microphoneInput: AVCaptureDeviceInput?
    private var completion: ((Result<URL, Error>) -> Void)?
    private var position: AVCaptureDevice.Position = .front

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
                    if self.session.canAddOutput(self.faces) {
                        self.session.addOutput(self.faces)
                        self.faces.setMetadataObjectsDelegate(self, queue: .main)
                        if self.faces.availableMetadataObjectTypes.contains(.face) {
                            self.faces.metadataObjectTypes = [.face]
                        }
                    }
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
        face = nil
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
        face = nil
        queue.async {
            if self.output.isRecording { self.output.stopRecording() }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        face = objects.compactMap { $0 as? AVMetadataFaceObject }.max {
            $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height
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
    let mask: CameraMask
    let face: AVMetadataFaceObject?
    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspectFill
        if view.preview.connection?.isVideoOrientationSupported == true {
            view.preview.connection?.videoOrientation = .portrait
        }
        return view
    }
    func updateUIView(_ uiView: Surface, context: Context) {
        uiView.face = face
        uiView.maskEffect = mask
        uiView.setNeedsLayout()
    }
    final class Surface: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var face: AVMetadataFaceObject?
        var maskEffect = CameraMask.none
        private let sticker = UIImageView()

        override func layoutSubviews() {
            super.layoutSubviews()
            if sticker.superview == nil {
                sticker.contentMode = .scaleAspectFit
                sticker.isUserInteractionEnabled = false
                addSubview(sticker)
            }
            let faceBounds = face.flatMap { preview.transformedMetadataObject(for: $0)?.bounds }
            guard let artwork = maskEffect.artwork,
                  let frame = maskEffect.placement(in: bounds, face: faceBounds, yIncreasesUp: false) else {
                sticker.isHidden = true
                return
            }
            sticker.image = artwork
            sticker.frame = frame
            sticker.isHidden = false
        }
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
            let sticker = mask.artwork.flatMap { CIImage(image: $0) }
            let faces = mask.tracksFace ? ExportFaceTracker() : nil
            exporter.videoComposition = AVVideoComposition(asset: composition, applyingCIFiltersWithHandler: { request in
                let bounds = request.sourceImage.extent
                var image = request.sourceImage
                if mask == .retro { image = image.applyingFilter("CIPhotoEffectInstant").cropped(to: bounds) }
                if mask == .neon {
                    image = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.55]).cropped(to: bounds)
                }
                if let sticker,
                   let frame = mask.placement(in: bounds, face: faces?.bounds(in: image, at: request.compositionTime),
                                              yIncreasesUp: true) {
                    let scaled = sticker.transformed(by: CGAffineTransform(scaleX: frame.width / sticker.extent.width,
                                                                           y: frame.height / sticker.extent.height))
                    let positioned = scaled.transformed(by: CGAffineTransform(translationX: frame.minX, y: frame.minY))
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


}


private final class ExportFaceTracker {
    private let lock = NSLock()
    private let detector = CIDetector(ofType: CIDetectorTypeFace, context: CIContext(),
                                      options: [CIDetectorAccuracy: CIDetectorAccuracyLow])
    private var sample = -1.0
    private var face: CGRect?

    func bounds(in image: CIImage, at time: CMTime) -> CGRect? {
        lock.lock()
        defer { lock.unlock() }
        let seconds = CMTimeGetSeconds(time)
        if abs(seconds - sample) > 0.13 {
            sample = seconds
            face = detector?.features(in: image).map(\.bounds).max {
                $0.width * $0.height < $1.width * $1.height
            }
        }
        return face
    }
}
