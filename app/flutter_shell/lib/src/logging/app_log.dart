import 'dart:io';

import '../storage/app_paths.dart';

class AppLog {
  AppLog._();

  static bool enabled = true;

  static Future<File> file() async {
    final dir = await AppPaths.appDataDirectory();
    final logDir = Directory('${dir.path}${Platform.pathSeparator}logs');
    if (!await logDir.exists()) {
      await logDir.create(recursive: true);
    }
    final file = File('${logDir.path}${Platform.pathSeparator}securevault.log');
    if (!await file.exists()) {
      await file.writeAsString(
        '[${DateTime.now().toIso8601String()}] filesmanagers log created\n',
        flush: true,
      );
    }
    return file;
  }

  static Future<void> write(String message, [Object? error]) async {
    if (!enabled) return;
    try {
      final target = await file();
      final suffix = error == null ? '' : ' | $error';
      await target.writeAsString(
        '[${DateTime.now().toIso8601String()}] $message$suffix\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Logging must never break application flow.
    }
  }
}
