import AVFoundation
import UIKit

class VideoManager {
    static let shared = VideoManager()
    private var currentAsset: AVAsset?
    private let fileManager = FileManager.default
    
    private init() {}
    
    func loadVideo(path: String) throws {
        guard fileManager.fileExists(atPath: path) else {
            throw VideoError.fileNotFound
        }
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        currentAsset = asset
    }
    
    func trimVideo(startTimeMs: Int64, endTimeMs: Int64, includeAudio: Bool = true, completion: @escaping (Result<String, Error>) -> Void) {
        guard let asset = currentAsset else {
            completion(.failure(VideoError.noVideoLoaded))
            return
        }

        // [수정 1] 트랙 정보 비동기 로드 (UI 멈춤 방지)
        let keys = ["tracks", "duration", "preferredTransform", "hasProtectedContent"]
        asset.loadValuesAsynchronously(forKeys: keys) { [weak self] in
            // 여기서부터는 백그라운드 스레드일 수 있음

            // 로드 실패 체크
            var error: NSError? = nil
            if asset.statusOfValue(forKey: "tracks", error: &error) == .failed {
                DispatchQueue.main.async { completion(.failure(VideoError.invalidVideoTrack)) }
                return
            }
            if asset.hasProtectedContent {
                DispatchQueue.main.async { completion(.failure(VideoError.unsupportedFormat)) }
                return
            }

            // --------------------------------------------------------
            // 트랙 로드 완료 후 기존 로직 수행
            // --------------------------------------------------------

            let compatiblePresets = AVAssetExportSession.exportPresets(compatibleWith: asset)
            guard compatiblePresets.contains(AVAssetExportPresetHighestQuality) else {
                DispatchQueue.main.async { completion(.failure(VideoError.unsupportedFormat)) }
                return
            }

            let composition = AVMutableComposition()

            do {
                guard let videoTrack = asset.tracks(withMediaType: .video).first else {
                    DispatchQueue.main.async { completion(.failure(VideoError.invalidVideoTrack)) }
                    return
                }

                guard let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    DispatchQueue.main.async { completion(.failure(VideoError.invalidVideoTrack)) }
                    return
                }
                try compositionVideoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: videoTrack, at: .zero)

                if includeAudio, let audioTrack = asset.tracks(withMediaType: .audio).first,
                   let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try compositionAudioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: asset.duration), of: audioTrack, at: .zero)
                }

                // 비디오 방향 보정
                let videoComposition = AVMutableVideoComposition()
                videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)

                let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack)

                var transform = videoTrack.preferredTransform
                let rotationAngle = atan2(transform.b, transform.a)
                var renderSize = videoTrack.naturalSize

                func isAlmostEqual(_ a: CGFloat, _ b: CGFloat, eps: CGFloat = 0.0001) -> Bool {
                    return abs(a - b) <= eps
                }

                if isAlmostEqual(rotationAngle, .pi / 2) || isAlmostEqual(rotationAngle, -.pi / 2) {
                    renderSize = CGSize(width: videoTrack.naturalSize.height, height: videoTrack.naturalSize.width)
                    transform.tx = 0
                    transform.ty = 0
                    if isAlmostEqual(rotationAngle, .pi / 2) {
                        transform.tx = videoTrack.naturalSize.height
                    } else {
                        transform.ty = videoTrack.naturalSize.width
                    }
                } else if isAlmostEqual(rotationAngle, .pi) || isAlmostEqual(rotationAngle, -.pi) {
                    renderSize = videoTrack.naturalSize
                    transform.tx = videoTrack.naturalSize.width
                    transform.ty = videoTrack.naturalSize.height
                } else {
                    renderSize = videoTrack.naturalSize
                    transform.tx = 0
                    transform.ty = 0
                }

                videoComposition.renderSize = renderSize
                layerInstruction.setTransform(transform, at: .zero)
                instruction.layerInstructions = [layerInstruction]
                videoComposition.instructions = [instruction]

                guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                    DispatchQueue.main.async { completion(.failure(VideoError.exportSessionFailed)) }
                    return
                }

                exportSession.videoComposition = videoComposition

                let timestamp = Int64(Date().timeIntervalSince1970)
                // self 캡처 주의 (FileManager는 thread-safe)
                let fileManager = FileManager.default
                guard let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                    DispatchQueue.main.async { completion(.failure(VideoError.unknown)) }
                    return
                }

                let outputURL = cacheDir.appendingPathComponent("video_trimmer_\(timestamp).mp4")
                try? fileManager.removeItem(at: outputURL)

                exportSession.outputURL = outputURL

                // [수정 2] 파일 타입 안전성 확보 (.mp4 미지원 시 크래시 방지)
                if exportSession.supportedFileTypes.contains(.mp4) {
                    exportSession.outputFileType = .mp4
                } else if let first = exportSession.supportedFileTypes.first {
                    exportSession.outputFileType = first
                } else {
                    DispatchQueue.main.async { completion(.failure(VideoError.unsupportedFormat)) }
                    return
                }

                let startTime = CMTime(value: startTimeMs, timescale: 1000)
                let endTime = CMTime(value: endTimeMs, timescale: 1000)

                let durationSeconds = CMTimeGetSeconds(asset.duration)
                let startSec = Double(startTimeMs) / 1000.0
                let endSec = Double(endTimeMs) / 1000.0

                guard startSec >= 0, endSec > startSec, endSec <= durationSeconds else {
                    DispatchQueue.main.async { completion(.failure(VideoError.invalidTimeRange)) }
                    return
                }

                let timeRange = CMTimeRange(start: startTime, end: endTime)
                exportSession.timeRange = timeRange

                if let firstInstruction = videoComposition.instructions.first as? AVMutableVideoCompositionInstruction {
                    firstInstruction.timeRange = timeRange
                }

                exportSession.exportAsynchronously {
                    DispatchQueue.main.async {
                        switch exportSession.status {
                        case .completed:
                            completion(.success(outputURL.path))
                        case .failed:
                            completion(.failure(exportSession.error ?? VideoError.exportFailed))
                        case .cancelled:
                            completion(.failure(VideoError.exportCancelled))
                        default:
                            completion(.failure(VideoError.unknown))
                        }
                    }
                }

            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
    
    func generateThumbnail(atMs position: Int64, size: CGSize?, quality: Int) throws -> String {
        guard let asset = currentAsset else {
            throw VideoError.noVideoLoaded
        }
        
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if let size = size {
            generator.maximumSize = size
        }
        
        // Convert milliseconds to CMTime
        let time = CMTime(value: position, timescale: 1000)
        let imageRef = try generator.copyCGImage(at: time, actualTime: nil)
        let image = UIImage(cgImage: imageRef)
        
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("video_trimmer_\(timestamp).jpg")
        
        guard let data = image.jpegData(compressionQuality: CGFloat(quality) / 100),
              let _ = try? data.write(to: outputURL) else {
            throw VideoError.thumbnailGenerationFailed
        }
        
        return outputURL.path
    }
    
    func clearCache() {
            let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            let tempEnumerator = fileManager.enumerator(at: tempDirectory, includingPropertiesForKeys: nil)

            while let url = tempEnumerator?.nextObject() as? URL {
                if (url.pathExtension == "mp4" || url.pathExtension == "jpg") &&
                   url.lastPathComponent.hasPrefix("video_trimmer") {
                    try? fileManager.removeItem(at: url)
                }
            }

            // Caches 정리 추가 (trimVideo는 Caches에 저장하므로 여기도 청소 필요)
            if let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
                 let cacheEnumerator = fileManager.enumerator(at: cacheDir, includingPropertiesForKeys: nil)
                 while let url = cacheEnumerator?.nextObject() as? URL {
                     if (url.pathExtension == "mp4" || url.pathExtension == "jpg") &&
                        url.lastPathComponent.hasPrefix("video_trimmer") {
                         try? fileManager.removeItem(at: url)
                     }
                 }
            }
        }
}

enum VideoError: LocalizedError {
    case fileNotFound
    case noVideoLoaded
    case unsupportedFormat
    case exportSessionFailed
    case exportFailed
    case exportCancelled
    case thumbnailGenerationFailed
    case unknown
    case invalidTimeRange
    case invalidVideoTrack
    
    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "Video file not found"
        case .noVideoLoaded:
            return "No video is currently loaded"
        case .unsupportedFormat:
            return "Video format is not supported"
        case .exportSessionFailed:
            return "Failed to create export session"
        case .exportFailed:
            return "Failed to export video"
        case .exportCancelled:
            return "Video export was cancelled"
        case .thumbnailGenerationFailed:
            return "Failed to generate thumbnail"
        case .unknown:
            return "An unknown error occurred"
        case .invalidTimeRange:
            return "Invalid time range. Start time must be non-negative and end time must be greater than start time and within video duration"
        case .invalidVideoTrack:
            return "Invalid video Track."
        }
    }
}
