import 'package:flutter/material.dart';

import '../../data/room_controller.dart';
import '../../strings.dart';
import '../../theme/theme.dart';
import '../player_sheet.dart';
import 'artwork.dart';
import 'glass.dart';
import 'marquee_text.dart';
import 'playback_bar.dart';
import 'transport.dart';

/// The player along the bottom of a wide screen, in the manner of Apple Music on an iPad or a Mac: the song on the
/// left, the controls over the seek bar in the middle, the lyrics and the queue on the right. Tap it, or drag it up,
/// to open the full player.
class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key, required this.controller});

  final RoomController controller;

  static const height = 76.0;

  @override
  Widget build(BuildContext context) {
    final sheet = PlayerSheetScope.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 280),
        switchInCurve: Curves.easeOutCubic,
        transitionBuilder: (child, animation) => SlideTransition(
          position: Tween(
            begin: const Offset(0, 0.6),
            end: Offset.zero,
          ).animate(animation),
          child: FadeTransition(opacity: animation, child: child),
        ),
        child: controller.snapshot.current == null
            ? const SizedBox(key: ValueKey('none'), width: double.infinity)
            : PlayerOpenDrag(
                key: const ValueKey('player'),
                child: KeyedSubtree(
                  key: sheet.miniBar,
                  child: PlayerBarBody(
                    controller: controller,
                    onTap: sheet.open,
                  ),
                ),
              ),
      ),
    );
  }
}

/// The bar itself. With [ghost] it is only a picture of it, drawn by the opening player as the bar turns into it: it
/// takes no touches and leaves the cover to the cover that flies.
class PlayerBarBody extends StatelessWidget {
  const PlayerBarBody({
    super.key,
    required this.controller,
    this.onTap,
    this.ghost = false,
  });

  final RoomController controller;
  final VoidCallback? onTap;
  final bool ghost;

  static const _cover = 52.0;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final sheet = PlayerSheetScope.of(context);
    final current = controller.snapshot.current;
    if (current == null) return const SizedBox.shrink();
    const side = (PlayerBar.height - _cover) / 2;
    return Glass(
      borderRadius: BorderRadius.circular(PlayerBar.height / 2),
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: PlayerBar.height,
          child: LayoutBuilder(
            builder: (context, box) {
              // The middle takes what the song and the buttons leave, within reason
              final middle = (box.maxWidth * 0.38).clamp(220.0, 420.0);
              return Row(
                children: [
                  const SizedBox(width: side),
                  // Round, as the mini player's: the cover flies from here into the full player
                  if (ghost)
                    const SizedBox.square(dimension: _cover)
                  else
                    Artwork(
                      key: sheet.miniCover,
                      url: current.thumb,
                      size: _cover,
                      radius: _cover / 2,
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        MarqueeText(
                          current.title,
                          style: theme.titleSmall,
                          rounds: MarqueeText.barRounds,
                        ),
                        MarqueeText(
                          controller.snapshot.solo
                              ? '${current.artist} · ${S.onYourOwn}'
                              : current.artist,
                          style: theme.bodySmall?.copyWith(
                            color: p.textSecondary,
                          ),
                          rounds: MarqueeText.barRounds,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 28),
                  SizedBox(
                    width: middle,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ListenableBuilder(
                          listenable: controller.playState,
                          builder: (context, _) => Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SkipButton(
                                forward: false,
                                onPressed: controller.prev,
                                size: 26,
                              ),
                              const SizedBox(width: 8),
                              PlayPauseButton(
                                playing: controller.isPlaying,
                                starting: controller.isStarting,
                                onPressed: controller.togglePlay,
                                size: 40,
                                filled: false,
                              ),
                              const SizedBox(width: 8),
                              SkipButton(
                                forward: true,
                                onPressed: controller.next,
                                size: 26,
                              ),
                            ],
                          ),
                        ),
                        PlaybackBar(controller: controller, compact: true),
                      ],
                    ),
                  ),
                  const SizedBox(width: 28),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        IconButton(
                          onPressed: () => sheet.openOn(PlayerPanel.lyrics),
                          tooltip: S.lyrics,
                          icon: Icon(
                            Icons.lyrics_outlined,
                            color: p.textSecondary,
                          ),
                        ),
                        IconButton(
                          onPressed: () => sheet.openOn(PlayerPanel.upNext),
                          tooltip: S.upNext,
                          icon: Icon(
                            Icons.queue_music_rounded,
                            color: p.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 14),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
