import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../plugins/cloud_plugin_registry.dart' hide basename;

class RemoteFileSystemEntry {
  const RemoteFileSystemEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int sizeBytes;
  final DateTime modifiedAt;
}

class RemoteFileStat {
  const RemoteFileStat({
    required this.path,
    required this.exists,
    required this.isDirectory,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  final String path;
  final bool exists;
  final bool isDirectory;
  final int sizeBytes;
  final DateTime modifiedAt;
}

abstract class RemoteFileSystemClient {
  Future<List<RemoteFileSystemEntry>> list(String path);

  Future<RemoteFileStat?> stat(String path);

  Future<Uint8List> readBytes(String path);

  Future<void> writeBytes(String path, List<int> bytes);

  Future<void> createDirectory(String path);

  Future<void> delete(String path, {required bool recursive});
}

class RemoteFileSystemRepository {
  final _plugins = <String, CloudPluginDefinition>{};

  void configurePlugins(List<CloudPluginDefinition> plugins) {
    _plugins
      ..clear()
      ..addEntries(plugins.map((plugin) => MapEntry(plugin.id, plugin)));
  }

  bool hasPlugin(String pluginId) => _plugins.containsKey(pluginId);

  bool isSupported(CloudPluginDefinition plugin) {
    final executor = _executorName(plugin);
    return executor == 'webdav-json' ||
        executor == 'json-http' ||
        executor == 'ftp' ||
        executor == 'sftp' ||
        executor == 'smb';
  }

  RemoteFileSystemClient clientFor(String pluginId) {
    final plugin = _plugins[pluginId];
    if (plugin == null) {
      throw StateError('Remote plugin is not loaded: $pluginId');
    }
    final executor = _executorName(plugin);
    return switch (executor) {
      'webdav-json' || 'json-http' => WebDavRemoteClient(plugin),
      'ftp' => FtpRemoteClient(plugin),
      'sftp' => SftpCommandRemoteClient(plugin),
      'smb' => SmbCommandRemoteClient(plugin),
      _ => throw UnsupportedError('Unsupported plugin executor: $executor'),
    };
  }

  String _executorName(CloudPluginDefinition plugin) {
    Object? value = plugin.components?['executor'];
    value ??= plugin.platformComponents?[_platformKey()] is Map
        ? (plugin.platformComponents![_platformKey()] as Map)['executor']
        : null;
    value ??= plugin.platformComponents?['fallback'] is Map
        ? (plugin.platformComponents!['fallback'] as Map)['executor']
        : null;
    return value?.toString() ?? plugin.pluginType;
  }

  String _platformKey() {
    final os = Platform.operatingSystem;
    final arch = switch (Platform.version.toLowerCase()) {
      final value when value.contains('arm64') || value.contains('aarch64') =>
        'arm64',
      _ => 'x64',
    };
    return '$os-$arch';
  }
}

class WebDavRemoteClient implements RemoteFileSystemClient {
  WebDavRemoteClient(this.plugin);

  final CloudPluginDefinition plugin;

  @override
  Future<List<RemoteFileSystemEntry>> list(String path) async {
    final request = plugin.listRequest ?? const <String, Object?>{};
    final response = await _send(
      request,
      path: path,
      defaultMethod: 'PROPFIND',
      body: _propfindBody(),
      depth: request['headers'] is Map ? null : '1',
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'WebDAV list failed: HTTP ${response.statusCode}',
      );
    }
    final body = await utf8.decodeStream(response);
    return _parsePropfind(body, path)
        .where((entry) => _normalize(entry.path) != _normalize(path))
        .toList()
      ..sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
  }

  @override
  Future<RemoteFileStat?> stat(String path) async {
    final request = plugin.infoRequest ?? plugin.listRequest;
    if (request == null) return null;
    final response = await _send(
      request,
      path: path,
      defaultMethod: 'PROPFIND',
      body: _propfindBody(),
      depth: '0',
    );
    if (response.statusCode == HttpStatus.notFound) return null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'WebDAV stat failed: HTTP ${response.statusCode}',
      );
    }
    final body = await utf8.decodeStream(response);
    final entries = _parsePropfind(body, path);
    final item = entries.isEmpty ? null : entries.first;
    if (item == null) return null;
    return RemoteFileStat(
      path: path,
      exists: true,
      isDirectory: item.isDirectory,
      sizeBytes: item.sizeBytes,
      modifiedAt: item.modifiedAt,
    );
  }

  @override
  Future<Uint8List> readBytes(String path) async {
    final request = plugin.streamRequest ??
        <String, Object?>{
          'method': 'GET',
          'url': plugin.listRequest?['url'],
          'auth': plugin.listRequest?['auth'],
        };
    final response = await _send(
      request,
      path: path,
      defaultMethod: 'GET',
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'WebDAV read failed: HTTP ${response.statusCode}',
      );
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  @override
  Future<void> writeBytes(String path, List<int> bytes) async {
    final request = plugin.raw['upload'] is Map
        ? (plugin.raw['upload'] as Map)
            .map((key, value) => MapEntry(key.toString(), value))
        : <String, Object?>{
            'method': 'PUT',
            'url': plugin.listRequest?['url'],
            'auth': plugin.listRequest?['auth'],
          };
    final response = await _send(
      request,
      path: path,
      defaultMethod: 'PUT',
      bytes: bytes,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'WebDAV upload failed: HTTP ${response.statusCode}',
      );
    }
    await response.drain<void>();
  }

  @override
  Future<void> createDirectory(String path) async {
    final response = await _send(
      <String, Object?>{
        'method': 'MKCOL',
        'url': plugin.listRequest?['url'],
        'auth': plugin.listRequest?['auth'],
      },
      path: path,
      defaultMethod: 'MKCOL',
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'WebDAV mkdir failed: HTTP ${response.statusCode}',
      );
    }
    await response.drain<void>();
  }

  @override
  Future<void> delete(String path, {required bool recursive}) async {
    final response = await _send(
      <String, Object?>{
        'method': 'DELETE',
        'url': plugin.listRequest?['url'],
        'auth': plugin.listRequest?['auth'],
      },
      path: path,
      defaultMethod: 'DELETE',
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'WebDAV delete failed: HTTP ${response.statusCode}',
      );
    }
    await response.drain<void>();
  }

  Future<HttpClientResponse> _send(
    Map<String, Object?> request, {
    required String path,
    required String defaultMethod,
    String? body,
    List<int>? bytes,
    String? depth,
  }) async {
    final urlTemplate = request['url']?.toString();
    if (urlTemplate == null || urlTemplate.trim().isEmpty) {
      throw StateError('Plugin ${plugin.id} has no URL template.');
    }
    final variables = _variables(plugin);
    final uri = Uri.parse(
      _substitute(urlTemplate, variables, path: path),
    );
    final client = HttpClient();
    final proxy = _proxy(plugin);
    if (proxy != null && proxy.isNotEmpty) {
      client.findProxy = (_) => 'PROXY $proxy';
    }
    final method = request['method']?.toString() ?? defaultMethod;
    final httpRequest = await client.openUrl(method, uri);
    final headers = request['headers'];
    if (headers is Map) {
      headers.forEach(
        (key, value) => httpRequest.headers.set(key.toString(), value),
      );
    }
    if (depth != null) {
      httpRequest.headers.set('Depth', depth);
    }
    if (request['auth'] == 'basic') {
      final username = variables['username'] ?? variables['login'] ?? '';
      final password = variables['password'] ?? variables['token'] ?? '';
      httpRequest.headers.set(
        HttpHeaders.authorizationHeader,
        'Basic ${base64Encode(utf8.encode('$username:$password'))}',
      );
    } else if (variables['token'] case final token? when token.isNotEmpty) {
      httpRequest.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $token',
      );
    }
    if (body != null) {
      httpRequest.headers.contentType =
          ContentType('application', 'xml', charset: 'utf-8');
      httpRequest.write(body);
    }
    if (bytes != null) {
      httpRequest.headers.contentLength = bytes.length;
      httpRequest.add(bytes);
    }
    return httpRequest.close();
  }

  String _propfindBody() => '''<?xml version="1.0" encoding="utf-8" ?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:displayname/>
    <d:getcontentlength/>
    <d:getlastmodified/>
    <d:resourcetype/>
  </d:prop>
</d:propfind>''';

  List<RemoteFileSystemEntry> _parsePropfind(
      String body, String requestedPath) {
    final document = XmlDocument.parse(body);
    final result = <RemoteFileSystemEntry>[];
    for (final response in document.descendants
        .whereType<XmlElement>()
        .where((node) => node.localName == 'response')) {
      final href = response.descendants
          .whereType<XmlElement>()
          .where((node) => node.localName == 'href')
          .map((node) => node.innerText)
          .firstOrNull;
      final prop = response.descendants
          .whereType<XmlElement>()
          .where((node) => node.localName == 'prop')
          .firstOrNull;
      if (href == null || prop == null) continue;
      final isDirectory = prop.descendants
          .whereType<XmlElement>()
          .any((node) => node.localName == 'collection');
      final lengthText = prop.descendants
          .whereType<XmlElement>()
          .where((node) => node.localName == 'getcontentlength')
          .map((node) => node.innerText)
          .firstOrNull;
      final modifiedText = prop.descendants
          .whereType<XmlElement>()
          .where((node) => node.localName == 'getlastmodified')
          .map((node) => node.innerText)
          .firstOrNull;
      final displayName = prop.descendants
          .whereType<XmlElement>()
          .where((node) => node.localName == 'displayname')
          .map((node) => node.innerText)
          .firstOrNull;
      final path = _pathFromHref(href, requestedPath);
      final name = (displayName?.trim().isNotEmpty == true
              ? displayName!.trim()
              : _remoteBasename(path))
          .trim();
      if (name.isEmpty) continue;
      result.add(RemoteFileSystemEntry(
        name: name,
        path: path,
        isDirectory: isDirectory,
        sizeBytes: int.tryParse(lengthText ?? '') ?? 0,
        modifiedAt: _parseHttpDate(modifiedText) ?? DateTime.now(),
      ));
    }
    return result;
  }

  String _pathFromHref(String href, String requestedPath) {
    final uri = Uri.parse(href);
    var decoded = Uri.decodeComponent(uri.path);
    final variables = _variables(plugin);
    for (final value in variables.values) {
      if (value.isEmpty) continue;
      decoded = decoded.replaceFirst('/$value/', '/');
    }
    final nextcloudMarker = '/remote.php/dav/files/';
    final markerIndex = decoded.indexOf(nextcloudMarker);
    if (markerIndex >= 0) {
      final rest = decoded.substring(markerIndex + nextcloudMarker.length);
      final slash = rest.indexOf('/');
      decoded = slash < 0 ? '/' : '/${rest.substring(slash + 1)}';
    }
    decoded = decoded.replaceAll(RegExp(r'/+'), '/');
    if (!decoded.startsWith('/')) decoded = '/$decoded';
    if (decoded != '/' && decoded.endsWith('/')) {
      decoded = decoded.substring(0, decoded.length - 1);
    }
    if (decoded == '/' && requestedPath != '/') return requestedPath;
    return decoded;
  }

  String _normalize(String value) {
    var normalized = value.replaceAll('\\', '/');
    if (normalized.length > 1 && normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }
}

