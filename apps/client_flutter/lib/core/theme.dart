import 'package:flutter/material.dart';

/// 主题与排版常量。中文优先字体，缺字回落到系统无衬线。
class AppTheme {
  AppTheme._();

  static const Color seed = Color(0xFF4C6A92);

  static const List<String> uiFontFallback = <String>[
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'Segoe UI',
    'Noto Sans CJK SC',
  ];

  static const List<String> monoFontFallback = <String>[
    'Cascadia Mono',
    'Consolas',
    'Microsoft YaHei UI',
    'Menlo',
  ];

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      visualDensity: VisualDensity.standard,
    );
    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      textTheme: base.textTheme.apply(fontFamilyFallback: uiFontFallback),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.5),
        thickness: 1,
        space: 1,
      ),
      tooltipTheme: const TooltipThemeData(
        waitDuration: Duration(milliseconds: 400),
      ),
    );
  }

  /// 编辑器正文样式（等宽，便于对齐 Markdown 结构）。
  static TextStyle editorStyle(double fontSize, Color color) {
    return TextStyle(
      fontFamily: 'Cascadia Mono',
      fontFamilyFallback: monoFontFallback,
      fontSize: fontSize,
      height: 1.6,
      color: color,
    );
  }
}
