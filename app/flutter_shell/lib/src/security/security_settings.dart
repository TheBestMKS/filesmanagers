import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:archive/archive.dart';

import '../storage/app_paths.dart';
import 'vault_crypto.dart';

class SecuritySettings {
  const SecuritySettings({
    this.appPasswordSalt,
    this.appPasswordDigest,
    this.filePasswordSalt,
    this.filePasswordDigest,
    this.useSeparateFilePassword = false,
    this.rememberFilePasswords = false,
    this.wipeSavedPasswordsOnFailedLogin = true,
    this.savedFilePasswordEnvelope,
    this.failedLoginAttempts = 0,
    this.commonEncryptionSalt,
    this.commonEncryptionDigest,
    this.commonEncryptionEnvelope,
    this.commonEncryptionAlgorithm = VaultCrypto.xchacha20Poly1305,
    this.commonEncryptionKeyFilePath,
    this.filePasswordGraceSeconds = 0,
    this.blockScreenCapture = true,
    this.languageCode = 'ru',
    this.customLanguagePath,
    this.extensionAssociations = const <String, String>{},
    this.favoritePaths = const <String>[],
    this.rememberRecentFiles = true,
    this.recentSidebarCount = 5,
    this.recentRememberCount = 50,
    this.recentFilePaths = const <String>[],
    this.favoriteSidebarCount = 10,
    this.decryptNamesInExplorer = true,
    this.openFullscreenOnHiddenPreviewTap = true,
    this.autoScaleForDpi = true,
    this.fileTextScale = 1.0,
    this.fileIconScale = 1.0,
    this.galleryFolders = const <String>[],
    this.galleryExclusions = '',
    this.musicFolders = const <String>[],
    this.musicExclusions = '',
    this.videoFolders = const <String>[],
    this.videoExclusions = '',
    this.documentFolders = const <String>[],
    this.documentExclusions = '',
    this.torrentEnabled = true,
    this.androidStoragePermissionPromptDismissed = false,
    this.storeSettingsInUserProfile = false,
    this.rememberLastFolder = true,
    this.lastOpenedFolder,
    this.navigationPolicy = 'fallbackToLocations',
    this.interfaceTextScale = 1.0,
    this.toolbarIconScale = 1.0,
    this.searchMode = 'name',
    this.searchUseRegex = false,
    this.searchRecursive = false,
    this.programProxy,
    this.globalPluginProxy,
    this.pluginProxyById = const <String, String>{},
    this.enableBackgroundVideo = true,
    this.enableMiniVideo = true,
    this.enableMiniAudio = true,
    this.continueMediaInBackground = true,
    this.autoCloseMediaOnSectionChange = false,
    this.mediaResumePositions = const <String, int>{},
  });

  final String? appPasswordSalt;
  final String? appPasswordDigest;
  final String? filePasswordSalt;
  final String? filePasswordDigest;
  final bool useSeparateFilePassword;
  final bool rememberFilePasswords;
  final bool wipeSavedPasswordsOnFailedLogin;
  final Map<String, Object?>? savedFilePasswordEnvelope;
  final int failedLoginAttempts;
  final String? commonEncryptionSalt;
  final String? commonEncryptionDigest;
  final Map<String, Object?>? commonEncryptionEnvelope;
  final String commonEncryptionAlgorithm;
  final String? commonEncryptionKeyFilePath;
  final int filePasswordGraceSeconds;
  final bool blockScreenCapture;
  final String languageCode;
  final String? customLanguagePath;
  final Map<String, String> extensionAssociations;
  final List<String> favoritePaths;
  final bool rememberRecentFiles;
  final int recentSidebarCount;
  final int recentRememberCount;
  final List<String> recentFilePaths;
  final int favoriteSidebarCount;
  final bool decryptNamesInExplorer;
  final bool openFullscreenOnHiddenPreviewTap;
  final bool autoScaleForDpi;
  final double fileTextScale;
  final double fileIconScale;
  final List<String> galleryFolders;
  final String galleryExclusions;
  final List<String> musicFolders;
  final String musicExclusions;
  final List<String> videoFolders;
  final String videoExclusions;
  final List<String> documentFolders;
  final String documentExclusions;
  final bool torrentEnabled;
  final bool androidStoragePermissionPromptDismissed;
  final bool storeSettingsInUserProfile;
  final bool rememberLastFolder;
  final String? lastOpenedFolder;
  final String navigationPolicy;
  final double interfaceTextScale;
  final double toolbarIconScale;
  final String searchMode;
  final bool searchUseRegex;
  final bool searchRecursive;
  final String? programProxy;
  final String? globalPluginProxy;
  final Map<String, String> pluginProxyById;
  final bool enableBackgroundVideo;
  final bool enableMiniVideo;
  final bool enableMiniAudio;
  final bool continueMediaInBackground;
  final bool autoCloseMediaOnSectionChange;
  final Map<String, int> mediaResumePositions;

  bool get hasAppPassword =>
      appPasswordSalt != null && appPasswordDigest != null;
  bool get hasFilePassword =>
      filePasswordSalt != null && filePasswordDigest != null;
  bool get hasCommonEncryption =>
      commonEncryptionSalt != null && commonEncryptionDigest != null;

