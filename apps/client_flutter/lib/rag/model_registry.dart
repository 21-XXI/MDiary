import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/app_paths.dart';
import 'rag_settings.dart';

/// 功能角色：配置一次，各功能按角色取模型。
enum ModelRole {
  chat,
  generate,
  segment,
  memory,
  embed,
}

extension ModelRoleInfo on ModelRole {
  String get key => name;

  String get label => switch (this) {
    ModelRole.chat => '问答对话',
    ModelRole.generate => '摘要 / 日报 / soul',
    ModelRole.segment => '分词切分',
    ModelRole.memory => '记忆对话',
    ModelRole.embed => '向量索引',
  };

  String get hint => switch (this) {
    ModelRole.chat => 'RAG 问答、对话生成',
    ModelRole.generate => '后台摘要、日报、灵魂档案、蒸馏',
    ModelRole.segment => '把文件夹资料切成日记',
    ModelRole.memory => '带 skill 的记忆对话',
    ModelRole.embed => '切片 embedding（仅本地）',
  };
}

/// 一套模型配置（本地 Ollama 或 OpenAI 兼容云端）。
class ModelProfile {
  const ModelProfile({
    required this.id,
    required this.name,
    required this.provider,
    required this.baseUrl,
    required this.model,
    this.apiKeyCipher = '',
    this.temperature = 0.3,
    this.numCtx = 0,
  });

  final String id;
  final String name;

  /// `ollama` 或 `openai`。
  final String provider;
  final String baseUrl;
  final String model;

  /// DPAPI 加密后的 Key（仅云端）。
  final String apiKeyCipher;
  final double temperature;

  /// 0 = 用服务端默认。
  final int numCtx;

  bool get isCloud => provider == 'openai';

  ModelProfile copyWith({
    String? name,
    String? provider,
    String? baseUrl,
    String? model,
    String? apiKeyCipher,
    double? temperature,
    int? numCtx,
  }) => ModelProfile(
    id: id,
    name: name ?? this.name,
    provider: provider ?? this.provider,
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    apiKeyCipher: apiKeyCipher ?? this.apiKeyCipher,
    temperature: temperature ?? this.temperature,
    numCtx: numCtx ?? this.numCtx,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'provider': provider,
    'base_url': baseUrl,
    'model': model,
    'api_key': apiKeyCipher,
    'temperature': temperature,
    'num_ctx': numCtx,
  };

  factory ModelProfile.fromJson(Map<String, Object?> json) => ModelProfile(
    id: '${json['id'] ?? ''}',
    name: _text(json['name'], '未命名'),
    provider: _text(json['provider'], 'ollama'),
    baseUrl: _text(json['base_url'], RagSettings.defaultBaseUrl),
    model: _text(json['model'], RagSettings.defaultGenerateModel),
    apiKeyCipher: json['api_key'] is String ? json['api_key']! as String : '',
    temperature: (json['temperature'] is num)
        ? (json['temperature']! as num).toDouble()
        : 0.3,
    numCtx: json['num_ctx'] is int ? json['num_ctx']! as int : 0,
  );

  String get summary =>
      isCloud ? '$model · 云端' : '$model · $baseUrl';
}

/// 模型配置 + 角色映射。存 `<数据目录>/models.json`。
class ModelRegistry {
  const ModelRegistry({
    this.profiles = const <ModelProfile>[],
    this.roleProfiles = const <ModelRole, String>{},
  });

  final List<ModelProfile> profiles;
  final Map<ModelRole, String> roleProfiles;

