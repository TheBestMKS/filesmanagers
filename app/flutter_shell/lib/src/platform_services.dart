import 'dart:io';

import 'package:flutter/services.dart';

class AndroidStorageAccessStatus {
  const AndroidStorageAccessStatus({
    required this.isAndroid,
    required this.sdkInt,
    required this.hasAllFilesAccess,
    required this.hasMediaImages,
    required this.hasMediaVideo,
    required this.hasMediaAudio,
  });

  final bool isAndroid;
  final int sdkInt;
  final bool hasAllFilesAccess;
  final bool hasMediaImages;
  final bool hasMediaVideo;
  final bool hasMediaAudio;

  bool get hasUsefulMediaAccess =>
      hasAllFilesAccess || (hasMediaImages && hasMediaVideo && hasMediaAudio);

  bool get needsRequest => isAndroid && !hasUsefulMediaAccess;

  factory AndroidStorageAccessStatus.notAndroid() =>
      const AndroidStorageAccessStatus(
        isAndroid: false,
        sdkInt: 0,
        hasAllFilesAccess: true,
        hasMediaImages: true,
        hasMediaVideo: true,
        hasMediaAudio: true,
      );

  factory AndroidStorageAccessStatus.fromMap(Map<Object?, Object?> map) {
    return AndroidStorageAccessStatus(
      isAndroid: map['isAndroid'] as bool? ?? false,
      sdkInt: map['sdkInt'] as int? ?? 0,
      hasAllFilesAccess: map['hasAllFilesAccess'] as bool? ?? false,
      hasMediaImages: map['hasMediaImages'] as bool? ?? false,
      hasMediaVideo: map['hasMediaVideo'] as bool? ?? false,
      hasMediaAudio: map['hasMediaAudio'] as bool? ?? false,
    );
  }
}

class PlatformServices {
  PlatformServices._();

  static const MethodChannel _channel = MethodChannel('secure_vault/platform');
  static const MethodChannel _windowChannel =
      MethodChannel('secure_vault/window');

  static Future<void> setWindowTitle(String title) async {
    if (Platform.isWindows) {
      await _windowChannel.invokeMethod<void>('setTitle', title);
    }
  }

  static Future<void> setScreenProtection(bool enabled) async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('setScreenProtection', enabled);
    }
  }

  static Future<void> setPrivacyHints({
    required bool disableCamera,
    required bool disableMicrophone,
  }) async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('setPrivacyHints', {
        'disableCamera': disableCamera,
        'disableMicrophone': disableMicrophone,
      });
    }
  }

  static Future<String?> getInitialOpenPath() async {
    if (Platform.isAndroid) {
      return _channel.invokeMethod<String>('getInitialOpenPath');
    }
    return null;
  }

  static Future<AndroidStorageAccessStatus> androidStorageAccessStatus() async {
    if (!Platform.isAndroid) {
      return AndroidStorageAccessStatus.notAndroid();
    }
    final raw = await _channel.invokeMethod<Object?>('storageAccessStatus');
    if (raw is Map) {
      return AndroidStorageAccessStatus.fromMap(raw);
    }
    return AndroidStorageAccessStatus.notAndroid();
  }

  static Future<void> requestAndroidStorageAccess() async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('requestStorageAccess');
    }
  }

  static Future<Uint8List?> readMediaArtwork(String path) async {
    if (!Platform.isAndroid) return null;
    return _channel.invokeMethod<Uint8List>('readMediaArtwork', path);
  }

  static Future<Uint8List?> readVideoThumbnail(String path) async {
    if (!Platform.isAndroid) return null;
    return _channel.invokeMethod<Uint8List>('readVideoThumbnail', path);
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

  static Future<void> speakText(String text) async {
    final value = text.trim();
    if (value.isEmpty) return;
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('speakText', value);
      return;
    }
    if (Platform.isWindows) {
      const script = r'''
param([string]$Text)
Add-Type -AssemblyName System.Speech
$speaker = New-Object System.Speech.Synthesis.SpeechSynthesizer
$speaker.Speak($Text)
''';
      await Process.start(
        'powershell',
        ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script, value],
        mode: ProcessStartMode.detached,
        runInShell: false,
      );
      return;
    }
    if (Platform.isLinux) {
      try {
        await Process.start(
          'spd-say',
          [value],
          mode: ProcessStartMode.detached,
          runInShell: false,
        );
      } catch (_) {}
    }
  }

  static Future<String?> pickFile() async {
    if (Platform.isWindows) {
      return _runPowerShellPicker(r'''
Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Multiselect = $false
if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  Write-Output $dialog.FileName
}
''');
    }
    if (Platform.isLinux) {
      final result = await Process.run('zenity', ['--file-selection'])
          .catchError((_) => Process.run('kdialog', ['--getopenfilename']));
      if (result.exitCode == 0) return result.stdout.toString().trim();
    }
    return null;
  }

  static Future<String?> pickDirectory() async {
    if (Platform.isWindows) {
      return _runPowerShellPicker(r'''
Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
  Write-Output $dialog.SelectedPath
}
''');
    }
    if (Platform.isLinux) {
      final result =
          await Process.run('zenity', ['--file-selection', '--directory'])
              .catchError(
                  (_) => Process.run('kdialog', ['--getexistingdirectory']));
      if (result.exitCode == 0) return result.stdout.toString().trim();
    }
    return null;
  }

  static List<String> _splitCommand(String command) {
    final matches = RegExp(r'"([^"]+)"|(\S+)').allMatches(command);
    final parts = [
      for (final match in matches) match.group(1) ?? match.group(2)!,
    ];
    return parts.isEmpty ? [command] : parts;
  }

  static Future<String?> _runPowerShellPicker(String script) async {
    final result = await Process.run(
      'powershell',
      ['-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-Command', script],
      runInShell: false,
    );
    if (result.exitCode != 0) return null;
    final value = result.stdout.toString().trim();
    return value.isEmpty ? null : value;
  }
}