  SecuritySettings copyWith({
    String? appPasswordSalt,
    String? appPasswordDigest,
    bool clearAppPassword = false,
    String? filePasswordSalt,
    String? filePasswordDigest,
    bool clearFilePassword = false,
    bool? useSeparateFilePassword,
    bool? rememberFilePasswords,
    bool? wipeSavedPasswordsOnFailedLogin,
    Map<String, Object?>? savedFilePasswordEnvelope,
    bool clearSavedFilePassword = false,
    int? failedLoginAttempts,
    String? commonEncryptionSalt,
    String? commonEncryptionDigest,
    Map<String, Object?>? commonEncryptionEnvelope,
    bool clearCommonEncryption = false,
    String? commonEncryptionAlgorithm,
    String? commonEncryptionKeyFilePath,
    bool clearCommonEncryptionKeyFilePath = false,
    int? filePasswordGraceSeconds,
    bool? blockScreenCapture,
    String? languageCode,
    String? customLanguagePath,
    bool clearCustomLanguagePath = false,
    Map<String, String>? extensionAssociations,
    List<String>? favoritePaths,
    bool? rememberRecentFiles,
    int? recentSidebarCount,
    int? recentRememberCount,
    List<String>? recentFilePaths,
    int? favoriteSidebarCount,
    bool? decryptNamesInExplorer,
    bool? openFullscreenOnHiddenPreviewTap,
    bool? autoScaleForDpi,
    double? fileTextScale,
    double? fileIconScale,
    List<String>? galleryFolders,
    String? galleryExclusions,
    List<String>? musicFolders,
    String? musicExclusions,
    List<String>? videoFolders,
    String? videoExclusions,
    List<String>? documentFolders,
    String? documentExclusions,
    bool? torrentEnabled,
    bool? androidStoragePermissionPromptDismissed,
    bool? storeSettingsInUserProfile,
    bool? rememberLastFolder,
    String? lastOpenedFolder,
    bool clearLastOpenedFolder = false,
    String? navigationPolicy,
    double? interfaceTextScale,
    double? toolbarIconScale,
    String? searchMode,
    bool? searchUseRegex,
    bool? searchRecursive,
    String? programProxy,
    bool clearProgramProxy = false,
    String? globalPluginProxy,
    bool clearGlobalPluginProxy = false,
    Map<String, String>? pluginProxyById,
    bool? enableBackgroundVideo,
    bool? enableMiniVideo,
    bool? enableMiniAudio,
    bool? continueMediaInBackground,
    bool? autoCloseMediaOnSectionChange,
    Map<String, int>? mediaResumePositions,
  }) {
    return SecuritySettings(
      appPasswordSalt:
          clearAppPassword ? null : appPasswordSalt ?? this.appPasswordSalt,
      appPasswordDigest:
          clearAppPassword ? null : appPasswordDigest ?? this.appPasswordDigest,
      filePasswordSalt:
          clearFilePassword ? null : filePasswordSalt ?? this.filePasswordSalt,
      filePasswordDigest: clearFilePassword
          ? null
          : filePasswordDigest ?? this.filePasswordDigest,
      useSeparateFilePassword:
          useSeparateFilePassword ?? this.useSeparateFilePassword,
      rememberFilePasswords:
          rememberFilePasswords ?? this.rememberFilePasswords,
      wipeSavedPasswordsOnFailedLogin: wipeSavedPasswordsOnFailedLogin ??
          this.wipeSavedPasswordsOnFailedLogin,
      savedFilePasswordEnvelope: clearSavedFilePassword
          ? null
          : savedFilePasswordEnvelope ?? this.savedFilePasswordEnvelope,
      failedLoginAttempts: failedLoginAttempts ?? this.failedLoginAttempts,
      commonEncryptionSalt: clearCommonEncryption
          ? null
          : commonEncryptionSalt ?? this.commonEncryptionSalt,
      commonEncryptionDigest: clearCommonEncryption
          ? null
          : commonEncryptionDigest ?? this.commonEncryptionDigest,
      commonEncryptionEnvelope: clearCommonEncryption
          ? null
          : commonEncryptionEnvelope ?? this.commonEncryptionEnvelope,
      commonEncryptionAlgorithm:
          commonEncryptionAlgorithm ?? this.commonEncryptionAlgorithm,
      commonEncryptionKeyFilePath: clearCommonEncryptionKeyFilePath
          ? null
          : commonEncryptionKeyFilePath ?? this.commonEncryptionKeyFilePath,
      filePasswordGraceSeconds:
          filePasswordGraceSeconds ?? this.filePasswordGraceSeconds,
      blockScreenCapture: blockScreenCapture ?? this.blockScreenCapture,
      languageCode: languageCode ?? this.languageCode,
      customLanguagePath: clearCustomLanguagePath
          ? null
          : customLanguagePath ?? this.customLanguagePath,
      extensionAssociations:
          extensionAssociations ?? this.extensionAssociations,
      favoritePaths: favoritePaths ?? this.favoritePaths,
      rememberRecentFiles: rememberRecentFiles ?? this.rememberRecentFiles,
      recentSidebarCount: recentSidebarCount ?? this.recentSidebarCount,
      recentRememberCount: recentRememberCount ?? this.recentRememberCount,
      recentFilePaths: recentFilePaths ?? this.recentFilePaths,
      favoriteSidebarCount: favoriteSidebarCount ?? this.favoriteSidebarCount,
      decryptNamesInExplorer:
          decryptNamesInExplorer ?? this.decryptNamesInExplorer,
      openFullscreenOnHiddenPreviewTap: openFullscreenOnHiddenPreviewTap ??
          this.openFullscreenOnHiddenPreviewTap,
      autoScaleForDpi: autoScaleForDpi ?? this.autoScaleForDpi,
      fileTextScale: fileTextScale ?? this.fileTextScale,
      fileIconScale: fileIconScale ?? this.fileIconScale,
      galleryFolders: galleryFolders ?? this.galleryFolders,
      galleryExclusions: galleryExclusions ?? this.galleryExclusions,
      musicFolders: musicFolders ?? this.musicFolders,
      musicExclusions: musicExclusions ?? this.musicExclusions,
      videoFolders: videoFolders ?? this.videoFolders,
      videoExclusions: videoExclusions ?? this.videoExclusions,
      documentFolders: documentFolders ?? this.documentFolders,
      documentExclusions: documentExclusions ?? this.documentExclusions,
      torrentEnabled: torrentEnabled ?? this.torrentEnabled,
      androidStoragePermissionPromptDismissed:
          androidStoragePermissionPromptDismissed ??
              this.androidStoragePermissionPromptDismissed,
      storeSettingsInUserProfile:
          storeSettingsInUserProfile ?? this.storeSettingsInUserProfile,
      rememberLastFolder: rememberLastFolder ?? this.rememberLastFolder,
      lastOpenedFolder: clearLastOpenedFolder
          ? null
          : lastOpenedFolder ?? this.lastOpenedFolder,
      navigationPolicy: navigationPolicy ?? this.navigationPolicy,
      interfaceTextScale: interfaceTextScale ?? this.interfaceTextScale,
      toolbarIconScale: toolbarIconScale ?? this.toolbarIconScale,
      searchMode: searchMode ?? this.searchMode,
      searchUseRegex: searchUseRegex ?? this.searchUseRegex,
      searchRecursive: searchRecursive ?? this.searchRecursive,
      programProxy:
          clearProgramProxy ? null : programProxy ?? this.programProxy,
      globalPluginProxy: clearGlobalPluginProxy
          ? null
          : globalPluginProxy ?? this.globalPluginProxy,
      pluginProxyById: pluginProxyById ?? this.pluginProxyById,
      enableBackgroundVideo:
          enableBackgroundVideo ?? this.enableBackgroundVideo,
      enableMiniVideo: enableMiniVideo ?? this.enableMiniVideo,
      enableMiniAudio: enableMiniAudio ?? this.enableMiniAudio,
      continueMediaInBackground:
          continueMediaInBackground ?? this.continueMediaInBackground,
      autoCloseMediaOnSectionChange:
          autoCloseMediaOnSectionChange ?? this.autoCloseMediaOnSectionChange,
      mediaResumePositions: mediaResumePositions ?? this.mediaResumePositions,
    );
  }

