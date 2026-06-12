import 'dart:io';
import 'dart:typed_data';

import '../ffi/crypt_bindings.dart';
import 'vault_models.dart';

class VaultRepository {
  VaultRepository(this._bindings);

  final CryptBindings _bindings;

  static final RegExp _folderDirPattern = RegExp(r'^d_[0-9a-f]{32}$');
  static final RegExp _filePattern = RegExp(r'^f_[0-9a-f]{32}\.crypt$');

  Future<VaultSnapshot> loadOrCreateDemoVault() async {
    final docsDir = await _applicationDataDirectory();
    final rootDir =
        Directory('${docsDir.path}${Platform.pathSeparator}demo_vault');
    if (!await rootDir.exists()) {
      await rootDir.create(recursive: true);
    }

    await _ensureDemoContent(rootDir);

    final entries = <VaultEntry>[];
    await for (final entity in rootDir.list(followLinks: false)) {
      if (entity is Directory) {
        final name = _basename(entity.path);
        final stat = await entity.stat();
        entries.add(
          VaultEntry(
            kind: _folderDirPattern.hasMatch(name)
                ? VaultEntryKind.folderDirectory
                : VaultEntryKind.unknown,
            name: name,
            logicalLabel: _folderDirPattern.hasMatch(name)
                ? 'Vault folder directory'
                : 'Unknown directory',
            path: entity.path,
            sizeBytes: stat.size,
          ),
        );

        final metaFile =
            File('${entity.path}${Platform.pathSeparator}.folder.cryptmeta');
        if (await metaFile.exists()) {
          final bytes = await metaFile.readAsBytes();
          entries.add(
            VaultEntry(
              kind: VaultEntryKind.folderMeta,
              name: '.folder.cryptmeta',
              logicalLabel: 'Encrypted folder metadata',
              path: metaFile.path,
              sizeBytes: bytes.length,
              containerInfo: await _bindings.inspectFolderMeta(bytes),
            ),
          );
        }
        continue;
      }

      if (entity is File) {
        final name = _basename(entity.path);
        final bytes = await entity.readAsBytes();
        entries.add(
          VaultEntry(
            kind: _filePattern.hasMatch(name)
                ? VaultEntryKind.fileContainer
                : VaultEntryKind.unknown,
            name: name,
            logicalLabel: _filePattern.hasMatch(name)
                ? 'Encrypted file container'
                : 'Unknown file',
            path: entity.path,
            sizeBytes: bytes.length,
            containerInfo: _filePattern.hasMatch(name)
                ? await _bindings.inspectFileContainer(bytes)
                : null,
          ),
        );
      }
    }

    entries.sort((a, b) => a.path.compareTo(b.path));
    return VaultSnapshot(rootPath: rootDir.path, entries: entries);
  }

  Future<Directory> _applicationDataDirectory() async {
    final basePath = switch (Platform.operatingSystem) {
      'android' => '/data/user/0/com.filesmanagers.app/files',
      'windows' =>
        _firstEnvironmentPath(['APPDATA', 'LOCALAPPDATA', 'USERPROFILE']),
      'linux' => _linuxDataPath(),
      _ => Directory.systemTemp.path,
    };
    final dir = Directory('$basePath${Platform.pathSeparator}filesmanagers');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String _firstEnvironmentPath(List<String> keys) {
    for (final key in keys) {
      final value = Platform.environment[key];
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    return Directory.systemTemp.path;
  }

  String _linuxDataPath() {
    final xdgDataHome = Platform.environment['XDG_DATA_HOME'];
    if (xdgDataHome != null && xdgDataHome.isNotEmpty) {
      return xdgDataHome;
    }
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      return '$home${Platform.pathSeparator}.local${Platform.pathSeparator}share';
    }
    return Directory.systemTemp.path;
  }

  Future<void> _ensureDemoContent(Directory rootDir) async {
    const folderIdHex = '7f3a91c2f0d84ee28d1ab6d58e3c4102';
    const fileIdHex = '1ca4220c44ef4bfdb77e574a228ef00a';
    const parentFolderHex = folderIdHex;
    final folderDir =
        Directory('${rootDir.path}${Platform.pathSeparator}d_$folderIdHex');
    if (!await folderDir.exists()) {
      await folderDir.create(recursive: true);
    }

    final metaFile =
        File('${folderDir.path}${Platform.pathSeparator}.folder.cryptmeta');
    if (!await metaFile.exists()) {
      await metaFile.writeAsBytes(_buildFolderMetaBytes(folderIdHex));
    }

    final cryptFile =
        File('${rootDir.path}${Platform.pathSeparator}f_$fileIdHex.crypt');
    if (!await cryptFile.exists()) {
      await cryptFile
          .writeAsBytes(_buildFileContainerBytes(fileIdHex, parentFolderHex));
    }
  }

  Uint8List _buildFolderMetaBytes(String folderIdHex) {
    const encryptedName = <int>[0x12, 0x34, 0x56, 0x78, 0x90];
    const encryptedPreview = <int>[0xA1, 0xB2];
    final folderId = _hex16(folderIdHex);
    final parentId = Uint8List(16);
    final out = BytesBuilder();
    out.add(_commonHeader(
      containerType: 2,
      headerSize: 90,
      extensionCount: 0,
    ));
    out.add(folderId);
    out.add(parentId);
    out.add(_u64(1713440000000));
    out.add(_u64(1713443600000));
    out.add(_u16(1));
    out.add(_u16(1));
    out.add(_u16(0));
    out.add(_u16(0));
    out.add(_u32(encryptedName.length));
    out.add(_u32(encryptedPreview.length));
    final bytes = out.toBytes();
    assert(bytes.length == 90);
    return Uint8List.fromList(
        [...bytes, ...encryptedName, ...encryptedPreview]);
  }

  Uint8List _buildFileContainerBytes(String fileIdHex, String parentFolderHex) {
    const encryptedHeader = <int>[0x01, 0x02, 0x03, 0x04, 0x05];
    const encryptedPayload = <int>[
      0x11,
      0x22,
      0x33,
      0x44,
      0x55,
      0x66,
      0x77,
      0x88
    ];
    final fileId = _hex16(fileIdHex);
    final parentId = _hex16(parentFolderHex);
    final out = BytesBuilder();
    out.add(_commonHeader(
      containerType: 1,
      headerSize: 106,
      extensionCount: 0,
    ));
    out.add(fileId);
    out.add(parentId);
    out.add(_u64(1713447200000));
    out.add(_u64(1713450800000));
    out.add(_u64(345678));
    out.add(_u64(encryptedPayload.length));
    out.add(_u16(1));
    out.add(_u16(1));
    out.add(_u16(1));
    out.add(_u16(1));
    out.add(_u32(65536));
    out.add(_u32(encryptedHeader.length));
    final bytes = out.toBytes();
    assert(bytes.length == 106);
    return Uint8List.fromList(
        [...bytes, ...encryptedHeader, ...encryptedPayload]);
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

  Uint8List _hex16(String hex) {
    final bytes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  String _basename(String path) => path.split(Platform.pathSeparator).last;
}
