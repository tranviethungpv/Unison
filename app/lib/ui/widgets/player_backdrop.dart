import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../theme/palette.dart';
import '../../theme/theme.dart';
import '../cover_glow.dart';
import 'low_rate_timer.dart';
import 'wash.dart';

/// Background of the full player, in the manner of Apple Music: the cover's own colours, enlarged and blurred
/// until they are only light. In the dark theme the colours are deep and the bottom is darkened for the controls;
/// in the light theme they are pale and the bottom fades to white. It changes from song to song by fading from one
/// picture to the next. A song with no cover, or one that cannot be read, gets the app's pink veil.
///
/// The picture is made once per cover (see [CoverGlow]) and is not drawn again until the song changes, so the
/// player costs no more with it than without.
class PlayerBackdrop extends StatefulWidget {
  const PlayerBackdrop({
    super.key,
    required this.coverUrl,
    this.glowHeight,
    this.moving = false,
  });

  final String? coverUrl;

  /// A fraction of the height: instead of the whole screen, the colours are a glow along the top that thins out to
  /// nothing by this much of the way down, the rest being left to what is behind. For the pages that are not about one
  /// cover (home, library, settings).
  final double? glowHeight;

  /// The colours drift slowly, as the background of Now Playing does in Apple Music. Only while true, and not for
  /// someone who asked the phone for less motion.
  final bool moving;

  @override
  State<PlayerBackdrop> createState() => _PlayerBackdropState();
}

class _PlayerBackdropState extends State<PlayerBackdrop> {
  /// The picture on show and the address it is of; kept while the next one is being made.
  ui.Image? _glow;
  String? _shownFor;

  /// The theme the picture on show was made for; the picture is made again when the app changes theme.
  bool? _light;

  /// How far the drift has gone, in turns, while [PlayerBackdrop.moving].
  final _phase = ValueNotifier<double>(0);
  late final _drift = LowRateTimer(const Duration(milliseconds: 50), () {
    // A turn in about a minute: slow enough to be felt rather than watched
    _phase.value += 0.05 / 60;
  });

  /// The picture with its edges faded out, which the drifting copies are made of (a copy with straight edges would show
  /// them as it turns), and the picture it was made from.
  ui.Image? _soft;
  ui.Image? _softOf;

  @override
  void dispose() {
    _drift.dispose();
    _phase.dispose();
    _soft?.dispose();
    super.dispose();
  }

  /// Makes the faded picture once the drift is wanted and the picture is there, and again for the next picture.
  Future<void> _ensureSoft() async {
    final glow = _glow;
    if (!widget.moving || glow == null || _softOf == glow) return;
    _softOf = glow;
    final soft = await _feather(glow);
    if (!mounted || _glow != glow) {
      soft.dispose();
      return;
    }
    // The one it replaces may still be drawn by the picture that fades out: it is left to be collected
    setState(() => _soft = soft);
  }

  /// [source] with the sides, top and bottom faded into nothing in the shape of an ellipse.
  static Future<ui.Image> _feather(ui.Image source) async {
    final w = source.width.toDouble();
    final h = source.height.toDouble();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..saveLayer(Rect.fromLTWH(0, 0, w, h), Paint())
      ..drawImage(source, Offset.zero, Paint())
      ..translate(w / 2, h / 2)
      ..scale(1, h / w);
    canvas
      ..drawRect(
        Rect.fromCenter(center: Offset.zero, width: w * 4, height: w * 4),
        Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = ui.Gradient.radial(
            Offset.zero,
            w / 2,
            const [Color(0xFFFFFFFF), Color(0xFFFFFFFF), Color(0x00FFFFFF)],
            const [0, 0.45, 1],
          ),
      )
      ..restore();
    final picture = recorder.endRecording();
    final image = await picture.toImage(source.width, source.height);
    picture.dispose();
    return image;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final light = context.palette.brightness == Brightness.light;
    if (light == _light) return;
    _light = light;
    _load();
  }

  @override
  void didUpdateWidget(PlayerBackdrop old) {
    super.didUpdateWidget(old);
    if (widget.coverUrl != old.coverUrl) _load();
    if (widget.moving && !old.moving) _ensureSoft();
  }

  bool get _drifts => widget.moving && !MediaQuery.disableAnimationsOf(context);

  void _load() {
    final url = widget.coverUrl;
    if (url == null) {
      setState(() {
        _glow = null;
        _shownFor = null;
      });
      return;
    }
    final light = _light!;
    CoverGlow.of(url, light: light).then((image) {
      if (!mounted || widget.coverUrl != url || _light != light) return;
      setState(() {
        _glow = image;
        _shownFor = url;
      });
      _ensureSoft();
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final glow = _glow;
    final light = p.brightness == Brightness.light;
    _drift.run(_drifts && glow != null);
    final fraction = widget.glowHeight;
    if (fraction != null) return _topGlow(p, glow, fraction);
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: p.base),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 900),
          switchInCurve: Curves.easeInOut,
          switchOutCurve: Curves.easeInOut,
          layoutBuilder: (current, previous) =>
              Stack(fit: StackFit.expand, children: [...previous, ?current]),
          child: glow == null
              ? const PinkWash(
                  key: ValueKey('pink'),
                  intensity: 0.55,
                  opaque: false,
                  child: SizedBox.expand(),
                )
              : RepaintBoundary(
                  key: ValueKey(_shownFor),
                  child: CustomPaint(
                    painter: _drifts
                        ? _DriftPainter(glow, _soft, _phase)
                        : _GlowPainter(glow),
                    child: const SizedBox.expand(),
                  ),
                ),
        ),
        // Darker (lighter, in the light theme) towards the bottom, where the controls are
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [0, 0.45, 1],
              colors: light
                  ? const [
                      Color(0x00FFFFFF),
                      Color(0x0DFFFFFF),
                      Color(0x4DFFFFFF),
                    ]
                  : const [
                      Color(0x14000000),
                      Color(0x26000000),
                      Color(0x73000000),
                    ],
            ),
          ),
        ),
      ],
    );
  }
}

