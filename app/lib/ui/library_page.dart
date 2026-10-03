import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/library_controller.dart';
import '../format.dart';
import '../data/models.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'home_shell.dart';
import 'scope.dart';
import 'settings_page.dart';
import 'widgets/artwork.dart';
import 'widgets/delete_background.dart';
import 'widgets/download_actions.dart';
import 'widgets/play_row.dart';
import 'widgets/scroll_edge.dart';
import 'widgets/text_dialog.dart';
import 'widgets/track_menu.dart';
import 'widgets/track_tile.dart';

/// What a person keeps: liked songs, what they heard lately, and their playlists. Opening one shows its
/// songs in place, so the mini player and the tabs stay where they are.
/// What the sidebar of a wide screen asks the library to open: [liked], [downloaded] or the id of a playlist (never
/// negative). Set to a value to ask, and the page forgets it once it has been shown.
class LibraryRequests extends ValueNotifier<int?> {
  LibraryRequests() : super(null);

  static const liked = -1;
  static const downloaded = -2;
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, this.requests});

  final LibraryRequests? requests;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

sealed class _Open {
  const _Open();
}

class _Liked extends _Open {
  const _Liked();
}

class _Recent extends _Open {
  const _Recent();
}

class _Downloaded extends _Open {
  const _Downloaded();
}

class _Playlist extends _Open {
  const _Playlist(this.id);
  final int id;
}

class _LibraryPageState extends State<LibraryPage> {
  _Open? _open;

  @override
  void initState() {
    super.initState();
    widget.requests?.addListener(_onRequest);
  }

  @override
  void didUpdateWidget(LibraryPage old) {
    super.didUpdateWidget(old);
    if (old.requests != widget.requests) {
      old.requests?.removeListener(_onRequest);
      widget.requests?.addListener(_onRequest);
    }
  }

  @override
  void dispose() {
    widget.requests?.removeListener(_onRequest);
    super.dispose();
  }

  void _onRequest() {
    final request = widget.requests?.value;
    if (request == null) return;
    widget.requests!.value = null;
    _show(switch (request) {
      LibraryRequests.liked => const _Liked(),
      LibraryRequests.downloaded => const _Downloaded(),
      final id => _Playlist(id),
    });
  }

  void _show(_Open? value) {
    if (value is _Playlist) AppScope.of(context).library.openPlaylist(value.id);
    setState(() => _open = value);
  }

  @override
  Widget build(BuildContext context) {
    final library = AppScope.of(context).library;
    // Each list starts below the status bar and scrolls up under it, to its glass edge
    return SafeArea(
      top: false,
      bottom: false,
      child: ListenableBuilder(
        listenable: library,
        builder: (context, _) {
          final open = _open;
          // A playlist that was deleted takes its page with it
          if (open is _Playlist &&
              !library.playlists.any((p) => p.id == open.id)) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => _open = null);
            });
          }
          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: switch (open) {
              null => _Overview(
                key: const ValueKey('overview'),
                library: library,
                onOpen: _show,
              ),
              _Liked() => _TrackList(
                key: const ValueKey('liked'),
                title: S.likedSongs,
                tracks: library.liked,
                onBack: () => _show(null),
                actions: [
                  if (library.liked.isNotEmpty)
                    IconButton(
                      onPressed: () => startDownload(context, library.liked),
                      tooltip: S.downloadAll,
                      icon: Icon(
                        Icons.download_rounded,
                        color: context.palette.primary,
                      ),
                    ),
                ],
              ),
              _Downloaded() => _TrackList(
                key: const ValueKey('downloaded'),
                title: S.downloadedSongs,
                tracks: [for (final d in library.downloads) d.track],
                subtitles: [
                  for (final d in library.downloads)
                    '${d.track.artist} · ${switch (d.state) {
                      DownloadState.done => formatBytes(d.bytes),
                      DownloadState.queued => S.queuedToDownload,
                      DownloadState.waiting => S.waitingToDownload,
                      DownloadState.failed => S.downloadFailed,
                    }}',
                ],
                onBack: () => _show(null),
                emptyTitle: S.noDownloadsTitle,
                emptyBody: S.noDownloadsBody,
                actions: [
                  if (library.downloads.isNotEmpty)
                    TextButton(
                      onPressed: () =>
                          _confirmDeleteDownloads(context, library),
                      child: Text(S.deleteAll),
                    ),
                ],
              ),
              _Recent() => _TrackList(
                key: const ValueKey('recent'),
                title: S.recentlyPlayed,
                tracks: [for (final e in library.recent) e.track],
                subtitles: [
                  for (final e in library.recent)
                    '${e.track.artist} · ${S.ago(DateTime.now().difference(e.at))}',
                ],
                onBack: () => _show(null),
                actions: [
                  if (library.recent.isNotEmpty)
                    TextButton(
                      onPressed: () => _confirmClear(context, library),
                      child: Text(S.clearHistory),
                    ),
                ],
              ),
              _Playlist(:final id) => _PlaylistPage(
                key: ValueKey('playlist$id'),
                library: library,
                id: id,
                onBack: () => _show(null),
              ),
            },
          );
        },
      ),
    );
  }

  Future<void> _confirmDeleteDownloads(
    BuildContext context,
    LibraryController library,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(S.deleteDownloadsQuestion),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(S.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(S.delete),
          ),
        ],
      ),
    );
    if (ok == true) library.clearDownloads();
  }

  Future<void> _confirmClear(
    BuildContext context,
    LibraryController library,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(S.clearHistoryQuestion),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(S.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(S.clear),
          ),
        ],
      ),
    );
    if (ok == true) library.clearHistory();
  }
}

