import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_html/flutter_html.dart' as flutter_html;
import 'package:image/image.dart' as img;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart'
    as syncfusion_pdfviewer;
import 'package:webview_flutter/webview_flutter.dart' as android_webview;
import 'package:webview_windows/webview_windows.dart' as windows_webview;

import 'src/explorer/explorer_models.dart';
import 'src/explorer/file_explorer_repository.dart';
import 'src/ffi/crypt_bindings.dart';
import 'src/i18n/app_language.dart';
import 'src/logging/app_log.dart';
import 'src/platform_services.dart';
import 'src/plugins/cloud_plugin_registry.dart' hide basename;
import 'src/plugins/connection_profile.dart';
import 'src/plugins/media_plugin_runtime.dart';
import 'src/security/security_settings.dart';
import 'src/security/vault_crypto.dart';
import 'src/storage/app_paths.dart';
import 'src/viewer/file_viewer_service.dart';
import 'src/viewer/media_artwork_service.dart';

const _appVersion = '0.12.17';
final _sharedMediaSession = _SharedMediaSession();

Future<void> main(List<String> args) async {
  await runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      unawaited(AppLog.write(
        'Flutter error',
        '${details.exceptionAsString()}\n${details.stack ?? ''}',
      ));
    };
    ui.PlatformDispatcher.instance.onError = (error, stack) {
      unawaited(AppLog.write('Platform dispatcher error', '$error\n$stack'));
      return false;
    };
    MediaKit.ensureInitialized();
    final initialSettings =
        await SecuritySettingsRepository().load().catchError((error, stack) {
      unawaited(AppLog.write('Failed to load settings', '$error\n$stack'));
      return const SecuritySettings();
    });
    AppLog.enabled = initialSettings.loggingEnabled;
    unawaited(AppLog.write('Application start ${args.join(' ')}'));
    runApp(SecureVaultApp(initialPath: args.isEmpty ? null : args.first));
  }, (error, stack) {
    unawaited(AppLog.write('Uncaught zone error', '$error\n$stack'));
  });
}

class SecureVaultApp extends StatelessWidget {
  const SecureVaultApp({super.key, this.initialPath});

  final String? initialPath;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppLanguage.russianTitle,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F4C81)),
        useMaterial3: true,
      ),
      home: VaultHomeScreen(initialOpenPath: initialPath),
    );
  }
}

enum ShellPage { explorer, gallery, music, video, documents, torrent, settings }

enum _CreateFileKind {
  plain,
  encryptedPlain,
  csv,
  encryptedCsv,
  image,
  encryptedImage
}

class _CreatedFileSpec {
  const _CreatedFileSpec({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

class _SearchDialogResult {
  const _SearchDialogResult({
    required this.query,
    required this.mode,
    required this.useRegex,
    required this.recursive,
  });

  final String query;
  final String mode;
  final bool useRegex;
  final bool recursive;
}

class _SearchFilters {
  const _SearchFilters({
    this.minSizeBytes,
    this.maxSizeBytes,
    this.createdFrom,
    this.createdTo,
    this.modifiedFrom,
    this.modifiedTo,
    this.minDurationSeconds,
    this.maxDurationSeconds,
  });

  final int? minSizeBytes;
  final int? maxSizeBytes;
  final DateTime? createdFrom;
  final DateTime? createdTo;
  final DateTime? modifiedFrom;
  final DateTime? modifiedTo;
  final int? minDurationSeconds;
  final int? maxDurationSeconds;

  bool get isEmpty =>
      minSizeBytes == null &&
      maxSizeBytes == null &&
      createdFrom == null &&
      createdTo == null &&
      modifiedFrom == null &&
      modifiedTo == null &&
      minDurationSeconds == null &&
      maxDurationSeconds == null;

  bool accepts(ExplorerEntry entry) {
    if (entry.isNavigationEntry || entry.isDirectory) return true;
    final size = entry.sizeBytes;
    if (minSizeBytes != null && size < minSizeBytes!) return false;
    if (maxSizeBytes != null && size > maxSizeBytes!) return false;
    final created = entry.createdAt ?? entry.modifiedAt;
    if (createdFrom != null && created.isBefore(createdFrom!)) return false;
    if (createdTo != null && created.isAfter(createdTo!)) return false;
    final modified = entry.modifiedAt;
    if (modifiedFrom != null && modified.isBefore(modifiedFrom!)) {
      return false;
    }
    if (modifiedTo != null && modified.isAfter(modifiedTo!)) return false;
    return true;
  }
}

class _FolderSortMode {
  const _FolderSortMode({
    required this.field,
    required this.ascending,
    required this.foldersFirst,
  });

  final String field;
  final bool ascending;
  final bool foldersFirst;

  static const defaultMode = _FolderSortMode(
    field: 'name',
    ascending: true,
    foldersFirst: true,
  );

  factory _FolderSortMode.parse(String? value) {
    if (value == null || value.trim().isEmpty) return defaultMode;
    final parts = value.split(':');
    return _FolderSortMode(
      field: parts.isNotEmpty ? parts[0] : 'name',
      ascending: parts.length < 2 ? true : parts[1] != 'desc',
      foldersFirst: parts.length < 3 ? true : parts[2] == 'foldersFirst',
    );
  }

  String encode() =>
      '$field:${ascending ? 'asc' : 'desc'}:${foldersFirst ? 'foldersFirst' : 'mixed'}';

  String label(AppLanguage language) {
    final fieldLabel = switch (field) {
      'modified' => language.t('sort.modified'),
      'created' => language.t('sort.created'),
      'size' => language.t('sort.size'),
      'extension' => language.t('sort.extension'),
      _ => language.t('sort.name'),
    };
    return '$fieldLabel ${ascending ? language.t('sort.asc') : language.t('sort.desc')}';
  }

  List<ExplorerEntry> sort(List<ExplorerEntry> entries) {
    final sorted = [...entries];
    sorted.sort((a, b) {
      if (a.isNavigationEntry != b.isNavigationEntry) {
        return a.isNavigationEntry ? -1 : 1;
      }
      if (foldersFirst && a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      final result = switch (field) {
        'modified' => a.modifiedAt.compareTo(b.modifiedAt),
        'created' =>
          (a.createdAt ?? a.modifiedAt).compareTo(b.createdAt ?? b.modifiedAt),
        'size' => a.sizeBytes.compareTo(b.sizeBytes),
        'extension' => FileViewerService.extensionForName(a.name)
            .compareTo(FileViewerService.extensionForName(b.name)),
        _ => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      };
      if (result != 0) return ascending ? result : -result;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return sorted;
  }
}

class _BackgroundJob {
  _BackgroundJob({required this.title, required this.total});

  final String title;
  final int total;
  var completed = 0;
  var status = '';
  var collapsed = false;
  var cancelled = false;
  var done = false;
  var failed = false;

  double get progress => total <= 0 ? 0 : completed / total;
}

class _ReadingSession {
  _ReadingSession({
    required this.title,
    required this.key,
    required this.chunks,
    required this.paths,
    required this.pathIndex,
    required this.chunkIndex,
    this.playing = true,
  });

  final String title;
  final String key;
  final List<String> chunks;
  final List<String> paths;
  final int pathIndex;
  final int chunkIndex;
  final bool playing;

  _ReadingSession copyWith({
    String? title,
    String? key,
    List<String>? chunks,
    List<String>? paths,
    int? pathIndex,
    int? chunkIndex,
    bool? playing,
  }) =>
      _ReadingSession(
        title: title ?? this.title,
        key: key ?? this.key,
        chunks: chunks ?? this.chunks,
        paths: paths ?? this.paths,
        pathIndex: pathIndex ?? this.pathIndex,
        chunkIndex: chunkIndex ?? this.chunkIndex,
        playing: playing ?? this.playing,
      );
}

class VaultHomeScreen extends StatefulWidget {
  const VaultHomeScreen({super.key, this.initialOpenPath});

  final String? initialOpenPath;

  @override
  State<VaultHomeScreen> createState() => _VaultHomeScreenState();
}

class _VaultHomeScreenState extends State<VaultHomeScreen>
    with WidgetsBindingObserver {
  late final CryptBindings _bindings;
  late final FileExplorerRepository _explorer;
  late final CloudPluginRegistry _plugins;
  late final WebMusicPluginService _webMusicPlugins;
  late final SecuritySettingsRepository _settingsRepo;

  var _loading = true;
  var _locked = false;
  var _page = ShellPage.explorer;
  var _locations = <ExplorerLocation>[];
  var _pluginDefs = <CloudPluginDefinition>[];
  var _pluginMediaSections = <PluginMediaSection>[];
  PluginMediaSection? _activePluginMediaSection;
  var _settings = const SecuritySettings();
  var _language = AppLanguage.builtIn('ru');
  var _runtime = CryptRuntimeInfo.unavailable;
  String? _filePassword;
  String? _commonEncryptionPassword;
  DateTime? _filePasswordValidUntil;
  String? _currentPath;
  ExplorerEntry? _selected;
  Future<DirectorySnapshot>? _snapshot;
  Future<FilePreview>? _preview;
  List<MediaPreviewItem> _mediaPlaylist = const [];
  List<MediaPreviewItem> _imagePlaylist = const [];
  List<MediaPreviewItem> _flashPlaylist = const [];
  double _sidebarWidth = 290;
  double _previewWidth = 420;
  bool _previewVisible = false;
  List<String> _clipboardPaths = const [];
  Map<String, String> _clipboardNames = const <String, String>{};
  bool _clipboardCut = false;
  bool _showingRecent = false;
  bool _showingLocations = false;
  String _searchQuery = '';
  String _searchMode = 'name';
  bool _searchUseRegex = false;
  bool _searchRecursive = false;
  _SearchFilters _searchFilters = const _SearchFilters();
  bool _goingUp = false;
  final List<String> _backStack = <String>[];
  final List<String> _forwardStack = <String>[];
  Set<String> _selectedPaths = const <String>{};
  bool _lockOnNextResume = false;
  final List<_BackgroundJob> _backgroundJobs = <_BackgroundJob>[];
  _ReadingSession? _readingSession;
  Timer? _readingTimer;
  Timer? _locationsRefreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bindings = CryptBindings();
    _explorer = FileExplorerRepository(_bindings);
    _plugins = CloudPluginRegistry();
    _webMusicPlugins = const WebMusicPluginService();
    _settingsRepo = SecuritySettingsRepository();
    _boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _readingTimer?.cancel();
    _locationsRefreshTimer?.cancel();
    unawaited(PlatformServices.stopSpeaking());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!Platform.isAndroid ||
        !_settings.requirePasswordOnAndroidResume ||
        !_settings.hasAppPassword) {
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _lockOnNextResume = true;
      return;
    }
    if (state == AppLifecycleState.resumed && _lockOnNextResume && mounted) {
      _lockOnNextResume = false;
      setState(() => _locked = true);
    }
  }

  Future<void> _boot() async {
    final settings = await _settingsRepo.load();
    AppLog.enabled = settings.loggingEnabled;
    final language = await AppLanguage.load(settings);
    MediaArtworkService.configure(
      cacheEnabled: settings.cacheThumbnailsInMemory,
      persistentCacheEnabled: true,
      encryptPersistentCache: settings.encryptThumbnailCache,
    );
    await PlatformServices.setWindowTitle(language.appTitle).catchError((_) {});
    final commonPassword = !settings.hasFilePassword && !settings.hasAppPassword
        ? await _settingsRepo
            .loadCommonEncryptionPassword(settings)
            .catchError((_) => null)
        : null;
    await PlatformServices.setScreenProtection(settings.blockScreenCapture);
    await PlatformServices.setMinimizeToTrayOnClose(
      settings.minimizeToTrayOnClose,
    ).catchError((_) {});
    final runtime = await _bindings.getRuntimeInfo();
    final pluginDefs = await _plugins.loadPlugins();
    final enabledPluginDefs = _enabledPluginDefs(pluginDefs, settings);
    _explorer.configurePlugins(enabledPluginDefs, settings.connectionProfiles);
    final locations = await _explorer.loadLocations(
        enabledPluginDefs, settings.connectionProfiles);
    final pluginMediaSections =
        PluginRuntime(enabledPluginDefs, settings.pluginSettingsById)
            .mediaSections();
    final first =
        locations.where((e) => e.enabled && e.path != null).firstOrNull;

    String? currentPath = first?.path;
    if (settings.rememberLastFolder &&
        settings.lastOpenedFolder != null &&
        settings.lastOpenedFolder!.trim().isNotEmpty &&
        await Directory(settings.lastOpenedFolder!.trim()).exists()) {
      currentPath = settings.lastOpenedFolder!.trim();
    }
    ExplorerEntry? selected;
    Future<FilePreview>? preview;
    final initialPath = widget.initialOpenPath ??
        await PlatformServices.getInitialOpenPath().catchError((_) => null);
    if (initialPath != null && initialPath.trim().isNotEmpty) {
      final entry = await _explorer.entryForPath(initialPath.trim());
      if (entry != null) {
        if (entry.isDirectory) {
          currentPath = entry.path;
        } else {
          currentPath = File(entry.path).parent.path;
          selected = entry;
          preview = _explorer.previewFile(
            entry.path,
            password: _activeFilePassword(),
            commonPassword: commonPassword,
          );
        }
      }
    }

    setState(() {
      _settings = settings;
      _language = language;
      _searchMode = settings.searchMode;
      _searchUseRegex = settings.searchUseRegex;
      _searchRecursive = settings.searchRecursive;
      _commonEncryptionPassword = commonPassword;
      _runtime = runtime;
      _pluginDefs = pluginDefs;
      _pluginMediaSections = pluginMediaSections;
      _locations = locations;
      _currentPath = currentPath;
      _selected = selected;
      _preview = preview;
      _previewVisible = settings.rememberPreviewVisibility
          ? settings.savedPreviewVisible
          : settings.previewVisibleByDefault;
      _mediaPlaylist = const [];
      _imagePlaylist = const [];
      _snapshot = currentPath == null ? null : _directorySnapshot(currentPath);
      _locked = settings.hasAppPassword;
      _loading = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_maybeRequestAndroidStorageAccess());
    });
    _startLocationsAutoRefresh();
  }

  void _startLocationsAutoRefresh() {
    _locationsRefreshTimer?.cancel();
    _locationsRefreshTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(_refreshLocationsSilently()),
    );
  }

  Future<void> _refreshLocationsSilently() async {
    if (_loading || _locked) return;
    try {
      final pluginDefs = await _plugins.loadPlugins();
      final enabledPluginDefs = _enabledPluginDefs(pluginDefs, _settings);
      _explorer.configurePlugins(
        enabledPluginDefs,
        _settings.connectionProfiles,
      );
      final locations = await _explorer.loadLocations(
        enabledPluginDefs,
        _settings.connectionProfiles,
      );
      final pluginMediaSections =
          PluginRuntime(enabledPluginDefs, _settings.pluginSettingsById)
              .mediaSections();
      if (!mounted) return;
      final locationsChanged =
          _locationsSignature(locations) != _locationsSignature(_locations);
      final pluginsChanged = _pluginDefs.map((item) => item.id).join('|') !=
          pluginDefs.map((item) => item.id).join('|');
      if (!locationsChanged && !pluginsChanged) return;
      setState(() {
        _pluginDefs = pluginDefs;
        _pluginMediaSections = pluginMediaSections;
        _locations = locations;
        if (_showingLocations) {
          _snapshot = _explorer.snapshotForLocations(
            _language.t('nav.explorer'),
            locations,
            extraPaths: [
              ..._settings.galleryFolders,
              ..._settings.musicFolders,
              ..._settings.videoFolders,
              ..._settings.documentFolders,
            ],
          );
        }
      });
    } catch (_) {
      // Location refresh is opportunistic; user-initiated refresh still reports errors.
    }
  }

  String _locationsSignature(List<ExplorerLocation> locations) => locations
      .map((item) =>
          '${item.id}\u001f${item.name}\u001f${item.path}\u001f${item.enabled}')
      .join('\u001e');

  Future<void> _maybeRequestAndroidStorageAccess() async {
    if (!Platform.isAndroid ||
        _locked ||
        _settings.androidStoragePermissionPromptDismissed ||
        !mounted) {
      return;
    }
    final status = await PlatformServices.androidStorageAccessStatus()
        .catchError((_) => AndroidStorageAccessStatus.notAndroid());
    if (!mounted || !status.needsRequest) return;
    final allow = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_language.t('android.storage.title')),
        content: Text(_language.t('android.storage.body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_language.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_language.t('android.storage.open')),
          ),
        ],
      ),
    );
    if (allow == true) {
      await PlatformServices.requestAndroidStorageAccess().catchError((_) {});
      final next = await _settingsRepo
          .setAndroidStoragePermissionPromptDismissed(_settings, true);
      if (mounted) setState(() => _settings = next);
    } else {
      final next = await _settingsRepo
          .setAndroidStoragePermissionPromptDismissed(_settings, true);
      if (mounted) setState(() => _settings = next);
    }
  }

  Future<void> _requestAndroidStorageAccessFromSettings() async {
    await PlatformServices.requestAndroidStorageAccess().catchError((_) {});
    final next = await _settingsRepo.setAndroidStoragePermissionPromptDismissed(
      _settings,
      true,
    );
    if (mounted) {
      setState(() => _settings = next);
      _snack(_language.t('android.storage.requested'));
    }
  }

  Future<void> _unlock(String password) async {
    final ok = await _settingsRepo.verifyAppPassword(_settings, password);
    if (!ok) {
      final next = await _settingsRepo.registerFailedLogin(_settings);
      setState(() => _settings = next);
      _snack(_language.t('snack.bad.password'));
      return;
    }
    String? remembered;
    try {
      remembered = await _settingsRepo.loadRememberedFilePassword(
        _settings,
        appPassword: password,
      );
    } catch (_) {
      remembered = null;
    }
    setState(() {
      _locked = false;
      if (remembered != null && remembered.isNotEmpty) {
        _setSessionFilePassword(remembered);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_maybeRequestAndroidStorageAccess());
    });
    if (!_settings.hasFilePassword) {
      final common = await _settingsRepo
          .loadCommonEncryptionPassword(_settings)
          .catchError((_) => null);
      if (mounted) setState(() => _commonEncryptionPassword = common);
    }
  }

  void _openPath(String path, {bool recordHistory = true}) {
    final previousPath = _currentPath;
    final changedPath = previousPath == null ||
        _normalizePath(previousPath) != _normalizePath(path);
    unawaited(_rememberOpenedFolder(path));
    unawaited(_applyFolderRuntimeProtection(path));
    setState(() {
      if (recordHistory &&
          previousPath != null &&
          previousPath.trim().isNotEmpty &&
          _normalizePath(previousPath) != _normalizePath(path) &&
          !_showingRecent) {
        _backStack.add(previousPath);
        if (_backStack.length > 100) _backStack.removeAt(0);
        _forwardStack.clear();
      }
      _page = ShellPage.explorer;
      _activePluginMediaSection = null;
      _showingRecent = false;
      _showingLocations = false;
      _currentPath = path;
      _selected = null;
      _preview = null;
      _mediaPlaylist = const [];
      _imagePlaylist = const [];
      _selectedPaths = const <String>{};
      if (changedPath) {
        _searchQuery = '';
        _searchFilters = const _SearchFilters();
        _searchRecursive = false;
      }
      _snapshot = _directorySnapshot(path);
    });
  }

  Future<void> _rememberOpenedFolder(String path) async {
    if (!_settings.rememberLastFolder || path.trim().isEmpty) return;
    if (!_folderBehaviorFor(path).rememberLocationOnOpen) return;
    final next = await _settingsRepo
        .recordLastOpenedFolder(_settings, path)
        .catchError((_) => _settings);
    if (mounted && next.lastOpenedFolder != _settings.lastOpenedFolder) {
      setState(() => _settings = next);
    }
  }

  Future<void> _openPathSafely(
    String path, {
    bool fromUp = false,
    bool recordHistory = true,
  }) async {
    if (_explorer.isVirtualPath(path)) {
      final entry = await _explorer.entryForPath(path);
      if (entry != null && entry.isDirectory) {
        _openPath(path, recordHistory: recordHistory);
      } else {
        _snack(_language.t('path.unavailable'));
        _openLocationsHome();
      }
      return;
    }
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      _openPath(path, recordHistory: recordHistory);
      return;
    }
    if (type == FileSystemEntityType.notFound) {
      _snack(_language.t('path.unavailable'));
      _openLocationsHome();
      return;
    }
    final policy = _settings.navigationPolicy;
    if (policy == 'allow') {
      _openPath(path, recordHistory: recordHistory);
      return;
    }
    if (policy == 'ask' && mounted) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(_language.t('path.unavailable')),
          content: Text(_language.t('path.unavailable.ask')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(_language.t('common.cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(_language.t('common.open')),
            ),
          ],
        ),
      );
      if (go == true) _openPath(path, recordHistory: recordHistory);
      return;
    }
    if (fromUp && policy == 'fallbackToLocations') {
      _openLocationsHome();
      return;
    }
    if (policy == 'requestRoot') {
      _snack(_language.t('path.root.unavailable'));
      return;
    }
    _snack(_language.t('path.unavailable'));
  }

  Future<DirectorySnapshot> _directorySnapshot(String path) =>
      _explorer.listDirectory(
        path,
        commonPassword: _commonEncryptionPassword,
        filePassword: _activeFilePassword(),
        decryptNames: _settings.decryptNamesInExplorer,
      );

  FolderBehaviorSettings _folderBehaviorFor(String? path) {
    final normalized = _normalizeSettingPath(path);
    if (normalized.isEmpty) return const FolderBehaviorSettings();
    final visited = <String>{};
    var cursor = normalized;
    while (cursor.isNotEmpty && visited.add(cursor)) {
      final behavior = _settings.folderBehaviorByPath[cursor];
      if (behavior != null && !behavior.inheritParent) return behavior;
      final parent = _settingParentPath(cursor);
      if (parent == cursor || parent.isEmpty) break;
      cursor = parent;
    }
    return const FolderBehaviorSettings();
  }

  String _normalizeSettingPath(String? path) {
    final value = path?.trim() ?? '';
    if (value.isEmpty) return '';
    if (Platform.isWindows && !value.startsWith(RegExp(r'^[a-z]+://'))) {
      return value.replaceAll('/', r'\').toLowerCase();
    }
    return value.replaceAll(RegExp(r'/+$'), '');
  }

  String _settingParentPath(String path) {
    if (path.startsWith('remote://')) {
      return _explorer.parentPathFor(path);
    }
    try {
      return Directory(path).parent.path;
    } catch (_) {
      return '';
    }
  }

  bool _rememberRecentForEntry(ExplorerEntry entry) {
    if (!_settings.rememberRecentFiles) return false;
    final parent =
        entry.isDirectory ? entry.path : _explorer.parentPathFor(entry.path);
    return _folderBehaviorFor(parent).rememberRecent;
  }

  bool _isMiniPlaybackAllowedForPath(String? path) {
    if (path == null || path.trim().isEmpty) return true;
    final parent = _explorer.parentPathFor(path);
    final behavior = _folderBehaviorFor(parent);
    return !behavior.forbidMiniPlayback && !behavior.forbidBackgroundPlayback;
  }

  Future<void> _applyFolderRuntimeProtection(String path) async {
    final behavior = _folderBehaviorFor(path);
    await PlatformServices.setScreenProtection(
      _settings.blockScreenCapture || behavior.blockScreenshots,
    ).catchError((_) {});
    if (Platform.isAndroid &&
        (behavior.disableCamera || behavior.disableMicrophone)) {
      await PlatformServices.setPrivacyHints(
        disableCamera: behavior.disableCamera,
        disableMicrophone: behavior.disableMicrophone,
      ).catchError((_) {});
    }
  }

  List<CloudPluginDefinition> _enabledPluginDefs([
    List<CloudPluginDefinition>? plugins,
    SecuritySettings? settings,
  ]) {
    final disabled = (settings ?? _settings).disabledPluginIds.toSet();
    return [
      for (final plugin in plugins ?? _pluginDefs)
        if (!disabled.contains(plugin.id)) plugin,
    ];
  }

  PluginRuntime _pluginRuntime([
    List<CloudPluginDefinition>? plugins,
    SecuritySettings? settings,
  ]) =>
      PluginRuntime(
        _enabledPluginDefs(plugins ?? _pluginDefs, settings ?? _settings),
        settings?.pluginSettingsById ?? _settings.pluginSettingsById,
      );

  Future<void> _toggleHiddenFiles() async {
    final next =
        _settings.copyWith(showHiddenFiles: !_settings.showHiddenFiles);
    await _settingsRepo.save(next);
    if (!mounted) return;
    setState(() => _settings = next);
    await _refresh();
  }

  Future<void> _toggleSystemFiles() async {
    final next =
        _settings.copyWith(showSystemFiles: !_settings.showSystemFiles);
    await _settingsRepo.save(next);
    if (!mounted) return;
    setState(() => _settings = next);
    await _refresh();
  }

  void _handleExplorerMenuAction(_ExplorerMenuAction action) {
    switch (action) {
      case _ExplorerMenuAction.upload:
        _importFile();
      case _ExplorerMenuAction.download:
        _exportFile();
      case _ExplorerMenuAction.downloadUrl:
        _showYtDlpDownloadDialog(_currentPath);
      case _ExplorerMenuAction.sort:
        _sortDialog();
      case _ExplorerMenuAction.toggleHidden:
        unawaited(_toggleHiddenFiles());
      case _ExplorerMenuAction.toggleSystem:
        unawaited(_toggleSystemFiles());
      case _ExplorerMenuAction.folderSettings:
        final path = _currentPath;
        if (path != null && !_showingRecent && !_showingLocations) {
          unawaited(_showFolderSettingsDialog(path));
        }
    }
  }

  Future<void> _refresh() async {
    if (_showingLocations) {
      final enabledPluginDefs = _enabledPluginDefs();
      _explorer.configurePlugins(
          enabledPluginDefs, _settings.connectionProfiles);
      final locations = await _explorer.loadLocations(
        enabledPluginDefs,
        _settings.connectionProfiles,
      );
      final extraPaths = <String>[
        ..._settings.galleryFolders,
        ..._settings.musicFolders,
        ..._settings.videoFolders,
        ..._settings.documentFolders,
      ];
      if (!mounted) return;
      setState(() {
        _locations = locations;
        _snapshot = _explorer.snapshotForLocations(
          _language.t('nav.explorer'),
          locations,
          extraPaths: extraPaths,
        );
      });
      return;
    }
    final pluginSection = _activePluginMediaSection;
    if (pluginSection != null) {
      _openPluginMediaSection(pluginSection);
      return;
    }
    final mediaSection = switch (_page) {
      ShellPage.gallery => MediaSection.gallery,
      ShellPage.music => MediaSection.music,
      ShellPage.video => MediaSection.video,
      ShellPage.documents => MediaSection.documents,
      ShellPage.torrent => MediaSection.torrent,
      _ => null,
    };
    if (mediaSection != null) {
      _openMediaSection(mediaSection);
      return;
    }
    final path = _currentPath;
    setState(() {
      _snapshot = _showingRecent
          ? _explorer.snapshotForPaths(
              _language.t('recent.title'),
              _settings.recentFilePaths
                  .take(_settings.recentRememberCount)
                  .toList(),
            )
          : path == null
              ? null
              : _directorySnapshot(path);
      if (_selected != null) {
        _preview = _explorer.previewFile(
          _selected!.path,
          password: _activeFilePassword(),
          commonPassword: _commonEncryptionPassword,
        );
      }
    });
  }

  void _togglePreviewVisibility() {
    final nextVisible = !_previewVisible;
    setState(() => _previewVisible = nextVisible);
    if (_settings.rememberPreviewVisibility) {
      unawaited(_settingsRepo
          .setPreviewVisibility(_settings, nextVisible)
          .then((next) {
        if (mounted) setState(() => _settings = next);
      }).catchError((_) {}));
    }
  }

  void _selectLocation(ExplorerLocation location) {
    if (!location.enabled || location.path == null) {
      _showProvider(location);
      return;
    }
    unawaited(_openPathSafely(location.path!));
  }

  Future<void> _showAddLocationDialog() async {
    final candidates = _pluginDefs
        .where((plugin) => _explorer.supportsRemotePlugin(plugin))
        .toList();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_language.t('locations.add')),
        content: SizedBox(
          width: 460,
          child: candidates.isEmpty
              ? Text(_language.t('locations.add.empty'))
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final plugin in candidates)
                      ListTile(
                        leading: const Icon(Icons.add_link),
                        title: Text(plugin.name),
                        subtitle: Text(plugin.description ??
                            _language.t('settings.plugins.note')),
                        onTap: () {
                          Navigator.pop(context);
                          unawaited(_showConnectionProfileDialog(plugin));
                        },
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_language.t('common.cancel')),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(context);
              setState(() => _page = ShellPage.settings);
            },
            icon: const Icon(Icons.settings_applications_outlined),
            label: Text(_language.t('settings.plugins.open.window')),
          ),
        ],
      ),
    );
  }

  Future<void> _showConnectionProfileDialog(
    CloudPluginDefinition plugin,
  ) async {
    final profile = await showDialog<PluginConnectionProfile>(
      context: context,
      builder: (context) => _ConnectionProfileDialog(
        language: _language,
        plugin: plugin,
        availableProfiles: _settings.connectionProfiles,
      ),
    );
    if (profile == null) {
      return;
    }
    final nextProfiles = <PluginConnectionProfile>[
      ..._settings.connectionProfiles,
      profile,
    ];
    final nextSettings =
        await _settingsRepo.setConnectionProfiles(_settings, nextProfiles);
    final enabledPluginDefs = _enabledPluginDefs(_pluginDefs, nextSettings);
    _explorer.configurePlugins(
        enabledPluginDefs, nextSettings.connectionProfiles);
    final locations = await _explorer.loadLocations(
      enabledPluginDefs,
      nextSettings.connectionProfiles,
    );
    if (!mounted) return;
    setState(() {
      _settings = nextSettings;
      _locations = locations;
    });
    _snack('${_language.t('locations.profile.created')} ${profile.name}');
    final created = locations
        .where((location) => location.pluginId == profile.runtimePluginId)
        .firstOrNull;
    if (created != null && created.path != null) {
      unawaited(_openPathSafely(created.path!));
    }
  }

  PluginConnectionProfile? _connectionProfileForEntry(ExplorerEntry entry) {
    final id = entry.connectionProfileId;
    if (id == null) {
      return null;
    }
    return _settings.connectionProfiles
        .where((profile) => profile.id == id)
        .firstOrNull;
  }

  CloudPluginDefinition? _pluginForProfile(PluginConnectionProfile profile) {
    return _pluginDefs
        .where((plugin) => plugin.id == profile.pluginId)
        .firstOrNull;
  }

  Future<void> _editConnectionProfile(ExplorerEntry entry) async {
    final profile = _connectionProfileForEntry(entry);
    if (profile == null) {
      _snack(_language.t('locations.profile.missing'));
      return;
    }
    final plugin = _pluginForProfile(profile);
    if (plugin == null) {
      _snack(_language.t('locations.profile.plugin.missing'));
      return;
    }
    final updated = await showDialog<PluginConnectionProfile>(
      context: context,
      builder: (context) => _ConnectionProfileDialog(
        language: _language,
        plugin: plugin,
        initialProfile: profile,
        availableProfiles: _settings.connectionProfiles,
      ),
    );
    if (updated == null) {
      return;
    }
    final profiles = _settings.connectionProfiles
        .map((item) => item.id == updated.id ? updated : item)
        .toList();
    final nextSettings =
        await _settingsRepo.setConnectionProfiles(_settings, profiles);
    final enabledPluginDefs = _enabledPluginDefs(_pluginDefs, nextSettings);
    _explorer.configurePlugins(
        enabledPluginDefs, nextSettings.connectionProfiles);
    final locations = await _explorer.loadLocations(
      enabledPluginDefs,
      nextSettings.connectionProfiles,
    );
    if (!mounted) return;
    setState(() {
      _settings = nextSettings;
      _locations = locations;
    });
    _openLocationsHome();
    _snack('${_language.t('locations.profile.updated')} ${updated.name}');
  }

  Future<void> _deleteConnectionProfile(ExplorerEntry entry) async {
    final profile = _connectionProfileForEntry(entry);
    if (profile == null) {
      _snack(_language.t('locations.profile.missing'));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_language.t('locations.profile.delete')),
        content: Text(
          '${_language.t('locations.profile.delete.confirm')}\n${profile.name}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_language.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_language.t('common.delete')),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    final profiles = _settings.connectionProfiles
        .where((item) => item.id != profile.id)
        .toList();
    final nextSettings =
        await _settingsRepo.setConnectionProfiles(_settings, profiles);
    final enabledPluginDefs = _enabledPluginDefs(_pluginDefs, nextSettings);
    _explorer.configurePlugins(
        enabledPluginDefs, nextSettings.connectionProfiles);
    final locations = await _explorer.loadLocations(
      enabledPluginDefs,
      nextSettings.connectionProfiles,
    );
    if (!mounted) return;
    setState(() {
      _settings = nextSettings;
      _locations = locations;
      if (_selected?.connectionProfileId == profile.id) {
        _selected = null;
        _preview = null;
      }
    });
    _openLocationsHome();
    _snack('${_language.t('locations.profile.deleted')} ${profile.name}');
  }

  void _openExplorerHome() {
    unawaited(_openLastWorkspaceOrLocations());
  }

  Future<void> _openLastWorkspaceOrLocations() async {
    final candidates = <String>[
      if (_settings.rememberLastFolder &&
          _settings.lastOpenedFolder != null &&
          _settings.lastOpenedFolder!.trim().isNotEmpty)
        _settings.lastOpenedFolder!.trim(),
      if (_currentPath != null && _currentPath!.trim().isNotEmpty)
        _currentPath!.trim(),
    ];
    for (final path in candidates) {
      if (_explorer.isVirtualPath(path)) {
        final entry = await _explorer.entryForPath(path);
        if (entry?.isDirectory == true) {
          _openPath(path);
          return;
        }
        continue;
      }
      if (await Directory(path).exists()) {
        _openPath(path);
        return;
      }
    }
    _openLocationsHome();
  }

  void _openLocationsHome() {
    final extraPaths = <String>[
      ..._settings.galleryFolders,
      ..._settings.musicFolders,
      ..._settings.videoFolders,
      ..._settings.documentFolders,
    ];
    setState(() {
      _page = ShellPage.explorer;
      _activePluginMediaSection = null;
      _showingRecent = false;
      _showingLocations = true;
      _selected = null;
      _preview = null;
      _mediaPlaylist = const [];
      _imagePlaylist = const [];
      _selectedPaths = const <String>{};
      _snapshot = _explorer.snapshotForLocations(
        _language.t('nav.explorer'),
        _locations,
        extraPaths: extraPaths,
      );
    });
  }

  void _openMediaSection(MediaSection section) {
    unawaited(_openMediaSectionAsync(section));
  }

  Future<void> _openMediaSectionAsync(MediaSection section) async {
    _activePluginMediaSection = null;
    if (section == MediaSection.torrent &&
        (!_settings.torrentEnabled || !_pluginRuntime().hasTorrentPlugin)) {
      _snack(_language.t('settings.torrent.disabled'));
      return;
    }
    final (page, label, configuredRoots, extensions, exclusions) =
        switch (section) {
      MediaSection.gallery => (
          ShellPage.gallery,
          _language.t('nav.gallery'),
          _settings.galleryFolders,
          {
            ...FileViewerService.imageExtensions,
            ...FileViewerService.videoExtensions,
          },
          _settings.galleryExclusions,
        ),
      MediaSection.music => (
          ShellPage.music,
          _language.t('nav.music'),
          _settings.musicFolders,
          FileViewerService.audioExtensions,
          _settings.musicExclusions,
        ),
      MediaSection.video => (
          ShellPage.video,
          _language.t('nav.video'),
          _settings.videoFolders,
          FileViewerService.videoExtensions,
          _settings.videoExclusions,
        ),
      MediaSection.documents => (
          ShellPage.documents,
          _language.t('nav.documents'),
          _settings.documentFolders,
          {
            ...FileViewerService.documentExtensions,
            ...FileViewerService.textExtensions,
            ...FileViewerService.htmlExtensions,
          },
          _settings.documentExclusions,
        ),
      MediaSection.torrent => (
          ShellPage.torrent,
          _language.t('nav.torrent'),
          const <String>[],
          {'.torrent'},
          '',
        ),
    };
    final roots = section == MediaSection.torrent
        ? const <String>[]
        : _mediaRootsFor(configuredRoots, section);
    final baseSnapshotFuture = section == MediaSection.torrent
        ? _torrentSectionSnapshot()
        : _explorer.mediaSnapshot(
            label: label,
            roots: roots,
            extensions: extensions,
            exclusions: exclusions,
          );
    final snapshotFuture = _searchQuery.trim().isEmpty
        ? baseSnapshotFuture
        : baseSnapshotFuture.then(_filterSnapshotBySearch);
    setState(() {
      _page = page;
      _activePluginMediaSection = null;
      _showingRecent = false;
      _showingLocations = false;
      _currentPath = label;
      _selected = null;
      _preview = null;
      _mediaPlaylist = const [];
      _imagePlaylist = const [];
      _selectedPaths = const <String>{};
      _snapshot = snapshotFuture;
    });
    if (section != MediaSection.music && section != MediaSection.video) {
      return;
    }
    final snapshot = await snapshotFuture;
    if (!mounted || _page != page || snapshot.entries.isEmpty) return;
    final kind = section == MediaSection.video
        ? FileContentKind.video
        : FileContentKind.audio;
    final playlist = _mediaItemsFromEntries(snapshot.entries, kind);
    setState(() {
      _selected = null;
      _preview = null;
      _mediaPlaylist = playlist;
      _imagePlaylist = const [];
    });
  }

  Future<DirectorySnapshot> _torrentSectionSnapshot() async {
    final dir = await AppPaths.torrentsDirectory();
    final snapshot = await _explorer.listDirectory(
      dir.path,
      commonPassword: _commonEncryptionPassword,
      filePassword: _activeFilePassword(),
      decryptNames: _settings.decryptNamesInExplorer,
    );
    return DirectorySnapshot(
      path: snapshot.path,
      entries:
          snapshot.entries.where((entry) => !entry.isNavigationEntry).toList(),
      error: snapshot.error,
    );
  }

  List<String> _mediaRootsFor(
    List<String> configuredRoots,
    MediaSection section,
  ) {
    final configured = configuredRoots
        .map((item) => item.trim())
        .map(_expandPathVariables)
        .where((item) => item.isNotEmpty)
        .toList();
    if (configured.isNotEmpty) return configured;

    final roots = <String>[..._standardMediaRoots(section)];
    for (final location in _locations) {
      final path = location.path;
      if (!location.enabled || path == null || path.isEmpty) continue;
      if (Platform.isAndroid &&
          location.kind == ExplorerLocationKind.local &&
          path == '/') {
        continue;
      }
      roots.add(path);
    }
    if (roots.isEmpty && Platform.isAndroid) {
      roots.add('/storage/emulated/0');
    }
    final seen = <String>{};
    return [
      for (final root in roots)
        if (seen.add(Platform.isWindows ? root.toLowerCase() : root)) root,
    ];
  }

  List<String> _standardMediaRoots(MediaSection section) {
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        (Platform.isAndroid ? '/storage/emulated/0' : null);
    if (home == null || home.isEmpty) return const <String>[];
    final sep = Platform.pathSeparator;
    if (Platform.isAndroid) {
      const base = '/storage/emulated/0';
      return switch (section) {
        MediaSection.gallery => [
            '$base/DCIM',
            '$base/Pictures',
            '$base/Movies',
            '$base/Download',
          ],
        MediaSection.music => ['$base/Music', '$base/Download'],
        MediaSection.video => ['$base/Movies', '$base/DCIM', '$base/Download'],
        MediaSection.documents => [
            '$base/Documents',
            '$base/Download',
          ],
        MediaSection.torrent => const <String>[],
      };
    }
    return switch (section) {
      MediaSection.gallery => [
          '$home${sep}Pictures',
          '$home${sep}Videos',
        ],
      MediaSection.music => ['$home${sep}Music'],
      MediaSection.video => ['$home${sep}Videos'],
      MediaSection.documents => [
          '$home${sep}Documents',
          '$home${sep}Downloads',
        ],
      MediaSection.torrent => const <String>[],
    };
  }

  String _expandPathVariables(String value) {
    var path = value.trim();
    if (path.isEmpty) return path;
    for (final entry in Platform.environment.entries) {
      path = path
          .replaceAll('%${entry.key}%', entry.value)
          .replaceAll('\$${entry.key}', entry.value)
          .replaceAll('\${${entry.key}}', entry.value);
    }
    if (path.startsWith('~')) {
      final home = Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          '';
      path = '$home${path.substring(1)}';
    }
    return path;
  }

  List<MediaPreviewItem> _mediaItemsFromEntries(
    List<ExplorerEntry> entries,
    FileContentKind kind,
  ) =>
      [
        for (final entry in entries)
          if (!entry.isDirectory &&
              (FileViewerService.kindForName(entry.name) == kind ||
                  FileViewerService.kindForName(entry.path) == kind))
            MediaPreviewItem(
              title: entry.name,
              kind: kind,
              path: entry.path,
              resumeKey: entry.path,
              encrypted: entry.isEncrypted,
            ),
      ];

  void _openRecentFiles() {
    setState(() {
      _page = ShellPage.explorer;
      _activePluginMediaSection = null;
      _showingRecent = true;
      _showingLocations = false;
      _selected = null;
      _preview = null;
      _mediaPlaylist = const [];
      _imagePlaylist = const [];
      _selectedPaths = const <String>{};
      _snapshot = _explorer.snapshotForPaths(
        _language.t('recent.title'),
        _settings.recentFilePaths.take(_settings.recentRememberCount).toList(),
      );
    });
  }

  void _openFavoriteFiles() {
    setState(() {
      _page = ShellPage.explorer;
      _activePluginMediaSection = null;
      _showingRecent = false;
      _showingLocations = false;
      _selected = null;
      _preview = null;
      _mediaPlaylist = const [];
      _imagePlaylist = const [];
      _selectedPaths = const <String>{};
      _snapshot = _explorer.snapshotForPaths(
        _language.t('favorites.title'),
        _settings.favoritePaths,
      );
    });
  }

  Future<void> _openFavoritePath(String path) async {
    final entry = await _explorer.entryForPath(path);
    if (entry == null) {
      _snack(_language.t('favorites.missing'));
      return;
    }
    await _openEntry(entry);
  }

  Future<void> _toggleFavorite(ExplorerEntry entry) async {
    final paths = [..._settings.favoritePaths];
    if (paths.contains(entry.path)) {
      paths.remove(entry.path);
    } else {
      paths.insert(0, entry.path);
    }
    final next = await _settingsRepo.updateFavorites(_settings, paths);
    if (mounted) {
      setState(() => _settings = next);
    }
  }

  Future<void> _removeRecentPath(String path) async {
    final next = await _settingsRepo.removeRecentFile(_settings, path);
    if (mounted) {
      setState(() {
        _settings = next;
        if (_showingRecent) {
          _snapshot = _explorer.snapshotForPaths(
            _language.t('recent.title'),
            next.recentFilePaths.take(next.recentRememberCount).toList(),
          );
        }
      });
    }
  }

  Future<void> _offerRemoveMissingRecent(String path) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_language.t('recent.missing.title')),
        content: Text('${_language.t('recent.missing.body')}\n$path'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_language.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_language.t('recent.remove')),
          ),
        ],
      ),
    );
    if (remove == true) {
      await _removeRecentPath(path);
    }
  }

  Future<void> _openEntry(
    ExplorerEntry entry, {
    bool forceFullScreen = false,
    List<MediaPreviewItem>? mediaPlaylistOverride,
  }) async {
    if (entry.isNavigationEntry &&
        await _navigationEntryReturnsToLocations(_currentPath)) {
      _openLocationsHome();
      return;
    }
    if (!entry.exists) {
      await _offerRemoveMissingRecent(entry.path);
      return;
    }
    final activePluginSection = _activePluginMediaSection;
    if (entry.isDirectory &&
        activePluginSection != null &&
        _isHttpMedia(entry.path)) {
      _openPluginMediaSection(PluginMediaSection(
        pluginId: activePluginSection.pluginId,
        sectionId: activePluginSection.sectionId,
        siteId: '${activePluginSection.siteId ?? activePluginSection.sectionId}'
            ':${entry.path}',
        title: entry.name,
        kind: activePluginSection.kind,
        baseUrl: entry.path,
        searchPath: activePluginSection.searchPath,
      ));
      return;
    }
    if (entry.isDirectory) {
      await _openPathSafely(entry.path);
      return;
    }
    if (FileViewerService.kindForName(entry.path) == FileContentKind.archive &&
        !_explorer.isVirtualPath(entry.path)) {
      final extension = FileViewerService.extensionForName(entry.path);
      if (extension == '.zip') {
        await _openPathSafely(_explorer.zipRootPath(entry.path));
        return;
      }
      if (extension == '.rar' || extension == '.cbr' || extension == '.rev') {
        if (_pluginRuntime().handlesFileExtension(extension)) {
          await _openPathSafely(_explorer.rarRootPath(entry.path));
          return;
        }
      }
      return;
    }
    if (FileViewerService.extensionForName(entry.path) == '.torrent' &&
        !_explorer.isVirtualPath(entry.path) &&
        _settings.torrentEnabled &&
        _pluginRuntime().handlesFileExtension('.torrent')) {
      final imported = await _explorer.importTorrentToVault(entry.path);
      await _openPathSafely(_explorer.torrentRootPath(imported.path));
      return;
    }
    if (_isHttpMedia(entry.path)) {
      final kind = FileViewerService.kindForName(entry.name);
      final preview = FilePreview(
        title: entry.name,
        subtitle: entry.path,
        sourcePath: entry.path,
        contentKind:
            kind == FileContentKind.unknown ? FileContentKind.audio : kind,
      );
      final previewFuture = Future<FilePreview>.value(preview);
      final playlist = mediaPlaylistOverride?.isNotEmpty == true
          ? mediaPlaylistOverride!
          : _mediaPlaylist.isEmpty
              ? [
                  MediaPreviewItem(
                    title: entry.name,
                    kind: preview.contentKind,
                    path: entry.path,
                    resumeKey: entry.path,
                  ),
                ]
              : _mediaPlaylist;
      setState(() {
        _selected = entry;
        _preview = previewFuture;
        _mediaPlaylist = playlist;
        _imagePlaylist = const [];
        _flashPlaylist = const [];
      });
      if (_shouldPlayInLocationMini(preview, forceFullScreen) ||
          _shouldPlayInExistingMini(preview) ||
          (_isMediaLibraryPage && _isPlayablePreview(preview))) {
        await _playMediaPreviewInSession(preview, playlist);
      } else if (_shouldOpenMediaFullscreen(preview, forceFullScreen)) {
        _showPreviewWindow(preview);
      }
      if (_rememberRecentForEntry(entry)) {
        final next =
            await _settingsRepo.recordRecentFile(_settings, entry.path);
        if (mounted) setState(() => _settings = next);
      }
      return;
    }
    final previewFuture = _explorer.previewFile(
      entry.path,
      password: _activeFilePassword(),
      commonPassword: _commonEncryptionPassword,
    );
    setState(() {
      _selected = entry;
      _preview = previewFuture;
      _mediaPlaylist = const [];
      _imagePlaylist = const [];
      _flashPlaylist = const [];
    });
    FilePreview? openedPreview;
    try {
      final preview = await previewFuture;
      openedPreview = preview;
      final playlist = mediaPlaylistOverride?.isNotEmpty == true
          ? _playlistWithSelectedPreview(
              preview,
              mediaPlaylistOverride!,
              selectedPath: entry.path,
            )
          : await _buildMediaPlaylist(entry, preview);
      final imagePlaylist = await _buildImagePlaylist(entry, preview);
      final flashPlaylist = await _buildFlashPlaylist(entry, preview);
      if (mounted && _selected?.path == entry.path) {
        setState(() {
          _mediaPlaylist = playlist;
          _imagePlaylist = imagePlaylist;
          _flashPlaylist = flashPlaylist;
        });
      }
    } catch (_) {
      if (mounted && _selected?.path == entry.path) {
        setState(() {
          _mediaPlaylist = const [];
          _imagePlaylist = const [];
          _flashPlaylist = const [];
        });
      }
    }
    if (mounted &&
        openedPreview != null &&
        _storedExtensionOpenMode(entry) != null) {
      final mode = _storedExtensionOpenMode(entry)!;
      if (mode == 'external') {
        await _openPreviewExternal(openedPreview);
        return;
      }
      final resolved = await _coercePreviewKind(openedPreview, mode);
      openedPreview = resolved;
      final playlist = mediaPlaylistOverride?.isNotEmpty == true
          ? _playlistWithSelectedPreview(
              resolved,
              mediaPlaylistOverride!,
              selectedPath: entry.path,
            )
          : await _buildMediaPlaylist(entry, resolved);
      final imagePlaylist = await _buildImagePlaylist(entry, resolved);
      final flashPlaylist = await _buildFlashPlaylist(entry, resolved);
      if (mounted && _selected?.path == entry.path) {
        setState(() {
          _preview = Future<FilePreview>.value(resolved);
          _mediaPlaylist = playlist;
          _imagePlaylist = imagePlaylist;
          _flashPlaylist = flashPlaylist;
        });
      }
    } else if (mounted &&
        openedPreview != null &&
        openedPreview.contentKind == FileContentKind.unknown) {
      final resolved = await _resolveUnknownPreview(entry, openedPreview);
      if (resolved == null) return;
      if (resolved.contentKind != openedPreview.contentKind ||
          resolved.text != openedPreview.text) {
        openedPreview = resolved;
        final playlist = mediaPlaylistOverride?.isNotEmpty == true
            ? _playlistWithSelectedPreview(
                resolved,
                mediaPlaylistOverride!,
                selectedPath: entry.path,
              )
            : await _buildMediaPlaylist(entry, resolved);
        final imagePlaylist = await _buildImagePlaylist(entry, resolved);
        final flashPlaylist = await _buildFlashPlaylist(entry, resolved);
        if (mounted && _selected?.path == entry.path) {
          setState(() {
            _preview = Future<FilePreview>.value(resolved);
            _mediaPlaylist = playlist;
            _imagePlaylist = imagePlaylist;
            _flashPlaylist = flashPlaylist;
          });
        }
      }
    }
    if (mounted &&
        openedPreview != null &&
        (_shouldPlayInLocationMini(openedPreview, forceFullScreen) ||
            _shouldPlayInExistingMini(openedPreview) ||
            (_isMediaLibraryPage && _isPlayablePreview(openedPreview)))) {
      await _playMediaPreviewInSession(openedPreview, _mediaPlaylist);
    } else if (mounted &&
        openedPreview != null &&
        _shouldOpenMediaFullscreen(openedPreview, forceFullScreen)) {
      _showPreviewWindow(openedPreview);
    }
    if (_rememberRecentForEntry(entry)) {
      final next = await _settingsRepo.recordRecentFile(_settings, entry.path);
      if (mounted) {
        setState(() => _settings = next);
      }
    }
  }

  String? _storedExtensionOpenMode(ExplorerEntry entry) {
    final extension = FileViewerService.extensionForName(entry.name).isNotEmpty
        ? FileViewerService.extensionForName(entry.name)
        : FileViewerService.extensionForName(entry.path);
    if (extension.isEmpty) return null;
    final mode = _settings.unknownExtensionModes[extension];
    if (mode == null || mode.isEmpty || mode == 'internal') return null;
    return mode;
  }

  Future<FilePreview?> _resolveUnknownPreview(
    ExplorerEntry entry,
    FilePreview preview,
  ) async {
    final extension = FileViewerService.extensionForName(entry.name).isNotEmpty
        ? FileViewerService.extensionForName(entry.name)
        : FileViewerService.extensionForName(entry.path);
    final storedMode = _settings.unknownExtensionModes[extension];
    final choice = storedMode == null || storedMode.isEmpty
        ? await _unknownExtensionDialog(extension)
        : (mode: storedMode, remember: false);
    if (choice == null) return preview;
    if (choice.remember && extension.isNotEmpty) {
      final next = await _settingsRepo.setUnknownExtensionMode(
        _settings,
        extension,
        choice.mode,
      );
      if (mounted) setState(() => _settings = next);
    }
    if (choice.mode == 'external') {
      await _openPreviewExternal(preview);
      return null;
    }
    return _coercePreviewKind(preview, choice.mode);
  }

  Future<({String mode, bool remember})?> _unknownExtensionDialog(
    String extension,
  ) async {
    var remember = extension.isNotEmpty;
    return showDialog<({String mode, bool remember})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(_language.t('preview.unsupported.title')),
          content: SizedBox(
            width: 460,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(_language.t('preview.unknown.body')),
              if (extension.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('${_language.t('common.extension')}: $extension'),
                CheckboxListTile(
                  value: remember,
                  onChanged: (value) =>
                      setDialogState(() => remember = value ?? false),
                  title: Text(_language.t('preview.unknown.remember')),
                ),
              ],
            ]),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_language.t('common.cancel')),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, (mode: 'text', remember: remember)),
              child: Text(_language.t('preview.force.text')),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, (mode: 'audio', remember: remember)),
              child: Text(_language.t('preview.force.audio')),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, (mode: 'video', remember: remember)),
              child: Text(_language.t('preview.force.video')),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, (mode: 'image', remember: remember)),
              child: Text(_language.t('preview.force.image')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                  context, (mode: 'external', remember: remember)),
              child: Text(_language.t('preview.external')),
            ),
          ],
        ),
      ),
    );
  }

  Future<FilePreview> _coercePreviewKind(
    FilePreview preview,
    String mode,
  ) async {
    final kind = switch (mode) {
      'text' => FileContentKind.text,
      'audio' => FileContentKind.audio,
      'video' => FileContentKind.video,
      'image' => FileContentKind.image,
      _ => FileContentKind.unknown,
    };
    var bytes = preview.bytes;
    var text = preview.text;
    final path = preview.sourcePath;
    if (bytes == null &&
        path != null &&
        !_explorer.isVirtualPath(path) &&
        !_isHttpMedia(path)) {
      try {
        final file = File(path);
        final stat = await file.stat();
        final limit = kind == FileContentKind.image
            ? 25 * 1024 * 1024
            : kind == FileContentKind.text
                ? 5 * 1024 * 1024
                : 80 * 1024 * 1024;
        if (stat.size <= limit) {
          bytes = await file.readAsBytes();
        }
      } catch (_) {}
    }
    if (kind == FileContentKind.text && bytes != null) {
      text = FileViewerService.bytesToText(bytes);
    }
    return FilePreview(
      title: preview.title,
      subtitle: '${preview.subtitle}\n${_language.t('preview.forced')}',
      sourcePath: preview.sourcePath,
      text: text,
      bytes: bytes,
      containerInfo: preview.containerInfo,
      decrypted: preview.decrypted,
      contentKind: kind,
    );
  }

  Future<void> _openEntryAs(ExplorerEntry entry, String mode) async {
    if (entry.isDirectory || !entry.exists) return;
    try {
      final raw = await _explorer.previewFile(
        entry.path,
        password: _activeFilePassword(),
        commonPassword: _commonEncryptionPassword,
      );
      final preview = await _coercePreviewKind(raw, mode);
      final previewFuture = Future<FilePreview>.value(preview);
      final mediaPlaylist = await _buildMediaPlaylist(entry, preview);
      final imagePlaylist = await _buildImagePlaylist(entry, preview);
      final flashPlaylist = await _buildFlashPlaylist(entry, preview);
      if (!mounted) return;
      setState(() {
        _selected = entry;
        _preview = previewFuture;
        _mediaPlaylist = mediaPlaylist;
        _imagePlaylist = imagePlaylist;
        _flashPlaylist = flashPlaylist;
      });
      if (_isPlayablePreview(preview) &&
          (_shouldPlayInExistingMini(preview) || !_previewVisible)) {
        await _playMediaPreviewInSession(preview, mediaPlaylist);
      }
    } catch (error) {
      _snack('${_language.t('snack.operation.error')} $error');
    }
  }

  Future<bool> _navigationEntryReturnsToLocations(String? path) async {
    if (path == null || path.trim().isEmpty) return false;
    final hidden = await AppPaths.hiddenVaultDirectory();
    final normalized = _normalizePath(path);
    if (normalized == _normalizePath(hidden.path)) return true;
    if (Platform.isAndroid &&
        (normalized == _normalizePath('/storage/emulated/0') ||
            normalized == _normalizePath('/sdcard'))) {
      return true;
    }
    return false;
  }

  Future<List<MediaPreviewItem>> _buildImagePlaylist(
    ExplorerEntry selected,
    FilePreview selectedPreview,
  ) async {
    if (selectedPreview.contentKind != FileContentKind.image) {
      return const [];
    }

    final selectedItem = MediaPreviewItem(
      title: selectedPreview.title,
      kind: FileContentKind.image,
      path: selected.path,
      bytes: selectedPreview.decrypted && selectedPreview.bytes != null
          ? Uint8List.fromList(selectedPreview.bytes!)
          : null,
      encrypted: selectedPreview.decrypted,
    );

    final parent = _explorer.parentPathFor(selected.path);
    final DirectorySnapshot snapshot;
    try {
      snapshot = await _explorer.listDirectory(
        parent,
        commonPassword: _commonEncryptionPassword,
        filePassword: _activeFilePassword(),
        decryptNames: _settings.decryptNamesInExplorer,
      );
    } catch (_) {
      return [selectedItem];
    }

    final sortedEntries = _sortModeForPath(parent).sort(snapshot.entries);
    final items = <MediaPreviewItem>[];
    for (final entry in sortedEntries) {
      if (!entry.exists || entry.isDirectory) continue;
      final displayedKind = FileViewerService.kindForName(entry.name);
      final pathKind = FileViewerService.kindForName(entry.path);
      final isSelected = entry.path == selected.path;
      if (!isSelected &&
          displayedKind != FileContentKind.image &&
          pathKind != FileContentKind.image) {
        continue;
      }
      if (isSelected) {
        items.add(selectedItem);
        continue;
      }
      items.add(MediaPreviewItem(
        title: entry.name,
        kind: FileContentKind.image,
        path: entry.path,
        encrypted: entry.isEncrypted,
      ));
    }

    if (!items.any((item) => item.path == selectedItem.path)) {
      items.insert(0, selectedItem);
    }
    return items;
  }

  Future<FilePreview?> _navigateImage(int delta) async {
    final selectedPath = _selected?.path;
    if (selectedPath == null || _imagePlaylist.isEmpty) return null;
    var index = _imagePlaylist.indexWhere((item) => item.path == selectedPath);
    if (index < 0) index = 0;
    final nextIndex = (index + delta) % _imagePlaylist.length;
    final normalizedIndex =
        nextIndex < 0 ? nextIndex + _imagePlaylist.length : nextIndex;
    final item = _imagePlaylist[normalizedIndex];
    final path = item.path;
    if (path == null || path.isEmpty) return null;
    final entry = await _explorer.entryForPath(path);
    if (entry == null) return null;
    final previewFuture = _explorer.previewFile(
      entry.path,
      password: _activeFilePassword(),
      commonPassword: _commonEncryptionPassword,
    );
    setState(() {
      _selected = entry;
      _preview = previewFuture;
      _mediaPlaylist = const [];
      _flashPlaylist = const [];
    });
    try {
      final preview = await previewFuture;
      final imagePlaylist = await _buildImagePlaylist(entry, preview);
      if (mounted && _selected?.path == entry.path) {
        setState(() => _imagePlaylist = imagePlaylist);
      }
      return preview;
    } catch (_) {
      return null;
    }
  }

  Future<List<MediaPreviewItem>> _buildFlashPlaylist(
    ExplorerEntry selected,
    FilePreview selectedPreview,
  ) async {
    if (selectedPreview.contentKind != FileContentKind.flash) {
      return const [];
    }
    final selectedItem = MediaPreviewItem(
      title: selectedPreview.title,
      kind: FileContentKind.flash,
      path: selected.path,
      bytes: selectedPreview.decrypted && selectedPreview.bytes != null
          ? Uint8List.fromList(selectedPreview.bytes!)
          : null,
      encrypted: selectedPreview.decrypted,
    );
    final parent = _explorer.parentPathFor(selected.path);
    final DirectorySnapshot snapshot;
    try {
      snapshot = await _explorer.listDirectory(
        parent,
        commonPassword: _commonEncryptionPassword,
        filePassword: _activeFilePassword(),
        decryptNames: _settings.decryptNamesInExplorer,
      );
    } catch (_) {
      return [selectedItem];
    }
    final items = <MediaPreviewItem>[];
    for (final entry in snapshot.entries) {
      if (!entry.exists || entry.isDirectory) continue;
      final displayedKind = FileViewerService.kindForName(entry.name);
      final pathKind = FileViewerService.kindForName(entry.path);
      if (entry.path == selected.path) {
        items.add(selectedItem);
      } else if (displayedKind == FileContentKind.flash ||
          pathKind == FileContentKind.flash) {
        items.add(MediaPreviewItem(
          title: entry.name,
          kind: FileContentKind.flash,
          path: entry.path,
          encrypted: entry.isEncrypted,
        ));
      }
    }
    if (!items.any((item) => item.path == selectedItem.path)) {
      items.insert(0, selectedItem);
    }
    return items;
  }

  Future<FilePreview?> _navigateFlash(int delta) async {
    final selectedPath = _selected?.path;
    if (selectedPath == null || _flashPlaylist.isEmpty) return null;
    var index = _flashPlaylist.indexWhere((item) => item.path == selectedPath);
    if (index < 0) index = 0;
    final nextIndex = (index + delta) % _flashPlaylist.length;
    final normalizedIndex =
        nextIndex < 0 ? nextIndex + _flashPlaylist.length : nextIndex;
    final item = _flashPlaylist[normalizedIndex];
    final path = item.path;
    if (path == null || path.isEmpty) return null;
    final entry = await _explorer.entryForPath(path);
    if (entry == null) return null;
    final previewFuture = _explorer.previewFile(
      entry.path,
      password: _activeFilePassword(),
      commonPassword: _commonEncryptionPassword,
    );
    setState(() {
      _selected = entry;
      _preview = previewFuture;
      _mediaPlaylist = const [];
      _imagePlaylist = const [];
    });
    try {
      final preview = await previewFuture;
      final flashPlaylist = await _buildFlashPlaylist(entry, preview);
      if (mounted && _selected?.path == entry.path) {
        setState(() => _flashPlaylist = flashPlaylist);
      }
      return preview;
    } catch (_) {
      return null;
    }
  }

  Future<List<MediaPreviewItem>> _buildMediaPlaylist(
    ExplorerEntry selected,
    FilePreview selectedPreview,
  ) async {
    final kind = selectedPreview.contentKind;
    if (kind != FileContentKind.audio && kind != FileContentKind.video) {
      return const [];
    }
    final selectedSource = selectedPreview.sourcePath;
    final selectedPlayablePath = selectedPreview.decrypted
        ? null
        : selectedSource != null &&
                selectedSource.isNotEmpty &&
                !_explorer.isVirtualPath(selectedSource)
            ? selectedSource
            : selected.path;

    final selectedItem = MediaPreviewItem(
      title: selectedPreview.title,
      kind: kind,
      path: selectedPlayablePath,
      resumeKey: selected.path,
      bytes: selectedPreview.decrypted && selectedPreview.bytes != null
          ? Uint8List.fromList(selectedPreview.bytes!)
          : null,
      encrypted: selectedPreview.decrypted,
    );

    final parent = _explorer.parentPathFor(selected.path);
    final DirectorySnapshot snapshot;
    try {
      snapshot = await _explorer.listDirectory(
        parent,
        commonPassword: _commonEncryptionPassword,
        filePassword: _activeFilePassword(),
        decryptNames: _settings.decryptNamesInExplorer,
      );
    } catch (_) {
      return [selectedItem];
    }

    final items = <MediaPreviewItem>[];
    for (final entry in snapshot.entries) {
      if (!entry.exists || entry.isDirectory) continue;
      final displayedKind = FileViewerService.kindForName(entry.name);
      final pathKind = FileViewerService.kindForName(entry.path);
      final isSelected = entry.path == selected.path;
      if (!isSelected && displayedKind != kind && pathKind != kind) {
        continue;
      }

      if (isSelected) {
        items.add(selectedItem);
        continue;
      }

      if (entry.isEncrypted || _explorer.isVirtualPath(entry.path)) {
        if (displayedKind != kind) continue;
        try {
          final preview = await _explorer.previewFile(
            entry.path,
            password: _activeFilePassword(),
            commonPassword: _commonEncryptionPassword,
          );
          final previewSource = preview.sourcePath;
          if (preview.contentKind == kind && preview.bytes != null) {
            items.add(MediaPreviewItem(
              title: preview.title,
              kind: kind,
              resumeKey: entry.path,
              bytes: Uint8List.fromList(preview.bytes!),
              encrypted: true,
            ));
          } else if (preview.contentKind == kind &&
              previewSource != null &&
              previewSource.isNotEmpty &&
              !_explorer.isVirtualPath(previewSource)) {
            items.add(MediaPreviewItem(
              title: preview.title,
              kind: kind,
              path: previewSource,
              resumeKey: entry.path,
            ));
          }
        } catch (_) {
          // Keep the playlist usable even when one encrypted neighbor fails.
        }
        continue;
      }

      items.add(MediaPreviewItem(
        title: entry.name,
        kind: kind,
        path: entry.path,
        resumeKey: entry.path,
      ));
    }

    if (!items.any((item) =>
        item.path == selectedItem.path || item.title == selectedItem.title)) {
      items.insert(0, selectedItem);
    }
    return items;
  }

  Future<void> _openFolderMediaRecursive(
    ExplorerEntry folder,
    FileContentKind kind,
  ) async {
    if (!folder.isDirectory || !folder.exists) return;
    final matches = <ExplorerEntry>[];
    final stack = <String>[folder.path];
    final visited = <String>{};
    while (stack.isNotEmpty && matches.length < 5000) {
      final path = stack.removeLast();
      if (!visited.add(path)) continue;
      DirectorySnapshot snapshot;
      try {
        snapshot = await _explorer.listDirectory(
          path,
          commonPassword: _commonEncryptionPassword,
          filePassword: _activeFilePassword(),
          decryptNames: _settings.decryptNamesInExplorer,
        );
      } catch (_) {
        continue;
      }
      for (final entry in snapshot.entries) {
        if (!entry.exists || entry.isNavigationEntry) continue;
        if (entry.isDirectory) {
          stack.add(entry.path);
          continue;
        }
        final displayedKind = FileViewerService.kindForName(entry.name);
        final pathKind = FileViewerService.kindForName(entry.path);
        if (displayedKind == kind || pathKind == kind) {
          matches.add(entry);
        }
      }
    }
    if (matches.isEmpty) {
      _snack(_language.t('explorer.open.all.none'));
      return;
    }
    matches
        .sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    final first = matches.first;
    if (kind == FileContentKind.image) {
      final previewFuture = _explorer.previewFile(
        first.path,
        password: _activeFilePassword(),
        commonPassword: _commonEncryptionPassword,
      );
      setState(() {
        _selected = first;
        _preview = previewFuture;
        _mediaPlaylist = const [];
        _flashPlaylist = const [];
        _imagePlaylist = [
          for (final entry in matches)
            MediaPreviewItem(
              title: entry.name,
              kind: FileContentKind.image,
              path: entry.path,
              encrypted: entry.isEncrypted,
            ),
        ];
      });
      final preview = await previewFuture;
      _showPreviewWindow(preview);
      return;
    }
    final playlist = _mediaItemsFromEntries(matches, kind);
    await _openEntry(first, mediaPlaylistOverride: playlist);
  }

  void _goUp() {
    if (_goingUp) return;
    if (_showingRecent) {
      setState(() {
        _showingRecent = false;
        _selected = null;
        _preview = null;
        _mediaPlaylist = const [];
        _imagePlaylist = const [];
        _snapshot =
            _currentPath == null ? null : _directorySnapshot(_currentPath!);
      });
      return;
    }
    final path = _currentPath;
    if (path == null) return;
    _goingUp = true;
    unawaited(() async {
      try {
        final hidden = await AppPaths.hiddenVaultDirectory();
        if (_normalizePath(path) == _normalizePath(hidden.path) ||
            (Platform.isAndroid &&
                (_normalizePath(path) ==
                        _normalizePath('/storage/emulated/0') ||
                    _normalizePath(path) == _normalizePath('/sdcard')))) {
          _openLocationsHome();
          return;
        }
        final parent = _explorer.parentPathFor(path);
        if (_normalizePath(parent) != _normalizePath(path)) {
          await _openPathSafely(parent, fromUp: true);
        } else {
          _openLocationsHome();
        }
      } finally {
        _goingUp = false;
      }
    }());
  }

  void _goBack() {
    if (_backStack.isEmpty) {
      _goUp();
      return;
    }
    final target = _backStack.removeLast();
    final current = _currentPath;
    if (current != null && current.trim().isNotEmpty) {
      _forwardStack.add(current);
    }
    unawaited(_openPathSafely(target, recordHistory: false));
  }

  void _goForward() {
    if (_forwardStack.isEmpty) return;
    final target = _forwardStack.removeLast();
    final current = _currentPath;
    if (current != null && current.trim().isNotEmpty) {
      _backStack.add(current);
    }
    unawaited(_openPathSafely(target, recordHistory: false));
  }

  Future<void> _openWithPassword() async {
    final selected = _selected;
    if (selected == null) return;
    final password = await _passwordDialog(
      _language.t('preview.open.password'),
      initial: _activeFilePassword(),
    );
    if (password == null || password.isEmpty) return;
    if (_settings.hasFilePassword &&
        !await _settingsRepo.verifyFilePassword(_settings, password)) {
      _snack(_language.t('snack.file.password.mismatch'));
      return;
    }
    setState(() {
      _setSessionFilePassword(password);
      _preview = _explorer.previewFile(
        selected.path,
        password: password,
        commonPassword: _commonEncryptionPassword,
      );
    });
  }

  Future<void> _editPathDialog() async {
    final controller = TextEditingController(text: _currentPath ?? '');
    final path = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_language.t('path.edit')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: _language.t('common.path')),
          onSubmitted: (_) => Navigator.pop(context, controller.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_language.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(_language.t('common.open')),
          ),
        ],
      ),
    );
    if (path == null || path.trim().isEmpty) return;
    final type = await FileSystemEntity.type(path.trim(), followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      _snack(_language.t('path.unavailable'));
      return;
    }
    if (type == FileSystemEntityType.directory) {
      await _openPathSafely(path.trim());
    } else {
      final entry = await _explorer.entryForPath(path.trim());
      if (entry == null) {
        _snack(_language.t('path.unavailable'));
      } else {
        await _openEntry(entry);
      }
    }
  }

  Future<void> _showPathDropdown() async {
    final choices = <(String, String)>[
      for (final location in _locations)
        if (location.enabled && location.path != null)
          (location.name, location.path!),
      if (_settings.includeFavoritesInPathDropdown)
        for (final path in _settings.favoritePaths) (basename(path), path),
    ];
    if (choices.isEmpty) {
      _snack(_language.t('explorer.choose.location.left'));
      return;
    }
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                _language.t('explorer.choose.location'),
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            for (final item in choices)
              ListTile(
                leading: const Icon(Icons.folder_open_outlined),
                title: Text(item.$1),
                subtitle: Text(item.$2, maxLines: 1),
                onTap: () => Navigator.pop(context, item.$2),
              ),
          ],
        ),
      ),
    );
    if (selected == null || selected.trim().isEmpty) return;
    final entry = await _explorer.entryForPath(selected);
    if (entry == null) {
      await _openPathSafely(selected);
    } else if (entry.isDirectory) {
      await _openPathSafely(entry.path);
    } else {
      await _openEntry(entry);
    }
  }

  Future<void> _searchDialog() async {
    final controller = TextEditingController(text: _searchQuery);
    var mode = _searchMode;
    var useRegex = _searchUseRegex;
    var recursive = _searchRecursive;
    final allowFilters = _activePluginMediaSection == null;
    final result = await showDialog<_SearchDialogResult>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(_language.t('search.title')),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration:
                      InputDecoration(labelText: _language.t('search.query')),
                  onSubmitted: (_) => Navigator.pop(
                    context,
                    _SearchDialogResult(
                      query: controller.text,
                      mode: mode,
                      useRegex: useRegex,
                      recursive: recursive,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: mode,
                  decoration:
                      InputDecoration(labelText: _language.t('search.mode')),
                  items: [
                    DropdownMenuItem(
                      value: 'name',
                      child: Text(_language.t('search.mode.name')),
                    ),
                    DropdownMenuItem(
                      value: 'nameContent',
                      child: Text(_language.t('search.mode.name.content')),
                    ),
                    DropdownMenuItem(
                      value: 'content',
                      child: Text(_language.t('search.mode.content')),
                    ),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => mode = value ?? 'name'),
                ),
                SwitchListTile(
                  value: useRegex,
                  onChanged: (value) => setDialogState(() => useRegex = value),
                  title: Text(_language.t('search.regex')),
                ),
                SwitchListTile(
                  value: recursive,
                  onChanged: (value) => setDialogState(() => recursive = value),
                  title: Text(_language.t('search.recursive')),
                ),
                if (allowFilters)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        unawaited(_searchFiltersDialog());
                      },
                      icon: const Icon(Icons.tune_outlined),
                      label: Text(_language.t('search.filters')),
                    ),
                  ),
              ]),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(
                context,
                _SearchDialogResult(
                  query: '',
                  mode: mode,
                  useRegex: useRegex,
                  recursive: recursive,
                ),
              ),
              child: Text(_language.t('search.clear')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                _SearchDialogResult(
                  query: controller.text,
                  mode: mode,
                  useRegex: useRegex,
                  recursive: recursive,
                ),
              ),
              child: Text(_language.t('search.apply')),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    final query = result.query.trim();
    final nextSettings = _settings.copyWith(
      searchMode: result.mode,
      searchUseRegex: result.useRegex,
      searchRecursive: result.recursive,
    );
    unawaited(_settingsRepo.save(nextSettings));
    setState(() {
      _settings = nextSettings;
      _searchQuery = query;
      _searchMode = result.mode;
      _searchUseRegex = result.useRegex;
      _searchRecursive = result.recursive;
    });
    final pluginSection = _activePluginMediaSection;
    if (pluginSection != null) {
      _openPluginMediaSection(pluginSection);
      return;
    }
    final mediaSection = switch (_page) {
      ShellPage.gallery => MediaSection.gallery,
      ShellPage.music => MediaSection.music,
      ShellPage.video => MediaSection.video,
      ShellPage.documents => MediaSection.documents,
      ShellPage.torrent => MediaSection.torrent,
      _ => null,
    };
    if (mediaSection != null) {
      _openMediaSection(mediaSection);
      return;
    }
    final path = _currentPath;
    if (path == null || _showingRecent) return;
    if (query.isEmpty) {
      setState(() => _snapshot = _directorySnapshot(path));
      return;
    }
    if (result.mode != 'name' || result.recursive) {
      setState(() {
        _snapshot = _explorer.searchDirectory(
          path,
          query: query,
          mode: result.mode,
          useRegex: result.useRegex,
          recursive: result.recursive,
          commonPassword: _commonEncryptionPassword,
          filePassword: _activeFilePassword(),
          decryptNames: _settings.decryptNamesInExplorer,
        );
      });
    }
  }

  Future<void> _searchFiltersDialog() async {
    final minSize = TextEditingController(
      text: _searchFilters.minSizeBytes?.toString() ?? '',
    );
    final maxSize = TextEditingController(
      text: _searchFilters.maxSizeBytes?.toString() ?? '',
    );
    final createdFrom = TextEditingController(
      text: _dateInput(_searchFilters.createdFrom),
    );
    final createdTo = TextEditingController(
      text: _dateInput(_searchFilters.createdTo),
    );
    final modifiedFrom = TextEditingController(
      text: _dateInput(_searchFilters.modifiedFrom),
    );
    final modifiedTo = TextEditingController(
      text: _dateInput(_searchFilters.modifiedTo),
    );
    final minDuration = TextEditingController(
      text: _searchFilters.minDurationSeconds?.toString() ?? '',
    );
    final maxDuration = TextEditingController(
      text: _searchFilters.maxDurationSeconds?.toString() ?? '',
    );
    final result = await showDialog<_SearchFilters>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_language.t('search.filters')),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(_language.t('search.filters.note')),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: minSize,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                        labelText: _language.t('filter.size.min')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: maxSize,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                        labelText: _language.t('filter.size.max')),
                  ),
                ),
              ]),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: createdFrom,
                    decoration: InputDecoration(
                        labelText: _language.t('filter.created.from')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: createdTo,
                    decoration: InputDecoration(
                        labelText: _language.t('filter.created.to')),
                  ),
                ),
              ]),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: modifiedFrom,
                    decoration: InputDecoration(
                        labelText: _language.t('filter.modified.from')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: modifiedTo,
                    decoration: InputDecoration(
                        labelText: _language.t('filter.modified.to')),
                  ),
                ),
              ]),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: minDuration,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                        labelText: _language.t('filter.duration.min')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: maxDuration,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                        labelText: _language.t('filter.duration.max')),
                  ),
                ),
              ]),
            ]),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, const _SearchFilters()),
            child: Text(_language.t('search.clear')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              _SearchFilters(
                minSizeBytes: int.tryParse(minSize.text.trim()),
                maxSizeBytes: int.tryParse(maxSize.text.trim()),
                createdFrom: _parseDateInput(createdFrom.text),
                createdTo: _parseDateInput(createdTo.text, endOfDay: true),
                modifiedFrom: _parseDateInput(modifiedFrom.text),
                modifiedTo: _parseDateInput(modifiedTo.text, endOfDay: true),
                minDurationSeconds: int.tryParse(minDuration.text.trim()),
                maxDurationSeconds: int.tryParse(maxDuration.text.trim()),
              ),
            ),
            child: Text(_language.t('search.apply')),
          ),
        ],
      ),
    );
    if (result == null) return;
    setState(() => _searchFilters = result);
  }

  _FolderSortMode _sortModeForCurrentPath() {
    final path = _currentPath;
    if (path == null || _showingRecent) return _FolderSortMode.defaultMode;
    return _sortModeForPath(path);
  }

  _FolderSortMode _sortModeForPath(String path) {
    return _FolderSortMode.parse(_settings.folderSortModes[path]);
  }

  Future<void> _sortDialog() async {
    final path = _currentPath;
    if (path == null || _showingRecent) return;
    var mode = _sortModeForCurrentPath();
    final result = await showDialog<_FolderSortMode>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(_language.t('sort.title')),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                initialValue: mode.field,
                decoration: InputDecoration(labelText: _language.t('sort.by')),
                items: [
                  DropdownMenuItem(
                    value: 'name',
                    child: Text(_language.t('sort.name')),
                  ),
                  DropdownMenuItem(
                    value: 'modified',
                    child: Text(_language.t('sort.modified')),
                  ),
                  DropdownMenuItem(
                    value: 'created',
                    child: Text(_language.t('sort.created')),
                  ),
                  DropdownMenuItem(
                    value: 'size',
                    child: Text(_language.t('sort.size')),
                  ),
                  DropdownMenuItem(
                    value: 'extension',
                    child: Text(_language.t('sort.extension')),
                  ),
                ],
                onChanged: (value) => setDialogState(
                  () => mode = _FolderSortMode(
                    field: value ?? 'name',
                    ascending: mode.ascending,
                    foldersFirst: mode.foldersFirst,
                  ),
                ),
              ),
              SwitchListTile(
                value: mode.ascending,
                onChanged: (value) => setDialogState(
                  () => mode = _FolderSortMode(
                    field: mode.field,
                    ascending: value,
                    foldersFirst: mode.foldersFirst,
                  ),
                ),
                title: Text(mode.ascending
                    ? _language.t('sort.asc')
                    : _language.t('sort.desc')),
              ),
              SwitchListTile(
                value: mode.foldersFirst,
                onChanged: (value) => setDialogState(
                  () => mode = _FolderSortMode(
                    field: mode.field,
                    ascending: mode.ascending,
                    foldersFirst: value,
                  ),
                ),
                title: Text(_language.t('sort.folders.first')),
              ),
            ]),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_language.t('common.cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, mode),
              child: Text(_language.t('search.apply')),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    final next = await _settingsRepo.setFolderSortMode(
      _settings,
      path,
      result.encode(),
    );
    if (mounted) {
      setState(() {
        _settings = next;
        _snapshot = _directorySnapshot(path);
      });
    }
  }

  String _dateInput(DateTime? value) {
    if (value == null) return '';
    return '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
  }

  DateTime? _parseDateInput(String value, {bool endOfDay = false}) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    final parsed = DateTime.tryParse(trimmed);
    if (parsed == null) return null;
    if (!endOfDay) return parsed;
    return DateTime(parsed.year, parsed.month, parsed.day, 23, 59, 59, 999);
  }

  Future<void> _importFile() async {
    final target = _currentPath;
    if (target == null) return;
    final options = await _transferDialog(
      title: _language.t('transfer.upload.title'),
      target: target,
      includeSource: true,
      encryptedText: _language.t('transfer.upload.encrypted'),
      plainText: _language.t('transfer.upload.plain'),
    );
    if (options == null) return;
    final sourceSize = options.sourcePath == null
        ? 1
        : await File(options.sourcePath!).length().catchError((_) => 1);
    final job = _startBackgroundJob(
      _language.t('transfer.upload.title'),
      total: math.max(1, sourceSize),
    );
    var lastUiProgress = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      final file = await _explorer.importFile(
        options,
        shouldCancel: () => job.cancelled,
        onProgress: (completed, total) {
          final now = DateTime.now();
          if (completed >= total ||
              now.difference(lastUiProgress).inMilliseconds >= 220) {
            lastUiProgress = now;
            _updateBackgroundJob(
              job,
              completed: completed.clamp(0, math.max(1, total)).toInt(),
              status: options.sourcePath ?? '',
            );
          }
        },
      );
      _updateBackgroundJob(
        job,
        completed: math.max(1, sourceSize),
        done: true,
        status: file.path,
      );
      _snack('${_language.t('snack.uploaded')} ${file.path}');
      await _refresh();
    } catch (error) {
      _updateBackgroundJob(job, failed: true, status: '$error');
      _snack('${_language.t('snack.upload.error')} $error');
    }
  }

  Future<void> _exportFile() async {
    final selected = _selected;
    if (selected == null || selected.isDirectory) {
      _snack(_language.t('snack.download.select'));
      return;
    }
    final options = await _transferDialog(
      title: _language.t('transfer.download.title'),
      target: _currentPath ?? '',
      includeSource: false,
      encryptedText: _language.t('transfer.download.encrypted'),
      plainText: _language.t('transfer.download.plain'),
    );
    if (options == null) return;
    final totalBytes = math.max(1, selected.sizeBytes);
    final job = _startBackgroundJob(
      _language.t('transfer.download.title'),
      total: totalBytes,
    );
    var lastUiProgress = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      final file = await _explorer.exportFile(
        selected.path,
        options,
        shouldCancel: () => job.cancelled,
        onProgress: (completed, total) {
          final now = DateTime.now();
          if (completed >= total ||
              now.difference(lastUiProgress).inMilliseconds >= 220) {
            lastUiProgress = now;
            _updateBackgroundJob(
              job,
              completed: completed.clamp(0, math.max(1, totalBytes)).toInt(),
              status: selected.path,
            );
          }
        },
      );
      _updateBackgroundJob(
        job,
        completed: totalBytes,
        done: true,
        status: file.path,
      );
      _snack('${_language.t('snack.downloaded')} ${file.path}');
      await _refresh();
    } catch (error) {
      _updateBackgroundJob(job, failed: true, status: '$error');
      _snack('${_language.t('snack.download.error')} $error');
    }
  }

  Future<void> _handleEntryAction(
    ExplorerEntry entry,
    _EntryAction action,
  ) async {
    switch (action) {
      case _EntryAction.open:
        await _openEntry(entry);
      case _EntryAction.edit:
        await _editEntry(entry);
      case _EntryAction.create:
        return;
      case _EntryAction.createFolder:
        await _createFolder(entry);
      case _EntryAction.createPlain:
        await _createFile(entry, _CreateFileKind.plain);
      case _EntryAction.createEncryptedPlain:
        await _createFile(entry, _CreateFileKind.encryptedPlain);
      case _EntryAction.createCsv:
        await _createFile(entry, _CreateFileKind.csv);
      case _EntryAction.createEncryptedCsv:
        await _createFile(entry, _CreateFileKind.encryptedCsv);
      case _EntryAction.createImage:
        await _createFile(entry, _CreateFileKind.image);
      case _EntryAction.createEncryptedImage:
        await _createFile(entry, _CreateFileKind.encryptedImage);
      case _EntryAction.openAs:
        return;
      case _EntryAction.openAsText:
        await _openEntryAs(entry, 'text');
      case _EntryAction.openAsImage:
        await _openEntryAs(entry, 'image');
      case _EntryAction.openAsAudio:
        await _openEntryAs(entry, 'audio');
      case _EntryAction.openAsVideo:
        await _openEntryAs(entry, 'video');
      case _EntryAction.encrypt:
        await _encryptSelectedFile(entry);
      case _EntryAction.decrypt:
        await _decryptSelectedFile(entry);
      case _EntryAction.copy:
        setState(() {
          _clipboardPaths = [entry.path];
          _clipboardNames = {entry.path: entry.name};
          _clipboardCut = false;
        });
        _snack(_language.t('snack.copied'));
      case _EntryAction.cut:
        setState(() {
          _clipboardPaths = [entry.path];
          _clipboardNames = {entry.path: entry.name};
          _clipboardCut = true;
        });
        _snack(_language.t('snack.cut'));
      case _EntryAction.paste:
        await _pasteClipboard(entry.isDirectory ? entry.path : _currentPath);
      case _EntryAction.delete:
        await _deleteEntry(entry);
      case _EntryAction.rename:
        await _renameEntry(entry);
      case _EntryAction.properties:
        await _showEntryProperties(entry);
      case _EntryAction.send:
        _snack(_language.t('snack.send.next'));
      case _EntryAction.unzip:
        await _unzipEntry(entry);
      case _EntryAction.addFavorite:
      case _EntryAction.removeFavorite:
        await _toggleFavorite(entry);
      case _EntryAction.removeRecent:
        await _removeRecentPath(entry.path);
      case _EntryAction.selectAll:
      case _EntryAction.clearSelection:
      case _EntryAction.zipSelected:
        await _handleBulkAction(action);
      case _EntryAction.encryptMenu:
      case _EntryAction.decryptMenu:
      case _EntryAction.useAs:
        return;
      case _EntryAction.folderContainer:
        await _createFolderContainer(entry);
      case _EntryAction.folderEncryptName:
        await _encryptFolderName(entry);
      case _EntryAction.folderDecryptName:
        await _decryptFolderName(entry);
      case _EntryAction.folderEncrypt:
        await _encryptFolderFiles(entry);
      case _EntryAction.folderDecrypt:
        await _decryptFolderFiles(entry);
      case _EntryAction.useAsGallery:
      case _EntryAction.useAsVideo:
      case _EntryAction.useAsMusic:
      case _EntryAction.useAsMultimedia:
        await _useFolderAs(entry, action);
      case _EntryAction.folderSettings:
        await _showFolderSettingsDialog(entry.path);
      case _EntryAction.openAllImages:
        await _openFolderMediaRecursive(entry, FileContentKind.image);
      case _EntryAction.openAllVideos:
        await _openFolderMediaRecursive(entry, FileContentKind.video);
      case _EntryAction.openAllAudio:
        await _openFolderMediaRecursive(entry, FileContentKind.audio);
      case _EntryAction.permissions:
        await _changePermissions(entry);
      case _EntryAction.ocrExtract:
        await _extractOcrText(entry);
      case _EntryAction.openSwf:
        await _openSwfEntry(entry);
      case _EntryAction.downloadUrl:
        await _showYtDlpDownloadDialog(
            entry.isDirectory ? entry.path : _currentPath);
      case _EntryAction.editConnectionProfile:
        await _editConnectionProfile(entry);
      case _EntryAction.deleteConnectionProfile:
        await _deleteConnectionProfile(entry);
    }
  }

  _BackgroundJob _startBackgroundJob(String title, {int total = 1}) {
    final job = _BackgroundJob(title: title, total: math.max(1, total));
    setState(() => _backgroundJobs.add(job));
    return job;
  }

  void _updateBackgroundJob(
    _BackgroundJob job, {
    int? completed,
    String? status,
    bool? done,
    bool? failed,
  }) {
    if (!mounted || !_backgroundJobs.contains(job)) return;
    setState(() {
      if (completed != null) job.completed = completed.clamp(0, job.total);
      if (status != null) job.status = status;
      if (done != null) job.done = done;
      if (failed != null) job.failed = failed;
    });
    if (done == true || failed == true) {
      Timer(const Duration(seconds: 3), () {
        if (!mounted || !_backgroundJobs.contains(job)) return;
        if (job.done || job.failed) {
          setState(() => _backgroundJobs.remove(job));
        }
      });
    }
  }

  void _cancelBackgroundJob(_BackgroundJob job) {
    if (!mounted || !_backgroundJobs.contains(job)) return;
    setState(() => job.cancelled = true);
  }

  void _removeBackgroundJob(_BackgroundJob job) {
    if (!mounted) return;
    setState(() => _backgroundJobs.remove(job));
  }

  Future<void> _handleEmptyAreaAction(
    String directoryPath,
    _EntryAction action,
  ) async {
    final entry = ExplorerEntry(
      name: basename(directoryPath),
      path: directoryPath,
      kind: ExplorerEntryKind.directory,
      sizeBytes: 0,
      modifiedAt: DateTime.now(),
    );
    await _handleEntryAction(entry, action);
  }

  void _togglePathSelection(ExplorerEntry entry) {
    if (entry.isNavigationEntry || !entry.exists) return;
    setState(() {
      final next = {..._selectedPaths};
      if (!next.add(entry.path)) {
        next.remove(entry.path);
      }
      _selectedPaths = next;
    });
  }

  void _selectAllEntries(List<ExplorerEntry> entries) {
    setState(() {
      _selectedPaths = {
        for (final entry in entries)
          if (!entry.isNavigationEntry && entry.exists) entry.path,
      };
    });
  }

  void _clearSelection() {
    setState(() => _selectedPaths = const <String>{});
  }

  Future<void> _handleBulkAction(_EntryAction action) async {
    final paths = _selectedPaths.toList();
    if (paths.isEmpty) return;
    switch (action) {
      case _EntryAction.selectAll:
        return;
      case _EntryAction.clearSelection:
        _clearSelection();
        return;
      case _EntryAction.copy:
        setState(() {
          _clipboardPaths = paths;
          _clipboardNames = const <String, String>{};
          _clipboardCut = false;
        });
        _snack(_language.t('snack.copied'));
      case _EntryAction.cut:
        setState(() {
          _clipboardPaths = paths;
          _clipboardNames = const <String, String>{};
          _clipboardCut = true;
        });
        _snack(_language.t('snack.cut'));
      case _EntryAction.delete:
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(_language.t('explorer.delete')),
            content: Text(
              '${_language.t('explorer.delete.confirm')}\n${paths.length}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(_language.t('common.cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(_language.t('explorer.delete')),
              ),
            ],
          ),
        );
        if (ok != true) return;
        for (final path in paths) {
          await _explorer.deleteEntity(path);
          await _removePathReferences(path);
        }
        _clearSelection();
        _snack(_language.t('snack.deleted'));
        await _refresh();
      case _EntryAction.zipSelected:
        await _archiveSelected(paths);
      default:
        _snack(_language.t('selection.unsupported.bulk'));
    }
  }

  Future<void> _archiveSelected(List<String> paths) async {
    final targetPath = _currentPath;
    if (targetPath == null || _explorer.isVirtualPath(targetPath)) {
      _snack(_language.t('selection.zip.local.only'));
      return;
    }
    final controller = TextEditingController(text: 'archive.zip');
    final archiveName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_language.t('selection.zip')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: _language.t('explorer.name')),
          onSubmitted: (_) => Navigator.pop(context, controller.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_language.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(_language.t('common.execute')),
          ),
        ],
      ),
    );
    if (archiveName == null || archiveName.trim().isEmpty) return;
    try {
      final file = await _explorer.createZipFromPaths(
        paths,
        Directory(targetPath),
        archiveName: archiveName.trim().toLowerCase().endsWith('.zip')
            ? archiveName.trim()
            : '${archiveName.trim()}.zip',
      );
      _clearSelection();
      _snack('${_language.t('snack.created')} ${file.path}');
      await _refresh();
    } catch (error) {
      _snack('${_language.t('snack.operation.error')} $error');
    }
  }

  Future<void> _pasteClipboard(String? targetDirectory) async {
    final sources = _clipboardPaths;
    if (sources.isEmpty || targetDirectory == null) return;
    try {
      final results = <FileSystemEntity>[];
      for (final source in sources) {
        if (_isHttpMedia(source)) {
          results.add(await _pasteHttpMedia(source, targetDirectory));
          continue;
        }
        results.add(_clipboardCut
            ? await _explorer.moveEntityToDirectory(source, targetDirectory)
            : await _explorer.copyEntityToDirectory(source, targetDirectory));
      }
      if (_clipboardCut) {
        setState(() {
          _clipboardPaths = const [];
          _clipboardNames = const <String, String>{};
          _clipboardCut = false;
        });
      }
      _snack('${_language.t('snack.pasted')} ${results.length}');
      await _refresh();
    } catch (error) {
      _snack('${_language.t('snack.operation.error')} $error');
    }
  }

  Future<FileSystemEntity> _pasteHttpMedia(
    String source,
    String targetDirectory,
  ) async {
    final name = _clipboardNames[source] ??
        Uri.tryParse(source)?.pathSegments.lastOrNull ??
        'track.mp3';
    final entry = ExplorerEntry(
      name: name.trim().isEmpty ? 'track.mp3' : name,
      path: source,
      kind: ExplorerEntryKind.file,
      sizeBytes: 0,
      modifiedAt: DateTime.now(),
    );
    final isVirtualTarget = _explorer.isVirtualPath(targetDirectory);
    final targetDir = isVirtualTarget
        ? await Directory.systemTemp.createTemp('securevault_http_paste_')
        : Directory(targetDirectory);
    final downloaded = await _webMusicPlugins.download(entry, targetDir);
    if (!isVirtualTarget) {
      return downloaded;
    }
    try {
      final createdPath = await _explorer.createFile(
        targetDirectory,
        basename(downloaded.path),
        await downloaded.readAsBytes(),
      );
      return File(createdPath);
    } finally {
      try {
        await targetDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> _createFile(ExplorerEntry entry, _CreateFileKind kind) async {
    final targetDir = entry.isDirectory ? entry.path : _currentPath;
    if (targetDir == null) return;
    final spec = await _createFileDialog(kind);
    if (spec == null) return;
    try {
      if (kind == _CreateFileKind.encryptedPlain ||
          kind == _CreateFileKind.encryptedCsv ||
          kind == _CreateFileKind.encryptedImage) {
        final password = await _passwordForGeneratedEncryption();
        if (password == null || password.isEmpty) {
          return;
        }
        final tempDir = await Directory.systemTemp.createTemp('securevault_');
        try {
          final plain =
              File('${tempDir.path}${Platform.pathSeparator}${spec.name}');
          await plain.writeAsBytes(spec.bytes, flush: true);
          final encrypted = await _explorer.encryptFileToDirectory(
            plain,
            tempDir,
            password: password,
            keyMode: _settings.hasCommonEncryption
                ? EncryptionKeyMode.common
                : EncryptionKeyMode.unique,
            algorithm: _settings.commonEncryptionAlgorithm,
          );
          final createdPath = await _explorer.createFile(
            targetDir,
            basename(encrypted.path),
            await encrypted.readAsBytes(),
          );
          _snack('${_language.t('snack.created')} $createdPath');
        } finally {
          try {
            await tempDir.delete(recursive: true);
          } catch (_) {}
        }
      } else {
        final createdPath = await _explorer.createFile(
          targetDir,
          spec.name,
          spec.bytes,
        );
        _snack('${_language.t('snack.created')} $createdPath');
      }
      await _refresh();
    } catch (error) {
      _snack('${_language.t('snack.operation.error')} $error');
    }
  }

  Future<void> _createFolder(ExplorerEntry entry) async {
    final targetDir = entry.isDirectory ? entry.path : _currentPath;
    if (targetDir == null) return;
    final controller = TextEditingController(text: 'New folder');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_language.t('create.folder')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: _language.t('explorer.name')),
          onSubmitted: (_) => Navigator.pop(context, controller.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_language.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(_language.t('explorer.create')),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    try {
      final directory = await _explorer.createDirectory(targetDir, name);
      _snack('${_language.t('snack.created')} ${directory.path}');
      await _refresh();
    } catch (error) {
      _snack('${_language.t('snack.operation.error')} $error');
    }
  }

  Future<String?> _passwordForFolderOperation() async {
    if (_settings.hasCommonEncryption &&
        !_settings.hasFilePassword &&
        _commonEncryptionPassword != null &&
        _commonEncryptionPassword!.isNotEmpty) {
      return _commonEncryptionPassword;
    }
    return _passwordDialog(_language.t('encrypt.password.common'));
  }

  Future<void> _encryptFolderName(ExplorerEntry entry) async {
    if (!entry.isDirectory || _explorer.isVirtualPath(entry.path)) return;
    final password = await _passwordForFolderOperation();
    if (password == null || password.isEmpty) return;
    try {
      final directory = await _explorer.encryptFolderName(
        Directory(entry.path),
        password: password,
      );
      await _replacePathReference(entry.path, directory.path);
      _snack('${_language.t('snack.renamed')} ${directory.path}');
      await _refresh();
    } catch (error) {
      _snack('${_language.t('snack.operation.error')} $error');
    }
  }

  Future<void> _decryptFolderName(ExplorerEntry entry) async {
    if (!entry.isDirectory || _explorer.isVirtualPath(entry.path)) return;
    final password = await _passwordForFolderOperation();
    if (password == null || password.isEmpty) return;
    try {
      final directory = await _explorer.decryptFolderName(
        Directory(entry.path),
        password: password,
      );
      await _replacePathReference(entry.path, directory.path);
      _snack('${_language.t('snack.renamed')} ${directory.path}');
      await _refresh();
    } catch (error) {
      _snack('${_language.t('snack.operation.error')} $error');
    }
  }

  Future<void> _createFolderContainer(ExplorerEntry entry) async {
    if (!entry.isDirectory || _explorer.isVirtualPath(entry.path)) return;
    final password = await _passwordForFolderOperation();
    if (password == null || password.isEmpty) return;
    try {
      final parent = Directory(entry.path).parent;
      final zip = await _explorer.createZipFromPaths(
        [entry.path],
        parent,
        archiveName: '${entry.name}.zip',
      );
      final encrypted = await _explorer.encryptFileToDirectory(
        zip,
        parent,
        password: password,
        keyMode: _settings.hasCommonEncryption
            ? EncryptionKeyMode.common
            : EncryptionKeyMode.unique,
        algorithm: _settings.commonEncryptionAlgorithm,
      );
      await zip.delete();
      _snack('${_language.t('snack.encrypted')} ${encrypted.path}');
      await _refresh();
    } catch (error) {
      _snack('${_language.t('snack.encrypt.error')} $error');
    }
  }

  Future<void> _encryptFolderFiles(ExplorerEntry entry) async {
    if (!entry.isDirectory || _explorer.isVirtualPath(entry.path)) return;
    final password = await _passwordForFolderOperation();
    if (password == null || password.isEmpty) return;
    var count = 0;
    final files = <File>[];
    await for (final entity
        in Directory(entry.path).list(recursive: true, followLinks: false)) {
      if (entity is File) files.add(entity);
    }
    final job = _startBackgroundJob(
      _language.t('jobs.encrypt.folder'),
      total: files.length,
    );
    try {
      for (final entity in files) {
        if (job.cancelled) break;
        final item = await _explorer.entryForPath(entity.path);
        if (item == null || item.isEncrypted) {
          _updateBackgroundJob(job, completed: ++count, status: entity.path);
          continue;
        }
        await _explorer.encryptFileToDirectory(
          entity,
          entity.parent,
          password: password,
          keyMode: _settings.hasCommonEncryption
              ? EncryptionKeyMode.common
              : EncryptionKeyMode.unique,
          algorithm: _settings.commonEncryptionAlgorithm,
        );
        _updateBackgroundJob(job, completed: ++count, status: entity.path);
      }
      _updateBackgroundJob(job, done: true, status: _language.t('jobs.done'));
      _snack('${_language.t('snack.encrypted')} $count');
      await _refresh();
    } catch (error) {
      _updateBackgroundJob(job, failed: true, status: '$error');
      _snack('${_language.t('snack.encrypt.error')} $error');
    }
  }

  Future<void> _decryptFolderFiles(ExplorerEntry entry) async {
    if (!entry.isDirectory || _explorer.isVirtualPath(entry.path)) return;
    final password = await _passwordForFolderOperation();
    if (password == null || password.isEmpty) return;
    var count = 0;
    final files = <File>[];
    await for (final entity
        in Directory(entry.path).list(recursive: true, followLinks: false)) {
      if (entity is File) files.add(entity);
    }
    final job = _startBackgroundJob(
      _language.t('jobs.decrypt.folder'),
      total: files.length,
    );
    try {
      for (final entity in files) {
        if (job.cancelled) break;
        final item = await _explorer.entryForPath(entity.path);
        if (item == null || !item.isEncrypted) {
          _updateBackgroundJob(job, completed: ++count, status: entity.path);
          continue;
        }
        await _explorer.decryptSelectedFile(
          entity,
          DecryptFileOptions(
            password: password,
            targetDirectory: entity.parent.path,
          ),
        );
        _updateBackgroundJob(job, completed: ++count, status: entity.path);
      }
      _updateBackgroundJob(job, done: true, status: _language.t('jobs.done'));
      _snack('${_language.t('snack.decrypted')} $count');
      await _refresh();
    } catch (error) {
      _updateBackgroundJob(job, failed: true, status: '$error');
      _snack('${_language.t('snack.decrypt.error')} $error');
    }
  }

  Future<void> _useFolderAs(ExplorerEntry entry, _EntryAction action) async {
    if (!entry.isDirectory || !entry.exists) return;
    var gallery = _settings.galleryFolders;
    var music = _settings.musicFolders;
    var video = _settings.videoFolders;
    List<String> addPath(List<String> values) {
      final next = <String>[entry.path, ...values];
      final seen = <String>{};
      return [
        for (final item in next)
          if (seen.add(Platform.isWindows ? item.toLowerCase() : item)) item,
      ];
    }

    switch (action) {
      case _EntryAction.useAsGallery:
        gallery = addPath(gallery);
      case _EntryAction.useAsMusic:
        music = addPath(music);
      case _EntryAction.useAsVideo:
        video = addPath(video);
      case _EntryAction.useAsMultimedia:
        gallery = addPath(gallery);
        music = addPath(music);
        video = addPath(video);
      default:
        return;
    }
    final next = await _settingsRepo.updateMediaFolders(
      _settings,
      galleryFolders: gallery,
      musicFolders: music,
      videoFolders: video,
    );
    if (mounted) {
      setState(() => _settings = next);
      _snack(_language.t('settings.saved'));
    }
  }

  Future<_CreatedFileSpec?> _createFileDialog(_CreateFileKind kind) async {
    final nameController = TextEditingController(
        text: switch (kind) {
      _CreateFileKind.plain || _CreateFileKind.encryptedPlain => 'new.txt',
      _CreateFileKind.csv || _CreateFileKind.encryptedCsv => 'table.csv',
      _ => 'image.png',
    });
    final separatorController = TextEditingController(text: ';');
    final widthController = TextEditingController(text: '1024');
    final heightController = TextEditingController(text: '1024');
    final colorController = TextEditingController(text: '#FFFFFF');
    var imageFormat = 'png';
    var transparent = false;
    final result = await showDialog<_CreatedFileSpec>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(_language.t('explorer.create')),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                  controller: nameController,
                  decoration:
                      InputDecoration(labelText: _language.t('explorer.name')),
                ),
                if (kind == _CreateFileKind.csv ||
                    kind == _CreateFileKind.encryptedCsv)
                  TextField(
                    controller: separatorController,
                    decoration: InputDecoration(
                      labelText: _language.t('create.csv.separator'),
                      helperText: _language.t('create.csv.separator.note'),
                    ),
                  ),
                if (kind == _CreateFileKind.image ||
                    kind == _CreateFileKind.encryptedImage) ...[
                  DropdownButtonFormField<String>(
                    initialValue: imageFormat,
                    decoration: InputDecoration(
                        labelText: _language.t('create.image.format')),
                    items: const [
                      DropdownMenuItem(value: 'png', child: Text('PNG')),
                      DropdownMenuItem(value: 'jpg', child: Text('JPG')),
                      DropdownMenuItem(value: 'bmp', child: Text('BMP')),
                    ],
                    onChanged: (value) => setDialogState(() {
                      imageFormat = value ?? 'png';
                      final name = nameController.text.trim();
                      nameController.text = name.replaceFirst(
                        RegExp(r'\.[^.]+$'),
                        '.$imageFormat',
                      );
                    }),
                  ),
                  TextField(
                    controller: widthController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                        labelText: _language.t('create.image.width')),
                  ),
                  TextField(
                    controller: heightController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                        labelText: _language.t('create.image.height')),
                  ),
                  TextField(
                    controller: colorController,
                    decoration: InputDecoration(
                        labelText: _language.t('create.image.background')),
                  ),
                  CheckboxListTile(
                    value: transparent,
                    onChanged: imageFormat == 'jpg'
                        ? null
                        : (value) =>
                            setDialogState(() => transparent = value ?? false),
                    title: Text(_language.t('create.image.transparent')),
                  ),
                ],
              ]),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_language.t('common.cancel')),
            ),
            FilledButton(
              onPressed: () {
                final name = nameController.text.trim();
                if (name.isEmpty) return;
                final bytes = switch (kind) {
                  _CreateFileKind.plain ||
                  _CreateFileKind.encryptedPlain =>
                    Uint8List.fromList(const []),
                  _CreateFileKind.csv ||
                  _CreateFileKind.encryptedCsv =>
                    Uint8List.fromList(
                        'Column1${_csvSeparator(separatorController.text)}Column2\r\n'
                            .codeUnits),
                  _ => _imageBytes(
                      width: int.tryParse(widthController.text.trim()) ?? 1024,
                      height:
                          int.tryParse(heightController.text.trim()) ?? 1024,
                      format: imageFormat,
                      color: colorController.text.trim(),
                      transparent: transparent,
                    ),
                };
                Navigator.pop(
                    context, _CreatedFileSpec(name: name, bytes: bytes));
              },
              child: Text(_language.t('explorer.create')),
            ),
          ],
        ),
      ),
    );
    return result;
  }

  String _csvSeparator(String text) {
    final value = text.trim();
    if (value.toLowerCase() == r'\t' || value.toLowerCase() == 'tab') {
      return '\t';
    }
    return value.isEmpty ? ';' : value;
  }

  Uint8List _imageBytes({
    required int width,
    required int height,
    required String format,
    required String color,
    required bool transparent,
  }) {
    final parsedColor = _parseHexColor(color);
    final image = img.Image(
      width: width.clamp(1, 8192),
      height: height.clamp(1, 8192),
      numChannels: 4,
    );
    final fill = transparent
        ? img.ColorRgba8(255, 255, 255, 0)
        : img.ColorRgba8(parsedColor.$1, parsedColor.$2, parsedColor.$3, 255);
    img.fill(image, color: fill);
    final bytes = switch (format) {
      'jpg' || 'jpeg' => img.encodeJpg(image),
      'bmp' => img.encodeBmp(image),
      _ => img.encodePng(image),
    };
    return Uint8List.fromList(bytes);
  }

  (int, int, int) _parseHexColor(String value) {
    final normalized = value.replaceAll('#', '').trim();
    if (normalized.length == 6) {
      final parsed = int.tryParse(normalized, radix: 16);
      if (parsed != null) {
        return ((parsed >> 16) & 0xFF, (parsed >> 8) & 0xFF, parsed & 0xFF);
      }
    }
    return (255, 255, 255);
  }

  Future<String?> _passwordForGeneratedEncryption() async {
    if (_settings.hasCommonEncryption &&
        !_settings.hasFilePassword &&
        _commonEncryptionPassword != null &&
        _commonEncryptionPassword!.isNotEmpty) {
      return _commonEncryptionPassword;
    }
    return _passwordDialog(_language.t('encrypt.password.unique'));
  }

  Future<void> _unzipEntry(ExplorerEntry entry) async {
    if (_explorer.isVirtualPath(entry.path)) {
      _snack(_language.t('selection.zip.local.only'));
      return;
    }
    final job = _startBackgroundJob(
      _language.t('explorer.unzip'),
      total: math.max(1, entry.sizeBytes),
    );
    try {
      _updateBackgroundJob(job, status: entry.path);
      final file = File(entry.path);
      final extension = FileViewerService.extensionForName(entry.path);
      final target = extension == '.zip'
          ? await _explorer.extractZipToDirectory(
              file,
              Directory(file.parent.path),
            )
          : await _explorer.extractRarToDirectory(
              file,
              Directory(file.parent.path),
            );
      _updateBackgroundJob(
        job,
        completed: math.max(1, entry.sizeBytes),
        done: true,
        status: target.path,
      );
      _snack('${_language.t('snack.unzipped')} ${target.path}');
      await _refresh();
    } catch (error) {
      _updateBackgroundJob(job, failed: true, status: '$error');
      _snack('${_language.t('snack.operation.error')} $error');
    }
  }

  Future<void> _deleteEntry(ExplorerEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_language.t('explorer.delete')),
        content:
            Text('${_language.t('explorer.delete.confirm')}\n${entry.path}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_language.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_language.t('explorer.delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _explorer.deleteEntity(entry.path);
      await _removePathReferences(entry.path);
      setState(() {
        if (_selected?.path == entry.path) {
          _selected = null;
          _preview = null;
          _mediaPlaylist = const [];
          _imagePlaylist = const [];
        }
      });
      _snack(_language.t('snack.deleted'));
      await _refresh();
    } catch (error) {
      _snack('${_language.t('snack.operation.error')} $error');
    }
  }

  Future<void> _renameEntry(ExplorerEntry entry) async {
    final controller = TextEditingController(text: entry.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_language.t('explorer.rename')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: _language.t('explorer.name')),
          onSubmitted: (_) => Navigator.pop(context, controller.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_language.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(_language.t('explorer.rename')),
          ),
        ],
      ),
    );
    if (newName == null || newName.trim().isEmpty || newName == entry.name) {
      return;
    }
    try {
      final renamed = await _explorer.renameEntity(entry.path, newName);
      await _replacePathReference(entry.path, renamed.path);
      _snack('${_language.t('snack.renamed')} ${renamed.path}');
      await _refresh();
    } catch (error) {
      _snack('${_language.t('snack.operation.error')} $error');
    }
  }

  Future<void> _showEntryProperties(ExplorerEntry entry) async {
    final extension = FileViewerService.extensionForName(entry.name).isNotEmpty
        ? FileViewerService.extensionForName(entry.name)
        : FileViewerService.extensionForName(entry.path);
    var openMode = extension.isEmpty
        ? 'internal'
        : (_settings.unknownExtensionModes[extension] ?? 'internal');
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(_language.t('explorer.properties')),
          content: SizedBox(
            width: 540,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    '${_language.t('common.path')}: ${entry.path}\n'
                    '${_language.t('explorer.name')}: ${entry.name}\n'
                    '${_language.t('explorer.type')}: ${entry.kind.name}\n'
                    '${_language.t('explorer.size')}: ${entry.sizeBytes}\n'
                    '${_language.t('explorer.modified')}: ${entry.modifiedAt}\n'
                    '${_language.t('explorer.exists')}: ${entry.exists}',
                  ),
                  if (!entry.isDirectory && extension.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(
                      '${_language.t('common.extension')}: $extension',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: openMode,
                      decoration: InputDecoration(
                        labelText: _language.t('properties.extension.opening'),
                      ),
                      items: [
                        DropdownMenuItem(
                          value: 'external',
                          child: Text(_language.t('properties.open.external')),
                        ),
                        DropdownMenuItem(
                          value: 'internal',
                          child: Text(_language.t('properties.open.internal')),
                        ),
                        DropdownMenuItem(
                          value: 'text',
                          child: Text(_language.t('preview.force.text')),
                        ),
                        DropdownMenuItem(
                          value: 'audio',
                          child: Text(_language.t('preview.force.audio')),
                        ),
                        DropdownMenuItem(
                          value: 'video',
                          child: Text(_language.t('preview.force.video')),
                        ),
                        DropdownMenuItem(
                          value: 'image',
                          child: Text(_language.t('preview.force.image')),
                        ),
                      ],
                      onChanged: (value) async {
                        if (value == null) return;
                        setDialogState(() => openMode = value);
                        await _setExtensionOpenMode(extension, value);
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () => unawaited(_changePermissions(entry)),
              icon: const Icon(Icons.admin_panel_settings_outlined),
              label: Text(_language.t('permissions.title')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_language.t('common.ok')),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _setExtensionOpenMode(String extension, String mode) async {
    if (extension.isEmpty) return;
    final nextModes = Map<String, String>.of(_settings.unknownExtensionModes);
    if (mode == 'internal') {
      nextModes.remove(extension);
    } else {
      nextModes[extension] = mode;
    }
    final next = _settings.copyWith(unknownExtensionModes: nextModes);
    await _settingsRepo.save(next);
    if (mounted) setState(() => _settings = next);
  }

  Future<void> _extractOcrText(ExplorerEntry entry) async {
    _snack(_language.t('ocr.processing'));
    try {
      final text = await _explorer.extractOcrText(
        entry.path,
        commonPassword: _commonEncryptionPassword,
        filePassword: _activeFilePassword(),
      );
      final normalized =
          text == null ? null : FileViewerService.normalizeReadableText(text);
      if (!mounted) return;
      if (normalized == null || normalized.trim().isEmpty) {
        _snack(_language.t('ocr.empty'));
        return;
      }
      final action = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(_language.t('ocr.extract')),
          content: SizedBox(
            width: 720,
            height: 520,
            child: Scrollbar(
              thumbVisibility: true,
              child: SingleChildScrollView(
                child: SelectableText(
                  normalized,
                  style: const TextStyle(fontFamily: 'Consolas', height: 1.35),
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: normalized));
                if (context.mounted) Navigator.pop(context);
                _snack(_language.t('ocr.copied'));
              },
              child: Text(_language.t('explorer.copy')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'edit'),
              child: Text(_language.t('ocr.edit')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'save'),
              child: Text(_language.t('ocr.save.text')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_language.t('common.close')),
            ),
          ],
        ),
      );
      if (action == 'edit') {
        await _openEditor(FilePreview(
          title: '${entry.name}.txt',
          subtitle: entry.path,
          sourcePath: null,
          text: normalized,
          bytes: Uint8List.fromList(utf8.encode(normalized)),
          contentKind: FileContentKind.text,
        ));
      } else if (action == 'save') {
        await _saveOcrText(entry, normalized);
      }
    } catch (error) {
      _snack('${_language.t('ocr.error')} $error');
    }
  }

  Future<void> _saveOcrText(ExplorerEntry entry, String text) async {
    final suggestedName = '${entry.name}.txt';
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => _SaveTextPathDialog(
        language: _language,
        suggestedName: suggestedName,
      ),
    );
    if (selected == null || selected.trim().isEmpty) return;
    try {
      final file = File(selected);
      await file.parent.create(recursive: true);
      await file.writeAsString(text, encoding: utf8);
      _snack('${_language.t('snack.saved')} ${file.path}');
    } catch (error) {
      _snack('${_language.t('snack.operation.error')} $error');
    }
  }

  Future<void> _openSwfEntry(ExplorerEntry entry) async {
    try {
      final preview = await _explorer.previewFile(
        entry.path,
        password: _activeFilePassword(),
        commonPassword: _commonEncryptionPassword,
      );
      if (preview.contentKind != FileContentKind.flash) {
        _snack(_language.t('preview.swf.not_file'));
        return;
      }
      final flashPlaylist = await _buildFlashPlaylist(entry, preview);
      if (mounted) {
        setState(() {
          _selected = entry;
          _preview = Future<FilePreview>.value(preview);
          _flashPlaylist = flashPlaylist;
        });
      }
      _showPreviewWindow(preview);
    } catch (error) {
      _snack('${_language.t('preview.swf.open.error')} $error');
    }
  }

  Future<void> _changePermissions(ExplorerEntry entry) async {
    final isLocalWindows = Platform.isWindows &&
        !_explorer.isVirtualPath(entry.path) &&
        entry.exists;
    if (isLocalWindows) {
      await _changeWindowsPermissions(entry);
      return;
    }
    if (!_explorer.supportsPermissions(entry.path)) {
      _snack(_language.t('permissions.unsupported'));
      return;
    }
    final modeController = TextEditingController(text: '755');
    var recursive = entry.isDirectory;
    final result = await showDialog<({int mode, bool recursive})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(_language.t('permissions.title')),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(entry.path),
                const SizedBox(height: 12),
                TextField(
                  controller: modeController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: _language.t('permissions.mode'),
                    helperText: '755, 775, 644',
                  ),
                ),
                if (entry.isDirectory)
                  SwitchListTile(
                    value: recursive,
                    onChanged: (value) =>
                        setDialogState(() => recursive = value),
                    title: Text(_language.t('permissions.recursive')),
                  ),
              ]),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_language.t('common.cancel')),
            ),
            FilledButton(
              onPressed: () {
                final text = modeController.text.trim().replaceFirst(
                      RegExp(r'^0+'),
                      '',
                    );
                final mode = int.tryParse(text.isEmpty ? '0' : text, radix: 8);
                if (mode == null || mode < 0 || mode > 0x1FF) {
                  return;
                }
                Navigator.pop(context, (mode: mode, recursive: recursive));
              },
              child: Text(_language.t('search.apply')),
            ),
          ],
        ),
      ),
    );
    modeController.dispose();
    if (result == null) return;
    try {
      await _explorer.setPermissions(
        entry.path,
        mode: result.mode,
        recursive: result.recursive,
      );
      _snack(_language.t('permissions.changed'));
      await _refresh();
    } catch (error) {
      _snack('${_language.t('snack.operation.error')} $error');
    }
  }

  Future<void> _changeWindowsPermissions(ExplorerEntry entry) async {
    final accountController = TextEditingController();
    var read = true;
    var write = false;
    var execute = entry.isDirectory;
    var recursive = entry.isDirectory;
    final result = await showDialog<
        ({
          String account,
          bool read,
          bool write,
          bool execute,
          bool recursive
        })>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(_language.t('permissions.title')),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(entry.path),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: accountController,
                  decoration: InputDecoration(
                    labelText: _language.t('security.account'),
                    helperText: r'РќР°РїСЂРёРјРµСЂ: DOMAIN\User, BUILTIN\Users',
                  ),
                ),
                CheckboxListTile(
                  value: read,
                  onChanged: (value) =>
                      setDialogState(() => read = value ?? false),
                  title: Text(_language.t('security.read')),
                ),
                CheckboxListTile(
                  value: write,
                  onChanged: (value) =>
                      setDialogState(() => write = value ?? false),
                  title: Text(_language.t('security.write')),
                ),
                CheckboxListTile(
                  value: execute,
                  onChanged: (value) =>
                      setDialogState(() => execute = value ?? false),
                  title: Text(_language.t('security.execute')),
                ),
                if (entry.isDirectory)
                  SwitchListTile(
                    value: recursive,
                    onChanged: (value) =>
                        setDialogState(() => recursive = value),
                    title: Text(_language.t('permissions.recursive')),
                  ),
              ]),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_language.t('common.cancel')),
            ),
            FilledButton(
              onPressed: () {
                final account = accountController.text.trim();
                if (account.isEmpty || (!read && !write && !execute)) return;
                Navigator.pop(
                  context,
                  (
                    account: account,
                    read: read,
                    write: write,
                    execute: execute,
                    recursive: recursive
                  ),
                );
              },
              child: Text(_language.t('security.apply')),
            ),
          ],
        ),
      ),
    );
    accountController.dispose();
    if (result == null) return;
    final rights = <String>[];
    if (result.read && result.execute) {
      rights.add('RX');
    } else {
      if (result.read) rights.add('R');
      if (result.execute) rights.add('X');
    }
    if (result.write) rights.add('W');
    final prefix = entry.isDirectory ? '(OI)(CI)' : '';
    final grant = '${result.account}:$prefix(${rights.join(',')})';
    final args = <String>[entry.path, '/grant', grant];
    if (result.recursive && entry.isDirectory) args.add('/T');
    try {
      final process = await Process.run('icacls', args);
      if (process.exitCode != 0) {
        throw ProcessException(
          'icacls',
          args,
          '${process.stderr}\n${process.stdout}',
          process.exitCode,
        );
      }
      _snack(_language.t('permissions.changed'));
      await _refresh();
    } catch (error) {
      _snack('${_language.t('snack.operation.error')} $error');
    }
  }

  Future<void> _showFolderSettingsDialog(String path) async {
    final normalized = _normalizeSettingPath(path);
    if (normalized.isEmpty) return;
    var behavior = _settings.folderBehaviorByPath[normalized] ??
        const FolderBehaviorSettings();
    final result = await showDialog<FolderBehaviorSettings>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          SwitchListTile item(
            String key,
            bool value,
            FolderBehaviorSettings Function(bool) update,
          ) =>
              SwitchListTile(
                dense: true,
                value: value,
                onChanged: behavior.inheritParent &&
                        key != 'folder.settings.inherit'
                    ? null
                    : (next) => setDialogState(() => behavior = update(next)),
                title: Text(_language.t(key)),
              );

          return AlertDialog(
            title: Text(_language.t('folder.settings.title')),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(
                      path,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(height: 8),
                  item(
                    'folder.settings.inherit',
                    behavior.inheritParent,
                    (v) => behavior.copyWith(inheritParent: v),
                  ),
                  const Divider(),
                  item(
                    'folder.settings.remember.open',
                    behavior.rememberLocationOnOpen,
                    (v) => behavior.copyWith(rememberLocationOnOpen: v),
                  ),
                  item(
                    'folder.settings.remember.background.collapse',
                    behavior.rememberLocationOnBackgroundCollapse,
                    (v) => behavior.copyWith(
                      rememberLocationOnBackgroundCollapse: v,
                    ),
                  ),
                  item(
                    'folder.settings.remember.background.video',
                    behavior.rememberBackgroundVideo,
                    (v) => behavior.copyWith(rememberBackgroundVideo: v),
                  ),
                  item(
                    'folder.settings.remember.background.audio',
                    behavior.rememberBackgroundAudio,
                    (v) => behavior.copyWith(rememberBackgroundAudio: v),
                  ),
                  item(
                    'folder.settings.forbid.background',
                    behavior.forbidBackgroundPlayback,
                    (v) => behavior.copyWith(forbidBackgroundPlayback: v),
                  ),
                  item(
                    'folder.settings.forbid.mini',
                    behavior.forbidMiniPlayback,
                    (v) => behavior.copyWith(forbidMiniPlayback: v),
                  ),
                  item(
                    'folder.settings.remember.recent',
                    behavior.rememberRecent,
                    (v) => behavior.copyWith(rememberRecent: v),
                  ),
                  const Divider(),
                  item(
                    'folder.settings.show.hidden.files',
                    behavior.showHiddenFiles,
                    (v) => behavior.copyWith(showHiddenFiles: v),
                  ),
                  item(
                    'folder.settings.show.hidden.folders',
                    behavior.showHiddenFolders,
                    (v) => behavior.copyWith(showHiddenFolders: v),
                  ),
                  item(
                    'folder.settings.show.system.folders',
                    behavior.showProtectedSystemFolders,
                    (v) => behavior.copyWith(showProtectedSystemFolders: v),
                  ),
                  item(
                    'folder.settings.show.system.files',
                    behavior.showProtectedSystemFiles,
                    (v) => behavior.copyWith(showProtectedSystemFiles: v),
                  ),
                  const Divider(),
                  item(
                    'folder.settings.block.screenshots',
                    behavior.blockScreenshots,
                    (v) => behavior.copyWith(blockScreenshots: v),
                  ),
                  item(
                    'folder.settings.disable.camera',
                    behavior.disableCamera,
                    (v) => behavior.copyWith(disableCamera: v),
                  ),
                  item(
                    'folder.settings.disable.microphone',
                    behavior.disableMicrophone,
                    (v) => behavior.copyWith(disableMicrophone: v),
                  ),
                ]),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(_language.t('common.cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, behavior),
                child: Text(_language.t('common.save')),
              ),
            ],
          );
        },
      ),
    );
    if (result == null) return;
    final next = await _settingsRepo.setFolderBehavior(
      _settings,
      normalized,
      result,
    );
    if (mounted) {
      setState(() => _settings = next);
      _snack(_language.t('settings.saved'));
      unawaited(_applyFolderRuntimeProtection(path));
      await _refresh();
    }
  }

  Future<void> _removePathReferences(String path) async {
    var next = _settings;
    if (next.favoritePaths.contains(path)) {
      next = await _settingsRepo.updateFavorites(
        next,
        next.favoritePaths.where((item) => item != path).toList(),
      );
    }
    if (next.recentFilePaths.contains(path)) {
      next = await _settingsRepo.removeRecentFile(next, path);
    }
    if (mounted) {
      setState(() => _settings = next);
    }
  }

  Future<void> _removeFavoritePath(String path) async {
    final next = await _settingsRepo.updateFavorites(
      _settings,
      _settings.favoritePaths.where((item) => item != path).toList(),
    );
    if (mounted) setState(() => _settings = next);
  }

  Future<void> _editLocationProfile(ExplorerLocation location) async {
    final profileId = _profileIdForLocation(location);
    if (profileId == null) return;
    await _editConnectionProfile(_entryForLocationProfile(location, profileId));
  }

  Future<void> _deleteLocationProfile(ExplorerLocation location) async {
    final profileId = _profileIdForLocation(location);
    if (profileId == null) return;
    await _deleteConnectionProfile(
        _entryForLocationProfile(location, profileId));
  }

  String? _profileIdForLocation(ExplorerLocation location) {
    if (location.id.startsWith('profile-')) {
      return location.id.substring('profile-'.length);
    }
    final pluginId = location.pluginId;
    if (pluginId != null && pluginId.startsWith('profile-')) {
      return pluginId.substring('profile-'.length);
    }
    return null;
  }

  ExplorerEntry _entryForLocationProfile(
    ExplorerLocation location,
    String profileId,
  ) {
    return ExplorerEntry(
      name: location.name,
      path: location.path ?? '',
      kind: ExplorerEntryKind.directory,
      sizeBytes: 0,
      modifiedAt: DateTime.now(),
      exists: location.enabled,
      connectionProfileId: profileId,
    );
  }

  Future<void> _replacePathReference(String oldPath, String newPath) async {
    var next = _settings;
    if (next.favoritePaths.contains(oldPath)) {
      next = await _settingsRepo.updateFavorites(
        next,
        next.favoritePaths
            .map((item) => item == oldPath ? newPath : item)
            .toList(),
      );
    }
    if (next.recentFilePaths.contains(oldPath)) {
      final recent = next.recentFilePaths
          .map((item) => item == oldPath ? newPath : item)
          .toList();
      next = next.copyWith(recentFilePaths: recent);
      await _settingsRepo.save(next);
    }
    if (mounted) {
      setState(() => _settings = next);
    }
  }

  Future<void> _encryptSelectedFile([ExplorerEntry? entry]) async {
    final selected = entry ?? _selected;
    if (selected == null || selected.isDirectory) {
      _snack(_language.t('encrypt.select.file'));
      return;
    }
    if (selected.isEncrypted) {
      _snack(_language.t('encrypt.already.encrypted'));
      return;
    }

    var initialMode = EncryptionKeyMode.common;
    if (!_settings.hasCommonEncryption) {
      final decision = await _offerCommonEncryptionSetup();
      if (decision == _CommonSetupDecision.settings) {
        setState(() => _page = ShellPage.settings);
        return;
      }
      if (decision == _CommonSetupDecision.cancel) return;
      initialMode = EncryptionKeyMode.unique;
    }

    final options = await _encryptDialog(selected, initialMode: initialMode);
    if (options == null) return;

    final canUseStoredCommonKey = options.mode == EncryptionKeyMode.common &&
        !_settings.hasFilePassword &&
        _commonEncryptionPassword != null &&
        _commonEncryptionPassword!.isNotEmpty &&
        options.password == _commonEncryptionPassword;
    if (options.mode == EncryptionKeyMode.common &&
        !canUseStoredCommonKey &&
        !await _settingsRepo.verifyCommonEncryptionPassword(
          _settings,
          options.password,
        )) {
      _snack(_language.t('encrypt.bad.common.password'));
      return;
    }

    final totalBytes = math.max(1, selected.sizeBytes);
    final job = _startBackgroundJob(
      _language.t('jobs.encrypt.file'),
      total: totalBytes,
    );
    var lastUiProgress = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      _updateBackgroundJob(job, status: selected.path);
      final file = await _explorer.encryptSelectedFile(
        File(selected.path),
        options,
        shouldCancel: () => job.cancelled,
        onProgress: (completed, total) {
          final now = DateTime.now();
          if (completed >= total ||
              now.difference(lastUiProgress).inMilliseconds >= 220) {
            lastUiProgress = now;
            _updateBackgroundJob(
              job,
              completed: completed.clamp(0, totalBytes).toInt(),
              status:
                  '${(completed / math.max(1, total) * 100).toStringAsFixed(1)}% ${selected.name}',
            );
          }
        },
      );
      _updateBackgroundJob(
        job,
        completed: totalBytes,
        done: true,
        status: file.path,
      );
      _snack('${_language.t('snack.encrypted')} ${file.path}');
      setState(() {
        _selected = null;
        _preview = null;
        _mediaPlaylist = const [];
        _imagePlaylist = const [];
      });
      await _refresh();
    } catch (error) {
      _updateBackgroundJob(job, failed: true, status: '$error');
      _snack('${_language.t('snack.encrypt.error')} $error');
    }
  }

  Future<void> _decryptSelectedFile([ExplorerEntry? entry]) async {
    final selected = entry ?? _selected;
    if (selected == null || selected.isDirectory || !selected.isEncrypted) {
      _snack(_language.t('decrypt.select.file'));
      return;
    }
    final params = await _explorer.encryptedFileParameters(selected.path);
    var password =
        params?.usesCommonKey == true ? _commonEncryptionPassword : null;
    if (password == null || password.isEmpty) {
      password = await _passwordDialog(
        _language.t('decrypt.password'),
        initial: _activeFilePassword(),
      );
      if (password == null || password.isEmpty) return;
      if (_settings.hasFilePassword &&
          !await _settingsRepo.verifyFilePassword(_settings, password)) {
        _snack(_language.t('snack.file.password.mismatch'));
        return;
      }
      _setSessionFilePassword(password);
    }
    final options = await _decryptDialog(selected, password);
    if (options == null) return;
    final job = _startBackgroundJob(_language.t('jobs.decrypt.file'));
    try {
      _updateBackgroundJob(job, status: selected.path);
      final file =
          await _explorer.decryptSelectedFile(File(selected.path), options);
      _updateBackgroundJob(
        job,
        completed: 1,
        done: true,
        status: file.path,
      );
      _snack('${_language.t('snack.decrypted')} ${file.path}');
      await _refresh();
    } catch (error) {
      _updateBackgroundJob(job, failed: true, status: '$error');
      _snack('${_language.t('snack.decrypt.error')} $error');
    }
  }

  Future<void> _openPreviewExternal(FilePreview preview) async {
    final selected = _selected;
    if (selected == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_language.t('preview.external.warning.title')),
        content: Text(_language.t('preview.external.warning')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(_language.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_language.t('preview.external')),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      var path = selected.path;
      if (preview.decrypted && preview.bytes != null) {
        final tempDir = await Directory.systemTemp.createTemp('secure_vault_');
        final tempFile = File(
          '${tempDir.path}${Platform.pathSeparator}${_safeFileName(preview.title)}',
        );
        await tempFile.writeAsBytes(preview.bytes!, flush: true);
        path = tempFile.path;
        _snack('${_language.t('preview.external.temp')} $path');
      }

      final extension = FileViewerService.extensionForName(preview.title);
      final association = _settings.extensionAssociations[extension];
      if (association != null && association.trim().isNotEmpty) {
        await PlatformServices.openWithCommand(association, path);
      } else {
        await PlatformServices.openExternal(path);
      }
    } catch (error) {
      _snack('${_language.t('snack.download.error')} $error');
    }
  }

  void _showPreviewWindow(
    FilePreview preview, {
    List<MediaPreviewItem>? mediaPlaylistOverride,
  }) {
    var currentPreview = preview;
    var videoRotationTurns = 0;
    showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => Dialog.fullscreen(
          child: Scaffold(
            appBar: AppBar(
              title: AnimatedBuilder(
                animation: _sharedMediaSession,
                builder: (context, _) {
                  final useMediaTitle = _isPlayablePreview(currentPreview);
                  final title =
                      useMediaTitle ? _sharedMediaSession.currentTitle : '';
                  return Text(title.isEmpty ? currentPreview.title : title);
                },
              ),
              actions: [
                PopupMenuButton<_PreviewAction>(
                  icon: const Icon(Icons.more_vert),
                  onSelected: (action) {
                    switch (action) {
                      case _PreviewAction.password:
                        _openWithPassword();
                      case _PreviewAction.window:
                        break;
                      case _PreviewAction.edit:
                        unawaited(() async {
                          final savedPath = await _openEditor(currentPreview);
                          if (savedPath == null) return;
                          final entry = await _explorer.entryForPath(savedPath);
                          if (entry == null) return;
                          final fresh = await _explorer.previewFile(
                            entry.path,
                            password: _activeFilePassword(),
                            commonPassword: _commonEncryptionPassword,
                          );
                          if (mounted) {
                            setState(() {
                              _selected = entry;
                              _preview = Future<FilePreview>.value(fresh);
                            });
                            setDialogState(() => currentPreview = fresh);
                          }
                        }());
                      case _PreviewAction.speak:
                        _startReadingPreview(currentPreview);
                      case _PreviewAction.ocrExtract:
                        if (_selected != null) {
                          _handleEntryAction(
                            _selected!,
                            _EntryAction.ocrExtract,
                          );
                        }
                      case _PreviewAction.rotateVideoLeft:
                        setDialogState(() {
                          videoRotationTurns = (videoRotationTurns - 1) % 4;
                        });
                      case _PreviewAction.rotateVideoRight:
                        setDialogState(() {
                          videoRotationTurns = (videoRotationTurns + 1) % 4;
                        });
                      case _PreviewAction.external:
                        _openPreviewExternal(currentPreview);
                      case _PreviewAction.copy:
                        if (_selected != null) {
                          _handleEntryAction(_selected!, _EntryAction.copy);
                        }
                      case _PreviewAction.cut:
                        if (_selected != null) {
                          _handleEntryAction(_selected!, _EntryAction.cut);
                        }
                      case _PreviewAction.delete:
                        if (_selected != null) {
                          _handleEntryAction(_selected!, _EntryAction.delete);
                          Navigator.pop(context);
                        }
                      case _PreviewAction.properties:
                        if (_selected != null) {
                          _handleEntryAction(
                              _selected!, _EntryAction.properties);
                        }
                      case _PreviewAction.hide:
                        Navigator.pop(context);
                    }
                  },
                  itemBuilder: (_) => [
                    if (_selected?.isEncrypted == true)
                      PopupMenuItem(
                        value: _PreviewAction.password,
                        child: Text(_language.t('preview.open.password')),
                      ),
                    if (_isEditablePreview(currentPreview))
                      PopupMenuItem(
                        value: _PreviewAction.edit,
                        child: Text(_language.t('editor.open')),
                      ),
                    if ((currentPreview.text ?? '').trim().isNotEmpty)
                      PopupMenuItem(
                        value: _PreviewAction.speak,
                        child: Text(_language.t('preview.speak')),
                      ),
                    if (_canOcrPreview(currentPreview))
                      PopupMenuItem(
                        value: _PreviewAction.ocrExtract,
                        child: Text(_language.t('ocr.extract')),
                      ),
                    if (currentPreview.contentKind == FileContentKind.video)
                      PopupMenuItem(
                        value: _PreviewAction.rotateVideoLeft,
                        child: Text(_language.t('video.rotate.left')),
                      ),
                    if (currentPreview.contentKind == FileContentKind.video)
                      PopupMenuItem(
                        value: _PreviewAction.rotateVideoRight,
                        child: Text(_language.t('video.rotate.right')),
                      ),
                    PopupMenuItem(
                      value: _PreviewAction.external,
                      child: Text(_language.t('preview.external')),
                    ),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                      value: _PreviewAction.copy,
                      child: Text(_language.t('explorer.copy')),
                    ),
                    PopupMenuItem(
                      value: _PreviewAction.cut,
                      child: Text(_language.t('explorer.cut')),
                    ),
                    PopupMenuItem(
                      value: _PreviewAction.delete,
                      child: Text(_language.t('explorer.delete')),
                    ),
                    PopupMenuItem(
                      value: _PreviewAction.properties,
                      child: Text(_language.t('explorer.properties')),
                    ),
                    PopupMenuItem(
                      value: _PreviewAction.hide,
                      child: Text(_language.t('common.cancel')),
                    ),
                  ],
                ),
              ],
            ),
            body: _PreviewContent(
              preview: currentPreview,
              language: _language,
              mediaPlaylist: mediaPlaylistOverride ?? _mediaPlaylist,
              imagePlaylist: _imagePlaylist,
              flashPlaylist: _flashPlaylist,
              mediaResumePositions: _settings.mediaResumePositions,
              onRememberMediaPosition: _rememberMediaPosition,
              fillAvailable: true,
              allowMiniDock: _isMiniPlaybackAllowedForPath(_selected?.path),
              videoRotationTurns: videoRotationTurns,
              onImageNavigate: (delta) async {
                final next = await _navigateImage(delta);
                if (next != null) {
                  setDialogState(() => currentPreview = next);
                }
              },
              onFlashNavigate: (delta) async {
                final next = await _navigateFlash(delta);
                if (next != null) {
                  setDialogState(() => currentPreview = next);
                }
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<String?> _openEditor(FilePreview preview) async {
    if (preview.bytes != null &&
        (preview.contentKind == FileContentKind.text ||
            preview.contentKind == FileContentKind.html ||
            preview.contentKind == FileContentKind.document ||
            preview.contentKind == FileContentKind.ebook ||
            preview.contentKind == FileContentKind.unknown)) {
      final savedPath = await showDialog<String>(
        context: context,
        builder: (context) => _TextBinaryEditorDialog(
          preview: preview,
          language: _language,
          currentDirectory: _currentPath,
          defaultOutputPath: _defaultEditedOutputPath(
            preview,
            FileViewerService.extensionForName(preview.title),
          ),
          onSaveBytes: _explorer.writeFile,
        ),
      );
      if (savedPath != null) {
        _snack('${_language.t('editor.saved')} $savedPath');
        await _refresh();
        await _refreshPreviewAfterEditorSave(savedPath);
      }
      return savedPath;
    }

    if (preview.contentKind == FileContentKind.image && preview.bytes != null) {
      final savedPath = await showDialog<String>(
        context: context,
        builder: (context) => _ImageEditorDialog(
          preview: preview,
          language: _language,
          currentDirectory: _currentPath,
          defaultOutputPath: _defaultEditedOutputPath(preview, '.png'),
          onSaveBytes: _explorer.writeFile,
        ),
      );
      if (savedPath != null) {
        _snack('${_language.t('editor.saved')} $savedPath');
        await _refresh();
        await _refreshPreviewAfterEditorSave(savedPath);
      }
      return savedPath;
    }

    if (preview.contentKind == FileContentKind.audio ||
        preview.contentKind == FileContentKind.video) {
      final savedPath = await showDialog<String>(
        context: context,
        builder: (context) => _FfmpegEditorDialog(
          preview: preview,
          language: _language,
          currentDirectory: _currentPath,
        ),
      );
      if (savedPath != null) {
        _snack('${_language.t('editor.saved')} $savedPath');
        await _refresh();
        await _refreshPreviewAfterEditorSave(savedPath);
      }
      return savedPath;
    }

    _snack(_language.t('editor.unsupported'));
    return null;
  }

  Future<void> _refreshPreviewAfterEditorSave(String savedPath) async {
    final entry = await _explorer.entryForPath(savedPath);
    if (entry == null || !mounted) return;
    final previewFuture = _explorer.previewFile(
      entry.path,
      password: _activeFilePassword(),
      commonPassword: _commonEncryptionPassword,
    );
    setState(() {
      _selected = entry;
      _preview = previewFuture;
    });
    try {
      final preview = await previewFuture;
      final mediaPlaylist = await _buildMediaPlaylist(entry, preview);
      final imagePlaylist = await _buildImagePlaylist(entry, preview);
      if (mounted && _selected?.path == entry.path) {
        setState(() {
          _mediaPlaylist = mediaPlaylist;
          _imagePlaylist = imagePlaylist;
        });
      }
    } catch (_) {}
  }

  Future<void> _editEntry(ExplorerEntry entry) async {
    if (entry.isDirectory || !entry.exists) {
      _snack(_language.t('editor.unsupported'));
      return;
    }
    try {
      final preview = await _explorer.previewFile(
        entry.path,
        password: _activeFilePassword(),
        commonPassword: _commonEncryptionPassword,
      );
      await _openEditor(preview);
    } catch (error) {
      _snack('${_language.t('editor.error')} $error');
    }
  }

  Future<void> _rememberMediaPosition(String key, Duration position) async {
    if (key.trim().isEmpty) return;
    final kind = FileViewerService.kindForName(key);
    if (kind == FileContentKind.video && !_settings.rememberVideoPositions) {
      return;
    }
    if (kind == FileContentKind.audio && !_settings.rememberAudioPositions) {
      return;
    }
    final next = await _settingsRepo
        .recordMediaResumePosition(_settings, key, position.inMilliseconds)
        .catchError((_) => _settings);
    if (mounted &&
        next.mediaResumePositions != _settings.mediaResumePositions) {
      setState(() => _settings = next);
    }
  }

  Future<void> _startReadingPreview(FilePreview preview) async {
    final text = FileViewerService.normalizeReadableText(
      preview.text ?? preview.subtitle,
    );
    if (text.trim().isEmpty) {
      _snack(_language.t('reader.empty'));
      return;
    }
    final key = _readingKeyFor(preview.sourcePath ?? preview.title);
    final chunks = _readingChunks(text);
    if (chunks.isEmpty) {
      _snack(_language.t('reader.empty'));
      return;
    }
    final savedChunk = ((_settings.mediaResumePositions[key] ?? 0) ~/ 10000 - 1)
        .clamp(0, chunks.length - 1)
        .toInt();
    final paths = await _readableSiblingPaths(preview.sourcePath);
    final pathIndex = preview.sourcePath == null
        ? -1
        : paths.indexWhere((path) => path == preview.sourcePath);
    setState(() {
      _readingSession = _ReadingSession(
        title: preview.title,
        key: key,
        chunks: chunks,
        paths: paths,
        pathIndex: pathIndex,
        chunkIndex: savedChunk,
      );
    });
    await _speakReadingChunk();
  }

  Future<List<String>> _readableSiblingPaths(String? sourcePath) async {
    if (sourcePath == null || sourcePath.trim().isEmpty) return const [];
    try {
      final parent = _explorer.parentPathFor(sourcePath);
      final snapshot = await _explorer.listDirectory(
        parent,
        commonPassword: _commonEncryptionPassword,
        filePassword: _activeFilePassword(),
        decryptNames: _settings.decryptNamesInExplorer,
      );
      return [
        for (final entry in snapshot.entries)
          if (entry.exists &&
              !entry.isDirectory &&
              _isReadableFileName(entry.name, entry.path))
            entry.path,
      ];
    } catch (_) {
      return [sourcePath];
    }
  }

  bool _isReadableFileName(String name, String path) {
    final displayedKind = FileViewerService.kindForName(name);
    final pathKind = FileViewerService.kindForName(path);
    return {
          FileContentKind.text,
          FileContentKind.html,
          FileContentKind.ebook,
          FileContentKind.document,
        }.contains(displayedKind) ||
        {
          FileContentKind.text,
          FileContentKind.html,
          FileContentKind.ebook,
          FileContentKind.document,
        }.contains(pathKind);
  }

  List<String> _readingChunks(String text) {
    final normalized = FileViewerService.normalizeReadableText(text);
    final chunks = <String>[];
    final buffer = StringBuffer();
    for (final paragraph in normalized.split(RegExp(r'\n{2,}'))) {
      final trimmed = paragraph.trim();
      if (trimmed.isEmpty) continue;
      if (buffer.length + trimmed.length > 900 && buffer.isNotEmpty) {
        chunks.add(buffer.toString().trim());
        buffer.clear();
      }
      if (buffer.isNotEmpty) buffer.write('\n\n');
      buffer.write(trimmed);
    }
    if (buffer.isNotEmpty) chunks.add(buffer.toString().trim());
    return chunks;
  }

  String _readingKeyFor(String source) => 'read:${source.trim()}';

  Future<void> _speakReadingChunk() async {
    final session = _readingSession;
    if (session == null || session.chunks.isEmpty) return;
    final index = session.chunkIndex.clamp(0, session.chunks.length - 1);
    final chunk = session.chunks[index.toInt()];
    await _rememberReadingPosition(session);
    await PlatformServices.speakText(chunk);
    _readingTimer?.cancel();
    if (!session.playing) return;
    final words = RegExp(r'\S+').allMatches(chunk).length;
    final seconds = (words * 0.42).clamp(4.0, 90.0).toDouble();
    _readingTimer = Timer(Duration(milliseconds: (seconds * 1000).round()), () {
      unawaited(_readingNextChunk(autoAdvance: true));
    });
  }

  Future<void> _rememberReadingPosition(_ReadingSession session) async {
    final next = await _settingsRepo
        .recordMediaResumePosition(
          _settings,
          session.key,
          (session.chunkIndex + 1) * 10000,
        )
        .catchError((_) => _settings);
    if (mounted &&
        next.mediaResumePositions != _settings.mediaResumePositions) {
      setState(() => _settings = next);
    }
  }

  Future<void> _readingTogglePlay() async {
    final session = _readingSession;
    if (session == null) return;
    if (session.playing) {
      _readingTimer?.cancel();
      await PlatformServices.stopSpeaking();
      setState(() => _readingSession = session.copyWith(playing: false));
      await _rememberReadingPosition(session);
      return;
    }
    setState(() => _readingSession = session.copyWith(playing: true));
    await _speakReadingChunk();
  }

  Future<void> _readingNextChunk({bool autoAdvance = false}) async {
    final session = _readingSession;
    if (session == null) return;
    if (session.chunkIndex + 1 >= session.chunks.length) {
      await _readingNextFile();
      return;
    }
    setState(() {
      _readingSession = session.copyWith(
        chunkIndex: session.chunkIndex + 1,
        playing: autoAdvance ? session.playing : true,
      );
    });
    await _speakReadingChunk();
  }

  Future<void> _readingPreviousChunk() async {
    final session = _readingSession;
    if (session == null) return;
    setState(() {
      _readingSession = session.copyWith(
        chunkIndex: math.max(0, session.chunkIndex - 1),
        playing: true,
      );
    });
    await _speakReadingChunk();
  }

  Future<void> _readingNextFile() async {
    final session = _readingSession;
    if (session == null || session.paths.isEmpty) return;
    final nextIndex = session.pathIndex < 0
        ? 0
        : (session.pathIndex + 1) % session.paths.length;
    await _loadReadingPath(session.paths[nextIndex], nextIndex);
  }

  Future<void> _loadReadingPath(String path, int pathIndex) async {
    try {
      final preview = await _explorer.previewFile(
        path,
        password: _activeFilePassword(),
        commonPassword: _commonEncryptionPassword,
      );
      final text = FileViewerService.normalizeReadableText(
        preview.text ?? preview.subtitle,
      );
      final chunks = _readingChunks(text);
      if (chunks.isEmpty) return;
      final key = _readingKeyFor(path);
      final savedChunk =
          ((_settings.mediaResumePositions[key] ?? 0) ~/ 10000 - 1)
              .clamp(0, chunks.length - 1)
              .toInt();
      setState(() {
        _readingSession = _readingSession?.copyWith(
          title: preview.title,
          key: key,
          chunks: chunks,
          pathIndex: pathIndex,
          chunkIndex: savedChunk,
          playing: true,
        );
      });
      await _speakReadingChunk();
    } catch (error) {
      _snack('${_language.t('reader.error')} $error');
    }
  }

  Future<void> _closeReadingSession() async {
    final session = _readingSession;
    _readingTimer?.cancel();
    await PlatformServices.stopSpeaking();
    if (session != null) await _rememberReadingPosition(session);
    if (mounted) setState(() => _readingSession = null);
  }

  Future<void> _resumeLastPlayedMedia() async {
    final key = _settings.lastPlayedMediaKey;
    if (key == null || key.trim().isEmpty) return;
    final entry = await _explorer.entryForPath(key);
    if (entry != null) {
      await _openEntry(entry);
    }
  }

  KeyEventResult _handleHardwareMediaKey(FocusNode node, KeyEvent event) {
    if (!_settings.headsetMediaControls || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final player = _sharedMediaSession.player;
    if (key == LogicalKeyboardKey.mediaTrackNext) {
      unawaited(player.next());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackPrevious) {
      unawaited(player.previous());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPause) {
      unawaited(player.pause());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      if (!_sharedMediaSession.active) {
        unawaited(_resumeLastPlayedMedia());
      } else {
        unawaited(player.playOrPause());
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _saveSecurity({
    required String? appPassword,
    required String? appPasswordCurrent,
    required String? filePassword,
    required String? filePasswordCurrent,
    required bool separate,
    required bool remember,
    required bool wipe,
    required String? commonEncryptionPassword,
    required String? commonEncryptionKeyFilePath,
    required String commonEncryptionAlgorithm,
    required int filePasswordGraceSeconds,
    required bool blockScreenCapture,
    required String languageCode,
    required String? customLanguagePath,
    required bool loggingEnabled,
    required Map<String, String> extensionAssociations,
    required bool rememberRecentFiles,
    required int recentSidebarCount,
    required int recentRememberCount,
    required int favoriteSidebarCount,
    required int locationSidebarCount,
    required bool decryptNamesInExplorer,
    required bool openFullscreenOnHiddenPreviewTap,
    required bool autoScaleForDpi,
    required double fileTextScale,
    required double fileIconScale,
    required List<String> galleryFolders,
    required String galleryExclusions,
    required List<String> musicFolders,
    required String musicExclusions,
    required List<String> videoFolders,
    required String videoExclusions,
    required List<String> documentFolders,
    required String documentExclusions,
    required bool torrentEnabled,
    required bool storeSettingsInUserProfile,
    required bool rememberLastFolder,
    required String navigationPolicy,
    required double interfaceTextScale,
    required double interfaceScale,
    required double toolbarIconScale,
    required String searchMode,
    required bool searchUseRegex,
    required bool searchRecursive,
    required String? programProxy,
    required String? globalPluginProxy,
    required List<String> visibleNavigationSections,
    required bool enableBackgroundVideo,
    required bool enableMiniVideo,
    required bool enableMiniAudio,
    required bool continueMediaInBackground,
    required bool autoCloseMediaOnSectionChange,
    required bool showVideoThumbnails,
    required bool animateVideoThumbnails,
    required bool showAudioArtwork,
    required bool cacheThumbnailsInMemory,
    required bool previewVisibleByDefault,
    required bool rememberPreviewVisibility,
    required bool includeFavoritesInPathDropdown,
    required bool requirePasswordOnAndroidResume,
    required bool showHiddenFiles,
    required bool showSystemFiles,
    required bool androidMediaNotificationControls,
    required bool headsetMediaControls,
    required bool externalFloatingPlayer,
    required bool minimizeToTrayOnClose,
    required bool encryptThumbnailCache,
    required bool encryptResumePositions,
    required int progressAutoCollapseSeconds,
    required bool rememberVideoPositions,
    required bool rememberAudioPositions,
  }) async {
    if (languageCode == 'custom' &&
        (customLanguagePath == null || customLanguagePath.trim().isEmpty)) {
      throw const FormatException('Custom language path is empty.');
    }
    if (languageCode == 'custom') {
      await AppLanguage.fromFile(customLanguagePath!.trim());
    }

    if (storeSettingsInUserProfile != _settings.storeSettingsInUserProfile) {
      await AppPaths.setUseUserDataDirectory(storeSettingsInUserProfile);
    }

    final next = await _settingsRepo.setPasswords(
      current: _settings,
      appPassword: appPassword,
      currentAppPassword: appPasswordCurrent,
      filePassword: filePassword,
      currentFilePassword: filePasswordCurrent,
      useSeparateFilePassword: separate,
      rememberFilePasswords: remember,
      wipeSavedPasswordsOnFailedLogin: wipe,
      commonEncryptionPassword: commonEncryptionPassword,
      commonEncryptionKeyFilePath: commonEncryptionKeyFilePath,
      commonEncryptionAlgorithm: commonEncryptionAlgorithm,
      filePasswordGraceSeconds: filePasswordGraceSeconds,
      blockScreenCapture: blockScreenCapture,
      languageCode: languageCode,
      customLanguagePath: customLanguagePath,
      loggingEnabled: loggingEnabled,
      extensionAssociations: extensionAssociations,
      rememberRecentFiles: rememberRecentFiles,
      recentSidebarCount: recentSidebarCount,
      recentRememberCount: recentRememberCount,
      favoriteSidebarCount: favoriteSidebarCount,
      locationSidebarCount: locationSidebarCount,
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
      storeSettingsInUserProfile: storeSettingsInUserProfile,
      rememberLastFolder: rememberLastFolder,
      navigationPolicy: navigationPolicy,
      interfaceTextScale: interfaceTextScale,
      interfaceScale: interfaceScale,
      toolbarIconScale: toolbarIconScale,
      searchMode: searchMode,
      searchUseRegex: searchUseRegex,
      searchRecursive: searchRecursive,
      programProxy: programProxy,
      globalPluginProxy: globalPluginProxy,
      visibleNavigationSections: visibleNavigationSections,
      enableBackgroundVideo: enableBackgroundVideo,
      enableMiniVideo: enableMiniVideo,
      enableMiniAudio: enableMiniAudio,
      continueMediaInBackground: continueMediaInBackground,
      autoCloseMediaOnSectionChange: autoCloseMediaOnSectionChange,
      showVideoThumbnails: showVideoThumbnails,
      animateVideoThumbnails: animateVideoThumbnails,
      showAudioArtwork: showAudioArtwork,
      cacheThumbnailsInMemory: cacheThumbnailsInMemory,
      previewVisibleByDefault: previewVisibleByDefault,
      rememberPreviewVisibility: rememberPreviewVisibility,
      savedPreviewVisible: _previewVisible,
      includeFavoritesInPathDropdown: includeFavoritesInPathDropdown,
      requirePasswordOnAndroidResume: requirePasswordOnAndroidResume,
      showHiddenFiles: showHiddenFiles,
      showSystemFiles: showSystemFiles,
      androidMediaNotificationControls: androidMediaNotificationControls,
      headsetMediaControls: headsetMediaControls,
      externalFloatingPlayer: externalFloatingPlayer,
      minimizeToTrayOnClose: minimizeToTrayOnClose,
      encryptThumbnailCache: encryptThumbnailCache,
      encryptResumePositions: encryptResumePositions,
      progressAutoCollapseSeconds: progressAutoCollapseSeconds,
      rememberVideoPositions: rememberVideoPositions,
      rememberAudioPositions: rememberAudioPositions,
    );
    AppLog.enabled = next.loggingEnabled;
    MediaArtworkService.configure(
      cacheEnabled: next.cacheThumbnailsInMemory,
      persistentCacheEnabled: true,
      encryptPersistentCache: next.encryptThumbnailCache,
    );
    await PlatformServices.setScreenProtection(next.blockScreenCapture);
    await PlatformServices.setMinimizeToTrayOnClose(next.minimizeToTrayOnClose)
        .catchError((_) {});
    final language = await AppLanguage.load(next);
    await PlatformServices.setWindowTitle(language.appTitle).catchError((_) {});
    setState(() {
      _settings = next;
      _language = language;
      _searchMode = next.searchMode;
      _searchUseRegex = next.searchUseRegex;
      _searchRecursive = next.searchRecursive;
      if (!next.hasFilePassword) {
        _settingsRepo.loadCommonEncryptionPassword(next).then((value) {
          if (mounted) setState(() => _commonEncryptionPassword = value);
        }).catchError((_) {});
      } else {
        _commonEncryptionPassword = null;
      }
      if (remember) {
        final remembered = separate ? filePassword : appPassword;
        if (remembered != null && remembered.isNotEmpty) {
          _setSessionFilePassword(remembered);
        }
      }
    });
  }

  Future<void> _clearRemembered() async {
    final next = await _settingsRepo.clearSavedFilePassword(_settings);
    setState(() {
      _settings = next;
      _filePassword = null;
    });
    _snack(_language.t('settings.remembered.deleted'));
  }

  Future<String> _validateLanguageFile(String path) async {
    await AppLanguage.fromFile(path);
    return _language.t('settings.language.valid');
  }

  Future<String> _installLanguageFile(String path) async {
    final language = await AppLanguage.fromFile(path);
    final dir = await AppPaths.languagesDirectory();
    final target = File(
      '${dir.path}${Platform.pathSeparator}${language.code}_${basename(path)}',
    );
    await File(path).copy(target.path);
    return '${_language.t('settings.language.installed')} ${target.path}';
  }

  Future<String> _installPluginZip(String path) async {
    final dir = await _plugins.installPluginZip(path);
    final pluginDefs = await _plugins.loadPlugins();
    final enabledPluginDefs = _enabledPluginDefs(pluginDefs, _settings);
    _explorer.configurePlugins(enabledPluginDefs, _settings.connectionProfiles);
    final locations = await _explorer.loadLocations(
        enabledPluginDefs, _settings.connectionProfiles);
    final pluginMediaSections =
        _pluginRuntime(pluginDefs, _settings).mediaSections();
    setState(() {
      _pluginDefs = pluginDefs;
      _pluginMediaSections = pluginMediaSections;
      _locations = locations;
    });
    return '${_language.t('settings.plugin.installed')} ${dir.path}';
  }

  Future<String> _exportPluginZip(String pluginId) async {
    final exportDir = await AppPaths.exportDirectory();
    final timestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final target =
        '${exportDir.path}${Platform.pathSeparator}${pluginId}_$timestamp.zip';
    final file = await _plugins.exportPluginZip(pluginId, target);
    return '${_language.t('settings.plugin.exported')} ${file.path}';
  }

  Future<String> _deletePlugin(String pluginId) async {
    await _plugins.deletePlugin(pluginId);
    final pluginDefs = await _plugins.loadPlugins();
    var settings = _settings;
    final filteredProfiles = settings.connectionProfiles
        .where((profile) => profile.pluginId != pluginId)
        .toList();
    if (filteredProfiles.length != settings.connectionProfiles.length) {
      settings =
          await _settingsRepo.setConnectionProfiles(settings, filteredProfiles);
    }
    if (settings.pluginSettingsById.containsKey(pluginId)) {
      settings = await _settingsRepo.setPluginSettings(
        settings,
        pluginId,
        const <String, String>{},
      );
    }
    if (settings.disabledPluginIds.contains(pluginId)) {
      settings = settings.copyWith(
        disabledPluginIds: [
          for (final id in settings.disabledPluginIds)
            if (id != pluginId) id,
        ],
      );
      await _settingsRepo.save(settings);
    }
    final enabledPluginDefs = _enabledPluginDefs(pluginDefs, settings);
    _explorer.configurePlugins(enabledPluginDefs, settings.connectionProfiles);
    final locations = await _explorer.loadLocations(
        enabledPluginDefs, settings.connectionProfiles);
    final pluginMediaSections =
        _pluginRuntime(pluginDefs, settings).mediaSections();
    if (mounted) {
      setState(() {
        _settings = settings;
        _pluginDefs = pluginDefs;
        _pluginMediaSections = pluginMediaSections;
        if (_activePluginMediaSection != null &&
            !pluginMediaSections.any((section) =>
                section.runtimeId == _activePluginMediaSection!.runtimeId)) {
          _activePluginMediaSection = null;
          _page = ShellPage.explorer;
        }
        _locations = locations;
      });
    }
    return _language.t('settings.plugin.deleted');
  }

  DirectorySnapshot _filterSnapshotBySearch(DirectorySnapshot snapshot) {
    final query = _searchQuery.trim();
    if (query.isEmpty) return snapshot;
    bool matches(String value) {
      if (_searchUseRegex) {
        try {
          return RegExp(query, caseSensitive: false).hasMatch(value);
        } catch (_) {
          return value.toLowerCase().contains(query.toLowerCase());
        }
      }
      return value.toLowerCase().contains(query.toLowerCase());
    }

    return DirectorySnapshot(
      path: snapshot.path,
      error: snapshot.error,
      entries: [
        for (final entry in snapshot.entries)
          if (matches(entry.name) || matches(entry.path)) entry,
      ],
    );
  }

  bool get _isMediaLibraryPage =>
      _page == ShellPage.music || _page == ShellPage.video;

  bool _isPlayablePreview(FilePreview preview) =>
      preview.contentKind == FileContentKind.audio ||
      preview.contentKind == FileContentKind.video;

  bool _shouldPlayInExistingMini(FilePreview preview) =>
      _isPlayablePreview(preview) &&
      _sharedMediaSession.active &&
      _sharedMediaSession.collapsed;

  bool _shouldPlayInLocationMini(FilePreview preview, bool forceFullScreen) {
    if (forceFullScreen ||
        _isMediaLibraryPage ||
        !_isPlayablePreview(preview)) {
      return false;
    }
    if (!_settings.continueMediaInBackground) return false;
    return _isMiniPlaybackAllowedForPath(preview.sourcePath);
  }

  bool _shouldOpenMediaFullscreen(FilePreview preview, bool forceFullScreen) {
    if (_shouldPlayInExistingMini(preview)) return false;
    if (forceFullScreen) return true;
    if (_isMediaLibraryPage && _isPlayablePreview(preview)) {
      return !_sharedMediaSession.active;
    }
    return !_previewVisible && _settings.openFullscreenOnHiddenPreviewTap;
  }

  List<MediaPreviewItem> _playlistWithSelectedPreview(
    FilePreview preview,
    List<MediaPreviewItem> playlist, {
    required String selectedPath,
  }) {
    if (!_isPlayablePreview(preview)) return playlist;
    if (playlist.any((item) =>
        item.path == preview.sourcePath ||
        item.resumeKey == selectedPath ||
        item.title == preview.title)) {
      return playlist;
    }
    return [
      MediaPreviewItem(
        title: preview.title,
        kind: preview.contentKind,
        path: preview.decrypted ? null : preview.sourcePath,
        resumeKey: selectedPath,
        bytes: preview.decrypted && preview.bytes != null
            ? Uint8List.fromList(preview.bytes!)
            : null,
        encrypted: preview.decrypted,
      ),
      ...playlist,
    ];
  }

  Future<void> _openMediaEntryFromList(
    ExplorerEntry entry,
    List<ExplorerEntry> playlistEntries,
  ) async {
    final kind = FileViewerService.kindForName(entry.name);
    final playlist = _mediaItemsFromEntries(
      playlistEntries,
      kind == FileContentKind.video
          ? FileContentKind.video
          : FileContentKind.audio,
    );
    await _openEntry(entry, mediaPlaylistOverride: playlist);
  }

  Future<void> _playMediaPreviewInSession(
    FilePreview preview,
    List<MediaPreviewItem> playlist,
  ) async {
    if (!_isPlayablePreview(preview)) return;
    final allowMiniDock = _isMiniPlaybackAllowedForPath(preview.sourcePath);
    final effectivePlaylist = playlist.isEmpty
        ? [
            MediaPreviewItem(
              title: preview.title,
              kind: preview.contentKind,
              path: preview.decrypted ? null : preview.sourcePath,
              resumeKey: preview.sourcePath,
              bytes: preview.decrypted && preview.bytes != null
                  ? Uint8List.fromList(preview.bytes!)
                  : null,
              encrypted: preview.decrypted,
            ),
          ]
        : playlist;
    var initialIndex = effectivePlaylist.indexWhere((item) =>
        item.title == preview.title ||
        item.path == preview.sourcePath ||
        item.resumeKey == preview.sourcePath);
    if (initialIndex < 0) initialIndex = 0;
    final wasAlreadyOpen =
        _sharedMediaSession.isSame(preview, effectivePlaylist);
    await _sharedMediaSession.open(
      preview: preview,
      playlist: effectivePlaylist,
      language: _language,
      initialIndex: initialIndex,
      repeatOne: false,
      shuffle: false,
      allowMiniDock: allowMiniDock,
    );
    final item = effectivePlaylist[initialIndex];
    final resumeMs = _settings.mediaResumePositions[item.resumeKey ?? ''] ?? 0;
    if (!wasAlreadyOpen && resumeMs > 1500) {
      await _sharedMediaSession.player.seek(Duration(milliseconds: resumeMs));
    }
  }

  Future<String> _setPluginEnabled(String pluginId, bool enabled) async {
    final disabled = _settings.disabledPluginIds.toSet();
    if (enabled) {
      disabled.remove(pluginId);
    } else {
      disabled.add(pluginId);
    }
    final next = _settings.copyWith(
      disabledPluginIds: disabled.toList()..sort(),
    );
    await _settingsRepo.save(next);
    final enabledPluginDefs = _enabledPluginDefs(_pluginDefs, next);
    _explorer.configurePlugins(enabledPluginDefs, next.connectionProfiles);
    final locations = await _explorer.loadLocations(
      enabledPluginDefs,
      next.connectionProfiles,
    );
    final pluginMediaSections =
        _pluginRuntime(_pluginDefs, next).mediaSections();
    if (mounted) {
      setState(() {
        _settings = next;
        _locations = locations;
        _pluginMediaSections = pluginMediaSections;
        if (_activePluginMediaSection != null &&
            !pluginMediaSections.any((section) =>
                section.runtimeId == _activePluginMediaSection!.runtimeId)) {
          _activePluginMediaSection = null;
          _page = ShellPage.explorer;
          _preview = null;
          _selected = null;
        }
      });
    }
    return enabled
        ? _language.t('settings.plugin.enabled')
        : _language.t('settings.plugin.disabled');
  }

  void _openPluginMediaSection(PluginMediaSection section) {
    unawaited(_openPluginMediaSectionAsync(section));
  }

  Future<void> _openPluginMediaSectionAsync(PluginMediaSection section) async {
    final snapshotFuture = _pluginMediaSnapshot(section);
    setState(() {
      _page = section.kind == FileContentKind.video
          ? ShellPage.video
          : ShellPage.music;
      _activePluginMediaSection = section;
      _showingRecent = false;
      _showingLocations = false;
      _currentPath = section.title;
      _selected = null;
      _preview = null;
      _mediaPlaylist = const [];
      _imagePlaylist = const [];
      _selectedPaths = const <String>{};
      _snapshot = snapshotFuture;
    });
    final snapshot = await snapshotFuture;
    if (!mounted || _activePluginMediaSection?.runtimeId != section.runtimeId) {
      return;
    }
    final playlist = _mediaItemsFromEntries(snapshot.entries, section.kind);
    setState(() => _mediaPlaylist = playlist);
  }

  Future<DirectorySnapshot> _pluginMediaSnapshot(
    PluginMediaSection section,
  ) =>
      _webMusicPlugins.snapshot(section, query: _searchQuery);

  Future<String> _savePluginSettings(
    String pluginId,
    Map<String, String> settings,
  ) async {
    final next = await _settingsRepo.setPluginSettings(
      _settings,
      pluginId,
      settings,
    );
    final pluginMediaSections =
        _pluginRuntime(_pluginDefs, next).mediaSections();
    if (!mounted) return _language.t('settings.saved');
    setState(() {
      _settings = next;
      _pluginMediaSections = pluginMediaSections;
      if (_activePluginMediaSection != null) {
        _activePluginMediaSection = pluginMediaSections
            .where((section) =>
                section.runtimeId == _activePluginMediaSection!.runtimeId)
            .firstOrNull;
      }
    });
    return _language.t('settings.saved');
  }

  Future<void> _showAddMusicSourceDialog() async {
    final plugin = _pluginDefs
        .where((item) => item.id == 'universal-web-music')
        .firstOrNull;
    if (plugin == null) {
      _snack(_language.t('plugin.music.unavailable'));
      return;
    }
    final titleController = TextEditingController();
    final siteController = TextEditingController(text: 'https://');
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_language.t('plugin.music.add.site')),
        content: SizedBox(
          width: 520,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: titleController,
              autofocus: true,
              decoration:
                  InputDecoration(labelText: _language.t('common.name')),
            ),
            TextField(
              controller: siteController,
              decoration:
                  InputDecoration(labelText: _language.t('plugin.music.site')),
            ),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_language.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, {
              'title': titleController.text.trim(),
              'baseUrl': siteController.text.trim(),
            }),
            child: Text(_language.t('common.add')),
          ),
        ],
      ),
    );
    titleController.dispose();
    siteController.dispose();
    if (result == null) return;
    final title = result['title'] ?? '';
    var baseUrl = result['baseUrl'] ?? '';
    if (baseUrl.isNotEmpty && Uri.tryParse(baseUrl)?.hasScheme != true) {
      baseUrl = 'https://$baseUrl';
    }
    if (title.isEmpty || Uri.tryParse(baseUrl)?.hasScheme != true) {
      _snack(_language.t('plugin.music.invalid.site'));
      return;
    }
    final current =
        _settings.pluginSettingsById[plugin.id] ?? const <String, String>{};
    final sites = <Map<String, Object?>>[];
    final existing = current['sitesJson'];
    if (existing != null && existing.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(existing);
        if (decoded is List) {
          for (final item in decoded.whereType<Map>()) {
            sites.add(
              item.map((key, value) => MapEntry(key.toString(), value)),
            );
          }
        }
      } catch (_) {}
    }
    sites.add({
      'id': '${DateTime.now().millisecondsSinceEpoch}',
      'title': title,
      'baseUrl': baseUrl,
      'searchPath': '/search?q={query}',
    });
    final message = await _savePluginSettings(plugin.id, {
      ...current,
      'sitesJson': jsonEncode(sites),
    });
    _snack(message);
  }

  Future<void> _downloadPluginMediaEntry(ExplorerEntry entry) async {
    await _downloadPluginMediaEntries([entry]);
  }

  Future<void> _downloadPluginMediaEntries(List<ExplorerEntry> entries) async {
    final downloadable = entries
        .where((entry) => !entry.isDirectory && _isHttpMedia(entry.path))
        .toList();
    if (downloadable.isEmpty) return;
    final targetController = TextEditingController(
      text: _standardMediaRoots(MediaSection.music).firstOrNull ??
          (Platform.environment['USERPROFILE'] ??
              Platform.environment['HOME'] ??
              ''),
    );
    final targetPath = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_language.t('plugin.media.download')),
        content: SizedBox(
          width: 520,
          child: _PathTextField(
            controller: targetController,
            label: _language.t('common.target.folder'),
            pickDirectory: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_language.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, targetController.text),
            child: Text(_language.t('common.download')),
          ),
        ],
      ),
    );
    targetController.dispose();
    if (targetPath == null || targetPath.trim().isEmpty) return;
    final job = _startBackgroundJob(
      downloadable.length == 1
          ? '${_language.t('plugin.media.download')}: ${downloadable.first.name}'
          : '${_language.t('plugin.media.download.selected')}: ${downloadable.length}',
      total: 100,
    );
    try {
      final targetDir = Directory(_expandPathVariables(targetPath.trim()));
      File? lastFile;
      for (var i = 0; i < downloadable.length; i++) {
        final entry = downloadable[i];
        lastFile = await _webMusicPlugins.download(
          entry,
          targetDir,
          onProgress: (received, total) {
            final itemPercent = total == null || total <= 0
                ? math.min(99, (received / 1024 / 1024).floor())
                : ((received / total) * 100).floor();
            final overall =
                (((i + itemPercent / 100) / downloadable.length) * 100).floor();
            _updateBackgroundJob(
              job,
              completed: overall.clamp(0, 99).toInt(),
              status:
                  '${entry.name}: ${_formatBytes(received)}${total == null ? '' : ' / ${_formatBytes(total)}'}',
            );
          },
        );
      }
      _updateBackgroundJob(
        job,
        completed: 100,
        status: lastFile?.path ?? targetDir.path,
        done: true,
      );
      _snack('${_language.t('transfer.done')} ${targetDir.path}');
    } catch (error) {
      _updateBackgroundJob(job, status: '$error', failed: true);
      _snack('$error');
    }
  }

  Future<void> _showYtDlpDownloadDialog(String? targetDirectory) async {
    final pluginId = 'yt-dlp-downloader';
    final plugin = _pluginDefs.where((item) => item.id == pluginId).firstOrNull;
    if (plugin == null || _settings.disabledPluginIds.contains(pluginId)) {
      _snack(_language.t('plugin.ytdlp.unavailable'));
      return;
    }
    final settings =
        _settings.pluginSettingsById[pluginId] ?? const <String, String>{};
    final urlController = TextEditingController(text: 'https://');
    final targetController = TextEditingController(
      text: targetDirectory ??
          (Platform.environment['USERPROFILE'] ??
              Platform.environment['HOME'] ??
              Directory.current.path),
    );
    final threadsController =
        TextEditingController(text: settings['threads'] ?? '4');
    var videoQuality = settings['videoQuality'] ?? 'best';
    var audioQuality = settings['audioQuality'] ?? 'best';
    final version = await _ytDlpVersion().catchError((_) => 'not installed');
    if (!mounted) return;
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(_language.t('plugin.ytdlp.download.url')),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                  controller: urlController,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: _language.t('plugin.ytdlp.url'),
                  ),
                ),
                const SizedBox(height: 12),
                _PathTextField(
                  controller: targetController,
                  label: _language.t('common.target.folder'),
                  pickDirectory: true,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: videoQuality,
                  decoration: InputDecoration(
                    labelText: _language.t('plugin.ytdlp.video.quality'),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'best', child: Text('best')),
                    DropdownMenuItem(value: '2160', child: Text('2160p')),
                    DropdownMenuItem(value: '1440', child: Text('1440p')),
                    DropdownMenuItem(value: '1080', child: Text('1080p')),
                    DropdownMenuItem(value: '720', child: Text('720p')),
                    DropdownMenuItem(value: '480', child: Text('480p')),
                    DropdownMenuItem(value: 'audio', child: Text('audio only')),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => videoQuality = value ?? 'best'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: audioQuality,
                  decoration: InputDecoration(
                    labelText: _language.t('plugin.ytdlp.audio.quality'),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'best', child: Text('best')),
                    DropdownMenuItem(value: '320', child: Text('320 kbps')),
                    DropdownMenuItem(value: '192', child: Text('192 kbps')),
                    DropdownMenuItem(value: '128', child: Text('128 kbps')),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => audioQuality = value ?? 'best'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: threadsController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: _language.t('plugin.ytdlp.threads'),
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child:
                      Text('${_language.t('plugin.ytdlp.version')}: $version'),
                ),
              ]),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_language.t('common.cancel')),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                Navigator.pop(context);
                await _updateYtDlpForCurrentSystem(plugin);
              },
              icon: const Icon(Icons.system_update_alt),
              label: Text(_language.t('plugin.ytdlp.update')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, {
                'url': urlController.text.trim(),
                'target': targetController.text.trim(),
                'videoQuality': videoQuality,
                'audioQuality': audioQuality,
                'threads': threadsController.text.trim(),
              }),
              child: Text(_language.t('common.download')),
            ),
          ],
        ),
      ),
    );
    urlController.dispose();
    targetController.dispose();
    threadsController.dispose();
    if (result == null) return;
    await _savePluginSettings(pluginId, {
      ...settings,
      'videoQuality': result['videoQuality'] ?? 'best',
      'audioQuality': result['audioQuality'] ?? 'best',
      'threads': result['threads'] ?? '4',
    });
    await _runYtDlpDownload(
      url: result['url'] ?? '',
      targetDirectory: result['target'] ?? '',
      videoQuality: result['videoQuality'] ?? 'best',
      audioQuality: result['audioQuality'] ?? 'best',
      threads: int.tryParse(result['threads'] ?? '4') ?? 4,
    );
  }

  Future<void> _runYtDlpDownload({
    required String url,
    required String targetDirectory,
    required String videoQuality,
    required String audioQuality,
    required int threads,
  }) async {
    if (url.trim().isEmpty || Uri.tryParse(url)?.hasScheme != true) {
      _snack(_language.t('plugin.ytdlp.invalid.url'));
      return;
    }
    final executable = await _ytDlpExecutablePath();
    final isVirtualTarget = _explorer.isVirtualPath(targetDirectory);
    final localTarget = isVirtualTarget
        ? await Directory.systemTemp.createTemp('securevault_ytdlp_')
        : Directory(_expandPathVariables(targetDirectory));
    await localTarget.create(recursive: true);
    final before = await _safeDirectoryFiles(localTarget);
    final job = _startBackgroundJob('yt-dlp: $url', total: 100);
    try {
      final args = <String>[
        '--newline',
        '--no-color',
        '-P',
        localTarget.path,
        '-N',
        threads.clamp(1, 32).toString(),
        '-f',
        _ytDlpFormat(videoQuality),
        if (videoQuality == 'audio') ...[
          '-x',
          '--audio-format',
          'mp3',
          if (audioQuality != 'best') ...['--audio-quality', audioQuality],
        ],
        url,
      ];
      final process = await Process.start(
        executable,
        args,
        runInShell: executable == 'yt-dlp' || executable == 'yt-dlp.exe',
      );
      void handleLine(String line) {
        final match = RegExp(r'(\d+(?:\.\d+)?)%').firstMatch(line);
        if (match != null) {
          final percent = double.tryParse(match.group(1) ?? '') ?? 0;
          _updateBackgroundJob(
            job,
            completed: percent.floor().clamp(0, 99).toInt(),
            status: line.trim(),
          );
        } else if (line.trim().isNotEmpty) {
          _updateBackgroundJob(job, status: line.trim());
        }
        if (job.cancelled) process.kill();
      }

      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(handleLine);
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(handleLine);
      final exitCode = await process.exitCode;
      if (job.cancelled) throw StateError('Cancelled');
      if (exitCode != 0) throw ProcessException(executable, args, '', exitCode);
      final after = await _safeDirectoryFiles(localTarget);
      final created = after
          .where((file) => !before.any((old) => old.path == file.path))
          .toList();
      if (isVirtualTarget) {
        for (final file in created) {
          await _explorer.createFile(
            targetDirectory,
            basename(file.path),
            await file.readAsBytes(),
          );
        }
      }
      _updateBackgroundJob(
        job,
        completed: 100,
        status: _language.t('transfer.done'),
        done: true,
      );
      _snack(_language.t('transfer.done'));
      await _refresh();
    } catch (error) {
      _updateBackgroundJob(job, status: '$error', failed: true);
      _snack('${_language.t('snack.operation.error')} $error');
    } finally {
      if (isVirtualTarget) {
        try {
          await localTarget.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  Future<List<File>> _safeDirectoryFiles(Directory directory) async {
    if (!await directory.exists()) return const <File>[];
    final files = <File>[];
    await for (final entity in directory.list(recursive: true)) {
      if (entity is File) files.add(entity);
    }
    return files;
  }

  String _ytDlpFormat(String videoQuality) {
    if (videoQuality == 'audio') return 'bestaudio/best';
    if (videoQuality == 'best') return 'bestvideo+bestaudio/best';
    final height = int.tryParse(videoQuality) ?? 1080;
    return 'bestvideo[height<=$height]+bestaudio/best[height<=$height]';
  }

  Future<String> _ytDlpExecutablePath() async {
    final plugin =
        _pluginDefs.where((item) => item.id == 'yt-dlp-downloader').firstOrNull;
    if (plugin != null) {
      final component = Platform.isWindows
          ? '${plugin.rootPath}${Platform.pathSeparator}components${Platform.pathSeparator}yt-dlp${Platform.pathSeparator}windows-x64${Platform.pathSeparator}yt-dlp.exe'
          : '${plugin.rootPath}${Platform.pathSeparator}components${Platform.pathSeparator}yt-dlp${Platform.pathSeparator}linux-x64${Platform.pathSeparator}yt-dlp';
      if (await File(component).exists()) return component;
    }
    return Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp';
  }

  Future<String> _ytDlpVersion() async {
    final executable = await _ytDlpExecutablePath();
    final result = await Process.run(
      executable,
      ['--version'],
      runInShell: executable == 'yt-dlp' || executable == 'yt-dlp.exe',
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(const Duration(seconds: 4));
    if (result.exitCode != 0) throw StateError(result.stderr.toString());
    return result.stdout.toString().trim();
  }

  Future<void> _updateYtDlpForCurrentSystem(
    CloudPluginDefinition plugin,
  ) async {
    if (!Platform.isWindows) {
      _snack(_language.t('plugin.ytdlp.update.windows.only'));
      return;
    }
    final target = File(
      '${plugin.rootPath}${Platform.pathSeparator}components${Platform.pathSeparator}yt-dlp${Platform.pathSeparator}windows-x64${Platform.pathSeparator}yt-dlp.exe',
    );
    final job =
        _startBackgroundJob(_language.t('plugin.ytdlp.update'), total: 100);
    try {
      await target.parent.create(recursive: true);
      await _downloadUriToFile(
        Uri.parse(
          'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe',
        ),
        target,
        job,
      );
      _updateBackgroundJob(
        job,
        completed: 100,
        status: target.path,
        done: true,
      );
      _snack('${_language.t('settings.saved')} ${target.path}');
    } catch (error) {
      _updateBackgroundJob(job, status: '$error', failed: true);
      _snack('$error');
    }
  }

  Future<void> _downloadUriToFile(
    Uri uri,
    File target,
    _BackgroundJob job,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode >= 400) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      final total = response.contentLength > 0 ? response.contentLength : null;
      var received = 0;
      final sink = target.openWrite();
      try {
        await for (final chunk in response) {
          if (job.cancelled) throw StateError('Cancelled');
          received += chunk.length;
          sink.add(chunk);
          final percent = total == null || total <= 0
              ? math.min(99, (received / 1024 / 1024).floor())
              : ((received / total) * 100).floor();
          _updateBackgroundJob(
            job,
            completed: percent.clamp(0, 99).toInt(),
            status:
                '${_formatBytes(received)}${total == null ? '' : ' / ${_formatBytes(total)}'}',
          );
        }
      } finally {
        await sink.close();
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _exportConfigurationArchive() async {
    final file = await _settingsRepo.exportConfigurationArchive();
    return '${_language.t('settings.export.done')} ${file.path}';
  }

  Future<String> _exportLanguageSample() => AppLanguage.exportEnglishSample();

  Future<String> _resetSettingsToDefaults() async {
    final next = await _settingsRepo.resetToDefaults();
    final language = await AppLanguage.load(next);
    await PlatformServices.setScreenProtection(next.blockScreenCapture)
        .catchError((_) {});
    await PlatformServices.setWindowTitle(language.appTitle).catchError((_) {});
    MediaArtworkService.configure(
      cacheEnabled: next.cacheThumbnailsInMemory,
      persistentCacheEnabled: true,
      encryptPersistentCache: next.encryptThumbnailCache,
    );
    final pluginDefs = await _plugins.loadPlugins();
    final enabledPluginDefs = _enabledPluginDefs(pluginDefs, next);
    _explorer.configurePlugins(enabledPluginDefs, next.connectionProfiles);
    final locations = await _explorer.loadLocations(
        enabledPluginDefs, next.connectionProfiles);
    final pluginMediaSections =
        _pluginRuntime(pluginDefs, next).mediaSections();
    if (mounted) {
      setState(() {
        _settings = next;
        _language = language;
        _pluginDefs = pluginDefs;
        _pluginMediaSections = pluginMediaSections;
        _activePluginMediaSection = null;
        _locations = locations;
        _searchMode = next.searchMode;
        _searchUseRegex = next.searchUseRegex;
        _searchRecursive = next.searchRecursive;
      });
    }
    return language.t('settings.reset.done');
  }

  Future<String> _revealCommonEncryptionPassword(String guardPassword) {
    return _settingsRepo.revealCommonEncryptionPassword(
      settings: _settings,
      guardPassword: guardPassword,
    );
  }

  double _effectiveTextScale(BuildContext context) {
    final interfaceScale = (_settings.interfaceTextScale *
            _settings.interfaceScale.clamp(0.55, 2.2))
        .clamp(0.55, 2.2)
        .toDouble();
    final dpi = _settings.autoScaleForDpi
        ? (MediaQuery.of(context).devicePixelRatio / 2.5).clamp(0.9, 1.35)
        : 1.0;
    return (_settings.fileTextScale * dpi * interfaceScale).clamp(0.55, 2.2);
  }

  double _effectiveIconScale(BuildContext context) {
    final interfaceScale = _settings.interfaceScale.clamp(0.55, 2.2).toDouble();
    final dpi = _settings.autoScaleForDpi
        ? (MediaQuery.of(context).devicePixelRatio / 2.5).clamp(0.9, 1.35)
        : 1.0;
    return (_settings.fileIconScale * dpi * interfaceScale).clamp(0.55, 2.5);
  }

  bool get _effectiveShowHiddenFiles {
    final behavior = _folderBehaviorFor(_currentPath);
    return _settings.showHiddenFiles ||
        behavior.showHiddenFiles ||
        behavior.showHiddenFolders;
  }

  bool get _effectiveShowSystemFiles {
    final behavior = _folderBehaviorFor(_currentPath);
    return _settings.showSystemFiles ||
        behavior.showProtectedSystemFiles ||
        behavior.showProtectedSystemFolders;
  }

  Future<void> _showAbout() async {
    final runtimeText = _runtime.isLoaded
        ? 'Core ${_runtime.versionText}'
        : _language.t('app.runtime.offline');
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(children: [
          Image.asset(
            'assets/icons/logo_program.png',
            width: 42,
            height: 42,
            errorBuilder: (_, __, ___) => const Icon(Icons.shield_outlined),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(_language.t('about.title'))),
        ]),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SelectableText(
                  '${_language.appTitle}\n'
                  '${_language.t('about.version')}: $_appVersion\n'
                  '$runtimeText\n\n'
                  '${_language.t('about.description')}\n\n'
                  '${_language.t('about.contacts')}',
                ),
                const SizedBox(height: 16),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton.icon(
                    onPressed: _showCryptoBenchmark,
                    icon: const Icon(Icons.speed_outlined),
                    label: Text(_language.t('about.crypto.test')),
                  ),
                  OutlinedButton.icon(
                    onPressed: _showMemoryInfo,
                    icon: const Icon(Icons.memory_outlined),
                    label: Text(_language.t('about.memory.info')),
                  ),
                  OutlinedButton.icon(
                    onPressed: _showCurrentVersionFeatures,
                    icon: const Icon(Icons.fact_check_outlined),
                    label: Text(_language.t('about.version.features')),
                  ),
                  OutlinedButton.icon(
                    onPressed: _openLogFile,
                    icon: const Icon(Icons.article_outlined),
                    label: Text(_language.t('about.open.log')),
                  ),
                ]),
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_language.t('common.ok')),
          ),
        ],
      ),
    );
  }

  Future<void> _openLogFile() async {
    try {
      final file = await AppLog.file();
      await AppLog.write('Log file opened from About dialog.');
      final entry = await _explorer.entryForPath(file.path);
      if (!mounted || entry == null) return;
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      await _openEntry(entry, forceFullScreen: true);
    } catch (error) {
      _snack('${_language.t('snack.operation.error')} $error');
    }
  }

  Future<void> _showCryptoBenchmark() async {
    final stopwatch = Stopwatch()..start();
    final salt = VaultCrypto.randomBytes(16);
    for (var i = 0; i < 24; i++) {
      await VaultCrypto.passwordDigest('securevault-benchmark-$i', salt);
    }
    stopwatch.stop();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_language.t('about.crypto.test')),
        content: SelectableText(
          '${_language.t('about.crypto.test.result')}: '
          '${stopwatch.elapsedMilliseconds} ms / 24 KDF',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_language.t('common.ok')),
          ),
        ],
      ),
    );
  }

  Future<void> _showMemoryInfo() async {
    final rss = ProcessInfo.currentRss;
    final maxRss = ProcessInfo.maxRss;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_language.t('about.memory.info')),
        content: SelectableText(
          'RSS: ${(rss / 1024 / 1024).toStringAsFixed(1)} MB\n'
          'Max RSS: ${(maxRss / 1024 / 1024).toStringAsFixed(1)} MB\n'
          '${_language.t('about.memory.cache')}: '
          '${_settings.cacheThumbnailsInMemory ? _language.t('common.enabled') : _language.t('common.disabled')}',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_language.t('common.ok')),
          ),
        ],
      ),
    );
  }

  Future<void> _showCurrentVersionFeatures() async {
    final features = [
      '0.12.0',
      _language.t('about.features.text.editor'),
      _language.t('about.features.preview.toolbar'),
      _language.t('about.features.thumbnail.cache'),
      _language.t('about.features.ebook.tts'),
      _language.t('about.features.media.session'),
      _language.t('about.features.plugins'),
      _language.t('about.features.background.jobs'),
    ].join('\n- ');
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_language.t('about.version.features')),
        content: SelectableText('- $features'),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_language.t('common.ok')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_locked) {
      return _scaledInterface(
        _LockScreen(
          language: _language,
          onUnlock: _unlock,
          failed: _settings.failedLoginAttempts,
        ),
      );
    }

    return _scaledInterface(Focus(
      autofocus: true,
      onKeyEvent: _handleHardwareMediaKey,
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              LayoutBuilder(
                builder: (context, c) {
                  final sidebar = _Sidebar(
                    language: _language,
                    locations: _locations
                        .take(_settings.locationSidebarCount
                            .clamp(0, 1000)
                            .toInt())
                        .toList(),
                    hasMoreLocations:
                        _locations.length > _settings.locationSidebarCount,
                    favoritePaths: _settings.favoritePaths
                        .take(_settings.favoriteSidebarCount)
                        .toList(),
                    recentPaths: _settings.rememberRecentFiles
                        ? _settings.recentFilePaths
                            .take(_settings.recentSidebarCount)
                            .toList()
                        : const <String>[],
                    currentPath: _currentPath,
                    page: _page,
                    pluginMediaSections: _pluginMediaSections,
                    activePluginSectionId: _activePluginMediaSection?.runtimeId,
                    visibleNavigationSections:
                        _settings.visibleNavigationSections,
                    showTorrentSection: _settings.torrentEnabled &&
                        _pluginRuntime().hasTorrentPlugin,
                    showMusicSourceAdd:
                        _pluginRuntime().hasUniversalMusicPlugin,
                    onLocation: _selectLocation,
                    onFavoritePath: _openFavoritePath,
                    onRemoveFavoritePath: _removeFavoritePath,
                    onRecentPath: (path) async {
                      final entry = await _explorer.entryForPath(path);
                      if (entry == null) {
                        await _offerRemoveMissingRecent(path);
                      } else {
                        await _openEntry(entry);
                      }
                    },
                    onRemoveRecentPath: _removeRecentPath,
                    onRecentList: _openRecentFiles,
                    onFavoriteList: _openFavoriteFiles,
                    onEditLocationProfile: _editLocationProfile,
                    onDeleteLocationProfile: _deleteLocationProfile,
                    onExplorer: _openExplorerHome,
                    onAllLocations: _openLocationsHome,
                    onAddLocation: _showAddLocationDialog,
                    onMediaSection: _openMediaSection,
                    onPluginMediaSection: _openPluginMediaSection,
                    onAddMusicSource: _showAddMusicSourceDialog,
                    onSettings: () =>
                        setState(() => _page = ShellPage.settings),
                    onAbout: _showAbout,
                  );
                  final body = _page == ShellPage.settings
                      ? _SettingsView(
                          language: _language,
                          settings: _settings,
                          plugins: _pluginDefs,
                          onSave: _saveSecurity,
                          onRequestAndroidStorageAccess:
                              _requestAndroidStorageAccessFromSettings,
                          onClear: _clearRemembered,
                          onRevealCommonKey: _revealCommonEncryptionPassword,
                          onValidateLanguageFile: _validateLanguageFile,
                          onInstallLanguageFile: _installLanguageFile,
                          onInstallPluginZip: _installPluginZip,
                          onExportPluginZip: _exportPluginZip,
                          onDeletePlugin: _deletePlugin,
                          onSetPluginEnabled: _setPluginEnabled,
                          onSavePluginSettings: _savePluginSettings,
                          onExportConfigurationArchive:
                              _exportConfigurationArchive,
                          onExportLanguageSample: _exportLanguageSample,
                          onResetDefaults: _resetSettingsToDefaults,
                        )
                      : _page == ShellPage.gallery
                          ? _GalleryLibraryView(
                              language: _language,
                              snapshot: _snapshot,
                              selected: _selected,
                              searchQuery: _searchQuery,
                              onRefresh: _refresh,
                              onSearch: _searchDialog,
                              onSearchFilters: _searchFiltersDialog,
                              onEntry: _openEntry,
                              onEntryFullscreen: (entry) =>
                                  _openEntry(entry, forceFullScreen: true),
                            )
                          : (_page == ShellPage.music ||
                                  _page == ShellPage.video)
                              ? _MediaOnlyView(
                                  language: _language,
                                  title: _activePluginMediaSection?.title,
                                  searchQuery: _searchQuery,
                                  entry: _selected,
                                  preview: _preview,
                                  mediaPlaylist: _mediaPlaylist,
                                  mediaResumePositions:
                                      _settings.mediaResumePositions,
                                  snapshot: _snapshot,
                                  isVideo: _page == ShellPage.video,
                                  onRefresh: _refresh,
                                  onSearch: _searchDialog,
                                  onSearchFilters: _searchFiltersDialog,
                                  onOpenPassword: _openWithPassword,
                                  onOpenExternal: _openPreviewExternal,
                                  onPreviewWindow: _showPreviewWindow,
                                  onEditPreview: _openEditor,
                                  onPreviewEntryAction: _handleEntryAction,
                                  onRememberMediaPosition:
                                      _rememberMediaPosition,
                                  onEntry: _openEntry,
                                  onEntryPlaylist: _openMediaEntryFromList,
                                  onDownloadEntry: _downloadPluginMediaEntry,
                                  onDownloadEntries:
                                      _downloadPluginMediaEntries,
                                  showFilters:
                                      _activePluginMediaSection == null,
                                )
                              : _ExplorerView(
                                  language: _language,
                                  currentPath: _showingRecent
                                      ? _language.t('recent.title')
                                      : _showingLocations
                                          ? _language.t('nav.explorer')
                                          : _currentPath,
                                  snapshot: _snapshot,
                                  selected: _selected,
                                  preview: _preview,
                                  mediaPlaylist: _mediaPlaylist,
                                  imagePlaylist: _imagePlaylist,
                                  flashPlaylist: _flashPlaylist,
                                  mediaResumePositions:
                                      _settings.mediaResumePositions,
                                  onUp: _goBack,
                                  onForward: _goForward,
                                  canGoForward: _forwardStack.isNotEmpty,
                                  onRefresh: _refresh,
                                  onImport: _importFile,
                                  onExport: _exportFile,
                                  previewWidth: _previewWidth,
                                  previewVisible: _previewVisible,
                                  fileTextScale: _effectiveTextScale(context),
                                  fileIconScale: _effectiveIconScale(context),
                                  toolbarIconScale: _settings.toolbarIconScale
                                      .clamp(0.75, 2.5)
                                      .toDouble(),
                                  showPathToolbar: _page != ShellPage.torrent,
                                  showToolbarActions: !Platform.isAndroid,
                                  showHiddenFiles: _effectiveShowHiddenFiles,
                                  showSystemFiles: _effectiveShowSystemFiles,
                                  ytDlpEnabled: _pluginRuntime().plugins.any(
                                        (plugin) =>
                                            plugin.id == 'yt-dlp-downloader',
                                      ),
                                  onPreviewResize: (delta) => setState(
                                    () => _previewWidth =
                                        (_previewWidth - delta)
                                            .clamp(280.0, 1800.0),
                                  ),
                                  onTogglePreview: _togglePreviewVisibility,
                                  onOpenPassword: _openWithPassword,
                                  onOpenExternal: _openPreviewExternal,
                                  onPreviewWindow: _showPreviewWindow,
                                  onEditPreview: _openEditor,
                                  onReadPreview: _startReadingPreview,
                                  allowMiniDockForPreview:
                                      _isMiniPlaybackAllowedForPath(
                                          _selected?.path),
                                  onImageNavigate: _navigateImage,
                                  onFlashNavigate: _navigateFlash,
                                  onRememberMediaPosition:
                                      _rememberMediaPosition,
                                  canPaste: _clipboardPaths.isNotEmpty,
                                  favoritePaths: _settings.favoritePaths,
                                  recentPaths: _settings.recentFilePaths,
                                  selectedPaths: _selectedPaths,
                                  searchQuery: _searchQuery,
                                  searchUseRegex: _searchUseRegex,
                                  searchFilters: _searchFilters,
                                  localSearchEnabled: _searchMode == 'name' &&
                                      !_searchRecursive,
                                  showVideoThumbnails:
                                      _settings.showVideoThumbnails,
                                  animateVideoThumbnails:
                                      _settings.animateVideoThumbnails,
                                  showAudioArtwork: _settings.showAudioArtwork,
                                  onThumbnailPreview: (entry) =>
                                      _explorer.previewFile(
                                    entry.path,
                                    password: _activeFilePassword(),
                                    commonPassword: _commonEncryptionPassword,
                                  ),
                                  onPathEdit: _editPathDialog,
                                  onPathPick: _showPathDropdown,
                                  onSearch: _searchDialog,
                                  onSearchFilters: _searchFiltersDialog,
                                  onSort: _sortDialog,
                                  onExplorerMenuAction:
                                      _handleExplorerMenuAction,
                                  sortMode: _sortModeForCurrentPath(),
                                  onEntryAction: _handleEntryAction,
                                  onEmptyAreaAction: _handleEmptyAreaAction,
                                  onRemoveRecent: _removeRecentPath,
                                  onToggleFavorite: _toggleFavorite,
                                  onToggleSelection: _togglePathSelection,
                                  onSelectAllEntries: _selectAllEntries,
                                  onClearSelection: _clearSelection,
                                  onBulkAction: _handleBulkAction,
                                  onEntry: _openEntry,
                                  onEntryFullscreen: (entry) =>
                                      _openEntry(entry, forceFullScreen: true),
                                );
                  if (c.maxWidth < 820) {
                    return Scaffold(
                      appBar: AppBar(
                        title: Platform.isAndroid && _page == ShellPage.explorer
                            ? null
                            : Text(_language.appTitle),
                        actions: [
                          if (Platform.isAndroid &&
                              _page != ShellPage.settings) ...[
                            IconButton(
                              onPressed: _searchDialog,
                              icon: Icon(_searchQuery.isEmpty
                                  ? Icons.search
                                  : Icons.search_off),
                              tooltip: _language.t('search.title'),
                            ),
                            if (_page != ShellPage.music &&
                                _page != ShellPage.video &&
                                _page != ShellPage.torrent)
                              IconButton(
                                onPressed: _togglePreviewVisibility,
                                icon: Icon(_previewVisible
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined),
                                tooltip: _previewVisible
                                    ? _language.t('preview.hide')
                                    : _language.t('preview.show'),
                              ),
                            _ExplorerOverflowMenu(
                              language: _language,
                              sortLabel: _language.t('sort.action'),
                              showHiddenFiles: _effectiveShowHiddenFiles,
                              showSystemFiles: _effectiveShowSystemFiles,
                              ytDlpEnabled: _pluginRuntime().plugins.any(
                                    (plugin) =>
                                        plugin.id == 'yt-dlp-downloader',
                                  ),
                              iconScale: 1,
                              onSelected: _handleExplorerMenuAction,
                            ),
                          ],
                        ],
                      ),
                      drawer: Drawer(child: sidebar),
                      body: body,
                    );
                  }
                  return Row(children: [
                    SizedBox(width: _sidebarWidth, child: sidebar),
                    _DragDivider(
                      onDrag: (delta) => setState(
                        () => _sidebarWidth =
                            (_sidebarWidth + delta).clamp(220.0, 520.0),
                      ),
                    ),
                    Expanded(child: body)
                  ]);
                },
              ),
              _BackgroundJobsPanel(
                jobs: _backgroundJobs,
                language: _language,
                autoCollapseSeconds: _settings.progressAutoCollapseSeconds,
                onCancel: _cancelBackgroundJob,
                onRemove: _removeBackgroundJob,
                onToggleCollapsed: (job) => setState(
                  () => job.collapsed = !job.collapsed,
                ),
              ),
              _FloatingMediaDock(
                session: _sharedMediaSession,
                language: _language,
                enableMiniVideo: _settings.enableMiniVideo,
                enableMiniAudio: _settings.enableMiniAudio,
                continueInBackground: _settings.continueMediaInBackground,
                externalFloatingPlayer: _settings.externalFloatingPlayer,
                onOpenFullScreen: (preview, playlist) => _showPreviewWindow(
                  preview,
                  mediaPlaylistOverride: playlist,
                ),
              ),
              if (_readingSession != null)
                _TextReadingDock(
                  session: _readingSession!,
                  language: _language,
                  onTogglePlay: _readingTogglePlay,
                  onPrevious: _readingPreviousChunk,
                  onNext: () => _readingNextChunk(),
                  onNextFile: _readingNextFile,
                  onClose: _closeReadingSession,
                ),
            ],
          ),
        ),
      ),
    ));
  }

  Widget _scaledInterface(Widget child) {
    final scale = (_settings.interfaceTextScale *
            _settings.interfaceScale.clamp(0.55, 2.2))
        .clamp(0.55, 2.2)
        .toDouble();
    return MediaQuery(
      data:
          MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: child,
    );
  }

  Future<String?> _passwordDialog(String title, {String? initial}) async {
    final controller = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration:
              InputDecoration(labelText: _language.t('common.password')),
          onSubmitted: (_) => Navigator.pop(context, controller.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_language.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(_language.t('common.open')),
          ),
        ],
      ),
    );
  }

  Future<TransferOptions?> _transferDialog({
    required String title,
    required String target,
    required bool includeSource,
    required String encryptedText,
    required String plainText,
  }) {
    final sourceController = TextEditingController();
    final targetController = TextEditingController(text: target);
    final passwordController =
        TextEditingController(text: _activeFilePassword() ?? '');
    var encrypted = true;
    var deleteSource = false;
    return showDialog<TransferOptions>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (includeSource)
                  _PathTextField(
                    controller: sourceController,
                    label: _language.t('transfer.source.path'),
                    pickDirectory: false,
                  ),
                _PathTextField(
                  controller: targetController,
                  label: _language.t('common.target.folder'),
                  pickDirectory: true,
                ),
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(value: true, label: Text(encryptedText)),
                    ButtonSegment(value: false, label: Text(plainText)),
                  ],
                  selected: {encrypted},
                  onSelectionChanged: (value) =>
                      setDialogState(() => encrypted = value.first),
                ),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: _language.t('transfer.password'),
                  ),
                ),
                CheckboxListTile(
                  value: deleteSource,
                  onChanged: (v) =>
                      setDialogState(() => deleteSource = v ?? false),
                  title: Text(_language.t('transfer.delete.source')),
                ),
              ]),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_language.t('common.cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                TransferOptions(
                  asEncrypted: encrypted,
                  deleteSourceAfter: deleteSource,
                  targetDirectory: targetController.text.trim(),
                  sourcePath:
                      includeSource ? sourceController.text.trim() : null,
                  password: passwordController.text,
                ),
              ),
              child: Text(_language.t('common.execute')),
            ),
          ],
        ),
      ),
    );
  }

  Future<EncryptFileOptions?> _encryptDialog(
    ExplorerEntry selected, {
    required EncryptionKeyMode initialMode,
  }) {
    final targetController = TextEditingController(
      text: _currentPath ?? File(selected.path).parent.path,
    );
    final passwordController =
        TextEditingController(text: _activeFilePassword() ?? '');
    var mode = initialMode;
    var algorithm = _settings.commonEncryptionAlgorithm;
    var deleteSource = false;
    bool canUseStoredCommonKey() =>
        mode == EncryptionKeyMode.common &&
        !_settings.hasFilePassword &&
        _commonEncryptionPassword != null &&
        _commonEncryptionPassword!.isNotEmpty;
    return showDialog<EncryptFileOptions>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(_language.t('encrypt.title')),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(selected.path),
                ),
                const SizedBox(height: 12),
                SegmentedButton<EncryptionKeyMode>(
                  segments: [
                    ButtonSegment(
                      value: EncryptionKeyMode.common,
                      enabled: _settings.hasCommonEncryption,
                      label: Text(_language.t('encrypt.mode.common')),
                    ),
                    ButtonSegment(
                      value: EncryptionKeyMode.unique,
                      label: Text(_language.t('encrypt.mode.unique')),
                    ),
                  ],
                  selected: {mode},
                  onSelectionChanged: (value) =>
                      setDialogState(() => mode = value.first),
                ),
                _PathTextField(
                  controller: targetController,
                  label: _language.t('common.target.folder'),
                  pickDirectory: true,
                ),
                DropdownButtonFormField<String>(
                  initialValue: algorithm,
                  decoration: InputDecoration(
                    labelText: _language.t('settings.common.algorithm'),
                  ),
                  items: [
                    for (final item in EncryptionAlgorithm.supported)
                      DropdownMenuItem(
                        value: item,
                        child: Text(EncryptionAlgorithm.label(item)),
                      ),
                  ],
                  onChanged: (value) => setDialogState(
                    () => algorithm =
                        value ?? EncryptionAlgorithm.xchacha20Poly1305,
                  ),
                ),
                if (canUseStoredCommonKey())
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.key_outlined),
                    title: Text(_language.t('encrypt.common.autokey')),
                    subtitle: Text(_language.t('encrypt.common.autokey.note')),
                  )
                else
                  TextField(
                    controller: passwordController,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: mode == EncryptionKeyMode.common
                          ? _language.t('encrypt.password.common')
                          : _language.t('encrypt.password.unique'),
                    ),
                  ),
                CheckboxListTile(
                  value: deleteSource,
                  onChanged: (v) =>
                      setDialogState(() => deleteSource = v ?? false),
                  title: Text(_language.t('encrypt.delete.source')),
                ),
              ]),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_language.t('common.cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                EncryptFileOptions(
                  mode: mode,
                  password: canUseStoredCommonKey()
                      ? _commonEncryptionPassword!
                      : passwordController.text,
                  algorithm: mode == EncryptionKeyMode.common
                      ? _settings.commonEncryptionAlgorithm
                      : algorithm,
                  deleteSourceAfter: deleteSource,
                  targetDirectory: targetController.text.trim(),
                ),
              ),
              child: Text(_language.t('explorer.encrypt')),
            ),
          ],
        ),
      ),
    );
  }

  Future<DecryptFileOptions?> _decryptDialog(
    ExplorerEntry selected,
    String password,
  ) {
    final targetController = TextEditingController(
      text: _currentPath ?? File(selected.path).parent.path,
    );
    var deleteSource = false;
    return showDialog<DecryptFileOptions>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(_language.t('decrypt.title')),
          content: SizedBox(
            width: 520,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Align(
                  alignment: Alignment.centerLeft, child: Text(selected.path)),
              _PathTextField(
                controller: targetController,
                label: _language.t('common.target.folder'),
                pickDirectory: true,
              ),
              CheckboxListTile(
                value: deleteSource,
                onChanged: (v) =>
                    setDialogState(() => deleteSource = v ?? false),
                title: Text(_language.t('decrypt.delete.source')),
              ),
            ]),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_language.t('common.cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                DecryptFileOptions(
                  password: password,
                  deleteSourceAfter: deleteSource,
                  targetDirectory: targetController.text.trim(),
                ),
              ),
              child: Text(_language.t('decrypt.action')),
            ),
          ],
        ),
      ),
    );
  }

  Future<_CommonSetupDecision> _offerCommonEncryptionSetup() async {
    return await showDialog<_CommonSetupDecision>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(_language.t('encrypt.configure.title')),
            content: Text(_language.t('encrypt.configure.body')),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(
                  context,
                  _CommonSetupDecision.cancel,
                ),
                child: Text(_language.t('common.cancel')),
              ),
              OutlinedButton(
                onPressed: () => Navigator.pop(
                  context,
                  _CommonSetupDecision.unique,
                ),
                child: Text(_language.t('encrypt.mode.unique')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(
                  context,
                  _CommonSetupDecision.settings,
                ),
                child: Text(_language.t('encrypt.configure.open')),
              ),
            ],
          ),
        ) ??
        _CommonSetupDecision.cancel;
  }

  void _showProvider(ExplorerLocation location) {
    final plugin =
        _pluginDefs.where((p) => p.id == location.pluginId).firstOrNull;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(location.name),
        content: Text(plugin == null
            ? _language.t('provider.reserved')
            : '${_language.t('provider.plugin')} ${plugin.manifestPath}\n${_language.t('provider.plugin.detail')}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_language.t('common.ok')),
          )
        ],
      ),
    );
  }

  String _safeFileName(String value) => value.replaceAll(
        RegExp(r'[\\/:*?"<>|]'),
        '_',
      );

  String _normalizePath(String path) {
    var value = path.replaceAll('\\', '/');
    if (value.length > 1 && value.endsWith('/')) {
      value = value.substring(0, value.length - 1);
    }
    return Platform.isWindows ? value.toLowerCase() : value;
  }

  String? _activeFilePassword() {
    final password = _filePassword;
    if (password == null || password.isEmpty) {
      return null;
    }
    final validUntil = _filePasswordValidUntil;
    if (validUntil == null) {
      return null;
    }
    if (DateTime.now().isAfter(validUntil)) {
      _filePassword = null;
      _filePasswordValidUntil = null;
      return null;
    }
    return password;
  }

  void _setSessionFilePassword(String password) {
    final ttl = _settings.filePasswordGraceSeconds;
    if (ttl <= 0) {
      _filePassword = null;
      _filePasswordValidUntil = null;
      return;
    }
    _filePassword = password;
    _filePasswordValidUntil = DateTime.now().add(Duration(seconds: ttl));
  }

  String _defaultEditedOutputPath(FilePreview preview, String extension) {
    final filename =
        '${_fileNameWithoutExtension(preview.title)}_edited$extension';
    final directory = _currentPath ??
        (preview.sourcePath == null
            ? Directory.current.path
            : File(preview.sourcePath!).parent.path);
    try {
      return _explorer.joinChildPath(directory, filename);
    } catch (_) {
      return '$directory${Platform.pathSeparator}$filename';
    }
  }

  String _formatBytes(int value) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var size = value.toDouble();
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${size.toStringAsFixed(size >= 10 || unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  void _snack(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }
}

enum _CommonSetupDecision { cancel, unique, settings }

enum _EntryAction {
  open,
  edit,
  create,
  createFolder,
  createPlain,
  createEncryptedPlain,
  createCsv,
  createEncryptedCsv,
  createImage,
  createEncryptedImage,
  openAs,
  openAsText,
  openAsImage,
  openAsAudio,
  openAsVideo,
  copy,
  cut,
  paste,
  delete,
  rename,
  properties,
  send,
  unzip,
  addFavorite,
  removeFavorite,
  removeRecent,
  selectAll,
  clearSelection,
  zipSelected,
  encrypt,
  decrypt,
  encryptMenu,
  decryptMenu,
  folderContainer,
  folderEncryptName,
  folderDecryptName,
  folderEncrypt,
  folderDecrypt,
  useAs,
  useAsGallery,
  useAsVideo,
  useAsMusic,
  useAsMultimedia,
  folderSettings,
  openAllImages,
  openAllVideos,
  openAllAudio,
  permissions,
  ocrExtract,
  openSwf,
  downloadUrl,
  editConnectionProfile,
  deleteConnectionProfile,
}

enum _PreviewAction {
  password,
  window,
  edit,
  speak,
  ocrExtract,
  rotateVideoLeft,
  rotateVideoRight,
  external,
  copy,
  cut,
  delete,
  properties,
  hide
}

enum _ExplorerMenuAction {
  upload,
  download,
  downloadUrl,
  sort,
  toggleHidden,
  toggleSystem,
  folderSettings,
}

class _ContextMenuSpec {
  const _ContextMenuSpec({
    this.action,
    this.label,
    this.enabled = true,
    this.children = const <_ContextMenuSpec>[],
  }) : divider = false;

  const _ContextMenuSpec.divider()
      : action = null,
        label = null,
        enabled = false,
        children = const <_ContextMenuSpec>[],
        divider = true;

  final _EntryAction? action;
  final String? label;
  final bool enabled;
  final List<_ContextMenuSpec> children;
  final bool divider;

  bool get hasChildren => children.isNotEmpty;
}

Future<_EntryAction?> _showCascadingContextMenu({
  required BuildContext context,
  required Offset? position,
  required List<_ContextMenuSpec> items,
}) {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final fallback = Offset(overlay.size.width / 2, overlay.size.height / 2);
  return showDialog<_EntryAction>(
    context: context,
    barrierColor: Colors.transparent,
    builder: (_) => _CascadingContextMenu(
      anchor: position ?? fallback,
      items: items,
    ),
  );
}

Offset _globalAnchorFor(BuildContext context, {bool trailing = false}) {
  final renderObject = context.findRenderObject();
  if (renderObject is RenderBox && renderObject.hasSize) {
    final origin = renderObject.localToGlobal(Offset.zero);
    return origin +
        Offset(
            trailing ? renderObject.size.width : 0, renderObject.size.height);
  }
  return Offset.zero;
}

class _CascadingContextMenu extends StatefulWidget {
  const _CascadingContextMenu({
    required this.anchor,
    required this.items,
  });

  final Offset anchor;
  final List<_ContextMenuSpec> items;

  @override
  State<_CascadingContextMenu> createState() => _CascadingContextMenuState();
}

class _CascadingContextMenuState extends State<_CascadingContextMenu> {
  static const _menuWidth = 292.0;
  static const _itemHeight = 42.0;
  static const _dividerHeight = 8.0;
  static const _menuMargin = 8.0;
  int? _activeIndex;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: LayoutBuilder(builder: (context, constraints) {
        final menuWidth = math
            .min(_menuWidth, math.max(176.0, constraints.maxWidth - 16))
            .toDouble();
        final rootPlacement = _verticalPlacement(
          anchorY: widget.anchor.dy,
          contentHeight: _contentHeight(widget.items),
          viewportHeight: constraints.maxHeight,
        );
        final left = widget.anchor.dx
            .clamp(_menuMargin,
                math.max(_menuMargin, constraints.maxWidth - menuWidth - 8))
            .toDouble();
        final top = rootPlacement.top;
        final active =
            _activeIndex == null ? null : widget.items[_activeIndex!];
        final childItems = active != null && active.enabled
            ? active.children
            : const <_ContextMenuSpec>[];
        final childPlacement = active == null
            ? rootPlacement
            : _verticalPlacement(
                anchorY: top + _rowOffset(_activeIndex!),
                contentHeight: _contentHeight(childItems),
                viewportHeight: constraints.maxHeight,
              );
        final rightSpace =
            constraints.maxWidth - (left + menuWidth + 6) - _menuMargin;
        final leftSpace = left - 6 - _menuMargin;
        final opensRight = rightSpace >= menuWidth || rightSpace >= leftSpace;
        final availableSide = opensRight ? rightSpace : leftSpace;
        final childWidth = math
            .max(148.0, math.min(menuWidth, math.max(0.0, availableSide)))
            .clamp(96.0, menuWidth)
            .toDouble();
        final childLeft = opensRight
            ? math.min(
                constraints.maxWidth - childWidth - _menuMargin,
                left + menuWidth + 6,
              )
            : math.max(_menuMargin, left - childWidth - 6);
        return Stack(children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.pop(context),
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            left: left,
            top: top,
            width: menuWidth,
            child: _menu(
              widget.items,
              maxHeight: rootPlacement.maxHeight,
              root: true,
            ),
          ),
          if (childItems.isNotEmpty)
            Positioned(
              left: childLeft,
              top: childPlacement.top,
              width: childWidth,
              child: _menu(childItems, maxHeight: childPlacement.maxHeight),
            ),
        ]);
      }),
    );
  }

  Widget _menu(
    List<_ContextMenuSpec> items, {
    required double maxHeight,
    bool root = false,
  }) {
    final needsScroll = _contentHeight(items) > maxHeight;
    return Material(
      elevation: 12,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      color: Theme.of(context).colorScheme.surface,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Scrollbar(
          thumbVisibility: needsScroll,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < items.length; i++) _row(items[i], i, root),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _row(_ContextMenuSpec item, int index, bool root) {
    if (item.divider) return const Divider(height: _dividerHeight);
    final active = root && _activeIndex == index && item.hasChildren;
    final colorScheme = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) {
        if (root && item.enabled && item.hasChildren) {
          setState(() => _activeIndex = index);
        }
      },
      child: InkWell(
        onTap: item.enabled ? () => _activate(item, root, index) : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: _itemHeight),
          child: Container(
            color: active
                ? colorScheme.primaryContainer.withValues(alpha: .55)
                : null,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child:
                Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Expanded(
                child: Text(
                  item.label ?? '',
                  maxLines: 3,
                  softWrap: true,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: item.enabled
                        ? colorScheme.onSurface
                        : colorScheme.onSurface.withValues(alpha: .38),
                  ),
                ),
              ),
              if (item.hasChildren) const Icon(Icons.chevron_right, size: 18),
            ]),
          ),
        ),
      ),
    );
  }

  void _activate(_ContextMenuSpec item, bool root, int index) {
    if (!item.enabled) return;
    if (item.hasChildren) {
      if (root) setState(() => _activeIndex = index);
      return;
    }
    final action = item.action;
    if (action != null) Navigator.pop(context, action);
  }

  double _rowOffset(int index) {
    var offset = 6.0;
    for (var i = 0; i < index; i++) {
      offset += widget.items[i].divider ? _dividerHeight : _itemHeight;
    }
    return offset;
  }

  double _contentHeight(List<_ContextMenuSpec> items) {
    return 12 +
        items.fold<double>(
          0,
          (height, item) => height + (item.divider ? _dividerHeight : 48),
        );
  }

  _MenuPlacement _verticalPlacement({
    required double anchorY,
    required double contentHeight,
    required double viewportHeight,
  }) {
    final safeHeight = math.max(80.0, viewportHeight - _menuMargin * 2);
    final downSpace = math.max(0.0, viewportHeight - anchorY - _menuMargin);
    final upSpace = math.max(0.0, anchorY - _menuMargin);
    if (contentHeight <= downSpace || downSpace >= upSpace) {
      final maxHeight = contentHeight <= downSpace
          ? contentHeight
          : math.max(80.0, downSpace).clamp(80.0, safeHeight).toDouble();
      return _MenuPlacement(
        top: anchorY
            .clamp(
              _menuMargin,
              math.max(_menuMargin, viewportHeight - maxHeight - _menuMargin),
            )
            .toDouble(),
        maxHeight: maxHeight,
      );
    }
    final maxHeight = contentHeight <= upSpace
        ? contentHeight
        : math.max(80.0, upSpace).clamp(80.0, safeHeight).toDouble();
    return _MenuPlacement(
      top: (anchorY - maxHeight)
          .clamp(
            _menuMargin,
            math.max(_menuMargin, viewportHeight - maxHeight - _menuMargin),
          )
          .toDouble(),
      maxHeight: maxHeight,
    );
  }
}

class _MenuPlacement {
  const _MenuPlacement({required this.top, required this.maxHeight});

  final double top;
  final double maxHeight;
}

class _LockScreen extends StatefulWidget {
  const _LockScreen({
    required this.language,
    required this.onUnlock,
    required this.failed,
  });

  final AppLanguage language;
  final Future<void> Function(String password) onUnlock;
  final int failed;

  @override
  State<_LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<_LockScreen> {
  final _controller = TextEditingController();
  var _busy = false;

  @override
  Widget build(BuildContext context) {
    final language = widget.language;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    language.appTitle,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(language.t('lock.prompt')),
                  if (widget.failed > 0)
                    Text('${language.t('lock.failed')}: ${widget.failed}'),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _controller,
                    obscureText: true,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: language.t('common.password'),
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: Text(
                      _busy
                          ? language.t('common.saving')
                          : language.t('common.open'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    await widget.onUnlock(_controller.text);
    if (mounted) setState(() => _busy = false);
  }
}

class _DragDivider extends StatelessWidget {
  const _DragDivider({required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (details) => onDrag(details.delta.dx),
        child: Container(
          width: 8,
          alignment: Alignment.center,
          child: Container(width: 1, color: const Color(0xFFDDE6F0)),
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.language,
    required this.locations,
    required this.hasMoreLocations,
    required this.favoritePaths,
    required this.recentPaths,
    required this.currentPath,
    required this.page,
    required this.pluginMediaSections,
    required this.activePluginSectionId,
    required this.visibleNavigationSections,
    required this.showTorrentSection,
    required this.showMusicSourceAdd,
    required this.onLocation,
    required this.onFavoritePath,
    required this.onRemoveFavoritePath,
    required this.onRecentPath,
    required this.onRemoveRecentPath,
    required this.onRecentList,
    required this.onFavoriteList,
    required this.onEditLocationProfile,
    required this.onDeleteLocationProfile,
    required this.onExplorer,
    required this.onAllLocations,
    required this.onAddLocation,
    required this.onMediaSection,
    required this.onPluginMediaSection,
    required this.onAddMusicSource,
    required this.onSettings,
    required this.onAbout,
  });

  final AppLanguage language;
  final List<ExplorerLocation> locations;
  final bool hasMoreLocations;
  final List<String> favoritePaths;
  final List<String> recentPaths;
  final String? currentPath;
  final ShellPage page;
  final List<PluginMediaSection> pluginMediaSections;
  final String? activePluginSectionId;
  final List<String> visibleNavigationSections;
  final bool showTorrentSection;
  final bool showMusicSourceAdd;
  final ValueChanged<ExplorerLocation> onLocation;
  final ValueChanged<String> onFavoritePath;
  final ValueChanged<String> onRemoveFavoritePath;
  final ValueChanged<String> onRecentPath;
  final ValueChanged<String> onRemoveRecentPath;
  final VoidCallback onRecentList;
  final VoidCallback onFavoriteList;
  final ValueChanged<ExplorerLocation> onEditLocationProfile;
  final ValueChanged<ExplorerLocation> onDeleteLocationProfile;
  final VoidCallback onExplorer;
  final VoidCallback onAllLocations;
  final VoidCallback onAddLocation;
  final ValueChanged<MediaSection> onMediaSection;
  final ValueChanged<PluginMediaSection> onPluginMediaSection;
  final VoidCallback onAddMusicSource;
  final VoidCallback onSettings;
  final VoidCallback onAbout;

  @override
  Widget build(BuildContext context) {
    void activate(VoidCallback callback) {
      if (Platform.isAndroid) {
        Navigator.of(context).maybePop();
        Future<void>.delayed(const Duration(milliseconds: 80), callback);
        return;
      }
      callback();
    }

    final visible = visibleNavigationSections.toSet();
    bool sectionVisible(String id) => visible.contains(id);

    return Material(
      color: const Color(0xFFEDF3FA),
      child: ListView(padding: const EdgeInsets.all(14), children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                language.appTitle,
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            IconButton.filledTonal(
              onPressed: onAbout,
              tooltip: language.t('about.title'),
              icon: const Text(
                'i',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (sectionVisible('explorer'))
          _nav(
            Icons.folder_open,
            language.t('nav.explorer'),
            page == ShellPage.explorer,
            () => activate(onExplorer),
          ),
        if (sectionVisible('gallery'))
          _nav(
            Icons.photo_library_outlined,
            language.t('nav.gallery'),
            page == ShellPage.gallery,
            () => activate(() => onMediaSection(MediaSection.gallery)),
          ),
        if (sectionVisible('music'))
          _musicNav(
            selected: page == ShellPage.music && activePluginSectionId == null,
            activate: activate,
          ),
        if (sectionVisible('video'))
          _nav(
            Icons.movie_outlined,
            language.t('nav.video'),
            page == ShellPage.video,
            () => activate(() => onMediaSection(MediaSection.video)),
          ),
        if (sectionVisible('documents'))
          _nav(
            Icons.description_outlined,
            language.t('nav.documents'),
            page == ShellPage.documents,
            () => activate(() => onMediaSection(MediaSection.documents)),
          ),
        if (showTorrentSection)
          _nav(
            Icons.hub_outlined,
            language.t('nav.torrent'),
            page == ShellPage.torrent,
            () => activate(() => onMediaSection(MediaSection.torrent)),
          ),
        for (final section in pluginMediaSections)
          _nav(
            Icons.library_music_outlined,
            section.title,
            activePluginSectionId == section.runtimeId,
            () => activate(() => onPluginMediaSection(section)),
          ),
        const SizedBox(height: 12),
        if (recentPaths.isNotEmpty) ...[
          _sectionTitle(language.t('recent.title')),
          ListTile(
            dense: true,
            leading: const Icon(Icons.history),
            title: Text(language.t('recent.open.all')),
            onTap: () => activate(onRecentList),
          ),
          for (final path in recentPaths)
            ListTile(
              dense: true,
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: Text(
                basename(path),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => activate(() => onRecentPath(path)),
              onLongPress: () => _showPathMenu(
                context,
                path,
                open: () => activate(() => onRecentPath(path)),
                remove: () => activate(() => onRemoveRecentPath(path)),
                removeLabel: language.t('recent.remove'),
              ),
            ),
          const SizedBox(height: 12),
        ],
        if (favoritePaths.isNotEmpty) ...[
          _sectionTitle(language.t('favorites.title')),
          ListTile(
            dense: true,
            leading: const Icon(Icons.star),
            title: Text(language.t('favorites.open.all')),
            onTap: () => activate(onFavoriteList),
          ),
          for (final path in favoritePaths)
            ListTile(
              dense: true,
              leading: const Icon(Icons.star_outline),
              title: Text(
                basename(path),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => activate(() => onFavoritePath(path)),
              onLongPress: () => _showPathMenu(
                context,
                path,
                open: () => activate(() => onFavoritePath(path)),
                remove: () => activate(() => onRemoveFavoritePath(path)),
                removeLabel: language.t('favorites.remove'),
              ),
            ),
          const SizedBox(height: 12),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
          child: Row(children: [
            Expanded(
              child: Text(
                language.t('locations.heading'),
                style: const TextStyle(
                    fontWeight: FontWeight.w800, letterSpacing: 1),
              ),
            ),
            IconButton(
              onPressed: () => activate(onAddLocation),
              icon: const Icon(Icons.add),
              tooltip: language.t('locations.add'),
            ),
          ]),
        ),
        for (final location in locations)
          ListTile(
            dense: true,
            selected:
                page == ShellPage.explorer && location.path == currentPath,
            leading: Icon(
              _icon(location),
              color: location.enabled ? null : const Color(0xFF8290A0),
            ),
            title: Text(
              location.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: location.description == null
                ? null
                : Text(
                    location.description!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
            trailing:
                location.enabled ? null : const Icon(Icons.extension, size: 18),
            onTap: () => activate(() => onLocation(location)),
            onLongPress: () => _showLocationMenu(
              context,
              location,
              open: () => activate(() => onLocation(location)),
              edit: () => activate(() => onEditLocationProfile(location)),
              delete: () => activate(() => onDeleteLocationProfile(location)),
            ),
          ),
        if (hasMoreLocations)
          ListTile(
            dense: true,
            leading: const Icon(Icons.more_horiz),
            title: Text(language.t('locations.open.all')),
            onTap: () => activate(onAllLocations),
          ),
        const SizedBox(height: 8),
        _nav(
          Icons.tune,
          language.t('nav.settings'),
          page == ShellPage.settings,
          () => activate(onSettings),
        ),
      ]),
    );
  }

  Future<void> _showPathMenu(
    BuildContext context,
    String path, {
    required VoidCallback open,
    required VoidCallback remove,
    required String removeLabel,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.open_in_new),
            title: Text(language.t('common.open')),
            subtitle: Text(path, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () {
              Navigator.pop(context);
              open();
            },
          ),
          ListTile(
            leading: const Icon(Icons.remove_circle_outline),
            title: Text(removeLabel),
            onTap: () {
              Navigator.pop(context);
              remove();
            },
          ),
        ]),
      ),
    );
  }

  Future<void> _showLocationMenu(
    BuildContext context,
    ExplorerLocation location, {
    required VoidCallback open,
    required VoidCallback edit,
    required VoidCallback delete,
  }) async {
    final profile = _isProfileLocation(location);
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.open_in_new),
            title: Text(language.t('common.open')),
            subtitle: Text(
              location.path ?? location.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () {
              Navigator.pop(context);
              open();
            },
          ),
          if (profile)
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(language.t('locations.profile.edit')),
              onTap: () {
                Navigator.pop(context);
                edit();
              },
            ),
          if (profile)
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(language.t('locations.profile.delete')),
              onTap: () {
                Navigator.pop(context);
                delete();
              },
            ),
        ]),
      ),
    );
  }

  bool _isProfileLocation(ExplorerLocation location) =>
      location.id.startsWith('profile-') ||
      (location.pluginId?.startsWith('profile-') ?? false);

  Widget _nav(IconData icon, String text, bool selected, VoidCallback onTap) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: ListTile(
          selected: selected,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          leading: Icon(icon),
          title: Text(text),
          onTap: onTap,
        ),
      );

  Widget _musicNav({
    required bool selected,
    required void Function(VoidCallback callback) activate,
  }) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: ListTile(
          selected: selected,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          leading: const Icon(Icons.music_note_outlined),
          title: Text(language.t('nav.music')),
          trailing: showMusicSourceAdd
              ? IconButton(
                  tooltip: language.t('plugin.music.add.site'),
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: () => activate(onAddMusicSource),
                )
              : null,
          onTap: () => activate(() => onMediaSection(MediaSection.music)),
        ),
      );

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          text,
          style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1),
        ),
      );

  IconData _icon(ExplorerLocation location) => switch (location.kind) {
        ExplorerLocationKind.local => Icons.storage,
        ExplorerLocationKind.appHidden => Icons.lock_outline,
        ExplorerLocationKind.phoneFiles => Icons.phone_android,
        ExplorerLocationKind.mtp => Icons.usb_outlined,
        ExplorerLocationKind.network => Icons.lan_outlined,
        ExplorerLocationKind.cloudPlugin => Icons.cloud_queue,
      };
}

class _GalleryLibraryView extends StatefulWidget {
  const _GalleryLibraryView({
    required this.language,
    required this.snapshot,
    required this.selected,
    required this.searchQuery,
    required this.onRefresh,
    required this.onSearch,
    required this.onSearchFilters,
    required this.onEntry,
    required this.onEntryFullscreen,
  });

  final AppLanguage language;
  final Future<DirectorySnapshot>? snapshot;
  final ExplorerEntry? selected;
  final String searchQuery;
  final Future<void> Function() onRefresh;
  final VoidCallback onSearch;
  final VoidCallback onSearchFilters;
  final Future<void> Function(ExplorerEntry) onEntry;
  final Future<void> Function(ExplorerEntry) onEntryFullscreen;

  @override
  State<_GalleryLibraryView> createState() => _GalleryLibraryViewState();
}

class _GalleryLibraryViewState extends State<_GalleryLibraryView> {
  var _tileExtent = 170.0;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      _MediaHeader(
        title: widget.language.t('nav.gallery'),
        language: widget.language,
        onRefresh: widget.onRefresh,
        onSearch: widget.onSearch,
        onSearchFilters: widget.onSearchFilters,
        searchQuery: widget.searchQuery,
      ),
      Expanded(
        child: FutureBuilder<DirectorySnapshot>(
          future: widget.snapshot,
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.data!.hasError) {
              return Center(
                child: Text(
                  '${widget.language.t('explorer.access.error')}\n${snap.data!.error}',
                  textAlign: TextAlign.center,
                ),
              );
            }
            final entries = _filtered(snap.data!.entries);
            if (entries.isEmpty) {
              return Center(child: Text(widget.language.t('explorer.empty')));
            }
            return Listener(
              onPointerSignal: _handlePointerSignal,
              child: _tileExtent <= 92
                  ? _buildCalendarMode(entries)
                  : _buildMonthGridMode(entries),
            );
          },
        ),
      ),
    ]);
  }

  List<ExplorerEntry> _filtered(List<ExplorerEntry> entries) {
    if (widget.searchQuery.isEmpty) return entries;
    final query = widget.searchQuery.toLowerCase();
    return entries
        .where((entry) => entry.name.toLowerCase().contains(query))
        .toList();
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        !HardwareKeyboard.instance.isControlPressed) {
      return;
    }
    final direction = event.scrollDelta.dy.sign;
    if (direction == 0) return;
    setState(() {
      _tileExtent = (_tileExtent + direction * -18).clamp(68.0, 290.0);
    });
  }

  Widget _buildMonthGridMode(List<ExplorerEntry> entries) {
    final groups = _groupByMonth(entries);
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final columns = (width / _tileExtent).floor().clamp(2, 12).toInt();
      return CustomScrollView(slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              widget.language.t('gallery.zoom.hint'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        for (final group in groups.entries) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
              child: Text(
                _monthTitle(group.key),
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: .82,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) => _GalleryTile(
                  entry: group.value[index],
                  selected: widget.selected?.path == group.value[index].path,
                  onEntry: widget.onEntry,
                  onEntryFullscreen: widget.onEntryFullscreen,
                ),
                childCount: group.value.length,
              ),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ]);
    });
  }

  Widget _buildCalendarMode(List<ExplorerEntry> entries) {
    final years = <int, Map<int, int>>{};
    for (final entry in entries) {
      final date = entry.modifiedAt;
      final months = years.putIfAbsent(date.year, () => <int, int>{});
      months[date.month] = (months[date.month] ?? 0) + 1;
    }
    final sortedYears = years.keys.toList()..sort((a, b) => b.compareTo(a));
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: sortedYears.length,
      itemBuilder: (context, index) {
        final year = sortedYears[index];
        final months = years[year]!;
        return Card(
          elevation: 0,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$year',
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 12),
                GridView.builder(
                  physics: const NeverScrollableScrollPhysics(),
                  shrinkWrap: true,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 6,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 1.4,
                  ),
                  itemCount: 12,
                  itemBuilder: (context, monthIndex) {
                    final month = monthIndex + 1;
                    final count = months[month] ?? 0;
                    return DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        color: count == 0
                            ? Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest
                            : Theme.of(context).colorScheme.primaryContainer,
                      ),
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_shortMonth(month)),
                            if (count > 0) ...[
                              const SizedBox(height: 4),
                              Container(
                                width: 7,
                                height: 7,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Map<String, List<ExplorerEntry>> _groupByMonth(List<ExplorerEntry> entries) {
    final sorted = [...entries]
      ..sort((a, b) => b.modifiedAt.compareTo(a.modifiedAt));
    final groups = <String, List<ExplorerEntry>>{};
    for (final entry in sorted) {
      final date = entry.modifiedAt;
      final key = '${date.year}-${date.month.toString().padLeft(2, '0')}';
      groups.putIfAbsent(key, () => <ExplorerEntry>[]).add(entry);
    }
    return groups;
  }

  String _monthTitle(String key) {
    final parts = key.split('-');
    final year = parts.first;
    final month = int.tryParse(parts.last) ?? 1;
    return '${widget.language.t('month.$month')} $year';
  }

  String _shortMonth(int month) => widget.language.t('month.short.$month');
}

class _GalleryTile extends StatelessWidget {
  const _GalleryTile({
    required this.entry,
    required this.selected,
    required this.onEntry,
    required this.onEntryFullscreen,
  });

  final ExplorerEntry entry;
  final bool selected;
  final Future<void> Function(ExplorerEntry) onEntry;
  final Future<void> Function(ExplorerEntry) onEntryFullscreen;

  @override
  Widget build(BuildContext context) {
    final kind = FileViewerService.kindForName(entry.name);
    return GestureDetector(
      onTap: () => unawaited(onEntry(entry)),
      onDoubleTap: () => unawaited(onEntryFullscreen(entry)),
      child: Card(
        clipBehavior: Clip.antiAlias,
        elevation: selected ? 4 : 0,
        child: Column(children: [
          Expanded(
            child: _MediaThumbnail(
              entry: entry,
              kind: kind,
              fit: BoxFit.cover,
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(children: [
              Icon(
                kind == FileContentKind.video
                    ? Icons.play_circle_outline
                    : Icons.image_outlined,
                size: 18,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _MediaOnlyView extends StatelessWidget {
  const _MediaOnlyView({
    required this.language,
    required this.title,
    required this.searchQuery,
    required this.entry,
    required this.preview,
    required this.mediaPlaylist,
    required this.mediaResumePositions,
    required this.snapshot,
    required this.isVideo,
    required this.onRefresh,
    required this.onSearch,
    required this.onSearchFilters,
    required this.onOpenPassword,
    required this.onOpenExternal,
    required this.onPreviewWindow,
    required this.onEditPreview,
    required this.onPreviewEntryAction,
    required this.onRememberMediaPosition,
    required this.onEntry,
    required this.onEntryPlaylist,
    required this.onDownloadEntry,
    required this.onDownloadEntries,
    this.showFilters = true,
  });

  final AppLanguage language;
  final String? title;
  final String searchQuery;
  final ExplorerEntry? entry;
  final Future<FilePreview>? preview;
  final List<MediaPreviewItem> mediaPlaylist;
  final Map<String, int> mediaResumePositions;
  final Future<DirectorySnapshot>? snapshot;
  final bool isVideo;
  final Future<void> Function() onRefresh;
  final VoidCallback onSearch;
  final VoidCallback onSearchFilters;
  final VoidCallback onOpenPassword;
  final ValueChanged<FilePreview> onOpenExternal;
  final ValueChanged<FilePreview> onPreviewWindow;
  final ValueChanged<FilePreview> onEditPreview;
  final Future<void> Function(ExplorerEntry, _EntryAction) onPreviewEntryAction;
  final Future<void> Function(String key, Duration position)
      onRememberMediaPosition;
  final Future<void> Function(ExplorerEntry) onEntry;
  final Future<void> Function(ExplorerEntry, List<ExplorerEntry>)
      onEntryPlaylist;
  final Future<void> Function(ExplorerEntry) onDownloadEntry;
  final Future<void> Function(List<ExplorerEntry>) onDownloadEntries;
  final bool showFilters;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      _MediaHeader(
        title: title ?? language.t(isVideo ? 'nav.video' : 'nav.music'),
        language: language,
        onRefresh: onRefresh,
        onSearch: onSearch,
        onSearchFilters: showFilters ? onSearchFilters : null,
        searchQuery: searchQuery,
      ),
      Expanded(
        child: FutureBuilder<DirectorySnapshot>(
          future: snapshot,
          builder: (context, snap) {
            if (!snap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.data!.hasError) {
              return Center(
                child: Text(
                  '${language.t('explorer.access.error')}\n${snap.data!.error}',
                  textAlign: TextAlign.center,
                ),
              );
            }
            if (snap.data!.entries.isEmpty) {
              return Center(child: Text(language.t('explorer.empty')));
            }
            return _MediaLibraryBrowser(
              language: language,
              entries: snap.data!.entries,
              isVideo: isVideo,
              mediaPlaylist: mediaPlaylist,
              mediaResumePositions: mediaResumePositions,
              onEntry: onEntry,
              onEntryPlaylist: onEntryPlaylist,
              onDownloadEntry: onDownloadEntry,
              onDownloadEntries: onDownloadEntries,
            );
          },
        ),
      ),
    ]);
  }
}

class _MediaLibraryBrowser extends StatelessWidget {
  const _MediaLibraryBrowser({
    required this.language,
    required this.entries,
    required this.isVideo,
    required this.mediaPlaylist,
    required this.mediaResumePositions,
    required this.onEntry,
    required this.onEntryPlaylist,
    required this.onDownloadEntry,
    required this.onDownloadEntries,
  });

  final AppLanguage language;
  final List<ExplorerEntry> entries;
  final bool isVideo;
  final List<MediaPreviewItem> mediaPlaylist;
  final Map<String, int> mediaResumePositions;
  final Future<void> Function(ExplorerEntry) onEntry;
  final Future<void> Function(ExplorerEntry, List<ExplorerEntry>)
      onEntryPlaylist;
  final Future<void> Function(ExplorerEntry) onDownloadEntry;
  final Future<void> Function(List<ExplorerEntry>) onDownloadEntries;

  @override
  Widget build(BuildContext context) {
    final kind = isVideo ? FileContentKind.video : FileContentKind.audio;
    final mediaEntries = entries
        .where((entry) =>
            !entry.isDirectory &&
            (FileViewerService.kindForName(entry.name) == kind ||
                FileViewerService.kindForName(entry.path) == kind))
        .toList();
    final directoryEntries = entries
        .where((entry) => entry.isDirectory)
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final recent = mediaEntries
        .where((entry) => mediaResumePositions.containsKey(entry.path))
        .toList()
      ..sort((a, b) => (mediaResumePositions[b.path] ?? 0)
          .compareTo(mediaResumePositions[a.path] ?? 0));
    final currentEntries = _currentEntries(mediaEntries);

    return DefaultTabController(
      length: 8,
      child: Column(children: [
        Material(
          color: Theme.of(context).colorScheme.surface,
          child: TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: language.t('media.tab.current')),
              Tab(text: language.t('media.tab.all')),
              Tab(text: language.t('media.tab.playlists')),
              Tab(text: language.t('media.tab.albums')),
              Tab(text: language.t('media.tab.artists')),
              Tab(text: language.t('media.tab.genres')),
              Tab(text: language.t('media.tab.folders')),
              Tab(text: language.t('media.tab.previous')),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(children: [
            _MediaEntryList(
              language: language,
              entries: currentEntries,
              emptyText: language.t('media.choose.to.play'),
              onEntry: (entry) => onEntryPlaylist(entry, currentEntries),
              onDownloadEntry: onDownloadEntry,
              onDownloadEntries: onDownloadEntries,
            ),
            _MediaEntryList(
              language: language,
              entries: [...directoryEntries, ...mediaEntries],
              onEntry: onEntry,
              onDownloadEntry: onDownloadEntry,
              onDownloadEntries: onDownloadEntries,
            ),
            _MediaGroupList(
              language: language,
              groups: _groupByNameHeuristic(mediaEntries, 'playlist'),
              onEntry: onEntryPlaylist,
              onDownloadEntry: onDownloadEntry,
            ),
            _MediaGroupList(
              language: language,
              groups: _groupByNameHeuristic(mediaEntries, 'album'),
              onEntry: onEntryPlaylist,
              onDownloadEntry: onDownloadEntry,
            ),
            _MediaGroupList(
              language: language,
              groups: _groupByNameHeuristic(mediaEntries, 'artist'),
              onEntry: onEntryPlaylist,
              onDownloadEntry: onDownloadEntry,
            ),
            _MediaGroupList(
              language: language,
              groups: _groupByNameHeuristic(mediaEntries, 'genre'),
              onEntry: onEntryPlaylist,
              onDownloadEntry: onDownloadEntry,
            ),
            _MediaGroupList(
              language: language,
              groups: _groupByFolder(mediaEntries),
              onEntry: onEntryPlaylist,
              onDownloadEntry: onDownloadEntry,
            ),
            _MediaEntryList(
              language: language,
              entries: recent,
              onEntry: onEntry,
              onDownloadEntry: onDownloadEntry,
              onDownloadEntries: onDownloadEntries,
            ),
          ]),
        ),
      ]),
    );
  }

  Map<String, List<ExplorerEntry>> _groupByFolder(List<ExplorerEntry> entries) {
    final result = <String, List<ExplorerEntry>>{};
    for (final entry in entries) {
      final parent = _safeParentLabel(entry.path);
      result.putIfAbsent(parent, () => <ExplorerEntry>[]).add(entry);
    }
    return result;
  }

  Map<String, List<ExplorerEntry>> _groupByNameHeuristic(
    List<ExplorerEntry> entries,
    String mode,
  ) {
    final result = <String, List<ExplorerEntry>>{};
    for (final entry in entries) {
      final parts = entry.name.split(RegExp(r'\s*-\s*'));
      final label = switch (mode) {
        'artist' when parts.length > 1 => parts.first.trim(),
        'album' => _safeParentLabel(entry.path),
        'playlist' => _safeParentLabel(entry.path),
        'genre' => language.t('media.group.unknown'),
        _ => language.t('media.group.unknown'),
      };
      result
          .putIfAbsent(
              label.isEmpty ? language.t('media.group.unknown') : label,
              () => <ExplorerEntry>[])
          .add(entry);
    }
    return result;
  }

  String _safeParentLabel(String path) {
    try {
      return basename(File(path).parent.path);
    } catch (_) {
      final parts = path.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty);
      return parts.length > 1 ? parts.elementAt(parts.length - 2) : path;
    }
  }

  List<ExplorerEntry> _currentEntries(List<ExplorerEntry> mediaEntries) {
    if (mediaPlaylist.isEmpty) return const <ExplorerEntry>[];
    final byPath = <String, ExplorerEntry>{
      for (final entry in mediaEntries) entry.path: entry,
    };
    final byName = <String, ExplorerEntry>{
      for (final entry in mediaEntries) entry.name: entry,
    };
    final result = <ExplorerEntry>[];
    for (final item in mediaPlaylist) {
      final entry =
          byPath[item.path] ?? byPath[item.resumeKey] ?? byName[item.title];
      if (entry != null && !result.any((e) => e.path == entry.path)) {
        result.add(entry);
      }
    }
    return result;
  }
}

class _MediaEntryList extends StatefulWidget {
  const _MediaEntryList({
    required this.language,
    required this.entries,
    required this.onEntry,
    required this.onDownloadEntry,
    required this.onDownloadEntries,
    this.emptyText,
  });

  final AppLanguage language;
  final List<ExplorerEntry> entries;
  final String? emptyText;
  final Future<void> Function(ExplorerEntry) onEntry;
  final Future<void> Function(ExplorerEntry) onDownloadEntry;
  final Future<void> Function(List<ExplorerEntry>) onDownloadEntries;

  @override
  State<_MediaEntryList> createState() => _MediaEntryListState();
}

class _MediaEntryListState extends State<_MediaEntryList> {
  final Set<String> _selectedPaths = <String>{};

  @override
  void didUpdateWidget(covariant _MediaEntryList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final currentPaths = widget.entries.map((entry) => entry.path).toSet();
    _selectedPaths.removeWhere((path) => !currentPaths.contains(path));
  }

  void _toggleSelection(ExplorerEntry entry) {
    if (!_downloadable(entry)) return;
    setState(() {
      if (!_selectedPaths.remove(entry.path)) {
        _selectedPaths.add(entry.path);
      }
    });
  }

  bool _downloadable(ExplorerEntry entry) =>
      !entry.isDirectory && _isHttpMedia(entry.path);

  List<ExplorerEntry> get _selectedEntries => widget.entries
      .where((entry) => _selectedPaths.contains(entry.path))
      .toList();

  @override
  Widget build(BuildContext context) {
    if (widget.entries.isEmpty) {
      return Center(
          child: Text(widget.emptyText ?? widget.language.t('explorer.empty')));
    }
    final list = ListView.separated(
      padding: const EdgeInsets.all(14),
      itemCount: widget.entries.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = widget.entries[index];
        final kind = FileViewerService.kindForName(entry.name);
        final selectionMode = _selectedPaths.isNotEmpty;
        final selected = _selectedPaths.contains(entry.path);
        final downloadable = _downloadable(entry);
        return ListTile(
          leading: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: downloadable ? () => _toggleSelection(entry) : null,
            onTap: selectionMode && downloadable
                ? () => _toggleSelection(entry)
                : null,
            child: selectionMode && downloadable
                ? Checkbox(
                    value: selected,
                    onChanged: (_) => _toggleSelection(entry),
                  )
                : Icon(entry.isDirectory
                    ? Icons.folder_outlined
                    : kind == FileContentKind.video
                        ? Icons.movie_outlined
                        : Icons.audiotrack_outlined),
          ),
          title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${_size(entry)} - ${_date(entry.modifiedAt)}'),
          selected: selected,
          trailing: downloadable
              ? IconButton(
                  tooltip: widget.language.t('plugin.media.download'),
                  icon: const Icon(Icons.download_outlined),
                  onPressed: () => unawaited(widget.onDownloadEntry(entry)),
                )
              : null,
          onTap: selectionMode && downloadable
              ? () => _toggleSelection(entry)
              : () => unawaited(widget.onEntry(entry)),
        );
      },
    );
    if (_selectedPaths.isEmpty) return list;
    return Column(children: [
      Material(
        color: Theme.of(context).colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            Expanded(
              child: Text(
                '${widget.language.t('selection.count')}: ${_selectedPaths.length}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            IconButton(
              tooltip: widget.language.t('plugin.media.download.selected'),
              onPressed: () {
                final selected = _selectedEntries;
                setState(() => _selectedPaths.clear());
                unawaited(widget.onDownloadEntries(selected));
              },
              icon: const Icon(Icons.download_outlined),
            ),
            IconButton(
              tooltip: widget.language.t('selection.clear'),
              onPressed: () => setState(_selectedPaths.clear),
              icon: const Icon(Icons.close),
            ),
          ]),
        ),
      ),
      Expanded(child: list),
    ]);
  }

  String _size(ExplorerEntry entry) {
    if (entry.isDirectory) return widget.language.t('explorer.folder');
    final size = entry.sizeBytes;
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  String _date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

bool _isHttpMedia(String path) =>
    path.startsWith('http://') || path.startsWith('https://');

class _MediaGroupList extends StatelessWidget {
  const _MediaGroupList({
    required this.language,
    required this.groups,
    required this.onEntry,
    required this.onDownloadEntry,
  });

  final AppLanguage language;
  final Map<String, List<ExplorerEntry>> groups;
  final Future<void> Function(ExplorerEntry, List<ExplorerEntry>) onEntry;
  final Future<void> Function(ExplorerEntry) onDownloadEntry;

  @override
  Widget build(BuildContext context) {
    if (groups.isEmpty) {
      return Center(child: Text(language.t('explorer.empty')));
    }
    final names = groups.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return ListView.builder(
      padding: const EdgeInsets.all(14),
      itemCount: names.length,
      itemBuilder: (context, index) {
        final name = names[index];
        final items = groups[name] ?? const <ExplorerEntry>[];
        return ExpansionTile(
          leading: const Icon(Icons.folder_outlined),
          title: Text(name),
          subtitle: Text('${items.length}'),
          children: [
            for (final entry in items)
              ListTile(
                dense: true,
                leading: const Icon(Icons.play_arrow_outlined),
                title: Text(entry.name, maxLines: 1),
                trailing: _isHttpMedia(entry.path)
                    ? IconButton(
                        tooltip: language.t('plugin.media.download'),
                        icon: const Icon(Icons.download_outlined),
                        onPressed: () => unawaited(onDownloadEntry(entry)),
                      )
                    : null,
                onTap: () => unawaited(onEntry(entry, items)),
              ),
          ],
        );
      },
    );
  }
}

class _MediaHeader extends StatelessWidget {
  const _MediaHeader({
    required this.title,
    required this.language,
    required this.onRefresh,
    required this.onSearch,
    required this.onSearchFilters,
    required this.searchQuery,
  });

  final String title;
  final AppLanguage language;
  final Future<void> Function() onRefresh;
  final VoidCallback onSearch;
  final VoidCallback? onSearchFilters;
  final String searchQuery;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFDDE6F0))),
      ),
      child: Row(children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        IconButton(
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh),
          tooltip: language.t('explorer.refresh'),
        ),
        IconButton(
          onPressed: onSearch,
          icon: Icon(searchQuery.isEmpty ? Icons.search : Icons.search_off),
          tooltip: language.t('search.title'),
        ),
        if (onSearchFilters != null)
          IconButton(
            onPressed: onSearchFilters,
            icon: const Icon(Icons.tune_outlined),
            tooltip: language.t('search.filters'),
          ),
      ]),
    );
  }
}

class _MediaThumbnail extends StatelessWidget {
  const _MediaThumbnail({
    required this.entry,
    required this.kind,
    this.fit = BoxFit.cover,
  });

  final ExplorerEntry entry;
  final FileContentKind kind;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    if (kind == FileContentKind.image) {
      return Image.file(
        File(entry.path),
        width: double.infinity,
        height: double.infinity,
        fit: fit,
        errorBuilder: (_, __, ___) => _fallback(context),
      );
    }
    if (kind == FileContentKind.video) {
      return FutureBuilder<Uint8List?>(
        future: MediaArtworkService.videoThumbnail(entry.path),
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (bytes != null && bytes.isNotEmpty) {
            return Stack(fit: StackFit.expand, children: [
              Image.memory(bytes, fit: fit),
              const Center(
                child: Icon(Icons.play_circle_fill,
                    color: Colors.white70, size: 42),
              ),
            ]);
          }
          return _fallback(context);
        },
      );
    }
    return _fallback(context);
  }

  Widget _fallback(BuildContext context) => Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Center(
          child: Icon(
            kind == FileContentKind.video
                ? Icons.movie_outlined
                : Icons.image_outlined,
            size: 42,
          ),
        ),
      );
}

class _ExplorerView extends StatelessWidget {
  const _ExplorerView({
    required this.language,
    required this.currentPath,
    required this.snapshot,
    required this.selected,
    required this.preview,
    required this.mediaPlaylist,
    required this.imagePlaylist,
    required this.flashPlaylist,
    required this.mediaResumePositions,
    required this.onUp,
    required this.onForward,
    required this.canGoForward,
    required this.onRefresh,
    required this.onImport,
    required this.onExport,
    required this.previewWidth,
    required this.previewVisible,
    required this.fileTextScale,
    required this.fileIconScale,
    required this.toolbarIconScale,
    required this.showPathToolbar,
    required this.showToolbarActions,
    required this.showHiddenFiles,
    required this.showSystemFiles,
    required this.ytDlpEnabled,
    required this.onPreviewResize,
    required this.onTogglePreview,
    required this.onOpenPassword,
    required this.onOpenExternal,
    required this.onPreviewWindow,
    required this.onEditPreview,
    required this.onReadPreview,
    required this.allowMiniDockForPreview,
    required this.onImageNavigate,
    required this.onFlashNavigate,
    required this.onRememberMediaPosition,
    required this.canPaste,
    required this.favoritePaths,
    required this.recentPaths,
    required this.selectedPaths,
    required this.searchQuery,
    required this.searchUseRegex,
    required this.searchFilters,
    required this.sortMode,
    required this.localSearchEnabled,
    required this.showVideoThumbnails,
    required this.animateVideoThumbnails,
    required this.showAudioArtwork,
    required this.onThumbnailPreview,
    required this.onPathEdit,
    required this.onPathPick,
    required this.onSearch,
    required this.onSearchFilters,
    required this.onSort,
    required this.onExplorerMenuAction,
    required this.onEntryAction,
    required this.onEmptyAreaAction,
    required this.onRemoveRecent,
    required this.onToggleFavorite,
    required this.onToggleSelection,
    required this.onSelectAllEntries,
    required this.onClearSelection,
    required this.onBulkAction,
    required this.onEntry,
    required this.onEntryFullscreen,
  });

  final AppLanguage language;
  final String? currentPath;
  final Future<DirectorySnapshot>? snapshot;
  final ExplorerEntry? selected;
  final Future<FilePreview>? preview;
  final List<MediaPreviewItem> mediaPlaylist;
  final List<MediaPreviewItem> imagePlaylist;
  final List<MediaPreviewItem> flashPlaylist;
  final Map<String, int> mediaResumePositions;
  final VoidCallback onUp;
  final VoidCallback onForward;
  final bool canGoForward;
  final Future<void> Function() onRefresh;
  final VoidCallback onImport;
  final VoidCallback onExport;
  final double previewWidth;
  final bool previewVisible;
  final double fileTextScale;
  final double fileIconScale;
  final double toolbarIconScale;
  final bool showPathToolbar;
  final bool showToolbarActions;
  final bool showHiddenFiles;
  final bool showSystemFiles;
  final bool ytDlpEnabled;
  final ValueChanged<double> onPreviewResize;
  final VoidCallback onTogglePreview;
  final VoidCallback onOpenPassword;
  final ValueChanged<FilePreview> onOpenExternal;
  final ValueChanged<FilePreview> onPreviewWindow;
  final ValueChanged<FilePreview> onEditPreview;
  final ValueChanged<FilePreview> onReadPreview;
  final bool allowMiniDockForPreview;
  final Future<FilePreview?> Function(int delta) onImageNavigate;
  final Future<FilePreview?> Function(int delta) onFlashNavigate;
  final Future<void> Function(String key, Duration position)
      onRememberMediaPosition;
  final bool canPaste;
  final List<String> favoritePaths;
  final List<String> recentPaths;
  final Set<String> selectedPaths;
  final String searchQuery;
  final bool searchUseRegex;
  final _SearchFilters searchFilters;
  final _FolderSortMode sortMode;
  final bool localSearchEnabled;
  final bool showVideoThumbnails;
  final bool animateVideoThumbnails;
  final bool showAudioArtwork;
  final Future<FilePreview> Function(ExplorerEntry) onThumbnailPreview;
  final VoidCallback onPathEdit;
  final VoidCallback onPathPick;
  final VoidCallback onSearch;
  final VoidCallback onSearchFilters;
  final VoidCallback onSort;
  final ValueChanged<_ExplorerMenuAction> onExplorerMenuAction;
  final Future<void> Function(ExplorerEntry, _EntryAction) onEntryAction;
  final Future<void> Function(String, _EntryAction) onEmptyAreaAction;
  final ValueChanged<String> onRemoveRecent;
  final ValueChanged<ExplorerEntry> onToggleFavorite;
  final ValueChanged<ExplorerEntry> onToggleSelection;
  final ValueChanged<List<ExplorerEntry>> onSelectAllEntries;
  final VoidCallback onClearSelection;
  final Future<void> Function(_EntryAction) onBulkAction;
  final Future<void> Function(ExplorerEntry) onEntry;
  final Future<void> Function(ExplorerEntry) onEntryFullscreen;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      if (showPathToolbar)
        Container(
          padding: const EdgeInsets.all(12),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: Color(0xFFDDE6F0))),
          ),
          child: Column(children: [
            Row(children: [
              IconButton(
                onPressed: onUp,
                icon: Icon(Icons.arrow_back, size: 24 * toolbarIconScale),
                tooltip: language.t('explorer.up'),
              ),
              IconButton(
                onPressed: onRefresh,
                icon: Icon(Icons.refresh, size: 24 * toolbarIconScale),
                tooltip: language.t('explorer.refresh'),
              ),
              IconButton(
                onPressed: canGoForward ? onForward : null,
                icon: Icon(Icons.arrow_forward, size: 24 * toolbarIconScale),
                tooltip: language.t('explorer.forward'),
              ),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onPathPick,
                  onLongPress: onPathEdit,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      color: const Color(0xFFF3F7FB),
                      border: Border.all(color: const Color(0xFFDDE6F0)),
                    ),
                    child: Text(
                      currentPath ?? language.t('explorer.choose.location'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              if (showToolbarActions) ...[
                const SizedBox(width: 8),
                IconButton(
                  onPressed: onSearch,
                  icon: Icon(
                    searchQuery.isEmpty ? Icons.search : Icons.search_off,
                    size: 24 * toolbarIconScale,
                  ),
                  tooltip: language.t('search.title'),
                ),
                IconButton(
                  onPressed: onTogglePreview,
                  icon: Icon(
                    previewVisible
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 24 * toolbarIconScale,
                  ),
                  tooltip: previewVisible
                      ? language.t('preview.hide')
                      : language.t('preview.show'),
                ),
                _ExplorerOverflowMenu(
                  language: language,
                  sortLabel: language.t('sort.action'),
                  showHiddenFiles: showHiddenFiles,
                  showSystemFiles: showSystemFiles,
                  ytDlpEnabled: ytDlpEnabled,
                  iconScale: toolbarIconScale,
                  onSelected: onExplorerMenuAction,
                ),
              ],
            ]),
            const SizedBox(height: 5),
            _StorageUsageStrip(path: currentPath, language: language),
          ]),
        ),
      Expanded(
        child: LayoutBuilder(builder: (context, c) {
          final list = _EntryList(
            language: language,
            snapshot: snapshot,
            selected: selected,
            fileTextScale: fileTextScale,
            fileIconScale: fileIconScale,
            onEntry: onEntry,
            onEntryFullscreen: onEntryFullscreen,
            canPaste: canPaste,
            favoritePaths: favoritePaths,
            recentPaths: recentPaths,
            selectedPaths: selectedPaths,
            searchQuery: searchQuery,
            searchUseRegex: searchUseRegex,
            searchFilters: searchFilters,
            sortMode: sortMode,
            localSearchEnabled: localSearchEnabled,
            showHiddenFiles: showHiddenFiles,
            showSystemFiles: showSystemFiles,
            ytDlpEnabled: ytDlpEnabled,
            showVideoThumbnails: showVideoThumbnails,
            animateVideoThumbnails: animateVideoThumbnails,
            showAudioArtwork: showAudioArtwork,
            onThumbnailPreview: onThumbnailPreview,
            onEntryAction: onEntryAction,
            currentPath: currentPath,
            onEmptyAreaAction: onEmptyAreaAction,
            onRemoveRecent: onRemoveRecent,
            onToggleFavorite: onToggleFavorite,
            onToggleSelection: onToggleSelection,
            onSelectAllEntries: onSelectAllEntries,
            onClearSelection: onClearSelection,
            onBulkAction: onBulkAction,
          );
          final pane = _PreviewPane(
            language: language,
            entry: selected,
            preview: preview,
            mediaPlaylist: mediaPlaylist,
            imagePlaylist: imagePlaylist,
            flashPlaylist: flashPlaylist,
            mediaResumePositions: mediaResumePositions,
            visible: previewVisible,
            onTogglePreview: onTogglePreview,
            onOpenPassword: onOpenPassword,
            onOpenExternal: onOpenExternal,
            onPreviewWindow: onPreviewWindow,
            onEditPreview: onEditPreview,
            onReadPreview: onReadPreview,
            allowMiniDock: allowMiniDockForPreview,
            onEntryAction: onEntryAction,
            onImageNavigate: onImageNavigate,
            onFlashNavigate: onFlashNavigate,
            onRememberMediaPosition: onRememberMediaPosition,
          );
          if (c.maxWidth < 980) {
            return Column(children: [
              Expanded(flex: 3, child: list),
              if (previewVisible) const Divider(height: 1),
              if (previewVisible) Expanded(flex: 2, child: pane)
            ]);
          }
          if (!previewVisible) {
            return Row(children: [Expanded(child: list)]);
          }
          return Row(children: [
            Expanded(child: list),
            _DragDivider(onDrag: onPreviewResize),
            SizedBox(width: previewWidth, child: pane)
          ]);
        }),
      ),
    ]);
  }
}

class _ExplorerOverflowMenu extends StatelessWidget {
  const _ExplorerOverflowMenu({
    required this.language,
    required this.sortLabel,
    required this.showHiddenFiles,
    required this.showSystemFiles,
    required this.ytDlpEnabled,
    required this.iconScale,
    required this.onSelected,
  });

  final AppLanguage language;
  final String sortLabel;
  final bool showHiddenFiles;
  final bool showSystemFiles;
  final bool ytDlpEnabled;
  final double iconScale;
  final ValueChanged<_ExplorerMenuAction> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_ExplorerMenuAction>(
      icon: Icon(Icons.more_vert, size: 24 * iconScale),
      onSelected: onSelected,
      itemBuilder: (_) => [
        PopupMenuItem(
          value: _ExplorerMenuAction.upload,
          child: Text(language.t('explorer.upload')),
        ),
        PopupMenuItem(
          value: _ExplorerMenuAction.download,
          child: Text(language.t('explorer.download')),
        ),
        if (ytDlpEnabled)
          PopupMenuItem(
            value: _ExplorerMenuAction.downloadUrl,
            child: Text(language.t('plugin.ytdlp.download.url')),
          ),
        PopupMenuItem(
          value: _ExplorerMenuAction.sort,
          child: Text(sortLabel),
        ),
        PopupMenuItem(
          value: _ExplorerMenuAction.folderSettings,
          child: Text(language.t('folder.settings.title')),
        ),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(
          value: _ExplorerMenuAction.toggleHidden,
          checked: showHiddenFiles,
          child: Text(language.t('explorer.show.hidden')),
        ),
        CheckedPopupMenuItem(
          value: _ExplorerMenuAction.toggleSystem,
          checked: showSystemFiles,
          child: Text(language.t('explorer.show.system')),
        ),
      ],
    );
  }
}

class _StorageUsageStrip extends StatelessWidget {
  const _StorageUsageStrip({
    required this.path,
    required this.language,
  });

  final String? path;
  final AppLanguage language;

  @override
  Widget build(BuildContext context) {
    final current = path;
    if (current == null || current.trim().isEmpty) {
      return const SizedBox.shrink();
    }
    return FutureBuilder<_StorageUsageInfo>(
      future: _StorageUsageInfo.load(current),
      builder: (context, snapshot) {
        final info = snapshot.data;
        final labels = info == null
            ? [language.t('storage.checking')]
            : info.available
                ? [
                    '${language.t('storage.total')}: ${_formatBytes(info.total)}',
                    '${language.t('storage.used')}: ${_formatBytes(info.used)}',
                    '${language.t('storage.free')}: ${_formatBytes(info.free)}',
                  ]
                : [info.message ?? language.t('storage.unavailable')];
        final value = info == null || !info.available || info.total <= 0
            ? null
            : (info.used / info.total).clamp(0.0, 1.0).toDouble();
        return LayoutBuilder(builder: (context, constraints) {
          final narrow = constraints.maxWidth < 420;
          final bar = ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              minHeight: 4,
              value: value,
              backgroundColor: const Color(0xFFE8EEF5),
            ),
          );
          final labelWrap = Wrap(
            spacing: 8,
            runSpacing: 2,
            children: [
              for (final label in labels)
                Text(
                  label,
                  maxLines: narrow ? 2 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontSize: narrow ? 10 : null,
                      ),
                ),
            ],
          );
          if (narrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                bar,
                const SizedBox(height: 4),
                labelWrap,
              ],
            );
          }
          return Row(children: [
            Expanded(child: bar),
            const SizedBox(width: 8),
            Flexible(flex: 2, child: labelWrap),
          ]);
        });
      },
    );
  }

  static String _formatBytes(int value) {
    if (value < 1024) return '$value B';
    final units = ['KB', 'MB', 'GB', 'TB'];
    var size = value / 1024.0;
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${size.toStringAsFixed(size >= 100 ? 0 : 1)} ${units[unit]}';
  }
}

class _StorageUsageInfo {
  const _StorageUsageInfo({
    required this.available,
    this.total = 0,
    this.free = 0,
    this.message,
  });

  final bool available;
  final int total;
  final int free;
  final String? message;

  int get used => math.max(0, total - free);

  static Future<_StorageUsageInfo> load(String path) async {
    if (path.startsWith('remote://') ||
        path.startsWith('zip://') ||
        path.startsWith('rar://') ||
        path.startsWith('torrent://')) {
      return const _StorageUsageInfo(
        available: false,
        message: 'Plugin/virtual storage',
      );
    }
    try {
      if (Platform.isWindows) {
        return await _loadWindows(path);
      }
      return await _loadDf(path);
    } catch (error) {
      return _StorageUsageInfo(available: false, message: '$error');
    }
  }

  static Future<_StorageUsageInfo> _loadWindows(String path) async {
    final drive = RegExp(r'^[a-zA-Z]:').firstMatch(path)?.group(0);
    if (drive == null) {
      return const _StorageUsageInfo(available: false);
    }
    final wmic = await Process.run(
      'wmic',
      [
        'logicaldisk',
        'where',
        "DeviceID='$drive'",
        'get',
        'Size,FreeSpace',
        '/value',
      ],
    ).timeout(const Duration(seconds: 4));
    return _parseWmic('${wmic.stdout}') ??
        const _StorageUsageInfo(available: false);
  }

  static _StorageUsageInfo? _parseWmic(String value) {
    int? total;
    int? free;
    for (final line in value.split(RegExp(r'\r?\n'))) {
      final parts = line.split('=');
      if (parts.length != 2) continue;
      if (parts[0].trim().toLowerCase() == 'size') {
        total = int.tryParse(parts[1].trim());
      } else if (parts[0].trim().toLowerCase() == 'freespace') {
        free = int.tryParse(parts[1].trim());
      }
    }
    if (total == null || free == null || total <= 0) return null;
    return _StorageUsageInfo(available: true, total: total, free: free);
  }

  static Future<_StorageUsageInfo> _loadDf(String path) async {
    final result = await Process.run('df', ['-k', path])
        .timeout(const Duration(seconds: 4));
    if (result.exitCode != 0) {
      return _StorageUsageInfo(available: false, message: '${result.stderr}');
    }
    final lines = '${result.stdout}'
        .split(RegExp(r'\r?\n'))
        .where((line) => line.trim().isNotEmpty)
        .toList();
    if (lines.length < 2) return const _StorageUsageInfo(available: false);
    final parts = lines.last.trim().split(RegExp(r'\s+'));
    if (parts.length < 4) return const _StorageUsageInfo(available: false);
    final totalKb = int.tryParse(parts[1]);
    final freeKb = int.tryParse(parts[3]);
    if (totalKb == null || freeKb == null || totalKb <= 0) {
      return const _StorageUsageInfo(available: false);
    }
    return _StorageUsageInfo(
      available: true,
      total: totalKb * 1024,
      free: freeKb * 1024,
    );
  }
}

class _EntryList extends StatelessWidget {
  const _EntryList({
    required this.language,
    required this.snapshot,
    required this.selected,
    required this.fileTextScale,
    required this.fileIconScale,
    required this.onEntry,
    required this.onEntryFullscreen,
    required this.canPaste,
    required this.favoritePaths,
    required this.recentPaths,
    required this.selectedPaths,
    required this.searchQuery,
    required this.searchUseRegex,
    required this.searchFilters,
    required this.sortMode,
    required this.localSearchEnabled,
    required this.showHiddenFiles,
    required this.showSystemFiles,
    required this.ytDlpEnabled,
    required this.showVideoThumbnails,
    required this.animateVideoThumbnails,
    required this.showAudioArtwork,
    required this.onThumbnailPreview,
    required this.currentPath,
    required this.onEntryAction,
    required this.onEmptyAreaAction,
    required this.onRemoveRecent,
    required this.onToggleFavorite,
    required this.onToggleSelection,
    required this.onSelectAllEntries,
    required this.onClearSelection,
    required this.onBulkAction,
  });

  final AppLanguage language;
  final Future<DirectorySnapshot>? snapshot;
  final ExplorerEntry? selected;
  final double fileTextScale;
  final double fileIconScale;
  final Future<void> Function(ExplorerEntry) onEntry;
  final Future<void> Function(ExplorerEntry) onEntryFullscreen;
  final bool canPaste;
  final List<String> favoritePaths;
  final List<String> recentPaths;
  final Set<String> selectedPaths;
  final String searchQuery;
  final bool searchUseRegex;
  final _SearchFilters searchFilters;
  final _FolderSortMode sortMode;
  final bool localSearchEnabled;
  final bool showHiddenFiles;
  final bool showSystemFiles;
  final bool ytDlpEnabled;
  final bool showVideoThumbnails;
  final bool animateVideoThumbnails;
  final bool showAudioArtwork;
  final Future<FilePreview> Function(ExplorerEntry) onThumbnailPreview;
  final String? currentPath;
  final Future<void> Function(ExplorerEntry, _EntryAction) onEntryAction;
  final Future<void> Function(String, _EntryAction) onEmptyAreaAction;
  final ValueChanged<String> onRemoveRecent;
  final ValueChanged<ExplorerEntry> onToggleFavorite;
  final ValueChanged<ExplorerEntry> onToggleSelection;
  final ValueChanged<List<ExplorerEntry>> onSelectAllEntries;
  final VoidCallback onClearSelection;
  final Future<void> Function(_EntryAction) onBulkAction;

  @override
  Widget build(BuildContext context) {
    final future = snapshot;
    if (future == null) {
      return Center(child: Text(language.t('explorer.choose.location.left')));
    }
    return FutureBuilder<DirectorySnapshot>(
      future: future,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = snap.data!;
        if (data.hasError) {
          return Center(
            child: Text(
              '${language.t('explorer.access.error')}\n${data.error}',
              textAlign: TextAlign.center,
            ),
          );
        }
        final entries = (searchQuery.isEmpty || !localSearchEnabled
                ? data.entries
                : data.entries
                    .where((entry) => _matchesSearch(entry.name))
                    .toList())
            .where(_isVisibleByFileFlags)
            .where(searchFilters.accepts)
            .toList();
        final sortedEntries = sortMode.sort(entries);
        if (sortedEntries.isEmpty) {
          return _EmptyExplorerArea(
            language: language,
            currentPath: currentPath,
            canPaste: canPaste,
            ytDlpEnabled: ytDlpEnabled,
            onAction: onEmptyAreaAction,
            child: Center(child: Text(language.t('explorer.empty'))),
          );
        }
        final listView = ListView.separated(
          padding: const EdgeInsets.all(12),
          cacheExtent: 220,
          itemCount: sortedEntries.length + 1,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            if (i == sortedEntries.length) {
              return _EmptyExplorerArea(
                language: language,
                currentPath: currentPath,
                canPaste: canPaste,
                ytDlpEnabled: ytDlpEnabled,
                onAction: onEmptyAreaAction,
                child: const SizedBox(height: 240),
              );
            }
            final entry = sortedEntries[i];
            final selectionMode = selectedPaths.isNotEmpty;
            final selectedForBulk = selectedPaths.contains(entry.path);
            return GestureDetector(
              onSecondaryTapDown: (details) =>
                  _showEntryContextMenu(context, entry, details.globalPosition),
              onLongPressStart: (details) =>
                  _showEntryContextMenu(context, entry, details.globalPosition),
              onDoubleTap: entry.isDirectory
                  ? null
                  : () => unawaited(onEntryFullscreen(entry)),
              child: ListTile(
                dense: fileTextScale <= 1.05 && fileIconScale <= 1.05,
                visualDensity: VisualDensity(
                  horizontal: -2,
                  vertical: ((fileTextScale + fileIconScale) / 2 - 1)
                      .clamp(-4.0, 2.0),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                minVerticalPadding: 0,
                selected: selected?.path == entry.path,
                textColor: _connectionTextColor(entry),
                iconColor: _connectionTextColor(entry),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                leading: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onLongPress: () => onToggleSelection(entry),
                  onTap: selectionMode ? () => onToggleSelection(entry) : null,
                  child: selectionMode && !entry.isNavigationEntry
                      ? Checkbox(
                          value: selectedForBulk,
                          onChanged: (_) => onToggleSelection(entry),
                        )
                      : _EntryLeadingThumbnail(
                          entry: entry,
                          icon: _icon(entry),
                          color: _color(entry),
                          size: 28 * fileIconScale,
                          showVideoThumbnails: showVideoThumbnails,
                          animateVideoThumbnails: animateVideoThumbnails,
                          showAudioArtwork: showAudioArtwork,
                          previewLoader: onThumbnailPreview,
                        ),
                ),
                title: Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14 * fileTextScale),
                ),
                subtitle: Text(entry.exists
                    ? _subtitle(entry)
                    : language.t('recent.missing.file')),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (entry.connectionStatus != ExplorerConnectionStatus.none)
                    Icon(
                      entry.connectionStatus ==
                              ExplorerConnectionStatus.available
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      color: _connectionTextColor(entry),
                    ),
                  if (entry.containerInfo?.isOk == true)
                    const Icon(Icons.verified_outlined,
                        color: Color(0xFF2B7A4B)),
                  Builder(
                    builder: (buttonContext) => IconButton(
                      icon: const Icon(Icons.more_vert),
                      onPressed: () => unawaited(
                        _showEntryContextMenu(
                          context,
                          entry,
                          _globalAnchorFor(buttonContext, trailing: true),
                        ),
                      ),
                    ),
                  ),
                ]),
                onTap: selectionMode
                    ? () => onToggleSelection(entry)
                    : () => onEntry(entry),
              ),
            );
          },
        );
        if (selectedPaths.isEmpty) return listView;
        return Column(children: [
          _SelectionToolbar(
            language: language,
            selectedCount: selectedPaths.length,
            onSelectAll: () => onSelectAllEntries(sortedEntries),
            onClear: onClearSelection,
            onAction: onBulkAction,
          ),
          Expanded(child: listView),
        ]);
      },
    );
  }

  bool _matchesSearch(String value) {
    if (searchQuery.isEmpty) return true;
    if (searchUseRegex) {
      try {
        return RegExp(searchQuery, caseSensitive: false).hasMatch(value);
      } catch (_) {
        return value.toLowerCase().contains(searchQuery.toLowerCase());
      }
    }
    return value.toLowerCase().contains(searchQuery.toLowerCase());
  }

  bool _isVisibleByFileFlags(ExplorerEntry entry) {
    if (entry.isNavigationEntry) return true;
    final name = entry.name;
    final lower = name.toLowerCase();
    final hidden =
        name.startsWith('.') || lower == 'thumbs.db' || lower == 'desktop.ini';
    final system = lower == 'system volume information' ||
        lower == r'$recycle.bin' ||
        lower == 'pagefile.sys' ||
        lower == 'hiberfil.sys' ||
        lower == 'swapfile.sys' ||
        lower == 'lost+found' ||
        lower == 'android';
    if (!showHiddenFiles && hidden) return false;
    if (!showSystemFiles && system) return false;
    return true;
  }

  Future<void> _showEntryContextMenu(
    BuildContext context,
    ExplorerEntry entry,
    Offset? position,
  ) async {
    final selectedAction = await _showCascadingContextMenu(
      context: context,
      position: position,
      items: _entryMenuSpecs(entry),
    );
    if (selectedAction != null) {
      _handleEntryAction(entry, selectedAction);
    }
  }

  _ContextMenuSpec _menuItem(
    _EntryAction action,
    String label, {
    bool enabled = true,
  }) =>
      _ContextMenuSpec(
        action: action,
        label: label,
        enabled: enabled,
      );

  _ContextMenuSpec _parentItem(
    _EntryAction action,
    String label, {
    bool enabled = true,
    required List<_ContextMenuSpec> children,
  }) =>
      _ContextMenuSpec(
        action: action,
        label: label,
        enabled: enabled,
        children: children,
      );

  List<_ContextMenuSpec> _createSubmenuSpecs() => [
        _menuItem(_EntryAction.createFolder, language.t('create.folder')),
        _menuItem(_EntryAction.createPlain, language.t('create.plain')),
        _menuItem(
          _EntryAction.createEncryptedPlain,
          language.t('create.encrypted.plain'),
        ),
        _menuItem(_EntryAction.createCsv, language.t('create.csv')),
        _menuItem(
          _EntryAction.createEncryptedCsv,
          language.t('create.encrypted.csv'),
        ),
        _menuItem(_EntryAction.createImage, language.t('create.image')),
        _menuItem(
          _EntryAction.createEncryptedImage,
          language.t('create.encrypted.image'),
        ),
      ];

  List<_ContextMenuSpec> _openAsSubmenuSpecs() => [
        _menuItem(_EntryAction.openAsText, language.t('preview.force.text')),
        _menuItem(_EntryAction.openAsImage, language.t('preview.force.image')),
        _menuItem(_EntryAction.openAsAudio, language.t('preview.force.audio')),
        _menuItem(_EntryAction.openAsVideo, language.t('preview.force.video')),
      ];

  List<_ContextMenuSpec> _useAsSubmenuSpecs() => [
        _menuItem(
          _EntryAction.useAsGallery,
          language.t('folder.use.gallery'),
        ),
        _menuItem(
          _EntryAction.useAsVideo,
          language.t('folder.use.video'),
        ),
        _menuItem(
          _EntryAction.useAsMusic,
          language.t('folder.use.audio'),
        ),
        _menuItem(
          _EntryAction.useAsMultimedia,
          language.t('folder.use.multimedia'),
        ),
      ];

  List<_ContextMenuSpec> _folderEncryptSubmenuSpecs() => [
        _menuItem(
          _EntryAction.folderContainer,
          language.t('explorer.folder.container.as'),
        ),
        _menuItem(
          _EntryAction.folderEncryptName,
          language.t('explorer.folder.encrypt.name.short'),
        ),
        _menuItem(
          _EntryAction.folderEncrypt,
          language.t('explorer.folder.encrypt.files'),
        ),
      ];

  List<_ContextMenuSpec> _folderDecryptSubmenuSpecs() => [
        _menuItem(
          _EntryAction.folderDecryptName,
          language.t('explorer.folder.decrypt.name.short'),
        ),
        _menuItem(
          _EntryAction.folderDecrypt,
          language.t('explorer.folder.decrypt.files'),
        ),
      ];

  List<_ContextMenuSpec> _entryMenuSpecs(ExplorerEntry entry) {
    final isFavorite = favoritePaths.contains(entry.path);
    final isRecent = recentPaths.contains(entry.path);
    final isVirtual =
        entry.path.startsWith('zip://') || entry.path.startsWith('rar://');
    final isRemote = entry.path.startsWith('remote://');
    final isProfileLocation = entry.connectionProfileId != null;
    final extension = FileViewerService.extensionForName(entry.path);
    final ocrCandidate =
        FileViewerService.kindForName(entry.path) == FileContentKind.image ||
            extension == '.pdf' ||
            entry.isEncrypted;
    final canChangeFile = entry.exists && !isVirtual && !isProfileLocation;
    if (entry.isNavigationEntry) {
      return [
        _menuItem(_EntryAction.open, language.t('common.open')),
      ];
    }
    return [
      _menuItem(_EntryAction.open, language.t('common.open')),
      if (!entry.isDirectory)
        _menuItem(
          _EntryAction.edit,
          language.t('editor.open'),
          enabled: entry.exists,
        ),
      const _ContextMenuSpec.divider(),
      if (entry.isDirectory)
        _parentItem(
          _EntryAction.create,
          language.t('explorer.create'),
          enabled: canChangeFile,
          children: _createSubmenuSpecs(),
        ),
      if (entry.isDirectory && ytDlpEnabled)
        _menuItem(
          _EntryAction.downloadUrl,
          language.t('plugin.ytdlp.download.url'),
          enabled: canChangeFile,
        ),
      if (!entry.isDirectory)
        _parentItem(
          _EntryAction.openAs,
          language.t('explorer.open.as'),
          enabled: entry.exists,
          children: _openAsSubmenuSpecs(),
        ),
      _menuItem(
        isFavorite ? _EntryAction.removeFavorite : _EntryAction.addFavorite,
        isFavorite
            ? language.t('favorites.remove')
            : language.t('favorites.add'),
      ),
      if (isRecent)
        _menuItem(_EntryAction.removeRecent, language.t('recent.remove')),
      const _ContextMenuSpec.divider(),
      _menuItem(
        _EntryAction.copy,
        language.t('explorer.copy'),
        enabled: canChangeFile,
      ),
      _menuItem(
        _EntryAction.cut,
        language.t('explorer.cut'),
        enabled: canChangeFile,
      ),
      _menuItem(
        _EntryAction.paste,
        language.t('explorer.paste'),
        enabled: canPaste && entry.isDirectory && canChangeFile,
      ),
      _menuItem(
        _EntryAction.rename,
        language.t('explorer.rename'),
        enabled: canChangeFile,
      ),
      _menuItem(
        _EntryAction.delete,
        language.t('explorer.delete'),
        enabled: canChangeFile,
      ),
      _menuItem(_EntryAction.properties, language.t('explorer.properties')),
      if (isRemote)
        _menuItem(
          _EntryAction.permissions,
          language.t('permissions.title'),
          enabled: entry.exists,
        ),
      if (entry.connectionProfileId != null) const _ContextMenuSpec.divider(),
      if (entry.connectionProfileId != null)
        _menuItem(
          _EntryAction.editConnectionProfile,
          language.t('locations.profile.edit'),
        ),
      if (entry.connectionProfileId != null)
        _menuItem(
          _EntryAction.deleteConnectionProfile,
          language.t('locations.profile.delete'),
        ),
      _menuItem(
        _EntryAction.send,
        language.t('explorer.send'),
        enabled: entry.exists && !isVirtual && !isProfileLocation,
      ),
      if (!entry.isDirectory) const _ContextMenuSpec.divider(),
      if (!entry.isDirectory &&
          {'.zip', '.rar', '.cbr', '.rev'}.contains(extension))
        _menuItem(
          _EntryAction.unzip,
          language.t('explorer.unzip'),
          enabled: canChangeFile,
        ),
      if (!entry.isDirectory && ocrCandidate)
        _menuItem(
          _EntryAction.ocrExtract,
          language.t('ocr.extract'),
          enabled: entry.exists,
        ),
      if (!entry.isDirectory && extension == '.swf')
        _menuItem(
          _EntryAction.openSwf,
          language.t('preview.swf.open'),
          enabled: entry.exists,
        ),
      if (!entry.isDirectory && !entry.isEncrypted)
        _menuItem(
          _EntryAction.encrypt,
          language.t('explorer.encrypt'),
          enabled: canChangeFile,
        ),
      if (!entry.isDirectory && entry.isEncrypted)
        _menuItem(
          _EntryAction.decrypt,
          language.t('decrypt.action'),
          enabled: canChangeFile,
        ),
      if (entry.isDirectory) const _ContextMenuSpec.divider(),
      if (entry.isDirectory)
        _menuItem(
          _EntryAction.folderSettings,
          language.t('folder.settings.title'),
          enabled: entry.exists,
        ),
      if (entry.isDirectory)
        _menuItem(
          _EntryAction.openAllImages,
          language.t('explorer.open.all.images'),
          enabled: entry.exists,
        ),
      if (entry.isDirectory)
        _menuItem(
          _EntryAction.openAllVideos,
          language.t('explorer.open.all.videos'),
          enabled: entry.exists,
        ),
      if (entry.isDirectory)
        _menuItem(
          _EntryAction.openAllAudio,
          language.t('explorer.open.all.audio'),
          enabled: entry.exists,
        ),
      if (entry.isDirectory) const _ContextMenuSpec.divider(),
      if (entry.isDirectory)
        _parentItem(
          _EntryAction.encryptMenu,
          language.t('explorer.encrypt.menu'),
          enabled: canChangeFile,
          children: _folderEncryptSubmenuSpecs(),
        ),
      if (entry.isDirectory)
        _parentItem(
          _EntryAction.decryptMenu,
          language.t('explorer.decrypt.menu'),
          enabled: entry.exists && !isProfileLocation,
          children: _folderDecryptSubmenuSpecs(),
        ),
      if (entry.isDirectory) const _ContextMenuSpec.divider(),
      if (entry.isDirectory)
        _parentItem(
          _EntryAction.useAs,
          language.t('explorer.use.as'),
          enabled: entry.exists,
          children: _useAsSubmenuSpecs(),
        ),
    ];
  }

  void _handleEntryAction(ExplorerEntry entry, _EntryAction action) {
    switch (action) {
      case _EntryAction.open:
        onEntry(entry);
      case _EntryAction.edit:
        onEntryAction(entry, action);
      case _EntryAction.create:
      case _EntryAction.openAs:
      case _EntryAction.encryptMenu:
      case _EntryAction.decryptMenu:
      case _EntryAction.useAs:
        return;
      case _EntryAction.createFolder:
      case _EntryAction.createPlain:
      case _EntryAction.createEncryptedPlain:
      case _EntryAction.createCsv:
      case _EntryAction.createEncryptedCsv:
      case _EntryAction.createImage:
      case _EntryAction.createEncryptedImage:
      case _EntryAction.openAsText:
      case _EntryAction.openAsImage:
      case _EntryAction.openAsAudio:
      case _EntryAction.openAsVideo:
      case _EntryAction.encrypt:
      case _EntryAction.decrypt:
      case _EntryAction.copy:
      case _EntryAction.cut:
      case _EntryAction.paste:
      case _EntryAction.delete:
      case _EntryAction.rename:
      case _EntryAction.properties:
      case _EntryAction.send:
      case _EntryAction.unzip:
      case _EntryAction.folderContainer:
      case _EntryAction.folderEncryptName:
      case _EntryAction.folderDecryptName:
      case _EntryAction.folderEncrypt:
      case _EntryAction.folderDecrypt:
      case _EntryAction.useAsGallery:
      case _EntryAction.useAsVideo:
      case _EntryAction.useAsMusic:
      case _EntryAction.useAsMultimedia:
      case _EntryAction.folderSettings:
      case _EntryAction.openAllImages:
      case _EntryAction.openAllVideos:
      case _EntryAction.openAllAudio:
      case _EntryAction.permissions:
      case _EntryAction.ocrExtract:
      case _EntryAction.openSwf:
      case _EntryAction.downloadUrl:
      case _EntryAction.editConnectionProfile:
      case _EntryAction.deleteConnectionProfile:
        onEntryAction(entry, action);
      case _EntryAction.addFavorite:
      case _EntryAction.removeFavorite:
        onToggleFavorite(entry);
      case _EntryAction.removeRecent:
        onRemoveRecent(entry.path);
      case _EntryAction.selectAll:
      case _EntryAction.clearSelection:
      case _EntryAction.zipSelected:
        onEntryAction(entry, action);
    }
  }

  IconData _icon(ExplorerEntry entry) => entry.isNavigationEntry
      ? Icons.more_horiz
      : switch (entry.kind) {
          ExplorerEntryKind.directory => Icons.folder,
          ExplorerEntryKind.encryptedFile => Icons.lock_outline,
          ExplorerEntryKind.folderMeta => Icons.description_outlined,
          ExplorerEntryKind.file => Icons.insert_drive_file_outlined,
          ExplorerEntryKind.unknown => Icons.help_outline,
        };

  Color? _color(ExplorerEntry entry) => switch (entry.kind) {
        _ when entry.connectionStatus == ExplorerConnectionStatus.available =>
          const Color(0xFF2B7A4B),
        _ when entry.connectionStatus == ExplorerConnectionStatus.unavailable =>
          const Color(0xFFB42318),
        ExplorerEntryKind.directory => const Color(0xFFD29522),
        ExplorerEntryKind.encryptedFile => const Color(0xFF0F4C81),
        ExplorerEntryKind.folderMeta => const Color(0xFF42617D),
        _ => null,
      };

  Color? _connectionTextColor(ExplorerEntry entry) =>
      switch (entry.connectionStatus) {
        ExplorerConnectionStatus.available => const Color(0xFF2B7A4B),
        ExplorerConnectionStatus.unavailable => const Color(0xFFB42318),
        ExplorerConnectionStatus.none => null,
      };

  String _subtitle(ExplorerEntry entry) {
    final connection = switch (entry.connectionStatus) {
      ExplorerConnectionStatus.available =>
        language.t('locations.connection.available'),
      ExplorerConnectionStatus.unavailable =>
        '${language.t('locations.connection.unavailable')}${entry.connectionMessage == null ? '' : ': ${entry.connectionMessage}'}',
      ExplorerConnectionStatus.none => null,
    };
    final details = '${_size(entry)} - ${_date(entry.modifiedAt)}';
    return connection == null ? details : '$connection - $details';
  }

  String _size(ExplorerEntry entry) {
    if (entry.isDirectory) return language.t('explorer.folder');
    final size = entry.sizeBytes;
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  String _date(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

class _EntryLeadingThumbnail extends StatelessWidget {
  const _EntryLeadingThumbnail({
    required this.entry,
    required this.icon,
    required this.size,
    required this.showVideoThumbnails,
    required this.animateVideoThumbnails,
    required this.showAudioArtwork,
    required this.previewLoader,
    this.color,
  });

  final ExplorerEntry entry;
  final IconData icon;
  final Color? color;
  final double size;
  final bool showVideoThumbnails;
  final bool animateVideoThumbnails;
  final bool showAudioArtwork;
  final Future<FilePreview> Function(ExplorerEntry) previewLoader;

  @override
  Widget build(BuildContext context) {
    if (entry.isDirectory || entry.isNavigationEntry) {
      return Icon(icon, color: color, size: size);
    }
    final kindByName = FileViewerService.kindForName(entry.name);
    final kindByPath = FileViewerService.kindForName(entry.path);
    final kind =
        kindByName == FileContentKind.unknown ? kindByPath : kindByName;
    final boxSize = math.max(30.0, size + 8);

    if (kind == FileContentKind.image) {
      if (!entry.isEncrypted &&
          !entry.path.startsWith('zip://') &&
          !entry.path.startsWith('rar://')) {
        return _ThumbBox(
          size: boxSize,
          child: Image.file(
            File(entry.path),
            fit: BoxFit.cover,
            cacheWidth: (boxSize * MediaQuery.devicePixelRatioOf(context))
                .round()
                .clamp(48, 256),
            errorBuilder: (_, __, ___) => Icon(icon, color: color, size: size),
          ),
        );
      }
      return _PreviewThumb(
        entry: entry,
        size: boxSize,
        previewLoader: previewLoader,
        fallback: Icon(icon, color: color, size: size),
      );
    }

    if (kind == FileContentKind.audio && showAudioArtwork) {
      return FutureBuilder<FilePreview>(
        future: entry.isEncrypted ||
                entry.path.startsWith('zip://') ||
                entry.path.startsWith('rar://')
            ? previewLoader(entry)
            : null,
        builder: (context, snapshot) {
          final preview = snapshot.data;
          return FutureBuilder<Uint8List?>(
            future: MediaArtworkService.audioArtwork(
              path: preview == null ? entry.path : null,
              bytes: preview?.bytes == null
                  ? null
                  : Uint8List.fromList(preview!.bytes!),
            ),
            builder: (context, art) {
              final bytes = art.data;
              if (bytes == null || bytes.isEmpty) {
                return Icon(Icons.audiotrack_outlined,
                    color: color, size: size);
              }
              return _ThumbBox(
                size: boxSize,
                child: Image.memory(bytes, fit: BoxFit.cover),
              );
            },
          );
        },
      );
    }

    if (kind == FileContentKind.video && showVideoThumbnails) {
      return FutureBuilder<Uint8List?>(
        future: entry.isEncrypted ||
                entry.path.startsWith('zip://') ||
                entry.path.startsWith('rar://')
            ? Future<Uint8List?>.value(null)
            : MediaArtworkService.videoThumbnail(entry.path),
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (bytes == null || bytes.isEmpty) {
            return Icon(Icons.movie_outlined, color: color, size: size);
          }
          return _ThumbBox(
            size: boxSize,
            child: Stack(fit: StackFit.expand, children: [
              Image.memory(bytes, fit: BoxFit.cover),
              if (animateVideoThumbnails)
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: .18, end: .72),
                  duration: const Duration(seconds: 2),
                  builder: (context, value, child) => Align(
                    alignment: Alignment(value * 2 - 1, .85),
                    child: Container(
                      width: 8,
                      height: 3,
                      color: Colors.white.withValues(alpha: .85),
                    ),
                  ),
                ),
              const Center(
                child: Icon(Icons.play_circle_fill,
                    color: Colors.white70, size: 18),
              ),
            ]),
          );
        },
      );
    }
    return Icon(icon, color: color, size: size);
  }
}

class _PreviewThumb extends StatelessWidget {
  const _PreviewThumb({
    required this.entry,
    required this.size,
    required this.previewLoader,
    required this.fallback,
  });

  final ExplorerEntry entry;
  final double size;
  final Future<FilePreview> Function(ExplorerEntry) previewLoader;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<FilePreview>(
      future: previewLoader(entry),
      builder: (context, snapshot) {
        final preview = snapshot.data;
        final bytes = preview?.bytes;
        if (bytes == null || bytes.isEmpty) return fallback;
        return _ThumbBox(
          size: size,
          child: Image.memory(Uint8List.fromList(bytes), fit: BoxFit.cover),
        );
      },
    );
  }
}

class _ThumbBox extends StatelessWidget {
  const _ThumbBox({required this.size, required this.child});

  final double size;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(7),
      child: SizedBox(width: size, height: size, child: child),
    );
  }
}

class _SelectionToolbar extends StatelessWidget {
  const _SelectionToolbar({
    required this.language,
    required this.selectedCount,
    required this.onSelectAll,
    required this.onClear,
    required this.onAction,
  });

  final AppLanguage language;
  final int selectedCount;
  final VoidCallback onSelectAll;
  final VoidCallback onClear;
  final Future<void> Function(_EntryAction) onAction;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(children: [
          IconButton(
            onPressed: onClear,
            icon: const Icon(Icons.close),
            tooltip: language.t('selection.clear'),
          ),
          Expanded(
            child: Text(
              '${language.t('selection.count')}: $selectedCount',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          TextButton.icon(
            onPressed: onSelectAll,
            icon: const Icon(Icons.select_all),
            label: Text(language.t('selection.all')),
          ),
          PopupMenuButton<_EntryAction>(
            icon: const Icon(Icons.more_vert),
            onSelected: (action) => unawaited(onAction(action)),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: _EntryAction.copy,
                child: Text(language.t('explorer.copy')),
              ),
              PopupMenuItem(
                value: _EntryAction.cut,
                child: Text(language.t('explorer.cut')),
              ),
              PopupMenuItem(
                value: _EntryAction.delete,
                child: Text(language.t('explorer.delete')),
              ),
              PopupMenuItem(
                value: _EntryAction.zipSelected,
                child: Text(language.t('selection.zip')),
              ),
              PopupMenuItem(
                value: _EntryAction.clearSelection,
                child: Text(language.t('selection.clear')),
              ),
            ],
          ),
        ]),
      ),
    );
  }
}

class _EmptyExplorerArea extends StatelessWidget {
  const _EmptyExplorerArea({
    required this.language,
    required this.currentPath,
    required this.canPaste,
    required this.ytDlpEnabled,
    required this.onAction,
    required this.child,
  });

  final AppLanguage language;
  final String? currentPath;
  final bool canPaste;
  final bool ytDlpEnabled;
  final Future<void> Function(String, _EntryAction) onAction;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: (details) =>
          _showMenu(context, details.globalPosition),
      onLongPressStart: (details) => _showMenu(context, details.globalPosition),
      child: child,
    );
  }

  Future<void> _showMenu(BuildContext context, Offset? position) async {
    final path = currentPath;
    if (path == null) return;
    final selected = await _showCascadingContextMenu(
      context: context,
      position: position,
      items: [
        _ContextMenuSpec(
          action: _EntryAction.paste,
          label: language.t('explorer.paste'),
          enabled: canPaste,
        ),
        const _ContextMenuSpec.divider(),
        _ContextMenuSpec(
          action: _EntryAction.create,
          label: language.t('explorer.create'),
          children: _createSubmenuSpecs(),
        ),
        if (ytDlpEnabled) const _ContextMenuSpec.divider(),
        if (ytDlpEnabled)
          _ContextMenuSpec(
            action: _EntryAction.downloadUrl,
            label: language.t('plugin.ytdlp.download.url'),
          ),
      ],
    );
    if (selected != null && selected != _EntryAction.create) {
      await onAction(path, selected);
    }
  }

  List<_ContextMenuSpec> _createSubmenuSpecs() => [
        _ContextMenuSpec(
          action: _EntryAction.createFolder,
          label: language.t('create.folder'),
        ),
        _ContextMenuSpec(
          action: _EntryAction.createPlain,
          label: language.t('create.plain'),
        ),
        _ContextMenuSpec(
          action: _EntryAction.createEncryptedPlain,
          label: language.t('create.encrypted.plain'),
        ),
        _ContextMenuSpec(
          action: _EntryAction.createCsv,
          label: language.t('create.csv'),
        ),
        _ContextMenuSpec(
          action: _EntryAction.createEncryptedCsv,
          label: language.t('create.encrypted.csv'),
        ),
        _ContextMenuSpec(
          action: _EntryAction.createImage,
          label: language.t('create.image'),
        ),
        _ContextMenuSpec(
          action: _EntryAction.createEncryptedImage,
          label: language.t('create.encrypted.image'),
        ),
      ];
}

class _PreviewPane extends StatelessWidget {
  const _PreviewPane({
    required this.language,
    required this.entry,
    required this.preview,
    required this.mediaPlaylist,
    required this.imagePlaylist,
    required this.flashPlaylist,
    required this.mediaResumePositions,
    required this.visible,
    required this.onTogglePreview,
    required this.onOpenPassword,
    required this.onOpenExternal,
    required this.onPreviewWindow,
    required this.onEditPreview,
    required this.onReadPreview,
    required this.allowMiniDock,
    required this.onEntryAction,
    required this.onImageNavigate,
    required this.onFlashNavigate,
    required this.onRememberMediaPosition,
  });

  final AppLanguage language;
  final ExplorerEntry? entry;
  final Future<FilePreview>? preview;
  final List<MediaPreviewItem> mediaPlaylist;
  final List<MediaPreviewItem> imagePlaylist;
  final List<MediaPreviewItem> flashPlaylist;
  final Map<String, int> mediaResumePositions;
  final bool visible;
  final VoidCallback onTogglePreview;
  final VoidCallback onOpenPassword;
  final ValueChanged<FilePreview> onOpenExternal;
  final ValueChanged<FilePreview> onPreviewWindow;
  final ValueChanged<FilePreview> onEditPreview;
  final ValueChanged<FilePreview> onReadPreview;
  final bool allowMiniDock;
  final Future<void> Function(ExplorerEntry, _EntryAction) onEntryAction;
  final Future<FilePreview?> Function(int delta) onImageNavigate;
  final Future<FilePreview?> Function(int delta) onFlashNavigate;
  final Future<void> Function(String key, Duration position)
      onRememberMediaPosition;

  @override
  Widget build(BuildContext context) {
    if (!visible) {
      return const SizedBox.shrink();
    }
    if (entry == null || preview == null) {
      return Center(child: Text(language.t('preview.choose.file')));
    }
    return FutureBuilder<FilePreview>(
      future: preview,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final p = snap.data!;
        return Stack(children: [
          Positioned.fill(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(18),
              child: _PreviewContent(
                preview: p,
                language: language,
                mediaPlaylist: mediaPlaylist,
                imagePlaylist: imagePlaylist,
                flashPlaylist: flashPlaylist,
                mediaResumePositions: mediaResumePositions,
                allowMiniDock: allowMiniDock,
                onRememberMediaPosition: onRememberMediaPosition,
                onImageNavigate: (delta) async {
                  await onImageNavigate(delta);
                },
                onFlashNavigate: (delta) async {
                  await onFlashNavigate(delta);
                },
              ),
            ),
          ),
          Positioned(
            right: 8,
            top: 8,
            child: Material(
              color:
                  Theme.of(context).colorScheme.surface.withValues(alpha: .85),
              borderRadius: BorderRadius.circular(18),
              child: PopupMenuButton<_PreviewAction>(
                icon: const Icon(Icons.more_vert),
                onSelected: (action) {
                  switch (action) {
                    case _PreviewAction.password:
                      onOpenPassword();
                    case _PreviewAction.window:
                      onPreviewWindow(p);
                    case _PreviewAction.edit:
                      onEditPreview(p);
                    case _PreviewAction.speak:
                      onReadPreview(p);
                    case _PreviewAction.ocrExtract:
                      onEntryAction(entry!, _EntryAction.ocrExtract);
                    case _PreviewAction.rotateVideoLeft:
                    case _PreviewAction.rotateVideoRight:
                      onPreviewWindow(p);
                    case _PreviewAction.external:
                      onOpenExternal(p);
                    case _PreviewAction.copy:
                      onEntryAction(entry!, _EntryAction.copy);
                    case _PreviewAction.cut:
                      onEntryAction(entry!, _EntryAction.cut);
                    case _PreviewAction.delete:
                      onEntryAction(entry!, _EntryAction.delete);
                    case _PreviewAction.properties:
                      onEntryAction(entry!, _EntryAction.properties);
                    case _PreviewAction.hide:
                      onTogglePreview();
                  }
                },
                itemBuilder: (_) => [
                  if (entry!.isEncrypted)
                    PopupMenuItem(
                      value: _PreviewAction.password,
                      child: Text(language.t('preview.open.password')),
                    ),
                  PopupMenuItem(
                    value: _PreviewAction.window,
                    child: Text(language.t('preview.window')),
                  ),
                  if (_isEditablePreview(p))
                    PopupMenuItem(
                      value: _PreviewAction.edit,
                      child: Text(language.t('editor.open')),
                    ),
                  if ((p.text ?? '').trim().isNotEmpty)
                    PopupMenuItem(
                      value: _PreviewAction.speak,
                      child: Text(language.t('preview.speak')),
                    ),
                  if (_canOcrPreview(p))
                    PopupMenuItem(
                      value: _PreviewAction.ocrExtract,
                      child: Text(language.t('ocr.extract')),
                    ),
                  PopupMenuItem(
                    value: _PreviewAction.external,
                    child: Text(language.t('preview.external')),
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: _PreviewAction.copy,
                    child: Text(language.t('explorer.copy')),
                  ),
                  PopupMenuItem(
                    value: _PreviewAction.cut,
                    child: Text(language.t('explorer.cut')),
                  ),
                  PopupMenuItem(
                    value: _PreviewAction.delete,
                    child: Text(language.t('explorer.delete')),
                  ),
                  PopupMenuItem(
                    value: _PreviewAction.properties,
                    child: Text(language.t('explorer.properties')),
                  ),
                  PopupMenuItem(
                    value: _PreviewAction.hide,
                    child: Text(language.t('preview.hide')),
                  ),
                ],
              ),
            ),
          ),
        ]);
      },
    );
  }
}

class _PreviewContent extends StatelessWidget {
  const _PreviewContent({
    required this.preview,
    required this.language,
    this.mediaPlaylist = const [],
    this.imagePlaylist = const [],
    this.flashPlaylist = const [],
    this.onImageNavigate,
    this.onFlashNavigate,
    this.mediaResumePositions = const <String, int>{},
    this.onRememberMediaPosition,
    this.fillAvailable = false,
    this.allowMiniDock = true,
    this.videoRotationTurns = 0,
  });

  final FilePreview preview;
  final AppLanguage language;
  final List<MediaPreviewItem> mediaPlaylist;
  final List<MediaPreviewItem> imagePlaylist;
  final List<MediaPreviewItem> flashPlaylist;
  final Future<void> Function(int delta)? onImageNavigate;
  final Future<void> Function(int delta)? onFlashNavigate;
  final Map<String, int> mediaResumePositions;
  final Future<void> Function(String key, Duration position)?
      onRememberMediaPosition;
  final bool fillAvailable;
  final bool allowMiniDock;
  final int videoRotationTurns;

  @override
  Widget build(BuildContext context) {
    if (preview.contentKind == FileContentKind.image && preview.bytes != null) {
      return _ImagePreviewNavigator(
        preview: preview,
        imagePlaylist: imagePlaylist,
        onNavigate: onImageNavigate,
        fillAvailable: fillAvailable,
      );
    }

    if (preview.contentKind == FileContentKind.video ||
        preview.contentKind == FileContentKind.audio) {
      final playlist = mediaPlaylist.isEmpty
          ? [
              MediaPreviewItem(
                title: preview.title,
                kind: preview.contentKind,
                path: preview.decrypted ? null : preview.sourcePath,
                resumeKey: preview.sourcePath,
                bytes: preview.decrypted && preview.bytes != null
                    ? Uint8List.fromList(preview.bytes!)
                    : null,
                encrypted: preview.decrypted,
              ),
            ]
          : mediaPlaylist;
      return _MediaPreviewPlayer(
        preview: preview,
        playlist: playlist,
        language: language,
        resumePositions: mediaResumePositions,
        onRememberPosition: onRememberMediaPosition,
        allowMiniDock: allowMiniDock,
        fillAvailable: fillAvailable,
        videoRotationTurns: videoRotationTurns,
      );
    }

    if (preview.contentKind == FileContentKind.html) {
      return _HtmlPreview(preview: preview, language: language);
    }

    if (preview.contentKind == FileContentKind.flash) {
      return _SwfPreview(
        preview: preview,
        language: language,
        flashPlaylist: flashPlaylist,
        onNavigate: onFlashNavigate,
      );
    }

    if (preview.contentKind == FileContentKind.document &&
        FileViewerService.extensionForName(preview.title) == '.pdf') {
      return _PdfPreview(preview: preview, language: language);
    }

    if (preview.contentKind == FileContentKind.ebook &&
        (preview.text ?? '').trim().isNotEmpty) {
      return _EbookPreview(preview: preview, language: language);
    }

    if (preview.text != null && preview.text!.isNotEmpty) {
      final extension = FileViewerService.extensionForName(preview.title);
      if (extension == '.csv' || extension == '.tsv') {
        return _CsvPreview(
          preview: preview,
          language: language,
          initialDelimiter: extension == '.tsv' ? '\t' : null,
        );
      }
      return _CodePreview(text: preview.text!, fileName: preview.title);
    }

    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(preview.subtitle),
      ),
    );
  }
}

bool _isVirtualPreviewPath(String path) =>
    path.startsWith('remote://') ||
    path.startsWith('torrent://') ||
    path.startsWith('zip://') ||
    path.startsWith('rar://');

class _PdfPreview extends StatelessWidget {
  const _PdfPreview({required this.preview, required this.language});

  final FilePreview preview;
  final AppLanguage language;

  @override
  Widget build(BuildContext context) {
    final bytes = preview.bytes;
    final sourcePath = preview.sourcePath;
    final viewer = bytes != null && bytes.isNotEmpty
        ? syncfusion_pdfviewer.SfPdfViewer.memory(Uint8List.fromList(bytes))
        : sourcePath != null &&
                sourcePath.isNotEmpty &&
                !_isVirtualPreviewPath(sourcePath) &&
                File(sourcePath).existsSync()
            ? syncfusion_pdfviewer.SfPdfViewer.file(File(sourcePath))
            : null;
    if (viewer == null) {
      return Card(
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: SelectableText(
            preview.text?.trim().isNotEmpty == true
                ? preview.text!
                : language.t('pdf.preview.unavailable'),
          ),
        ),
      );
    }
    return Card(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: math.max(520, MediaQuery.sizeOf(context).height * 0.72),
        child: viewer,
      ),
    );
  }
}

class _EbookPreview extends StatefulWidget {
  const _EbookPreview({required this.preview, required this.language});

  final FilePreview preview;
  final AppLanguage language;

  @override
  State<_EbookPreview> createState() => _EbookPreviewState();
}

class _EbookPreviewState extends State<_EbookPreview> {
  late final PageController _controller;
  late List<String> _pages;
  var _page = 0;

  @override
  void initState() {
    super.initState();
    _controller = PageController();
    _pages = _paginate(widget.preview.text ?? '');
  }

  @override
  void didUpdateWidget(covariant _EbookPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preview.text != widget.preview.text ||
        oldWidget.preview.title != widget.preview.title) {
      _pages = _paginate(widget.preview.text ?? '');
      _page = 0;
      _controller.jumpToPage(0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_pages.isEmpty) {
      return Center(child: Text(widget.language.t('ebook.empty')));
    }
    return Card(
      elevation: 0,
      color: const Color(0xFFFFFBF1),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
          child: Row(children: [
            const Icon(Icons.menu_book_outlined),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.preview.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Text('${_page + 1}/${_pages.length}'),
          ]),
        ),
        const Divider(height: 24),
        SizedBox(
          height: math.max(520, MediaQuery.sizeOf(context).height * 0.7),
          child: PageView.builder(
            controller: _controller,
            onPageChanged: (value) => setState(() => _page = value),
            itemCount: _pages.length,
            itemBuilder: (context, index) => SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
              child: Align(
                alignment: Alignment.topLeft,
                child: SelectableText(
                  _pages[index],
                  textAlign: TextAlign.left,
                  style: const TextStyle(
                    fontSize: 18,
                    height: 1.55,
                    color: Color(0xFF1F2933),
                  ),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  List<String> _paginate(String raw) {
    final text = FileViewerService.normalizeReadableText(raw);
    if (text.isEmpty) return const <String>[];
    final paragraphs = text
        .split(RegExp(r'\n{2,}|(?<=\.)\s+(?=[A-Z\u0410-\u042F\u0401])'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty);
    final pages = <String>[];
    final buffer = StringBuffer();
    for (final paragraph in paragraphs) {
      if (buffer.length + paragraph.length > 2600 && buffer.isNotEmpty) {
        pages.add(buffer.toString().trim());
        buffer.clear();
      }
      if (buffer.isNotEmpty) buffer.write('\n\n');
      buffer.write(paragraph);
    }
    if (buffer.isNotEmpty) pages.add(buffer.toString().trim());
    return pages;
  }
}

class _EmbeddedBrowserView extends StatefulWidget {
  const _EmbeddedBrowserView({
    required this.sessionFuture,
    required this.language,
    required this.fallback,
  });

  final Future<EmbeddedWebSession> sessionFuture;
  final AppLanguage language;
  final Widget fallback;

  @override
  State<_EmbeddedBrowserView> createState() => _EmbeddedBrowserViewState();
}

class _EmbeddedBrowserViewState extends State<_EmbeddedBrowserView> {
  EmbeddedWebSession? _session;
  Future<void>? _controllerFuture;
  windows_webview.WebviewController? _windowsController;
  android_webview.WebViewController? _androidController;

  @override
  void initState() {
    super.initState();
    _controllerFuture = _initialize();
  }

  @override
  void didUpdateWidget(covariant _EmbeddedBrowserView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionFuture != widget.sessionFuture) {
      unawaited(_session?.close());
      _session = null;
      _windowsController?.dispose();
      _windowsController = null;
      _androidController = null;
      _controllerFuture = _initialize();
    }
  }

  @override
  void dispose() {
    unawaited(_session?.close());
    _windowsController?.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    final session = await widget.sessionFuture;
    if (!mounted) {
      await session.close();
      return;
    }
    _session = session;
    if (Platform.isWindows) {
      final version =
          await windows_webview.WebviewController.getWebViewVersion();
      if (version == null || version.trim().isEmpty) {
        throw StateError(widget.language.t('preview.webview2.missing'));
      }
      final controller = windows_webview.WebviewController();
      await controller.initialize();
      await controller.setPopupWindowPolicy(
        windows_webview.WebviewPopupWindowPolicy.sameWindow,
      );
      await controller.loadUrl(session.uri.toString());
      _windowsController = controller;
      return;
    }
    if (Platform.isAndroid) {
      final controller = android_webview.WebViewController()
        ..setJavaScriptMode(android_webview.JavaScriptMode.unrestricted)
        ..setBackgroundColor(Colors.transparent)
        ..setNavigationDelegate(android_webview.NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri == null) return android_webview.NavigationDecision.prevent;
            if (uri.host == '127.0.0.1' || uri.host == 'localhost') {
              return android_webview.NavigationDecision.navigate;
            }
            unawaited(PlatformServices.openExternal(request.url));
            return android_webview.NavigationDecision.prevent;
          },
        ));
      await controller.loadRequest(session.uri);
      _androidController = controller;
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows && !Platform.isAndroid) {
      return widget.fallback;
    }
    return FutureBuilder<void>(
      future: _controllerFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Card(
            elevation: 0,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                '${widget.language.t('preview.browser.error')}\n${snapshot.error}',
              ),
            ),
          );
        }
        if (Platform.isWindows && _windowsController != null) {
          return windows_webview.Webview(_windowsController!);
        }
        if (Platform.isAndroid && _androidController != null) {
          return android_webview.WebViewWidget(controller: _androidController!);
        }
        return widget.fallback;
      },
    );
  }
}

class _HtmlPreview extends StatefulWidget {
  const _HtmlPreview({required this.preview, required this.language});

  final FilePreview preview;
  final AppLanguage language;

  @override
  State<_HtmlPreview> createState() => _HtmlPreviewState();
}

class _HtmlPreviewState extends State<_HtmlPreview> {
  late Future<EmbeddedWebSession> _sessionFuture;

  @override
  void initState() {
    super.initState();
    _sessionFuture = _createSession();
  }

  @override
  void didUpdateWidget(covariant _HtmlPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preview.sourcePath != widget.preview.sourcePath ||
        oldWidget.preview.title != widget.preview.title ||
        oldWidget.preview.text != widget.preview.text ||
        oldWidget.preview.bytes?.length != widget.preview.bytes?.length) {
      _sessionFuture = _createSession();
    }
  }

  Future<EmbeddedWebSession> _createSession() {
    final html = _html;
    return PlatformServices.startHtmlSession(
      title: widget.preview.title,
      html: html.isEmpty ? '<p>${widget.preview.subtitle}</p>' : html,
      sourcePath: _canUseLocalAssets(widget.preview.sourcePath)
          ? widget.preview.sourcePath
          : null,
    );
  }

  String get _html => widget.preview.bytes == null
      ? (widget.preview.text ?? '')
      : FileViewerService.bytesToText(widget.preview.bytes!);

  @override
  Widget build(BuildContext context) {
    final html = _html;
    return Card(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.all(10),
          color: const Color(0xFFEAF1F8),
          child: Row(children: [
            const Icon(Icons.public),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.preview.sourcePath ?? widget.preview.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ]),
        ),
        Expanded(
          child: _EmbeddedBrowserView(
            language: widget.language,
            sessionFuture: _sessionFuture,
            fallback: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: flutter_html.Html(
                data: html.isEmpty ? '<p>${widget.preview.subtitle}</p>' : html,
                onLinkTap: (url, attributes, element) async {
                  final target = _resolveLink(url);
                  if (target == null) return;
                  try {
                    await PlatformServices.openExternal(target);
                  } catch (_) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(target)),
                    );
                  }
                },
              ),
            ),
          ),
        ),
      ]),
    );
  }

  bool _canUseLocalAssets(String? sourcePath) {
    if (sourcePath == null || widget.preview.decrypted) return false;
    final extension = FileViewerService.extensionForName(sourcePath);
    if (!FileViewerService.htmlExtensions.contains(extension)) return false;
    return !sourcePath.startsWith('zip://') &&
        !sourcePath.startsWith('rar://') &&
        !sourcePath.startsWith('remote://') &&
        !sourcePath.startsWith('torrent://') &&
        !sourcePath.startsWith('http://') &&
        !sourcePath.startsWith('https://');
  }

  String? _resolveLink(String? url) {
    if (url == null || url.trim().isEmpty || url.startsWith('#')) return null;
    final value = url.trim();
    if (value.startsWith('http://') ||
        value.startsWith('https://') ||
        value.startsWith('mailto:')) {
      return value;
    }
    final source = widget.preview.sourcePath;
    if (source == null ||
        source.startsWith('zip://') ||
        source.startsWith('rar://') ||
        source.startsWith('remote://') ||
        source.startsWith('torrent://')) {
      return value;
    }
    final base = File(source).parent.path;
    return File('$base${Platform.pathSeparator}$value').absolute.path;
  }
}

class _SwfPreview extends StatefulWidget {
  const _SwfPreview({
    required this.preview,
    required this.language,
    this.flashPlaylist = const [],
    this.onNavigate,
  });

  final FilePreview preview;
  final AppLanguage language;
  final List<MediaPreviewItem> flashPlaylist;
  final Future<void> Function(int delta)? onNavigate;

  @override
  State<_SwfPreview> createState() => _SwfPreviewState();
}

class _SwfPreviewState extends State<_SwfPreview> {
  late Future<EmbeddedWebSession> _sessionFuture;

  @override
  void initState() {
    super.initState();
    _sessionFuture = _createSession();
  }

  @override
  void didUpdateWidget(covariant _SwfPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preview.sourcePath != widget.preview.sourcePath ||
        oldWidget.preview.title != widget.preview.title ||
        oldWidget.preview.bytes?.length != widget.preview.bytes?.length) {
      _sessionFuture = _createSession();
    }
  }

  Future<EmbeddedWebSession> _createSession() {
    return PlatformServices.startSwfRuffleSession(
      title: widget.preview.title,
      sourcePath: widget.preview.sourcePath,
      bytes: widget.preview.bytes,
    );
  }

  @override
  Widget build(BuildContext context) {
    final canNavigate = widget.onNavigate != null &&
        widget.flashPlaylist.length > 1 &&
        widget.preview.contentKind == FileContentKind.flash;
    return SizedBox(
      height: math.max(520, MediaQuery.sizeOf(context).height * 0.72),
      child: Stack(children: [
        Positioned.fill(
          child: _EmbeddedBrowserView(
            language: widget.language,
            sessionFuture: _sessionFuture,
            fallback: _buildFallback(context),
          ),
        ),
        Positioned(
          right: 10,
          top: 10,
          child: Material(
            elevation: 6,
            borderRadius: BorderRadius.circular(24),
            color: Theme.of(context).colorScheme.surface.withValues(alpha: .9),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                onPressed: canNavigate
                    ? () => unawaited(widget.onNavigate!(-1))
                    : null,
                icon: const Icon(Icons.chevron_left),
                tooltip: widget.language.t('media.previous'),
              ),
              IconButton(
                onPressed:
                    canNavigate ? () => unawaited(widget.onNavigate!(1)) : null,
                icon: const Icon(Icons.chevron_right),
                tooltip: widget.language.t('media.next'),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.touch_app_outlined),
                tooltip: widget.language.t('preview.swf.menu'),
                onSelected: (value) {
                  if (value == 'reload') {
                    setState(() => _sessionFuture = _createSession());
                  }
                  if (value == 'external') {
                    unawaited(PlatformServices.openSwfWithRuffle(
                      title: widget.preview.title,
                      sourcePath: widget.preview.sourcePath,
                      bytes: widget.preview.bytes,
                    ));
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'reload',
                    child: Text(widget.language.t('explorer.refresh')),
                  ),
                  PopupMenuItem(
                    value: 'external',
                    child: Text(widget.language.t('preview.swf.open')),
                  ),
                ],
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _buildFallback(BuildContext context) {
    return Center(
      child: Card(
        elevation: 0,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.extension_outlined, size: 48),
              const SizedBox(height: 12),
              Text(
                widget.language.t('preview.swf.title'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                widget.language.t('preview.swf.body'),
                textAlign: TextAlign.center,
              ),
              if (widget.preview.text != null &&
                  widget.preview.text!.isNotEmpty) ...[
                const SizedBox(height: 12),
                SelectableText(widget.preview.text!),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}

class _CsvPreview extends StatefulWidget {
  const _CsvPreview({
    required this.preview,
    required this.language,
    required this.initialDelimiter,
  });

  final FilePreview preview;
  final AppLanguage language;
  final String? initialDelimiter;

  @override
  State<_CsvPreview> createState() => _CsvPreviewState();
}

class _CsvPreviewState extends State<_CsvPreview> {
  late String _delimiter;
  var _tableMode = true;

  @override
  void initState() {
    super.initState();
    _delimiter =
        widget.initialDelimiter ?? _detectDelimiter(widget.preview.text!);
  }

  @override
  Widget build(BuildContext context) {
    final rows = _parseCsv(widget.preview.text!, _delimiter).take(200).toList();
    final columns = rows.isEmpty
        ? 0
        : rows.map((row) => row.length).reduce(math.max).clamp(1, 80).toInt();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<bool>(
              segments: [
                ButtonSegment(
                  value: true,
                  label: Text(widget.language.t('csv.view.table')),
                ),
                ButtonSegment(
                  value: false,
                  label: Text(widget.language.t('csv.view.raw')),
                ),
              ],
              selected: {_tableMode},
              onSelectionChanged: (value) =>
                  setState(() => _tableMode = value.first),
            ),
            DropdownButton<String>(
              value: _delimiter,
              items: [
                DropdownMenuItem(
                    value: ';',
                    child: Text(widget.language.t('csv.delimiter.semicolon'))),
                DropdownMenuItem(
                    value: ',',
                    child: Text(widget.language.t('csv.delimiter.comma'))),
                DropdownMenuItem(
                    value: '\t',
                    child: Text(widget.language.t('csv.delimiter.tab'))),
              ],
              onChanged: (value) => setState(() => _delimiter = value ?? ';'),
            ),
          ]),
      const SizedBox(height: 12),
      if (!_tableMode)
        _CodePreview(text: widget.preview.text!)
      else
        Card(
          elevation: 0,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: [
                for (var i = 0; i < columns; i++)
                  DataColumn(label: Text('${i + 1}')),
              ],
              rows: [
                for (final row in rows)
                  DataRow(cells: [
                    for (var i = 0; i < columns; i++)
                      DataCell(Text(i < row.length ? row[i] : '')),
                  ]),
              ],
            ),
          ),
        ),
    ]);
  }

  String _detectDelimiter(String text) {
    final firstLine = text.split(RegExp(r'\r?\n')).firstOrNull ?? '';
    final candidates = [';', ',', '\t'];
    candidates
        .sort((a, b) => _count(firstLine, b).compareTo(_count(firstLine, a)));
    return candidates.first;
  }

  int _count(String value, String char) => char == '\t'
      ? '\t'.allMatches(value).length
      : char.allMatches(value).length;

  List<List<String>> _parseCsv(String text, String delimiter) {
    final rows = <List<String>>[];
    final row = <String>[];
    final cell = StringBuffer();
    var quoted = false;
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (char == '"') {
        if (quoted && i + 1 < text.length && text[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = !quoted;
        }
      } else if (!quoted && char == delimiter) {
        row.add(cell.toString());
        cell.clear();
      } else if (!quoted && (char == '\n' || char == '\r')) {
        if (char == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
        row.add(cell.toString());
        cell.clear();
        rows.add(List<String>.of(row));
        row.clear();
      } else {
        cell.write(char);
      }
    }
    if (cell.isNotEmpty || row.isNotEmpty) {
      row.add(cell.toString());
      rows.add(row);
    }
    return rows;
  }
}

class _CodePreview extends StatelessWidget {
  const _CodePreview({required this.text, this.fileName});

  final String text;
  final String? fileName;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      color: Color(0xFFE8F0F7),
      fontFamily: 'Consolas',
      fontSize: 13,
      height: 1.35,
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF101923),
        borderRadius: BorderRadius.circular(16),
      ),
      child: SelectableText.rich(
        TextSpan(
          style: style,
          children: _SyntaxHighlighter.highlight(
            text,
            fileName: fileName,
            baseStyle: style,
          ),
        ),
      ),
    );
  }
}

class _SyntaxHighlighter {
  _SyntaxHighlighter._();

  static final _token = RegExp(
    r'(/\*[\s\S]*?\*/|//[^\r\n]*|#[^\r\n]*|"(?:\\.|[^"\\])*"|'
    r"'(?:\\.|[^'\\])*'|\b\d+(?:\.\d+)?\b|[$@]?[A-Za-z_][A-Za-z0-9_#]*\b)",
    multiLine: true,
  );

  static const _languages = {
    '.c': 'cpp',
    '.cc': 'cpp',
    '.cpp': 'cpp',
    '.cxx': 'cpp',
    '.h': 'cpp',
    '.hpp': 'cpp',
    '.cs': 'csharp',
    '.py': 'python',
    '.pyw': 'python',
    '.kt': 'kotlin',
    '.kts': 'kotlin',
    '.cmd': 'cmd',
    '.bat': 'cmd',
    '.ps1': 'powershell',
    '.psm1': 'powershell',
    '.psd1': 'powershell',
    '.json': 'json',
    '.yaml': 'yaml',
    '.yml': 'yaml',
    '.xml': 'xml',
    '.html': 'html',
    '.htm': 'html',
    '.js': 'javascript',
    '.ts': 'javascript',
    '.dart': 'dart',
  };

  static const _keywords = {
    'cpp': {
      'alignas',
      'alignof',
      'auto',
      'bool',
      'break',
      'case',
      'catch',
      'class',
      'const',
      'constexpr',
      'continue',
      'default',
      'delete',
      'do',
      'double',
      'else',
      'enum',
      'explicit',
      'export',
      'extern',
      'false',
      'float',
      'for',
      'friend',
      'if',
      'inline',
      'int',
      'long',
      'namespace',
      'new',
      'noexcept',
      'nullptr',
      'operator',
      'private',
      'protected',
      'public',
      'return',
      'short',
      'sizeof',
      'static',
      'struct',
      'switch',
      'template',
      'this',
      'throw',
      'true',
      'try',
      'typedef',
      'typename',
      'using',
      'virtual',
      'void',
      'while',
    },
    'csharp': {
      'abstract',
      'async',
      'await',
      'base',
      'bool',
      'break',
      'case',
      'catch',
      'class',
      'const',
      'decimal',
      'default',
      'delegate',
      'do',
      'double',
      'else',
      'enum',
      'event',
      'false',
      'finally',
      'float',
      'for',
      'foreach',
      'if',
      'int',
      'interface',
      'internal',
      'is',
      'lock',
      'namespace',
      'new',
      'null',
      'object',
      'override',
      'private',
      'protected',
      'public',
      'readonly',
      'return',
      'sealed',
      'static',
      'string',
      'struct',
      'switch',
      'this',
      'throw',
      'true',
      'try',
      'using',
      'var',
      'virtual',
      'void',
      'while',
    },
    'python': {
      'and',
      'as',
      'assert',
      'async',
      'await',
      'break',
      'class',
      'continue',
      'def',
      'del',
      'elif',
      'else',
      'except',
      'False',
      'finally',
      'for',
      'from',
      'global',
      'if',
      'import',
      'in',
      'is',
      'lambda',
      'None',
      'nonlocal',
      'not',
      'or',
      'pass',
      'raise',
      'return',
      'True',
      'try',
      'while',
      'with',
      'yield',
    },
    'kotlin': {
      'as',
      'break',
      'class',
      'companion',
      'continue',
      'data',
      'do',
      'else',
      'false',
      'for',
      'fun',
      'if',
      'in',
      'interface',
      'is',
      'null',
      'object',
      'override',
      'package',
      'private',
      'protected',
      'public',
      'return',
      'sealed',
      'super',
      'this',
      'throw',
      'true',
      'try',
      'typealias',
      'val',
      'var',
      'when',
      'while',
    },
    'cmd': {
      'echo',
      'set',
      'if',
      'else',
      'for',
      'in',
      'do',
      'call',
      'goto',
      'exit',
      'rem',
      'shift',
      'start',
    },
    'powershell': {
      'begin',
      'break',
      'catch',
      'class',
      'continue',
      'data',
      'do',
      'dynamicparam',
      'else',
      'elseif',
      'end',
      'exit',
      'filter',
      'finally',
      'for',
      'foreach',
      'from',
      'function',
      'if',
      'in',
      'param',
      'process',
      'return',
      'switch',
      'throw',
      'trap',
      'try',
      'until',
      'using',
      'var',
      'while',
    },
    'dart': {
      'abstract',
      'async',
      'await',
      'break',
      'case',
      'catch',
      'class',
      'const',
      'continue',
      'default',
      'deferred',
      'do',
      'dynamic',
      'else',
      'enum',
      'export',
      'extends',
      'extension',
      'false',
      'final',
      'finally',
      'for',
      'if',
      'implements',
      'import',
      'in',
      'is',
      'late',
      'new',
      'null',
      'operator',
      'part',
      'return',
      'static',
      'super',
      'switch',
      'this',
      'throw',
      'true',
      'try',
      'typedef',
      'var',
      'void',
      'while',
      'with',
      'yield',
    },
  };

  static List<TextSpan> highlight(
    String text, {
    String? fileName,
    required TextStyle baseStyle,
  }) {
    final lang = _languageFor(fileName);
    if (lang == null) return [TextSpan(text: text)];
    final spans = <TextSpan>[];
    var offset = 0;
    for (final match in _token.allMatches(text)) {
      if (match.start > offset) {
        spans.add(TextSpan(text: text.substring(offset, match.start)));
      }
      final token = match.group(0)!;
      spans.add(TextSpan(text: token, style: _styleFor(token, lang)));
      offset = match.end;
    }
    if (offset < text.length) spans.add(TextSpan(text: text.substring(offset)));
    return spans;
  }

  static String? _languageFor(String? fileName) {
    if (fileName == null) return null;
    final extension = FileViewerService.extensionForName(fileName);
    return _languages[extension];
  }

  static TextStyle? _styleFor(String token, String lang) {
    if (token.startsWith('//') ||
        token.startsWith('/*') ||
        token.startsWith('#') ||
        token.toLowerCase().startsWith('rem ')) {
      return const TextStyle(color: Color(0xFF7DCB85));
    }
    if (token.startsWith('"') || token.startsWith("'")) {
      return const TextStyle(color: Color(0xFFFFD479));
    }
    if (RegExp(r'^\d').hasMatch(token)) {
      return const TextStyle(color: Color(0xFF9CDCFE));
    }
    final normalized = token.startsWith(r'$') || token.startsWith('@')
        ? token.substring(1)
        : token;
    final words = _keywords[lang] ?? const <String>{};
    if (words.contains(normalized) ||
        words.contains(normalized.toLowerCase())) {
      return const TextStyle(
        color: Color(0xFFB794F4),
        fontWeight: FontWeight.w700,
      );
    }
    if (token.startsWith(r'$')) {
      return const TextStyle(color: Color(0xFF80CBC4));
    }
    if (token.startsWith('@')) {
      return const TextStyle(color: Color(0xFFFFB86C));
    }
    return null;
  }
}

class _PathTextField extends StatelessWidget {
  const _PathTextField({
    required this.controller,
    required this.label,
    required this.pickDirectory,
    this.multiLine = false,
    this.helperText,
  });

  final TextEditingController controller;
  final String label;
  final bool pickDirectory;
  final bool multiLine;
  final String? helperText;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      minLines: multiLine ? 1 : null,
      maxLines: multiLine ? 4 : 1,
      decoration: InputDecoration(
        labelText: label,
        helperText: helperText,
        suffixIcon: IconButton(
          tooltip: label,
          icon: Icon(pickDirectory
              ? Icons.create_new_folder_outlined
              : Icons.file_open_outlined),
          onPressed: () => unawaited(_pick(context)),
        ),
      ),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => _InAppPathPickerDialog(
        pickDirectory: pickDirectory,
        title: label,
      ),
    );
    if (selected == null || selected.trim().isEmpty) return;
    if (multiLine && controller.text.trim().isNotEmpty) {
      controller.text = '${controller.text.trimRight()}\n${selected.trim()}';
    } else {
      controller.text = selected.trim();
    }
  }
}

class _SaveTextPathDialog extends StatefulWidget {
  const _SaveTextPathDialog({
    required this.language,
    required this.suggestedName,
  });

  final AppLanguage language;
  final String suggestedName;

  @override
  State<_SaveTextPathDialog> createState() => _SaveTextPathDialogState();
}

class _SaveTextPathDialogState extends State<_SaveTextPathDialog> {
  late final TextEditingController _directoryController;
  late final TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _directoryController = TextEditingController();
    _nameController = TextEditingController(text: widget.suggestedName);
  }

  @override
  void dispose() {
    _directoryController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.language.t('ocr.save.text')),
      content: SizedBox(
        width: 520,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _PathTextField(
            controller: _directoryController,
            label: widget.language.t('picker.title.folder'),
            pickDirectory: true,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              labelText: widget.language.t('explorer.name'),
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.language.t('common.cancel')),
        ),
        FilledButton(
          onPressed: () {
            final dir = _directoryController.text.trim();
            final name = _nameController.text.trim();
            if (dir.isEmpty || name.isEmpty) return;
            Navigator.pop(context,
                '${dir.replaceAll(RegExp(r'[\\/]+$'), '')}${Platform.pathSeparator}$name');
          },
          child: Text(widget.language.t('picker.select')),
        ),
      ],
    );
  }
}

class _InAppPathPickerDialog extends StatefulWidget {
  const _InAppPathPickerDialog({
    required this.pickDirectory,
    required this.title,
  });

  final bool pickDirectory;
  final String title;

  @override
  State<_InAppPathPickerDialog> createState() => _InAppPathPickerDialogState();
}

class _InAppPathPickerDialogState extends State<_InAppPathPickerDialog> {
  final _pathController = TextEditingController();
  final _locations = <_PickerLocation>[];
  var _entries = <FileSystemEntity>[];
  String? _selectedPath;
  String? _error;
  var _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLocations());
  }

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  Future<void> _loadLocations() async {
    final language = _pickerLanguage(context);
    final locations = <_PickerLocation>[];
    if (Platform.isWindows) {
      for (var code = 65; code <= 90; code++) {
        final letter = String.fromCharCode(code);
        final root = '$letter:\\';
        if (await Directory(root).exists()) {
          locations.add(
              _PickerLocation('${language.t('picker.drive')} $letter:', root));
        }
      }
    } else {
      locations.add(_PickerLocation(language.t('picker.filesystem.root'), '/'));
      final home = Platform.environment['HOME'];
      if (home != null && home.isNotEmpty && await Directory(home).exists()) {
        locations.add(_PickerLocation(language.t('picker.home'), home));
      }
      if (Platform.isAndroid) {
        for (final path in const [
          '/storage/emulated/0',
          '/sdcard',
          '/storage/self/primary',
        ]) {
          if (await Directory(path).exists()) {
            locations
                .add(_PickerLocation(language.t('picker.phone.storage'), path));
            break;
          }
        }
      }
    }
    try {
      final hidden = await AppPaths.hiddenVaultDirectory();
      locations.add(
          _PickerLocation(language.t('location.hidden.vault'), hidden.path));
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _locations
        ..clear()
        ..addAll(locations);
      _loading = false;
    });
    if (locations.isNotEmpty) {
      await _openPath(locations.first.path);
    }
  }

  Future<void> _openPath(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final directory = Directory(path);
      if (!await directory.exists()) {
        throw FileSystemException('Path is not available', path);
      }
      final entries = await directory
          .list(followLinks: false)
          .where((entity) => entity is Directory || !widget.pickDirectory)
          .toList();
      entries.sort((a, b) {
        final ad = a is Directory ? 0 : 1;
        final bd = b is Directory ? 0 : 1;
        if (ad != bd) return ad.compareTo(bd);
        return _pickerName(a.path).toLowerCase().compareTo(
              _pickerName(b.path).toLowerCase(),
            );
      });
      if (!mounted) return;
      setState(() {
        _selectedPath = widget.pickDirectory ? path : null;
        _pathController.text = path;
        _entries = entries;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$error';
        _entries = const [];
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final language = _pickerLanguage(context);
    final narrow = MediaQuery.sizeOf(context).width < 720;
    final locations = ListView(
      shrinkWrap: narrow,
      children: [
        for (final location in _locations)
          ListTile(
            dense: true,
            leading: const Icon(Icons.storage_outlined),
            title: Text(location.name),
            subtitle: Text(
              location.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => unawaited(_openPath(location.path)),
          ),
      ],
    );
    final files = _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
            ? Center(child: SelectableText(_error!))
            : ListView.builder(
                itemCount: _entries.length,
                itemBuilder: (context, index) {
                  final entity = _entries[index];
                  final isDir = entity is Directory;
                  final path = entity.path;
                  final selected = path == _selectedPath;
                  return ListTile(
                    selected: selected,
                    dense: true,
                    leading: Icon(isDir
                        ? Icons.folder_outlined
                        : Icons.insert_drive_file_outlined),
                    title: Text(_pickerName(path)),
                    subtitle: Text(
                      path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () {
                      if (isDir) {
                        unawaited(_openPath(path));
                      } else {
                        setState(() => _selectedPath = path);
                      }
                    },
                  );
                },
              );
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 860,
        height: 560,
        child: Column(children: [
          TextField(
            controller: _pathController,
            decoration: InputDecoration(
              labelText: language.t('common.path'),
              suffixIcon: IconButton(
                icon: const Icon(Icons.arrow_forward),
                onPressed: () => unawaited(_openPath(_pathController.text)),
              ),
            ),
            onSubmitted: (value) => unawaited(_openPath(value)),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: narrow
                ? Column(children: [
                    SizedBox(height: 150, child: locations),
                    const Divider(height: 1),
                    Expanded(child: files),
                  ])
                : Row(children: [
                    SizedBox(width: 260, child: locations),
                    const VerticalDivider(width: 1),
                    Expanded(child: files),
                  ]),
          ),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(language.t('common.cancel')),
        ),
        FilledButton(
          onPressed: _selectedPath == null
              ? null
              : () => Navigator.pop(context, _selectedPath),
          child: Text(language.t('picker.select')),
        ),
      ],
    );
  }
}

AppLanguage _pickerLanguage(BuildContext context) {
  final code = Localizations.localeOf(context).languageCode;
  return AppLanguage.builtIn(code == 'en' ? 'en' : 'ru');
}

class _PickerLocation {
  const _PickerLocation(this.name, this.path);

  final String name;
  final String path;
}

String _pickerName(String path) {
  final normalized = path.replaceAll('\\', '/');
  final trimmed = normalized.endsWith('/') && normalized.length > 1
      ? normalized.substring(0, normalized.length - 1)
      : normalized;
  final slash = trimmed.lastIndexOf('/');
  return slash == -1 ? trimmed : trimmed.substring(slash + 1);
}

class _ImagePreviewNavigator extends StatefulWidget {
  const _ImagePreviewNavigator({
    required this.preview,
    required this.imagePlaylist,
    required this.onNavigate,
    required this.fillAvailable,
  });

  final FilePreview preview;
  final List<MediaPreviewItem> imagePlaylist;
  final Future<void> Function(int delta)? onNavigate;
  final bool fillAvailable;

  @override
  State<_ImagePreviewNavigator> createState() => _ImagePreviewNavigatorState();
}

class _ImagePreviewNavigatorState extends State<_ImagePreviewNavigator> {
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(debugLabel: 'image-preview-navigator');
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  bool get _canNavigate =>
      widget.onNavigate != null && widget.imagePlaylist.length > 1;

  Future<void> _navigate(int delta) async {
    if (!_canNavigate) return;
    await widget.onNavigate!(delta);
  }

  @override
  Widget build(BuildContext context) {
    final image = SizedBox.expand(
      child: InteractiveViewer(
        minScale: 0.25,
        maxScale: 8,
        boundaryMargin: const EdgeInsets.all(2048),
        clipBehavior: Clip.none,
        child: Center(
          child: Image.memory(
            Uint8List.fromList(widget.preview.bytes!),
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
    final content = Focus(
      autofocus: true,
      focusNode: _focusNode,
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent || !_canNavigate) {
          return KeyEventResult.ignored;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          unawaited(_navigate(-1));
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          unawaited(_navigate(1));
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragEnd: (details) {
          if (!_canNavigate) return;
          final velocity = details.primaryVelocity ?? 0;
          if (velocity < -180) {
            unawaited(_navigate(1));
          } else if (velocity > 180) {
            unawaited(_navigate(-1));
          }
        },
        child: Stack(children: [
          Positioned.fill(child: image),
          if (_canNavigate) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton.filledTonal(
                onPressed: () => unawaited(_navigate(-1)),
                icon: const Icon(Icons.chevron_left),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: IconButton.filledTonal(
                onPressed: () => unawaited(_navigate(1)),
                icon: const Icon(Icons.chevron_right),
              ),
            ),
          ],
        ]),
      ),
    );
    if (widget.fillAvailable) {
      return SizedBox.expand(child: content);
    }
    final height = math.max(320.0, MediaQuery.sizeOf(context).height * .62);
    return SizedBox(
      height: height,
      child: content,
    );
  }
}

class _MediaPreviewPlayer extends StatefulWidget {
  const _MediaPreviewPlayer({
    required this.preview,
    required this.playlist,
    required this.language,
    required this.resumePositions,
    required this.onRememberPosition,
    required this.allowMiniDock,
    required this.fillAvailable,
    required this.videoRotationTurns,
  });

  final FilePreview preview;
  final List<MediaPreviewItem> playlist;
  final AppLanguage language;
  final Map<String, int> resumePositions;
  final Future<void> Function(String key, Duration position)?
      onRememberPosition;
  final bool allowMiniDock;
  final bool fillAvailable;
  final int videoRotationTurns;

  @override
  State<_MediaPreviewPlayer> createState() => _MediaPreviewPlayerState();
}

class _MediaPreviewPlayerState extends State<_MediaPreviewPlayer> {
  Player get _player => _sharedMediaSession.player;
  VideoController get _controller => _sharedMediaSession.controller;
  Future<void>? _openFuture;
  StreamSubscription<String>? _errorSubscription;
  var _shuffle = false;
  var _repeatOne = false;
  String? _error;
  String _playlistKey = '';

  @override
  void initState() {
    super.initState();
    _errorSubscription = _player.stream.error.listen((error) {
      if (mounted) setState(() => _error = error);
    });
    _playlistKey = _SharedMediaSession.keyFor(widget.preview, widget.playlist);
    _openFuture = _openPlaylist();
  }

  @override
  void didUpdateWidget(covariant _MediaPreviewPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextKey = _SharedMediaSession.keyFor(widget.preview, widget.playlist);
    if (nextKey != _playlistKey ||
        widget.preview.title != oldWidget.preview.title) {
      unawaited(_rememberCurrentPosition());
      _playlistKey = nextKey;
      _openFuture = _openPlaylist();
    }
  }

  @override
  void dispose() {
    unawaited(_rememberCurrentPosition());
    _errorSubscription?.cancel();
    super.dispose();
  }

  int _initialIndex() {
    final index = widget.playlist.indexWhere((item) =>
        item.title == widget.preview.title ||
        (widget.preview.sourcePath != null &&
            item.path == widget.preview.sourcePath));
    return index < 0 ? 0 : index;
  }

  Future<void> _openPlaylist() async {
    setState(() => _error = null);
    try {
      final wasAlreadyOpen =
          _sharedMediaSession.isSame(widget.preview, widget.playlist);
      final canAttachToActivePlaylist =
          _sharedMediaSession.isSamePlaylist(widget.playlist);
      if (!wasAlreadyOpen && canAttachToActivePlaylist) {
        _sharedMediaSession.attachToActivePlaylist(
          preview: widget.preview,
          playlist: widget.playlist,
          allowMiniDock: widget.allowMiniDock,
        );
        await _player.setPlaylistMode(
          _repeatOne ? PlaylistMode.single : PlaylistMode.loop,
        );
        await _player.setShuffle(_shuffle);
        return;
      }
      await _sharedMediaSession.open(
        preview: widget.preview,
        playlist: widget.playlist,
        language: widget.language,
        initialIndex: _initialIndex(),
        repeatOne: _repeatOne,
        shuffle: _shuffle,
        allowMiniDock: widget.allowMiniDock,
      );
      final initialItem = _itemAt(_initialIndex());
      final resumeMs = initialItem == null
          ? 0
          : widget.resumePositions[initialItem.resumeKey ?? ''] ?? 0;
      if (!wasAlreadyOpen && resumeMs > 1500) {
        await _player.seek(Duration(milliseconds: resumeMs));
      }
      await _player.setPlaylistMode(
        _repeatOne ? PlaylistMode.single : PlaylistMode.loop,
      );
      await _player.setShuffle(_shuffle);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _toggleShuffle() async {
    setState(() => _shuffle = !_shuffle);
    await _player.setShuffle(_shuffle);
  }

  Future<void> _toggleRepeatOne() async {
    setState(() => _repeatOne = !_repeatOne);
    await _player.setPlaylistMode(
      _repeatOne ? PlaylistMode.single : PlaylistMode.loop,
    );
  }

  MediaPreviewItem? _currentItem() => _itemAt(_player.state.playlist.index);

  MediaPreviewItem? _itemAt(int index) {
    if (widget.playlist.isEmpty) return null;
    final normalized = index.clamp(0, widget.playlist.length - 1).toInt();
    return widget.playlist[normalized];
  }

  Future<void> _rememberCurrentPosition() async {
    final callback = widget.onRememberPosition;
    if (callback == null) return;
    final item = _currentItem();
    final key = item?.resumeKey ?? item?.path;
    if (key == null || key.trim().isEmpty) return;
    final duration = _player.state.duration;
    final position = _player.state.position;
    final value = duration > Duration.zero &&
            duration - position < const Duration(seconds: 10)
        ? Duration.zero
        : position;
    await callback(key, value);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _openFuture,
      builder: (context, snapshot) {
        final loading = snapshot.connectionState != ConnectionState.done;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (loading)
              const LinearProgressIndicator(minHeight: 2)
            else
              const SizedBox(height: 2),
            if (_error != null)
              Card(
                color: const Color(0xFFFFF3E0),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text('${widget.language.t('media.error')}\n$_error'),
                ),
              )
            else if (widget.preview.contentKind == FileContentKind.video)
              if (widget.fillAvailable)
                Expanded(child: _buildVideoSurface())
              else
                _buildVideoSurface()
            else
              Card(
                color: const Color(0xFFEAF2F8),
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: Column(children: [
                    _AudioArtworkForCurrent(
                      player: _player,
                      items: widget.playlist,
                    ),
                    const SizedBox(height: 8),
                    StreamBuilder<Playlist>(
                      stream: _player.stream.playlist,
                      initialData: _player.state.playlist,
                      builder: (context, snapshot) {
                        final item = _currentItem();
                        return Text(
                          item?.title ?? widget.preview.title,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium,
                        );
                      },
                    ),
                    _AudioLyricsForCurrent(
                      player: _player,
                      items: widget.playlist,
                      language: widget.language,
                    ),
                    if (widget.preview.decrypted)
                      Text(widget.language.t('media.decrypted.memory')),
                  ]),
                ),
              ),
            const SizedBox(height: 12),
            _MediaTransportControls(
              player: _player,
              language: widget.language,
              shuffle: _shuffle,
              repeatOne: _repeatOne,
              onShuffle: _toggleShuffle,
              onRepeatOne: _toggleRepeatOne,
              onBeforeTrackChange: _rememberCurrentPosition,
            ),
            const SizedBox(height: 12),
            _MediaPlaylistView(
              player: _player,
              items: widget.playlist,
              language: widget.language,
              onBeforeTrackChange: _rememberCurrentPosition,
            ),
          ],
        );
      },
    );
  }

  Widget _buildVideoSurface() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: _AdaptiveVideoSurface(
        controller: _controller,
        quarterTurns: widget.videoRotationTurns,
        disableNativeFullscreen: widget.fillAvailable,
      ),
    );
  }
}

class _AdaptiveVideoSurface extends StatelessWidget {
  const _AdaptiveVideoSurface({
    required this.controller,
    this.quarterTurns = 0,
    this.disableNativeFullscreen = false,
  });

  final VideoController controller;
  final int quarterTurns;
  final bool disableNativeFullscreen;

  @override
  Widget build(BuildContext context) {
    final player = controller.player;
    return StreamBuilder<int?>(
      stream: player.stream.width,
      initialData: player.state.width,
      builder: (context, widthSnapshot) => StreamBuilder<int?>(
        stream: player.stream.height,
        initialData: player.state.height,
        builder: (context, heightSnapshot) {
          final width = (widthSnapshot.data ?? 0).toDouble();
          final height = (heightSnapshot.data ?? 0).toDouble();
          final aspectRatio = width > 0 && height > 0 ? width / height : 16 / 9;
          final normalizedTurns = quarterTurns % 4;
          final displayAspectRatio =
              normalizedTurns.isOdd ? 1 / aspectRatio : aspectRatio;
          return Center(
            child: AspectRatio(
              aspectRatio: displayAspectRatio.clamp(0.1, 10.0).toDouble(),
              child: RotatedBox(
                quarterTurns: normalizedTurns,
                child: Video(
                  controller: controller,
                  fit: BoxFit.contain,
                  onEnterFullscreen: disableNativeFullscreen
                      ? () async {}
                      : defaultEnterNativeFullscreen,
                  onExitFullscreen: disableNativeFullscreen
                      ? () async {}
                      : defaultExitNativeFullscreen,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SharedMediaSession extends ChangeNotifier {
  _SharedMediaSession() {
    _playlistSubscription = player.stream.playlist.listen((_) {
      notifyListeners();
    });
  }

  late final Player player = Player();
  late final VideoController controller = VideoController(player);
  _InMemoryMediaServer? _memoryMediaServer;
  late final StreamSubscription<Playlist> _playlistSubscription;
  FilePreview? preview;
  List<MediaPreviewItem> playlist = const [];
  String _sessionKey = '';
  var active = false;
  var collapsed = false;
  var dockSuppressed = false;

  @override
  void dispose() {
    unawaited(_playlistSubscription.cancel());
    unawaited(player.dispose());
    super.dispose();
  }

  static String playlistKeyFor(List<MediaPreviewItem> playlist) {
    return playlist
        .map((item) =>
            '${item.title}|${item.path ?? ''}|${item.resumeKey ?? ''}|${item.bytes?.length ?? 0}|${item.encrypted}')
        .join('\n');
  }

  static String keyFor(FilePreview preview, List<MediaPreviewItem> playlist) {
    final itemsKey = playlistKeyFor(playlist);
    return '${preview.title}|${preview.sourcePath ?? ''}|${preview.contentKind.name}|$itemsKey';
  }

  bool isSame(FilePreview preview, List<MediaPreviewItem> playlist) =>
      active && _sessionKey == keyFor(preview, playlist);

  bool isSamePlaylist(List<MediaPreviewItem> playlist) =>
      active && playlistKeyFor(this.playlist) == playlistKeyFor(playlist);

  MediaPreviewItem? get currentItem {
    if (playlist.isEmpty) return null;
    final index = player.state.playlist.index.clamp(0, playlist.length - 1);
    return playlist[index.toInt()];
  }

  String get currentTitle => currentItem?.title ?? preview?.title ?? '';

  FilePreview? get currentPreview {
    final item = currentItem;
    if (item == null) return preview;
    return FilePreview(
      title: item.title,
      subtitle: item.path ?? item.resumeKey ?? preview?.subtitle ?? '',
      sourcePath: item.path ?? preview?.sourcePath,
      bytes: item.bytes,
      decrypted: item.encrypted,
      contentKind: item.kind,
    );
  }

  void attachToActivePlaylist({
    required FilePreview preview,
    required List<MediaPreviewItem> playlist,
    required bool allowMiniDock,
  }) {
    if (!active) return;
    this.preview = preview;
    this.playlist = playlist;
    _sessionKey = keyFor(preview, playlist);
    dockSuppressed = !allowMiniDock;
    notifyListeners();
  }

  Future<void> open({
    required FilePreview preview,
    required List<MediaPreviewItem> playlist,
    required AppLanguage language,
    required int initialIndex,
    required bool repeatOne,
    required bool shuffle,
    required bool allowMiniDock,
  }) async {
    final nextKey = keyFor(preview, playlist);
    if (active && _sessionKey == nextKey) {
      this.preview = preview;
      this.playlist = playlist;
      dockSuppressed = !allowMiniDock;
      await player.setPlaylistMode(
        repeatOne ? PlaylistMode.single : PlaylistMode.loop,
      );
      await player.setShuffle(shuffle);
      notifyListeners();
      return;
    }
    final preserveCollapsed = active ? collapsed : false;
    await _clearMemoryMedia();
    final medias = <Media>[];
    for (var i = 0; i < playlist.length; i++) {
      final item = playlist[i];
      if (item.bytes != null) {
        final server =
            _memoryMediaServer ??= await _InMemoryMediaServer.start();
        final uri = server.add(item, i);
        medias.add(Media(uri.toString()));
      } else if (item.path != null && item.path!.isNotEmpty) {
        final path = item.path!;
        if (path.startsWith('http://') || path.startsWith('https://')) {
          if (_isLoopbackTorrentStream(path)) {
            await _prewarmTorrentStream(path);
          }
          medias.add(Media(path));
          continue;
        }
        if (path.startsWith('remote://') ||
            path.startsWith('torrent://') ||
            path.startsWith('zip://') ||
            path.startsWith('rar://')) {
          continue;
        }
        medias.add(Media(Uri.file(path).toString()));
      }
    }
    if (medias.isEmpty) {
      throw StateError(language.t('media.unavailable'));
    }
    this.preview = preview;
    this.playlist = playlist;
    _sessionKey = nextKey;
    active = true;
    collapsed = preserveCollapsed;
    dockSuppressed = !allowMiniDock;
    notifyListeners();
    await player.open(Playlist(medias, index: initialIndex), play: true);
    await player.setPlaylistMode(
      repeatOne ? PlaylistMode.single : PlaylistMode.loop,
    );
    await player.setShuffle(shuffle);
    notifyListeners();
  }

  Future<void> close() async {
    active = false;
    dockSuppressed = false;
    _sessionKey = '';
    preview = null;
    playlist = const [];
    await player.stop();
    await _clearMemoryMedia();
    notifyListeners();
  }

  void setCollapsed(bool value) {
    collapsed = value;
    notifyListeners();
  }

  Future<void> _clearMemoryMedia() async {
    final server = _memoryMediaServer;
    _memoryMediaServer = null;
    await server?.close();
  }

  bool _isLoopbackTorrentStream(String path) {
    final uri = Uri.tryParse(path);
    if (uri == null || uri.scheme != 'http') return false;
    final host = uri.host.toLowerCase();
    return uri.pathSegments.isNotEmpty &&
        uri.pathSegments.first == 'torrent' &&
        (host == '127.0.0.1' || host == 'localhost');
  }

  Future<void> _prewarmTorrentStream(String path) async {
    final uri = Uri.parse(path);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final request =
          await client.getUrl(uri).timeout(const Duration(seconds: 8));
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final response =
          await request.close().timeout(const Duration(seconds: 45));
      if (response.statusCode >= 400) {
        final body = await utf8
            .decodeStream(response)
            .timeout(const Duration(seconds: 8), onTimeout: () => '');
        throw StateError(body.trim().isEmpty
            ? 'Torrent stream returned HTTP ${response.statusCode}.'
            : body.trim());
      }
      await response.drain<void>().timeout(const Duration(seconds: 45));
    } on TimeoutException catch (_) {
      throw StateError(
        'Torrent stream did not provide initial media bytes in time.',
      );
    } finally {
      client.close(force: true);
    }
  }
}

class _InMemoryMediaServer {
  _InMemoryMediaServer._(this._server) {
    _subscription = _server.listen(_handleRequest);
  }

  final HttpServer _server;
  late final StreamSubscription<HttpRequest> _subscription;
  final _items = <String, _InMemoryMediaEntry>{};

  static Future<_InMemoryMediaServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _InMemoryMediaServer._(server);
  }

  Uri add(MediaPreviewItem item, int index) {
    final id = '${DateTime.now().microsecondsSinceEpoch}_$index';
    final title = _safeFileName(item.title).trim().isEmpty
        ? 'media_$index'
        : _safeFileName(item.title);
    _items[id] = _InMemoryMediaEntry(
      title: title,
      bytes: item.bytes!,
      contentType: _contentType(item),
    );
    return Uri.parse(
      'http://127.0.0.1:${_server.port}/media/$id/${Uri.encodeComponent(title)}',
    );
  }

  Future<void> close() async {
    _items.clear();
    await _subscription.cancel();
    await _server.close(force: true);
  }

  void _handleRequest(HttpRequest request) {
    unawaited(() async {
      try {
        final segments = request.uri.pathSegments;
        if (segments.length < 2 || segments.first != 'media') {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        final item = _items[segments[1]];
        if (item == null) {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        final bytes = item.bytes;
        final range = request.headers.value(HttpHeaders.rangeHeader);
        var start = 0;
        var end = bytes.length - 1;
        if (range != null && range.startsWith('bytes=')) {
          final spec = range.substring('bytes='.length).split('-');
          start = int.tryParse(spec.first) ?? 0;
          if (spec.length > 1 && spec[1].isNotEmpty) {
            end = int.tryParse(spec[1]) ?? end;
          }
          start = start.clamp(0, bytes.length - 1).toInt();
          end = end.clamp(start, bytes.length - 1).toInt();
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${bytes.length}',
          );
        }
        request.response.headers
          ..set(HttpHeaders.acceptRangesHeader, 'bytes')
          ..set(HttpHeaders.contentTypeHeader, item.contentType)
          ..set(HttpHeaders.contentLengthHeader, end - start + 1)
          ..set(HttpHeaders.cacheControlHeader, 'no-store');
        request.response.add(bytes.sublist(start, end + 1));
        await request.response.close();
      } catch (_) {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      }
    }());
  }

  String _contentType(MediaPreviewItem item) {
    final extension = FileViewerService.extensionForName(item.title);
    return switch (extension) {
      '.mp3' => 'audio/mpeg',
      '.wav' => 'audio/wav',
      '.flac' => 'audio/flac',
      '.ogg' => 'audio/ogg',
      '.m4a' || '.aac' => 'audio/mp4',
      '.webm' =>
        item.kind == FileContentKind.video ? 'video/webm' : 'audio/webm',
      '.mkv' => 'video/x-matroska',
      '.mov' => 'video/quicktime',
      '.avi' => 'video/x-msvideo',
      '.mp4' || '.m4v' => 'video/mp4',
      _ => item.kind == FileContentKind.video
          ? 'application/octet-stream'
          : 'audio/mpeg',
    };
  }
}

class _InMemoryMediaEntry {
  const _InMemoryMediaEntry({
    required this.title,
    required this.bytes,
    required this.contentType,
  });

  final String title;
  final Uint8List bytes;
  final String contentType;
}

class _TextReadingDock extends StatefulWidget {
  const _TextReadingDock({
    required this.session,
    required this.language,
    required this.onTogglePlay,
    required this.onPrevious,
    required this.onNext,
    required this.onNextFile,
    required this.onClose,
  });

  final _ReadingSession session;
  final AppLanguage language;
  final Future<void> Function() onTogglePlay;
  final Future<void> Function() onPrevious;
  final Future<void> Function() onNext;
  final Future<void> Function() onNextFile;
  final Future<void> Function() onClose;

  @override
  State<_TextReadingDock> createState() => _TextReadingDockState();
}

class _TextReadingDockState extends State<_TextReadingDock> {
  Offset? _offset;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      const width = 360.0;
      const height = 132.0;
      final initial = Offset(
        math.max(12, constraints.maxWidth - width - 16),
        math.max(12, constraints.maxHeight - height - 96),
      );
      final rawOffset = _offset ?? initial;
      final left = rawOffset.dx
          .clamp(8.0, math.max(8.0, constraints.maxWidth - width - 8))
          .toDouble();
      final top = rawOffset.dy
          .clamp(8.0, math.max(8.0, constraints.maxHeight - height - 8))
          .toDouble();
      final current = widget.session.chunkIndex + 1;
      final total = math.max(1, widget.session.chunks.length);
      return Positioned(
        left: left,
        top: top,
        width: width,
        child: GestureDetector(
          onPanUpdate: (details) => setState(() {
            _offset = Offset(left, top) + details.delta;
          }),
          child: Material(
            elevation: 12,
            borderRadius: BorderRadius.circular(20),
            color: Theme.of(context).colorScheme.surface,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  const Icon(Icons.record_voice_over_outlined),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.session.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  IconButton(
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close),
                    tooltip: widget.language.t('common.close'),
                  ),
                ]),
                LinearProgressIndicator(value: current / total),
                const SizedBox(height: 4),
                Text(
                  '${widget.language.t('reader.fragment')} $current/$total',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  IconButton(
                    onPressed: widget.onPrevious,
                    icon: const Icon(Icons.skip_previous),
                    tooltip: widget.language.t('media.previous'),
                  ),
                  IconButton(
                    onPressed: widget.onTogglePlay,
                    icon: Icon(widget.session.playing
                        ? Icons.pause_circle_outline
                        : Icons.play_circle_outline),
                    tooltip: widget.session.playing
                        ? widget.language.t('media.pause')
                        : widget.language.t('media.play'),
                  ),
                  IconButton(
                    onPressed: widget.onNext,
                    icon: const Icon(Icons.skip_next),
                    tooltip: widget.language.t('media.next'),
                  ),
                  IconButton(
                    onPressed: widget.onNextFile,
                    icon: const Icon(Icons.queue_play_next_outlined),
                    tooltip: widget.language.t('reader.next.file'),
                  ),
                ]),
              ]),
            ),
          ),
        ),
      );
    });
  }
}

class _FloatingMediaDock extends StatefulWidget {
  const _FloatingMediaDock({
    required this.session,
    required this.language,
    required this.enableMiniVideo,
    required this.enableMiniAudio,
    required this.continueInBackground,
    required this.externalFloatingPlayer,
    required this.onOpenFullScreen,
  });

  final _SharedMediaSession session;
  final AppLanguage language;
  final bool enableMiniVideo;
  final bool enableMiniAudio;
  final bool continueInBackground;
  final bool externalFloatingPlayer;
  final void Function(FilePreview preview, List<MediaPreviewItem> playlist)
      onOpenFullScreen;

  @override
  State<_FloatingMediaDock> createState() => _FloatingMediaDockState();
}

class _BackgroundJobsPanel extends StatefulWidget {
  const _BackgroundJobsPanel({
    required this.jobs,
    required this.language,
    required this.autoCollapseSeconds,
    required this.onCancel,
    required this.onRemove,
    required this.onToggleCollapsed,
  });

  final List<_BackgroundJob> jobs;
  final AppLanguage language;
  final int autoCollapseSeconds;
  final ValueChanged<_BackgroundJob> onCancel;
  final ValueChanged<_BackgroundJob> onRemove;
  final ValueChanged<_BackgroundJob> onToggleCollapsed;

  @override
  State<_BackgroundJobsPanel> createState() => _BackgroundJobsPanelState();
}

class _BackgroundJobsPanelState extends State<_BackgroundJobsPanel> {
  Offset? _offset;
  var _compact = true;
  Timer? _collapseTimer;

  @override
  void didUpdateWidget(covariant _BackgroundJobsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_compact && widget.jobs.isNotEmpty) {
      _scheduleAutoCollapse();
    }
  }

  @override
  void dispose() {
    _collapseTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.jobs.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, constraints) {
      final visibleJobs = widget.jobs.where((job) => !job.collapsed).toList();
      final panelHeight = _compact
          ? 72.0
          : math.min(
              constraints.maxHeight - 24,
              92.0 + math.max(1, visibleJobs.length) * 78.0,
            );
      final panelWidth = _compact
          ? 72.0
          : math.min(680.0, math.max(280.0, constraints.maxWidth - 32));
      final initial = Offset(
        16,
        math.max(8, constraints.maxHeight - panelHeight - 16),
      );
      final rawOffset = _offset ?? initial;
      final left = rawOffset.dx
          .clamp(8.0, math.max(8.0, constraints.maxWidth - panelWidth - 8))
          .toDouble();
      final top = rawOffset.dy
          .clamp(8.0, math.max(8.0, constraints.maxHeight - panelHeight - 8))
          .toDouble();
      return Positioned(
        left: left,
        top: top,
        width: panelWidth,
        child: GestureDetector(
          onPanUpdate: (details) => setState(() {
            _offset = Offset(left, top) + details.delta;
          }),
          child: _compact
              ? _buildCompact(context)
              : _buildExpanded(context, visibleJobs, panelHeight),
        ),
      );
    });
  }

  Widget _buildCompact(BuildContext context) {
    final aggregate = _aggregateProgress();
    final failed = widget.jobs.any((job) => job.failed);
    final done = widget.jobs.every((job) => job.done || job.failed);
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 10,
      color: colorScheme.surface,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: _expand,
        child: SizedBox(
          width: 72,
          height: 72,
          child: Stack(alignment: Alignment.center, children: [
            SizedBox(
              width: 56,
              height: 56,
              child: CircularProgressIndicator(
                value: done ? 1 : aggregate,
                color: failed ? colorScheme.error : colorScheme.primary,
                strokeWidth: 5,
              ),
            ),
            Text(
              '${widget.jobs.length}',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            Positioned(
              bottom: 10,
              child: Text(
                '${(aggregate * 100).round()}%',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildExpanded(
    BuildContext context,
    List<_BackgroundJob> visibleJobs,
    double maxHeight,
  ) {
    final language = widget.language;
    return Material(
      elevation: 10,
      borderRadius: BorderRadius.circular(18),
      color: Theme.of(context).colorScheme.surface,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              const Icon(Icons.sync_outlined),
              const SizedBox(width: 8),
              Expanded(child: Text(language.t('jobs.title'))),
              Text('${widget.jobs.length}'),
              IconButton(
                onPressed: () => setState(() => _compact = true),
                icon: const Icon(Icons.radio_button_unchecked),
                tooltip: language.t('jobs.collapse'),
              ),
            ]),
            if (visibleJobs.isEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(language.t('jobs.collapsed')),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final job in visibleJobs)
                    ListTile(
                      dense: true,
                      title: Text(job.title, maxLines: 1),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          LinearProgressIndicator(
                            value: job.done || job.failed ? 1 : job.progress,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            job.status.isEmpty
                                ? '${job.completed}/${job.total}'
                                : job.status,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                      trailing: Wrap(spacing: 4, children: [
                        IconButton(
                          onPressed: () => widget.onToggleCollapsed(job),
                          icon: const Icon(Icons.expand_more),
                          tooltip: language.t('jobs.collapse'),
                        ),
                        if (!job.done && !job.failed)
                          IconButton(
                            onPressed: () => widget.onCancel(job),
                            icon: const Icon(Icons.stop_circle_outlined),
                            tooltip: language.t('jobs.cancel'),
                          ),
                        if (job.done || job.failed)
                          IconButton(
                            onPressed: () => widget.onRemove(job),
                            icon: const Icon(Icons.close),
                            tooltip: language.t('common.close'),
                          ),
                      ]),
                    ),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }

  double _aggregateProgress() {
    if (widget.jobs.isEmpty) return 0;
    final total = widget.jobs.fold<int>(0, (sum, job) => sum + job.total);
    if (total <= 0) return 0;
    final completed = widget.jobs.fold<int>(
      0,
      (sum, job) => sum + (job.done || job.failed ? job.total : job.completed),
    );
    return (completed / total).clamp(0.0, 1.0).toDouble();
  }

  void _expand() {
    setState(() => _compact = false);
    _scheduleAutoCollapse();
  }

  void _scheduleAutoCollapse() {
    _collapseTimer?.cancel();
    final seconds = widget.autoCollapseSeconds.clamp(1, 120);
    _collapseTimer = Timer(Duration(seconds: seconds), () {
      if (mounted) setState(() => _compact = true);
    });
  }
}

class _FloatingMediaDockState extends State<_FloatingMediaDock> {
  Offset _offset = const Offset(24, 92);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.session,
      builder: (context, _) {
        final preview = widget.session.preview;
        final item = widget.session.currentItem;
        if (!widget.continueInBackground ||
            !widget.session.active ||
            widget.session.dockSuppressed ||
            preview == null ||
            item == null) {
          return const SizedBox.shrink();
        }
        final isVideo = item.kind == FileContentKind.video;
        if (isVideo && !widget.enableMiniVideo) return const SizedBox.shrink();
        if (!isVideo && !widget.enableMiniAudio) return const SizedBox.shrink();

        final size = MediaQuery.sizeOf(context);
        final width = isVideo && !widget.session.collapsed ? 340.0 : 320.0;
        final videoHeight = math.min(190.0, size.height * 0.32);
        final height =
            isVideo && !widget.session.collapsed ? videoHeight + 58.0 : 92.0;
        final canFloatOutside =
            Platform.isWindows && widget.externalFloatingPlayer;
        final minLeft = canFloatOutside ? -width + 72.0 : 8.0;
        final maxLeft = canFloatOutside
            ? size.width - 72.0
            : math.max(8.0, size.width - width - 8);
        final minTop = canFloatOutside ? -height + 48.0 : 8.0;
        final maxTop = canFloatOutside
            ? size.height - 48.0
            : math.max(8.0, size.height - height - 8);
        final left =
            _offset.dx.clamp(minLeft, math.max(minLeft, maxLeft)).toDouble();
        final top =
            _offset.dy.clamp(minTop, math.max(minTop, maxTop)).toDouble();
        return Positioned(
          left: left,
          top: top,
          width: width,
          child: GestureDetector(
            onPanUpdate: (details) => setState(() {
              _offset += details.delta;
            }),
            child: Material(
              elevation: 12,
              borderRadius: BorderRadius.circular(20),
              clipBehavior: Clip.antiAlias,
              color: Theme.of(context).colorScheme.surface,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (isVideo && !widget.session.collapsed)
                  SizedBox(
                    height: videoHeight,
                    width: double.infinity,
                    child: _AdaptiveVideoSurface(
                      controller: widget.session.controller,
                    ),
                  )
                else
                  _MiniAudioHeader(item: item),
                if (!isVideo || widget.session.collapsed)
                  _MiniPositionSlider(player: widget.session.player),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 2),
                  child: Row(children: [
                    Expanded(
                      child: _MarqueeText(
                        item.title,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    StreamBuilder<bool>(
                      stream: widget.session.player.stream.playing,
                      initialData: widget.session.player.state.playing,
                      builder: (context, snapshot) {
                        final playing = snapshot.data ?? false;
                        return IconButton(
                          onPressed: widget.session.player.playOrPause,
                          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                          tooltip: playing
                              ? widget.language.t('media.pause')
                              : widget.language.t('media.play'),
                        );
                      },
                    ),
                    IconButton(
                      onPressed: () =>
                          unawaited(widget.session.player.previous()),
                      icon: const Icon(Icons.skip_previous),
                      tooltip: widget.language.t('media.previous'),
                    ),
                    IconButton(
                      onPressed: () => unawaited(widget.session.player.next()),
                      icon: const Icon(Icons.skip_next),
                      tooltip: widget.language.t('media.next'),
                    ),
                    IconButton(
                      onPressed: () => widget.onOpenFullScreen(
                        widget.session.currentPreview ?? preview,
                        widget.session.playlist,
                      ),
                      icon: const Icon(Icons.fullscreen),
                      tooltip: widget.language.t('preview.window'),
                    ),
                    IconButton(
                      onPressed: () => unawaited(widget.session.close()),
                      icon: const Icon(Icons.close),
                      tooltip: widget.language.t('common.cancel'),
                    ),
                  ]),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }
}

class _MiniPositionSlider extends StatelessWidget {
  const _MiniPositionSlider({required this.player});

  final Player player;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 12,
      child: StreamBuilder<Duration>(
        stream: player.stream.duration,
        initialData: player.state.duration,
        builder: (context, durationSnapshot) {
          final duration = durationSnapshot.data ?? Duration.zero;
          return StreamBuilder<Duration>(
            stream: player.stream.position,
            initialData: player.state.position,
            builder: (context, positionSnapshot) {
              final position = positionSnapshot.data ?? Duration.zero;
              final maxMs = math.max(duration.inMilliseconds, 1);
              final value = position.inMilliseconds.clamp(0, maxMs).toDouble();
              return SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 4),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 9),
                  tickMarkShape: SliderTickMarkShape.noTickMark,
                ),
                child: Slider(
                  value: value,
                  min: 0,
                  max: maxMs.toDouble(),
                  onChanged: duration == Duration.zero
                      ? null
                      : (value) => player.seek(
                            Duration(milliseconds: value.round()),
                          ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _MiniAudioHeader extends StatelessWidget {
  const _MiniAudioHeader({required this.item});

  final MediaPreviewItem item;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future:
          MediaArtworkService.audioArtwork(path: item.path, bytes: item.bytes),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        return Container(
          height: 30,
          color: Theme.of(context).colorScheme.secondaryContainer,
          child: Row(children: [
            const SizedBox(width: 10),
            if (bytes != null && bytes.isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(bytes,
                    width: 24, height: 24, fit: BoxFit.cover),
              )
            else
              const Icon(Icons.graphic_eq, size: 24),
            const SizedBox(width: 10),
            Expanded(
              child: _MarqueeText(
                item.title,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
          ]),
        );
      },
    );
  }
}

class _MarqueeText extends StatefulWidget {
  const _MarqueeText(
    this.text, {
    this.style,
  });

  final String text;
  final TextStyle? style;

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
  }

  @override
  void didUpdateWidget(covariant _MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _controller
        ..stop()
        ..reset();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final style = widget.style ?? DefaultTextStyle.of(context).style;
      final painter = TextPainter(
        text: TextSpan(text: widget.text, style: style),
        textDirection: Directionality.of(context),
        maxLines: 1,
      )..layout();
      final width = painter.width;
      if (width <= constraints.maxWidth || constraints.maxWidth.isInfinite) {
        _controller.stop();
        return Text(
          widget.text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style,
        );
      }
      final distance = width + 42;
      final durationMs = math.max(4500, distance * 38).round();
      if (_controller.duration?.inMilliseconds != durationMs) {
        _controller.duration = Duration(milliseconds: durationMs);
      }
      if (!_controller.isAnimating) {
        _controller.repeat();
      }
      return ClipRect(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final offset = -_controller.value * distance;
            return Transform.translate(
              offset: Offset(offset, 0),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(widget.text, maxLines: 1, style: style),
                const SizedBox(width: 42),
                Text(widget.text, maxLines: 1, style: style),
              ]),
            );
          },
        ),
      );
    });
  }
}

class _MediaTransportControls extends StatelessWidget {
  const _MediaTransportControls({
    required this.player,
    required this.language,
    required this.shuffle,
    required this.repeatOne,
    required this.onShuffle,
    required this.onRepeatOne,
    required this.onBeforeTrackChange,
  });

  final Player player;
  final AppLanguage language;
  final bool shuffle;
  final bool repeatOne;
  final VoidCallback onShuffle;
  final VoidCallback onRepeatOne;
  final Future<void> Function() onBeforeTrackChange;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 560;
              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ..._primaryControls(),
                  const SizedBox(width: 8),
                  if (compact)
                    _combinedControls(context)
                  else
                    ..._expandedControls(context),
                ],
              );
            },
          ),
          StreamBuilder<Duration>(
            stream: player.stream.duration,
            initialData: player.state.duration,
            builder: (context, durationSnapshot) {
              final duration = durationSnapshot.data ?? Duration.zero;
              return StreamBuilder<Duration>(
                stream: player.stream.position,
                initialData: player.state.position,
                builder: (context, positionSnapshot) {
                  final position = positionSnapshot.data ?? Duration.zero;
                  final maxMs = math.max(duration.inMilliseconds, 1);
                  final value =
                      position.inMilliseconds.clamp(0, maxMs).toDouble();
                  return Row(children: [
                    Text(_formatDuration(position)),
                    Expanded(
                      child: Slider(
                        value: value,
                        min: 0,
                        max: maxMs.toDouble(),
                        onChanged: (value) => player.seek(
                          Duration(milliseconds: value.round()),
                        ),
                      ),
                    ),
                    Text(_formatDuration(duration)),
                  ]);
                },
              );
            },
          ),
        ]),
      ),
    );
  }

  List<Widget> _primaryControls() => [
        IconButton(
          onPressed: () => unawaited(() async {
            await onBeforeTrackChange();
            await player.previous();
          }()),
          icon: const Icon(Icons.skip_previous),
          tooltip: language.t('media.previous'),
        ),
        StreamBuilder<bool>(
          stream: player.stream.playing,
          initialData: player.state.playing,
          builder: (context, snapshot) {
            final playing = snapshot.data ?? false;
            return IconButton.filled(
              onPressed: player.playOrPause,
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              tooltip: playing
                  ? language.t('media.pause')
                  : language.t('media.play'),
            );
          },
        ),
        IconButton(
          onPressed: () => unawaited(() async {
            await onBeforeTrackChange();
            await player.next();
          }()),
          icon: const Icon(Icons.skip_next),
          tooltip: language.t('media.next'),
        ),
      ];

  List<Widget> _expandedControls(BuildContext context) => [
        IconButton(
          onPressed: onShuffle,
          icon: Icon(shuffle ? Icons.shuffle_on : Icons.shuffle),
          tooltip: language.t('media.shuffle'),
        ),
        IconButton(
          onPressed: onRepeatOne,
          icon: Icon(repeatOne ? Icons.repeat_one_on : Icons.repeat),
          tooltip: language.t('media.repeat.one'),
        ),
        StreamBuilder<double>(
          stream: player.stream.rate,
          initialData: player.state.rate,
          builder: (context, snapshot) {
            final rate = snapshot.data ?? 1.0;
            return PopupMenuButton<double>(
              tooltip: language.t('media.speed'),
              icon: const Icon(Icons.speed_outlined),
              onSelected: (value) => unawaited(player.setRate(value)),
              itemBuilder: (_) => [
                for (final value in const [.5, .75, 1.0, 1.25, 1.5, 2.0])
                  CheckedPopupMenuItem(
                    value: value,
                    checked: (rate - value).abs() < .01,
                    child: Text('${value.toStringAsFixed(2)}x'),
                  ),
              ],
            );
          },
        ),
        _tracksMenuButton(),
        _equalizerMenuButton(context),
      ];

  Widget _tracksMenuButton() => StreamBuilder<Tracks>(
        stream: player.stream.tracks,
        initialData: player.state.tracks,
        builder: (context, snapshot) {
          final tracks = snapshot.data ?? const Tracks();
          return PopupMenuButton<Object>(
            tooltip: language.t('media.tracks'),
            icon: const Icon(Icons.subtitles_outlined),
            onSelected: _selectExtraControl,
            itemBuilder: (_) => _trackItems(tracks),
          );
        },
      );

  Widget _equalizerMenuButton(BuildContext context) => PopupMenuButton<String>(
        tooltip: language.t('media.equalizer'),
        icon: const Icon(Icons.equalizer_outlined),
        onSelected: (preset) => preset == 'custom'
            ? unawaited(_showCustomEqualizerDialog(context))
            : unawaited(_applyEqualizerPreset(player, preset)),
        itemBuilder: (_) => [
          for (final preset in const [
            'flat',
            'bass',
            'voice',
            'treble',
            'loudness',
            'custom',
          ])
            PopupMenuItem(
              value: preset,
              child: Text(language.t('media.equalizer.$preset')),
            ),
        ],
      );

  Widget _combinedControls(BuildContext menuContext) => StreamBuilder<Tracks>(
        stream: player.stream.tracks,
        initialData: player.state.tracks,
        builder: (context, snapshot) {
          final tracks = snapshot.data ?? const Tracks();
          final rate = player.state.rate;
          return PopupMenuButton<Object>(
            tooltip: language.t('media.more.controls'),
            icon: const Icon(Icons.tune_outlined),
            onSelected: (value) => _selectExtraControl(value, menuContext),
            itemBuilder: (_) => [
              CheckedPopupMenuItem<Object>(
                value: 'shuffle',
                checked: shuffle,
                child: Text(language.t('media.shuffle')),
              ),
              CheckedPopupMenuItem<Object>(
                value: 'repeatOne',
                checked: repeatOne,
                child: Text(language.t('media.repeat.one')),
              ),
              const PopupMenuDivider(),
              PopupMenuItem<Object>(
                enabled: false,
                child: Text(language.t('media.speed')),
              ),
              for (final value in const [.5, .75, 1.0, 1.25, 1.5, 2.0])
                CheckedPopupMenuItem<Object>(
                  value: 'speed:$value',
                  checked: (rate - value).abs() < .01,
                  child: Text('${value.toStringAsFixed(2)}x'),
                ),
              const PopupMenuDivider(),
              ..._trackItems(tracks),
              const PopupMenuDivider(),
              PopupMenuItem<Object>(
                enabled: false,
                child: Text(language.t('media.equalizer')),
              ),
              for (final preset in const [
                'flat',
                'bass',
                'voice',
                'treble',
                'loudness',
                'custom',
              ])
                PopupMenuItem<Object>(
                  value: 'eq:$preset',
                  child: Text(language.t('media.equalizer.$preset')),
                ),
            ],
          );
        },
      );

  List<PopupMenuEntry<Object>> _trackItems(Tracks tracks) => [
        PopupMenuItem<Object>(
          enabled: false,
          child: Text(language.t('media.audio.track')),
        ),
        for (final track in tracks.audio)
          PopupMenuItem<Object>(
            value: track,
            child: Text(_trackTitle(track)),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<Object>(
          enabled: false,
          child: Text(language.t('media.subtitle.track')),
        ),
        for (final track in tracks.subtitle)
          PopupMenuItem<Object>(
            value: track,
            child: Text(_trackTitle(track)),
          ),
      ];

  void _selectExtraControl(Object value, [BuildContext? context]) {
    if (value == 'shuffle') {
      onShuffle();
      return;
    }
    if (value == 'repeatOne') {
      onRepeatOne();
      return;
    }
    if (value is String && value.startsWith('speed:')) {
      final speed = double.tryParse(value.substring('speed:'.length));
      if (speed != null) unawaited(player.setRate(speed));
      return;
    }
    if (value is String && value.startsWith('eq:')) {
      final preset = value.substring(3);
      if (preset == 'custom') {
        if (context != null) unawaited(_showCustomEqualizerDialog(context));
      } else {
        unawaited(_applyEqualizerPreset(player, preset));
      }
      return;
    }
    if (value is AudioTrack) {
      unawaited(player.setAudioTrack(value));
    } else if (value is SubtitleTrack) {
      unawaited(player.setSubtitleTrack(value));
    }
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  String _trackTitle(dynamic track) {
    final title = track.title?.toString();
    final languageCode = track.language?.toString();
    final id = track.id?.toString() ?? '';
    final parts = [
      if (title != null && title.isNotEmpty) title,
      if (languageCode != null && languageCode.isNotEmpty) languageCode,
      if (id.isNotEmpty) id,
    ];
    return parts.isEmpty ? 'auto' : parts.join(' / ');
  }

  Future<void> _applyEqualizerPreset(Player player, String preset) async {
    final filter = switch (preset) {
      'bass' => 'equalizer=f=60:t=q:w=1:g=6,equalizer=f=170:t=q:w=1:g=4',
      'voice' => 'equalizer=f=1000:t=q:w=1:g=4,equalizer=f=3000:t=q:w=1:g=3',
      'treble' => 'equalizer=f=6000:t=q:w=1:g=4,equalizer=f=12000:t=q:w=1:g=3',
      'loudness' =>
        'equalizer=f=80:t=q:w=1:g=4,equalizer=f=12000:t=q:w=1:g=3,loudnorm',
      _ => '',
    };
    try {
      await (player.platform as dynamic).setProperty('af', filter);
    } catch (_) {
      // Some platform backends do not expose mpv audio filters.
    }
  }

  Future<void> _showCustomEqualizerDialog(BuildContext context) async {
    var bandCount = 10;
    var preamp = 0.0;
    var gains = List<double>.filled(bandCount, 0);
    final result = await showDialog<({double preamp, List<double> gains})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          void resize(int count) {
            setDialogState(() {
              bandCount = count;
              gains = List<double>.generate(
                count,
                (index) => index < gains.length ? gains[index] : 0,
              );
            });
          }

          final frequencies = _equalizerFrequencies(bandCount);
          return AlertDialog(
            title: Text(language.t('media.equalizer.custom')),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  DropdownButtonFormField<int>(
                    initialValue: bandCount,
                    decoration: InputDecoration(
                      labelText: language.t('media.equalizer.bands'),
                    ),
                    items: [
                      for (final value in const [5, 10, 15, 20, 31])
                        DropdownMenuItem(value: value, child: Text('$value')),
                    ],
                    onChanged: (value) {
                      if (value != null) resize(value);
                    },
                  ),
                  const SizedBox(height: 10),
                  _dbSlider(
                    context,
                    label: language.t('media.equalizer.preamp'),
                    value: preamp,
                    onChanged: (value) => setDialogState(() => preamp = value),
                  ),
                  const Divider(),
                  for (var i = 0; i < gains.length; i++)
                    _dbSlider(
                      context,
                      label: _frequencyLabel(frequencies[i]),
                      value: gains[i],
                      onChanged: (value) =>
                          setDialogState(() => gains[i] = value),
                    ),
                ]),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(language.t('common.cancel')),
              ),
              TextButton(
                onPressed: () => Navigator.pop(
                  context,
                  (preamp: 0.0, gains: List<double>.filled(bandCount, 0)),
                ),
                child: Text(language.t('search.clear')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(
                  context,
                  (preamp: preamp, gains: List<double>.from(gains)),
                ),
                child: Text(language.t('search.apply')),
              ),
            ],
          );
        },
      ),
    );
    if (result == null) return;
    await _applyCustomEqualizer(player, result.preamp, result.gains);
  }

  Widget _dbSlider(
    BuildContext context, {
    required String label,
    required double value,
    required ValueChanged<double> onChanged,
  }) {
    return Row(children: [
      SizedBox(width: 82, child: Text(label)),
      Expanded(
        child: Slider(
          min: -12,
          max: 12,
          divisions: 48,
          value: value.clamp(-12, 12).toDouble(),
          label: '${value.toStringAsFixed(1)} dB',
          onChanged: onChanged,
        ),
      ),
      SizedBox(
        width: 58,
        child: Text(
          '${value.toStringAsFixed(1)} dB',
          textAlign: TextAlign.end,
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ),
    ]);
  }

  List<double> _equalizerFrequencies(int count) {
    const min = 32.0;
    const max = 16000.0;
    if (count <= 1) return const [1000];
    return [
      for (var i = 0; i < count; i++)
        min * math.pow(max / min, i / (count - 1)),
    ];
  }

  String _frequencyLabel(double frequency) {
    if (frequency >= 1000) return '${(frequency / 1000).toStringAsFixed(1)}k';
    return frequency.round().toString();
  }

  Future<void> _applyCustomEqualizer(
    Player player,
    double preamp,
    List<double> gains,
  ) async {
    final frequencies = _equalizerFrequencies(gains.length);
    final filters = <String>[
      if (preamp.abs() >= .05) 'volume=${preamp.toStringAsFixed(1)}dB',
      for (var i = 0; i < gains.length; i++)
        if (gains[i].abs() >= .05)
          'equalizer=f=${frequencies[i].round()}:t=q:w=1:g=${gains[i].toStringAsFixed(1)}',
    ];
    try {
      await (player.platform as dynamic).setProperty('af', filters.join(','));
    } catch (_) {
      // Some platform backends do not expose mpv audio filters.
    }
  }
}

class _AudioArtworkForCurrent extends StatelessWidget {
  const _AudioArtworkForCurrent({
    required this.player,
    required this.items,
  });

  final Player player;
  final List<MediaPreviewItem> items;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Playlist>(
      stream: player.stream.playlist,
      initialData: player.state.playlist,
      builder: (context, snapshot) {
        if (items.isEmpty) return _fallback(context);
        final index =
            (snapshot.data?.index ?? 0).clamp(0, items.length - 1).toInt();
        final item = items[index];
        return FutureBuilder<Uint8List?>(
          future: MediaArtworkService.audioArtwork(
            path: item.path,
            bytes: item.bytes,
          ),
          builder: (context, artSnapshot) {
            final bytes = artSnapshot.data;
            if (bytes == null || bytes.isEmpty) return _fallback(context);
            return ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Image.memory(
                bytes,
                width: 180,
                height: 180,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _fallback(context),
              ),
            );
          },
        );
      },
    );
  }

  Widget _fallback(BuildContext context) => Container(
        width: 180,
        height: 180,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        child: const Icon(Icons.graphic_eq, size: 64),
      );
}

class _AudioLyricsForCurrent extends StatelessWidget {
  const _AudioLyricsForCurrent({
    required this.player,
    required this.items,
    required this.language,
  });

  final Player player;
  final List<MediaPreviewItem> items;
  final AppLanguage language;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Playlist>(
      stream: player.stream.playlist,
      initialData: player.state.playlist,
      builder: (context, snapshot) {
        if (items.isEmpty) return const SizedBox.shrink();
        final index =
            (snapshot.data?.index ?? 0).clamp(0, items.length - 1).toInt();
        final item = items[index];
        return FutureBuilder<String?>(
          future: MediaArtworkService.audioLyrics(
            path: item.path,
            bytes: item.bytes,
          ),
          builder: (context, lyricsSnapshot) {
            final lyrics = lyricsSnapshot.data?.trim();
            if (lyrics == null || lyrics.isEmpty) {
              return const SizedBox.shrink();
            }
            return ExpansionTile(
              title: Text(language.t('media.lyrics')),
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(lyrics),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _MediaPlaylistView extends StatelessWidget {
  const _MediaPlaylistView({
    required this.player,
    required this.items,
    required this.language,
    required this.onBeforeTrackChange,
  });

  final Player player;
  final List<MediaPreviewItem> items;
  final AppLanguage language;
  final Future<void> Function() onBeforeTrackChange;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            language.t(items.firstOrNull?.kind == FileContentKind.video
                ? 'media.video.playlist'
                : 'media.audio.playlist'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          DefaultTabController(
            length: 8,
            child: SizedBox(
              height: 330,
              child: Column(children: [
                TabBar(isScrollable: true, tabs: [
                  Tab(text: language.t('media.tab.current')),
                  Tab(text: language.t('media.tab.all')),
                  Tab(text: language.t('media.tab.playlists')),
                  Tab(text: language.t('media.tab.albums')),
                  Tab(text: language.t('media.tab.artists')),
                  Tab(text: language.t('media.tab.genres')),
                  Tab(text: language.t('media.tab.folders')),
                  Tab(text: language.t('media.tab.previous')),
                ]),
                Expanded(
                  child: StreamBuilder<Playlist>(
                    stream: player.stream.playlist,
                    initialData: player.state.playlist,
                    builder: (context, snapshot) {
                      final current = snapshot.data?.index ?? 0;
                      return TabBarView(children: [
                        _MediaPlaylistItems(
                          player: player,
                          items: items,
                          allItems: items,
                          language: language,
                          current: current,
                          onBeforeTrackChange: onBeforeTrackChange,
                        ),
                        _MediaPlaylistItems(
                          player: player,
                          items: items,
                          allItems: items,
                          language: language,
                          current: current,
                          onBeforeTrackChange: onBeforeTrackChange,
                        ),
                        _MediaPlaylistGroups(
                          groups: _groupItemsByFolder(items),
                          allItems: items,
                          player: player,
                          language: language,
                          current: current,
                          onBeforeTrackChange: onBeforeTrackChange,
                        ),
                        _MediaPlaylistGroups(
                          groups: _groupItemsByFolder(items),
                          allItems: items,
                          player: player,
                          language: language,
                          current: current,
                          onBeforeTrackChange: onBeforeTrackChange,
                        ),
                        _MediaPlaylistGroups(
                          groups: _groupItemsByArtist(items),
                          allItems: items,
                          player: player,
                          language: language,
                          current: current,
                          onBeforeTrackChange: onBeforeTrackChange,
                        ),
                        _MediaPlaylistGroups(
                          groups: {
                            language.t('media.group.unknown'): items,
                          },
                          allItems: items,
                          player: player,
                          language: language,
                          current: current,
                          onBeforeTrackChange: onBeforeTrackChange,
                        ),
                        _MediaPlaylistGroups(
                          groups: _groupItemsByFolder(items),
                          allItems: items,
                          player: player,
                          language: language,
                          current: current,
                          onBeforeTrackChange: onBeforeTrackChange,
                        ),
                        _MediaPlaylistItems(
                          player: player,
                          items: items.reversed.take(25).toList(),
                          allItems: items,
                          language: language,
                          current: current,
                          onBeforeTrackChange: onBeforeTrackChange,
                        ),
                      ]);
                    },
                  ),
                ),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Map<String, List<MediaPreviewItem>> _groupItemsByFolder(
      List<MediaPreviewItem> items) {
    final result = <String, List<MediaPreviewItem>>{};
    for (final item in items) {
      final path = item.path ?? item.resumeKey ?? item.title;
      final label = _parentLabel(path);
      result.putIfAbsent(label, () => <MediaPreviewItem>[]).add(item);
    }
    return result;
  }

  Map<String, List<MediaPreviewItem>> _groupItemsByArtist(
      List<MediaPreviewItem> items) {
    final result = <String, List<MediaPreviewItem>>{};
    for (final item in items) {
      final parts = item.title.split(RegExp(r'\s*-\s*'));
      final label = parts.length > 1
          ? parts.first.trim()
          : language.t('media.group.unknown');
      result
          .putIfAbsent(
              label.isEmpty ? language.t('media.group.unknown') : label,
              () => <MediaPreviewItem>[])
          .add(item);
    }
    return result;
  }

  String _parentLabel(String path) {
    try {
      return basename(File(path).parent.path);
    } catch (_) {
      final parts = path.split(RegExp(r'[\\/]')).where((p) => p.isNotEmpty);
      return parts.length > 1 ? parts.elementAt(parts.length - 2) : path;
    }
  }
}

class _MediaPlaylistItems extends StatelessWidget {
  const _MediaPlaylistItems({
    required this.player,
    required this.items,
    required this.allItems,
    required this.language,
    required this.current,
    required this.onBeforeTrackChange,
  });

  final Player player;
  final List<MediaPreviewItem> items;
  final List<MediaPreviewItem> allItems;
  final AppLanguage language;
  final int current;
  final Future<void> Function() onBeforeTrackChange;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return Center(child: Text(language.t('explorer.empty')));
    return ListView.builder(
      shrinkWrap: true,
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final actualIndex = allItems.indexOf(item);
        final selected = actualIndex == current;
        return ListTile(
          dense: true,
          selected: selected,
          leading: Icon(
            item.kind == FileContentKind.video
                ? Icons.movie_outlined
                : Icons.audiotrack_outlined,
          ),
          title: Text(item.title, maxLines: 1),
          subtitle:
              item.encrypted ? Text(language.t('media.encrypted.item')) : null,
          onTap: actualIndex < 0
              ? null
              : () => unawaited(() async {
                    await onBeforeTrackChange();
                    await player.jump(actualIndex);
                  }()),
        );
      },
    );
  }
}

class _MediaPlaylistGroups extends StatelessWidget {
  const _MediaPlaylistGroups({
    required this.groups,
    required this.allItems,
    required this.player,
    required this.language,
    required this.current,
    required this.onBeforeTrackChange,
  });

  final Map<String, List<MediaPreviewItem>> groups;
  final List<MediaPreviewItem> allItems;
  final Player player;
  final AppLanguage language;
  final int current;
  final Future<void> Function() onBeforeTrackChange;

  @override
  Widget build(BuildContext context) {
    final names = groups.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return ListView.builder(
      itemCount: names.length,
      itemBuilder: (context, index) {
        final name = names[index];
        final items = groups[name] ?? const <MediaPreviewItem>[];
        return ExpansionTile(
          title: Text(name),
          subtitle: Text('${items.length}'),
          children: [
            _MediaPlaylistItems(
              player: player,
              items: items,
              allItems: allItems,
              language: language,
              current: current,
              onBeforeTrackChange: onBeforeTrackChange,
            ),
          ],
        );
      },
    );
  }
}

class _TextBinaryEditorDialog extends StatefulWidget {
  const _TextBinaryEditorDialog({
    required this.preview,
    required this.language,
    required this.currentDirectory,
    required this.defaultOutputPath,
    required this.onSaveBytes,
  });

  final FilePreview preview;
  final AppLanguage language;
  final String? currentDirectory;
  final String defaultOutputPath;
  final Future<String> Function(String path, List<int> bytes) onSaveBytes;

  @override
  State<_TextBinaryEditorDialog> createState() =>
      _TextBinaryEditorDialogState();
}

class _TextBinaryEditorDialogState extends State<_TextBinaryEditorDialog> {
  late Uint8List _bytes;
  late final TextEditingController _controller;
  late final TextEditingController _searchController;
  late final TextEditingController _outputController;
  late final ScrollController _editorScrollController;
  var _mode = 'text';
  var _encoding = 'auto';
  var _busy = false;
  String? _status;
  int _lastSearchIndex = -1;

  @override
  void initState() {
    super.initState();
    _bytes = Uint8List.fromList(widget.preview.bytes ?? const <int>[]);
    _controller = TextEditingController();
    _searchController = TextEditingController();
    _editorScrollController = ScrollController();
    _outputController = TextEditingController(text: widget.defaultOutputPath);
    _rebuildEditorText();
  }

  @override
  void dispose() {
    _controller.dispose();
    _searchController.dispose();
    _outputController.dispose();
    _editorScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final language = widget.language;
    final compact = MediaQuery.sizeOf(context).width < 760;
    return Dialog.fullscreen(
      child: Scaffold(
        endDrawer: compact
            ? Drawer(
                width: math.min(360, MediaQuery.sizeOf(context).width * 0.88),
                child: SafeArea(child: _sidePanel(language)),
              )
            : null,
        appBar: AppBar(
          title: Text(language.t('editor.text.title')),
          actions: [
            if (compact)
              Builder(
                builder: (context) => IconButton(
                  onPressed: () => Scaffold.of(context).openEndDrawer(),
                  icon: const Icon(Icons.tune_outlined),
                  tooltip: language.t('editor.text.convert'),
                ),
              ),
            IconButton(
              onPressed: _busy ? null : _save,
              icon: const Icon(Icons.save_outlined),
              tooltip: language.t('editor.save.as'),
            ),
          ],
        ),
        body: compact
            ? _editorPane(language)
            : Row(children: [
                Expanded(child: _editorPane(language)),
                SizedBox(width: 340, child: _sidePanel(language)),
              ]),
      ),
    );
  }

  Widget _editorPane(AppLanguage language) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<String>(
              segments: [
                ButtonSegment(
                  value: 'text',
                  label: Text(language.t('editor.text.mode.text')),
                ),
                ButtonSegment(
                  value: 'hex',
                  label: Text(language.t('editor.text.mode.hex')),
                ),
                ButtonSegment(
                  value: 'binary',
                  label: Text(language.t('editor.text.mode.binary')),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (value) {
                _syncBytesFromEditor();
                setState(() {
                  _mode = value.first;
                  _rebuildEditorText();
                });
              },
            ),
            DropdownButton<String>(
              value: _encoding,
              items: [
                const DropdownMenuItem(value: 'auto', child: Text('auto')),
                for (final encoding in FileViewerService.knownTextEncodings)
                  DropdownMenuItem(value: encoding, child: Text(encoding)),
              ],
              onChanged: _mode == 'text'
                  ? (value) => setState(() {
                        _encoding = value ?? 'auto';
                        _rebuildEditorText();
                      })
                  : null,
            ),
            SizedBox(
              width: math.min(
                  280, math.max(180, MediaQuery.sizeOf(context).width - 48)),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  labelText: language.t('editor.text.search'),
                  suffixIcon: IconButton(
                    onPressed: _findNext,
                    icon: const Icon(Icons.search),
                  ),
                ),
                onSubmitted: (_) => _findNext(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: TextField(
            controller: _controller,
            scrollController: _editorScrollController,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            maxLines: null,
            minLines: null,
            style: const TextStyle(
              fontFamily: 'Consolas',
              fontSize: 13,
              height: 1.35,
            ),
            decoration: InputDecoration(
              alignLabelWithHint: true,
              labelText: widget.preview.title,
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        if (_status != null) ...[
          const SizedBox(height: 8),
          Align(alignment: Alignment.centerLeft, child: Text(_status!)),
        ],
      ]),
    );
  }

  Widget _sidePanel(AppLanguage language) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          language.t('editor.text.convert'),
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text(language.t('editor.text.convert.note')),
        const SizedBox(height: 16),
        _PathTextField(
          controller: _outputController,
          label: language.t('editor.output.path'),
          pickDirectory: false,
          multiLine: false,
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : _saveAs,
          icon: const Icon(Icons.save_as_outlined),
          label: Text(language.t('editor.save.as')),
        ),
      ],
    );
  }

  void _rebuildEditorText() {
    _controller.text = switch (_mode) {
      'hex' => _toHex(_bytes),
      'binary' => _toBinary(_bytes),
      _ => FileViewerService.decodeText(_bytes, encoding: _encoding),
    };
  }

  void _syncBytesFromEditor() {
    try {
      _bytes = switch (_mode) {
        'hex' => _parseHex(_controller.text),
        'binary' => _parseBinary(_controller.text),
        _ => FileViewerService.encodeText(
            _controller.text,
            encoding: _encoding == 'auto' ? 'utf-8' : _encoding,
          ),
      };
      _status = null;
    } catch (error) {
      _status = '${widget.language.t('editor.error')} $error';
    }
  }

  Future<void> _save() async {
    if (_canOverwriteSource(widget.preview)) {
      _outputController.text = widget.preview.sourcePath!;
    }
    await _saveAs();
  }

  Future<void> _saveAs() async {
    setState(() => _busy = true);
    try {
      _syncBytesFromEditor();
      final path = _outputController.text.trim();
      if (path.isEmpty) throw const FormatException('Output path is empty.');
      final savedPath = await widget.onSaveBytes(path, _bytes);
      if (mounted) Navigator.pop(context, savedPath);
    } catch (error) {
      if (mounted) {
        setState(() => _status = '${widget.language.t('editor.error')} $error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _findNext() {
    final query = _searchController.text;
    if (query.isEmpty) return;
    final text = _controller.text;
    final start = (_lastSearchIndex + query.length).clamp(0, text.length);
    var index = text.toLowerCase().indexOf(query.toLowerCase(), start);
    if (index < 0 && start > 0) {
      index = text.toLowerCase().indexOf(query.toLowerCase());
    }
    if (index < 0) {
      setState(() => _status = widget.language.t('editor.text.search.none'));
      return;
    }
    _lastSearchIndex = index;
    _controller.selection = TextSelection(
      baseOffset: index,
      extentOffset: index + query.length,
    );
    _scrollEditorToOffset(index, text);
    setState(() => _status = null);
  }

  void _scrollEditorToOffset(int offset, String text) {
    if (!_editorScrollController.hasClients) return;
    final before = text.substring(0, offset.clamp(0, text.length).toInt());
    final line = '\n'.allMatches(before).length;
    final target = (line * 17.5).clamp(
      0.0,
      _editorScrollController.position.maxScrollExtent,
    );
    _editorScrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  bool _canOverwriteSource(FilePreview preview) {
    final path = preview.sourcePath;
    if (path == null || preview.decrypted) return false;
    return !(path.startsWith('remote://') ||
        path.startsWith('zip://') ||
        path.startsWith('rar://') ||
        path.startsWith('torrent://'));
  }

  String _toHex(Uint8List bytes) {
    final buffer = StringBuffer();
    for (var i = 0; i < bytes.length; i += 16) {
      final chunk = bytes.sublist(i, math.min(i + 16, bytes.length));
      final hex =
          chunk.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(' ');
      final ascii = _printableText(chunk);
      if (buffer.isNotEmpty) buffer.write('\n');
      buffer.write(
        '${i.toRadixString(16).padLeft(8, '0')}  '
        '${hex.padRight(47)}  |$ascii|',
      );
    }
    return buffer.toString();
  }

  String _toBinary(Uint8List bytes) {
    final buffer = StringBuffer();
    for (var i = 0; i < bytes.length; i += 8) {
      final chunk = bytes.sublist(i, math.min(i + 8, bytes.length));
      final bits =
          chunk.map((byte) => byte.toRadixString(2).padLeft(8, '0')).join(' ');
      final ascii = _printableText(chunk);
      if (buffer.isNotEmpty) buffer.write('\n');
      buffer.write(
        '${i.toRadixString(16).padLeft(8, '0')}  '
        '${bits.padRight(71)}  |$ascii|',
      );
    }
    return buffer.toString();
  }

  Uint8List _parseHex(String value) {
    final bytes = <int>[];
    for (final line in value.split(RegExp(r'\r?\n'))) {
      final left = line.split('|').first.replaceFirst(
            RegExp(r'^\s*[0-9a-fA-F]{8}\s+'),
            '',
          );
      for (final match in RegExp(r'\b[0-9a-fA-F]{2}\b').allMatches(left)) {
        bytes.add(int.parse(match.group(0)!, radix: 16));
      }
    }
    return Uint8List.fromList(bytes);
  }

  Uint8List _parseBinary(String value) {
    final bytes = <int>[];
    for (final line in value.split(RegExp(r'\r?\n'))) {
      final left = line.split('|').first.replaceFirst(
            RegExp(r'^\s*[0-9a-fA-F]{8}\s+'),
            '',
          );
      for (final match in RegExp(r'\b[01]{8}\b').allMatches(left)) {
        bytes.add(int.parse(match.group(0)!, radix: 2));
      }
    }
    return Uint8List.fromList(bytes);
  }

  String _printableText(List<int> bytes) {
    final decoded = FileViewerService.decodeText(
      bytes,
      encoding: _encoding == 'auto' ? 'utf-8' : _encoding,
      trim: false,
    );
    return decoded
        .replaceAll(RegExp(r'[\r\n\t]'), ' ')
        .replaceAll(RegExp(r'[\u0000-\u001F]'), '.');
  }
}

class _DrawStroke {
  _DrawStroke({required this.color, required this.width});

  final Color color;
  final double width;
  final points = <Offset>[];
}

class _StrokePainter extends CustomPainter {
  const _StrokePainter(this.strokes);

  final List<_DrawStroke> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in strokes) {
      if (stroke.points.length < 2) continue;
      final paint = Paint()
        ..color = stroke.color
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = stroke.width;
      for (var i = 1; i < stroke.points.length; i++) {
        canvas.drawLine(
          Offset(stroke.points[i - 1].dx * size.width,
              stroke.points[i - 1].dy * size.height),
          Offset(stroke.points[i].dx * size.width,
              stroke.points[i].dy * size.height),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _StrokePainter oldDelegate) => true;
}

class _ImageEditorDialog extends StatefulWidget {
  const _ImageEditorDialog({
    required this.preview,
    required this.language,
    required this.currentDirectory,
    required this.defaultOutputPath,
    required this.onSaveBytes,
  });

  final FilePreview preview;
  final AppLanguage language;
  final String? currentDirectory;
  final String defaultOutputPath;
  final Future<String> Function(String path, List<int> bytes) onSaveBytes;

  @override
  State<_ImageEditorDialog> createState() => _ImageEditorDialogState();
}

class _ImageEditorDialogState extends State<_ImageEditorDialog> {
  late img.Image _image;
  late Uint8List _baseBytes;
  late final TextEditingController _outputController;
  final _strokes = <_DrawStroke>[];
  var _format = 'png';
  var _busy = false;
  Color _brushColor = Colors.red;
  var _brushWidth = 6.0;
  _DrawStroke? _activeStroke;

  @override
  void initState() {
    super.initState();
    final decoded = img.decodeImage(Uint8List.fromList(widget.preview.bytes!));
    _image = decoded ?? img.Image(width: 1024, height: 1024);
    _baseBytes = Uint8List.fromList(img.encodePng(_image));
    _outputController = TextEditingController(text: widget.defaultOutputPath);
  }

  @override
  void dispose() {
    _outputController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 760;
    return Dialog.fullscreen(
      child: Scaffold(
        endDrawer: compact
            ? Drawer(
                width: math.min(360, MediaQuery.sizeOf(context).width * 0.9),
                child: SafeArea(child: _toolPanel()),
              )
            : null,
        appBar: AppBar(
          title: Text(widget.language.t('editor.image.title')),
          actions: [
            if (compact)
              Builder(
                builder: (context) => IconButton(
                  onPressed: () => Scaffold.of(context).openEndDrawer(),
                  icon: const Icon(Icons.tune_outlined),
                  tooltip: widget.language.t('editor.image.title'),
                ),
              ),
            IconButton(
              onPressed: _busy ? null : _save,
              icon: const Icon(Icons.save_outlined),
              tooltip: widget.language.t('editor.save.as'),
            ),
          ],
        ),
        body: compact
            ? _canvasPane()
            : Row(children: [
                Expanded(child: _canvasPane()),
                SizedBox(width: 360, child: _toolPanel()),
              ]),
      ),
    );
  }

  Widget _canvasPane() {
    return Padding(
      padding: EdgeInsets.all(MediaQuery.sizeOf(context).width < 520 ? 8 : 16),
      child: Center(
        child: AspectRatio(
          aspectRatio: _image.width / math.max(_image.height, 1),
          child: LayoutBuilder(builder: (context, constraints) {
            return GestureDetector(
              onPanStart: (details) {
                final box = context.findRenderObject() as RenderBox;
                _activeStroke =
                    _DrawStroke(color: _brushColor, width: _brushWidth);
                _activeStroke!.points.add(_normalizePoint(
                  box.globalToLocal(details.globalPosition),
                  box.size,
                ));
                setState(() => _strokes.add(_activeStroke!));
              },
              onPanUpdate: (details) {
                final stroke = _activeStroke;
                if (stroke == null) return;
                final box = context.findRenderObject() as RenderBox;
                setState(() => stroke.points.add(_normalizePoint(
                      box.globalToLocal(details.globalPosition),
                      box.size,
                    )));
              },
              onPanEnd: (_) => _activeStroke = null,
              child: Stack(fit: StackFit.expand, children: [
                Image.memory(_baseBytes, fit: BoxFit.contain),
                CustomPaint(painter: _StrokePainter(_strokes)),
              ]),
            );
          }),
        ),
      ),
    );
  }

  Widget _toolPanel() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PathTextField(
            controller: _outputController,
            label: widget.language.t('editor.output.path'),
            pickDirectory: false,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _format,
            decoration: InputDecoration(
              labelText: widget.language.t('editor.output.format'),
            ),
            items: const [
              DropdownMenuItem(value: 'png', child: Text('PNG')),
              DropdownMenuItem(value: 'jpg', child: Text('JPG')),
              DropdownMenuItem(value: 'bmp', child: Text('BMP')),
            ],
            onChanged: (value) => setState(() => _format = value ?? 'png'),
          ),
          const Divider(height: 28),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
              onPressed: _rotateRight,
              icon: const Icon(Icons.rotate_right),
              label: Text(widget.language.t('editor.rotate.right')),
            ),
            OutlinedButton.icon(
              onPressed: _cropCenter,
              icon: const Icon(Icons.crop),
              label: Text(widget.language.t('editor.crop.center')),
            ),
            OutlinedButton.icon(
              onPressed: _undoLayer,
              icon: const Icon(Icons.undo),
              label: Text(widget.language.t('editor.layer.undo')),
            ),
            OutlinedButton.icon(
              onPressed: _clearLayers,
              icon: const Icon(Icons.layers_clear),
              label: Text(widget.language.t('editor.layer.clear')),
            ),
          ]),
          const SizedBox(height: 12),
          Text(widget.language.t('editor.draw.hint')),
          Slider(
            value: _brushWidth,
            min: 2,
            max: 24,
            label: _brushWidth.round().toString(),
            onChanged: (value) => setState(() => _brushWidth = value),
          ),
          SegmentedButton<Color>(
            segments: const [
              ButtonSegment(value: Colors.red, label: Text('Red')),
              ButtonSegment(value: Colors.blue, label: Text('Blue')),
              ButtonSegment(value: Colors.black, label: Text('Black')),
              ButtonSegment(value: Colors.white, label: Text('Erase')),
            ],
            selected: {_brushColor},
            onSelectionChanged: (value) =>
                setState(() => _brushColor = value.first),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: Text(widget.language.t('editor.save.as')),
          ),
        ],
      ),
    );
  }

  Offset _normalizePoint(Offset point, Size size) => Offset(
        (point.dx / math.max(size.width, 1)).clamp(0.0, 1.0),
        (point.dy / math.max(size.height, 1)).clamp(0.0, 1.0),
      );

  void _rotateRight() {
    setState(() {
      _image = img.copyRotate(_compositedImage(), angle: 90);
      _baseBytes = Uint8List.fromList(img.encodePng(_image));
      _strokes.clear();
    });
  }

  void _cropCenter() {
    final composed = _compositedImage();
    final width = (composed.width * 0.8).round().clamp(1, composed.width);
    final height = (composed.height * 0.8).round().clamp(1, composed.height);
    setState(() {
      _image = img.copyCrop(
        composed,
        x: ((composed.width - width) / 2).round(),
        y: ((composed.height - height) / 2).round(),
        width: width,
        height: height,
      );
      _baseBytes = Uint8List.fromList(img.encodePng(_image));
      _strokes.clear();
    });
  }

  void _undoLayer() {
    if (_strokes.isEmpty) return;
    setState(() => _strokes.removeLast());
  }

  void _clearLayers() => setState(_strokes.clear);

  img.Image _compositedImage() {
    final output = img.Image.from(_image);
    for (final stroke in _strokes) {
      if (stroke.points.length < 2) continue;
      final color = img.ColorRgba8(
        _colorByte(stroke.color.r),
        _colorByte(stroke.color.g),
        _colorByte(stroke.color.b),
        _colorByte(stroke.color.a),
      );
      for (var i = 1; i < stroke.points.length; i++) {
        img.drawLine(
          output,
          x1: (stroke.points[i - 1].dx * output.width).round(),
          y1: (stroke.points[i - 1].dy * output.height).round(),
          x2: (stroke.points[i].dx * output.width).round(),
          y2: (stroke.points[i].dy * output.height).round(),
          color: color,
          thickness: stroke.width,
        );
      }
    }
    return output;
  }

  int _colorByte(double value) => (value * 255).round().clamp(0, 255).toInt();

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final path = _ensureExtension(_outputController.text.trim(), _format);
      final output = _compositedImage();
      final bytes = switch (_format) {
        'jpg' => img.encodeJpg(output, quality: 92),
        'bmp' => img.encodeBmp(output),
        _ => img.encodePng(output),
      };
      final savedPath = await widget.onSaveBytes(path, bytes);
      if (mounted) Navigator.pop(context, savedPath);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('${widget.language.t('editor.error')} $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _MediaEditorTimeline extends StatelessWidget {
  const _MediaEditorTimeline({
    required this.preview,
    required this.isVideo,
    required this.range,
    required this.durationSeconds,
    required this.onChanged,
  });

  final FilePreview preview;
  final bool isVideo;
  final RangeValues range;
  final double durationSeconds;
  final ValueChanged<RangeValues> onChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            height: 86,
            child: CustomPaint(
              painter: isVideo
                  ? _VideoTimelinePainter(range: range)
                  : _AudioWaveformPainter(
                      bytes: preview.bytes,
                      range: range,
                    ),
            ),
          ),
          RangeSlider(
            values: range,
            min: 0,
            max: 1,
            divisions: 1000,
            labels: RangeLabels(
              _secondsToTimestamp(durationSeconds * range.start),
              _secondsToTimestamp(durationSeconds * range.end),
            ),
            onChanged: onChanged,
          ),
        ]),
      ),
    );
  }
}

class _AudioWaveformPainter extends CustomPainter {
  const _AudioWaveformPainter({required this.bytes, required this.range});

  final List<int>? bytes;
  final RangeValues range;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.height / 2;
    final bars = math.max(48, size.width ~/ 4);
    final paint = Paint()
      ..color = const Color(0xFF0F4C81)
      ..strokeWidth = math.max(1, size.width / bars * .55);
    final raw = bytes ?? const <int>[];
    for (var i = 0; i < bars; i++) {
      final x = i / math.max(1, bars - 1) * size.width;
      final sample = raw.isEmpty
          ? (math.sin(i * .42) * .5 + .5)
          : raw[(i * raw.length / bars).floor().clamp(0, raw.length - 1)] /
              255.0;
      final height = (sample * size.height * .82).clamp(4.0, size.height);
      canvas.drawLine(
        Offset(x, center - height / 2),
        Offset(x, center + height / 2),
        paint,
      );
    }
    _paintSelection(canvas, size, range);
  }

  @override
  bool shouldRepaint(covariant _AudioWaveformPainter oldDelegate) =>
      oldDelegate.bytes != bytes || oldDelegate.range != range;
}

class _VideoTimelinePainter extends CustomPainter {
  const _VideoTimelinePainter({required this.range});

  final RangeValues range;

  @override
  void paint(Canvas canvas, Size size) {
    final frameWidth = math.max(54.0, size.width / 8);
    for (var x = 0.0; x < size.width; x += frameWidth + 6) {
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(
            x, 8, math.min(frameWidth, size.width - x), size.height - 16),
        const Radius.circular(10),
      );
      final hue = (x / math.max(1, size.width) * 255).round();
      final paint = Paint()
        ..shader = LinearGradient(
          colors: [
            HSVColor.fromAHSV(1, hue.toDouble(), .42, .78).toColor(),
            HSVColor.fromAHSV(1, (hue + 28).toDouble(), .58, .52).toColor(),
          ],
        ).createShader(rect.outerRect);
      canvas.drawRRect(rect, paint);
      canvas.drawCircle(
        Offset(x + frameWidth / 2, size.height / 2),
        12,
        Paint()..color = Colors.white.withValues(alpha: .72),
      );
      canvas.drawPath(
        Path()
          ..moveTo(x + frameWidth / 2 - 4, size.height / 2 - 7)
          ..lineTo(x + frameWidth / 2 - 4, size.height / 2 + 7)
          ..lineTo(x + frameWidth / 2 + 8, size.height / 2)
          ..close(),
        Paint()..color = const Color(0xFF203040),
      );
    }
    _paintSelection(canvas, size, range);
  }

  @override
  bool shouldRepaint(covariant _VideoTimelinePainter oldDelegate) =>
      oldDelegate.range != range;
}

void _paintSelection(Canvas canvas, Size size, RangeValues range) {
  final left = range.start * size.width;
  final right = range.end * size.width;
  final overlay = Paint()..color = Colors.black.withValues(alpha: .34);
  if (left > 0) {
    canvas.drawRect(Rect.fromLTWH(0, 0, left, size.height), overlay);
  }
  if (right < size.width) {
    canvas.drawRect(
        Rect.fromLTWH(right, 0, size.width - right, size.height), overlay);
  }
  final border = Paint()
    ..color = const Color(0xFFFFB000)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2;
  canvas.drawRect(
    Rect.fromLTRB(left, 2, right, size.height - 2),
    border,
  );
}

class _FfmpegEditorDialog extends StatefulWidget {
  const _FfmpegEditorDialog({
    required this.preview,
    required this.language,
    required this.currentDirectory,
  });

  final FilePreview preview;
  final AppLanguage language;
  final String? currentDirectory;

  @override
  State<_FfmpegEditorDialog> createState() => _FfmpegEditorDialogState();
}

class _FfmpegEditorDialogState extends State<_FfmpegEditorDialog> {
  late final TextEditingController _outputController;
  final _startController = TextEditingController();
  final _endController = TextEditingController();
  final _appendController = TextEditingController();
  final _extraAudioController = TextEditingController();
  final _widthController = TextEditingController();
  final _heightController = TextEditingController();
  final _crfController = TextEditingController(text: '23');
  final _audioBitrateController = TextEditingController(text: '128k');
  RangeValues _timelineRange = const RangeValues(0, 1);
  double _durationSeconds = 60;
  var _rotateVideo = false;
  var _busy = false;
  String? _log;

  @override
  void initState() {
    super.initState();
    final directory = widget.currentDirectory ??
        (widget.preview.sourcePath == null
            ? Directory.current.path
            : File(widget.preview.sourcePath!).parent.path);
    final extension =
        widget.preview.contentKind == FileContentKind.video ? '.mp4' : '.mp3';
    _outputController = TextEditingController(
      text:
          '$directory${Platform.pathSeparator}${_fileNameWithoutExtension(widget.preview.title)}_edited$extension',
    );
    unawaited(_probeDuration());
  }

  @override
  void dispose() {
    _outputController.dispose();
    _startController.dispose();
    _endController.dispose();
    _appendController.dispose();
    _extraAudioController.dispose();
    _widthController.dispose();
    _heightController.dispose();
    _crfController.dispose();
    _audioBitrateController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.preview.contentKind == FileContentKind.video;
    return AlertDialog(
      title: Text(widget.language
          .t(isVideo ? 'editor.video.title' : 'editor.audio.title')),
      content: SizedBox(
        width: 680,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(widget.language.t('editor.ffmpeg.note')),
            const SizedBox(height: 12),
            _MediaEditorTimeline(
              preview: widget.preview,
              isVideo: isVideo,
              range: _timelineRange,
              durationSeconds: _durationSeconds,
              onChanged: (range) {
                setState(() => _timelineRange = range);
                _startController.text = _secondsToTimestamp(
                  _durationSeconds * range.start,
                );
                _endController.text = _secondsToTimestamp(
                  _durationSeconds * range.end,
                );
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _outputController,
              decoration: InputDecoration(
                labelText: widget.language.t('editor.output.path'),
              ),
            ),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _startController,
                  decoration: InputDecoration(
                    labelText: widget.language.t('editor.trim.start'),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _endController,
                  decoration: InputDecoration(
                    labelText: widget.language.t('editor.trim.end'),
                  ),
                ),
              ),
            ]),
            TextField(
              controller: _appendController,
              decoration: InputDecoration(
                labelText: widget.language
                    .t(isVideo ? 'editor.video.append' : 'editor.audio.append'),
              ),
            ),
            TextField(
              controller: _extraAudioController,
              decoration: InputDecoration(
                labelText: widget.language.t(isVideo
                    ? 'editor.video.replace.audio'
                    : 'editor.audio.mix'),
              ),
            ),
            if (isVideo) ...[
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _widthController,
                    decoration: InputDecoration(
                      labelText: widget.language.t('editor.video.width'),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _heightController,
                    decoration: InputDecoration(
                      labelText: widget.language.t('editor.video.height'),
                    ),
                  ),
                ),
              ]),
              SwitchListTile(
                value: _rotateVideo,
                onChanged: (value) => setState(() => _rotateVideo = value),
                title: Text(widget.language.t('editor.video.rotate')),
              ),
              TextField(
                controller: _crfController,
                decoration: InputDecoration(
                  labelText: widget.language.t('editor.video.quality'),
                ),
              ),
            ],
            TextField(
              controller: _audioBitrateController,
              decoration: InputDecoration(
                labelText: widget.language.t('editor.audio.quality'),
              ),
            ),
            if (_log != null) ...[
              const SizedBox(height: 12),
              SelectableText(_log!, maxLines: 8),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(widget.language.t('common.cancel')),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _run,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.movie_creation_outlined),
          label: Text(widget.language.t('editor.render')),
        ),
      ],
    );
  }

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _log = null;
    });
    File? tempSource;
    try {
      final ffmpeg = await Process.run('ffmpeg', ['-version']);
      if (ffmpeg.exitCode != 0) {
        throw StateError(widget.language.t('editor.ffmpeg.missing'));
      }

      var sourcePath = widget.preview.sourcePath;
      if (widget.preview.decrypted && widget.preview.bytes != null) {
        final tempDir =
            await Directory.systemTemp.createTemp('secure_vault_edit_');
        tempSource = File(
          '${tempDir.path}${Platform.pathSeparator}${_safeFileName(widget.preview.title)}',
        );
        await tempSource.writeAsBytes(widget.preview.bytes!, flush: true);
        sourcePath = tempSource.path;
      }
      if (sourcePath == null || sourcePath.isEmpty) {
        throw StateError(widget.language.t('media.unavailable'));
      }

      final outputPath = _outputController.text.trim();
      final args = _buildFfmpegArgs(sourcePath, outputPath);
      final result = await Process.run('ffmpeg', args);
      final log = '${result.stdout}\n${result.stderr}'.trim();
      if (result.exitCode != 0) {
        throw StateError(log.isEmpty ? 'ffmpeg exit ${result.exitCode}' : log);
      }
      if (mounted) Navigator.pop(context, outputPath);
    } catch (error) {
      if (mounted) {
        setState(() => _log = error.toString());
      }
    } finally {
      try {
        await tempSource?.parent.delete(recursive: true);
      } catch (_) {}
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _probeDuration() async {
    final source = widget.preview.sourcePath;
    if (source == null ||
        source.startsWith('remote://') ||
        source.startsWith('zip://') ||
        source.startsWith('rar://') ||
        source.startsWith('torrent://')) {
      return;
    }
    try {
      final result = await Process.run('ffprobe', [
        '-v',
        'error',
        '-show_entries',
        'format=duration',
        '-of',
        'default=noprint_wrappers=1:nokey=1',
        source,
      ]);
      final parsed = double.tryParse(result.stdout.toString().trim());
      if (mounted && parsed != null && parsed.isFinite && parsed > 0) {
        setState(() => _durationSeconds = parsed);
      }
    } catch (_) {
      // The editor still works through manual time fields when ffprobe is absent.
    }
  }

  List<String> _buildFfmpegArgs(String sourcePath, String outputPath) {
    final isVideo = widget.preview.contentKind == FileContentKind.video;
    final args = <String>['-y'];
    if (_startController.text.trim().isNotEmpty) {
      args.addAll(['-ss', _startController.text.trim()]);
    }
    if (_endController.text.trim().isNotEmpty) {
      args.addAll(['-to', _endController.text.trim()]);
    }
    args.addAll(['-i', sourcePath]);

    final append = _appendController.text.trim();
    final extraAudio = _extraAudioController.text.trim();
    if (append.isNotEmpty) args.addAll(['-i', append]);
    if (extraAudio.isNotEmpty) args.addAll(['-i', extraAudio]);

    final filters = <String>[];
    if (isVideo) {
      final width = _widthController.text.trim();
      final height = _heightController.text.trim();
      final videoFilters = <String>[
        if (width.isNotEmpty && height.isNotEmpty) 'scale=$width:$height',
        if (_rotateVideo) 'transpose=1',
      ];
      if (videoFilters.isNotEmpty) {
        filters.add(videoFilters.join(','));
      }
    }

    if (append.isNotEmpty) {
      if (isVideo) {
        args.addAll([
          '-filter_complex',
          '[0:v][0:a][1:v][1:a]concat=n=2:v=1:a=1[outv][outa]',
          '-map',
          '[outv]',
          '-map',
          '[outa]',
        ]);
      } else {
        args.addAll([
          '-filter_complex',
          '[0:a][1:a]concat=n=2:v=0:a=1[outa]',
          '-map',
          '[outa]',
        ]);
      }
    } else if (extraAudio.isNotEmpty) {
      if (isVideo) {
        args.addAll(['-map', '0:v:0', '-map', '1:a:0', '-shortest']);
      } else {
        args.addAll([
          '-filter_complex',
          '[0:a][1:a]amix=inputs=2:duration=longest[outa]',
          '-map',
          '[outa]',
        ]);
      }
    }

    if (filters.isNotEmpty && append.isEmpty) {
      args.addAll(['-vf', filters.join(',')]);
    }
    if (isVideo) {
      args.addAll(['-c:v', 'libx264', '-crf', _crfController.text.trim()]);
    }
    args.addAll(['-b:a', _audioBitrateController.text.trim()]);
    args.add(outputPath);
    return args;
  }
}

String _fileNameWithoutExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}

String _ensureExtension(String path, String extension) {
  if (path.toLowerCase().endsWith('.$extension')) return path;
  final dot = path.lastIndexOf('.');
  if (dot > path.lastIndexOf(Platform.pathSeparator)) {
    return '${path.substring(0, dot)}.$extension';
  }
  return '$path.$extension';
}

String _secondsToTimestamp(double seconds) {
  final total = seconds.round().clamp(0, 24 * 60 * 60 * 30);
  final hours = total ~/ 3600;
  final minutes = (total ~/ 60) % 60;
  final secs = total % 60;
  return '${hours.toString().padLeft(2, '0')}:'
      '${minutes.toString().padLeft(2, '0')}:'
      '${secs.toString().padLeft(2, '0')}';
}

String _safeFileName(String value) =>
    value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

bool _isEditablePreview(FilePreview preview) =>
    preview.contentKind == FileContentKind.image ||
    preview.contentKind == FileContentKind.audio ||
    preview.contentKind == FileContentKind.video ||
    preview.contentKind == FileContentKind.text ||
    preview.contentKind == FileContentKind.html ||
    preview.contentKind == FileContentKind.document ||
    preview.contentKind == FileContentKind.ebook ||
    preview.contentKind == FileContentKind.unknown;

bool _canOcrPreview(FilePreview preview) =>
    preview.contentKind == FileContentKind.image ||
    FileViewerService.extensionForName(preview.title) == '.pdf' ||
    FileViewerService.extensionForName(preview.sourcePath ?? '') == '.pdf';

class _EndpointFieldControllers {
  _EndpointFieldControllers({
    String label = '',
    String host = '',
    String port = '',
  })  : label = TextEditingController(text: label),
        host = TextEditingController(text: host),
        port = TextEditingController(text: port);

  final TextEditingController label;
  final TextEditingController host;
  final TextEditingController port;

  void dispose() {
    label.dispose();
    host.dispose();
    port.dispose();
  }
}

class _ConnectionProfileDialog extends StatefulWidget {
  const _ConnectionProfileDialog({
    required this.language,
    required this.plugin,
    this.availableProfiles = const <PluginConnectionProfile>[],
    this.initialProfile,
  });

  final AppLanguage language;
  final CloudPluginDefinition plugin;
  final List<PluginConnectionProfile> availableProfiles;
  final PluginConnectionProfile? initialProfile;

  @override
  State<_ConnectionProfileDialog> createState() =>
      _ConnectionProfileDialogState();
}

class _ConnectionProfileDialogState extends State<_ConnectionProfileDialog> {
  late final TextEditingController _nameController;
  final Map<String, TextEditingController> _variableControllers =
      <String, TextEditingController>{};
  final List<_EndpointFieldControllers> _endpoints =
      <_EndpointFieldControllers>[];
  final Set<String> _selectedRaidMembers = <String>{};
  String? _error;

  static const _endpointVariableKeys = <String>{
    'host',
    'server',
    'baseUrl',
    'port',
  };

  @override
  void initState() {
    super.initState();
    final initialProfile = widget.initialProfile;
    _nameController =
        TextEditingController(text: initialProfile?.name ?? widget.plugin.name);
    final variables = widget.plugin.variables ?? const <String, Object?>{};
    for (final entry in variables.entries) {
      if (_endpointVariableKeys.contains(entry.key)) {
        continue;
      }
      if (_isRaidPlugin && entry.key == 'members') {
        continue;
      }
      _variableControllers[entry.key] = TextEditingController(
        text: initialProfile?.variables[entry.key] ??
            _variableDefault(entry.value),
      );
    }
    if (_isRaidPlugin) {
      _selectedRaidMembers.addAll(
        _splitProfileList(
          initialProfile?.variables['members'] ??
              initialProfile?.variables['memberProfileIds'] ??
              '',
        ),
      );
    }
    if (initialProfile != null && initialProfile.endpoints.isNotEmpty) {
      _endpoints.addAll(
        initialProfile.endpoints.map(
          (endpoint) => _EndpointFieldControllers(
            label: endpoint.label,
            host: endpoint.host,
            port: endpoint.port?.toString() ?? '',
          ),
        ),
      );
      return;
    }
    final endpointHost = _variableDefault(variables['host']).isNotEmpty
        ? _variableDefault(variables['host'])
        : _variableDefault(variables['server']).isNotEmpty
            ? _variableDefault(variables['server'])
            : _variableDefault(variables['baseUrl']);
    final endpointPort = _variableDefault(variables['port']);
    if (_requiresEndpoint) {
      _endpoints.add(
        _EndpointFieldControllers(host: endpointHost, port: endpointPort),
      );
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    for (final controller in _variableControllers.values) {
      controller.dispose();
    }
    for (final endpoint in _endpoints) {
      endpoint.dispose();
    }
    super.dispose();
  }

  bool get _requiresEndpoint {
    final variables = widget.plugin.variables ?? const <String, Object?>{};
    return variables.keys.any(_endpointVariableKeys.contains);
  }

  bool get _isRaidPlugin {
    final executor = widget.plugin.components?['executor']?.toString() ??
        widget.plugin.pluginType;
    return executor == 'raid0' || executor == 'raid1';
  }

  @override
  Widget build(BuildContext context) {
    final language = widget.language;
    final compact = MediaQuery.sizeOf(context).width < 640;
    final title = widget.initialProfile == null
        ? language.t('locations.profile.title')
        : language.t('locations.profile.edit');
    final content = _profileForm(context);
    final actions = [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(language.t('common.cancel')),
      ),
      FilledButton(
        onPressed: _save,
        child: Text(widget.initialProfile == null
            ? language.t('locations.profile.save')
            : language.t('locations.profile.update')),
      ),
    ];
    if (compact) {
      return Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: Text(title),
            actions: [
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
                tooltip: language.t('common.cancel'),
              ),
              IconButton(
                onPressed: _save,
                icon: const Icon(Icons.check),
                tooltip: widget.initialProfile == null
                    ? language.t('locations.profile.save')
                    : language.t('locations.profile.update'),
              ),
            ],
          ),
          body: SafeArea(child: content),
        ),
      );
    }
    return AlertDialog(
      title: Text(title),
      content: SizedBox(width: 680, child: content),
      actions: actions,
    );
  }

  Widget _profileForm(BuildContext context) {
    final language = widget.language;
    final variables = widget.plugin.variables ?? const <String, Object?>{};
    final compact = MediaQuery.sizeOf(context).width < 640;
    return SingleChildScrollView(
      padding: EdgeInsets.only(
        left: compact ? 18 : 0,
        right: compact ? 18 : 0,
        top: compact ? 14 : 0,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.plugin.name,
              style: Theme.of(context).textTheme.titleMedium),
          if (widget.plugin.description != null) ...[
            const SizedBox(height: 4),
            Text(widget.plugin.description!),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _nameController,
            decoration: InputDecoration(
              labelText: language.t('locations.profile.name'),
            ),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                language.t('locations.profile.endpoint'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              TextButton.icon(
                onPressed: _addEndpoint,
                icon: const Icon(Icons.add),
                label: Text(language.t('locations.profile.endpoint.add')),
              ),
            ],
          ),
          if (_endpoints.isEmpty)
            Text(language.t('locations.profile.endpoint.optional'))
          else
            for (var i = 0; i < _endpoints.length; i++) ...[
              _EndpointEditorRow(
                language: language,
                index: i,
                total: _endpoints.length,
                controllers: _endpoints[i],
                onMoveUp: i == 0 ? null : () => _moveEndpoint(i, -1),
                onMoveDown: i == _endpoints.length - 1
                    ? null
                    : () => _moveEndpoint(i, 1),
                onRemove: () => _removeEndpoint(i),
              ),
              const SizedBox(height: 8),
            ],
          const SizedBox(height: 12),
          Text(
            language.t('locations.profile.parameters'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          if (_variableControllers.isEmpty)
            Text(_isRaidPlugin
                ? language.t('locations.profile.raid.choose')
                : language.t('settings.plugin.no.global.settings'))
          else
            for (final entry in _variableControllers.entries) ...[
              TextField(
                controller: entry.value,
                obscureText: _isSecret(variables[entry.key]),
                decoration: InputDecoration(
                  labelText:
                      _pluginVariableLabel(entry.key, variables[entry.key]),
                ),
              ),
              const SizedBox(height: 8),
            ],
          if (_isRaidPlugin) ...[
            const SizedBox(height: 12),
            Text(
              language.t('locations.profile.raid.members'),
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            if (_raidMemberCandidates.isEmpty)
              Text(language.t('locations.profile.raid.empty'))
            else
              for (final profile in _raidMemberCandidates)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _selectedRaidMembers.contains(profile.runtimePluginId),
                  title: Text(profile.name),
                  subtitle: Text(profile.runtimePluginId),
                  onChanged: (value) {
                    setState(() {
                      if (value == true) {
                        _selectedRaidMembers.add(profile.runtimePluginId);
                      } else {
                        _selectedRaidMembers.remove(profile.runtimePluginId);
                      }
                    });
                  },
                ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }

  void _addEndpoint() {
    setState(() => _endpoints.add(_EndpointFieldControllers()));
  }

  void _removeEndpoint(int index) {
    final endpoint = _endpoints.removeAt(index);
    endpoint.dispose();
    setState(() {});
  }

  void _moveEndpoint(int index, int direction) {
    final item = _endpoints.removeAt(index);
    _endpoints.insert(index + direction, item);
    setState(() {});
  }

  void _save() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = widget.language.t('locations.profile.need.name'));
      return;
    }
    final endpoints = <PluginConnectionEndpoint>[];
    for (final controller in _endpoints) {
      final host = controller.host.text.trim();
      if (host.isEmpty) continue;
      endpoints.add(
        PluginConnectionEndpoint(
          label: controller.label.text.trim(),
          host: host,
          port: int.tryParse(controller.port.text.trim()),
        ),
      );
    }
    if (_requiresEndpoint && endpoints.isEmpty) {
      setState(
          () => _error = widget.language.t('locations.profile.need.endpoint'));
      return;
    }
    if (_isRaidPlugin && _selectedRaidMembers.length < 2) {
      setState(
          () => _error = widget.language.t('locations.profile.raid.need.two'));
      return;
    }
    final variables = <String, String>{};
    for (final entry in _variableControllers.entries) {
      final value = entry.value.text.trim();
      if (value.isNotEmpty) {
        variables[entry.key] = value;
      }
    }
    if (_isRaidPlugin) {
      variables['members'] = _selectedRaidMembers.join(',');
    }
    final initialProfile = widget.initialProfile;
    final profile = initialProfile == null
        ? PluginConnectionProfile.create(
            pluginId: widget.plugin.id,
            name: name,
            variables: variables,
            endpoints: endpoints,
          )
        : initialProfile.copyWith(
            name: name,
            variables: variables,
            endpoints: endpoints,
          );
    Navigator.pop(
      context,
      profile,
    );
  }

  List<PluginConnectionProfile> get _raidMemberCandidates =>
      widget.availableProfiles
          .where((profile) => profile.id != widget.initialProfile?.id)
          .toList();

  List<String> _splitProfileList(String value) => value
      .split(RegExp(r'[,;\n]'))
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .map((item) => item.startsWith('profile-') ? item : 'profile-$item')
      .toList();

  bool _isSecret(Object? value) => value is Map && value['secret'] == true;

  String _variableDefault(Object? value) {
    if (value is Map && value['default'] != null) {
      return value['default'].toString();
    }
    return '';
  }

  String _pluginVariableLabel(String key, Object? value) {
    if (value is Map && value['label'] != null) {
      return value['label'].toString();
    }
    return key;
  }
}

class _EndpointEditorRow extends StatelessWidget {
  const _EndpointEditorRow({
    required this.language,
    required this.index,
    required this.total,
    required this.controllers,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onRemove,
  });

  final AppLanguage language;
  final int index;
  final int total;
  final _EndpointFieldControllers controllers;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final fields = [
      Expanded(
        flex: 2,
        child: TextField(
          controller: controllers.label,
          decoration: InputDecoration(
            labelText: language.t('locations.profile.endpoint.label'),
          ),
        ),
      ),
      const SizedBox(width: 8, height: 8),
      Expanded(
        flex: 3,
        child: TextField(
          controller: controllers.host,
          decoration: InputDecoration(
            labelText: language.t('locations.profile.endpoint.host'),
          ),
        ),
      ),
      const SizedBox(width: 8, height: 8),
      SizedBox(
        width: 100,
        child: TextField(
          controller: controllers.port,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: language.t('locations.profile.endpoint.port'),
          ),
        ),
      ),
    ];
    final actions = [
      IconButton(
        tooltip: language.t('common.up'),
        onPressed: onMoveUp,
        icon: const Icon(Icons.arrow_upward),
      ),
      IconButton(
        tooltip: language.t('common.down'),
        onPressed: onMoveDown,
        icon: const Icon(Icons.arrow_downward),
      ),
      IconButton(
        tooltip: language.t('common.delete'),
        onPressed: total <= 1 ? null : onRemove,
        icon: const Icon(Icons.close),
      ),
    ];
    return LayoutBuilder(builder: (context, constraints) {
      final compact = constraints.maxWidth < 520;
      if (compact) {
        return Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(child: Text('${index + 1}.')),
                  ...actions,
                ]),
                TextField(
                  controller: controllers.label,
                  decoration: InputDecoration(
                    labelText: language.t('locations.profile.endpoint.label'),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: controllers.host,
                  decoration: InputDecoration(
                    labelText: language.t('locations.profile.endpoint.host'),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: controllers.port,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: language.t('locations.profile.endpoint.port'),
                  ),
                ),
              ],
            ),
          ),
        );
      }
      return Row(
        children: [
          SizedBox(width: 28, child: Text('${index + 1}.')),
          ...fields,
          ...actions,
        ],
      );
    });
  }
}

class _PluginSettingsDialog extends StatefulWidget {
  const _PluginSettingsDialog({
    required this.language,
    required this.plugins,
    required this.pluginSettingsById,
    required this.disabledPluginIds,
    required this.onInstallPluginZip,
    required this.onExportPluginZip,
    required this.onDeletePlugin,
    required this.onSetPluginEnabled,
    required this.onSavePluginSettings,
  });

  final AppLanguage language;
  final List<CloudPluginDefinition> plugins;
  final Map<String, Map<String, String>> pluginSettingsById;
  final List<String> disabledPluginIds;
  final Future<String> Function(String path) onInstallPluginZip;
  final Future<String> Function(String pluginId) onExportPluginZip;
  final Future<String> Function(String pluginId) onDeletePlugin;
  final Future<String> Function(String pluginId, bool enabled)
      onSetPluginEnabled;
  final Future<String> Function(String pluginId, Map<String, String> settings)
      onSavePluginSettings;

  @override
  State<_PluginSettingsDialog> createState() => _PluginSettingsDialogState();
}

class _PluginSettingsDialogState extends State<_PluginSettingsDialog> {
  final _zipController = TextEditingController();
  late final Set<String> _disabledPluginIds = widget.disabledPluginIds.toSet();
  String? _message;
  var _busy = false;

  @override
  void dispose() {
    _zipController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final language = widget.language;
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          title: Text(language.t('settings.plugins.window.title')),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(language.t('settings.plugins.note')),
            const SizedBox(height: 12),
            TextField(
              controller: _zipController,
              decoration: InputDecoration(
                labelText: language.t('settings.plugin.zip.path'),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy ? null : _install,
              icon: const Icon(Icons.extension_outlined),
              label: Text(language.t('settings.plugin.install')),
            ),
            if (_message != null) ...[
              const SizedBox(height: 12),
              SelectableText(_message!),
            ],
            const Divider(height: 32),
            for (final plugin in widget.plugins)
              Builder(builder: (context) {
                final globalSettings = _globalSettings(plugin);
                final enabled = !_disabledPluginIds.contains(plugin.id);
                return Card(
                  elevation: 0,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Column(children: [
                      ListTile(
                        leading: const Icon(Icons.extension_outlined),
                        title: Text('${plugin.name} ${plugin.version}'),
                        subtitle: SelectableText(
                          [
                            enabled
                                ? language.t('common.enabled')
                                : language.t('common.disabled'),
                            plugin.description ?? '',
                            plugin.pluginType,
                            plugin.manifestPath,
                            if (plugin.capabilities.isNotEmpty)
                              plugin.capabilities.join(', '),
                            if (plugin.repositoryUrl != null)
                              '${language.t('settings.plugin.repository')}: ${plugin.repositoryUrl}',
                            if (plugin.updateUrl != null)
                              '${language.t('settings.plugin.update')}: ${plugin.updateUrl}',
                          ].where((item) => item.trim().isNotEmpty).join('\n'),
                        ),
                      ),
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        OutlinedButton.icon(
                          onPressed: _busy
                              ? null
                              : () => _setEnabled(plugin, !enabled),
                          icon: Icon(enabled
                              ? Icons.toggle_on_outlined
                              : Icons.toggle_off_outlined),
                          label: Text(enabled
                              ? language.t('settings.plugin.disable')
                              : language.t('settings.plugin.enable')),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _showPluginInfo(plugin),
                          icon: const Icon(Icons.info_outline),
                          label: Text(language.t('settings.plugin.info')),
                        ),
                        OutlinedButton.icon(
                          onPressed: globalSettings.isEmpty
                              ? null
                              : () => _showPluginSettings(plugin),
                          icon: const Icon(Icons.tune_outlined),
                          label: Text(language.t('settings.plugin.settings')),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _exportPlugin(plugin),
                          icon: const Icon(Icons.archive_outlined),
                          label: Text(language.t('settings.plugin.export')),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _deletePlugin(plugin),
                          icon: const Icon(Icons.delete_outline),
                          label: Text(language.t('settings.plugin.delete')),
                        ),
                      ]),
                      if (globalSettings.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              language.t('settings.plugin.no.global.settings'),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ),
                    ]),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Future<void> _install() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final message = await widget.onInstallPluginZip(_zipController.text);
      if (mounted) setState(() => _message = message);
    } catch (error) {
      if (mounted) setState(() => _message = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportPlugin(CloudPluginDefinition plugin) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final message = await widget.onExportPluginZip(plugin.id);
      if (mounted) setState(() => _message = message);
    } catch (error) {
      if (mounted) setState(() => _message = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deletePlugin(CloudPluginDefinition plugin) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.language.t('settings.plugin.delete')),
        content: Text(plugin.name),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(widget.language.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(widget.language.t('settings.plugin.delete')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final message = await widget.onDeletePlugin(plugin.id);
      if (mounted) setState(() => _message = message);
    } catch (error) {
      if (mounted) setState(() => _message = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setEnabled(
    CloudPluginDefinition plugin,
    bool enabled,
  ) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final message = await widget.onSetPluginEnabled(plugin.id, enabled);
      if (mounted) {
        setState(() {
          if (enabled) {
            _disabledPluginIds.remove(plugin.id);
          } else {
            _disabledPluginIds.add(plugin.id);
          }
          _message = message;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _message = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showPluginInfo(CloudPluginDefinition plugin) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(plugin.name),
        content: SingleChildScrollView(
          child: SelectableText(
              const JsonEncoder.withIndent('  ').convert(plugin.raw)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(widget.language.t('common.close')),
          ),
        ],
      ),
    );
  }

  Future<void> _showPluginSettings(CloudPluginDefinition plugin) {
    final settings = _globalSettings(plugin);
    final saved =
        widget.pluginSettingsById[plugin.id] ?? const <String, String>{};
    final controllers = <String, TextEditingController>{
      for (final entry in settings.entries)
        entry.key: TextEditingController(
          text: saved[entry.key] ?? _pluginSettingDefault(entry.value),
        ),
    };
    return showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, _) => AlertDialog(
          title: Text(widget.language.t('settings.plugin.global.settings')),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (settings.isEmpty)
                    Text(
                        widget.language.t('settings.plugin.no.global.settings'))
                  else
                    for (final entry in settings.entries)
                      TextField(
                        controller: controllers[entry.key],
                        decoration: InputDecoration(
                          labelText:
                              _pluginVariableLabel(entry.key, entry.value),
                        ),
                        minLines:
                            entry.key.toLowerCase().contains('json') ? 3 : 1,
                        maxLines:
                            entry.key.toLowerCase().contains('json') ? 8 : 1,
                        obscureText: entry.value is Map &&
                            ((entry.value as Map)['secret'] == true),
                      ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(widget.language.t('common.cancel')),
            ),
            FilledButton(
              onPressed: settings.isEmpty
                  ? null
                  : () async {
                      final next = <String, String>{
                        for (final entry in controllers.entries)
                          entry.key: entry.value.text.trim(),
                      };
                      final message =
                          await widget.onSavePluginSettings(plugin.id, next);
                      if (!context.mounted) return;
                      Navigator.pop(context);
                      setState(() => _message = message);
                    },
              child: Text(widget.language.t('common.save')),
            ),
          ],
        ),
      ),
    ).whenComplete(() {
      for (final controller in controllers.values) {
        controller.dispose();
      }
    });
  }

  Map<String, Object?> _globalSettings(CloudPluginDefinition plugin) {
    final value = plugin.raw['settings'];
    if (value is Map) {
      return value.map((key, value) => MapEntry(key.toString(), value));
    }
    return const <String, Object?>{};
  }

  String _pluginVariableLabel(String key, Object? value) {
    if (value is Map && value['label'] != null) {
      return value['label'].toString();
    }
    return key;
  }

  String _pluginSettingDefault(Object? value) {
    if (value is Map && value['default'] != null) {
      return value['default'].toString();
    }
    return '';
  }
}

class _AndroidPermissionStatusCard extends StatelessWidget {
  const _AndroidPermissionStatusCard({required this.language});

  final AppLanguage language;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AndroidStorageAccessStatus>(
      future: PlatformServices.androidStorageAccessStatus(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const LinearProgressIndicator(minHeight: 2);
        }
        final status = snapshot.data!;
        String mark(bool value) => value
            ? language.t('common.enabled')
            : language.t('common.disabled');
        return Card(
          elevation: 0,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  language.t('settings.android.permissions.status'),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 6),
                SelectableText([
                  'SDK: ${status.sdkInt}',
                  '${language.t('settings.android.permission.all.files')}: ${mark(status.hasAllFilesAccess)}',
                  '${language.t('settings.android.permission.images')}: ${mark(status.hasMediaImages)}',
                  '${language.t('settings.android.permission.video')}: ${mark(status.hasMediaVideo)}',
                  '${language.t('settings.android.permission.audio')}: ${mark(status.hasMediaAudio)}',
                ].join('\n')),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SettingsView extends StatefulWidget {
  const _SettingsView({
    required this.language,
    required this.settings,
    required this.plugins,
    required this.onSave,
    required this.onRequestAndroidStorageAccess,
    required this.onClear,
    required this.onRevealCommonKey,
    required this.onValidateLanguageFile,
    required this.onInstallLanguageFile,
    required this.onInstallPluginZip,
    required this.onExportPluginZip,
    required this.onDeletePlugin,
    required this.onSetPluginEnabled,
    required this.onSavePluginSettings,
    required this.onExportConfigurationArchive,
    required this.onExportLanguageSample,
    required this.onResetDefaults,
  });

  final AppLanguage language;
  final SecuritySettings settings;
  final List<CloudPluginDefinition> plugins;
  final Future<void> Function({
    required String? appPassword,
    required String? appPasswordCurrent,
    required String? filePassword,
    required String? filePasswordCurrent,
    required bool separate,
    required bool remember,
    required bool wipe,
    required String? commonEncryptionPassword,
    required String? commonEncryptionKeyFilePath,
    required String commonEncryptionAlgorithm,
    required int filePasswordGraceSeconds,
    required bool blockScreenCapture,
    required String languageCode,
    required String? customLanguagePath,
    required bool loggingEnabled,
    required Map<String, String> extensionAssociations,
    required bool rememberRecentFiles,
    required int recentSidebarCount,
    required int recentRememberCount,
    required int favoriteSidebarCount,
    required int locationSidebarCount,
    required bool decryptNamesInExplorer,
    required bool openFullscreenOnHiddenPreviewTap,
    required bool autoScaleForDpi,
    required double fileTextScale,
    required double fileIconScale,
    required List<String> galleryFolders,
    required String galleryExclusions,
    required List<String> musicFolders,
    required String musicExclusions,
    required List<String> videoFolders,
    required String videoExclusions,
    required List<String> documentFolders,
    required String documentExclusions,
    required bool torrentEnabled,
    required bool storeSettingsInUserProfile,
    required bool rememberLastFolder,
    required String navigationPolicy,
    required double interfaceTextScale,
    required double interfaceScale,
    required double toolbarIconScale,
    required String searchMode,
    required bool searchUseRegex,
    required bool searchRecursive,
    required String? programProxy,
    required String? globalPluginProxy,
    required List<String> visibleNavigationSections,
    required bool enableBackgroundVideo,
    required bool enableMiniVideo,
    required bool enableMiniAudio,
    required bool continueMediaInBackground,
    required bool autoCloseMediaOnSectionChange,
    required bool showVideoThumbnails,
    required bool animateVideoThumbnails,
    required bool showAudioArtwork,
    required bool cacheThumbnailsInMemory,
    required bool previewVisibleByDefault,
    required bool rememberPreviewVisibility,
    required bool includeFavoritesInPathDropdown,
    required bool requirePasswordOnAndroidResume,
    required bool showHiddenFiles,
    required bool showSystemFiles,
    required bool androidMediaNotificationControls,
    required bool headsetMediaControls,
    required bool externalFloatingPlayer,
    required bool minimizeToTrayOnClose,
    required bool encryptThumbnailCache,
    required bool encryptResumePositions,
    required int progressAutoCollapseSeconds,
    required bool rememberVideoPositions,
    required bool rememberAudioPositions,
  }) onSave;
  final Future<void> Function() onRequestAndroidStorageAccess;
  final Future<void> Function() onClear;
  final Future<String> Function(String guardPassword) onRevealCommonKey;
  final Future<String> Function(String path) onValidateLanguageFile;
  final Future<String> Function(String path) onInstallLanguageFile;
  final Future<String> Function(String path) onInstallPluginZip;
  final Future<String> Function(String pluginId) onExportPluginZip;
  final Future<String> Function(String pluginId) onDeletePlugin;
  final Future<String> Function(String pluginId, bool enabled)
      onSetPluginEnabled;
  final Future<String> Function(String pluginId, Map<String, String> settings)
      onSavePluginSettings;
  final Future<String> Function() onExportConfigurationArchive;
  final Future<String> Function() onExportLanguageSample;
  final Future<String> Function() onResetDefaults;

  @override
  State<_SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<_SettingsView> {
  final _appCurrent = TextEditingController();
  final _app = TextEditingController();
  final _appRepeat = TextEditingController();
  final _fileCurrent = TextEditingController();
  final _file = TextEditingController();
  final _fileRepeat = TextEditingController();
  final _common = TextEditingController();
  late final TextEditingController _commonKeyFile;
  late final TextEditingController _graceSeconds;
  late final TextEditingController _recentSidebarCount;
  late final TextEditingController _recentRememberCount;
  late final TextEditingController _favoriteSidebarCount;
  late final TextEditingController _locationSidebarCount;
  late final TextEditingController _fileTextScale;
  late final TextEditingController _fileIconScale;
  late final TextEditingController _interfaceTextScale;
  late final TextEditingController _interfaceScale;
  late final TextEditingController _toolbarIconScale;
  late final TextEditingController _progressAutoCollapseSeconds;
  late final TextEditingController _programProxy;
  late final TextEditingController _globalPluginProxy;
  late final TextEditingController _galleryFolders;
  late final TextEditingController _galleryExclusions;
  late final TextEditingController _musicFolders;
  late final TextEditingController _musicExclusions;
  late final TextEditingController _videoFolders;
  late final TextEditingController _videoExclusions;
  late final TextEditingController _documentFolders;
  late final TextEditingController _documentExclusions;
  late final TextEditingController _languagePath;
  late final TextEditingController _pluginZipPath;
  late final TextEditingController _associations;
  late bool _separate;
  late bool _remember;
  late bool _wipe;
  late bool _rememberRecent;
  late bool _loggingEnabled;
  late bool _decryptNamesInExplorer;
  late bool _openFullscreenOnHiddenPreviewTap;
  late bool _autoScaleForDpi;
  late bool _torrentEnabled;
  late bool _blockScreenCapture;
  late bool _storeSettingsInUserProfile;
  late bool _rememberLastFolder;
  late bool _searchUseRegex;
  late bool _searchRecursive;
  late bool _enableBackgroundVideo;
  late bool _enableMiniVideo;
  late bool _enableMiniAudio;
  late bool _continueMediaInBackground;
  late bool _autoCloseMediaOnSectionChange;
  late bool _showVideoThumbnails;
  late bool _animateVideoThumbnails;
  late bool _showAudioArtwork;
  late bool _cacheThumbnailsInMemory;
  late bool _previewVisibleByDefault;
  late bool _rememberPreviewVisibility;
  late bool _includeFavoritesInPathDropdown;
  late bool _requirePasswordOnAndroidResume;
  late bool _showHiddenFiles;
  late bool _showSystemFiles;
  late bool _androidMediaNotificationControls;
  late bool _headsetMediaControls;
  late bool _externalFloatingPlayer;
  late bool _minimizeToTrayOnClose;
  late bool _encryptThumbnailCache;
  late bool _encryptResumePositions;
  late bool _rememberVideoPositions;
  late bool _rememberAudioPositions;
  late Set<String> _visibleNavigationSections;
  late String _languageCode;
  late String _commonAlgorithm;
  late String _navigationPolicy;
  late String _searchMode;
  var _busy = false;
  var _autoSaveReady = false;
  var _autoSaving = false;
  Timer? _autoSaveTimer;

  @override
  void initState() {
    super.initState();
    _separate = widget.settings.useSeparateFilePassword;
    _remember = widget.settings.rememberFilePasswords;
    _wipe = widget.settings.wipeSavedPasswordsOnFailedLogin;
    _rememberRecent = widget.settings.rememberRecentFiles;
    _loggingEnabled = widget.settings.loggingEnabled;
    _decryptNamesInExplorer = widget.settings.decryptNamesInExplorer;
    _openFullscreenOnHiddenPreviewTap =
        widget.settings.openFullscreenOnHiddenPreviewTap;
    _autoScaleForDpi = widget.settings.autoScaleForDpi;
    _torrentEnabled = widget.settings.torrentEnabled;
    _blockScreenCapture = widget.settings.blockScreenCapture;
    _storeSettingsInUserProfile = widget.settings.storeSettingsInUserProfile;
    _rememberLastFolder = widget.settings.rememberLastFolder;
    _searchUseRegex = widget.settings.searchUseRegex;
    _searchRecursive = widget.settings.searchRecursive;
    _enableBackgroundVideo = widget.settings.enableBackgroundVideo;
    _enableMiniVideo = widget.settings.enableMiniVideo;
    _enableMiniAudio = widget.settings.enableMiniAudio;
    _continueMediaInBackground = widget.settings.continueMediaInBackground;
    _autoCloseMediaOnSectionChange =
        widget.settings.autoCloseMediaOnSectionChange;
    _showVideoThumbnails = widget.settings.showVideoThumbnails;
    _animateVideoThumbnails = widget.settings.animateVideoThumbnails;
    _showAudioArtwork = widget.settings.showAudioArtwork;
    _cacheThumbnailsInMemory = widget.settings.cacheThumbnailsInMemory;
    _previewVisibleByDefault = widget.settings.previewVisibleByDefault;
    _rememberPreviewVisibility = widget.settings.rememberPreviewVisibility;
    _includeFavoritesInPathDropdown =
        widget.settings.includeFavoritesInPathDropdown;
    _requirePasswordOnAndroidResume =
        widget.settings.requirePasswordOnAndroidResume;
    _showHiddenFiles = widget.settings.showHiddenFiles;
    _showSystemFiles = widget.settings.showSystemFiles;
    _androidMediaNotificationControls =
        widget.settings.androidMediaNotificationControls;
    _headsetMediaControls = widget.settings.headsetMediaControls;
    _externalFloatingPlayer = widget.settings.externalFloatingPlayer;
    _minimizeToTrayOnClose = widget.settings.minimizeToTrayOnClose;
    _encryptThumbnailCache = widget.settings.encryptThumbnailCache;
    _encryptResumePositions = widget.settings.encryptResumePositions;
    _rememberVideoPositions = widget.settings.rememberVideoPositions;
    _rememberAudioPositions = widget.settings.rememberAudioPositions;
    _visibleNavigationSections =
        widget.settings.visibleNavigationSections.toSet();
    _commonAlgorithm = widget.settings.commonEncryptionAlgorithm;
    _navigationPolicy = widget.settings.navigationPolicy;
    _searchMode = widget.settings.searchMode;
    _commonKeyFile = TextEditingController(
      text: widget.settings.commonEncryptionKeyFilePath ?? '',
    );
    _graceSeconds = TextEditingController(
      text: '${widget.settings.filePasswordGraceSeconds}',
    );
    _recentSidebarCount = TextEditingController(
      text: '${widget.settings.recentSidebarCount}',
    );
    _recentRememberCount = TextEditingController(
      text: '${widget.settings.recentRememberCount}',
    );
    _favoriteSidebarCount = TextEditingController(
      text: '${widget.settings.favoriteSidebarCount}',
    );
    _locationSidebarCount = TextEditingController(
      text: '${widget.settings.locationSidebarCount}',
    );
    _fileTextScale = TextEditingController(
      text: widget.settings.fileTextScale.toStringAsFixed(2),
    );
    _fileIconScale = TextEditingController(
      text: widget.settings.fileIconScale.toStringAsFixed(2),
    );
    _interfaceTextScale = TextEditingController(
      text: widget.settings.interfaceTextScale.toStringAsFixed(2),
    );
    _interfaceScale = TextEditingController(
      text: widget.settings.interfaceScale.toStringAsFixed(2),
    );
    _toolbarIconScale = TextEditingController(
      text: widget.settings.toolbarIconScale.toStringAsFixed(2),
    );
    _progressAutoCollapseSeconds = TextEditingController(
      text: '${widget.settings.progressAutoCollapseSeconds}',
    );
    _programProxy = TextEditingController(
      text: widget.settings.programProxy ?? '',
    );
    _globalPluginProxy = TextEditingController(
      text: widget.settings.globalPluginProxy ?? '',
    );
    _galleryFolders = TextEditingController(
      text: widget.settings.galleryFolders.join('\n'),
    );
    _galleryExclusions = TextEditingController(
      text: widget.settings.galleryExclusions,
    );
    _musicFolders = TextEditingController(
      text: widget.settings.musicFolders.join('\n'),
    );
    _musicExclusions = TextEditingController(
      text: widget.settings.musicExclusions,
    );
    _videoFolders = TextEditingController(
      text: widget.settings.videoFolders.join('\n'),
    );
    _videoExclusions = TextEditingController(
      text: widget.settings.videoExclusions,
    );
    _documentFolders = TextEditingController(
      text: widget.settings.documentFolders.join('\n'),
    );
    _documentExclusions = TextEditingController(
      text: widget.settings.documentExclusions,
    );
    _languageCode = widget.settings.languageCode;
    _languagePath = TextEditingController(
      text: widget.settings.customLanguagePath ?? '',
    );
    _pluginZipPath = TextEditingController();
    _associations = TextEditingController(
      text: widget.settings.extensionAssociations.entries
          .map((entry) => '${entry.key}=${entry.value}')
          .join('\n'),
    );
    for (final controller in [
      _commonKeyFile,
      _graceSeconds,
      _recentSidebarCount,
      _recentRememberCount,
      _favoriteSidebarCount,
      _locationSidebarCount,
      _fileTextScale,
      _fileIconScale,
      _interfaceTextScale,
      _interfaceScale,
      _toolbarIconScale,
      _progressAutoCollapseSeconds,
      _programProxy,
      _globalPluginProxy,
      _galleryFolders,
      _galleryExclusions,
      _musicFolders,
      _musicExclusions,
      _videoFolders,
      _videoExclusions,
      _documentFolders,
      _documentExclusions,
      _languagePath,
      _associations,
    ]) {
      controller.addListener(_scheduleAutoSave);
    }
    _autoSaveReady = true;
  }

  @override
  void dispose() {
    _appCurrent.dispose();
    _app.dispose();
    _appRepeat.dispose();
    _fileCurrent.dispose();
    _file.dispose();
    _fileRepeat.dispose();
    _common.dispose();
    _commonKeyFile.dispose();
    _graceSeconds.dispose();
    _recentSidebarCount.dispose();
    _recentRememberCount.dispose();
    _favoriteSidebarCount.dispose();
    _locationSidebarCount.dispose();
    _fileTextScale.dispose();
    _fileIconScale.dispose();
    _interfaceTextScale.dispose();
    _interfaceScale.dispose();
    _toolbarIconScale.dispose();
    _progressAutoCollapseSeconds.dispose();
    _programProxy.dispose();
    _globalPluginProxy.dispose();
    _galleryFolders.dispose();
    _galleryExclusions.dispose();
    _musicFolders.dispose();
    _musicExclusions.dispose();
    _videoFolders.dispose();
    _videoExclusions.dispose();
    _documentFolders.dispose();
    _documentExclusions.dispose();
    _languagePath.dispose();
    _pluginZipPath.dispose();
    _associations.dispose();
    _autoSaveTimer?.cancel();
    super.dispose();
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _scheduleAutoSave();
  }

  void _scheduleAutoSave() {
    if (!_autoSaveReady || _busy || _autoSaving) return;
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted && !_busy) {
        unawaited(_save(showSnack: false));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final language = widget.language;
    return ListView(padding: const EdgeInsets.all(22), children: [
      Text(
        language.t('settings.title'),
        style: Theme.of(context)
            .textTheme
            .headlineSmall
            ?.copyWith(fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 8),
      Text(language.t('settings.description')),
      const SizedBox(height: 18),
      _settingsCard(context, language.t('settings.storage'), [
        SwitchListTile(
          value: _storeSettingsInUserProfile,
          onChanged: (v) => setState(() => _storeSettingsInUserProfile = v),
          title: Text(language.t('settings.storage.user')),
          subtitle: Text(language.t('settings.storage.note')),
        ),
        SwitchListTile(
          value: _rememberLastFolder,
          onChanged: (v) => setState(() => _rememberLastFolder = v),
          title: Text(language.t('settings.remember.last.folder')),
        ),
        SwitchListTile(
          value: _loggingEnabled,
          onChanged: (v) => setState(() => _loggingEnabled = v),
          title: Text(language.t('settings.logging.enabled')),
          subtitle: Text(language.t('settings.logging.note')),
        ),
        DropdownButtonFormField<String>(
          initialValue: _navigationPolicy,
          decoration: InputDecoration(
              labelText: language.t('settings.navigation.policy')),
          items: [
            DropdownMenuItem(
              value: 'ask',
              child: Text(language.t('settings.navigation.ask')),
            ),
            DropdownMenuItem(
              value: 'deny',
              child: Text(language.t('settings.navigation.deny')),
            ),
            DropdownMenuItem(
              value: 'allow',
              child: Text(language.t('settings.navigation.allow')),
            ),
            DropdownMenuItem(
              value: 'fallbackToLocations',
              child: Text(language.t('settings.navigation.fallback')),
            ),
            DropdownMenuItem(
              value: 'requestRoot',
              child: Text(language.t('settings.navigation.root')),
            ),
          ],
          onChanged: (value) => setState(
              () => _navigationPolicy = value ?? 'fallbackToLocations'),
        ),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
            onPressed: _exportConfiguration,
            icon: const Icon(Icons.archive_outlined),
            label: Text(language.t('settings.export.config')),
          ),
          OutlinedButton.icon(
            onPressed: _resetDefaults,
            icon: const Icon(Icons.restart_alt_outlined),
            label: Text(language.t('settings.reset.defaults')),
          ),
        ]),
      ]),
      const SizedBox(height: 12),
      _settingsCard(context, language.t('settings.passwords'), [
        if (widget.settings.hasAppPassword)
          TextField(
            controller: _appCurrent,
            obscureText: true,
            decoration: InputDecoration(
              labelText: language.t('settings.app.password.current'),
            ),
          ),
        TextField(
          controller: _app,
          obscureText: true,
          decoration: InputDecoration(
            labelText: widget.settings.hasAppPassword
                ? language.t('settings.app.password.new')
                : language.t('settings.app.password'),
          ),
        ),
        TextField(
          controller: _appRepeat,
          obscureText: true,
          decoration: InputDecoration(
            labelText: language.t('settings.app.password.repeat'),
          ),
        ),
        SwitchListTile(
          value: _separate,
          onChanged: (v) => setState(() => _separate = v),
          title: Text(language.t('settings.file.password.separate')),
        ),
        if (_separate)
          Column(
            children: [
              if (widget.settings.hasFilePassword)
                TextField(
                  controller: _fileCurrent,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: language.t('settings.file.password.current'),
                  ),
                ),
              TextField(
                controller: _file,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: widget.settings.hasFilePassword
                      ? language.t('settings.file.password.new')
                      : language.t('settings.file.password'),
                ),
              ),
              TextField(
                controller: _fileRepeat,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: language.t('settings.file.password.repeat'),
                ),
              ),
            ],
          ),
      ]),
      const SizedBox(height: 12),
      _settingsCard(context, language.t('settings.common.encryption'), [
        Text(
          widget.settings.hasCommonEncryption
              ? language.t('settings.common.status.ready')
              : language.t('settings.common.status.empty'),
        ),
        DropdownButtonFormField<String>(
          initialValue: EncryptionAlgorithm.supported.contains(_commonAlgorithm)
              ? _commonAlgorithm
              : EncryptionAlgorithm.xchacha20Poly1305,
          decoration: InputDecoration(
            labelText: language.t('settings.common.algorithm'),
          ),
          items: [
            for (final item in EncryptionAlgorithm.supported)
              DropdownMenuItem(
                value: item,
                child: Text(EncryptionAlgorithm.label(item)),
              ),
          ],
          onChanged: (value) => setState(
            () => _commonAlgorithm =
                value ?? EncryptionAlgorithm.xchacha20Poly1305,
          ),
        ),
        TextField(
          controller: _common,
          obscureText: true,
          decoration: InputDecoration(
            labelText: language.t('settings.common.password.new'),
          ),
        ),
        _PathTextField(
          controller: _commonKeyFile,
          label: language.t('settings.common.keyfile'),
          helperText: language.t('settings.common.keyfile.note'),
          pickDirectory: false,
        ),
        ListTile(
          leading: const Icon(Icons.key_outlined),
          title: Text(language.t('settings.common.reveal')),
          subtitle: Text(language.t('settings.common.reveal.note')),
          onTap: _revealCommonKey,
        ),
      ]),
      const SizedBox(height: 12),
      _settingsCard(context, language.t('settings.remembering'), [
        SwitchListTile(
          value: _remember,
          onChanged: (v) => setState(() => _remember = v),
          title: Text(language.t('settings.remember.file.password')),
        ),
        TextField(
          controller: _graceSeconds,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: language.t('settings.file.password.grace'),
          ),
        ),
        SwitchListTile(
          value: _wipe,
          onChanged: (v) => setState(() => _wipe = v),
          title: Text(language.t('settings.wipe.failed')),
        ),
        ListTile(
          leading: const Icon(Icons.delete_outline),
          title: Text(language.t('settings.clear.now')),
          onTap: widget.onClear,
        ),
      ]),
      const SizedBox(height: 12),
      _settingsCard(context, language.t('settings.recent'), [
        SwitchListTile(
          value: _rememberRecent,
          onChanged: (v) => setState(() => _rememberRecent = v),
          title: Text(language.t('settings.recent.remember')),
        ),
        TextField(
          controller: _recentSidebarCount,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: language.t('settings.recent.sidebar.count'),
          ),
        ),
        TextField(
          controller: _recentRememberCount,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: language.t('settings.recent.remember.count'),
          ),
        ),
        TextField(
          controller: _favoriteSidebarCount,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: language.t('settings.favorite.sidebar.count'),
          ),
        ),
        TextField(
          controller: _locationSidebarCount,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: language.t('settings.locations.sidebar.count'),
          ),
        ),
      ]),
      const SizedBox(height: 12),
      _settingsCard(context, language.t('settings.explorer.view'), [
        SwitchListTile(
          value: _decryptNamesInExplorer,
          onChanged: (v) => setState(() => _decryptNamesInExplorer = v),
          title: Text(language.t('settings.decrypt.names')),
        ),
        SwitchListTile(
          value: _openFullscreenOnHiddenPreviewTap,
          onChanged: (v) =>
              setState(() => _openFullscreenOnHiddenPreviewTap = v),
          title: Text(language.t('settings.fullscreen.hidden.preview.tap')),
        ),
        SwitchListTile(
          value: _previewVisibleByDefault,
          onChanged: (v) => setState(() => _previewVisibleByDefault = v),
          title: Text(language.t('settings.preview.visible.default')),
        ),
        SwitchListTile(
          value: _rememberPreviewVisibility,
          onChanged: (v) => setState(() => _rememberPreviewVisibility = v),
          title: Text(language.t('settings.preview.remember.visibility')),
        ),
        SwitchListTile(
          value: _includeFavoritesInPathDropdown,
          onChanged: (v) => setState(() => _includeFavoritesInPathDropdown = v),
          title: Text(language.t('settings.path.dropdown.favorites')),
        ),
        SwitchListTile(
          value: _autoScaleForDpi,
          onChanged: (v) => setState(() => _autoScaleForDpi = v),
          title: Text(language.t('settings.auto.dpi')),
        ),
        SwitchListTile(
          value: _showVideoThumbnails,
          onChanged: (v) => setState(() => _showVideoThumbnails = v),
          title: Text(language.t('settings.thumbnails.video')),
        ),
        SwitchListTile(
          value: _animateVideoThumbnails,
          onChanged: _showVideoThumbnails
              ? (v) => setState(() => _animateVideoThumbnails = v)
              : null,
          title: Text(language.t('settings.thumbnails.video.animate')),
        ),
        SwitchListTile(
          value: _showAudioArtwork,
          onChanged: (v) => setState(() => _showAudioArtwork = v),
          title: Text(language.t('settings.thumbnails.audio')),
        ),
        SwitchListTile(
          value: _cacheThumbnailsInMemory,
          onChanged: (v) => setState(() => _cacheThumbnailsInMemory = v),
          title: Text(language.t('settings.thumbnails.cache.memory')),
        ),
        SwitchListTile(
          value: _encryptThumbnailCache,
          onChanged: (v) => setState(() => _encryptThumbnailCache = v),
          title: Text(language.t('settings.thumbnails.cache.encrypted')),
        ),
        SwitchListTile(
          value: _showHiddenFiles,
          onChanged: (v) => setState(() => _showHiddenFiles = v),
          title: Text(language.t('settings.show.hidden')),
        ),
        SwitchListTile(
          value: _showSystemFiles,
          onChanged: (v) => setState(() => _showSystemFiles = v),
          title: Text(language.t('settings.show.system')),
        ),
        TextField(
          controller: _fileTextScale,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: language.t('settings.file.text.scale'),
          ),
        ),
        TextField(
          controller: _fileIconScale,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: language.t('settings.file.icon.scale'),
          ),
        ),
        TextField(
          controller: _interfaceTextScale,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: language.t('settings.interface.text.scale'),
          ),
        ),
        TextField(
          controller: _interfaceScale,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: language.t('settings.interface.scale'),
            helperText: language.t('settings.interface.scale.note'),
          ),
        ),
        TextField(
          controller: _toolbarIconScale,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: language.t('settings.toolbar.icon.scale'),
          ),
        ),
        DropdownButtonFormField<String>(
          initialValue: _searchMode,
          decoration:
              InputDecoration(labelText: language.t('settings.search.default')),
          items: [
            DropdownMenuItem(
              value: 'name',
              child: Text(language.t('search.mode.name')),
            ),
            DropdownMenuItem(
              value: 'nameContent',
              child: Text(language.t('search.mode.name.content')),
            ),
            DropdownMenuItem(
              value: 'content',
              child: Text(language.t('search.mode.content')),
            ),
          ],
          onChanged: (value) => setState(() => _searchMode = value ?? 'name'),
        ),
        SwitchListTile(
          value: _searchUseRegex,
          onChanged: (v) => setState(() => _searchUseRegex = v),
          title: Text(language.t('search.regex')),
        ),
        SwitchListTile(
          value: _searchRecursive,
          onChanged: (v) => setState(() => _searchRecursive = v),
          title: Text(language.t('search.recursive')),
        ),
      ]),
      const SizedBox(height: 12),
      _settingsCard(context, language.t('settings.navigation.sections'), [
        for (final section in const [
          'explorer',
          'gallery',
          'music',
          'video',
          'documents'
        ])
          CheckboxListTile(
            value: _visibleNavigationSections.contains(section),
            onChanged: (value) => setState(() {
              if (value ?? false) {
                _visibleNavigationSections.add(section);
              } else {
                _visibleNavigationSections.remove(section);
              }
            }),
            title: Text(language.t('nav.$section')),
          ),
      ]),
      const SizedBox(height: 12),
      _settingsCard(context, language.t('settings.media.sections'), [
        _folderField(language.t('nav.gallery'), _galleryFolders,
            pickDirectory: true),
        _folderField(language.t('settings.exclusions'), _galleryExclusions),
        _folderField(language.t('nav.music'), _musicFolders,
            pickDirectory: true),
        _folderField(language.t('settings.exclusions'), _musicExclusions),
        _folderField(language.t('nav.video'), _videoFolders,
            pickDirectory: true),
        _folderField(language.t('settings.exclusions'), _videoExclusions),
        _folderField(language.t('nav.documents'), _documentFolders,
            pickDirectory: true),
        _folderField(language.t('settings.exclusions'), _documentExclusions),
        SwitchListTile(
          value: _torrentEnabled,
          onChanged: (v) => setState(() => _torrentEnabled = v),
          title: Text(language.t('settings.torrent.enabled')),
        ),
      ]),
      const SizedBox(height: 12),
      _settingsCard(context, language.t('settings.background.media'), [
        SwitchListTile(
          value: _enableBackgroundVideo,
          onChanged: (v) => setState(() => _enableBackgroundVideo = v),
          title: Text(language.t('settings.background.video')),
        ),
        SwitchListTile(
          value: _enableMiniVideo,
          onChanged: (v) => setState(() => _enableMiniVideo = v),
          title: Text(language.t('settings.background.video.mini')),
        ),
        SwitchListTile(
          value: _enableMiniAudio,
          onChanged: (v) => setState(() => _enableMiniAudio = v),
          title: Text(language.t('settings.background.audio.mini')),
        ),
        SwitchListTile(
          value: _continueMediaInBackground,
          onChanged: (v) => setState(() => _continueMediaInBackground = v),
          title: Text(language.t('settings.background.continue')),
        ),
        SwitchListTile(
          value: _externalFloatingPlayer,
          onChanged: (v) => setState(() => _externalFloatingPlayer = v),
          title: Text(language.t('settings.background.external.overlay')),
        ),
        SwitchListTile(
          value: _minimizeToTrayOnClose,
          onChanged: Platform.isWindows
              ? (v) => setState(() => _minimizeToTrayOnClose = v)
              : null,
          title: Text(language.t('settings.window.minimize.tray')),
        ),
        SwitchListTile(
          value: _androidMediaNotificationControls,
          onChanged: Platform.isAndroid
              ? (v) => setState(() => _androidMediaNotificationControls = v)
              : null,
          title: Text(language.t('settings.android.media.notifications')),
        ),
        SwitchListTile(
          value: _headsetMediaControls,
          onChanged: (v) => setState(() => _headsetMediaControls = v),
          title: Text(language.t('settings.media.headset.controls')),
        ),
        SwitchListTile(
          value: _encryptResumePositions,
          onChanged: (v) => setState(() => _encryptResumePositions = v),
          title: Text(language.t('settings.media.resume.encrypted')),
        ),
        SwitchListTile(
          value: _rememberVideoPositions,
          onChanged: (v) => setState(() => _rememberVideoPositions = v),
          title: Text(language.t('settings.media.resume.video')),
        ),
        SwitchListTile(
          value: _rememberAudioPositions,
          onChanged: (v) => setState(() => _rememberAudioPositions = v),
          title: Text(language.t('settings.media.resume.audio')),
        ),
        SwitchListTile(
          value: _autoCloseMediaOnSectionChange,
          onChanged: (v) => setState(() => _autoCloseMediaOnSectionChange = v),
          title: Text(language.t('settings.background.autoclose')),
        ),
        TextField(
          controller: _progressAutoCollapseSeconds,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: language.t('settings.progress.autocollapse.seconds'),
            helperText: language.t('settings.progress.autocollapse.note'),
          ),
        ),
      ]),
      const SizedBox(height: 12),
      _settingsCard(context, language.t('settings.proxy'), [
        TextField(
          controller: _programProxy,
          decoration:
              InputDecoration(labelText: language.t('settings.proxy.program')),
        ),
        TextField(
          controller: _globalPluginProxy,
          decoration:
              InputDecoration(labelText: language.t('settings.proxy.plugins')),
        ),
      ]),
      const SizedBox(height: 12),
      _settingsCard(context, language.t('settings.screen'), [
        SwitchListTile(
          value: _blockScreenCapture,
          onChanged: (v) => setState(() => _blockScreenCapture = v),
          title: Text(language.t('settings.block.capture')),
        ),
        Text(language.t('settings.block.capture.note')),
        if (Platform.isAndroid) ...[
          SwitchListTile(
            value: _requirePasswordOnAndroidResume,
            onChanged: (v) =>
                setState(() => _requirePasswordOnAndroidResume = v),
            title: Text(language.t('settings.android.lock.resume')),
          ),
          const SizedBox(height: 8),
          _AndroidPermissionStatusCard(language: language),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: widget.onRequestAndroidStorageAccess,
            icon: const Icon(Icons.folder_special_outlined),
            label: Text(language.t('settings.android.storage.request')),
          ),
        ],
      ]),
      const SizedBox(height: 12),
      _settingsCard(context, language.t('settings.language'), [
        DropdownButtonFormField<String>(
          initialValue: _languageCode == 'en' || _languageCode == 'custom'
              ? _languageCode
              : 'ru',
          decoration: InputDecoration(
            labelText: language.t('settings.language.select'),
          ),
          items: [
            DropdownMenuItem(
              value: 'ru',
              child: Text(language.t('settings.language.ru')),
            ),
            DropdownMenuItem(
              value: 'en',
              child: Text(language.t('settings.language.en')),
            ),
            DropdownMenuItem(
              value: 'custom',
              child: Text(language.t('settings.language.custom')),
            ),
          ],
          onChanged: (value) => setState(() => _languageCode = value ?? 'ru'),
        ),
        _PathTextField(
          controller: _languagePath,
          label: language.t('settings.language.path'),
          pickDirectory: false,
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
            onPressed: _validateLanguage,
            icon: const Icon(Icons.fact_check_outlined),
            label: Text(language.t('settings.language.validate')),
          ),
          OutlinedButton.icon(
            onPressed: _installLanguage,
            icon: const Icon(Icons.add_circle_outline),
            label: Text(language.t('settings.language.install')),
          ),
          OutlinedButton.icon(
            onPressed: _exportSample,
            icon: const Icon(Icons.file_download_outlined),
            label: Text(language.t('settings.language.export')),
          ),
        ]),
      ]),
      const SizedBox(height: 12),
      _settingsCard(context, language.t('settings.associations'), [
        TextField(
          controller: _associations,
          minLines: 3,
          maxLines: 6,
          decoration: InputDecoration(
            hintText: language.t('settings.associations.hint'),
          ),
        ),
      ]),
      const SizedBox(height: 12),
      _settingsCard(context, language.t('settings.plugins'), [
        Text(language.t('settings.plugins.note')),
        OutlinedButton.icon(
          onPressed: _openPluginSettings,
          icon: const Icon(Icons.settings_applications_outlined),
          label: Text(language.t('settings.plugins.open.window')),
        ),
        const SizedBox(height: 8),
        _PathTextField(
          controller: _pluginZipPath,
          label: language.t('settings.plugin.zip.path'),
          pickDirectory: false,
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _installPlugin,
          icon: const Icon(Icons.extension_outlined),
          label: Text(language.t('settings.plugin.install')),
        ),
      ]),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: _busy ? null : () => _save(),
        icon: const Icon(Icons.save_outlined),
        label: Text(
          _busy ? language.t('common.saving') : language.t('common.save'),
        ),
      ),
    ]);
  }

  Widget _settingsCard(
          BuildContext context, String title, List<Widget> children) =>
      Card(
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              title,
              style: Theme.of(context)
                  .textTheme
                  .titleLarge
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            ...children,
          ]),
        ),
      );

  Widget _folderField(
    String label,
    TextEditingController controller, {
    bool pickDirectory = false,
  }) =>
      _PathTextField(
        controller: controller,
        label: label,
        pickDirectory: pickDirectory,
        multiLine: true,
        helperText: widget.language.t('settings.paths.one.per.line'),
      );

  Future<void> _save({bool showSnack = true}) async {
    _autoSaveTimer?.cancel();
    _autoSaving = true;
    setState(() => _busy = true);
    try {
      final nextApp = _app.text.trim();
      final repeatApp = _appRepeat.text.trim();
      final nextFile = _file.text.trim();
      final repeatFile = _fileRepeat.text.trim();
      if (nextApp != repeatApp) {
        throw FormatException(
            widget.language.t('settings.app.password.mismatch'));
      }
      if (_separate && nextFile != repeatFile) {
        throw FormatException(
            widget.language.t('settings.file.password.mismatch'));
      }
      await widget.onSave(
        appPassword: nextApp.isEmpty ? null : _app.text,
        appPasswordCurrent:
            _appCurrent.text.trim().isEmpty ? null : _appCurrent.text,
        filePassword: nextFile.isEmpty ? null : _file.text,
        filePasswordCurrent:
            _fileCurrent.text.trim().isEmpty ? null : _fileCurrent.text,
        separate: _separate,
        remember: _remember,
        wipe: _wipe,
        commonEncryptionPassword:
            _common.text.trim().isEmpty ? null : _common.text,
        commonEncryptionKeyFilePath: _commonKeyFile.text.trim(),
        commonEncryptionAlgorithm: _commonAlgorithm,
        filePasswordGraceSeconds: int.tryParse(_graceSeconds.text.trim()) ?? 0,
        blockScreenCapture: _blockScreenCapture,
        languageCode: _languageCode,
        customLanguagePath: _languagePath.text.trim().isEmpty
            ? null
            : _languagePath.text.trim(),
        loggingEnabled: _loggingEnabled,
        extensionAssociations: _parseAssociations(_associations.text),
        rememberRecentFiles: _rememberRecent,
        recentSidebarCount: int.tryParse(_recentSidebarCount.text.trim()) ?? 5,
        recentRememberCount:
            int.tryParse(_recentRememberCount.text.trim()) ?? 50,
        favoriteSidebarCount:
            int.tryParse(_favoriteSidebarCount.text.trim()) ?? 10,
        locationSidebarCount:
            int.tryParse(_locationSidebarCount.text.trim()) ?? 5,
        decryptNamesInExplorer: _decryptNamesInExplorer,
        openFullscreenOnHiddenPreviewTap: _openFullscreenOnHiddenPreviewTap,
        autoScaleForDpi: _autoScaleForDpi,
        fileTextScale: double.tryParse(_fileTextScale.text.trim()) ?? 1.0,
        fileIconScale: double.tryParse(_fileIconScale.text.trim()) ?? 1.0,
        galleryFolders: _parseLines(_galleryFolders.text),
        galleryExclusions: _galleryExclusions.text,
        musicFolders: _parseLines(_musicFolders.text),
        musicExclusions: _musicExclusions.text,
        videoFolders: _parseLines(_videoFolders.text),
        videoExclusions: _videoExclusions.text,
        documentFolders: _parseLines(_documentFolders.text),
        documentExclusions: _documentExclusions.text,
        torrentEnabled: _torrentEnabled,
        storeSettingsInUserProfile: _storeSettingsInUserProfile,
        rememberLastFolder: _rememberLastFolder,
        navigationPolicy: _navigationPolicy,
        interfaceTextScale:
            double.tryParse(_interfaceTextScale.text.trim()) ?? 1.0,
        interfaceScale: double.tryParse(_interfaceScale.text.trim()) ?? 1.0,
        toolbarIconScale: double.tryParse(_toolbarIconScale.text.trim()) ?? 1.0,
        searchMode: _searchMode,
        searchUseRegex: _searchUseRegex,
        searchRecursive: _searchRecursive,
        programProxy: _programProxy.text.trim().isEmpty
            ? null
            : _programProxy.text.trim(),
        globalPluginProxy: _globalPluginProxy.text.trim().isEmpty
            ? null
            : _globalPluginProxy.text.trim(),
        visibleNavigationSections: _visibleNavigationSections.toList(),
        enableBackgroundVideo: _enableBackgroundVideo,
        enableMiniVideo: _enableMiniVideo,
        enableMiniAudio: _enableMiniAudio,
        continueMediaInBackground: _continueMediaInBackground,
        autoCloseMediaOnSectionChange: _autoCloseMediaOnSectionChange,
        showVideoThumbnails: _showVideoThumbnails,
        animateVideoThumbnails: _animateVideoThumbnails,
        showAudioArtwork: _showAudioArtwork,
        cacheThumbnailsInMemory: _cacheThumbnailsInMemory,
        previewVisibleByDefault: _previewVisibleByDefault,
        rememberPreviewVisibility: _rememberPreviewVisibility,
        includeFavoritesInPathDropdown: _includeFavoritesInPathDropdown,
        requirePasswordOnAndroidResume: _requirePasswordOnAndroidResume,
        showHiddenFiles: _showHiddenFiles,
        showSystemFiles: _showSystemFiles,
        androidMediaNotificationControls: _androidMediaNotificationControls,
        headsetMediaControls: _headsetMediaControls,
        externalFloatingPlayer: _externalFloatingPlayer,
        minimizeToTrayOnClose: _minimizeToTrayOnClose,
        encryptThumbnailCache: _encryptThumbnailCache,
        encryptResumePositions: _encryptResumePositions,
        progressAutoCollapseSeconds:
            int.tryParse(_progressAutoCollapseSeconds.text.trim()) ?? 3,
        rememberVideoPositions: _rememberVideoPositions,
        rememberAudioPositions: _rememberAudioPositions,
      );
      if (showSnack) {
        _snack(widget.language.t('settings.saved'));
      }
    } catch (error) {
      _snack('${widget.language.t('settings.language.invalid')} $error');
    } finally {
      if (mounted) setState(() => _busy = false);
      _autoSaving = false;
    }
  }

  Future<void> _validateLanguage() async {
    try {
      final message = await widget.onValidateLanguageFile(
        _languagePath.text.trim(),
      );
      _snack(message);
    } catch (error) {
      _snack('${widget.language.t('settings.language.invalid')} $error');
    }
  }

  Future<void> _installLanguage() async {
    try {
      final message = await widget.onInstallLanguageFile(
        _languagePath.text.trim(),
      );
      _snack(message);
    } catch (error) {
      _snack('${widget.language.t('settings.language.invalid')} $error');
    }
  }

  Future<void> _installPlugin() async {
    try {
      final message = await widget.onInstallPluginZip(
        _pluginZipPath.text.trim(),
      );
      _snack(message);
    } catch (error) {
      _snack('${widget.language.t('settings.language.invalid')} $error');
    }
  }

  Future<void> _openPluginSettings() async {
    await showDialog<void>(
      context: context,
      builder: (context) => _PluginSettingsDialog(
        language: widget.language,
        plugins: widget.plugins,
        pluginSettingsById: widget.settings.pluginSettingsById,
        disabledPluginIds: widget.settings.disabledPluginIds,
        onInstallPluginZip: widget.onInstallPluginZip,
        onExportPluginZip: widget.onExportPluginZip,
        onDeletePlugin: widget.onDeletePlugin,
        onSetPluginEnabled: widget.onSetPluginEnabled,
        onSavePluginSettings: widget.onSavePluginSettings,
      ),
    );
  }

  Future<void> _exportConfiguration() async {
    try {
      final message = await widget.onExportConfigurationArchive();
      _snack(message);
    } catch (error) {
      _snack('$error');
    }
  }

  Future<void> _resetDefaults() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.language.t('settings.reset.defaults')),
        content: Text(widget.language.t('settings.reset.confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(widget.language.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(widget.language.t('settings.reset.defaults')),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final message = await widget.onResetDefaults();
      _snack(message);
    } catch (error) {
      _snack('$error');
    }
  }

  Future<void> _exportSample() async {
    try {
      final path = await widget.onExportLanguageSample();
      _snack('${widget.language.t('settings.language.exported')} $path');
    } catch (error) {
      _snack('$error');
    }
  }

  Future<void> _revealCommonKey() async {
    Future<void> showKey(String password) async {
      try {
        final value = await widget.onRevealCommonKey(password);
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(widget.language.t('settings.common.current.key')),
            content: SelectableText(value),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: Text(widget.language.t('common.ok')),
              ),
            ],
          ),
        );
      } catch (error) {
        _snack('$error');
      }
    }

    if (!widget.settings.hasFilePassword && !widget.settings.hasAppPassword) {
      await showKey('');
      return;
    }

    final guard = TextEditingController();
    final password = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.language.t('settings.common.reveal')),
        content: TextField(
          controller: guard,
          obscureText: true,
          autofocus: true,
          decoration: InputDecoration(
            labelText: widget.settings.hasFilePassword
                ? widget.language.t('settings.file.password')
                : widget.language.t('settings.app.password'),
          ),
          onSubmitted: (_) => Navigator.pop(context, guard.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(widget.language.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, guard.text),
            child: Text(widget.language.t('common.open')),
          ),
        ],
      ),
    );
    if (password == null) return;
    await showKey(password);
  }

  Map<String, String> _parseAssociations(String raw) {
    final result = <String, String>{};
    for (final line in raw.split(RegExp(r'\r?\n'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final equals = trimmed.indexOf('=');
      if (equals <= 0) continue;
      var extension = trimmed.substring(0, equals).trim().toLowerCase();
      final command = trimmed.substring(equals + 1).trim();
      if (extension.isEmpty || command.isEmpty) continue;
      if (!extension.startsWith('.')) extension = '.$extension';
      result[extension] = command;
    }
    return result;
  }

  List<String> _parseLines(String text) => text
      .split(RegExp(r'[\r\n]+'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();

  void _snack(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }
}
