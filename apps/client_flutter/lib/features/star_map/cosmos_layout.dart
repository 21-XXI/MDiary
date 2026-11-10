import 'dart:math' as math;
import 'dart:ui';

import '../../data/models.dart';
import 'star_map_layout.dart' show StarPeriod;

/// 星图的一颗星：一篇日记，或有日记的某一天。
class CosmosStar {
  const CosmosStar({
    required this.entry,
    required this.center,
    required this.radius,
    required this.label,
    required this.hollow,
  });

  final Entry? entry;
  final Offset center;
  final double radius;
  final String label;

  /// 没有日记的日子：只画一个暗点。
  final bool hollow;
}

class CosmosLink {
  const CosmosLink({required this.from, required this.to, required this.emphasis});

  final Offset from;
  final Offset to;
  final double emphasis;
}

/// 附件绕所属日记旋转的轨道（只画，不参与命中）。
class CosmosOrbit {
  const CosmosOrbit({
    required this.center,
    required this.radius,
    required this.count,
  });

  final Offset center;
  final double radius;
  final int count;
}

/// 年 / 全部尺度下的星团（一个月或一年）。
class CosmosCluster {
  const CosmosCluster({
    required this.center,
    required this.radius,
    required this.label,
    required this.count,
    required this.seed,
  });

  final Offset center;
  final double radius;
  final String label;
  final int count;
  final int seed;
}

/// 一屏星图的几何信息；纯计算，方便单测。
class CosmosLayout {
  const CosmosLayout({
    required this.period,
    required this.stars,
    required this.links,
    required this.orbits,
    required this.clusters,
  });

  final StarPeriod period;
  final List<CosmosStar> stars;
  final List<CosmosLink> links;
  final List<CosmosOrbit> orbits;
  final List<CosmosCluster> clusters;

  CosmosStar? hitTest(Offset point, {double radius = 20}) {
    CosmosStar? best;
    var bestDistance = radius;
    for (final star in stars) {
      if (star.entry == null) continue;
      final distance = (star.center - point).distance;
      if (distance <= bestDistance) {
        best = star;
        bestDistance = distance;
      }
    }
    return best;
  }
}


/// 计算当前尺度下的星图。
CosmosLayout buildCosmosLayout({
  required List<Entry> entries,
  required List<Attachment> attachments,
  required StarPeriod period,
  required Size size,
}) {
  final width = math.max(size.width, 320.0);
  final height = math.max(size.height, 320.0);
  final center = Offset(width / 2, height / 2);
  final minSide = math.min(width, height);
  final byDate = <DateTime, List<Entry>>{};
  for (final entry in entries) {
    final day = DateTime(entry.entryDate.year, entry.entryDate.month, entry.entryDate.day);
    byDate.putIfAbsent(day, () => <Entry>[]).add(entry);
  }
  final attachmentCount = <String, int>{};
  for (final attachment in attachments) {
    attachmentCount.update(attachment.entryId, (value) => value + 1, ifAbsent: () => 1);
  }

  switch (period) {
    case StarPeriod.week:
      return _week(
        byDate: byDate,
        attachmentCount: attachmentCount,
        center: center,
        width: width,
        height: height,
      );
    case StarPeriod.month:
      return _month(
        byDate: byDate,
        attachmentCount: attachmentCount,
        center: center,
        minSide: minSide,
      );
    case StarPeriod.year:
      return _year(
        byDate: byDate,
        attachmentCount: attachmentCount,
        center: center,
        minSide: minSide,
      );
    case StarPeriod.all:
      return _all(byDate: byDate, center: center, minSide: minSide);
  }
}

DateTime _latestDay(List<DateTime> days, StarPeriod fallback) {
  if (days.isEmpty) return DateTime.now();
  days.sort();
  return days.last;
}

