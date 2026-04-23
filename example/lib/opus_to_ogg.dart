import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

class OggCrc32 {
  static final List<int> _table = _createTable();

  static List<int> _createTable() {
    const poly = 0x04C11DB7;
    final table = List<int>.filled(256, 0);
    for (int i = 0; i < 256; i++) {
      int r = i << 24;
      for (int j = 0; j < 8; j++) {
        r = (r & 0x80000000 != 0) ? (r << 1) ^ poly : r << 1;
      }
      table[i] = r & 0xffffffff;
    }
    return table;
  }

  static int compute(Uint8List data) {
    int crc = 0;
    for (final b in data) {
      crc = ((crc << 8) ^ _table[((crc >> 24) ^ b) & 0xff]) & 0xffffffff;
    }
    return crc;
  }
}

class OggPageBuilder {
  int _sequence = 0;
  int _serial = DateTime.now().millisecondsSinceEpoch & 0xffffffff;

  OggPageBuilder({int? serial, int sequence = 0})
      : _serial =
            serial ?? (DateTime.now().millisecondsSinceEpoch & 0xffffffff),
        _sequence = sequence;

  /// 重置状态，用于处理新文件
  void reset({int? serial, int sequence = 0}) {
    _sequence = sequence;
    _serial = serial ?? (DateTime.now().millisecondsSinceEpoch & 0xffffffff);
  }

  Uint8List buildPage({
    required List<Uint8List> packets,
    required int granulePos,
    required int headerType,
  }) {
    final segmentTable = <int>[];
    final body = BytesBuilder();

    for (final p in packets) {
      int size = p.length;
      while (size >= 255) {
        segmentTable.add(255);
        size -= 255;
      }
      segmentTable.add(size);
      body.add(p);
    }

    final header = BytesBuilder();
    header.add([0x4f, 0x67, 0x67, 0x53]); // "OggS"
    header.addByte(0); // version
    header.addByte(headerType);
    header.add(_int64LE(granulePos));
    header.add(_int32LE(_serial));
    header.add(_int32LE(_sequence++));
    header.add([0, 0, 0, 0]); // CRC Placeholder (MUST BE 0)
    header.addByte(segmentTable.length);
    header.add(Uint8List.fromList(segmentTable));

    final pageBytes = BytesBuilder();
    pageBytes.add(header.toBytes());
    pageBytes.add(body.toBytes());

    final data = pageBytes.toBytes();

    // 关键修复：确保 CRC 区域在计算前为 0
    data[22] = 0;
    data[23] = 0;
    data[24] = 0;
    data[25] = 0;

    final crc = OggCrc32.compute(data);

    // 填入计算结果
    final crcBytes = _int32LE(crc);
    data[22] = crcBytes[0];
    data[23] = crcBytes[1];
    data[24] = crcBytes[2];
    data[25] = crcBytes[3];

    return data;
  }

  Uint8List _int32LE(int v) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);

  Uint8List _int64LE(int v) =>
      Uint8List(8)..buffer.asByteData().setUint64(0, v, Endian.little);
}

class OpusToOgg {
  final int sampleRate;
  final int channels;
  final int packetsPerPage;

  late final OggPageBuilder _ogg;
  final List<Uint8List> _packetBuffer = [];
  int _granulePos = 0;
  bool _headerSent = false;

  final List<Uint8List> _inputChunks = [];
  int _inputTotalLength = 0;

  OpusToOgg({
    this.sampleRate = 16000,
    this.channels = 1,
    this.packetsPerPage = 10,
    bool headerSent = false, // 新增：标记是否已发送过头信息
    int initialGranulePos = 0, // 新增：起始 granulePos
    int initialSequence = 0, // 新增：起始序列号
    int? initialSerial, // 新增：保持相同的 Serial
  })  : _headerSent = headerSent,
        _granulePos = initialGranulePos {
    _ogg = OggPageBuilder(serial: initialSerial, sequence: initialSequence);
  }