  factory SecuritySettings.fromJson(Map<String, Object?> json) {
    final envelope = json['savedFilePasswordEnvelope'];
    final commonEnvelope = json['commonEncryptionEnvelope'];
    final associations = json['extensionAssociations'];
    final favorites = json['favoritePaths'];
    final recent = json['recentFilePaths'];
    final pluginProxy = json['pluginProxyById'];
    final mediaResume = json['mediaResumePositions'];
    List<String> listField(String key) {
      final value = json[key];
      return value is List
          ? value.map((item) => item.toString()).toList()
          : const <String>[];
    }

    return SecuritySettings(
      appPasswordSalt: json['appPasswordSalt'] as String?,
      appPasswordDigest: json['appPasswordDigest'] as String?,
      filePasswordSalt: json['filePasswordSalt'] as String?,
      filePasswordDigest: json['filePasswordDigest'] as String?,
      useSeparateFilePassword:
          json['useSeparateFilePassword'] as bool? ?? false,
      rememberFilePasswords: json['rememberFilePasswords'] as bool? ?? false,
      wipeSavedPasswordsOnFailedLogin:
          json['wipeSavedPasswordsOnFailedLogin'] as bool? ?? true,
      savedFilePasswordEnvelope: envelope is Map
          ? envelope.map((key, value) => MapEntry(key.toString(), value))
          : null,
      failedLoginAttempts: json['failedLoginAttempts'] as int? ?? 0,
      commonEncryptionSalt: json['commonEncryptionSalt'] as String?,
      commonEncryptionDigest: json['commonEncryptionDigest'] as String?,
      commonEncryptionEnvelope: commonEnvelope is Map
          ? commonEnvelope.map((key, value) => MapEntry(key.toString(), value))
          : null,
      commonEncryptionAlgorithm: json['commonEncryptionAlgorithm'] as String? ??
          VaultCrypto.xchacha20Poly1305,
      commonEncryptionKeyFilePath:
          json['commonEncryptionKeyFilePath'] as String?,
      filePasswordGraceSeconds: json['filePasswordGraceSeconds'] as int? ?? 0,
      blockScreenCapture: json['blockScreenCapture'] as bool? ?? true,
      languageCode: json['languageCode'] as String? ?? 'ru',
      customLanguagePath: json['customLanguagePath'] as String?,
      extensionAssociations: associations is Map
          ? associations.map((key, value) =>
              MapEntry(key.toString().toLowerCase(), value.toString()))
          : const <String, String>{},
      favoritePaths: favorites is List
          ? favorites.map((item) => item.toString()).toList()
          : const <String>[],
      rememberRecentFiles: json['rememberRecentFiles'] as bool? ?? true,
      recentSidebarCount: json['recentSidebarCount'] as int? ?? 5,
      recentRememberCount: json['recentRememberCount'] as int? ?? 50,
      recentFilePaths: recent is List
          ? recent.map((item) => item.toString()).toList()
          : const <String>[],
      favoriteSidebarCount: json['favoriteSidebarCount'] as int? ?? 10,
      decryptNamesInExplorer: json['decryptNamesInExplorer'] as bool? ?? true,
      openFullscreenOnHiddenPreviewTap:
          json['openFullscreenOnHiddenPreviewTap'] as bool? ?? true,
      autoScaleForDpi: json['autoScaleForDpi'] as bool? ?? true,
      fileTextScale: (json['fileTextScale'] as num?)?.toDouble() ?? 1.0,
      fileIconScale: (json['fileIconScale'] as num?)?.toDouble() ?? 1.0,
      galleryFolders: listField('galleryFolders'),
      galleryExclusions: json['galleryExclusions'] as String? ?? '',
      musicFolders: listField('musicFolders'),
      musicExclusions: json['musicExclusions'] as String? ?? '',
      videoFolders: listField('videoFolders'),
      videoExclusions: json['videoExclusions'] as String? ?? '',
      documentFolders: listField('documentFolders'),
      documentExclusions: json['documentExclusions'] as String? ?? '',
      torrentEnabled: json['torrentEnabled'] as bool? ?? true,
      androidStoragePermissionPromptDismissed:
          json['androidStoragePermissionPromptDismissed'] as bool? ?? false,
      storeSettingsInUserProfile:
          json['storeSettingsInUserProfile'] as bool? ?? false,
      rememberLastFolder: json['rememberLastFolder'] as bool? ?? true,
      lastOpenedFolder: json['lastOpenedFolder'] as String?,
      navigationPolicy:
          json['navigationPolicy'] as String? ?? 'fallbackToLocations',
      interfaceTextScale:
          (json['interfaceTextScale'] as num?)?.toDouble() ?? 1.0,
      toolbarIconScale: (json['toolbarIconScale'] as num?)?.toDouble() ?? 1.0,
      searchMode: json['searchMode'] as String? ?? 'name',
      searchUseRegex: json['searchUseRegex'] as bool? ?? false,
      searchRecursive: json['searchRecursive'] as bool? ?? false,
      programProxy: json['programProxy'] as String?,
      globalPluginProxy: json['globalPluginProxy'] as String?,
      pluginProxyById: pluginProxy is Map
          ? pluginProxy
              .map((key, value) => MapEntry(key.toString(), value.toString()))
          : const <String, String>{},
      enableBackgroundVideo: json['enableBackgroundVideo'] as bool? ?? true,
      enableMiniVideo: json['enableMiniVideo'] as bool? ?? true,
      enableMiniAudio: json['enableMiniAudio'] as bool? ?? true,
      continueMediaInBackground:
          json['continueMediaInBackground'] as bool? ?? true,
      autoCloseMediaOnSectionChange:
          json['autoCloseMediaOnSectionChange'] as bool? ?? false,
      mediaResumePositions: mediaResume is Map
          ? mediaResume.map((key, value) => MapEntry(
                key.toString(),
                value is num ? value.round() : int.tryParse('$value') ?? 0,
              ))
          : const <String, int>{},
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'appPasswordSalt': appPasswordSalt,
      'appPasswordDigest': appPasswordDigest,
      'filePasswordSalt': filePasswordSalt,
      'filePasswordDigest': filePasswordDigest,
      'useSeparateFilePassword': useSeparateFilePassword,
      'rememberFilePasswords': rememberFilePasswords,
      'wipeSavedPasswordsOnFailedLogin': wipeSavedPasswordsOnFailedLogin,
      'savedFilePasswordEnvelope': savedFilePasswordEnvelope,
      'failedLoginAttempts': failedLoginAttempts,
      'commonEncryptionSalt': commonEncryptionSalt,
      'commonEncryptionDigest': commonEncryptionDigest,
      'commonEncryptionEnvelope': commonEncryptionEnvelope,
      'commonEncryptionAlgorithm': commonEncryptionAlgorithm,
      'commonEncryptionKeyFilePath': commonEncryptionKeyFilePath,
      'filePasswordGraceSeconds': filePasswordGraceSeconds,
      'blockScreenCapture': blockScreenCapture,
      'languageCode': languageCode,
      'customLanguagePath': customLanguagePath,
      'extensionAssociations': extensionAssociations,
      'favoritePaths': favoritePaths,
      'rememberRecentFiles': rememberRecentFiles,
      'recentSidebarCount': recentSidebarCount,
      'recentRememberCount': recentRememberCount,
      'recentFilePaths': recentFilePaths,
      'favoriteSidebarCount': favoriteSidebarCount,
      'decryptNamesInExplorer': decryptNamesInExplorer,
      'openFullscreenOnHiddenPreviewTap': openFullscreenOnHiddenPreviewTap,
      'autoScaleForDpi': autoScaleForDpi,
      'fileTextScale': fileTextScale,
      'fileIconScale': fileIconScale,
      'galleryFolders': galleryFolders,
      'galleryExclusions': galleryExclusions,
      'musicFolders': musicFolders,
      'musicExclusions': musicExclusions,
      'videoFolders': videoFolders,
      'videoExclusions': videoExclusions,
      'documentFolders': documentFolders,
      'documentExclusions': documentExclusions,
      'torrentEnabled': torrentEnabled,
      'androidStoragePermissionPromptDismissed':
          androidStoragePermissionPromptDismissed,
      'storeSettingsInUserProfile': storeSettingsInUserProfile,
      'rememberLastFolder': rememberLastFolder,
      'lastOpenedFolder': lastOpenedFolder,
      'navigationPolicy': navigationPolicy,
      'interfaceTextScale': interfaceTextScale,
      'toolbarIconScale': toolbarIconScale,
      'searchMode': searchMode,
      'searchUseRegex': searchUseRegex,
      'searchRecursive': searchRecursive,
      'programProxy': programProxy,
      'globalPluginProxy': globalPluginProxy,
      'pluginProxyById': pluginProxyById,
      'enableBackgroundVideo': enableBackgroundVideo,
      'enableMiniVideo': enableMiniVideo,
      'enableMiniAudio': enableMiniAudio,
      'continueMediaInBackground': continueMediaInBackground,
      'autoCloseMediaOnSectionChange': autoCloseMediaOnSectionChange,
      'mediaResumePositions': mediaResumePositions,
    };
  }
}

