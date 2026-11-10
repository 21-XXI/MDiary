import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/rag/skill_job.dart';

/// 蒸馏提示词与 skills/diary-distiller/SKILL.md 同步。
void main() {
  test('提示词包含 skill 的六节结构与资料分层规则', () {
    final skillFile = File('../../skills/diary-distiller/SKILL.md');
    expect(skillFile.existsSync(), isTrue, reason: 'skill 文件应存在');
    final skill = skillFile.readAsStringSync();
    final prompt = CloudSkillDistiller.buildPrompt(soul: 'soul', digest: 'digest');
    for (final key in <String>[
      '资料分层',
      '主文件事实',
      '附加笔记细节',
      '不确定项',
      '[主',
      '[附',
      '禁止事项',
    ]) {
      expect(skill, contains(key), reason: 'SKILL.md 缺少 $key');
      expect(prompt, contains(key), reason: '提示词缺少 $key');
    }
  });
}