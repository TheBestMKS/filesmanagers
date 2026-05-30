import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

import '../storage/app_paths.dart';

class CloudPluginDefinition {
  const CloudPluginDefinition({
    required this.id,
    required this.name,
    required this.rootPath,
    required this.manifestPath,
    this.description,
    this.authType,
    this.listRequest,
    this.infoRequest,
    this.streamRequest,
  });

  final String id;
  final String name;
  final String rootPath;
  final String manifestPath;
  final String? description;
  final String? authType;
  final Map<String, Object?>? listRequest;
  final Map<String, Object?>? infoRequest;
  final Map<String, Object?>? streamRequest;

  factory CloudPluginDefinition.fromJson(
    Map<String, Object?> json, {
    required String rootPath,
    required String manifestPath,
  }) {
    Map<String, Object?>? mapField(String key) {
      final value = json[key];
      if (value is Map) {
        return value.map((k, v) => MapEntry(k.toString(), v));
      }
      return null;
    }

    return CloudPluginDefinition(
      id: json['id'] as String? ?? basename(rootPath),
      name: json['name'] as String? ?? basename(rootPath),
      description: json['description'] as String?,
      authType: json['authType'] as String?,
      rootPath: rootPath,
      manifestPath: manifestPath,
      listRequest: mapField('listFiles'),
      infoRequest: mapField('fileInfo'),
      streamRequest: mapField('fileStream'),
    );
  }
}

class CloudPluginRegistry {
  Future<List<CloudPluginDefinition>> loadPlugins() async {
    final pluginsDir = await AppPaths.pluginsDirectory();
    await _ensureSamplePlugin(pluginsDir);
    await _ensureWebDavTemplates(pluginsDir);
    final plugins = <CloudPluginDefinition>[];
    await for (final entity in pluginsDir.list(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }
      final manifest =
          File('${entity.path}${Platform.pathSeparator}plugin.json');
      if (!await manifest.exists()) {
        continue;
      }
      try {
        final decoded = jsonDecode(await manifest.readAsString());
        if (decoded is Map<String, Object?>) {
          plugins.add(
            CloudPluginDefinition.fromJson(
              decoded,
              rootPath: entity.path,
              manifestPath: manifest.path,
            ),
          );
        }
      } catch (_) {
        // Broken plugins stay isolated from the explorer.
      }
    }
    plugins.sort((a, b) => a.name.compareTo(b.name));
    return plugins;
  }

  Future<Directory> installPluginZip(String zipPath) async {
    final source = File(zipPath);
    if (!await source.exists()) {
      throw FileSystemException('Plugin ZIP not found', zipPath);
    }
    final archive = ZipDecoder().decodeBytes(await source.readAsBytes());
    final rootName = basename(zipPath).replaceFirst(
      RegExp(r'\.zip$', caseSensitive: false),
      '',
    );
    final pluginsDir = await AppPaths.pluginsDirectory();
    final target =
        Directory('${pluginsDir.path}${Platform.pathSeparator}$rootName');
    await target.create(recursive: true);
    for (final item in archive.files) {
      final safeName = item.name
          .replaceAll('\\', '/')
          .split('/')
          .where((part) => part.isNotEmpty && part != '..')
          .join(Platform.pathSeparator);
      if (safeName.isEmpty) continue;
      final path = '${target.path}${Platform.pathSeparator}$safeName';
      if (item.isFile) {
        final file = File(path);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(item.content as List<int>, flush: true);
      } else {
        await Directory(path).create(recursive: true);
      }
    }
    final manifest = File('${target.path}${Platform.pathSeparator}plugin.json');
    if (!await manifest.exists()) {
      throw const FormatException('plugin.json not found in plugin ZIP.');
    }
    return target;
  }

