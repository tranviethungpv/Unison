import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../data/library_controller.dart';
import '../data/models.dart';
import '../data/room_controller.dart';
import '../data/setup_link.dart';
import '../data/update_controller.dart';
import '../data/update_info.dart';
import '../format.dart';
import '../strings.dart';
import '../theme/theme.dart';
import 'home_shell.dart';
import 'scope.dart';
import 'setup_dialog.dart';
import 'profile_sheet.dart';
import 'widgets/ambient_backdrop.dart';
import 'widgets/avatars.dart';
import 'widgets/page_width.dart';
import 'widgets/play_row.dart';
import 'widgets/scroll_edge.dart';
import 'widgets/text_dialog.dart';

/// Opens the settings in the tab that is showing (beside the sidebar of a wide screen), with a way back.
Future<void> openSettings(BuildContext context) => TabNavigation.push(
  context,
  MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
);

/// The settings as a page of their own. A page on its own paints its own backdrop, the same as the home screen's,
/// so that the page it covers does not show through.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) => AmbientBackdrop(
    child: Padding(
      padding: EdgeInsets.only(left: SideInset.of(context)),
      child: const Scaffold(body: SettingsPage()),
    ),
  );
}

/// A topic of the settings: its title, and what is on its page.
typedef _Topic = (
  String Function() title,
  List<Widget> Function(BuildContext context, AppModel model) children,
);

