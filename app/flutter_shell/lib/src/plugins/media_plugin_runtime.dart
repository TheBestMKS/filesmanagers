import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
    final errors = <String>[];
    for (final uri in _candidateUris(section, query)) {
      try {
        final html = await _readHtml(uri);
        final entries = await _entriesFromHtml(html, uri, section, query);
        if (entries.isNotEmpty &&
            (query.trim().isEmpty || _htmlMentionsQuery(html, query))) {
          return DirectorySnapshot(path: section.runtimeId, entries: entries);
        }
        if (query.trim().isEmpty) {
          return DirectorySnapshot(path: section.runtimeId, entries: entries);
        }
      } catch (error) {
        errors.add('$uri: $error');
      }
    }
    return DirectorySnapshot(
      path: section.runtimeId,
      entries: const <ExplorerEntry>[],
      error: errors.isEmpty ? null : errors.join('\n'),
    );
  }

  Future<File> download(
    ExplorerEntry entry,
    Directory targetDirectory, {
    void Function(int receivedBytes, int? totalBytes)? onProgress,
  }) async {
    final uri = Uri.parse(entry.path);
    final safeName = _safeFileName(entry.name);
    final target = File('${targetDirectory.path}${Platform.pathSeparator}'
        '${safeName.isEmpty ? 'track.mp3' : safeName}');
    await target.parent.create(recursive: true);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(uri);
      _applyHeaders(request, referer: uri.origin);
      final response = await request.close();
      if (response.statusCode >= 400) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
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

  Iterable<Uri> _candidateUris(PluginMediaSection section, String query) sync* {
    final base = _normalizedBaseUri(section.baseUrl);
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) {
      yield base;
      return;
    }
    final seen = <String>{};
    for (final path in _searchPathCandidates(section, base)) {
      final uri = base.resolve(_fillSearchPath(path, normalizedQuery));
      if (seen.add(uri.toString())) yield uri;
    }
  }

  Uri _normalizedBaseUri(String value) {
    final trimmed = value.trim();
    final withScheme =
        Uri.tryParse(trimmed)?.hasScheme == true ? trimmed : 'https://$trimmed';
    return Uri.parse(withScheme);
  }

  List<String> _searchPathCandidates(PluginMediaSection section, Uri base) {
    final host = base.host.toLowerCase();
    final paths = <String>[
      section.searchPath,
      if (host.contains('zaycev')) '/search?query_search={query}',
      if (host.contains('hitmoz')) '/search?q={query}',
      if (host.contains('zvooq')) '/search?q={query}',
      if (host.contains('zvooq')) '/search?query={query}',
      if (host.contains('zvooq')) '/?s={query}',
      if (host.contains('zvooq')) '/search/{query}',
      if (host.contains('tuthit')) '/search?q={query}',
      if (host.contains('zvukofon')) '/?s={query}',
      if (host.contains('zvu4it')) '/?s={query}',
      if (host.contains('muzexo')) '/?do=search&subaction=search&story={query}',
      if (host.contains('muzexo'))
        '/index.php?do=search&subaction=search&story={query}',
      if (host.contains('muzjam')) '/search/{query}',
      if (host.contains('muzvox')) '/search/{query}',
      '/search?q={query}',
      '/search?query={query}',
      '/search?query_search={query}',
      '/search/{query}',
      '/search/{query}/',
      '/?s={query}',
      '/?do=search&subaction=search&story={query}',
      '/index.php?do=search&subaction=search&story={query}',
      '/poisk/{query}',
      '/poisk/{query}/',
      '/mp3/{query}',
      '/mp3/{query}/',
    ];
    final seen = <String>{};
    return [
      for (final path in paths)
        if (seen.add(path)) path
    ];
  }

  String _fillSearchPath(String path, String query) {
    final encodedQuery = Uri.encodeQueryComponent(query);
    final encodedPath = Uri.encodeComponent(query).replaceAll('%20', '+');
    return path
        .replaceAll('{query}', encodedQuery)
        .replaceAll('{pathQuery}', encodedPath);
  }

  Future<String> _readHtml(Uri uri, {Uri? referer}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(uri);
      _applyHeaders(request, referer: referer?.toString());
      final response = await request.close();
      if (response.statusCode >= 400) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      final bytes = await _readAllBytes(response);
      return _decodeResponse(bytes, response.headers.contentType);
    } finally {
      client.close(force: true);
    }
  }

  Future<List<int>> _readAllBytes(Stream<List<int>> stream) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  void _applyHeaders(HttpClientRequest request, {String? referer}) {
    request.headers.set(HttpHeaders.userAgentHeader, _userAgent);
    request.headers.set(HttpHeaders.acceptHeader,
        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8');
    request.headers.set(HttpHeaders.acceptLanguageHeader, 'ru,en;q=0.8');
    if (referer != null && referer.isNotEmpty) {
      request.headers.set(HttpHeaders.refererHeader, referer);
    }
  }

  String _decodeResponse(List<int> bytes, ContentType? contentType) {
    final charset = contentType?.charset?.toLowerCase();
    if (charset == null || charset == 'utf-8' || charset == 'utf8') {
      return utf8.decode(bytes, allowMalformed: true);
    }
    if (charset == 'iso-8859-1' || charset == 'latin1') {
      return latin1.decode(bytes, allowInvalid: true);
    }
    if (charset == 'windows-1251' || charset == 'cp1251') {
      return _decodeWindows1251(bytes);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  Future<List<ExplorerEntry>> _entriesFromHtml(
    String html,
    Uri pageUri,
    PluginMediaSection section,
    String query,
  ) async {
    final parsed = <_ParsedAudioEntry>[];
    parsed.addAll(_parseJsonAudioEntries(html, pageUri));
    parsed.addAll(_parseAttributeAudioEntries(html, pageUri));
    parsed.addAll(_parseDirectAudioEntries(html, pageUri));

    final detailLinks = _parseTrackPageLinks(html, pageUri).take(16).toList();
    if (parsed.length < 8 && detailLinks.isNotEmpty) {
      for (final link in detailLinks) {
        try {
          final detailHtml = await _readHtml(link.uri, referer: pageUri);
          final detailEntries = <_ParsedAudioEntry>[
            ..._parseJsonAudioEntries(detailHtml, link.uri),
            ..._parseAttributeAudioEntries(detailHtml, link.uri),
            ..._parseDirectAudioEntries(detailHtml, link.uri),
          ];
          for (final entry in detailEntries) {
            parsed.add(entry.title.isEmpty && link.title.isNotEmpty
                ? entry.copyWith(title: link.title)
                : entry);
          }
        } catch (_) {
          // A single unsupported catalogue page must not break the whole site.
        }
      }
    }

    final tracks = _dedupe(parsed)
        .take(200)
        .map((entry) => ExplorerEntry(
              name: _ensureAudioExtension(entry.bestTitle),
              path: entry.uri.toString(),
              kind: ExplorerEntryKind.file,
              sizeBytes: 0,
              modifiedAt: DateTime.now(),
            ))
        .toList();
    if (query.trim().isNotEmpty) return tracks;
    final genres = _parseGenreLinks(html, pageUri)
        .take(80)
        .map((genre) => ExplorerEntry(
              name: genre.title,
              path: genre.uri.toString(),
              kind: ExplorerEntryKind.directory,
              sizeBytes: 0,
              modifiedAt: DateTime.now(),
            ))
        .toList();
    return [...genres, ...tracks];
  }

  Iterable<_TrackPageLink> _parseGenreLinks(String html, Uri pageUri) sync* {
    final scope = _popularGenresScope(html);
    final seen = <String>{};
    final source = scope.isEmpty ? html : scope;
    for (final match in _anchorTextPattern.allMatches(source)) {
      final raw = match.group(1);
      final text = match.group(2);
      if (raw == null || text == null) continue;
      final title = _cleanTitle(_stripTags(text));
      if (!_isGoodTitle(title) || _isGenericTitle(title)) continue;
      final decoded = _decodeHtml(raw.trim());
      if (!_looksLikeGenreReference(decoded, title)) continue;
      final uri = _resolveReference(pageUri, decoded);
      if (uri == null) continue;
      if (uri.host.isNotEmpty && uri.host != pageUri.host) continue;
      final normalized = uri.removeFragment().toString();
      if (!seen.add(normalized)) continue;
      yield _TrackPageLink(uri: uri, title: title);
    }
  }

  String _popularGenresScope(String html) {
    final lower = html.toLowerCase();
    final markers = [
      _ru('043f 043e 043f 0443 043b 044f 0440 043d 044b 0435 0020 0436 0430 043d 0440 044b'),
      'popular genres',
      'sidebar-genres',
    ];
    var index = -1;
    for (final marker in markers) {
      index = lower.indexOf(marker.toLowerCase());
      if (index >= 0) break;
    }
    if (index < 0) return '';
    final endCandidates = <int>[
      lower.indexOf('</ul>', index),
      lower.indexOf('</aside>', index),
      lower.indexOf('sidebar-item-title', index + 20),
    ].where((value) => value > index).toList()
      ..sort();
    final end = endCandidates.isEmpty
        ? (index + 12000).clamp(0, html.length).toInt()
        : endCandidates.first.clamp(0, html.length).toInt();
    return html.substring(index, end);
  }

  Iterable<_ParsedAudioEntry> _parseJsonAudioEntries(
    String html,
    Uri pageUri,
  ) sync* {
    for (final match in _dataJsonAttributePattern.allMatches(html)) {
      final raw = match.group(1);
      if (raw == null || raw.trim().isEmpty) continue;
      final decoded = _decodeHtml(raw.trim());
      final parsed = _tryJsonMap(decoded);
      if (parsed == null) continue;
      final url = _jsonString(parsed, ['url', 'file', 'src', 'stream']);
      if (url == null || !_looksLikeMediaReference(url, fromData: true)) {
        continue;
      }
      final uri = _resolveReference(pageUri, _decodeHtml(url));
      if (uri == null) continue;
      final title = _joinTitle(
        _jsonString(parsed, ['artist', 'artistName', 'author']),
        _jsonString(parsed, ['title', 'track', 'name']),
      );
      yield _ParsedAudioEntry(uri: uri, title: title);
    }

    for (final match in _jsonUrlPattern.allMatches(html)) {
      final raw = match.group(1);
      if (raw == null || raw.isEmpty) continue;
      final url = _decodeJsonString(raw);
      if (!_looksLikeMediaReference(url, fromData: true)) continue;
      final uri = _resolveReference(pageUri, url);
      if (uri == null) continue;
      final window = _windowAround(html, match.start, match.end, 1800);
      yield _ParsedAudioEntry(uri: uri, title: _bestTitle(window, uri));
    }
  }

  Iterable<_ParsedAudioEntry> _parseAttributeAudioEntries(
    String html,
    Uri pageUri,
  ) sync* {
    for (final match in _attributeUrlPattern.allMatches(html)) {
      final attrName = (match.group(1) ?? '').toLowerCase();
      final raw = match.group(2);
      if (raw == null || raw.trim().isEmpty) continue;
      final fromData = attrName.startsWith('data-');
      final decoded = _decodeHtml(raw.trim());
      if (!_looksLikeMediaReference(decoded, fromData: fromData)) continue;
      final uri = _resolveReference(pageUri, decoded);
      if (uri == null) continue;
      final window = _windowAround(html, match.start, match.end, 2200);
      yield _ParsedAudioEntry(uri: uri, title: _bestTitle(window, uri));
    }
  }

  Iterable<_ParsedAudioEntry> _parseDirectAudioEntries(
    String html,
    Uri pageUri,
  ) sync* {
    for (final match in _directMediaUrlPattern.allMatches(html)) {
      final raw = match.group(1);
      if (raw == null || raw.trim().isEmpty) continue;
      final decoded = _decodeHtml(raw.trim());
      final uri = _resolveReference(pageUri, decoded);
      if (uri == null) continue;
      final window = _windowAround(html, match.start, match.end, 1800);
      yield _ParsedAudioEntry(uri: uri, title: _bestTitle(window, uri));
    }
  }

  Iterable<_TrackPageLink> _parseTrackPageLinks(
      String html, Uri pageUri) sync* {
    final seen = <String>{};
    for (final match in _anchorPattern.allMatches(html)) {
      final raw = match.group(1);
      if (raw == null || raw.trim().isEmpty) continue;
      final decoded = _decodeHtml(raw.trim());
      if (!_looksLikeTrackPageReference(decoded)) continue;
      final uri = _resolveReference(pageUri, decoded);
      if (uri == null) continue;
      if (uri.host.isNotEmpty && uri.host != pageUri.host) continue;
      final normalized = uri.removeFragment().toString();
      if (!seen.add(normalized)) continue;
      final window = _windowAround(html, match.start, match.end, 650);
      yield _TrackPageLink(uri: uri, title: _bestTitle(window, uri));
    }
  }

  List<_ParsedAudioEntry> _dedupe(List<_ParsedAudioEntry> entries) {
    final byUrl = <String, _ParsedAudioEntry>{};
    final byTitle = <String>{};
    for (final entry in entries) {
      if (!entry.uri.hasScheme) continue;
      final pathKey = _mediaKey(entry.uri);
      final titleKey = _titleKey(entry.bestTitle);
      if (byUrl.containsKey(pathKey)) continue;
      if (titleKey.isNotEmpty && byTitle.contains(titleKey)) continue;
      byUrl[pathKey] = entry;
      if (titleKey.isNotEmpty) byTitle.add(titleKey);
    }
    final result = byUrl.values.toList();
    result.sort((a, b) => a.bestTitle.compareTo(b.bestTitle));
    return result;
  }

  String _titleNear(String html, Uri uri) {
    final data = _dataJsonAttributePattern.firstMatch(html);
    if (data != null) {
      final parsed = _tryJsonMap(_decodeHtml(data.group(1) ?? ''));
      if (parsed != null) {
        final title = _joinTitle(
          _jsonString(parsed, ['artist', 'artistName', 'author']),
          _jsonString(parsed, ['title', 'track', 'name']),
        );
        if (_isGoodTitle(title) && !_isGenericTitle(title)) return title;
      }
    }

    final jsonTitle = _jsonTitleNear(html);
    if (_isGoodTitle(jsonTitle) && !_isGenericTitle(jsonTitle)) {
      return jsonTitle;
    }

    for (final pattern in _semanticTitlePatterns) {
      final match = pattern.firstMatch(html);
      if (match != null) {
        final value = _cleanTitle(_stripTags(match.group(1) ?? ''));
        if (_isGoodTitle(value) && !_isGenericTitle(value)) return value;
      }
    }

    for (final pattern in _attributeTitlePatterns) {
      final match = pattern.firstMatch(html);
      if (match != null) {
        final value = _cleanTitle(_decodeHtml(match.group(1) ?? ''));
        if (_isGoodTitle(value) && !_isGenericTitle(value)) return value;
      }
    }

    final text = _cleanTitle(_stripTags(html));
    if (_isGoodTitle(text) && !_isGenericTitle(text) && text.length < 90) {
      return text;
    }
    return _titleFromUri(uri);
  }

  String _bestTitle(String html, Uri uri) {
    final near = _titleNear(html, uri);
    final fromUri = _titleFromUri(uri);
    if (_hasAudioExtension(uri.path) &&
        uri.path.toLowerCase().contains('/uploads/') &&
        _isGoodTitle(fromUri)) {
      return fromUri;
    }
    if (_isGenericTitle(near) && _isGoodTitle(fromUri)) return fromUri;
    if (!_isGoodTitle(near) && _isGoodTitle(fromUri)) return fromUri;
    final nearLower = near.toLowerCase();
    if (_isGoodTitle(fromUri) &&
        (near.contains('%') ||
            near.contains('__') ||
            nearLower.contains('div') ||
            (fromUri.contains(' - ') && !near.contains(' - ')) ||
            near.length > fromUri.length * 2)) {
      return fromUri;
    }
    if (_hasAudioExtension(uri.path) &&
        _isGoodTitle(fromUri) &&
        _wordOverlap(near, fromUri) == 0) {
      return fromUri;
    }
    return near;
  }

  bool _hasAudioExtension(String value) =>
      RegExp(r'\.(mp3|m4a|aac|ogg|oga|flac|wav)$', caseSensitive: false)
          .hasMatch(value.split('?').first);

  int _wordOverlap(String left, String right) {
    final leftWords =
        _titleKey(left).split(' ').where((word) => word.length > 2).toSet();
    if (leftWords.isEmpty) return 0;
    return _titleKey(right)
        .split(' ')
        .where((word) => word.length > 2 && leftWords.contains(word))
        .length;
  }

  bool _htmlMentionsQuery(String html, String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return true;
    return html.toLowerCase().contains(normalized);
  }

  String _jsonTitleNear(String html) {
    String? title;
    String? artist;
    for (final match in _jsonTextFieldPattern.allMatches(html)) {
      final key = (match.group(1) ?? '').toLowerCase();
      final value = _cleanTitle(_decodeJsonString(match.group(2) ?? ''));
      if (!_isGoodTitle(value)) continue;
      if (['artist', 'artistname', 'author'].contains(key)) artist ??= value;
      if (['title', 'track', 'name'].contains(key)) title ??= value;
    }
    return _joinTitle(artist, title);
  }

  Map<String, Object?>? _tryJsonMap(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {}
    return null;
  }

  String? _jsonString(Map<String, Object?> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value != null && value.toString().trim().isNotEmpty) {
        return _cleanTitle(value.toString());
      }
    }
    return null;
  }

  String _joinTitle(String? artist, String? title) {
    final cleanArtist = artist == null ? '' : _cleanTitle(artist);
    final cleanTitle = title == null ? '' : _cleanTitle(title);
    if (cleanArtist.isNotEmpty && cleanTitle.isNotEmpty) {
      if (cleanTitle.toLowerCase().contains(cleanArtist.toLowerCase())) {
        return cleanTitle;
      }
      return '$cleanArtist - $cleanTitle';
    }
    return cleanTitle.isNotEmpty ? cleanTitle : cleanArtist;
  }

  String _windowAround(String html, int start, int end, int radius) {
    final windowStart = (start - radius).clamp(0, html.length).toInt();
    final windowEnd = (end + radius).clamp(0, html.length).toInt();
    return html.substring(windowStart, windowEnd);
  }

  Uri? _resolveReference(Uri base, String reference) {
    try {
      return base.resolve(reference);
    } catch (_) {
      final escaped = reference.replaceAllMapped(
        RegExp(r'%(?![0-9a-fA-F]{2})'),
        (_) => '%25',
      );
      try {
        return base.resolve(escaped);
      } catch (_) {
        return null;
      }
    }
  }

  bool _looksLikeMediaReference(String value, {required bool fromData}) {
    final lower = value.toLowerCase();
    if (lower.contains('.jpg') ||
        lower.contains('.jpeg') ||
        lower.contains('.png') ||
        lower.contains('.gif') ||
        lower.contains('.webp') ||
        lower.contains('.svg') ||
        lower.contains('.css') ||
        lower.contains('.js')) {
      return false;
    }
    if (RegExp(r'\.(mp3|m4a|aac|ogg|oga|flac|wav)(?:[?#]|$)',
            caseSensitive: false)
        .hasMatch(lower)) {
      return true;
    }
    if (!fromData) return false;
    return lower.contains('/play/') ||
        lower.contains('/stream/') ||
        lower.contains('/download/') ||
        lower.contains('/listen/') ||
        lower.contains('/dl/') ||
        lower.contains('/get/');
  }

  bool _looksLikeTrackPageReference(String value) {
    final lower = value.toLowerCase();
    if (lower.startsWith('#') ||
        lower.startsWith('mailto:') ||
        lower.startsWith('javascript:') ||
        lower.contains('/static/') ||
        lower.contains('/assets/') ||
        lower.contains('/cdn-cgi/') ||
        lower.contains('.css') ||
        lower.contains('.js') ||
        lower.contains('.jpg') ||
        lower.contains('.png') ||
        lower.contains('.svg')) {
      return false;
    }
    return lower.contains('/track/') ||
        lower.contains('/song/') ||
        lower.contains('/music/') ||
        lower.contains('/mp3/') ||
        (lower.contains('/pages/') && lower.endsWith('.shtml'));
  }

  bool _looksLikeGenreReference(String value, String title) {
    final lower = value.toLowerCase();
    if (lower.startsWith('#') ||
        lower.startsWith('mailto:') ||
        lower.startsWith('javascript:') ||
        lower.contains('/static/') ||
        lower.contains('/assets/') ||
        lower.contains('.css') ||
        lower.contains('.js') ||
        lower.contains('/artist') ||
        lower.contains('/track') ||
        lower.contains('/song/') ||
        lower.contains('/download/')) {
      return false;
    }
    if (lower.contains('/genre/')) return true;
    if (lower.contains('/genres/')) return true;
    if (lower.contains('/songs/') &&
        !lower.contains('/top-') &&
        title.length <= 60) {
      return true;
    }
    return false;
  }

  String _mediaKey(Uri uri) {
    final normalizedPath = uri.path
        .replaceAll(RegExp(r'_b\d+f\d+', caseSensitive: false), '')
        .replaceAll(RegExp(r'_[a-f0-9]{16,}', caseSensitive: false), '')
        .toLowerCase();
    return uri.replace(path: normalizedPath, query: '').toString();
  }

  String _titleKey(String title) => _cleanTitle(title)
      .toLowerCase()
      .replaceAll(RegExp(r'\.(mp3|m4a|aac|ogg|oga|flac|wav)$'), '')
      .replaceAll(RegExp(r'[^a-z0-9\u0400-\u04ff]+', caseSensitive: false), ' ')
      .trim();

  String _titleFromUri(Uri uri) {
    final rawName = _lastPathSegment(uri);
    final decoded = _safeDecodeComponent(rawName);
    return _cleanTitle(decoded
        .replaceAll(
            RegExp(r'\.(mp3|m4a|aac|ogg|oga|flac|wav)$', caseSensitive: false),
            '')
        .replaceAll(RegExp(r'\[[^\]]+\]'), '')
        .replaceAll(RegExp(r'_b\d+f\d+', caseSensitive: false), '')
        .replaceAll(RegExp(r'_[a-f0-9]{12,}', caseSensitive: false), '')
        .replaceAll('_-_', ' - ')
        .replaceAll('_', ' '));
  }

  String _safeDecodeComponent(String value) {
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return value.replaceAll('%', ' ');
    }
  }

  String _lastPathSegment(Uri uri) {
    final parts = uri.path.split('/').where((part) => part.isNotEmpty).toList();
    return parts.isEmpty ? 'track.mp3' : parts.last;
  }

  bool _isGoodTitle(String value) {
    final title = _cleanTitle(value);
    if (title.length < 2 || title.length > 160) return false;
    final lower = title.toLowerCase();
    if (lower.startsWith('http') ||
        lower.contains('{') ||
        lower.contains('function(') ||
        lower.contains('download free') ||
        lower.contains('listen online') ||
        lower.contains(_ru('0441 043a 0430 0447 0430 0442 044c')) ||
        lower.contains(_ru('0441 043b 0443 0448 0430 0442 044c')) ||
        lower == 'play' ||
        lower == 'download') {
      return false;
    }
    return true;
  }

  bool _isGenericTitle(String value) {
    final lower = _cleanTitle(value).toLowerCase();
    return lower.contains(_ru('043d 0430 0439 0434 0435 043d')) ||
        lower.contains(_ru('043f 043e 043f 0443 043b 044f 0440 043d')) ||
        lower.contains(_ru('0436 0430 043d 0440')) ||
        lower.contains(_ru('0441 043a 0430 0447 0430 0442 044c')) ||
        lower.contains(_ru('0441 043b 0443 0448 0430 0442 044c')) ||
        lower == 'download' ||
        lower == 'play';
  }

  String _ensureAudioExtension(String title) {
    final trimmed = title.trim().isEmpty ? 'track.mp3' : title.trim();
    final kind = FileViewerService.kindForName(trimmed);
    if (kind == FileContentKind.audio) return _safeFileName(trimmed);
    return '${_safeFileName(trimmed)}.mp3';
  }

  String _cleanTitle(String value) {
    var title = _decodeHtml(value)
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(
            RegExp(r'\s+-\s+(download|listen).*$', caseSensitive: false), '')
        .replaceAll(
            RegExp(r'\s+(download|listen).*$', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+mp3\s*$', caseSensitive: false), '')
        .trim();
    title = title.replaceAll(RegExp(r'^[\-\s]+|[\-\s]+$'), '');
    return title;
  }

  String _stripTags(String value) => value
      .replaceAll(RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), '')
      .replaceAll(RegExp(r'<style[\s\S]*?</style>', caseSensitive: false), '')
      .replaceAll(RegExp(r'<[^>]+>'), ' ');

  String _decodeJsonString(String value) {
    try {
      final decoded = jsonDecode('"${value.replaceAll('"', r'\"')}"');
      if (decoded is String) return _decodeHtml(decoded);
    } catch (_) {}
    return _decodeHtml(value).replaceAll(r'\/', '/');
  }

  String _decodeHtml(String value) => value
          .replaceAll('&amp;', '&')
          .replaceAll('&quot;', '"')
          .replaceAll('&#39;', "'")
          .replaceAll('&apos;', "'")
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&nbsp;', ' ')
          .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (match) {
        final code = int.tryParse(match.group(1) ?? '', radix: 16);
        return code == null ? match.group(0)! : String.fromCharCode(code);
      }).replaceAllMapped(RegExp(r'&#(\d+);'), (match) {
        final code = int.tryParse(match.group(1) ?? '');
        return code == null ? match.group(0)! : String.fromCharCode(code);
      }).replaceAll(r'\/', '/');

  String _safeFileName(String value) =>
      value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();

  String _decodeWindows1251(List<int> bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      if (byte < 128) {
        buffer.writeCharCode(byte);
      } else {
        buffer.writeCharCode(_windows1251[byte - 128]);
      }
    }
    return buffer.toString();
  }

  String _ru(String hexCodes) => String.fromCharCodes(
        hexCodes.split(' ').map((part) => int.parse(part, radix: 16)),
      );
}

