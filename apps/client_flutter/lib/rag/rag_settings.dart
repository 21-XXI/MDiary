import 'dart:convert';
import 'dart:io';

import '../core/app_paths.dart';

/// 本地模型设置（全局，存在 `<数据目录>/settings.json`，不随库切换）。
class RagSettings {
  const RagSettings({
    this.askModel = defaultAskModel,
    this.generateModel = defaultGenerateModel,
    this.embedModel = defaultEmbedModel,
    this.baseUrl = defaultBaseUrl,
    this.cloudEnabled = false,
    this.cloudBaseUrl = defaultCloudBaseUrl,
    this.cloudModel = defaultCloudModel,
    this.cloudApiKeyCipher = '',
  });

  static const String defaultAskModel = 'qwen3:8b';
  static const String defaultGenerateModel = 'qwen3:8b';
  static const String defaultEmbedModel = 'bge-m3';
  static const String defaultBaseUrl = 'http://127.0.0.1:11434';
  static const String defaultCloudBaseUrl = 'https://api.openai.com/v1';
  static const String defaultCloudModel = 'gpt-4o-mini';

  /// 问答（交互）用模型。
  final String askModel;

  /// 摘要 / 日报 / soul.md（后台生成）用模型。
  final String generateModel;

  /// 向量模型。
  final String embedModel;

  /// Ollama 地址。
  final String baseUrl;

  /// 是否允许把内容发送到云端模型（需显式开启）。
  final bool cloudEnabled;

  /// OpenAI 兼容地址（例如 `https://api.openai.com/v1`）。
  final String cloudBaseUrl;

  /// 云端模型名。
  final String cloudModel;

  /// DPAPI 加密后的 API Key（`dpapi:` / `b64:` 前缀）。
  final String cloudApiKeyCipher;

  bool get hasCloudKey => cloudApiKeyCipher.isNotEmpty;

  RagSettings copyWith({
    String? askModel,
    String? generateModel,
    String? embedModel,
    String? baseUrl,
    bool? cloudEnabled,
    String? cloudBaseUrl,
    String? cloudModel,
    String? cloudApiKeyCipher,
  }) => RagSettings(
    askModel: askModel ?? this.askModel,
    generateModel: generateModel ?? this.generateModel,
    embedModel: embedModel ?? this.embedModel,
    baseUrl: baseUrl ?? this.baseUrl,
    cloudEnabled: cloudEnabled ?? this.cloudEnabled,
    cloudBaseUrl: cloudBaseUrl ?? this.cloudBaseUrl,
    cloudModel: cloudModel ?? this.cloudModel,
    cloudApiKeyCipher: cloudApiKeyCipher ?? this.cloudApiKeyCipher,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'ask_model': askModel,
    'generate_model': generateModel,
    'embed_model': embedModel,
    'base_url': baseUrl,
    'cloud_enabled': cloudEnabled,
    'cloud_base_url': cloudBaseUrl,
    'cloud_model': cloudModel,
    'cloud_api_key': cloudApiKeyCipher,
  };

  factory RagSettings.fromJson(Map<String, Object?> json) => RagSettings(
    askModel: _string(json['ask_model'], defaultAskModel),
    generateModel: _string(json['generate_model'], defaultGenerateModel),
    embedModel: _string(json['embed_model'], defaultEmbedModel),
    baseUrl: _string(json['base_url'], defaultBaseUrl),
    cloudEnabled: json['cloud_enabled'] == true,
    cloudBaseUrl: _string(json['cloud_base_url'], defaultCloudBaseUrl),
    cloudModel: _string(json['cloud_model'], defaultCloudModel),
    cloudApiKeyCipher: json['cloud_api_key'] is String
        ? json['cloud_api_key']! as String
        : '',
  );

  static String _string(Object? value, String fallback) {
    final text = value is String ? value.trim() : '';
    return text.isEmpty ? fallback : text;
  }
}

/// 读写 `settings.json`；不依赖 Flutter，测试可传临时路径。
class RagSettingsStore {
  // ignore: prefer_initializing_formals
  RagSettingsStore({String? path}) : _path = path;

  final String? _path;

  String? get path => _path ?? _defaultPath();

  static String? _defaultPath() =>
      AppPaths.isInitialized ? AppPaths.settingsFile : null;

  RagSettings load() {
    final file = path;
    if (file == null) return const RagSettings();
    final handle = File(file);
    if (!handle.existsSync()) return const RagSettings();
    try {
      final decoded = jsonDecode(handle.readAsStringSync());
      if (decoded is Map<String, dynamic>) {
        return RagSettings.fromJson(decoded);
      }
    } on Object {
      // 坏文件当作默认值，避免启动失败
    }
    return const RagSettings();
  }

  void save(RagSettings settings) {
    final file = path;
    if (file == null) return;
    final handle = File(file);
    handle.parent.createSync(recursive: true);
    handle.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
      flush: true,
    );
  }
}
