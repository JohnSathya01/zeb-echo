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
    final w = size.width;
    // Origin sits left-of-centre so arcs sweep rightward — sound emanating out.
    final origin = Offset(w * 0.26, size.height * 0.5);

    // Three evenly-spaced concentric arcs opening right (the "echo"), with a
    // gentle outward taper in weight + opacity for a refined, balanced look.
    const arcCount = 3;
    const sweep = 2.5; // radians (~143°)
    const start = -sweep / 2;
    final baseRadius = w * 0.20;
    final ringGap = w * 0.15;

    for (var i = 0; i < arcCount; i++) {
      final radius = baseRadius + ringGap * i;
      // Outer rings slightly thinner + more transparent → sense of fade-out.
      final strokeW = w * (0.105 - i * 0.012);
      final opacity = 1.0 - i * 0.26;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = strokeW
        ..color = AppColors.accent.withValues(alpha: opacity);
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
    canvas.drawCircle(origin, w * 0.075, dot);
  }

  @override
  bool shouldRepaint(covariant _EchoLogoPainter oldDelegate) => false;
}
