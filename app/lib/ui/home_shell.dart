import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/room_controller.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'home_page.dart';
import 'library_page.dart';
import 'player_sheet.dart';
import 'room_page.dart';
import 'rooms_sheet.dart';
import 'scope.dart';
import 'setup_dialog.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'widgets/artwork.dart';
import 'widgets/cached_cover.dart';
import 'widgets/glass.dart';
import 'widgets/mini_player.dart';
import 'widgets/page_width.dart';
import 'widgets/player_bar.dart';

/// How the home screen is laid out for the size of its window, after Material's window size classes: by the width
/// of the window, not by which way the device is turned.
enum ShellLayout {
  /// A phone, upright or on its side: the tabs, Search and the mini player float at the bottom.
  bars,

  /// A tablet held upright, an unfolded phone, a small window: a rail of tabs on the left, the mini player floating
  /// at the bottom.
  rail,

  /// A tablet on its side, Samsung DeX, a computer: a sidebar on the left with the playlists in it, and a bar for the
  /// player along the bottom.
  sidebar,
}

/// Tabs plus the floating mini player. Lists scroll behind both bars, which blur them.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  /// Whether the screen is wider than it is tall, where the bars are lower to leave room for the page.
  static bool isWide(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.width > size.height;
  }

  static ShellLayout layoutOf(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    // A phone on its side is wide but short, and keeps the phone's bars
    if (size.width < 600 || size.height < 480) return ShellLayout.bars;
    return size.width < 840 ? ShellLayout.rail : ShellLayout.sidebar;
  }

  /// Bottom padding lists need so their last row can scroll clear of the bars. A phone's bars are folded by the time a
  /// page has been scrolled to its end, so it is their folded height (the row of tabs above the system's bar) and a
  /// little room: made for the open bars, the end of every page was a long empty band under the folded ones. Scrolled
  /// back up, the open mini player covers the last rows, as glass that shows them.
  static double bottomInsetOf(BuildContext context) =>
      switch (layoutOf(context)) {
        ShellLayout.bars =>
          math.max(MediaQuery.viewPaddingOf(context).bottom, _barsBottom) +
              tabHeightOf(context) +
              16,
        ShellLayout.rail => 120,
        ShellLayout.sidebar => 112,
      };

  /// The least room under a phone's bars, where the system has no bar of its own.
  static const _barsBottom = 10.0;

  /// Side of a cover in a row of cards: larger where the window is.
  static double cardSizeOf(BuildContext context) => switch (layoutOf(context)) {
    ShellLayout.bars => 148,
    ShellLayout.rail => 164,
    ShellLayout.sidebar => 172,
  };

  /// Height of the capsule of tabs and of the Search button.
  static double tabHeightOf(BuildContext context) => isWide(context) ? 40 : 60;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with TickerProviderStateMixin {
  int _tab = 0;

  /// The last tab of the capsule that was open, where its lens waits while Search is.
  int _browsing = 0;
  late final _sheet = PlayerSheetController(this);

  /// 0 with the bars open, 1 with them folded away while a page is scrolled down, as Apple Music does: the tabs shrink
  /// to the one that is open and the mini player moves down between it and Search.
  late final _folded = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 440),
  );
  bool _isFolded = false;

  /// The two parts of folding: the capsule of tabs shrinks first and the mini player comes down after, so that the
  /// two hardly cross; unfolding plays it backwards, the mini player going up first.
  late final _shrink = CurvedAnimation(
    parent: _folded,
    curve: const Interval(0, 0.6, curve: Curves.easeInOutCubic),
  );
  late final _drop = CurvedAnimation(
    parent: _folded,
    curve: const Interval(0.4, 1, curve: Curves.easeInOutCubic),
  );

  /// Whether the scroll under way is the person's, and how far it has gone one way since it last turned.
  bool _touched = false;
  double _travel = 0;

  /// What the glass of every bar reads from, once for them all.
  final _backdrop = BackdropKey();

  /// Every tab has a navigator of its own, so that a page opened from it (a playlist, an artist) opens inside the
  /// tab, between the top of the screen and the bars, instead of on top of everything.
  final _navigators = List.generate(4, (_) => GlobalKey<NavigatorState>());

  /// Pings when a page is opened or closed in a tab, which the Back button has to know about.
  final _stack = ValueNotifier<int>(0);

  /// One for each navigator: an observer can watch only one.
  late final _watchers = List.generate(
    4,
    (_) => _StackWatcher(() {
      // Opening a page happens in the middle of building; the news waits for the frame to be done
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _stack.value++;
        // A page that opens or closes shows the bars, as a tab does
        _fold(false);
      });
    }),
  );

  /// The search field, for the sidebar and the `/` key to put the cursor in.
  final _searchFocus = FocusNode(debugLabel: 'search');

  /// What the sidebar of a wide screen asks the library to show.
  final _libraryRequests = LibraryRequests();

  NavigatorState? get _current => _navigators[_tab].currentState;
  StreamSubscription<String>? _messages;
  StreamSubscription<String>? _libraryMessages;
  StreamSubscription<Notice>? _notices;
  RoomController? _watched;
  String? _precachedCover;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_messages != null) return;
    final room = _watched = AppScope.roomOf(context);
    _messages = room.messages.listen((text) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(text)));
    });
    _libraryMessages = AppScope.of(context).library.messages.listen((text) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(text)));
    });
    _notices = room.notices.listen((notice) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(notice.text),
            duration: const Duration(seconds: 6),
            action: notice.canKeepPlaying
                ? SnackBarAction(
                    label: S.keepPlaying,
                    onPressed: room.keepPlaying,
                  )
                : null,
          ),
        );
    });
    HardwareKeyboard.instance.addHandler(_onKey);
    TabNavigation._active = () => _current;
    TabNavigation._closePlayer = () {
      if (_sheet.isOpen) _sheet.close();
    };
    room.invite.addListener(_onInvite);
    room.setup.addListener(_onSetup);
    room.addListener(_precacheCover);
    WidgetsBinding.instance.addPostFrameCallback((_) => _precacheCover());
    WidgetsBinding.instance.addPostFrameCallback((_) => _onInvite());
    WidgetsBinding.instance.addPostFrameCallback((_) => _onSetup());
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    TabNavigation._active = null;
    TabNavigation._closePlayer = null;
    _stack.dispose();
    _watched?.invite.removeListener(_onInvite);
    _watched?.setup.removeListener(_onSetup);
    _watched?.removeListener(_precacheCover);
    _messages?.cancel();
    _libraryMessages?.cancel();
    _notices?.cancel();
    _sheet.dispose();
    _searchFocus.dispose();
    _libraryRequests.dispose();
    _shrink.dispose();
    _drop.dispose();
    _folded.dispose();
    super.dispose();
  }

  /// Fetches the current song's cover in the size the full player shows it, ahead of time, so
  /// opening the player shows the picture at once instead of a placeholder.
  void _precacheCover() {
    final url = _watched?.snapshot.current?.thumb;
    if (url == null || url == _precachedCover || !mounted) return;
    _precachedCover = url;
    precacheImage(
      CachedCover(sharpThumbnail(url)),
      context,
      // No enlarged picture for this one: the player will fall back to the original
      onError: (_, _) =>
          precacheImage(CachedCover(url), context, onError: (_, _) {}),
    );
  }

  /// A setup link arrived, from the camera of this phone or from a message: the server and key of another phone.
  Future<void> _onSetup() async {
    final room = AppScope.roomOf(context);
    final link = room.setup.value;
    if (link == null || !mounted) return;
    room.setup.value = null;
    await askToUseSetup(context, room, link);
  }

  /// An invitation link arrived. Outside a room it opens the sheet with the code filled in; in a room
  /// it switches only if it is another room and the user agrees.
  Future<void> _onInvite() async {
    final room = AppScope.roomOf(context);
    final code = room.invite.value;
    if (code == null || !mounted) return;
    room.invite.value = null;
    if (code == room.snapshot.room) return;
    if (!room.snapshot.inRoom) return showRoomSheet(context, invitedCode: code);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(S.switchRoom),
        content: Text(S.inviteSwitch(code)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(S.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(S.join),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      room.join(code, room.snapshot.me?.name ?? room.profile.name ?? '');
    }
  }

  void _select(int tab) {
    _fold(false);
    if (tab == _tab) {
      // The tab that is open is touched again: back to its first page
      _current?.popUntil((route) => route.isFirst);
      return;
    }
    HapticFeedback.selectionClick();
    setState(() {
      _tab = tab;
      if (tab != 1) _browsing = tab;
    });
  }

  /// Opens Search with the cursor in its field.
  void _search() {
    _select(1);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _searchFocus.requestFocus(),
    );
  }

  /// Opens a list of the library from the sidebar: one of [LibraryRequests]'s.
  void _openLibrary(int list) {
    _select(2);
    _current?.popUntil((route) => route.isFirst);
    _libraryRequests.value = list;
  }

  /// Keys of a keyboard, for DeX and a computer: Space plays or pauses, Shift with an arrow goes back or on ten
  /// seconds, Ctrl with an arrow skips, `/` or Ctrl+F searches, Escape closes the player. Plain arrows are left to move
  /// between the buttons, as a TV remote does.
  bool _onKey(KeyEvent event) {
    if (event is KeyUpEvent || !mounted) return false;
    // What is typed into a field is the field's, and a dialog or a sheet over the screen has its own keys
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null &&
        focused.findAncestorWidgetOfExactType<EditableText>() != null) {
      return false;
    }
    if (Navigator.of(context, rootNavigator: true).canPop()) return false;
    final room = AppScope.roomOf(context);
    final keys = HardwareKeyboard.instance;
    final ctrl = keys.isControlPressed || keys.isMetaPressed;
    final playing = room.snapshot.current != null;
    final once = event is KeyDownEvent;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.space when once && playing:
        room.togglePlay();
      case LogicalKeyboardKey.arrowRight when ctrl && once && playing:
        room.next();
      case LogicalKeyboardKey.arrowLeft when ctrl && once && playing:
        room.prev();
      case LogicalKeyboardKey.arrowRight when keys.isShiftPressed && playing:
        room.seek(
          (room.positionMs() + 10000).clamp(0, room.durationMs()).toInt(),
        );
      case LogicalKeyboardKey.arrowLeft when keys.isShiftPressed && playing:
        room.seek(
          (room.positionMs() - 10000).clamp(0, room.durationMs()).toInt(),
        );
      case LogicalKeyboardKey.slash when once:
        _search();
      case LogicalKeyboardKey.keyF when ctrl && once:
        _search();
      case LogicalKeyboardKey.escape when once && _sheet.isOpen:
        _sheet.close();
      default:
        return false;
    }
    return true;
  }

  void _fold(bool fold) {
    if (fold == _isFolded) return;
    _isFolded = fold;
    _folded.animateTo(fold ? 1 : 0);
  }

  /// Scrolling a page down folds the bars away; scrolling back up, however little, brings them back.
  bool _onScroll(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    // Only the phone's bars fold: beside a rail or a sidebar there is room for the player
    if (HomeShell.layoutOf(context) != ShellLayout.bars) return false;
    switch (notification) {
      case ScrollStartNotification(:final dragDetails):
        // Only a finger's scroll counts, with the glide after it, not a page moving by itself
        _touched = dragDetails != null;
        _travel = 0;
      case ScrollEndNotification():
        _touched = false;
      case ScrollUpdateNotification(:final scrollDelta?, :final metrics)
          when _touched && !metrics.outOfRange:
        // Past either end the page only bounces back, which says nothing of where the person is going
        if (scrollDelta.sign != _travel.sign) _travel = 0;
        _travel += scrollDelta;
        if (_travel > 24) _fold(true);
        if (_travel < -8) _fold(false);
      default:
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.roomOf(context);
    final layout = HomeShell.layoutOf(context);
    final pages = NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: IndexedStack(
        index: _tab,
        // A tab that is not showing keeps its state but not its animations
        children: [
          for (final (i, page) in [
            const HomePage(),
            SearchPage(focusNode: _searchFocus),
            LibraryPage(requests: _libraryRequests),
            RoomPage(onAddSongs: () => _select(1)),
          ].indexed)
            TickerMode(
              enabled: i == _tab,
              child: Navigator(
                key: _navigators[i],
                observers: [_watchers[i]],
                onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (_) => PageWidth(child: page),
                ),
              ),
            ),
        ],
      ),
    );
    final home = Scaffold(
      extendBody: true,
      // Beside a notch, when the phone is on its side
      body: SafeArea(
        top: false,
        bottom: false,
        child: layout == ShellLayout.bars
            ? pages
            : _Side(
                layout: layout,
                controller: controller,
                index: _tab,
                onSelect: _select,
                onSearch: _search,
                onLibrary: _openLibrary,
                child: pages,
              ),
      ),
      bottomNavigationBar: layout == ShellLayout.bars
          ? _Bars(
              controller: controller,
              shrink: _shrink,
              drop: _drop,
              index: _tab,
              browsing: _browsing,
              onSelect: _select,
              onUnfold: () => _fold(false),
            )
          : null,
    );
    return PlayerSheetScope(
      controller: _sheet,
      // Back closes an open player first, then goes back a page of the tab; only then does it leave the screen
      child: ListenableBuilder(
        listenable: Listenable.merge([_sheet, _stack]),
        builder: (context, stack) => PopScope(
          canPop: !_sheet.isOpen && !(_current?.canPop() ?? false),
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (_sheet.isOpen) {
              _sheet.close();
            } else {
              _current?.maybePop();
            }
          },
          child: stack!,
        ),
        // Around the sheet as well, for the picture of the mini player it draws while it opens
        child: BackdropGroup(
          backdropKey: _backdrop,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Nothing to draw behind a fully open player
              AnimatedBuilder(
                animation: _sheet.position,
                child: home,
                // Hidden behind the full player: not drawn, and its small animations stand still too
                builder: (context, home) => TickerMode(
                  enabled: _sheet.position.value != 1,
                  child: Offstage(
                    offstage: _sheet.position.value == 1,
                    child: home,
                  ),
                ),
              ),
              PlayerSheetLayer(controller: _sheet, folded: _drop),
            ],
          ),
        ),
      ),
    );
  }
}

