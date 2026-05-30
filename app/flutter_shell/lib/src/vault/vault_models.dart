enum VaultEntryKind {
  folderDirectory,
  folderMeta,
  fileContainer,
  unknown,
}

class VaultContainerInfo {
  const VaultContainerInfo({
    required this.statusCode,
    required this.containerType,
    required this.formatMajor,
    required this.formatMinor,
    required this.headerSize,
    required this.extensionCount,
    required this.flags,
    this.previewType,
    this.nameKdfId,
    this.nameCipherId,
    this.headerKdfId,
    this.headerCipherId,
    this.payloadCipherId,
    this.chunkSize,
    this.originalSize,
    this.storedSize,
    this.encryptedNameLength,
    this.encryptedPreviewLength,
    this.encryptedHeaderLength,
    this.encryptedPayloadLength,
  });

  final int statusCode;
  final int containerType;
  final int formatMajor;
  final int formatMinor;
  final int headerSize;
  final int extensionCount;
  final int flags;
  final int? previewType;
  final int? nameKdfId;
  final int? nameCipherId;
  final int? headerKdfId;
  final int? headerCipherId;
  final int? payloadCipherId;
  final int? chunkSize;
  final int? originalSize;
  final int? storedSize;
  final int? encryptedNameLength;
  final int? encryptedPreviewLength;
  final int? encryptedHeaderLength;
  final int? encryptedPayloadLength;

  bool get isOk => statusCode == 0;
}

class VaultEntry {
  const VaultEntry({
    required this.kind,
    required this.name,
    required this.logicalLabel,
    required this.path,
    required this.sizeBytes,
    this.containerInfo,
  });

  final VaultEntryKind kind;
  final String name;
  final String logicalLabel;
  final String path;
  final int sizeBytes;
  final VaultContainerInfo? containerInfo;
}

class VaultSnapshot {
  const VaultSnapshot({
    required this.rootPath,
    required this.entries,
  });

  final String rootPath;
  final List<VaultEntry> entries;

  int get folderCount => entries
      .where((entry) => entry.kind == VaultEntryKind.folderDirectory)
      .length;

  int get fileCount => entries
      .where((entry) => entry.kind == VaultEntryKind.fileContainer)
      .length;

  int get metaCount =>
      entries.where((entry) => entry.kind == VaultEntryKind.folderMeta).length;
}
