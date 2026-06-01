import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

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

const _appVersion = '0.12.7';
final _sharedMediaSession = _SharedMediaSession();

void main(List<String> args) {
  MediaKit.ensureInitialized();
  unawaited(AppLog.write('Application start ${args.join(' ')}'));
  runApp(SecureVaultApp(initialPath: args.isEmpty ? null : args.first));
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
  double _sidebarWidth = 290;
  double _previewWidth = 420;
  bool _previewVisible = false;
  List<String> _clipboardPaths = const [];
  bool _clipboardCut = false;
  bool _showingRecent = false;
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
    final runtime = await _bindings.getRuntimeInfo();
    final pluginDefs = await _plugins.loadPlugins();
    _explorer.configurePlugins(pluginDefs, settings.connectionProfiles);
    final locations =
        await _explorer.loadLocations(pluginDefs, settings.connectionProfiles);
    final pluginMediaSections =
        PluginRuntime(pluginDefs, settings.pluginSettingsById).mediaSections();
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
  }

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
    unawaited(_rememberOpenedFolder(path));
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
      _currentPath = path;
      _selected = null;
      _preview = null;
      _mediaPlaylist = const [];
      _imagePlaylist = const [];
      _selectedPaths = const <String>{};
      _snapshot = _directorySnapshot(path);
    });
  }

  Future<void> _rememberOpenedFolder(String path) async {
    if (!_settings.rememberLastFolder || path.trim().isEmpty) return;
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
      }
      return;
    }
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      _openPath(path, recordHistory: recordHistory);
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

  PluginRuntime _pluginRuntime([
    List<CloudPluginDefinition>? plugins,
    SecuritySettings? settings,
  ]) =>
      PluginRuntime(
        plugins ?? _pluginDefs,
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
      case _ExplorerMenuAction.sort:
        _sortDialog();
      case _ExplorerMenuAction.toggleHidden:
        unawaited(_toggleHiddenFiles());
      case _ExplorerMenuAction.toggleSystem:
        unawaited(_toggleSystemFiles());
    }
  }

  Future<void> _refresh() async {
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
    _explorer.configurePlugins(_pluginDefs, nextSettings.connectionProfiles);
    final locations = await _explorer.loadLocations(
      _pluginDefs,
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
    _explorer.configurePlugins(_pluginDefs, nextSettings.connectionProfiles);
    final locations = await _explorer.loadLocations(
      _pluginDefs,
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
    _explorer.configurePlugins(_pluginDefs, nextSettings.connectionProfiles);
    final locations = await _explorer.loadLocations(
      _pluginDefs,
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
    final snapshotFuture = section == MediaSection.torrent
        ? _torrentSectionSnapshot()
        : _explorer.mediaSnapshot(
            label: label,
            roots: roots,
            extensions: extensions,
            exclusions: exclusions,
          );
    setState(() {
      _page = page;
      _activePluginMediaSection = null;
      _showingRecent = false;
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
    if (entry.isDirectory) {
      await _openPathSafely(entry.path);
      return;
    }
    if (FileViewerService.kindForName(entry.path) == FileContentKind.archive &&
        !_explorer.isVirtualPath(entry.path)) {
      await _openPathSafely(_explorer.zipRootPath(entry.path));
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
      final playlist = _mediaPlaylist.isEmpty
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
      });
      if (forceFullScreen ||
          (!_previewVisible && _settings.openFullscreenOnHiddenPreviewTap)) {
        _showPreviewWindow(preview);
      }
      if (_settings.rememberRecentFiles) {
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
    });
    FilePreview? openedPreview;
    try {
      final preview = await previewFuture;
      openedPreview = preview;
      final playlist = await _buildMediaPlaylist(entry, preview);
      final imagePlaylist = await _buildImagePlaylist(entry, preview);
      if (mounted && _selected?.path == entry.path) {
        setState(() {
          _mediaPlaylist = playlist;
          _imagePlaylist = imagePlaylist;
        });
      }
    } catch (_) {
      if (mounted && _selected?.path == entry.path) {
        setState(() {
          _mediaPlaylist = const [];
          _imagePlaylist = const [];
        });
      }
    }
    if (mounted &&
        openedPreview != null &&
        openedPreview.contentKind == FileContentKind.unknown) {
      final openExternal = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(_language.t('preview.unsupported.title')),
          content: Text(_language.t('preview.unsupported.body')),
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
      if (openExternal == true) {
        await _openPreviewExternal(openedPreview);
      }
    }
    if (mounted &&
        openedPreview != null &&
        (forceFullScreen ||
            (!_previewVisible && _settings.openFullscreenOnHiddenPreviewTap))) {
      _showPreviewWindow(openedPreview);
    }
    if (_settings.rememberRecentFiles) {
      final next = await _settingsRepo.recordRecentFile(_settings, entry.path);
      if (mounted) {
        setState(() => _settings = next);
      }
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

    final items = <MediaPreviewItem>[];
    for (final entry in snapshot.entries) {
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
    try {
      final file = await _explorer.importFile(options);
      _snack('${_language.t('snack.uploaded')} ${file.path}');
      await _refresh();
    } catch (error) {
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
    try {
      final file = await _explorer.exportFile(selected.path, options);
      _snack('${_language.t('snack.downloaded')} ${file.path}');
      await _refresh();
    } catch (error) {
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
      case _EntryAction.encrypt:
        await _encryptSelectedFile(entry);
      case _EntryAction.decrypt:
        await _decryptSelectedFile(entry);
      case _EntryAction.copy:
        setState(() {
          _clipboardPaths = [entry.path];
          _clipboardCut = false;
        });
        _snack(_language.t('snack.copied'));
      case _EntryAction.cut:
        setState(() {
          _clipboardPaths = [entry.path];
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
          _clipboardCut = false;
        });
        _snack(_language.t('snack.copied'));
      case _EntryAction.cut:
        setState(() {
          _clipboardPaths = paths;
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
        results.add(_clipboardCut
            ? await _explorer.moveEntityToDirectory(source, targetDirectory)
            : await _explorer.copyEntityToDirectory(source, targetDirectory));
      }
      if (_clipboardCut) {
        setState(() {
          _clipboardPaths = const [];
          _clipboardCut = false;
        });
      }
      _snack('${_language.t('snack.pasted')} ${results.length}');
      await _refresh();
    } catch (error) {
      _snack('${_language.t('snack.operation.error')} $error');
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
    try {
      final target = await _explorer.extractZipToDirectory(
        File(entry.path),
        Directory(File(entry.path).parent.path),
      );
      _snack('${_language.t('snack.unzipped')} ${target.path}');
      await _refresh();
    } catch (error) {
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
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_language.t('explorer.properties')),
        content: SelectableText(
          '${_language.t('common.path')}: ${entry.path}\n'
          '${_language.t('explorer.name')}: ${entry.name}\n'
          '${_language.t('explorer.type')}: ${entry.kind.name}\n'
          '${_language.t('explorer.size')}: ${entry.sizeBytes}\n'
          '${_language.t('explorer.modified')}: ${entry.modifiedAt}\n'
          '${_language.t('explorer.exists')}: ${entry.exists}',
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

  void _showPreviewWindow(FilePreview preview) {
    var currentPreview = preview;
    showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => Dialog.fullscreen(
          child: Scaffold(
            appBar: AppBar(
              title: Text(currentPreview.title),
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
                        _openEditor(currentPreview);
                      case _PreviewAction.speak:
                        unawaited(PlatformServices.speakText(
                          currentPreview.text ?? currentPreview.subtitle,
                        ));
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
              mediaPlaylist: _mediaPlaylist,
              imagePlaylist: _imagePlaylist,
              mediaResumePositions: _settings.mediaResumePositions,
              onRememberMediaPosition: _rememberMediaPosition,
              fillAvailable: true,
              onImageNavigate: (delta) async {
                final next = await _navigateImage(delta);
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

  Future<void> _openEditor(FilePreview preview) async {
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
        ),
      );
      if (savedPath != null) {
        _snack('${_language.t('editor.saved')} $savedPath');
        await _refresh();
      }
      return;
    }

    if (preview.contentKind == FileContentKind.image && preview.bytes != null) {
      final savedPath = await showDialog<String>(
        context: context,
        builder: (context) => _ImageEditorDialog(
          preview: preview,
          language: _language,
          currentDirectory: _currentPath,
        ),
      );
      if (savedPath != null) {
        _snack('${_language.t('editor.saved')} $savedPath');
        await _refresh();
      }
      return;
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
      }
      return;
    }

    _snack(_language.t('editor.unsupported'));
  }

  Future<void> _rememberMediaPosition(String key, Duration position) async {
    if (key.trim().isEmpty) return;
    final next = await _settingsRepo
        .recordMediaResumePosition(_settings, key, position.inMilliseconds)
        .catchError((_) => _settings);
    if (mounted &&
        next.mediaResumePositions != _settings.mediaResumePositions) {
      setState(() => _settings = next);
    }
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
    required double toolbarIconScale,
    required String searchMode,
    required bool searchUseRegex,
    required bool searchRecursive,
    required String? programProxy,
    required String? globalPluginProxy,
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
    required bool encryptThumbnailCache,
    required bool encryptResumePositions,
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
      toolbarIconScale: toolbarIconScale,
      searchMode: searchMode,
      searchUseRegex: searchUseRegex,
      searchRecursive: searchRecursive,
      programProxy: programProxy,
      globalPluginProxy: globalPluginProxy,
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
      encryptThumbnailCache: encryptThumbnailCache,
      encryptResumePositions: encryptResumePositions,
    );
    MediaArtworkService.configure(
      cacheEnabled: next.cacheThumbnailsInMemory,
      persistentCacheEnabled: true,
      encryptPersistentCache: next.encryptThumbnailCache,
    );
    await PlatformServices.setScreenProtection(next.blockScreenCapture);
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
    _explorer.configurePlugins(pluginDefs, _settings.connectionProfiles);
    final locations =
        await _explorer.loadLocations(pluginDefs, _settings.connectionProfiles);
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
    _explorer.configurePlugins(pluginDefs, settings.connectionProfiles);
    final locations =
        await _explorer.loadLocations(pluginDefs, settings.connectionProfiles);
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
    if (!_isHttpMedia(entry.path)) return;
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
    try {
      final file = await _webMusicPlugins.download(
        entry,
        Directory(_expandPathVariables(targetPath.trim())),
      );
      _snack('${_language.t('transfer.done')} ${file.path}');
    } catch (error) {
      _snack('$error');
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
    _explorer.configurePlugins(pluginDefs, next.connectionProfiles);
    final locations =
        await _explorer.loadLocations(pluginDefs, next.connectionProfiles);
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
    final interfaceScale =
        _settings.interfaceTextScale.clamp(0.55, 2.2).toDouble();
    final dpi = _settings.autoScaleForDpi
        ? (MediaQuery.of(context).devicePixelRatio / 2.5).clamp(0.9, 1.35)
        : 1.0;
    return (_settings.fileTextScale * dpi * interfaceScale).clamp(0.55, 2.2);
  }

  double _effectiveIconScale(BuildContext context) {
    final interfaceScale =
        _settings.interfaceTextScale.clamp(0.55, 2.2).toDouble();
    final dpi = _settings.autoScaleForDpi
        ? (MediaQuery.of(context).devicePixelRatio / 2.5).clamp(0.9, 1.35)
        : 1.0;
    return (_settings.fileIconScale * dpi * interfaceScale).clamp(0.55, 2.5);
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
      await PlatformServices.openExternal(file.path);
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
                                  onDownloadEntry: _downloadPluginMediaEntry,
                                )
                              : _ExplorerView(
                                  language: _language,
                                  currentPath: _showingRecent
                                      ? _language.t('recent.title')
                                      : _currentPath,
                                  snapshot: _snapshot,
                                  selected: _selected,
                                  preview: _preview,
                                  mediaPlaylist: _mediaPlaylist,
                                  imagePlaylist: _imagePlaylist,
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
                                  showHiddenFiles: _settings.showHiddenFiles,
                                  showSystemFiles: _settings.showSystemFiles,
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
                                  onImageNavigate: _navigateImage,
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
                              sortLabel:
                                  _sortModeForCurrentPath().label(_language),
                              showHiddenFiles: _settings.showHiddenFiles,
                              showSystemFiles: _settings.showSystemFiles,
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
                onOpenFullScreen: _showPreviewWindow,
              ),
            ],
          ),
        ),
      ),
    ));
  }

  Widget _scaledInterface(Widget child) {
    final scale = _settings.interfaceTextScale.clamp(0.55, 2.2).toDouble();
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

  void _snack(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }
}

enum _CommonSetupDecision { cancel, unique, settings }

enum _EntryAction {
  open,
  createFolder,
  createPlain,
  createEncryptedPlain,
  createCsv,
  createEncryptedCsv,
  createImage,
  createEncryptedImage,
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
  folderContainer,
  folderEncryptName,
  folderDecryptName,
  folderEncrypt,
  folderDecrypt,
  useAsGallery,
  useAsVideo,
  useAsMusic,
  useAsMultimedia,
  editConnectionProfile,
  deleteConnectionProfile,
}

enum _PreviewAction {
  password,
  window,
  edit,
  speak,
  external,
  copy,
  cut,
  delete,
  properties,
  hide
}

enum _ExplorerMenuAction { upload, download, sort, toggleHidden, toggleSystem }

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
        _nav(
          Icons.folder_open,
          language.t('nav.explorer'),
          page == ShellPage.explorer,
          () => activate(onExplorer),
        ),
        _nav(
          Icons.photo_library_outlined,
          language.t('nav.gallery'),
          page == ShellPage.gallery,
          () => activate(() => onMediaSection(MediaSection.gallery)),
        ),
        _musicNav(
          selected: page == ShellPage.music && activePluginSectionId == null,
          activate: activate,
        ),
        _nav(
          Icons.movie_outlined,
          language.t('nav.video'),
          page == ShellPage.video,
          () => activate(() => onMediaSection(MediaSection.video)),
        ),
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
        _nav(
          Icons.tune,
          language.t('nav.settings'),
          page == ShellPage.settings,
          () => activate(onSettings),
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
    required this.onDownloadEntry,
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
  final Future<void> Function(ExplorerEntry) onDownloadEntry;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      _MediaHeader(
        title: title ?? language.t(isVideo ? 'nav.video' : 'nav.music'),
        language: language,
        onRefresh: onRefresh,
        onSearch: onSearch,
        onSearchFilters: onSearchFilters,
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
            if (preview == null) {
              return _MediaLibraryBrowser(
                language: language,
                entries: snap.data!.entries,
                isVideo: isVideo,
                mediaPlaylist: mediaPlaylist,
                mediaResumePositions: mediaResumePositions,
                onEntry: onEntry,
                onDownloadEntry: onDownloadEntry,
              );
            }
            return Padding(
              padding: const EdgeInsets.all(14),
              child: _PreviewPane(
                language: language,
                entry: entry,
                preview: preview,
                mediaPlaylist: mediaPlaylist,
                imagePlaylist: const [],
                mediaResumePositions: mediaResumePositions,
                onRememberMediaPosition: onRememberMediaPosition,
                visible: true,
                onTogglePreview: () {},
                onOpenPassword: onOpenPassword,
                onOpenExternal: onOpenExternal,
                onPreviewWindow: onPreviewWindow,
                onEditPreview: onEditPreview,
                onEntryAction: onPreviewEntryAction,
                onImageNavigate: (_) async => null,
                allowMiniDock: false,
              ),
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
    required this.onDownloadEntry,
  });

  final AppLanguage language;
  final List<ExplorerEntry> entries;
  final bool isVideo;
  final List<MediaPreviewItem> mediaPlaylist;
  final Map<String, int> mediaResumePositions;
  final Future<void> Function(ExplorerEntry) onEntry;
  final Future<void> Function(ExplorerEntry) onDownloadEntry;

  @override
  Widget build(BuildContext context) {
    final kind = isVideo ? FileContentKind.video : FileContentKind.audio;
    final mediaEntries = entries
        .where((entry) =>
            !entry.isDirectory &&
            (FileViewerService.kindForName(entry.name) == kind ||
                FileViewerService.kindForName(entry.path) == kind))
        .toList();
    final recent = mediaEntries
        .where((entry) => mediaResumePositions.containsKey(entry.path))
        .toList()
      ..sort((a, b) => (mediaResumePositions[b.path] ?? 0)
          .compareTo(mediaResumePositions[a.path] ?? 0));

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
              entries: mediaEntries,
              emptyText: language.t('media.choose.to.play'),
              onEntry: onEntry,
              onDownloadEntry: onDownloadEntry,
            ),
            _MediaEntryList(
              language: language,
              entries: mediaEntries,
              onEntry: onEntry,
              onDownloadEntry: onDownloadEntry,
            ),
            _MediaGroupList(
              language: language,
              groups: _groupByNameHeuristic(mediaEntries, 'playlist'),
              onEntry: onEntry,
              onDownloadEntry: onDownloadEntry,
            ),
            _MediaGroupList(
              language: language,
              groups: _groupByNameHeuristic(mediaEntries, 'album'),
              onEntry: onEntry,
              onDownloadEntry: onDownloadEntry,
            ),
            _MediaGroupList(
              language: language,
              groups: _groupByNameHeuristic(mediaEntries, 'artist'),
              onEntry: onEntry,
              onDownloadEntry: onDownloadEntry,
            ),
            _MediaGroupList(
              language: language,
              groups: _groupByNameHeuristic(mediaEntries, 'genre'),
              onEntry: onEntry,
              onDownloadEntry: onDownloadEntry,
            ),
            _MediaGroupList(
              language: language,
              groups: _groupByFolder(mediaEntries),
              onEntry: onEntry,
              onDownloadEntry: onDownloadEntry,
            ),
            _MediaEntryList(
              language: language,
              entries: recent,
              onEntry: onEntry,
              onDownloadEntry: onDownloadEntry,
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
}

class _MediaEntryList extends StatelessWidget {
  const _MediaEntryList({
    required this.language,
    required this.entries,
    required this.onEntry,
    required this.onDownloadEntry,
    this.emptyText,
  });

  final AppLanguage language;
  final List<ExplorerEntry> entries;
  final String? emptyText;
  final Future<void> Function(ExplorerEntry) onEntry;
  final Future<void> Function(ExplorerEntry) onDownloadEntry;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return Center(child: Text(emptyText ?? language.t('explorer.empty')));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(14),
      itemCount: entries.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = entries[index];
        final kind = FileViewerService.kindForName(entry.name);
        return ListTile(
          leading: Icon(kind == FileContentKind.video
              ? Icons.movie_outlined
              : Icons.audiotrack_outlined),
          title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${_size(entry)} - ${_date(entry.modifiedAt)}'),
          trailing: _isHttpMedia(entry.path)
              ? IconButton(
                  tooltip: language.t('plugin.media.download'),
                  icon: const Icon(Icons.download_outlined),
                  onPressed: () => unawaited(onDownloadEntry(entry)),
                )
              : null,
          onTap: () => unawaited(onEntry(entry)),
        );
      },
    );
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
  final Future<void> Function(ExplorerEntry) onEntry;
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
                onTap: () => unawaited(onEntry(entry)),
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
  final VoidCallback onSearchFilters;
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
    required this.onPreviewResize,
    required this.onTogglePreview,
    required this.onOpenPassword,
    required this.onOpenExternal,
    required this.onPreviewWindow,
    required this.onEditPreview,
    required this.onImageNavigate,
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
  final ValueChanged<double> onPreviewResize;
  final VoidCallback onTogglePreview;
  final VoidCallback onOpenPassword;
  final ValueChanged<FilePreview> onOpenExternal;
  final ValueChanged<FilePreview> onPreviewWindow;
  final ValueChanged<FilePreview> onEditPreview;
  final Future<FilePreview?> Function(int delta) onImageNavigate;
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
          child: Row(children: [
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
                sortLabel: sortMode.label(language),
                showHiddenFiles: showHiddenFiles,
                showSystemFiles: showSystemFiles,
                iconScale: toolbarIconScale,
                onSelected: onExplorerMenuAction,
              ),
            ],
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
            mediaResumePositions: mediaResumePositions,
            visible: previewVisible,
            onTogglePreview: onTogglePreview,
            onOpenPassword: onOpenPassword,
            onOpenExternal: onOpenExternal,
            onPreviewWindow: onPreviewWindow,
            onEditPreview: onEditPreview,
            onEntryAction: onEntryAction,
            onImageNavigate: onImageNavigate,
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
    required this.iconScale,
    required this.onSelected,
  });

  final AppLanguage language;
  final String sortLabel;
  final bool showHiddenFiles;
  final bool showSystemFiles;
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
        PopupMenuItem(
          value: _ExplorerMenuAction.sort,
          child: Text(sortLabel),
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
            onAction: onEmptyAreaAction,
            child: Center(child: Text(language.t('explorer.empty'))),
          );
        }
        final listView = ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: sortedEntries.length + 1,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            if (i == sortedEntries.length) {
              return _EmptyExplorerArea(
                language: language,
                currentPath: currentPath,
                canPaste: canPaste,
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
              onLongPress: () => _showEntryContextMenu(context, entry, null),
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
                  PopupMenuButton<_EntryAction>(
                    icon: const Icon(Icons.more_vert),
                    onSelected: (action) => _handleEntryAction(entry, action),
                    itemBuilder: (_) => _entryMenuItems(entry),
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
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selectedAction = await showMenu<_EntryAction>(
      context: context,
      position: position == null
          ? RelativeRect.fromLTRB(
              overlay.size.width / 2,
              overlay.size.height / 2,
              overlay.size.width / 2,
              overlay.size.height / 2,
            )
          : RelativeRect.fromRect(
              Rect.fromLTWH(position.dx, position.dy, 1, 1),
              Offset.zero & overlay.size,
            ),
      items: _entryMenuItems(entry),
    );
    if (selectedAction != null) {
      _handleEntryAction(entry, selectedAction);
    }
  }

  List<PopupMenuEntry<_EntryAction>> _entryMenuItems(ExplorerEntry entry) {
    final isFavorite = favoritePaths.contains(entry.path);
    final isRecent = recentPaths.contains(entry.path);
    final isVirtual = entry.path.startsWith('zip://');
    final isProfileLocation = entry.connectionProfileId != null;
    if (entry.isNavigationEntry) {
      return [
        PopupMenuItem(
          value: _EntryAction.open,
          child: Text(language.t('common.open')),
        ),
      ];
    }
    return <PopupMenuEntry<_EntryAction>>[
      PopupMenuItem(
        value: _EntryAction.open,
        child: Text(language.t('common.open')),
      ),
      const PopupMenuDivider(),
      PopupMenuItem(
        value: _EntryAction.createFolder,
        enabled: entry.exists &&
            entry.isDirectory &&
            !isVirtual &&
            !isProfileLocation,
        child: Text(
            '${language.t('explorer.create')} > ${language.t('create.folder')}'),
      ),
      PopupMenuItem(
        value: _EntryAction.createPlain,
        enabled: entry.exists &&
            entry.isDirectory &&
            !isVirtual &&
            !isProfileLocation,
        child: Text(
            '${language.t('explorer.create')} > ${language.t('create.plain')}'),
      ),
      PopupMenuItem(
        value: _EntryAction.createEncryptedPlain,
        enabled: entry.exists &&
            entry.isDirectory &&
            !isVirtual &&
            !isProfileLocation,
        child: Text(
            '${language.t('explorer.create')} > ${language.t('create.encrypted.plain')}'),
      ),
      PopupMenuItem(
        value: _EntryAction.createCsv,
        enabled: entry.exists &&
            entry.isDirectory &&
            !isVirtual &&
            !isProfileLocation,
        child: Text(
            '${language.t('explorer.create')} > ${language.t('create.csv')}'),
      ),
      PopupMenuItem(
        value: _EntryAction.createEncryptedCsv,
        enabled: entry.exists &&
            entry.isDirectory &&
            !isVirtual &&
            !isProfileLocation,
        child: Text(
            '${language.t('explorer.create')} > ${language.t('create.encrypted.csv')}'),
      ),
      PopupMenuItem(
        value: _EntryAction.createImage,
        enabled: entry.exists &&
            entry.isDirectory &&
            !isVirtual &&
            !isProfileLocation,
        child: Text(
            '${language.t('explorer.create')} > ${language.t('create.image')}'),
      ),
      PopupMenuItem(
        value: _EntryAction.createEncryptedImage,
        enabled: entry.exists &&
            entry.isDirectory &&
            !isVirtual &&
            !isProfileLocation,
        child: Text(
            '${language.t('explorer.create')} > ${language.t('create.encrypted.image')}'),
      ),
      PopupMenuItem(
        value:
            isFavorite ? _EntryAction.removeFavorite : _EntryAction.addFavorite,
        child: Text(
          isFavorite
              ? language.t('favorites.remove')
              : language.t('favorites.add'),
        ),
      ),
      if (isRecent)
        PopupMenuItem(
          value: _EntryAction.removeRecent,
          child: Text(language.t('recent.remove')),
        ),
      const PopupMenuDivider(),
      PopupMenuItem(
        value: _EntryAction.copy,
        enabled: entry.exists && !isVirtual && !isProfileLocation,
        child: Text(language.t('explorer.copy')),
      ),
      PopupMenuItem(
        value: _EntryAction.cut,
        enabled: entry.exists && !isVirtual && !isProfileLocation,
        child: Text(language.t('explorer.cut')),
      ),
      PopupMenuItem(
        value: _EntryAction.paste,
        enabled: canPaste &&
            entry.isDirectory &&
            entry.exists &&
            !isVirtual &&
            !isProfileLocation,
        child: Text(language.t('explorer.paste')),
      ),
      PopupMenuItem(
        value: _EntryAction.rename,
        enabled: entry.exists && !isVirtual && !isProfileLocation,
        child: Text(language.t('explorer.rename')),
      ),
      PopupMenuItem(
        value: _EntryAction.delete,
        enabled: entry.exists && !isVirtual && !isProfileLocation,
        child: Text(language.t('explorer.delete')),
      ),
      PopupMenuItem(
        value: _EntryAction.properties,
        child: Text(language.t('explorer.properties')),
      ),
      if (entry.connectionProfileId != null) const PopupMenuDivider(),
      if (entry.connectionProfileId != null)
        PopupMenuItem(
          value: _EntryAction.editConnectionProfile,
          child: Text(language.t('locations.profile.edit')),
        ),
      if (entry.connectionProfileId != null)
        PopupMenuItem(
          value: _EntryAction.deleteConnectionProfile,
          child: Text(language.t('locations.profile.delete')),
        ),
      PopupMenuItem(
        value: _EntryAction.send,
        enabled: entry.exists && !isVirtual && !isProfileLocation,
        child: Text(language.t('explorer.send')),
      ),
      if (!entry.isDirectory) const PopupMenuDivider(),
      if (!entry.isDirectory &&
          FileViewerService.extensionForName(entry.path) == '.zip')
        PopupMenuItem(
          value: _EntryAction.unzip,
          enabled: entry.exists && !isVirtual && !isProfileLocation,
          child: Text(language.t('explorer.unzip')),
        ),
      if (!entry.isDirectory && !entry.isEncrypted)
        PopupMenuItem(
          value: _EntryAction.encrypt,
          enabled: entry.exists && !isVirtual && !isProfileLocation,
          child: Text(language.t('explorer.encrypt')),
        ),
      if (!entry.isDirectory && entry.isEncrypted)
        PopupMenuItem(
          value: _EntryAction.decrypt,
          enabled: entry.exists && !isVirtual && !isProfileLocation,
          child: Text(language.t('decrypt.action')),
        ),
      if (entry.isDirectory) const PopupMenuDivider(),
      if (entry.isDirectory)
        PopupMenuItem(
          value: _EntryAction.folderContainer,
          enabled: entry.exists && !isVirtual && !isProfileLocation,
          child: Text(language.t('explorer.folder.container')),
        ),
      if (entry.isDirectory)
        PopupMenuItem(
          value: _EntryAction.folderEncryptName,
          enabled: entry.exists && !isVirtual && !isProfileLocation,
          child: Text(language.t('explorer.folder.encrypt.name')),
        ),
      if (entry.isDirectory)
        PopupMenuItem(
          value: _EntryAction.folderDecryptName,
          enabled: entry.exists && !isVirtual && !isProfileLocation,
          child: Text(language.t('explorer.folder.decrypt.name')),
        ),
      if (entry.isDirectory)
        PopupMenuItem(
          value: _EntryAction.folderEncrypt,
          enabled: entry.exists && !isVirtual && !isProfileLocation,
          child: Text(language.t('explorer.folder.encrypt')),
        ),
      if (entry.isDirectory)
        PopupMenuItem(
          value: _EntryAction.folderDecrypt,
          enabled: entry.exists && !isProfileLocation,
          child: Text(language.t('explorer.folder.decrypt')),
        ),
      if (entry.isDirectory) const PopupMenuDivider(),
      if (entry.isDirectory)
        PopupMenuItem(
          value: _EntryAction.useAsGallery,
          enabled: entry.exists,
          child: Text(
              '${language.t('explorer.use.as')} > ${language.t('explorer.use.as.gallery')}'),
        ),
      if (entry.isDirectory)
        PopupMenuItem(
          value: _EntryAction.useAsVideo,
          enabled: entry.exists,
          child: Text(
              '${language.t('explorer.use.as')} > ${language.t('explorer.use.as.video')}'),
        ),
      if (entry.isDirectory)
        PopupMenuItem(
          value: _EntryAction.useAsMusic,
          enabled: entry.exists,
          child: Text(
              '${language.t('explorer.use.as')} > ${language.t('explorer.use.as.music')}'),
        ),
      if (entry.isDirectory)
        PopupMenuItem(
          value: _EntryAction.useAsMultimedia,
          enabled: entry.exists,
          child: Text(
              '${language.t('explorer.use.as')} > ${language.t('explorer.use.as.multimedia')}'),
        ),
    ];
  }

  void _handleEntryAction(ExplorerEntry entry, _EntryAction action) {
    switch (action) {
      case _EntryAction.open:
        onEntry(entry);
      case _EntryAction.createFolder:
      case _EntryAction.createPlain:
      case _EntryAction.createEncryptedPlain:
      case _EntryAction.createCsv:
      case _EntryAction.createEncryptedCsv:
      case _EntryAction.createImage:
      case _EntryAction.createEncryptedImage:
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
      if (!entry.isEncrypted && !entry.path.startsWith('zip://')) {
        return _ThumbBox(
          size: boxSize,
          child: Image.file(
            File(entry.path),
            fit: BoxFit.cover,
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
        future: entry.isEncrypted || entry.path.startsWith('zip://')
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
        future: entry.isEncrypted || entry.path.startsWith('zip://')
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
    required this.onAction,
    required this.child,
  });

  final AppLanguage language;
  final String? currentPath;
  final bool canPaste;
  final Future<void> Function(String, _EntryAction) onAction;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: (details) =>
          _showMenu(context, details.globalPosition),
      onLongPress: () => _showMenu(context, null),
      child: child,
    );
  }

  Future<void> _showMenu(BuildContext context, Offset? position) async {
    final path = currentPath;
    if (path == null) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<_EntryAction>(
      context: context,
      position: position == null
          ? RelativeRect.fromLTRB(
              overlay.size.width / 2,
              overlay.size.height / 2,
              overlay.size.width / 2,
              overlay.size.height / 2,
            )
          : RelativeRect.fromRect(
              Rect.fromLTWH(position.dx, position.dy, 1, 1),
              Offset.zero & overlay.size,
            ),
      items: [
        PopupMenuItem(
          value: _EntryAction.paste,
          enabled: canPaste,
          child: Text(language.t('explorer.paste')),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _EntryAction.createFolder,
          child: Text(
              '${language.t('explorer.create')} > ${language.t('create.folder')}'),
        ),
        PopupMenuItem(
          value: _EntryAction.createPlain,
          child: Text(
              '${language.t('explorer.create')} > ${language.t('create.plain')}'),
        ),
        PopupMenuItem(
          value: _EntryAction.createEncryptedPlain,
          child: Text(
              '${language.t('explorer.create')} > ${language.t('create.encrypted.plain')}'),
        ),
        PopupMenuItem(
          value: _EntryAction.createCsv,
          child: Text(
              '${language.t('explorer.create')} > ${language.t('create.csv')}'),
        ),
        PopupMenuItem(
          value: _EntryAction.createImage,
          child: Text(
              '${language.t('explorer.create')} > ${language.t('create.image')}'),
        ),
      ],
    );
    if (selected != null) {
      await onAction(path, selected);
    }
  }
}

class _PreviewPane extends StatelessWidget {
  const _PreviewPane({
    required this.language,
    required this.entry,
    required this.preview,
    required this.mediaPlaylist,
    required this.imagePlaylist,
    required this.mediaResumePositions,
    required this.visible,
    required this.onTogglePreview,
    required this.onOpenPassword,
    required this.onOpenExternal,
    required this.onPreviewWindow,
    required this.onEditPreview,
    required this.onEntryAction,
    required this.onImageNavigate,
    required this.onRememberMediaPosition,
    this.allowMiniDock = true,
  });

  final AppLanguage language;
  final ExplorerEntry? entry;
  final Future<FilePreview>? preview;
  final List<MediaPreviewItem> mediaPlaylist;
  final List<MediaPreviewItem> imagePlaylist;
  final Map<String, int> mediaResumePositions;
  final bool visible;
  final VoidCallback onTogglePreview;
  final VoidCallback onOpenPassword;
  final ValueChanged<FilePreview> onOpenExternal;
  final ValueChanged<FilePreview> onPreviewWindow;
  final ValueChanged<FilePreview> onEditPreview;
  final Future<void> Function(ExplorerEntry, _EntryAction) onEntryAction;
  final Future<FilePreview?> Function(int delta) onImageNavigate;
  final Future<void> Function(String key, Duration position)
      onRememberMediaPosition;
  final bool allowMiniDock;

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
                mediaResumePositions: mediaResumePositions,
                allowMiniDock: allowMiniDock,
                onRememberMediaPosition: onRememberMediaPosition,
                onImageNavigate: (delta) async {
                  await onImageNavigate(delta);
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
                      unawaited(PlatformServices.speakText(
                        p.text ?? p.subtitle,
                      ));
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
    this.onImageNavigate,
    this.mediaResumePositions = const <String, int>{},
    this.onRememberMediaPosition,
    this.fillAvailable = false,
    this.allowMiniDock = true,
  });

  final FilePreview preview;
  final AppLanguage language;
  final List<MediaPreviewItem> mediaPlaylist;
  final List<MediaPreviewItem> imagePlaylist;
  final Future<void> Function(int delta)? onImageNavigate;
  final Map<String, int> mediaResumePositions;
  final Future<void> Function(String key, Duration position)?
      onRememberMediaPosition;
  final bool fillAvailable;
  final bool allowMiniDock;

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
      );
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
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF101923),
          borderRadius: BorderRadius.circular(16),
        ),
        child: SelectableText(
          preview.text!,
          style: const TextStyle(
            color: Color(0xFFE8F0F7),
            fontFamily: 'Consolas',
            fontSize: 13,
            height: 1.35,
          ),
        ),
      );
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
  const _CodePreview({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF101923),
        borderRadius: BorderRadius.circular(16),
      ),
      child: SelectableText(
        text,
        style: const TextStyle(
          color: Color(0xFFE8F0F7),
          fontFamily: 'Consolas',
          fontSize: 13,
          height: 1.35,
        ),
      ),
    );
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
          onPressed: () => unawaited(_pick()),
        ),
      ),
    );
  }

  Future<void> _pick() async {
    final selected = pickDirectory
        ? await PlatformServices.pickDirectory()
        : await PlatformServices.pickFile();
    if (selected == null || selected.trim().isEmpty) return;
    if (multiLine && controller.text.trim().isNotEmpty) {
      controller.text = '${controller.text.trimRight()}\n${selected.trim()}';
    } else {
      controller.text = selected.trim();
    }
  }
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
  });

  final FilePreview preview;
  final List<MediaPreviewItem> playlist;
  final AppLanguage language;
  final Map<String, int> resumePositions;
  final Future<void> Function(String key, Duration position)?
      onRememberPosition;
  final bool allowMiniDock;

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
            duration - position < const Duration(seconds: 3)
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
              ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: _AdaptiveVideoSurface(controller: _controller),
              )
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
                    Text(
                      widget.preview.title,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleMedium,
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
}

