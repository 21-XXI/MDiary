import 'dart:io';

import 'package:flutter/material.dart';

import 'app.dart';
import 'core/app_logger.dart';
import 'core/app_paths.dart';
import 'data/attachment_repository.dart';
import 'data/attachment_store.dart';
import 'data/database.dart';
import 'data/entry_repository.dart';
import 'data/markdown_io.dart';
import 'data/meta_repository.dart';
import 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppLogger? logger;
  try {
    await AppPaths.init();
    logger = AppLogger(resolveLogFile(AppPaths.root.path))..install();
    final resolution = AppPaths.resolution;
    if (resolution != null && resolution.isFallback) {
      // 数据目录被换过位置，日志里必须留痕，否则用户会以为日记丢了。
      logger.log(
        'Startup',
        '默认数据目录不可写，本次改用 ${resolution.path}\n'
        '原因：${resolution.fallbackReason}',
      );
    }

    final db = AppDatabase.openDefault();
    final store = AttachmentStore(AppPaths.attachmentsDir);
    await store.directory.create(recursive: true);

    final entryRepo = EntryRepository(db);
    final attachmentRepo = AttachmentRepository(db);
    final metaRepo = MetaRepository(db);

    final state = AppState(
      db: db,
      entryRepo: entryRepo,
      attachmentRepo: attachmentRepo,
      metaRepo: metaRepo,
      store: store,
      markdownIo: MarkdownIo(
        entries: entryRepo,
        attachments: attachmentRepo,
        store: store,
      ),
      dataRootPath: AppPaths.root.path,
      dataRootNotice: AppPaths.fallbackReason,
    );
    await state.bootstrap();
    runApp(MDiaryApp(state: state));
  } catch (error, stack) {
    // 启动阶段的异常也要落盘，否则用户只能看到「打不开」
    final fallback = logger ?? AppLogger(resolveLogFile(''));
    fallback.log('Startup', error, stack);
    fallback.install();
    runApp(_StartupFailureApp(message: '$error', details: '$stack'));
  }
}

/// 启动失败时也要有窗口，告诉用户数据目录在哪、怎么救。
class _StartupFailureApp extends StatelessWidget {
  const _StartupFailureApp({required this.message, required this.details});

  final String message;
  final String details;

  @override
  Widget build(BuildContext context) {
    final exeDir = AppPaths.exeDirectory;
    final dataPath = exeDir != null
        ? '$exeDir\\${AppPaths.portableDirName}'
        : '${Platform.environment['APPDATA'] ?? ''}\\${AppPaths.dataDirName}';
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF4C6A92),
        useMaterial3: true,
      ),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                'MDiary 启动失败',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              SelectableText('原因：$message'),
              const SizedBox(height: 8),
              SelectableText('数据目录：$dataPath'),
              const SizedBox(height: 8),
              SelectableText('错误日志：$dataPath\\logs\\error.log'),
              const SizedBox(height: 12),
              const Text('可尝试：确认该目录可写、数据库文件未被其他程序占用（例如同时开了两个实例），再重新启动。'),
              const SizedBox(height: 8),
              const Text('若所在环境不允许写该目录（沙箱、漫游配置异常等），可设置环境变量 MDIARY_HOME 指向任意可写目录后重启。'),
              const SizedBox(height: 16),
              const Text(
                '技术详情：',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF2F2F2),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      details,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
