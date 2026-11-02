import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/ui/markdown_view.dart';

/// MarkdownView 是预览与附件展示的枢纽：这里验证图片引用解析、缺失提示、链接回调。
void main() {
  // 1x1 透明 PNG
  final tinyPng = Uint8List.fromList(<int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
  ]);

  late Directory tempDir;
  setUp(() => tempDir = Directory.systemTemp.createTempSync('mdiary_md_'));
  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('本地图片引用被解析为 Image 控件', (tester) async {
    final file = File('${tempDir.path}/pic.png')..writeAsBytesSync(tinyPng);
    String? requested;
    final hash = 'a' * 64;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownView(
            data: '看图：![](assets/$hash.png)',
            resolveLocalPath: (reference) {
              requested = reference;
              return file.path;
            },
          ),
        ),
      ),
    );
    await tester.pump();

    expect(requested, 'assets/$hash.png');
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('图片缺失时给出可见提示而不是空白', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownView(
            data: '![](assets/${'b' * 64}.png)',
            resolveLocalPath: (reference) => null,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('附件缺失'), findsOneWidget);
  });

  testWidgets('链接点击回调把引用交给外部处理', (tester) async {
    String? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownView(
            data: '[外部链接](https://example.com/a)',
            resolveLocalPath: (reference) => null,
            onOpenLink: (reference) => opened = reference,
          ),
        ),
      ),
    );
    await tester.tap(find.text('外部链接'));
    await tester.pumpAndSettle();

    expect(opened, 'https://example.com/a');
  });

  testWidgets('空正文显示占位文案', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MarkdownView(data: '   ', resolveLocalPath: _neverResolve),
        ),
      ),
    );
    expect(find.text('还没有内容'), findsOneWidget);
  });

  testWidgets('GFM 语法（标题/列表/引用/代码块/表格/删除线）渲染无异常', (tester) async {
    const markdown = '''
# 一级标题

## 二级标题

- 项目一
- 项目二
  - 嵌套项

1. 有序一
2. 有序二

> 引用段落
> 第二行

```dart
final x = 1;
```

| 列 A | 列 B |
|---|---|
| a1 | b1 |
| a2 | b2 |

~~删除线~~ 与 **粗体** 与 `行内代码`

---

- [x] 已完成
- [ ] 未完成
''';

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MarkdownView(data: markdown, resolveLocalPath: _neverResolve),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('一级标题'), findsOneWidget);
    expect(find.textContaining('项目一'), findsOneWidget);
    expect(find.textContaining('引用段落'), findsOneWidget);
    expect(find.textContaining('a1'), findsOneWidget);
  });
}

String? _neverResolve(String reference) => null;
