import 'dart:io';

/// 把 skills/diary-distiller/SKILL.md 生成为 Dart 常量，保证代码提示词与 skill 同源。
void main() {
  final skill = File('skills/diary-distiller/SKILL.md').readAsStringSync();
  final out = File('apps/client_flutter/lib/rag/skill_prompts.g.dart');
  out.writeAsStringSync(
    '// 由 skills/diary-distiller/SKILL.md 生成；不要手改，改 skill 后重跑 tool/gen_skill_prompts.dart。\n\n'
    "const String distillerSkillMarkdown = r'''\n$skill\n''';\n",
  );
  stdout.writeln('generated ${out.path}');
}