package com.simform.audio_waveforms

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Compatibility decoder used only when Amplituda cannot decode a stream.
 *
 * It still produces a fixed-width, full-duration overview and never sends
 * intermediate samples over the method channel. Using presentation timestamps
 * rather than decoded-frame counts keeps buckets aligned with the source time.
 */
internal class PlatformWaveformDecoder(
    private val source: File,
    expectedPoints: Int,
    durationMillis: Long,
    private val isCancelled: () -> Boolean,
) {
    private val points = expectedPoints.coerceAtLeast(1)
    private val durationUs = (durationMillis.coerceAtLeast(1L) * 1_000L)
    private val squareSums = DoubleArray(points)
    private val sampleCounts = LongArray(points)

    fun decode(): List<Double> {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(source.absolutePath)
            val trackIndex = findAudioTrack(extractor)
            val inputFormat = extractor.getTrackFormat(trackIndex)
            val mime = inputFormat.getString(MediaFormat.KEY_MIME)
                ?: throw IllegalArgumentException("Audio track has no MIME type.")
            extractor.selectTrack(trackIndex)

            val activeCodec = MediaCodec.createDecoderByType(mime).apply {
                configure(inputFormat, null, null, 0)
                start()
            }
            codec = activeCodec

            val info = MediaCodec.BufferInfo()
            var inputEos = false
            var outputEos = false
            var sampleRate = inputFormat.getIntegerOrNull(MediaFormat.KEY_SAMPLE_RATE) ?: 44_100
            var channels = inputFormat.getIntegerOrNull(MediaFormat.KEY_CHANNEL_COUNT) ?: 1
            var encoding = AudioFormat.ENCODING_PCM_16BIT

            while (!outputEos) {
                ensureNotCancelled()

                if (!inputEos) {
                    val inputIndex = activeCodec.dequeueInputBuffer(TIMEOUT_US)
                    if (inputIndex >= 0) {
                        val inputBuffer = activeCodec.getInputBuffer(inputIndex)
                            ?: throw IllegalStateException("Decoder input buffer is unavailable.")
                        val size = extractor.readSampleData(inputBuffer, 0)
                        if (size < 0) {
                            activeCodec.queueInputBuffer(
                                inputIndex,
                                0,
                                0,
                                0,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            inputEos = true
                        } else {
                            activeCodec.queueInputBuffer(inputIndex, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }

                when (val outputIndex = activeCodec.dequeueOutputBuffer(info, TIMEOUT_US)) {
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val outputFormat = activeCodec.outputFormat
                        sampleRate = outputFormat.getIntegerOrNull(MediaFormat.KEY_SAMPLE_RATE) ?: sampleRate
                        channels = outputFormat.getIntegerOrNull(MediaFormat.KEY_CHANNEL_COUNT) ?: channels
                        encoding = outputFormat.getIntegerOrNull(MediaFormat.KEY_PCM_ENCODING)
                            ?: AudioFormat.ENCODING_PCM_16BIT
                    }

                    in 0..Int.MAX_VALUE -> {
                        try {
                            if (info.size > 0) {
                                activeCodec.getOutputBuffer(outputIndex)?.let { buffer ->
                                    processBuffer(buffer, info, sampleRate, channels, encoding)
                                }
                            }
                        } finally {
                            activeCodec.releaseOutputBuffer(outputIndex, false)
                        }
                        outputEos = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                    }
                }
            }
            return finishWaveform()
        } finally {
            codec?.stopSafely()
            codec?.release()
            extractor.release()
        }
    }

    private fun findAudioTrack(extractor: MediaExtractor): Int {
        for (index in 0 until extractor.trackCount) {
            if (extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                return index
            }
        }
        throw IllegalArgumentException("No audio track found in the source.")
    }

    private fun processBuffer(
        buffer: ByteBuffer,
        info: MediaCodec.BufferInfo,
        sampleRate: Int,
        channels: Int,
        encoding: Int,
    ) {
        val bytesPerSample = when (encoding) {
            AudioFormat.ENCODING_PCM_8BIT -> 1
            AudioFormat.ENCODING_PCM_FLOAT -> 4
            else -> 2
        }
        val frameSize = bytesPerSample * channels.coerceAtLeast(1)
        if (frameSize <= 0) return

        val pcm = buffer.duplicate().order(ByteOrder.LITTLE_ENDIAN)
        pcm.position(info.offset)
        pcm.limit(info.offset + info.size)
        val frameCount = info.size / frameSize
        val safeRate = sampleRate.coerceAtLeast(1)
        for (frameIndex in 0 until frameCount) {
            if ((frameIndex and CANCELLATION_CHECK_MASK) == 0) ensureNotCancelled()
            val timeUs = info.presentationTimeUs + frameIndex * 1_000_000L / safeRate
            val bucket = ((timeUs.coerceAtLeast(0L) * points) / durationUs)
                .toInt()
                .coerceIn(0, points - 1)
            repeat(channels.coerceAtLeast(1)) {
                val value = when (encoding) {
                    AudioFormat.ENCODING_PCM_8BIT -> ((pcm.get().toInt() and 0xff) - 128) / 128.0
                    AudioFormat.ENCODING_PCM_FLOAT -> pcm.float.toDouble()
                    else -> pcm.short.toDouble() / 32_768.0
                }
                if (value.isFinite()) {
                    squareSums[bucket] += value * value
                    sampleCounts[bucket]++
                }
            }
        }
    }

    private fun finishWaveform(): List<Double> {
        val waveform = DoubleArray(points)
        var maximum = 0.0
        for (index in waveform.indices) {
            if (sampleCounts[index] > 0) {
                waveform[index] = sqrt(squareSums[index] / sampleCounts[index])
                maximum = max(maximum, waveform[index])
            }
        }
        return if (maximum == 0.0) List(points) { 0.0 }
        else waveform.map { it / maximum }
    }

    private fun ensureNotCancelled() {
        if (isCancelled()) throw InterruptedException("Waveform extraction cancelled.")
    }

    private fun MediaFormat.getIntegerOrNull(key: String): Int? =
        if (containsKey(key)) getInteger(key) else null

    private fun MediaCodec.stopSafely() {
        try {
            stop()
        } catch (_: IllegalStateException) {
            // The codec may not have completed startup after a configuration error.
        }
    }

    private companion object {
        const val TIMEOUT_US = 10_000L
        const val CANCELLATION_CHECK_MASK = 0x3ff
    }
}
