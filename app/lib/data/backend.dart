import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import '../frame_boost.dart';

import 'models.dart';
import 'music_models.dart';
import 'update_info.dart';

sealed class BackendEvent {
  const BackendEvent();
}

class StateEvent extends BackendEvent {
  const StateEvent(this.snapshot);
  final RoomSnapshot snapshot;
}

class PositionEvent extends BackendEvent {
  const PositionEvent(this.position);
  final PlayerPosition position;
}

/// Someone opened a `sapoche://join/CODE` link.
class InviteEvent extends BackendEvent {
  const InviteEvent(this.code);
  final String code;
}

/// Someone opened a `sapoche://setup?server=…&key=…` link, which another phone shows to set this one up.
class SetupEvent extends BackendEvent {
  const SetupEvent(this.link);
  final String link;
}

/// Another member paused the room ([kind] `paused`) or switched the song (`skipped`).
class NoticeEvent extends BackendEvent {
  const NoticeEvent({required this.kind, required this.by, this.title});
  final String kind;
  final String by;
  final String? title;
}

/// Liked songs or the history changed, possibly while the screen was off.
class LibraryEvent extends BackendEvent {
  const LibraryEvent();
}

/// The sleep timer was set, ran out or was turned off.
class SleepEvent extends BackendEvent {
  const SleepEvent(this.sleep);
  final SleepState sleep;
}

/// A member's picture arrived, or ([bytes] null) they took it away.
class AvatarEvent extends BackendEvent {
  const AvatarEvent(this.id, this.bytes);
  final String id;
  final Uint8List? bytes;
}

/// The phone became warm or went into battery saver ([on]), or stopped being so.
class CalmEvent extends BackendEvent {
  const CalmEvent(this.on);
  final bool on;
}

/// The sound is now played to another place: headphones, a Bluetooth speaker, the phone itself.
class OutputEvent extends BackendEvent {
  const OutputEvent(this.output);
  final AudioOutput output;
}

/// How far an update of the app has come.
class UpdateEvent extends BackendEvent {
  const UpdateEvent(this.info);
  final UpdateInfo info;
}

class ErrorEvent extends BackendEvent {
  const ErrorEvent(this.error);
  final ServerError error;
}

/// Everything the UI needs from the native side: commands and a stream of state.
/// The player and the room connection live in the Android foreground service, not here.
abstract class Backend {
  Stream<BackendEvent> get events;

  Future<Profile> profile();

  /// Sets where the room server is and the key it asks for (iOS; on Android both are built into the app). What is
  /// left out stays as it was.
  Future<void> configure({String? server, String? key});

  /// A link that sets up another phone with this one's server and key (Android, which has them built in); null when
  /// there is no server. It holds the secret, so it is only for the person to see.
  Future<String?> setupLink();

  /// The app's cache folder, which the system may empty when it needs the room.
  Future<String?> cacheFolder();

  Future<String> createRoom(String name);
  Future<void> join(String code, String name);
  Future<void> leave();

  Future<void> play();
  Future<void> pause();
  Future<void> next();
  Future<void> prev();
  Future<void> seek(int positionMs);
  Future<void> jump(String itemId);

  /// Listen on this device alone ([on]) or follow the room again.
  Future<void> setSolo(bool on);

  /// Opens the system's list of places to play to.
  Future<void> pickOutput();

  /// The picture the room sees of this device, as base64 of a small JPEG; null for none.
  Future<void> setAvatar(String? base64);

  /// The room stopped but this device carries on by itself.
  Future<void> keepPlaying();

  Future<void> add(Track track, {bool playNext = false});
  Future<void> addMany(List<Track> tracks, {bool playNext = false});
  Future<void> setRepeat(Repeat mode);
  Future<void> remove(String itemId);

  /// Puts [track], another release of the same song, in place of the queue item [itemId]; the one playing carries
  /// on from the same moment. In a room it changes for everybody.
  Future<void> swap(String itemId, Track track);
  Future<void> move(String itemId, int toIndex);
  Future<void> clear();

  /// Videos matching [query]; with [songsOnly] just what YouTube Music lists as songs.
  Future<List<Track>> search(String query, {bool songsOnly = false});

  /// Mixes up the songs still to come; with the queue finished, mixes them all and plays from the top.
  Future<void> shuffle();

