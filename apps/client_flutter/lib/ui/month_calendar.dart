import 'package:flutter/material.dart';

/// 左栏的月历：点某一天 = 打开/新建那天的日记。
///
/// 刻意不用 `CalendarDatePicker`：它是给对话框用的，最小宽度 330，
/// 塞进 240~360 宽的左栏会溢出。这里用 7 列紧凑网格（单元格 24px），
/// 有日记的日子在数字下面点一个小圆点。
class MonthCalendar extends StatelessWidget {
  const MonthCalendar({
    super.key,
    required this.month,
    required this.selectedDate,
    required this.markedDates,
    required this.today,
    required this.onSelect,
    required this.onMonthChanged,
  });

  /// 当前显示的月份（只取 year / month）。
  final DateTime month;

  /// 当前选中的那天。
  final DateTime selectedDate;

  /// 有日记的日期（小圆点）。
  final Set<DateTime> markedDates;

  /// 今天（由调用方给，测试里可以固定）。
  final DateTime today;

  final ValueChanged<DateTime> onSelect;
  final ValueChanged<DateTime> onMonthChanged;

  static const double _cellHeight = 24;
  static const List<String> _weekdayLabels = <String>[
    '一',
    '二',
    '三',
    '四',
    '五',
    '六',
    '日',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final first = DateTime(month.year, month.month);
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    // 周一开头：周一 leading 0，周日 leading 6。
    final leading = first.weekday - 1;
    final cells = <DateTime?>[
      for (var i = 0; i < leading; i++) null,
      for (var day = 1; day <= daysInMonth; day++)
        DateTime(month.year, month.month, day),
    ];
    while (cells.length % 7 != 0) {
      cells.add(null);
    }
    final rows = cells.length ~/ 7;
    final marked = markedDates.map(_key).toSet();

    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 2, 6, 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            children: <Widget>[
              _chevron(
                Icon(
                  Icons.chevron_left,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                '上个月',
                () => onMonthChanged(DateTime(month.year, month.month - 1)),
              ),
              Expanded(
                child: Text(
                  '${month.year} 年 ${month.month} 月',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelLarge,
                ),
              ),
              _chevron(
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                '下个月',
                () => onMonthChanged(DateTime(month.year, month.month + 1)),
              ),
              TextButton(
                onPressed: () => onSelect(today),
                style: TextButton.styleFrom(
                  minimumSize: const Size(30, 24),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                child: Text('今天', style: theme.textTheme.labelSmall),
              ),
            ],
          ),
          Row(
            children: <Widget>[
              for (final label in _weekdayLabels)
                Expanded(
                  child: Center(
                    child: Text(
                      label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          for (var row = 0; row < rows; row++)
            Row(
              children: <Widget>[
                for (var column = 0; column < 7; column++)
                  Expanded(
                    child: _cell(
                      context,
                      cells[row * 7 + column],
                      marked,
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  /// 自绘箭头：不用 IconButton —— 它的最小点击区域（40~48）在 240 宽的左栏里
  /// 会把月份标题挤到放不下，这里固定 28x28。
  ///
  /// 注意：[icon] 必须由调用方直接写 `Icon(Icons.xxx)`：图标树摇只认
  /// 「常量 IconData 直接出现在 Icon 构造处」，穿过参数会被当成动态图标裁掉，
  /// release 包里就会变成空白按钮（debug 下正常，很容易漏掉）。
  Widget _chevron(Widget icon, String tooltip, VoidCallback onPressed) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onPressed,
        radius: 14,
        child: SizedBox(width: 28, height: 28, child: icon),
      ),
    );
  }

  Widget _cell(BuildContext context, DateTime? date, Set<String> marked) {
    if (date == null) return const SizedBox(height: _cellHeight);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isSelected = DateUtils.isSameDay(date, selectedDate);
    final isToday = DateUtils.isSameDay(date, today);
    final hasEntry = marked.contains(_key(date));
    final foreground = isSelected
        ? scheme.onPrimary
        : isToday
        ? scheme.primary
        : scheme.onSurface;
    return SizedBox(
      height: _cellHeight,
      child: InkWell(
        onTap: () => onSelect(date),
        borderRadius: BorderRadius.circular(4),
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            if (isSelected)
              Positioned.fill(
                child: Container(
                  margin: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            Text(
              '${date.day}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: foreground,
                fontWeight: isSelected || isToday
                    ? FontWeight.w700
                    : FontWeight.w400,
              ),
            ),
            if (hasEntry)
              Positioned(
                bottom: 2,
                child: Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                    color: isSelected ? scheme.onPrimary : scheme.primary,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _key(DateTime date) => '${date.year}-${date.month}-${date.day}';
}
