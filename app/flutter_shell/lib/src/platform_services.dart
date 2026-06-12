import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'storage/app_paths.dart';

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

class EmbeddedWebSession {
  EmbeddedWebSession._(this.uri, this._onClose);

  final Uri uri;
  final Future<void> Function() _onClose;
  var _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _onClose();
  }
}

class PlatformServices {
  PlatformServices._();

  static const MethodChannel _channel = MethodChannel('filesmanagers/platform');
  static const MethodChannel _windowChannel =
      MethodChannel('filesmanagers/window');
  static final List<HttpServer> _swfServers = <HttpServer>[];

  static const List<String> _ruffleRuntimeFiles = <String>[
    'ruffle.js',
    'core.ruffle.a6584f4c154875f3f805.js',
    'core.ruffle.f8e79026a9aea0a4e05d.js',
    'bae0d5b86e41210ba443.wasm',
    'ecc5e233d534bdc785c1.wasm',
  ];

  static Future<void> setWindowTitle(String title) async {
    if (Platform.isWindows) {
      await _windowChannel.invokeMethod<void>('setTitle', title);
    }
  }

  static Future<void> setWindowAlwaysOnTop(bool enabled) async {
    if (Platform.isWindows) {
      await _windowChannel.invokeMethod<void>('setTopMost', enabled);
    }
  }

