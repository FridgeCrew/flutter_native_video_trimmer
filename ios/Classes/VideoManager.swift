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
        currentAsset = AVAsset(url: url)
    }
    
    func trimVideo(startTimeMs: Int64, endTimeMs: Int64, includeAudio: Bool = true, completion: @escaping (Result<String, Error>) -> Void) {
        guard let asset = currentAsset else {
            completion(.failure(VideoError.noVideoLoaded))
            return
        }
        
        let compatiblePresets = AVAssetExportSession.exportPresets(compatibleWith: asset)
        guard compatiblePresets.contains(AVAssetExportPresetHighestQuality) else {
            completion(.failure(VideoError.unsupportedFormat))
            return
        }
        // [수정 1] AVMutableComposition 생성 (비디오/오디오 트랙을 직접 제어하기 위해 필요)
        let composition = AVMutableComposition()

        do {
            // 원본 비디오 트랙 가져오기
            guard let videoTrack = asset.tracks(withMediaType: .video).first else {
                completion(.failure(VideoError.invalidVideoTrack))
                return
            }

            // Composition 비디오 트랙 생성 및 삽입
            let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            try compositionVideoTrack?.insertTimeRange(CMTimeRangeMake(start: .zero, duration: asset.duration), of: videoTrack, at: .zero)

            // 오디오 트랙 처리 (includeAudio가 true일 때만)
            if includeAudio, let audioTrack = asset.tracks(withMediaType: .audio).first {
                let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                try compositionAudioTrack?.insertTimeRange(CMTimeRangeMake(start: .zero, duration: asset.duration), of: audioTrack, at: .zero)
            }

            // [수정 2] 비디오 방향(Orientation) 보정 로직 추가
            // 원본 트랙의 변환(Transform) 정보를 가져와서 VideoComposition에 적용합니다.
            let videoComposition = AVMutableVideoComposition()
            videoComposition.renderSize = videoTrack.naturalSize // 일단 원본 사이즈로 설정 (회전 시 바뀔 수 있음)
            videoComposition.frameDuration = CMTime(value: 1, timescale: 30) // 기본 프레임 레이트 (30fps)

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)

            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compositionVideoTrack!)

            // [핵심] 원본 트랙의 Transform을 그대로 적용 (이게 없으면 회전 정보가 날아갑니다)
            let transform = videoTrack.preferredTransform
            layerInstruction.setTransform(transform, at: .zero)

            // [회전 보정 심화] 90도/270도 회전된 경우 renderSize(가로/세로)를 바꿔줘야 잘리지 않습니다.
            if transform.a == 0 && transform.b == 1.0 && transform.d == 0 { // 90도
                 videoComposition.renderSize = CGSize(width: videoTrack.naturalSize.height, height: videoTrack.naturalSize.width)
            } else if transform.a == 0 && transform.b == -1.0 && transform.d == 0 { // 270도
                 videoComposition.renderSize = CGSize(width: videoTrack.naturalSize.height, height: videoTrack.naturalSize.width)
            }
            // (0도, 180도는 가로/세로가 바뀌지 않으므로 naturalSize 그대로 사용)

            instruction.layerInstructions = [layerInstruction]
            videoComposition.instructions = [instruction]


            // [수정 3] ExportSession 생성 시 asset 대신 composition 사용
            guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                completion(.failure(VideoError.exportSessionFailed))
                return
            }

            // [수정 4] 생성한 videoComposition 적용
            exportSession.videoComposition = videoComposition

            // Use cacheDir like Android
            let timestamp = Int64(Date().timeIntervalSince1970)
            let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            let outputURL = cacheDir.appendingPathComponent("video_trimmer_\(timestamp).mp4")

            // Delete any existing file
            try? fileManager.removeItem(at: outputURL)

            exportSession.outputURL = outputURL
            exportSession.outputFileType = .mp4

            // Convert milliseconds to CMTime
            let startTime = CMTime(value: startTimeMs, timescale: 1000)
            let endTime = CMTime(value: endTimeMs, timescale: 1000)

            // Validate time range against asset duration
            let durationSeconds = CMTimeGetSeconds(asset.duration)
            let requestedDuration = Double(endTimeMs) / 1000.0

            // (참고: 부동소수점 오차 등을 고려하여 약간의 여유를 두거나 검증 로직을 유연하게 할 필요가 있습니다)
            guard startTimeMs >= 0 && Double(startTimeMs)/1000.0 < durationSeconds else {
                 completion(.failure(VideoError.invalidTimeRange))
                 return
            }

            let timeRange = CMTimeRange(start: startTime, end: endTime)
            exportSession.timeRange = timeRange

            // (참고) AudioMix 로직은 Composition을 사용하면서 위에서 처리했으므로 삭제하거나
            // 필요하다면 compositionAudioTrack에 대해 적용해야 합니다.
            // 여기서는 includeAudio 체크로 트랙 자체를 안 넣었으므로 AudioMix는 불필요합니다.

            exportSession.exportAsynchronously {
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

        } catch {
             completion(.failure(error))
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
        let enumerator = fileManager.enumerator(at: tempDirectory, includingPropertiesForKeys: nil)

        while let url = enumerator?.nextObject() as? URL {
            if (url.pathExtension == "mp4" || url.pathExtension == "jpg") &&
               url.lastPathComponent.hasPrefix("video_trimmer") {
                try? fileManager.removeItem(at: url)
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