class FtpRemoteClient implements RemoteFileSystemClient {
  FtpRemoteClient(this.plugin);

  final CloudPluginDefinition plugin;

  @override
  Future<List<RemoteFileSystemEntry>> list(String path) async {
    return _withConnection((connection) async {
      await connection.login();
      final lines = await connection.list(path);
      return lines
          .map((line) => _parseListLine(line, path))
          .whereType<RemoteFileSystemEntry>()
          .toList()
        ..sort((a, b) {
          if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
    });
  }

  @override
  Future<RemoteFileStat?> stat(String path) async {
    final parent = _remoteParent(path);
    final name = _remoteBasename(path);
    final entries = await list(parent);
    return entries
        .where((entry) => entry.name == name)
        .map((entry) => RemoteFileStat(
              path: path,
              exists: true,
              isDirectory: entry.isDirectory,
              sizeBytes: entry.sizeBytes,
              modifiedAt: entry.modifiedAt,
            ))
        .firstOrNull;
  }

  @override
  Future<Uint8List> readBytes(String path) async {
    return _withConnection((connection) async {
      await connection.login();
      return connection.retrieve(path);
    });
  }

  @override
  Future<void> writeBytes(String path, List<int> bytes) async {
    return _withConnection((connection) async {
      await connection.login();
      await connection.store(path, bytes);
    });
  }

  @override
  Future<void> createDirectory(String path) async {
    return _withConnection((connection) async {
      await connection.login();
      await connection.command('MKD ${_ftpPath(path)}', expected: [257, 250]);
    });
  }

  @override
  Future<void> delete(String path, {required bool recursive}) async {
    return _withConnection((connection) async {
      await connection.login();
      final stat = await this.stat(path);
      if (stat?.isDirectory == true) {
        await connection.command('RMD ${_ftpPath(path)}', expected: [250]);
      } else {
        await connection.command('DELE ${_ftpPath(path)}', expected: [250]);
      }
    });
  }

  Future<T> _withConnection<T>(Future<T> Function(_FtpConnection) body) async {
    final variables = _variables(plugin);
    final host = variables['host'] ?? variables['server'];
    if (host == null || host.isEmpty) {
      throw StateError('FTP plugin ${plugin.id} has no host variable.');
    }
    final port = int.tryParse(variables['port'] ?? '') ?? 21;
    final connection = await _FtpConnection.connect(
      host,
      port,
      username: variables['username'] ?? variables['user'] ?? 'anonymous',
      password: variables['password'] ?? 'anonymous@',
    );
    try {
      return await body(connection);
    } finally {
      await connection.close();
    }
  }

  RemoteFileSystemEntry? _parseListLine(String line, String parent) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('total ')) return null;
    final mlsd = RegExp(r'^([^ ]+)\s+(.+)$').firstMatch(trimmed);
    if (mlsd != null && mlsd.group(1)!.contains('=')) {
      final facts = <String, String>{};
      for (final part in mlsd.group(1)!.split(';')) {
        final eq = part.indexOf('=');
        if (eq > 0) {
          facts[part.substring(0, eq).toLowerCase()] = part.substring(eq + 1);
        }
      }
      final name = mlsd.group(2)!.trim();
      if (name == '.' || name == '..') return null;
      return RemoteFileSystemEntry(
        name: name,
        path: _remoteJoin(parent, name),
        isDirectory: facts['type'] == 'dir' || facts['type'] == 'cdir',
        sizeBytes: int.tryParse(facts['size'] ?? '') ?? 0,
        modifiedAt: _parseFtpModify(facts['modify']) ?? DateTime.now(),
      );
    }
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length < 9) return null;
    final isDirectory = parts.first.startsWith('d');
    final size = int.tryParse(parts[4]) ?? 0;
    final name = parts.sublist(8).join(' ');
    if (name == '.' || name == '..') return null;
    return RemoteFileSystemEntry(
      name: name,
      path: _remoteJoin(parent, name),
      isDirectory: isDirectory,
      sizeBytes: size,
      modifiedAt: DateTime.now(),
    );
  }

  DateTime? _parseFtpModify(String? value) {
    if (value == null || value.length < 14) return null;
    return DateTime.tryParse(
      '${value.substring(0, 4)}-${value.substring(4, 6)}-'
      '${value.substring(6, 8)}T${value.substring(8, 10)}:'
      '${value.substring(10, 12)}:${value.substring(12, 14)}Z',
    )?.toLocal();
  }
}

