package com.simform.audio_waveforms

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.Looper
import com.linc.amplituda.Amplituda
import com.linc.amplituda.Compress
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.ceil
import kotlin.math.max

/**
 * Extracts a fixed-width overview waveform with Amplituda's native FFmpeg
 * decoder. The entire source is processed, but native compression limits the
 * intermediate amplitude data to at least one sample per second.
 */
class WaveformExtractor(
    private val path: String,
    expectedPoints: Int,
    private val requestedSamplesPerSecond: Int?,
    private val result: MethodChannel.Result,
    private val context: Context,
) {
    private val expectedPoints = expectedPoints.coerceAtLeast(1)
    private val cancelled = AtomicBoolean(false)
    private val replySubmitted = AtomicBoolean(false)
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var temporarySource: File? = null

    /** Starts extraction without blocking the Flutter platform thread. */
    fun startDecode() {
        extractionExecutor.execute {
            try {
                if (cancelled.get()) return@execute
                val source = resolveSource(path)
                if (cancelled.get()) {
                    cleanupTemporarySource()
                    return@execute
                }

                val durationMillis = readDurationMillis(source)
                val targetPoints = requestedSamplesPerSecond
                    ?.coerceAtLeast(1)
                    ?.times(durationMillis / 1000.0)
                    ?.let { ceil(it).toInt().coerceAtLeast(1) }
                    ?: expectedPoints
                val samplesPerSecond = requestedSamplesPerSecond
                    ?.coerceAtLeast(1)
                    ?: samplesPerSecond(durationMillis, targetPoints)
                val compress = Compress.withParams(Compress.AVERAGE, samplesPerSecond)

                Amplituda(context)
                    .processAudio(source, compress)
                    .get(
                        { amplitudaResult ->
                            try {
                                if (!cancelled.get()) {
                                    submitSuccess(
                                        aggregateAndNormalize(
                                            amplitudaResult.amplitudesAsList(),
                                            targetPoints,
                                        ),
                                    )
                                }
                            } finally {
                                cleanupTemporarySource()
                            }
                        },
                        { exception ->
                            // Amplituda's bundled FFmpeg decoder rejects some otherwise
                            // valid streams (for example, it can fail while submitting an
                            // AAC packet). Do not expose that implementation limitation as
                            // a Flutter error: fall back to Android's codec for this source.
                            extractionExecutor.execute {
                                try {
                                    if (!cancelled.get()) {
                                        val waveform = PlatformWaveformDecoder(
                                            source = source,
                                            expectedPoints = targetPoints,
                                            durationMillis = durationMillis,
                                            isCancelled = cancelled::get,
                                        ).decode()
                                        if (!cancelled.get()) submitSuccess(waveform)
                                    }
                                } catch (fallbackException: Exception) {
                                    if (!cancelled.get()) {
                                        submitError(
                                            fallbackException.message
                                                ?: exception.message
                                                ?: "Failed to extract waveform data.",
                                            "Both the fast and Android compatibility decoders could not process the audio source.",
                                        )
                                    }
                                } finally {
                                    cleanupTemporarySource()
                                }
                            }
                        },
                    )
            } catch (exception: Exception) {
                cleanupTemporarySource()
                if (!cancelled.get()) {
                    submitError(
                        exception.message ?: "Failed to prepare audio source.",
                        "Only local file and content URIs are supported for waveform extraction.",
                    )
                }
            }
        }
    }

    /**
     * Cancels the Flutter request immediately. Amplituda has no public force
     * cancellation API, so an already-running native decode is allowed to end
     * and its callback is ignored.
     */
    fun stop() {
        cancelled.set(true)
        submitError("Waveform extraction cancelled.", "The extraction was cancelled.")
    }

    private fun resolveSource(rawPath: String): File {
        val uri = Uri.parse(rawPath)
        return when (uri.scheme) {
            null -> File(rawPath)
            "file" -> File(uri.path ?: throw IllegalArgumentException("File URI has no path."))
            "content" -> copyContentUriToCache(uri)
            else -> throw IllegalArgumentException("Unsupported URI scheme: ${uri.scheme}")
        }.also { source ->
            if (!source.isFile || !source.canRead()) {
                throw IllegalArgumentException("Audio source is not a readable local file.")
            }
        }
    }

    private fun copyContentUriToCache(uri: Uri): File {
        val file = File.createTempFile("audio_waveform_", ".source", context.cacheDir)
        temporarySource = file
        try {
            context.contentResolver.openInputStream(uri)?.use { input ->
                file.outputStream().use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    while (true) {
                        if (cancelled.get()) {
                            throw InterruptedException("Waveform extraction cancelled.")
                        }
                        val bytesRead = input.read(buffer)
                        if (bytesRead < 0) break
                        output.write(buffer, 0, bytesRead)
                    }
                }
            } ?: throw IllegalArgumentException("Unable to read content URI.")
            return file
        } catch (exception: Exception) {
            file.delete()
            temporarySource = null
            throw exception
        }
    }

    private fun readDurationMillis(source: File): Long {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(source.absolutePath)
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull()
                ?.coerceAtLeast(1L)
                ?: 1L
        } finally {
            retriever.release()
        }
    }

    private fun samplesPerSecond(durationMillis: Long, targetPoints: Int): Int {
        val durationSeconds = max(durationMillis / 1000.0, 1.0)
        return ceil(targetPoints / durationSeconds).toInt().coerceAtLeast(1)
    }

    private fun cleanupTemporarySource() {
        temporarySource?.let { source ->
            source.delete()
            temporarySource = null
        }
    }

    private fun submitSuccess(waveform: List<Double>) {
        if (!replySubmitted.compareAndSet(false, true)) return
        mainHandler.post { result.success(waveform) }
    }

    private fun submitError(message: String, details: String) {
        if (!replySubmitted.compareAndSet(false, true)) return
        mainHandler.post { result.error(Constants.LOG_TAG, message, details) }
    }

    companion object {
        // Amplituda 2.3.0 keeps FFmpeg decoder state in native global
        // variables, so multiple simultaneous JNI extractions can corrupt the
        // shared state and abort the process. Serialize all plugin requests.
        private val extractionExecutor = Executors.newSingleThreadExecutor()

        /**
         * Aggregates compressed amplitudes into equal-duration buckets and
         * normalizes the output to the [0, 1] range expected by Flutter.
         */
        internal fun aggregateAndNormalize(
            amplitudes: List<Int>,
            expectedPoints: Int,
        ): List<Double> {
            val points = expectedPoints.coerceAtLeast(1)
            if (amplitudes.isEmpty()) return List(points) { 0.0 }
            val waveform = ArrayList<Double>(points)
            var maximum = 0.0

            for (point in 0 until points) {
                // A long source can have hundreds of thousands of compressed
                // amplitudes. Keep this multiplication in Long: Int overflow
                // produces a negative bucket start and crashes extraction.
                val start = (point.toLong() * amplitudes.size / points).toInt()
                val endExclusive = max(
                    start + 1,
                    ((point + 1L) * amplitudes.size / points).toInt(),
                )
                    .coerceAtMost(amplitudes.size)
                var sum = 0.0
                for (index in start until endExclusive) {
                    sum += amplitudes[index].coerceAtLeast(0)
                }
                val value = sum / (endExclusive - start)
                waveform.add(value)
                maximum = max(maximum, value)
            }

            if (maximum == 0.0) return List(points) { 0.0 }
            return waveform.map { it / maximum }
        }
    }
}
