import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/calm.dart';
import 'package:sapoche/ui/widgets/marquee_text.dart';

const _long =
    'A title that is much too long to fit in the little room it is given';

Future<void> _pump(
  WidgetTester tester,
  String text, {
  bool reduceMotion = false,
  int? rounds,
}) async {
  tester.platformDispatcher.accessibilityFeaturesTestValue =
      FakeAccessibilityFeatures(disableAnimations: reduceMotion);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 120, child: MarqueeText(text, rounds: rounds)),
        ),
      ),
    ),
  );
  await tester.pump();
}

final _shifts = find.descendant(
  of: find.byType(MarqueeText),
  matching: find.byType(Transform),
);

/// How far the text has moved to the left of where it started.
double _moved(WidgetTester tester) =>
    0 - tester.widget<Transform>(_shifts).transform.getTranslation().x;

void main() {
  testWidgets('text that fits stays put and needs no animation', (
    tester,
  ) async {
    await _pump(tester, 'Short');
    expect(_shifts, findsNothing);
    expect(find.text('Short'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('a long line waits, scrolls to its end and comes round again', (
    tester,
  ) async {
    await _pump(tester, _long);
    expect(_moved(tester), 0);

    // Still waiting at the start
    await tester.pump(const Duration(milliseconds: 1500));
    expect(_moved(tester), 0);

    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump(const Duration(seconds: 2));
    final partway = _moved(tester);
    expect(partway, greaterThan(0));

    // It goes all the way round, then waits again
    await tester.pump(const Duration(seconds: 30));
    expect(_moved(tester), 0);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(_moved(tester), 0);
  });

  testWidgets('no frames are drawn while it waits', (tester) async {
    await _pump(tester, _long);
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('with less motion asked for, the line is cut instead', (
    tester,
  ) async {
    await _pump(tester, _long, reduceMotion: true);
    expect(_shifts, findsNothing);
    expect(
      tester.widget<Text>(find.text(_long)).overflow,
      TextOverflow.ellipsis,
    );
  });

  testWidgets('a new text starts again from its beginning', (tester) async {
    await _pump(tester, _long);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    expect(_moved(tester), greaterThan(0));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 120,
              child: MarqueeText('$_long and then some more'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(_moved(tester), 0);
  });

  testWidgets(
    'with a number of rounds, the line rests at its start after them',
    (tester) async {
      await _pump(tester, _long, rounds: 1);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));
      expect(_moved(tester), greaterThan(0));

      await tester.pump(const Duration(seconds: 30));
      expect(_moved(tester), 0);
      await tester.pump(const Duration(seconds: 30));
      expect(_moved(tester), 0);
      expect(tester.hasRunningAnimations, isFalse);
    },
  );

  testWidgets('rests while the phone is warm, and goes again once it is not', (
    tester,
  ) async {
    addTearDown(() => Calm.on.value = false);
    Calm.on.value = true;
    await _pump(tester, _long);
    await tester.pump(const Duration(seconds: 5));
    expect(_moved(tester), 0);
    expect(tester.hasRunningAnimations, isFalse);

    Calm.on.value = false;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    expect(_moved(tester), greaterThan(0));

    // Warm again half way: it goes back to its start and stays there
    Calm.on.value = true;
    await tester.pump();
    expect(_moved(tester), 0);
    await tester.pump(const Duration(seconds: 10));
    expect(_moved(tester), 0);
  });
}