class SftpCommandRemoteClient implements RemoteFileSystemClient {
  SftpCommandRemoteClient(this.plugin);

  final CloudPluginDefinition plugin;

  @override
  Future<List<RemoteFileSystemEntry>> list(String path) async {
    final result = await _ssh([
      'python3',
      '-c',
      _remotePythonListScript(),
      _remotePath(path),
    ]);
    final decoded = jsonDecode(result);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map>()
        .map((item) => RemoteFileSystemEntry(
              name: item['name'].toString(),
              path: _remoteJoin(path, item['name'].toString()),
              isDirectory: item['isDirectory'] == true,
              sizeBytes:
                  item['size'] is num ? (item['size'] as num).round() : 0,
              modifiedAt: DateTime.fromMillisecondsSinceEpoch(
                item['mtimeMs'] is num
                    ? (item['mtimeMs'] as num).round()
                    : DateTime.now().millisecondsSinceEpoch,
              ),
            ))
        .toList()
      ..sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
  }

  @override
  Future<RemoteFileStat?> stat(String path) async {
    final parent = _remoteParent(path);
    final name = _remoteBasename(path);
    final entries = await list(parent);
    return entries
        .where((entry) => entry.name == name)
        .map((entry) => RemoteFileStat(
              path: path,
              exists: true,
              isDirectory: entry.isDirectory,
              sizeBytes: entry.sizeBytes,
              modifiedAt: entry.modifiedAt,
            ))
        .firstOrNull;
  }

