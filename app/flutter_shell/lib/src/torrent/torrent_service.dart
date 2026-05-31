import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../storage/app_paths.dart';

class TorrentMetadata {
  const TorrentMetadata({
    required this.sourcePath,
    required this.name,
    required this.infoHash,
    required this.totalSize,
    required this.files,
  });

  final String sourcePath;
  final String name;
  final String infoHash;
  final int totalSize;
  final List<TorrentFileEntry> files;
}

class TorrentFileEntry {
  const TorrentFileEntry({
    required this.index,
    required this.path,
    required this.sizeBytes,
  });

  final int index;
  final String path;
  final int sizeBytes;

  String get name => path.split('/').last;
}

class TorrentService {
  const TorrentService();

  Future<File> importTorrent(String torrentPath) async {
    final source = File(torrentPath);
    if (!await source.exists()) {
      throw FileSystemException('Torrent file not found', torrentPath);
    }
    final metadata = await readMetadata(torrentPath);
    final torrents = await AppPaths.torrentsDirectory();
    final name = _safeFileName(metadata.name).isEmpty
        ? 'torrent'
        : _safeFileName(metadata.name);
    final target = File(
      '${torrents.path}${Platform.pathSeparator}'
      '${name}_${metadata.infoHash.substring(0, 12)}.torrent',
    );
    if (_normalizePath(source.path) == _normalizePath(target.path)) {
      return target;
    }
    if (!await target.exists()) {
      await target.writeAsBytes(await source.readAsBytes(), flush: true);
    }
    return target;
  }

  Future<TorrentMetadata> readMetadata(String torrentPath) async {
    final bytes = await File(torrentPath).readAsBytes();
    final parser = _BencodeParser(bytes);
    final root = parser.parseRoot();
    final info = root['info'];
    if (info is! Map<String, Object?>) {
      throw const FormatException('Torrent info dictionary is missing.');
    }
    final infoHash = sha1
        .convert(bytes.sublist(parser.infoStart, parser.infoEnd))
        .toString();
    final name = _string(info['name.utf-8'] ?? info['name'] ?? 'torrent');
    final files = <TorrentFileEntry>[];
    final multifile = info['files'];
    if (multifile is List) {
      var index = 0;
      for (final item in multifile.whereType<Map<String, Object?>>()) {
        final length = _int(item['length']);
        final pathList = item['path.utf-8'] ?? item['path'];
        final parts = pathList is List
            ? pathList.map(_string).where((part) => part.isNotEmpty).toList()
            : <String>[_string(pathList)];
        if (parts.isEmpty) continue;
        files.add(TorrentFileEntry(
          index: index++,
          path: parts.join('/'),
          sizeBytes: length,
        ));
      }
    } else {
      files.add(TorrentFileEntry(
        index: 0,
        path: name,
        sizeBytes: _int(info['length']),
      ));
    }
    return TorrentMetadata(
      sourcePath: torrentPath,
      name: name,
      infoHash: infoHash,
      totalSize: files.fold<int>(0, (sum, item) => sum + item.sizeBytes),
      files: files,
    );
  }

  Future<Directory> downloadDirectory(TorrentMetadata metadata) async {
    final torrents = await AppPaths.torrentsDirectory();
    final dir = Directory(
      '${torrents.path}${Platform.pathSeparator}downloads'
      '${Platform.pathSeparator}${metadata.infoHash}',
    );
    await dir.create(recursive: true);
    return dir;
  }

  Future<File> downloadedFile(
      TorrentMetadata metadata, TorrentFileEntry file) async {
    final dir = await downloadDirectory(metadata);
    return File(
      '${dir.path}${Platform.pathSeparator}${file.path.replaceAll('/', Platform.pathSeparator)}',
    );
  }

  Future<ProcessResult> startDownload(
    TorrentMetadata metadata, {
    Iterable<TorrentFileEntry> selectedFiles = const [],
  }) async {
    final dir = await downloadDirectory(metadata);
    final select =
        selectedFiles.map((file) => (file.index + 1).toString()).join(',');
    final args = <String>[
      '--seed-time=0',
      '--continue=true',
      '--summary-interval=1',
      '--dir=${dir.path}',
      if (select.isNotEmpty) '--select-file=$select',
      metadata.sourcePath,
    ];
    return Process.run('aria2c', args, runInShell: Platform.isWindows);
  }

