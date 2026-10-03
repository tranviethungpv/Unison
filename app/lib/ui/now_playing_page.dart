import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../data/music_models.dart';
import '../data/room_controller.dart';
import '../format.dart';
import '../strings.dart';
import '../theme/palette.dart';
import '../theme/theme.dart';
import 'artist_page.dart';
import 'members_sheet.dart';
import 'player/lyrics_view.dart';
import 'player/related_view.dart';
import 'player/up_next_view.dart';
import 'player_sheet.dart';
import 'song_info_sheet.dart';
import 'scope.dart';
import 'sleep_sheet.dart';
import 'widgets/artwork.dart';
import 'widgets/avatars.dart';
import 'widgets/not_interested.dart';
import 'widgets/like_button.dart';
import 'widgets/marquee_text.dart';
import 'widgets/download_actions.dart';
import 'widgets/playlist_picker.dart';
import 'widgets/playback_bar.dart';
import 'widgets/transport.dart';
import 'widgets/video_view.dart';
import 'widgets/player_backdrop.dart';

class NowPlayingPage extends StatelessWidget {
  const NowPlayingPage({super.key});

  @override
  Widget build(BuildContext context) {
    // Icons in the status bar and the navigation bar that show on the backdrop, light or dark like the app
    final icons = Theme.of(context).brightness == Brightness.dark
        ? Brightness.light
        : Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarIconBrightness: icons,
        systemNavigationBarIconBrightness: icons,
      ),
      child: const _PlayerPage(),
    );
  }
}

class _PlayerPage extends StatelessWidget {
  const _PlayerPage();

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.roomOf(context);
    final sheet = PlayerSheetScope.of(context);
    return PlayerPull(
      child: KeyedSubtree(
        key: sheet.pageRoot,
        child: Scaffold(
          body: ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              final current = controller.snapshot.current;
              if (current == null) {
                // The queue emptied while the sheet was open
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => sheet.close(),
                );
                return const SizedBox.shrink();
              }
              return _Body(controller: controller, current: current);
            },
          ),
        ),
      ),
    );
  }
}

/// Side of the full player's cover. It depends only on the screen, so the cover can be decoded
/// at this size before the player is ever opened.
double coverSize(MediaQueryData media) {
  // Everything except the cover needs about this much height; the cover takes what is left
  const otherContent = 436.0;
  return [
    media.size.width - 64,
    380.0,
    media.size.height - media.padding.vertical - otherContent,
  ].reduce((a, b) => a < b ? a : b).clamp(140.0, 380.0);
}

/// What the middle of the full player shows: the cover, or one of the panels that take its place.
enum _Panel { cover, lyrics, upNext, related }

class _Body extends StatefulWidget {
  const _Body({required this.controller, required this.current});

  final RoomController controller;
  final QueueEntry current;

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  /// Opens on the panel the player bar of a wide screen was asked for, if it was.
  late _Panel _panel = switch (PlayerSheetScope.of(context).takePanel()) {
    PlayerPanel.lyrics => _Panel.lyrics,
    PlayerPanel.upNext => _Panel.upNext,
    null => _Panel.cover,
  };

  RoomController get _c => widget.controller;

