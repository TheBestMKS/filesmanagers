import 'dart:convert';
import 'dart:io';

class AppPaths {
  const AppPaths._();

  static const _storageFileName = 'securevault_storage.json';
  static const _programDataFolder = 'SecureVaultData';
  static const _pluginsFolder = 'plugins';

  static Future<Directory> appDataDirectory() async {
    if (await useUserDataDirectory()) {
      return userDataDirectory();
    }
    return programDataDirectory();
  }

  static Future<Directory> programDataDirectory() async {
    final override = Platform.environment['SECUREVAULT_DATA_DIR'];
    if (override != null && override.trim().isNotEmpty) {
      return _ensureDirectory(Directory(override.trim()));
    }
    if (Platform.isAndroid) {
      return _ensureDirectory(
        Directory('/data/user/0/com.securevault.app/files'),
      );
    }
    final dir = Directory(
      '${_programDirectory()}${Platform.pathSeparator}$_programDataFolder',
    );
    try {
      return await _ensureDirectory(dir);
    } on FileSystemException {
      return userDataDirectory();
    }
  }

  static Future<Directory> userDataDirectory() async {
    final basePath = switch (Platform.operatingSystem) {
      'android' => '/data/user/0/com.securevault.app/files',
      'windows' =>
        _firstEnvironmentPath(['APPDATA', 'LOCALAPPDATA', 'USERPROFILE']),
      'linux' => _linuxDataPath(),
      _ => Directory.systemTemp.path,
    };
    return _ensureDirectory(
      Directory('$basePath${Platform.pathSeparator}SecureVault'),
    );
  }

  static Future<bool> useUserDataDirectory() async {
    final file = File(
      '${_programDirectory()}${Platform.pathSeparator}$_programDataFolder'
      '${Platform.pathSeparator}$_storageFileName',
    );
    if (!await file.exists()) {
      return false;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, Object?>) {
        return decoded['storage'] == 'user';
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  static Future<void> setUseUserDataDirectory(bool value) async {
    final dir = Directory(
      '${_programDirectory()}${Platform.pathSeparator}$_programDataFolder',
    );
    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}$_storageFileName');
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'schema': 'securevault.storage.v1',
        'storage': value ? 'user' : 'program',
      }),
      flush: true,
    );
  }

  static Future<Directory> exportDirectory() async {
    final appData = await appDataDirectory();
    return _ensureDirectory(
      Directory('${appData.path}${Platform.pathSeparator}exports'),
    );
  }

  static Future<Directory> hiddenVaultDirectory() async {
    final appData = await appDataDirectory();
    final dir =
        Directory('${appData.path}${Platform.pathSeparator}hidden_vault');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<Directory> pluginsDirectory() async {
    final override = Platform.environment['SECUREVAULT_PLUGINS_DIR'];
    if (override != null && override.trim().isNotEmpty) {
      return _ensureDirectory(Directory(override.trim()));
    }
    final dir = Directory(
      '${_programDirectory()}${Platform.pathSeparator}$_pluginsFolder',
    );
    try {
      final ensured = await _ensureDirectory(dir);
      await _migrateLegacyPlugins(ensured);
      return ensured;
    } on FileSystemException {
      // Some desktop installs can be read-only. Keep the fallback outside of
      // SecureVaultData so plugins are still separated from encrypted data.
      final userData = await userDataDirectory();
      return _ensureDirectory(
        Directory('${userData.path}${Platform.pathSeparator}$_pluginsFolder'),
      );
    }
  }

  static Future<Directory> languagesDirectory() async {
    final appData = await appDataDirectory();
    final dir = Directory('${appData.path}${Platform.pathSeparator}languages');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<Directory> torrentsDirectory() async {
    final appData = await appDataDirectory();
    final dir = Directory('${appData.path}${Platform.pathSeparator}torrents');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static String _firstEnvironmentPath(List<String> keys) {
    for (final key in keys) {
      final value = Platform.environment[key];
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    return Directory.systemTemp.path;
  }

  static String _linuxDataPath() {
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

  static Future<Directory> _ensureDirectory(Directory dir) async {
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<void> _migrateLegacyPlugins(Directory target) async {
    final targetPath = _normalize(target.path);
    final legacyRoots = <Directory>[
      Directory(
        '${_programDirectory()}${Platform.pathSeparator}$_programDataFolder'
        '${Platform.pathSeparator}$_pluginsFolder',
      ),
    ];
    try {
      final userData = await userDataDirectory();
      legacyRoots.add(
        Directory('${userData.path}${Platform.pathSeparator}$_pluginsFolder'),
      );
    } catch (_) {}
    for (final legacy in legacyRoots) {
      if (_normalize(legacy.path) == targetPath || !await legacy.exists()) {
        continue;
      }
      await for (final entity in legacy.list(followLinks: false)) {
        final name = entity.path.split(Platform.pathSeparator).last;
        if (name.isEmpty) continue;
        final destination = '${target.path}${Platform.pathSeparator}$name';
        if (entity is Directory) {
          final targetDir = Directory(destination);
          if (!await targetDir.exists()) {
            await _copyDirectory(entity, targetDir);
          }
        } else if (entity is File) {
          final targetFile = File(destination);
          if (!await targetFile.exists()) {
            await entity.copy(targetFile.path);
          }
        }
      }
    }
  }

  static Future<void> _copyDirectory(Directory source, Directory target) async {
    await target.create(recursive: true);
    await for (final entity in source.list(followLinks: false)) {
      final name = entity.path.split(Platform.pathSeparator).last;
      final destination = '${target.path}${Platform.pathSeparator}$name';
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(destination));
      } else if (entity is File) {
        await File(destination).parent.create(recursive: true);
        await entity.copy(destination);
      }
    }
  }

  static String _normalize(String path) =>
      Platform.isWindows ? path.toLowerCase() : path;

  static String _programDirectory() {
    if (Platform.isAndroid) {
      return '/data/user/0/com.securevault.app/files';
    }
    final current = Directory.current.path;
    if (File('$current${Platform.pathSeparator}pubspec.yaml').existsSync()) {
      return current;
    }
    final executable = File(Platform.resolvedExecutable);
    final parent = executable.parent;
    return parent.path.isEmpty ? current : parent.path;
  }
}
