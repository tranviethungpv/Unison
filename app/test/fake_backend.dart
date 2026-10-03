import 'dart:async';

import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/music_models.dart';
import 'package:sapoche/data/song_key.dart';
import 'package:sapoche/frame_boost.dart';

/// In-memory [Backend] that records calls and lets a test push state.
class FakeBackend implements Backend {
  final _events = StreamController<BackendEvent>.broadcast();
  final calls = <String>[];

  void emit(BackendEvent event) => _events.add(event);

  Profile profileValue = const Profile(name: 'Anna');
  List<Track> searchResults = const [];
  Object? failWith;

  /// When set, searches wait for it, so a test can look at the loading state.
  Completer<void>? searchGate;

  @override
  Stream<BackendEvent> get events => _events.stream;

  Future<void> _record(String call) async {
    calls.add(call);
    if (failWith != null) throw failWith!;
  }

  @override
  Future<Profile> profile() async => profileValue;

  @override
  Future<void> configure({String? server, String? key}) =>
      _record('configure $server $key');

  /// What the setup link of this phone is, when it has one.
  String? setupLinkValue;

  @override
  Future<String?> setupLink() async => setupLinkValue;

  @override
  Future<String?> cacheFolder() async => null;

  @override
  Future<String> createRoom(String name) async {
    await _record('createRoom $name');
    return 'ABC234';
  }

  @override
  Future<void> join(String code, String name) => _record('join $code $name');

  @override
  Future<void> leave() => _record('leave');

  @override
  Future<void> play() => _record('play');

  @override
  Future<void> pause() => _record('pause');

  @override
  Future<void> next() => _record('next');

  @override
  Future<void> prev() => _record('prev');

  @override
  Future<void> seek(int positionMs) => _record('seek $positionMs');

  @override
  Future<void> jump(String itemId) => _record('jump $itemId');

  @override
  Future<void> setSolo(bool on) => _record('solo $on');

  @override
  Future<void> keepPlaying() => _record('keepPlaying');

  @override
  Future<void> add(Track track, {bool playNext = false}) =>
      _record('add ${track.videoId} next=$playNext');

  @override
  Future<void> addMany(List<Track> tracks, {bool playNext = false}) => _record(
    'addMany ${tracks.map((t) => t.videoId).join(',')} next=$playNext',
  );

  @override
  Future<void> setRepeat(Repeat mode) => _record('repeat ${mode.name}');

  @override
  Future<void> rename(String name) async {
    await _record('rename $name');
    profileValue = Profile(name: name);
  }

  @override
  Future<void> share(String text) => _record('share $text');

  @override
  Future<void> remove(String itemId) => _record('remove $itemId');

  @override
  Future<void> move(String itemId, int toIndex) =>
      _record('move $itemId $toIndex');

  @override
  Future<void> clear() => _record('clear');

  @override
  Future<void> shuffle() => _record('shuffle');

  @override
  Future<void> swap(String itemId, Track track) =>
      _record('swap $itemId ${track.videoId}');

  @override
  Future<void> fillRadio(String videoId) => _record('radio $videoId');

  @override
  Future<void> setVideoMode(bool on) => _record('video $on');

  @override
  Future<void> setVideoVisible(bool visible) =>
      _record('videoVisible $visible');

  @override
  Future<int> videoSurface() async {
    await _record('videoSurface');
    return 7;
  }

  @override
  Future<void> setVideoQuality(int height) => _record('videoQuality $height');

  @override
  Future<List<Track>> search(String query, {bool songsOnly = false}) async {
    await _record(songsOnly ? 'search $query songs' : 'search $query');
    await searchGate?.future;
    return searchResults;
  }

  LinkResult? lookupResult;

  @override
  Future<LinkResult?> lookup(String text) async {
    await _record('lookup $text');
    return lookupResult;
  }

  RoomInfo? roomInfoResult;

  @override
  Future<RoomInfo?> roomInfo(String code) async {
    await _record('roomInfo $code');
    return roomInfoResult;
  }

  @override
  Future<void> kick(String memberId) => _record('kick $memberId');

  @override
  Future<void> setRoomName(String name) => _record('roomName $name');

  @override
  Future<void> setGuestControl(GuestControl mode) =>
      _record('guestControl ${mode.name}');