CosmosLayout _week({
  required Map<DateTime, List<Entry>> byDate,
  required Map<String, int> attachmentCount,
  required Offset center,
  required double width,
  required double height,
}) {
  final anchor = _latestDay(byDate.keys.toList(), StarPeriod.week);
  final monday = anchor.subtract(Duration(days: anchor.weekday - 1));
  final stars = <CosmosStar>[];
  final links = <CosmosLink>[];
  final orbits = <CosmosOrbit>[];
  final points = <Offset>[];
  for (var i = 0; i < 7; i++) {
    final day = monday.add(Duration(days: i));
    final x = width * 0.16 + i / 6 * width * 0.68;
    final y = center.dy + math.sin(i * 1.05) * height * 0.16;
    final point = Offset(x, y);
    points.add(point);
    final entries = byDate[day] ?? const <Entry>[];
    final entry = entries.isEmpty ? null : entries.first;
    final words = entries.fold<int>(0, (sum, item) => sum + item.bodyMd.length);
    stars.add(
      CosmosStar(
        entry: entry,
        center: point,
        radius: entries.isEmpty ? 2.2 : (4 + math.min(words / 240, 5)),
        label: '${_weekday(day)}\n${day.day}',
        hollow: entries.isEmpty,
      ),
    );
    if (entry != null) {
      final count = attachmentCount[entry.id] ?? 0;
      if (count > 0) {
        orbits.add(
          CosmosOrbit(
            center: point,
            radius: 26 + math.min(count, 5) * 5,
            count: math.min(count, 6),
          ),
        );
      }
    }
  }
  for (var i = 0; i < 6; i++) {
    links.add(
      CosmosLink(
        from: points[i],
        to: points[i + 1],
        emphasis: (stars[i].hollow || stars[i + 1].hollow) ? 0.25 : 0.8,
      ),
    );
  }
  return CosmosLayout(
    period: StarPeriod.week,
    stars: stars,
    links: links,
    orbits: orbits,
    clusters: const <CosmosCluster>[],
  );
}

CosmosLayout _month({
  required Map<DateTime, List<Entry>> byDate,
  required Map<String, int> attachmentCount,
  required Offset center,
  required double minSide,
}) {
  final anchor = _latestDay(byDate.keys.toList(), StarPeriod.month);
  final first = DateTime(anchor.year, anchor.month);
  final daysInMonth = DateTime(anchor.year, anchor.month + 1, 0).day;
  final stars = <CosmosStar>[];
  final links = <CosmosLink>[];
  final orbits = <CosmosOrbit>[];
  final points = <Offset>[];
  final rx = minSide * 0.30;
  final ry = minSide * 0.28;
  for (var day = 1; day <= daysInMonth; day++) {
    final date = DateTime(first.year, first.month, day);
    final angle = -math.pi / 2 + (day - 1) / daysInMonth * 2 * math.pi;
    final wobble = math.sin(day * 2.3) * 6;
    final point = center +
        Offset(math.cos(angle) * (rx + wobble), math.sin(angle) * (ry + wobble));
    points.add(point);
    final entries = byDate[date] ?? const <Entry>[];
    final entry = entries.isEmpty ? null : entries.first;
    final words = entries.fold<int>(0, (sum, item) => sum + item.bodyMd.length);
    stars.add(
      CosmosStar(
        entry: entry,
        center: point,
        radius: entries.isEmpty ? 2.0 : (3.5 + math.min(words / 260, 5)),
        label: '$day',
        hollow: entries.isEmpty,
      ),
    );
    if (entry != null) {
      final count = attachmentCount[entry.id] ?? 0;
      if (count > 0) {
        orbits.add(
          CosmosOrbit(
            center: point,
            radius: 22 + math.min(count, 5) * 4,
            count: math.min(count, 6),
          ),
        );
      }
    }
  }
  for (var i = 0; i < daysInMonth - 1; i++) {
    if (stars[i].hollow || stars[i + 1].hollow) continue;
    links.add(CosmosLink(from: points[i], to: points[i + 1], emphasis: 0.75));
  }
  return CosmosLayout(
    period: StarPeriod.month,
    stars: stars,
    links: links,
    orbits: orbits,
    clusters: const <CosmosCluster>[],
  );
}

