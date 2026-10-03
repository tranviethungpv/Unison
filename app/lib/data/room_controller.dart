import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../strings.dart';
import 'backend.dart';
import 'calm.dart';
import 'models.dart';
import 'recent_rooms.dart';
import 'setup_link.dart';

/// Something another member did that moved this device: worth a snackbar, sometimes with a way out.
class Notice {
  const Notice(this.text, {this.canKeepPlaying = false});

  final String text;

  /// The room paused and this device may prefer to go on alone.
  final bool canKeepPlaying;
}

/// The room as the UI sees it: latest state from the native side plus the actions a user can take.
///
/// Room structure notifies listeners rarely; the player position lives in [player] and is
/// extrapolated by [positionMs], so nothing has to rebuild sixty times a second.
class RoomController extends ChangeNotifier {
  RoomController(this._backend, {this._recents}) {
    player.addListener(_updatePlayState);
    addListener(_updatePlayState);
  }

  final Backend _backend;
  final RecentRooms? _recents;
  StreamSubscription<BackendEvent>? _subscription;

  RoomSnapshot _snapshot = const RoomSnapshot();
  SleepState _sleep = const SleepState();
  AudioOutput _output = const AudioOutput();

  /// The pictures the other members chose, by member id.
  final _avatars = <String, Uint8List>{};
  Profile _profile = const Profile();
  bool _ready = false;

  /// Local player state, updated about once a second while the screen is on.
  final ValueNotifier<PlayerPosition> player = ValueNotifier(
    const PlayerPosition(),
  );
  final Stopwatch _sinceSample = Stopwatch();

  /// [isPlaying] and [isStarting], told only when one of them changes: for what shows a play button or moves while a
  /// song plays. Listening to [player] instead draws the screen again at every position the phone sends, for nothing.
  final ValueNotifier<(bool playing, bool starting)> playState = ValueNotifier((
    false,
    false,
  ));

  void _updatePlayState() => playState.value = (isPlaying, isStarting);

  /// While the user's seek is in flight the bar stays where they dropped it.
  int? _seekTarget;
  Timer? _seekTimer;

  /// A room code from an invitation link that the UI has not dealt with yet.
  final ValueNotifier<String?> invite = ValueNotifier(null);

  /// A setup link that was opened, for the screen to check and ask about.
  final ValueNotifier<SetupLink?> setup = ValueNotifier(null);

  final _messages = StreamController<String>.broadcast();
  final _notices = StreamController<Notice>.broadcast();

  /// What other members did to this device, see [Notice].
  Stream<Notice> get notices => _notices.stream;

  /// While listening alone, what the play button shows right after a tap, before the player reports back.
  bool? _soloPlaying;

  /// Short notices for a snackbar: server errors, failed actions.
  Stream<String> get messages => _messages.stream;

  RoomSnapshot get snapshot => _snapshot;

  /// When the music is set to stop by itself.
  SleepState get sleep => _sleep;

  /// Where the sound goes now.
  AudioOutput get output => _output;

  /// The picture a member chose, or null when they have none.
  Uint8List? avatarOf(String memberId) => _avatars[memberId];
  Profile get profile => _profile;

  /// False until the first state arrived from the native side.
  bool get ready => _ready;

  Future<void> start() async {
    _subscription = _backend.events.listen(_onEvent);
    try {
      _profile = await _backend.profile();
    } on Object {
      // The name field just starts empty
    }
    notifyListeners();
  }