/// A short list of topics; each opens a page of its own, so no page grows long. On a wide screen the topic is shown
/// beside the list instead, as the settings of a tablet do.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// Whether the topics are shown beside the list, as of the last layout.
  bool _wide = false;

  /// The topic beside the list on a wide screen.
  _Topic _topic = (() => S.appearance, _appearance);

  /// Whether [children] is the topic shown beside the list.
  bool _shows(List<Widget> Function(BuildContext, AppModel) children) =>
      _wide && _topic.$2 == children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      _wide = box.maxWidth >= 760;
      final list = _SettingsList(
        title: S.settingsTitle,
        children: _topics(context),
      );
      if (!_wide) return list;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 380, child: list),
          Expanded(
            child: _SettingsList(
              key: ValueKey(_topic.$2),
              title: _topic.$1(),
              back: false,
              children: _topic.$2(context, AppScope.of(context)),
            ),
          ),
        ],
      );
    },
  );

  List<Widget> _topics(BuildContext context) {
    final model = AppScope.of(context);
    return [
      _ProfileCard(room: model.room),
      _Group(
        children: [
          ListenableBuilder(
            listenable: model.settings,
            builder: (context, _) => _NavRow(
              selected: _shows(_appearance),
              key: const ValueKey('settings-appearance'),
              icon: Icons.palette_outlined,
              label: S.appearance,
              value: switch (model.settings.themeMode) {
                ThemeMode.system => S.themeSystem,
                ThemeMode.light => S.themeLight,
                ThemeMode.dark => S.themeDark,
              },
              onTap: () => _open(context, () => S.appearance, _appearance),
            ),
          ),
          ListenableBuilder(
            listenable: model.settings,
            builder: (context, _) => _NavRow(
              selected: _shows(_language),
              key: const ValueKey('settings-language'),
              icon: Icons.translate_rounded,
              label: S.languageLabel,
              value: model.settings.language == null
                  ? S.languageSystem
                  : S.languageName(model.settings.language!),
              onTap: () => _open(context, () => S.languageLabel, _language),
            ),
          ),
          _NavRow(
            selected: _shows(_playback),
            key: const ValueKey('settings-playback'),
            icon: Icons.play_circle_outline_rounded,
            label: S.playback,
            onTap: () => _open(context, () => S.playback, _playback),
          ),
          _NavRow(
            selected: _shows(_suggestions),
            key: const ValueKey('settings-suggestions'),
            icon: Icons.auto_awesome_outlined,
            label: S.suggestionsTitle,
            onTap: () => _open(context, () => S.suggestionsTitle, _suggestions),
          ),
          ListenableBuilder(
            listenable: model.room,
            builder: (context, _) {
              final snapshot = model.room.snapshot;
              if (!snapshot.inRoom) return const SizedBox.shrink();
              return _NavRow(
                selected: _shows(_room),
                key: const ValueKey('settings-room'),
                icon: Icons.groups_outlined,
                label: S.room,
                value: snapshot.room,
                onTap: () => _open(context, () => S.room, _room),
              );
            },
          ),
          _NavRow(
            selected: _shows(_storage),
            key: const ValueKey('settings-storage'),
            icon: Icons.download_for_offline_outlined,
            label: S.storage,
            onTap: () => _open(context, () => S.storage, _storage),
          ),
          _NavRow(
            selected: _shows(_backup),
            key: const ValueKey('settings-backup'),
            icon: Icons.backup_outlined,
            label: S.backup,
            onTap: () => _open(context, () => S.backup, _backup),
          ),
          // The server is set by the person on iOS; on Android it is built into the app
          if (Platform.isIOS)
            _NavRow(
              selected: _shows(_server),
              key: const ValueKey('settings-server'),
              icon: Icons.dns_outlined,
              label: S.serverSection,
              onTap: () => _open(context, () => S.serverSection, _server),
            ),
          // The phone that has the server built in can set another one up
          if (Platform.isAndroid)
            _NavRow(
              key: const ValueKey('settings-setup-another'),
              icon: Icons.qr_code_2_rounded,
              label: S.setupAnother,
              onTap: () => showSetupLinkDialog(context, model.room),
            ),
          // iOS installs updates by itself: they come from SideStore, not from the app
          if (!Platform.isIOS)
            ListenableBuilder(
              listenable: model.update,
              builder: (context, _) {
                final info = model.update.info;
                return _NavRow(
                  selected: _shows(_updates),
                  key: const ValueKey('settings-updates'),
                  icon: Icons.system_update_outlined,
                  label: S.updates,
                  value: info.hasUpdate ? info.version : info.installed,
                  onTap: () => _open(context, () => S.updates, _updates),
                );
              },
            ),
        ],
      ),
      _Group(
        footer: S.diagnosticsHelp,
        children: [
          _Row(
            label: S.copyLog,
            onTap: () async {
              final lines = await model.room.log();
              await Clipboard.setData(ClipboardData(text: lines.join('\n')));
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(S.logCopied)));
              }
            },
          ),
        ],
      ),
      const _VersionLabel(),
    ];
  }

  /// [title] is a function so that the page can change its words when the language does.
  void _open(
    BuildContext context,
    String Function() title,
    List<Widget> Function(BuildContext context, AppModel model) children,
  ) {
    if (_wide) {
      setState(() => _topic = (title, children));
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => _SubPage(
          title: title(),
          children: children(context, AppScope.of(context)),
        ),
      ),
    );
  }

  static List<Widget> _appearance(BuildContext context, AppModel model) => [
    _Group(
      children: [
        ListenableBuilder(
          listenable: model.settings,
          builder: (context, _) => Column(
            children: [
              for (final (mode, label) in [
                (ThemeMode.system, S.themeSystem),
                (ThemeMode.light, S.themeLight),
                (ThemeMode.dark, S.themeDark),
              ])
                _Row(
                  key: ValueKey('theme-${mode.name}'),
                  label: label,
                  trailing: model.settings.themeMode == mode
                      ? Icon(
                          Icons.check_rounded,
                          color: context.palette.primary,
                        )
                      : null,
                  onTap: () => model.settings.themeMode = mode,
                ),
            ],
          ),
        ),
      ],
    ),
  ];

  static List<Widget> _language(BuildContext context, AppModel model) => [
    _Group(
      footer: S.languageHelp,
      children: [
        ListenableBuilder(
          listenable: model.settings,
          builder: (context, _) => Column(
            children: [
              for (final code in [null, ...S.languages])
                _Row(
                  key: ValueKey('language-${code ?? 'system'}'),
                  label: code == null ? S.languageSystem : S.languageName(code),
                  trailing: model.settings.language == code
                      ? Icon(
                          Icons.check_rounded,
                          color: context.palette.primary,
                        )
                      : null,
                  onTap: () => model.settings.language = code,
                ),
            ],
          ),
        ),
      ],
    ),
  ];

  /// What was blocked from the suggestions, to be let back one by one.
  static List<Widget> _suggestions(BuildContext context, AppModel model) => [
    _Group(
      title: S.blockedHeading,
      footer: S.blockedHelp,
      children: [
        ListenableBuilder(
          listenable: model.library,
          builder: (context, _) {
            final blocked = model.library.blocked;
            if (blocked.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  S.blockedNone,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: context.palette.textSecondary),
                ),
              );
            }
            return Column(
              children: [
                for (final item in blocked)
                  _Row(
                    key: ValueKey('blocked-${item.kind}-${item.key}'),
                    label: item.label,
                    leading: Icon(
                      item.isArtist
                          ? Icons.person_off_outlined
                          : Icons.music_off_outlined,
                      color: context.palette.primary,
                    ),
                    trailing: Icon(
                      Icons.close_rounded,
                      color: context.palette.textTertiary,
                    ),
                    onTap: () => model.library.unblock(item),
                  ),
              ],
            );
          },
        ),
      ],
    ),
  ];

  static List<Widget> _playback(BuildContext context, AppModel model) => [
    _Group(
      title: S.autoplay,
      footer: S.autoplayHelp,
      children: [
        ListenableBuilder(
          listenable: model.room,
          builder: (context, _) => Material(
            type: MaterialType.transparency,
            child: SwitchListTile(
              title: Text(S.autoplay),
              value: model.room.autoplay,
              onChanged: model.room.setAutoplay,
            ),
          ),
        ),
      ],
    ),
    _Group(
      title: S.videoSection,
      footer: S.videoQualityHelp,
      children: [
        ListenableBuilder(
          listenable: model.room,
          builder: (context, _) => Padding(
            padding: const EdgeInsets.all(12),
            child: SegmentedButton<int>(
              showSelectedIcon: false,
              expandedInsets: EdgeInsets.zero,
              style: SegmentedButton.styleFrom(
                backgroundColor: Colors.transparent,
                selectedBackgroundColor: context.palette.primaryContainer,
                selectedForegroundColor: context.palette.onPrimaryContainer,
                foregroundColor: context.palette.textSecondary,
                side: BorderSide(color: context.palette.outline),
              ),
              segments: [
                for (final h in const [360, 480, 720, 1080])
                  ButtonSegment(value: h, label: Text('${h}p')),
              ],
              selected: {model.room.snapshot.videoHeight},
              onSelectionChanged: (s) => model.room.setVideoQuality(s.first),
            ),
          ),
        ),
      ],
    ),
    _Group(
      title: S.sync,
      footer: S.latencyTrimHelp,
      children: [_TrimRow(controller: model.room)],
    ),
  ];

  static List<Widget> _storage(BuildContext context, AppModel model) => [
    _StorageGroup(library: model.library),
  ];

  static List<Widget> _backup(BuildContext context, AppModel model) => [
    _BackupGroup(library: model.library),
  ];

  static List<Widget> _server(BuildContext context, AppModel model) => [
    _ServerGroup(room: model.room),
  ];

  static List<Widget> _updates(BuildContext context, AppModel model) => [
    _UpdateGroup(update: model.update),
  ];

  static List<Widget> _room(BuildContext context, AppModel model) => [
    _RoomGroup(room: model.room),
  ];
}

