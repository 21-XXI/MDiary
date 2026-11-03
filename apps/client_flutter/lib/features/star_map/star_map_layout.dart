import 'dart:math' as math;
import 'dart:ui';

import '../../data/models.dart';

/// 星图的时间分组方式。
enum StarPeriod { all, year, month, week }

extension StarPeriodInfo on StarPeriod {
  String get label => switch (this) {
    StarPeriod.all => '全部',
    StarPeriod.year => '年',
    StarPeriod.month => '月',
    StarPeriod.week => '周',
  };
}

/// 星图里被点中的对象。
sealed class StarHit {
  const StarHit();
}

class StarEntryHit extends StarHit {
  const StarEntryHit(this.entry);

  final Entry entry;
}

class StarAttachmentHit extends StarHit {
  const StarAttachmentHit({
    required this.sha256,
    required this.filename,
    required this.refCount,
  });

  final String sha256;
  final String filename;
  final int refCount;
}

/// 一颗「日记星」。
class StarEntryStar {
  const StarEntryStar(this.entry, this.center);

  final Entry entry;
  final Offset center;
}

/// 一颗「附件星」：同一个附件被多篇日记索引时只有一颗，`refCount > 1`。
class StarAttachmentStar {
  const StarAttachmentStar({
    required this.sha256,
    required this.filename,
    required this.center,
    required this.refCount,
  });

  final String sha256;
  final String filename;
  final Offset center;
  final int refCount;

  bool get shared => refCount > 1;
}

/// 一条索引关系：日记 -> 附件。
class StarLine {
  const StarLine({required this.from, required this.to, required this.shared});

  final Offset from;
  final Offset to;
  final bool shared;
}

/// 分组标题（全部 / 2026 年 / 2026 年 11 月 / 2026 年第 45 周）。
class StarBucketLabel {
  const StarBucketLabel({required this.label, required this.position});

  final String label;
  final Offset position;
}

/// 一屏星图的完整几何信息：只做计算、不碰 IO，方便单测。
class StarMap {
  const StarMap({
    required this.entries,
    required this.attachments,
    required this.lines,
    required this.buckets,
    required this.width,
    required this.height,
  });

  final List<StarEntryStar> entries;
  final List<StarAttachmentStar> attachments;
  final List<StarLine> lines;
  final List<StarBucketLabel> buckets;
  final double width;
  final double height;

  int get sharedAttachmentCount =>
      attachments.where((star) => star.shared).length;

  /// 命中测试：先看日记（星更大更好点），再看附件。
  StarHit? hitTest(Offset point, {double entryRadius = 14, double attachmentRadius = 9}) {
    StarEntryStar? bestEntry;
    var bestDistance = entryRadius;
    for (final star in entries) {
      final distance = (star.center - point).distance;
      if (distance <= bestDistance) {
        bestEntry = star;
        bestDistance = distance;
      }
    }
    if (bestEntry != null) return StarEntryHit(bestEntry.entry);

    StarAttachmentStar? bestAttachment;
    var bestAttachmentDistance = attachmentRadius;
    for (final star in attachments) {
      final distance = (star.center - point).distance;
      if (distance <= bestAttachmentDistance) {
        bestAttachment = star;
        bestAttachmentDistance = distance;
      }
    }
    if (bestAttachment != null) {
      return StarAttachmentHit(
        sha256: bestAttachment.sha256,
        filename: bestAttachment.filename,
        refCount: bestAttachment.refCount,
      );
    }
    return null;
  }
}

const double _columnWidth = 250;
const double _rowHeight = 156;
const int _columns = 3;
const double _padding = 40;
const double _bucketHeader = 36;