  /// Fills the personal queue, where [videoId] plays alone, with songs like it. Does nothing in a room, with
  /// autoplay off, or once the queue was changed.
  Future<void> fillRadio(String videoId);

  /// Play songs with their picture ([on]) or sound only.
  Future<void> setVideoMode(bool on);

  /// The picture is on screen ([visible]) or not; off, it is neither downloaded nor decoded.
  Future<void> setVideoVisible(bool visible);

  /// The id of the texture the picture is drawn into.
  Future<int> videoSurface();

  /// Tallest picture to fetch, in pixels.
  Future<void> setVideoQuality(int height);

  /// The songs behind a pasted YouTube link, or null when the text is not a link.
  Future<LinkResult?> lookup(String text);

  /// What the server says about the room with [code], or null when it cannot be reached.
  Future<RoomInfo?> roomInfo(String code);

  /// Owner only: remove a member from the room.
  Future<void> kick(String memberId);

  Future<void> setRoomName(String name);

  /// Owner only.
  Future<void> setGuestControl(GuestControl mode);

  Future<void> rename(String name);

  /// Opens the system share sheet with [text].
  Future<void> share(String text);

  /// Liked songs, the most recently liked first.
  Future<List<Track>> liked();

  /// Songs heard, once each, the most recent first.
  Future<List<HistoryEntry>> recent();

  Future<void> setLiked(Track track, bool liked);
  Future<void> clearHistory();

  /// The songs on the list of downloads, what is on the phone first.
  Future<List<DownloadEntry>> downloads();

  /// Asks for [tracks] to be downloaded. Gives back false, having done nothing, when the phone is on mobile
  /// data and [allowMetered] is not set: the person has to be asked first.
  Future<bool> download(List<Track> tracks, {bool allowMetered = false});

  Future<void> removeDownload(String videoId);
  Future<void> clearDownloads();

  Future<StorageInfo> storage();
  Future<void> clearPlayCache();

  /// Size of the cache of played songs in MB; counts from the next start of the app.
  Future<void> setCacheLimit(int mb);
  Future<void> setAutoDownload(bool on);

  /// Songs to offer, from what was kept; works without a network.
  Future<List<Track>> forYou();

  /// Fetches the suggestions again, whatever their age, and gives back the new list.
  Future<List<Track>> refreshSuggestions();

  /// Songs by artists the person does not know yet, from what was kept: something new to try.
  Future<List<Track>> discover();

  /// A mix for this time of day; no songs until enough was heard at this hour.
  Future<ContextMix> contextMix();

  /// Asks not to be offered [track], or with [artistOnly] its artist, any more.
  Future<void> block(Track track, {bool artistOnly = false});

  /// Lets a blocked song or artist be offered again.
  Future<void> unblock(BlockedItem item);

  /// What was blocked, the latest first.
  Future<List<BlockedItem>> blocked();

  /// What YouTube would complete [query] to; empty when it cannot say.
  Future<List<String>> suggest(String query);

  /// Whether the music carries on with similar songs when the queue runs out.
  Future<void> setAutoplay(bool on);

  /// The person's playlists, the one changed last first.
  Future<List<SavedPlaylist>> playlists();
  Future<List<Track>> playlistTracks(int id);

  /// Makes a playlist and gives back its id.
  Future<int> createPlaylist(String name, List<Track> tracks);
  Future<void> renamePlaylist(int id, String name);
  Future<void> deletePlaylist(int id);

  /// Adds songs to the end; those already there stay put. Gives back how many were added.
  Future<int> addToPlaylist(int id, List<Track> tracks);
  Future<void> removeFromPlaylist(int id, String videoId);
  Future<void> movePlaylistItem(int id, String videoId, int toIndex);

  /// Saves the library to a file the person picks. Null when they backed out.
  Future<BackupCounts?> exportBackup();

  /// Adds what a file the person picks holds to the library. Null when they backed out; throws when the file is no backup.
  Future<BackupCounts?> importBackup();

  /// Stops the music in [minutes] (mode time), when the song is over (song) or not at all (off).
  Future<void> setSleep(SleepMode mode, {int minutes = 0});

  /// What YouTube Music would play after the song, with the song itself first. Throws without a network.
  Future<SongRadio> musicNext(String videoId);