  /// 静态方法：从现有 Ogg 文件中读取最后一页的状态
  static Future<
          ({int granulePos, int sequence, int serial, int originalLength})?>
      readLastPageInfo(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return null;

    final raf = await file.open(mode: FileMode.read);
    try {
      final length = await raf.length();
      if (length < 27) return null; // Ogg Header 最小 27 字节

      // 从文件末尾向前读取一小段（例如 8KB），通常最后一页就在这里
      final readSize = length < 8192 ? length : 8192;
      await raf.setPosition(length - readSize);
      final buffer = await raf.read(readSize.toInt());

      // 从后往前搜 "OggS" (0x4f, 0x67, 0x67, 0x53)
      for (int i = buffer.length - 4; i >= 0; i--) {
        if (buffer[i] == 0x4f &&
            buffer[i + 1] == 0x67 &&
            buffer[i + 2] == 0x67 &&
            buffer[i + 3] == 0x53) {
          // 确保剩余长度足够读取 Header
          if (i + 26 >= buffer.length) continue;

          final view = ByteData.sublistView(buffer, i);
          final granulePos = view.getUint64(6, Endian.little);
          final serial = view.getUint32(14, Endian.little);
          final sequence = view.getUint32(18, Endian.little);

          // 计算含4字节长度头的原始 opus 数据长度：packetCount * (4 + 40)
          const int step48k = 960;
          const int frameSize = 44; // 4字节长度头 + 40字节 payload
          final int originalLength = (granulePos ~/ step48k) * frameSize;

          return (
            granulePos: granulePos,
            sequence: sequence + 1,
            serial: serial,
            originalLength: originalLength,
          );
        }
      }
    } catch (e) {
      print('读取 Ogg 最后一页信息失败: $e');
    } finally {
      await raf.close();
    }
    return null;
  }

  int get _step48k => (48000 * 0.02).toInt();

  /// 从 ogg 文件反推实际接收到的 opus 裸数据长度
  /// 返回值与 _receivedOpusLength 兼容（仅计算 payload 字节，不含4字节长度头）
  /// 即：(granulePos / 960) * 40
  static Future<int?> calcReceivedOpusLength(String filePath) async {
    final info = await readLastPageInfo(filePath);
    if (info == null) return null;
    const int step48k = 960; // (48000 * 0.02).toInt()
    const int payloadSize = 40; // 每帧 opus payload 字节数（不含4字节长度头）
    final int packetCount = info.granulePos ~/ step48k;
    return packetCount * payloadSize;
  }

  /// 从 ogg 文件反推实际接收到的 opus 裸数据长度（含4字节长度头）
  /// 即：(granulePos / 960) * (4 + 40) = packetCount * 44
  static Future<int?> calcReceivedOpusLengthWithHeader(String filePath) async {
    if (filePath.isEmpty) return 0;
    final info = await readLastPageInfo(filePath);
    return info?.originalLength;
  }

  /// 重置转换器所有状态，使其可以重新用于新文件下载
  void reset() {
    _packetBuffer.clear();
    _granulePos = 0;
    _headerSent = false;
    _isClosed = false;
    _inputChunks.clear();
    _inputTotalLength = 0;
    _ogg.reset(); // 同时重置 Ogg 页构建器
  }

  /// 同步处理输入的原始数据块（包含 4 字节 BigEndian 长度头）
  /// 内部会自动拆解成 Opus 包并封装成 Ogg 页
  Uint8List addOpus(Uint8List data) {
    if (data.isEmpty) return Uint8List(0);

    _inputChunks.add(data);
    _inputTotalLength += data.length;

    final outputBuilder = BytesBuilder();

    // 循环提取完整的 Opus 包并处理
    while (_inputTotalLength >= 4) {
      final header = _peekBytes(4);
      final packetLen =
          (header[0] << 24) | (header[1] << 16) | (header[2] << 8) | header[3];

      if (packetLen <= 0 || packetLen > 65535) {
        // 数据异常，清空缓存
        _inputChunks.clear();
        _inputTotalLength = 0;
        break;
      }

      if (_inputTotalLength < 4 + packetLen) break;

      _consume(4);
      final packet = _readBytes(packetLen);

      // 处理提取出的单个 Opus 包，生成 Ogg 数据块
      outputBuilder.add(_processPacket(packet));
    }

    return outputBuilder.toBytes();
  }

  /// 处理单个 Opus 包
  Uint8List _processPacket(Uint8List packet) {
    final builder = BytesBuilder();

    if (!_headerSent) {
      builder.add(_sendHeaders());
      _headerSent = true;
    }

    _packetBuffer.add(packet);

    // Flush when we have more than packetsPerPage, keeping at least 1 packet
    // in the buffer so the EOS page always contains audio data.
    if (_packetBuffer.length > packetsPerPage) {
      builder.add(_flushPage(isLast: false));
    }

    return builder.toBytes();
  }

