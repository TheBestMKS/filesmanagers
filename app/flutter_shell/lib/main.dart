import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'src/explorer/explorer_models.dart';
import 'src/explorer/file_explorer_repository.dart';
import 'src/ffi/crypt_bindings.dart';
import 'src/i18n/app_language.dart';
import 'src/platform_services.dart';
import 'src/plugins/cloud_plugin_registry.dart' hide basename;
import 'src/security/security_settings.dart';
import 'src/viewer/file_viewer_service.dart';

const _appVersion = '0.3.0';

void main(List<String> args) => runApp(
      SecureVaultApp(initialPath: args.isEmpty ? null : args.first),
    );

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

enum ShellPage { explorer, settings }

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
  double _sidebarWidth = 290;
  double _previewWidth = 420;
  bool _previewVisible = true;
  String? _clipboardPath;
  bool _clipboardCut = false;
  bool _showingRecent = false;

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
      _commonEncryptionPassword = commonPassword;
      _runtime = runtime;
      _pluginDefs = pluginDefs;
      _locations = locations;
      _currentPath = currentPath;
      _selected = selected;
      _preview = preview;
      _snapshot =
          currentPath == null ? null : _explorer.listDirectory(currentPath);
      _locked = settings.hasAppPassword;
      _loading = false;
    });
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
    if (!_settings.hasFilePassword) {
      final common = await _settingsRepo
          .loadCommonEncryptionPassword(_settings)
          .catchError((_) => null);
      if (mounted) setState(() => _commonEncryptionPassword = common);
    }
  }

  void _openPath(String path) {
    setState(() {
      _page = ShellPage.explorer;
      _showingRecent = false;
      _currentPath = path;
      _selected = null;
      _preview = null;
      _snapshot = _explorer.listDirectory(path);
    });
  }

  Future<void> _refresh() async {
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
              : _explorer.listDirectory(path);
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
    _openPath(location.path!);
  }

  void _openRecentFiles() {
    setState(() {
      _page = ShellPage.explorer;
      _showingRecent = true;
      _selected = null;
      _preview = null;
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

  Future<void> _openEntry(ExplorerEntry entry) async {
    if (!entry.exists) {
      await _offerRemoveMissingRecent(entry.path);
      return;
    }
    if (entry.isDirectory) {
      _openPath(entry.path);
      return;
    }
    setState(() {
      _selected = entry;
      _preview = _explorer.previewFile(
        entry.path,
        password: _activeFilePassword(),
        commonPassword: _commonEncryptionPassword,
      );
    });
    if (_settings.rememberRecentFiles) {
      final next = await _settingsRepo.recordRecentFile(_settings, entry.path);
      if (mounted) {
        setState(() => _settings = next);
      }
    }
  }

  void _goUp() {
    if (_showingRecent) {
      setState(() {
        _showingRecent = false;
        _selected = null;
        _preview = null;
        _snapshot = _currentPath == null
            ? null
            : _explorer.listDirectory(_currentPath!);
      });
      return;
    }
    final path = _currentPath;
    if (path == null) return;
    final parent =
        Uri.file(path).resolve('..').toFilePath(windows: path.contains('\\'));
    if (parent != path) _openPath(parent);
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
      case _EntryAction.addFavorite:
      case _EntryAction.removeFavorite:
        await _toggleFavorite(entry);
      case _EntryAction.removeRecent:
        await _removeRecentPath(entry.path);
      case _EntryAction.folderContainer:
      case _EntryAction.folderEncrypt:
      case _EntryAction.folderDecrypt:
        _snack(_language.t('snack.folder.actions.next'));
    }
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
    showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: Text(preview.title),
            actions: [
              IconButton(
                onPressed: () => _openPreviewExternal(preview),
                icon: const Icon(Icons.open_in_new),
                tooltip: _language.t('preview.external'),
              ),
            ],
          ),
          body: _PreviewContent(preview: preview, language: _language),
        ),
      ),
    );
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
  }) async {
    if (languageCode == 'custom' &&
        (customLanguagePath == null || customLanguagePath.trim().isEmpty)) {
      throw const FormatException('Custom language path is empty.');
    }
    if (languageCode == 'custom') {
      await AppLanguage.fromFile(customLanguagePath!.trim());
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
    );
    await PlatformServices.setScreenProtection(next.blockScreenCapture);
    final language = await AppLanguage.load(next);
    setState(() {
      _settings = next;
      _language = language;
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

  Future<String> _exportLanguageSample() => AppLanguage.exportEnglishSample();

  Future<String> _revealCommonEncryptionPassword(String guardPassword) {
    return _settingsRepo.revealCommonEncryptionPassword(
      settings: _settings,
      guardPassword: guardPassword,
    );
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
      return _LockScreen(
        language: _language,
        onUnlock: _unlock,
        failed: _settings.failedLoginAttempts,
      );
    }

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, c) {
            final sidebar = _Sidebar(
              language: _language,
              locations: _locations,
              favoritePaths: _settings.favoritePaths,
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
              onExplorer: () => setState(() => _page = ShellPage.explorer),
              onSettings: () => setState(() => _page = ShellPage.settings),
              onAbout: _showAbout,
            );
            final body = _page == ShellPage.settings
                ? _SettingsView(
                    language: _language,
                    settings: _settings,
                    onSave: _saveSecurity,
                    onClear: _clearRemembered,
                    onRevealCommonKey: _revealCommonEncryptionPassword,
                    onValidateLanguageFile: _validateLanguageFile,
                    onExportLanguageSample: _exportLanguageSample,
                  )
                : _ExplorerView(
                    language: _language,
                    currentPath: _showingRecent
                        ? _language.t('recent.title')
                        : _currentPath,
                    snapshot: _snapshot,
                    selected: _selected,
                    preview: _preview,
                    onUp: _goUp,
                    onRefresh: _refresh,
                    onImport: _importFile,
                    onExport: _exportFile,
                    previewWidth: _previewWidth,
                    previewVisible: _previewVisible,
                    onPreviewResize: (delta) => setState(
                      () => _previewWidth =
                          (_previewWidth - delta).clamp(280.0, 760.0),
                    ),
                    onTogglePreview: () =>
                        setState(() => _previewVisible = !_previewVisible),
                    onOpenPassword: _openWithPassword,
                    onOpenExternal: _openPreviewExternal,
                    onPreviewWindow: _showPreviewWindow,
                    canPaste: _clipboardPath != null,
                    favoritePaths: _settings.favoritePaths,
                    recentPaths: _settings.recentFilePaths,
                    onEntryAction: _handleEntryAction,
                    onRemoveRecent: _removeRecentPath,
                    onToggleFavorite: _toggleFavorite,
                    onEntry: _openEntry,
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
  copy,
  cut,
  paste,
  delete,
  rename,
  properties,
  addFavorite,
  removeFavorite,
  removeRecent,
  encrypt,
  decrypt,
  folderContainer,
  folderEncrypt,
  folderDecrypt,
}

enum _PreviewAction { password, window, external, hide }

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

class _ExplorerView extends StatelessWidget {
  const _ExplorerView({
    required this.language,
    required this.currentPath,
    required this.snapshot,
    required this.selected,
    required this.preview,
    required this.onUp,
    required this.onRefresh,
    required this.onImport,
    required this.onExport,
    required this.previewWidth,
    required this.previewVisible,
    required this.onPreviewResize,
    required this.onTogglePreview,
    required this.onOpenPassword,
    required this.onOpenExternal,
    required this.onPreviewWindow,
    required this.canPaste,
    required this.favoritePaths,
    required this.recentPaths,
    required this.onEntryAction,
    required this.onRemoveRecent,
    required this.onToggleFavorite,
    required this.onEntry,
  });

  final AppLanguage language;
  final String? currentPath;
  final Future<DirectorySnapshot>? snapshot;
  final ExplorerEntry? selected;
  final Future<FilePreview>? preview;
  final VoidCallback onUp;
  final Future<void> Function() onRefresh;
  final VoidCallback onImport;
  final VoidCallback onExport;
  final double previewWidth;
  final bool previewVisible;
  final ValueChanged<double> onPreviewResize;
  final VoidCallback onTogglePreview;
  final VoidCallback onOpenPassword;
  final ValueChanged<FilePreview> onOpenExternal;
  final ValueChanged<FilePreview> onPreviewWindow;
  final bool canPaste;
  final List<String> favoritePaths;
  final List<String> recentPaths;
  final Future<void> Function(ExplorerEntry, _EntryAction) onEntryAction;
  final ValueChanged<String> onRemoveRecent;
  final ValueChanged<ExplorerEntry> onToggleFavorite;
  final Future<void> Function(ExplorerEntry) onEntry;

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
              icon: const Icon(Icons.arrow_upward),
              tooltip: language.t('explorer.up'),
            ),
            IconButton(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
              tooltip: language.t('explorer.refresh'),
            ),
            SizedBox(
              width: 420,
              child: Text(
                currentPath ?? language.t('explorer.choose.location'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            FilledButton.icon(
              onPressed: onImport,
              icon: const Icon(Icons.file_upload_outlined),
              label: Text(language.t('explorer.upload')),
            ),
            OutlinedButton.icon(
              onPressed: onExport,
              icon: const Icon(Icons.file_download_outlined),
              label: Text(language.t('explorer.download')),
            ),
            IconButton(
              onPressed: onTogglePreview,
              icon: Icon(
                previewVisible
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
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
            onEntry: onEntry,
            canPaste: canPaste,
            favoritePaths: favoritePaths,
            recentPaths: recentPaths,
            onEntryAction: onEntryAction,
            onRemoveRecent: onRemoveRecent,
            onToggleFavorite: onToggleFavorite,
          );
          final pane = _PreviewPane(
            language: language,
            entry: selected,
            preview: preview,
            visible: previewVisible,
            onTogglePreview: onTogglePreview,
            onOpenPassword: onOpenPassword,
            onOpenExternal: onOpenExternal,
            onPreviewWindow: onPreviewWindow,
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
    required this.onEntry,
    required this.canPaste,
    required this.favoritePaths,
    required this.recentPaths,
    required this.onEntryAction,
    required this.onRemoveRecent,
    required this.onToggleFavorite,
  });

  final AppLanguage language;
  final Future<DirectorySnapshot>? snapshot;
  final ExplorerEntry? selected;
  final Future<void> Function(ExplorerEntry) onEntry;
  final bool canPaste;
  final List<String> favoritePaths;
  final List<String> recentPaths;
  final Future<void> Function(ExplorerEntry, _EntryAction) onEntryAction;
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
        if (data.entries.isEmpty) {
          return Center(child: Text(language.t('explorer.empty')));
        }
        return ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: data.entries.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final entry = data.entries[i];
            return GestureDetector(
              onSecondaryTapDown: (details) =>
                  _showEntryContextMenu(context, entry, details.globalPosition),
              onLongPress: () => _showEntryContextMenu(context, entry, null),
              child: ListTile(
                selected: selected?.path == entry.path,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                leading: Icon(_icon(entry), color: _color(entry)),
                title: Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
    return <PopupMenuEntry<_EntryAction>>[
      PopupMenuItem(
        value: _EntryAction.open,
        child: Text(language.t('common.open')),
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
      if (!entry.isDirectory) const PopupMenuDivider(),
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
    ];
  }

  void _handleEntryAction(ExplorerEntry entry, _EntryAction action) {
    switch (action) {
      case _EntryAction.open:
        onEntry(entry);
      case _EntryAction.encrypt:
      case _EntryAction.decrypt:
      case _EntryAction.copy:
      case _EntryAction.cut:
      case _EntryAction.paste:
      case _EntryAction.delete:
      case _EntryAction.rename:
      case _EntryAction.properties:
      case _EntryAction.folderContainer:
      case _EntryAction.folderEncrypt:
      case _EntryAction.folderDecrypt:
        onEntryAction(entry, action);
      case _EntryAction.addFavorite:
      case _EntryAction.removeFavorite:
        onToggleFavorite(entry);
      case _EntryAction.removeRecent:
        onRemoveRecent(entry.path);
    }
  }

  IconData _icon(ExplorerEntry entry) => switch (entry.kind) {
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

class _PreviewPane extends StatelessWidget {
  const _PreviewPane({
    required this.language,
    required this.entry,
    required this.preview,
    required this.visible,
    required this.onTogglePreview,
    required this.onOpenPassword,
    required this.onOpenExternal,
    required this.onPreviewWindow,
  });

  final AppLanguage language;
  final ExplorerEntry? entry;
  final Future<FilePreview>? preview;
  final bool visible;
  final VoidCallback onTogglePreview;
  final VoidCallback onOpenPassword;
  final ValueChanged<FilePreview> onOpenExternal;
  final ValueChanged<FilePreview> onPreviewWindow;

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
              child: _PreviewContent(preview: p, language: language),
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
  const _PreviewContent({required this.preview, required this.language});

  final FilePreview preview;
  final AppLanguage language;

  @override
  Widget build(BuildContext context) {
    if (preview.contentKind == FileContentKind.image && preview.bytes != null) {
      return Center(
        child: InteractiveViewer(
          minScale: 0.25,
          maxScale: 6,
          child: Image.memory(Uint8List.fromList(preview.bytes!)),
        ),
      );
    }

    if (preview.contentKind == FileContentKind.video ||
        preview.contentKind == FileContentKind.audio) {
      return Card(
        elevation: 0,
        color: const Color(0xFFEAF2F8),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(children: [
            Icon(
              preview.contentKind == FileContentKind.video
                  ? Icons.movie_outlined
                  : Icons.audiotrack_outlined,
              size: 38,
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(preview.text ?? preview.subtitle)),
          ]),
        ),
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

class _SettingsView extends StatefulWidget {
  const _SettingsView({
    required this.language,
    required this.settings,
    required this.onSave,
    required this.onClear,
    required this.onRevealCommonKey,
    required this.onValidateLanguageFile,
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
  }) onSave;
  final Future<void> Function() onClear;
  final Future<String> Function(String guardPassword) onRevealCommonKey;
  final Future<String> Function(String path) onValidateLanguageFile;
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
  late final TextEditingController _languagePath;
  late final TextEditingController _associations;
  late bool _separate;
  late bool _remember;
  late bool _wipe;
  late bool _rememberRecent;
  late bool _blockScreenCapture;
  late String _languageCode;
  late String _commonAlgorithm;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    _separate = widget.settings.useSeparateFilePassword;
    _remember = widget.settings.rememberFilePasswords;
    _wipe = widget.settings.wipeSavedPasswordsOnFailedLogin;
    _rememberRecent = widget.settings.rememberRecentFiles;
    _blockScreenCapture = widget.settings.blockScreenCapture;
    _commonAlgorithm = widget.settings.commonEncryptionAlgorithm;
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
    _languageCode = widget.settings.languageCode;
    _languagePath = TextEditingController(
      text: widget.settings.customLanguagePath ?? '',
    );
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
    _languagePath.dispose();
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
      ]),
      const SizedBox(height: 12),
      _settingsCard(context, language.t('settings.screen'), [
        SwitchListTile(
          value: _blockScreenCapture,
          onChanged: (v) => setState(() => _blockScreenCapture = v),
          title: Text(language.t('settings.block.capture')),
        ),
        Text(language.t('settings.block.capture.note')),
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

  void _snack(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }
}