/// The pages of a large window beside a rail or a sidebar, with the player floating over their bottom.
class _Side extends StatelessWidget {
  const _Side({
    required this.layout,
    required this.controller,
    required this.index,
    required this.onSelect,
    required this.onSearch,
    required this.onLibrary,
    required this.child,
  });

  final ShellLayout layout;
  final RoomController controller;
  final int index;
  final ValueChanged<int> onSelect;
  final VoidCallback onSearch;
  final ValueChanged<int> onLibrary;
  final Widget child;

  static const _gap = 12.0;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.viewPaddingOf(context);
    final rail = layout == ShellLayout.rail;
    // Where the pages start: right of the rail or the sidebar, with a gap on either side of it
    final inset = rail ? 16 + _Rail.width + 16 : _gap + _Sidebar.width + _gap;
    final bottom = padding.bottom + (rail ? 16 : _gap);
    return LayoutBuilder(
      builder: (context, box) {
        final content = box.maxWidth - inset;
        final mini = (content - 32).clamp(0.0, 520.0);
        return Stack(
          children: [
            // The pages take the whole window, and keep clear of the rail or the sidebar themselves
            Positioned.fill(
              child: SideInset(left: inset, child: child),
            ),
            if (rail)
              Positioned(
                left: 16,
                top: padding.top + 16,
                bottom: bottom,
                width: _Rail.width,
                child: _Rail(index: index, onSelect: onSelect),
              )
            else
              Positioned(
                left: _gap,
                top: padding.top + _gap,
                bottom: bottom,
                width: _Sidebar.width,
                child: _Sidebar(
                  index: index,
                  onSelect: onSelect,
                  onSearch: onSearch,
                  onLibrary: onLibrary,
                ),
              ),
            // The mini player floats in the middle of the pages, the player bar runs along them
            Positioned(
              left: rail ? inset + (content - mini) / 2 : inset,
              right: rail ? null : _gap,
              width: rail ? mini : null,
              bottom: bottom,
              child: rail
                  ? MiniPlayer(controller: controller)
                  : PlayerBar(controller: controller),
            ),
          ],
        );
      },
    );
  }
}

