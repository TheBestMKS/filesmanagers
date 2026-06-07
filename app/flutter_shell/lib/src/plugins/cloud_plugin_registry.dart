import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';

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
    deleted.add('zvooq-music');
    await _removeObsoleteSamplePlugin(pluginsDir);
    await _ensureWebDavTemplates(pluginsDir, deleted);
    await _ensureRaidTemplates(pluginsDir, deleted);
    await _ensureExperiencePlugins(pluginsDir, deleted);
    await _ensureUtilityPlugins(pluginsDir, deleted);
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
          if (decoded['id'] == 'zvooq-music') {
            continue;
          }
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
            'default': 'https://eu.hitmoz.com/songs/top-today',
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
              'baseUrl': 'https://eu.hitmoz.com/songs/top-today',
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
      folder: 'zvooq_music',
      manifest: <String, Object?>{
        'id': 'zvooq-music',
        'name': 'Zvooq / i.zvooq.net',
        'version': '1.0.0',
        'pluginType': 'media-source',
        'description':
            'Parses i.zvooq.net-compatible online music pages, adds the Zvooq section, supports search, streaming and user-requested downloads through the universal HTML audio parser.',
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
            'label': 'Zvooq base URL',
            'default': 'https://i.zvooq.net/',
          },
        },
        'components': <String, Object?>{'executor': 'web-music-parser'},
        'platformComponents': <String, Object?>{
          'windows-x64': <String, Object?>{'executor': 'web-music-parser'},
          'windows-arm64': <String, Object?>{'executor': 'web-music-parser'},
          'android-arm': <String, Object?>{'executor': 'web-music-parser'},
          'android-arm64': <String, Object?>{'executor': 'web-music-parser'},
          'android-x64': <String, Object?>{'executor': 'web-music-parser'},
          'fallback': <String, Object?>{'executor': 'web-music-parser'},
        },
        'sections': [
          <String, Object?>{
            'id': 'zvooq',
            'title': 'Zvooq',
            'kind': 'music',
            'icon': 'library_music',
            'executor': 'web-music-parser',
          }
        ],
        'mediaCatalog': <String, Object?>{
          'executor': 'web-music-parser',
          'sites': [
            <String, Object?>{
              'id': 'zvooq',
              'title': 'Zvooq',
              'baseUrl': 'https://i.zvooq.net/',
              'searchPath': '/search?q={query}',
              'parser': 'generic-audio-html',
            }
          ],
        },
      },
    );

    final rarDir = await _writeTemplate(
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
    if (rarDir != null) {
      await _ensureRarPluginPayload(rarDir);
    }

    final swfDir = await _writeTemplate(
      pluginsDir,
      deleted: deleted,
      folder: 'swf_ruffle_player',
      manifest: <String, Object?>{
        'id': 'swf-ruffle-player',
        'name': 'Ruffle SWF Player',
        'version': '1.0.0',
        'pluginType': 'viewer-extension',
        'description':
            'Adds interactive SWF/Flash opening through the bundled Ruffle web runtime served from SecureVault memory cache on Windows and Android.',
        'authType': 'none',
        'capabilities': [
          'fileHandler',
          'previewProvider',
          'interactiveViewer',
          'contextMenuActions'
        ],
        'components': <String, Object?>{
          'executor': 'swf-ruffle',
          'runtime': 'components/ruffle',
        },
        'platformComponents': <String, Object?>{
          'windows-x64': <String, Object?>{
            'executor': 'swf-ruffle',
            'runtime': 'components/ruffle',
          },
          'android-arm64': <String, Object?>{
            'executor': 'swf-ruffle',
            'runtime': 'components/ruffle',
          },
          'fallback': <String, Object?>{
            'executor': 'swf-ruffle',
            'runtime': 'components/ruffle',
          },
        },
        'fileHandlers': [
          <String, Object?>{
            'extensions': ['.swf'],
            'mode': 'interactive-preview',
          }
        ],
      },
    );
    if (swfDir != null) {
      await _ensureSwfRufflePayload(swfDir);
    }

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

  Future<void> _ensureUtilityPlugins(
    Directory pluginsDir,
    Set<String> deleted,
  ) async {
    final ocrDir = await _writeTemplate(
      pluginsDir,
      deleted: deleted,
      folder: 'tesseract_ocr_search',
      manifest: <String, Object?>{
        'id': 'tesseract-ocr',
        'name': 'Tesseract OCR Search',
        'version': '1.2.0',
        'pluginType': 'content-search-extension',
        'description':
            'Adds OCR-assisted content search and context-menu text extraction for images and PDFs. Android uses bundled flutter_tesseract_ocr with rus+eng tessdata; Windows uses the bundled Tesseract CLI runtime from plugin components and falls back to system Tesseract if needed.',
        'authType': 'none',
        'capabilities': [
          'contentSearch',
          'ocr',
          'pdfImageSearch',
          'contextMenuActions'
        ],
        'settings': <String, Object?>{
          'languages': <String, Object?>{
            'label': 'OCR languages',
            'default': 'rus+eng',
          },
          'useSystemTesseract': <String, Object?>{
            'label': 'Use system tesseract if bundled component is absent',
            'default': 'true',
          },
        },
        'components': <String, Object?>{
          'executor': 'tesseract-ocr',
          'androidEngine': 'flutter_tesseract_ocr',
          'desktopEngine': 'tesseract-cli',
          'tessdata': 'assets/tessdata',
        },
        'platformComponents': <String, Object?>{
          'windows-x64': <String, Object?>{
            'executor': 'tesseract-ocr',
            'binary': 'components/tesseract/windows-x64/tesseract.exe',
          },
          'windows-arm64': <String, Object?>{
            'executor': 'tesseract-ocr',
            'binary': 'components/tesseract/windows-arm64/tesseract.exe',
          },
          'linux-x64': <String, Object?>{
            'executor': 'tesseract-ocr',
            'binary': 'components/tesseract/linux-x64/tesseract',
          },
          'android-arm': <String, Object?>{
            'executor': 'tesseract-ocr',
            'engine': 'flutter_tesseract_ocr',
            'tessdataAssets': 'assets/tessdata',
          },
          'android-arm64': <String, Object?>{
            'executor': 'tesseract-ocr',
            'engine': 'flutter_tesseract_ocr',
            'tessdataAssets': 'assets/tessdata',
          },
          'android-x64': <String, Object?>{
            'executor': 'tesseract-ocr',
            'engine': 'flutter_tesseract_ocr',
            'tessdataAssets': 'assets/tessdata',
          },
          'fallback': <String, Object?>{'executor': 'tesseract-ocr'},
        },
      },
    );
    if (ocrDir != null) {
      await _ensureTesseractPluginPayload(ocrDir);
    }

    await _writeTemplate(
      pluginsDir,
      deleted: deleted,
      folder: 'veracrypt_container_support',
      manifest: <String, Object?>{
        'id': 'veracrypt-container-support',
        'name': 'TrueCrypt / VeraCrypt Containers',
        'version': '1.0.0',
        'pluginType': 'container-extension',
        'description':
            'Creates, recognizes and mounts VeraCrypt/TrueCrypt containers through installed system drivers or bundled platform CLI components.',
        'authType': 'password',
        'capabilities': [
          'containerCreate',
          'containerMount',
          'containerDismount',
          'fileHandler'
        ],
        'settings': <String, Object?>{
          'veracryptCommand': <String, Object?>{
            'label': 'VeraCrypt command',
            'default': 'veracrypt',
          },
          'defaultFilesystem': <String, Object?>{
            'label': 'Default filesystem',
            'default': 'exFAT',
          },
        },
        'components': <String, Object?>{'executor': 'veracrypt-cli'},
        'platformComponents': <String, Object?>{
          'windows-x64': <String, Object?>{
            'executor': 'veracrypt-cli',
            'binary': 'components/veracrypt/windows-x64/VeraCrypt.exe',
          },
          'linux-x64': <String, Object?>{
            'executor': 'veracrypt-cli',
            'binary': 'components/veracrypt/linux-x64/veracrypt',
          },
          'fallback': <String, Object?>{'executor': 'veracrypt-cli'},
        },
        'fileHandlers': [
          <String, Object?>{
            'extensions': ['.hc', '.tc', '.vc'],
            'mode': 'encrypted-container',
          }
        ],
      },
    );

    await _writeTemplate(
      pluginsDir,
      deleted: deleted,
      folder: 'syntax_highlight_code',
      manifest: <String, Object?>{
        'id': 'syntax-highlight-code',
        'name': 'Code Syntax Highlight',
        'version': '1.0.0',
        'pluginType': 'preview-extension',
        'description':
            'Automatically detects C/C++, C#, Python, Kotlin, CMD, PowerShell, Dart and common markup/script files and colors source text in the built-in viewer/editor.',
        'authType': 'none',
        'capabilities': [
          'previewEnhancer',
          'syntaxHighlight',
          'textEditorEnhancer',
          'autoLanguageDetection'
        ],
        'components': <String, Object?>{
          'executor': 'builtin-dart-syntax-highlighter',
        },
        'platformComponents': <String, Object?>{
          'windows-x64': <String, Object?>{
            'executor': 'builtin-dart-syntax-highlighter',
          },
          'windows-arm64': <String, Object?>{
            'executor': 'builtin-dart-syntax-highlighter',
          },
          'android-arm': <String, Object?>{
            'executor': 'builtin-dart-syntax-highlighter',
          },
          'android-arm64': <String, Object?>{
            'executor': 'builtin-dart-syntax-highlighter',
          },
          'android-x64': <String, Object?>{
            'executor': 'builtin-dart-syntax-highlighter',
          },
          'fallback': <String, Object?>{
            'executor': 'builtin-dart-syntax-highlighter',
          },
        },
        'fileHandlers': [
          <String, Object?>{
            'extensions': [
              '.c',
              '.cc',
              '.cpp',
              '.cxx',
              '.h',
              '.hpp',
              '.cs',
              '.py',
              '.pyw',
              '.kt',
              '.kts',
              '.cmd',
              '.bat',
              '.ps1',
              '.psm1',
              '.psd1',
              '.dart',
              '.js',
              '.ts',
              '.json',
              '.yaml',
              '.yml',
              '.xml',
              '.html',
              '.htm'
            ],
            'mode': 'syntax-highlight',
          }
        ],
      },
    );

    await _writeTemplate(
      pluginsDir,
      deleted: deleted,
      folder: 'yt_dlp_downloader',
      manifest: <String, Object?>{
        'id': 'yt-dlp-downloader',
        'name': 'yt-dlp URL Downloader',
        'version': '1.0.0',
        'pluginType': 'download-extension',
        'description':
            'Adds a context-menu action to download media by URL through yt-dlp with configurable quality, thread count, self-update and SecureVault background progress reporting.',
        'authType': 'none',
        'repositoryUrl': 'https://github.com/yt-dlp/yt-dlp',
        'updateUrl':
            'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe',
        'capabilities': [
          'contextMenuActions',
          'urlDownload',
          'mediaDownload',
          'backgroundProgress',
          'selfUpdate'
        ],
        'settings': <String, Object?>{
          'videoQuality': <String, Object?>{
            'label': 'Preferred video quality',
            'default': 'best',
          },
          'audioQuality': <String, Object?>{
            'label': 'Preferred audio quality',
            'default': 'best',
          },
          'threads': <String, Object?>{
            'label': 'Download threads',
            'default': '4',
          },
        },
        'contextMenuActions': [
          <String, Object?>{
            'id': 'download-url',
            'titleKey': 'plugin.ytdlp.download.url',
            'target': 'folder',
          }
        ],
        'components': <String, Object?>{
          'executor': 'yt-dlp',
          'engine': 'process',
        },
        'platformComponents': <String, Object?>{
          'windows-x64': <String, Object?>{
            'executor': 'yt-dlp',
            'binary': 'components/yt-dlp/windows-x64/yt-dlp.exe',
            'updateUrl':
                'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe',
          },
          'windows-arm64': <String, Object?>{
            'executor': 'yt-dlp',
            'binary': 'components/yt-dlp/windows-arm64/yt-dlp.exe',
            'updateUrl':
                'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe',
          },
          'android-arm': <String, Object?>{
            'executor': 'yt-dlp',
            'engine': 'embedded-python-or-system',
          },
          'android-arm64': <String, Object?>{
            'executor': 'yt-dlp',
            'engine': 'embedded-python-or-system',
          },
          'android-x64': <String, Object?>{
            'executor': 'yt-dlp',
            'engine': 'embedded-python-or-system',
          },
          'linux-x64': <String, Object?>{
            'executor': 'yt-dlp',
            'binary': 'components/yt-dlp/linux-x64/yt-dlp',
          },
          'fallback': <String, Object?>{'executor': 'yt-dlp'},
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
    final normalizedManifest = _withStandardPlatformComponents(manifest);
    final id = normalizedManifest['id']?.toString();
    if (id != null && deleted.contains(id)) return null;
    final dir = Directory('${pluginsDir.path}${Platform.pathSeparator}$folder');
    final file = File('${dir.path}${Platform.pathSeparator}plugin.json');
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map) {
          final existing = decoded.map((key, value) => MapEntry(
                key.toString(),
                value as Object?,
              ));
          final merged = _mergeTemplateManifest(existing, normalizedManifest);
          final before = const JsonEncoder.withIndent('  ').convert(existing);
          final after = const JsonEncoder.withIndent('  ').convert(merged);
          if (before != after) {
            await file.writeAsString(after);
          }
        }
      } catch (_) {
        // Keep a broken user-supplied plugin file untouched; the loader will
        // surface parsing errors separately without deleting user data.
      }
      return dir;
    }
    await dir.create(recursive: true);
    await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(normalizedManifest));
    return dir;
  }

  Map<String, Object?> _withStandardPlatformComponents(
    Map<String, Object?> manifest,
  ) {
    final copy = <String, Object?>{...manifest};
    final components = _asStringMap(copy['components']);
    final platform = <String, Object?>{
      ...?_asStringMap(copy['platformComponents']),
    };
    final executor = components?['executor']?.toString() ??
        _firstExecutor(platform) ??
        'plugin-executor';
    final fallback = _asStringMap(platform['fallback']) ??
        <String, Object?>{'executor': executor};
    Map<String, Object?> componentFor(String key, [String? sourceKey]) {
      return <String, Object?>{
        ...fallback,
        ...?_asStringMap(platform[sourceKey ?? key]),
      };
    }

    platform['windows-x64'] =
        _asStringMap(platform['windows-x64']) ?? componentFor('windows-x64');
    platform['windows-arm64'] = _asStringMap(platform['windows-arm64']) ??
        componentFor('windows-arm64', 'windows-x64');
    platform['android-arm64'] = _asStringMap(platform['android-arm64']) ??
        componentFor('android-arm64');
    platform['android-arm'] = _asStringMap(platform['android-arm']) ??
        componentFor('android-arm', 'android-arm64');
    platform['android-x64'] = _asStringMap(platform['android-x64']) ??
        componentFor('android-x64', 'android-arm64');
    platform['fallback'] = fallback;
    copy['platformComponents'] = platform;
    return copy;
  }

  Map<String, Object?> _mergeTemplateManifest(
    Map<String, Object?> existing,
    Map<String, Object?> template,
  ) {
    final merged = <String, Object?>{...existing};
    for (final key in [
      'id',
      'name',
      'version',
      'pluginType',
      'description',
      'authType',
      'repositoryUrl',
      'updateUrl',
      'components',
      'proxy',
      'mediaCatalog',
      'listFiles',
      'fileInfo',
      'fileStream',
      'upload',
    ]) {
      if (template.containsKey(key)) {
        merged[key] = _mergeObject(existing[key], template[key]);
      }
    }
    merged['capabilities'] = _mergeStringLists(
      existing['capabilities'],
      template['capabilities'],
    );
    merged['fileHandlers'] = _mergeObjectLists(
      existing['fileHandlers'],
      template['fileHandlers'],
      keyFields: const ['mode', 'sectionId'],
    );
    merged['sections'] = _mergeObjectLists(
      existing['sections'],
      template['sections'],
      keyFields: const ['id'],
    );
    merged['settings'] =
        _mergeObject(existing['settings'], template['settings']);
    merged['variables'] =
        _mergeObject(existing['variables'], template['variables']);
    merged['platformComponents'] = _mergeObject(
      existing['platformComponents'],
      template['platformComponents'],
    );
    return merged;
  }

  Object? _mergeObject(Object? existing, Object? template) {
    if (existing is Map && template is Map) {
      final result = <String, Object?>{};
      for (final entry in template.entries) {
        result[entry.key.toString()] = entry.value as Object?;
      }
      for (final entry in existing.entries) {
        final key = entry.key.toString();
        result[key] = _mergeObject(entry.value, result[key]);
      }
      return result;
    }
    return existing ?? template;
  }

  List<String> _mergeStringLists(Object? existing, Object? template) {
    final values = <String>[];
    for (final source in [template, existing]) {
      if (source is List) {
        for (final item in source) {
          final value = item.toString();
          if (!values.contains(value)) values.add(value);
        }
      }
    }
    return values;
  }

  List<Object?> _mergeObjectLists(
    Object? existing,
    Object? template, {
    required List<String> keyFields,
  }) {
    final values = <Object?>[];
    void addAll(Object? source) {
      if (source is! List) return;
      for (final item in source) {
        if (item is Map) {
          final key =
              keyFields.map((field) => item[field]?.toString() ?? '').join('|');
          final already = values.any((existingItem) {
            if (existingItem is! Map) return false;
            final existingKey = keyFields
                .map((field) => existingItem[field]?.toString() ?? '')
                .join('|');
            return existingKey == key;
          });
          if (!already) values.add(item);
        } else if (!values.contains(item)) {
          values.add(item);
        }
      }
    }

    addAll(template);
    addAll(existing);
    return values;
  }

  Map<String, Object?>? _asStringMap(Object? value) {
    if (value is! Map) return null;
    return value.map((key, item) => MapEntry(key.toString(), item as Object?));
  }

  String? _firstExecutor(Map<String, Object?> platform) {
    for (final value in platform.values) {
      final map = _asStringMap(value);
      final executor = map?['executor']?.toString();
      if (executor != null && executor.isNotEmpty) return executor;
    }
    return null;
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

  Future<void> _ensureRarPluginPayload(Directory pluginDir) async {
    final targetDir = Directory(
      '${pluginDir.path}${Platform.pathSeparator}components'
      '${Platform.pathSeparator}7zip${Platform.pathSeparator}windows-x64',
    );
    final target = File('${targetDir.path}${Platform.pathSeparator}7z.exe');
    if (await target.exists()) return;
    final candidates = <Directory>[
      Directory('windows${Platform.pathSeparator}runner'
          '${Platform.pathSeparator}resources${Platform.pathSeparator}7zip'),
      Directory('app${Platform.pathSeparator}flutter_shell'
          '${Platform.pathSeparator}windows${Platform.pathSeparator}runner'
          '${Platform.pathSeparator}resources${Platform.pathSeparator}7zip'),
    ];
    for (final sourceDir in candidates) {
      final exe = File('${sourceDir.path}${Platform.pathSeparator}7z.exe');
      final dll = File('${sourceDir.path}${Platform.pathSeparator}7z.dll');
      if (!await exe.exists() || !await dll.exists()) continue;
      await targetDir.create(recursive: true);
      for (final name in [
        '7z.exe',
        '7z.dll',
        '7zip_LICENSE.txt',
        '7zip_README.txt',
      ]) {
        final source = File('${sourceDir.path}${Platform.pathSeparator}$name');
        if (await source.exists()) {
          await source.copy('${targetDir.path}${Platform.pathSeparator}$name');
        }
      }
      return;
    }
  }

  Future<void> _ensureSwfRufflePayload(Directory pluginDir) async {
    final targetDir = Directory(
      '${pluginDir.path}${Platform.pathSeparator}components'
      '${Platform.pathSeparator}ruffle',
    );
    await targetDir.create(recursive: true);
    const files = <String>[
      'ruffle.js',
      'core.ruffle.a6584f4c154875f3f805.js',
      'core.ruffle.f8e79026a9aea0a4e05d.js',
      'bae0d5b86e41210ba443.wasm',
      'ecc5e233d534bdc785c1.wasm',
      'LICENSE_APACHE',
      'LICENSE_MIT',
    ];
    for (final name in files) {
      final target = File('${targetDir.path}${Platform.pathSeparator}$name');
      if (await target.exists() && await target.length() > 0) continue;
      try {
        final data = await rootBundle.load(
          'assets/plugin_components/swf_ruffle_player/ruffle/$name',
        );
        await target.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      } catch (_) {
        final source = File(
          'app${Platform.pathSeparator}flutter_shell'
          '${Platform.pathSeparator}assets${Platform.pathSeparator}'
          'plugin_components${Platform.pathSeparator}swf_ruffle_player'
          '${Platform.pathSeparator}ruffle${Platform.pathSeparator}$name',
        );
        if (await source.exists()) {
          await source.copy(target.path);
        }
      }
    }
  }

  Future<void> _ensureTesseractPluginPayload(Directory pluginDir) async {
    final targetDir = Directory(
      '${pluginDir.path}${Platform.pathSeparator}components'
      '${Platform.pathSeparator}tessdata',
    );
    await targetDir.create(recursive: true);
    const files = <String>['eng.traineddata', 'rus.traineddata'];
    for (final name in files) {
      final target = File('${targetDir.path}${Platform.pathSeparator}$name');
      if (await target.exists() && await target.length() > 0) continue;
      try {
        final data = await rootBundle.load('assets/tessdata/$name');
        await target.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      } catch (_) {
        final source = File(
          'app${Platform.pathSeparator}flutter_shell'
          '${Platform.pathSeparator}assets${Platform.pathSeparator}'
          'tessdata${Platform.pathSeparator}$name',
        );
        if (await source.exists()) {
          await source.copy(target.path);
        }
      }
    }
    final windowsRuntimeTarget = Directory(
      '${pluginDir.path}${Platform.pathSeparator}components'
      '${Platform.pathSeparator}tesseract'
      '${Platform.pathSeparator}windows-x64',
    );
    final runtimeSources = <Directory>[
      Directory(
        'windows${Platform.pathSeparator}runner${Platform.pathSeparator}'
        'resources${Platform.pathSeparator}tesseract'
        '${Platform.pathSeparator}windows-x64',
      ),
      Directory(
        'app${Platform.pathSeparator}flutter_shell'
        '${Platform.pathSeparator}windows${Platform.pathSeparator}runner'
        '${Platform.pathSeparator}resources${Platform.pathSeparator}tesseract'
        '${Platform.pathSeparator}windows-x64',
      ),
    ];
    for (final source in runtimeSources) {
      final binary = File(
        '${source.path}${Platform.pathSeparator}tesseract.exe',
      );
      if (await source.exists() && await binary.exists()) {
        await _copyDirectoryContents(source, windowsRuntimeTarget);
        break;
      }
    }
    final config = File(
      '${pluginDir.path}${Platform.pathSeparator}components'
      '${Platform.pathSeparator}tessdata_config.json',
    );
    if (!await config.exists()) {
      await config.writeAsString(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          'files': files,
          'defaultLanguage': 'rus+eng',
        }),
      );
    }
  }

  Future<void> _copyDirectoryContents(
    Directory source,
    Directory target,
  ) async {
    await target.create(recursive: true);
    await for (final entity
        in source.list(recursive: true, followLinks: false)) {
      final relative = entity.path
          .substring(source.path.length)
          .replaceFirst(RegExp(r'^[\\/]+'), '');
      if (relative.isEmpty) continue;
      final targetPath = '${target.path}${Platform.pathSeparator}$relative';
      if (entity is Directory) {
        await Directory(targetPath).create(recursive: true);
      } else if (entity is File) {
        await Directory(_dirname(targetPath)).create(recursive: true);
        await entity.copy(targetPath);
      }
    }
  }
}

String basename(String path) => path.split(Platform.pathSeparator).last;

String _dirname(String path) {
  final index = path.lastIndexOf(Platform.pathSeparator);
  if (index <= 0) return '.';
  return path.substring(0, index);
}