  Uint8List _flushPage({bool isLast = false}) {
    if (_packetBuffer.isEmpty && !isLast) return Uint8List(0);

    final packetsToFlush = isLast
        ? List<Uint8List>.from(_packetBuffer)
        : List<Uint8List>.from(_packetBuffer.sublist(0, packetsPerPage));

    _granulePos += _step48k * packetsToFlush.length;

    final page = _ogg.buildPage(
      packets: packetsToFlush,
      granulePos: _granulePos,
      headerType: isLast ? 0x04 : 0x00,
    );

    if (isLast) {
      _packetBuffer.clear();
    } else {
      _packetBuffer.removeRange(0, packetsPerPage);
    }

    return page;
  }

  Uint8List _sendHeaders() {
    final builder = BytesBuilder();

    // Page 1: ID Header (BOS)
    builder.add(_ogg.buildPage(
      packets: [_buildOpusHead()],
      granulePos: 0,
      headerType: 0x02,
    ));

    // Page 2: Comment Header
    builder.add(_ogg.buildPage(
      packets: [_buildOpusTags()],
      granulePos: 0,
      headerType: 0x00,
    ));

    return builder.toBytes();
  }

  bool _isClosed = false;

  /// 暂停时调用：将缓冲区中剩余的 Opus 包刷出为一个非 EOS 页
  /// 确保 granulePos 与实际接收字节数同步，以便续传时正确恢复 _receivedOpusLength
  Uint8List flushPartial() {
    if (!_headerSent || _packetBuffer.isEmpty) return Uint8List(0);
    final packetsToFlush = List<Uint8List>.from(_packetBuffer);
    _granulePos += _step48k * packetsToFlush.length;
    final page = _ogg.buildPage(
      packets: packetsToFlush,
      granulePos: _granulePos,
      headerType: 0x00,
    );
    _packetBuffer.clear();
    return page;
  }

  /// 流结束必须调用
  Uint8List flushAndClose() {
    if (_isClosed) return Uint8List(0); // 防止重复关闭
    _isClosed = true;

    // 只有在发送过头信息的情况下才有必要 flush
    if (!_headerSent) {
      return Uint8List(0);
    }
    return _flushPage(isLast: true);
  }

  Uint8List _buildOpusHead() {
    final b = BytesBuilder();
    b.add("OpusHead".codeUnits);
    b.addByte(1); // Version
    b.addByte(channels);
    b.add(Uint8List(2)
      ..buffer.asByteData().setUint16(0, 312, Endian.little)); // Pre-skip
    b.add(Uint8List(4)
      ..buffer
          .asByteData()
          .setUint32(0, sampleRate, Endian.little)); // Original Rate
    b.add(Uint8List(2)
      ..buffer.asByteData().setUint16(0, 0, Endian.little)); // Output Gain
    b.addByte(0); // Mapping Family
    return b.toBytes();
  }

  Uint8List _buildOpusTags() {
    const vendor = "gemini-opus-enc";
    final b = BytesBuilder();
    b.add("OpusTags".codeUnits);
    final vLen = Uint8List(4)
      ..buffer.asByteData().setUint32(0, vendor.length, Endian.little);
    b.add(vLen);
    b.add(vendor.codeUnits);
    b.add([0, 0, 0, 0]); // User Comment List Length (0)
    return b.toBytes();
  }

  // --- Internal Splitter Logic ---

  Uint8List _peekBytes(int n) {
    final res = Uint8List(n);
    int count = 0;
    for (var chunk in _inputChunks) {
      int take = (n - count).clamp(0, chunk.length);
      res.setRange(count, count + take, chunk);
      count += take;
      if (count >= n) break;
    }
    return res;
  }

  Uint8List _readBytes(int n) {
    final res = Uint8List(n);
    int offset = 0;
    while (offset < n) {
      final first = _inputChunks.first;
      int take = (n - offset).clamp(0, first.length);
      res.setRange(offset, offset + take, first);
      offset += take;
      if (take == first.length) {
        _inputChunks.removeAt(0);
      } else {
        _inputChunks[0] = Uint8List.sublistView(first, take);
      }
    }
    _inputTotalLength -= n;
    return res;
  }

  void _consume(int n) {
    int remain = n;
    while (remain > 0 && _inputChunks.isNotEmpty) {
      final first = _inputChunks.first;
      if (first.length <= remain) {
        remain -= first.length;
        _inputChunks.removeAt(0);
      } else {
        _inputChunks[0] = Uint8List.sublistView(first, remain);
        remain = 0;
      }
    }
    _inputTotalLength -= n;
  }
}
