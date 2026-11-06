// RAG 索引/检索的本地命令行工具（2.0.1 的验收入口，也方便 agent 调用）。
//
// 用法：
//   dart run tool/rag_search.dart --root <库目录> --reindex [--force]
//   dart run tool/rag_search.dart --root <库目录> "去年在杭州" [--k 8] [--json]
//
// `--root` 可以是库目录（里面有 mdiary.sqlite），也可以是数据目录（里面有 db/mdiary.sqlite）。
// 没有本地 Ollama 时加 `--fake-embedder` 做离线自检（向量质量差，只验证链路）。
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
import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';

Future<void> main(List<String> args) async {
  try {
    exitCode = await _run(args);
  } on EmbedderUnavailable catch (error) {
    stderr.writeln('本地模型不可用：$error');
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
  final libraryRoot = p.dirname(dbFile) == p.join(root, 'db')
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

  final embedder = options.fakeEmbedder
      ? HashingEmbedder()
      : OllamaEmbedder(baseUrl: options.baseUrl, model: options.model);

  final service = RagService.open(
    libraryRoot: libraryRoot,
    entries: entries,
    attachments: attachments,
    tags: tags,
    store: store,
    embedder: embedder,
  );

  try {
    if (options.reindex) {
      if (embedder is OllamaEmbedder && !await embedder.isAvailable()) {
        stderr.writeln(
          '连不上 ${options.baseUrl} 或没有模型 ${options.model}。'
          '先 `ollama pull ${options.model}`，或用 --fake-embedder 自检。',
        );
        return 2;
      }
      final report = await service.reindex(
        force: options.force,
        onProgress: (progress) {
          if (options.verbose && progress.done % 10 == 0) {
            stderr.writeln(
              '[${progress.done}/${progress.total}] ${progress.label}',
            );
          }
        },
      );
      stdout.writeln(report);
      for (final error in report.errors.take(5)) {
        stdout.writeln('  - $error');
      }
      if (options.onlyReindex) return 0;
    }

    final query = options.query;
    if (query == null || query.trim().isEmpty) {
      stdout.writeln(jsonEncode(service.stats().toJson()));
      return 0;
    }

    final hits = await service.search(query, k: options.k);
    if (options.json) {
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          'query': query,
          'hits': <Object?>[for (final hit in hits) hit.toJson()],
        }),
      );
    } else {
      if (hits.isEmpty) {
        stdout.writeln('没有命中。');
      }
      for (var i = 0; i < hits.length; i++) {
        final hit = hits[i];
        final kind = hit.isAttachment ? '附件' : '日记';
        stdout.writeln(
          '${i + 1}. [$kind] ${ChunkerDate.format(hit.date)} '
          '《${hit.label}》  score=${hit.score.toStringAsFixed(4)}',
        );
        stdout.writeln('   ${hit.snippet}');
      }
    }
    return 0;
  } finally {
    service.close();
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
RAG 索引 / 检索

  dart run tool/rag_search.dart --root <库目录> --reindex [--force] [--fake-embedder]
  dart run tool/rag_search.dart --root <库目录> "查询词" [--k 8] [--json]

参数：
  --root <dir>        库目录（含 mdiary.sqlite）或数据目录（含 db/mdiary.sqlite）
  --reindex           建立/更新索引（增量；--force 全量）
  --query <text>      查询（也可以直接把查询词放最后）
  --k <n>             返回条数，默认 8
  --json              以 JSON 输出
  --fake-embedder     用本地哈希向量，不联网（只验证链路）
  --model <name>      Ollama 模型名，默认 bge-m3
  --base-url <url>    Ollama 地址，默认 http://127.0.0.1:11434
  --verbose           进度输出
''';

class _Options {
  _Options({
    this.root,
    this.query,
    this.k = 8,
    this.reindex = false,
    this.force = false,
    this.onlyReindex = false,
    this.json = false,
    this.fakeEmbedder = false,
    this.model = 'bge-m3',
    this.baseUrl = 'http://127.0.0.1:11434',
    this.verbose = false,
  });

  final String? root;
  final String? query;
  final int k;
  final bool reindex;
  final bool force;
  final bool onlyReindex;
  final bool json;
  final bool fakeEmbedder;
  final String model;
  final String baseUrl;
  final bool verbose;

  static _Options parse(List<String> args) {
    String? root;
    String? query;
    var k = 8;
    var reindex = false;
    var force = false;
    var json = false;
    var fake = false;
    var verbose = false;
    var model = 'bge-m3';
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
        case '--query':
          query = next();
        case '--k':
          k = int.tryParse(next()) ?? 8;
        case '--model':
          model = next();
        case '--base-url':
          baseUrl = next();
        case '--reindex':
          reindex = true;
        case '--force':
          force = true;
        case '--json':
          json = true;
        case '--fake-embedder':
          fake = true;
        case '--verbose':
          verbose = true;
        case '--help':
        case '-h':
          throw StateError(_usage);
        default:
          if (arg.startsWith('-')) throw StateError('未知参数：$arg');
          query = arg;
      }
    }

    return _Options(
      root: root,
      query: query,
      k: k,
      reindex: reindex,
      force: force,
      onlyReindex: reindex && query == null,
      json: json,
      fakeEmbedder: fake,
      model: model,
      baseUrl: baseUrl,
      verbose: verbose,
    );
  }
}
