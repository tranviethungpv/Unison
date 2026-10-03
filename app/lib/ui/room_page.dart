import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../data/room_controller.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'home_shell.dart';
import 'members_sheet.dart';
import 'rooms_sheet.dart';
import 'scope.dart';
import 'widgets/appear.dart';
import 'widgets/avatars.dart';
import 'widgets/delete_background.dart';
import 'widgets/equalizer.dart';
import 'widgets/link_banner.dart';
import 'widgets/scroll_edge.dart';
import 'widgets/track_tile.dart';

/// What is playing and what is queued: the room's shared queue while in a room, and otherwise
/// this device's own, with the way into a room at the top.
class RoomPage extends StatefulWidget {
  const RoomPage({super.key, required this.onAddSongs});

  final VoidCallback onAddSongs;

  @override
  State<RoomPage> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage> {
  /// Songs that were already on the list, so only ones that show up later animate in.
  final _known = <String>{};
  bool _seeded = false;

  VoidCallback get onAddSongs => widget.onAddSongs;

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.roomOf(context);
    if (!_seeded) {
      _seeded = true;
      _known.addAll(controller.snapshot.queue.map((e) => e.id));
    }
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final snapshot = controller.snapshot;
        // Remember what is on screen once this frame is done
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _known.addAll(snapshot.queue.map((e) => e.id)),
        );
        // The list starts below the status bar and scrolls up under it, to its glass edge
        return ScrollEdge(
          title: snapshot.inRoom ? snapshot.name ?? S.tabRoom : S.tabListen,
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            slivers: [
              SliverToBoxAdapter(
                child: SizedBox(height: ScrollEdge.topOf(context)),
              ),
              SliverToBoxAdapter(child: _Header(snapshot: snapshot)),
              SliverToBoxAdapter(child: LinkBanner(link: snapshot.link)),
              if (snapshot.solo)
                SliverToBoxAdapter(child: _SoloBanner(controller: controller)),
              if (snapshot.inRoom &&
                  snapshot.guestControl == GuestControl.add &&
                  !snapshot.canControl)
                const SliverToBoxAdapter(child: _GuestsAddOnlyBanner()),
              if (snapshot.phase == 'idle' &&
                  snapshot.queue.isNotEmpty &&
                  !snapshot.solo)
                SliverToBoxAdapter(
                  child: _FinishedBanner(controller: controller),
                ),
              if (snapshot.queue.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _EmptyQueue(
                    onAddSongs: onAddSongs,
                    body: snapshot.inRoom
                        ? S.emptyQueueBody
                        : S.emptyQueueBodyAlone,
                  ),
                )
              else
                ..._queueSlivers(context, controller, snapshot),
              SliverToBoxAdapter(
                child: SizedBox(height: HomeShell.bottomInsetOf(context)),
              ),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _queueSlivers(
    BuildContext context,
    RoomController controller,
    RoomSnapshot snapshot,
  ) {
    final current = snapshot.current;
    final played = snapshot.queue.take(snapshot.myIndex).toList();
    final upNext = snapshot.upNext;
    return [
      if (current != null) ...[
        _SectionTitle(S.nowPlaying),
        SliverToBoxAdapter(
          child: _swipeToRemove(
            controller,
            current,
            ListenableBuilder(
              listenable: controller.playState,
              builder: (context, _) => TrackTile(
                track: current,
                subtitle: _byline(snapshot, current),
                highlight: true,
                leadingOverlay: Equalizer(
                  active: controller.isPlaying,
                  color: Colors.white,
                ),
                onTap: () => controller.jump(current),
              ),
            ),
          ),
        ),
      ],
      if (upNext.isNotEmpty) ...[
        _SectionTitle(
          S.upNext,
          action: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                onPressed: () {
                  HapticFeedback.selectionClick();
                  controller.shuffle();
                },
                tooltip: S.shuffle,
                icon: Icon(
                  Icons.shuffle_rounded,
                  color: context.palette.primary,
                ),
              ),
              _ClearButton(controller: controller),
            ],
          ),
        ),
        SliverReorderableList(
          itemCount: upNext.length,
          onReorderItem: (from, to) =>
              controller.move(upNext[from], snapshot.myIndex + 1 + to),
          proxyDecorator: (child, _, animation) => Material(
            color: Colors.transparent,
            elevation: 0,
            child: ScaleTransition(
              scale: Tween(begin: 1.0, end: 1.02).animate(animation),
              child: child,
            ),
          ),
          itemBuilder: (context, i) {
            final entry = upNext[i];
            return Dismissible(
              key: ValueKey(entry.id),
              direction: DismissDirection.endToStart,
              background: const DeleteBackground(),
              onDismissed: (_) {
                HapticFeedback.lightImpact();
                controller.remove(entry);
              },
              child: ReorderableDelayedDragStartListener(
                index: i,
                child: Appear(
                  animate: !_known.contains(entry.id),
                  child: TrackTile(
                    track: entry,
                    subtitle: _byline(snapshot, entry),
                    onTap: () => controller.jump(entry),
                  ),
                ),
              ),
            );
          },
        ),
      ],
      if (played.isNotEmpty) ...[
        _SectionTitle(S.played),
        SliverList.builder(
          itemCount: played.length,
          itemBuilder: (context, i) {
            final entry = played[played.length - 1 - i];
            return _swipeToRemove(
              controller,
              entry,
              TrackTile(
                track: entry,
                subtitle: _byline(snapshot, entry),
                dimmed: true,
                // Tap to hear it again
                onTap: () => controller.jump(entry),
              ),
            );
          },
        ),
      ],
    ];
  }

  /// Swipe a row to the left to take the song off the queue.
  Widget _swipeToRemove(
    RoomController controller,
    QueueEntry entry,
    Widget child,
  ) => Dismissible(
    key: ValueKey(entry.id),
    direction: DismissDirection.endToStart,
    background: const DeleteBackground(),
    onDismissed: (_) {
      HapticFeedback.lightImpact();
      controller.remove(entry);
    },
    child: child,
  );

  String _byline(RoomSnapshot snapshot, QueueEntry entry) {
    final who = entry.addedBy == snapshot.you
        ? S.you
        : snapshot.nameOf(entry.addedBy);
    return who.isEmpty ? entry.artist : '${entry.artist} · ${S.addedBy(who)}';
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.snapshot});

  final RoomSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  snapshot.inRoom ? snapshot.name ?? S.tabRoom : S.tabListen,
                  style: theme.headlineLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (snapshot.inRoom) ...[
                _CodeChip(code: snapshot.room ?? ''),
                IconButton(
                  onPressed: AppScope.roomOf(context).shareInvite,
                  tooltip: S.invite,
                  icon: Icon(Icons.ios_share_rounded, color: p.primary),
                ),
                IconButton(
                  onPressed: () => showRoomSheet(context),
                  tooltip: S.room,
                  icon: Icon(Icons.more_horiz_rounded, color: p.primary),
                ),
              ] else
                const _RoomButton(),
            ],
          ),
          if (snapshot.inRoom) ...[
            const SizedBox(height: 12),
            // Tapping who is here opens the list of members
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => showMembersSheet(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    AvatarStack(members: snapshot.members),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        snapshot.awayCount == 0
                            ? S.listening(snapshot.listeningCount)
                            : '${S.listening(snapshot.listeningCount)} · ${S.awayCount(snapshot.awayCount)}',
                        style: theme.bodyMedium?.copyWith(
                          color: p.textSecondary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: p.textTertiary,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The way into a room, shown while this device is on its own.
class _RoomButton extends StatelessWidget {
  const _RoomButton();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: p.primaryContainer,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => showRoomSheet(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.groups_rounded, size: 18, color: p.onPrimaryContainer),
              const SizedBox(width: 8),
              Text(
                S.tabRoom,
                style: Theme.of(context).textTheme.labelLarge
                    ?.copyWith(color: p.onPrimaryContainer),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The owner has limited guests to adding songs, and this device is a guest.
class _GuestsAddOnlyBanner extends StatelessWidget {
  const _GuestsAddOnlyBanner();

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: p.primaryContainer,
          borderRadius: BorderRadius.circular(SapocheTheme.cardRadius),
        ),
        child: Row(
          children: [
            Icon(
              Icons.lock_outline_rounded,
              size: 18,
              color: p.onPrimaryContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                S.guestsAddOnlyBanner,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: p.onPrimaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The queue played to its end: the songs are still here, with a way to hear them again.
class _FinishedBanner extends StatelessWidget {
  const _FinishedBanner({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        decoration: BoxDecoration(
          color: p.primaryContainer,
          borderRadius: BorderRadius.circular(SapocheTheme.cardRadius),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                S.queueFinished,
                style: Theme.of(context).textTheme.titleSmall
                    ?.copyWith(color: p.onPrimaryContainer),
              ),
            ),
            IconButton(
              onPressed: controller.shuffle,
              tooltip: S.shuffle,
              icon: Icon(Icons.shuffle_rounded, color: p.onPrimaryContainer),
            ),
            FilledButton(
              onPressed: controller.togglePlay,
              style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
              child: Text(S.playAgain),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown while this device listens on its own, with the way back to the room.
class _SoloBanner extends StatelessWidget {
  const _SoloBanner({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
        decoration: BoxDecoration(
          color: p.primaryContainer,
          borderRadius: BorderRadius.circular(SapocheTheme.cardRadius),
        ),
        child: Row(
          children: [
            Icon(
              Icons.headphones_rounded,
              size: 18,
              color: p.onPrimaryContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                S.soloBanner,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: p.onPrimaryContainer),
              ),
            ),
            TextButton(
              onPressed: () => controller.setSolo(false),
              child: Text(S.rejoin),
            ),
          ],
        ),
      ),
    );
  }
}

class _CodeChip extends StatelessWidget {
  const _CodeChip({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: p.primaryContainer,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () {
          Clipboard.setData(ClipboardData(text: code));
          HapticFeedback.selectionClick();
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text(S.codeCopied)));
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                code,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: p.onPrimaryContainer,
                  letterSpacing: 2.5,
                  fontFeatures: const [],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.copy_rounded, size: 15, color: p.onPrimaryContainer),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 12, 6),
        child: Row(
          children: [
            Expanded(
              child: Text(text, style: Theme.of(context).textTheme.titleLarge),
            ),
            ?action,
          ],
        ),
      ),
    );
  }
}

class _ClearButton extends StatelessWidget {
  const _ClearButton({required this.controller});

  final RoomController controller;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () async {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(S.clearQueue),
            content: Text(S.clearQueueQuestion),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(S.cancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(
                  S.clear,
                  style: TextStyle(color: context.palette.error),
                ),
              ),
            ],
          ),
        );
        if (confirmed == true) controller.clearQueue();
      },
      child: Text(S.clear),
    );
  }
}

class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue({required this.onAddSongs, required this.body});

  final VoidCallback onAddSongs;
  final String body;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(36, 0, 36, HomeShell.bottomInsetOf(context)),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: p.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.queue_music_rounded, size: 42, color: p.primary),
          ),
          const SizedBox(height: 22),
          Text(S.emptyQueueTitle, style: theme.titleLarge),
          const SizedBox(height: 8),
          Text(
            body,
            textAlign: TextAlign.center,
            style: theme.bodyMedium?.copyWith(color: p.textSecondary),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onAddSongs,
            icon: const Icon(Icons.add_rounded),
            label: Text(S.addSongs),
          ),
        ],
      ),
    );
  }
}
