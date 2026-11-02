import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/core/formatters.dart';

void main() {
  group('countCharacters', () {
    test('忽略空白，中文按字计', () {
      expect(countCharacters('你好 世界'), 4);
      expect(countCharacters('a b\nc'), 3);
      expect(countCharacters('   '), 0);
    });
  });

  group('deriveTitleFromBody', () {
    test('取首个非空行并剥离 # 标记', () {
      expect(deriveTitleFromBody('\n\n## 今天下雨\n正文'), '今天下雨');
    });

    test('空正文回落', () {
      expect(deriveTitleFromBody('   \n\n'), '无标题');
    });

    test('超长行截断加省略号', () {
      final title = deriveTitleFromBody('字' * 100);
      expect(title.endsWith('…'), isTrue);
      expect(title.length, lessThanOrEqualTo(61));
    });
  });

  group('formatBytes', () {
    test('单位换算', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(2048), '2.0 KB');
      expect(formatBytes(5 * 1024 * 1024), '5.0 MB');
    });
  });

  group('formatDate', () {
    test('补零', () {
      expect(formatDate(DateTime(2026, 1, 5)), '2026-01-05');
      expect(formatDateTime(DateTime(2026, 1, 5, 7, 9)), '2026-01-05 07:09');
    });
  });

  group('formatRelative', () {
    final now = DateTime(2026, 11, 2, 12, 0);

    test('今天显示时间', () {
      expect(formatRelative(DateTime(2026, 11, 2, 9, 5), now: now), '09:05');
    });

    test('昨天带前缀', () {
      expect(formatRelative(DateTime(2026, 11, 1, 9, 5), now: now), startsWith('昨天'));
    });

    test('一周内显示天数', () {
      expect(formatRelative(DateTime(2026, 10, 30, 9, 5), now: now), '3 天前');
    });

    test('更早显示日期', () {
      expect(formatRelative(DateTime(2026, 1, 1), now: now), '2026-01-01');
    });
  });
}