class _AdaptiveVideoSurface extends StatelessWidget {
  const _AdaptiveVideoSurface({required this.controller});

  final VideoController controller;

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
          return Center(
            child: AspectRatio(
              aspectRatio: aspectRatio.clamp(0.1, 10.0).toDouble(),
              child: Video(controller: controller, fit: BoxFit.contain),
            ),
          );
        },
      ),
    );
  }
}

class _SharedMediaSession extends ChangeNotifier {
  _SharedMediaSession();

  late final Player player = Player();
  late final VideoController controller = VideoController(player);
  _InMemoryMediaServer? _memoryMediaServer;
  FilePreview? preview;
  List<MediaPreviewItem> playlist = const [];
  String _sessionKey = '';
  var active = false;
  var collapsed = false;
  var dockSuppressed = false;

  static String keyFor(FilePreview preview, List<MediaPreviewItem> playlist) {
    final itemsKey = playlist
        .map((item) =>
            '${item.title}|${item.path ?? ''}|${item.resumeKey ?? ''}|${item.bytes?.length ?? 0}|${item.encrypted}')
        .join('\n');
    return '${preview.title}|${preview.sourcePath ?? ''}|${preview.contentKind.name}|$itemsKey';
  }

  bool isSame(FilePreview preview, List<MediaPreviewItem> playlist) =>
      active && _sessionKey == keyFor(preview, playlist);

