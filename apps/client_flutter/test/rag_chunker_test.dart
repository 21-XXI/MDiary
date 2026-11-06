import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/rag/chunker.dart';

void main() {
  group('Markdown 切片', () {
    test('按标题分节，切片里带章节路径', () {
      final chunker = MarkdownChunker(targetTokens: 120, maxTokens: 200);
      final chunks = chunker.chunkEntry(
        entryId: 'e1',
        title: '杭州',
        date: DateTime(2026, 11, 5),
        body: '开头一段。\n\n# 第一天\n\n去了西湖。\n\n## 晚上\n\n吃了片儿川。',
        tags: <String>['旅行'],
      );

      expect(chunks, isNotEmpty);
      expect(chunks.every((c) => c.entryId == 'e1'), isTrue);
      expect(chunks.any((c) => c.headingPath == '第一天'), isTrue);
      expect(chunks.any((c) => c.headingPath == '第一天 > 晚上'), isTrue);
      expect(chunks.first.text, contains('《杭州》2026-11-05'));
      expect(chunks.first.text, contains('标签：旅行'));
      expect(chunks.first.tokens, greaterThan(0));
    });

    test('代码块不被空行切开', () {
      final chunker = MarkdownChunker(targetTokens: 80, maxTokens: 100);
      final chunks = chunker.chunkEntry(
        entryId: 'e2',
        title: '代码',
        date: DateTime(2026, 11, 5),
        body: '说明\n\n```dart\nvoid main() {\n\n  print(1);\n\n}\n```\n\n结尾',
      );
      final code = chunks.firstWhere((c) => c.text.contains('void main'));
      expect(code.text, contains('print(1);'));
      expect(code.text, contains('```'));
    });

    test('超长段落会被切开，且都带上下文前缀', () {
      final chunker = MarkdownChunker(targetTokens: 40, maxTokens: 60);
      final long = List<String>.generate(40, (i) => '第 $i 行内容，写满一点。').join('\n');
      final chunks = chunker.chunkEntry(
        entryId: 'e3',
        title: '长文',
        date: DateTime(2026, 11, 5),
        body: long,
      );
      expect(chunks.length, greaterThan(1));
      for (final chunk in chunks) {
        expect(chunk.text, contains('《长文》'));
        expect(chunk.tokens, lessThanOrEqualTo(120), reason: '前缀另算，但不该离谱');
      }
    });

    test('空正文也留一条切片，便于按标题/日期检索', () {
      final chunker = MarkdownChunker();
      final chunks = chunker.chunkEntry(
        entryId: 'e4',
        title: '空白的一天',
        date: DateTime(2026, 11, 5),
        body: '',
      );
      expect(chunks, hasLength(1));
      expect(chunks.single.text, contains('空白的一天'));
      expect(chunks.single.text, contains('（空）'));
    });

    test('附件切片包含元数据与抽取文本', () {
      final chunker = MarkdownChunker();
      final chunks = chunker.chunkAttachment(
        attachmentId: 'a1',
        entryId: 'e1',
        filename: '发票.txt',
        mime: 'text/plain',
        sizeBytes: 2048,
        entryTitle: '出差',
        date: DateTime(2026, 11, 5),
        extractedText: '住宿费 380 元',
      );
      expect(chunks.single.kind, 'attachment');
      expect(chunks.single.attachmentId, 'a1');
      expect(chunks.single.text, contains('发票.txt'));
      expect(chunks.single.text, contains('住宿费 380 元'));
      expect(chunks.single.label, '发票.txt');
    });

    test('token 估算：中文按字、英文按 4 字符', () {
      expect(MarkdownChunker.estimateTokens('你好世界'), 4);
      expect(MarkdownChunker.estimateTokens('hello world'), lessThan(4));
      expect(MarkdownChunker.estimateTokens(''), 0);
    });
  });
}
