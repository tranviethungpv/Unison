import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../data/home_model.dart';
import '../data/models.dart';
import '../data/music_models.dart';
import '../data/song_key.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'artist_page.dart';
import 'home_shell.dart';
import 'collection_screen.dart';
import 'player/track_section.dart';
import 'rooms_sheet.dart';
import 'scope.dart';
import 'settings_page.dart';
import 'widgets/artwork.dart';
import 'widgets/cached_cover.dart';
import 'widgets/play_actions.dart';
import 'widgets/play_row.dart';
import 'widgets/scroll_edge.dart';
import 'widgets/song_card.dart';

/// Where the app opens: what to play next, drawn from what the person listens to, like the home of YouTube Music.
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final library = AppScope.of(context).library;
    // The page scrolls up under the status bar, where its glass edge blurs it away
    final top = ScrollEdge.topOf(context);
    return ScrollEdge(
      title: _Header.greeting(DateTime.now().hour),
      child: ListenableBuilder(
        listenable: library,
        builder: (context, _) {
          final home = buildHome(
            recent: library.recent,
            liked: library.liked,
            forYou: library.forYou,
            seedLists: library.seedLists,
            now: DateTime.now(),
            discover: library.discover,
            context: library.context,
            blocked: library.blocked,
          );
          return LayoutBuilder(
            builder: (context, box) {
              final heroes = _heroCount(box.maxWidth, home.mixes.length);
              return RefreshIndicator(
                onRefresh: library.refreshForYou,
                edgeOffset: top,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.only(
                    top: top,
                    bottom: HomeShell.bottomInsetOf(context),
                  ),
                  children: [
                    const _Header(),
                    if (home.isEmpty) const _Welcome(),
                    if (heroes > 0)
                      _Heroes(mixes: home.mixes.take(heroes).toList()),
                    _QuickPicks(tracks: home.quickPicks),
                    CardShelf(
                      title: S.listenAgain,
                      cards: [
                        for (final t in home.listenAgain)
                          SongCard.track(
                            context,
                            t,
                            onTap: () => playNow(context, t),
                          ),
                      ],
                    ),
                    CardShelf(
                      title: S.contextMix(home.contextBucket),
                      cards: [
                        for (final t in home.context)
                          SongCard.track(
                            context,
                            t,
                            onTap: () => playNow(context, t),
                          ),
                      ],
                    ),
                    // A phone swipes along wide cards, as Apple Music does for its picks; a wide window has shown the
                    // first ones across the top already
                    if (heroes == 0)
                      _MixRow(mixes: home.mixes)
                    else
                      CardShelf(
                        title: S.mixedForYou,
                        cards: [
                          // The first are the cards at the top
                          for (final mix in home.mixes.skip(heroes))
                            SongCard(
                              title: S.mixOf(mix.artist),
                              subtitle: '',
                              thumb: mix.seed.thumb,
                              onTap: () => startMix(context, mix.seed),
                            ),
                        ],
                      ),
                    CardShelf(
                      title: S.discoverShelf,
                      cards: [
                        for (final t in home.discover)
                          SongCard.track(
                            context,
                            t,
                            onTap: () => playNow(context, t),
                          ),
                      ],
                    ),
                    CardShelf(
                      title: S.forgottenFavorites,
                      cards: [
                        for (final t in home.forgotten)
                          SongCard.track(
                            context,
                            t,
                            onTap: () => playNow(context, t),
                          ),
                      ],
                    ),
                    for (final b in home.becauseOf)
                      CardShelf(
                        title: S.becauseYouListened(b.seed.title),
                        cards: [
                          for (final t in b.tracks)
                            SongCard.track(
                              context,
                              t,
                              onTap: () => playNow(context, t),
                            ),
                        ],
                      ),
                    if (home.topSeed != null)
                      _SimilarArtists(seed: home.topSeed!),
                    const _Trending(),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  /// How many mixes go across the top: none on a phone, which swipes through them further down, more where the page
  /// is wide.
  static int _heroCount(double width, int mixes) {
    final fit = width >= 1000 ? 3 : (width >= 640 ? 2 : 0);
    return math.min(fit, mixes);
  }
}

class _Header extends StatelessWidget {
  const _Header();

  static String greeting(int hour) => hour < 12
      ? S.goodMorning
      : hour < 18
      ? S.goodAfternoon
      : S.goodEvening;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 16, 6),
      child: Row(
        children: [
          // The greeting gives way to the buttons on a narrow phone rather than being cut off
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                greeting(DateTime.now().hour),
                maxLines: 1,
                style: Theme.of(context).textTheme.headlineLarge,
              ),
            ),
          ),
          const SizedBox(width: 8),
          const _RoomChip(),
          const SizedBox(width: 8),
          IconButton(
            onPressed: () => openSettings(context),
            tooltip: S.settingsTitle,
            style: roundButtonStyle(context, size: 40),
            // A dot while a newer version of the app is waiting
            icon: ListenableBuilder(
              listenable: AppScope.of(context).update,
              builder: (context, _) => Badge(
                key: const ValueKey('update-dot'),
                smallSize: 9,
                backgroundColor: p.primary,
                isLabelVisible: AppScope.of(context).update.info.hasUpdate,
                child: Icon(Icons.settings_outlined, size: 22, color: p.text),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Mixes of the artists the person plays, as wide cards that scroll sideways: part of the next one shows, which says
/// there is more.
class _MixRow extends StatelessWidget {
  const _MixRow({required this.mixes});

  final List<ArtistMix> mixes;

  @override
  Widget build(BuildContext context) {
    if (mixes.isEmpty) return const SizedBox.shrink();
    final width = (MediaQuery.sizeOf(context).width * 0.78).clamp(240.0, 320.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeading(S.mixedForYou),
        SizedBox(
          height: 168,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: mixes.length,
            separatorBuilder: (_, _) => const SizedBox(width: 14),
            itemBuilder: (_, i) => SizedBox(
              width: width,
              child: _Hero(mix: mixes[i], height: 168, label: false),
            ),
          ),
        ),
      ],
    );
  }
}

/// The way into a room from the home page, so that it is not a trip to another tab: it says "Room" when there is
/// nothing to go back to, "Rejoin" when this device has been in a room (a touch goes straight back into the last one),
/// and the room's code while this device is in one (a touch opens the room's panel). Holding it opens the list of
/// rooms. It never enters a room by itself: only a touch does.
class _RoomChip extends StatefulWidget {
  const _RoomChip();

  @override
  State<_RoomChip> createState() => _RoomChipState();
}

class _RoomChipState extends State<_RoomChip> {
  bool _busy = false;

  Future<void> _touch() async {
    final model = AppScope.of(context);
    final room = model.room;
    final last = model.recents.rooms.firstOrNull;
    final name = room.snapshot.me?.name ?? room.profile.name ?? '';
    // Without a room to go back to, or a name to go in with, the sheet is the way
    if (room.snapshot.inRoom || last == null || name.isEmpty) {
      return showRoomSheet(context);
    }
    setState(() => _busy = true);
    final error = await room.join(last.code, name);
    if (!mounted) return;
    setState(() => _busy = false);
    // The room may be gone or the server out of reach: the sheet shows the rooms there are, and says what went wrong
    if (error != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(error)));
      await showRoomSheet(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final model = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([model.room, model.recents]),
      builder: (context, _) {
        final snapshot = model.room.snapshot;
        final last = model.recents.rooms.firstOrNull;
        final inRoom = snapshot.inRoom;
        final label = inRoom
            ? snapshot.room ?? S.tabRoom
            : last == null
            ? S.tabRoom
            : S.rejoinChip;
        final color = inRoom ? p.onPrimary : p.text;
        return Tooltip(
          message: inRoom || last == null ? S.tabRoom : last.title,
          child: Material(
            color: inRoom ? p.primary : p.text.withValues(alpha: 0.14),
            shape: const StadiumBorder(),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: _busy ? null : _touch,
              onLongPress: () => showRoomSheet(context),
              child: SizedBox(
                height: 40,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _busy
                          ? SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: color,
                              ),
                            )
                          : Icon(Icons.groups_rounded, size: 18, color: color),
                      const SizedBox(width: 6),
                      Text(
                        label,
                        maxLines: 1,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: color,
                          letterSpacing: inRoom ? 1.5 : 0,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// The mixes of the artists the person plays most as large cards across the top of a wide page, a picture on each and
/// the words on a veil of dark glass.
class _Heroes extends StatelessWidget {
  const _Heroes({required this.mixes});

  final List<ArtistMix> mixes;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
    child: Row(
      children: [
        for (final (i, mix) in mixes.indexed) ...[
          if (i > 0) const SizedBox(width: 14),
          Expanded(
            child: _Hero(mix: mix, height: mixes.length == 1 ? 216 : 240),
          ),
        ],
      ],
    ),
  );
}

class _Hero extends StatelessWidget {
  const _Hero({required this.mix, required this.height, this.label = true});

  final ArtistMix mix;
  final double height;

  /// Says "Mixed for you" over the title; a row that has that for its heading leaves it out.
  final bool label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return LayoutBuilder(
      builder: (context, box) {
        return Container(
          height: height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.28),
                blurRadius: 28,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: InkWell(
              onTap: () => startMix(context, mix.seed),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // The picture is square, so a wide card shows a band of it
                  OverflowBox(
                    minWidth: box.maxWidth,
                    maxWidth: box.maxWidth,
                    minHeight: box.maxWidth,
                    maxHeight: box.maxWidth,
                    child: Artwork(
                      url: mix.seed.thumb,
                      size: box.maxWidth,
                      radius: 0,
                      sharp: true,
                    ),
                  ),
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 8,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Stack(
                        children: [
                          // The picture under the words, blurred: made once, where a backdrop blur would blur it again
                          // in every frame the screen draws
                          if (mix.seed.thumb case final thumb?)
                            Positioned(
                              left: -8,
                              bottom: -(8 + (box.maxWidth - height) / 2),
                              width: box.maxWidth,
                              height: box.maxWidth,
                              child: _BlurredCover(
                                url: thumb,
                                sigma: 18 / box.maxWidth,
                              ),
                            ),
                          ColoredBox(
                            color: Colors.black.withValues(alpha: 0.42),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        if (label)
                                          Text(
                                            S.mixedForYou.toUpperCase(),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.labelSmall?.copyWith(
                                              color: Colors.white70,
                                              letterSpacing: 0.8,
                                            ),
                                          ),
                                        Text(
                                          S.mixOf(mix.artist),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.titleSmall?.copyWith(
                                            color: Colors.white,
                                            fontSize: 16,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  // Not a button of its own: the whole card is
                                  DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(999),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 11,
                                        vertical: 5,
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(
                                            Icons.play_arrow_rounded,
                                            size: 16,
                                            color: Color(0xFF22161A),
                                          ),
                                          const SizedBox(width: 2),
                                          Text(
                                            S.play,
                                            style: theme.labelMedium?.copyWith(
                                              color: const Color(0xFF22161A),
                                              fontSize: 13,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A cover blurred into a small picture once and stretched over its box, cropped square as [Artwork] crops it.
class _BlurredCover extends StatefulWidget {
  const _BlurredCover({required this.url, required this.sigma});

  final String url;

  /// How strong the blur is, as a fraction of the side of the box.
  final double sigma;

  @override
  State<_BlurredCover> createState() => _BlurredCoverState();
}

class _BlurredCoverState extends State<_BlurredCover> {
  /// Side of the blurred picture, in pixels; it is stretched, and stretching a blurred picture stays smooth.
  static const _side = 64;

  ui.Image? _image;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void initState() {
    super.initState();
    _resolve(sharpThumbnail(widget.url));
  }

  @override
  void didUpdateWidget(_BlurredCover old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url || old.sigma != widget.sigma) {
      _resolve(sharpThumbnail(widget.url));
    }
  }

  @override
  void dispose() {
    _stop();
    _image?.dispose();
    super.dispose();
  }

  void _stop() {
    final listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  /// Reads the picture at [address], small; the cover's own address when the enlarged one is not there, as [Artwork]
  /// does.
  void _resolve(String address) {
    _stop();
    final stream = ResizeImage(
      CachedCover(address),
      height: _side,
      allowUpscaling: false,
    ).resolve(ImageConfiguration.empty);
    final url = widget.url;
    final sigma = widget.sigma;
    final listener = ImageStreamListener(
      (info, _) async {
        final blurred = await _blur(info.image, sigma * _side);
        info.image.dispose();
        if (!mounted || widget.url != url || widget.sigma != sigma) {
          blurred.dispose();
          return;
        }
        final old = _image;
        setState(() => _image = blurred);
        old?.dispose();
      },
      onError: (_, _) {
        if (mounted && address != url && widget.url == url) _resolve(url);
      },
    );
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  static Future<ui.Image> _blur(ui.Image source, double sigma) async {
    final side = math.min(source.width, source.height).toDouble();
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      source,
      Rect.fromCenter(
        center: Offset(source.width / 2, source.height / 2),
        width: side,
        height: side,
      ),
      Rect.fromLTWH(0, 0, _side.toDouble(), _side.toDouble()),
      Paint()
        ..filterQuality = FilterQuality.medium
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: sigma,
          sigmaY: sigma,
          tileMode: TileMode.mirror,
        ),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(_side, _side);
    picture.dispose();
    return image;
  }

  @override
  Widget build(BuildContext context) => RawImage(
    image: _image,
    fit: BoxFit.fill,
    filterQuality: FilterQuality.high,
  );
}

/// Said while nothing is known about the person yet.
class _Welcome extends StatelessWidget {
  const _Welcome();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: p.veil,
          borderRadius: BorderRadius.circular(SapocheTheme.groupRadius),
        ),
        child: Row(
          children: [
            Icon(Icons.auto_awesome_rounded, color: p.primary, size: 30),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(S.homeEmptyTitle, style: theme.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    S.homeEmptyBody,
                    style: theme.bodyMedium?.copyWith(color: p.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Songs in columns of four that scroll sideways, each a row to touch.
class _QuickPicks extends StatelessWidget {
  const _QuickPicks({required this.tracks});

  final List<Track> tracks;

  static const _rows = 4;
  static const _rowHeight = 64.0;

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) return const SizedBox.shrink();
    final columns = (tracks.length / _rows).ceil();
    // A phone shows one column and a bit of the next; a wide window shows as many as fit
    final fit = (MediaQuery.sizeOf(context).width / 380).floor();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeading(S.quickPicks),
        SizedBox(
          height: _rows * _rowHeight,
          child: PageView.builder(
            padEnds: false,
            controller: PageController(
              viewportFraction: fit < 2 ? 0.9 : 1 / fit.clamp(2, 4),
            ),
            itemCount: columns,
            itemBuilder: (context, column) => Column(
              children: [
                for (var r = 0; r < _rows; r++)
                  if (column * _rows + r < tracks.length)
                    _QuickRow(track: tracks[column * _rows + r])
                  else
                    const SizedBox(height: _QuickPicks._rowHeight),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _QuickRow extends StatelessWidget {
  const _QuickRow({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return InkWell(
      onTap: () => playNow(context, track),
      child: SizedBox(
        height: _QuickPicks._rowHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
          child: Row(
            children: [
              Artwork(url: track.thumb, size: 50, radius: 8),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.titleSmall,
                    ),
                    Text(
                      track.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.bodySmall?.copyWith(color: p.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Artists like the one the person plays most. Asked for when the page shows, and left out if it fails.
class _SimilarArtists extends StatefulWidget {
  const _SimilarArtists({required this.seed});

  final Track seed;

  @override
  State<_SimilarArtists> createState() => _SimilarArtistsState();
}

class _SimilarArtistsState extends State<_SimilarArtists> {
  Future<RelatedPage>? _related;
  String? _for;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_for != widget.seed.videoId) {
      _for = widget.seed.videoId;
      _related = AppScope.of(context).music.related(widget.seed.videoId);
    }
  }

  @override
  void didUpdateWidget(_SimilarArtists old) {
    super.didUpdateWidget(old);
    if (_for != widget.seed.videoId) {
      _for = widget.seed.videoId;
      _related = AppScope.of(context).music.related(widget.seed.videoId);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<RelatedPage>(
    future: _related,
    builder: (context, async) {
      final artists = async.data?.artists ?? const <ArtistCard>[];
      if (artists.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeading(S.similarTo(displayArtist(widget.seed.artist))),
          ArtistRow(artists: artists, onOpen: (id) => openArtist(context, id)),
        ],
      );
    },
  );
}

/// What YouTube Music shows everybody: the same for all, so it is the only thing there is at first.
class _Trending extends StatelessWidget {
  const _Trending();

  @override
  Widget build(BuildContext context) => FutureBuilder<List<MusicShelf>>(
    future: AppScope.of(context).music.trending(),
    builder: (context, async) {
      final shelves = async.data ?? const <MusicShelf>[];
      return Column(
        children: [
          for (final shelf in shelves.take(3)) ...[
            CardShelf(
              title: shelf.tracks.isNotEmpty && shelves.first == shelf
                  ? S.trending
                  : shelf.title,
              cards: [
                for (final t in shelf.tracks)
                  SongCard.track(context, t, onTap: () => playNow(context, t)),
                for (final list in shelf.playlists)
                  SongCard(
                    title: list.title,
                    subtitle: list.subtitle ?? '',
                    thumb: list.thumb,
                    onTap: () => openCollection(
                      context,
                      id: list.id,
                      title: list.title,
                      thumb: list.thumb,
                    ),
                  ),
              ],
            ),
          ],
        ],
      );
    },
  );
}