  void _onEvent(BackendEvent event) {
    switch (event) {
      case StateEvent(:final snapshot):
        if (snapshot.ownPlayback != _snapshot.ownPlayback) _soloPlaying = null;
        final code = snapshot.room;
        if (code != null) _recents?.touch(code, name: snapshot.name);
        _snapshot = snapshot;
        // A picture is kept while its owner is in the room
        _avatars.removeWhere(
          (id, _) => !snapshot.members.any((m) => m.id == id),
        );
        _ready = true;
        notifyListeners();
      case NoticeEvent(:final kind, :final by, :final title):
        final who = by.isEmpty ? S.someone : by;
        if (kind == 'paused') {
          _notices.add(Notice(S.pausedBy(who), canKeepPlaying: true));
        } else if (kind == 'skipped') {
          _notices.add(Notice(S.skippedBy(who, title ?? '')));
        }
      case PositionEvent(:final position):
        _soloPlaying = null;
        _sinceSample
          ..reset()
          ..start();
        player.value = position;
      case InviteEvent(:final code):
        invite.value = code;
      case SetupEvent(:final link):
        // A link that is not one is ignored, as is any other thing that is opened
        final parsed = SetupLink.parse(link);
        if (parsed != null) setup.value = parsed;
      case SleepEvent(:final sleep):
        _sleep = sleep;
        notifyListeners();
      case AvatarEvent(:final id, :final bytes):
        if (bytes == null) {
          _avatars.remove(id);
        } else {
          _avatars[id] = bytes;
        }
        notifyListeners();
      case OutputEvent(:final output):
        _output = output;
        notifyListeners();
      case LibraryEvent():
        break; // LibraryController listens for this itself
      case UpdateEvent():
        break; // and UpdateController for this
      case CalmEvent(:final on):
        Calm.on.value = on;
      case ErrorEvent(:final error):
        final text = _describe(error);
        if (text != null) _messages.add(text);
    }
  }

  /// Lets the native side know which language is shown, for the texts it writes itself.
  Future<void> setLanguage(String code) => _backend.setLanguage(code);

  String? _describe(ServerError error) {
    if (error.code == 'unplayable') {
      // The message reads "Nobody could load: <title>", and from the iPhone a second line says what went wrong
      final lines = error.message.split('\n');
      final title = lines.first.split(': ').skip(1).join(': ');
      final text = S.unplayable(title.isEmpty ? S.thisSong : title);
      final cause = lines.skip(1).join(' ').trim();
      return cause.isEmpty ? text : '$text\n$cause';
    }
    return S.serverError(error.code) ?? error.message;
  }

  // ------------------------------------------------------------------ derived state

  /// Position of the current song now, in ms.
  int positionMs() {
    final target = _seekTarget;
    if (target != null) return target;
    final p = player.value;
    if (!p.playing) return p.positionMs;
    final advanced =
        p.positionMs + (_sinceSample.elapsedMilliseconds * p.speed).round();
    final limit = p.durationMs > 0 ? p.durationMs : advanced;
    return advanced < limit ? advanced : limit;
  }

  /// Total length of the current song: from the player once known, else from the queue entry.
  int durationMs() {
    final fromPlayer = player.value.durationMs;
    return fromPlayer > 0 ? fromPlayer : (_snapshot.current?.durMs ?? 0);
  }

  /// Sound is coming or is already playing (used for the play/pause glyph). Outside a room, and while
  /// listening alone, this is about this device's own player, not the room.
  bool get isPlaying => _snapshot.ownPlayback
      ? (_soloPlaying ?? (player.value.playing || player.value.buffering))
      : _snapshot.wantsPlaying;

  /// The room started something but nothing is audible yet: everyone is still loading.
  bool get isStarting => _snapshot.ownPlayback
      ? isPlaying && player.value.buffering
      : _snapshot.phase == 'preparing' || (isPlaying && player.value.buffering);

  // ------------------------------------------------------------------ room

  /// Returns null on success, else a message for the user.
  Future<String?> createRoom(String name) async {
    try {
      await _backend.createRoom(name.trim());
      return null;
    } on BackendException catch (e) {
      return e.code == 'not_configured'
          ? S.serverNotSet
          : '${S.createFailed}: $e';
    } on Object catch (e) {
      return '${S.createFailed}: $e';
    }
  }

