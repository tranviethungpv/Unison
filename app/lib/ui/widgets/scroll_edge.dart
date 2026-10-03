import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../data/calm.dart';
import '../../theme/theme.dart';
import '../home_shell.dart';
import 'glass.dart';

/// The top edge of a page that scrolls up under the status bar, in the manner of iOS (on a tablet or a wide screen;
/// a phone's page ends below the status bar). While the page is at its top
/// its own large title is all there is; once it has scrolled past [after], a strip of the bars' glass comes in under
/// the status bar with the title small in it, so what goes up is blurred away instead of being cut off by the edge
/// of the screen.
///
/// The page itself pads its top by the status bar, so that it starts below it and scrolls under it.
class ScrollEdge extends StatefulWidget {
  const ScrollEdge({
    super.key,
    required this.title,
    required this.child,
    this.after = 44,
  });

  final String title;
  final Widget child;

  /// How far the page scrolls before the strip comes in: about the height of its large title.
  final double after;

  /// Height of the strip below the status bar.
  static const height = 44.0;

  /// How far a page inside a [ScrollEdge] pads its top: by the status bar where it scrolls up under it (a tablet, a
  /// wide screen), and by nothing on a phone, where the edge has already put it below the status bar. Read from the
  /// page's own context, which is above the edge.
  static double topOf(BuildContext context) =>
      HomeShell.layoutOf(context) == ShellLayout.bars
      ? 0
      : MediaQuery.paddingOf(context).top;

  @override
  State<ScrollEdge> createState() => _ScrollEdgeState();
}

class _ScrollEdgeState extends State<ScrollEdge> {
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    Calm.on.addListener(_calmChanged);
  }

  @override
  void dispose() {
    Calm.on.removeListener(_calmChanged);
    super.dispose();
  }

  void _calmChanged() => setState(() {});

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth == 0 && notification.metrics.axis == Axis.vertical) {
      final shown = notification.metrics.pixels > widget.after;
      if (shown != _shown) setState(() => _shown = shown);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    // On a phone the page simply ends below the status bar, as it did before the strip: it looked heavy there
    if (HomeShell.layoutOf(context) == ShellLayout.bars) {
      return Padding(
        padding: EdgeInsets.only(top: top),
        child: MediaQuery.removePadding(
          context: context,
          removeTop: true,
          child: widget.child,
        ),
      );
    }
    final p = context.palette;
    // Glass as the bars are, solid while the phone is warm
    final calm = Calm.on.value;
    final tint = Glass.tintOf(p, calm: calm);
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          widget.child,
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: top + ScrollEdge.height,
            child: IgnorePointer(
              // The blur comes in by growing rather than by fading: a blur inside a fading layer has nothing behind it
              // to blur until the fade is over
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: _shown ? 1 : 0),
                duration: const Duration(milliseconds: 200),
                builder: (context, t, _) {
                  if (t == 0) return const SizedBox.shrink();
                  return ClipRect(
                    child: BackdropFilter.grouped(
                      enabled: !calm,
                      filter: ui.ImageFilter.blur(
                        sigmaX: Glass.sigma * t,
                        sigmaY: Glass.sigma * t,
                      ),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: tint.withValues(alpha: tint.a * t),
                          border: Border(
                            bottom: BorderSide(
                              color: p.text.withValues(alpha: 0.08 * t),
                            ),
                          ),
                        ),
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(56, top, 56, 0),
                          child: Center(
                            child: Opacity(
                              opacity: t,
                              child: Text(
                                widget.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
