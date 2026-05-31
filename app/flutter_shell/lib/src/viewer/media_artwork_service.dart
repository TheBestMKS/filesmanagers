import 'dart:convert';
import 'dart:typed_data';

import '../platform_services.dart';

class MediaArtworkService {
  const MediaArtworkService._();

  static const int _maxCacheEntries = 256;
  static bool _cacheEnabled = true;
  static final Map<String, Future<Uint8List?>> _audioCache = {};
  static final Map<String, Future<Uint8List?>> _videoCache = {};

  static void configure({required bool cacheEnabled}) {
    if (_cacheEnabled == cacheEnabled) return;
    _cacheEnabled = cacheEnabled;
    if (!cacheEnabled) {
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
      return _cached(_audioCache, key, () => _loadAudioArtwork(path, bytes));
    }
    return _loadAudioArtwork(path, bytes);
  }

  static Future<Uint8List?> videoThumbnail(String path) async {
    if (path.isEmpty) return null;
    if (_cacheEnabled) {
      return _cached(
        _videoCache,
        'video:$path',
        () => PlatformServices.readVideoThumbnail(path).catchError((_) => null),
      );
    }
    return PlatformServices.readVideoThumbnail(path).catchError((_) => null);
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