  static Future<void> setMinimizeToTrayOnClose(bool enabled) async {
    if (Platform.isWindows) {
      await _windowChannel.invokeMethod<void>(
          'setMinimizeToTrayOnClose', enabled);
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

  static Future<Uint8List?> renderPdfFirstPage(String path) async {
    if (!Platform.isAndroid) return null;
    return _channel.invokeMethod<Uint8List>('renderPdfFirstPage', path);
  }

  static Future<void> openExternal(String path) async {
    if (path.startsWith('http://') ||
        path.startsWith('https://') ||
        path.startsWith('mailto:')) {
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
    }
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

  static Future<void> openSwfWithRuffle({
    required String title,
    String? sourcePath,
    List<int>? bytes,
  }) async {
    final session = await startSwfRuffleSession(
      title: title,
      sourcePath: sourcePath,
      bytes: bytes,
    );
    await openExternal(session.uri.toString());
  }

  static Future<EmbeddedWebSession> startHtmlSession({
    required String title,
    required String html,
    String? sourcePath,
  }) async {
    final baseDir = _localBaseDirectory(sourcePath);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _swfServers.add(server);
    final session = EmbeddedWebSession._(
      Uri.parse('http://127.0.0.1:${server.port}/index.html'),
      () async {
        _swfServers.remove(server);
        await server.close(force: true);
      },
    );
    unawaited(_serveHtmlSession(
      server,
      title: title,
      html: html,
      baseDir: baseDir,
    ));
    Timer(const Duration(minutes: 30), () => unawaited(session.close()));
    return session;
  }

  static Future<EmbeddedWebSession> startSwfRuffleSession({
    required String title,
    String? sourcePath,
    List<int>? bytes,
  }) async {
    final swfBytes = bytes != null
        ? Uint8List.fromList(bytes)
        : await File(sourcePath ?? '').readAsBytes();
    final runtimeDir = await _ensureRuffleRuntime();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _swfServers.add(server);
    final session = EmbeddedWebSession._(
      Uri.parse('http://127.0.0.1:${server.port}/index.html'),
      () async {
        _swfServers.remove(server);
        await server.close(force: true);
      },
    );
    unawaited(_serveSwfSession(
      server,
      title: title,
      swfBytes: swfBytes,
      runtimeDir: runtimeDir,
    ));
    Timer(const Duration(minutes: 30), () => unawaited(session.close()));
    return session;
  }

  static Future<Directory> _ensureRuffleRuntime() async {
    final cache = await AppPaths.protectedCacheDirectory();
    final runtimeDir = Directory(
      '${cache.path}${Platform.pathSeparator}swf_ruffle'
      '${Platform.pathSeparator}runtime',
    );
    await runtimeDir.create(recursive: true);
    for (final name in _ruffleRuntimeFiles) {
      final target = File('${runtimeDir.path}${Platform.pathSeparator}$name');
      if (await target.exists() && await target.length() > 0) continue;
      final data = await rootBundle.load(
        'assets/plugin_components/swf_ruffle_player/ruffle/$name',
      );
      await target.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    return runtimeDir;
  }

  static Future<void> _serveSwfSession(
    HttpServer server, {
    required String title,
    required Uint8List swfBytes,
    required Directory runtimeDir,
  }) async {
    await for (final request in server) {
      try {
        final path = request.uri.path == '/' ? '/index.html' : request.uri.path;
        if (path == '/index.html') {
          final safeTitle = const HtmlEscape().convert(title);
          final html = '''
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$safeTitle</title>
  <style>
    html, body { margin: 0; height: 100%; background: #101923; color: #e8f0f7; }
    #stage { width: 100vw; height: 100vh; display: grid; place-items: center; }
    ruffle-player { width: 100%; height: 100%; max-width: 100vw; max-height: 100vh; }
  </style>
  <script src="/ruffle.js"></script>
</head>
<body>
  <div id="stage"></div>
  <script>
    window.RufflePlayer = window.RufflePlayer || {};
    window.addEventListener("DOMContentLoaded", () => {
      const ruffle = window.RufflePlayer.newest();
      const player = ruffle.createPlayer();
      document.getElementById("stage").appendChild(player);
      player.load("/movie.swf");
    });
  </script>
</body>
</html>
''';
          request.response.headers.contentType = ContentType.html;
          request.response.write(html);
        } else if (path == '/movie.swf') {
          request.response.headers.set(
            HttpHeaders.contentTypeHeader,
            'application/x-shockwave-flash',
          );
          request.response.add(swfBytes);
        } else {
          final name = path.substring(1);
          if (!_ruffleRuntimeFiles.contains(name)) {
            request.response.statusCode = HttpStatus.notFound;
          } else {
            final file =
                File('${runtimeDir.path}${Platform.pathSeparator}$name');
            if (!await file.exists()) {
              request.response.statusCode = HttpStatus.notFound;
            } else {
              request.response.headers.set(
                HttpHeaders.contentTypeHeader,
                _contentTypeFor(name),
              );
              await request.response.addStream(file.openRead());
            }
          }
        }
      } catch (error) {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write(error.toString());
      } finally {
        await request.response.close();
      }
    }
  }

  static Future<void> _serveHtmlSession(
    HttpServer server, {
    required String title,
    required String html,
    required Directory? baseDir,
  }) async {
    await for (final request in server) {
      try {
        final path = request.uri.path == '/' ? '/index.html' : request.uri.path;
        if (path == '/index.html') {
          request.response.headers.contentType = ContentType.html;
          request.response.write(html);
        } else if (baseDir != null) {
          final relative = Uri.decodeComponent(path.substring(1))
              .replaceAll('\\', '/')
              .split('/')
              .where((part) => part.isNotEmpty && part != '..')
              .join(Platform.pathSeparator);
          if (relative.isEmpty) {
            request.response.statusCode = HttpStatus.notFound;
          } else {
            final file =
                File('${baseDir.path}${Platform.pathSeparator}$relative');
            final normalizedBase = baseDir.absolute.path;
            final normalizedFile = file.absolute.path;
            if (!normalizedFile.startsWith(normalizedBase) ||
                !await file.exists()) {
              request.response.statusCode = HttpStatus.notFound;
            } else {
              request.response.headers.set(
                HttpHeaders.contentTypeHeader,
                _contentTypeFor(file.path),
              );
              await request.response.addStream(file.openRead());
            }
          }
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
      } catch (error) {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write(error.toString());
      } finally {
        await request.response.close();
      }
    }
  }

  static Directory? _localBaseDirectory(String? sourcePath) {
    if (sourcePath == null ||
        sourcePath.startsWith('zip://') ||
        sourcePath.startsWith('rar://') ||
        sourcePath.startsWith('remote://') ||
        sourcePath.startsWith('torrent://') ||
        sourcePath.startsWith('http://') ||
        sourcePath.startsWith('https://')) {
      return null;
    }
    final file = File(sourcePath);
    return file.existsSync() ? file.parent : null;
  }

  static String _contentTypeFor(String name) {
    if (name.endsWith('.js')) return 'application/javascript; charset=utf-8';
    if (name.endsWith('.wasm')) return 'application/wasm';
    if (name.endsWith('.map')) return 'application/json; charset=utf-8';
    if (name.endsWith('.html') || name.endsWith('.htm')) {
      return 'text/html; charset=utf-8';
    }
    if (name.endsWith('.css')) return 'text/css; charset=utf-8';
    if (name.endsWith('.png')) return 'image/png';
    if (name.endsWith('.jpg') || name.endsWith('.jpeg')) return 'image/jpeg';
    if (name.endsWith('.gif')) return 'image/gif';
    if (name.endsWith('.svg')) return 'image/svg+xml';
    if (name.endsWith('.webp')) return 'image/webp';
    return 'application/octet-stream';
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
      _windowsTtsProcess?.kill();
      const script = r'''
$Text = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($args[0]))
Add-Type -AssemblyName System.Speech
$speaker = New-Object System.Speech.Synthesis.SpeechSynthesizer
$speaker.Speak($Text)
''';
      _windowsTtsProcess = await Process.start(
        'powershell',
        [
          '-NoProfile',
          '-STA',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          script,
          base64.encode(utf8.encode(value)),
        ],
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

  static Process? _windowsTtsProcess;

  static Future<void> stopSpeaking() async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('stopSpeaking');
      return;
    }
    if (Platform.isWindows) {
      _windowsTtsProcess?.kill();
      _windowsTtsProcess = null;
      return;
    }
    if (Platform.isLinux) {
      try {
        await Process.run('spd-say', ['--cancel']);
      } catch (_) {}
    }
  }

  static Future<String?> pickFile() async {
    if (Platform.isAndroid) {
      return _channel.invokeMethod<String>('pickFile');
    }
    if (Platform.isWindows) {
      return _runPowerShellPicker(r'''
Add-Type -AssemblyName System.Windows.Forms
function Write-filesmanagersPath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  [Console]::OutputEncoding = [System.Text.Encoding]::ASCII
  [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Path))
}
$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Multiselect = $false
if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  Write-filesmanagersPath $dialog.FileName
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
    if (Platform.isAndroid) {
      return _channel.invokeMethod<String>('pickDirectory');
    }
    if (Platform.isWindows) {
      return _runPowerShellPicker(r'''
Add-Type -AssemblyName System.Windows.Forms
function Write-filesmanagersPath([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  [Console]::OutputEncoding = [System.Text.Encoding]::ASCII
  [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Path))
}
$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
  Write-filesmanagersPath $dialog.SelectedPath
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
    final raw = result.stdout.toString();
    final value = raw
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '');
    if (value.isEmpty) return null;
    try {
      return utf8.decode(base64.decode(value));
    } catch (_) {}
    return value;
  }
}