class _Overview extends StatelessWidget {
  const _Overview({super.key, required this.library, required this.onOpen});

  final LibraryController library;
  final ValueChanged<_Open> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    final p = context.palette;
    return ScrollEdge(
      title: S.tabLibrary,
      child: ListView(
        padding: EdgeInsets.only(
          top: ScrollEdge.topOf(context),
          bottom: HomeShell.bottomInsetOf(context),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 16, 12),
            child: Row(
              children: [
                Expanded(child: Text(S.tabLibrary, style: theme.headlineLarge)),
                IconButton(
                  onPressed: () => openSettings(context),
                  tooltip: S.settingsTitle,
                  style: roundButtonStyle(context, size: 40),
                  icon: Icon(Icons.settings_outlined, size: 22, color: p.text),
                ),
              ],
            ),
          ),
          _CollectionRow(
            leading: const _IconTile(Icons.favorite_rounded),
            title: S.likedSongs,
            subtitle: S.songCount(library.liked.length),
            onTap: () => onOpen(const _Liked()),
          ),
          _CollectionRow(
            leading: const _IconTile(Icons.history_rounded),
            title: S.recentlyPlayed,
            subtitle: S.songCount(library.recent.length),
            onTap: () => onOpen(const _Recent()),
          ),
          _CollectionRow(
            leading: const _IconTile(Icons.download_done_rounded),
            title: S.downloadedSongs,
            subtitle: S.songCount(
              library.downloads
                  .where((d) => d.state == DownloadState.done)
                  .length,
            ),
            onTap: () => onOpen(const _Downloaded()),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 16, 4),
            child: Row(
              children: [
                Expanded(child: Text(S.playlists, style: theme.titleLarge)),
                PopupMenuButton<String>(
                  useRootNavigator: true,
                  style: roundButtonStyle(context, size: 40),
                  icon: Icon(Icons.add_rounded, color: p.text),
                  tooltip: S.newPlaylist,
                  color: p.brightness == Brightness.light
                      ? const Color(0xFFFFF7F9)
                      : const Color(0xFF2B1F25),
                  surfaceTintColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  onSelected: (value) => value == 'new'
                      ? _create(context, library)
                      : _import(context, library),
                  itemBuilder: (context) => [
                    PopupMenuItem(value: 'new', child: Text(S.newPlaylist)),
                    PopupMenuItem(
                      value: 'import',
                      child: Text(S.importFromLink),
                    ),
                  ],
                ),
              ],
            ),
          ),
          for (final playlist in library.playlists)
            _CollectionRow(
              leading: Artwork(url: playlist.thumb, size: 54),
              title: playlist.name,
              subtitle: S.songCount(playlist.count),
              onTap: () => onOpen(_Playlist(playlist.id)),
            ),
        ],
      ),
    );
  }

  Future<void> _create(BuildContext context, LibraryController library) async {
    final name = await showTextDialog(
      context,
      title: S.newPlaylist,
      hint: S.playlistName,
      maxLength: 60,
    );
    if (name == null || name.isEmpty) return;
    final id = await library.createPlaylist(name);
    if (id != null) onOpen(_Playlist(id));
  }

  /// Makes a playlist out of a YouTube link: the songs of a playlist, or the one song of a video.
  Future<void> _import(BuildContext context, LibraryController library) async {
    final room = AppScope.roomOf(context);
    final messenger = ScaffoldMessenger.of(context);
    final text = await showTextDialog(
      context,
      title: S.importFromLink,
      hint: S.importHint,
      maxLength: 300,
      capitalization: TextCapitalization.none,
    );
    if (text == null || text.isEmpty) return;
    void say(String message) => messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
    final LinkResult? link;
    try {
      link = await room.lookup(text);
    } on Object {
      return say(S.importFailed);
    }
    if (link == null) return say(S.importFailed);
    if (link.tracks.isEmpty) return say(S.importEmpty);
    final id = await library.createPlaylist(
      link.playlistTitle ?? link.tracks.first.title,
      link.tracks,
    );
    if (id != null) onOpen(_Playlist(id));
  }
}

