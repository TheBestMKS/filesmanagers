import 'dart:async';
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

  static _TorrentHttpStreamer? _streamer;

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
    final candidates = await downloadedFileCandidates(metadata, file);
    for (final candidate in candidates) {
      if (await candidate.exists()) return candidate;
    }
    return candidates.first;
  }

  Future<List<File>> downloadedFileCandidates(
      TorrentMetadata metadata, TorrentFileEntry file) async {
    final dir = await downloadDirectory(metadata);
    final safeRelative = _safeTorrentRelativePath(file.path);
    final candidates = <File>[
      File(_joinPath(dir.path, safeRelative)),
    ];
    final root = _safeFileName(metadata.name);
    if (root.isNotEmpty) {
      candidates.add(File(_joinPath(dir.path, '$root/$safeRelative')));
    }
    return candidates;
  }

  Future<ProcessResult> startDownload(
    TorrentMetadata metadata, {
    Iterable<TorrentFileEntry> selectedFiles = const [],
  }) async {
    final dir = await downloadDirectory(metadata);
    final selected = selectedFiles.toList(growable: false);
    final select =
        selected.map((file) => (file.index + 1).toString()).join(',');
    final args = <String>[
      '--seed-time=0',
      '--continue=true',
      '--summary-interval=1',
      '--stream-piece-selector=inorder',
      '--bt-prioritize-piece=head=64M,tail=16M',
      '--dir=${dir.path}',
      if (select.isNotEmpty) '--select-file=$select',
      for (final file in selected)
        '--index-out=${file.index + 1}=${_safeTorrentRelativePath(file.path)}',
      metadata.sourcePath,
    ];
    return Process.run(
      await _aria2Executable(),
      args,
      runInShell: Platform.isWindows,
    );
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

  Future<Uri> streamingUri(
    TorrentMetadata metadata,
    TorrentFileEntry file,
  ) async {
    final local = await downloadedFile(metadata, file);
    final streamer = _streamer ??= await _TorrentHttpStreamer.start();
    return streamer.add(
      _TorrentStreamSource(
        metadata: metadata,
        file: file,
        localFile: local,
        startDownload: () => _startDownloadDetached(
          metadata,
          selectedFiles: [file],
        ),
      ),
    );
  }

  Future<void> _startDownloadDetached(
    TorrentMetadata metadata, {
    Iterable<TorrentFileEntry> selectedFiles = const [],
  }) async {
    final dir = await downloadDirectory(metadata);
    final selected = selectedFiles.toList(growable: false);
    final select =
        selected.map((file) => (file.index + 1).toString()).join(',');
    final args = <String>[
      '--seed-time=0',
      '--continue=true',
      '--summary-interval=0',
      '--file-allocation=none',
      '--allow-overwrite=true',
      '--auto-file-renaming=false',
      '--stream-piece-selector=inorder',
      '--bt-prioritize-piece=head=64M,tail=16M',
      '--dir=${dir.path}',
      if (select.isNotEmpty) '--select-file=$select',
      for (final file in selected)
        '--index-out=${file.index + 1}=${_safeTorrentRelativePath(file.path)}',
      metadata.sourcePath,
    ];
    await Process.start(
      await _aria2Executable(),
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

  Future<String> _aria2Executable() async {
    final override = Platform.environment['SECUREVAULT_ARIA2C'];
    if (override != null && override.trim().isNotEmpty) {
      return override.trim();
    }
    final executableName = Platform.isWindows ? 'aria2c.exe' : 'aria2c';
    final appDir = File(Platform.resolvedExecutable).parent;
    final bundledCandidates = <File>[
      File('${appDir.path}${Platform.pathSeparator}$executableName'),
      File(
        '${appDir.path}${Platform.pathSeparator}bin'
        '${Platform.pathSeparator}$executableName',
      ),
      File(
        '${appDir.path}${Platform.pathSeparator}tools'
        '${Platform.pathSeparator}$executableName',
      ),
    ];
    if (Platform.isAndroid) {
      final dataDir = await AppPaths.appDataDirectory();
      bundledCandidates.addAll([
        File('${dataDir.path}${Platform.pathSeparator}$executableName'),
        File(
          '${dataDir.path}${Platform.pathSeparator}bin'
          '${Platform.pathSeparator}$executableName',
        ),
      ]);
    }
    for (final candidate in bundledCandidates) {
      if (await candidate.exists()) {
        return candidate.path;
      }
    }
    return 'aria2c';
  }
}

class _TorrentStreamSource {
  _TorrentStreamSource({
    required this.metadata,
    required this.file,
    required this.localFile,
    required this.startDownload,
  });

  final TorrentMetadata metadata;
  final TorrentFileEntry file;
  final File localFile;
  final Future<void> Function() startDownload;
  Future<void>? _downloadStart;

  Future<void> ensureDownloadStarted() {
    final existing = _downloadStart;
    if (existing != null) return existing;
    final started = _startAndResetOnFailure();
    _downloadStart = started;
    return started;
  }

  Future<void> _startAndResetOnFailure() async {
    try {
      await startDownload();
    } catch (_) {
      _downloadStart = null;
      rethrow;
    }
  }
}

class _TorrentHttpStreamer {
  _TorrentHttpStreamer._(this._server);

  final HttpServer _server;
  final Map<String, _TorrentStreamSource> _sources =
      <String, _TorrentStreamSource>{};

  static Future<_TorrentHttpStreamer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final streamer = _TorrentHttpStreamer._(server);
    unawaited(streamer._serve());
    return streamer;
  }

  Uri add(_TorrentStreamSource source) {
    final token = sha1
        .convert(utf8.encode(
          '${source.metadata.infoHash}:${source.file.index}:${source.file.path}',
        ))
        .toString();
    _sources[token] = source;
    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: _server.port,
      pathSegments: ['torrent', token, source.file.name],
    );
  }

  Future<void> _serve() async {
    await for (final request in _server) {
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        response.statusCode = HttpStatus.methodNotAllowed;
        await response.close();
        return;
      }
      final segments = request.uri.pathSegments;
      if (segments.length < 2 || segments.first != 'torrent') {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final source = _sources[segments[1]];
      if (source == null) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }

      final totalSize = math.max(0, source.file.sizeBytes);
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      final range =
          rangeHeader == null ? null : _parseRange(rangeHeader, totalSize);
      if (rangeHeader != null && range == null && totalSize > 0) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes */$totalSize');
        await response.close();
        return;
      }
      final start = range?.$1 ?? 0;
      final end = range?.$2 ?? math.max(0, totalSize - 1);
      final length = totalSize <= 0 ? null : end - start + 1;
      if (request.method != 'HEAD') {
        try {
          await source.ensureDownloadStarted();
        } catch (error) {
          response.statusCode = HttpStatus.serviceUnavailable;
          response.headers.contentType = ContentType.text;
          response.write(
            'Torrent engine is unavailable: $error\n'
            'Install/bundle aria2c or set SECUREVAULT_ARIA2C.',
          );
          await response.close();
          return;
        }
      }
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      response.headers.contentType = _contentTypeFor(source.file.name);
      response.headers.set(
        HttpHeaders.cacheControlHeader,
        'no-store, no-cache, must-revalidate',
      );
      if (range != null) {
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/$totalSize',
        );
      } else {
        response.statusCode = HttpStatus.ok;
      }
      if (length != null) {
        response.contentLength = length;
      }
      if (request.method == 'HEAD') {
        await response.close();
        return;
      }
      await response.flush();
      await _writeRange(response, source.localFile, start, end);
    } catch (error) {
      try {
        response.statusCode = HttpStatus.internalServerError;
        response.headers.contentType = ContentType.text;
        response.write(error.toString());
      } catch (_) {}
      try {
        await response.close();
      } catch (_) {}
    }
  }

  (int, int)? _parseRange(String? header, int totalSize) {
    if (totalSize <= 0) return (0, 0);
    if (header == null || header.trim().isEmpty) {
      return null;
    }
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header.trim());
    if (match == null) return null;
    final startText = match.group(1) ?? '';
    final endText = match.group(2) ?? '';
    if (startText.isEmpty && endText.isEmpty) return null;
    int start;
    int end;
    if (startText.isEmpty) {
      final suffix = int.tryParse(endText) ?? 0;
      if (suffix <= 0) return null;
      start = math.max(0, totalSize - suffix);
      end = totalSize - 1;
    } else {
      start = int.tryParse(startText) ?? -1;
      end = endText.isEmpty ? totalSize - 1 : int.tryParse(endText) ?? -1;
    }
    if (start < 0 || end < start || start >= totalSize) return null;
    return (start, math.min(end, totalSize - 1));
  }

  Future<void> _writeRange(
    HttpResponse response,
    File file,
    int start,
    int end,
  ) async {
    var position = start;
    var idleTicks = 0;
    const maxIdleTicks = 2400; // 10 minutes at 250 ms, enough for slow peers.
    while (position <= end) {
      if (!await file.exists()) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (++idleTicks > maxIdleTicks) break;
        continue;
      }
      final available = await file.length().catchError((_) => 0);
      if (available <= position) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (++idleTicks > maxIdleTicks) break;
        continue;
      }
      idleTicks = 0;
      final nextEnd = math.min(end + 1, available);
      await response.addStream(file.openRead(position, nextEnd));
      position = nextEnd;
      await response.flush();
    }
    await response.close();
  }

  ContentType _contentTypeFor(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.mp4') || lower.endsWith('.m4v')) {
      return ContentType('video', 'mp4');
    }
    if (lower.endsWith('.webm')) return ContentType('video', 'webm');
    if (lower.endsWith('.mkv')) return ContentType('video', 'x-matroska');
    if (lower.endsWith('.avi')) return ContentType('video', 'x-msvideo');
    if (lower.endsWith('.mov')) return ContentType('video', 'quicktime');
    if (lower.endsWith('.mp3')) return ContentType('audio', 'mpeg');
    if (lower.endsWith('.m4a') || lower.endsWith('.aac')) {
      return ContentType('audio', 'aac');
    }
    if (lower.endsWith('.flac')) return ContentType('audio', 'flac');
    if (lower.endsWith('.ogg') || lower.endsWith('.oga')) {
      return ContentType('audio', 'ogg');
    }
    if (lower.endsWith('.wav')) return ContentType('audio', 'wav');
    return ContentType.binary;
  }
}

String _safeFileName(String value) =>
    value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();

String _safeTorrentRelativePath(String value) {
  final parts = value
      .replaceAll('\\', '/')
      .split('/')
      .map(_safeFileName)
      .where((part) => part.isNotEmpty && part != '.' && part != '..')
      .toList(growable: false);
  if (parts.isEmpty) return 'torrent_file';
  return parts.join('/');
}

String _joinPath(String root, String relative) {
  final normalized = relative.replaceAll('/', Platform.pathSeparator);
  return '$root${Platform.pathSeparator}$normalized';
}

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
