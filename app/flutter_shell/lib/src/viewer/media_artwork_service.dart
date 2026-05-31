import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../platform_services.dart';
import '../security/vault_crypto.dart';
import '../storage/app_paths.dart';

class MediaArtworkService {
  const MediaArtworkService._();

  static const int _maxCacheEntries = 256;
  static bool _cacheEnabled = true;
  static bool _persistentCacheEnabled = true;
  static bool _encryptPersistentCache = false;
  static final Map<String, Future<Uint8List?>> _audioCache = {};
  static final Map<String, Future<Uint8List?>> _videoCache = {};

  static void configure({
    required bool cacheEnabled,
    bool persistentCacheEnabled = true,
    bool encryptPersistentCache = false,
  }) {
    final memoryChanged = _cacheEnabled != cacheEnabled;
    _cacheEnabled = cacheEnabled;
    _persistentCacheEnabled = persistentCacheEnabled;
    _encryptPersistentCache = encryptPersistentCache;
    if (!cacheEnabled || memoryChanged) {
      _audioCache.clear();
      _videoCache.clear();
    }
  }

  static Future<Uint8List?> audioArtwork({
    String? path,
    Uint8List? bytes,
  }) async {
    final key = _audioKey(path: path, bytes: bytes);
    if (_cacheEnabled && key != null) {
      return _cached(
        _audioCache,
        key,
        () => _persistentCached(key, () => _loadAudioArtwork(path, bytes)),
      );
    }
    if (key != null) {
      return _persistentCached(key, () => _loadAudioArtwork(path, bytes));
    }
    return _loadAudioArtwork(path, bytes);
  }

  static Future<Uint8List?> videoThumbnail(String path) async {
    if (path.isEmpty) return null;
    if (_cacheEnabled) {
      return _cached(
        _videoCache,
        'video:$path',
        () => _persistentCached(
          'video:$path',
          () =>
              PlatformServices.readVideoThumbnail(path).catchError((_) => null),
        ),
      );
    }
    return _persistentCached(
      'video:$path',
      () => PlatformServices.readVideoThumbnail(path).catchError((_) => null),
    );
  }

  static Future<String?> audioLyrics({
    String? path,
    Uint8List? bytes,
  }) async {
    Uint8List? data = bytes;
    if ((data == null || data.isEmpty) && path != null && path.isNotEmpty) {
      final file = File(path);
      if (await file.exists()) {
        final length = await file.length().catchError((_) => 0);
        final stream = file.openRead(0, length.clamp(0, 2 * 1024 * 1024));
        data =
            Uint8List.fromList(await stream.expand((chunk) => chunk).toList());
      }
    }
    if (data == null || data.isEmpty) return null;
    return Future<String?>(() => _id3v2Lyrics(data!));
  }

  static Future<Uint8List?> _persistentCached(
    String key,
    Future<Uint8List?> Function() loader,
  ) async {
    if (!_persistentCacheEnabled) return loader();
    final file = await _cacheFile(key);
    if (await file.exists()) {
      try {
        final bytes = await file.readAsBytes();
        if (!_encryptPersistentCache) return bytes;
        return VaultCrypto.decryptBytes(
          bytes,
          password: await _deviceSecret(),
          salt: _cacheSalt(key),
          aad: utf8.encode('securevault.thumbnail.v1'),
        );
      } catch (_) {
        await file.delete().catchError((_) => file);
      }
    }
    final loaded = await loader();
    if (loaded == null || loaded.isEmpty) return loaded;
    await file.parent.create(recursive: true);
    if (_encryptPersistentCache) {
      final encrypted = await VaultCrypto.encryptBytes(
        loaded,
        password: await _deviceSecret(),
        salt: _cacheSalt(key),
        aad: utf8.encode('securevault.thumbnail.v1'),
      );
      await file.writeAsBytes(encrypted, flush: true);
    } else {
      await file.writeAsBytes(loaded, flush: true);
    }
    return loaded;
  }