  /// A second touch on the button of the panel that is open goes back to the cover.
  void _show(_Panel panel) =>
      setState(() => _panel = _panel == panel ? _Panel.cover : panel);

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // The colours drift while the song plays, as Apple Music's do
        ListenableBuilder(
          listenable: _c.playState,
          builder: (context, _) => PlayerBackdrop(
            coverUrl: widget.current.thumb,
            moving: _c.isPlaying,
          ),
        ),
        // On its side the phone has no height for one column: the cover goes beside the controls instead. The
        // safe area also keeps both clear of a notch at the side.
        SafeArea(
          child: LayoutBuilder(
            builder: (context, box) =>
                box.maxWidth > box.maxHeight ? _wide(box) : _tall(context),
          ),
        ),
      ],
    );
  }

  Widget _tall(BuildContext context) {
    final p = context.palette;
    final current = widget.current;
    // On a tablet held upright the column does not stretch across the screen
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: _tallColumn(p, current),
      ),
    );
  }

  Widget _tallColumn(Palette p, QueueEntry current) {
    return Column(
      children: [
        const SizedBox(height: 6),
        _Grabber(color: p.textTertiary.withValues(alpha: 0.5)),
        const SizedBox(height: 10),
        _ModePill(controller: _c),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 240),
            layoutBuilder: (current, previous) =>
                Stack(fit: StackFit.expand, children: [...previous, ?current]),
            child: switch (_panel) {
              _Panel.cover => _CoverStage(
                key: const ValueKey('cover'),
                controller: _c,
                current: current,
              ),
              _ => _PanelStage(
                key: ValueKey(_panel),
                controller: _c,
                current: current,
                panel: _panel,
                onCover: () => setState(() => _panel = _Panel.cover),
              ),
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            children: [
              const SizedBox(height: 14),
              PlaybackBar(controller: _c),
              const SizedBox(height: 10),
              _TransportRow(controller: _c),
              const SizedBox(height: 6),
              _Toolbar(controller: _c, panel: _panel, onPanel: _show),
              if (_c.snapshot.inRoom) ...[
                const SizedBox(height: 6),
                _RoomStrip(controller: _c),
              ],
              const SizedBox(height: 14),
            ],
          ),
        ),
      ],
    );
  }

  /// The cover on the left, as tall as the screen allows; the controls, or a panel in their place, on the right.
  Widget _wide(BoxConstraints box) {
    const margin = 16.0;
    // As tall as the screen allows, but not the size of a wall on a big one
    final side = (box.maxHeight - 2 * margin).clamp(
      100.0,
      (box.maxWidth * 0.46).clamp(100.0, 520.0),
    );
    // A picture keeps its own proportions, so it gets a wider place than a square cover
    final left = _c.snapshot.video
        ? (side * 16 / 9).clamp(0.0, box.maxWidth * 0.52)
        : side;
    // The cover and the controls stay together in the middle of a wide window instead of drifting to its two sides
    final gutter = ((box.maxWidth - 1040) / 2).clamp(0.0, double.infinity);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 24 + gutter, vertical: margin),
      child: Row(
        children: [
          SizedBox(
            width: left,
            height: box.maxHeight - 2 * margin,
            child: Center(
              child: _CoverArt(
                controller: _c,
                current: widget.current,
                size: side,
              ),
            ),
          ),
          const SizedBox(width: 28),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 240),
              layoutBuilder: (current, previous) => Stack(
                fit: StackFit.expand,
                children: [...previous, ?current],
              ),
              child: _panel == _Panel.cover
                  ? _WideControls(
                      key: const ValueKey('controls'),
                      controller: _c,
                      current: widget.current,
                      panel: _panel,
                      onPanel: _show,
                    )
                  : _WidePanel(
                      key: ValueKey(_panel),
                      controller: _c,
                      current: widget.current,
                      panel: _panel,
                      onPanel: _show,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shuffle, previous, play, next and repeat.
class _TransportRow extends StatelessWidget {
  const _TransportRow({required this.controller, this.playSize = 72});

  final RoomController controller;
  final double playSize;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller.playState,
    builder: (context, _) => Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _ShuffleButton(controller: controller),
        SkipButton(forward: false, onPressed: controller.prev, size: 52),
        PlayPauseButton(
          playing: controller.isPlaying,
          starting: controller.isStarting,
          onPressed: controller.togglePlay,
          size: playSize,
        ),
        SkipButton(forward: true, onPressed: controller.next, size: 52),
        _RepeatButton(controller: controller),
      ],
    ),
  );
}

/// Closes the player. The grabber of the upright player is too small a mark when the phone is on its side.
class _CloseButton extends StatelessWidget {
  const _CloseButton();

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: PlayerSheetScope.of(context).close,
    tooltip: S.close,
    icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 32),
    color: context.palette.textSecondary,
  );
}

/// The right side of the player on its side: what the upright player has under its cover.
class _WideControls extends StatelessWidget {
  const _WideControls({
    super.key,
    required this.controller,
    required this.current,
    required this.panel,
    required this.onPanel,
  });

