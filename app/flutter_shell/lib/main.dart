import 'dart:async';
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
import 'src/platform_services.dart';
import 'src/plugins/cloud_plugin_registry.dart' hide basename;
import 'src/security/security_settings.dart';
import 'src/storage/app_paths.dart';
import 'src/viewer/file_viewer_service.dart';
import 'src/viewer/media_artwork_service.dart';

const _appVersion = '0.8.0';

void main(List<String> args) {
  MediaKit.ensureInitialized();
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

class VaultHomeScreen extends StatefulWidget {
  const VaultHomeScreen({super.key, this.initialOpenPath});

  final String? initialOpenPath;

  @override
  State<VaultHomeScreen> createState() => _VaultHomeScreenState();
}

class _VaultHomeScreenState extends State<VaultHomeScreen> {
  late final CryptBindings _bindings;
  late final FileExplorerRepository _explorer;
  late final CloudPluginRegistry _plugins;
  late final SecuritySettingsRepository _settingsRepo;

  var _loading = true;
  var _locked = false;
  var _page = ShellPage.explorer;
  var _locations = <ExplorerLocation>[];
  var _pluginDefs = <CloudPluginDefinition>[];
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
  bool _previewVisible = true;
  String? _clipboardPath;
  bool _clipboardCut = false;
  bool _showingRecent = false;
  String _searchQuery = '';
  String _searchMode = 'name';
  bool _searchUseRegex = false;
  bool _searchRecursive = false;
  bool _goingUp = false;

  @override
  void initState() {
    super.initState();
    _bindings = CryptBindings();
    _explorer = FileExplorerRepository(_bindings);
    _plugins = CloudPluginRegistry();
    _settingsRepo = SecuritySettingsRepository();
    _boot();
  }

  Future<void> _boot() async {
    final settings = await _settingsRepo.load();
    final language = await AppLanguage.load(settings);
    await PlatformServices.setWindowTitle(language.appTitle).catchError((_) {});
    final commonPassword = !settings.hasFilePassword && !settings.hasAppPassword
        ? await _settingsRepo
            .loadCommonEncryptionPassword(settings)
            .catchError((_) => null)
        : null;
    await PlatformServices.setScreenProtection(settings.blockScreenCapture);
    final runtime = await _bindings.getRuntimeInfo();
    final pluginDefs = await _plugins.loadPlugins();
    final locations = await _explorer.loadLocations(pluginDefs);
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
      _locations = locations;
      _currentPath = currentPath;
      _selected = selected;
      _preview = preview;
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

  void _openPath(String path) {
    unawaited(_rememberOpenedFolder(path));
    setState(() {
      _page = ShellPage.explorer;
      _showingRecent = false;
      _currentPath = path;
      _selected = null;
      _preview = null;
      _mediaPlaylist = const [];
      _imagePlaylist = const [];
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

  Future<void> _openPathSafely(String path, {bool fromUp = false}) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      _openPath(path);
      return;
    }
    final policy = _settings.navigationPolicy;
    if (policy == 'allow') {
      _openPath(path);
      return;
    }
    if (fromUp && policy == 'fallbackToLocations') {
      _openExplorerHome();
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

  Future<void> _refresh() async {
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

  void _selectLocation(ExplorerLocation location) {
    if (!location.enabled || location.path == null) {
      _showProvider(location);
      return;
    }
    unawaited(_openPathSafely(location.path!));
  }

  void _openExplorerHome() {
    final paths = <String>[
      for (final location in _locations)
        if (location.enabled && location.path != null) location.path!,
      ..._settings.galleryFolders,
      ..._settings.musicFolders,
      ..._settings.videoFolders,
      ..._settings.documentFolders,
    ];
    setState(() {
      _page = ShellPage.explorer;
      _showingRecent = false;
      _selected = null;
      _preview = null;
      _mediaPlaylist = const [];
      _imagePlaylist = const [];
      _snapshot = _explorer.snapshotForPaths(
        _language.t('nav.explorer'),
        paths,
      );
    });
  }

  void _openMediaSection(MediaSection section) {
    unawaited(_openMediaSectionAsync(section));
  }

  Future<void> _openMediaSectionAsync(MediaSection section) async {
    if (section == MediaSection.torrent && !_settings.torrentEnabled) {
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
        : _mediaRootsFor(configuredRoots);
    final snapshotFuture = section == MediaSection.torrent
        ? AppPaths.torrentsDirectory().then((dir) => _explorer.listDirectory(
              dir.path,
              commonPassword: _commonEncryptionPassword,
              filePassword: _activeFilePassword(),
              decryptNames: _settings.decryptNamesInExplorer,
            ))
        : _explorer.mediaSnapshot(
            label: label,
            roots: roots,
            extensions: extensions,
            exclusions: exclusions,
          );
    setState(() {
      _page = page;
      _showingRecent = false;
      _currentPath = label;
      _selected = null;
      _preview = null;
      _mediaPlaylist = const [];
      _imagePlaylist = const [];
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
    final first = snapshot.entries.firstWhere(
      (entry) => FileViewerService.kindForName(entry.name) == kind,
      orElse: () => snapshot.entries.first,
    );
    final previewFuture = _explorer.previewFile(
      first.path,
      password: _activeFilePassword(),
      commonPassword: _commonEncryptionPassword,
    );
    setState(() {
      _selected = first;
      _preview = previewFuture;
      _mediaPlaylist = _mediaItemsFromEntries(snapshot.entries, kind);
      _imagePlaylist = const [];
    });
    if (_settings.rememberRecentFiles) {
      final next = await _settingsRepo.recordRecentFile(_settings, first.path);
      if (mounted) setState(() => _settings = next);
    }
  }

  List<String> _mediaRootsFor(List<String> configuredRoots) {
    final configured = configuredRoots
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();
    if (configured.isNotEmpty) return configured;

    final roots = <String>[];
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
      _showingRecent = true;
      _selected = null;
      _preview = null;
      _mediaPlaylist = const [];
      _imagePlaylist = const [];
      _snapshot = _explorer.snapshotForPaths(
        _language.t('recent.title'),
        _settings.recentFilePaths.take(_settings.recentRememberCount).toList(),
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
    if (!entry.exists) {
      await _offerRemoveMissingRecent(entry.path);
      return;
    }
    if (entry.isDirectory) {
      await _openPathSafely(entry.path);
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

    final parent = File(selected.path).parent.path;
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

    final selectedItem = MediaPreviewItem(
      title: selectedPreview.title,
      kind: kind,
      path: selectedPreview.decrypted ? null : selected.path,
      resumeKey: selected.path,
      bytes: selectedPreview.decrypted && selectedPreview.bytes != null
          ? Uint8List.fromList(selectedPreview.bytes!)
          : null,
      encrypted: selectedPreview.decrypted,
    );

    final parent = File(selected.path).parent.path;
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

      if (entry.isEncrypted) {
        if (displayedKind != kind) continue;
        try {
          final preview = await _explorer.previewFile(
            entry.path,
            password: _activeFilePassword(),
            commonPassword: _commonEncryptionPassword,
          );
          if (preview.contentKind == kind && preview.bytes != null) {
            items.add(MediaPreviewItem(
              title: preview.title,
              kind: kind,
              resumeKey: entry.path,
              bytes: Uint8List.fromList(preview.bytes!),
              encrypted: true,
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
        final parent = Directory(path).parent.path;
        if (_normalizePath(parent) != _normalizePath(path)) {
          await _openPathSafely(parent, fromUp: true);
        } else {
          _openExplorerHome();
        }
      } finally {
        _goingUp = false;
      }
    }());
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
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_language.t('search.filters')),
        content: Text(_language.t('search.filters.note')),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_language.t('common.ok')),
          ),
        ],
      ),
    );
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
          _clipboardPath = entry.path;
          _clipboardCut = false;
        });
        _snack(_language.t('snack.copied'));
      case _EntryAction.cut:
        setState(() {
          _clipboardPath = entry.path;
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
      case _EntryAction.folderContainer:
      case _EntryAction.folderEncrypt:
      case _EntryAction.folderDecrypt:
        _snack(_language.t('snack.folder.actions.next'));
      case _EntryAction.useAsGallery:
      case _EntryAction.useAsVideo:
      case _EntryAction.useAsMusic:
      case _EntryAction.useAsMultimedia:
        await _useFolderAs(entry, action);
    }
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

  Future<void> _pasteClipboard(String? targetDirectory) async {
    final source = _clipboardPath;
    if (source == null || targetDirectory == null) return;
    try {
      final result = _clipboardCut
          ? await _explorer.moveEntityToDirectory(source, targetDirectory)
          : await _explorer.copyEntityToDirectory(source, targetDirectory);
      if (_clipboardCut) {
        setState(() {
          _clipboardPath = null;
          _clipboardCut = false;
        });
      }
      _snack('${_language.t('snack.pasted')} ${result.path}');
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
      final file = File('$targetDir${Platform.pathSeparator}${spec.name}');
      final target = await _availableCreatedFile(file);
      await target.writeAsBytes(spec.bytes, flush: true);
      if (kind == _CreateFileKind.encryptedPlain ||
          kind == _CreateFileKind.encryptedCsv ||
          kind == _CreateFileKind.encryptedImage) {
        final password = await _passwordForGeneratedEncryption();
        if (password == null || password.isEmpty) {
          await target.delete();
          return;
        }
        final encrypted = await _explorer.encryptFileToDirectory(
          target,
          Directory(targetDir),
          password: password,
          keyMode: _settings.hasCommonEncryption
              ? EncryptionKeyMode.common
              : EncryptionKeyMode.unique,
          algorithm: _settings.commonEncryptionAlgorithm,
        );
        await target.delete();
        _snack('${_language.t('snack.created')} ${encrypted.path}');
      } else {
        _snack('${_language.t('snack.created')} ${target.path}');
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

  Future<File> _availableCreatedFile(File desired) async {
    if (!await desired.exists()) return desired;
    final parent = desired.parent;
    final name = basename(desired.path);
    final dot = name.lastIndexOf('.');
    final stem = dot <= 0 ? name : name.substring(0, dot);
    final ext = dot <= 0 ? '' : name.substring(dot);
    var index = 1;
    while (true) {
      final candidate =
          File('${parent.path}${Platform.pathSeparator}$stem-$index$ext');
      if (!await candidate.exists()) return candidate;
      index++;
    }
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

    try {
      final file = await _explorer.encryptSelectedFile(
        File(selected.path),
        options,
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
    try {
      final file =
          await _explorer.decryptSelectedFile(File(selected.path), options);
      _snack('${_language.t('snack.decrypted')} ${file.path}');
      await _refresh();
    } catch (error) {
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
                      case _PreviewAction.external:
                        _openPreviewExternal(currentPreview);
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
                    if (currentPreview.contentKind == FileContentKind.image ||
                        currentPreview.contentKind == FileContentKind.audio ||
                        currentPreview.contentKind == FileContentKind.video)
                      PopupMenuItem(
                        value: _PreviewAction.edit,
                        child: Text(_language.t('editor.open')),
                      ),
                    PopupMenuItem(
                      value: _PreviewAction.external,
                      child: Text(_language.t('preview.external')),
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
    _snack(language.t('settings.saved'));
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
    setState(() => _pluginDefs = pluginDefs);
    return '${_language.t('settings.plugin.installed')} ${dir.path}';
  }

  Future<String> _exportConfigurationArchive() async {
    final file = await _settingsRepo.exportConfigurationArchive();
    return '${_language.t('settings.export.done')} ${file.path}';
  }

  Future<String> _exportLanguageSample() => AppLanguage.exportEnglishSample();

  Future<String> _revealCommonEncryptionPassword(String guardPassword) {
    return _settingsRepo.revealCommonEncryptionPassword(
      settings: _settings,
      guardPassword: guardPassword,
    );
  }

  double _effectiveTextScale(BuildContext context) {
    final dpi = _settings.autoScaleForDpi
        ? (MediaQuery.of(context).devicePixelRatio / 2.5).clamp(0.9, 1.35)
        : 1.0;
    return (_settings.fileTextScale * dpi).clamp(0.75, 2.2);
  }

  double _effectiveIconScale(BuildContext context) {
    final dpi = _settings.autoScaleForDpi
        ? (MediaQuery.of(context).devicePixelRatio / 2.5).clamp(0.9, 1.35)
        : 1.0;
    return (_settings.fileIconScale * dpi).clamp(0.75, 2.5);
  }

  Future<void> _showAbout() async {
    final runtimeText = _runtime.isLoaded
        ? 'Core ${_runtime.versionText}'
        : _language.t('app.runtime.offline');
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_language.t('about.title')),
        content: SelectableText(
          '${_language.appTitle}\n'
          '${_language.t('about.version')}: $_appVersion\n'
          '$runtimeText\n\n'
          '${_language.t('about.description')}',
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

    return _scaledInterface(Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, c) {
            final sidebar = _Sidebar(
              language: _language,
              locations: _locations,
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
              onLocation: _selectLocation,
              onFavoritePath: _openFavoritePath,
              onRecentPath: (path) async {
                final entry = await _explorer.entryForPath(path);
                if (entry == null) {
                  await _offerRemoveMissingRecent(path);
                } else {
                  await _openEntry(entry);
                }
              },
              onRecentList: _openRecentFiles,
              onExplorer: _openExplorerHome,
              onMediaSection: _openMediaSection,
              onSettings: () => setState(() => _page = ShellPage.settings),
              onAbout: _showAbout,
            );
            final body = _page == ShellPage.settings
                ? _SettingsView(
                    language: _language,
                    settings: _settings,
                    onSave: _saveSecurity,
                    onRequestAndroidStorageAccess:
                        _requestAndroidStorageAccessFromSettings,
                    onClear: _clearRemembered,
                    onRevealCommonKey: _revealCommonEncryptionPassword,
                    onValidateLanguageFile: _validateLanguageFile,
                    onInstallLanguageFile: _installLanguageFile,
                    onInstallPluginZip: _installPluginZip,
                    onExportConfigurationArchive: _exportConfigurationArchive,
                    onExportLanguageSample: _exportLanguageSample,
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
                    : (_page == ShellPage.music || _page == ShellPage.video)
                        ? _MediaOnlyView(
                            language: _language,
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
                            onRememberMediaPosition: _rememberMediaPosition,
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
                            onUp: _goUp,
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
                            onPreviewResize: (delta) => setState(
                              () => _previewWidth =
                                  (_previewWidth - delta).clamp(280.0, 1800.0),
                            ),
                            onTogglePreview: () => setState(
                                () => _previewVisible = !_previewVisible),
                            onOpenPassword: _openWithPassword,
                            onOpenExternal: _openPreviewExternal,
                            onPreviewWindow: _showPreviewWindow,
                            onEditPreview: _openEditor,
                            onImageNavigate: _navigateImage,
                            onRememberMediaPosition: _rememberMediaPosition,
                            canPaste: _clipboardPath != null,
                            favoritePaths: _settings.favoritePaths,
                            recentPaths: _settings.recentFilePaths,
                            searchQuery: _searchQuery,
                            searchUseRegex: _searchUseRegex,
                            localSearchEnabled:
                                _searchMode == 'name' && !_searchRecursive,
                            onPathEdit: _editPathDialog,
                            onSearch: _searchDialog,
                            onSearchFilters: _searchFiltersDialog,
                            onEntryAction: _handleEntryAction,
                            onEmptyAreaAction: _handleEmptyAreaAction,
                            onRemoveRecent: _removeRecentPath,
                            onToggleFavorite: _toggleFavorite,
                            onEntry: _openEntry,
                            onEntryFullscreen: (entry) =>
                                _openEntry(entry, forceFullScreen: true),
                          );
            if (c.maxWidth < 820) {
              return Scaffold(
                appBar: AppBar(title: Text(_language.appTitle)),
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
      ),
    ));
  }

  Widget _scaledInterface(Widget child) {
    final scale = _settings.interfaceTextScale.clamp(0.75, 2.2).toDouble();
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
                  TextField(
                    controller: sourceController,
                    decoration: InputDecoration(
                      labelText: _language.t('transfer.source.path'),
                    ),
                  ),
                TextField(
                  controller: targetController,
                  decoration: InputDecoration(
                    labelText: _language.t('common.target.folder'),
                  ),
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
                TextField(
                  controller: targetController,
                  decoration: InputDecoration(
                    labelText: _language.t('common.target.folder'),
                  ),
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
              TextField(
                controller: targetController,
                decoration: InputDecoration(
                  labelText: _language.t('common.target.folder'),
                ),
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
  encrypt,
  decrypt,
  folderContainer,
  folderEncrypt,
  folderDecrypt,
  useAsGallery,
  useAsVideo,
  useAsMusic,
  useAsMultimedia,
}

enum _PreviewAction { password, window, edit, external, hide }

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
    required this.favoritePaths,
    required this.recentPaths,
    required this.currentPath,
    required this.page,
    required this.onLocation,
    required this.onFavoritePath,
    required this.onRecentPath,
    required this.onRecentList,
    required this.onExplorer,
    required this.onMediaSection,
    required this.onSettings,
    required this.onAbout,
  });

  final AppLanguage language;
  final List<ExplorerLocation> locations;
  final List<String> favoritePaths;
  final List<String> recentPaths;
  final String? currentPath;
  final ShellPage page;
  final ValueChanged<ExplorerLocation> onLocation;
  final ValueChanged<String> onFavoritePath;
  final ValueChanged<String> onRecentPath;
  final VoidCallback onRecentList;
  final VoidCallback onExplorer;
  final ValueChanged<MediaSection> onMediaSection;
  final VoidCallback onSettings;
  final VoidCallback onAbout;

  @override
  Widget build(BuildContext context) {
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
          onExplorer,
        ),
        _nav(
          Icons.photo_library_outlined,
          language.t('nav.gallery'),
          page == ShellPage.gallery,
          () => onMediaSection(MediaSection.gallery),
        ),
        _nav(
          Icons.music_note_outlined,
          language.t('nav.music'),
          page == ShellPage.music,
          () => onMediaSection(MediaSection.music),
        ),
        _nav(
          Icons.movie_outlined,
          language.t('nav.video'),
          page == ShellPage.video,
          () => onMediaSection(MediaSection.video),
        ),
        _nav(
          Icons.description_outlined,
          language.t('nav.documents'),
          page == ShellPage.documents,
          () => onMediaSection(MediaSection.documents),
        ),
        _nav(
          Icons.hub_outlined,
          language.t('nav.torrent'),
          page == ShellPage.torrent,
          () => onMediaSection(MediaSection.torrent),
        ),
        _nav(
          Icons.tune,
          language.t('nav.settings'),
          page == ShellPage.settings,
          onSettings,
        ),
        const SizedBox(height: 12),
        if (recentPaths.isNotEmpty) ...[
          _sectionTitle(language.t('recent.title')),
          ListTile(
            dense: true,
            leading: const Icon(Icons.history),
            title: Text(language.t('recent.open.all')),
            onTap: onRecentList,
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
              onTap: () => onRecentPath(path),
            ),
          const SizedBox(height: 12),
        ],
        if (favoritePaths.isNotEmpty) ...[
          _sectionTitle(language.t('favorites.title')),
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
              onTap: () => onFavoritePath(path),
            ),
          const SizedBox(height: 12),
        ],
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            language.t('locations.heading'),
            style:
                const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1),
          ),
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
            onTap: () => onLocation(location),
          ),
      ]),
    );
  }

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
    required this.onRememberMediaPosition,
  });

  final AppLanguage language;
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
  final Future<void> Function(String key, Duration position)
      onRememberMediaPosition;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      _MediaHeader(
        title: language.t(isVideo ? 'nav.video' : 'nav.music'),
        language: language,
        onRefresh: onRefresh,
        onSearch: onSearch,
        onSearchFilters: onSearchFilters,
        searchQuery: '',
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
              return const Center(child: CircularProgressIndicator());
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
                onImageNavigate: (_) async => null,
              ),
            );
          },
        ),
      ),
    ]);
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
    required this.onRefresh,
    required this.onImport,
    required this.onExport,
    required this.previewWidth,
    required this.previewVisible,
    required this.fileTextScale,
    required this.fileIconScale,
    required this.toolbarIconScale,
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
    required this.searchQuery,
    required this.searchUseRegex,
    required this.localSearchEnabled,
    required this.onPathEdit,
    required this.onSearch,
    required this.onSearchFilters,
    required this.onEntryAction,
    required this.onEmptyAreaAction,
    required this.onRemoveRecent,
    required this.onToggleFavorite,
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
  final Future<void> Function() onRefresh;
  final VoidCallback onImport;
  final VoidCallback onExport;
  final double previewWidth;
  final bool previewVisible;
  final double fileTextScale;
  final double fileIconScale;
  final double toolbarIconScale;
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
  final String searchQuery;
  final bool searchUseRegex;
  final bool localSearchEnabled;
  final VoidCallback onPathEdit;
  final VoidCallback onSearch;
  final VoidCallback onSearchFilters;
  final Future<void> Function(ExplorerEntry, _EntryAction) onEntryAction;
  final Future<void> Function(String, _EntryAction) onEmptyAreaAction;
  final ValueChanged<String> onRemoveRecent;
  final ValueChanged<ExplorerEntry> onToggleFavorite;
  final Future<void> Function(ExplorerEntry) onEntry;
  final Future<void> Function(ExplorerEntry) onEntryFullscreen;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Container(
        padding: const EdgeInsets.all(12),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: Color(0xFFDDE6F0))),
        ),
        child: Wrap(
          runSpacing: 8,
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            IconButton(
              onPressed: onUp,
              icon: Icon(Icons.arrow_upward, size: 24 * toolbarIconScale),
              tooltip: language.t('explorer.up'),
            ),
            IconButton(
              onPressed: onRefresh,
              icon: Icon(Icons.refresh, size: 24 * toolbarIconScale),
              tooltip: language.t('explorer.refresh'),
            ),
            SizedBox(
              width: 420,
              child: GestureDetector(
                onDoubleTap: onPathEdit,
                child: Text(
                  currentPath ?? language.t('explorer.choose.location'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            IconButton.filled(
              onPressed: onImport,
              icon:
                  Icon(Icons.file_upload_outlined, size: 24 * toolbarIconScale),
              tooltip: language.t('explorer.upload'),
            ),
            IconButton.outlined(
              onPressed: onExport,
              icon: Icon(Icons.file_download_outlined,
                  size: 24 * toolbarIconScale),
              tooltip: language.t('explorer.download'),
            ),
            IconButton(
              onPressed: onSearch,
              icon: Icon(
                searchQuery.isEmpty ? Icons.search : Icons.search_off,
                size: 24 * toolbarIconScale,
              ),
              tooltip: language.t('search.title'),
            ),
            IconButton(
              onPressed: onSearchFilters,
              icon: Icon(Icons.tune_outlined, size: 24 * toolbarIconScale),
              tooltip: language.t('search.filters'),
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
          ],
        ),
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
            searchQuery: searchQuery,
            searchUseRegex: searchUseRegex,
            localSearchEnabled: localSearchEnabled,
            onEntryAction: onEntryAction,
            currentPath: currentPath,
            onEmptyAreaAction: onEmptyAreaAction,
            onRemoveRecent: onRemoveRecent,
            onToggleFavorite: onToggleFavorite,
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
    required this.searchQuery,
    required this.searchUseRegex,
    required this.localSearchEnabled,
    required this.currentPath,
    required this.onEntryAction,
    required this.onEmptyAreaAction,
    required this.onRemoveRecent,
    required this.onToggleFavorite,
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
  final String searchQuery;
  final bool searchUseRegex;
  final bool localSearchEnabled;
  final String? currentPath;
  final Future<void> Function(ExplorerEntry, _EntryAction) onEntryAction;
  final Future<void> Function(String, _EntryAction) onEmptyAreaAction;
  final ValueChanged<String> onRemoveRecent;
  final ValueChanged<ExplorerEntry> onToggleFavorite;

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
        final entries = searchQuery.isEmpty || !localSearchEnabled
            ? data.entries
            : data.entries
                .where((entry) => _matchesSearch(entry.name))
                .toList();
        if (entries.isEmpty) {
          return _EmptyExplorerArea(
            language: language,
            currentPath: currentPath,
            canPaste: canPaste,
            onAction: onEmptyAreaAction,
            child: Center(child: Text(language.t('explorer.empty'))),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: entries.length + 1,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            if (i == entries.length) {
              return _EmptyExplorerArea(
                language: language,
                currentPath: currentPath,
                canPaste: canPaste,
                onAction: onEmptyAreaAction,
                child: const SizedBox(height: 240),
              );
            }
            final entry = entries[i];
            return GestureDetector(
              onSecondaryTapDown: (details) =>
                  _showEntryContextMenu(context, entry, details.globalPosition),
              onLongPress: () => _showEntryContextMenu(context, entry, null),
              onDoubleTap: entry.isDirectory
                  ? null
                  : () => unawaited(onEntryFullscreen(entry)),
              child: ListTile(
                selected: selected?.path == entry.path,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                leading: Icon(
                  _icon(entry),
                  color: _color(entry),
                  size: 24 * fileIconScale,
                ),
                title: Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14 * fileTextScale),
                ),
                subtitle: Text(entry.exists
                    ? '${_size(entry)} - ${_date(entry.modifiedAt)}'
                    : language.t('recent.missing.file')),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (entry.containerInfo?.isOk == true)
                    const Icon(Icons.verified_outlined,
                        color: Color(0xFF2B7A4B)),
                  PopupMenuButton<_EntryAction>(
                    icon: const Icon(Icons.more_vert),
                    onSelected: (action) => _handleEntryAction(entry, action),
                    itemBuilder: (_) => _entryMenuItems(entry),
                  ),
                ]),
                onTap: () => onEntry(entry),
              ),
            );
          },
        );
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
        enabled: entry.exists && entry.isDirectory,
        child: Text(
            '${language.t('explorer.create')} > ${language.t('create.folder')}'),
      ),
      PopupMenuItem(
        value: _EntryAction.createPlain,
        enabled: entry.exists && entry.isDirectory,
        child: Text(
            '${language.t('explorer.create')} > ${language.t('create.plain')}'),
      ),
      PopupMenuItem(
        value: _EntryAction.createEncryptedPlain,
        enabled: entry.exists && entry.isDirectory,
        child: Text(
            '${language.t('explorer.create')} > ${language.t('create.encrypted.plain')}'),
      ),
      PopupMenuItem(
        value: _EntryAction.createCsv,
        enabled: entry.exists && entry.isDirectory,
        child: Text(
            '${language.t('explorer.create')} > ${language.t('create.csv')}'),
      ),
      PopupMenuItem(
        value: _EntryAction.createEncryptedCsv,
        enabled: entry.exists && entry.isDirectory,
        child: Text(
            '${language.t('explorer.create')} > ${language.t('create.encrypted.csv')}'),
      ),
      PopupMenuItem(
        value: _EntryAction.createImage,
        enabled: entry.exists && entry.isDirectory,
        child: Text(
            '${language.t('explorer.create')} > ${language.t('create.image')}'),
      ),
      PopupMenuItem(
        value: _EntryAction.createEncryptedImage,
        enabled: entry.exists && entry.isDirectory,
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
        enabled: entry.exists,
        child: Text(language.t('explorer.copy')),
      ),
      PopupMenuItem(
        value: _EntryAction.cut,
        enabled: entry.exists,
        child: Text(language.t('explorer.cut')),
      ),
      PopupMenuItem(
        value: _EntryAction.paste,
        enabled: canPaste && entry.isDirectory && entry.exists,
        child: Text(language.t('explorer.paste')),
      ),
      PopupMenuItem(
        value: _EntryAction.rename,
        enabled: entry.exists,
        child: Text(language.t('explorer.rename')),
      ),
      PopupMenuItem(
        value: _EntryAction.delete,
        enabled: entry.exists,
        child: Text(language.t('explorer.delete')),
      ),
      PopupMenuItem(
        value: _EntryAction.properties,
        child: Text(language.t('explorer.properties')),
      ),
      PopupMenuItem(
        value: _EntryAction.send,
        enabled: entry.exists,
        child: Text(language.t('explorer.send')),
      ),
      if (!entry.isDirectory) const PopupMenuDivider(),
      if (!entry.isDirectory &&
          FileViewerService.extensionForName(entry.path) == '.zip')
        PopupMenuItem(
          value: _EntryAction.unzip,
          enabled: entry.exists,
          child: Text(language.t('explorer.unzip')),
        ),
      if (!entry.isDirectory && !entry.isEncrypted)
        PopupMenuItem(
          value: _EntryAction.encrypt,
          enabled: entry.exists,
          child: Text(language.t('explorer.encrypt')),
        ),
      if (!entry.isDirectory && entry.isEncrypted)
        PopupMenuItem(
          value: _EntryAction.decrypt,
          enabled: entry.exists,
          child: Text(language.t('decrypt.action')),
        ),
      if (entry.isDirectory) const PopupMenuDivider(),
      if (entry.isDirectory)
        PopupMenuItem(
          value: _EntryAction.folderContainer,
          enabled: entry.exists,
          child: Text(language.t('explorer.folder.container')),
        ),
      if (entry.isDirectory)
        PopupMenuItem(
          value: _EntryAction.folderEncrypt,
          enabled: entry.exists,
          child: Text(language.t('explorer.folder.encrypt')),
        ),
      if (entry.isDirectory)
        PopupMenuItem(
          value: _EntryAction.folderDecrypt,
          enabled: entry.exists,
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
      case _EntryAction.folderEncrypt:
      case _EntryAction.folderDecrypt:
      case _EntryAction.useAsGallery:
      case _EntryAction.useAsVideo:
      case _EntryAction.useAsMusic:
      case _EntryAction.useAsMultimedia:
        onEntryAction(entry, action);
      case _EntryAction.addFavorite:
      case _EntryAction.removeFavorite:
        onToggleFavorite(entry);
      case _EntryAction.removeRecent:
        onRemoveRecent(entry.path);
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
        ExplorerEntryKind.directory => const Color(0xFFD29522),
        ExplorerEntryKind.encryptedFile => const Color(0xFF0F4C81),
        ExplorerEntryKind.folderMeta => const Color(0xFF42617D),
        _ => null,
      };

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
    required this.onImageNavigate,
    required this.onRememberMediaPosition,
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
  final Future<FilePreview?> Function(int delta) onImageNavigate;
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
                mediaResumePositions: mediaResumePositions,
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
                    case _PreviewAction.external:
                      onOpenExternal(p);
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
                  if (p.contentKind == FileContentKind.image ||
                      p.contentKind == FileContentKind.audio ||
                      p.contentKind == FileContentKind.video)
                    PopupMenuItem(
                      value: _PreviewAction.edit,
                      child: Text(language.t('editor.open')),
                    ),
                  PopupMenuItem(
                    value: _PreviewAction.external,
                    child: Text(language.t('preview.external')),
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
      );
    }

    if (preview.text != null && preview.text!.isNotEmpty) {
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
    final image = Center(
      child: InteractiveViewer(
        minScale: 0.25,
        maxScale: 6,
        child: Image.memory(Uint8List.fromList(widget.preview.bytes!)),
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
  });

  final FilePreview preview;
  final List<MediaPreviewItem> playlist;
  final AppLanguage language;
  final Map<String, int> resumePositions;
  final Future<void> Function(String key, Duration position)?
      onRememberPosition;

  @override
  State<_MediaPreviewPlayer> createState() => _MediaPreviewPlayerState();
}