  Future<String?> join(String code, String name) async {
    try {
      await _backend.join(code.trim().toUpperCase(), name.trim());
      return null;
    } on BackendException catch (e) {
      return e.code == 'not_configured'
          ? S.serverNotSet
          : '${S.joinFailed}: $e';
    } on Object catch (e) {
      return '${S.joinFailed}: $e';
    }
  }

  /// Where the room server is and its key; what is left out stays as it was.
  Future<void> configure({String? server, String? key}) async {
    await _backend.configure(server: server, key: key);
    _profile = await _backend.profile();
    notifyListeners();
  }

  /// The link that sets up another phone like this one; null when this one has no server.
  Future<String?> setupLink() => _backend.setupLink();

  Future<void> leave() => _run(_backend.leave);

  /// Address that opens the app on this room from a chat message, or the app's own link when the
  /// server's address is not known.
  String inviteLink(String code) => _profile.server.isEmpty
      ? 'sapoche://join/$code'
      : '${_profile.server}/join/$code';

  /// What the server says about a room, for the list of recent ones.
  Future<RoomInfo?> roomInfo(String code) => _backend.roomInfo(code);

  Future<void> setRoomName(String name) =>
      _run(() => _backend.setRoomName(name.trim()));

  Future<void> setGuestControl(GuestControl mode) =>
      _run(() => _backend.setGuestControl(mode));

  /// Owner only: remove a member from the room.
  Future<void> kick(Member member) => _run(() => _backend.kick(member.id));

  /// Changes the name the others see; playback carries on.
  Future<void> rename(String name) async {
    await _run(() => _backend.rename(name.trim()));
    // Outside a room there is no state to carry the name back: read it where it is kept
    try {
      _profile = await _backend.profile();
      notifyListeners();
    } on Object {
      // The name shown stays as it was
    }
  }

  /// Sends the room code (and a link that opens the app on it) through the share sheet.
  Future<void> shareInvite() {
    final code = _snapshot.room;
    if (code == null) return Future.value();
    return _run(() => _backend.share(S.inviteText(code, inviteLink(code))));
  }

  // ------------------------------------------------------------------ transport

  Future<void> togglePlay() {
    final playing = isPlaying;
    if (_snapshot.ownPlayback) {
      _soloPlaying = !playing;
      notifyListeners();
    }
    return _run(playing ? _backend.pause : _backend.play);
  }

  /// Listen on this device alone ([on]) or follow the room again.
  Future<void> setSolo(bool on) => _run(() => _backend.setSolo(on));

  /// Opens the system's list of places to play to.
  Future<void> pickOutput() => _run(_backend.pickOutput);

  /// Shows [picture] to the room as this device's own, or with null takes it away. A picture too big to send stays
  /// on this phone.
  Future<void> shareAvatar(Uint8List? picture) {
    final text = picture == null ? null : base64Encode(picture);
    return _run(
      () => _backend.setAvatar(
        text != null && text.length <= maxAvatarChars ? text : null,
      ),
    );
  }

  /// The longest base64 text of a picture the room accepts.
  static const maxAvatarChars = 24000;

  /// Carry on playing by myself after the room paused.
  Future<void> keepPlaying() => _run(_backend.keepPlaying);
  Future<void> next() => _run(_backend.next);
  Future<void> prev() => _run(_backend.prev);
  Future<void> jump(QueueEntry entry) => _run(() => _backend.jump(entry.id));

  Future<void> seek(int positionMs) {
    _seekTarget = positionMs;
    _seekTimer?.cancel();
    _seekTimer = Timer(
      const Duration(milliseconds: 1500),
      () => _seekTarget = null,
    );
    return _run(() => _backend.seek(positionMs));
  }

  // ------------------------------------------------------------------ queue

  /// Songs that are waiting in the queue already are not added again.
  Future<void> add(Track track, {bool playNext = false}) async {
    if (_snapshot.isQueued(track)) return;
    await _run(() => _backend.add(track, playNext: playNext));
  }

