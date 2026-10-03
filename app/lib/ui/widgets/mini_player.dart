import 'package:flutter/material.dart';

import '../../data/room_controller.dart';
import '../../strings.dart';
import '../../theme/theme.dart';
import '../home_shell.dart';
import '../player_sheet.dart';
import 'artwork.dart';
import 'glass.dart';
import 'marquee_text.dart';
import 'transport.dart';

/// Floating capsule above the tab bar. Tap it, or drag it up, to open the full player.
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.controller, this.folded = 0});

  final RoomController controller;

  /// How far the bars are folded away, 0 to 1. Folded, the capsule sits between the tab that is open and Search, as
  /// low as they are, with the cover, the title and the play button only.
  final double folded;

  /// Lower on a screen that is wider than it is tall, where height is what is short.
  static double heightOf(BuildContext context) =>
      HomeShell.isWide(context) ? 52 : 58;

  @override
  Widget build(BuildContext context) {
    final sheet = PlayerSheetScope.of(context);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final current = controller.snapshot.current;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          switchInCurve: Curves.easeOutCubic,
          transitionBuilder: (child, animation) => SlideTransition(
            position: Tween(
              begin: const Offset(0, 0.6),
              end: Offset.zero,
            ).animate(animation),
            child: FadeTransition(opacity: animation, child: child),
          ),
          child: current == null
              ? const SizedBox(key: ValueKey('none'), width: double.infinity)
              : PlayerOpenDrag(
                  key: const ValueKey('player'),
                  child: KeyedSubtree(
                    key: sheet.miniBar,
                    child: MiniPlayerCapsule(
                      controller: controller,
                      onTap: sheet.open,
                      folded: folded,
                    ),
                  ),
                ),
        );
      },
    );
  }
}

/// The capsule itself. With [ghost] it is only a picture of the capsule, drawn by the opening player as the capsule
/// turns into it: it takes no touches and leaves the cover to the cover that flies.
class MiniPlayerCapsule extends StatelessWidget {
  const MiniPlayerCapsule({
    super.key,
    required this.controller,
    this.onTap,
    this.ghost = false,
    this.folded = 0,
  });

  final RoomController controller;
  final VoidCallback? onTap;
  final bool ghost;

  /// See [MiniPlayer.folded].
  final double folded;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final sheet = PlayerSheetScope.of(context);
    final current = controller.snapshot.current;
    if (current == null) return const SizedBox.shrink();
    final open = MiniPlayer.heightOf(context);
    final height = open + (HomeShell.tabHeightOf(context) - open) * folded;
    final cover = (height - 8).clamp(0.0, 44.0);
    // What folding takes away is gone half way
    final fading = (1 - 2 * folded).clamp(0.0, 1.0);
    return Glass(
      borderRadius: BorderRadius.circular(height / 2),
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: height,
          child: Row(
            children: [
              // The cover is round and as far from the edge on the left as from the top and bottom, so its curve
              // follows the capsule's end
              SizedBox(width: (height - cover) / 2),
              if (ghost)
                SizedBox.square(dimension: cover)
              else
                Artwork(
                  key: sheet.miniCover,
                  url: current.thumb,
                  size: cover,
                  radius: cover / 2,
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
                    if (fading > 0)
                      Align(
                        alignment: Alignment.topLeft,
                        heightFactor: 1 - folded,
                        child: Opacity(
                          opacity: fading,
                          child: MarqueeText(
                            controller.snapshot.solo
                                ? '${current.artist} · ${S.onYourOwn}'
                                : current.artist,
                            style: theme.bodySmall?.copyWith(
                              color: p.textSecondary,
                            ),
                            rounds: MarqueeText.barRounds,
                          ),
                        ),
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
                  size: height < 48 ? height : 48,
                  filled: false,
                ),
              ),
              if (fading > 0)
                Align(
                  alignment: Alignment.centerLeft,
                  widthFactor: 1 - folded,
                  child: Opacity(
                    opacity: fading,
                    child: SkipButton(
                      forward: true,
                      onPressed: controller.next,
                      size: 34,
                    ),
                  ),
                ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}