/// The tabs in a column of glass on the left of a tablet held upright, with Settings at the bottom.
class _Rail extends StatelessWidget {
  const _Rail({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  static const width = 80.0;

  /// A getter, not a constant: the names follow the language.
  static List<(int, IconData, String)> get _items => [
    (0, Icons.home_rounded, S.tabHome),
    (1, Icons.search_rounded, S.tabSearch),
    (2, Icons.library_music_rounded, S.tabLibrary),
    (3, Icons.graphic_eq_rounded, S.tabListen),
  ];

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Column(
      children: [
        Glass(
          borderRadius: BorderRadius.circular(width / 2),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                for (final (tab, icon, label) in _items)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Material(
                      color: tab == index ? p.veilStrong : Colors.transparent,
                      borderRadius: BorderRadius.circular(20),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () => onSelect(tab),
                        child: SizedBox.square(
                          dimension: 64,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                icon,
                                size: 26,
                                color: tab == index
                                    ? p.primary
                                    : p.textSecondary,
                              ),
                              const SizedBox(height: 3),
                              Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.fade,
                                softWrap: false,
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(
                                      color: tab == index
                                          ? p.primary
                                          : p.textSecondary,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const Spacer(),
        SizedBox.square(
          dimension: 56,
          child: Glass(
            borderRadius: BorderRadius.circular(28),
            child: IconButton(
              onPressed: () => openSettings(context),
              tooltip: S.settingsTitle,
              icon: Icon(Icons.settings_outlined, color: p.text),
            ),
          ),
        ),
      ],
    );
  }
}

/// The sidebar of a wide screen, in the manner of Apple Music and Spotify on a computer: Search, the tabs, the
/// playlists of the library, and Settings at the bottom.
class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.index,
    required this.onSelect,
    required this.onSearch,
    required this.onLibrary,
  });

  final int index;
  final ValueChanged<int> onSelect;
  final VoidCallback onSearch;
  final ValueChanged<int> onLibrary;

  static const width = 256.0;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final library = AppScope.of(context).library;
    return Glass(
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 18, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 14),
              child: Text(S.appName, style: theme.headlineSmall),
            ),
            // Looks like a field, and opens Search with the cursor in its own
            Material(
              color: index == 1 ? p.veilStrong : p.veil,
              shape: const StadiumBorder(),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: onSearch,
                child: SizedBox(
                  height: 40,
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      Icon(
                        Icons.search_rounded,
                        size: 20,
                        color: index == 1 ? p.primary : p.textSecondary,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          S.tabSearch,
                          style: theme.bodyMedium?.copyWith(
                            color: index == 1 ? p.primary : p.textSecondary,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        decoration: BoxDecoration(
                          border: Border.all(color: p.outline),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('/', style: theme.labelSmall),
                      ),
                      const SizedBox(width: 12),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            _SideRow(
              icon: Icons.home_rounded,
              label: S.tabHome,
              selected: index == 0,
              onTap: () => onSelect(0),
            ),
            _SideRow(
              icon: Icons.library_music_rounded,
              label: S.tabLibrary,
              selected: index == 2,
              onTap: () => onSelect(2),
            ),
            _SideRow(
              icon: Icons.graphic_eq_rounded,
              label: S.tabListen,
              selected: index == 3,
              onTap: () => onSelect(3),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 20, 10, 6),
              child: Text(
                S.playlists.toUpperCase(),
                style: theme.labelSmall?.copyWith(letterSpacing: 0.8),
              ),
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: library,
                builder: (context, _) => ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    _SideRow(
                      leading: _SideTile(
                        icon: Icons.favorite_rounded,
                        color: p.primary,
                        on: p.onPrimary,
                      ),
                      label: S.likedSongs,
                      onTap: () => onLibrary(LibraryRequests.liked),
                    ),
                    _SideRow(
                      leading: _SideTile(
                        icon: Icons.download_done_rounded,
                        color: p.veilStrong,
                        on: p.text,
                      ),
                      label: S.downloadedSongs,
                      onTap: () => onLibrary(LibraryRequests.downloaded),
                    ),
                    for (final playlist in library.playlists)
                      _SideRow(
                        leading: Artwork(
                          url: playlist.thumb,
                          size: 32,
                          radius: 7,
                        ),
                        label: playlist.name,
                        onTap: () => onLibrary(playlist.id),
                      ),
                  ],
                ),
              ),
            ),
            _SideRow(
              icon: Icons.settings_outlined,
              label: S.settingsTitle,
              onTap: () => openSettings(context),
            ),
          ],
        ),
      ),
    );
  }
}