class _MediaPreviewPlayerState extends State<_MediaPreviewPlayer> {
  late final Player _player;
  late final VideoController _controller;
  Future<void>? _openFuture;
  StreamSubscription<String>? _errorSubscription;
  Directory? _tempMediaDirectory;
  var _shuffle = false;
  var _repeatOne = false;
  String? _error;
  String _playlistKey = '';

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _errorSubscription = _player.stream.error.listen((error) {
      if (mounted) setState(() => _error = error);
    });
    _playlistKey = _makePlaylistKey(widget.playlist);
    _openFuture = _openPlaylist();
  }

  @override
  void didUpdateWidget(covariant _MediaPreviewPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextKey = _makePlaylistKey(widget.playlist);
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
    _player.dispose();
    unawaited(_clearTempMedia());
    super.dispose();
  }

  String _makePlaylistKey(List<MediaPreviewItem> items) => items
      .map((item) =>
          '${item.title}|${item.path ?? ''}|${item.bytes?.length ?? 0}|${item.encrypted}')
      .join('\n');

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
      await _clearTempMedia();
      final medias = <Media>[];
      for (var i = 0; i < widget.playlist.length; i++) {
        final item = widget.playlist[i];
        if (item.bytes != null) {
          final path = await _writeTempMedia(item, i);
          medias.add(Media(Uri.file(path).toString()));
        } else if (item.path != null && item.path!.isNotEmpty) {
          medias.add(Media(Uri.file(item.path!).toString()));
        }
      }
      if (medias.isEmpty) {
        throw StateError(widget.language.t('media.unavailable'));
      }
      await _player.open(Playlist(medias, index: _initialIndex()), play: true);
      final initialItem = _itemAt(_initialIndex());
      final resumeMs = initialItem == null
          ? 0
          : widget.resumePositions[initialItem.resumeKey ?? ''] ?? 0;
      if (resumeMs > 1500) {
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

  Future<String> _writeTempMedia(MediaPreviewItem item, int index) async {
    final directory =
        _tempMediaDirectory ??= await Directory.systemTemp.createTemp(
      'secure_vault_media_',
    );
    final extension = FileViewerService.extensionForName(item.title);
    final fallbackExtension =
        item.kind == FileContentKind.video ? '.mp4' : '.mp3';
    final safeName = _safeFileName(item.title).trim().isEmpty
        ? 'media_$index${extension.isEmpty ? fallbackExtension : extension}'
        : _safeFileName(item.title);
    final file = File(
      '${directory.path}${Platform.pathSeparator}${index.toString().padLeft(3, '0')}_$safeName',
    );
    await file.writeAsBytes(item.bytes!, flush: true);
    return file.path;
  }

  Future<void> _clearTempMedia() async {
    final directory = _tempMediaDirectory;
    _tempMediaDirectory = null;
    if (directory == null) return;
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } catch (_) {
      // Temporary preview files are best-effort cleanup.
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
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Video(
                    controller: _controller,
                    fit: BoxFit.contain,
                  ),
                ),
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
          StreamBuilder<Playlist>(
            stream: player.stream.playlist,
            initialData: player.state.playlist,
            builder: (context, snapshot) {
              final current = snapshot.data?.index ?? 0;
              return ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final selected = index == current;
                    return ListTile(
                      dense: true,
                      selected: selected,
                      leading: Icon(
                        item.kind == FileContentKind.video
                            ? Icons.movie_outlined
                            : Icons.audiotrack_outlined,
                      ),
                      title: Text(item.title, maxLines: 1),
                      subtitle: item.encrypted
                          ? Text(language.t('media.encrypted.item'))
                          : null,
                      onTap: () => unawaited(() async {
                        await onBeforeTrackChange();
                        await player.jump(index);
                      }()),
                    );
                  },
                ),
              );
            },
          ),
        ]),
      ),
    );
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

