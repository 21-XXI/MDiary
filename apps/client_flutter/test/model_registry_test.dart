@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/data/attachment_repository.dart';
import 'package:mdiary/data/attachment_store.dart';
import 'package:mdiary/data/database.dart';
import 'package:mdiary/data/entry_repository.dart';
import 'package:mdiary/data/markdown_io.dart';
import 'package:mdiary/data/meta_repository.dart';
import 'package:mdiary/data/tag_repository.dart';
import 'package:mdiary/rag/model_registry.dart';
import 'package:mdiary/rag/rag_settings.dart';
import 'package:mdiary/state/app_state.dart';
import 'package:path/path.dart' as p;

/// v2.7 第一步：统一模型管理（配置 + 角色）。
void main() {
  test('旧设置迁移成配置与角色', () {
    const settings = RagSettings(askModel: 'qwen3:4b', embedModel: 'bge-m3');
    final registry = ModelRegistry.migration(settings);
    expect(registry.profiles, isNotEmpty);
    expect(
      registry.profileFor(ModelRole.chat)?.model,
      'qwen3:4b',
    );
    expect(
      registry.profileFor(ModelRole.embed)?.model,
      'bge-m3',
    );
    expect(
      registry.profileFor(ModelRole.memory)?.model,
      'qwen3:4b',
    );
  });

  test('JSON 往返保留配置与角色', () {
    const registry = ModelRegistry(
      profiles: <ModelProfile>[
        ModelProfile(
          id: 'a',
          name: '本地',
          provider: 'ollama',
          baseUrl: 'http://127.0.0.1:11434',
          model: 'qwen3:8b',
        ),
        ModelProfile(
          id: 'b',
          name: '云端',
          provider: 'openai',
          baseUrl: 'https://api.openai.com/v1',
          model: 'gpt-4o-mini',
          apiKeyCipher: 'dpapi:x',
        ),
      ],
      roleProfiles: <ModelRole, String>{
        ModelRole.chat: 'a',
        ModelRole.memory: 'b',
      },
    );
    final decoded = jsonDecode(jsonEncode(registry.toJson()));
    final loaded = ModelRegistry.fromJson(decoded as Map<String, dynamic>);
    expect(loaded.profiles, hasLength(2));
    expect(loaded.profileFor(ModelRole.chat)?.name, '本地');
    expect(loaded.profileFor(ModelRole.memory)?.isCloud, isTrue);
  });

  test('删除配置会清掉引用它的角色', () {
    const registry = ModelRegistry(
      profiles: <ModelProfile>[
        ModelProfile(
          id: 'a',
          name: 'A',
          provider: 'ollama',
          baseUrl: 'x',
          model: 'm',
        ),
      ],
      roleProfiles: <ModelRole, String>{ModelRole.chat: 'a'},
    );
    final next = registry.withoutProfile('a');
    expect(next.profiles, isEmpty);
    expect(next.profileFor(ModelRole.chat), isNull);
  });

  group('AppState 持久化', () {
    late Directory sandbox;
    late AppDatabase db;
    late File modelsFile;
    late AppState state;

    setUp(() async {
      sandbox = Directory.systemTemp.createTempSync('mdiary_models_');
      modelsFile = File(p.join(sandbox.path, 'models.json'));
      db = AppDatabase.inMemory();
      state = _stateFor(db, sandbox, modelsFile);
      await state.bootstrap();
    });

    tearDown(() {
      state.dispose();
      db.dispose();
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    });

    test('首次启动自动迁移并写入 models.json', () {
      expect(modelsFile.existsSync(), isTrue);
      expect(state.modelRegistry.profiles, isNotEmpty);
      expect(state.profileFor(ModelRole.chat), isNotNull);
    });

    test('改角色/新增配置后重新打开仍在', () async {
      final profile = ModelProfile(
        id: 'custom',
        name: '自定义',
        provider: 'openai',
        baseUrl: 'https://example.com/v1',
        model: 'm',
        apiKeyCipher: 'dpapi:x',
      );
      state.upsertModelProfile(profile);
      state.setRoleProfile(ModelRole.memory, 'custom');
      expect(state.profileFor(ModelRole.memory)?.id, 'custom');

      final second = _stateFor(db, sandbox, modelsFile);
      await second.bootstrap();
      expect(second.modelRegistry.byId('custom')?.name, '自定义');
      expect(second.profileFor(ModelRole.memory)?.id, 'custom');
      second.dispose();
    });
  });
}

AppState _stateFor(AppDatabase db, Directory sandbox, File modelsFile) {
  final entries = EntryRepository(db);
  final attachments = AttachmentRepository(db);
  final store = AttachmentStore(
    Directory(p.join(sandbox.path, 'attachments')),
    blobs: attachments,
  );
  return AppState(
    db: db,
    entryRepo: entries,
    attachmentRepo: attachments,
    metaRepo: MetaRepository(db),
    tagRepository: TagRepository(db),
    store: store,
    markdownIo: MarkdownIo(
      entries: entries,
      attachments: attachments,
      store: store,
      tags: TagRepository(db),
    ),
    filePicker: () async => null,
    directoryPicker: (title) async => null,
    dataRootPath: sandbox.path,
    ragSettingsStore: RagSettingsStore(path: p.join(sandbox.path, 'settings.json')),
    modelRegistryStore: ModelRegistryStore(path: modelsFile.path),
  );
}
