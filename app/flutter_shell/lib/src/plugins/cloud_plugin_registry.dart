import 'dart:convert';
import 'dart:io';

import '../storage/app_paths.dart';

class CloudPluginDefinition {
  const CloudPluginDefinition({
    required this.id,
    required this.name,
    required this.rootPath,
    required this.manifestPath,
    this.description,
    this.authType,
    this.listRequest,
    this.infoRequest,
    this.streamRequest,
  });

  final String id;
  final String name;
  final String rootPath;
  final String manifestPath;
  final String? description;
  final String? authType;
  final Map<String, Object?>? listRequest;
  final Map<String, Object?>? infoRequest;
  final Map<String, Object?>? streamRequest;

  factory CloudPluginDefinition.fromJson(
    Map<String, Object?> json, {
    required String rootPath,
    required String manifestPath,
  }) {
    Map<String, Object?>? mapField(String key) {
      final value = json[key];
      if (value is Map) {
        return value.map((k, v) => MapEntry(k.toString(), v));
      }
      return null;
    }

    return CloudPluginDefinition(
      id: json['id'] as String? ?? basename(rootPath),
      name: json['name'] as String? ?? basename(rootPath),
      description: json['description'] as String?,
      authType: json['authType'] as String?,
      rootPath: rootPath,
      manifestPath: manifestPath,
      listRequest: mapField('listFiles'),
      infoRequest: mapField('fileInfo'),
      streamRequest: mapField('fileStream'),
    );
  }
}

class CloudPluginRegistry {
  Future<List<CloudPluginDefinition>> loadPlugins() async {
    final pluginsDir = await AppPaths.pluginsDirectory();
    await _ensureSamplePlugin(pluginsDir);
    final plugins = <CloudPluginDefinition>[];
    await for (final entity in pluginsDir.list(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }
      final manifest =
          File('${entity.path}${Platform.pathSeparator}plugin.json');
      if (!await manifest.exists()) {
        continue;
      }
      try {
        final decoded = jsonDecode(await manifest.readAsString());
        if (decoded is Map<String, Object?>) {
          plugins.add(
            CloudPluginDefinition.fromJson(
              decoded,
              rootPath: entity.path,
              manifestPath: manifest.path,
            ),
          );
        }
      } catch (_) {
        // Broken plugins stay isolated from the explorer.
      }
    }
    plugins.sort((a, b) => a.name.compareTo(b.name));
    return plugins;
  }

  Future<void> _ensureSamplePlugin(Directory pluginsDir) async {
    final sampleDir = Directory(
        '${pluginsDir.path}${Platform.pathSeparator}sample_cloud_plugin');
    final manifest =
        File('${sampleDir.path}${Platform.pathSeparator}plugin.json');
    if (await manifest.exists()) {
      return;
    }
    await sampleDir.create(recursive: true);
    await manifest.writeAsString(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'id': 'sample-cloud',
      'name': 'Sample Cloud Provider',
      'description': 'Template for JSON-defined cloud storage adapters.',
      'authType': 'oauth-html-return',
      'auth': <String, Object?>{
        'authorizeUrl': 'https://example.invalid/oauth/authorize',
        'redirectUri': 'securevault://oauth-return',
        'tokenRequest': <String, Object?>{
          'method': 'POST',
          'url': 'https://example.invalid/oauth/token',
        },
      },
      'listFiles': <String, Object?>{
        'method': 'GET',
        'url': 'https://example.invalid/api/files',
        'pathParameter': 'path',
        'foldersJsonPath': r'$.folders',
        'filesJsonPath': r'$.files',
      },
      'fileInfo': <String, Object?>{
        'method': 'GET',
        'url': 'https://example.invalid/api/file/info',
        'idParameter': 'id',
      },
      'fileStream': <String, Object?>{
        'method': 'GET',
        'url': 'https://example.invalid/api/file/download',
        'idParameter': 'id',
      },
    }));
  }
}

String basename(String path) => path.split(Platform.pathSeparator).last;