  static Future<File> _cacheFile(String key) async {
    final appData = await AppPaths.appDataDirectory();
    final dir = Directory('${appData.path}${Platform.pathSeparator}thumbnails');
    final digest = sha256.convert(utf8.encode(key)).toString();
    final extension = _encryptPersistentCache ? '.svthumb' : '.thumb';
    return File('${dir.path}${Platform.pathSeparator}$digest$extension');
  }

  static List<int> _cacheSalt(String key) => sha256
      .convert(utf8.encode('securevault.thumbnail.salt:$key'))
      .bytes
      .take(16)
      .toList();

  static Future<String> _deviceSecret() async {
    final appData = await AppPaths.appDataDirectory();
    final file = File(
      '${appData.path}${Platform.pathSeparator}securevault_device_secret.key',
    );
    if (await file.exists()) {
      final existing = (await file.readAsString()).trim();
      if (existing.isNotEmpty) return existing;
    }
    final secret = base64UrlEncode(VaultCrypto.randomBytes(32));
    await file.writeAsString(secret, flush: true);
    return secret;
  }

  static Future<Uint8List?> _loadAudioArtwork(
    String? path,
    Uint8List? bytes,
  ) async {
    if (path != null && path.isNotEmpty) {
      final native =
          await PlatformServices.readMediaArtwork(path).catchError((_) => null);
      if (native != null && native.isNotEmpty) return native;
    }
    if (bytes == null || bytes.isEmpty) return null;
    return Future<Uint8List?>(() => _id3v2Picture(bytes));
  }

  static Future<Uint8List?> _cached(
    Map<String, Future<Uint8List?>> cache,
    String key,
    Future<Uint8List?> Function() loader,
  ) {
    final existing = cache[key];
    if (existing != null) return existing;
    while (cache.length >= _maxCacheEntries) {
      cache.remove(cache.keys.first);
    }
    final future = loader();
    cache[key] = future;
    return future;
  }

  static String? _audioKey({String? path, Uint8List? bytes}) {
    if (path != null && path.isNotEmpty) return 'audio:$path';
    if (bytes == null || bytes.isEmpty) return null;
    return 'audio-bytes:${bytes.length}:${_sampleHash(bytes)}';
  }

  static int _sampleHash(Uint8List bytes) {
    var hash = 0x811C9DC5;
    final take = bytes.length < 128 ? bytes.length : 128;
    for (var i = 0; i < take; i++) {
      hash = (hash ^ bytes[i]) * 0x01000193;
    }
    for (var i = (bytes.length - take).clamp(0, bytes.length);
        i < bytes.length;
        i++) {
      hash = (hash ^ bytes[i]) * 0x01000193;
    }
    return hash & 0x7FFFFFFF;
  }

  static Uint8List? _id3v2Picture(Uint8List bytes) {
    if (bytes.length < 10) return null;
    if (ascii.decode(bytes.sublist(0, 3), allowInvalid: true) != 'ID3') {
      return null;
    }
    final major = bytes[3];
    final flags = bytes[5];
    final tagSize = _syncSafe(bytes, 6);
    var offset = 10;
    final end = (10 + tagSize).clamp(10, bytes.length);

    if ((flags & 0x40) != 0 && offset + 4 < end) {
      final extendedSize =
          major == 4 ? _syncSafe(bytes, offset) : _u32(bytes, offset);
      offset += 4 + extendedSize;
    }

    while (offset + 10 <= end) {
      final id =
          ascii.decode(bytes.sublist(offset, offset + 4), allowInvalid: true);
      if (id.trim().isEmpty) break;
      final frameSize =
          major == 4 ? _syncSafe(bytes, offset + 4) : _u32(bytes, offset + 4);
      final contentStart = offset + 10;
      final contentEnd = (contentStart + frameSize).clamp(contentStart, end);
      if (frameSize <= 0 || contentStart >= contentEnd) break;
      if (id == 'APIC' || id == 'PIC') {
        final picture =
            _findImageSignature(bytes.sublist(contentStart, contentEnd));
        if (picture != null) return picture;
      }
      offset = contentEnd;
    }
    return null;
  }