  @override
  Future<Uint8List> readBytes(String path) async {
    return _sshBytes(['cat', _remotePath(path)]);
  }

  @override
  Future<void> writeBytes(String path, List<int> bytes) async {
    final variables = _variables(plugin);
    final target = _sshTarget(variables);
    final process = await Process.start(
      'ssh',
      [
        ..._sshOptions(variables),
        target,
        'cat > ${_shellQuote(_remotePath(path))}',
      ],
      runInShell: Platform.isWindows,
    );
    process.stdin.add(bytes);
    await process.stdin.close();
    final stderr = await utf8.decodeStream(process.stderr);
    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      throw ProcessException('ssh', ['write', path], stderr, exitCode);
    }
  }

  @override
  Future<void> createDirectory(String path) async {
    await _ssh(['mkdir', '-p', _remotePath(path)]);
  }

  @override
  Future<void> delete(String path, {required bool recursive}) async {
    await _ssh(recursive
        ? ['rm', '-rf', _remotePath(path)]
        : ['rm', '-f', _remotePath(path)]);
  }

  Future<String> _ssh(List<String> command) async {
    final bytes = await _sshBytes(command);
    return utf8.decode(bytes, allowMalformed: true);
  }

  Future<Uint8List> _sshBytes(List<String> command) async {
    final variables = _variables(plugin);
    final target = _sshTarget(variables);
    final remoteCommand = command.map(_shellQuote).join(' ');
    final result = await Process.run(
      'ssh',
      [..._sshOptions(variables), target, remoteCommand],
      runInShell: Platform.isWindows,
      stdoutEncoding: null,
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0) {
      throw ProcessException(
        'ssh',
        [target, remoteCommand],
        result.stderr.toString(),
        result.exitCode,
      );
    }
    return Uint8List.fromList(
      result.stdout is List<int>
          ? result.stdout as List<int>
          : utf8.encode(result.stdout.toString()),
    );
  }

  String _sshTarget(Map<String, String> variables) {
    final host = variables['host'] ?? variables['server'];
    if (host == null || host.isEmpty) {
      throw StateError('SFTP plugin ${plugin.id} has no host variable.');
    }
    final username = variables['username'] ?? variables['user'];
    return username == null || username.isEmpty ? host : '$username@$host';
  }

  List<String> _sshOptions(Map<String, String> variables) => [
        if ((variables['port'] ?? '').isNotEmpty) ...[
          '-p',
          variables['port']!,
        ],
        if ((variables['identityFile'] ?? '').isNotEmpty) ...[
          '-i',
          variables['identityFile']!,
        ],
        '-o',
        'BatchMode=yes',
      ];

  String _remotePythonListScript() => r'''
import json, os, sys
p=sys.argv[1]
out=[]
for name in os.listdir(p):
    if name in ('.','..'): continue
    full=os.path.join(p,name)
    st=os.stat(full)
    out.append({'name':name,'isDirectory':os.path.isdir(full),'size':st.st_size,'mtimeMs':int(st.st_mtime*1000)})
print(json.dumps(out))
''';
}