class SecuritySettingsRepository {
  Future<File> _settingsFile() async {
    final appData = await AppPaths.appDataDirectory();
    return File(
        '${appData.path}${Platform.pathSeparator}security_settings.json');
  }

  Future<SecuritySettings> load() async {
    final file = await _settingsFile();
    if (!await file.exists()) {
      return const SecuritySettings();
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?>) {
      return const SecuritySettings();
    }
    if (decoded['schema'] == 'securevault.settingsFile.v1') {
      final envelope = decoded['envelope'];
      if (envelope is! Map) {
        return const SecuritySettings();
      }
      try {
        final clear = await VaultCrypto.decryptTextEnvelope(
          envelope.map((key, value) => MapEntry(key.toString(), value)),
          password: await _deviceSecret(),
        );
        final settingsJson = jsonDecode(clear);
        if (settingsJson is Map<String, Object?>) {
          return SecuritySettings.fromJson(settingsJson);
        }
      } catch (_) {
        return const SecuritySettings();
      }
      return const SecuritySettings();
    }
    return SecuritySettings.fromJson(decoded);
  }

  Future<void> save(SecuritySettings settings) async {
    final file = await _settingsFile();
    final clear = const JsonEncoder.withIndent('  ').convert(settings.toJson());
    final envelope = await VaultCrypto.encryptTextEnvelope(
      clear,
      password: await _deviceSecret(),
    );
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'schema': 'securevault.settingsFile.v1',
        'key': 'device',
        'envelope': envelope,
      }),
    );
  }

  Future<SecuritySettings> updateFavorites(
    SecuritySettings current,
    List<String> paths,
  ) async {
    final deduped = _dedupePaths(paths);
    final next = current.copyWith(favoritePaths: deduped);
    await save(next);
    return next;
  }

  Future<SecuritySettings> recordRecentFile(
    SecuritySettings current,
    String path,
  ) async {
    if (!current.rememberRecentFiles) {
      return current;
    }
    final nextPaths = _dedupePaths(<String>[path, ...current.recentFilePaths])
        .take(current.recentRememberCount.clamp(0, 500).toInt())
        .toList();
    final next = current.copyWith(recentFilePaths: nextPaths);
    await save(next);
    return next;
  }

  Future<SecuritySettings> removeRecentFile(
    SecuritySettings current,
    String path,
  ) async {
    final next = current.copyWith(
      recentFilePaths:
          current.recentFilePaths.where((item) => item != path).toList(),
    );
    await save(next);
    return next;
  }

  Future<SecuritySettings> setAndroidStoragePermissionPromptDismissed(
    SecuritySettings current,
    bool dismissed,
  ) async {
    final next =
        current.copyWith(androidStoragePermissionPromptDismissed: dismissed);
    await save(next);
    return next;
  }

  Future<SecuritySettings> recordLastOpenedFolder(
    SecuritySettings current,
    String path,
  ) async {
    if (!current.rememberLastFolder || path.trim().isEmpty) {
      return current;
    }
    final next = current.copyWith(lastOpenedFolder: path.trim());
    await save(next);
    return next;
  }

  Future<SecuritySettings> recordMediaResumePosition(
    SecuritySettings current,
    String key,
    int positionMs,
  ) async {
    final normalized = key.trim();
    if (normalized.isEmpty) return current;
    final nextPositions = Map<String, int>.of(current.mediaResumePositions);
    if (positionMs <= 1500) {
      nextPositions.remove(normalized);
    } else {
      nextPositions[normalized] = positionMs;
    }
    while (nextPositions.length > 500) {
      nextPositions.remove(nextPositions.keys.first);
    }
    final next = current.copyWith(mediaResumePositions: nextPositions);
    await save(next);
    return next;
  }

  Future<SecuritySettings> updateMediaFolders(
    SecuritySettings current, {
    List<String>? galleryFolders,
    List<String>? musicFolders,
    List<String>? videoFolders,
  }) async {
    final next = current.copyWith(
      galleryFolders: galleryFolders,
      musicFolders: musicFolders,
      videoFolders: videoFolders,
    );
    await save(next);
    return next;
  }

  Future<File> exportConfigurationArchive({String? targetPath}) async {
    final appData = await AppPaths.appDataDirectory();
    final exportDir = await AppPaths.exportDirectory();
    final timestamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-');
    final target = File(
      targetPath?.trim().isNotEmpty == true
          ? targetPath!.trim()
          : '${exportDir.path}${Platform.pathSeparator}securevault_configuration_$timestamp.zip',
    );
    await target.parent.create(recursive: true);
    final archive = Archive();
    await _addDirectoryToArchive(archive, appData, rootName: 'SecureVaultData');
    final bytes = ZipEncoder().encode(archive);
    await target.writeAsBytes(bytes, flush: true);
    return target;
  }

  List<String> _dedupePaths(Iterable<String> paths) {
    final seen = <String>{};
    final result = <String>[];
    for (final path in paths) {
      final trimmed = path.trim();
      if (trimmed.isEmpty) continue;
      final key = Platform.isWindows ? trimmed.toLowerCase() : trimmed;
      if (seen.add(key)) {
        result.add(trimmed);
      }
    }
    return result;
  }

  Future<void> _addDirectoryToArchive(
    Archive archive,
    Directory directory, {
    required String rootName,
  }) async {
    if (!await directory.exists()) return;
    await for (final entity in directory.list(recursive: true)) {
      if (entity is! File) continue;
      final relative = entity.path
          .substring(directory.path.length)
          .replaceFirst(RegExp(r'^[\\/]+'), '')
          .replaceAll('\\', '/');
      if (relative.isEmpty) continue;
      archive.addFile(
        ArchiveFile(
          '$rootName/$relative',
          await entity.length(),
          await entity.readAsBytes(),
        ),
      );
    }
  }

  Future<SecuritySettings> setPasswords({
    required SecuritySettings current,
    required String? appPassword,
    required String? currentAppPassword,
    required String? filePassword,
    required String? currentFilePassword,
    required bool useSeparateFilePassword,
    required bool rememberFilePasswords,
    required bool wipeSavedPasswordsOnFailedLogin,
    String? commonEncryptionPassword,
    String? commonEncryptionAlgorithm,
    String? commonEncryptionKeyFilePath,
    int? filePasswordGraceSeconds,
    bool? blockScreenCapture,
    String? languageCode,
    String? customLanguagePath,
    Map<String, String>? extensionAssociations,
    bool? rememberRecentFiles,
    int? recentSidebarCount,
    int? recentRememberCount,
    int? favoriteSidebarCount,
    bool? decryptNamesInExplorer,
    bool? openFullscreenOnHiddenPreviewTap,
    bool? autoScaleForDpi,
    double? fileTextScale,
    double? fileIconScale,
    List<String>? galleryFolders,
    String? galleryExclusions,
    List<String>? musicFolders,
    String? musicExclusions,
    List<String>? videoFolders,
    String? videoExclusions,
    List<String>? documentFolders,
    String? documentExclusions,
    bool? torrentEnabled,
    bool? androidStoragePermissionPromptDismissed,
    bool? storeSettingsInUserProfile,
    bool? rememberLastFolder,
    String? navigationPolicy,
    double? interfaceTextScale,
    double? toolbarIconScale,
    String? searchMode,
    bool? searchUseRegex,
    bool? searchRecursive,
    String? programProxy,
    String? globalPluginProxy,
    Map<String, String>? pluginProxyById,
    bool? enableBackgroundVideo,
    bool? enableMiniVideo,
    bool? enableMiniAudio,
    bool? continueMediaInBackground,
    bool? autoCloseMediaOnSectionChange,
  }) async {
    var next = current.copyWith(
      useSeparateFilePassword: useSeparateFilePassword,
      rememberFilePasswords: rememberFilePasswords,
      wipeSavedPasswordsOnFailedLogin: wipeSavedPasswordsOnFailedLogin,
      commonEncryptionAlgorithm: commonEncryptionAlgorithm,
      commonEncryptionKeyFilePath: commonEncryptionKeyFilePath == null ||
              commonEncryptionKeyFilePath.isEmpty
          ? null
          : commonEncryptionKeyFilePath,
      clearCommonEncryptionKeyFilePath: commonEncryptionKeyFilePath != null &&
          commonEncryptionKeyFilePath.isEmpty,
      filePasswordGraceSeconds: filePasswordGraceSeconds,
      blockScreenCapture: blockScreenCapture,
      languageCode: languageCode,
      customLanguagePath: customLanguagePath,
      extensionAssociations: extensionAssociations,
      rememberRecentFiles: rememberRecentFiles,
      recentSidebarCount: recentSidebarCount,
      recentRememberCount: recentRememberCount,
      favoriteSidebarCount: favoriteSidebarCount,
      decryptNamesInExplorer: decryptNamesInExplorer,
      openFullscreenOnHiddenPreviewTap: openFullscreenOnHiddenPreviewTap,
      autoScaleForDpi: autoScaleForDpi,
      fileTextScale: fileTextScale,
      fileIconScale: fileIconScale,
      galleryFolders: galleryFolders,
      galleryExclusions: galleryExclusions,
      musicFolders: musicFolders,
      musicExclusions: musicExclusions,
      videoFolders: videoFolders,
      videoExclusions: videoExclusions,
      documentFolders: documentFolders,
      documentExclusions: documentExclusions,
      torrentEnabled: torrentEnabled,
      androidStoragePermissionPromptDismissed:
          androidStoragePermissionPromptDismissed,
      storeSettingsInUserProfile: storeSettingsInUserProfile,
      rememberLastFolder: rememberLastFolder,
      navigationPolicy: navigationPolicy,
      interfaceTextScale: interfaceTextScale,
      toolbarIconScale: toolbarIconScale,
      searchMode: searchMode,
      searchUseRegex: searchUseRegex,
      searchRecursive: searchRecursive,
      programProxy:
          programProxy == null || programProxy.isEmpty ? null : programProxy,
      clearProgramProxy: programProxy != null && programProxy.isEmpty,
      globalPluginProxy: globalPluginProxy == null || globalPluginProxy.isEmpty
          ? null
          : globalPluginProxy,
      clearGlobalPluginProxy:
          globalPluginProxy != null && globalPluginProxy.isEmpty,
      pluginProxyById: pluginProxyById,
      enableBackgroundVideo: enableBackgroundVideo,
      enableMiniVideo: enableMiniVideo,
      enableMiniAudio: enableMiniAudio,
      continueMediaInBackground: continueMediaInBackground,
      autoCloseMediaOnSectionChange: autoCloseMediaOnSectionChange,
      recentFilePaths: rememberRecentFiles == false
          ? const <String>[]
          : current.recentFilePaths
              .take((recentRememberCount ?? current.recentRememberCount)
                  .clamp(0, 500)
                  .toInt())
              .toList(),
      failedLoginAttempts: 0,
    );

    final normalizedAppPassword = appPassword?.trim() ?? '';
    final normalizedCurrentAppPassword = currentAppPassword?.trim() ?? '';
    final appPasswordChangeRequested = normalizedAppPassword.isNotEmpty ||
        normalizedCurrentAppPassword.isNotEmpty;
    if (current.hasAppPassword && appPasswordChangeRequested) {
      final ok = await verifyAppPassword(current, normalizedCurrentAppPassword);
      if (!ok) {
        throw const FormatException('Current app password is incorrect.');
      }
    }
    final appPasswordWasCleared = current.hasAppPassword &&
        appPasswordChangeRequested &&
        normalizedAppPassword.isEmpty;
    if (normalizedAppPassword.isNotEmpty) {
      final salt = VaultCrypto.randomBytes(16);
      final digest =
          await VaultCrypto.passwordDigest(normalizedAppPassword, salt);
      next = next.copyWith(
        appPasswordSalt: base64UrlEncode(salt),
        appPasswordDigest: digest,
      );
    } else if (appPasswordWasCleared) {
      next = next.copyWith(clearAppPassword: true);
    }

    final normalizedFilePassword = filePassword?.trim() ?? '';
    final normalizedCurrentFilePassword = currentFilePassword?.trim() ?? '';
    final filePasswordChangeRequested = normalizedFilePassword.isNotEmpty ||
        normalizedCurrentFilePassword.isNotEmpty;
    if (useSeparateFilePassword &&
        current.hasFilePassword &&
        filePasswordChangeRequested) {
      final ok =
          await verifyFilePassword(current, normalizedCurrentFilePassword);
      if (!ok) {
        throw const FormatException(
            'Current encrypted-file password is incorrect.');
      }
    }
    final filePasswordWasCleared = useSeparateFilePassword &&
        current.hasFilePassword &&
        filePasswordChangeRequested &&
        normalizedFilePassword.isEmpty;
    final effectiveFilePassword = useSeparateFilePassword
        ? normalizedFilePassword
        : normalizedAppPassword;
    final appPasswordForEnvelope = normalizedAppPassword.isNotEmpty
        ? normalizedAppPassword
        : normalizedCurrentAppPassword;
    if (effectiveFilePassword.isNotEmpty) {
      final salt = VaultCrypto.randomBytes(16);
      final digest =
          await VaultCrypto.passwordDigest(effectiveFilePassword, salt);
      Map<String, Object?>? envelope;
      if (rememberFilePasswords && appPasswordForEnvelope.isNotEmpty) {
        envelope = await VaultCrypto.encryptTextEnvelope(
          effectiveFilePassword,
          password: appPasswordForEnvelope,
        );
      }
      next = next.copyWith(
        filePasswordSalt: base64UrlEncode(salt),
        filePasswordDigest: digest,
        savedFilePasswordEnvelope: envelope,
        clearSavedFilePassword: envelope == null,
      );
    } else if (filePasswordWasCleared ||
        (!useSeparateFilePassword && appPasswordWasCleared)) {
      next = next.copyWith(
        clearFilePassword: true,
        clearSavedFilePassword: true,
      );
    } else if (!rememberFilePasswords) {
      next = next.copyWith(clearSavedFilePassword: true);
    }

    final normalizedKeyFilePath = commonEncryptionKeyFilePath?.trim() ?? '';
    var normalizedCommonPassword = commonEncryptionPassword?.trim() ?? '';
    if (normalizedCommonPassword.isEmpty && normalizedKeyFilePath.isNotEmpty) {
      final file = File(normalizedKeyFilePath);
      if (!await file.exists()) {
        throw const FormatException('Common encryption key file not found.');
      }
      normalizedCommonPassword =
          'file:${sha256.convert(await file.readAsBytes())}';
    }
    if (normalizedCommonPassword.isNotEmpty) {
      final salt = VaultCrypto.randomBytes(16);
      final digest =
          await VaultCrypto.passwordDigest(normalizedCommonPassword, salt);
      final envelope = await VaultCrypto.encryptTextEnvelope(
        normalizedCommonPassword,
        password: await _deviceSecret(),
      );
      next = next.copyWith(
        commonEncryptionSalt: base64UrlEncode(salt),
        commonEncryptionDigest: digest,
        commonEncryptionEnvelope: envelope,
      );
    }

    await save(next);
    return next;
  }

  Future<bool> verifyAppPassword(
      SecuritySettings settings, String password) async {
    if (!settings.hasAppPassword) {
      return true;
    }
    final salt = base64Url.decode(settings.appPasswordSalt!);
    final digest = await VaultCrypto.passwordDigest(password, salt);
    return digest == settings.appPasswordDigest;
  }

  Future<bool> verifyFilePassword(
      SecuritySettings settings, String password) async {
    if (!settings.hasFilePassword) {
      return password.isNotEmpty;
    }
    final salt = base64Url.decode(settings.filePasswordSalt!);
    final digest = await VaultCrypto.passwordDigest(password, salt);
    return digest == settings.filePasswordDigest;
  }

  Future<bool> verifyCommonEncryptionPassword(
      SecuritySettings settings, String password) async {
    if (!settings.hasCommonEncryption) {
      return false;
    }
    final salt = base64Url.decode(settings.commonEncryptionSalt!);
    final digest = await VaultCrypto.passwordDigest(password, salt);
    return digest == settings.commonEncryptionDigest;
  }

  Future<String?> loadCommonEncryptionPassword(
      SecuritySettings settings) async {
    final envelope = settings.commonEncryptionEnvelope;
    if (envelope == null) {
      return null;
    }
    return VaultCrypto.decryptTextEnvelope(
      envelope,
      password: await _deviceSecret(),
    );
  }

  Future<String> revealCommonEncryptionPassword({
    required SecuritySettings settings,
    required String guardPassword,
  }) async {
    if (settings.hasFilePassword) {
      final ok = await verifyFilePassword(settings, guardPassword);
      if (!ok) {
        throw const FormatException('Encrypted-file password is incorrect.');
      }
    } else if (settings.hasAppPassword) {
      final ok = await verifyAppPassword(settings, guardPassword);
      if (!ok) {
        throw const FormatException('App password is incorrect.');
      }
    }
    final common = await loadCommonEncryptionPassword(settings);
    if (common == null || common.isEmpty) {
      throw const FormatException('Common encryption key is not stored.');
    }
    return common;
  }

  Future<String?> loadRememberedFilePassword(
    SecuritySettings settings, {
    required String appPassword,
  }) async {
    final envelope = settings.savedFilePasswordEnvelope;
    if (envelope == null || appPassword.isEmpty) {
      return null;
    }
    return VaultCrypto.decryptTextEnvelope(envelope, password: appPassword);
  }

  Future<SecuritySettings> registerFailedLogin(
      SecuritySettings settings) async {
    var next = settings.copyWith(
        failedLoginAttempts: settings.failedLoginAttempts + 1);
    if (settings.wipeSavedPasswordsOnFailedLogin) {
      next = next.copyWith(
          clearSavedFilePassword: true, rememberFilePasswords: false);
    }
    await save(next);
    return next;
  }

  Future<SecuritySettings> clearSavedFilePassword(
      SecuritySettings settings) async {
    final next = settings.copyWith(
        clearSavedFilePassword: true, rememberFilePasswords: false);
    await save(next);
    return next;
  }

  Future<String> _deviceSecret() async {
    final appData = await AppPaths.appDataDirectory();
    final file = File(
        '${appData.path}${Platform.pathSeparator}securevault_device_secret.key');
    if (await file.exists()) {
      final existing = (await file.readAsString()).trim();
      if (existing.isNotEmpty) {
        return existing;
      }
    }
    final secret = base64UrlEncode(VaultCrypto.randomBytes(32));
    await file.writeAsString(secret, flush: true);
    return secret;
  }
}
