import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';
import 'package:rar/rar.dart' as rar_plugin;

import '../ffi/crypt_bindings.dart';
import '../plugins/cloud_plugin_registry.dart' hide basename;
import '../plugins/connection_profile.dart';
import '../remote/remote_file_system.dart';
import '../security/vault_crypto.dart';
import '../storage/app_paths.dart';
import '../torrent/torrent_service.dart';
import '../viewer/file_viewer_service.dart';
import '../vault/vault_models.dart';
import 'explorer_models.dart';

class FileExplorerRepository {
  FileExplorerRepository(this._bindings);

  final CryptBindings _bindings;
  final RemoteFileSystemRepository _remote = RemoteFileSystemRepository();
  final TorrentService _torrents = const TorrentService();

  static const int _fileContainerFixedSize = 106;
  static const int _fileParamsTlvTag = 0x1001;
  static const int _chunkedEncryptionThreshold = 32 * 1024 * 1024;
  static const int _chunkedEncryptionChunkSize = 2 * 1024 * 1024;
  static const String _zipScheme = 'zip://';
  static const String _rarScheme = 'rar://';
  static const String _remoteScheme = 'remote://';
  static const String _torrentScheme = 'torrent://';
  static const String _folderMetaFileName = '.folder.cryptmeta';

  void configurePlugins(
    List<CloudPluginDefinition> plugins, [
    List<PluginConnectionProfile> profiles = const <PluginConnectionProfile>[],
  ]) {
    _remote.configurePlugins(_runtimePlugins(plugins, profiles));
  }

  bool supportsRemotePlugin(CloudPluginDefinition plugin) =>
      _remote.isSupported(plugin);

  bool isVirtualPath(String path) =>
      _ZipVirtualPath.tryParse(path) != null ||
      _RarVirtualPath.tryParse(path) != null ||
      _RemoteVirtualPath.tryParse(path) != null ||
      _TorrentVirtualPath.tryParse(path) != null;

  String zipRootPath(String archivePath) => _ZipVirtualPath.build(archivePath);

  String rarRootPath(String archivePath) => _RarVirtualPath.build(archivePath);

  String remoteRootPath(String pluginId) => _RemoteVirtualPath.build(pluginId);

  String torrentRootPath(String torrentPath) =>
      _TorrentVirtualPath.build(torrentPath);

  Future<File> importTorrentToVault(String torrentPath) =>
      _torrents.importTorrent(torrentPath);

  String parentPathFor(String path) {
    final zip = _ZipVirtualPath.tryParse(path);
    if (zip != null) {
      if (zip.innerPath.isEmpty) {
        return File(zip.archivePath).parent.path;
      }
      final parts = zip.innerPath.split('/')..removeLast();
      return _ZipVirtualPath.build(zip.archivePath, parts.join('/'));
    }
    final rar = _RarVirtualPath.tryParse(path);
    if (rar != null) {
      if (rar.innerPath.isEmpty) {
        return File(rar.archivePath).parent.path;
      }
      final parts = rar.innerPath.split('/')..removeLast();
      return _RarVirtualPath.build(rar.archivePath, parts.join('/'));
    }
    final remote = _RemoteVirtualPath.tryParse(path);
    if (remote != null) {
      if (remote.innerPath == '/') {
        return remote.fullPath;
      }
      return _RemoteVirtualPath.build(
        remote.pluginId,
        _remoteParent(remote.innerPath),
      );
    }
    final torrent = _TorrentVirtualPath.tryParse(path);
    if (torrent != null) {
      if (torrent.innerPath.isEmpty) {
        return File(torrent.torrentPath).parent.path;
      }
      return _TorrentVirtualPath.build(
        torrent.torrentPath,
        _zipParent(torrent.innerPath),
      );
    }
    return File(path).parent.path;
  }

  Future<List<ExplorerLocation>> loadLocations(
    List<CloudPluginDefinition> plugins, [
    List<PluginConnectionProfile> profiles = const <PluginConnectionProfile>[],
  ]) async {
    final hidden = await AppPaths.hiddenVaultDirectory();
    final locations = <ExplorerLocation>[];

    if (Platform.isWindows) {
      for (var code = 65; code <= 90; code++) {
        final letter = String.fromCharCode(code);
        final root = '$letter:\\';
        if (await Directory(root).exists()) {
          locations.add(
            ExplorerLocation(
              id: 'drive-$letter',
              name: 'Диск $letter:',
              kind: ExplorerLocationKind.local,
              path: root,
              description: 'Локальная область памяти Windows',
            ),
          );
        }
      }
    } else if (Platform.isAndroid) {
      locations.addAll(<ExplorerLocation>[
        const ExplorerLocation(
          id: 'android-root',
          name: 'Корень файловой системы',
          kind: ExplorerLocationKind.local,
          path: '/',
          description:
              'Системный корень Android, часть путей может быть закрыта',
        ),
        const ExplorerLocation(
          id: 'android-phone-files',
          name: 'Файлы телефона',
          kind: ExplorerLocationKind.phoneFiles,
          path: '/storage/emulated/0',
          description: 'Стандартная пользовательская область Android',
        ),
      ]);
    } else {
      locations.addAll(<ExplorerLocation>[
        const ExplorerLocation(
          id: 'linux-root',
          name: 'Корень файловой системы',
          kind: ExplorerLocationKind.local,
          path: '/',
          description: 'Локальная область относительно /',
        ),
        if (Platform.environment['HOME'] case final home?)
          ExplorerLocation(
            id: 'linux-home',
            name: 'Домашняя папка',
            kind: ExplorerLocationKind.local,
            path: home,
            description: 'Пользовательская область Linux',
          ),
      ]);
    }

    locations.add(
      ExplorerLocation(
        id: 'app-hidden',
        name: 'Скрытое хранилище программы',
        kind: ExplorerLocationKind.appHidden,
        path: hidden.path,
        description: 'Файлы внутри директории приложения',
      ),
    );

    final pluginsById = {
      for (final plugin in plugins) plugin.id: plugin,
    };
    for (final profile in profiles) {
      final plugin = pluginsById[profile.pluginId];
      if (plugin == null || !_remote.isSupported(plugin)) {
        continue;
      }
      final description = [
        plugin.name,
        if (profile.endpointSummary.trim().isNotEmpty) profile.endpointSummary,
      ].join(' • ');
      locations.add(
        ExplorerLocation(
          id: 'profile-${profile.id}',
          name: profile.name,
          kind: plugin.pluginType.contains('network')
              ? ExplorerLocationKind.network
              : ExplorerLocationKind.cloudPlugin,
          description: description,
          enabled: true,
          path: remoteRootPath(profile.runtimePluginId),
          pluginId: profile.runtimePluginId,
        ),
      );
    }

    return locations;
  }

  List<CloudPluginDefinition> _runtimePlugins(
    List<CloudPluginDefinition> plugins,
    List<PluginConnectionProfile> profiles,
  ) {
    final pluginsById = {
      for (final plugin in plugins) plugin.id: plugin,
    };
    return <CloudPluginDefinition>[
      ...plugins,
      for (final profile in profiles)
        if (pluginsById[profile.pluginId] case final plugin?)
          plugin.withConnectionProfile(profile),
    ];
  }

