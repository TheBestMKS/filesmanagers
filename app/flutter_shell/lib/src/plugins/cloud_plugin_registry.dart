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
    this.version = '1.0.0',
    this.pluginType = 'cloud-storage',
    this.description,
    this.authType,
    this.updateUrl,
    this.repositoryUrl,
    this.capabilities = const <String>[],
    this.variables,
    this.components,
    this.platformComponents,
    this.proxy,
    this.mediaCatalog,
    this.listRequest,
    this.infoRequest,
    this.streamRequest,
    this.raw = const <String, Object?>{},
  });

  final String id;
  final String name;
  final String rootPath;
  final String manifestPath;
  final String version;
  final String pluginType;
  final String? description;
  final String? authType;
  final String? updateUrl;
  final String? repositoryUrl;
  final List<String> capabilities;
  final Map<String, Object?>? variables;
  final Map<String, Object?>? components;
  final Map<String, Object?>? platformComponents;
  final Map<String, Object?>? proxy;
  final Map<String, Object?>? mediaCatalog;
  final Map<String, Object?>? listRequest;
  final Map<String, Object?>? infoRequest;
  final Map<String, Object?>? streamRequest;
  final Map<String, Object?> raw;

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

    List<String> listField(String key) {
      final value = json[key];
      return value is List
          ? value.map((item) => item.toString()).toList()
          : const <String>[];
    }

    return CloudPluginDefinition(
      id: json['id'] as String? ?? basename(rootPath),
      name: json['name'] as String? ?? basename(rootPath),
      version: json['version'] as String? ?? '1.0.0',
      pluginType: json['pluginType'] as String? ?? 'cloud-storage',
      description: json['description'] as String?,
      authType: json['authType'] as String?,
      updateUrl: json['updateUrl'] as String?,
      repositoryUrl: json['repositoryUrl'] as String?,
      capabilities: listField('capabilities'),
      variables: mapField('variables'),
      components: mapField('components'),
      platformComponents: mapField('platformComponents'),
      proxy: mapField('proxy'),
      mediaCatalog: mapField('mediaCatalog'),
      rootPath: rootPath,
      manifestPath: manifestPath,
      listRequest: mapField('listFiles'),
      infoRequest: mapField('fileInfo'),
      streamRequest: mapField('fileStream'),
      raw: json,
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

  Future<File> exportPluginZip(String pluginId, String targetPath) async {
    final plugins = await loadPlugins();
    final plugin = plugins.firstWhere(
      (item) => item.id == pluginId,
      orElse: () => throw FormatException('Plugin not found: $pluginId'),
    );
    final archive = Archive();
    final root = Directory(plugin.rootPath);
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = entity.path
          .substring(root.path.length)
          .replaceFirst(RegExp(r'^[\\/]+'), '')
          .replaceAll('\\', '/');
      if (relative.isEmpty) continue;
      archive.addFile(
        ArchiveFile(
            relative, await entity.length(), await entity.readAsBytes()),
      );
    }
    final target = File(targetPath);
    await target.parent.create(recursive: true);
    final bytes = ZipEncoder().encode(archive);
    await target.writeAsBytes(bytes, flush: true);
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
      'version': '1.0.0',
      'pluginType': 'cloud-storage',
      'description': 'Template for JSON-defined cloud storage adapters.',
      'repositoryUrl': 'https://example.invalid/securevault/sample-cloud.git',
      'updateUrl':
          'https://example.invalid/securevault/sample-cloud/plugin.json',
      'authType': 'oauth-html-return',
      'capabilities': [
        'listFiles',
        'fileInfo',
        'fileStream',
        'upload',
        'freeSpace',
        'checkUpdates'
      ],
      'proxy': <String, Object?>{
        'mode': 'inherit',
        'variables': ['HTTPS_PROXY', 'HTTP_PROXY']
      },
      'components': <String, Object?>{
        'executor': 'json-http',
        'htmlReturnPage': 'oauth_return.html'
      },
      'platformComponents': <String, Object?>{
        'windows-x64': <String, Object?>{
          'library': 'bin/windows-x64/cloud.dll'
        },
        'linux-x64': <String, Object?>{'library': 'bin/linux-x64/libcloud.so'},
        'android-arm64': <String, Object?>{
          'library': 'lib/arm64-v8a/libcloud.so'
        },
        'fallback': <String, Object?>{'executor': 'json-http'}
      },
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
      'mediaCatalog': <String, Object?>{
        'enabled': false,
        'search': <String, Object?>{
          'method': 'GET',
          'url': 'https://example.invalid/api/media/search',
          'queryParameter': 'q',
        },
        'sections': <Map<String, Object?>>[
          {'id': 'music', 'label': 'Music'},
          {'id': 'video', 'label': 'Video'},
        ],
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
        'version': '1.0.0',
        'pluginType': 'cloud-storage',
        'description': 'Template adapter for Yandex Disk through WebDAV.',
        'repositoryUrl': 'https://github.com/example/securevault-yandex-disk',
        'updateUrl':
            'https://raw.githubusercontent.com/example/securevault-yandex-disk/main/plugin.json',
        'authType': 'password-or-app-password',
        'variables': <String, Object?>{
          'username': <String, Object?>{
            'label': 'Yandex login',
            'env': 'SECUREVAULT_YANDEX_DISK_WEBDAV_USERNAME',
          },
          'password': <String, Object?>{
            'label': 'App password or WebDAV password',
            'secret': true,
            'env': 'SECUREVAULT_YANDEX_DISK_WEBDAV_PASSWORD',
          },
        },
        'capabilities': ['listFiles', 'fileInfo', 'fileStream', 'freeSpace'],
        'proxy': <String, Object?>{'mode': 'inherit'},
        'components': <String, Object?>{'executor': 'webdav-json'},
        'platformComponents': <String, Object?>{
          'windows-x64': <String, Object?>{'executor': 'webdav-json'},
          'linux-x64': <String, Object?>{'executor': 'webdav-json'},
          'android-arm64': <String, Object?>{'executor': 'webdav-json'},
          'fallback': <String, Object?>{'executor': 'webdav-json'},
        },
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
        'version': '1.0.0',
        'pluginType': 'cloud-storage',
        'description':
            'Template adapter for Nextcloud/ownCloud compatible WebDAV.',
        'repositoryUrl': 'https://github.com/example/securevault-nextcloud',
        'updateUrl':
            'https://raw.githubusercontent.com/example/securevault-nextcloud/main/plugin.json',
        'authType': 'password-or-app-password',
        'variables': <String, Object?>{
          'baseUrl': <String, Object?>{
            'label': 'Server URL, e.g. https://cloud.example.com',
            'env': 'SECUREVAULT_NEXTCLOUD_WEBDAV_BASEURL',
          },
          'username': <String, Object?>{
            'label': 'Username',
            'env': 'SECUREVAULT_NEXTCLOUD_WEBDAV_USERNAME',
          },
          'password': <String, Object?>{
            'label': 'App password',
            'secret': true,
            'env': 'SECUREVAULT_NEXTCLOUD_WEBDAV_PASSWORD',
          },
        },
        'capabilities': ['listFiles', 'fileInfo', 'fileStream', 'freeSpace'],
        'proxy': <String, Object?>{'mode': 'inherit'},
        'components': <String, Object?>{'executor': 'webdav-json'},
        'platformComponents': <String, Object?>{
          'windows-x64': <String, Object?>{'executor': 'webdav-json'},
          'linux-x64': <String, Object?>{'executor': 'webdav-json'},
          'android-arm64': <String, Object?>{'executor': 'webdav-json'},
          'fallback': <String, Object?>{'executor': 'webdav-json'},
        },
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
    await _writeTemplate(
      pluginsDir,
      folder: 'ftp_resource',
      manifest: <String, Object?>{
        'id': 'ftp-resource',
        'name': 'FTP resource',
        'version': '1.0.0',
        'pluginType': 'network-storage',
        'description':
            'Native Dart FTP adapter with passive mode LIST/MLSD, RETR, STOR, MKD and delete.',
        'authType': 'password',
        'capabilities': [
          'listFiles',
          'fileInfo',
          'fileStream',
          'upload',
          'mkdir',
          'delete'
        ],
        'variables': <String, Object?>{
          'host': <String, Object?>{
            'label': 'FTP host',
            'env': 'SECUREVAULT_FTP_RESOURCE_HOST',
          },
          'port': <String, Object?>{
            'label': 'FTP port',
            'default': '21',
            'env': 'SECUREVAULT_FTP_RESOURCE_PORT',
          },
          'username': <String, Object?>{
            'label': 'Username',
            'default': 'anonymous',
            'env': 'SECUREVAULT_FTP_RESOURCE_USERNAME',
          },
          'password': <String, Object?>{
            'label': 'Password',
            'secret': true,
            'default': 'anonymous@',
            'env': 'SECUREVAULT_FTP_RESOURCE_PASSWORD',
          },
        },
        'components': <String, Object?>{'executor': 'ftp'},
        'platformComponents': <String, Object?>{
          'windows-x64': <String, Object?>{'executor': 'ftp'},
          'linux-x64': <String, Object?>{'executor': 'ftp'},
          'android-arm64': <String, Object?>{'executor': 'ftp'},
          'fallback': <String, Object?>{'executor': 'ftp'},
        },
      },
    );
    await _writeTemplate(
      pluginsDir,
      folder: 'sftp_resource',
      manifest: <String, Object?>{
        'id': 'sftp-resource',
        'name': 'SFTP/SSH resource',
        'version': '1.0.0',
        'pluginType': 'network-storage',
        'description':
            'SFTP-compatible SSH adapter through the system ssh client and key/agent authentication.',
        'authType': 'ssh-key-or-agent',
        'capabilities': [
          'listFiles',
          'fileInfo',
          'fileStream',
          'upload',
          'mkdir',
          'delete'
        ],
        'variables': <String, Object?>{
          'host': <String, Object?>{
            'label': 'SSH host',
            'env': 'SECUREVAULT_SFTP_RESOURCE_HOST',
          },
          'port': <String, Object?>{
            'label': 'SSH port',
            'default': '22',
            'env': 'SECUREVAULT_SFTP_RESOURCE_PORT',
          },
          'username': <String, Object?>{
            'label': 'Username',
            'env': 'SECUREVAULT_SFTP_RESOURCE_USERNAME',
          },
          'identityFile': <String, Object?>{
            'label': 'Private key path',
            'env': 'SECUREVAULT_SFTP_RESOURCE_IDENTITYFILE',
          },
        },
        'components': <String, Object?>{'executor': 'sftp'},
        'platformComponents': <String, Object?>{
          'windows-x64': <String, Object?>{'executor': 'sftp'},
          'linux-x64': <String, Object?>{'executor': 'sftp'},
          'android-arm64': <String, Object?>{'executor': 'sftp'},
          'fallback': <String, Object?>{'executor': 'sftp'},
        },
      },
    );
    await _writeTemplate(
      pluginsDir,
      folder: 'smb_resource',
      manifest: <String, Object?>{
        'id': 'smb-resource',
        'name': 'SMB resource',
        'version': '1.0.0',
        'pluginType': 'network-storage',
        'description':
            'SMB adapter through smbclient. Use //server/share as the share variable.',
        'authType': 'password',
        'capabilities': [
          'listFiles',
          'fileInfo',
          'fileStream',
          'upload',
          'mkdir',
          'delete'
        ],
        'variables': <String, Object?>{
          'share': <String, Object?>{
            'label': 'Share, e.g. //server/share',
            'env': 'SECUREVAULT_SMB_RESOURCE_SHARE',
          },
          'username': <String, Object?>{
            'label': 'Username',
            'env': 'SECUREVAULT_SMB_RESOURCE_USERNAME',
          },
          'password': <String, Object?>{
            'label': 'Password',
            'secret': true,
            'env': 'SECUREVAULT_SMB_RESOURCE_PASSWORD',
          },
        },
        'components': <String, Object?>{'executor': 'smb'},
        'platformComponents': <String, Object?>{
          'windows-x64': <String, Object?>{'executor': 'smb'},
          'linux-x64': <String, Object?>{'executor': 'smb'},
          'android-arm64': <String, Object?>{'executor': 'smb'},
          'fallback': <String, Object?>{'executor': 'smb'},
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