  Future<File?> prepareStreamingFile(
    TorrentMetadata metadata,
    TorrentFileEntry file, {
    Duration waitForFirstBytes = const Duration(seconds: 10),
  }) async {
    final local = await downloadedFile(metadata, file);
    if (await _hasPlayableBytes(local, file)) return local;

    try {
      await _startDownloadDetached(metadata, selectedFiles: [file]);
    } catch (_) {
      return null;
    }

    final deadline = DateTime.now().add(waitForFirstBytes);
    while (DateTime.now().isBefore(deadline)) {
      if (await _hasPlayableBytes(local, file)) return local;
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
    return await local.exists() ? local : null;
  }

  Future<void> _startDownloadDetached(
    TorrentMetadata metadata, {
    Iterable<TorrentFileEntry> selectedFiles = const [],
  }) async {
    final dir = await downloadDirectory(metadata);
    final select =
        selectedFiles.map((file) => (file.index + 1).toString()).join(',');
    final args = <String>[
      '--seed-time=0',
      '--continue=true',
      '--summary-interval=0',
      '--file-allocation=none',
      '--allow-overwrite=true',
      '--auto-file-renaming=false',
      '--bt-prioritize-piece=head=64M,tail=16M',
      '--dir=${dir.path}',
      if (select.isNotEmpty) '--select-file=$select',
      metadata.sourcePath,
    ];
    await Process.start(
      'aria2c',
      args,
      runInShell: Platform.isWindows,
      mode: ProcessStartMode.detached,
    );
  }

  Future<bool> _hasPlayableBytes(File local, TorrentFileEntry file) async {
    if (!await local.exists()) return false;
    final length = await local.length().catchError((_) => 0);
    if (file.sizeBytes <= 0) return length > 0;
    return length >= math.min(file.sizeBytes, 256 * 1024);
  }
}

String _safeFileName(String value) =>
    value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();

String _normalizePath(String path) {
  final normalized = File(path).absolute.path;
  return Platform.isWindows ? normalized.toLowerCase() : normalized;
}

class _BencodeParser {
  _BencodeParser(this.bytes);

  final Uint8List bytes;
  var offset = 0;
  var infoStart = -1;
  var infoEnd = -1;

  Map<String, Object?> parseRoot() {
    final value = _parseValue(isTopLevel: true);
    if (value is! Map<String, Object?>) {
      throw const FormatException('Torrent root must be a dictionary.');
    }
    if (infoStart < 0 || infoEnd <= infoStart) {
      throw const FormatException('Torrent info hash span was not found.');
    }
    return value;
  }

  Object? _parseValue({bool isTopLevel = false}) {
    if (offset >= bytes.length) {
      throw const FormatException('Unexpected end of bencode stream.');
    }
    final byte = bytes[offset];
    if (byte == 0x64) return _parseDictionary(isTopLevel: isTopLevel);
    if (byte == 0x6C) return _parseList();
    if (byte == 0x69) return _parseInteger();
    if (byte >= 0x30 && byte <= 0x39) return _parseBytes();
    throw FormatException('Unexpected bencode byte: $byte');
  }

  Map<String, Object?> _parseDictionary({bool isTopLevel = false}) {
    offset++;
    final result = <String, Object?>{};
    while (offset < bytes.length && bytes[offset] != 0x65) {
      final keyBytes = _parseBytes();
      final key = utf8.decode(keyBytes, allowMalformed: true);
      final valueStart = offset;
      final value = _parseValue();
      if (isTopLevel && key == 'info') {
        infoStart = valueStart;
        infoEnd = offset;
      }
      result[key] = value;
    }
    if (offset >= bytes.length) {
      throw const FormatException('Dictionary is not terminated.');
    }
    offset++;
    return result;
  }

  List<Object?> _parseList() {
    offset++;
    final result = <Object?>[];
    while (offset < bytes.length && bytes[offset] != 0x65) {
      result.add(_parseValue());
    }
    if (offset >= bytes.length) {
      throw const FormatException('List is not terminated.');
    }
    offset++;
    return result;
  }

  int _parseInteger() {
    offset++;
    final start = offset;
    while (offset < bytes.length && bytes[offset] != 0x65) {
      offset++;
    }
    if (offset >= bytes.length) {
      throw const FormatException('Integer is not terminated.');
    }
    final text = ascii.decode(bytes.sublist(start, offset));
    offset++;
    return int.parse(text);
  }

  Uint8List _parseBytes() {
    final start = offset;
    while (offset < bytes.length && bytes[offset] != 0x3A) {
      offset++;
    }
    if (offset >= bytes.length) {
      throw const FormatException('Byte string length is not terminated.');
    }
    final length = int.parse(ascii.decode(bytes.sublist(start, offset)));
    offset++;
    if (offset + length > bytes.length) {
      throw const FormatException('Byte string exceeds input length.');
    }
    final value = bytes.sublist(offset, offset + length);
    offset += length;
    return value;
  }
}

String _string(Object? value) {
  if (value is Uint8List) return utf8.decode(value, allowMalformed: true);
  if (value is List<int>) return utf8.decode(value, allowMalformed: true);
  return value?.toString() ?? '';
}

int _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
