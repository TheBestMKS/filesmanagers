import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';

import '../storage/app_paths.dart';
import 'connection_profile.dart';

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
    this.profileId,
    this.sourcePluginId,
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
  final String? profileId;
  final String? sourcePluginId;
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

  CloudPluginDefinition withConnectionProfile(
    PluginConnectionProfile profile,
  ) {
    final mergedVariables = <String, Object?>{
      ...?variables,
      ...profile.variables,
      if (profile.endpoints.isNotEmpty)
        'endpointsJson':
            jsonEncode(profile.endpoints.map((item) => item.toJson()).toList()),
      if (profile.endpoints.isNotEmpty)
        ...profile.endpoints.first.toVariables(),
    };
    return CloudPluginDefinition(
      id: profile.runtimePluginId,
      name: profile.name,
      rootPath: rootPath,
      manifestPath: manifestPath,
      version: version,
      pluginType: pluginType,
      description: description,
      authType: authType,
      updateUrl: updateUrl,
      repositoryUrl: repositoryUrl,
      capabilities: capabilities,
      variables: mergedVariables,
      components: components,
      platformComponents: platformComponents,
      proxy: proxy,
      mediaCatalog: mediaCatalog,
      profileId: profile.id,
      sourcePluginId: id,
      listRequest: listRequest,
      infoRequest: infoRequest,
      streamRequest: streamRequest,
      raw: <String, Object?>{
        ...raw,
        'connectionProfile': profile.toJson(),
        'sourcePluginId': id,
      },
    );
  }
}