  ModelProfile? byId(String? id) {
    if (id == null) return null;
    for (final profile in profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  ModelProfile? profileFor(ModelRole role) => byId(roleProfiles[role]);

  bool get isEmpty => profiles.isEmpty;

  ModelRegistry copyWith({
    List<ModelProfile>? profiles,
    Map<ModelRole, String>? roleProfiles,
  }) => ModelRegistry(
    profiles: profiles ?? this.profiles,
    roleProfiles: roleProfiles ?? this.roleProfiles,
  );

  ModelRegistry withProfile(ModelProfile profile) {
    final next = <ModelProfile>[
      for (final item in profiles)
        if (item.id != profile.id) item,
      profile,
    ];
    return copyWith(profiles: next);
  }

  ModelRegistry withoutProfile(String id) {
    final next = <ModelProfile>[
      for (final item in profiles)
        if (item.id != id) item,
    ];
    final roles = <ModelRole, String>{};
    for (final entry in roleProfiles.entries) {
      if (entry.value != id) roles[entry.key] = entry.value;
    }
    return ModelRegistry(profiles: next, roleProfiles: roles);
  }

  ModelRegistry withRole(ModelRole role, String? profileId) {
    final roles = <ModelRole, String>{...roleProfiles};
    if (profileId == null || profileId.isEmpty) {
      roles.remove(role);
    } else {
      roles[role] = profileId;
    }
    return copyWith(roleProfiles: roles);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'profiles': <Object?>[for (final profile in profiles) profile.toJson()],
    'roles': <String, String>{
      for (final entry in roleProfiles.entries) entry.key.name: entry.value,
    },
  };

  factory ModelRegistry.fromJson(Map<String, Object?> json) {
    final profiles = <ModelProfile>[];
    final rawProfiles = json['profiles'];
    if (rawProfiles is List) {
      for (final item in rawProfiles) {
        if (item is Map<String, dynamic>) {
          profiles.add(ModelProfile.fromJson(item));
        }
      }
    }
    final roles = <ModelRole, String>{};
    final rawRoles = json['roles'];
    if (rawRoles is Map) {
      for (final entry in rawRoles.entries) {
        final role = ModelRole.values.where((r) => r.name == entry.key);
        if (role.isNotEmpty && entry.value is String) {
          roles[role.first] = entry.value as String;
        }
      }
    }
    return ModelRegistry(profiles: profiles, roleProfiles: roles);
  }

  /// 从旧 `settings.json` 迁出一套默认配置。
  static ModelRegistry migration(RagSettings settings) {
    final profiles = <ModelProfile>[
      ModelProfile(
        id: 'local-chat',
        name: '本地 · 对话',
        provider: 'ollama',
        baseUrl: settings.baseUrl,
        model: settings.askModel,
      ),
      ModelProfile(
        id: 'local-generate',
        name: '本地 · 生成',
        provider: 'ollama',
        baseUrl: settings.baseUrl,
        model: settings.generateModel,
      ),
      ModelProfile(
        id: 'local-embed',
        name: '本地 · 向量',
        provider: 'ollama',
        baseUrl: settings.baseUrl,
        model: settings.embedModel,
      ),
    ];
    if (settings.cloudEnabled && settings.cloudApiKeyCipher.isNotEmpty) {
      profiles.add(
        ModelProfile(
          id: 'cloud-generate',
          name: '云端 · 生成',
          provider: 'openai',
          baseUrl: settings.cloudBaseUrl,
          model: settings.cloudModel,
          apiKeyCipher: settings.cloudApiKeyCipher,
        ),
      );
    }
    return ModelRegistry(
      profiles: profiles,
      roleProfiles: <ModelRole, String>{
        ModelRole.chat: 'local-chat',
        ModelRole.generate: 'local-generate',
        ModelRole.segment: 'local-generate',
        ModelRole.memory: 'local-chat',
        ModelRole.embed: 'local-embed',
      },
    );
  }
}

/// 读写 `models.json`。
class ModelRegistryStore {
  // ignore: prefer_initializing_formals
  ModelRegistryStore({String? path}) : _path = path;

  final String? _path;

  String? get path => _path ?? _defaultPath();

  static String? _defaultPath() {
    if (!AppPaths.isInitialized) return null;
    final file = File(AppPaths.settingsFile);
    return p.join(file.parent.path, 'models.json');
  }

  ModelRegistry load() {
    final file = path;
    if (file == null) return const ModelRegistry();
    final handle = File(file);
    if (!handle.existsSync()) return const ModelRegistry();
    try {
      final decoded = jsonDecode(handle.readAsStringSync());
      if (decoded is Map<String, dynamic>) {
        return ModelRegistry.fromJson(decoded);
      }
    } on Object {
      // 坏文件当没有，启动时再迁移
    }
    return const ModelRegistry();
  }

  void save(ModelRegistry registry) {
    final file = path;
    if (file == null) return;
    final handle = File(file);
    handle.parent.createSync(recursive: true);
    handle.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(registry.toJson()),
      flush: true,
    );
  }
}

String _text(Object? value, String fallback) {
  final text = value is String ? value.trim() : '';
  return text.isEmpty ? fallback : text;
}