  /// Plays [other], another release of the song, in place of [entry].
  Future<void> swapVersion(QueueEntry entry, Track other) =>
      _run(() => _backend.swap(entry.id, other));

  Future<void> remove(QueueEntry entry) =>
      _run(() => _backend.remove(entry.id));
  Future<void> move(QueueEntry entry, int toIndex) =>
      _run(() => _backend.move(entry.id, toIndex));
  Future<void> clearQueue() => _run(_backend.clear);
  Future<void> shuffle() => _run(_backend.shuffle);
  Future<void> addMany(List<Track> tracks, {bool playNext = false}) async {
    final fresh = _snapshot.fresh(tracks);
    if (fresh.isEmpty) return;
    await _run(() => _backend.addMany(fresh, playNext: playNext));
  }

  /// Outside a room: replaces the queue with [tracks] and starts them. In a room the queue belongs
  /// to everybody, so they are only added to it.
  Future<void> playTracks(List<Track> tracks) async {
    if (!_snapshot.inRoom) await _run(_backend.clear);
    await addMany(tracks);
  }

  /// Outside a room: plays [track] in place of the queue and lets songs like it follow, as YouTube Music does
  /// when a song is tapped.
  Future<void> playSong(Track track) async {
    await playTracks([track]);
    await _run(() => _backend.fillRadio(track.videoId));
  }

  /// Stops the music in [minutes]; with [SleepMode.song] at the end of this song, with [SleepMode.off] never.
  Future<void> setSleep(SleepMode mode, {int minutes = 0}) =>
      _run(() => _backend.setSleep(mode, minutes: minutes));

  Future<void> cycleRepeat() =>
      _run(() => _backend.setRepeat(_snapshot.repeat.next));

  // ------------------------------------------------------------------ search and settings

  Future<List<Track>> search(String query, {bool songsOnly = false}) =>
      _backend.search(query, songsOnly: songsOnly);
  Future<LinkResult?> lookup(String text) => _backend.lookup(text);

  /// Whether the music carries on with similar songs when the queue runs out.
  bool get autoplay => _profile.autoplay;

  Future<void> setAutoplay(bool on) {
    _profile = _profile.withAutoplay(on);
    notifyListeners();
    return _run(() => _backend.setAutoplay(on));
  }

  /// What YouTube would complete a half-typed search to.
  Future<List<String>> suggest(String query) async {
    try {
      return await _backend.suggest(query);
    } on Object {
      return const [];
    }
  }

  Future<void> setTrim(int ms) => _run(() => _backend.setTrim(ms));

  /// Play songs with their picture on this device, or sound only.
  Future<void> setVideoMode(bool on) => _run(() => _backend.setVideoMode(on));

  /// The picture views that are seen now. When the phone turns, the new layout's view comes before the old one's
  /// goes, so a view that leaves must not hide the picture another still shows: the player is told whether any is seen.
  final Set<Object> _videoViewsSeen = {};

  /// Whether [view], a picture view, is seen: on screen with the app in front.
  Future<void> setVideoSeen(Object view, bool seen) {
    if (seen) {
      _videoViewsSeen.add(view);
    } else {
      _videoViewsSeen.remove(view);
    }
    return _run(() => _backend.setVideoVisible(_videoViewsSeen.isNotEmpty));
  }

  /// The texture the picture is drawn into, or null when it cannot be made.
  Future<int?> videoSurface() async {
    try {
      return await _backend.videoSurface();
    } on Object {
      return null;
    }
  }

  Future<void> setVideoQuality(int height) =>
      _run(() => _backend.setVideoQuality(height));
  Future<List<String>> log() => _backend.log();

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } on BackendException catch (e) {
      _messages.add(e.code == 'no_room' ? S.notInRoom : e.message);
    } on Object catch (e) {
      _messages.add('$e');
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _seekTimer?.cancel();
    _messages.close();
    _notices.close();
    player.dispose();
    playState.dispose();
    invite.dispose();
    setup.dispose();
    super.dispose();
  }
}
