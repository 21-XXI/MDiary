// 日报（2.0.5）命令行：生成/补全 `rag/reports/YYYY-MM-DD.md`。
//
// 用法：
//   dart run tool/rag_report.dart --root <库目录>                 # 补齐到昨天
//   dart run tool/rag_report.dart --root <库目录> --date 2026-11-05
//   dart run tool/rag_report.dart --root <库目录> --force
//   dart run tool/rag_report.dart --root <库目录> --fake          # 不连模型
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';

import 'package:mdiary/data/attachment_repository.dart';
import 'package:mdiary/data/attachment_store.dart';
import 'package:mdiary/data/database.dart';
import 'package:mdiary/data/entry_repository.dart';
import 'package:mdiary/data/tag_repository.dart';
import 'package:mdiary/rag/embedder.dart';
import 'package:mdiary/rag/rag_service.dart';
import 'package:mdiary/rag/report_job.dart';
import 'package:mdiary/rag/summarizer.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';

Future<void> main(List<String> args) async {
  try {
    exitCode = await _run(args);
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

  final ragService = RagService.open(
    libraryRoot: libraryRoot,
    entries: entries,
    attachments: attachments,
    tags: tags,
    store: store,
    embedder: options.fake
        ? HashingEmbedder()
        : OllamaEmbedder(baseUrl: options.baseUrl),
  );

  try {
    final job = DailyReportJob(
      rag: ragService.database,
      entries: entries,
      attachments: attachments,
      summarizer: summarizer,
    );

    if (options.date != null) {
      final date = _parseDate(options.date!);
      final result = await job.generate(
        date,
        force: options.force,
        allowModel: !options.noModel,
      );
      if (result.skipped) {
        stdout.writeln('${DailyReportJob.dateKey(date)} 已有日报，跳过（--force 覆盖）');
      } else {
        stdout.writeln(
          '已生成 ${DailyReportJob.dateKey(date)} 日报'
          '（模型：${result.model.isEmpty ? '离线骨架' : result.model}）',
        );
        if (result.error != null) stdout.writeln('  备注：${result.error}');
      }
      stdout.writeln(_filePath(result.date, libraryRoot));
      return 0;
    }

    final run = options.force
        ? await job.backfill(force: true)
        : await job.runIfDue();
    if (options.json) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(run.toJson()));
    } else {
      stdout.writeln(run);
      for (final error in run.errors.take(10)) {
        stdout.writeln('  - $error');
      }
      final dates = job.reportDates();
      if (dates.isNotEmpty) {
        stdout.writeln('最近日报：${dates.take(5).map(DailyReportJob.dateKey).join('、')}');
      }
    }
    return run.ok ? 0 : 3;
  } finally {
    ragService.close();
    db.dispose();
  }
}

String _filePath(DateTime date, String libraryRoot) => p.join(
  libraryRoot,
  'rag',
  'reports',
  '${DailyReportJob.dateKey(date)}.md',
);

DateTime _parseDate(String text) {
  final parts = text.split('-');
  if (parts.length != 3) throw StateError('日期格式应为 YYYY-MM-DD：$text');
  return DateTime(
    int.parse(parts[0]),
    int.parse(parts[1]),
    int.parse(parts[2]),
  );
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
日报（2.0.5）

  dart run tool/rag_report.dart --root <库目录> [--date YYYY-MM-DD] [--force] [--fake]

参数：
  --root <dir>     库目录（含 mdiary.sqlite）或数据目录（含 db/mdiary.sqlite）
  --date <date>    只生成某一天；不传则补齐到昨天
  --force          已有日报也重新生成
  --no-model       只写离线骨架，不调用模型
  --fake           用假模型（自检）
  --model <name>   摘要/日报模型，默认 qwen3:8b
  --base-url <url> Ollama 地址，默认 http://127.0.0.1:11434
  --json           以 JSON 输出
''';

class _Options {
  _Options({
    this.root,
    this.date,
    this.force = false,
    this.noModel = false,
    this.fake = false,
    this.json = false,
    this.model = 'qwen3:8b',
    this.baseUrl = 'http://127.0.0.1:11434',
  });

  final String? root;
  final String? date;
  final bool force;
  final bool noModel;
  final bool fake;
  final bool json;
  final String model;
  final String baseUrl;

  static _Options parse(List<String> args) {
    String? root;
    String? date;
    var force = false;
    var noModel = false;
    var fake = false;
    var json = false;
    var model = 'qwen3:8b';
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
        case '--date':
          date = next();
        case '--model':
          model = next();
        case '--base-url':
          baseUrl = next();
        case '--force':
          force = true;
        case '--no-model':
          noModel = true;
        case '--fake':
          fake = true;
        case '--json':
          json = true;
        case '--help':
        case '-h':
          throw StateError(_usage);
        default:
          throw StateError('未知参数：$arg');
      }
    }
    return _Options(
      root: root,
      date: date,
      force: force,
      noModel: noModel,
      fake: fake,
      json: json,
      model: model,
      baseUrl: baseUrl,
    );
  }
}