  List<Track> likedSongs = [];
  List<HistoryEntry> recentSongs = [];

  @override
  Future<List<Track>> liked() async {
    await _record('liked');
    return [...likedSongs];
  }

  @override
  Future<List<HistoryEntry>> recent() async {
    await _record('recent');
    return [...recentSongs];
  }

  @override
  Future<void> setLiked(Track track, bool liked) async {
    await _record('like ${track.videoId} $liked');
    likedSongs.removeWhere((t) => t.videoId == track.videoId);
    if (liked) likedSongs.insert(0, track);
  }

  @override
  Future<void> clearHistory() async {
    await _record('clearHistory');
    recentSongs = [];
  }

  final downloadList = <DownloadEntry>[];

  /// Set to pretend the phone is on mobile data.
  bool metered = false;
  StorageInfo storageInfo = const StorageInfo();

  @override
  Future<List<DownloadEntry>> downloads() async {
    await _record('downloads');
    return [...downloadList];
  }

  @override
  Future<bool> download(List<Track> tracks, {bool allowMetered = false}) async {
    await _record(
      'download ${tracks.map((t) => t.videoId).join(',')} metered=$allowMetered',
    );
    if (metered && !allowMetered) return false;
    for (final t in tracks) {
      if (downloadList.any((e) => e.track.videoId == t.videoId)) continue;
      downloadList.add(DownloadEntry(track: t, state: DownloadState.queued));
    }
    return true;
  }

  @override
  Future<void> removeDownload(String videoId) async {
    await _record('removeDownload $videoId');
    downloadList.removeWhere((e) => e.track.videoId == videoId);
  }

  @override
  Future<void> clearDownloads() async {
    await _record('clearDownloads');
    downloadList.clear();
  }

  @override
  Future<StorageInfo> storage() async {
    await _record('storage');
    return storageInfo;
  }

  @override
  Future<void> clearPlayCache() => _record('clearPlayCache');

  @override
  Future<void> setCacheLimit(int mb) => _record('cacheLimit $mb');

  @override
  Future<void> setAutoDownload(bool on) => _record('autoDownload $on');

  List<Track> forYouSongs = [];
  List<Track> refreshedSongs = [];
  List<String> suggestions = [];

  @override
  Future<List<Track>> forYou() async {
    await _record('forYou');
    return [...forYouSongs];
  }

  @override
  Future<List<Track>> refreshSuggestions() async {
    await _record('refreshSuggestions');
    forYouSongs = [...refreshedSongs];
    return [...forYouSongs];
  }

  List<Track> discoverSongs = [];
  ContextMix contextMixResult = const ContextMix();
  List<BlockedItem> blockedItems = [];

  @override
  Future<List<Track>> discover() async {
    await _record('discover');
    return [...discoverSongs];
  }

  @override
  Future<ContextMix> contextMix() async {
    await _record('contextMix');
    return contextMixResult;
  }

  @override
  Future<void> block(Track track, {bool artistOnly = false}) async {
    await _record(
      artistOnly ? 'block artist ${track.artist}' : 'block ${track.videoId}',
    );
    blockedItems = [
      BlockedItem(
        kind: artistOnly ? 'artist' : 'song',
        key: artistOnly ? mainArtist(track.artist) : track.videoId,
        label: artistOnly ? displayArtist(track.artist) : track.title,
      ),
      ...blockedItems,
    ];
  }

  @override
  Future<void> unblock(BlockedItem item) async {
    await _record('unblock ${item.kind} ${item.key}');
    blockedItems = [
      for (final b in blockedItems)
        if (b.kind != item.kind || b.key != item.key) b,
    ];
  }

  @override
  Future<List<BlockedItem>> blocked() async {
    await _record('blocked');
    return [...blockedItems];
  }

  @override
  Future<List<String>> suggest(String query) async {
    await _record('suggest $query');
    return suggestions;
  }

  /// What the file the person "picks" holds; null stands for backing out.
  BackupCounts? backupCounts = const BackupCounts(liked: 2, playlists: 1);

  @override
  Future<BackupCounts?> exportBackup() async {
    await _record('backupExport');
    return backupCounts;
  }