class _IconTile extends StatelessWidget {
  const _IconTile(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      width: 54,
      height: 54,
      decoration: BoxDecoration(
        color: p.primaryContainer,
        borderRadius: BorderRadius.circular(SapocheTheme.artworkRadius),
      ),
      child: Icon(icon, color: p.primary),
    );
  }
}

class _CollectionRow extends StatelessWidget {
  const _CollectionRow({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final Widget leading;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.bodyMedium?.copyWith(color: p.textSecondary),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: p.textTertiary),
          ],
        ),
      ),
    );
  }
}

/// A playlist: its songs can be dragged into another order and swiped away, and it can be renamed or deleted.
class _PlaylistPage extends StatelessWidget {
  const _PlaylistPage({
    super.key,
    required this.library,
    required this.id,
    required this.onBack,
  });

  final LibraryController library;
  final int id;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final playlist = library.playlists.where((p) => p.id == id).firstOrNull;
    final tracks = library.playlistTracks(id);
    return _TrackList(
      title: playlist?.name ?? '',
      tracks: tracks,
      onBack: onBack,
      emptyTitle: S.emptyPlaylistTitle,
      emptyBody: S.emptyPlaylistBody,
      onRemove: (track) => library.removeFromPlaylist(id, track),
      onMove: (track, to) => library.movePlaylistItem(id, track, to),
      actions: [
        if (tracks.isNotEmpty)
          IconButton(
            onPressed: () => startDownload(context, tracks),
            tooltip: S.downloadAll,
            icon: Icon(Icons.download_rounded, color: context.palette.primary),
          ),
        PopupMenuButton<String>(
          useRootNavigator: true,
          icon: Icon(
            Icons.more_horiz_rounded,
            color: context.palette.textSecondary,
          ),
          onSelected: (value) => value == 'rename'
              ? _rename(context, playlist)
              : _delete(context, playlist),
          itemBuilder: (context) => [
            PopupMenuItem(value: 'rename', child: Text(S.rename)),
            PopupMenuItem(value: 'delete', child: Text(S.deletePlaylist)),
          ],
        ),
      ],
    );
  }

  Future<void> _rename(BuildContext context, SavedPlaylist? playlist) async {
    final name = await showTextDialog(
      context,
      title: S.rename,
      hint: S.playlistName,
      initial: playlist?.name ?? '',
      maxLength: 60,
    );
    if (name != null && name.isNotEmpty) library.renamePlaylist(id, name);
  }

  Future<void> _delete(BuildContext context, SavedPlaylist? playlist) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(S.deletePlaylistQuestion(playlist?.name ?? '')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(S.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(S.delete),
          ),
        ],
      ),
    );
    if (ok == true) library.deletePlaylist(id);
  }
}

/// The songs of one collection, with the ways to play them. With [onMove] the rows can be dragged into
/// another order, with [onRemove] they can be swiped away.
class _TrackList extends StatelessWidget {
  const _TrackList({
    super.key,
    required this.title,
    required this.tracks,
    required this.onBack,
    this.subtitles,
    this.actions = const [],
    this.emptyTitle,
    this.emptyBody,
    this.onRemove,
    this.onMove,
  });

  final String title;
  final List<Track> tracks;

  /// Replaces the artist line of each row, when given.
  final List<String>? subtitles;
  final VoidCallback onBack;

