import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'widgets/cached_cover.dart';

/// The soft, blurred picture of a cover that lights the full player's background, the way Apple Music does: the
/// cover itself, enlarged, blurred and more vivid. In the dark theme it is darkened until white text reads well on
/// any colours; in the light theme it is faded towards white until dark text does.
///
/// The cover is shrunk to a few dozen pixels, blurred and tinted once into a small picture, which is then just
/// stretched over the screen. Nothing is blurred while the player is open, so it costs nothing per frame.
class CoverGlow {
  CoverGlow._();

  /// Size of the finished picture; it is stretched, and stretching a smooth picture stays smooth.
  static const width = 72;
  static const height = 156;

  /// Side of the cover that is read, in pixels.
  static const _side = 48;

  /// How vivid the colours are made.
  static const saturation = 1.75;

  /// The brightness the background should average, 0 black to 1 white.
  static const _targetLuma = 0.30;

  /// How vivid the colours are made in the light theme: less than in the dark one, where they have a dark ground to
  /// glow on, as against pale ones that turn garish.
  static const _lightSaturation = 1.35;

  /// The brightness the background should average in the light theme, 0 black to 1 white: pale enough for dark text.
  static const _lightLuma = 0.62;

  /// In the order they were last used, the oldest first (a map literal keeps the order of insertion).
  static final _cache = <String, ui.Image?>{};
  static final _pending = <String, Future<ui.Image?>>{};
  static const _kept = 8;

  /// The blurred picture for the cover at [url], pale when [light], or null when the cover cannot be read.
  static Future<ui.Image?> of(String url, {bool light = false}) {
    final key = '${light ? 'light' : 'dark'} $url';
    if (_cache.containsKey(key)) {
      // Most recently used goes last
      final image = _cache.remove(key);
      _cache[key] = image;
      return Future.value(image);
    }
    return _pending.putIfAbsent(key, () async {
      final image = await _make(url, light);
      _remember(key, image);
      _pending.remove(key);
      return image;
    });
  }

  static void _remember(String key, ui.Image? image) {
    _cache[key] = image;
    while (_cache.length > _kept) {
      final oldest = _cache.keys.first;
      _cache.remove(oldest)?.dispose();
    }
  }

  static Future<ui.Image?> _make(String url, bool light) async {
    final small = await _load(url);
    if (small == null) return null;
    try {
      return await render(small, light: light);
    } finally {
      small.dispose();
    }
  }

  static Future<ui.Image?> _load(String url) async {
    final completer = Completer<ui.Image?>();
    final stream = ResizeImage(
      CachedCover(url),
      width: _side,
      height: _side,
      allowUpscaling: false,
    ).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        // The stream owns this image and may drop it: keep a copy
        if (!completer.isCompleted) completer.complete(info.image.clone());
        stream.removeListener(listener);
      },
      onError: (_, _) {
        if (!completer.isCompleted) completer.complete(null);
        stream.removeListener(listener);
      },
    );
    stream.addListener(listener);
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => null,
    );
  }

  /// Blurs and tints [cover] into the small picture. Public so that it can be tested with a made-up cover.
  static Future<ui.Image> render(ui.Image cover, {bool light = false}) async {
    final data = await cover.toByteData(format: ui.ImageByteFormat.rawRgba);
    final luma = data == null ? 0.5 : averageLuma(data.buffer.asUint8List());
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint()
      ..filterQuality = FilterQuality.high
      ..imageFilter = ui.ImageFilter.blur(
        sigmaX: 5,
        sigmaY: 5,
        tileMode: TileMode.mirror,
      )
      ..colorFilter = ColorFilter.matrix(
        light
            ? tint(
                lightKeep(luma),
                lift: 1 - lightKeep(luma),
                saturation: _lightSaturation,
              )
            : tint(darkening(luma)),
      );
    // The cover fills the height and is cropped at the sides, as it would be on a tall screen
    final target = Rect.fromCenter(
      center: const Offset(width / 2, height / 2),
      width: height.toDouble(),
      height: height.toDouble(),
    );
    canvas.drawImageRect(
      cover,
      Rect.fromLTWH(0, 0, cover.width.toDouble(), cover.height.toDouble()),
      target,
      paint,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    return image;
  }

  /// How bright the pixels are on average, 0 to 1, from raw RGBA.
  static double averageLuma(Uint8List rgba) {
    var sum = 0.0;
    var count = 0;
    for (var i = 0; i + 3 < rgba.length; i += 4) {
      if (rgba[i + 3] < 128) continue;
      sum +=
          (0.2126 * rgba[i] + 0.7152 * rgba[i + 1] + 0.0722 * rgba[i + 2]) /
          255;
      count++;
    }
    return count == 0 ? 0.5 : sum / count;
  }

  /// By how much to darken a cover of this [luma]: a pale cover a lot, a dark one hardly at all.
  static double darkening(double luma) =>
      (_targetLuma / (luma <= 0.01 ? 0.01 : luma)).clamp(0.38, 0.9);

  /// How much of the colour of a cover of this [luma] is kept in the light theme, the rest being white: a dark cover
  /// is faded a lot to stay pale, a light or colourful one keeps more of its colours.
  static double lightKeep(double luma) =>
      ((1 - _lightLuma) / (1 - (luma > 0.9 ? 0.9 : luma))).clamp(0.38, 0.75);

  /// A colour matrix that makes colours more vivid, darkens them by [factor] and then mixes in [lift] of white.
  static List<double> tint(
    double factor, {
    double lift = 0,
    double saturation = CoverGlow.saturation,
  }) {
    final s = saturation;
    const r = 0.2126, g = 0.7152, b = 0.0722;
    double k(double v) => v * factor;
    final white = lift * 255;
    return [
      k(r * (1 - s) + s),
      k(g * (1 - s)),
      k(b * (1 - s)),
      0,
      white,
      k(r * (1 - s)),
      k(g * (1 - s) + s),
      k(b * (1 - s)),
      0,
      white,
      k(r * (1 - s)),
      k(g * (1 - s)),
      k(b * (1 - s) + s),
      0,
      white,
      0,
      0,
      0,
      1,
      0,
    ];
  }
}
