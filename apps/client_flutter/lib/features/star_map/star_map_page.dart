import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../state/app_scope.dart';
import 'cosmos_layout.dart';
import 'star_map_layout.dart';
import 'cosmos_painter.dart';

/// 星图（v2.6）：星座 ↔ 星云 ↔ 星系 的连续缩放。
///
/// - 周 / 月：每天一颗星，连成星座；附件绕所属日记星旋转；
/// - 年：每月一个星团，星团之间连线；
/// - 全部：每年一团星云，组成星系；
/// - 滚轮缩放、拖拽平移、双击复位、点星打开日记。
class StarMapPage extends StatefulWidget {
  const StarMapPage({super.key});

  /// 测试里关掉循环动画，避免 pumpAndSettle 永远等不到静止。
  static bool disableAnimations = false;

  @override
  State<StarMapPage> createState() => _StarMapPageState();
}

class _StarMapPageState extends State<StarMapPage>
    with SingleTickerProviderStateMixin {
  StarPeriod _period = StarPeriod.month;
  Offset _pan = Offset.zero;
  String? _tag;

  late final AnimationController _phase = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 12),
  );

  @override
  void initState() {
    super.initState();
    if (!StarMapPage.disableAnimations) _phase.repeat();
  }

  @override
  void dispose() {
    _phase.dispose();
    super.dispose();
  }

  StarPeriod _zoomIn(StarPeriod current) => switch (current) {
    StarPeriod.all => StarPeriod.year,
    StarPeriod.year => StarPeriod.month,
    StarPeriod.month => StarPeriod.week,
    StarPeriod.week => StarPeriod.week,
  };

  StarPeriod _zoomOut(StarPeriod current) => switch (current) {
    StarPeriod.week => StarPeriod.month,
    StarPeriod.month => StarPeriod.year,
    StarPeriod.year => StarPeriod.all,
    StarPeriod.all => StarPeriod.all,
  };

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final theme = Theme.of(context);
    final all = state.allEntries;
    final entries = _tag == null
        ? all
        : all
              .where((entry) => state.tagsOf(entry.id).contains(_tag))
              .toList(growable: false);
    final attachments = state.allAttachments;

    return Scaffold(
      backgroundColor: const Color(0xFF05070F),
      appBar: AppBar(
        title: Text(
          '星图',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.92)),
        ),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        actions: <Widget>[
          if (state.allTags.isNotEmpty)
            PopupMenuButton<String?>(
              tooltip: '按标签筛选',
              icon: const Icon(Icons.filter_alt_outlined, size: 20),
              onSelected: (value) => setState(() => _tag = value),
              itemBuilder: (menuContext) => <PopupMenuEntry<String?>>[
                const PopupMenuItem<String?>(value: null, child: Text('全部')),
                for (final tag in state.allTags)
                  PopupMenuItem<String?>(value: tag, child: Text(tag)),
              ],
            ),
          IconButton(
            tooltip: '复位',
            icon: const Icon(Icons.fit_screen_outlined, size: 20),
            onPressed: () => setState(() => _pan = Offset.zero),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                '${entries.length} 篇 · ${attachments.length} 个附件',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Colors.white.withValues(alpha: 0.55),
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
                  foregroundColor: WidgetStatePropertyAll<Color>(
                    Color(0xFFCFE0FF),
                  ),
                ),
                segments: const <ButtonSegment<StarPeriod>>[
                  ButtonSegment<StarPeriod>(value: StarPeriod.week, label: Text('周')),
                  ButtonSegment<StarPeriod>(value: StarPeriod.month, label: Text('月')),
                  ButtonSegment<StarPeriod>(value: StarPeriod.year, label: Text('年')),
                  ButtonSegment<StarPeriod>(value: StarPeriod.all, label: Text('全部')),
                ],
                selected: <StarPeriod>{_period},
                onSelectionChanged: (selection) => setState(() {
                  _period = selection.first;
                  _pan = Offset.zero;
                }),
              ),
            ),
          ),
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          final layout = buildCosmosLayout(
            entries: entries,
            attachments: attachments,
            period: _period,
            size: size,
          );
          return Listener(
            onPointerSignal: (event) {
              if (event is! PointerScrollEvent) return;
              final next = event.scrollDelta.dy < 0
                  ? _zoomIn(_period)
                  : _zoomOut(_period);
              if (next == _period) return;
              setState(() {
                _period = next;
                _pan = Offset.zero;
              });
            },
            child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (details) =>
                setState(() => _pan += details.delta),
            onTapUp: (details) {
              final hit = layout.hitTest(details.localPosition - _pan);
              final entry = hit?.entry;
              if (entry == null) return;
              Navigator.of(context).pop(entry);
            },
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: ClipRect(
                    child: AnimatedBuilder(
                      animation: _phase,
                      builder: (context, _) => Transform.translate(
                        offset: _pan,
                        child: CustomPaint(
                          key: const Key('star-map-canvas'),
                          size: size,
                          painter: CosmosPainter(
                            layout: layout,
                            phase: _phase.value,
                            scheme: theme.colorScheme,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 20,
                  bottom: 16,
                  child: Text(
                    '滚轮缩放 · 拖拽平移 · 点星打开',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.35),
                    ),
                  ),
                ),
                Positioned(
                  right: 20,
                  bottom: 16,
                  child: Text(
                    '${_period.label}视图',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.35),
                    ),
                  ),
                ),
              ],
            ),
            ),
          );
        },
      ),
    );
  }
}
