import 'dart:io';
import 'dart:typed_data';

import '../vault/vault_models.dart';

enum ExplorerLocationKind {
  local,
  appHidden,
  phoneFiles,
  network,
  cloudPlugin,
}

class ExplorerLocation {
  const ExplorerLocation({
    required this.id,
    required this.name,
    required this.kind,
    this.path,
    this.description,
    this.enabled = true,
    this.pluginId,
  });

  final String id;
  final String name;
  final ExplorerLocationKind kind;
  final String? path;
  final String? description;
  final bool enabled;
  final String? pluginId;
}

enum ExplorerEntryKind {
  directory,
  file,
  encryptedFile,
  folderMeta,
  unknown,
}

enum FileContentKind {
  text,
  image,
  video,
  audio,
  document,
  html,
  archive,
  unknown,
}

enum MediaSection {
  gallery,
  music,
  video,
  documents,
  torrent,
}

enum EncryptionKeyMode {
  common,
  unique,
}

class EncryptionAlgorithm {
  const EncryptionAlgorithm._();

  static const xchacha20Poly1305 = 'xchacha20-poly1305';
  static const aes256Gcm = 'aes-256-gcm';

  static const supported = <String>[
    xchacha20Poly1305,
    aes256Gcm,
  ];

  static String label(String value) => switch (value) {
        aes256Gcm => 'AES-256-GCM',
        _ => 'XChaCha20-Poly1305',
      };
}

class EncryptedFileParameters {
  const EncryptedFileParameters({
    required this.keyMode,
    required this.algorithm,
  });

  final EncryptionKeyMode keyMode;
  final String algorithm;

  bool get usesCommonKey => keyMode == EncryptionKeyMode.common;
}

class ExplorerEntry {
  const ExplorerEntry({
    required this.name,
    required this.path,
    required this.kind,
    required this.sizeBytes,
    required this.modifiedAt,
    this.containerInfo,
    this.exists = true,
    this.isNavigationEntry = false,
  });

  final String name;
  final String path;
  final ExplorerEntryKind kind;
  final int sizeBytes;
  final DateTime modifiedAt;
  final VaultContainerInfo? containerInfo;
  final bool exists;
  final bool isNavigationEntry;

  bool get isDirectory => kind == ExplorerEntryKind.directory;
  bool get isEncrypted =>
      kind == ExplorerEntryKind.encryptedFile ||
      kind == ExplorerEntryKind.folderMeta;
}

class DirectorySnapshot {
  const DirectorySnapshot({
    required this.path,
    required this.entries,
    this.error,
  });

  final String path;
  final List<ExplorerEntry> entries;
  final String? error;

  bool get hasError => error != null;
}

class FilePreview {
  const FilePreview({
    required this.title,
    required this.subtitle,
    this.sourcePath,
    this.text,
    this.bytes,
    this.containerInfo,
    this.decrypted = false,
    this.contentKind = FileContentKind.unknown,
  });

  final String title;
  final String subtitle;
  final String? sourcePath;
  final String? text;
  final List<int>? bytes;
  final VaultContainerInfo? containerInfo;
  final bool decrypted;
  final FileContentKind contentKind;
}

class MediaPreviewItem {
  const MediaPreviewItem({
    required this.title,
    required this.kind,
    this.path,
    this.resumeKey,
    this.bytes,
    this.encrypted = false,
  });

  final String title;
  final FileContentKind kind;
  final String? path;
  final String? resumeKey;
  final Uint8List? bytes;
  final bool encrypted;
}

class TransferOptions {
  const TransferOptions({
    required this.asEncrypted,
    required this.deleteSourceAfter,
    required this.targetDirectory,
    this.sourcePath,
    this.password,
  });

  final bool asEncrypted;
  final bool deleteSourceAfter;
  final String targetDirectory;
  final String? sourcePath;
  final String? password;
}

class EncryptFileOptions {
  const EncryptFileOptions({
    required this.mode,
    required this.password,
    required this.algorithm,
    required this.deleteSourceAfter,
    required this.targetDirectory,
  });

  final EncryptionKeyMode mode;
  final String password;
  final String algorithm;
  final bool deleteSourceAfter;
  final String targetDirectory;
}

class DecryptFileOptions {
  const DecryptFileOptions({
    required this.password,
    required this.targetDirectory,
    this.deleteSourceAfter = false,
  });

  final String password;
  final String targetDirectory;
  final bool deleteSourceAfter;
}

String basename(String path) {
  final separator = Platform.pathSeparator;
  final normalized = path.endsWith(separator) && path.length > 1
      ? path.substring(0, path.length - 1)
      : path;
  return normalized.split(separator).last;
}
