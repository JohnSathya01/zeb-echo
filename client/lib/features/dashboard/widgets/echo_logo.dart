import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';

/// The Echo logo mark — a rounded-square brand badge containing the "echo"
/// glyph (a solid origin dot with concentric arcs radiating outward like a
/// sound ripple), in the zeb lime accent. Purely vector (CustomPaint) so it
/// scales crisply and ships no asset; mirrors the app icon for brand cohesion.
class EchoLogo extends StatelessWidget {
  const EchoLogo({super.key, this.size = 38});

  /// Edge length of the square badge.
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _EchoLogoPainter()),
    );
  }
}

class _EchoLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final radius = w * 0.28;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, w, h),
      Radius.circular(radius),
    );

    // Badge fill: a soft accent-tinted gradient over the elevated surface, so
    // the mark reads as a contained brand tile rather than loose arcs.
    final fill = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          AppColors.surfaceElevated,
          AppColors.backgroundBlack,
        ],
      ).createShader(Rect.fromLTWH(0, 0, w, h));
    canvas.drawRRect(rrect, fill);

    // Thin accent hairline border.
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.04
      ..color = AppColors.accent.withValues(alpha: 0.55);
    canvas.drawRRect(rrect.deflate(w * 0.02), border);

    // Echo ripples, centred within the badge, opening right.
    canvas.save();
    canvas.clipRRect(rrect);
    final origin = Offset(w * 0.38, h * 0.5);
    const arcCount = 3;
    const sweep = 2.5; // ~143°
    const start = -sweep / 2;
    final baseRadius = w * 0.13;
    final ringGap = w * 0.115;

    for (var i = 0; i < arcCount; i++) {
      final r = baseRadius + ringGap * i;
      final strokeW = w * (0.075 - i * 0.009);
      final opacity = 1.0 - i * 0.24;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = strokeW
        ..color = AppColors.accent.withValues(alpha: opacity);
      canvas.drawArc(
        Rect.fromCircle(center: origin, radius: r),
        start,
        sweep,
        false,
        paint,
      );
    }

    // Solid origin dot — the source of the echo.
    final dot = Paint()
      ..style = PaintingStyle.fill
      ..color = AppColors.accent;
    canvas.drawCircle(origin, w * 0.058, dot);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _EchoLogoPainter oldDelegate) => false;
}
