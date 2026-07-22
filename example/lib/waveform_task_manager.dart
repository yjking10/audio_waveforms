import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:audio_waveforms/audio_waveforms.dart';

class WaveformData {
  final int mid;
  final List<double> data;

  String get wvData => json.encode(data);

  WaveformData(this.mid, this.data);
}

class WaveformSyncManager {
  // 单例模式
  WaveformSyncManager._internal();

  static final WaveformSyncManager instance = WaveformSyncManager._internal();

  // 任务队列
  final Queue<_SyncTask> _queue = Queue();

  // 正在处理中的路径，防止重复添加
  final Set<String> _processingPaths = {};
  bool _isWorking = false;

  // 用于通知 UI 或其他模块：某个音频的波形数据同步完成了
  final _onCompletedController = StreamController<WaveformData>.broadcast();

  Stream<WaveformData> get onTaskCompleted => _onCompletedController.stream;

  /// 添加同步任务
  /// [mid] 数据库中的记录ID
  /// [path] 音频文件绝对路径
  void addTask(int mid, String path) {
    // 如果已经在队列或正在处理，直接跳过
    if (_processingPaths.contains(path)) return;

    print('addTask mid=$mid; path=$path');
    _processingPaths.add(path);
    _queue.add(_SyncTask(mid, path));

    // 启动处理机

    _runNext();
  }

  Future<void> _runNext() async {
    if (_isWorking || _queue.isEmpty) return;

    _isWorking = true;
    final task = _queue.removeFirst();
    print('_runNext mid=${task.mid}; path=${task.path}');
    late final waveformExtraction = WaveformExtractionController();

    try {
      final List<double> wvData = await waveformExtraction.extractWaveformData(
          path: task.path,
          // noOfSamples: 100, // 建议固定采样数以便数据库存储一致性
          noOfSamplesPerSecond: 10);

      if (wvData.isNotEmpty) {
        // 2. 完成后更新到数据库
        // 这里调用你提供的 AudioRecordManager

        final model = WaveformData(task.mid, wvData);

        // 3. 发送完成通知 (传递路径或ID，方便UI监听更新)
        _onCompletedController.add(model);
        print("波形同步成功: ${task.path}");
      }
    } catch (e) {
      print("波形同步失败: ${task.path}, 错误: $e");
    } finally {
      // await waveformExtraction.stopWaveformExtraction();
      _processingPaths.remove(task.path);
      _isWorking = false;
      await Future.delayed(const Duration(milliseconds: 1000));

      await _runNext(); // 处理下一个
    }
  }

  // 释放资源
  void dispose() {
    _onCompletedController.close();
  }
}

class _SyncTask {
  final int mid;
  final String path;

  _SyncTask(this.mid, this.path);
}