  MediaPreviewItem? get currentItem {
    if (playlist.isEmpty) return null;
    final index = player.state.playlist.index.clamp(0, playlist.length - 1);
    return playlist[index.toInt()];
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
      collapsed = false;
      dockSuppressed = !allowMiniDock;
      await player.setPlaylistMode(
        repeatOne ? PlaylistMode.single : PlaylistMode.loop,
      );
      await player.setShuffle(shuffle);
      notifyListeners();
      return;
    }
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
            path.startsWith('zip://')) {
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
    collapsed = false;
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

class _FloatingMediaDock extends StatefulWidget {
  const _FloatingMediaDock({
    required this.session,
    required this.language,
    required this.enableMiniVideo,
    required this.enableMiniAudio,
    required this.continueInBackground,
    required this.onOpenFullScreen,
  });

  final _SharedMediaSession session;
  final AppLanguage language;
  final bool enableMiniVideo;
  final bool enableMiniAudio;
  final bool continueInBackground;
  final ValueChanged<FilePreview> onOpenFullScreen;

  @override
  State<_FloatingMediaDock> createState() => _FloatingMediaDockState();
}

class _BackgroundJobsPanel extends StatefulWidget {
  const _BackgroundJobsPanel({
    required this.jobs,
    required this.language,
    required this.onCancel,
    required this.onRemove,
    required this.onToggleCollapsed,
  });

  final List<_BackgroundJob> jobs;
  final AppLanguage language;
  final ValueChanged<_BackgroundJob> onCancel;
  final ValueChanged<_BackgroundJob> onRemove;
  final ValueChanged<_BackgroundJob> onToggleCollapsed;

  @override
  State<_BackgroundJobsPanel> createState() => _BackgroundJobsPanelState();
}

class _BackgroundJobsPanelState extends State<_BackgroundJobsPanel> {
  Offset? _offset;
  var _compact = false;

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
        onTap: () => setState(() => _compact = false),
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
              done ? '${widget.jobs.length}' : '${(aggregate * 100).round()}%',
              style: const TextStyle(fontWeight: FontWeight.w800),
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
        final height = isVideo && !widget.session.collapsed ? 236.0 : 92.0;
        final left = _offset.dx
            .clamp(8.0, math.max(8.0, size.width - width - 8))
            .toDouble();
        final top = _offset.dy
            .clamp(8.0, math.max(8.0, size.height - height - 8))
            .toDouble();
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
                  _AdaptiveVideoSurface(
                    controller: widget.session.controller,
                  )
                else
                  _MiniAudioHeader(item: item),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(children: [
                    Expanded(
                      child: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
                      onPressed: () => widget.session.setCollapsed(
                        !widget.session.collapsed,
                      ),
                      icon: Icon(widget.session.collapsed
                          ? Icons.open_in_full
                          : Icons.minimize),
                      tooltip: widget.language.t('preview.window'),
                    ),
                    IconButton(
                      onPressed: () => widget.onOpenFullScreen(preview),
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
          height: 34,
          color: Theme.of(context).colorScheme.secondaryContainer,
          child: Row(children: [
            const SizedBox(width: 10),
            if (bytes != null && bytes.isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(bytes,
                    width: 28, height: 28, fit: BoxFit.cover),
              )
            else
              const Icon(Icons.graphic_eq, size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'SecureVault media',
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
          ]),
        );
      },
    );
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
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
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
            const SizedBox(width: 8),
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
            StreamBuilder<Tracks>(
              stream: player.stream.tracks,
              initialData: player.state.tracks,
              builder: (context, snapshot) {
                final tracks = snapshot.data ?? const Tracks();
                return PopupMenuButton<Object>(
                  tooltip: language.t('media.tracks'),
                  icon: const Icon(Icons.subtitles_outlined),
                  onSelected: (track) {
                    if (track is AudioTrack) {
                      unawaited(player.setAudioTrack(track));
                    } else if (track is SubtitleTrack) {
                      unawaited(player.setSubtitleTrack(track));
                    }
                  },
                  itemBuilder: (_) => [
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
                  ],
                );
              },
            ),
            PopupMenuButton<String>(
              tooltip: language.t('media.equalizer'),
              icon: const Icon(Icons.equalizer_outlined),
              onSelected: (preset) =>
                  unawaited(_applyEqualizerPreset(player, preset)),
              itemBuilder: (_) => [
                for (final preset in const [
                  'flat',
                  'bass',
                  'voice',
                  'treble',
                  'loudness'
                ])
                  PopupMenuItem(
                    value: preset,
                    child: Text(language.t('media.equalizer.$preset')),
                  ),
              ],
            ),
          ]),
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
    final currentIndex = player.state.playlist.index;
    final currentItems = items.isEmpty
        ? const <MediaPreviewItem>[]
        : [items[currentIndex.clamp(0, items.length - 1).toInt()]];
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
                          items: currentItems,
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
  });

  final FilePreview preview;
  final AppLanguage language;
  final String? currentDirectory;

  @override
  State<_TextBinaryEditorDialog> createState() =>
      _TextBinaryEditorDialogState();
}

