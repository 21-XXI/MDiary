import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'cosmos_layout.dart';
import 'star_map_layout.dart' show StarPeriod;

/// 星图绘制：星云 / 连线 / 星 / 附件轨道。
class CosmosPainter extends CustomPainter {
  CosmosPainter({
    required this.layout,
    required this.phase,
    required this.scheme,
  });

  final CosmosLayout layout;
  final double phase;
  final ColorScheme scheme;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(0, -0.15),
          radius: 1.15,
          colors: <Color>[Color(0xFF0B1730), Color(0xFF05070F)],
        ).createShader(rect),
    );
    _ambient(canvas, size);
    _clusters(canvas);
    _links(canvas);
    _orbits(canvas);
    _stars(canvas);
  }

  void _ambient(Canvas canvas, Size size) {
    final rnd = math.Random(7);
    final paint = Paint();
    for (var i = 0; i < 150; i++) {
      final x = rnd.nextDouble() * size.width;
      final y = rnd.nextDouble() * size.height;
      final r = 0.5 + rnd.nextDouble() * 1.2;
      paint.color = Color.fromRGBO(150, 180, 230, 0.12 + rnd.nextDouble() * 0.25);
      canvas.drawCircle(Offset(x, y), r, paint);
    }
  }

  void _clusters(Canvas canvas) {
    for (final cluster in layout.clusters) {
      final radius = cluster.radius * 2.1;
      final rect = Rect.fromCircle(center: cluster.center, radius: radius);
      final color = _clusterColor(cluster.seed);
      canvas.drawCircle(
        cluster.center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: <Color>[
              color.withValues(alpha: 0.26),
              color.withValues(alpha: 0.06),
              Colors.transparent,
            ],
            stops: const <double>[0, 0.55, 1],
          ).createShader(rect),
      );
      final rnd = math.Random(cluster.seed);
      final paint = Paint();
      for (var i = 0; i < 110; i++) {
        final angle = rnd.nextDouble() * math.pi * 2;
        final r = math.sqrt(rnd.nextDouble()) * radius;
        final x = cluster.center.dx + math.cos(angle) * r;
        final y = cluster.center.dy + math.sin(angle) * r * 0.8;
        paint.color = color.withValues(alpha: 0.10 + rnd.nextDouble() * 0.25);
        canvas.drawCircle(Offset(x, y), 0.7 + rnd.nextDouble() * 1.3, paint);
      }
      _text(
        canvas,
        cluster.label,
        cluster.center + Offset(0, radius * 0.72),
        color: Colors.white.withValues(alpha: 0.72),
        size: 12,
      );
    }
  }

  void _links(Canvas canvas) {
    final paint = Paint()..strokeWidth = 1;
    for (final link in layout.links) {
      paint.color = scheme.primary.withValues(alpha: 0.10 + 0.28 * link.emphasis);
      canvas.drawLine(link.from, link.to, paint);
    }
  }

  void _orbits(Canvas canvas) {
    final path = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = scheme.primary.withValues(alpha: 0.22);
    final dot = Paint()..color = scheme.tertiary;
    for (final orbit in layout.orbits) {
      final rect = Rect.fromCenter(
        center: orbit.center,
        width: orbit.radius * 2,
        height: orbit.radius * 1.1,
      );
      canvas.drawOval(rect, path);
      for (var i = 0; i < orbit.count; i++) {
        final angle = phase * 2 * math.pi + i * (2 * math.pi / orbit.count);
        final point = Offset(
          orbit.center.dx + math.cos(angle) * orbit.radius,
          orbit.center.dy + math.sin(angle) * orbit.radius * 0.55,
        );
        canvas.drawCircle(point, 1.8, dot);
      }
    }
  }

  void _stars(Canvas canvas) {
    final glow = Paint()..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    final core = Paint();
    for (var i = 0; i < layout.stars.length; i++) {
      final star = layout.stars[i];
      final pulse = 0.85 + 0.15 * math.sin(phase * 2 * math.pi + i * 0.9);
      if (star.hollow) {
        core.color = Colors.white.withValues(alpha: 0.18);
        canvas.drawCircle(star.center, 1.6, core);
        continue;
      }
      final r = star.radius * pulse;
      glow.color = scheme.primary.withValues(alpha: 0.35);
      canvas.drawCircle(star.center, r * 2.4, glow);
      core.color = const Color(0xFFEAF3FF);
      canvas.drawCircle(star.center, r, core);
      if (layout.period == StarPeriod.week || layout.period == StarPeriod.month) {
        _text(
          canvas,
          star.label,
          star.center + Offset(0, r + 13),
          color: Colors.white.withValues(alpha: 0.55),
          size: 10,
        );
      }
    }
  }

  void _text(
    Canvas canvas,
    String text,
    Offset center, {
    required Color color,
    required double size,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: size, height: 1.25),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, center - Offset(painter.width / 2, painter.height / 2));
  }

  Color _clusterColor(int seed) {
    final hue = (seed * 47) % 360;
    return HSLColor.fromAHSL(1, hue.toDouble(), 0.55, 0.62).toColor();
  }

  @override
  bool shouldRepaint(covariant CosmosPainter oldDelegate) =>
      oldDelegate.layout != layout ||
      oldDelegate.phase != phase ||
      oldDelegate.scheme != scheme;
}
