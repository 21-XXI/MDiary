import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/ui/markdown_extras.dart';
import 'package:mdiary/ui/markdown_view.dart';

void main() {
  group('分段', () {
    test('块级公式与 Mermaid 被拆出来', () {
      const source = '''
前面

\$\$
E = mc^2
\$\$

中间 \$a+b\$

```mermaid
graph TD
A --> B
```

结尾
''';
      final segments = splitMarkdownSegments(source);
      expect(segments.any((s) => s.math != null), isTrue);
      expect(segments.any((s) => s.mermaid != null), isTrue);
      expect(
        segments.firstWhere((s) => s.math != null).math,
        contains('mc^2'),
      );
      expect(
        segments.firstWhere((s) => s.mermaid != null).mermaid,
        contains('A --> B'),
      );
      expect(
        segments.where((s) => s.text != null).map((s) => s.text).join(),
        contains('中间'),
      );
    });

    test('单行 \$\$x\$\$ 与普通文本', () {
      final segments = splitMarkdownSegments(r'前 $$x^2$$ 后');
      final math = segments.firstWhere((segment) => segment.math != null);
      expect(math.math, 'x^2');
      expect(
        segments.where((segment) => segment.text != null).length,
        2,
        reason: '公式前后的文字各自成段',
      );
    });
  });

  testWidgets('预览渲染行内公式、块级公式与 Mermaid 卡片', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MarkdownView(
              data: '质能方程 \$E=mc^2\$。\n\n\$\$\n\\frac{a}{b}\n\$\$\n\n'
                  '```mermaid\ngraph TD\nA --> B\n```\n',
              resolveLocalPath: (_) => null,
              padding: EdgeInsets.zero,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Math), findsWidgets, reason: '行内与块级公式都要渲染');
    expect(find.byType(MermaidCard), findsOneWidget);
    expect(find.textContaining('graph TD'), findsOneWidget);
  });
}