  static String? _id3v2Lyrics(Uint8List bytes) {
    if (bytes.length < 10) return null;
    if (ascii.decode(bytes.sublist(0, 3), allowInvalid: true) != 'ID3') {
      return null;
    }
    final major = bytes[3];
    final flags = bytes[5];
    final tagSize = _syncSafe(bytes, 6);
    var offset = 10;
    final end = (10 + tagSize).clamp(10, bytes.length);
    if ((flags & 0x40) != 0 && offset + 4 < end) {
      final extendedSize =
          major == 4 ? _syncSafe(bytes, offset) : _u32(bytes, offset);
      offset += 4 + extendedSize;
    }
    while (offset + 10 <= end) {
      final id =
          ascii.decode(bytes.sublist(offset, offset + 4), allowInvalid: true);
      if (id.trim().isEmpty) break;
      final frameSize =
          major == 4 ? _syncSafe(bytes, offset + 4) : _u32(bytes, offset + 4);
      final contentStart = offset + 10;
      final contentEnd = (contentStart + frameSize).clamp(contentStart, end);
      if (frameSize <= 0 || contentStart >= contentEnd) break;
      if (id == 'USLT' || id == 'SYLT') {
        final text = _decodeId3Text(bytes.sublist(contentStart, contentEnd));
        if (text.trim().isNotEmpty) return text.trim();
      }
      offset = contentEnd;
    }
    return null;
  }

  static String _decodeId3Text(Uint8List frame) {
    if (frame.isEmpty) return '';
    final encoding = frame.first;
    var payload = frame.sublist(1);
    if (payload.length > 3 &&
        payload[0] >= 0x61 &&
        payload[0] <= 0x7A &&
        payload[1] >= 0x61 &&
        payload[1] <= 0x7A &&
        payload[2] >= 0x61 &&
        payload[2] <= 0x7A) {
      payload = payload.sublist(3);
    }
    final zero = payload.indexOf(0);
    if (zero >= 0 && zero + 1 < payload.length) {
      payload = payload.sublist(zero + 1);
    }
    return switch (encoding) {
      1 || 2 => _decodeUtf16(payload, littleEndian: encoding == 1),
      3 => utf8.decode(payload, allowMalformed: true),
      _ => latin1.decode(payload, allowInvalid: true),
    }
        .replaceAll('\u0000', '\n')
        .trim();
  }

  static String _decodeUtf16(Uint8List bytes, {required bool littleEndian}) {
    if (bytes.length >= 2) {
      if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
        return _decodeUtf16(bytes.sublist(2), littleEndian: true);
      }
      if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
        return _decodeUtf16(bytes.sublist(2), littleEndian: false);
      }
    }
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add(littleEndian
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(units);
  }

  static Uint8List? _findImageSignature(Uint8List frame) {
    for (var i = 0; i + 4 < frame.length; i++) {
      final isJpeg = frame[i] == 0xFF && frame[i + 1] == 0xD8;
      final isPng = i + 8 < frame.length &&
          frame[i] == 0x89 &&
          frame[i + 1] == 0x50 &&
          frame[i + 2] == 0x4E &&
          frame[i + 3] == 0x47;
      if (isJpeg || isPng) {
        return Uint8List.fromList(frame.sublist(i));
      }
    }
    return null;
  }

  static int _syncSafe(Uint8List bytes, int offset) {
    if (offset + 3 >= bytes.length) return 0;
    return ((bytes[offset] & 0x7F) << 21) |
        ((bytes[offset + 1] & 0x7F) << 14) |
        ((bytes[offset + 2] & 0x7F) << 7) |
        (bytes[offset + 3] & 0x7F);
  }

  static int _u32(Uint8List bytes, int offset) {
    if (offset + 3 >= bytes.length) return 0;
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
  }
}
