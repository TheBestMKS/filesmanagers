import 'dart:io';

import 'package:flutter/services.dart';

class PlatformServices {
  PlatformServices._();

  static const MethodChannel _channel = MethodChannel('secure_vault/platform');

  static Future<void> setScreenProtection(bool enabled) async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('setScreenProtection', enabled);
    }
  }

  static Future<String?> getInitialOpenPath() async {
    if (Platform.isAndroid) {
      return _channel.invokeMethod<String>('getInitialOpenPath');
    }
    return null;
  }

  static Future<void> openExternal(String path) async {
    if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', '', path], runInShell: false);
      return;
    }
    if (Platform.isLinux) {
      await Process.run('xdg-open', [path], runInShell: false);
      return;
    }
    if (Platform.isMacOS) {
      await Process.run('open', [path], runInShell: false);
      return;
    }
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('openExternal', path);
      return;
    }
    throw UnsupportedError(
        'External opening is not supported on this platform.');
  }

  static Future<void> openWithCommand(String command, String path) async {
    final executable = command.trim();
    if (executable.isEmpty) {
      await openExternal(path);
      return;
    }
    final parts = _splitCommand(executable);
    await Process.start(
      parts.first,
      [...parts.skip(1), path],
      mode: ProcessStartMode.detached,
      runInShell: Platform.isWindows,
    );
  }

  static List<String> _splitCommand(String command) {
    final matches = RegExp(r'"([^"]+)"|(\S+)').allMatches(command);
    final parts = [
      for (final match in matches) match.group(1) ?? match.group(2)!,
    ];
    return parts.isEmpty ? [command] : parts;
  }
}