  /// Next to the title.
  final List<Widget> actions;
  final String? emptyTitle;
  final String? emptyBody;
  final ValueChanged<Track>? onRemove;
  final void Function(Track track, int toIndex)? onMove;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final room = AppScope.roomOf(context);

    void confirm(String text) {
      HapticFeedback.selectionClick();
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(text)));
    }

    Future<void> add(Track track, {bool playNext = false}) async {
      if (room.snapshot.isQueued(track)) {
        confirm(S.alreadyInQueue);
        return;
      }
      await room.add(track, playNext: playNext);
      if (context.mounted) {
        confirm(playNext ? S.willPlayNext : S.addedToQueue);
      }
    }

    return ListenableBuilder(
      listenable: room,
      builder: (context, _) {
        final inRoom = room.snapshot.inRoom;

        Widget row(int i) {
          final track = tracks[i];
          final tile = TrackTile(
            track: track,
            subtitle: subtitles?[i],
            // Outside a room the song plays with the rest of the list behind it; in a room it is queued
            onTap: inRoom
                ? () => add(track)
                : () => room.playTracks(tracks.sublist(i)),
            trailing: TrackMenu(
              track: track,
              onAdd: () => add(track),
              onPlayNext: () => add(track, playNext: true),
            ),
          );
          if (onRemove == null) return tile;
          return Dismissible(
            key: ValueKey('remove ${track.videoId}'),
            direction: DismissDirection.endToStart,
            background: const DeleteBackground(),
            onDismissed: (_) {
              HapticFeedback.lightImpact();
              onRemove!(track);
            },
            child: tile,
          );
        }

        return ScrollEdge(
          title: title,
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    ScrollEdge.topOf(context) + 8,
                    20,
                    10,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextButton.icon(
                        onPressed: onBack,
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(0, 36),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(
                          Icons.arrow_back_ios_new_rounded,
                          size: 14,
                        ),
                        label: Text(S.backToLibrary),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.headlineMedium,
                            ),
                          ),
                          ...actions,
                        ],
                      ),
                      Text(
                        S.songCount(tracks.length),
                        style: theme.bodyMedium?.copyWith(
                          color: p.textSecondary,
                        ),
                      ),
                      if (tracks.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: () {
                                  room.playTracks(tracks);
                                  confirm(
                                    inRoom ? S.playlistAdded : S.addedToQueue,
                                  );
                                },
                                icon: Icon(
                                  inRoom
                                      ? Icons.playlist_add_rounded
                                      : Icons.play_arrow_rounded,
                                ),
                                label: Text(inRoom ? S.addAll : S.play),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: () {
                                  room.playTracks([...tracks]..shuffle());
                                  confirm(
                                    inRoom ? S.playlistAdded : S.addedToQueue,
                                  );
                                },
                                child: Text(S.shuffle),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (tracks.isEmpty && emptyTitle != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(36, 48, 36, 0),
                    child: Column(
                      children: [
                        Icon(
                          Icons.queue_music_rounded,
                          size: 44,
                          color: p.primary.withValues(alpha: 0.55),
                        ),
                        const SizedBox(height: 14),
                        Text(emptyTitle!, style: theme.titleMedium),
                        if (emptyBody != null) ...[
                          const SizedBox(height: 6),
                          Text(
                            emptyBody!,
                            textAlign: TextAlign.center,
                            style: theme.bodyMedium?.copyWith(
                              color: p.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                )
              else if (onMove != null)
                SliverReorderableList(
                  itemCount: tracks.length,
                  onReorderItem: (from, to) => onMove!(tracks[from], to),
                  proxyDecorator: (child, _, animation) => Material(
                    color: Colors.transparent,
                    elevation: 0,
                    child: ScaleTransition(
                      scale: Tween(begin: 1.0, end: 1.02).animate(animation),
                      child: child,
                    ),
                  ),
                  itemBuilder: (context, i) =>
                      ReorderableDelayedDragStartListener(
                        key: ValueKey('row ${tracks[i].videoId}'),
                        index: i,
                        child: row(i),
                      ),
                )
              else
                SliverList.builder(
                  itemCount: tracks.length,
                  itemBuilder: (context, i) => row(i),
                ),
              SliverToBoxAdapter(
                child: SizedBox(height: HomeShell.bottomInsetOf(context)),
              ),
            ],
          ),
        );
      },
    );
  }
}