  final RoomController controller;
  final QueueEntry current;
  final _Panel panel;
  final ValueChanged<_Panel> onPanel;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => Center(
      // Phones that are short on their side shrink the whole column a little rather than overflow
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox(
          // Never narrower than the row of buttons needs, so that a narrow place scales it down instead
          width: box.maxWidth.clamp(320.0, 440.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const _CloseButton(),
                  Expanded(
                    child: Center(child: _ModePill(controller: controller)),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
              const SizedBox(height: 8),
              _TitleRow(controller: controller, current: current),
              const SizedBox(height: 4),
              PlaybackBar(controller: controller),
              const SizedBox(height: 6),
              _TransportRow(controller: controller, playSize: 64),
              const SizedBox(height: 4),
              _Toolbar(controller: controller, panel: panel, onPanel: onPanel),
              if (controller.snapshot.inRoom) ...[
                const SizedBox(height: 4),
                _RoomStrip(controller: controller),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

/// A panel in place of the controls, with the song and the means to play or skip it above, so that music stays in
/// hand while its lyrics or queue are read.
class _WidePanel extends StatelessWidget {
  const _WidePanel({
    super.key,
    required this.controller,
    required this.current,
    required this.panel,
    required this.onPanel,
  });

  final RoomController controller;
  final QueueEntry current;
  final _Panel panel;
  final ValueChanged<_Panel> onPanel;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          children: [
            Row(
              children: [
                const _CloseButton(),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MarqueeText(
                        current.title,
                        style: theme.titleMedium,
                        rounds: MarqueeText.playerRounds,
                      ),
                      MarqueeText(
                        current.artist,
                        style: theme.bodyMedium?.copyWith(color: p.primary),
                        rounds: MarqueeText.playerRounds,
                      ),
                    ],
                  ),
                ),
                ListenableBuilder(
                  listenable: controller.playState,
                  builder: (context, _) => PlayPauseButton(
                    playing: controller.isPlaying,
                    starting: controller.isStarting,
                    onPressed: controller.togglePlay,
                    size: 44,
                  ),
                ),
                SkipButton(forward: true, onPressed: controller.next, size: 34),
              ],
            ),
            Expanded(
              child: switch (panel) {
                _Panel.lyrics => LyricsView(
                  controller: controller,
                  track: current,
                ),
                _Panel.upNext => UpNextView(controller: controller),
                _ => RelatedView(track: current),
              },
            ),
            _Toolbar(controller: controller, panel: panel, onPanel: onPanel),
          ],
        ),
      ),
    );
  }
}

/// The big cover (or the picture) with the title and the buttons that go with the song.
class _CoverStage extends StatelessWidget {
  const _CoverStage({
    super.key,
    required this.controller,
    required this.current,
  });

  final RoomController controller;
  final QueueEntry current;

  @override
  Widget build(BuildContext context) {
    final artSize = coverSize(MediaQuery.of(context));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        children: [
          const Spacer(flex: 2),
          _CoverArt(controller: controller, current: current, size: artSize),
          const Spacer(flex: 2),
          _TitleRow(controller: controller, current: current),
        ],
      ),
    );
  }
}

/// The cover, or the picture when the song is shown as a video. It is the same in the upright player and on its side.
class _CoverArt extends StatelessWidget {
  const _CoverArt({
    required this.controller,
    required this.current,
    required this.size,
  });

  final RoomController controller;
  final QueueEntry current;
  final double size;

  @override
  Widget build(BuildContext context) {
    final sheet = PlayerSheetScope.of(context);
    if (controller.snapshot.video) {
      return VideoView(
        key: const ValueKey('video'),
        controller: controller,
        cover: current,
      );
    }
    return ListenableBuilder(
      listenable: controller.playState,
      // Paused covers shrink, like in Apple Music; the shadow settles with the cover rather than jumping ahead of it
      builder: (context, _) => TweenAnimationBuilder<double>(
        tween: Tween(end: controller.isPlaying ? 1 : 0),
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutBack,
        builder: (context, t, child) => Transform.scale(
          scale: 0.86 + 0.14 * t,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.14 + 0.14 * t),
                  blurRadius: 18 + 18 * t,
                  offset: Offset(0, 8 + 10 * t),
                ),
              ],
            ),
            child: child,
          ),
        ),
        child: CoverSlot(
          controller: sheet,
          child: Artwork(
            key: sheet.pageCover,
            url: current.thumb,
            size: size,
            radius: 16,
            sharp: true,
          ),
        ),
      ),
    );
  }
}