class SmbCommandRemoteClient implements RemoteFileSystemClient {
  SmbCommandRemoteClient(this.plugin);

  final CloudPluginDefinition plugin;

  @override
  Future<List<RemoteFileSystemEntry>> list(String path) async {
    final output = await _smb(['dir "${_smbPath(path)}"']);
    final entries = <RemoteFileSystemEntry>[];
    for (final line in output.split(RegExp(r'\r?\n'))) {
      final match =
          RegExp(r'^\s*(.+?)\s+([ADHRS]+)\s+(\d+)\s+(.+)$').firstMatch(line);
      if (match == null) continue;
      final name = match.group(1)!.trim();
      if (name == '.' || name == '..') continue;
      entries.add(RemoteFileSystemEntry(
        name: name,
        path: _remoteJoin(path, name),
        isDirectory: match.group(2)!.contains('D'),
        sizeBytes: int.tryParse(match.group(3)!) ?? 0,
        modifiedAt: DateTime.tryParse(match.group(4)!) ?? DateTime.now(),
      ));
    }
    return entries
      ..sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
  }

  @override
  Future<RemoteFileStat?> stat(String path) async {
    final parent = _remoteParent(path);
    final name = _remoteBasename(path);
    final entries = await list(parent);
    return entries
        .where((entry) => entry.name == name)
        .map((entry) => RemoteFileStat(
              path: path,
              exists: true,
              isDirectory: entry.isDirectory,
              sizeBytes: entry.sizeBytes,
              modifiedAt: entry.modifiedAt,
            ))
        .firstOrNull;
  }