  @override
  Future<BackupCounts?> importBackup() async {
    await _record('backupImport');
    return backupCounts;
  }

  @override
  Future<void> setSleep(SleepMode mode, {int minutes = 0}) =>
      _record('sleep ${mode.name} $minutes');

  @override
  Future<void> setAutoplay(bool on) => _record('autoplay $on');

  SongRadio radioResult = const SongRadio();
  RelatedPage relatedResult = const RelatedPage();
  ArtistPage artistResult = const ArtistPage(id: 'UC1', name: 'Artist');
  Lyrics? lyricsResult;
  CollectionPage collectionResult = const CollectionPage(
    id: 'PL1',
    title: 'Playlist',
  );

  /// What a search of YouTube Music answers; when not set, the songs of [searchResults].
  SearchResults? searchPageResult;

  /// The answer to a search for one kind of result, by its filter.
  final searchPageResults = <String, SearchResults>{};

  /// The answer to each [musicSearchMore] token.
  final searchMoreResults = <String, SearchResults>{};

  /// The answer to each [musicMore] token.
  final moreResults = <String, MoreTracks>{};

  /// When set, these calls wait for it, so a test can look at the loading state.
  Completer<void>? musicGate;

  /// Makes only the calls to YouTube Music fail.
  Object? musicFailWith;

  Future<T> _music<T>(String call, T value) async {
    if (musicFailWith != null) {
      calls.add(call);
      throw musicFailWith!;
    }
    await _record(call);
    await musicGate?.future;
    return value;
  }

  List<MusicShelf> trendingResult = const [];
  List<MusicTrack> songSearchResult = const [];
  List<MusicTrack> videoSearchResult = const [];
  List<SeedList> seedListsResult = const [];

  @override
  Future<List<MusicShelf>> musicTrending() =>
      _music('musicTrending', trendingResult);

  @override
  Future<List<MusicTrack>> musicSearch(String query, {required bool songs}) =>
      _music(
        'musicSearch ${songs ? 'songs' : 'videos'} $query',
        songs ? songSearchResult : videoSearchResult,
      );

  @override
  Future<List<SeedList>> seedLists() async {
    await _record('seedLists');
    return seedListsResult;
  }

  @override
  Future<SongRadio> musicNext(String videoId) =>
      _music('musicNext $videoId', radioResult);

  @override
  Future<RelatedPage> musicRelated(String videoId) =>
      _music('musicRelated $videoId', relatedResult);

  @override
  Future<ArtistPage> musicArtist(String artistId) =>
      _music('musicArtist $artistId', artistResult);

  @override
  Future<SearchResults> musicSearchPage(String query, {String? params}) async {
    final found = await _music(
      'musicSearchPage ${params ?? '-'} $query',
      (params == null ? null : searchPageResults[params]) ??
          searchPageResult ??
          SearchResults(
            items: [
              for (final t in searchResults)
                SearchItem(
                  kind: 'song',
                  id: t.videoId,
                  title: t.title,
                  track: t,
                ),
            ],
          ),
    );
    await searchGate?.future;
    return found;
  }

  @override
  Future<SearchResults> musicSearchMore(String token) => _music(
    'musicSearchMore $token',
    searchMoreResults[token] ?? const SearchResults(),
  );

  @override
  Future<CollectionPage> musicCollection(String id) =>
      _music('musicCollection $id', collectionResult);

  @override
  Future<MoreTracks> musicMore(String token) =>
      _music('musicMore $token', moreResults[token] ?? const MoreTracks());

  @override
  Future<Lyrics?> lyrics(Track track) =>
      _music('lyrics ${track.videoId}', lyricsResult);

  /// Playlists by id, in the order they were made; the songs of each in order.
  final playlistSongs = <int, List<Track>>{};
  final playlistNames = <int, String>{};
  int _nextPlaylist = 1;

  @override
  Future<List<SavedPlaylist>> playlists() async {
    await _record('playlists');
    return [
      for (final id in playlistNames.keys.toList().reversed)
        SavedPlaylist(
          id: id,
          name: playlistNames[id]!,
          count: playlistSongs[id]!.length,
          thumb: playlistSongs[id]!.firstOrNull?.thumb,
        ),
    ];
  }

