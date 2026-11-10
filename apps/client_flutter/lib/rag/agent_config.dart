import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Agent 配置：步数上限 + 工具权限 + 日志开关。
class AgentConfig {
  const AgentConfig({
    this.maxSteps = 3,
    this.allowReadFolder = true,
    this.allowCreateLibrary = true,
    this.allowWriteDiary = true,
    this.allowReadSkill = true,
    this.allowSearchDiary = false,
    this.logEnabled = true,
  });

  final int maxSteps;
  final bool allowReadFolder;
  final bool allowCreateLibrary;
  final bool allowWriteDiary;
  final bool allowReadSkill;
  final bool allowSearchDiary;
  final bool logEnabled;

  AgentConfig copyWith({
    int? maxSteps,
    bool? allowReadFolder,
    bool? allowCreateLibrary,
    bool? allowWriteDiary,
    bool? allowReadSkill,
    bool? allowSearchDiary,
    bool? logEnabled,
  }) => AgentConfig(
    maxSteps: maxSteps ?? this.maxSteps,
    allowReadFolder: allowReadFolder ?? this.allowReadFolder,
    allowCreateLibrary: allowCreateLibrary ?? this.allowCreateLibrary,
    allowWriteDiary: allowWriteDiary ?? this.allowWriteDiary,
    allowReadSkill: allowReadSkill ?? this.allowReadSkill,
    allowSearchDiary: allowSearchDiary ?? this.allowSearchDiary,
    logEnabled: logEnabled ?? this.logEnabled,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'max_steps': maxSteps,
    'allow_read_folder': allowReadFolder,
    'allow_create_library': allowCreateLibrary,
    'allow_write_diary': allowWriteDiary,
    'allow_read_skill': allowReadSkill,
    'allow_search_diary': allowSearchDiary,
    'log_enabled': logEnabled,
  };

  factory AgentConfig.fromJson(Map<String, Object?> json) => AgentConfig(
    maxSteps: json['max_steps'] is int
        ? (json['max_steps']! as int).clamp(1, 10)
        : 3,
    allowReadFolder: json['allow_read_folder'] != false,
    allowCreateLibrary: json['allow_create_library'] != false,
    allowWriteDiary: json['allow_write_diary'] != false,
    allowReadSkill: json['allow_read_skill'] != false,
    allowSearchDiary: json['allow_search_diary'] == true,
    logEnabled: json['log_enabled'] != false,
  );
}

class AgentConfigStore {
  // ignore: prefer_initializing_formals
  AgentConfigStore({String? path}) : _path = path;

  final String? _path;

  String? get path => _path;

  AgentConfig load() {
    final file = path;
    if (file == null) return const AgentConfig();
    final handle = File(file);
    if (!handle.existsSync()) return const AgentConfig();
    try {
      final decoded = jsonDecode(handle.readAsStringSync());
      if (decoded is Map<String, dynamic>) return AgentConfig.fromJson(decoded);
    } on Object {
      // 坏文件用默认
    }
    return const AgentConfig();
  }

  void save(AgentConfig config) {
    final file = path;
    if (file == null) return;
    final handle = File(file);
    handle.parent.createSync(recursive: true);
    handle.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(config.toJson()),
      flush: true,
    );
  }
}

/// 一次 Agent 运行的记录。
class AgentRun {
  const AgentRun({
    required this.kind,
    required this.startedAt,
    required this.steps,
    required this.ok,
    required this.message,
  });

  final String kind;
  final DateTime startedAt;
  final int steps;
  final bool ok;
  final String message;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'at': startedAt.toIso8601String(),
    'steps': steps,
    'ok': ok,
    'message': message,
  };

  factory AgentRun.fromJson(Map<String, dynamic> json) => AgentRun(
    kind: '${json['kind'] ?? 'agent'}',
    startedAt: DateTime.tryParse('${json['at'] ?? ''}') ?? DateTime.now(),
    steps: json['steps'] is int ? json['steps']! as int : 0,
    ok: json['ok'] == true,
    message: '${json['message'] ?? ''}',
  );
}

/// 运行日志（按库）：`<库>/agent/runs.jsonl`。
class AgentRunLog {
  const AgentRunLog(this.path);

  final String path;

  List<AgentRun> load({int limit = 100}) {
    final file = File(path);
    if (!file.existsSync()) return const <AgentRun>[];
    final runs = <AgentRun>[];
    for (final line in file.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map<String, dynamic>) runs.add(AgentRun.fromJson(decoded));
      } on FormatException {
        // 坏行跳过
      }
    }
    if (runs.length > limit) {
      return runs.sublist(runs.length - limit);
    }
    return runs;
  }

  void append(AgentRun run) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '${jsonEncode(run.toJson())}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  void clear() {
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
  }

  static String pathFor(String libraryDir) =>
      p.join(libraryDir, 'agent', 'runs.jsonl');
}
