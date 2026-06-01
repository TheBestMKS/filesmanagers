import 'dart:convert';
import 'dart:io';

import '../explorer/explorer_models.dart';
import '../viewer/file_viewer_service.dart';
import 'cloud_plugin_registry.dart';

class PluginMediaSection {
  const PluginMediaSection({
    required this.pluginId,
    required this.sectionId,
    required this.title,
    required this.kind,
    required this.baseUrl,
    required this.searchPath,
    this.siteId,
  });

  final String pluginId;
  final String sectionId;
  final String title;
  final FileContentKind kind;
  final String baseUrl;
  final String searchPath;
  final String? siteId;

  String get runtimeId => siteId == null
      ? 'plugin:$pluginId:$sectionId'
      : 'plugin:$pluginId:$sectionId:$siteId';
}

class PluginRuntime {
  const PluginRuntime(this.plugins, this.settingsByPluginId);

  final List<CloudPluginDefinition> plugins;
  final Map<String, Map<String, String>> settingsByPluginId;

  bool get hasTorrentPlugin => plugins.any((plugin) =>
      plugin.id == 'securevault-torrent' &&
      plugin.capabilities.contains('torrentStreaming') &&
      _settingBool(plugin.id, 'createTorrentSection', defaultValue: true));

  bool handlesFileExtension(String extension) {
    final normalized = extension.toLowerCase();
    for (final plugin in plugins) {
      if (plugin.id == 'securevault-torrent' &&
          !_settingBool(plugin.id, 'handleTorrentFiles', defaultValue: true)) {
        continue;
      }
      final handlers = plugin.raw['fileHandlers'];
      if (handlers is! List) continue;
      for (final handler in handlers.whereType<Map>()) {
        final extensions = handler['extensions'];
        if (extensions is List &&
            extensions
                .map((item) => item.toString().toLowerCase())
                .contains(normalized)) {
          return true;
        }
      }
    }
    return false;
  }

  bool get hasUniversalMusicPlugin => plugins.any((plugin) =>
      plugin.id == 'universal-web-music' &&
      plugin.capabilities.contains('musicSourceProfiles'));

  List<PluginMediaSection> mediaSections() {
    final result = <PluginMediaSection>[];
    for (final plugin in plugins) {
      final catalog = plugin.mediaCatalog;
      if (catalog == null || catalog['executor'] != 'web-music-parser') {
        continue;
      }
      if (plugin.id == 'universal-web-music') {
        result.addAll(_universalMusicSections(plugin));
        continue;
      }
      final sites = catalog['sites'];
      if (sites is! List) continue;
      final settings =
          settingsByPluginId[plugin.id] ?? const <String, String>{};
      for (final site in sites.whereType<Map>()) {
        final title = site['title']?.toString() ?? plugin.name;
        final defaultBaseUrl = site['baseUrl']?.toString() ?? '';
        final baseUrl = settings['baseUrl']?.trim().isNotEmpty == true
            ? settings['baseUrl']!.trim()
            : defaultBaseUrl;
        if (baseUrl.isEmpty) continue;
        result.add(PluginMediaSection(
          pluginId: plugin.id,
          sectionId: site['id']?.toString() ?? 'music',
          title: title,
          kind: FileContentKind.audio,
          baseUrl: baseUrl,
          searchPath: site['searchPath']?.toString() ?? '/search?q={query}',
        ));
      }
    }
    result.sort((a, b) => a.title.compareTo(b.title));
    return result;
  }

  List<PluginMediaSection> _universalMusicSections(
      CloudPluginDefinition plugin) {
    final settings = settingsByPluginId[plugin.id] ?? const <String, String>{};
    final rawSites = settings['sitesJson'];
    if (rawSites == null || rawSites.trim().isEmpty) {
      return const <PluginMediaSection>[];
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(rawSites);
    } catch (_) {
      return const <PluginMediaSection>[];
    }
    if (decoded is! List) return const <PluginMediaSection>[];
    final result = <PluginMediaSection>[];
    for (final item in decoded.whereType<Map>()) {
      final title = item['title']?.toString().trim() ?? '';
      final baseUrl = item['baseUrl']?.toString().trim() ?? '';
      if (title.isEmpty || baseUrl.isEmpty) continue;
      result.add(PluginMediaSection(
        pluginId: plugin.id,
        sectionId: 'site',
        siteId: item['id']?.toString() ?? _siteId(title, baseUrl),
        title: title,
        kind: FileContentKind.audio,
        baseUrl: baseUrl,
        searchPath: item['searchPath']?.toString() ?? '/search?q={query}',
      ));
    }
    return result;
  }

  static String _siteId(String title, String baseUrl) {
    final raw = '$title-$baseUrl'.toLowerCase();
    return raw.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  }

