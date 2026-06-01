class PluginConnectionEndpoint {
  const PluginConnectionEndpoint({
    this.label = '',
    required this.host,
    this.port,
  });

  final String label;
  final String host;
  final int? port;

  factory PluginConnectionEndpoint.fromJson(Map<String, Object?> json) {
    return PluginConnectionEndpoint(
      label: json['label']?.toString() ?? '',
      host: json['host']?.toString() ?? '',
      port: json['port'] is num
          ? (json['port'] as num).round()
          : int.tryParse(json['port']?.toString() ?? ''),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'label': label,
        'host': host,
        if (port != null) 'port': port,
      };

  Map<String, String> toVariables() {
    final value = host.trim();
    final result = <String, String>{
      if (value.isNotEmpty) 'host': value,
      if (value.isNotEmpty) 'server': value,
      if (value.startsWith('http://') || value.startsWith('https://'))
        'baseUrl': value,
      if (port != null) 'port': '$port',
    };
    return result;
  }

  String get displayLabel {
    final name = label.trim();
    final endpoint = port == null ? host : '$host:$port';
    if (name.isEmpty) return endpoint;
    return '$name: $endpoint';
  }
}

class PluginConnectionProfile {
  const PluginConnectionProfile({
    required this.id,
    required this.pluginId,
    required this.name,
    this.variables = const <String, String>{},
    this.endpoints = const <PluginConnectionEndpoint>[],
  });

  final String id;
  final String pluginId;
  final String name;
  final Map<String, String> variables;
  final List<PluginConnectionEndpoint> endpoints;

  String get runtimePluginId => 'profile-$id';

  String get endpointSummary {
    if (endpoints.isEmpty) return '';
    return endpoints.map((endpoint) => endpoint.displayLabel).join(' -> ');
  }

  PluginConnectionProfile copyWith({
    String? name,
    Map<String, String>? variables,
    List<PluginConnectionEndpoint>? endpoints,
  }) {
    return PluginConnectionProfile(
      id: id,
      pluginId: pluginId,
      name: name ?? this.name,
      variables: variables ?? this.variables,
      endpoints: endpoints ?? this.endpoints,
    );
  }

  factory PluginConnectionProfile.create({
    required String pluginId,
    required String name,
    Map<String, String> variables = const <String, String>{},
    List<PluginConnectionEndpoint> endpoints =
        const <PluginConnectionEndpoint>[],
  }) {
    final now = DateTime.now().microsecondsSinceEpoch;
    return PluginConnectionProfile(
      id: '$now',
      pluginId: pluginId,
      name: name,
      variables: variables,
      endpoints: endpoints,
    );
  }

  factory PluginConnectionProfile.fromJson(Map<String, Object?> json) {
    final variables = json['variables'];
    final endpoints = json['endpoints'];
    return PluginConnectionProfile(
      id: json['id']?.toString() ?? '${DateTime.now().microsecondsSinceEpoch}',
      pluginId: json['pluginId']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      variables: variables is Map
          ? variables.map(
              (key, value) => MapEntry(key.toString(), value?.toString() ?? ''))
          : const <String, String>{},
      endpoints: endpoints is List
          ? endpoints
              .whereType<Map>()
              .map((item) => PluginConnectionEndpoint.fromJson(
                    item.map((key, value) => MapEntry(key.toString(), value)),
                  ))
              .where((endpoint) => endpoint.host.trim().isNotEmpty)
              .toList()
          : const <PluginConnectionEndpoint>[],
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'pluginId': pluginId,
        'name': name,
        'variables': variables,
        'endpoints': endpoints.map((endpoint) => endpoint.toJson()).toList(),
      };
}
