@TestOn('windows')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/data/models.dart';
import 'package:mdiary/features/star_map/star_map_layout.dart';

Entry _entry(String id, DateTime date, {String title = '', String body = ''}) {
  return Entry(
    id: id,
    title: title,
    bodyMd: body,
    entryDate: date,
    createdAt: date,
    updatedAt: date,
    rev: 1,
    pinned: false,
    deviceId: 'dev',
  );
}

Attachment _attachment({
  required String id,
  required String entryId,
  required String sha,
  String filename = 'shot.png',
}) {
  return Attachment(
    id: id,
    entryId: entryId,
    sha256: sha,
    filename: filename,
    mime: 'image/png',
    sizeBytes: 3,
    createdAt: DateTime(2026, 11, 1),
  );
}

void main() {
  test('按月分组：两个月两个标题，坐标都落在画布内', () {
    final map = buildStarMap(
      entries: <Entry>[
        _entry('a', DateTime(2026, 10, 2)),
        _entry('b', DateTime(2026, 10, 9)),
        _entry('c', DateTime(2026, 11, 1)),
      ],
      attachments: const <Attachment>[],
      period: StarPeriod.month,
    );

    expect(map.buckets.map((b) => b.label), <String>[
      '2026 年 10 月',
      '2026 年 11 月',
    ]);
    expect(map.entries, hasLength(3));
    for (final star in map.entries) {
      expect(star.center.dx, greaterThan(0));
      expect(star.center.dx, lessThan(map.width));
      expect(star.center.dy, lessThan(map.height));
    }
    // 10 月的两颗星排在同一行，11 月的在下面
    expect(map.entries[0].center.dy, map.entries[1].center.dy);
    expect(map.entries[2].center.dy, greaterThan(map.entries[0].center.dy));
  });

  test('按年 / 全部 / 周分组', () {
    final entries = <Entry>[
      _entry('a', DateTime(2025, 12, 29)), // 属于 2026 年第 1 周
      _entry('b', DateTime(2026, 1, 5)),
      _entry('c', DateTime(2026, 3, 1)),
    ];

    final byYear = buildStarMap(
      entries: entries,
      attachments: const <Attachment>[],
      period: StarPeriod.year,
    );
    expect(byYear.buckets.map((b) => b.label), <String>['2025 年', '2026 年']);

    final all = buildStarMap(
      entries: entries,
      attachments: const <Attachment>[],
      period: StarPeriod.all,
    );
    expect(all.buckets.single.label, '全部日记');

    final byWeek = buildStarMap(
      entries: entries,
      attachments: const <Attachment>[],
      period: StarPeriod.week,
    );
    expect(byWeek.buckets.first.label, '2026 年第 01 周');
    expect(byWeek.buckets, hasLength(3));
  });

  test('同一个附件被两篇日记索引：只画一颗星，两条连线', () {
    final map = buildStarMap(
      entries: <Entry>[
        _entry('a', DateTime(2026, 11, 1)),
        _entry('b', DateTime(2026, 11, 2)),
      ],
      attachments: <Attachment>[
        _attachment(id: 'x', entryId: 'a', sha: 'deadbeef'),
        _attachment(id: 'y', entryId: 'b', sha: 'deadbeef'),
      ],
      period: StarPeriod.month,
    );

    expect(map.attachments, hasLength(1), reason: '同 sha 只画一颗');
    expect(map.attachments.single.refCount, 2);
    expect(map.attachments.single.shared, isTrue);
    expect(map.sharedAttachmentCount, 1);
    expect(map.lines, hasLength(2));
    expect(map.lines.every((line) => line.shared), isTrue);
  });

  test('不同附件各自一颗星，不共享', () {
    final map = buildStarMap(
      entries: <Entry>[
        _entry('a', DateTime(2026, 11, 1)),
        _entry('b', DateTime(2026, 11, 2)),
      ],
      attachments: <Attachment>[
        _attachment(id: 'x', entryId: 'a', sha: 'aaa'),
        _attachment(id: 'y', entryId: 'b', sha: 'bbb'),
      ],
      period: StarPeriod.month,
    );

    expect(map.attachments, hasLength(2));
    expect(map.sharedAttachmentCount, 0);
    expect(map.lines, hasLength(2));
    expect(map.lines.any((line) => line.shared), isFalse);
  });

  test('同一篇日记的多个附件围绕它排布', () {
    final map = buildStarMap(
      entries: <Entry>[_entry('a', DateTime(2026, 11, 1))],
      attachments: <Attachment>[
        _attachment(id: 'x', entryId: 'a', sha: 'aaa', filename: 'a.png'),
        _attachment(id: 'y', entryId: 'a', sha: 'bbb', filename: 'b.png'),
        _attachment(id: 'z', entryId: 'a', sha: 'ccc', filename: 'c.png'),
      ],
      period: StarPeriod.month,
    );

    expect(map.attachments, hasLength(3));
    final centers = map.attachments.map((a) => a.center).toSet();
    expect(centers, hasLength(3), reason: '三颗星不能重叠在同一个点');
  });

  test('命中最靠近的日记星 / 附件星 / 空白处返回 null', () {
    final map = buildStarMap(
      entries: <Entry>[_entry('a', DateTime(2026, 11, 1), title: '第一篇')],
      attachments: <Attachment>[
        _attachment(id: 'x', entryId: 'a', sha: 'aaa', filename: 'a.png'),
      ],
      period: StarPeriod.month,
    );

    final entryStar = map.entries.single;
    final hit = map.hitTest(entryStar.center + const Offset(3, 2));
    expect(hit, isA<StarEntryHit>());
    expect((hit! as StarEntryHit).entry.id, 'a');

    final attachmentStar = map.attachments.single;
    final attachmentHit = map.hitTest(attachmentStar.center);
    expect(attachmentHit, isA<StarAttachmentHit>());
    expect((attachmentHit! as StarAttachmentHit).filename, 'a.png');

    expect(map.hitTest(entryStar.center + const Offset(200, 200)), isNull);
  });

  test('没有日记时画布仍有最小尺寸', () {
    final map = buildStarMap(
      entries: const <Entry>[],
      attachments: const <Attachment>[],
      period: StarPeriod.week,
    );
    expect(map.entries, isEmpty);
    expect(map.buckets, isEmpty);
    expect(map.width, greaterThan(0));
    expect(map.height, greaterThan(0));
  });

  test('ISO 周号：跨年那一周算到下一年第 1 周', () {
    expect(isoWeekNumber(DateTime(2026, 1, 1)), 1);
    expect(isoWeekNumber(DateTime(2026, 1, 5)), 2);
    expect(isoWeekNumber(DateTime(2025, 12, 29)), 1);
    expect(isoWeekNumber(DateTime(2026, 11, 2)), 45);
  });
}