  Future<DirectorySnapshot> listDirectory(
    String path, {
    String? commonPassword,
    String? filePassword,
    bool decryptNames = true,
  }) async {
    final zipPath = _ZipVirtualPath.tryParse(path);
    if (zipPath != null) {
      return _listZipDirectory(zipPath);
    }
    final rarPath = _RarVirtualPath.tryParse(path);
    if (rarPath != null) {
      return _listRarDirectory(rarPath);
    }
    final remotePath = _RemoteVirtualPath.tryParse(path);
    if (remotePath != null) {
      return _listRemoteDirectory(remotePath);
    }
    final torrentPath = _TorrentVirtualPath.tryParse(path);
    if (torrentPath != null) {
      return _listTorrentDirectory(torrentPath);
    }

    final directory = Directory(path);
    if (!await directory.exists()) {
      return DirectorySnapshot(
          path: path, entries: const [], error: 'Папка не найдена.');
    }

    final entries = <ExplorerEntry>[];
    try {
      final parent = directory.parent.path;
      if (_normalizePath(parent) != _normalizePath(directory.path)) {
        entries.add(
          ExplorerEntry(
            name: '...',
            path: parent,
            kind: ExplorerEntryKind.directory,
            sizeBytes: 0,
            modifiedAt: DateTime.now(),
            isNavigationEntry: true,
          ),
        );
      }
      await for (final entity in directory.list(followLinks: false)) {
        final stat = await entity.stat();
        final name = basename(entity.path);
        if (entity is Directory) {
          final displayName = decryptNames
              ? await _folderDisplayName(
                  entity,
                  commonPassword: commonPassword,
                  filePassword: filePassword,
                )
              : name;
          entries.add(
            ExplorerEntry(
              name: displayName,
              path: entity.path,
              kind: ExplorerEntryKind.directory,
              sizeBytes: 0,
              modifiedAt: stat.modified,
              createdAt: stat.changed,
            ),
          );
          continue;
        }
        if (entity is File) {
          final kind = _kindForFile(name);
          VaultContainerInfo? info;
          var displayName = name;
          if (kind == ExplorerEntryKind.encryptedFile ||
              kind == ExplorerEntryKind.folderMeta) {
            info = await _inspectContainer(entity, kind);
            if (decryptNames && kind == ExplorerEntryKind.encryptedFile) {
              final password = await _passwordForAutoName(
                entity,
                commonPassword: commonPassword,
                filePassword: filePassword,
              );
              if (password != null) {
                displayName = await _decryptAppCryptName(
                        await _readCryptHeaderBytes(entity),
                        password: password)
                    .catchError((_) => name);
              }
            }
          }
          entries.add(
            ExplorerEntry(
              name: displayName,
              path: entity.path,
              kind: kind,
              sizeBytes: stat.size,
              modifiedAt: stat.modified,
              createdAt: stat.changed,
              containerInfo: info,
            ),
          );
        }
      }
    } on FileSystemException catch (error) {
      return DirectorySnapshot(
          path: path, entries: entries, error: error.message);
    }

    entries.sort((a, b) {
      if (a.isNavigationEntry != b.isNavigationEntry) {
        return a.isNavigationEntry ? -1 : 1;
      }
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return DirectorySnapshot(path: path, entries: entries);
  }

  Future<DirectorySnapshot> searchDirectory(
    String path, {
    required String query,
    required String mode,
    required bool useRegex,
    required bool recursive,
    String? commonPassword,
    String? filePassword,
    bool decryptNames = true,
  }) async {
    final directory = Directory(path);
    if (!await directory.exists()) {
      return DirectorySnapshot(
        path: path,
        entries: const [],
        error: 'Папка не найдена.',
      );
    }
    final matcher = _SearchMatcher(query, useRegex: useRegex);
    final entries = <ExplorerEntry>[];
    try {
      await for (final entity
          in directory.list(recursive: recursive, followLinks: false)) {
        final entry = await entryForPath(entity.path);
        if (entry == null || entry.isNavigationEntry) continue;
        final nameMatches = matcher.matches(entry.name) ||
            matcher.matches(basename(entry.path));
        var contentMatches = false;
        if (!entry.isDirectory && mode != 'name') {
          contentMatches = await _fileContentMatches(
            entry,
            matcher,
            commonPassword: commonPassword,
            filePassword: filePassword,
          );
        }
        final accepted = switch (mode) {
          'content' => contentMatches,
          'nameContent' => nameMatches || contentMatches,
          _ => nameMatches,
        };
        if (accepted) {
          if (decryptNames && entry.isEncrypted) {
            try {
              final preview = await previewFile(
                entry.path,
                password: filePassword,
                commonPassword: commonPassword,
              );
              if (preview.decrypted) {
                entries.add(ExplorerEntry(
                  name: preview.title,
                  path: entry.path,
                  kind: entry.kind,
                  sizeBytes: entry.sizeBytes,
                  modifiedAt: entry.modifiedAt,
                  createdAt: entry.createdAt,
                  containerInfo: entry.containerInfo,
                  exists: entry.exists,
                ));
                continue;
              }
            } catch (_) {}
          }
          entries.add(entry);
        }
      }
    } on FileSystemException catch (error) {
      return DirectorySnapshot(
          path: path, entries: entries, error: error.message);
    }
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return DirectorySnapshot(path: path, entries: entries);
  }

  Future<ExplorerEntry?> entryForPath(String path) async {
    final zipPath = _ZipVirtualPath.tryParse(path);
    if (zipPath != null) {
      return _entryForZipPath(zipPath);
    }
    final remotePath = _RemoteVirtualPath.tryParse(path);
    if (remotePath != null) {
      return _entryForRemotePath(remotePath);
    }
    final torrentPath = _TorrentVirtualPath.tryParse(path);
    if (torrentPath != null) {
      return _entryForTorrentPath(torrentPath);
    }

    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      return null;
    }
    final entity =
        type == FileSystemEntityType.directory ? Directory(path) : File(path);
    final stat = await entity.stat();
    final name = basename(path);
    if (type == FileSystemEntityType.directory) {
      return ExplorerEntry(
        name: name,
        path: path,
        kind: ExplorerEntryKind.directory,
        sizeBytes: 0,
        modifiedAt: stat.modified,
        createdAt: stat.changed,
      );
    }
    final kind = _kindForFile(name);
    VaultContainerInfo? info;
    if (kind == ExplorerEntryKind.encryptedFile ||
        kind == ExplorerEntryKind.folderMeta) {
      info = await _inspectContainer(File(path), kind);
    }
    return ExplorerEntry(
      name: name,
      path: path,
      kind: kind,
      sizeBytes: stat.size,
      modifiedAt: stat.modified,
      createdAt: stat.changed,
      containerInfo: info,
    );
  }

  Future<DirectorySnapshot> snapshotForPaths(
    String label,
    List<String> paths,
  ) async {
    final entries = <ExplorerEntry>[];
    for (final path in paths) {
      final entry = await entryForPath(path);
      if (entry != null) {
        entries.add(entry);
      } else {
        entries.add(
          ExplorerEntry(
            name: basename(path),
            path: path,
            kind: ExplorerEntryKind.unknown,
            sizeBytes: 0,
            modifiedAt: DateTime.fromMillisecondsSinceEpoch(0),
            exists: false,
          ),
        );
      }
    }
    return DirectorySnapshot(path: label, entries: entries);
  }

  Future<DirectorySnapshot> snapshotForLocations(
    String label,
    List<ExplorerLocation> locations, {
    List<String> extraPaths = const <String>[],
  }) async {
    final entries = <ExplorerEntry>[];
    final profileChecks = <String, Future<_RemoteConnectionCheck>>{
      for (final location in locations)
        if (location.enabled &&
            location.path != null &&
            _profileIdForLocation(location) != null &&
            location.pluginId != null)
          location.pluginId!: _checkRemoteProfile(location.pluginId!),
    };
    for (final location in locations) {
      final path = location.path;
      if (!location.enabled || path == null) {
        continue;
      }
      final profileId = _profileIdForLocation(location);
      final connectionCheck = location.pluginId == null
          ? null
          : await profileChecks[location.pluginId!];
      final entry = await entryForPath(path);
      if (entry != null) {
        entries.add(
          ExplorerEntry(
            name: location.name,
            path: entry.path,
            kind: entry.isDirectory
                ? ExplorerEntryKind.directory
                : ExplorerEntryKind.unknown,
            sizeBytes: entry.sizeBytes,
            modifiedAt: entry.modifiedAt,
            createdAt: entry.createdAt,
            exists: entry.exists,
            connectionProfileId: profileId,
            connectionStatus:
                connectionCheck?.status ?? ExplorerConnectionStatus.none,
            connectionMessage: connectionCheck?.message,
          ),
        );
      } else {
        entries.add(
          ExplorerEntry(
            name: location.name,
            path: path,
            kind: ExplorerEntryKind.unknown,
            sizeBytes: 0,
            modifiedAt: DateTime.fromMillisecondsSinceEpoch(0),
            exists: false,
            connectionProfileId: profileId,
            connectionStatus:
                connectionCheck?.status ?? ExplorerConnectionStatus.none,
            connectionMessage: connectionCheck?.message,
          ),
        );
      }
    }
    for (final path in extraPaths) {
      final entry = await entryForPath(path);
      if (entry != null) {
        entries.add(entry);
      } else {
        entries.add(
          ExplorerEntry(
            name: basename(path),
            path: path,
            kind: ExplorerEntryKind.unknown,
            sizeBytes: 0,
            modifiedAt: DateTime.fromMillisecondsSinceEpoch(0),
            exists: false,
          ),
        );
      }
    }
    return DirectorySnapshot(path: label, entries: entries);
  }

  String? _profileIdForLocation(ExplorerLocation location) {
    final id = location.id;
    if (id.startsWith('profile-')) {
      return id.substring('profile-'.length);
    }
    final pluginId = location.pluginId;
    if (pluginId != null && pluginId.startsWith('profile-')) {
      return pluginId.substring('profile-'.length);
    }
    return null;
  }

  Future<_RemoteConnectionCheck> _checkRemoteProfile(
    String runtimePluginId,
  ) async {
    if (!_remote.hasPlugin(runtimePluginId)) {
      return const _RemoteConnectionCheck(
        ExplorerConnectionStatus.unavailable,
        'Profile executor is not loaded.',
      );
    }
    try {
      await _remote
          .clientFor(runtimePluginId)
          .list('/')
          .timeout(const Duration(seconds: 6));
      return const _RemoteConnectionCheck(
        ExplorerConnectionStatus.available,
        null,
      );
    } catch (error) {
      return _RemoteConnectionCheck(
        ExplorerConnectionStatus.unavailable,
        error.toString(),
      );
    }
  }

  Future<DirectorySnapshot> mediaSnapshot({
    required String label,
    required List<String> roots,
    required Set<String> extensions,
    String exclusions = '',
  }) async {
    final entries = <ExplorerEntry>[];
    final rules = _exclusionRules(exclusions);
    for (final root in roots.where((item) => item.trim().isNotEmpty)) {
      final directory = Directory(root.trim());
      if (!await directory.exists()) continue;
      try {
        await for (final entity
            in directory.list(recursive: true, followLinks: false)) {
          if (entity is! File) continue;
          final name = basename(entity.path);
          if (!extensions.contains(FileViewerService.extensionForName(name))) {
            continue;
          }
          if (_isExcluded(entity.path, name, rules)) {
            continue;
          }
          final entry = await entryForPath(entity.path);
          if (entry != null) entries.add(entry);
        }
      } on FileSystemException {
        continue;
      }
    }
    entries
        .sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return DirectorySnapshot(path: label, entries: entries);
  }

  Future<FilePreview> previewFile(
    String path, {
    String? password,
    String? commonPassword,
  }) async {
    final zipPath = _ZipVirtualPath.tryParse(path);
    if (zipPath != null) {
      return _previewZipFile(zipPath);
    }
    final rarPath = _RarVirtualPath.tryParse(path);
    if (rarPath != null) {
      return _previewRarFile(rarPath);
    }
    final remotePath = _RemoteVirtualPath.tryParse(path);
    if (remotePath != null) {
      return _previewRemoteFile(remotePath);
    }
    final torrentPath = _TorrentVirtualPath.tryParse(path);
    if (torrentPath != null) {
      return _previewTorrentFile(torrentPath);
    }

    final file = File(path);
    final name = basename(path);
    if (!await file.exists()) {
      return FilePreview(title: name, subtitle: 'Файл не найден.');
    }

    final kind = _kindForFile(name);
    if (kind == ExplorerEntryKind.encryptedFile) {
      final bytes = await file.readAsBytes();
      final info = await _bindings.inspectFileContainer(bytes);
      final params = _readCryptParameters(bytes);
      final effectivePassword =
          (password != null && password.isNotEmpty) ? password : null;
      final passwordToUse = effectivePassword ??
          (params?.usesCommonKey == true ? commonPassword : null);
      if (passwordToUse == null || passwordToUse.isEmpty) {
        return FilePreview(
          title: name,
          subtitle:
              'Зашифрованный контейнер. Укажите пароль, чтобы просмотреть содержимое.',
          containerInfo: info,
          contentKind: FileContentKind.unknown,
        );
      }
      try {
        final opened = await _decryptAppCrypt(bytes, password: passwordToUse);
        return FileViewerService.previewBytes(
          name: opened.name,
          subtitle: 'Расшифровано: ${opened.payload.length} байт',
          bytes: opened.payload,
          sourcePath: file.path,
          containerInfo: info,
        );
      } catch (error) {
        return FilePreview(
          title: name,
          subtitle: 'Контейнер прочитан, но расшифровать не удалось: $error',
          containerInfo: info,
        );
      }
    }

    if (kind == ExplorerEntryKind.folderMeta) {
      final bytes = await file.readAsBytes();
      final info = await _bindings.inspectFolderMeta(bytes);
      return FilePreview(
        title: name,
        subtitle: 'Метаданные папки Secure Vault',
        containerInfo: info,
        contentKind: FileContentKind.document,
      );
    }

    return FileViewerService.previewPlainFile(file);
  }

  Future<EncryptedFileParameters?> encryptedFileParameters(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      return null;
    }
    return _readCryptParameters(await _readCryptHeaderBytes(file));
  }

  Future<File> importFile(TransferOptions options) async {
    final sourcePath = options.sourcePath;
    if (sourcePath == null || sourcePath.isEmpty) {
      throw ArgumentError('Не указан исходный файл.');
    }
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw FileSystemException('Исходный файл не найден', sourcePath);
    }
    final targetDir = Directory(options.targetDirectory);
    await targetDir.create(recursive: true);

    final result = options.asEncrypted
        ? await encryptFileToDirectory(
            source,
            targetDir,
            password: _requirePassword(options.password),
          )
        : await _copyFileToDirectory(source, targetDir,
            preferredName: basename(source.path));

