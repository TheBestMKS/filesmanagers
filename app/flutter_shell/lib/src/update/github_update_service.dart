import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../storage/app_paths.dart';

class GitHubUpdateInfo {
  const GitHubUpdateInfo({
    required this.tag,
    required this.version,
    required this.name,
    required this.body,
    required this.assetName,
    required this.assetUrl,
    required this.releaseUrl,
    required this.assetSize,
  });

  final String tag;
  final String version;
  final String name;
  final String body;
  final String assetName;
  final Uri assetUrl;
  final Uri releaseUrl;
  final int assetSize;
}

class GitHubUpdateService {
  const GitHubUpdateService({
    this.owner = 'TheBestMKS',
    this.repository = 'filesmanagers',
  });

  final String owner;
  final String repository;

  Future<GitHubUpdateInfo?> check({
    required String currentVersion,
  }) async {
    final uri = Uri.https(
      'api.github.com',
      '/repos/$owner/$repository/releases/latest',
    );
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request = await client.getUrl(uri);
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'filesmanagers-update-checker');
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode == HttpStatus.notFound ||
          response.statusCode == HttpStatus.forbidden ||
          response.statusCode >= 500) {
        return null;
      }
      if (response.statusCode >= 400) {
        return null;
      }
      final raw = await utf8.decodeStream(response);
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return null;
      final tag = decoded['tag_name']?.toString().trim() ?? '';
      final version = _normalizeVersion(tag);
      if (tag.isEmpty || !_isNewer(version, currentVersion)) return null;
      final asset = _selectAsset(decoded['assets']);
      if (asset == null) return null;
      final downloadUrl = asset['browser_download_url']?.toString();
      final releaseUrl = decoded['html_url']?.toString();
      if (downloadUrl == null ||
          releaseUrl == null ||
          Uri.tryParse(downloadUrl)?.hasScheme != true) {
        return null;
      }
      return GitHubUpdateInfo(
        tag: tag,
        version: version,
        name: decoded['name']?.toString() ?? tag,
        body: decoded['body']?.toString() ?? '',
        assetName: asset['name']?.toString() ?? 'update',
        assetUrl: Uri.parse(downloadUrl),
        releaseUrl: Uri.parse(releaseUrl),
        assetSize: asset['size'] is num ? (asset['size'] as num).round() : 0,
      );
    } on SocketException {
      return null;
    } on TimeoutException {
      return null;
    } on FormatException {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<File> download(
    GitHubUpdateInfo update, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    final dir = await AppPaths.protectedCacheDirectory();
    final updatesDir = Directory(
      '${dir.path}${Platform.pathSeparator}updates',
    );
    await updatesDir.create(recursive: true);
    final target = File(
      '${updatesDir.path}${Platform.pathSeparator}${_safeName(update.assetName)}',
    );
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(update.assetUrl);
      request.headers
        ..set(HttpHeaders.userAgentHeader, 'filesmanagers-update-downloader')
        ..set(HttpHeaders.acceptHeader, 'application/octet-stream');
      final response =
          await request.close().timeout(const Duration(seconds: 30));
      if (response.statusCode >= 400) {
        throw HttpException(
          'GitHub asset download failed: HTTP ${response.statusCode}',
          uri: update.assetUrl,
        );
      }
      final total = response.contentLength > 0 ? response.contentLength : null;
      var received = 0;
      final sink = target.openWrite();
      try {
        await for (final chunk in response) {
          received += chunk.length;
          sink.add(chunk);
          onProgress?.call(received, total);
        }
      } finally {
        await sink.close();
      }
      return target;
    } finally {
      client.close(force: true);
    }
  }

  Map<String, Object?>? _selectAsset(Object? assets) {
    if (assets is! List) return null;
    final candidates = assets.whereType<Map>().toList();
    bool matches(Map asset, String value) {
      final name = asset['name']?.toString().toLowerCase() ?? '';
      return name.contains(value.toLowerCase());
    }

    if (Platform.isWindows) {
      return candidates
          .where((asset) => matches(asset, 'windows'))
          .firstOrNull
          ?.map((key, value) => MapEntry(key.toString(), value));
    }
    if (Platform.isAndroid) {
      final android = candidates
          .where((asset) => matches(asset, 'android') && matches(asset, '.apk'))
          .toList();
      final arm64 = android.where((asset) => matches(asset, 'arm64'));
      return (arm64.firstOrNull ?? android.firstOrNull)
          ?.map((key, value) => MapEntry(key.toString(), value));
    }
    if (Platform.isLinux) {
      return candidates
          .where((asset) => matches(asset, 'linux'))
          .firstOrNull
          ?.map((key, value) => MapEntry(key.toString(), value));
    }
    return null;
  }

  bool _isNewer(String remote, String current) {
    final remoteParts = _versionParts(remote);
    final currentParts = _versionParts(current);
    final maxLength = remoteParts.length > currentParts.length
        ? remoteParts.length
        : currentParts.length;
    for (var i = 0; i < maxLength; i++) {
      final a = i < remoteParts.length ? remoteParts[i] : 0;
      final b = i < currentParts.length ? currentParts[i] : 0;
      if (a > b) return true;
      if (a < b) return false;
    }
    return false;
  }

  List<int> _versionParts(String value) => _normalizeVersion(value)
      .split('.')
      .map((part) => int.tryParse(part.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
      .toList();

  String _normalizeVersion(String value) {
    return value.trim().replaceFirst(RegExp(r'^[vV]'), '');
  }

  String _safeName(String name) {
    final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]+'), '_').trim();
    return safe.isEmpty ? 'filesmanagers-update.bin' : safe;
  }
}
