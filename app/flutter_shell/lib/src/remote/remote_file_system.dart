import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:dartssh2/dartssh2.dart';
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
  bool get supportsPermissions => false;

  Future<List<RemoteFileSystemEntry>> list(String path);

  Future<RemoteFileStat?> stat(String path);

  Future<Uint8List> readBytes(String path);

  Future<void> writeBytes(String path, List<int> bytes);

  Future<void> createDirectory(String path);

  Future<void> delete(String path, {required bool recursive});

  Future<void> setPermissions(
    String path, {
    required int mode,
    required bool recursive,
  }) async {
    throw UnsupportedError('Permissions are not supported by this location.');
  }
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
        executor == 'ssh' ||
        executor == 'sftp' ||
        executor == 'smb' ||
        executor == 'raid0' ||
        executor == 'raid1';
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
      'ssh' || 'sftp' => SftpRemoteClient(plugin),
      'smb' => SmbRemoteClient(plugin),
      'raid0' => RaidRemoteClient(plugin, this, mirror: false),
      'raid1' => RaidRemoteClient(plugin, this, mirror: true),
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
  bool get supportsPermissions => false;

  @override
  Future<void> setPermissions(
    String path, {
    required int mode,
    required bool recursive,
  }) async {
    throw UnsupportedError('WebDAV permissions are not supported.');
  }

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
    Object? lastError;
    for (final variables in _endpointVariableSets(_variables(plugin))) {
      try {
        final uri = Uri.parse(
          _substitute(urlTemplate, variables, path: path),
        );
        final client = HttpClient();
        final proxy = _proxy(plugin, variables);
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
      } catch (error) {
        lastError = error;
      }
    }
    throw StateError('WebDAV connection failed: $lastError');
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
  bool get supportsPermissions => false;

  @override
  Future<void> setPermissions(
    String path, {
    required int mode,
    required bool recursive,
  }) async {
    throw UnsupportedError('FTP permissions are not supported.');
  }

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
    Object? lastError;
    for (final variables in _endpointVariableSets(_variables(plugin))) {
      final host = variables['host'] ?? variables['server'];
      if (host == null || host.isEmpty) {
        lastError = StateError('FTP plugin ${plugin.id} has no host variable.');
        continue;
      }
      final port = int.tryParse(variables['port'] ?? '') ?? 21;
      try {
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
      } catch (error) {
        lastError = error;
      }
    }
    throw StateError('FTP connection failed: $lastError');
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

class SftpRemoteClient implements RemoteFileSystemClient {
  SftpRemoteClient(this.plugin);

  final CloudPluginDefinition plugin;

  @override
  bool get supportsPermissions => true;