/// A panel in place of the cover, under a small cover and the title so that the song stays in view.
class _PanelStage extends StatelessWidget {
  const _PanelStage({
    super.key,
    required this.controller,
    required this.current,
    required this.panel,
    required this.onCover,
  });

  final RoomController controller;
  final QueueEntry current;
  final _Panel panel;
  final VoidCallback onCover;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 14, 20, 8),
          child: Row(
            children: [
              GestureDetector(
                onTap: onCover,
                child: Artwork(url: current.thumb, size: 56, radius: 10),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MarqueeText(
                      current.title,
                      style: theme.titleMedium,
                      rounds: MarqueeText.playerRounds,
                    ),
                    MarqueeText(
                      current.artist,
                      style: theme.bodyMedium?.copyWith(color: p.primary),
                      rounds: MarqueeText.playerRounds,
                    ),
                  ],
                ),
              ),
              LikeButton(track: current, size: 24),
              _MoreButton(controller: controller, current: current),
            ],
          ),
        ),
        Expanded(
          child: switch (panel) {
            _Panel.lyrics => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: LyricsView(controller: controller, track: current),
            ),
            _Panel.upNext => UpNextView(controller: controller),
            _ => RelatedView(track: current),
          },
        ),
      ],
    );
  }
}

class _TitleRow extends StatelessWidget {
  const _TitleRow({required this.controller, required this.current});

  final RoomController controller;
  final QueueEntry current;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MarqueeText(
                current.title,
                style: theme.headlineSmall,
                rounds: MarqueeText.playerRounds,
              ),
              const SizedBox(height: 2),
              MarqueeText(
                current.artist,
                style: theme.titleMedium?.copyWith(
                  color: p.primary,
                  fontWeight: FontWeight.w500,
                ),
                rounds: MarqueeText.playerRounds,
              ),
            ],
          ),
        ),
        LikeButton(track: current, size: 26),
        _MoreButton(controller: controller, current: current),
      ],
    );
  }
}

/// The "…" of the song: its info, its artist, a playlist to put it in, keeping it on the phone.
class _MoreButton extends StatelessWidget {
  const _MoreButton({required this.controller, required this.current});

  final RoomController controller;
  final QueueEntry current;

  Future<void> _openArtist(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    String? id;
    try {
      final radio = await AppScope.of(context).music.radio(current.videoId);
      id = radio.songOf(current.videoId)?.artistId;
    } on Object {
      // Said below
    }
    if (id == null) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(S.musicFailed)));
      return;
    }
    if (navigator.mounted) await openArtist(navigator.context, id);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final library = AppScope.of(context).library;
    final snapshot = controller.snapshot;
    final who = current.addedBy == snapshot.you
        ? S.you
        : snapshot.nameOf(current.addedBy);
    return PopupMenuButton<String>(
      useRootNavigator: true,
      icon: Icon(Icons.more_horiz_rounded, color: p.textSecondary),
      color: p.brightness == Brightness.light
          ? const Color(0xFFFFF7F9)
          : const Color(0xFF2B1F25),
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      onSelected: (value) => switch (value) {
        'info' => showSongInfo(
          context,
          current,
          addedBy: who.isEmpty ? null : who,
        ),
        'artist' => _openArtist(context),
        'playlist' => showAddToPlaylist(context, [current]),
        'download' => startDownload(context, [current]),
        'blocked' => showNotInterested(context, current),
        _ => library.removeDownload(current.videoId),
      },
      itemBuilder: (context) => [
        PopupMenuItem(value: 'info', child: Text(S.songInfo)),
        PopupMenuItem(value: 'artist', child: Text(S.goToArtist)),
        PopupMenuItem(value: 'playlist', child: Text(S.addToPlaylist)),
        ...switch (library.downloadState(current.videoId)) {
          DownloadState.done => [
            PopupMenuItem(value: 'undownload', child: Text(S.removeDownload)),
          ],
          DownloadState.queued || DownloadState.waiting => [
            PopupMenuItem(
              enabled: false,
              value: 'none',
              child: Text(S.downloading),
            ),
          ],
          _ => [PopupMenuItem(value: 'download', child: Text(S.download))],
        },
        PopupMenuItem(value: 'blocked', child: Text(S.notInterested)),
      ],
    );
  }
}

