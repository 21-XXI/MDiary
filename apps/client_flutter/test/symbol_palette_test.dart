import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/ui/symbol_palette.dart';

void main() {
  group('insertSymbol', () {
    test('在光标处插入，并选中占位符', () {
      final controller = TextEditingController(text: 'abc');
      controller.selection = const TextSelection.collapsed(offset: 3);
      insertSymbol(
        controller,
        const SymbolItem('粗体', '**', suffix: '**', placeholder: '粗体'),
      );
      expect(controller.text, 'abc**粗体**');
      expect(
        controller.selection.baseOffset,
        5,
        reason: '占位符应被选中，方便直接输入',
      );
      expect(controller.selection.extentOffset, 7);
    });

    test('有选区时包裹选区文字', () {
      final controller = TextEditingController(text: '重点内容');
      controller.selection = const TextSelection(baseOffset: 0, extentOffset: 2);
      insertSymbol(
        controller,
        const SymbolItem('粗体', '**', suffix: '**', placeholder: '粗体'),
      );
      expect(controller.text, '**重点**内容');
      expect(controller.selection.baseOffset, 2);
      expect(controller.selection.extentOffset, 4);
    });

    test('纯符号直接插入', () {
      final controller = TextEditingController(text: 'A');
      controller.selection = const TextSelection.collapsed(offset: 1);
      insertSymbol(controller, const SymbolItem('α', 'α'));
      expect(controller.text, 'Aα');
      expect(controller.selection.baseOffset, 2);
    });
  });

  testWidgets('符号面板点一下插入到控制器', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showSymbolPalette(context, controller),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('符号与公式'), findsOneWidget);

    await tester.tap(find.widgetWithText(ActionChip, '分数'));
    await tester.pump();
    expect(controller.text, contains(r'\frac{'));
  });
}