String _safeFileName(String value) =>
    value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

class _SettingsView extends StatefulWidget {
  const _SettingsView({
    required this.language,
    required this.settings,
    required this.onSave,
    required this.onRequestAndroidStorageAccess,
    required this.onClear,
    required this.onRevealCommonKey,
    required this.onValidateLanguageFile,
    required this.onInstallLanguageFile,
    required this.onInstallPluginZip,
    required this.onExportConfigurationArchive,
    required this.onExportLanguageSample,
  });

  final AppLanguage language;
  final SecuritySettings settings;
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
  }) onSave;
  final Future<void> Function() onRequestAndroidStorageAccess;
  final Future<void> Function() onClear;
  final Future<String> Function(String guardPassword) onRevealCommonKey;
  final Future<String> Function(String path) onValidateLanguageFile;
  final Future<String> Function(String path) onInstallLanguageFile;
  final Future<String> Function(String path) onInstallPluginZip;
  final Future<String> Function() onExportConfigurationArchive;
  final Future<String> Function() onExportLanguageSample;

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
  late String _languageCode;
  late String _commonAlgorithm;
  late String _navigationPolicy;
  late String _searchMode;
  var _busy = false;

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
    super.dispose();
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
        TextField(
          controller: _commonKeyFile,
          decoration: InputDecoration(
            labelText: language.t('settings.common.keyfile'),
            helperText: language.t('settings.common.keyfile.note'),
          ),
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
          value: _autoScaleForDpi,
          onChanged: (v) => setState(() => _autoScaleForDpi = v),
          title: Text(language.t('settings.auto.dpi')),
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
        _folderField(language.t('nav.gallery'), _galleryFolders),
        _folderField(language.t('settings.exclusions'), _galleryExclusions),
        _folderField(language.t('nav.music'), _musicFolders),
        _folderField(language.t('settings.exclusions'), _musicExclusions),
        _folderField(language.t('nav.video'), _videoFolders),
        _folderField(language.t('settings.exclusions'), _videoExclusions),
        _folderField(language.t('nav.documents'), _documentFolders),
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
        TextField(
          controller: _languagePath,
          decoration: InputDecoration(
            labelText: language.t('settings.language.path'),
          ),
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
        TextField(
          controller: _pluginZipPath,
          decoration: InputDecoration(
            labelText: language.t('settings.plugin.zip.path'),
          ),
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
        onPressed: _busy ? null : _save,
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

  Widget _folderField(String label, TextEditingController controller) =>
      TextField(
        controller: controller,
        minLines: 1,
        maxLines: 4,
        decoration: InputDecoration(
          labelText: label,
          helperText: widget.language.t('settings.paths.one.per.line'),
        ),
      );

  Future<void> _save() async {
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
      );
    } catch (error) {
      _snack('${widget.language.t('settings.language.invalid')} $error');
    } finally {
      if (mounted) setState(() => _busy = false);
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

  Future<void> _exportConfiguration() async {
    try {
      final message = await widget.onExportConfigurationArchive();
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
