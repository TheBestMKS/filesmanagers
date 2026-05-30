import 'dart:io';

class AppPaths {
  const AppPaths._();

  static Future<Directory> appDataDirectory() async {
    final basePath = switch (Platform.operatingSystem) {
      'android' => '/data/user/0/com.securevault.app/files',
      'windows' =>
        _firstEnvironmentPath(['APPDATA', 'LOCALAPPDATA', 'USERPROFILE']),
      'linux' => _linuxDataPath(),
      _ => Directory.systemTemp.path,
    };
    final dir = Directory('$basePath${Platform.pathSeparator}SecureVault');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
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
    final appData = await appDataDirectory();
    final dir = Directory('${appData.path}${Platform.pathSeparator}plugins');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
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
}
