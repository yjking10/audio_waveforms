import 'package:flutter/material.dart';

import '../../audio_waveforms.dart';

class PlayerWavePainter extends CustomPainter {
  final List<double> waveformData;
  final double animValue;
  final Offset totalBackDistance;
  final Offset dragOffset;
  final double audioProgress;
  final VoidCallback pushBack;
  final bool callPushback;
  final double emptySpace;
  final double scrollScale;
  final WaveformType waveformType;
  final double? dragSeekLinePosition;

  final PlayerWaveStyle playerWaveStyle;

  PlayerWavePainter({
    required this.waveformData,
    required this.animValue,
    required this.dragOffset,
    required this.totalBackDistance,
    required this.audioProgress,
    required this.pushBack,
    required this.callPushback,
    required this.scrollScale,
    required this.waveformType,
    required this.cachedAudioProgress,
    required this.playerWaveStyle,
    this.dragSeekLinePosition,
  })  : fixedWavePaint = Paint()
          ..color = playerWaveStyle.fixedWaveColor
          ..strokeWidth = playerWaveStyle.waveThickness
          ..strokeCap = playerWaveStyle.waveCap
          ..shader = playerWaveStyle.fixedWaveGradient,
        liveWavePaint = Paint()
          ..color = playerWaveStyle.liveWaveColor
          ..strokeWidth = playerWaveStyle.waveThickness
          ..strokeCap = playerWaveStyle.waveCap
          ..shader = playerWaveStyle.liveWaveGradient,
        emptySpace = playerWaveStyle.spacing,
        middleLinePaint = Paint()
          ..color = playerWaveStyle.seekLineColor
          ..strokeWidth = playerWaveStyle.seekLineThickness;

  Paint fixedWavePaint;
  Paint liveWavePaint;
  Paint middleLinePaint;
  double cachedAudioProgress;

  @override
  void paint(Canvas canvas, Size size) {
    _drawWave(size, canvas);
    double? lineX;
    if (playerWaveStyle.showSeekLine && waveformType.isLong) {
      _drawMiddleLine(size, canvas);
    }
    if (playerWaveStyle.showSeekLine && waveformType.isFitWidth) {
      lineX = _drawFitWidthLine(size, canvas);
    }
    // 在拖拽时绘制渐变遮罩，确保遮罩覆盖在波形上
    if (dragSeekLinePosition != null &&
        lineX != null &&
        lineX > 0 &&
        callPushback) {
      print("callPushback  变化  $callPushback");
      _drawDragGradientMask(size, canvas, lineX);
    }
  }

  @override
  bool shouldRepaint(PlayerWavePainter oldDelegate) => true;

  void _drawMiddleLine(Size size, Canvas canvas) {
    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, size.height),
      fixedWavePaint
        ..color = playerWaveStyle.seekLineColor
        ..strokeWidth = playerWaveStyle.seekLineThickness,
    );
  }

  double _drawFitWidthLine(Size size, Canvas canvas) {
    // Calculate line position at the boundary between liveWavePaint and fixedWavePaint
    final length = waveformData.length;
    final currentDragPointer = dragOffset.dx - totalBackDistance.dx;

    // Calculate the exact position where the progress line should be drawn
    // This should be at the boundary between played (liveWavePaint) and unplayed (fixedWavePaint) waves
    final progressIndex = audioProgress * length;
    final waveWidth = progressIndex * playerWaveStyle.spacing;

    final lineX = waveWidth + currentDragPointer + emptySpace;

    // Clamp to visible bounds
    final clampedLineX = lineX.clamp(0.0, size.width);

    canvas.drawLine(
      Offset(clampedLineX, 0),
      Offset(clampedLineX, size.height),
      middleLinePaint
        ..color = playerWaveStyle.seekLineColor
        ..strokeWidth = playerWaveStyle.seekLineThickness,
    );

    return clampedLineX;
  }

  void _drawDragGradientMask(Size size, Canvas canvas, double lineX) {
    // 创建从开始位置到进度线位置的渐变遮罩
    final gradient = LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [
        Color(0xFF99C8D7).withAlpha(0),
        Color(0xFF99C8D7).withAlpha(102),
      ],
      stops: const [0.0, 1.0],
    );

    final gradientPaint = Paint()
      ..shader = gradient.createShader(
        Rect.fromLTWH(0, 0, lineX, size.height),
      )
      ..blendMode = BlendMode.srcOver;

    // 绘制渐变遮罩矩形，覆盖在波形上
    canvas.drawRect(
      Rect.fromLTWH(0, 0, lineX, size.height),
      gradientPaint,
    );
  }

  void _drawWave(Size size, Canvas canvas) {
    final length = waveformData.length;

    final halfWidth = size.width * 0.5;
    final halfHeight = size.height * 0.5;
    if (cachedAudioProgress != audioProgress) {
      pushBack();
    }
    for (int i = 0; i < length; i++) {
      final currentDragPointer = dragOffset.dx - totalBackDistance.dx;
      final waveWidth = i * playerWaveStyle.spacing;
      final dx = waveWidth +
          currentDragPointer +
          emptySpace +
          (waveformType.isFitWidth ? 0 : halfWidth);
      // 移除除以2的操作，让波形更明显
      final waveHeight = (waveformData[i] * animValue) *
          playerWaveStyle.scaleFactor *
          scrollScale;
      final bottomDy =
          halfHeight + (playerWaveStyle.showBottom ? waveHeight : 0);
      final topDy = halfHeight + (playerWaveStyle.showTop ? -waveHeight : 0);

      // Only draw waves which are in visible viewport.
      if (dx > 0 && dx < halfWidth * 2) {
        canvas.drawLine(
          Offset(dx, bottomDy),
          Offset(dx, topDy),
          i < audioProgress * length ? liveWavePaint : fixedWavePaint,
        );
      }
    }
  }
}
