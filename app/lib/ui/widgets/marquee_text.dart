import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../data/calm.dart';

/// One line of text that scrolls past when it does not fit, like the title in YouTube Music's player: it waits,
/// moves slowly to the end and comes round again. Text that fits stays where it is, and so does all of it when
/// the system asks for less motion (then it is cut with "…"). While the phone is warm or saving power ([Calm]) it
/// rests at its start.
class MarqueeText extends StatefulWidget {
  const MarqueeText(
    this.text, {
    super.key,
    this.style,
    this.pause = const Duration(seconds: 2),
    this.rounds,
  });

  final String text;
  final TextStyle? style;

  /// How long the start of the text stays readable before it moves.
  final Duration pause;

  /// How many times a long line goes round before it rests at its start, until the text changes or the app comes
  /// back to the front; null for ever. For a line that is always on screen, like the mini player's: every frame of
  /// its movement draws the glass around it again.
  final int? rounds;

  /// The [rounds] of the lines of the bars that stay on screen under every page (the mini player, the player bar).
  static const barRounds = 2;

  /// The [rounds] of the lines of the full player. An iPhone cannot be asked for its normal rate for what moves by
  /// itself (see `DisplayPace`), so a line that went round for ever would be drawn at 120 frames a second for as long as
  /// the player is open: there it rests after a few rounds. Elsewhere it goes on, at the normal rate.
  static int? get playerRounds =>
      defaultTargetPlatform == TargetPlatform.iOS ? 3 : null;

  /// Logical pixels the text moves in a second.
  static const speed = 34.0;

  /// Room between the end of the text and its beginning coming round again.
  static const gap = 56.0;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final _controller = AnimationController(vsync: this);

  /// Bumped whenever the loop has to start again or stop, so an old loop notices and ends.
  int _run = 0;
  Timer? _wait;
  double _distance = 0;

  /// The line's size, and what it was measured for: laying the text out again in every frame that rebuilds the line
  /// (the mini player while the bars fold) is work for nothing.
  Size _size = Size.zero;
  Object? _measuredFor;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Calm.on.addListener(_restart);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.rounds != null) {
      _restart();
    }
  }

  /// Starts the loop again from the beginning, with all its rounds.
  void _restart() {
    final distance = _distance;
    _travel(0);
    _travel(distance);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    Calm.on.removeListener(_restart);
    _run++;
    _wait?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Starts (or restarts) the loop for a line that has to travel [distance]; 0 stops it.
  void _travel(double distance) {
    if (distance == _distance) return;
    _distance = distance;
    final run = ++_run;
    _wait?.cancel();
    _controller.value = 0;
    if (distance == 0) return;
    final rounds = widget.rounds;
    var done = 0;
    // No frames are drawn while the text waits: only the timer runs
    void again() {
      _wait = Timer(widget.pause, () async {
        if (run != _run || !mounted || Calm.on.value) return;
        _controller.duration = Duration(
          milliseconds: (distance / MarqueeText.speed * 1000).round(),
        );
        try {
          await _controller.forward(from: 0).orCancel;
        } on TickerCanceled {
          return;
        }
        if (run != _run || !mounted) return;
        // The copy of the text that came round looks just like the start
        _controller.value = 0;
        if (rounds != null && ++done >= rounds) return;
        again();
      });
    }

    again();
  }

  @override
  void didUpdateWidget(MarqueeText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _travel(0);
  }

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(widget.style);
    final still = MediaQuery.disableAnimationsOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final direction = Directionality.of(context);
        final scaler = MediaQuery.textScalerOf(context);
        final measuring = (widget.text, style, direction, scaler);
        if (measuring != _measuredFor) {
          final painter = TextPainter(
            text: TextSpan(text: widget.text, style: style),
            textDirection: direction,
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          _size = painter.size;
          _measuredFor = measuring;
          painter.dispose();
        }
        final width = _size.width;
        final height = _size.height;
        final fits = width <= constraints.maxWidth;
        final distance = fits || still ? 0.0 : width + MarqueeText.gap;
        // The loop is only (re)started after this frame is built
        if (distance != _distance) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _travel(distance);
          });
        }
        if (distance == 0) {
          return Text(
            widget.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: widget.style,
          );
        }
        final line = Text(
          widget.text,
          maxLines: 1,
          softWrap: false,
          style: style,
        );
        return ClipRect(
          child: SizedBox(
            width: constraints.maxWidth,
            height: height,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                final offset = _controller.value * distance;
                return ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (rect) => LinearGradient(
                    colors: [
                      Colors.white.withValues(
                        alpha: (1 - (offset / 14).clamp(0, 1)).toDouble(),
                      ),
                      Colors.white,
                      Colors.white,
                      Colors.transparent,
                    ],
                    stops: [0, 14 / rect.width, 1 - 14 / rect.width, 1],
                  ).createShader(rect),
                  child: OverflowBox(
                    alignment: Alignment.centerLeft,
                    minWidth: 0,
                    maxWidth: double.infinity,
                    child: Transform.translate(
                      offset: Offset(-offset, 0),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          line,
                          const SizedBox(width: MarqueeText.gap),
                          line,
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}