  bool _settingBool(
    String pluginId,
    String key, {
    required bool defaultValue,
  }) {
    final value = settingsByPluginId[pluginId]?[key]?.trim().toLowerCase();
    if (value == null || value.isEmpty) return defaultValue;
    if (['1', 'true', 'yes', 'on'].contains(value)) return true;
    if (['0', 'false', 'no', 'off'].contains(value)) return false;
    return defaultValue;
  }
}

class WebMusicPluginService {
  const WebMusicPluginService();

  Future<DirectorySnapshot> snapshot(
    PluginMediaSection section, {
    String query = '',
  }) async {
    try {
      final uri = _sectionUri(section, query);
      final html = await _readHtml(uri);
      final entries = _parseAudioEntries(html, uri, section).take(200).toList();
      return DirectorySnapshot(
        path: section.runtimeId,
        entries: entries,
      );
    } catch (error) {
      return DirectorySnapshot(
        path: section.runtimeId,
        entries: const <ExplorerEntry>[],
        error: error.toString(),
      );
    }
  }

  Future<File> download(ExplorerEntry entry, Directory targetDirectory) async {
    final uri = Uri.parse(entry.path);
    final safeName = _safeFileName(entry.name);
    final target = File('${targetDirectory.path}${Platform.pathSeparator}'
        '${safeName.isEmpty ? 'track.mp3' : safeName}');
    await target.parent.create(recursive: true);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      final response = await request.close();
      if (response.statusCode >= 400) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      await response.pipe(target.openWrite());
      return target;
    } finally {
      client.close(force: true);
    }
  }

  Uri _sectionUri(PluginMediaSection section, String query) {
    final base = Uri.parse(section.baseUrl);
    if (query.trim().isEmpty) return base;
    final encoded = Uri.encodeQueryComponent(query.trim());
    final path = section.searchPath.replaceAll('{query}', encoded);
    return base.resolve(path);
  }

  Future<String> _readHtml(Uri uri) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
      final response = await request.close();
      if (response.statusCode >= 400) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      return await utf8.decodeStream(response);
    } finally {
      client.close(force: true);
    }
  }

  Iterable<ExplorerEntry> _parseAudioEntries(
    String html,
    Uri pageUri,
    PluginMediaSection section,
  ) sync* {
    final seen = <String>{};
    for (final match in _mediaUrlPattern.allMatches(html)) {
      final raw = match.group(1);
      if (raw == null || raw.trim().isEmpty) continue;
      final decoded = _decodeHtml(raw.trim());
      final uri = pageUri.resolve(decoded);
      if (!uri.hasScheme || !seen.add(uri.toString())) continue;
      final windowStart = (match.start - 500).clamp(0, html.length).toInt();
      final windowEnd = (match.end + 500).clamp(0, html.length).toInt();
      final title = _titleNear(html.substring(windowStart, windowEnd), uri);
      yield ExplorerEntry(
        name: _ensureAudioExtension(title),
        path: uri.toString(),
        kind: ExplorerEntryKind.file,
        sizeBytes: 0,
        modifiedAt: DateTime.now(),
      );
    }
  }

  String _titleNear(String html, Uri uri) {
    final attrs = <RegExp>[
      RegExp(r'''title=["']([^"']+)["']''', caseSensitive: false),
      RegExp(r'''alt=["']([^"']+)["']''', caseSensitive: false),
      RegExp(r'''data-title=["']([^"']+)["']''', caseSensitive: false),
    ];
    for (final pattern in attrs) {
      final match = pattern.firstMatch(html);
      if (match != null) {
        final value = _decodeHtml(match.group(1) ?? '').trim();
        if (value.isNotEmpty) return value;
      }
    }
    final text = html
        .replaceAll(
            RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.length > 4 && text.length < 120) return _decodeHtml(text);
    final name = uri.pathSegments.isEmpty ? 'track.mp3' : uri.pathSegments.last;
    return Uri.decodeComponent(name);
  }

  String _ensureAudioExtension(String title) {
    final trimmed = title.trim().isEmpty ? 'track.mp3' : title.trim();
    final kind = FileViewerService.kindForName(trimmed);
    if (kind == FileContentKind.audio) return _safeFileName(trimmed);
    return '${_safeFileName(trimmed)}.mp3';
  }

  String _decodeHtml(String value) => value
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll(r'\/', '/');

  String _safeFileName(String value) =>
      value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
}

final _mediaUrlPattern = RegExp(
  r'''["']([^"']+\.(?:mp3|m4a|aac|ogg|oga|flac|wav)(?:\?[^"']*)?)["']''',
  caseSensitive: false,
);

const _userAgent =
    'SecureVault/0.12 plugin-media-parser (+https://localhost/securevault)';
