import 'dart:convert';

import 'models.dart';
import 'protected_export_codec.dart';

class SourceConfigBundle {
  const SourceConfigBundle({required this.servers, this.selectedServerUrl});

  final List<ServerConfig> servers;
  final String? selectedServerUrl;
}

String encodeSourceConfig({
  required List<ServerConfig> servers,
  required String? selectedServerId,
}) {
  final payload = {
    'version': 1,
    'selectedServerUrl': selectedServerId,
    'servers': servers.map(_serverToExportJson).toList(),
  };
  return encodeProtectedExportText(jsonEncode(payload));
}

SourceConfigBundle decodeSourceConfig(String value) {
  final payload = jsonDecode(decodeProtectedExportText(value));
  if (payload is! Map) {
    throw const FormatException('音源配置格式无效。');
  }

  final rawServers = payload['servers'];
  if (rawServers is! List) {
    throw const FormatException('音源配置缺少 servers。');
  }

  final servers = <ServerConfig>[];
  final seenSources = <String>{};
  for (final rawServer in rawServers.whereType<Map>()) {
    final server = ServerConfig.fromJson(Map<String, Object?>.from(rawServer));
    final sourceId = server.id;
    if (sourceId.isEmpty || !seenSources.add(sourceId)) {
      continue;
    }
    servers.add(server);
  }

  if (servers.isEmpty) {
    throw const FormatException('音源配置没有有效音源。');
  }

  final selectedServerUrl = readString(
    payload.cast<String, Object?>(),
    'selectedServerUrl',
  );
  return SourceConfigBundle(
    servers: servers,
    selectedServerUrl: selectedServerUrl.isEmpty ? null : selectedServerUrl,
  );
}

Map<String, Object?> _serverToExportJson(ServerConfig server) {
  if (server.isLocalFolder) {
    return server.toJson();
  }
  return {
    'sourceKind': server.sourceKind.name,
    'name': server.name,
    'baseUrl': server.normalizedBaseUrl,
    'username': server.username,
    'password': server.password,
  };
}