/// The version of the app in small print at the foot of the list, the same on both platforms.
class _VersionLabel extends StatefulWidget {
  const _VersionLabel();

  @override
  State<_VersionLabel> createState() => _VersionLabelState();
}

class _VersionLabelState extends State<_VersionLabel> {
  late final Future<PackageInfo> _info = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) => FutureBuilder<PackageInfo>(
    future: _info,
    builder: (context, async) {
      final info = async.data;
      if (info == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          'Sapoche ${info.version} (${info.buildNumber})',
          key: const ValueKey('settings-version'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: context.palette.textTertiary),
        ),
      );
    },
  );
}

/// Where the room server is and the key it asks for, for the phones that are not built with them.
class _ServerGroup extends StatelessWidget {
  const _ServerGroup({required this.room});

  final RoomController room;

  Future<void> _edit(BuildContext context, {required bool key}) async {
    final value = await showTextDialog(
      context,
      title: key ? S.serverKey : S.serverAddress,
      hint: key ? S.serverKey : 'https://…',
      initial: key ? '' : room.profile.server,
      maxLength: 200,
      capitalization: TextCapitalization.none,
    );
    if (value == null || (key && value.isEmpty)) return;
    await (key ? room.configure(key: value) : room.configure(server: value));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: room,
      builder: (context, _) => _Group(
        footer: S.serverHelp,
        children: [
          _Row(
            key: const ValueKey('server-address'),
            label: S.serverAddress,
            value: room.profile.server,
            trailing: Icon(
              Icons.edit_outlined,
              size: 18,
              color: context.palette.textSecondary,
            ),
            onTap: () => _edit(context, key: false),
          ),
          _Row(
            key: const ValueKey('server-key'),
            label: S.serverKey,
            value: room.profile.hasKey ? S.serverKeySet : S.serverKeyNotSet,
            trailing: Icon(
              Icons.edit_outlined,
              size: 18,
              color: context.palette.textSecondary,
            ),
            onTap: () => _edit(context, key: true),
          ),
          _Row(
            key: const ValueKey('server-paste'),
            label: S.setupPaste,
            onTap: () => _paste(context),
          ),
        ],
      ),
    );
  }

  /// Takes the server and key from a setup link that was copied, e.g. one sent from the other phone.
  Future<void> _paste(BuildContext context) async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    final link = SetupLink.parse(text);
    if (!context.mounted) return;
    if (link == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(S.setupBad)));
      return;
    }
    await askToUseSetup(context, room, link);
  }
}

