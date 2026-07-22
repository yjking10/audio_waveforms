package com.simform.audio_waveforms

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WaveformExtractorTest {
    @Test
    fun aggregatesIntoEqualDurationBucketsAndNormalizes() {
        val waveform = WaveformExtractor.aggregateAndNormalize(
            amplitudes = listOf(0, 10, 20, 30),
            expectedPoints = 2,
        )

        assertEquals(listOf(0.2, 1.0), waveform)
    }

    @Test
    fun returnsRequestedNumberOfSilentPoints() {
        val waveform = WaveformExtractor.aggregateAndNormalize(
            amplitudes = listOf(0, 0),
            expectedPoints = 3,
        )

        assertEquals(listOf(0.0, 0.0, 0.0), waveform)
    }

    @Test
    fun returnsSilentOverviewWhenDecoderHasNoAmplitudeFrames() {
        val waveform = WaveformExtractor.aggregateAndNormalize(
            amplitudes = emptyList(),
            expectedPoints = 3,
        )

        assertEquals(listOf(0.0, 0.0, 0.0), waveform)
    }

    @Test
    fun repeatsShortInputAcrossRequestedOverviewWidth() {
        val waveform = WaveformExtractor.aggregateAndNormalize(
            amplitudes = listOf(10, 20),
            expectedPoints = 4,
        )

        assertEquals(listOf(0.5, 0.5, 1.0, 1.0), waveform)
    }

    @Test
    fun coercesNonPositiveRequestedPointCountToOne() {
        val waveform = WaveformExtractor.aggregateAndNormalize(
            amplitudes = listOf(10, 20),
            expectedPoints = 0,
        )

        assertEquals(listOf(1.0), waveform)
    }

    @Test
    fun doesNotOverflowBucketIndexesForLongAudioOverviews() {
        // 30,000 * 100,000 exceeds Int.MAX_VALUE. This mirrors a long audio
        // source requested with noOfSamplesPerSecond rather than fitWidth.
        val waveform = WaveformExtractor.aggregateAndNormalize(
            amplitudes = List(100_000) { 1 },
            expectedPoints = 30_000,
        )

        assertEquals(30_000, waveform.size)
        assertTrue(waveform.all { it == 1.0 })
    }
}
