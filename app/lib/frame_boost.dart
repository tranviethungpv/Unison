import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'data/calm.dart';

/// What the display is asked for.
enum DisplayPace {
  /// Nothing: the system chooses, as it does for a still screen.
  free,

  /// Its normal rate, 60 Hz, for what moves by itself: a title that scrolls, a background that drifts. Left to choose,
  /// a phone may show those at its fastest, drawing twice the frames for a movement no finger is following.
  steady,

  /// Its fastest rate, while someone moves the screen.
  fast,
}

/// Tells the display how fast the screen is moving, so that it runs at its fastest only then. Frames that follow one
/// another closely (a drag, a fling, a page sliding in) are movement; the few frames a second of a seek bar or the
/// bars of the equalizer are not, and must not hold a 120 Hz display awake.
///
/// Only movement that someone set off gets the fastest rate: frames while a finger (or a mouse, or a key) is at work,
/// or shortly after, for a fling that runs on or a page that settles. Frames that come one after another with no touch
/// at all (a scrolling title, a drifting background) get the normal rate: at the fastest one they kept a phone at
/// over 100 frames a second without a touch, and warm. While the phone is warm or saving power ([Calm]) everything
/// gets the normal rate.
class FrameBoost {
  FrameBoost(this._set, {Duration? idle, Duration? afterTouch})
    : _idle = idle ?? const Duration(milliseconds: 700),
      _afterTouch = afterTouch ?? const Duration(seconds: 2);

  final void Function(DisplayPace pace) _set;
  final Duration _idle;

  /// How long after the last touch frames still count as movement.
  final Duration _afterTouch;

  /// Frames closer than this are one movement.
  static const _together = Duration(milliseconds: 40);

  /// How many in a row make it movement.
  static const _streakToBoost = 4;

  Duration? _last;
  int _streak = 0;
  DisplayPace _pace = DisplayPace.free;
  Timer? _timer;
  bool _started = false;
  bool _disposed = false;

  /// The pointers that are down, and whether one moved or a key was pressed within [_afterTouch].
  final _down = <int>{};
  bool _recent = false;
  Timer? _touchTimer;

  DisplayPace get pace => _pace;

  void start() {
    if (_started) return;
    _started = true;
    SchedulerBinding.instance.addPersistentFrameCallback(_onFrame);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent) _down.add(event.pointer);
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _down.remove(event.pointer);
    }
    _touch();
  }

  bool _onKey(KeyEvent event) {
    _touch();
    return false;
  }

  void _touch() {
    _recent = true;
    _touchTimer?.cancel();
    _touchTimer = Timer(_afterTouch, () => _recent = false);
  }

  bool get _touched => _recent || _down.isNotEmpty;

  void _onFrame(Duration time) {
    if (_disposed) return;
    final last = _last;
    _last = time;
    _streak = last != null && time - last < _together ? _streak + 1 : 1;
    if (_pace == DisplayPace.free && _streak < _streakToBoost) return;
    // While the phone is warm or saving power even a finger gets the normal rate
    final wanted = _touched && !Calm.on.value
        ? DisplayPace.fast
        : DisplayPace.steady;
    if (wanted != _pace) {
      _pace = wanted;
      _set(wanted);
    }
    _timer?.cancel();
    _timer = Timer(_idle, _release);
  }

  void _release() {
    _pace = DisplayPace.free;
    _streak = 0;
    _set(DisplayPace.free);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _touchTimer?.cancel();
    if (_started) {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
      HardwareKeyboard.instance.removeHandler(_onKey);
    }
    if (_pace != DisplayPace.free) _set(DisplayPace.free);
  }
}