  @override
  Future<Uint8List> readBytes(String path) async {
    final variables = _variables(plugin);
    final temp = await File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}securevault_smb_${DateTime.now().microsecondsSinceEpoch}',
    ).create();
    try {
      await _smb(['get "${_smbPath(path)}" "${temp.path}"'], variables);
      return temp.readAsBytes();
    } finally {
      await temp.delete().catchError((_) => temp);
    }
  }

  @override
  Future<void> writeBytes(String path, List<int> bytes) async {
    final temp = await File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}securevault_smb_${DateTime.now().microsecondsSinceEpoch}',
    ).create();
    try {
      await temp.writeAsBytes(bytes, flush: true);
      await _smb(['put "${temp.path}" "${_smbPath(path)}"']);
    } finally {
      await temp.delete().catchError((_) => temp);
    }
  }

  @override
  Future<void> createDirectory(String path) async {
    await _smb(['mkdir "${_smbPath(path)}"']);
  }

  @override
  Future<void> delete(String path, {required bool recursive}) async {
    final stat = await this.stat(path);
    await _smb([
      stat?.isDirectory == true
          ? 'rmdir "${_smbPath(path)}"'
          : 'del "${_smbPath(path)}"',
    ]);
  }

  Future<String> _smb(
    List<String> commands, [
    Map<String, String>? variables,
  ]) async {
    variables ??= _variables(plugin);
    final share = variables['share'] ?? variables['url'];
    if (share == null || share.isEmpty) {
      throw StateError('SMB plugin ${plugin.id} has no share variable.');
    }
    final username = variables['username'] ?? variables['user'] ?? '';
    final password = variables['password'] ?? '';
    final args = <String>[
      share,
      if (username.isNotEmpty) ...['-U', '$username%$password'],
      '-c',
      commands.join('; '),
    ];
    final result = await Process.run(
      'smbclient',
      args,
      runInShell: Platform.isWindows,
    );
    if (result.exitCode != 0) {
      throw ProcessException(
        'smbclient',
        args,
        result.stderr.toString(),
        result.exitCode,
      );
    }
    return result.stdout.toString();
  }
}