class CloudPluginRegistry {
  Future<List<CloudPluginDefinition>> loadPlugins() async {
    final pluginsDir = await AppPaths.pluginsDirectory();
    final deleted = await _deletedPluginIds(pluginsDir);
    await _removeObsoleteSamplePlugin(pluginsDir);
    await _ensureWebDavTemplates(pluginsDir, deleted);
    await _ensureRaidTemplates(pluginsDir, deleted);
    await _ensureExperiencePlugins(pluginsDir, deleted);
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

  Future<void> deletePlugin(String pluginId) async {
    final pluginsDir = await AppPaths.pluginsDirectory();
    final plugins = await loadPlugins();
    final plugin = plugins.firstWhere(
      (item) => item.id == pluginId,
      orElse: () => throw FormatException('Plugin not found: $pluginId'),
    );
    final deleted = await _deletedPluginIds(pluginsDir);
    deleted.add(pluginId);
    await _deletedPluginFile(pluginsDir).writeAsString(
      const JsonEncoder.withIndent('  ').convert(deleted.toList()..sort()),
      flush: true,
    );
    final root = Directory(plugin.rootPath);
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  }

  Future<Set<String>> _deletedPluginIds(Directory pluginsDir) async {
    final file = _deletedPluginFile(pluginsDir);
    if (!await file.exists()) return <String>{};
    try {
      final decoded = jsonDecode(await file.readAsString());
      return decoded is List
          ? decoded.map((item) => item.toString()).toSet()
          : <String>{};
    } catch (_) {
      return <String>{};
    }
  }

  File _deletedPluginFile(Directory pluginsDir) =>
      File('${pluginsDir.path}${Platform.pathSeparator}.deleted_plugins.json');

  Future<void> _removeObsoleteSamplePlugin(Directory pluginsDir) async {
    final sampleDir = Directory(
        '${pluginsDir.path}${Platform.pathSeparator}sample_cloud_plugin');
    final manifest =
        File('${sampleDir.path}${Platform.pathSeparator}plugin.json');
    if (!await manifest.exists()) return;
    try {
      final decoded = jsonDecode(await manifest.readAsString());
      if (decoded is Map && decoded['id'] == 'sample-cloud') {
        await sampleDir.delete(recursive: true);
      }
    } catch (_) {
      // Broken obsolete sample plugins should not block real plugin loading.
    }
  }

  Future<void> _ensureWebDavTemplates(
    Directory pluginsDir,
    Set<String> deleted,
  ) async {
    await _writeTemplate(
      pluginsDir,
      deleted: deleted,
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
      deleted: deleted,
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
      deleted: deleted,
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
      deleted: deleted,
      folder: 'sftp_resource',
      manifest: <String, Object?>{
        'id': 'sftp-resource',
        'name': 'SFTP/SSH resource',
        'version': '1.0.0',
        'pluginType': 'network-storage',
        'description':
            'Embedded SFTP/SSH adapter powered by dartssh2. Supports password, keyboard-interactive password prompts, and PEM private keys without external ssh.',
        'authType': 'ssh-password-or-key',
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
          'passphrase': <String, Object?>{
            'label': 'Private key passphrase',
            'secret': true,
            'env': 'SECUREVAULT_SFTP_RESOURCE_PASSPHRASE',
          },
          'password': <String, Object?>{
            'label': 'Password',
            'secret': true,
            'env': 'SECUREVAULT_SFTP_RESOURCE_PASSWORD',
          },
          'timeoutSeconds': <String, Object?>{
            'label': 'Connection timeout, seconds',
            'default': '30',
            'env': 'SECUREVAULT_SFTP_RESOURCE_TIMEOUTSECONDS',
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
      deleted: deleted,
      folder: 'smb_resource',
      manifest: <String, Object?>{
        'id': 'smb-resource',
        'name': 'SMB resource',
        'version': '1.0.0',
        'pluginType': 'network-storage',
        'description':
            'Embedded SMB2/3 adapter powered by dart_smb2/libsmb2. Use host + share name, smb://server/share, or //server/share without external smbclient.',
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
            'label': 'SMB host',
            'env': 'SECUREVAULT_SMB_RESOURCE_HOST',
          },
          'share': <String, Object?>{
            'label': 'Share name or URL, e.g. Documents or //server/share',
            'env': 'SECUREVAULT_SMB_RESOURCE_SHARE',
          },
          'domain': <String, Object?>{
            'label': 'Domain / workgroup',
            'env': 'SECUREVAULT_SMB_RESOURCE_DOMAIN',
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
          'version': <String, Object?>{
            'label': 'SMB dialect: any, any2, any3, 2.1, 3.0, 3.1.1',
            'default': 'any',
            'env': 'SECUREVAULT_SMB_RESOURCE_VERSION',
          },
          'workers': <String, Object?>{
            'label': 'Parallel SMB workers',
            'default': '4',
            'env': 'SECUREVAULT_SMB_RESOURCE_WORKERS',
          },
          'timeoutSeconds': <String, Object?>{
            'label': 'Connection timeout, seconds',
            'default': '30',
            'env': 'SECUREVAULT_SMB_RESOURCE_TIMEOUTSECONDS',
          },
          'signing': <String, Object?>{
            'label': 'Require SMB signing',
            'default': 'false',
            'env': 'SECUREVAULT_SMB_RESOURCE_SIGNING',
          },
          'seal': <String, Object?>{
            'label': 'Require SMB encryption',
            'default': 'false',
            'env': 'SECUREVAULT_SMB_RESOURCE_SEAL',
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

  Future<void> _ensureRaidTemplates(
    Directory pluginsDir,
    Set<String> deleted,
  ) async {
    Future<void> write({
      required String folder,
      required String id,
      required String name,
      required String executor,
      required String description,
    }) {
      return _writeTemplate(
        pluginsDir,
        deleted: deleted,
        folder: folder,
        manifest: <String, Object?>{
          'id': id,
          'name': name,
          'version': '1.0.0',
          'pluginType': 'virtual-storage',
          'description': description,
          'authType': 'none',
          'capabilities': [
            'listFiles',
            'fileInfo',
            'fileStream',
            'upload',
            'mkdir',
            'delete',
            'compositeLocation'
          ],
          'variables': <String, Object?>{
            'members': <String, Object?>{
              'label':
                  'Member location runtime plugin ids, selected by SecureVault profile dialog',
              'default': '',
            },
          },
          'components': <String, Object?>{'executor': executor},
          'platformComponents': <String, Object?>{
            'windows-x64': <String, Object?>{'executor': executor},
            'linux-x64': <String, Object?>{'executor': executor},
            'android-arm64': <String, Object?>{'executor': executor},
            'fallback': <String, Object?>{'executor': executor},
          },
        },
      );
    }

    await write(
      folder: 'raid0_combined_location',
      id: 'raid0-combined-location',
      name: 'RAID0 combined location',
      executor: 'raid0',
      description:
          'Combines several configured SecureVault locations into one expandable virtual location. Files are placed on one member by free-space hint or stable path distribution.',
    );
    await write(
      folder: 'raid1_mirror_location',
      id: 'raid1-mirror-location',
      name: 'RAID1 mirror location',
      executor: 'raid1',
      description:
          'Mirrors writes and folder creation to all selected SecureVault locations and reads from the first available copy.',
    );
  }

  Future<void> _ensureExperiencePlugins(
    Directory pluginsDir,
    Set<String> deleted,
  ) async {
    final torrentDir = await _writeTemplate(
      pluginsDir,
      deleted: deleted,
      folder: 'securevault_torrent',
      manifest: <String, Object?>{
        'id': 'securevault-torrent',
        'name': 'SecureVault Torrent',
        'version': '1.2.0',
        'pluginType': 'media-extension',
        'description':
            'Adds the Torrent section, .torrent file handling, folder-like torrent browsing and audio/video streaming.',
        'authType': 'none',
        'capabilities': [
          'section',
          'fileHandler',
          'torrentBrowse',
          'torrentStreaming',
          'mediaPlayback'
        ],
        'settings': <String, Object?>{
          'createTorrentSection': <String, Object?>{
            'label': 'Create Torrent section',
            'default': 'true',
          },
          'handleTorrentFiles': <String, Object?>{
            'label': 'Open .torrent files as folders',
            'default': 'true',
          },
        },
        'components': <String, Object?>{
          'executor': 'torrent',
          'engine': 'plugin-bundled',
        },
        'platformComponents': <String, Object?>{
          'windows-x64': <String, Object?>{
            'executor': 'torrent',
            'engine': 'components/aria2/windows-x64/aria2c.exe',
          },
          'linux-x64': <String, Object?>{
            'executor': 'torrent',
            'engine': 'components/aria2/linux-x64/aria2c',
          },
          'android-arm64': <String, Object?>{
            'executor': 'torrent',
            'engine': 'components/aria2/android-arm64/aria2c',
          },
          'fallback': <String, Object?>{'executor': 'torrent'},
        },
        'sections': [
          <String, Object?>{
            'id': 'torrent',
            'title': 'Torrent',
            'titleKey': 'nav.torrent',
            'kind': 'torrent',
            'icon': 'hub',
            'executor': 'torrent',
          }
        ],
        'fileHandlers': [
          <String, Object?>{
            'extensions': ['.torrent'],
            'mode': 'torrent-folder',
            'sectionId': 'torrent',
          }
        ],
      },
    );
    if (torrentDir != null) {
      await _ensureTorrentPluginPayload(torrentDir);
    }

    await _writeTemplate(
      pluginsDir,
      deleted: deleted,
      folder: 'hitmoz_music',
      manifest: <String, Object?>{
        'id': 'hitmoz-music',
        'name': 'Hitmoz',
        'version': '1.0.0',
        'pluginType': 'media-source',
        'description':
            'Parses a configured Hitmoz-compatible music site, adds the Hitmoz music section, supports search, streaming and user-requested download of direct audio links.',
        'authType': 'none',
        'capabilities': [
          'section',
          'musicSearch',
          'musicGenres',
          'musicPlaylists',
          'mediaStreaming',
          'mediaDownload'
        ],
        'settings': <String, Object?>{
          'baseUrl': <String, Object?>{
            'label': 'Hitmoz base URL',
            'default': 'https://eu.hitmoz.com/',
          },
        },
        'components': <String, Object?>{'executor': 'web-music-parser'},
        'platformComponents': <String, Object?>{
          'windows-x64': <String, Object?>{'executor': 'web-music-parser'},
          'linux-x64': <String, Object?>{'executor': 'web-music-parser'},
          'android-arm64': <String, Object?>{'executor': 'web-music-parser'},
          'fallback': <String, Object?>{'executor': 'web-music-parser'},
        },
        'sections': [
          <String, Object?>{
            'id': 'hitmoz',
            'title': 'Hitmoz',
            'kind': 'music',
            'icon': 'music_note',
            'executor': 'web-music-parser',
          }
        ],
        'mediaCatalog': <String, Object?>{
          'executor': 'web-music-parser',
          'sites': [
            <String, Object?>{
              'id': 'hitmoz',
              'title': 'Hitmoz',
              'baseUrl': 'https://eu.hitmoz.com/',
              'searchPath': '/search?q={query}',
              'parser': 'generic-audio-html',
            }
          ],
        },
      },
    );

    await _writeTemplate(
      pluginsDir,
      deleted: deleted,
      folder: 'rar_archive_support',
      manifest: <String, Object?>{
        'id': 'rar-archive-support',
        'name': 'RAR Archive Support',
        'version': '1.0.0',
        'pluginType': 'archive-extension',
        'description':
            'Adds RAR/CBR/REV archive browsing and extraction on Windows and Android using bundled Flutter/Dart archive engines.',
        'authType': 'none',
        'capabilities': [
          'fileHandler',
          'archiveBrowse',
          'archiveExtract',
          'previewProvider'
        ],
        'components': <String, Object?>{
          'executor': 'rar-archive',
          'windowsEngine': 'unrar-ffi',
          'androidEngine': 'rar-libarchive-ffi',
        },
        'platformComponents': <String, Object?>{
          'windows-x64': <String, Object?>{
            'executor': 'rar-archive',
            'engine': 'unrar-ffi',
          },
          'android-arm64': <String, Object?>{
            'executor': 'rar-archive',
            'engine': 'rar-libarchive-ffi',
          },
          'fallback': <String, Object?>{
            'executor': 'rar-archive',
            'engine': 'best-available',
          },
        },
        'fileHandlers': [
          <String, Object?>{
            'extensions': ['.rar', '.cbr', '.rev'],
            'mode': 'archive-folder',
          }
        ],
      },
    );

    await _writeTemplate(
      pluginsDir,
      deleted: deleted,
      folder: 'universal_web_music',
      manifest: <String, Object?>{
        'id': 'universal-web-music',
        'name': 'Universal Web Music Parser',
        'version': '1.0.0',
        'pluginType': 'media-source-manager',
        'description':
            'Adds a + button near Music. Users can register multiple music sites; each site becomes a removable streaming music section.',
        'authType': 'none',
        'capabilities': [
          'musicSourceProfiles',
          'sectionFactory',
          'musicSearch',
          'mediaStreaming',
          'mediaDownload'
        ],
        'settings': <String, Object?>{
          'sitesJson': <String, Object?>{
            'label': 'Registered music sites JSON',
            'default': '[]',
          },
        },
        'components': <String, Object?>{'executor': 'web-music-parser'},
        'platformComponents': <String, Object?>{
          'windows-x64': <String, Object?>{'executor': 'web-music-parser'},
          'linux-x64': <String, Object?>{'executor': 'web-music-parser'},
          'android-arm64': <String, Object?>{'executor': 'web-music-parser'},
          'fallback': <String, Object?>{'executor': 'web-music-parser'},
        },
        'mediaCatalog': <String, Object?>{
          'executor': 'web-music-parser',
          'userSites': true,
          'defaultSearchPath': '/search?q={query}',
        },
      },
    );
  }

  Future<Directory?> _writeTemplate(
    Directory pluginsDir, {
    required String folder,
    required Map<String, Object?> manifest,
    Set<String> deleted = const <String>{},
  }) async {
    final id = manifest['id']?.toString();
    if (id != null && deleted.contains(id)) return null;
    final dir = Directory('${pluginsDir.path}${Platform.pathSeparator}$folder');
    final file = File('${dir.path}${Platform.pathSeparator}plugin.json');
    if (await file.exists()) return dir;
    await dir.create(recursive: true);
    await file
        .writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));
    return dir;
  }

  Future<void> _ensureTorrentPluginPayload(Directory pluginDir) async {
    final target = File(
      '${pluginDir.path}${Platform.pathSeparator}components'
      '${Platform.pathSeparator}aria2${Platform.pathSeparator}windows-x64'
      '${Platform.pathSeparator}aria2c.exe',
    );
    if (await target.exists()) return;
    final candidates = <File>[
      File('windows${Platform.pathSeparator}runner'
          '${Platform.pathSeparator}resources${Platform.pathSeparator}aria2c.exe'),
      File('app${Platform.pathSeparator}flutter_shell'
          '${Platform.pathSeparator}windows${Platform.pathSeparator}runner'
          '${Platform.pathSeparator}resources${Platform.pathSeparator}aria2c.exe'),
    ];
    for (final source in candidates) {
      if (await source.exists()) {
        await target.parent.create(recursive: true);
        await source.copy(target.path);
        final sourceDir = source.parent;
        for (final license in [
          'aria2_COPYING.txt',
          'aria2_LICENSE.OpenSSL.txt'
        ]) {
          final licenseFile = File(
            '${sourceDir.path}${Platform.pathSeparator}$license',
          );
          if (await licenseFile.exists()) {
            await licenseFile.copy(
              '${target.parent.path}${Platform.pathSeparator}$license',
            );
          }
        }
        return;
      }
    }
  }
}

String basename(String path) => path.split(Platform.pathSeparator).last;