/// The version in use and, when there is a newer one, getting it and installing it.
class _UpdateGroup extends StatelessWidget {
  const _UpdateGroup({required this.update});

  final UpdateController update;

  /// Fetches the version on offer, asking first when it would use mobile data.
  Future<void> _download(BuildContext context) async {
    if (await update.download()) return;
    if (!context.mounted) return;
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(S.useMobileData),
        content: Text(S.useMobileDataBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(S.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(S.updateDownload),
          ),
        ],
      ),
    );
    if (agreed == true) await update.download(allowMetered: true);
  }

  /// Installing closes the app, so the person is told before it happens.
  Future<void> _install(BuildContext context) async {
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(S.updateRestartTitle),
        content: Text(S.updateRestartBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(S.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(S.updateInstall),
          ),
        ],
      ),
    );
    if (agreed != true) return;
    if (await update.install() || !context.mounted) return;
    // Android has not yet allowed this app to install: say so, and take the person to the page for it
    final open = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(S.updatePermissionTitle),
        content: Text(S.updatePermissionBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(S.cancel),
          ),
          TextButton(
            key: const ValueKey('update-open-settings'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(S.updateOpenSettings),
          ),
        ],
      ),
    );
    if (open == true) await update.allowInstalls();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: update,
      builder: (context, _) {
        final info = update.info;
        final version = info.version ?? '';
        final busy =
            info.phase == UpdatePhase.checking ||
            info.phase == UpdatePhase.installing;
        final (
          String message,
          String? action,
          VoidCallback? onAction,
        ) = switch (info.phase) {
          UpdatePhase.available => (
            S.updateAvailable(version),
            S.updateDownload,
            () => _download(context),
          ),
          UpdatePhase.downloading => (S.updateDownloading, null, null),
          UpdatePhase.ready => (
            S.updateReady(version),
            S.updateInstall,
            () => _install(context),
          ),
          UpdatePhase.needsPermission => (
            S.updatePermission,
            S.updateOpenSettings,
            update.allowInstalls,
          ),
          UpdatePhase.checking => (S.updateChecking, null, null),
          UpdatePhase.installing => (S.updateInstalling, null, null),
          UpdatePhase.failed => (
            S.updateError(info.error),
            info.version == null ? S.updateCheck : S.updateTryAgain,
            info.version == null ? update.check : () => _download(context),
          ),
          UpdatePhase.upToDate => (
            S.updateUpToDate,
            S.updateCheck,
            update.check,
          ),
          UpdatePhase.idle => (S.updateCheck, S.updateCheck, update.check),
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Group(
              children: [
                _Row(label: S.updateVersion, value: info.installed),
                if (info.phase != UpdatePhase.idle)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (busy) ...[
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              const SizedBox(width: 12),
                            ],
                            Expanded(
                              child: Text(message, style: theme.bodyLarge),
                            ),
                          ],
                        ),
                        if (info.phase == UpdatePhase.downloading) ...[
                          const SizedBox(height: 12),
                          LinearProgressIndicator(
                            key: const ValueKey('update-progress'),
                            value: info.progress,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${formatBytes(info.done)} / ${formatBytes(info.size)}',
                            style: theme.bodySmall,
                          ),
                        ] else if (info.size > 0 && info.hasUpdate)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              formatBytes(info.size),
                              style: theme.bodySmall,
                            ),
                          ),
                        if (info.notes != null && info.hasUpdate) ...[
                          const SizedBox(height: 12),
                          Text(
                            S.updateWhatsNew,
                            style: theme.labelLarge?.copyWith(
                              color: p.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          _ReleaseNotes(info.notes!),
                        ],
                      ],
                    ),
                  ),
                if (action != null && !busy)
                  _Row(
                    key: ValueKey('update-action'),
                    label: action,
                    onTap: onAction,
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// The notes of a release: a line that starts with "- " is a bullet, any other line is a heading.
class _ReleaseNotes extends StatelessWidget {
  const _ReleaseNotes(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final lines = text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty);
    return Column(
      key: const ValueKey('release-notes'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in lines)
          if (line.startsWith('- '))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 10, left: 2),
                    child: Text(
                      '•',
                      style: theme.bodyMedium?.copyWith(color: p.primary),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      line.substring(2).trim(),
                      style: theme.bodyMedium,
                    ),
                  ),
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 6),
              child: Text(line, style: theme.titleSmall),
            ),
      ],
    );
  }
}