class _FtpConnection {
  _FtpConnection._(
    this._socket, {
    required this.username,
    required this.password,
  }) {
    _lines = _socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .asBroadcastStream();
  }

  final Socket _socket;
  final String username;
  final String password;
  late final Stream<String> _lines;

  static Future<_FtpConnection> connect(
    String host,
    int port, {
    required String username,
    required String password,
  }) async {
    final socket =
        await Socket.connect(host, port, timeout: const Duration(seconds: 20));
    final connection = _FtpConnection._(
      socket,
      username: username,
      password: password,
    );
    await connection._readResponse(expected: [220]);
    return connection;
  }

  Future<void> login() async {
    _socket.writeln('USER $username');
    final user =
        await _readResponse(expected: [230, 331], allowUnexpected: true);
    if (user.code == 331) {
      _socket.writeln('PASS $password');
      await _readResponse(expected: [230, 202]);
    } else if (user.code != 230) {
      throw StateError('FTP login failed: ${user.message}');
    }
  }

  Future<void> command(String command,
      {List<int> expected = const [200]}) async {
    _socket.writeln(command);
    await _readResponse(expected: expected);
  }

  Future<List<String>> list(String path) async {
    await command('TYPE I');
    final data = await _openPassiveData();
    _socket.writeln('MLSD ${_ftpPath(path)}');
    final accepted =
        await _readResponse(expected: [125, 150], allowUnexpected: true);
    if (accepted.code >= 400) {
      await data.close();
      final data2 = await _openPassiveData();
      _socket.writeln('LIST ${_ftpPath(path)}');
      await _readResponse(expected: [125, 150]);
      final lines = await utf8.decoder
          .bind(data2)
          .transform(const LineSplitter())
          .toList();
      await _readResponse(expected: [226, 250]);
      return lines;
    }
    final lines =
        await utf8.decoder.bind(data).transform(const LineSplitter()).toList();
    await _readResponse(expected: [226, 250]);
    return lines;
  }

  Future<Uint8List> retrieve(String path) async {
    await command('TYPE I');
    final data = await _openPassiveData();
    _socket.writeln('RETR ${_ftpPath(path)}');
    await _readResponse(expected: [125, 150]);
    final builder = BytesBuilder(copy: false);
    await for (final chunk in data) {
      builder.add(chunk);
    }
    await _readResponse(expected: [226, 250]);
    return builder.takeBytes();
  }

  Future<void> store(String path, List<int> bytes) async {
    await command('TYPE I');
    final data = await _openPassiveData();
    _socket.writeln('STOR ${_ftpPath(path)}');
    await _readResponse(expected: [125, 150]);
    data.add(bytes);
    await data.close();
    await _readResponse(expected: [226, 250]);
  }

  Future<Socket> _openPassiveData() async {
    _socket.writeln('PASV');
    final response = await _readResponse(expected: [227]);
    final match = RegExp(r'\((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\)')
        .firstMatch(response.message);
    if (match == null) {
      throw const FormatException('Invalid FTP PASV response.');
    }
    final host = [
      for (var i = 1; i <= 4; i++) match.group(i)!,
    ].join('.');
    final p1 = int.parse(match.group(5)!);
    final p2 = int.parse(match.group(6)!);
    return Socket.connect(host, p1 * 256 + p2,
        timeout: const Duration(seconds: 20));
  }

