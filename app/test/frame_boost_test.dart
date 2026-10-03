import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/frame_boost.dart';

const fast = DisplayPace.fast;
const steady = DisplayPace.steady;
const free = DisplayPace.free;

void main() {
  /// Draws [count] frames [gapMs] apart by keeping something animating.
  Future<void> drawn(WidgetTester tester, int count, int gapMs) async {
    for (var i = 0; i < count; i++) {
      SchedulerBinding.instance.scheduleFrame();
      await tester.pump(Duration(milliseconds: gapMs));
    }
  }

  /// Lets every timer run out, the time after the last touch among them.
  Future<void> settle(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 3));

  /// The same with a finger on the screen, which lifts at the end.
  Future<void> frames(WidgetTester tester, int count, int gapMs) async {
    final finger = await tester.startGesture(const Offset(10, 10));
    await drawn(tester, count, gapMs);
    await finger.up();
  }

  testWidgets(
    'asks for the fastest rate while frames follow one another, and gives it back when they stop',
    (tester) async {
      final calls = <DisplayPace>[];
      final boost = FrameBoost(
        calls.add,
        idle: const Duration(milliseconds: 300),
      )..start();
      addTearDown(boost.dispose);

      await frames(tester, 10, 8);
      expect(calls, [fast]);
      expect(boost.pace, fast);

      await tester.pump(const Duration(milliseconds: 400));
      expect(calls, [fast, free]);
      expect(boost.pace, free);
      await settle(tester);
    },
  );

  testWidgets('a few frames a second are not movement', (tester) async {
    final calls = <DisplayPace>[];
    final boost = FrameBoost(calls.add)..start();
    addTearDown(boost.dispose);
    // A seek bar moves five times a second, the bars of the equalizer ten
    await frames(tester, 20, 200);
    await frames(tester, 20, 100);
    expect(calls, isEmpty);
    await settle(tester);
  });

  testWidgets('three frames in a row are not yet movement, four are', (
    tester,
  ) async {
    final calls = <DisplayPace>[];
    final boost = FrameBoost(calls.add)..start();
    addTearDown(boost.dispose);
    await frames(tester, 3, 16);
    expect(calls, isEmpty);
    await frames(tester, 2, 16);
    expect(calls, [fast]);
    await tester.pump(const Duration(seconds: 1)); // the quiet time runs out
    await settle(tester);
  });

  testWidgets(
    'goes on holding the rate while the movement goes on, and takes it only once',
    (tester) async {
      final calls = <DisplayPace>[];
      final boost = FrameBoost(
        calls.add,
        idle: const Duration(milliseconds: 300),
      )..start();
      addTearDown(boost.dispose);
      await frames(
        tester,
        30,
        16,
      ); // about half a second, longer than the quiet time
      expect(calls, [fast]);
      await tester.pump(const Duration(milliseconds: 400));
      expect(calls, [fast, free]);
      await settle(tester);
    },
  );

  testWidgets('a second movement asks again', (tester) async {
    final calls = <DisplayPace>[];
    final boost = FrameBoost(calls.add, idle: const Duration(milliseconds: 100))
      ..start();
    addTearDown(boost.dispose);
    await frames(tester, 8, 8);
    await tester.pump(const Duration(milliseconds: 300));
    await frames(tester, 8, 8);
    expect(calls, [fast, free, fast]);
    await tester.pump(const Duration(milliseconds: 300));
    await settle(tester);
  });

  testWidgets('gives the rate back when the app goes away during a movement', (
    tester,
  ) async {
    final calls = <DisplayPace>[];
    final boost = FrameBoost(calls.add)..start();
    await frames(tester, 8, 8);
    expect(calls, [fast]);
    boost.dispose();
    expect(calls, [fast, free]);
    await settle(tester);
  });

  testWidgets(
    'frames that nobody set off, like a scrolling title, ask for the normal rate, not the fastest',
    (tester) async {
      final calls = <DisplayPace>[];
      final boost = FrameBoost(calls.add)..start();
      addTearDown(boost.dispose);
      await drawn(tester, 120, 8);
      expect(calls, [steady]);
      await settle(tester);
      expect(calls, [steady, free]);
    },
  );

  testWidgets(
    'a movement that runs on after the finger lifts keeps the fastest rate a while, then the normal one',
    (tester) async {
      final calls = <DisplayPace>[];
      final boost = FrameBoost(
        calls.add,
        idle: const Duration(milliseconds: 300),
        afterTouch: const Duration(seconds: 1),
      )..start();
      addTearDown(boost.dispose);
      await frames(tester, 8, 8);
      expect(calls, [fast]);
      // A fling, or a title that goes on scrolling by itself
      await drawn(tester, 100, 8);
      expect(calls, [fast]);
      // The touch is a second old: what still moves, moves by itself
      await drawn(tester, 30, 8);
      expect(calls, [fast, steady]);
      await drawn(tester, 100, 8);
      expect(calls, [fast, steady]);
      await settle(tester);
      expect(calls, [fast, steady, free]);
    },
  );

  testWidgets('a key press counts as a touch', (tester) async {
    final calls = <DisplayPace>[];
    final boost = FrameBoost(calls.add)..start();
    addTearDown(boost.dispose);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await drawn(tester, 8, 8);
    expect(calls, [fast]);
    await tester.pump(const Duration(seconds: 3));
    await settle(tester);
  });
}