/// The room this device is in: its code, who is there, the name shown, inviting and leaving.
class _RoomGroup extends StatelessWidget {
  const _RoomGroup({required this.room});

  final RoomController room;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: room,
      builder: (context, _) {
        final snapshot = room.snapshot;
        if (!snapshot.inRoom) {
          // The room was left from this page: nothing left to show
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) Navigator.of(context).maybePop();
          });
          return const SizedBox.shrink();
        }
        return _Group(
          children: [
            _Row(
              label: S.roomCode,
              value: snapshot.room ?? '',
              trailing: Icon(
                Icons.copy_rounded,
                size: 18,
                color: context.palette.textSecondary,
              ),
              onTap: () {
                Clipboard.setData(ClipboardData(text: snapshot.room ?? ''));
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(content: Text(S.codeCopied)));
              },
            ),
            _Row(label: S.tabRoom, value: S.listening(snapshot.members.length)),
            _Row(
              label: S.yourName,
              value: snapshot.me?.name ?? '',
              trailing: Icon(
                Icons.edit_outlined,
                size: 18,
                color: context.palette.textSecondary,
              ),
              onTap: () => _rename(context),
            ),
            _Row(label: S.invite, onTap: room.shareInvite),
            _Row(
              label: S.leaveRoom,
              destructive: true,
              onTap: () => _confirmLeave(context),
            ),
          ],
        );
      },
    );
  }

  Future<void> _rename(BuildContext context) async {
    final name = await showTextDialog(
      context,
      title: S.rename,
      hint: S.yourName,
      initial: room.snapshot.me?.name ?? '',
    );
    if (name != null && name.isNotEmpty) room.rename(name);
  }

  Future<void> _confirmLeave(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(S.leaveRoom),
        content: Text(S.leaveQuestion),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(S.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              S.leave,
              style: TextStyle(color: context.palette.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) room.leave();
  }
}

/// What the songs kept on the phone take, and the settings that go with them.
class _StorageGroup extends StatefulWidget {
  const _StorageGroup({required this.library});

  final LibraryController library;

  @override
  State<_StorageGroup> createState() => _StorageGroupState();
}

class _StorageGroupState extends State<_StorageGroup> {
  StorageInfo _info = const StorageInfo();