  Future<_FtpResponse> _readResponse({
    required List<int> expected,
    bool allowUnexpected = false,
  }) async {
    final iterator = StreamIterator<String>(_lines);
    final buffer = <String>[];
    int? code;
    while (await iterator.moveNext()) {
      final line = iterator.current;
      buffer.add(line);
      if (line.length >= 3 && int.tryParse(line.substring(0, 3)) != null) {
        code = int.parse(line.substring(0, 3));
        if (line.length < 4 || line[3] == ' ') break;
      }
    }
    final response = _FtpResponse(code ?? 0, buffer.join('\n'));
    if (!expected.contains(response.code) && !allowUnexpected) {
      throw StateError('FTP command failed: ${response.message}');
    }
    return response;
  }

  Future<void> close() async {
    try {
      _socket.writeln('QUIT');
    } catch (_) {}
    await _socket.close();
  }
}

class _FtpResponse {
  const _FtpResponse(this.code, this.message);

  final int code;
  final String message;
}

Map<String, String> _variables(CloudPluginDefinition plugin) {
  final result = <String, String>{};
  void readMap(Map<String, Object?>? values) {
    values?.forEach((key, raw) {
      if (raw is Map) {
        final env = raw['env']?.toString();
        final value = raw['value']?.toString() ??
            raw['default']?.toString() ??
            (env == null ? null : Platform.environment[env]);
        if (value != null) result[key] = value;
      } else if (raw != null) {
        result[key] = raw.toString();
      }
    });
  }

  readMap(plugin.variables);
  final envPrefix =
      'SECUREVAULT_${plugin.id.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]+'), '_')}';
  for (final entry in Platform.environment.entries) {
    if (entry.key.startsWith('${envPrefix}_')) {
      final key = entry.key.substring(envPrefix.length + 1).toLowerCase();
      result[key] = entry.value;
    }
  }
  return result;
}

String? _proxy(CloudPluginDefinition plugin) {
  final proxy = plugin.proxy;
  if (proxy == null) return null;
  final value = proxy['value']?.toString();
  if (value != null && value.isNotEmpty) return value;
  final envs = proxy['variables'];
  if (envs is List) {
    for (final env in envs) {
      final value = Platform.environment[env.toString()];
      if (value != null && value.isNotEmpty) return value;
    }
  }
  return null;
}

DateTime? _parseHttpDate(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  try {
    return HttpDate.parse(value);
  } catch (_) {
    return null;
  }
}

String _substitute(
  String template,
  Map<String, String> variables, {
  required String path,
}) {
  var value = template;
  variables.forEach((key, variableValue) {
    value = value.replaceAll('{$key}', Uri.encodeComponent(variableValue));
  });
  final remotePath = path == '/' ? '' : path.replaceFirst(RegExp(r'^/+'), '');
  return value.replaceAll(
      '{path}', remotePath.split('/').map(Uri.encodeComponent).join('/'));
}

String _remoteJoin(String parent, String name) {
  final cleanParent =
      parent.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
  final cleanName = name.replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '');
  if (cleanParent.isEmpty || cleanParent == '/') return '/$cleanName';
  return '$cleanParent/$cleanName';
}

String _remoteParent(String path) {
  final clean = path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
  final index = clean.lastIndexOf('/');
  if (index <= 0) return '/';
  return clean.substring(0, index);
}

String _remoteBasename(String path) {
  final clean = path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
  if (clean.isEmpty || clean == '/') return '/';
  return clean.split('/').last;
}

String _remotePath(String path) => path.isEmpty ? '/' : path;

String _ftpPath(String path) {
  final normalized = path.isEmpty ? '/' : path;
  if (!RegExp(r'[\s"\\]').hasMatch(normalized)) return normalized;
  return '"${normalized.replaceAll('"', r'\"')}"';
}

String _smbPath(String path) {
  final normalized =
      path.replaceAll('/', '\\').replaceFirst(RegExp(r'^\\+'), '');
  return normalized.isEmpty ? '\\' : normalized;
}

String _shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