  /// The "related" page of a song: more like it, other performances, similar artists.
  Future<RelatedPage> musicRelated(String videoId);

  Future<ArtistPage> musicArtist(String artistId);

  /// An album or a playlist of YouTube Music, by the id of its page (`MPRE…` for an album).
  Future<CollectionPage> musicCollection(String id);

  /// The songs of a long playlist after [token], which the page or an earlier call gave.
  Future<MoreTracks> musicMore(String token);

  /// Everything YouTube Music finds for [query], or with [params] (a filter the page offered) only one kind of it.
  Future<SearchResults> musicSearchPage(String query, {String? params});

  /// The results of a search after [token], which the page or an earlier call gave.
  Future<SearchResults> musicSearchMore(String token);

  /// What YouTube Music shows everybody on its home page.
  Future<List<MusicShelf>> musicTrending();

  /// Songs (audio releases, with [songs]) or videos matching [query], as YouTube Music lists them.
  Future<List<MusicTrack>> musicSearch(String query, {required bool songs});

  /// The songs kept for each seed song, for "because you listened to".
  Future<List<SeedList>> seedLists();

  /// The words of a song, with times when there are any; null when nobody wrote them down.
  Future<Lyrics?> lyrics(Track track);

  Future<void> setTrim(int ms);
  Future<List<String>> log();

  /// Writes a line in the diary the log shows, for what only the screen can tell (how fast it was drawn).
  Future<void> note(String line);

  /// Asks the display for its fastest refresh rate while someone moves the screen, its normal one while the screen moves
  /// by itself, and nothing when it is still.
  Future<void> setDisplayPace(DisplayPace pace);

  /// Tells the native side which language the app speaks, for the few texts it shows itself.
  Future<void> setLanguage(String code);

  /// Asks the server for a newer version of the app; the answer comes as an [UpdateEvent].
  Future<void> updateCheck();

  /// Fetches the version on offer; false when it is waiting for a yes to mobile data.
  Future<bool> updateDownload({bool allowMetered = false});

  /// Hands the fetched version to Android to install; false when Android first has to be told to allow it.
  Future<bool> updateInstall();

  /// Opens the system page where the person lets this app install updates.
  Future<void> updateAllowInstalls();
}

/// [Backend] over Flutter platform channels, see SapocheBridge.kt.
class NativeBackend implements Backend {
  static const _control = MethodChannel('app.sapoche/control');
  static const _state = EventChannel('app.sapoche/state');

