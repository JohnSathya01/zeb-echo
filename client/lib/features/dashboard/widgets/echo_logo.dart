import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';

/// The Echo vector logo mark — a hand-painted "echo" glyph: a solid origin dot
/// with concentric arcs radiating outward like a sound echo / ripple, in the
/// zeb lime accent. Purely vector (CustomPaint) so it scales crisply at any size
/// and ships no asset. Used in the top-bar wordmark.
class EchoLogo extends StatelessWidget {
  const EchoLogo({super.key, this.size = 34});

  /// Edge length of the square the mark is painted within.
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
    // Origin sits to the left-of-centre so the arcs sweep rightward, reading as
    // sound emanating outward.
    final origin = Offset(size.width * 0.30, size.height * 0.5);
    final maxRadius = size.width * 0.46;

    // Three concentric arcs, fading outward, opening to the right (the "echo").
    const arcCount = 3;
    for (var i = 0; i < arcCount; i++) {
      final t = (i + 1) / arcCount;
      final radius = maxRadius * t;
      final opacity = 1.0 - i * 0.28;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = size.width * 0.085
        ..color = AppColors.accent.withValues(alpha: opacity);

      // Sweep an arc opening toward the right (~150° centred on 0 rad).
      const sweep = 2.6; // radians (~150°)
      const start = -sweep / 2;
      canvas.drawArc(
        Rect.fromCircle(center: origin, radius: radius),
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
    canvas.drawCircle(origin, size.width * 0.085, dot);
  }

  @override
  bool shouldRepaint(covariant _EchoLogoPainter oldDelegate) => false;
}