class _ParsedAudioEntry {
  const _ParsedAudioEntry({required this.uri, required this.title});

  final Uri uri;
  final String title;

  String get bestTitle {
    if (title.trim().isNotEmpty) return title;
    final parts = uri.path.split('/').where((part) => part.isNotEmpty).toList();
    return parts.isEmpty ? 'track.mp3' : parts.last;
  }

  _ParsedAudioEntry copyWith({String? title}) =>
      _ParsedAudioEntry(uri: uri, title: title ?? this.title);
}

class _TrackPageLink {
  const _TrackPageLink({required this.uri, required this.title});

  final Uri uri;
  final String title;
}

final _directMediaUrlPattern = RegExp(
  r'''["']([^"']+\.(?:mp3|m4a|aac|ogg|oga|flac|wav)(?:\?[^"']*)?)["']''',
  caseSensitive: false,
);

final _attributeUrlPattern = RegExp(
  r'''(data-[a-z0-9_-]*url|data-[a-z0-9_-]*src|data-[a-z0-9_-]*file|data-[a-z0-9_-]*play|data-[a-z0-9_-]*download|href|src)=["']([^"']+)["']''',
  caseSensitive: false,
);

final _dataJsonAttributePattern = RegExp(
  r'''data-(?:musmeta|track|song|audio|music|meta|player)=["']([^"']+)["']''',
  caseSensitive: false,
);

