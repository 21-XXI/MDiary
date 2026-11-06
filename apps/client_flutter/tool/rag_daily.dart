// 每日语义管理（2.0.4）命令行入口：增量索引 + 给新增/修改的日记写摘要。
//
// 用法：
//   dart run tool/rag_daily.dart --root <库目录> [--force] [--skip-index]
//   dart run tool/rag_daily.dart --root <库目录> --fake        # 不连模型，自检链路
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:mdiary/data/attachment_repository.dart';
import 'package:mdiary/data/attachment_store.dart';
import 'package:mdiary/data/database.dart';
import 'package:mdiary/data/entry_repository.dart';
import 'package:mdiary/data/tag_repository.dart';
import 'package:mdiary/rag/daily_job.dart';
import 'package:mdiary/rag/embedder.dart';
import 'package:mdiary/rag/rag_service.dart';
import 'package:mdiary/rag/summarizer.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';

Future<void> main(List<String> args) async {
  try {
    exitCode = await _run(args);
  } on SummarizerUnavailable catch (error) {
    stderr.writeln('本地模型不可用：$error');
    exitCode = 2;
  } on EmbedderUnavailable catch (error) {
    stderr.writeln('本地 embedding 模型不可用：$error');
    exitCode = 2;
  } on Object catch (error, stack) {
    stderr.writeln('失败：$error');
    if (Platform.environment['RAG_DEBUG'] == '1') stderr.writeln(stack);
    exitCode = 1;
  }
}

Future<int> _run(List<String> args) async {
  final options = _Options.parse(args);
  if (options.root == null) {
    stderr.writeln(_usage);
    return 1;
  }
  _loadSqlite3();

  final root = p.canonicalize(options.root!);
  final dbFile = _locateDatabase(root);
  if (dbFile == null) {
    stderr.writeln('找不到数据库：$root 下没有 mdiary.sqlite 或 db/mdiary.sqlite');
    return 1;
  }
  final libraryRoot = p.isWithin(root, p.dirname(dbFile)) ||
          p.equals(root, p.dirname(dbFile))
      ? root
      : p.dirname(dbFile);

  final db = AppDatabase.open(dbFile);
  final entries = EntryRepository(db);
  final attachments = AttachmentRepository(db);
  final tags = TagRepository(db);
  final store = AttachmentStore(
    Directory(p.join(libraryRoot, 'attachments')),
    blobs: attachments,
  );

  final summarizer = options.fake
      ? FakeSummarizer()
      : OllamaSummarizer(baseUrl: options.baseUrl, model: options.model);
  final embedder = options.fake
      ? HashingEmbedder()
      : OllamaEmbedder(baseUrl: options.baseUrl, model: options.embedModel);

  final ragService = RagService.open(
    libraryRoot: libraryRoot,
    entries: entries,
    attachments: attachments,
    tags: tags,
    store: store,
    embedder: embedder,
  );

  try {
    if (!await summarizer.isAvailable()) {
      stderr.writeln(
        '连不上 ${options.baseUrl} 或没有模型 ${summarizer.modelId}。'
        '先 `ollama pull ${options.model}`，或加 --fake 自检。',
      );
      return 2;
    }

    if (!options.skipIndex) {
      final report = await ragService.reindex();
      if (options.verbose) stdout.writeln(report);
    }

    final job = DailySemanticJob(
      rag: ragService.database,
      entries: entries,
      tags: tags,
      summarizer: summarizer,
    );
    final report = await job.runIfDue(force: options.force);

    if (options.json) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(report.toJson()));
    } else {
      stdout.writeln(report);
      for (final error in report.errors.take(10)) {
        stdout.writeln('  - $error');
      }
    }

    final jobRow = ragService.database.job('daily:${report.date}');
    if (jobRow != null && options.verbose) {
      stdout.writeln('job: ${jobRow['status']} (attempts=${jobRow['attempts']})');
    }
    return report.ok ? 0 : 3;
  } finally {
    ragService.close();
    db.dispose();
  }
}

String? _locateDatabase(String root) {
  final direct = File(p.join(root, 'mdiary.sqlite'));
  if (direct.existsSync()) return direct.path;
  final nested = File(p.join(root, 'db', 'mdiary.sqlite'));
  if (nested.existsSync()) return nested.path;
  return null;
}

void _loadSqlite3() {
  if (!Platform.isWindows) return;
  final fromEnv = Platform.environment['MDIARY_SQLITE_DLL'];
  final candidates = <String>[
    ?fromEnv,
    'sqlite3.dll',
    'build/windows/x64/runner/Release/sqlite3.dll',
    'build/windows/x64/runner/Debug/sqlite3.dll',
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) {
      open.overrideFor(
        OperatingSystem.windows,
        () => DynamicLibrary.open(File(candidate).absolute.path),
      );
      return;
    }
  }
}

const String _usage = '''
每日语义管理（增量索引 + 摘要）

  dart run tool/rag_daily.dart --root <库目录> [--force] [--skip-index] [--fake]

参数：
  --root <dir>         库目录（含 mdiary.sqlite）或数据目录（含 db/mdiary.sqlite）
  --force              今天跑过也强制再跑一遍
  --skip-index         跳过索引，只补摘要
  --fake               用假模型，不联网（自检）
  --model <name>       摘要模型，默认 qwen3:8b
  --embed-model <name> 向量模型，默认 bge-m3
  --base-url <url>     Ollama 地址，默认 http://127.0.0.1:11434
  --json               以 JSON 输出
  --verbose            输出索引与 job 详情
''';

class _Options {
  _Options({
    this.root,
    this.force = false,
    this.skipIndex = false,
    this.fake = false,
    this.json = false,
    this.verbose = false,
    this.model = 'qwen3:8b',
    this.embedModel = 'bge-m3',
    this.baseUrl = 'http://127.0.0.1:11434',
  });

  final String? root;
  final bool force;
  final bool skipIndex;
  final bool fake;
  final bool json;
  final bool verbose;
  final String model;
  final String embedModel;
  final String baseUrl;

  static _Options parse(List<String> args) {
    String? root;
    var force = false;
    var skipIndex = false;
    var fake = false;
    var json = false;
    var verbose = false;
    var model = 'qwen3:8b';
    var embedModel = 'bge-m3';
    var baseUrl = 'http://127.0.0.1:11434';

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      String next() {
        if (i + 1 >= args.length) throw StateError('$arg 缺少参数');
        return args[++i];
      }

      switch (arg) {
        case '--root':
          root = next();
        case '--model':
          model = next();
        case '--embed-model':
          embedModel = next();
        case '--base-url':
          baseUrl = next();
        case '--force':
          force = true;
        case '--skip-index':
          skipIndex = true;
        case '--fake':
          fake = true;
        case '--json':
          json = true;
        case '--verbose':
          verbose = true;
        case '--help':
        case '-h':
          throw StateError(_usage);
        default:
          throw StateError('未知参数：$arg');
      }
    }
    return _Options(
      root: root,
      force: force,
      skipIndex: skipIndex,
      fake: fake,
      json: json,
      verbose: verbose,
      model: model,
      embedModel: embedModel,
      baseUrl: baseUrl,
    );
  }
}