  @override
  Future<List<RemoteFileSystemEntry>> list(String path) async {
    return _withSftp((sftp) async {
      final entries = await sftp.listdir(_remotePath(path));
      return entries
          .where((entry) => entry.filename != '.' && entry.filename != '..')
          .map((entry) => RemoteFileSystemEntry(
                name: entry.filename,
                path: _remoteJoin(path, entry.filename),
                isDirectory: entry.attr.isDirectory,
                sizeBytes: entry.attr.size ?? 0,
                modifiedAt: _sftpModifiedAt(entry.attr),
              ))
          .toList()
        ..sort((a, b) {
          if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
    });
  }

  @override
  Future<RemoteFileStat?> stat(String path) async {
    return _withSftp((sftp) async {
      try {
        final attrs = await sftp.stat(_remotePath(path));
        return RemoteFileStat(
          path: path,
          exists: true,
          isDirectory: attrs.isDirectory,
          sizeBytes: attrs.size ?? 0,
          modifiedAt: _sftpModifiedAt(attrs),
        );
      } on SftpStatusError catch (error) {
        if (error.code == SftpStatusCode.noSuchFile) return null;
        rethrow;
      }
    });
  }

  @override
  Future<Uint8List> readBytes(String path) async {
    return _withSftp((sftp) async {
      final file = await sftp.open(_remotePath(path));
      try {
        return file.readBytes();
      } finally {
        await file.close();
      }
    });
  }

  @override
  Future<void> writeBytes(String path, List<int> bytes) async {
    return _withSftp((sftp) async {
      final file = await sftp.open(
        _remotePath(path),
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.truncate |
            SftpFileOpenMode.write,
      );
      try {
        await file.writeBytes(Uint8List.fromList(bytes));
      } finally {
        await file.close();
      }
    });
  }

  @override
  Future<void> createDirectory(String path) async {
    return _withSftp((sftp) => sftp.mkdir(_remotePath(path)));
  }

  @override
  Future<void> delete(String path, {required bool recursive}) async {
    return _withSftp((sftp) => _deleteSftpPath(sftp, path, recursive));
  }

  @override
  Future<void> setPermissions(
    String path, {
    required int mode,
    required bool recursive,
  }) async {
    if (mode < 0 || mode > 0xFFF) {
      throw ArgumentError('Permission mode must be an octal value like 755.');
    }
    return _withSsh((client, _) async {
      final modeText = mode.toRadixString(8).padLeft(3, '0');
      final command = [
        'chmod',
        if (recursive) '-R',
        modeText,
        '--',
        _shellQuote(_remotePath(path)),
      ].join(' ');
      final output = await client.run(command, stderr: true);
      final message = utf8.decode(output, allowMalformed: true).trim();
      if (message.toLowerCase().contains('permission denied')) {
        throw StateError(message);
      }
    });
  }

  Future<void> _deleteSftpPath(
    SftpClient sftp,
    String path,
    bool recursive,
  ) async {
    final remotePath = _remotePath(path);
    final attrs = await sftp.stat(remotePath);
    if (attrs.isDirectory) {
      if (recursive) {
        final children = await sftp.listdir(remotePath);
        for (final child in children) {
          if (child.filename == '.' || child.filename == '..') continue;
          await _deleteSftpPath(
            sftp,
            _remoteJoin(path, child.filename),
            recursive,
          );
        }
      }
      await sftp.rmdir(remotePath);
    } else {
      await sftp.remove(remotePath);
    }
  }

  Future<T> _withSsh<T>(
    Future<T> Function(SSHClient, Map<String, String>) body,
  ) async {
    Object? lastError;
    for (final variables in _endpointVariableSets(_variables(plugin))) {
      final host = variables['host'] ?? variables['server'];
      if (host == null || host.isEmpty) {
        lastError =
            StateError('SFTP plugin ${plugin.id} has no host variable.');
        continue;
      }
      try {
        final port = int.tryParse(variables['port'] ?? '') ?? 22;
        final username = variables['username'] ??
            variables['user'] ??
            Platform.environment['USERNAME'] ??
            Platform.environment['USER'] ??
            'anonymous';
        final password = _emptyToNull(variables['password']);
        final identities = await _loadSshIdentities(variables);
        final socket = await SSHSocket.connect(
          host,
          port,
          timeout: _connectionTimeout(variables),
        );
        final client = SSHClient(
          socket,
          username: username,
          identities: identities,
          onPasswordRequest: password == null ? null : () => password,
          onUserInfoRequest: password == null
              ? null
              : (request) =>
                  List<String>.filled(request.prompts.length, password),
          ident: 'FilesManagersEmbeddedSSH_1.0',
        );
        try {
          return await body(client, variables);
        } finally {
          client.close();
          try {
            await client.done.timeout(const Duration(seconds: 2));
          } catch (_) {}
        }
      } catch (error) {
        lastError = error;
      }
    }
    throw StateError('SSH connection failed: $lastError');
  }

  Future<T> _withSftp<T>(Future<T> Function(SftpClient) body) async {
    Object? lastError;
    for (final variables in _endpointVariableSets(_variables(plugin))) {
      final host = variables['host'] ?? variables['server'];
      if (host == null || host.isEmpty) {
        lastError =
            StateError('SFTP plugin ${plugin.id} has no host variable.');
        continue;
      }
      try {
        final port = int.tryParse(variables['port'] ?? '') ?? 22;
        final username = variables['username'] ??
            variables['user'] ??
            Platform.environment['USERNAME'] ??
            Platform.environment['USER'] ??
            'anonymous';
        final password = _emptyToNull(variables['password']);
        final identities = await _loadSshIdentities(variables);
        final socket = await SSHSocket.connect(
          host,
          port,
          timeout: _connectionTimeout(variables),
        );
        final client = SSHClient(
          socket,
          username: username,
          identities: identities,
          onPasswordRequest: password == null ? null : () => password,
          onUserInfoRequest: password == null
              ? null
              : (request) =>
                  List<String>.filled(request.prompts.length, password),
          ident: 'FilesManagersEmbeddedSSH_1.0',
        );
        final sftp = await client.sftp();
        try {
          return await body(sftp);
        } finally {
          sftp.close();
          client.close();
          try {
            await client.done.timeout(const Duration(seconds: 2));
          } catch (_) {}
        }
      } catch (error) {
        lastError = error;
      }
    }
    throw StateError('SFTP connection failed: $lastError');
  }

  Future<List<SSHKeyPair>?> _loadSshIdentities(
    Map<String, String> variables,
  ) async {
    final identityFile = _emptyToNull(
      variables['identityFile'] ??
          variables['identityfile'] ??
          variables['privateKey'] ??
          variables['privatekey'],
    );
    if (identityFile == null) return null;
    final passphrase = _emptyToNull(
      variables['passphrase'] ?? variables['keyPassphrase'],
    );
    final pem = await File(identityFile).readAsString();
    return SSHKeyPair.fromPem(pem, passphrase);
  }

  DateTime _sftpModifiedAt(SftpFileAttrs attrs) {
    final seconds = attrs.modifyTime;
    if (seconds == null) return DateTime.now();
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  }
}

class SmbRemoteClient implements RemoteFileSystemClient {
  SmbRemoteClient(this.plugin);

  final CloudPluginDefinition plugin;

  @override
  bool get supportsPermissions => false;

  @override
  Future<void> setPermissions(
    String path, {
    required int mode,
    required bool recursive,
  }) async {
    throw UnsupportedError(
      'SMB permission changes are not exposed by the bundled dart_smb2/libsmb2 API.',
    );
  }

  @override
  Future<List<RemoteFileSystemEntry>> list(String path) async {
    return _withPool((pool, settings) async {
      final entries = await pool.listDirectory(_smbPoolPath(path, settings));
      return entries
          .where((entry) => entry.name != '.' && entry.name != '..')
          .map((entry) => RemoteFileSystemEntry(
                name: entry.name,
                path: _remoteJoin(path, entry.name),
                isDirectory: entry.isDirectory,
                sizeBytes: entry.size,
                modifiedAt: entry.stat.modified.toLocal(),
              ))
          .toList()
        ..sort((a, b) {
          if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
    });
  }

  @override
  Future<RemoteFileStat?> stat(String path) async {
    return _withPool((pool, settings) async {
      final smbPath = _smbPoolPath(path, settings);
      if (smbPath.isEmpty) {
        return RemoteFileStat(
          path: path,
          exists: true,
          isDirectory: true,
          sizeBytes: 0,
          modifiedAt: DateTime.now(),
        );
      }
      try {
        final stat = await pool.stat(smbPath);
        return RemoteFileStat(
          path: path,
          exists: true,
          isDirectory: stat.isDirectory,
          sizeBytes: stat.size,
          modifiedAt: stat.modified.toLocal(),
        );
      } on Smb2Exception catch (error) {
        if (error.type == Smb2ErrorType.fileNotFound) return null;
        rethrow;
      }
    });
  }

  @override
  Future<Uint8List> readBytes(String path) async {
    return _withPool(
      (pool, settings) => pool.readFile(_smbPoolPath(path, settings)),
    );
  }

  @override
  Future<void> writeBytes(String path, List<int> bytes) async {
    return _withPool(
      (pool, settings) => pool.writeFile(
        _smbPoolPath(path, settings),
        Uint8List.fromList(bytes),
      ),
    );
  }

  @override
  Future<void> createDirectory(String path) async {
    return _withPool(
      (pool, settings) => pool.mkdir(_smbPoolPath(path, settings)),
    );
  }

  @override
  Future<void> delete(String path, {required bool recursive}) async {
    return _withPool(
      (pool, settings) => _deleteSmbPath(pool, settings, path, recursive),
    );
  }

  Future<void> _deleteSmbPath(
    Smb2Pool pool,
    _SmbConnectionSettings settings,
    String path,
    bool recursive,
  ) async {
    final smbPath = _smbPoolPath(path, settings);
    final stat = await pool.stat(smbPath);
    if (stat.isDirectory) {
      if (recursive) {
        final children = await pool.listDirectory(smbPath);
        for (final child in children) {
          if (child.name == '.' || child.name == '..') continue;
          await _deleteSmbPath(
            pool,
            settings,
            _remoteJoin(path, child.name),
            recursive,
          );
        }
      }
      await pool.rmdir(smbPath);
    } else {
      await pool.deleteFile(smbPath);
    }
  }

  Future<T> _withPool<T>(
    Future<T> Function(Smb2Pool, _SmbConnectionSettings) body,
  ) async {
    Object? lastError;
    for (final variables in _endpointVariableSets(_variables(plugin))) {
      try {
        final settings = _smbSettings(variables);
        final pool = await Smb2Pool.connect(
          host: settings.host,
          share: settings.share,
          user: settings.username,
          password: settings.password,
          domain: settings.domain,
          workers: settings.workers,
          timeoutSeconds: settings.timeoutSeconds,
          seal: settings.seal,
          signing: settings.signing,
          version: settings.version,
        );
        try {
          return await body(pool, settings);
        } finally {
          await pool.disconnect();
        }
      } catch (error) {
        lastError = error;
      }
    }
    throw StateError('SMB connection failed: $lastError');
  }

  _SmbConnectionSettings _smbSettings(Map<String, String> variables) {
    final rawShare = variables['share'] ?? variables['url'];
    final parsed = _parseSmbShare(rawShare);
    final host =
        _emptyToNull(variables['host'] ?? variables['server']) ?? parsed.host;
    final share = _emptyToNull(
          variables['shareName'] ?? variables['sharename'],
        ) ??
        parsed.share;
    if (host == null || host.isEmpty) {
      throw StateError('SMB plugin ${plugin.id} has no host variable.');
    }
    if (share == null || share.isEmpty) {
      throw StateError('SMB plugin ${plugin.id} has no share variable.');
    }
    var username = _emptyToNull(variables['username'] ?? variables['user']);
    var domain = _emptyToNull(variables['domain'] ?? variables['workgroup']);
    if (username != null && username.contains(r'\') && domain == null) {
      final parts = username.split(r'\');
      domain = parts.first;
      username = parts.sublist(1).join(r'\');
    }
    return _SmbConnectionSettings(
      host: host,
      share: share,
      basePath: _joinSmbFragments([
        parsed.basePath,
        _emptyToNull(variables['basePath'] ?? variables['basepath']),
      ]),
      username: username,
      password: _emptyToNull(variables['password']),
      domain: domain,
      workers:
          _boundedInt(variables['workers'], defaultValue: 4, min: 1, max: 8),
      timeoutSeconds: _boundedInt(
        variables['timeoutSeconds'],
        defaultValue: 30,
        min: 5,
        max: 300,
      ),
      seal: _boolValue(variables['seal']),
      signing: _boolValue(variables['signing']),
      version: _smbVersion(variables['version']),
    );
  }

  _ParsedSmbShare _parseSmbShare(String? rawShare) {
    final value = _emptyToNull(rawShare);
    if (value == null) return const _ParsedSmbShare();
    var normalized = value.trim().replaceAll('\\', '/');
    if (normalized.startsWith('smb://')) {
      normalized = normalized.substring('smb://'.length);
    } else {
      normalized = normalized.replaceFirst(RegExp(r'^/+'), '');
    }
    final parts =
        normalized.split('/').where((part) => part.isNotEmpty).toList();
    if (parts.length >= 2 &&
        (value.contains('://') ||
            value.startsWith('//') ||
            value.startsWith(r'\\'))) {
      return _ParsedSmbShare(
        host: parts[0],
        share: parts[1],
        basePath: parts.length > 2 ? parts.sublist(2).join('/') : '',
      );
    }
    return _ParsedSmbShare(share: parts.isEmpty ? value : parts.first);
  }

  String _smbPoolPath(String path, _SmbConnectionSettings settings) {
    return _joinSmbFragments([settings.basePath, path]);
  }

  Smb2Version _smbVersion(String? value) {
    final normalized =
        (value ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return switch (normalized) {
      '2' || 'smb2' || 'any2' => Smb2Version.any2,
      '3' || 'smb3' || 'any3' => Smb2Version.any3,
      '202' || 'smb202' || 'v202' => Smb2Version.v202,
      '210' || '21' || 'smb210' || 'v210' => Smb2Version.v210,
      '300' || '30' || 'smb300' || 'v300' => Smb2Version.v300,
      '302' || '3020' || 'smb302' || 'v302' => Smb2Version.v302,
      '311' || '3110' || 'smb311' || 'v311' => Smb2Version.v311,
      _ => Smb2Version.any,
    };
  }
}

class _ParsedSmbShare {
  const _ParsedSmbShare({this.host, this.share, this.basePath = ''});

  final String? host;
  final String? share;
  final String basePath;
}

class _SmbConnectionSettings {
  const _SmbConnectionSettings({
    required this.host,
    required this.share,
    required this.basePath,
    required this.username,
    required this.password,
    required this.domain,
    required this.workers,
    required this.timeoutSeconds,
    required this.seal,
    required this.signing,
    required this.version,
  });

  final String host;
  final String share;
  final String basePath;
  final String? username;
  final String? password;
  final String? domain;
  final int workers;
  final int timeoutSeconds;
  final bool seal;
  final bool signing;
  final Smb2Version version;
}

class RaidRemoteClient implements RemoteFileSystemClient {
  RaidRemoteClient(this.plugin, this.repository, {required this.mirror});

  final CloudPluginDefinition plugin;
  final RemoteFileSystemRepository repository;
  final bool mirror;

  @override
  bool get supportsPermissions => false;

  @override
  Future<void> setPermissions(
    String path, {
    required int mode,
    required bool recursive,
  }) async {
    throw UnsupportedError('Composite RAID locations do not expose chmod.');
  }

  @override
  Future<List<RemoteFileSystemEntry>> list(String path) async {
    final members = _members();
    final merged = <String, RemoteFileSystemEntry>{};
    Object? lastError;
    var successful = 0;
    for (final member in members) {
      try {
        final entries = await repository.clientFor(member).list(path);
        successful++;
        for (final entry in entries) {
          final key = '${entry.isDirectory ? 'd' : 'f'}:${entry.path}';
          merged.putIfAbsent(key, () => entry);
        }
      } catch (error) {
        lastError = error;
      }
    }
    if (successful == 0 && lastError != null) {
      throw StateError('RAID location could not be opened: $lastError');
    }
    return merged.values.toList()
      ..sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
  }

  @override
  Future<RemoteFileStat?> stat(String path) async {
    if (path == '/' || path.isEmpty) {
      return RemoteFileStat(
        path: '/',
        exists: true,
        isDirectory: true,
        sizeBytes: 0,
        modifiedAt: DateTime.now(),
      );
    }
    Object? lastError;
    for (final member in _members()) {
      try {
        final stat = await repository.clientFor(member).stat(path);
        if (stat != null && stat.exists) return stat;
      } catch (error) {
        lastError = error;
      }
    }
    if (lastError != null) return null;
    return null;
  }

  @override
  Future<Uint8List> readBytes(String path) async {
    Object? lastError;
    for (final member in _members()) {
      try {
        final stat = await repository.clientFor(member).stat(path);
        if (stat == null || !stat.exists || stat.isDirectory) continue;
        return await repository.clientFor(member).readBytes(path);
      } catch (error) {
        lastError = error;
      }
    }
    throw StateError('RAID file is unavailable: $path ($lastError)');
  }

  @override
  Future<void> writeBytes(String path, List<int> bytes) async {
    final members = _members();
    await _ensureParentsOnMembers(path, members);
    if (mirror) {
      await Future.wait(
        members.map((member) => repository.clientFor(member).writeBytes(
              path,
              bytes,
            )),
      );
      return;
    }
    final target = _chooseRaid0Member(path, members);
    await repository.clientFor(target).writeBytes(path, bytes);
  }

  @override
  Future<void> createDirectory(String path) async {
    final members = _members();
    await _ensureParentsOnMembers(path, members);
    await Future.wait(members.map((member) async {
      final client = repository.clientFor(member);
      final stat = await client.stat(path);
      if (stat?.exists == true) return;
      await client.createDirectory(path);
    }));
  }

  @override
  Future<void> delete(String path, {required bool recursive}) async {
    Object? lastError;
    var deleted = false;
    for (final member in _members()) {
      try {
        final client = repository.clientFor(member);
        final stat = await client.stat(path);
        if (stat == null || !stat.exists) continue;
        await client.delete(path, recursive: recursive || stat.isDirectory);
        deleted = true;
      } catch (error) {
        lastError = error;
      }
    }
    if (!deleted && lastError != null) {
      throw StateError('RAID delete failed: $lastError');
    }
  }

  List<String> _members() {
    final variables = _variables(plugin);
    final raw = variables['members'] ?? variables['memberProfileIds'] ?? '';
    final members = raw
        .split(RegExp(r'[,;\n]'))
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .map(_resolveMemberToken)
        .whereType<String>()
        .where((id) => id != plugin.id)
        .where(repository.hasPlugin)
        .toSet()
        .toList();
    if (members.isEmpty) {
      throw StateError('RAID profile ${plugin.name} has no available members.');
    }
    return members;
  }

  String? _resolveMemberToken(String token) {
    if (repository.hasPlugin(token)) return token;
    final prefixed = token.startsWith('profile-') ? token : 'profile-$token';
    if (repository.hasPlugin(prefixed)) return prefixed;
    for (final entry in repository._plugins.entries) {
      final candidate = entry.value;
      if (candidate.profileId == token ||
          candidate.name == token ||
          candidate.sourcePluginId == token) {
        return entry.key;
      }
    }
    return null;
  }

  Future<void> _ensureParentsOnMembers(
    String path,
    List<String> members,
  ) async {
    final parents = <String>[];
    var parent = _remoteParent(path);
    while (parent != '/' && parent.isNotEmpty) {
      parents.add(parent);
      parent = _remoteParent(parent);
    }
    for (final directory in parents.reversed) {
      await Future.wait(members.map((member) async {
        final client = repository.clientFor(member);
        final stat = await client.stat(directory);
        if (stat?.exists == true) return;
        await client.createDirectory(directory);
      }));
    }
  }

  String _chooseRaid0Member(String path, List<String> members) {
    var bestMember = members.first;
    var bestFree = -1;
    for (final member in members) {
      final plugin = repository._plugins[member];
      if (plugin == null) continue;
      final free =
          int.tryParse(_variables(plugin)['freeSpaceBytes'] ?? '') ?? -1;
      if (free > bestFree) {
        bestFree = free;
        bestMember = member;
      }
    }
    if (bestFree >= 0) return bestMember;
    var hash = 0;
    for (final codeUnit in path.codeUnits) {
      hash = ((hash * 31) + codeUnit) & 0x7fffffff;
    }
    return members[hash % members.length];
  }
}

String _joinSmbFragments(List<String?> fragments) {
  return fragments
      .whereType<String>()
      .map((part) => part.replaceAll('\\', '/'))
      .expand((part) => part.split('/'))
      .where((part) => part.trim().isNotEmpty)
      .join('/');
}

Duration _connectionTimeout(Map<String, String> variables) {
  return Duration(
    seconds: _boundedInt(
      variables['timeoutSeconds'] ?? variables['timeout'],
      defaultValue: 30,
      min: 5,
      max: 300,
    ),
  );
}

String _shellQuote(String value) {
  final escaped = value.replaceAll("'", r"'\''");
  return "'$escaped'";
}

String? _emptyToNull(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

bool _boolValue(String? value) {
  final normalized = value?.trim().toLowerCase();
  return normalized == '1' ||
      normalized == 'true' ||
      normalized == 'yes' ||
      normalized == 'on';
}

int _boundedInt(
  String? value, {
  required int defaultValue,
  required int min,
  required int max,
}) {
  final parsed = int.tryParse(value ?? '') ?? defaultValue;
  if (parsed < min) return min;
  if (parsed > max) return max;
  return parsed;
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
  final normalizedPluginId =
      plugin.id.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]+'), '_');
  final envPrefixes = <String>[
    'FILESMANAGERS_$normalizedPluginId',
    'SECUREVAULT_$normalizedPluginId',
  ];
  for (final prefix in envPrefixes) {
    for (final entry in Platform.environment.entries) {
      if (entry.key.startsWith('${prefix}_')) {
        final key = entry.key.substring(prefix.length + 1).toLowerCase();
        result[key] = entry.value;
      }
    }
  }
  return result;
}

List<Map<String, String>> _endpointVariableSets(Map<String, String> base) {
  final raw = base['endpointsJson'];
  if (raw == null || raw.trim().isEmpty) return [base];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return [base];
    final result = <Map<String, String>>[];
    for (final item in decoded.whereType<Map>()) {
      final host = item['host']?.toString().trim() ?? '';
      if (host.isEmpty) continue;
      final port = item['port']?.toString().trim() ?? '';
      final next = Map<String, String>.of(base)
        ..['host'] = host
        ..['server'] = host;
      if (host.startsWith('http://') || host.startsWith('https://')) {
        next['baseUrl'] = host;
      }
      if (port.isNotEmpty) {
        next['port'] = port;
      }
      result.add(next);
    }
    return result.isEmpty ? [base] : result;
  } catch (_) {
    return [base];
  }
}

String? _proxy(CloudPluginDefinition plugin, [Map<String, String>? variables]) {
  final variableProxy = variables?['proxy'];
  if (variableProxy != null && variableProxy.isNotEmpty) return variableProxy;
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

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