/// Lyrics, the queue, related songs and the sleep timer: the things to reach for while listening.
class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.controller,
    required this.panel,
    required this.onPanel,
  });

  final RoomController controller;
  final _Panel panel;
  final ValueChanged<_Panel> onPanel;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    Widget button(IconData icon, String label, _Panel target) {
      final on = panel == target;
      return IconButton(
        onPressed: () => onPanel(target),
        tooltip: label,
        isSelected: on,
        icon: Icon(icon, size: 26),
        style: IconButton.styleFrom(
          foregroundColor: on ? p.onPrimaryContainer : p.textTertiary,
          backgroundColor: on ? p.primaryContainer : Colors.transparent,
          fixedSize: const Size(52, 44),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            button(Icons.lyrics_outlined, S.lyrics, _Panel.lyrics),
            button(Icons.queue_music_rounded, S.upNext, _Panel.upNext),
            button(Icons.explore_outlined, S.related, _Panel.related),
            Flexible(child: _SleepButton(controller: controller)),
          ],
        ),
        _OutputButton(controller: controller),
      ],
    );
  }
}

/// Says where the sound goes, the phone or headphones or a speaker, and opens the system's list to play somewhere
/// else. Lit up while the sound is not on the phone itself.
class _OutputButton extends StatelessWidget {
  const _OutputButton({required this.controller});

  final RoomController controller;

  static IconData _icon(String kind) => switch (kind) {
    'headphones' => Icons.headphones_rounded,
    'bluetooth' => Icons.bluetooth_audio_rounded,
    'airplay' => Icons.airplay_rounded,
    'car' => Icons.directions_car_rounded,
    'other' => Icons.speaker_group_rounded,
    _ => Icons.smartphone_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final output = controller.output;
    final away = output.kind != 'speaker';
    return Tooltip(
      message: S.playOn,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        child: TextButton.icon(
          onPressed: controller.pickOutput,
          icon: Icon(_icon(output.kind), size: 20),
          label: Text(
            output.name.isEmpty ? S.thisPhone : output.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          style: TextButton.styleFrom(
            foregroundColor: away ? p.primary : p.textTertiary,
            backgroundColor: away ? p.primaryContainer : Colors.transparent,
            shape: const StadiumBorder(),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
      ),
    );
  }
}

/// Opens the sleep timer; lit up, with the hour it stops at, while one is set.
class _SleepButton extends StatelessWidget {
  const _SleepButton({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final sleep = controller.sleep;
    if (!sleep.on) {
      return IconButton(
        onPressed: () => showSleepSheet(context, controller),
        tooltip: S.sleepTimer,
        icon: const Icon(Icons.bedtime_outlined, size: 26),
        style: IconButton.styleFrom(
          foregroundColor: p.textTertiary,
          fixedSize: const Size(52, 44),
        ),
      );
    }
    return TextButton.icon(
      onPressed: () => showSleepSheet(context, controller),
      icon: const Icon(Icons.bedtime_outlined, size: 20),
      label: Text(
        sleepLabel(context, sleep),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      style: TextButton.styleFrom(
        foregroundColor: p.primary,
        backgroundColor: p.primaryContainer,
        shape: const StadiumBorder(),
      ),
    );
  }
}

/// Mixes up what comes next. It is an action, not a mode, so it says what it did: the icon turns once and a
/// note follows. Dimmed when there is nothing to mix.
class _ShuffleButton extends StatefulWidget {
  const _ShuffleButton({required this.controller});

  final RoomController controller;

  @override
  State<_ShuffleButton> createState() => _ShuffleButtonState();
}

class _ShuffleButtonState extends State<_ShuffleButton> {
  int _turns = 0;

  void _shuffle() {
    HapticFeedback.selectionClick();
    setState(() => _turns++);
    widget.controller.shuffle();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(S.upNextShuffled),
          duration: Duration(milliseconds: 1400),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final enough = widget.controller.snapshot.upNext.length > 1;
    return IconButton(
      onPressed: enough ? _shuffle : null,
      tooltip: S.shuffle,
      color: p.primary,
      disabledColor: p.textTertiary.withValues(alpha: 0.5),
      icon: AnimatedRotation(
        turns: _turns.toDouble(),
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
        child: const Icon(Icons.shuffle_rounded),
      ),
    );
  }
}

/// Cycles off, repeat all, repeat this song. Lit up while repeating.
class _RepeatButton extends StatelessWidget {
  const _RepeatButton({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final mode = controller.snapshot.repeat;
    final on = mode != Repeat.off;
    return Tooltip(
      message: switch (mode) {
        Repeat.off => S.repeatOff,
        Repeat.all => S.repeatAll,
        Repeat.one => S.repeatOne,
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: on ? p.primaryContainer : Colors.transparent,
        ),
        child: IconButton(
          onPressed: controller.cycleRepeat,
          icon: Icon(
            mode == Repeat.one
                ? Icons.repeat_one_rounded
                : Icons.repeat_rounded,
          ),
          color: on ? p.onPrimaryContainer : p.textTertiary,
        ),
      ),
    );
  }
}

/// What a touch on Audio or Video does. The picture is this device's own choice and follows at once. The song also
/// changes to its other release (the music video, or the audio release) like YouTube Music's switch does: outside a
/// room for this device, in a room for everybody, because the queue is shared. A room only goes to the video
/// that way, not back: somebody else may be watching it.
Future<void> _chooseMode(BuildContext context, bool video) async {
  final controller = AppScope.roomOf(context);
  final music = AppScope.of(context).music;
  final messenger = ScaffoldMessenger.of(context);
  final snapshot = controller.snapshot;
  final current = snapshot.current;
  if (video == snapshot.video) return;
  await controller.setVideoMode(video);
  if (current == null ||
      (snapshot.inRoom && (!video || !snapshot.canControl))) {
    return;
  }
  MusicTrack? other;
  try {
    // Already the release asked for?
    if (await music.isAudioRelease(current) == !video) return;
    other = await music.otherRelease(current, video: video);
  } on Object {
    return; // no network: the picture alone
  }
  // The person may have moved on while YouTube was asked
  if (controller.snapshot.current?.id != current.id) return;
  if (other == null) {
    if (video) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(S.noVideoVersion)));
    }
    return;
  }
  await controller.swapVersion(current, other);
  if (snapshot.inRoom) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(S.videoForEveryone)));
  }
}

