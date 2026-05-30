import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../ffi/crypt_bindings.dart';
import '../plugins/cloud_plugin_registry.dart' hide basename;
import '../security/vault_crypto.dart';
import '../storage/app_paths.dart';
import '../viewer/file_viewer_service.dart';
import '../vault/vault_models.dart';
import 'explorer_models.dart';

class FileExplorerRepository {
  FileExplorerRepository(this._bindings);

  final CryptBindings _bindings;

  static const int _fileContainerFixedSize = 106;
  static const int _fileParamsTlvTag = 0x1001;

  Future<List<ExplorerLocation>> loadLocations(
      List<CloudPluginDefinition> plugins) async {
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

    locations.addAll(const <ExplorerLocation>[
      ExplorerLocation(
        id: 'network-smb',
        name: 'SMB ресурс',
        kind: ExplorerLocationKind.network,
        description: 'Подключаемый сетевой провайдер',
        enabled: false,
      ),
      ExplorerLocation(
        id: 'network-ssh',
        name: 'SSH/SCP ресурс',
        kind: ExplorerLocationKind.network,
        description: 'Подключаемый сетевой провайдер',
        enabled: false,
      ),
      ExplorerLocation(
        id: 'network-ftp',
        name: 'FTP ресурс',
        kind: ExplorerLocationKind.network,
        description: 'Подключаемый сетевой провайдер',
        enabled: false,
      ),
      ExplorerLocation(
        id: 'network-sftp',
        name: 'SFTP ресурс',
        kind: ExplorerLocationKind.network,
        description: 'Подключаемый сетевой провайдер',
        enabled: false,
      ),
    ]);

    for (final plugin in plugins) {
      locations.add(
        ExplorerLocation(
          id: 'cloud-${plugin.id}',
          name: plugin.name,
          kind: ExplorerLocationKind.cloudPlugin,
          description: plugin.description ?? 'JSON cloud plugin',
          enabled: false,
          pluginId: plugin.id,
        ),
      );
    }

    return locations;
  }

  Future<DirectorySnapshot> listDirectory(String path) async {
    final directory = Directory(path);
    if (!await directory.exists()) {
      return DirectorySnapshot(
          path: path, entries: const [], error: 'Папка не найдена.');
    }

    final entries = <ExplorerEntry>[];
    try {
      await for (final entity in directory.list(followLinks: false)) {
        final stat = await entity.stat();
        final name = basename(entity.path);
        if (entity is Directory) {
          entries.add(
            ExplorerEntry(
              name: name,
              path: entity.path,
              kind: ExplorerEntryKind.directory,
              sizeBytes: 0,
              modifiedAt: stat.modified,
            ),
          );
          continue;
        }
        if (entity is File) {
          final kind = _kindForFile(name);
          VaultContainerInfo? info;
          if (kind == ExplorerEntryKind.encryptedFile ||
              kind == ExplorerEntryKind.folderMeta) {
            info = await _inspectContainer(entity, kind);
          }
          entries.add(
            ExplorerEntry(
              name: name,
              path: entity.path,
              kind: kind,
              sizeBytes: stat.size,
              modifiedAt: stat.modified,
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
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return DirectorySnapshot(path: path, entries: entries);
  }

  Future<ExplorerEntry?> entryForPath(String path) async {
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

  Future<FilePreview> previewFile(
    String path, {
    String? password,
    String? commonPassword,
  }) async {
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
    return _readCryptParameters(await file.readAsBytes());
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
  }) async {
    final sourceBytes = await source.readAsBytes();
    final sourceStat = await source.stat();
    final salt = VaultCrypto.randomBytes(16);
    final fileId = VaultCrypto.randomBytes(16);
    final fileName = basename(source.path);
    final headerPlain = utf8.encode(jsonEncode(<String, Object?>{
      'schema': 'securevault.fileHeader.v1',
      'name': fileName,
      'originalSize': sourceStat.size,
      'createdAtUtcMs': sourceStat.changed.toUtc().millisecondsSinceEpoch,
      'updatedAtUtcMs': sourceStat.modified.toUtc().millisecondsSinceEpoch,
    }));

    final encryptedHeader = await VaultCrypto.encryptBytes(
      headerPlain,
      password: password,
      salt: salt,
      aad: utf8.encode('securevault.file.header.v1'),
      algorithm: algorithm,
    );
    final encryptedPayload = await VaultCrypto.encryptBytes(
      sourceBytes,
      password: password,
      salt: salt,
      aad: utf8.encode('securevault.file.payload.v1:$fileName'),
      algorithm: algorithm,
    );

    final params = utf8.encode(jsonEncode(<String, Object?>{
      'schema': 'securevault.fileCrypto.v1',
      'kdf': 'argon2id',
      'cipher': algorithm,
      'keyMode': keyMode.name,
      'salt': base64UrlEncode(salt),
      'box': 'nonce+cipherText+mac',
      'nonceLength': VaultCrypto.nonceLengthFor(algorithm),
      'macLength': 16,
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

    final target = await _availableFile(targetDir, 'f_${_hex(fileId)}.crypt');
    await target.writeAsBytes(containerBytes, flush: true);
    return target;
  }

  Future<File> encryptSelectedFile(
    File source,
    EncryptFileOptions options,
  ) async {
    final targetDir = Directory(options.targetDirectory);
    await targetDir.create(recursive: true);
    final encrypted = await encryptFileToDirectory(
      source,
      targetDir,
      password: options.password,
      keyMode: options.mode,
      algorithm: options.algorithm,
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

  ExplorerEntryKind _kindForFile(String name) {
    if (name == '.folder.cryptmeta') {
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
      final bytes = await file.readAsBytes();
      return kind == ExplorerEntryKind.folderMeta
          ? _bindings.inspectFolderMeta(bytes)
          : _bindings.inspectFileContainer(bytes);
    } catch (_) {
      return null;
    }
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

    final headerJsonBytes = await VaultCrypto.decryptBytes(
      encryptedHeader,
      password: password,
      salt: salt,
      aad: utf8.encode('securevault.file.header.v1'),
      algorithm: algorithm,
    );
    final headerJson = jsonDecode(utf8.decode(headerJsonBytes));
    if (headerJson is! Map<String, Object?>) {
      throw const FormatException('Заголовок не является JSON.');
    }
    final name = headerJson['name'] as String? ?? 'decrypted-file.bin';
    final payload = await VaultCrypto.decryptBytes(
      encryptedPayload,
      password: password,
      salt: salt,
      aad: utf8.encode('securevault.file.payload.v1:$name'),
      algorithm: algorithm,
    );
    return _OpenedCryptFile(name: name, payload: payload);
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
    out.add(encryptedPayload);
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