final _jsonUrlPattern = RegExp(
  r'''"(?:url|file|src|stream|audio|mp3|downloadUrl|playUrl)"\s*:\s*"([^"]+)"''',
  caseSensitive: false,
);

final _jsonTextFieldPattern = RegExp(
  r'''"(artist|artistName|author|title|track|name)"\s*:\s*"([^"]+)"''',
  caseSensitive: false,
);

final _anchorPattern = RegExp(
  r'''<a\b[^>]*href=["']([^"']+)["'][\s\S]*?</a>''',
  caseSensitive: false,
);

final _anchorTextPattern = RegExp(
  r'''<a\b[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)</a>''',
  caseSensitive: false,
);

final _semanticTitlePatterns = <RegExp>[
  RegExp(
    r'''<a\b[^>]*href=["'][^"']*(?:/track/|/song/|/music/|/mp3/)[^"']*["'][^>]*>([\s\S]*?)</a>''',
    caseSensitive: false,
  ),
  RegExp(
    r'''class=["'][^"']*(?:track__title|song[-_ ]?title|audio[-_ ]?title|player[-_ ]?title|music[-_ ]?title)[^"']*["'][^>]*>([\s\S]*?)</''',
    caseSensitive: false,
  ),
  RegExp(r'''<h1[^>]*>([\s\S]*?)</h1>''', caseSensitive: false),
  RegExp(r'''<h2[^>]*>([\s\S]*?)</h2>''', caseSensitive: false),
  RegExp(r'''itemProp=["']name["'][^>]*content=["']([^"']+)["']''',
      caseSensitive: false),
  RegExp(r'''property=["']og:title["'][^>]*content=["']([^"']+)["']''',
      caseSensitive: false),
];

