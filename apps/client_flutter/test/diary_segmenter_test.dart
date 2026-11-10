import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/rag/diary_segmenter.dart';

/// v2.7：分词计划解析（模型 JSON → 天/附件/警告）。
void main() {
  test('解析合法 JSON 并按日期排序', () {
    const raw = '''
```json
{"days":[
 {"date":"2026-11-07","title":"返程","body":"下午回家。","tags":["工作"]},
 {"date":"2026-11-06","title":"杭州","body":"去了西湖。","attachments":["西湖.png"],"tags":["旅行"]}
]}
```
''';
    final plan = DiarySegmenter.parsePlan(
      raw,
      availableAttachments: <String>{'西湖.png'},
    );
    expect(plan.days, hasLength(2));
    expect(plan.days.first.date, DateTime(2026, 11, 6));
    expect(plan.days.first.attachments, <String>['西湖.png']);
    expect(plan.days.last.title, '返程');
    expect(plan.warnings, isEmpty);
  });

  test('缺少日期/正文的天被跳过并记警告', () {
    const raw = '{"days":[{"date":"2026-11-06","body":""},'
        '{"date":"11/06","body":"x"},'
        '{"date":"2026-11-08","body":"ok"}]}';
    final plan = DiarySegmenter.parsePlan(raw);
    expect(plan.days, hasLength(1));
    expect(plan.warnings, hasLength(2));
  });

  test('重复日期只保留第一篇', () {
    const raw = '{"days":['
        '{"date":"2026-11-06","body":"a"},'
        '{"date":"2026-11-06","body":"b"}]}';
    final plan = DiarySegmenter.parsePlan(raw);
    expect(plan.days, hasLength(1));
    expect(plan.days.single.body, 'a');
    expect(plan.warnings.single, contains('重复'));
  });

  test('资料里没有的附件被丢弃并警告', () {
    const raw = '{"days":[{"date":"2026-11-06","body":"x",'
        '"attachments":["不存在.png"]}]}';
    final plan = DiarySegmenter.parsePlan(
      raw,
      availableAttachments: <String>{'西湖.png'},
    );
    expect(plan.days.single.attachments, isEmpty);
    expect(plan.warnings.single, contains('不存在.png'));
  });

  test('非 JSON 直接报错', () {
    expect(
      () => DiarySegmenter.parsePlan('我觉得应该分成三天'),
      throwsA(isA<SegmenterException>()),
    );
  });

  test('没有 days 或全空也报错', () {
    expect(
      () => DiarySegmenter.parsePlan('{"foo":1}'),
      throwsA(isA<SegmenterException>()),
    );
    expect(
      () => DiarySegmenter.parsePlan('{"days":[]}'),
      throwsA(isA<SegmenterException>()),
    );
  });
}
