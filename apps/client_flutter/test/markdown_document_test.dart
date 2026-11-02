import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/data/markdown_document.dart';

void main() {
  group('front matter 解析', () {
    test('标准 front matter 被解析为 meta + body', () {
      const content =
          '---\n'
          'title: 杭州三日\n'
          'date: 2026-03-14\n'
          'tags: [旅行, 杭州]\n'
          '---\n'
          '\n'
          '# 第一天\n'
          '西湖下雨。\n';
      final doc = parseMarkdownDocument(content);
      expect(doc.title, '杭州三日');
      expect(doc.date, DateTime(2026, 3, 14));
      expect(doc.tags, <String>['旅行', '杭州']);
      expect(doc.body.startsWith('# 第一天'), isTrue);
    });

    test('没有 front matter 时整篇作为正文', () {
      final doc = parseMarkdownDocument('# 标题\n正文');
      expect(doc.meta, isEmpty);
      expect(doc.title, isNull);
      expect(doc.body, '# 标题\n正文');
    });

    test('front matter 未闭合时不吞掉正文', () {
      final doc = parseMarkdownDocument('---\ntitle: x\n正文还在');
      expect(doc.meta, isEmpty);
      expect(doc.body.contains('正文还在'), isTrue);
    });

    test('BOM 与 CRLF 会被规范化', () {
      final doc = parseMarkdownDocument(
        '\uFEFF---\r\ntitle: t\r\n---\r\n正文\r\n',
      );
      expect(doc.title, 't');
      expect(doc.body.contains('\r'), isFalse);
    });

    test('带引号的 title 会去掉引号', () {
      final doc = parseMarkdownDocument('---\ntitle: "带: 冒号"\n---\n正文');
      expect(doc.title, '带: 冒号');
    });
  });

  group('文档生成', () {
    test('build 与 parse 往返一致', () {
      final text = buildMarkdownDocument(
        title: '雨天',
        date: DateTime(2026, 11, 2),
        tags: <String>['日记'],
        body: '# 雨天\n\n今天下雨。\n',
      );
      final doc = parseMarkdownDocument(text);
      expect(doc.title, '雨天');
      expect(doc.date, DateTime(2026, 11, 2));
      expect(doc.tags, <String>['日记']);
      expect(doc.body.contains('今天下雨。'), isTrue);
    });

    test('标题含冒号时加引号且可还原', () {
      final text = buildMarkdownDocument(
        title: 'A: B',
        date: DateTime(2026, 1, 2),
        body: '正文',
      );
      final doc = parseMarkdownDocument(text);
      expect(doc.title, 'A: B');
    });
  });

  group('文件名', () {
    test('非法字符被替换，日期前缀正确', () {
      final name = safeFileName(DateTime(2026, 11, 2), 'a/b:c*d?"e"<f>|g');
      expect(name, startsWith('2026-11-02-'));
      expect(name, endsWith('.md'));
      for (final ch in <String>['/', ':', '*', '?', '"', '<', '>', '|']) {
        expect(name.contains(ch), isFalse, reason: '不应包含 $ch');
      }
    });

    test('空标题回落为“无标题”', () {
      final name = safeFileName(DateTime(2026, 1, 1), '   ');
      expect(name, '2026-01-01-无标题.md');
    });

    test('超长标题被截断且不以点结尾', () {
      final name = safeFileName(DateTime(2026, 1, 1), '${'长' * 200}...');
      expect(name.length, lessThan(90));
      expect(name.endsWith('...md'), isFalse);
      expect(name.endsWith('.md'), isTrue);
    });
  });

  group('引用改写', () {
    test('本地引用被改写为 assets/<hash>', () {
      final body = '![图](./images/pic.png) 以及 [文件](docs/a.pdf)';
      final rewritten = rewriteLocalReferences(
        body,
        (ref) => ref.endsWith('.png') ? 'abc123' : null,
      );
      expect(rewritten.contains('![图](assets/abc123)'), isTrue);
      expect(rewritten.contains('[文件](docs/a.pdf)'), isTrue);
    });

    test('网络引用保持原样', () {
      final body = '![x](https://example.com/a.png)';
      final rewritten = rewriteLocalReferences(
        body,
        (ref) => 'should-not-be-used',
      );
      expect(rewritten, body);
    });

    test('提取本地引用会忽略 http/data', () {
      final body =
          '![a](assets/1.png) ![b](https://x/y.png) ![c](data:image/png;base64,AA)';
      final refs = extractLocalReferences(body);
      expect(refs, <String>{'assets/1.png'});
    });
  });

  group('日期解析', () {
    test('支持 iso 与 年月日分隔', () {
      expect(parseDate('2026-03-04'), DateTime(2026, 3, 4));
      expect(parseDate('2026/3/4'), DateTime(2026, 3, 4));
      expect(parseDate('2026.03.04'), DateTime(2026, 3, 4));
      expect(parseDate('2026-03-04T10:00:00'), DateTime(2026, 3, 4, 10));
      expect(parseDate('乱写'), isNull);
      expect(parseDate(null), isNull);
      expect(parseDate('2026-13-40'), isNull);
    });
  });
}