/// A line of the sidebar: a tab, a playlist, Settings.
class _SideRow extends StatelessWidget {
  const _SideRow({
    required this.label,
    required this.onTap,
    this.icon,
    this.leading,
    this.selected = false,
  });

  final String label;
  final VoidCallback onTap;
  final IconData? icon;

  /// In place of the icon, a playlist's cover.
  final Widget? leading;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = selected ? p.primary : p.text;
    return Material(
      color: selected ? p.veilStrong : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: SizedBox(
          height: leading == null ? 42 : 46,
          child: Row(
            children: [
              SizedBox(width: leading == null ? 12 : 6),
              leading ??
                  Icon(
                    icon,
                    size: 22,
                    color: selected ? p.primary : p.textSecondary,
                  ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: leading == null
                      ? Theme.of(context).textTheme.titleSmall
                            ?.copyWith(color: color)
                      : Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The small square in front of the liked and the downloaded songs in the sidebar.
class _SideTile extends StatelessWidget {
  const _SideTile({required this.icon, required this.color, required this.on});

  final IconData icon;
  final Color color;
  final Color on;

  @override
  Widget build(BuildContext context) => Container(
    width: 32,
    height: 32,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(7),
    ),
    child: Icon(icon, size: 18, color: on),
  );
}

/// The mini player, the tabs and Search, in the manner of Apple Music, open or folded away. Open,
/// the mini player floats above a capsule of tabs, with Search apart as a round button. Folded, the capsule shrinks to
/// the tab that is open and the mini player moves down between it and Search.
///
/// The bars take the same height either way, so that folding them moves nothing on the page; only they themselves
/// take touches, not the room around them.
class _Bars extends StatelessWidget {
  const _Bars({
    required this.controller,
    required this.shrink,
    required this.drop,
    required this.index,
    required this.browsing,
    required this.onSelect,
    required this.onUnfold,
  });

  final RoomController controller;

  /// How far the capsule of tabs has shrunk, and the mini player come down, 0 to 1.
  final Animation<double> shrink;
  final Animation<double> drop;

  /// The tab that is open, and the last of the capsule's that was.
  final int index;
  final int browsing;
  final ValueChanged<int> onSelect;
  final VoidCallback onUnfold;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final wide = HomeShell.isWide(context);
    final tabs = HomeShell.tabHeightOf(context);
    final mini = MiniPlayer.heightOf(context);
    // Between the mini player and the tabs, between the tabs and Search, and to the sides of the screen
    final gap = wide ? 4.0 : 10.0;
    final apart = wide ? 8.0 : 10.0;
    const side = 12.0;
    return ListenableBuilder(
      listenable: Listenable.merge([controller, shrink, drop]),
      builder: (context, _) {
        final shrink = this.shrink.value;
        final drop = this.drop.value;
        // Where the row of tabs starts: below the mini player, when there is a song
        final row = controller.snapshot.current == null ? 0.0 : mini + gap;
        return Stack(
          children: [
            // What scrolls under the bars fades out at the very bottom, so it does not run into the system's own
            // bar below them; only there, so the glass shows the page and not a band of plain colour
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: MediaQuery.viewPaddingOf(context).bottom + 24,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        p.base.withValues(alpha: 0),
                        p.base.withValues(alpha: 0.7),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // Clear of the system's own bar
            SafeArea(
              top: false,
              minimum: const EdgeInsets.only(bottom: HomeShell._barsBottom),
              child: SizedBox(
                height: row + tabs,
                child: LayoutBuilder(
                  builder: (context, box) {
                    final open = box.maxWidth - 2 * side - apart - tabs;
                    // The mini player's sides, folded: beside the tab on the left and Search on the right
                    final inset = side + tabs + apart;
                    return Stack(
                      // A song that ends draws its capsule above the bars as it goes
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          left: side + (inset - side) * drop,
                          right: side + (inset - side) * drop,
                          top: (row - gap - mini) * (1 - drop) + row * drop,
                          child: MiniPlayer(
                            controller: controller,
                            folded: drop,
                          ),
                        ),
                        Positioned(
                          left: side,
                          top: row,
                          width: open + (tabs - open) * shrink,
                          height: tabs,
                          child: _Tabs(
                            index: index,
                            browsing: browsing,
                            folded: shrink,
                            openWidth: open,
                            onSelect: onSelect,
                            onUnfold: onUnfold,
                          ),
                        ),
                        Positioned(
                          right: side,
                          top: row,
                          width: tabs,
                          height: tabs,
                          child: Glass(
                            borderRadius: BorderRadius.circular(tabs / 2),
                            child: IconButton(
                              onPressed: () => onSelect(1),
                              tooltip: S.tabSearch,
                              icon: Icon(
                                Icons.search_rounded,
                                size: wide ? 22 : 26,
                                color: index == 1 ? p.primary : p.text,
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The capsule of tabs, with a soft lens under the tab that is open. Folded, it is a round button with only the tab
/// that is open (or was, while Search is), which opens the bars again.
class _Tabs extends StatelessWidget {
  const _Tabs({
    required this.index,
    required this.browsing,
    required this.folded,
    required this.openWidth,
    required this.onSelect,
    required this.onUnfold,
  });

  final int index;
  final int browsing;
  final double folded;

  /// The capsule's width when open, which the tabs keep while it shrinks over them.
  final double openWidth;
  final ValueChanged<int> onSelect;
  final VoidCallback onUnfold;

  /// The tabs of the capsule, each with its place among the tabs; Search, the second, is the round button. A getter,
  /// not a constant: the names follow the language.
  static List<(int, IconData, String)> get _items => [
    (0, Icons.home_rounded, S.tabHome),
    (2, Icons.library_music_rounded, S.tabLibrary),
    (3, Icons.graphic_eq_rounded, S.tabListen),
  ];

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final wide = HomeShell.isWide(context);
    final round = BorderRadius.circular(HomeShell.tabHeightOf(context) / 2);
    final items = _items;
    final slot = items.indexWhere((item) => item.$1 == browsing);
    return Glass(
      borderRadius: round,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // The tabs are gone half way, and the one that stays comes in once the capsule is nearly round: never both
          if (folded < 0.5)
            Opacity(
              opacity: 1 - 2 * folded,
              child: IgnorePointer(
                ignoring: folded > 0,
                child: OverflowBox(
                  alignment: Alignment.centerLeft,
                  minWidth: openWidth,
                  maxWidth: openWidth,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Slides to the tab that is opened; gone while Search is open
                      AnimatedOpacity(
                        opacity: index == 1 ? 0 : 1,
                        duration: const Duration(milliseconds: 200),
                        child: AnimatedAlign(
                          alignment: Alignment(
                            2 * slot / (items.length - 1) - 1,
                            0,
                          ),
                          duration: const Duration(milliseconds: 320),
                          curve: Curves.easeOutCubic,
                          child: FractionallySizedBox(
                            widthFactor: 1 / items.length,
                            heightFactor: 1,
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: p.text.withValues(alpha: 0.09),
                                  borderRadius: round,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          for (final (tab, icon, label) in items)
                            Expanded(
                              child: InkResponse(
                                onTap: () => onSelect(tab),
                                radius: 40,
                                child: TweenAnimationBuilder<Color?>(
                                  tween: ColorTween(
                                    end: tab == index
                                        ? p.primary
                                        : p.textSecondary,
                                  ),
                                  duration: const Duration(milliseconds: 200),
                                  builder: (context, color, _) {
                                    final glyph = Icon(
                                      icon,
                                      color: color,
                                      size: wide ? 22 : 26,
                                    );
                                    final name = Text(
                                      label,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(
                                            color: color,
                                            fontSize: 10.5,
                                          ),
                                    );
                                    // On its side the label goes beside the icon: there is no height to stack them
                                    return wide
                                        ? Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              glyph,
                                              const SizedBox(width: 6),
                                              name,
                                            ],
                                          )
                                        : Column(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              glyph,
                                              const SizedBox(height: 2),
                                              name,
                                            ],
                                          );
                                  },
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (folded > 0.6)
            Opacity(
              opacity: (folded - 0.6) / 0.4,
              child: IgnorePointer(
                ignoring: folded < 1,
                child: IconButton(
                  onPressed: onUnfold,
                  tooltip: items[slot].$3,
                  icon: Icon(
                    items[slot].$2,
                    size: wide ? 22 : 26,
                    color: index == 1 ? p.text : p.primary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Tells when a page is opened or closed in a tab.
class _StackWatcher extends NavigatorObserver {
  _StackWatcher(this.changed);

  final VoidCallback changed;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      changed();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => changed();

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      changed();

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      changed();
}

/// Where a page opened from anywhere goes: into the tab that is showing, with the full player put away if it is open.
/// Sheets and the full player sit above the tabs, so their own navigator is the one for the whole screen, which is not
/// where such a page belongs.
abstract final class TabNavigation {
  static NavigatorState? Function()? _active;
  static VoidCallback? _closePlayer;

  static Future<T?> push<T>(BuildContext context, Route<T> route) {
    _closePlayer?.call();
    return (_active?.call() ?? Navigator.of(context)).push(route);
  }
}