  @override
  Future<List<Track>> playlistTracks(int id) async {
    await _record('playlistTracks $id');
    return [...?playlistSongs[id]];
  }

  @override
  Future<int> createPlaylist(String name, List<Track> tracks) async {
    await _record(
      'createPlaylist $name ${tracks.map((t) => t.videoId).join(',')}',
    );
    final id = _nextPlaylist++;
    playlistNames[id] = name;
    playlistSongs[id] = [...tracks];
    return id;
  }

  @override
  Future<void> renamePlaylist(int id, String name) async {
    await _record('renamePlaylist $id $name');
    playlistNames[id] = name;
  }

  @override
  Future<void> deletePlaylist(int id) async {
    await _record('deletePlaylist $id');
    playlistNames.remove(id);
    playlistSongs.remove(id);
  }

  @override
  Future<int> addToPlaylist(int id, List<Track> tracks) async {
    await _record(
      'addToPlaylist $id ${tracks.map((t) => t.videoId).join(',')}',
    );
    final songs = playlistSongs[id]!;
    var added = 0;
    for (final t in tracks) {
      if (songs.any((s) => s.videoId == t.videoId)) continue;
      songs.add(t);
      added++;
    }
    return added;
  }

  @override
  Future<void> removeFromPlaylist(int id, String videoId) async {
    await _record('removeFromPlaylist $id $videoId');
    playlistSongs[id]!.removeWhere((t) => t.videoId == videoId);
  }

  @override
  Future<void> movePlaylistItem(int id, String videoId, int toIndex) async {
    await _record('movePlaylistItem $id $videoId $toIndex');
    final songs = playlistSongs[id]!;
    final at = songs.indexWhere((t) => t.videoId == videoId);
    if (at < 0) return;
    final song = songs.removeAt(at);
    songs.insert(toIndex.clamp(0, songs.length), song);
  }

  @override
  Future<void> setTrim(int ms) => _record('setTrim $ms');

  /// What [updateDownload] answers: false is "waiting for a yes to mobile data".
  bool updateOnWifi = true;

  @override
  Future<void> setDisplayPace(DisplayPace pace) => _record('pace ${pace.name}');

  @override
  Future<void> setLanguage(String code) => _record('setLanguage $code');

  @override
  Future<void> updateCheck() => _record('updateCheck');

  @override
  Future<bool> updateDownload({bool allowMetered = false}) async {
    await _record('updateDownload $allowMetered');
    return updateOnWifi || allowMetered;
  }

  /// What [updateInstall] answers: false is "Android has to allow installs first".
  bool mayInstall = true;

  @override
  Future<bool> updateInstall() async {
    await _record('updateInstall');
    return mayInstall;
  }

  @override
  Future<void> updateAllowInstalls() => _record('updateAllowInstalls');

  @override
  Future<void> pickOutput() => _record('pickOutput');

  @override
  Future<void> setAvatar(String? base64) => _record('setAvatar $base64');

  @override
  Future<List<String>> log() async => ['line one', 'line two'];

  @override
  Future<void> note(String line) async {}
}

RoomSnapshot sampleRoom({
  String phase = 'playing',
  int index = 0,
  int songs = 3,
  Repeat repeat = Repeat.off,
  List<Member>? members,
  bool video = false,
  bool solo = false,
  String? soloItemId,
  String? name,
  String? ownerId,
  GuestControl guestControl = GuestControl.all,

  /// Outside a room: the personal queue.
  bool local = false,
}) => RoomSnapshot(
  room: local ? null : 'ABC234',
  link: Link.connected,
  you: 'me',
  phase: phase,
  index: index,
  repeat: repeat,
  solo: solo,
  video: video,
  soloItemId: soloItemId,
  name: name,
  ownerId: ownerId,
  guestControl: guestControl,
  members:
      members ??
      const [
        Member(id: 'me', name: 'Anna', ready: true),
        Member(id: 'b', name: 'Binh', ready: true),
      ],
  queue: [
    for (var i = 0; i < songs; i++)
      QueueEntry(
        id: 'q$i',
        videoId: 'video$i',
        title: 'Song $i',
        artist: 'Artist $i',
        durMs: 200000 + i * 1000,
        addedBy: i.isEven ? 'me' : 'b',
      ),
  ],
);
