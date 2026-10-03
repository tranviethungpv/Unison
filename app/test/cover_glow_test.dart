import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/theme/palette.dart';
import 'package:sapoche/theme/theme.dart';
import 'package:sapoche/ui/cover_glow.dart';
import 'package:sapoche/ui/widgets/player_backdrop.dart';

Future<ui.Image> solid(int r, int g, int b, {int size = 16}) async {
  final bytes = Uint8List(size * size * 4);
  for (var i = 0; i < bytes.length; i += 4) {
    bytes[i] = r;
    bytes[i + 1] = g;
    bytes[i + 2] = b;
    bytes[i + 3] = 255;
  }
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    bytes,
    size,
    size,
    ui.PixelFormat.rgba8888,
    done.complete,
  );
  return done.future;
}

Future<List<int>> pixelAt(ui.Image image, int x, int y) async {
  final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final i = (y * image.width + x) * 4;
  return [
    data.getUint8(i),
    data.getUint8(i + 1),
    data.getUint8(i + 2),
    data.getUint8(i + 3),
  ];
}

void main() {
  group('the numbers behind it', () {
    test('a pale cover is darkened a lot, a dark one hardly at all', () {
      expect(CoverGlow.darkening(0.95), lessThan(0.4));
      expect(CoverGlow.darkening(0.1), 0.9);
      expect(
        CoverGlow.darkening(0.0),
        0.9,
        reason: 'black does not divide by zero',
      );
    });

    test('the average brightness counts clear pixels only', () {
      final white = Uint8List.fromList([255, 255, 255, 255, 0, 0, 0, 255]);
      expect(CoverGlow.averageLuma(white), closeTo(0.5, 0.01));
      final clear = Uint8List.fromList([255, 255, 255, 0, 0, 0, 0, 255]);
      expect(CoverGlow.averageLuma(clear), closeTo(0, 0.01));
      expect(CoverGlow.averageLuma(Uint8List(0)), 0.5);
    });

    test('a dark cover is faded more than a light one in the light theme', () {
      expect(CoverGlow.lightKeep(0), 0.38);
      expect(CoverGlow.lightKeep(0.4), greaterThan(CoverGlow.lightKeep(0.1)));
      expect(
        CoverGlow.lightKeep(1),
        0.75,
        reason: 'white does not divide by zero',
      );
    });

    test('a lower saturation pulls colours apart less', () {
      double spread(List<double> m) {
        const orange = [200.0, 120.0, 40.0];
        double row(int at) =>
            m[at] * orange[0] + m[at + 1] * orange[1] + m[at + 2] * orange[2];
        return row(0) - row(10);
      }

      expect(
        spread(CoverGlow.tint(1, saturation: 1.35)),
        lessThan(spread(CoverGlow.tint(1))),
      );
      expect(spread(CoverGlow.tint(1, saturation: 1)), closeTo(160, 0.01));
    });

    test('the light matrix mixes white in', () {
      final m = CoverGlow.tint(0.4, lift: 0.6);
      expect(m[4], closeTo(153, 0.01));
      expect(m[9], closeTo(153, 0.01));
      expect(m[14], closeTo(153, 0.01));
      expect(CoverGlow.tint(1)[4], 0);
    });

    test('the colour matrix keeps grey grey and pulls colours apart', () {
      final m = CoverGlow.tint(1);
      double apply(List<double> row, List<double> rgb) =>
          row[0] * rgb[0] + row[1] * rgb[1] + row[2] * rgb[2];
      const grey = [100.0, 100.0, 100.0];
      expect(apply(m.sublist(0, 5), grey), closeTo(100, 0.01));
      expect(apply(m.sublist(5, 10), grey), closeTo(100, 0.01));
      const orange = [200.0, 120.0, 40.0];
      final red = apply(m.sublist(0, 5), orange);
      final blue = apply(m.sublist(10, 15), orange);
      expect(
        red - blue,
        greaterThan(200 - 40),
        reason: 'more vivid than before',
      );
    });
  });

  group('the picture', () {
    testWidgets('has the colour of the cover and is darker than it', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final cover = await solid(220, 40, 60);
        final glow = await CoverGlow.render(cover);
        expect(glow.width, CoverGlow.width);
        expect(glow.height, CoverGlow.height);
        final centre = await pixelAt(glow, 36, 78);
        expect(centre[0], greaterThan(centre[1] + 40), reason: 'still red');
        double luma(List<int> px) =>
            0.2126 * px[0] + 0.7152 * px[1] + 0.0722 * px[2];
        // The red is stronger than in the cover (more vivid), the picture as a whole darker
        expect(luma(centre), lessThan(luma([220, 40, 60])), reason: 'darkened');
        expect(centre[3], 255);
      });
    });

    testWidgets('of a white cover is dark enough for white text', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final glow = await CoverGlow.render(await solid(255, 255, 255));
        final px = await pixelAt(glow, 36, 78);
        final luma = (0.2126 * px[0] + 0.7152 * px[1] + 0.0722 * px[2]) / 255;
        expect(luma, lessThan(0.45));
      });
    });

    testWidgets('in the light theme is pale, even from a black cover', (
      tester,
    ) async {
      await tester.runAsync(() async {
        double luma(List<int> px) =>
            (0.2126 * px[0] + 0.7152 * px[1] + 0.0722 * px[2]) / 255;
        final black = await CoverGlow.render(await solid(0, 0, 0), light: true);
        expect(luma(await pixelAt(black, 36, 78)), greaterThan(0.55));
        final red = await CoverGlow.render(
          await solid(220, 40, 60),
          light: true,
        );
        final px = await pixelAt(red, 36, 78);
        expect(px[0], greaterThan(px[1] + 30), reason: 'still red');
        expect(luma(px), greaterThan(0.55));
      });
    });

    testWidgets('of a black cover stays dark and does not break', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final glow = await CoverGlow.render(await solid(0, 0, 0));
        final px = await pixelAt(glow, 10, 10);
        expect(px[0] + px[1] + px[2], lessThan(30));
      });
    });
  });

  group('the background of the player', () {
    testWidgets('is made again for the other theme', (tester) async {
      final mode = ValueNotifier(Palette.light);
      addTearDown(mode.dispose);
      await tester.pumpWidget(
        ValueListenableBuilder(
          valueListenable: mode,
          builder: (context, palette, _) => MaterialApp(
            theme: buildTheme(palette),
            home: const Scaffold(body: PlayerBackdrop(coverUrl: null)),
          ),
        ),
      );
      mode.value = Palette.dark;
      await tester.pump();
      expect(find.byKey(const ValueKey('pink')), findsOneWidget);
    });

    testWidgets('is the pink veil when the song has no cover', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Palette.dark),
          home: const Scaffold(body: PlayerBackdrop(coverUrl: null)),
        ),
      );
      expect(find.byKey(const ValueKey('pink')), findsOneWidget);
    });

    testWidgets('falls back to the veil when the cover cannot be read', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Palette.dark),
          home: const Scaffold(
            body: PlayerBackdrop(coverUrl: 'https://example.invalid/none.jpg'),
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('pink')), findsOneWidget);
    });

    testWidgets('has a glow that ends on a whole device pixel', (tester) async {
      // The phone this was seen on: 34% of 2340 device pixels is 795.6, part-way through a pixel
      tester.view
        ..devicePixelRatio = 2.625
        ..physicalSize = const Size(1080, 2340);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Palette.light),
          home: const Scaffold(
            body: PlayerBackdrop(coverUrl: null, glowHeight: 0.34),
          ),
        ),
      );
      final height = tester.getSize(find.byType(ShaderMask)).height;
      expect(height * 2.625, closeTo((height * 2.625).roundToDouble(), 1e-6));
      expect(height * 2.625, lessThanOrEqualTo(2340 * 0.34));
    });
  });
}
