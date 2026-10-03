import 'package:flutter/material.dart';

import '../../data/models.dart';
import '../../data/music_models.dart';
import '../../theme/theme.dart';
import '../widgets/queue_actions.dart';
import '../widgets/play_actions.dart';
import '../widgets/track_menu.dart';
import '../widgets/cached_cover.dart';
import '../widgets/track_tile.dart';

/// A heading and rows of songs that a touch plays, each with the usual "more" menu.
class TrackSection extends StatelessWidget {
  const TrackSection({
    super.key,
    required this.title,
    required this.tracks,
    this.headerAction,
  });

  final String title;
  final List<Track> tracks;

  /// At the end of the heading, like a switch.
  final Widget? headerAction;

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title.isNotEmpty) SectionHeading(title, action: headerAction),
        for (final track in tracks)
          TrackTile(
            track: track,
            onTap: () => playNow(context, track),
            trailing: TrackMenu(
              track: track,
              onAdd: () => queueTrack(context, track),
              onPlayNext: () => queueTrack(context, track, playNext: true),
            ),
          ),
      ],
    );
  }
}

/// A title above a block of a page, with room for something at its end.
class SectionHeading extends StatelessWidget {
  const SectionHeading(this.title, {super.key, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 12, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          ?action,
        ],
      ),
    );
  }
}

/// Round pictures with a name under each, in a row that scrolls sideways: artists to look at next.
class ArtistRow extends StatelessWidget {
  const ArtistRow({super.key, required this.artists, required this.onOpen});

  final List<ArtistCard> artists;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SizedBox(
      height: 132,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: artists.length,
        separatorBuilder: (_, _) => const SizedBox(width: 14),
        itemBuilder: (context, i) {
          final artist = artists[i];
          return InkWell(
            onTap: () => onOpen(artist.id),
            borderRadius: BorderRadius.circular(46),
            child: SizedBox(
              width: 92,
              child: Column(
                children: [
                  ClipOval(
                    child: SizedBox.square(
                      dimension: 92,
                      child: artist.thumb == null
                          ? ColoredBox(
                              color: p.primaryContainer,
                              child: Icon(
                                Icons.person_rounded,
                                color: p.primary,
                              ),
                            )
                          : Image(
                              image: ResizeImage(
                                CachedCover(artist.thumb!),
                                width: 276,
                              ),
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) =>
                                  ColoredBox(color: p.primaryContainer),
                            ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    artist.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
