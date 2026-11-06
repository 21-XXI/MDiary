// 灵魂档案（2.0.6）命令行：生成/查看 `rag/soul.md`。
//
// 用法：
//   dart run tool/rag_soul.dart --root <库目录>            # 到期才重新生成
//   dart run tool/rag_soul.dart --root <库目录> --force     # 强制重写
//   dart run tool/rag_soul.dart --root <库目录> --show      # 只打印现有内容
//   dart run tool/rag_soul.dart --root <库目录> --fake      # 不连模型
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
import 'package:mdiary/rag/soul_job.dart';
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
    final job = SoulJob(
      rag: ragService.database,
      entries: entries,
      tags: tags,
      attachments: attachments,
      summarizer: summarizer,
    );

    if (options.show) {
      final text = job.read();
      if (text == null) {
        stderr.writeln('还没有 soul.md，先去掉 --show 生成一次。');
        return 1;
      }
      stdout.writeln(text);
      return 0;
    }

    if (!options.fake && !await summarizer.isAvailable()) {
      stderr.writeln(
        '连不上 ${options.baseUrl} 或没有模型 ${summarizer.modelId}；'
        '会退化成统计版（也可加 --fake 自检）。',
      );
    }

    final report = options.force
        ? await job.generate(force: true)
        : await job.runIfDue();
    if (options.json) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(report.toJson()));
    } else {
      stdout.writeln(report);
    }
    return 0;
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
灵魂档案（2.0.6）—— `rag/soul.md`

  dart run tool/rag_soul.dart --root <库目录> [--force] [--show] [--fake]

参数：
  --root <dir>     库目录（含 mdiary.sqlite）或数据目录（含 db/mdiary.sqlite）
  --force          强制重新生成（默认 7 天或新增 20 篇才重生成）
  --show           只打印现有 soul.md
  --fake           用假模型（自检）
  --model <name>   模型，默认 qwen3:8b
  --base-url <url> Ollama 地址，默认 http://127.0.0.1:11434
  --json           以 JSON 输出
''';

class _Options {
  _Options({
    this.root,
    this.force = false,
    this.show = false,
    this.fake = false,
    this.json = false,
    this.model = 'qwen3:8b',
    this.baseUrl = 'http://127.0.0.1:11434',
  });

  final String? root;
  final bool force;
  final bool show;
  final bool fake;
  final bool json;
  final String model;
  final String baseUrl;

  static _Options parse(List<String> args) {
    String? root;
    var force = false;
    var show = false;
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
        case '--model':
          model = next();
        case '--base-url':
          baseUrl = next();
        case '--force':
          force = true;
        case '--show':
          show = true;
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
      force: force,
      show: show,
      fake: fake,
      json: json,
      model: model,
      baseUrl: baseUrl,
    );
  }
}
