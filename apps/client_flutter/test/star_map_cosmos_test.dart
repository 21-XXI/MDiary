import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdiary/data/models.dart';
import 'package:mdiary/features/star_map/cosmos_layout.dart';
import 'package:mdiary/features/star_map/star_map_layout.dart';

/// v2.6：星图几何（星座 / 星云 / 命中）。
void main() {
  Entry entry(int day, {String? id, int words = 100}) => Entry(
    id: id ?? 'e-$day',
    title: '第 $day 天',
    bodyMd: '正' * words,
    entryDate: DateTime(2026, 11, day),
    createdAt: DateTime(2026, 11, day),
    updatedAt: DateTime(2026, 11, day),
    rev: 1,
    pinned: false,
    deviceId: 'd',
  );

  Attachment attachment(String entryId, String sha) => Attachment(
    id: 'a-$sha',
    entryId: entryId,
    sha256: sha,
    filename: '$sha.png',
    mime: 'image/png',
    sizeBytes: 3,
    createdAt: DateTime(2026, 11, 1),
  );

  const size = Size(1200, 800);

  test('周视图：7 个槽位、连续连线、附件轨道', () {
    final entries = <Entry>[entry(2), entry(4), entry(6)];
    final layout = buildCosmosLayout(
      entries: entries,
      attachments: <Attachment>[attachment('e-4', 'a' * 64)],
      period: StarPeriod.week,
      size: size,
    );
    expect(layout.stars, hasLength(7));
    expect(layout.stars.where((s) => s.hollow).length, 4);
    expect(layout.links, hasLength(6));
    expect(layout.orbits, hasLength(1), reason: '只有 11-04 有附件');
    expect(layout.clusters, isEmpty);
  });

  test('月视图：按当月天数排布，空格也有暗点', () {
    final layout = buildCosmosLayout(
      entries: <Entry>[entry(1), entry(15)],
      attachments: const <Attachment>[],
      period: StarPeriod.month,
      size: size,
    );
    expect(layout.stars, hasLength(30), reason: '2026 年 11 月 30 天');
    expect(layout.stars.where((s) => !s.hollow), hasLength(2));
    expect(layout.links.length, lessThan(29), reason: '空白日不连线');
  });

  test('年视图：12 个星团，星团连线成环', () {
    final layout = buildCosmosLayout(
      entries: <Entry>[entry(1), entry(15), entry(20, id: 'e-20')],
      attachments: const <Attachment>[],
      period: StarPeriod.year,
      size: size,
    );
    expect(layout.clusters, hasLength(12));
    expect(layout.links, hasLength(12));
    expect(layout.stars, hasLength(3));
    expect(layout.clusters.first.label, '1 月');
  });

  test('全部视图：按年分组，每年一个星团', () {
    final layout = buildCosmosLayout(
      entries: <Entry>[
        entry(1),
        Entry(
          id: 'old',
          title: '旧年',
          bodyMd: 'x',
          entryDate: DateTime(2024, 5, 1),
          createdAt: DateTime(2024, 5, 1),
          updatedAt: DateTime(2024, 5, 1),
          rev: 1,
          pinned: false,
          deviceId: 'd',
        ),
      ],
      attachments: const <Attachment>[],
      period: StarPeriod.all,
      size: size,
    );
    expect(layout.clusters.map((c) => c.label), <String>['2024', '2026']);
    expect(layout.stars, hasLength(2));
  });

  test('同一天位置稳定（确定性布局）', () {
    final first = buildCosmosLayout(
      entries: <Entry>[entry(3)],
      attachments: const <Attachment>[],
      period: StarPeriod.month,
      size: size,
    );
    final second = buildCosmosLayout(
      entries: <Entry>[entry(3)],
      attachments: const <Attachment>[],
      period: StarPeriod.month,
      size: size,
    );
    expect(first.stars[2].center, second.stars[2].center);
  });

  test('命中测试：点星星返回日记，点空白返回 null', () {
    final layout = buildCosmosLayout(
      entries: <Entry>[entry(5)],
      attachments: const <Attachment>[],
      period: StarPeriod.month,
      size: size,
    );
    final star = layout.stars.firstWhere((s) => s.entry != null);
    expect(layout.hitTest(star.center)?.entry?.id, star.entry!.id);
    expect(layout.hitTest(const Offset(1, 1)), isNull);
  });
}