    if (options.deleteSourceAfter) {
      await source.delete();
    }
    return result;
  }

  Future<File> exportFile(String sourcePath, TransferOptions options) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw FileSystemException('Файл не найден', sourcePath);
    }
    final targetDir = Directory(options.targetDirectory);
    await targetDir.create(recursive: true);
    final sourceKind = _kindForFile(basename(source.path));

    late final File result;
    if (options.asEncrypted) {
      result = sourceKind == ExplorerEntryKind.encryptedFile
          ? await _copyFileToDirectory(source, targetDir,
              preferredName: basename(source.path))
          : await encryptFileToDirectory(source, targetDir,
              password: _requirePassword(options.password));
    } else {
      if (sourceKind == ExplorerEntryKind.encryptedFile) {
        final opened = await _decryptAppCrypt(await source.readAsBytes(),
            password: _requirePassword(options.password));
        final target = await _availableFile(targetDir, opened.name);
        await target.writeAsBytes(opened.payload);
        result = target;
      } else {
        result = await _copyFileToDirectory(source, targetDir,
            preferredName: basename(source.path));
      }
    }

    if (options.deleteSourceAfter) {
      await source.delete();
    }
    return result;
  }

  Future<File> encryptFileToDirectory(
    File source,
    Directory targetDir, {
    required String password,
    EncryptionKeyMode keyMode = EncryptionKeyMode.unique,
    String algorithm = EncryptionAlgorithm.xchacha20Poly1305,
    void Function(int completedBytes, int totalBytes)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    final sourceStat = await source.stat();
    final salt = VaultCrypto.randomBytes(16);
    final fileId = VaultCrypto.randomBytes(16);
    final fileName = basename(source.path);
    final target = await _availableFile(targetDir, 'f_${_hex(fileId)}.crypt');
    final key = await VaultCrypto.deriveKey(password, salt);
    final headerPlain = utf8.encode(jsonEncode(<String, Object?>{
      'schema': 'securevault.fileHeader.v1',
      'name': fileName,
      'originalSize': sourceStat.size,
      'createdAtUtcMs': sourceStat.changed.toUtc().millisecondsSinceEpoch,
      'updatedAtUtcMs': sourceStat.modified.toUtc().millisecondsSinceEpoch,
    }));

    final encryptedHeader = await VaultCrypto.encryptBytesWithKey(
      headerPlain,
      key: key,
      aad: utf8.encode('securevault.file.header.v1'),
      algorithm: algorithm,
    );

    if (sourceStat.size >= _chunkedEncryptionThreshold) {
      return _encryptFileToDirectoryChunked(
        source: source,
        target: target,
        sourceStat: sourceStat,
        fileId: fileId,
        fileName: fileName,
        salt: salt,
        keyMode: keyMode,
        algorithm: algorithm,
        key: key,
        encryptedHeader: encryptedHeader,
        onProgress: onProgress,
        shouldCancel: shouldCancel,
      );
    }

    if (shouldCancel?.call() == true) {
      throw FileSystemException('Operation cancelled.', source.path);
    }
    final sourceBytes = await source.readAsBytes();
    final encryptedPayload = await VaultCrypto.encryptBytesWithKey(
      sourceBytes,
      key: key,
      aad: utf8.encode('securevault.file.payload.v1:$fileName'),
      algorithm: algorithm,
    );
    onProgress?.call(sourceStat.size, sourceStat.size);

    final params = utf8.encode(jsonEncode(<String, Object?>{
      'schema': 'securevault.fileCrypto.v1',
      'kdf': 'argon2id',
      'cipher': algorithm,
      'keyMode': keyMode.name,
      'salt': base64UrlEncode(salt),
      'box': 'nonce+cipherText+mac',
      'nonceLength': VaultCrypto.nonceLengthFor(algorithm),
      'macLength': 16,
      'payloadEncoding': 'single-box-v1',
    }));

    final containerBytes = _buildFileContainerBytes(
      fileId: fileId,
      originalName: fileName,
      originalSize: sourceStat.size,
      storedSize: encryptedPayload.length,
      encryptedHeader: encryptedHeader,
      encryptedPayload: encryptedPayload,
      tlvValue: params,
      createdAtUtcMs: sourceStat.changed.toUtc().millisecondsSinceEpoch,
      updatedAtUtcMs: DateTime.now().toUtc().millisecondsSinceEpoch,
    );

    await target.writeAsBytes(containerBytes, flush: true);
    return target;
  }

  Future<File> _encryptFileToDirectoryChunked({
    required File source,
    required File target,
    required FileStat sourceStat,
    required Uint8List fileId,
    required String fileName,
    required Uint8List salt,
    required EncryptionKeyMode keyMode,
    required String algorithm,
    required SecretKey key,
    required Uint8List encryptedHeader,
    void Function(int completedBytes, int totalBytes)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    final payloadTemp = File('${target.path}.payload.tmp');
    IOSink? payloadSink;
    RandomAccessFile? input;
    var processed = 0;
    var chunkIndex = 0;
    var storedPayloadSize = 0;
    try {
      payloadSink = payloadTemp.openWrite();
      input = await source.open();
      while (processed < sourceStat.size) {
        if (shouldCancel?.call() == true) {
          throw FileSystemException('Operation cancelled.', source.path);
        }
        final remaining = sourceStat.size - processed;
        final readLength = math.min(_chunkedEncryptionChunkSize, remaining);
        final chunk = await input.read(readLength);
        if (chunk.isEmpty) break;
        final encryptedChunk = await VaultCrypto.encryptBytesWithKey(
          chunk,
          key: key,
          aad: utf8.encode(
            'securevault.file.payload.chunk.v1:$fileName:$chunkIndex',
          ),
          algorithm: algorithm,
        );
        payloadSink.add(_u32(encryptedChunk.length));
        payloadSink.add(encryptedChunk);
        storedPayloadSize += 4 + encryptedChunk.length;
        processed += chunk.length;
        chunkIndex++;
        onProgress?.call(processed, sourceStat.size);
        await Future<void>.delayed(Duration.zero);
      }
      await payloadSink.flush();
      await payloadSink.close();
      payloadSink = null;
      await input.close();
      input = null;

      final params = utf8.encode(jsonEncode(<String, Object?>{
        'schema': 'securevault.fileCrypto.v1',
        'kdf': 'argon2id',
        'cipher': algorithm,
        'keyMode': keyMode.name,
        'salt': base64UrlEncode(salt),
        'box': 'nonce+cipherText+mac',
        'nonceLength': VaultCrypto.nonceLengthFor(algorithm),
        'macLength': 16,
        'payloadEncoding': 'chunked-v1',
        'chunkSize': _chunkedEncryptionChunkSize,
        'chunkCount': chunkIndex,
      }));

      final prefix = _buildFileContainerPrefix(
        fileId: fileId,
        originalSize: sourceStat.size,
        storedSize: storedPayloadSize,
        encryptedHeader: encryptedHeader,
        tlvValue: params,
        createdAtUtcMs: sourceStat.changed.toUtc().millisecondsSinceEpoch,
        updatedAtUtcMs: DateTime.now().toUtc().millisecondsSinceEpoch,
      );

      final output = target.openWrite();
      output.add(prefix);
      await output.addStream(payloadTemp.openRead());
      await output.flush();
      await output.close();
      try {
        await payloadTemp.delete();
      } catch (_) {}
      onProgress?.call(sourceStat.size, sourceStat.size);
      return target;
    } catch (_) {
      try {
        await payloadSink?.close();
      } catch (_) {}
      try {
        await input?.close();
      } catch (_) {}
      if (await payloadTemp.exists()) {
        try {
          await payloadTemp.delete();
        } catch (_) {}
      }
      if (await target.exists()) {
        try {
          await target.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<File> encryptSelectedFile(
    File source,
    EncryptFileOptions options, {
    void Function(int completedBytes, int totalBytes)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    final targetDir = Directory(options.targetDirectory);
    await targetDir.create(recursive: true);
    final encrypted = await encryptFileToDirectory(
      source,
      targetDir,
      password: options.password,
      keyMode: options.mode,
      algorithm: options.algorithm,
      onProgress: onProgress,
      shouldCancel: shouldCancel,
    );
    if (options.deleteSourceAfter) {
      await source.delete();
    }
    return encrypted;
  }

  Future<File> decryptSelectedFile(
    File source,
    DecryptFileOptions options,
  ) async {
    final targetDir = Directory(options.targetDirectory);
    await targetDir.create(recursive: true);
    final opened = await _decryptAppCrypt(
      await source.readAsBytes(),
      password: options.password,
    );
    final target = await _availableFile(targetDir, opened.name);
    await target.writeAsBytes(opened.payload, flush: true);
    if (options.deleteSourceAfter) {
      await source.delete();
    }
    return target;
  }

  Future<Directory> extractZipToDirectory(
    File source,
    Directory targetDir,
  ) async {
    await targetDir.create(recursive: true);
    final outDir = await _availableDirectory(
      targetDir,
      basename(source.path)
          .replaceFirst(RegExp(r'\.zip$', caseSensitive: false), ''),
    );
    await outDir.create(recursive: true);
    final archive = ZipDecoder().decodeBytes(await source.readAsBytes());
    for (final item in archive.files) {
      final safeName = item.name
          .replaceAll('\\', '/')
          .split('/')
          .where((part) => part.isNotEmpty && part != '..')
          .join(Platform.pathSeparator);
      if (safeName.isEmpty) continue;
      final outPath = '${outDir.path}${Platform.pathSeparator}$safeName';
      if (item.isFile) {
        final file = File(outPath);
        await file.parent.create(recursive: true);
        await file.writeAsBytes(item.content as List<int>, flush: true);
      } else {
        await Directory(outPath).create(recursive: true);
      }
    }
    return outDir;
  }

  Future<Directory> extractRarToDirectory(
    File source,
    Directory targetDir,
  ) async {
    await targetDir.create(recursive: true);
    final outDir = await _availableDirectory(
      targetDir,
      basename(source.path)
          .replaceFirst(RegExp(r'\.rar$', caseSensitive: false), ''),
    );
    await outDir.create(recursive: true);
    if (Platform.isAndroid) {
      final result = await rar_plugin.Rar.extractRarFile(
        rarFilePath: source.path,
        destinationPath: outDir.path,
      );
      if (result['success'] != true) {
        throw FileSystemException(
          result['message']?.toString() ?? 'RAR extraction failed.',
          source.path,
        );
      }
      return outDir;
    }
    await _runRarCliExtract(
      archivePath: source.path,
      outputDirectory: outDir.path,
    );
    return outDir;
  }

  Future<File> createZipFromPaths(
    Iterable<String> sourcePaths,
    Directory targetDir, {
    required String archiveName,
  }) async {
    await targetDir.create(recursive: true);
    final archive = Archive();
    for (final sourcePath in sourcePaths) {
      final type = await FileSystemEntity.type(sourcePath, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        await _addDirectoryToZipArchive(
          archive,
          Directory(sourcePath),
          rootName: basename(sourcePath),
        );
      } else if (type == FileSystemEntityType.file) {
        final file = File(sourcePath);
        final stat = await file.stat();
        final archiveFile = ArchiveFile(
          basename(sourcePath),
          stat.size,
          await file.readAsBytes(),
        )..lastModTime = stat.modified.millisecondsSinceEpoch ~/ 1000;
        archive.addFile(archiveFile);
      }
    }
    final target = await _availableFile(targetDir, archiveName);
    final bytes = ZipEncoder().encode(archive);
    await target.writeAsBytes(bytes, flush: true);
    return target;
  }

  Future<Directory> encryptFolderName(
    Directory source, {
    required String password,
  }) async {
    if (!await source.exists()) {
      throw FileSystemException('Folder not found', source.path);
    }
    final currentName = basename(source.path);
    if (currentName.startsWith('d_') && currentName.endsWith('.cryptdir')) {
      return source;
    }
    final parent = source.parent;
    final directoryId = _hex(VaultCrypto.randomBytes(16));
    final target = Directory(
      '${parent.path}${Platform.pathSeparator}d_$directoryId.cryptdir',
    );
    final renamed = await source.rename(target.path);
    final envelope = await VaultCrypto.encryptTextEnvelope(
      jsonEncode(<String, Object?>{
        'schema': 'securevault.folderName.v1',
        'name': currentName,
        'renamedAtUtcMs': DateTime.now().toUtc().millisecondsSinceEpoch,
      }),
      password: password,
    );
    final metaFile =
        File('${renamed.path}${Platform.pathSeparator}$_folderMetaFileName');
    await metaFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'schema': 'securevault.folderMeta.v1',
        'folderNameEnvelope': envelope,
      }),
      flush: true,
    );
    return renamed;
  }

  Future<Directory> decryptFolderName(
    Directory source, {
    required String password,
  }) async {
    final originalName = await _decryptFolderName(source, password: password);
    if (originalName == null || originalName.trim().isEmpty) {
      throw const FormatException(
          'Folder does not contain encrypted metadata.');
    }
    final parent = source.parent;
    final target = await _availableDirectory(parent, originalName);
    final metaFile =
        File('${source.path}${Platform.pathSeparator}$_folderMetaFileName');
    if (await metaFile.exists()) {
      await metaFile.delete();
    }
    return source.rename(target.path);
  }

  Future<FileSystemEntity> copyEntityToDirectory(
    String sourcePath,
    String targetDirectory,
  ) async {
    final type = await FileSystemEntity.type(sourcePath, followLinks: false);
    final targetDir = Directory(targetDirectory);
    await targetDir.create(recursive: true);
    if (type == FileSystemEntityType.directory) {
      final target = await _availableDirectory(targetDir, basename(sourcePath));
      await _copyDirectory(Directory(sourcePath), target);
      return target;
    }
    if (type == FileSystemEntityType.file) {
      return _copyFileToDirectory(
        File(sourcePath),
        targetDir,
        preferredName: basename(sourcePath),
      );
    }
    throw FileSystemException('Path not found', sourcePath);
  }

  Future<FileSystemEntity> moveEntityToDirectory(
    String sourcePath,
    String targetDirectory,
  ) async {
    final type = await FileSystemEntity.type(sourcePath, followLinks: false);
    final targetDir = Directory(targetDirectory);
    await targetDir.create(recursive: true);
    if (type == FileSystemEntityType.directory) {
      final target = await _availableDirectory(targetDir, basename(sourcePath));
      return Directory(sourcePath).rename(target.path);
    }
    if (type == FileSystemEntityType.file) {
      final target = await _availableFile(targetDir, basename(sourcePath));
      return File(sourcePath).rename(target.path);
    }
    throw FileSystemException('Path not found', sourcePath);
  }

  Future<Directory> createDirectory(String targetDirectory, String name) async {
    final normalized = name.trim();
    if (normalized.isEmpty ||
        normalized.contains('/') ||
        normalized.contains('\\')) {
      throw ArgumentError('Invalid folder name.');
    }
    final remote = _RemoteVirtualPath.tryParse(targetDirectory);
    if (remote != null) {
      await _remote
          .clientFor(remote.pluginId)
          .createDirectory(_remoteJoin(remote.innerPath, normalized));
      return Directory(targetDirectory);
    }
    final targetDir = Directory(targetDirectory);
    await targetDir.create(recursive: true);
    final directory = await _availableDirectory(targetDir, normalized);
    await directory.create(recursive: true);
    return directory;
  }

  Future<String> createFile(
    String targetDirectory,
    String name,
    List<int> bytes,
  ) async {
    final normalized = name.trim();
    if (normalized.isEmpty ||
        normalized.contains('/') ||
        normalized.contains('\\')) {
      throw ArgumentError('Invalid file name.');
    }
    final remote = _RemoteVirtualPath.tryParse(targetDirectory);
    if (remote != null) {
      final client = _remote.clientFor(remote.pluginId);
      final remotePath =
          await _availableRemoteFile(client, remote.innerPath, normalized);
      await client.writeBytes(remotePath, bytes);
      return _RemoteVirtualPath.build(remote.pluginId, remotePath);
    }
    final targetDir = Directory(targetDirectory);
    await targetDir.create(recursive: true);
    final target = await _availableFile(targetDir, normalized);
    await target.writeAsBytes(bytes, flush: true);
    return target.path;
  }

  Future<String> _availableRemoteFile(
    RemoteFileSystemClient client,
    String parentPath,
    String preferredName,
  ) async {
    final dotIndex = preferredName.lastIndexOf('.');
    final stem =
        dotIndex <= 0 ? preferredName : preferredName.substring(0, dotIndex);
    final ext = dotIndex <= 0 ? '' : preferredName.substring(dotIndex);
    var candidateName = preferredName;
    var candidatePath = _remoteJoin(parentPath, candidateName);
    var index = 1;
    while (await client.stat(candidatePath) != null) {
      candidateName = '$stem-$index$ext';
      candidatePath = _remoteJoin(parentPath, candidateName);
      index++;
    }
    return candidatePath;
  }

  Future<FileSystemEntity> renameEntity(String path, String newName) async {
    final normalized = newName.trim();
    if (normalized.isEmpty ||
        normalized.contains('/') ||
        normalized.contains('\\')) {
      throw ArgumentError('Invalid file name.');
    }
    final parent = File(path).parent.path;
    final nextPath = '$parent${Platform.pathSeparator}$normalized';
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      return Directory(path).rename(nextPath);
    }
    if (type == FileSystemEntityType.file) {
      return File(path).rename(nextPath);
    }
    throw FileSystemException('Path not found', path);
  }

  Future<void> deleteEntity(String path) async {
    final remote = _RemoteVirtualPath.tryParse(path);
    if (remote != null) {
      final entry = await _entryForRemotePath(remote);
      await _remote.clientFor(remote.pluginId).delete(
            remote.innerPath,
            recursive: entry?.isDirectory == true,
          );
      return;
    }
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: true);
      return;
    }
    if (type == FileSystemEntityType.file) {
      await File(path).delete();
      return;
    }
    throw FileSystemException('Path not found', path);
  }

  Future<DirectorySnapshot> _listRemoteDirectory(
      _RemoteVirtualPath remote) async {
    try {
      final client = _remote.clientFor(remote.pluginId);
      final entries = <ExplorerEntry>[];
      if (remote.innerPath != '/') {
        entries.add(
          ExplorerEntry(
            name: '...',
            path: _RemoteVirtualPath.build(
              remote.pluginId,
              _remoteParent(remote.innerPath),
            ),
            kind: ExplorerEntryKind.directory,
            sizeBytes: 0,
            modifiedAt: DateTime.now(),
            isNavigationEntry: true,
          ),
        );
      }
      final remoteEntries = await client.list(remote.innerPath);
      entries.addAll(remoteEntries.map((entry) {
        final path = _RemoteVirtualPath.build(remote.pluginId, entry.path);
        return ExplorerEntry(
          name: entry.name,
          path: path,
          kind: entry.isDirectory
              ? ExplorerEntryKind.directory
              : _kindForFile(entry.name),
          sizeBytes: entry.sizeBytes,
          modifiedAt: entry.modifiedAt,
        );
      }));
      return DirectorySnapshot(path: remote.fullPath, entries: entries);
    } catch (error) {
      return DirectorySnapshot(
        path: remote.fullPath,
        entries: const [],
        error: 'Remote resource could not be opened: $error',
      );
    }
  }

  Future<ExplorerEntry?> _entryForRemotePath(_RemoteVirtualPath remote) async {
    if (!_remote.hasPlugin(remote.pluginId)) return null;
    if (remote.innerPath == '/') {
      return ExplorerEntry(
        name: remote.pluginId,
        path: remote.fullPath,
        kind: ExplorerEntryKind.directory,
        sizeBytes: 0,
        modifiedAt: DateTime.now(),
      );
    }
    final stat =
        await _remote.clientFor(remote.pluginId).stat(remote.innerPath);
    if (stat == null || !stat.exists) return null;
    return ExplorerEntry(
      name: _remoteBasename(remote.innerPath),
      path: remote.fullPath,
      kind: stat.isDirectory
          ? ExplorerEntryKind.directory
          : _kindForFile(_remoteBasename(remote.innerPath)),
      sizeBytes: stat.sizeBytes,
      modifiedAt: stat.modifiedAt,
    );
  }

  Future<FilePreview> _previewRemoteFile(_RemoteVirtualPath remote) async {
    final name = _remoteBasename(remote.innerPath);
    final bytes = await _remote.clientFor(remote.pluginId).readBytes(
          remote.innerPath,
        );
    return FileViewerService.previewBytes(
      name: name,
      subtitle: 'Remote file, ${bytes.length} bytes',
      bytes: bytes,
      sourcePath: remote.fullPath,
    );
  }

  Future<DirectorySnapshot> _listTorrentDirectory(
      _TorrentVirtualPath torrent) async {
    try {
      final metadata = await _torrents.readMetadata(torrent.torrentPath);
      final prefix = torrent.innerPath.isEmpty ? '' : '${torrent.innerPath}/';
      final directories = <String, int>{};
      final files = <TorrentFileEntry>[];
      for (final file in metadata.files) {
        if (!file.path.startsWith(prefix)) continue;
        final rest = file.path.substring(prefix.length);
        if (rest.isEmpty) continue;
        final slash = rest.indexOf('/');
        if (slash >= 0) {
          directories[rest.substring(0, slash)] =
              (directories[rest.substring(0, slash)] ?? 0) + file.sizeBytes;
        } else {
          files.add(file);
        }
      }
      final entries = <ExplorerEntry>[];
      for (final directory in directories.entries) {
        entries.add(ExplorerEntry(
          name: directory.key,
          path: _TorrentVirtualPath.build(
            torrent.torrentPath,
            _joinZipPath(torrent.innerPath, directory.key),
          ),
          kind: ExplorerEntryKind.directory,
          sizeBytes: directory.value,
          modifiedAt: DateTime.now(),
        ));
      }
      for (final file in files) {
        final local = await _torrents.downloadedFile(metadata, file);
        final localExists = await local.exists();
        final stat = localExists ? await local.stat() : null;
        entries.add(ExplorerEntry(
          name: _zipBasename(file.path),
          path: _TorrentVirtualPath.build(torrent.torrentPath, file.path),
          kind: _kindForFile(file.path),
          sizeBytes: file.sizeBytes,
          modifiedAt: stat?.modified ?? DateTime.now(),
          exists: true,
        ));
      }
      entries.sort((a, b) {
        if (a.isNavigationEntry != b.isNavigationEntry) {
          return a.isNavigationEntry ? -1 : 1;
        }
        if (a.isDirectory != b.isDirectory) {
          return a.isDirectory ? -1 : 1;
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      return DirectorySnapshot(path: torrent.fullPath, entries: entries);
    } catch (error) {
      return DirectorySnapshot(
        path: torrent.fullPath,
        entries: const [],
        error: 'Torrent could not be opened: $error',
      );
    }
  }

  Future<ExplorerEntry?> _entryForTorrentPath(
      _TorrentVirtualPath torrent) async {
    if (!await File(torrent.torrentPath).exists()) return null;
    final metadata = await _torrents.readMetadata(torrent.torrentPath);
    if (torrent.innerPath.isEmpty) {
      return ExplorerEntry(
        name: metadata.name,
        path: torrent.fullPath,
        kind: ExplorerEntryKind.directory,
        sizeBytes: metadata.totalSize,
        modifiedAt: (await File(torrent.torrentPath).stat()).modified,
      );
    }
    TorrentFileEntry? exact;
    for (final file in metadata.files) {
      if (file.path == torrent.innerPath) {
        exact = file;
        break;
      }
    }
    if (exact != null) {
      final local = await _torrents.downloadedFile(metadata, exact);
      final localExists = await local.exists();
      final stat = localExists ? await local.stat() : null;
      return ExplorerEntry(
        name: _zipBasename(exact.path),
        path: torrent.fullPath,
        kind: _kindForFile(exact.path),
        sizeBytes: exact.sizeBytes,
        modifiedAt: stat?.modified ?? DateTime.now(),
        exists: true,
      );
    }
    final prefix = '${torrent.innerPath}/';
    final hasChildren =
        metadata.files.any((file) => file.path.startsWith(prefix));
    if (!hasChildren) return null;
    return ExplorerEntry(
      name: _zipBasename(torrent.innerPath),
      path: torrent.fullPath,
      kind: ExplorerEntryKind.directory,
      sizeBytes: 0,
      modifiedAt: DateTime.now(),
    );
  }

  Future<FilePreview> _previewTorrentFile(_TorrentVirtualPath torrent) async {
    final metadata = await _torrents.readMetadata(torrent.torrentPath);
    TorrentFileEntry? file;
    for (final item in metadata.files) {
      if (item.path == torrent.innerPath) {
        file = item;
        break;
      }
    }
    if (file == null) {
      return FilePreview(
        title: _zipBasename(torrent.innerPath),
        subtitle: 'Torrent entry is not a file.',
        sourcePath: torrent.fullPath,
      );
    }
    final kind = FileViewerService.kindForName(file.name);
    if (kind == FileContentKind.audio || kind == FileContentKind.video) {
      final streamUri = await _torrents.streamingUri(metadata, file);
      return FilePreview(
        title: file.name,
        subtitle:
            'Torrent stream, ${(file.sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB',
        sourcePath: streamUri.toString(),
        text:
            'SecureVault streams this torrent entry through a local range server. '
            'The torrent engine starts when playback requests the URL.',
        contentKind: kind,
      );
    }
    final local = await _torrents.downloadedFile(metadata, file);
    var localReady = false;
    if (await local.exists()) {
      localReady = (await local.length().catchError((_) => 0)) > 0;
    }
    if (!localReady) {
      final streaming = await _torrents.prepareStreamingFile(metadata, file);
      if (streaming != null && await streaming.exists()) {
        return FileViewerService.previewPlainFile(streaming);
      }
      return FilePreview(
        title: file.name,
        subtitle:
            'Torrent streaming was requested, but no local pieces are available yet.',
        sourcePath: torrent.fullPath,
        text:
            'SecureVault started aria2c in background when available. Open this file again after the first pieces are downloaded.',
        contentKind: FileViewerService.kindForName(file.name),
      );
    }
    return FileViewerService.previewPlainFile(local);
  }

  Future<DirectorySnapshot> _listZipDirectory(_ZipVirtualPath zip) async {
    final archiveFile = File(zip.archivePath);
    if (!await archiveFile.exists()) {
      return DirectorySnapshot(
        path: zip.fullPath,
        entries: const [],
        error: 'ZIP archive not found.',
      );
    }
    try {
      final archive = ZipDecoder().decodeBytes(
        await archiveFile.readAsBytes(),
        verify: false,
      );
      final prefix = zip.innerPath.isEmpty ? '' : '${zip.innerPath}/';
      final directories = <String, DateTime>{};
      final files = <String, ArchiveFile>{};
      for (final item in archive.files) {
        final name = _normalizeZipEntryName(item.name);
        if (name.isEmpty || !name.startsWith(prefix)) continue;
        final rest = name.substring(prefix.length);
        if (rest.isEmpty) continue;
        final slash = rest.indexOf('/');
        if (slash >= 0) {
          final dir = rest.substring(0, slash);
          if (dir.isNotEmpty) {
            directories[dir] = item.lastModDateTime;
          }
          continue;
        }
        if (item.isFile) {
          files[rest] = item;
        } else {
          directories[rest] = item.lastModDateTime;
        }
      }

      final entries = <ExplorerEntry>[];
      entries.add(
        ExplorerEntry(
          name: '...',
          path: zip.innerPath.isEmpty
              ? archiveFile.parent.path
              : _ZipVirtualPath.build(
                  zip.archivePath,
                  zip.innerPath.split('/')..removeLast(),
                ),
          kind: ExplorerEntryKind.directory,
          sizeBytes: 0,
          modifiedAt: DateTime.now(),
          isNavigationEntry: true,
        ),
      );
      for (final item in directories.entries) {
        entries.add(
          ExplorerEntry(
            name: item.key,
            path: _ZipVirtualPath.build(
              zip.archivePath,
              _joinZipPath(zip.innerPath, item.key),
            ),
            kind: ExplorerEntryKind.directory,
            sizeBytes: 0,
            modifiedAt: item.value,
          ),
        );
      }
      for (final item in files.entries) {
        final file = item.value;
        entries.add(
          ExplorerEntry(
            name: item.key,
            path: _ZipVirtualPath.build(
              zip.archivePath,
              _joinZipPath(zip.innerPath, item.key),
            ),
            kind: _kindForFile(item.key),
            sizeBytes: file.size,
            modifiedAt: file.lastModDateTime,
          ),
        );
      }
      entries.sort((a, b) {
        if (a.isNavigationEntry != b.isNavigationEntry) {
          return a.isNavigationEntry ? -1 : 1;
        }
        if (a.isDirectory != b.isDirectory) {
          return a.isDirectory ? -1 : 1;
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      return DirectorySnapshot(path: zip.fullPath, entries: entries);
    } catch (error) {
      return DirectorySnapshot(
        path: zip.fullPath,
        entries: const [],
        error: 'ZIP archive could not be opened: $error',
      );
    }
  }

  Future<ExplorerEntry?> _entryForZipPath(_ZipVirtualPath zip) async {
    if (!await File(zip.archivePath).exists()) return null;
    if (zip.innerPath.isEmpty) {
      final stat = await File(zip.archivePath).stat();
      return ExplorerEntry(
        name: basename(zip.archivePath),
        path: zip.fullPath,
        kind: ExplorerEntryKind.directory,
        sizeBytes: stat.size,
        modifiedAt: stat.modified,
      );
    }
    final archive = ZipDecoder().decodeBytes(
      await File(zip.archivePath).readAsBytes(),
      verify: false,
    );
    final normalized = _normalizeZipEntryName(zip.innerPath);
    final file = archive.findFile(normalized);
    if (file != null) {
      return ExplorerEntry(
        name: _zipBasename(normalized),
        path: zip.fullPath,
        kind: file.isFile
            ? _kindForFile(_zipBasename(normalized))
            : ExplorerEntryKind.directory,
        sizeBytes: file.isFile ? file.size : 0,
        modifiedAt: file.lastModDateTime,
      );
    }
    final prefix = normalized.endsWith('/') ? normalized : '$normalized/';
    final hasChildren = archive.files.any(
      (item) => _normalizeZipEntryName(item.name).startsWith(prefix),
    );
    if (!hasChildren) return null;
    return ExplorerEntry(
      name: _zipBasename(normalized),
      path: zip.fullPath,
      kind: ExplorerEntryKind.directory,
      sizeBytes: 0,
      modifiedAt: DateTime.now(),
    );
  }

  Future<FilePreview> _previewZipFile(_ZipVirtualPath zip) async {
    final archive = ZipDecoder().decodeBytes(
      await File(zip.archivePath).readAsBytes(),
      verify: false,
    );
    final file = archive.findFile(_normalizeZipEntryName(zip.innerPath));
    if (file == null || !file.isFile) {
      return FilePreview(
        title: _zipBasename(zip.innerPath),
        subtitle: 'ZIP entry is not a file.',
        sourcePath: zip.fullPath,
      );
    }
    final bytes = file.readBytes() ?? Uint8List(0);
    return FileViewerService.previewBytes(
      name: _zipBasename(file.name),
      subtitle: 'ZIP entry, ${bytes.length} bytes',
      bytes: bytes,
      sourcePath: zip.fullPath,
    );
  }

  Future<DirectorySnapshot> _listRarDirectory(_RarVirtualPath rar) async {
    final archiveFile = File(rar.archivePath);
    if (!await archiveFile.exists()) {
      return DirectorySnapshot(
        path: rar.fullPath,
        entries: const [],
        error: 'RAR archive not found.',
      );
    }
    try {
      final archiveEntries = await _rarEntries(rar.archivePath);
      final prefix = rar.innerPath.isEmpty ? '' : '${rar.innerPath}/';
      final directories = <String, DateTime>{};
      final files = <String, _RarArchiveEntry>{};
      for (final item in archiveEntries) {
        final name = _normalizeZipEntryName(item.name);
        if (name.isEmpty || !name.startsWith(prefix)) continue;
        final rest = name.substring(prefix.length);
        if (rest.isEmpty) continue;
        final slash = rest.indexOf('/');
        if (slash >= 0) {
          final dir = rest.substring(0, slash);
          if (dir.isNotEmpty) directories[dir] = item.modifiedAt;
          continue;
        }
        if (item.isDirectory) {
          directories[rest] = item.modifiedAt;
        } else {
          files[rest] = item;
        }
      }

      final entries = <ExplorerEntry>[
        ExplorerEntry(
          name: '...',
          path: rar.innerPath.isEmpty
              ? archiveFile.parent.path
              : _RarVirtualPath.build(
                  rar.archivePath,
                  rar.innerPath.split('/')..removeLast(),
                ),
          kind: ExplorerEntryKind.directory,
          sizeBytes: 0,
          modifiedAt: DateTime.now(),
          isNavigationEntry: true,
        ),
      ];
      for (final item in directories.entries) {
        entries.add(
          ExplorerEntry(
            name: item.key,
            path: _RarVirtualPath.build(
              rar.archivePath,
              _joinZipPath(rar.innerPath, item.key),
            ),
            kind: ExplorerEntryKind.directory,
            sizeBytes: 0,
            modifiedAt: item.value,
          ),
        );
      }
      for (final item in files.entries) {
        entries.add(
          ExplorerEntry(
            name: item.key,
            path: _RarVirtualPath.build(
              rar.archivePath,
              _joinZipPath(rar.innerPath, item.key),
            ),
            kind: _kindForFile(item.key),
            sizeBytes: item.value.sizeBytes,
            modifiedAt: item.value.modifiedAt,
          ),
        );
      }
      entries.sort((a, b) {
        if (a.isNavigationEntry != b.isNavigationEntry) {
          return a.isNavigationEntry ? -1 : 1;
        }
        if (a.isDirectory != b.isDirectory) {
          return a.isDirectory ? -1 : 1;
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      return DirectorySnapshot(path: rar.fullPath, entries: entries);
    } catch (error) {
      return DirectorySnapshot(
        path: rar.fullPath,
        entries: const [],
        error: 'RAR archive could not be opened: $error',
      );
    }
  }

  Future<FilePreview> _previewRarFile(_RarVirtualPath rar) async {
    try {
      final bytes = await _rarEntryBytes(rar.archivePath, rar.innerPath);
      return FileViewerService.previewBytes(
        name: _zipBasename(rar.innerPath),
        subtitle: 'RAR entry, ${bytes.length} bytes',
        bytes: bytes,
        sourcePath: rar.fullPath,
      );
    } catch (error) {
      return FilePreview(
        title: _zipBasename(rar.innerPath),
        subtitle: 'RAR entry could not be read: $error',
        sourcePath: rar.fullPath,
      );
    }
  }

  Future<List<_RarArchiveEntry>> _rarEntries(String archivePath) async {
    if (Platform.isAndroid) {
      final result = await rar_plugin.Rar.listRarContents(
        rarFilePath: archivePath,
      );
      if (result['success'] != true) {
        throw FileSystemException(
          result['message']?.toString() ?? 'RAR listing failed.',
          archivePath,
        );
      }
      final files = result['files'];
      return files is List
          ? files
              .map((item) => _RarArchiveEntry(
                    name: item.toString(),
                    sizeBytes: 0,
                    modifiedAt: DateTime.now(),
                    isDirectory: item.toString().endsWith('/') ||
                        item.toString().endsWith('\\'),
                  ))
              .toList()
          : const <_RarArchiveEntry>[];
    }
    return _rarCliEntries(archivePath);
  }

  Future<Uint8List> _rarEntryBytes(String archivePath, String innerPath) async {
    final normalized = _normalizeZipEntryName(innerPath);
    if (Platform.isAndroid) {
      final temp = await Directory.systemTemp.createTemp('securevault_rar_');
      try {
        final result = await rar_plugin.Rar.extractRarFile(
          rarFilePath: archivePath,
          destinationPath: temp.path,
        );
        if (result['success'] != true) {
          throw FileSystemException(
            result['message']?.toString() ?? 'RAR extraction failed.',
            archivePath,
          );
        }
        final file = File(
          '${temp.path}${Platform.pathSeparator}'
          '${normalized.split('/').join(Platform.pathSeparator)}',
        );
        return await file.readAsBytes();
      } finally {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      }
    }
    final temp = await Directory.systemTemp.createTemp('securevault_rar_');
    try {
      await _runRarCliExtract(
        archivePath: archivePath,
        outputDirectory: temp.path,
        innerPath: normalized,
      );
      final file = File(
        '${temp.path}${Platform.pathSeparator}'
        '${normalized.split('/').join(Platform.pathSeparator)}',
      );
      return await file.readAsBytes();
    } finally {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    }
  }

  Future<List<_RarArchiveEntry>> _rarCliEntries(String archivePath) async {
    final tool = await _rarCliTool();
    if (tool.kind == _RarCliKind.sevenZip) {
      final result = await Process.run(
        tool.path,
        ['l', '-slt', archivePath],
        runInShell: false,
      );
      if (result.exitCode != 0) {
        throw StateError('${result.stdout}\n${result.stderr}'.trim());
      }
      return _parseSevenZipList(result.stdout.toString());
    }
    final result = await Process.run(
      tool.path,
      ['lb', archivePath],
      runInShell: false,
    );
    if (result.exitCode != 0) {
      throw StateError('${result.stdout}\n${result.stderr}'.trim());
    }
    return result.stdout
        .toString()
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .map((name) => _RarArchiveEntry(
              name: name,
              sizeBytes: 0,
              modifiedAt: DateTime.now(),
              isDirectory: name.endsWith('/') || name.endsWith('\\'),
            ))
        .toList();
  }

  Future<void> _runRarCliExtract({
    required String archivePath,
    required String outputDirectory,
    String? innerPath,
  }) async {
    final tool = await _rarCliTool();
    final args = tool.kind == _RarCliKind.sevenZip
        ? [
            'x',
            '-y',
            '-o$outputDirectory',
            archivePath,
            if (innerPath != null) innerPath,
          ]
        : [
            'x',
            '-y',
            archivePath,
            if (innerPath != null) innerPath,
            outputDirectory,
          ];
    final result = await Process.run(tool.path, args, runInShell: false);
    if (result.exitCode != 0) {
      throw StateError('${result.stdout}\n${result.stderr}'.trim());
    }
  }

  List<_RarArchiveEntry> _parseSevenZipList(String output) {
    final entries = <_RarArchiveEntry>[];
    final blocks = output.split(RegExp(r'\r?\n\r?\n'));
    for (final block in blocks) {
      final values = <String, String>{};
      for (final line in block.split(RegExp(r'\r?\n'))) {
        final index = line.indexOf(' = ');
        if (index <= 0) continue;
        values[line.substring(0, index).trim()] = line.substring(index + 3);
      }
      final path = values['Path']?.trim();
      if (path == null ||
          path.isEmpty ||
          path == values['Physical Size'] ||
          path.toLowerCase().endsWith('.rar')) {
        continue;
      }
      final attributes = values['Attributes'] ?? '';
      final modified = DateTime.tryParse(
            (values['Modified'] ?? '').replaceFirst(' ', 'T'),
          ) ??
          DateTime.now();
      entries.add(_RarArchiveEntry(
        name: path.replaceAll('\\', '/'),
        sizeBytes: int.tryParse(values['Size'] ?? '') ?? 0,
        modifiedAt: modified,
        isDirectory: attributes.contains('D') ||
            path.endsWith('/') ||
            path.endsWith('\\'),
      ));
    }
    return entries;
  }

  Future<_RarCliTool> _rarCliTool() async {
    final pluginsDir = await AppPaths.pluginsDirectory();
    final exeNames = Platform.isWindows
        ? ['7z.exe', '7za.exe', 'unrar.exe', 'rar.exe']
        : ['7z', '7za', 'unrar', 'rar'];
    final componentDirs = <Directory>[
      Directory(
        '${pluginsDir.path}${Platform.pathSeparator}rar_archive_support'
        '${Platform.pathSeparator}components${Platform.pathSeparator}7zip'
        '${Platform.pathSeparator}${Platform.isWindows ? 'windows-x64' : Platform.operatingSystem}',
      ),
      Directory(
        '${pluginsDir.path}${Platform.pathSeparator}rar_archive_support'
        '${Platform.pathSeparator}components${Platform.pathSeparator}unrar'
        '${Platform.pathSeparator}${Platform.isWindows ? 'windows-x64' : Platform.operatingSystem}',
      ),
    ];
    for (final dir in componentDirs) {
      for (final name in exeNames) {
        final file = File('${dir.path}${Platform.pathSeparator}$name');
        if (await file.exists()) {
          return _RarCliTool(file.path, _rarCliKindForName(name));
        }
      }
    }
    for (final name in exeNames) {
      if (await _commandAvailable(name)) {
        return _RarCliTool(name, _rarCliKindForName(name));
      }
    }
    throw StateError(
      'RAR CLI not found. Put 7z/7za/unrar into plugins/rar_archive_support/components or add it to PATH.',
    );
  }

  _RarCliKind _rarCliKindForName(String name) =>
      name.toLowerCase().startsWith('7z')
          ? _RarCliKind.sevenZip
          : _RarCliKind.unrar;

  Future<bool> _commandAvailable(String command) async {
    try {
      final result = await Process.run(
        Platform.isWindows ? 'where' : 'which',
        [command],
        runInShell: true,
      ).timeout(const Duration(seconds: 2));
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<String> _folderDisplayName(
    Directory directory, {
    String? commonPassword,
    String? filePassword,
  }) async {
    final name = basename(directory.path);
    if (name == 'hidden_vault') {
      return 'Скрытое хранилище программы';
    }
    final password = filePassword?.isNotEmpty == true
        ? filePassword
        : commonPassword?.isNotEmpty == true
            ? commonPassword
            : null;
    if (password == null) return name;
    return await _decryptFolderName(directory, password: password)
            .catchError((_) => null) ??
        name;
  }

  Future<String?> _decryptFolderName(
    Directory directory, {
    required String password,
  }) async {
    final metaFile =
        File('${directory.path}${Platform.pathSeparator}$_folderMetaFileName');
    if (!await metaFile.exists()) return null;
    final decoded = jsonDecode(await metaFile.readAsString());
    if (decoded is! Map<String, Object?>) return null;
    final envelope = decoded['folderNameEnvelope'];
    if (envelope is! Map) return null;
    final clear = await VaultCrypto.decryptTextEnvelope(
      envelope.map((key, value) => MapEntry(key.toString(), value)),
      password: password,
    );
    final json = jsonDecode(clear);
    if (json is! Map<String, Object?>) return null;
    return json['name'] as String?;
  }

  Future<void> _addDirectoryToZipArchive(
    Archive archive,
    Directory source, {
    required String rootName,
  }) async {
    await for (final entity
        in source.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = entity.path
          .substring(source.path.length)
          .replaceFirst(RegExp(r'^[\\/]+'), '')
          .replaceAll('\\', '/');
      if (relative.isEmpty) continue;
      final stat = await entity.stat();
      final archiveFile = ArchiveFile(
        '$rootName/$relative',
        stat.size,
        await entity.readAsBytes(),
      )..lastModTime = stat.modified.millisecondsSinceEpoch ~/ 1000;
      archive.addFile(archiveFile);
    }
  }

  String _normalizeZipEntryName(String name) => name
      .replaceAll('\\', '/')
      .split('/')
      .where((part) => part.isNotEmpty && part != '..')
      .join('/');

  String _joinZipPath(String base, String child) {
    final cleanBase = _normalizeZipEntryName(base);
    final cleanChild = _normalizeZipEntryName(child);
    if (cleanBase.isEmpty) return cleanChild;
    if (cleanChild.isEmpty) return cleanBase;
    return '$cleanBase/$cleanChild';
  }

  String _zipBasename(String path) {
    final normalized = _normalizeZipEntryName(path);
    if (normalized.isEmpty) return basename(path);
    return normalized.split('/').last;
  }

  String _zipParent(String path) {
    final normalized = _normalizeZipEntryName(path);
    if (normalized.isEmpty) return '';
    final parts = normalized.split('/');
    if (parts.length <= 1) return '';
    parts.removeLast();
    return parts.join('/');
  }

  ExplorerEntryKind _kindForFile(String name) {
    if (name == _folderMetaFileName) {
      return ExplorerEntryKind.folderMeta;
    }
    if (RegExp(r'^f_[0-9a-f]{32}\.crypt$').hasMatch(name) ||
        name.endsWith('.crypt')) {
      return ExplorerEntryKind.encryptedFile;
    }
    return ExplorerEntryKind.file;
  }

  Future<VaultContainerInfo?> _inspectContainer(
      File file, ExplorerEntryKind kind) async {
    try {
      if (kind == ExplorerEntryKind.encryptedFile) {
        return await _inspectFileContainerHeader(file);
      }
      final bytes = await file.readAsBytes();
      return kind == ExplorerEntryKind.folderMeta
          ? _bindings.inspectFolderMeta(bytes)
          : _bindings.inspectFileContainer(bytes);
    } catch (_) {
      return null;
    }
  }

  Future<VaultContainerInfo?> _inspectFileContainerHeader(File file) async {
    final stat = await file.stat();
    final data = await _readCryptHeaderBytes(file);
    if (data.length < _fileContainerFixedSize) return null;
    final layout = _readCryptPayloadLayout(data);
    return VaultContainerInfo(
      statusCode: 0,
      containerType: _readU16(data, 8),
      formatMajor: _readU16(data, 10),
      formatMinor: _readU16(data, 12),
      headerSize: _readU16(data, 14),
      extensionCount: _readU16(data, 16),
      flags: _readU32(data, 18),
      chunkSize: _readU32(data, 98),
      originalSize: _readU64(data, 74),
      storedSize: _readU64(data, 82),
      encryptedHeaderLength: layout.encryptedHeaderLength,
      encryptedPayloadLength: math.max(
          0, stat.size - layout.payloadOffset - layout.encryptedHeaderLength),
    );
  }

  Future<_OpenedCryptFile> _decryptAppCrypt(List<int> bytes,
      {required String password}) async {
    if (bytes.length < _fileContainerFixedSize) {
      throw const FormatException('Файл меньше фиксированного заголовка.');
    }
    final data = Uint8List.fromList(bytes);
    final layout = _readCryptPayloadLayout(data);
    final params = layout.params;
    var offset = layout.payloadOffset;
    final encryptedHeaderLength = layout.encryptedHeaderLength;
    if (params['schema'] != 'securevault.fileCrypto.v1') {
      throw const FormatException(
          'Это legacy/demo контейнер без app crypto параметров.');
    }
    final saltText = params['salt'] as String?;
    final algorithm =
        params['cipher'] as String? ?? EncryptionAlgorithm.xchacha20Poly1305;
    if (saltText == null) {
      throw const FormatException('Нет соли KDF.');
    }
    if (offset + encryptedHeaderLength > data.length) {
      throw const FormatException('Зашифрованный заголовок обрывается.');
    }
    final encryptedHeader =
        data.sublist(offset, offset + encryptedHeaderLength);
    offset += encryptedHeaderLength;
    final encryptedPayload = data.sublist(offset);
    final salt = base64Url.decode(saltText);
    final key = await VaultCrypto.deriveKey(password, salt);

    final headerJsonBytes = await VaultCrypto.decryptBytesWithKey(
      encryptedHeader,
      key: key,
      aad: utf8.encode('securevault.file.header.v1'),
      algorithm: algorithm,
    );
    final headerJson = jsonDecode(utf8.decode(headerJsonBytes));
    if (headerJson is! Map<String, Object?>) {
      throw const FormatException('Заголовок не является JSON.');
    }
    final name = headerJson['name'] as String? ?? 'decrypted-file.bin';
    final payload = params['payloadEncoding'] == 'chunked-v1'
        ? await _decryptChunkedPayload(
            encryptedPayload,
            key: key,
            name: name,
            algorithm: algorithm,
          )
        : await VaultCrypto.decryptBytesWithKey(
            encryptedPayload,
            key: key,
            aad: utf8.encode('securevault.file.payload.v1:$name'),
            algorithm: algorithm,
          );
    return _OpenedCryptFile(name: name, payload: payload);
  }

  Future<Uint8List> _decryptChunkedPayload(
    Uint8List encryptedPayload, {
    required SecretKey key,
    required String name,
    required String algorithm,
  }) async {
    final out = BytesBuilder(copy: false);
    var offset = 0;
    var chunkIndex = 0;
    while (offset < encryptedPayload.length) {
      if (offset + 4 > encryptedPayload.length) {
        throw const FormatException('Chunked payload length is truncated.');
      }
      final chunkLength = _readU32(encryptedPayload, offset);
      offset += 4;
      if (offset + chunkLength > encryptedPayload.length) {
        throw const FormatException('Chunked payload chunk is truncated.');
      }
      final encryptedChunk =
          encryptedPayload.sublist(offset, offset + chunkLength);
      offset += chunkLength;
      final clearChunk = await VaultCrypto.decryptBytesWithKey(
        encryptedChunk,
        key: key,
        aad: utf8.encode(
          'securevault.file.payload.chunk.v1:$name:$chunkIndex',
        ),
        algorithm: algorithm,
      );
      out.add(clearChunk);
      chunkIndex++;
      await Future<void>.delayed(Duration.zero);
    }
    return out.takeBytes();
  }

  Future<String> _decryptAppCryptName(List<int> bytes,
      {required String password}) async {
    final data = Uint8List.fromList(bytes);
    final layout = _readCryptPayloadLayout(data);
    final params = layout.params;
    if (params['schema'] != 'securevault.fileCrypto.v1') {
      throw const FormatException('Legacy container.');
    }
    final saltText = params['salt'] as String?;
    if (saltText == null) {
      throw const FormatException('Missing salt.');
    }
    final algorithm =
        params['cipher'] as String? ?? EncryptionAlgorithm.xchacha20Poly1305;
    final encryptedHeader = data.sublist(
      layout.payloadOffset,
      layout.payloadOffset + layout.encryptedHeaderLength,
    );
    final headerJsonBytes = await VaultCrypto.decryptBytesWithKey(
      encryptedHeader,
      key: await VaultCrypto.deriveKey(password, base64Url.decode(saltText)),
      aad: utf8.encode('securevault.file.header.v1'),
      algorithm: algorithm,
    );
    final headerJson = jsonDecode(utf8.decode(headerJsonBytes));
    if (headerJson is! Map<String, Object?>) {
      throw const FormatException('Invalid header.');
    }
    return headerJson['name'] as String? ?? 'decrypted-file.bin';
  }

  Future<String?> _passwordForAutoName(
    File file, {
    String? commonPassword,
    String? filePassword,
  }) async {
    final params = await encryptedFileParameters(file.path);
    if (params == null) return null;
    if (params.usesCommonKey &&
        commonPassword != null &&
        commonPassword.isNotEmpty) {
      return commonPassword;
    }
    if (!params.usesCommonKey &&
        filePassword != null &&
        filePassword.isNotEmpty) {
      return filePassword;
    }
    return null;
  }

  List<RegExp> _exclusionRules(String raw) => raw
          .split(RegExp(r'[\r\n]+'))
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .map((line) {
        final escaped = RegExp.escape(line).replaceAll(r'\*', '.*');
        return RegExp('^$escaped\$', caseSensitive: false);
      }).toList();

  bool _isExcluded(String path, String name, List<RegExp> rules) {
    final normalized = path.replaceAll('\\', '/');
    return rules
        .any((rule) => rule.hasMatch(name) || rule.hasMatch(normalized));
  }

  EncryptedFileParameters? _readCryptParameters(List<int> bytes) {
    try {
      final data = Uint8List.fromList(bytes);
      final params = _readCryptPayloadLayout(data).params;
      final keyModeText = params['keyMode'] as String? ?? 'unique';
      final keyMode = keyModeText == EncryptionKeyMode.common.name
          ? EncryptionKeyMode.common
          : EncryptionKeyMode.unique;
      return EncryptedFileParameters(
        keyMode: keyMode,
        algorithm: params['cipher'] as String? ??
            EncryptionAlgorithm.xchacha20Poly1305,
      );
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List> _readCryptHeaderBytes(File file) async {
    RandomAccessFile? raf;
    try {
      raf = await file.open();
      final fixed = await raf.read(_fileContainerFixedSize);
      if (fixed.length < _fileContainerFixedSize) return fixed;
      final fixedData = Uint8List.fromList(fixed);
      final extensionCount = _readU16(fixedData, 16);
      final encryptedHeaderLength = _readU32(fixedData, 102);
      final out = BytesBuilder(copy: false)..add(fixedData);
      for (var i = 0; i < extensionCount; i++) {
        final tlvHeader = await raf.read(4);
        if (tlvHeader.length < 4) break;
        out.add(tlvHeader);
        final tlvData = Uint8List.fromList(tlvHeader);
        final length = _readU16(tlvData, 2);
        if (length > 0) {
          out.add(await raf.read(length));
        }
      }
      if (encryptedHeaderLength > 0) {
        out.add(await raf.read(encryptedHeaderLength));
      }
      return out.takeBytes();
    } finally {
      await raf?.close();
    }
  }

  _CryptPayloadLayout _readCryptPayloadLayout(Uint8List data) {
    if (data.length < _fileContainerFixedSize) {
      throw const FormatException('Файл меньше фиксированного заголовка.');
    }
    final extensionCount = _readU16(data, 16);
    final encryptedHeaderLength = _readU32(data, 102);
    var offset = _fileContainerFixedSize;
    Map<String, Object?>? params;
    for (var i = 0; i < extensionCount; i++) {
      if (offset + 4 > data.length) {
        throw const FormatException('TLV обрывается.');
      }
      final tag = _readU16(data, offset);
      final length = _readU16(data, offset + 2);
      offset += 4;
      if (offset + length > data.length) {
        throw const FormatException('TLV выходит за границы файла.');
      }
      if (tag == _fileParamsTlvTag) {
        final decoded =
            jsonDecode(utf8.decode(data.sublist(offset, offset + length)));
        if (decoded is Map<String, Object?>) {
          params = decoded;
        }
      }
      offset += length;
    }
    if (params == null) {
      throw const FormatException('Нет app crypto параметров.');
    }
    return _CryptPayloadLayout(
      params: params,
      payloadOffset: offset,
      encryptedHeaderLength: encryptedHeaderLength,
    );
  }

  Uint8List _buildFileContainerBytes({
    required Uint8List fileId,
    required String originalName,
    required int originalSize,
    required int storedSize,
    required Uint8List encryptedHeader,
    required Uint8List encryptedPayload,
    required List<int> tlvValue,
    required int createdAtUtcMs,
    required int updatedAtUtcMs,
  }) {
    final prefix = _buildFileContainerPrefix(
      fileId: fileId,
      originalSize: originalSize,
      storedSize: storedSize,
      encryptedHeader: encryptedHeader,
      tlvValue: tlvValue,
      createdAtUtcMs: createdAtUtcMs,
      updatedAtUtcMs: updatedAtUtcMs,
    );
    final out = BytesBuilder();
    out.add(prefix);
    out.add(encryptedPayload);
    return out.toBytes();
  }

  Uint8List _buildFileContainerPrefix({
    required Uint8List fileId,
    required int originalSize,
    required int storedSize,
    required Uint8List encryptedHeader,
    required List<int> tlvValue,
    required int createdAtUtcMs,
    required int updatedAtUtcMs,
  }) {
    if (tlvValue.length > 0xFFFF) {
      throw StateError('Container TLV is too large: ${tlvValue.length}');
    }
    final out = BytesBuilder();
    out.add(_commonHeader(
        containerType: 1,
        headerSize: _fileContainerFixedSize,
        extensionCount: 1));
    out.add(fileId);
    out.add(Uint8List(16));
    out.add(_u64(createdAtUtcMs));
    out.add(_u64(updatedAtUtcMs));
    out.add(_u64(originalSize));
    out.add(_u64(storedSize));
    out.add(_u16(1));
    out.add(_u16(1));
    out.add(_u16(1));
    out.add(_u16(0));
    out.add(_u32(65536));
    out.add(_u32(encryptedHeader.length));
    final fixed = out.toBytes();
    if (fixed.length != _fileContainerFixedSize) {
      throw StateError('Unexpected .crypt fixed header size: ${fixed.length}');
    }
    out.add(_u16(_fileParamsTlvTag));
    out.add(_u16(tlvValue.length));
    out.add(tlvValue);
    out.add(encryptedHeader);
    return out.toBytes();
  }

  Uint8List _commonHeader({
    required int containerType,
    required int headerSize,
    required int extensionCount,
  }) {
    final out = BytesBuilder();
    out.add('CRYPTFMT'.codeUnits);
    out.add(_u16(containerType));
    out.add(_u16(1));
    out.add(_u16(0));
    out.add(_u16(headerSize));
    out.add(_u16(extensionCount));
    out.add(_u32(0));
    out.add(_u32(0));
    return out.toBytes();
  }

  Future<File> _copyFileToDirectory(File source, Directory targetDir,
      {required String preferredName}) async {
    final target = await _availableFile(targetDir, preferredName);
    return source.copy(target.path);
  }

  Future<File> _availableFile(Directory targetDir, String preferredName) async {
    final dotIndex = preferredName.lastIndexOf('.');
    final stem =
        dotIndex <= 0 ? preferredName : preferredName.substring(0, dotIndex);
    final ext = dotIndex <= 0 ? '' : preferredName.substring(dotIndex);
    var candidate =
        File('${targetDir.path}${Platform.pathSeparator}$preferredName');
    var index = 1;
    while (await candidate.exists()) {
      candidate =
          File('${targetDir.path}${Platform.pathSeparator}$stem-$index$ext');
      index++;
    }
    return candidate;
  }

  Future<Directory> _availableDirectory(
    Directory targetDir,
    String preferredName,
  ) async {
    var candidate =
        Directory('${targetDir.path}${Platform.pathSeparator}$preferredName');
    var index = 1;
    while (await candidate.exists()) {
      candidate = Directory(
          '${targetDir.path}${Platform.pathSeparator}$preferredName-$index');
      index++;
    }
    return candidate;
  }

  Future<void> _copyDirectory(Directory source, Directory target) async {
    await target.create(recursive: true);
    await for (final entity in source.list(followLinks: false)) {
      final name = basename(entity.path);
      final nextPath = '${target.path}${Platform.pathSeparator}$name';
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(nextPath));
      } else if (entity is File) {
        await entity.copy(nextPath);
      }
    }
  }

  Future<bool> _fileContentMatches(
    ExplorerEntry entry,
    _SearchMatcher matcher, {
    String? commonPassword,
    String? filePassword,
  }) async {
    try {
      if (entry.isEncrypted) {
        final preview = await previewFile(
          entry.path,
          password: filePassword,
          commonPassword: commonPassword,
        );
        final text = preview.text;
        return text != null && matcher.matches(text);
      }
      final kind = FileViewerService.kindForName(entry.path);
      if (kind != FileContentKind.text &&
          kind != FileContentKind.html &&
          kind != FileContentKind.ebook &&
          kind != FileContentKind.document) {
        return false;
      }
      final file = File(entry.path);
      if (await file.length() > 2 * 1024 * 1024) {
        if (kind == FileContentKind.ebook || kind == FileContentKind.document) {
          final preview = await FileViewerService.previewPlainFile(file);
          final text = preview.text;
          return text != null && matcher.matches(text);
        }
        return false;
      }
      if (kind == FileContentKind.text || kind == FileContentKind.html) {
        return matcher.matches(await file.readAsString());
      }
      final preview = await FileViewerService.previewPlainFile(file);
      final text = preview.text;
      return text != null && matcher.matches(text);
    } catch (_) {
      return false;
    }
  }

  String _normalizePath(String path) {
    var value = path.replaceAll('\\', '/');
    if (value.length > 1 && value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return Platform.isWindows ? value.toLowerCase() : value;
  }

  String _requirePassword(String? password) {
    if (password == null || password.isEmpty) {
      throw ArgumentError('Для операции с зашифрованным видом нужен пароль.');
    }
    return password;
  }

  int _readU16(Uint8List data, int offset) =>
      ByteData.sublistView(data).getUint16(offset, Endian.little);
  int _readU32(Uint8List data, int offset) =>
      ByteData.sublistView(data).getUint32(offset, Endian.little);
  int _readU64(Uint8List data, int offset) =>
      ByteData.sublistView(data).getUint64(offset, Endian.little);

  Uint8List _u16(int value) {
    final data = ByteData(2)..setUint16(0, value, Endian.little);
    return data.buffer.asUint8List();
  }

  Uint8List _u32(int value) {
    final data = ByteData(4)..setUint32(0, value, Endian.little);
    return data.buffer.asUint8List();
  }

  Uint8List _u64(int value) {
    final data = ByteData(8)..setUint64(0, value, Endian.little);
    return data.buffer.asUint8List();
  }

  String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

class _SearchMatcher {
  _SearchMatcher(String query, {required bool useRegex})
      : _query = query,
        _regex = useRegex && query.isNotEmpty
            ? RegExp(query, caseSensitive: false, multiLine: true)
            : null;

  final String _query;
  final RegExp? _regex;

  bool matches(String value) {
    if (_query.isEmpty) return true;
    final regex = _regex;
    if (regex != null) return regex.hasMatch(value);
    return value.toLowerCase().contains(_query.toLowerCase());
  }
}

class _OpenedCryptFile {
  const _OpenedCryptFile({required this.name, required this.payload});

  final String name;
  final Uint8List payload;
}

class _CryptPayloadLayout {
  const _CryptPayloadLayout({
    required this.params,
    required this.payloadOffset,
    required this.encryptedHeaderLength,
  });

  final Map<String, Object?> params;
  final int payloadOffset;
  final int encryptedHeaderLength;
}

class _RemoteConnectionCheck {
  const _RemoteConnectionCheck(this.status, this.message);

  final ExplorerConnectionStatus status;
  final String? message;
}

class _ZipVirtualPath {
  const _ZipVirtualPath({
    required this.archivePath,
    required this.innerPath,
    required this.fullPath,
  });

  final String archivePath;
  final String innerPath;
  final String fullPath;

  static _ZipVirtualPath? tryParse(String path) {
    if (!path.startsWith(FileExplorerRepository._zipScheme)) return null;
    final rest = path.substring(FileExplorerRepository._zipScheme.length);
    final slash = rest.indexOf('/');
    final encodedArchive = slash < 0 ? rest : rest.substring(0, slash);
    if (encodedArchive.isEmpty) return null;
    try {
      final archivePath = utf8.decode(base64Url.decode(encodedArchive));
      final inner =
          slash < 0 ? '' : Uri.decodeComponent(rest.substring(slash + 1));
      return _ZipVirtualPath(
        archivePath: archivePath,
        innerPath: inner
            .replaceAll('\\', '/')
            .split('/')
            .where((part) => part.isNotEmpty && part != '..')
            .join('/'),
        fullPath: path,
      );
    } catch (_) {
      return null;
    }
  }

  static String build(String archivePath, [Object? innerPath]) {
    final encoded = base64Url.encode(utf8.encode(archivePath));
    final inner = switch (innerPath) {
      null => '',
      List<String> parts => parts
          .where((part) => part.trim().isNotEmpty && part.trim() != '..')
          .join('/'),
      _ => innerPath.toString(),
    }
        .replaceAll('\\', '/')
        .split('/')
        .where((part) => part.isNotEmpty && part != '..')
        .join('/');
    return inner.isEmpty
        ? '${FileExplorerRepository._zipScheme}$encoded'
        : '${FileExplorerRepository._zipScheme}$encoded/${Uri.encodeComponent(inner)}';
  }
}

class _RarVirtualPath {
  const _RarVirtualPath({
    required this.archivePath,
    required this.innerPath,
    required this.fullPath,
  });

  final String archivePath;
  final String innerPath;
  final String fullPath;

  static _RarVirtualPath? tryParse(String path) {
    if (!path.startsWith(FileExplorerRepository._rarScheme)) return null;
    final rest = path.substring(FileExplorerRepository._rarScheme.length);
    final slash = rest.indexOf('/');
    final encodedArchive = slash < 0 ? rest : rest.substring(0, slash);
    if (encodedArchive.isEmpty) return null;
    try {
      final archivePath = utf8.decode(base64Url.decode(encodedArchive));
      final inner =
          slash < 0 ? '' : Uri.decodeComponent(rest.substring(slash + 1));
      return _RarVirtualPath(
        archivePath: archivePath,
        innerPath: inner
            .replaceAll('\\', '/')
            .split('/')
            .where((part) => part.isNotEmpty && part != '..')
            .join('/'),
        fullPath: path,
      );
    } catch (_) {
      return null;
    }
  }

  static String build(String archivePath, [Object? innerPath]) {
    final encoded = base64Url.encode(utf8.encode(archivePath));
    final inner = switch (innerPath) {
      null => '',
      List<String> parts => parts
          .where((part) => part.trim().isNotEmpty && part.trim() != '..')
          .join('/'),
      _ => innerPath.toString(),
    }
        .replaceAll('\\', '/')
        .split('/')
        .where((part) => part.isNotEmpty && part != '..')
        .join('/');
    return inner.isEmpty
        ? '${FileExplorerRepository._rarScheme}$encoded'
        : '${FileExplorerRepository._rarScheme}$encoded/${Uri.encodeComponent(inner)}';
  }
}

class _RarArchiveEntry {
  const _RarArchiveEntry({
    required this.name,
    required this.sizeBytes,
    required this.modifiedAt,
    required this.isDirectory,
  });

  final String name;
  final int sizeBytes;
  final DateTime modifiedAt;
  final bool isDirectory;
}

enum _RarCliKind { sevenZip, unrar }

class _RarCliTool {
  const _RarCliTool(this.path, this.kind);

  final String path;
  final _RarCliKind kind;
}

class _RemoteVirtualPath {
  const _RemoteVirtualPath({
    required this.pluginId,
    required this.innerPath,
    required this.fullPath,
  });

  final String pluginId;
  final String innerPath;
  final String fullPath;

  static _RemoteVirtualPath? tryParse(String path) {
    if (!path.startsWith(FileExplorerRepository._remoteScheme)) return null;
    final rest = path.substring(FileExplorerRepository._remoteScheme.length);
    final slash = rest.indexOf('/');
    final pluginId = slash < 0 ? rest : rest.substring(0, slash);
    if (pluginId.trim().isEmpty) return null;
    final inner =
        slash < 0 ? '/' : Uri.decodeComponent(rest.substring(slash + 1));
    final normalized = _normalizeRemotePath(inner);
    return _RemoteVirtualPath(
      pluginId: pluginId,
      innerPath: normalized,
      fullPath: path,
    );
  }

  static String build(String pluginId, [String innerPath = '/']) {
    final normalized = _normalizeRemotePath(innerPath);
    final encodedInner = Uri.encodeComponent(normalized);
    return '${FileExplorerRepository._remoteScheme}$pluginId/$encodedInner';
  }
}

String _normalizeRemotePath(String value) {
  var normalized = value.replaceAll('\\', '/');
  normalized = normalized
      .split('/')
      .where((part) => part.isNotEmpty && part != '..')
      .join('/');
  return normalized.isEmpty ? '/' : '/$normalized';
}

String _remoteJoin(String parent, String name) {
  final normalizedParent = _normalizeRemotePath(parent);
  final cleanName = name
      .replaceAll('\\', '/')
      .split('/')
      .where((part) => part.isNotEmpty && part != '..')
      .join('/');
  if (cleanName.isEmpty) return normalizedParent;
  if (normalizedParent == '/') return '/$cleanName';
  return '$normalizedParent/$cleanName';
}

String _remoteParent(String path) {
  final normalized = _normalizeRemotePath(path);
  if (normalized == '/') return '/';
  final index = normalized.lastIndexOf('/');
  if (index <= 0) return '/';
  return normalized.substring(0, index);
}

String _remoteBasename(String path) {
  final normalized = _normalizeRemotePath(path);
  if (normalized == '/') return '/';
  return normalized.split('/').last;
}

class _TorrentVirtualPath {
  const _TorrentVirtualPath({
    required this.torrentPath,
    required this.innerPath,
    required this.fullPath,
  });

  final String torrentPath;
  final String innerPath;
  final String fullPath;

  static _TorrentVirtualPath? tryParse(String path) {
    if (!path.startsWith(FileExplorerRepository._torrentScheme)) return null;
    final rest = path.substring(FileExplorerRepository._torrentScheme.length);
    final slash = rest.indexOf('/');
    final encodedTorrent = slash < 0 ? rest : rest.substring(0, slash);
    if (encodedTorrent.isEmpty) return null;
    try {
      final torrentPath = utf8.decode(base64Url.decode(encodedTorrent));
      final inner =
          slash < 0 ? '' : Uri.decodeComponent(rest.substring(slash + 1));
      return _TorrentVirtualPath(
        torrentPath: torrentPath,
        innerPath: inner
            .replaceAll('\\', '/')
            .split('/')
            .where((part) => part.isNotEmpty && part != '..')
            .join('/'),
        fullPath: path,
      );
    } catch (_) {
      return null;
    }
  }

  static String build(String torrentPath, [String innerPath = '']) {
    final encoded = base64Url.encode(utf8.encode(torrentPath));
    final inner = innerPath
        .replaceAll('\\', '/')
        .split('/')
        .where((part) => part.isNotEmpty && part != '..')
        .join('/');
    return inner.isEmpty
        ? '${FileExplorerRepository._torrentScheme}$encoded'
        : '${FileExplorerRepository._torrentScheme}$encoded/${Uri.encodeComponent(inner)}';
  }
}