  @override
  void initState() {
    super.initState();
    widget.library.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.library.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final info = await widget.library.storage();
    if (info != null && mounted) setState(() => _info = info);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    final library = widget.library;
    return _Group(
      footer: S.cacheLimitHelp,
      children: [
        _Row(
          label: S.storageDownloads,
          value:
              '${S.songCount(_info.downloadCount)} · ${formatBytes(_info.downloadBytes)}',
        ),
        _Row(
          label: S.storagePlayed,
          value: '${formatBytes(_info.playBytes)} / ${_info.playLimitMb} MB',
          trailing: TextButton(
            onPressed: _info.playBytes == 0
                ? null
                : () async {
                    await library.clearPlayCache();
                    _load();
                  },
            child: Text(S.clearCache),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Text(S.cacheLimit, style: theme.bodyMedium),
              ),
              SegmentedButton<int>(
                showSelectedIcon: false,
                expandedInsets: EdgeInsets.zero,
                style: SegmentedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  selectedBackgroundColor: p.primaryContainer,
                  selectedForegroundColor: p.onPrimaryContainer,
                  foregroundColor: p.textSecondary,
                  side: BorderSide(color: p.outline),
                ),
                segments: [
                  for (final mb in const [128, 256, 512, 1024])
                    ButtonSegment(
                      value: mb,
                      label: Text(mb == 1024 ? '1 GB' : '$mb MB'),
                    ),
                ],
                selected: {_info.playLimitMb},
                onSelectionChanged: (s) async {
                  await library.setCacheLimit(s.first);
                  _load();
                },
              ),
            ],
          ),
        ),
        Material(
          type: MaterialType.transparency,
          child: SwitchListTile(
            title: Text(S.autoDownload),
            subtitle: Text(S.autoDownloadHelp),
            value: _info.autoDownload,
            onChanged: (on) async {
              await library.setAutoDownload(on);
              _load();
            },
          ),
        ),
      ],
    );
  }
}

/// Rounded block of related rows with a small heading, like a settings group on iOS.
/// Saves the library to a file and adds one back, for a new phone or after a reinstall.
class _BackupGroup extends StatelessWidget {
  const _BackupGroup({required this.library});

  final LibraryController library;