final _attributeTitlePatterns = <RegExp>[
  RegExp(r'''data-title=["']([^"']+)["']''', caseSensitive: false),
  RegExp(r'''data-name=["']([^"']+)["']''', caseSensitive: false),
  RegExp(r'''aria-label=["']([^"']+)["']''', caseSensitive: false),
  RegExp(r'''title=["']([^"']+)["']''', caseSensitive: false),
  RegExp(r'''alt=["']([^"']+)["']''', caseSensitive: false),
];

const _windows1251 = <int>[
  0x0402,
  0x0403,
  0x201A,
  0x0453,
  0x201E,
  0x2026,
  0x2020,
  0x2021,
  0x20AC,
  0x2030,
  0x0409,
  0x2039,
  0x040A,
  0x040C,
  0x040B,
  0x040F,
  0x0452,
  0x2018,
  0x2019,
  0x201C,
  0x201D,
  0x2022,
  0x2013,
  0x2014,
  0x0000,
  0x2122,
  0x0459,
  0x203A,
  0x045A,
  0x045C,
  0x045B,
  0x045F,
  0x00A0,
  0x040E,
  0x045E,
  0x0408,
  0x00A4,
  0x0490,
  0x00A6,
  0x00A7,
  0x0401,
  0x00A9,
  0x0404,
  0x00AB,
  0x00AC,
  0x00AD,
  0x00AE,
  0x0407,
  0x00B0,
  0x00B1,
  0x0406,
  0x0456,
  0x0491,
  0x00B5,
  0x00B6,
  0x00B7,
  0x0451,
  0x2116,
  0x0454,
  0x00BB,
  0x0458,
  0x0405,
  0x0455,
  0x0457,
  0x0410,
  0x0411,
  0x0412,
  0x0413,
  0x0414,
  0x0415,
  0x0416,
  0x0417,
  0x0418,
  0x0419,
  0x041A,
  0x041B,
  0x041C,
  0x041D,
  0x041E,
  0x041F,
  0x0420,
  0x0421,
  0x0422,
  0x0423,
  0x0424,
  0x0425,
  0x0426,
  0x0427,
  0x0428,
  0x0429,
  0x042A,
  0x042B,
  0x042C,
  0x042D,
  0x042E,
  0x042F,
  0x0430,
  0x0431,
  0x0432,
  0x0433,
  0x0434,
  0x0435,
  0x0436,
  0x0437,
  0x0438,
  0x0439,
  0x043A,
  0x043B,
  0x043C,
  0x043D,
  0x043E,
  0x043F,
  0x0440,
  0x0441,
  0x0442,
  0x0443,
  0x0444,
  0x0445,
  0x0446,
  0x0447,
  0x0448,
  0x0449,
  0x044A,
  0x044B,
  0x044C,
  0x044D,
  0x044E,
  0x044F,
];

const _userAgent =
    'SecureVault/0.12.7 plugin-media-parser (+https://localhost/securevault)';
