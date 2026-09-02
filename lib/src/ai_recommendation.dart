import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'settings_models.dart';

enum AiServicePreset { chatGpt, deepSeek, tencent, bailian, custom }

extension AiServicePresetDetails on AiServicePreset {
  String get label => switch (this) {
    AiServicePreset.chatGpt => 'ChatGPT',
    AiServicePreset.deepSeek => 'DeepSeek',
    AiServicePreset.tencent => 'Tencent',
    AiServicePreset.bailian => 'Bailian',
    AiServicePreset.custom => '自定义',
  };

  String get endpoint => switch (this) {
    AiServicePreset.chatGpt => 'https://api.openai.com/v1/chat/completions',
    AiServicePreset.deepSeek => 'https://api.deepseek.com/chat/completions',
    AiServicePreset.tencent =>
      'https://lkeap.tencentcloudapi.com/v1/chat/completions',
    AiServicePreset.bailian =>
      'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',
    AiServicePreset.custom => '',
  };
}

enum AiRecommendationPurpose { dailyRecommendation, casualListening }

class AiRecommendationCandidate {
  const AiRecommendationCandidate({required this.track, required this.sources});

  final Track track;
  final Set<String> sources;
}

class AiRecommendationException implements Exception {
  const AiRecommendationException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AiRecommendationClient {
  AiRecommendationClient({http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client(),
      _ownsHttpClient = httpClient == null;

  static const Duration _testTimeout = Duration(seconds: 20);
  static const Duration _recommendationTimeout = Duration(seconds: 90);
  static const int _recommendationMaxOutputTokens = 1024;

  final http.Client _httpClient;
  final bool _ownsHttpClient;
  Future<void> _rankRequestTail = Future<void>.value();

  Future<void> testConnection({
    required AiServiceConfig service,
    required String apiKey,
  }) async {
    final content = await _request(
      service: service,
      apiKey: apiKey,
      timeout: _testTimeout,
      messages: const [
        {'role': 'user', 'content': '只回复 OK'},
      ],
    );
    if (content.trim().isEmpty) {
      throw const AiRecommendationException('AI 服务未返回内容。');
    }
  }

  Future<List<String>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) async {
    final uri = _modelsUri(endpoint);
    if (apiKey.trim().isEmpty) {
      throw const AiRecommendationException('请填写 API Key。');
    }
    try {
      final response = await _httpClient
          .get(
            uri,
            headers: {
              'Authorization': 'Bearer ${apiKey.trim()}',
              'Accept': 'application/json',
            },
          )
          .timeout(_testTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AiRecommendationException('HTTP ${response.statusCode}。');
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map || decoded['data'] is! List) {
        throw const AiRecommendationException('模型列表响应格式无效。');
      }
      final models = <String>{};
      for (final item in decoded['data'] as List) {
        if (item is Map) {
          final id = item['id'];
          if (id is String && id.trim().isNotEmpty) {
            models.add(id.trim());
          }
        }
      }
      if (models.isEmpty) {
        throw const AiRecommendationException('服务未返回可用模型。');
      }
      return models.toList()..sort();
    } on TimeoutException {
      throw const AiRecommendationException('请求超时，请检查网络后重试。');
    } on AiRecommendationException {
      rethrow;
    } on FormatException {
      throw const AiRecommendationException('模型列表返回了无法解析的数据。');
    } on http.ClientException {
      throw const AiRecommendationException('无法连接 AI 服务，请检查服务地址和网络。');
    }
  }

  Future<List<Track>> rankTracks({
    required AiServiceConfig service,
    required String apiKey,
    required AiRecommendationPurpose purpose,
    required List<AiRecommendationCandidate> candidates,
  }) async {
    // Providers may serialize requests per account; avoid concurrent ranking
    // calls from the daily and casual recommendation loaders.
    final previousRequest = _rankRequestTail;
    final releaseRequest = Completer<void>();
    _rankRequestTail = previousRequest.then<void>((_) => releaseRequest.future);
    try {
      await previousRequest;
    } catch (_) {
      // Keep a later request usable even if a custom client failed internally.
    }
    try {
      return await _rankTracks(
        service: service,
        apiKey: apiKey,
        purpose: purpose,
        candidates: candidates,
      );
    } finally {
      if (!releaseRequest.isCompleted) {
        releaseRequest.complete();
      }
    }
  }

  Future<List<Track>> _rankTracks({
    required AiServiceConfig service,
    required String apiKey,
    required AiRecommendationPurpose purpose,
    required List<AiRecommendationCandidate> candidates,
  }) async {
    if (candidates.length < 2) {
      return candidates.map((candidate) => candidate.track).toList();
    }
    final limitedCandidates = candidates.take(80).toList();
    final tracksByTemporaryId = <String, Track>{};
    final candidatePayload = <Map<String, Object?>>[];
    for (var index = 0; index < limitedCandidates.length; index += 1) {
      final temporaryId = 'T${(index + 1).toString().padLeft(3, '0')}';
      final candidate = limitedCandidates[index];
      tracksByTemporaryId[temporaryId] = candidate.track;
      candidatePayload.add({
        'id': temporaryId,
        'title': candidate.track.title,
        'artist': candidate.track.artist,
        'album': candidate.track.album,
        'genre': candidate.track.genre,
        'playCount': candidate.track.playCount,
        'lastPlayedDate': candidate.track.lastPlayedAt
            ?.toIso8601String()
            .split('T')
            .first,
        'candidateSources': candidate.sources.toList()..sort(),
      });
    }
    final purposeDescription = switch (purpose) {
      AiRecommendationPurpose.dailyRecommendation =>
        '每日推荐：兼顾用户熟悉的歌手和歌曲、近期偏好与新鲜探索。',
      AiRecommendationPurpose.casualListening =>
        '随便听听：优先未听过、很久未听、播放次数少，并与近期常听风格形成反差。',
    };
    final content = await _request(
      service: service,
      apiKey: apiKey,
      timeout: _recommendationTimeout,
      messages: [
        const {
          'role': 'system',
          'content':
              '你是音乐推荐排序器。只能从候选歌曲中排序，不得新增歌曲。'
              '只返回严格 JSON：{"selected":["T001","T002"]}，'
              'selected 按推荐优先级列出最多 30 个候选 ID，不要输出解释或 Markdown。',
        },
        {
          'role': 'user',
          'content':
              '$purposeDescription\n候选歌曲：${jsonEncode(candidatePayload)}',
        },
      ],
    );
    final selectedIds = _parseSelectedIds(content);
    final ordered = <Track>[];
    final selectedTracks = <Track>{};
    for (final id in selectedIds) {
      final track = tracksByTemporaryId[id];
      if (track != null && selectedTracks.add(track)) {
        ordered.add(track);
      }
    }
    if (ordered.isEmpty) {
      throw const AiRecommendationException('AI 服务返回的推荐结果无效。');
    }
    for (final candidate in limitedCandidates) {
      if (selectedTracks.add(candidate.track)) {
        ordered.add(candidate.track);
      }
    }
    return ordered;
  }

  Future<String> _request({
    required AiServiceConfig service,
    required String apiKey,
    required Duration timeout,
    required List<Map<String, String>> messages,
  }) async {
    final uri = Uri.tryParse(service.endpoint.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      throw const AiRecommendationException('AI 服务地址无效。');
    }
    if (service.model.trim().isEmpty) {
      throw const AiRecommendationException('请填写模型名称。');
    }
    if (apiKey.trim().isEmpty) {
      throw const AiRecommendationException('请填写 API Key。');
    }
    try {
      final response = await _httpClient
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer ${apiKey.trim()}',
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({
              'model': service.model.trim(),
              'messages': messages,
              'max_tokens': _recommendationMaxOutputTokens,
            }),
          )
          .timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AiRecommendationException(
          'AI 服务请求失败：HTTP ${response.statusCode}。',
        );
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) {
        throw const AiRecommendationException('AI 服务响应格式无效。');
      }
      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty || choices.first is! Map) {
        throw const AiRecommendationException('AI 服务响应缺少结果。');
      }
      final message = (choices.first as Map)['message'];
      if (message is! Map) {
        throw const AiRecommendationException('AI 服务响应缺少消息内容。');
      }
      return _readMessageContent(message['content']);
    } on TimeoutException {
      throw const AiRecommendationException('AI 服务请求超时，请检查网络后重试。');
    } on AiRecommendationException {
      rethrow;
    } on FormatException {
      throw const AiRecommendationException('AI 服务返回了无法解析的数据。');
    } on http.ClientException {
      throw const AiRecommendationException('无法连接 AI 服务，请检查服务地址和网络。');
    }
  }

  Uri _modelsUri(String endpoint) {
    final uri = Uri.tryParse(endpoint.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      throw const AiRecommendationException('AI 服务地址无效。');
    }
    final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    const chatCompletionsSuffix = '/chat/completions';
    if (!path.endsWith(chatCompletionsSuffix)) {
      throw const AiRecommendationException('当前服务地址无法推导模型列表地址，请手动填写模型名称。');
    }
    return uri.replace(
      path:
          '${path.substring(0, path.length - chatCompletionsSuffix.length)}/models',
      query: null,
      fragment: null,
    );
  }

  String _readMessageContent(Object? value) {
    if (value is String) {
      return value;
    }
    if (value is List) {
      return value
          .whereType<Map>()
          .map((part) => part['text'])
          .whereType<String>()
          .join();
    }
    throw const AiRecommendationException('AI 服务响应内容无效。');
  }

  List<String> _parseSelectedIds(String content) {
    var normalized = content.trim();
    if (normalized.startsWith('```')) {
      normalized = normalized
          .replaceFirst(RegExp(r'^```(?:json)?\s*'), '')
          .replaceFirst(RegExp(r'\s*```$'), '');
    }
    final objectStart = normalized.indexOf('{');
    final objectEnd = normalized.lastIndexOf('}');
    if (objectStart < 0 || objectEnd <= objectStart) {
      throw const AiRecommendationException('AI 服务返回的推荐结果无效。');
    }
    try {
      final decoded = jsonDecode(
        normalized.substring(objectStart, objectEnd + 1),
      );
      if (decoded is! Map || decoded['selected'] is! List) {
        throw const AiRecommendationException('AI 服务返回的推荐结果无效。');
      }
      return (decoded['selected'] as List).whereType<String>().toList();
    } on FormatException {
      throw const AiRecommendationException('AI 服务返回的推荐结果无效。');
    }
  }

  void dispose() {
    if (_ownsHttpClient) {
      _httpClient.close();
    }
  }
}