  void _say(BuildContext context, String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _save(BuildContext context) async {
    final saved = await library.exportBackup();
    if (saved == null || !context.mounted) return;
    _say(
      context,
      saved.isEmpty
          ? S.backupEmpty
          : S.backupSaved(saved.liked, saved.playlists, saved.listens),
    );
  }

  Future<void> _add(BuildContext context) async {
    final added = await library.importBackup();
    if (added == null || !context.mounted) return;
    _say(
      context,
      added.isEmpty
          ? S.backupNothingNew
          : S.backupAdded(added.liked, added.playlists, added.listens),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return _Group(
      footer: S.backupHelp,
      children: [
        _Row(
          label: S.backupSave,
          trailing: Icon(Icons.save_alt_rounded, color: p.textTertiary),
          onTap: () => _save(context),
        ),
        _Row(
          label: S.backupAdd,
          trailing: Icon(Icons.file_open_outlined, color: p.textTertiary),
          onTap: () => _add(context),
        ),
      ],
    );
  }
}

/// A page of one topic, opened from the settings list. A page on its own paints its own backdrop.
class _SubPage extends StatelessWidget {
  const _SubPage({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => AmbientBackdrop(
    child: Padding(
      padding: EdgeInsets.only(left: SideInset.of(context)),
      child: Scaffold(
        body: _SettingsList(title: title, children: children),
      ),
    ),
  );
}

/// The settings list, or a topic's page: a round Back, the title large, and what is under it scrolling up under the
/// glass edge.
class _SettingsList extends StatelessWidget {
  const _SettingsList({
    super.key,
    required this.title,
    required this.children,
    this.back = true,
  });

  final String title;
  final List<Widget> children;

  /// False for a topic beside the list on a wide screen, which goes back with the list.
  final bool back;

  @override
  Widget build(BuildContext context) => ScrollEdge(
    title: title,
    child: ListView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      // The mini player and the tab bar are drawn over the end of the page: it scrolls clear of them, so the
      // last button (Install, Download) can be reached however long the text above it is
      padding: EdgeInsets.fromLTRB(
        16,
        ScrollEdge.topOf(context) + 8,
        16,
        HomeShell.bottomInsetOf(context),
      ),
      children: [
        SizedBox(
          height: 44,
          child: back
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: BackButton(style: roundButtonStyle(context, size: 44)),
                )
              : null,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 18),
          child: Text(title, style: Theme.of(context).textTheme.headlineLarge),
        ),
        ...children,
      ],
    ),
  );
}

/// Who this is and where: the name shown to others and the room, if any.
class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.room});

  final RoomController room;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: room,
      builder: (context, _) {
        final snapshot = room.snapshot;
        final name = snapshot.me?.name ?? room.profile.name ?? '';
        return _Group(
          children: [
            InkWell(
              key: const ValueKey('settings-profile'),
              onTap: () => showProfileSheet(context),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    ListenableBuilder(
                      listenable: AppScope.of(context).settings,
                      builder: (context, _) => Avatar(
                        name: name,
                        size: 52,
                        image: AppScope.of(context).settings.avatar,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name.isEmpty ? S.appName : name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.titleLarge,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            snapshot.inRoom
                                ? '${S.room} ${snapshot.room} · ${S.listening(snapshot.members.length)}'
                                : S.noRoom,
                            style: theme.bodyMedium?.copyWith(
                              color: p.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.edit_outlined, size: 18, color: p.textTertiary),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A row of the settings list that opens a page.
class _NavRow extends StatelessWidget {
  const _NavRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.value,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final String? value;
  final VoidCallback onTap;

  /// Its topic is the one shown beside the list, on a wide screen.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ColoredBox(
      color: selected ? p.veilStrong : Colors.transparent,
      child: _Row(
        label: label,
        value: value,
        leading: Icon(icon, color: p.primary),
        trailing: Icon(Icons.chevron_right_rounded, color: p.textTertiary),
        onTap: onTap,
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({this.title, required this.children, this.footer});

  final String? title;
  final List<Widget> children;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Text(
                title!.toUpperCase(),
                style: theme.labelSmall?.copyWith(letterSpacing: 0.8),
              ),
            ),
          // See-through on the page's backdrop, like the rest of what sits on it
          Container(
            decoration: BoxDecoration(
              color: p.veil,
              borderRadius: BorderRadius.circular(SapocheTheme.groupRadius),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      indent: 16,
                      color: p.text.withValues(alpha: 0.07),
                    ),
                  children[i],
                ],
              ],
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Text(footer!, style: theme.bodySmall),
            ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.label,
    this.value,
    this.leading,
    this.trailing,
    this.onTap,
    this.destructive = false,
  });

  final String label;
  final String? value;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 14)],
            Expanded(
              child: Text(
                label,
                style: theme.bodyLarge?.copyWith(
                  color: destructive ? p.error : p.text,
                ),
              ),
            ),
            if (value != null)
              // As wide as the words need, up to half the row: a long address must not push the label out
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.sizeOf(context).width * 0.5,
                ),
                child: Text(
                  value!,
                  maxLines: 1,
                  textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis,
                  style: theme.bodyLarge?.copyWith(color: p.textSecondary),
                ),
              ),
            if (trailing != null) ...[const SizedBox(width: 10), trailing!],
          ],
        ),
      ),
    );
  }
}

class _TrimRow extends StatefulWidget {
  const _TrimRow({required this.controller});

  final RoomController controller;

  @override
  State<_TrimRow> createState() => _TrimRowState();
}

class _TrimRowState extends State<_TrimRow> {
  static const _limit = 300.0;
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final theme = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final saved = widget.controller.snapshot.trimMs.toDouble();
        final value = (_dragging ?? saved).clamp(-_limit, _limit);
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 6),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(child: Text(S.latencyTrim, style: theme.bodyLarge)),
                  Text(
                    '${value >= 0 ? '+' : '−'}${value.abs().round()} ms',
                    style: theme.bodyLarge?.copyWith(color: p.textSecondary),
                  ),
                  TextButton(
                    onPressed: saved == 0
                        ? null
                        : () => widget.controller.setTrim(0),
                    child: Text(S.reset),
                  ),
                ],
              ),
              Slider(
                value: value,
                min: -_limit,
                max: _limit,
                divisions: (_limit * 2 / 10).round(),
                onChanged: (v) => setState(() => _dragging = v),
                onChangeEnd: (v) {
                  widget.controller.setTrim(v.round());
                  setState(() => _dragging = null);
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