  /// One subscription to the platform channel, shared by everyone who listens: a second call to
  /// receiveBroadcastStream would take the stream over from the first listener.
  @override
  late final Stream<BackendEvent> events = _state.receiveBroadcastStream().map((
    raw,
  ) {
    final json = jsonDecode(raw as String) as Map<String, dynamic>;
    return switch (json['type']) {
      'position' => PositionEvent(PlayerPosition.fromJson(json)),
      'library' => const LibraryEvent(),
      'update' => UpdateEvent(UpdateInfo.fromJson(json)),
      'calm' => CalmEvent(json['on'] as bool),
      'output' => OutputEvent(AudioOutput.fromJson(json)),
      'avatar' => AvatarEvent(
        json['id'] as String,
        json['data'] == null ? null : base64Decode(json['data'] as String),
      ),
      'sleep' => SleepEvent(SleepState.fromJson(json)),
      'invite' => InviteEvent(json['code'] as String),
      'setup' => SetupEvent(json['link'] as String),
      'notice' => NoticeEvent(
        kind: json['kind'] as String,
        by: json['by'] as String? ?? '',
        title: json['title'] as String?,
      ),
      'error' => ErrorEvent(
        ServerError(json['code'] as String, json['message'] as String),
      ),
      _ => StateEvent(RoomSnapshot.fromJson(json)),
    };
  });

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _control.invokeMethod<T>(method, args);
    } on PlatformException catch (e) {
      throw BackendException(e.code, e.message ?? e.code);
    }
  }

  @override
  Future<Profile> profile() async =>
      Profile.fromMap((await _call<Map<Object?, Object?>>('profile'))!);

  @override
  Future<void> configure({String? server, String? key}) =>
      _call('configure', {'server': ?server, 'key': ?key});

  @override
  Future<String?> setupLink() => _call<String>('setupLink');

  @override
  Future<String?> cacheFolder() => _call<String>('cacheFolder');

  @override
  Future<String> createRoom(String name) async =>
      (await _call<String>('createRoom', {'name': name}))!;

  @override
  Future<void> join(String code, String name) =>
      _call('join', {'code': code, 'name': name});

  @override
  Future<void> leave() => _call('leave');

  @override
  Future<void> play() => _call('play');

  @override
  Future<void> pause() => _call('pause');

  @override
  Future<void> next() => _call('next');

  @override
  Future<void> prev() => _call('prev');

  @override
  Future<void> seek(int positionMs) => _call('seek', {'ms': positionMs});

  @override
  Future<void> jump(String itemId) => _call('jump', {'id': itemId});

  @override
  Future<void> setSolo(bool on) => _call('solo', {'on': on});

  @override
  Future<void> pickOutput() => _call<void>('pickOutput');

  @override
  Future<void> setAvatar(String? base64) =>
      _call<void>('setAvatar', {'data': base64});

  @override
  Future<void> keepPlaying() => _call('keepPlaying');

  @override
  Future<void> add(Track track, {bool playNext = false}) =>
      _call('add', {...track.toMap(), 'next': playNext});

  @override
  Future<void> addMany(List<Track> tracks, {bool playNext = false}) =>
      _call('addMany', {
        'tracks': [for (final t in tracks) t.toMap()],
        'next': playNext,
      });

  @override
  Future<void> setRepeat(Repeat mode) => _call('repeat', {'mode': mode.name});

  @override
  Future<void> remove(String itemId) => _call('remove', {'id': itemId});

  @override
  Future<void> swap(String itemId, Track track) =>
      _call('swap', {'id': itemId, 'track': track.toMap()});

  @override
  Future<void> move(String itemId, int toIndex) =>
      _call('move', {'id': itemId, 'to': toIndex});

  @override
  Future<void> clear() => _call('clear');

  @override
  Future<void> shuffle() => _call('shuffle');

  @override
  Future<void> fillRadio(String videoId) =>
      _call('radio', {'videoId': videoId});

  @override
  Future<void> setVideoMode(bool on) => _call('videoMode', {'on': on});

  @override
  Future<void> setVideoVisible(bool visible) =>
      _call('videoVisible', {'visible': visible});

  @override
  Future<int> videoSurface() async => (await _call<int>('videoSurface'))!;

  @override
  Future<void> setVideoQuality(int height) =>
      _call('videoQuality', {'height': height});

  @override
  Future<List<Track>> search(String query, {bool songsOnly = false}) async {
    final raw = await _call<List<Object?>>('search', {
      'query': query,
      'songsOnly': songsOnly,
    });
    return [
      for (final e in raw ?? const [])
        Track.fromMap(e as Map<Object?, Object?>),
    ];
  }

  @override
  Future<LinkResult?> lookup(String text) async {
    final raw = await _call<Map<Object?, Object?>>('lookup', {'text': text});
    return raw == null ? null : LinkResult.fromMap(raw);
  }

  @override
  Future<RoomInfo?> roomInfo(String code) async {
    try {
      final raw = await _call<Map<Object?, Object?>>('roomInfo', {
        'code': code,
      });
      return raw == null ? null : RoomInfo.fromMap(raw);
    } on BackendException {
      return null;
    }
  }

  @override
  Future<void> kick(String memberId) => _call('kick', {'id': memberId});

  @override
  Future<void> setRoomName(String name) => _call('roomName', {'name': name});

  @override
  Future<void> setGuestControl(GuestControl mode) =>
      _call('roomSettings', {'guestControl': mode.name});

  @override
  Future<void> rename(String name) => _call('rename', {'name': name});

  @override
  Future<void> share(String text) => _call('share', {'text': text});

  @override
  Future<List<Track>> liked() async => [
    for (final e in await _call<List<Object?>>('libraryLiked') ?? const [])
      Track.fromMap(e as Map<Object?, Object?>),
  ];

  @override
  Future<List<HistoryEntry>> recent() async => [
    for (final e in await _call<List<Object?>>('libraryRecent') ?? const [])
      HistoryEntry.fromMap(e as Map<Object?, Object?>),
  ];

  @override
  Future<void> setLiked(Track track, bool liked) =>
      _call('libraryLike', {...track.toMap(), 'on': liked});

  @override
  Future<void> clearHistory() => _call('libraryClearHistory');

  @override
  Future<List<DownloadEntry>> downloads() async => [
    for (final e in await _call<List<Object?>>('downloads') ?? const [])
      DownloadEntry.fromMap(e as Map<Object?, Object?>),
  ];

  @override
  Future<bool> download(
    List<Track> tracks, {
    bool allowMetered = false,
  }) async =>
      await _call<String>('download', {
        'tracks': [for (final t in tracks) t.toMap()],
        'allowMetered': allowMetered,
      }) ==
      'queued';

  @override
  Future<void> removeDownload(String videoId) =>
      _call('downloadRemove', {'videoId': videoId});

  @override
  Future<void> clearDownloads() => _call('downloadClear');

  @override
  Future<StorageInfo> storage() async =>
      StorageInfo.fromMap((await _call<Map<Object?, Object?>>('storage'))!);

  @override
  Future<void> clearPlayCache() => _call('clearPlayCache');

  @override
  Future<void> setCacheLimit(int mb) => _call('setCacheLimit', {'mb': mb});

  @override
  Future<void> setAutoDownload(bool on) => _call('setAutoDownload', {'on': on});

  @override
  Future<List<Track>> forYou() async => [
    for (final e in await _call<List<Object?>>('forYou') ?? const [])
      Track.fromMap(e as Map<Object?, Object?>),
  ];

  @override
  Future<List<Track>> refreshSuggestions() async => [
    for (final e
        in await _call<List<Object?>>('refreshSuggestions') ?? const [])
      Track.fromMap(e as Map<Object?, Object?>),
  ];

  @override
  Future<List<Track>> discover() async => [
    for (final e in await _call<List<Object?>>('discover') ?? const [])
      Track.fromMap(e as Map<Object?, Object?>),
  ];

  @override
  Future<ContextMix> contextMix() async => ContextMix.fromMap(
    await _call<Map<Object?, Object?>>('contextMix') ?? const {},
  );

  @override
  Future<void> block(Track track, {bool artistOnly = false}) =>
      _call<void>('block', {
        'videoId': track.videoId,
        'title': track.title,
        'artist': track.artist,
        'artistOnly': artistOnly,
      });

  @override
  Future<void> unblock(BlockedItem item) =>
      _call<void>('unblock', {'kind': item.kind, 'key': item.key});

  @override
  Future<List<BlockedItem>> blocked() async => [
    for (final e in await _call<List<Object?>>('blocked') ?? const [])
      BlockedItem.fromMap(e as Map<Object?, Object?>),
  ];

  @override
  Future<List<String>> suggest(String query) async =>
      (await _call<List<Object?>>('suggest', {'query': query}) ?? const [])
          .cast<String>();

  @override
  Future<void> setAutoplay(bool on) => _call('setAutoplay', {'on': on});

  @override
  Future<SongRadio> musicNext(String videoId) async => SongRadio.fromMap(
    (await _call<Map<Object?, Object?>>('musicNext', {'videoId': videoId}))!,
  );

  @override
  Future<RelatedPage> musicRelated(String videoId) async => RelatedPage.fromMap(
    (await _call<Map<Object?, Object?>>('musicRelated', {'videoId': videoId}))!,
  );

  @override
  Future<ArtistPage> musicArtist(String artistId) async => ArtistPage.fromMap(
    (await _call<Map<Object?, Object?>>('musicArtist', {'id': artistId}))!,
  );

  @override
  Future<SearchResults> musicSearchPage(String query, {String? params}) async =>
      SearchResults.fromMap(
        (await _call<Map<Object?, Object?>>('musicSearchPage', {
          'query': query,
          'params': params,
        }))!,
      );

  @override
  Future<SearchResults> musicSearchMore(String token) async =>
      SearchResults.fromMap(
        (await _call<Map<Object?, Object?>>('musicSearchMore', {
          'token': token,
        }))!,
      );

  @override
  Future<CollectionPage> musicCollection(String id) async =>
      CollectionPage.fromMap(
        (await _call<Map<Object?, Object?>>('musicCollection', {'id': id}))!,
      );

  @override
  Future<MoreTracks> musicMore(String token) async => MoreTracks.fromMap(
    (await _call<Map<Object?, Object?>>('musicMore', {'token': token}))!,
  );

  @override
  Future<List<MusicShelf>> musicTrending() async => [
    for (final e in await _call<List<Object?>>('musicTrending') ?? const [])
      MusicShelf.fromMap(e as Map<Object?, Object?>),
  ];

  @override
  Future<List<MusicTrack>> musicSearch(
    String query, {
    required bool songs,
  }) async => [
    for (final e
        in await _call<List<Object?>>('musicSearch', {
              'query': query,
              'songs': songs,
            }) ??
            const [])
      MusicTrack.fromMap(e as Map<Object?, Object?>),
  ];

  @override
  Future<List<SeedList>> seedLists() async => [
    for (final e in await _call<List<Object?>>('seedLists') ?? const [])
      SeedList.fromMap(e as Map<Object?, Object?>),
  ];

  @override
  Future<Lyrics?> lyrics(Track track) async {
    final found = await _call<Map<Object?, Object?>>('lyrics', {
      'videoId': track.videoId,
      'title': track.title,
      'artist': track.artist,
      'durMs': track.durMs,
    });
    return found == null ? null : Lyrics.fromMap(found);
  }

  @override
  Future<List<SavedPlaylist>> playlists() async => [
    for (final e in await _call<List<Object?>>('playlists') ?? const [])
      SavedPlaylist.fromMap(e as Map<Object?, Object?>),
  ];

  @override
  Future<List<Track>> playlistTracks(int id) async => [
    for (final e
        in await _call<List<Object?>>('playlistTracks', {'id': id}) ?? const [])
      Track.fromMap(e as Map<Object?, Object?>),
  ];

  @override
  Future<int> createPlaylist(String name, List<Track> tracks) async =>
      (await _call<int>('playlistCreate', {
        'name': name,
        'tracks': [for (final t in tracks) t.toMap()],
      }))!;

  @override
  Future<void> renamePlaylist(int id, String name) =>
      _call('playlistRename', {'id': id, 'name': name});

  @override
  Future<void> deletePlaylist(int id) => _call('playlistDelete', {'id': id});

  @override
  Future<int> addToPlaylist(int id, List<Track> tracks) async =>
      (await _call<int>('playlistAdd', {
        'id': id,
        'tracks': [for (final t in tracks) t.toMap()],
      }))!;

  @override
  Future<void> removeFromPlaylist(int id, String videoId) =>
      _call('playlistRemove', {'id': id, 'videoId': videoId});

  @override
  Future<void> movePlaylistItem(int id, String videoId, int toIndex) =>
      _call('playlistMove', {'id': id, 'videoId': videoId, 'to': toIndex});

  @override
  Future<BackupCounts?> exportBackup() async {
    final raw = await _call<Map<Object?, Object?>>('backupExport');
    return raw == null ? null : BackupCounts.fromMap(raw);
  }

  @override
  Future<BackupCounts?> importBackup() async {
    final raw = await _call<Map<Object?, Object?>>('backupImport');
    return raw == null ? null : BackupCounts.fromMap(raw);
  }

  @override
  Future<void> setSleep(SleepMode mode, {int minutes = 0}) =>
      _call('sleep', {'mode': mode.name, 'minutes': minutes});

  @override
  Future<void> setTrim(int ms) => _call('setTrim', {'ms': ms});

  @override
  Future<List<String>> log() async =>
      (await _call<List<Object?>>('log') ?? const []).cast<String>();

  @override
  Future<void> note(String line) async {
    try {
      await _call<void>('note', {'line': line});
    } on Object {
      // A diary that cannot be written to must not break what is being measured
    }
  }

  @override
  Future<void> setDisplayPace(DisplayPace pace) =>
      _call<void>('smooth', {'pace': pace.name});

  @override
  Future<void> setLanguage(String code) =>
      _call<void>('setLanguage', {'code': code});

  @override
  Future<void> updateCheck() => _call<void>('updateCheck');

  @override
  Future<bool> updateDownload({bool allowMetered = false}) async =>
      await _call<String>('updateDownload', {'allowMetered': allowMetered}) !=
      'metered';

  @override
  Future<bool> updateInstall() async =>
      await _call<String>('updateInstall') != 'permission';

  @override
  Future<void> updateAllowInstalls() => _call<void>('updateAllowInstalls');
}

class BackendException implements Exception {
  BackendException(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => message;
}