extension on _PlayerBackdropState {
  /// The colours as a glow along the top, over whatever the page has behind: richer than the full player's, since only
  /// a thin part of the screen has them, and gone by [fraction] of the height.
  Widget _topGlow(Palette p, ui.Image? glow, double fraction) {
    final light = p.brightness == Brightness.light;
    return Align(
      alignment: Alignment.topCenter,
      child: LayoutBuilder(
        builder: (context, box) {
          // A whole number of device pixels: where the mask ends part-way through one, that row keeps part of the
          // picture and shows as a faint line across the page
          final scale = MediaQuery.devicePixelRatioOf(context);
          final height = (box.maxHeight * fraction * scale).floor() / scale;
          return SizedBox(
            width: double.infinity,
            height: height,
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (rect) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0, 0.5, 1],
                // Soft even at its strongest, so that the titles over it stay easy to read
                colors: [
                  Color(0x99FFFFFF),
                  Color(0x52FFFFFF),
                  Color(0x00FFFFFF),
                ],
              ).createShader(rect),
              child: ColorFiltered(
                // The dark theme's picture is deep so that white text reads on all of the full player; as a glow it is
                // only brought up a little
                colorFilter: ColorFilter.matrix(
                  light ? _bright(1, 1.15) : _bright(1.15, 1.0),
                ),
                child: SizedBox.expand(
                  child: glow == null
                      ? const SizedBox.shrink()
                      : RepaintBoundary(
                          key: ValueKey(_shownFor),
                          child: CustomPaint(painter: _GlowPainter(glow)),
                        ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// A colour matrix that multiplies the colours by [gain] and makes them [vivid] times as vivid.
  static List<double> _bright(double gain, double vivid) {
    const r = 0.2126, g = 0.7152, b = 0.0722;
    final s = vivid;
    double k(double v) => v * gain;
    return [
      k(r * (1 - s) + s), k(g * (1 - s)), k(b * (1 - s)), 0, 0, //
      k(r * (1 - s)), k(g * (1 - s) + s), k(b * (1 - s)), 0, 0, //
      k(r * (1 - s)), k(g * (1 - s)), k(b * (1 - s) + s), 0, 0, //
      0, 0, 0, 1, 0,
    ];
  }
}

/// The picture with copies of itself over it that turn and wander slowly, as the layers of Apple Music's Now Playing
/// do: where the colours of the cover meet they flow into each other, and the screen is never still.
class _DriftPainter extends CustomPainter {
  _DriftPainter(this.image, this.soft, this.phase) : super(repaint: phase);

  final ui.Image image;

  /// [image] with its edges faded out; the copies are made of it. Null until it is made.
  final ui.Image? soft;
  final ValueNotifier<double> phase;

  /// Scale of each copy against the screen's width, how far it wanders, and how fast and which way it turns.
  static const _layers = [
    (scale: 2.1, reach: 0.18, turns: 1.0, alpha: 0.55),
    (scale: 1.5, reach: 0.30, turns: -1.4, alpha: 0.5),
    (scale: 1.0, reach: 0.38, turns: 1.9, alpha: 0.45),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final src = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    // The picture on its own below: nothing is ever bare
    canvas.drawImageRect(
      image,
      src,
      Offset.zero & size,
      Paint()..filterQuality = FilterQuality.medium,
    );
    final copy = soft;
    if (copy == null) return;
    final t = phase.value * 2 * math.pi;
    for (final (i, layer) in _layers.indexed) {
      final angle = t * layer.turns + i * 2.1;
      canvas
        ..save()
        ..translate(
          size.width / 2 + math.cos(angle) * layer.reach * size.width,
          size.height / 2 + math.sin(angle * 0.8) * layer.reach * size.height,
        )
        ..rotate(angle * 0.6);
      final width = size.width * layer.scale;
      canvas.drawImageRect(
        copy,
        src,
        Rect.fromCenter(
          center: Offset.zero,
          width: width,
          height: width * image.height / image.width,
        ),
        Paint()
          ..filterQuality = FilterQuality.medium
          ..color = Color.fromRGBO(255, 255, 255, layer.alpha),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_DriftPainter old) =>
      old.image != image || old.soft != soft || old.phase != phase;
}

class _GlowPainter extends CustomPainter {
  _GlowPainter(this.image);

  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      // Stretched far, so it is smoothed the best way there is
      Paint()..filterQuality = FilterQuality.high,
    );
  }

  @override
  bool shouldRepaint(_GlowPainter old) => old.image != image;
}