/// 把日记与附件排成星图。
///
/// 同一个附件（sha256 相同）无论被多少篇日记索引，只画一颗星，并连出多条线 ——
/// 这就是「一个附件索引多个 .md」的可视化。
StarMap buildStarMap({
  required List<Entry> entries,
  required List<Attachment> attachments,
  required StarPeriod period,
}) {
  final groups = <DateTime, List<Entry>>{};
  for (final entry in entries) {
    groups.putIfAbsent(_bucketStart(entry.entryDate, period), () => <Entry>[]).add(entry);
  }
  final starts = groups.keys.toList()..sort();

  final entryStars = <StarEntryStar>[];
  final positions = <String, Offset>{};
  final buckets = <StarBucketLabel>[];
  var y = _padding;
  var maxRight = 0.0;

  for (final start in starts) {
    final list = groups[start]!
      ..sort((a, b) {
        final byDate = a.entryDate.compareTo(b.entryDate);
        return byDate != 0 ? byDate : a.createdAt.compareTo(b.createdAt);
      });
    buckets.add(
      StarBucketLabel(
        label: _bucketLabel(start, period),
        position: Offset(_padding, y + 16),
      ),
    );
    final rows = (list.length / _columns).ceil();
    for (var i = 0; i < list.length; i++) {
      final column = i % _columns;
      final row = i ~/ _columns;
      final center = Offset(
        _padding + column * _columnWidth + _columnWidth / 2,
        y + _bucketHeader + 46 + row * _rowHeight,
      );
      entryStars.add(StarEntryStar(list[i], center));
      positions[list[i].id] = center;
      maxRight = math.max(maxRight, center.dx + _columnWidth / 2);
    }
    y += _bucketHeader + rows * _rowHeight + 16;
  }

  // 同一个 sha 只画一颗附件星。
  final bySha = <String, List<Attachment>>{};
  for (final attachment in attachments) {
    if (!positions.containsKey(attachment.entryId)) continue;
    bySha.putIfAbsent(attachment.sha256, () => <Attachment>[]).add(attachment);
  }

  final attachmentStars = <StarAttachmentStar>[];
  final lines = <StarLine>[];
  final singles = <String, List<Attachment>>{};
  final sharedBySha = <String, List<Attachment>>{};
  for (final entry in bySha.entries) {
    final entryIds = entry.value.map((a) => a.entryId).toSet();
    if (entryIds.length > 1) {
      sharedBySha[entry.key] = entry.value;
    } else {
      singles.putIfAbsent(entry.value.first.entryId, () => <Attachment>[]).add(
        entry.value.first,
      );
    }
  }

  // 只被一篇日记索引的附件：绕在日记星旁边的小卫星。
  for (final entry in singles.entries) {
    final center = positions[entry.key]!;
    final list = entry.value;
    for (var i = 0; i < list.length; i++) {
      final angle = -math.pi / 2 + (i - (list.length - 1) / 2) * 0.44;
      final point = center + Offset(math.cos(angle), math.sin(angle)) * 42;
      attachmentStars.add(
        StarAttachmentStar(
          sha256: list[i].sha256,
          filename: list[i].filename,
          center: point,
          refCount: 1,
        ),
      );
      lines.add(StarLine(from: center, to: point, shared: false));
      maxRight = math.max(maxRight, point.dx);
    }
  }

  // 被多篇日记索引的附件：放在这些日记的重心上方，连线到每一篇。
  var sharedIndex = 0;
  for (final entry in sharedBySha.entries) {
    final refs = entry.value;
    final entryIds = refs.map((a) => a.entryId).toSet().toList()..sort();
    var centroid = Offset.zero;
    for (final id in entryIds) {
      centroid += positions[id]!;
    }
    centroid /= entryIds.length.toDouble();
    final point = centroid +
        Offset((sharedIndex % 3 - 1) * 22, -78 - (sharedIndex ~/ 3) * 20);
    sharedIndex++;
    attachmentStars.add(
      StarAttachmentStar(
        sha256: entry.key,
        filename: refs.first.filename,
        center: point,
        refCount: entryIds.length,
      ),
    );
    for (final id in entryIds) {
      lines.add(StarLine(from: positions[id]!, to: point, shared: true));
    }
    maxRight = math.max(maxRight, point.dx);
  }

  return StarMap(
    entries: entryStars,
    attachments: attachmentStars,
    lines: lines,
    buckets: buckets,
    width: math.max(maxRight + _padding, 640),
    height: math.max(y + _padding, 480),
  );
}

/// 分桶起点：年 -> 1 月 1 日；月 -> 1 号；周 -> 周一；全部 -> 纪元。
DateTime _bucketStart(DateTime date, StarPeriod period) {
  final day = DateTime(date.year, date.month, date.day);
  switch (period) {
    case StarPeriod.all:
      return DateTime.fromMillisecondsSinceEpoch(0);
    case StarPeriod.year:
      return DateTime(day.year);
    case StarPeriod.month:
      return DateTime(day.year, day.month);
    case StarPeriod.week:
      return day.subtract(Duration(days: day.weekday - 1));
  }
}

String _bucketLabel(DateTime start, StarPeriod period) {
  switch (period) {
    case StarPeriod.all:
      return '全部日记';
    case StarPeriod.year:
      return '${start.year} 年';
    case StarPeriod.month:
      return '${start.year} 年 ${start.month.toString().padLeft(2, '0')} 月';
    case StarPeriod.week:
      // ISO 周跨年时按「那一周所属的年」显示（12 月 29 日可能属于下一年的第 1 周）。
      final thursday = start.add(const Duration(days: 3));
      return '${thursday.year} 年第 '
          '${isoWeekNumber(start).toString().padLeft(2, '0')} 周';
  }
}

/// ISO 8601 周号（周一为一周第一天，含 1 月 4 日的那周为第 1 周）。
int isoWeekNumber(DateTime date) {
  final day = DateTime(date.year, date.month, date.day);
  final thursday = day.add(Duration(days: 4 - day.weekday));
  final januaryFourth = DateTime(thursday.year, 1, 4);
  final firstThursday = januaryFourth.add(
    Duration(days: 4 - januaryFourth.weekday),
  );
  return 1 + thursday.difference(firstThursday).inDays ~/ 7;
}
