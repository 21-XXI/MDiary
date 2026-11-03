import 'package:flutter/material.dart';

import '../../core/formatters.dart';
import '../../data/attachment_store.dart';
import '../../data/models.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../../ui/widgets.dart';
import 'star_map_layout.dart';

/// 星图：把「日记（.md）」和它索引的附件画成星空。
///
/// - 大星 = 一篇日记，旁边的小星 = 它索引的附件；
/// - 同一个附件被多篇日记索引时只有一颗星，连线指向每一篇（存储只存一份）；
/// - 顶部可按 全部 / 年 / 月 / 周 分组浏览；
/// - 点日记星 -> 回到主界面打开它；点附件星 -> 用系统默认程序打开。
class StarMapPage extends StatefulWidget {
  const StarMapPage({super.key});

  @override
  State<StarMapPage> createState() => _StarMapPageState();
}

class _StarMapPageState extends State<StarMapPage> {
  StarPeriod _period = StarPeriod.month;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final entries = state.allEntries;
    final attachments = state.allAttachments;
    final map = buildStarMap(
      entries: entries,
      attachments: attachments,
      period: _period,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('星图'),
        centerTitle: false,
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                '${map.entries.length} 篇 · ${map.attachments.length} 个附件'
                '${map.sharedAttachmentCount > 0 ? '（${map.sharedAttachmentCount} 个共用）' : ''}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: SegmentedButton<StarPeriod>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                segments: <ButtonSegment<StarPeriod>>[
                  for (final period in StarPeriod.values)
                    ButtonSegment<StarPeriod>(
                      value: period,
                      label: Text(period.label),
                    ),
                ],
                selected: <StarPeriod>{_period},
                onSelectionChanged: (selection) =>
                    setState(() => _period = selection.first),
              ),
            ),
          ),
        ),
      ),
      body: entries.isEmpty
          ? const EmptyState(
              icon: Icons.hub_outlined,
              title: '星图还是空的',
              description: '先写一篇日记，它的附件会出现在这里',
            )
          : Stack(
              children: <Widget>[
                Positioned.fill(
                  child: InteractiveViewer(
                    constrained: false,
                    minScale: 0.3,
                    maxScale: 2.5,
                    boundaryMargin: const EdgeInsets.all(240),
                    child: SizedBox(
                      width: map.width,
                      height: map.height,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (details) =>
                            _handleTap(state, map, details.localPosition),
                        child: CustomPaint(
                          painter: _StarMapPainter(
                            map: map,
                            entryColor: theme.colorScheme.primary,
                            attachmentColor: theme.colorScheme.tertiary,
                            sharedColor: theme.colorScheme.secondary,
                            lineColor: theme.colorScheme.outlineVariant,
                            labelColor: theme.colorScheme.onSurface,
                            bucketColor: theme.colorScheme.onSurfaceVariant,
                            surface: theme.colorScheme.surface,
                            titleOf: _titleOf,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 16,
                  bottom: 12,
                  child: Text(
                    '● 日记    ● 附件    连线 = 这篇日记索引了该附件（多条线 = 共用）'
                    '    拖拽可平移，滚轮可缩放',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Future<void> _handleTap(AppState state, StarMap map, Offset point) async {
    final hit = map.hitTest(point);
    if (hit == null) return;
    switch (hit) {
      case StarEntryHit(:final entry):
        if (!mounted) return;
        Navigator.of(context).pop(entry);
      case StarAttachmentHit(:final sha256, :final filename):
        final path = state.store.pathFor(sha256, normalizeExtension(filename));
        if (path == null) {
          if (mounted) {
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(content: Text('附件文件已不在磁盘上：$filename')),
              );
          }
          return;
        }
        await state.openInSystem(path);
    }
  }

  static String _titleOf(Entry entry) {
    final title = entry.title.trim();
    if (title.isNotEmpty) return title;
    final body = entry.bodyMd.trim();
    if (body.isEmpty) return formatDate(entry.entryDate);
    final line = body.split('\n').first.trim();
    return line.length > 14 ? '${line.substring(0, 14)}…' : line;
  }
}

class _StarMapPainter extends CustomPainter {
  _StarMapPainter({
    required this.map,
    required this.entryColor,
    required this.attachmentColor,
    required this.sharedColor,
    required this.lineColor,
    required this.labelColor,
    required this.bucketColor,
    required this.surface,
    required this.titleOf,
  });

  final StarMap map;
  final Color entryColor;
  final Color attachmentColor;
  final Color sharedColor;
  final Color lineColor;
  final Color labelColor;
  final Color bucketColor;
  final Color surface;
  final String Function(Entry entry) titleOf;

  @override
  void paint(Canvas canvas, Size size) {
    _paintBuckets(canvas);
    _paintLines(canvas);
    _paintAttachments(canvas);
    _paintEntries(canvas);
  }

  void _paintBuckets(Canvas canvas) {
    for (final bucket in map.buckets) {
      _text(
        canvas,
        bucket.label,
        TextAlign.left,
        bucket.position,
        TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: bucketColor),
        maxWidth: 320,
      );
    }
  }

  void _paintLines(Canvas canvas) {
    final normal = Paint()
      ..color = lineColor.withValues(alpha: 0.45)
      ..strokeWidth = 1;
    final shared = Paint()
      ..color = sharedColor.withValues(alpha: 0.55)
      ..strokeWidth = 1.6;
    for (final line in map.lines) {
      canvas.drawLine(line.from, line.to, line.shared ? shared : normal);
    }
  }

  void _paintAttachments(Canvas canvas) {
    for (final star in map.attachments) {
      if (star.shared) {
        canvas.drawCircle(
          star.center,
          9,
          Paint()
            ..color = sharedColor.withValues(alpha: 0.18)
            ..style = PaintingStyle.fill,
        );
        canvas.drawCircle(
          star.center,
          9,
          Paint()
            ..color = sharedColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4,
        );
      }
      canvas.drawCircle(
        star.center,
        star.shared ? 5 : 4,
        Paint()..color = star.shared ? sharedColor : attachmentColor,
      );
      if (star.shared) {
        _text(
          canvas,
          '${star.filename} ×${star.refCount}',
          TextAlign.center,
          star.center + const Offset(0, 20),
          TextStyle(fontSize: 10, color: sharedColor),
          maxWidth: 150,
        );
      }
    }
  }

  void _paintEntries(Canvas canvas) {
    for (final star in map.entries) {
      canvas.drawCircle(
        star.center,
        14,
        Paint()..color = entryColor.withValues(alpha: 0.12),
      );
      canvas.drawCircle(
        star.center,
        10,
        Paint()..color = entryColor.withValues(alpha: 0.22),
      );
      canvas.drawCircle(star.center, 6.5, Paint()..color = entryColor);
      canvas.drawCircle(
        star.center,
        6.5,
        Paint()
          ..color = surface
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
      _text(
        canvas,
        titleOf(star.entry),
        TextAlign.center,
        star.center + const Offset(0, 18),
        TextStyle(fontSize: 11, color: labelColor),
        maxWidth: 150,
      );
    }
  }

  void _text(
    Canvas canvas,
    String value,
    TextAlign align,
    Offset anchor,
    TextStyle style, {
    required double maxWidth,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: value, style: style),
      textAlign: align,
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    final dx = align == TextAlign.center
        ? anchor.dx - painter.width / 2
        : anchor.dx;
    painter.paint(canvas, Offset(dx, anchor.dy - painter.height / 2));
  }

  @override
  bool shouldRepaint(covariant _StarMapPainter oldDelegate) =>
      oldDelegate.map != map || oldDelegate.entryColor != entryColor;
}
