import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../data/calm.dart';
import '../../theme/palette.dart';
import '../../theme/theme.dart';

/// Frosted glass for the bars that float over the pages (the tabs, the search button, the mini player): what is
/// behind is blurred under a thin veil, so a bar takes the colours of the page it is over, the cover of an album as
/// much as the pink of the home page. The veil is the soft tint of the round buttons of an album page, on a little of
/// the background colour so that text reads over any picture.
///
/// A backdrop blur costs a pass over the screen behind it in every frame that moves, whatever its strength. Measured
/// on the phone while scrolling, three separate ones took 10 ms to draw a frame; grouped under the [BackdropGroup] of
/// the home screen, so that they share one reading of what is behind them, they take 4 ms, against 2.5 ms without
/// any glass.
///
/// While the phone is warm or saving power ([Calm]) the bars are a near solid veil instead, as iOS turns its glass
/// solid in Low Power Mode: nothing behind them is read or blurred, which is half of what the screen costs as a page
/// scrolls.
class Glass extends StatelessWidget {
  const Glass({super.key, required this.child, required this.borderRadius});

  final Widget child;
  final BorderRadius borderRadius;

  /// How strongly what is behind is blurred.
  static const sigma = 20.0;

  static final _blur = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);

  /// The veil over the blur; with [calm], the veil without one.
  static Color tintOf(Palette p, {bool calm = false}) {
    final light = p.brightness == Brightness.light;
    return Color.alphaBlend(
      p.text.withValues(alpha: light ? 0.06 : 0.08),
      p.base.withValues(alpha: calm ? 0.94 : (light ? 0.55 : 0.40)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ValueListenableBuilder(
      valueListenable: Calm.on,
      // Touches ripple on the glass, not under it
      child: Material(type: MaterialType.transparency, child: child),
      builder: (context, calm, child) => ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter.grouped(
          enabled: !calm,
          filter: _blur,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tintOf(p, calm: calm),
              borderRadius: borderRadius,
              border: Border.all(color: p.text.withValues(alpha: 0.09)),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