/// Audio or Video, like the switch at the top of YouTube Music's player.
class _ModePill extends StatelessWidget {
  const _ModePill({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final video = controller.snapshot.video;
    Widget segment(String label, bool selected, VoidCallback onTap) =>
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
            decoration: BoxDecoration(
              color: selected ? p.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium
                  ?.copyWith(color: selected ? p.onPrimary : p.textSecondary),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: p.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          segment(S.modeAudio, !video, () => _chooseMode(context, false)),
          segment(S.modeVideo, video, () => _chooseMode(context, true)),
        ],
      ),
    );
  }
}

class _Grabber extends StatelessWidget {
  const _Grabber({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 40,
    height: 5,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(3),
    ),
  );
}

/// Who is listening and whether this phone is in step with them.
class _RoomStrip extends StatelessWidget {
  const _RoomStrip({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final snapshot = controller.snapshot;
    return Row(
      children: [
        // Who is here: tapping opens the list of members
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => showMembersSheet(context),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  AvatarStack(members: snapshot.members, size: 30),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      S.listening(snapshot.listeningCount),
                      style: theme.bodySmall?.copyWith(color: p.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        ListenableBuilder(
          listenable: controller.player,
          builder: (context, _) => _SyncChip(controller: controller),
        ),
      ],
    );
  }
}

/// Within this many ms of the room counts as in sync (the drift control aims well inside it).
const _inSyncMs = 80;

class _SyncChip extends StatelessWidget {
  const _SyncChip({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final player = controller.player.value;
    final drift = player.driftMs;
    final String label;
    final Color color;
    if (controller.snapshot.solo) {
      label = S.onYourOwn;
      color = p.primary;
    } else if (!controller.isPlaying) {
      return const SizedBox.shrink();
    } else if (controller.isStarting) {
      label = S.buffering;
      color = p.textSecondary;
    } else if (drift == null) {
      label = S.syncing;
      color = p.textSecondary;
    } else if (drift.abs() <= _inSyncMs) {
      label = '${S.inSync} · ${formatDrift(drift)}';
      color = p.success;
    } else {
      // Off by an audible amount: the drift control is bringing this phone back
      label = '${S.catchingUp} · ${formatDrift(drift)}';
      color = p.textSecondary;
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showMembersSheet(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium
                  ?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}