class _TextBinaryEditorDialogState extends State<_TextBinaryEditorDialog> {
  late Uint8List _bytes;
  late final TextEditingController _controller;
  late final TextEditingController _searchController;
  late final TextEditingController _outputController;
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
    final directory = widget.currentDirectory ??
        (widget.preview.sourcePath == null
            ? Directory.current.path
            : File(widget.preview.sourcePath!).parent.path);
    _outputController = TextEditingController(
      text:
          '$directory${Platform.pathSeparator}${_fileNameWithoutExtension(widget.preview.title)}_edited${FileViewerService.extensionForName(widget.preview.title)}',
    );
    _rebuildEditorText();
  }

  @override
  void dispose() {
    _controller.dispose();
    _searchController.dispose();
    _outputController.dispose();
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
            expands: true,
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
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(_bytes, flush: true);
      if (mounted) Navigator.pop(context, file.path);
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
    setState(() => _status = null);
  }

  bool _canOverwriteSource(FilePreview preview) {
    final path = preview.sourcePath;
    if (path == null || preview.decrypted) return false;
    return !(path.startsWith('remote://') ||
        path.startsWith('zip://') ||
        path.startsWith('torrent://'));
  }

  String _toHex(Uint8List bytes) {
    final buffer = StringBuffer();
    for (var i = 0; i < bytes.length; i++) {
      if (i > 0) {
        buffer.write(i % 16 == 0 ? '\n' : ' ');
      }
      buffer.write(bytes[i].toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  String _toBinary(Uint8List bytes) {
    final buffer = StringBuffer();
    for (var i = 0; i < bytes.length; i++) {
      if (i > 0) {
        buffer.write(i % 8 == 0 ? '\n' : ' ');
      }
      buffer.write(bytes[i].toRadixString(2).padLeft(8, '0'));
    }
    return buffer.toString();
  }

  Uint8List _parseHex(String value) {
    final cleaned = value.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    if (cleaned.length.isOdd) {
      throw const FormatException('Hex length must be even.');
    }
    return Uint8List.fromList([
      for (var i = 0; i < cleaned.length; i += 2)
        int.parse(cleaned.substring(i, i + 2), radix: 16),
    ]);
  }

  Uint8List _parseBinary(String value) {
    final cleaned = value.replaceAll(RegExp(r'[^01]'), '');
    if (cleaned.length % 8 != 0) {
      throw const FormatException('Binary length must be divisible by 8.');
    }
    return Uint8List.fromList([
      for (var i = 0; i < cleaned.length; i += 8)
        int.parse(cleaned.substring(i, i + 8), radix: 2),
    ]);
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
  });

  final FilePreview preview;
  final AppLanguage language;
  final String? currentDirectory;

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
    final directory = widget.currentDirectory ??
        (widget.preview.sourcePath == null
            ? Directory.current.path
            : File(widget.preview.sourcePath!).parent.path);
    _outputController = TextEditingController(
      text:
          '$directory${Platform.pathSeparator}${_fileNameWithoutExtension(widget.preview.title)}_edited.png',
    );
  }

  @override
  void dispose() {
    _outputController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.language.t('editor.image.title')),
          actions: [
            IconButton(
              onPressed: _busy ? null : _save,
              icon: const Icon(Icons.save_outlined),
              tooltip: widget.language.t('editor.save.as'),
            ),
          ],
        ),
        body: Row(children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
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
            ),
          ),
          SizedBox(
            width: 360,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _outputController,
                    decoration: InputDecoration(
                      labelText: widget.language.t('editor.output.path'),
                    ),
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
                    onChanged: (value) =>
                        setState(() => _format = value ?? 'png'),
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
            ),
          ),
        ]),
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
      await File(path).writeAsBytes(bytes, flush: true);
      if (mounted) Navigator.pop(context, path);
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
    this.initialProfile,
  });

  final AppLanguage language;
  final CloudPluginDefinition plugin;
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
      _variableControllers[entry.key] = TextEditingController(
        text: initialProfile?.variables[entry.key] ??
            _variableDefault(entry.value),
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
    return SingleChildScrollView(
      padding: EdgeInsets.only(
        left: 0,
        right: 0,
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
            Text(language.t('settings.plugin.no.global.settings'))
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
    final variables = <String, String>{};
    for (final entry in _variableControllers.entries) {
      final value = entry.value.text.trim();
      if (value.isNotEmpty) {
        variables[entry.key] = value;
      }
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
    required this.onInstallPluginZip,
    required this.onExportPluginZip,
    required this.onDeletePlugin,
    required this.onSavePluginSettings,
  });

  final AppLanguage language;
  final List<CloudPluginDefinition> plugins;
  final Map<String, Map<String, String>> pluginSettingsById;
  final Future<String> Function(String path) onInstallPluginZip;
  final Future<String> Function(String pluginId) onExportPluginZip;
  final Future<String> Function(String pluginId) onDeletePlugin;
  final Future<String> Function(String pluginId, Map<String, String> settings)
      onSavePluginSettings;

  @override
  State<_PluginSettingsDialog> createState() => _PluginSettingsDialogState();
}

class _PluginSettingsDialogState extends State<_PluginSettingsDialog> {
  final _zipController = TextEditingController();
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
    required double toolbarIconScale,
    required String searchMode,
    required bool searchUseRegex,
    required bool searchRecursive,
    required String? programProxy,
    required String? globalPluginProxy,
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
    required bool encryptThumbnailCache,
    required bool encryptResumePositions,
  }) onSave;
  final Future<void> Function() onRequestAndroidStorageAccess;
  final Future<void> Function() onClear;
  final Future<String> Function(String guardPassword) onRevealCommonKey;
  final Future<String> Function(String path) onValidateLanguageFile;
  final Future<String> Function(String path) onInstallLanguageFile;
  final Future<String> Function(String path) onInstallPluginZip;
  final Future<String> Function(String pluginId) onExportPluginZip;
  final Future<String> Function(String pluginId) onDeletePlugin;
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
  late final TextEditingController _toolbarIconScale;
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
  late bool _encryptThumbnailCache;
  late bool _encryptResumePositions;
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
    _encryptThumbnailCache = widget.settings.encryptThumbnailCache;
    _encryptResumePositions = widget.settings.encryptResumePositions;
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
    _toolbarIconScale = TextEditingController(
      text: widget.settings.toolbarIconScale.toStringAsFixed(2),
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
      _toolbarIconScale,
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
    _toolbarIconScale.dispose();
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
          value: _autoCloseMediaOnSectionChange,
          onChanged: (v) => setState(() => _autoCloseMediaOnSectionChange = v),
          title: Text(language.t('settings.background.autoclose')),
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
        encryptThumbnailCache: _encryptThumbnailCache,
        encryptResumePositions: _encryptResumePositions,
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
        onInstallPluginZip: widget.onInstallPluginZip,
        onExportPluginZip: widget.onExportPluginZip,
        onDeletePlugin: widget.onDeletePlugin,
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