CosmosLayout _year({
  required Map<DateTime, List<Entry>> byDate,
  required Map<String, int> attachmentCount,
  required Offset center,
  required double minSide,
}) {
  final anchor = _latestDay(byDate.keys.toList(), StarPeriod.year);
  final radius = minSide * 0.33;
  final clusters = <CosmosCluster>[];
  final stars = <CosmosStar>[];
  final links = <CosmosLink>[];
  for (var month = 1; month <= 12; month++) {
    final angle = -math.pi / 2 + (month - 1) / 12 * 2 * math.pi;
    final clusterCenter = center + Offset(math.cos(angle), math.sin(angle)) * radius;
    final monthEntries = <Entry>[];
    for (var day = 1; day <= 31; day++) {
      final date = DateTime(anchor.year, month, day);
      if (date.month != month) break;
      final list = byDate[date];
      if (list != null) monthEntries.addAll(list);
    }
    clusters.add(
      CosmosCluster(
        center: clusterCenter,
        radius: 26 + math.min(monthEntries.length, 20) * 1.4,
        label: '$month 月',
        count: monthEntries.length,
        seed: anchor.year * 100 + month,
      ),
    );
    for (var i = 0; i < monthEntries.length; i++) {
      final entry = monthEntries[i];
      final a = (i / math.max(monthEntries.length, 1)) * 2 * math.pi + month;
      final r = 8 + (i % 5) * 7.0;
      stars.add(
        CosmosStar(
          entry: entry,
          center: clusterCenter + Offset(math.cos(a) * r, math.sin(a) * r),
          radius: 2.4,
          label: '',
          hollow: false,
        ),
      );
    }
  }
  for (var i = 0; i < 12; i++) {
    final next = (i + 1) % 12;
    links.add(
      CosmosLink(
        from: clusters[i].center,
        to: clusters[next].center,
        emphasis: 0.22,
      ),
    );
  }
  return CosmosLayout(
    period: StarPeriod.year,
    stars: stars,
    links: links,
    orbits: const <CosmosOrbit>[],
    clusters: clusters,
  );
}

CosmosLayout _all({
  required Map<DateTime, List<Entry>> byDate,
  required Offset center,
  required double minSide,
}) {
  final years = <int>{for (final day in byDate.keys) day.year}.toList()..sort();
  if (years.isEmpty) years.add(DateTime.now().year);
  final clusters = <CosmosCluster>[];
  final stars = <CosmosStar>[];
  final links = <CosmosLink>[];
  final count = years.length;
  for (var i = 0; i < count; i++) {
    final t = count == 1 ? 0.5 : i / (count - 1);
    final angle = -math.pi / 2 + t * math.pi * 1.7;
    final radius = minSide * (0.10 + 0.30 * t);
    final clusterCenter = center + Offset(math.cos(angle), math.sin(angle)) * radius;
    final year = years[i];
    final yearEntries = <Entry>[
      for (final entry in byDate.entries)
        if (entry.key.year == year) ...entry.value,
    ];
    clusters.add(
      CosmosCluster(
        center: clusterCenter,
        radius: 34 + math.min(yearEntries.length, 40).toDouble(),
        label: '$year',
        count: yearEntries.length,
        seed: year,
      ),
    );
    for (var j = 0; j < yearEntries.length; j++) {
      final a = j * 2.39996;
      final r = math.sqrt(j + 1) * 7.5;
      stars.add(
        CosmosStar(
          entry: yearEntries[j],
          center: clusterCenter + Offset(math.cos(a) * r, math.sin(a) * r),
          radius: 1.8,
          label: '',
          hollow: false,
        ),
      );
    }
    if (i > 0) {
      links.add(
        CosmosLink(from: clusters[i - 1].center, to: clusterCenter, emphasis: 0.18),
      );
    }
  }
  return CosmosLayout(
    period: StarPeriod.all,
    stars: stars,
    links: links,
    orbits: const <CosmosOrbit>[],
    clusters: clusters,
  );
}

String _weekday(DateTime day) =>
    const <String>['周一', '周二', '周三', '周四', '周五', '周六', '周日'][day.weekday - 1];
