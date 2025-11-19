package com.example.video_trimmer

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.ScaleAndRotateTransformation
import androidx.media3.transformer.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException


@UnstableApi
class VideoManager {
    private var currentVideoPath: String? = null
//    private var transformer: Transformer? = null
    private val mediaMetadataRetriever = MediaMetadataRetriever()

    companion object {
        @Volatile
        private var instance: VideoManager? = null

        fun getInstance(): VideoManager {
            return instance ?: synchronized(this) {
                instance ?: VideoManager().also { instance = it }
            }
        }
    }

    fun loadVideo(path: String) {
        if (!File(path).exists()) {
            throw VideoException("Video file not found")
        }
        currentVideoPath = path
        mediaMetadataRetriever.setDataSource(path)
    }

   suspend fun trimVideo(
        context: Context,
        startTimeMs: Long,
        endTimeMs: Long,
        includeAudio: Boolean
    ): String {
        val videoPath = currentVideoPath ?: throw VideoException("No video loaded")

        // [1] 무거운 IO 작업 (파일 준비, 메타데이터 읽기) -> Dispatchers.IO
        val (outputFile, rotation) = withContext(Dispatchers.IO) {
            // 파일 준비
            val timestamp = System.currentTimeMillis()
            val file = File(context.cacheDir, "video_trimmer_$timestamp.mp4")
            if (file.exists()) {
                file.delete()
            }

            // 회전 정보 읽기
            val rot = try {
                val retriever = MediaMetadataRetriever()
                retriever.setDataSource(context, Uri.fromFile(File(videoPath)))
                val r = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toFloatOrNull() ?: 0f
                retriever.release()
                r
            } catch (e: Exception) {
                0f
            }

            // 결과 반환 (Pair로 묶어서 전달)
            Pair(file, rot)
        }

        // [2] Transformer 실행 -> Dispatchers.Main (필수!)
        return withContext(Dispatchers.Main) {
            suspendCancellableCoroutine { continuation ->
                val mediaItem = MediaItem.Builder()
                    .setUri(Uri.fromFile(File(videoPath)))
                    .setClippingConfiguration(
                        MediaItem.ClippingConfiguration.Builder()
                            .setStartPositionMs(startTimeMs)
                            .setEndPositionMs(endTimeMs)
                            .build()
                    )
                    .build()

                val videoEffects = ArrayList<Effect>()

                // 회전 보정 (필요 시 주석 해제)
                if (rotation != 0f) {
                    val rotateEffect = ScaleAndRotateTransformation.Builder()
                        .setRotationDegrees(rotation)
                        .build()
                    videoEffects.add(rotateEffect)
                }

                val editedMediaItem = EditedMediaItem.Builder(mediaItem)
                    .setRemoveAudio(!includeAudio)
                    .setEffects(Effects(emptyList(), videoEffects))
                    .build()

                val transformerListener = object : Transformer.Listener {
                    override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                        if (continuation.isActive) {
                            continuation.resume(outputFile.absolutePath)
                        }
                    }

                    override fun onError(
                        composition: Composition,
                        exportResult: ExportResult,
                        exportException: ExportException
                    ) {
                        if (continuation.isActive) {
                            continuation.resumeWithException(VideoException("Failed to trim video", exportException))
                        }
                    }
                }

                // Transformer 생성 및 실행은 Main 스레드에서!
                val transformer = Transformer.Builder(context)
                    .addListener(transformerListener)
                    .experimentalSetTrimOptimizationEnabled(true)
                    .build()

                transformer.start(editedMediaItem, outputFile.absolutePath)
                println("Transformer started "+ outputFile.absolutePath)
                continuation.invokeOnCancellation {
                    transformer.cancel()
                    if (outputFile.exists()) {
                        outputFile.delete()
                    }
                }
            }
        }
    }

    suspend fun generateThumbnail(
        context: Context,
        positionMs: Long,
        width: Int? = null,
        height: Int? = null,
        quality: Int
    ): String = withContext(Dispatchers.IO) {
        if (currentVideoPath == null) {
            throw VideoException("No video loaded")
        }

        val bitmap = mediaMetadataRetriever.getFrameAtTime(
            positionMs * 1000, // Convert to microseconds
            MediaMetadataRetriever.OPTION_CLOSEST_SYNC
        ) ?: throw VideoException("Failed to generate thumbnail")

        val scaledBitmap = if (width != null && height != null) {
            Bitmap.createScaledBitmap(bitmap, width, height, true)
        } else {
            bitmap
        }

        val timestamp = System.currentTimeMillis()
        val outputFile = File(context.cacheDir, "video_trimmer_$timestamp.jpg")
        
        FileOutputStream(outputFile).use { out ->
            scaledBitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)
        }

        if (scaledBitmap != bitmap) {
            scaledBitmap.recycle()
        }
        bitmap.recycle()

        outputFile.absolutePath
    }

    fun clearCache(context: Context) {
        context.cacheDir.listFiles()?.forEach { file ->
            if (file.name.startsWith("video_trimmer_") && 
                (file.extension == "mp4" || file.extension == "jpg")) {
                file.delete()
            }
        }
    }
    fun release() {
//        transformer?.cancel()
//        transformer = null
        mediaMetadataRetriever.release()
        currentVideoPath = null
        synchronized(this) {
            instance = null
        }
    }
}

class VideoException : Exception {
    constructor(message: String) : super(message)
    constructor(message: String, cause: Throwable) : super(message, cause)
}