  Future<void> _ensureSamplePlugin(Directory pluginsDir) async {
    final sampleDir = Directory(
        '${pluginsDir.path}${Platform.pathSeparator}sample_cloud_plugin');
    final manifest =
        File('${sampleDir.path}${Platform.pathSeparator}plugin.json');
    if (await manifest.exists()) {
      return;
    }
    await sampleDir.create(recursive: true);
    await manifest.writeAsString(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'id': 'sample-cloud',
      'name': 'Sample Cloud Provider',
      'description': 'Template for JSON-defined cloud storage adapters.',
      'authType': 'oauth-html-return',
      'auth': <String, Object?>{
        'authorizeUrl': 'https://example.invalid/oauth/authorize',
        'redirectUri': 'securevault://oauth-return',
        'tokenRequest': <String, Object?>{
          'method': 'POST',
          'url': 'https://example.invalid/oauth/token',
        },
      },
      'listFiles': <String, Object?>{
        'method': 'GET',
        'url': 'https://example.invalid/api/files',
        'pathParameter': 'path',
        'foldersJsonPath': r'$.folders',
        'filesJsonPath': r'$.files',
      },
      'fileInfo': <String, Object?>{
        'method': 'GET',
        'url': 'https://example.invalid/api/file/info',
        'idParameter': 'id',
      },
      'fileStream': <String, Object?>{
        'method': 'GET',
        'url': 'https://example.invalid/api/file/download',
        'idParameter': 'id',
      },
    }));
  }

  Future<void> _ensureWebDavTemplates(Directory pluginsDir) async {
    await _writeTemplate(
      pluginsDir,
      folder: 'yandex_disk_webdav',
      manifest: <String, Object?>{
        'id': 'yandex-disk-webdav',
        'name': 'Яндекс.Диск WebDAV',
        'description': 'Template adapter for Yandex Disk through WebDAV.',
        'authType': 'password-or-app-password',
        'variables': <String, Object?>{
          'username': <String, Object?>{'label': 'Yandex login'},
          'password': <String, Object?>{
            'label': 'App password or WebDAV password',
            'secret': true
          },
        },
        'capabilities': ['listFiles', 'fileInfo', 'fileStream', 'freeSpace'],
        'listFiles': <String, Object?>{
          'method': 'PROPFIND',
          'url': 'https://webdav.yandex.ru/{path}',
          'headers': {'Depth': '1'},
          'auth': 'basic',
          'xmlResponse': true,
        },
        'fileInfo': <String, Object?>{
          'method': 'PROPFIND',
          'url': 'https://webdav.yandex.ru/{path}',
          'headers': {'Depth': '0'},
          'auth': 'basic',
          'xmlResponse': true,
        },
        'fileStream': <String, Object?>{
          'method': 'GET',
          'url': 'https://webdav.yandex.ru/{path}',
          'auth': 'basic',
        },
        'upload': <String, Object?>{
          'method': 'PUT',
          'url': 'https://webdav.yandex.ru/{path}',
          'auth': 'basic',
        },
      },
    );
    await _writeTemplate(
      pluginsDir,
      folder: 'nextcloud_webdav',
      manifest: <String, Object?>{
        'id': 'nextcloud-webdav',
        'name': 'Nextcloud WebDAV',
        'description':
            'Template adapter for Nextcloud/ownCloud compatible WebDAV.',
        'authType': 'password-or-app-password',
        'variables': <String, Object?>{
          'baseUrl': <String, Object?>{
            'label': 'Server URL, e.g. https://cloud.example.com'
          },
          'username': <String, Object?>{'label': 'Username'},
          'password': <String, Object?>{
            'label': 'App password',
            'secret': true
          },
        },
        'capabilities': ['listFiles', 'fileInfo', 'fileStream', 'freeSpace'],
        'listFiles': <String, Object?>{
          'method': 'PROPFIND',
          'url': '{baseUrl}/remote.php/dav/files/{username}/{path}',
          'headers': {'Depth': '1'},
          'auth': 'basic',
          'xmlResponse': true,
        },
        'fileInfo': <String, Object?>{
          'method': 'PROPFIND',
          'url': '{baseUrl}/remote.php/dav/files/{username}/{path}',
          'headers': {'Depth': '0'},
          'auth': 'basic',
          'xmlResponse': true,
        },
        'fileStream': <String, Object?>{
          'method': 'GET',
          'url': '{baseUrl}/remote.php/dav/files/{username}/{path}',
          'auth': 'basic',
        },
        'upload': <String, Object?>{
          'method': 'PUT',
          'url': '{baseUrl}/remote.php/dav/files/{username}/{path}',
          'auth': 'basic',
        },
      },
    );
  }

  Future<void> _writeTemplate(
    Directory pluginsDir, {
    required String folder,
    required Map<String, Object?> manifest,
  }) async {
    final dir = Directory('${pluginsDir.path}${Platform.pathSeparator}$folder');
    final file = File('${dir.path}${Platform.pathSeparator}plugin.json');
    if (await file.exists()) return;
    await dir.create(recursive: true);
    await file
        .writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));
  }
}

String basename(String path) => path.split(Platform.pathSeparator).last;
