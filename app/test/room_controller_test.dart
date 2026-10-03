import 'package:flutter_test/flutter_test.dart';
import 'package:sapoche/data/backend.dart';
import 'package:sapoche/data/calm.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sapoche/data/models.dart';
import 'package:sapoche/data/recent_rooms.dart';
import 'package:sapoche/data/room_controller.dart';

import 'fake_backend.dart';

void main() {
  late FakeBackend backend;
  late RoomController controller;

  setUp(() async {
    backend = FakeBackend();
    controller = RoomController(backend);
    await controller.start();
  });

  tearDown(() => controller.dispose());

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test(
    'loads the saved profile so the welcome screen can prefill the name',
    () {
      expect(controller.profile.name, 'Anna');
      expect(controller.ready, isFalse);
    },
  );

  test(
    'slows the screen down while the native side says the phone is warm',
    () async {
      addTearDown(() => Calm.on.value = false);
      backend.emit(const CalmEvent(true));
      await settle();
      expect(Calm.on.value, isTrue);
      expect(Calm.slowdown, 2);
      backend.emit(const CalmEvent(false));
      await settle();
      expect(Calm.slowdown, 1);
    },
  );

  test('is ready once the first state arrives', () async {
    backend.emit(const StateEvent(RoomSnapshot()));
    await settle();
    expect(controller.ready, isTrue);
    expect(controller.snapshot.inRoom, isFalse);
  });

  test('exposes the current song and what comes next', () async {
    backend.emit(StateEvent(sampleRoom(index: 1)));
    await settle();
    expect(controller.snapshot.current?.title, 'Song 1');
    expect(controller.snapshot.upNext.map((e) => e.id), ['q2']);
    expect(controller.snapshot.nameOf('b'), 'Binh');
  });

  test('play button follows the room phase', () async {
    backend.emit(StateEvent(sampleRoom(phase: 'paused')));
    await settle();
    expect(controller.isPlaying, isFalse);
    await controller.togglePlay();
    expect(backend.calls.last, 'play');

    backend.emit(StateEvent(sampleRoom(phase: 'playing')));
    await settle();
    expect(controller.isPlaying, isTrue);
    await controller.togglePlay();
    expect(backend.calls.last, 'pause');
  });

  test('preparing counts as starting, so the button shows progress', () async {
    backend.emit(StateEvent(sampleRoom(phase: 'preparing')));
    await settle();
    expect(controller.isStarting, isTrue);
  });

  test(
    'position stands still while paused and advances while playing',
    () async {
      backend.emit(
        const PositionEvent(
          PlayerPosition(positionMs: 5000, durationMs: 60000),
        ),
      );
      await settle();
      expect(controller.positionMs(), 5000);

      backend.emit(
        const PositionEvent(
          PlayerPosition(playing: true, positionMs: 5000, durationMs: 60000),
        ),
      );
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(controller.positionMs(), inInclusiveRange(5100, 5400));
    },
  );

  test('tells what shows a play button only when playing starts or stops, not at every position', () async {
    var told = 0;
    controller.playState.addListener(() => told++);
    for (final ms in [1000, 2000, 3000]) {
      backend.emit(
        PositionEvent(
          PlayerPosition(playing: true, positionMs: ms, durationMs: 60000),
        ),
      );
      await settle();
    }
    expect(told, 1);
    expect(controller.playState.value, (true, false));

    backend.emit(
      const PositionEvent(PlayerPosition(positionMs: 3000, durationMs: 60000)),
    );
    await settle();
    expect(told, 2);
    expect(controller.playState.value, (false, false));
  });

  test('position never runs past the end of the song', () async {
    backend.emit(
      const PositionEvent(
        PlayerPosition(playing: true, positionMs: 59990, durationMs: 60000),
      ),
    );
    await settle();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(controller.positionMs(), 60000);
  });

  test(
    'a seek holds the bar at the target until the player catches up',
    () async {
      backend.emit(
        const PositionEvent(
          PlayerPosition(playing: true, positionMs: 1000, durationMs: 60000),
        ),
      );
      await settle();
      await controller.seek(30000);
      expect(backend.calls.last, 'seek 30000');
      expect(controller.positionMs(), 30000);
    },
  );

  test(
    'duration falls back to the queue entry before the player knows it',
    () async {
      backend.emit(StateEvent(sampleRoom()));
      await settle();
      expect(controller.durationMs(), 200000);
    },
  );

  test('queue moves are sent as the index in the whole queue', () async {
    backend.emit(StateEvent(sampleRoom(index: 0, songs: 4)));
    await settle();
    await controller.move(controller.snapshot.queue[3], 1);
    expect(backend.calls.last, 'move q3 1');
  });

  test('an unplayable song is announced with its title', () async {
    final messages = <String>[];
    controller.messages.listen(messages.add);
    backend.emit(
      const ErrorEvent(
        ServerError('unplayable', 'Nobody could load: Blinding Lights'),
      ),
    );
    await settle();
    expect(messages, ['Nobody could play “Blinding Lights”. Skipped.']);
  });

  test(
    'an unplayable song tells what went wrong when the phone says',
    () async {
      final messages = <String>[];
      controller.messages.listen(messages.add);
      backend.emit(
        const ErrorEvent(
          ServerError(
            'unplayable',
            'Could not load: Blinding Lights\nThe file is damaged (AVFoundationErrorDomain -11829)',
          ),
        ),
      );
      await settle();
      expect(messages, [
        'Nobody could play “Blinding Lights”. Skipped.\nThe file is damaged (AVFoundationErrorDomain -11829)',
      ]);
    },
  );

  test(
    'a setup link that was opened is kept for the screen to ask about',
    () async {
      backend.emit(
        const SetupEvent('sapoche://setup?server=https://a.example&key=k'),
      );
      await settle();
      expect(controller.setup.value?.server, 'https://a.example');
      expect(controller.setup.value?.key, 'k');
      controller.setup.value = null;
      backend.emit(const SetupEvent('sapoche://setup?server=http://a.example'));
      await settle();
      expect(controller.setup.value, isNull, reason: 'not an https server');
    },
  );

  test('a failing command becomes a message instead of an exception', () async {
    final messages = <String>[];
    controller.messages.listen(messages.add);
    backend.failWith = BackendException('no_room', 'Not in a room');
    await controller.next();
    await settle();
    expect(messages, ['Join a room first']);
  });

  test('joining reports a failure to the caller', () async {
    backend.failWith = BackendException('failed', 'server answered 401');
    final error = await controller.join(' abc234 ', ' Anna ');
    expect(error, contains('Could not connect'));
    expect(backend.calls.last, 'join ABC234 Anna');
  });

  test('creating a room trims the name', () async {
    expect(await controller.createRoom('  Anna '), isNull);
    expect(backend.calls.last, 'createRoom Anna');
  });

  test('the repeat button cycles off, all, one, off', () async {
    backend.emit(StateEvent(sampleRoom()));
    await settle();
    await controller.cycleRepeat();
    expect(backend.calls.last, 'repeat all');

    backend.emit(StateEvent(sampleRoom(repeat: Repeat.all)));
    await settle();
    await controller.cycleRepeat();
    expect(backend.calls.last, 'repeat one');

    backend.emit(StateEvent(sampleRoom(repeat: Repeat.one)));
    await settle();
    await controller.cycleRepeat();
    expect(backend.calls.last, 'repeat off');
  });

  test('an invitation link is handed to the UI once', () async {
    backend.emit(const InviteEvent('K2A5RF'));
    await settle();
    expect(controller.invite.value, 'K2A5RF');
  });

  test('sharing sends the code and a link that opens the app', () async {
    backend.emit(StateEvent(sampleRoom()));
    await settle();
    await controller.shareInvite();
    expect(backend.calls.last, contains('ABC234'));
    expect(backend.calls.last, contains('sapoche://join/ABC234'));
  });

  test('sharing does nothing outside a room', () async {
    await controller.shareInvite();
    expect(backend.calls.where((c) => c.startsWith('share')), isEmpty);
  });

  test('renaming trims the name', () async {
    await controller.rename('  Binh ');
    expect(backend.calls.last, 'rename Binh');
  });

  test('a playlist goes to the room in one call', () async {
    const tracks = [
      Track(videoId: 'aaaaaaaaaaa', title: 'A', artist: 'x', durMs: 1),
      Track(videoId: 'bbbbbbbbbbb', title: 'B', artist: 'x', durMs: 1),
    ];
    await controller.addMany(tracks, playNext: true);
    expect(backend.calls.last, 'addMany aaaaaaaaaaa,bbbbbbbbbbb next=true');
  });

  group('listening alone', () {
    test(
      'a pause by someone else offers to keep playing, a skip does not',
      () async {
        final notices = <Notice>[];
        controller.notices.listen(notices.add);
        backend.emit(const NoticeEvent(kind: 'paused', by: 'Binh'));
        backend.emit(
          const NoticeEvent(
            kind: 'skipped',
            by: 'Binh',
            title: 'Blinding Lights',
          ),
        );
        await settle();
        expect(notices.map((n) => n.text), [
          'Binh paused the room',
          'Binh switched to Blinding Lights',
        ]);
        expect(notices.map((n) => n.canKeepPlaying), [true, false]);
      },
    );

    test(
      'the play button follows this device\'s own player, not the room',
      () async {
        backend.emit(StateEvent(sampleRoom(phase: 'paused', solo: true)));
        backend.emit(const PositionEvent(PlayerPosition(playing: true)));
        await settle();
        expect(
          controller.isPlaying,
          isTrue,
          reason: 'the room is paused but I am playing',
        );
        await controller.togglePlay();
        expect(backend.calls.last, 'pause');
        expect(
          controller.isPlaying,
          isFalse,
          reason: 'shown at once, before the player reports',
        );
      },
    );

    test('the switch and the notice action reach the backend', () async {
      await controller.setSolo(true);
      await controller.keepPlaying();
      await controller.setSolo(false);
      expect(
        backend.calls,
        containsAllInOrder(['solo true', 'keepPlaying', 'solo false']),
      );
    });
  });

  test(
    'outside a room the play button follows this device\'s own player',
    () async {
      backend.emit(const StateEvent(RoomSnapshot()));
      await settle();
      expect(controller.isPlaying, isFalse);
      backend.emit(
        const PositionEvent(
          PlayerPosition(playing: true, positionMs: 1000, durationMs: 60000),
        ),
      );
      await settle();
      expect(controller.isPlaying, isTrue);
      await controller.togglePlay();
      expect(backend.calls.last, 'pause');
      expect(
        controller.isPlaying,
        isFalse,
        reason: 'shown at once, before the player reports back',
      );
      expect(controller.isStarting, isFalse);
    },
  );

  test(
    'rooms are remembered when this device is in them, with their name',
    () async {
      SharedPreferences.setMockInitialValues({});
      final recents = await RecentRooms.load();
      final remembering = RoomController(backend, recents: recents);
      await remembering.start();
      backend.emit(const StateEvent(RoomSnapshot()));
      await settle();
      expect(
        recents.rooms,
        isEmpty,
        reason: 'nothing to remember outside a room',
      );
      backend.emit(StateEvent(sampleRoom(name: 'Family')));
      await settle();
      expect(recents.rooms.single.code, 'ABC234');
      expect(recents.rooms.single.name, 'Family');
      remembering.dispose();
    },
  );

  test(
    'the invitation link lives on the server, or falls back to the app\'s own',
    () async {
      expect(controller.inviteLink('K2A5RF'), 'sapoche://join/K2A5RF');
      backend.profileValue = const Profile(
        name: 'Anna',
        server: 'https://x.example',
      );
      final withServer = RoomController(backend);
      await withServer.start();
      expect(withServer.inviteLink('K2A5RF'), 'https://x.example/join/K2A5RF');
      withServer.dispose();
    },
  );

  test('sharing an invitation sends the code and the link', () async {
    backend.profileValue = const Profile(
      name: 'Anna',
      server: 'https://x.example',
    );
    final sharing = RoomController(backend);
    await sharing.start();
    backend.emit(StateEvent(sampleRoom()));
    await settle();
    await sharing.shareInvite();
    expect(backend.calls.last, contains('ABC234'));
    expect(backend.calls.last, contains('https://x.example/join/ABC234'));
    sharing.dispose();
  });

  test('room settings and removals go to the native side', () async {
    await controller.setRoomName('  Weekend ');
    expect(backend.calls.last, 'roomName Weekend');
    await controller.setGuestControl(GuestControl.add);
    expect(backend.calls.last, 'guestControl add');
    await controller.kick(const Member(id: 'b', name: 'Binh', ready: true));
    expect(backend.calls.last, 'kick b');
  });

  test(
    'autoplay is on until turned off, and the choice goes to the native side',
    () async {
      expect(controller.autoplay, isTrue);
      await controller.setAutoplay(false);
      expect(controller.autoplay, isFalse);
      expect(backend.calls.last, 'autoplay false');
    },
  );

  test('the sleep timer follows what the native side reports', () async {
    expect(controller.sleep.on, isFalse);
    await controller.setSleep(SleepMode.time, minutes: 30);
    expect(backend.calls.last, 'sleep time 30');

    final endsAt = DateTime(2026, 9, 30, 23, 40);
    backend.emit(SleepEvent(SleepState(mode: SleepMode.time, endsAt: endsAt)));
    await Future<void>.delayed(Duration.zero);
    expect(controller.sleep.mode, SleepMode.time);
    expect(controller.sleep.endsAt, endsAt);

    // It ran out on its own, while the screen was off
    backend.emit(const SleepEvent(SleepState()));
    await Future<void>.delayed(Duration.zero);
    expect(controller.sleep.on, isFalse);
  });

  test('the sleep state is read from the JSON the native side sends', () {
    final state = SleepState.fromJson({'mode': 'time', 'endsAt': 1000});
    expect(state.mode, SleepMode.time);
    expect(state.endsAt, DateTime.fromMillisecondsSinceEpoch(1000));
    expect(
      SleepState.fromJson({'mode': 'song', 'endsAt': null}).mode,
      SleepMode.song,
    );
    expect(SleepState.fromJson({'mode': 'off'}).on, isFalse);
  });

  test(
    'completions come from the backend, and a failing one is just empty',
    () async {
      backend.suggestions = ['lofi girl', 'lofi beats'];
      expect(await controller.suggest('lofi'), ['lofi girl', 'lofi beats']);
      backend.failWith = StateError('offline');
      expect(await controller.suggest('lofi'), isEmpty);
    },
  );

  group('a song that is waiting in the queue is not added again', () {
    Track song(String id) =>
        Track(videoId: id, title: id, artist: 'x', durMs: 1000);

    test(
      'the one playing and those to come count, those played do not',
      () async {
        // video0 was played, video1 plays now, video2 is to come
        backend.emit(StateEvent(sampleRoom(index: 1)));
        await settle();
        expect(controller.snapshot.isQueued(song('video0')), isFalse);
        expect(controller.snapshot.isQueued(song('video1')), isTrue);
        expect(controller.snapshot.isQueued(song('video2')), isTrue);
        expect(controller.snapshot.isQueued(song('other')), isFalse);

        await controller.add(song('video1'));
        await controller.add(song('video2'), playNext: true);
        expect(backend.calls.where((c) => c.startsWith('add')), isEmpty);

        await controller.add(song('video0'));
        expect(backend.calls.last, 'add video0 next=false');
      },
    );

    test('the video of a queued song counts as queued', () async {
      backend.emit(StateEvent(sampleRoom(index: 0)));
      await settle();
      // The queue holds "Song 1" by "Artist 1"; this is the same song as a video
      const video = Track(
        videoId: 'clipaaaaaaa',
        title: 'Song 1 (Official Video)',
        artist: 'Artist 1 - Topic',
        durMs: 201000,
      );
      expect(controller.snapshot.isQueued(video), isTrue);
      await controller.add(video);
      expect(backend.calls.where((c) => c.startsWith('add')), isEmpty);
    });

    test('adding many leaves out what is queued and what repeats', () async {
      backend.emit(StateEvent(sampleRoom(index: 1)));
      await settle();
      await controller.addMany([
        song('video2'),
        song('new1'),
        song('new2'),
        song('new1'),
      ]);
      expect(backend.calls.last, 'addMany new1,new2 next=false');

      backend.calls.clear();
      await controller.addMany([song('video1'), song('video2')]);
      expect(backend.calls, isEmpty, reason: 'nothing new, nothing sent');
    });

    test('outside a room a queue that has played through is empty of waiting songs', () async {
      backend.emit(
        StateEvent(
          RoomSnapshot(
            phase: 'idle',
            index: 0,
            queue: [
              for (final id in ['a', 'b'])
                QueueEntry(
                  id: id,
                  videoId: id,
                  title: id,
                  artist: 'x',
                  durMs: 1000,
                  addedBy: '',
                ),
            ],
          ),
        ),
      );
      await settle();
      expect(controller.snapshot.isQueued(song('a')), isFalse);
      await controller.add(song('a'));
      expect(backend.calls.last, 'add a next=false');
    });
  });
}
