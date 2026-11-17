import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_journal/is_journal.dart';
import 'package:is_journal/service.dart';
import 'package:test/test.dart';

Uint8List bytesOf(String s) => utf8.encode(s);

/// Sends [request] to the service at [socket] and returns its one-line
/// answer.
Future<String> send(File socket, String request) async {
  final s = await Socket.connect(
    InternetAddress(socket.path, type: InternetAddressType.unix),
    0,
  );
  s.add(bytesOf(request));
  await s.close();
  return (await utf8.decoder.bind(s).join()).trim();
}

/// One entry as the read socket sends it.
typedef Frame = ({String hash, String kind, String previous, String bytes});

/// A connection to the read socket that sent one request: what comes back
/// is lines, and [Frame]s for entries.
final class Reader {
  Reader._(this._socket) : _items = StreamIterator(_parse(_socket));

  final Socket _socket;
  final StreamIterator<Object> _items;

  static Future<Reader> open(File socket, String request) async {
    final s = await Socket.connect(
      InternetAddress(socket.path, type: InternetAddressType.unix),
      0,
    );
    s.add(bytesOf('$request\n'));
    return Reader._(s);
  }

  /// The next line or entry; null when the service has closed.
  Future<Object?> next() async =>
      await _items.moveNext().timeout(const Duration(seconds: 5))
      ? _items.current
      : null;

  Future<void> close() async => _socket.destroy();

  static Stream<Object> _parse(Stream<Uint8List> input) async* {
    var buffer = <int>[];
    await for (final chunk in input) {
      buffer.addAll(chunk);
      while (true) {
        final nl = buffer.indexOf(0x0a);
        if (nl < 0) break;
        final words = utf8.decode(buffer.sublist(0, nl)).split(' ');
        if (words.first != 'entry') {
          yield words.join(' ');
          buffer = buffer.sublist(nl + 1);
          continue;
        }
        final end = nl + 1 + int.parse(words[4]);
        if (buffer.length < end) break;
        yield (
          hash: words[1],
          kind: words[2],
          previous: words[3],
          bytes: utf8.decode(buffer.sublist(nl + 1, end)),
        );
        buffer = buffer.sublist(end);
      }
    }
  }
}

void main() {
  final me = Process.runSync('id', ['-un']).stdout.toString().trim();
  late Directory dir;
  late File socket;
  late File readSocket;
  late JournalService service;

  /// A service on [dir] whose sender table is [table].
  Future<JournalService> start(String table) async => JournalService.start(
    Journal.open(dir)!,
    SenderTable.parse(bytesOf(table)),
    socket,
    readSocket: readSocket,
  );

  /// The object of entry [n] (from 1), as text.
  String object(int n) {
    final raw = File('${dir.path}/entries').readAsBytesSync();
    final entry = JournalEntry.parse(
      Uint8List.sublistView(raw, (n - 1) * 96, n * 96),
    )!;
    return utf8.decode(service.journal.get(entry.object)!);
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('service_test');
    socket = File('${dir.path}.sock');
    readSocket = File('${dir.path}.read.sock');
    service = await start('$me turn witnessed\nroot decided\n');
  });
  tearDown(() async {
    await service.close();
    dir.deleteSync(recursive: true);
  });

  test('starts with an entry holding the sender table in force', () {
    expect(object(1), 'started\n-\n$me turn witnessed\nroot decided\n');
  });

  test('adds what a sender may write, exactly as sent', () async {
    final answer = await send(socket, 'turn\n-\nhello');
    final head = (service.journal.check() as Intact).head;
    expect(answer, 'ok ${head.hex}');
    expect(object(2), 'turn\n-\nhello');
  });

  test('refuses a kind its sender may not write, and adds nothing', () async {
    expect(await send(socket, 'decided\n-\nnot mine'), startsWith('refused'));
    expect(await send(socket, 'started\n-\nnot mine'), startsWith('refused'));
    expect((service.journal.check() as Intact).count, 1);
  });

  test('refuses a sender not in the table', () async {
    await service.close();
    service = await start('root turn\n');
    expect(await send(socket, 'turn\n-\nhello'), startsWith('refused'));
    expect((service.journal.check() as Intact).count, 2);
  });

  test('refuses a request with no header', () async {
    expect(await send(socket, 'just bytes'), startsWith('refused'));
    expect(await send(socket, 'turn\nnot-a-hash\nx'), startsWith('refused'));
  });

  group('the read socket', () {
    String ok(String answer) => answer.substring('ok '.length);

    test('subscribes to a kind from the start, then as entries come', () async {
      final a = ok(await send(socket, 'turn\n-\na'));
      final w = ok(await send(socket, 'witnessed\n-\nw'));
      final reader = await Reader.open(readSocket, 'subscribe turn from start');
      expect(await reader.next(), (
        hash: a,
        kind: 'turn',
        previous: '-',
        bytes: 'turn\n-\na',
      ));
      // Where the backlog ends: the journal's head, of whatever kind.
      expect(await reader.next(), 'caught-up $w');
      // The hash it reads back is the one the write answered with.
      final b = ok(await send(socket, 'turn\n$a\nb'));
      expect(await reader.next(), (
        hash: b,
        kind: 'turn',
        previous: a,
        bytes: 'turn\n$a\nb',
      ));
      await reader.close();
    });

    test('starts after the entry it is given', () async {
      final w1 = ok(await send(socket, 'witnessed\n-\nw1'));
      final w2 = ok(await send(socket, 'witnessed\n-\nw2'));
      final reader = await Reader.open(
        readSocket,
        'subscribe witnessed from $w1',
      );
      expect(((await reader.next())! as Frame).hash, w2);
      expect(await reader.next(), 'caught-up $w2');
      await reader.close();
    });

    test('says it is caught up even when nothing came before', () async {
      final head = (service.journal.check() as Intact).head.hex;
      final reader = await Reader.open(readSocket, 'subscribe turn from start');
      expect(await reader.next(), 'caught-up $head');
      final a = ok(await send(socket, 'turn\n-\na'));
      expect(((await reader.next())! as Frame).hash, a);
      await reader.close();
    });

    test('subscribes to several kinds, or every kind with *', () async {
      await send(socket, 'turn\n-\nt');
      await send(socket, 'witnessed\n-\nw');
      var reader = await Reader.open(readSocket, 'subscribe *  from start');
      expect(await reader.next(), 'refused not-a-request');
      reader = await Reader.open(readSocket, 'subscribe * from start');
      expect(((await reader.next())! as Frame).kind, 'started');
      await reader.close();
      reader = await Reader.open(
        readSocket,
        'subscribe witnessed,turn from start',
      );
      expect(((await reader.next())! as Frame).kind, 'turn');
      expect(((await reader.next())! as Frame).kind, 'witnessed');
      await reader.close();
    });

    test("answers a chain's tip", () async {
      final a = ok(await send(socket, 'turn\n-\na'));
      final b = ok(await send(socket, 'turn\n$a\nb'));
      expect(await (await Reader.open(readSocket, 'tip $a')).next(), 'tip $b');
      final unknown = ObjectId.of(bytesOf('nothing')).hex;
      expect(
        await (await Reader.open(readSocket, 'tip $unknown')).next(),
        'refused unknown $unknown',
      );
    });

    test('refuses an unknown starting point', () async {
      final unknown = ObjectId.of(bytesOf('nothing')).hex;
      final reader = await Reader.open(
        readSocket,
        'subscribe turn from $unknown',
      );
      expect(await reader.next(), 'refused unknown $unknown');
      expect(await reader.next(), isNull);
    });

    test('takes only the subscribe request, read strictly', () async {
      for (final old in [
        'follow turn -',
        'subscribe turn -',
        'subscribe turn from -',
        'subscribe turn start',
        'subscribe turn after start',
      ]) {
        final reader = await Reader.open(readSocket, old);
        expect(await reader.next(), 'refused not-a-request', reason: old);
        await reader.close();
      }
    });

    test(
      'cannot write: a write request is refused, and adds nothing',
      () async {
        final reader = await Reader.open(readSocket, 'turn\n-\nsneaked in');
        expect(await reader.next(), 'refused not-a-request');
        expect((service.journal.check() as Intact).count, 1);
      },
    );

    test('a closing service ends its subscribers', () async {
      final reader = await Reader.open(readSocket, 'subscribe turn from start');
      expect(await reader.next(), startsWith('caught-up '));
      await send(socket, 'turn\n-\na');
      expect(await reader.next(), isA<Frame>());
      await service.close();
      expect(await reader.next(), isNull);
      service = await start('$me turn\n');
    });
  });

  group('get', () {
    String ok(String answer) => answer.substring('ok '.length);

    /// The file holding the object of entry [hash].
    File objectOf(String hash) {
      final raw = File('${dir.path}/entries').readAsBytesSync();
      for (var at = 0; at < raw.length; at += 96) {
        final entry = Uint8List.sublistView(raw, at, at + 96);
        if (EntryHash.of(entry).hex != hash) continue;
        final id = JournalEntry.parse(entry)!.object.hex;
        return File(
          '${dir.path}/objects/${id.substring(0, 2)}/${id.substring(2)}',
        );
      }
      throw StateError('no entry $hash');
    }

    /// Asks the read socket for entry [hash], keeping its own side open,
    /// and returns the first line and the bytes after it.
    Future<({List<String> line, Uint8List rest})> get(String hash) async {
      final s = await Socket.connect(
        InternetAddress(readSocket.path, type: InternetAddressType.unix),
        0,
      );
      s.add(bytesOf('get $hash\n'));
      final all = BytesBuilder();
      await s.forEach(all.add).timeout(const Duration(seconds: 5));
      s.destroy();
      final bytes = all.takeBytes();
      final nl = bytes.indexOf(0x0a);
      return (
        line: utf8.decode(bytes.sublist(0, nl)).split(' '),
        rest: Uint8List.sublistView(bytes, nl + 1),
      );
    }

    Uint8List unhex(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

    test(
      'answers an entry with its bytes, and its 96 bytes, which check',
      () async {
        final a = ok(await send(socket, 'turn\n-\na'));
        final b = ok(await send(socket, 'turn\n$a\nb'));
        final got = await get(b);
        expect(got.line.sublist(0, 5), [
          'entry',
          b,
          'turn',
          a,
          '${'turn\n$a\nb'.length}',
        ]);
        expect(utf8.decode(got.rest), 'turn\n$a\nb');
        final entry = unhex(got.line[5]);
        expect(EntryHash.of(entry).hex, b);
        expect(JournalEntry.parse(entry)!.object, ObjectId.of(got.rest));
        expect(JournalEntry.parse(entry)!.previous.hex, a);
      },
    );

    test('says none for an entry the journal does not hold', () async {
      final unknown = ObjectId.of(bytesOf('nothing')).hex;
      expect((await get(unknown)).line, ['none', unknown]);
    });

    test('says unreadable, not none, when the object is gone', () async {
      final a = ok(await send(socket, 'turn\n-\na'));
      objectOf(a).deleteSync();
      expect((await get(a)).line, ['unreadable', a, 'missing']);
      // Read back from the journal on a restart, it was still recorded.
      await service.close();
      service = await start('$me turn\n');
      expect((await get(a)).line, ['unreadable', a, 'missing']);
    });

    test('says unreadable when the object no longer holds its bytes', () async {
      final a = ok(await send(socket, 'turn\n-\na'));
      objectOf(a).writeAsStringSync('turn\n-\nchanged');
      expect((await get(a)).line, ['unreadable', a, 'corrupt']);
      await service.close();
      service = await start('$me turn\n');
      expect((await get(a)).line, ['unreadable', a, 'corrupt']);
    });

    test(
      'finds an entry written without a header, and what came after',
      () async {
        // Not through the service: it reads the journal back to catch up.
        service.journal.add(bytesOf('no header'));
        final plain = (service.journal.check() as Intact).head.hex;
        final a = ok(await send(socket, 'turn\n-\na'));
        final got = await get(plain);
        expect(got.line.sublist(0, 5), ['entry', plain, '-', '-', '9']);
        expect(utf8.decode(got.rest), 'no header');
        expect((await get(a)).line.sublist(0, 3), ['entry', a, 'turn']);
      },
    );

    test('refuses a hash that is not one', () async {
      expect((await get('xyz')).line, ['refused', 'not-a-request']);
    });
  });

  group('the tip check', () {
    test('appends only to a tip; a refusal names the tip', () async {
      final a = (await send(socket, 'turn\n-\na')).substring(3);
      final b = (await send(socket, 'turn\n$a\nb')).substring(3);
      expect(await send(socket, 'turn\n$a\nfork'), 'refused not-tip $b');
      expect(await send(socket, 'turn\n$b\nc'), startsWith('ok '));
      expect((service.journal.check() as Intact).count, 4);
    });

    test('chains are separate: each "-" starts one', () async {
      final a = (await send(socket, 'turn\n-\na')).substring(3);
      final x = (await send(socket, 'turn\n-\nx')).substring(3);
      expect(await send(socket, 'turn\n$a\nb'), startsWith('ok '));
      expect(await send(socket, 'turn\n$x\ny'), startsWith('ok '));
    });

    test('refuses an entry it does not know', () async {
      final unknown = ObjectId.of(bytesOf('nothing here')).hex;
      expect(
        await send(socket, 'turn\n$unknown\nx'),
        'refused unknown $unknown',
      );
    });

    test('a restart reads the chains back, and starts again', () async {
      final a = (await send(socket, 'turn\n-\na')).substring(3);
      final b = (await send(socket, 'turn\n$a\nb')).substring(3);
      await service.close();
      service = await start('$me turn\n');
      expect(object(4), 'started\n-\n$me turn\n');
      expect(await send(socket, 'turn\n$a\nfork'), 'refused not-tip $b');
      expect(await send(socket, 'turn\n$b\nc'), startsWith('ok '));
    });
  });

  group('chain ownership', () {
    final myUid = int.parse(
      Process.runSync('id', ['-u']).stdout.toString().trim(),
    );
    final trajectory1 = 'a1' * 32,
        trajectory2 = 'a2' * 32,
        trajectory3 = 'a3' * 32;
    final mission1 = 'b1' * 32, mission2 = 'b2' * 32;
    const table = 'attaching: reply-chunk\n';

    String ok(String answer) {
      expect(answer, startsWith('ok '));
      return answer.substring('ok '.length);
    }

    String usersAssigned(
      String trajectory,
      String mission,
      String loop,
      String suit,
    ) =>
        'users-assigned-to-trajectory\n-\n{"trajectory":"$trajectory","mission":"$mission",'
        '"loopUser":"$loop","suit":"$suit"}';

    /// The docking station's decisions chain: each decision,
    /// `mission-ended` among them, follows the last one.
    String? decided;

    /// Ends [mission] as the docking station does, on its decisions chain.
    Future<String> end(String mission, {String? body}) async {
      body ??= '{"event":"${'e0' * 32}","by":"person","mission":"$mission"}';
      final answer = await send(
        socket,
        'mission-ended\n${decided ?? '-'}\n$body',
      );
      if (answer.startsWith('ok ')) decided = answer.substring('ok '.length);
      return answer;
    }

    setUp(() async {
      decided = null;
      await service.close();
      service = await start(
        '$me users-assigned-to-trajectory mission-ended reply-chunk turn proposed\n$table',
      );
    });

    test(
      'users-assigned-to-trajectory roots a chain only its loop user extends',
      () async {
        final mine = ok(
          await send(socket, usersAssigned(trajectory1, mission1, me, '9001')),
        );
        final t = ok(await send(socket, 'turn\n$mine\nmy turn'));
        expect(await send(socket, 'proposed\n$t\nx'), startsWith('ok '));
        final theirs = ok(
          await send(
            socket,
            usersAssigned(trajectory2, mission1, '9002', '9003'),
          ),
        );
        expect(await send(socket, 'turn\n$theirs\nx'), 'refused not-owner');
      },
    );

    test('the loop user, given as a uid, is the same user', () async {
      final a = ok(
        await send(
          socket,
          usersAssigned(trajectory1, mission1, '$myUid', '9001'),
        ),
      );
      expect(await send(socket, 'turn\n$a\nx'), startsWith('ok '));
    });

    test('reads users-assigned-to-trajectory strictly', () async {
      final good = usersAssigned(trajectory1, mission1, '9001', '9002');
      for (final bad in [
        good.replaceFirst('}', ',"extra":1}'),
        good.replaceFirst('"suit"', '"missionUser"'),
        good.replaceFirst(trajectory1, trajectory1.toUpperCase()),
        good.replaceFirst(mission1, 'b1'),
        good.replaceFirst('"9001"', '9001'),
        good.replaceFirst('"9001"', '"-n"'),
        good.replaceFirst('{', '['),
      ]) {
        expect(
          await send(socket, bad),
          'refused users-assigned-body',
          reason: bad,
        );
      }
      expect(await send(socket, good), startsWith('ok '));
    });

    test(
      'users-assigned-to-trajectory starts a chain, never extends one',
      () async {
        final t = ok(await send(socket, 'turn\n-\nt'));
        final body = usersAssigned(trajectory1, mission1, '9001', '9002');
        expect(
          await send(socket, body.replaceFirst('\n-\n', '\n$t\n')),
          'refused users-assigned-not-root',
        );
      },
    );

    test('a user it cannot find is refused, not skipped', () async {
      expect(
        await send(
          socket,
          usersAssigned(trajectory1, mission1, 'no-such-user-xq', '1'),
        ),
        'refused no-user no-such-user-xq',
      );
      expect(
        await send(
          socket,
          usersAssigned(trajectory1, mission1, '9001', 'no-such-user-xq'),
        ),
        'refused no-user no-such-user-xq',
      );
    });

    test('a trajectory is assigned once, ever', () async {
      ok(
        await send(
          socket,
          usersAssigned(trajectory1, mission1, '9001', '9002'),
        ),
      );
      expect(
        await send(
          socket,
          usersAssigned(trajectory1, mission2, '9003', '9004'),
        ),
        'refused users-assigned-again $trajectory1',
      );
      ok(await end(mission1));
      expect(
        await send(
          socket,
          usersAssigned(trajectory1, mission2, '9003', '9004'),
        ),
        'refused users-assigned-again $trajectory1',
      );
    });

    test('an open trajectory holds its users, in any mission', () async {
      ok(
        await send(
          socket,
          usersAssigned(trajectory1, mission1, '9001', '9002'),
        ),
      );
      // The loop user, or the suit, of an open trajectory: in its own mission or
      // another, and as either user.
      for (final (mission, loop, suit, inUse) in [
        (mission1, '9001', '9005', '9001'),
        (mission2, '9005', '9002', '9002'),
        (mission2, '9002', '9005', '9002'),
        (mission2, '9005', '9001', '9001'),
        (mission2, '9005', '9005', '9005'),
      ]) {
        expect(
          await send(socket, usersAssigned(trajectory2, mission, loop, suit)),
          'refused in-use $inUse',
        );
      }
      ok(
        await send(
          socket,
          usersAssigned(trajectory2, mission2, '9003', '9004'),
        ),
      );
    });

    test(
      'mission-ended closes every chain of its mission, and frees its users',
      () async {
        final a = ok(
          await send(socket, usersAssigned(trajectory1, mission1, me, '9001')),
        );
        final b = ok(
          await send(
            socket,
            usersAssigned(trajectory2, mission1, '9002', '9003'),
          ),
        );
        final c = ok(
          await send(
            socket,
            usersAssigned(trajectory3, mission2, '9004', '9005'),
          ),
        );
        final t = ok(await send(socket, 'turn\n$a\nt'));
        ok(await end(mission1));
        expect(
          await send(socket, 'turn\n$t\nx'),
          'refused mission-ended $mission1',
        );
        expect(
          await send(socket, 'turn\n$b\nx'),
          'refused mission-ended $mission1',
        );
        expect(await send(socket, 'turn\n$c\nx'), 'refused not-owner');
        // Ended twice changes nothing.
        ok(await end(mission1));
        // Its users are free for a trajectory of another mission.
        ok(
          await send(
            socket,
            usersAssigned('a4' * 32, mission2, '9001', '9002'),
          ),
        );
      },
    );

    test(
      'reads the mission of mission-ended strictly, and only that',
      () async {
        for (final bad in [
          '{}',
          '{"mission":"${mission1.toUpperCase()}"}',
          '{"mission":"b1"}',
          '{"mission":1}',
          '["mission"]',
          'not json',
        ]) {
          expect(await end(mission1, body: bad), 'refused mission-ended-body');
        }
        // The rest of the body is the docking station's to read.
        final a = ok(
          await send(socket, usersAssigned(trajectory1, mission1, me, '9001')),
        );
        ok(await end(mission1, body: '{"mission":"$mission1","new":[1]}'));
        expect(
          await send(socket, 'turn\n$a\nx'),
          'refused mission-ended $mission1',
        );
      },
    );

    test('mission-ended takes the tip check like any entry', () async {
      ok(await end(mission1));
      final first = decided!;
      ok(await end(mission2));
      expect(
        await send(socket, 'mission-ended\n$first\n{"mission":"$mission1"}'),
        'refused not-tip $decided',
      );
    });

    group('an attached chain', () {
      test('names its parent, and its owner extends it', () async {
        final a = ok(
          await send(socket, usersAssigned(trajectory1, mission1, me, '9001')),
        );
        final r = ok(await send(socket, 'reply-chunk\n-\n$a\nchunk 1'));
        expect(
          await send(socket, 'reply-chunk\n$r\nchunk 2'),
          startsWith('ok '),
        );
        // It is a chain of its own: the trajectory's chain goes on beside it.
        expect(await send(socket, 'turn\n$a\nt'), startsWith('ok '));
      });

      test('is refused unless its sender owns the parent', () async {
        final theirs = ok(
          await send(
            socket,
            usersAssigned(trajectory1, mission1, '9001', '9002'),
          ),
        );
        expect(
          await send(socket, 'reply-chunk\n-\n$theirs\nx'),
          'refused not-owner',
        );
        final unowned = ok(await send(socket, 'turn\n-\nt'));
        expect(
          await send(socket, 'reply-chunk\n-\n$unowned\nx'),
          'refused parent-unowned',
        );
        final unknown = 'c0' * 32;
        expect(
          await send(socket, 'reply-chunk\n-\n$unknown\nx'),
          'refused unknown $unknown',
        );
        for (final bad in ['reply-chunk\n-\nno parent', 'reply-chunk\n-\n']) {
          expect(await send(socket, bad), 'refused no-parent', reason: bad);
        }
      });

      test('closes with the mission', () async {
        final a = ok(
          await send(socket, usersAssigned(trajectory1, mission1, me, '9001')),
        );
        final r = ok(await send(socket, 'reply-chunk\n-\n$a\nchunk'));
        ok(await end(mission1));
        expect(
          await send(socket, 'reply-chunk\n$r\nlate'),
          'refused mission-ended $mission1',
        );
        expect(
          await send(socket, 'reply-chunk\n-\n$a\nlate'),
          'refused mission-ended $mission1',
        );
      });

      test('only for kinds the table lists as attaching', () async {
        final a = ok(
          await send(socket, usersAssigned(trajectory1, mission1, me, '9001')),
        );
        // A kind that does not attach starts an unowned chain, body and all.
        expect(await send(socket, 'turn\n-\n$a\nx'), startsWith('ok '));
      });
    });

    test('a restart refuses exactly what the live service did', () async {
      final mine = ok(
        await send(socket, usersAssigned(trajectory1, mission1, me, '9001')),
      );
      final theirs = ok(
        await send(
          socket,
          usersAssigned(trajectory2, mission2, '9002', '9003'),
        ),
      );
      final r = ok(await send(socket, 'reply-chunk\n-\n$mine\nchunk'));
      await service.close();
      // Restarted with no attaching kinds: the attached chain was attached
      // under the table in force when it was added, and stays attached.
      service = await start(
        '$me users-assigned-to-trajectory mission-ended reply-chunk turn proposed\n',
      );
      expect(await send(socket, 'turn\n$theirs\nx'), 'refused not-owner');
      expect(
        await send(
          socket,
          usersAssigned(trajectory2, mission1, '9004', '9005'),
        ),
        'refused users-assigned-again $trajectory2',
      );
      expect(
        await send(socket, usersAssigned('a4' * 32, mission1, '9002', '9005')),
        'refused in-use 9002',
      );
      ok(await end(mission1));
      await service.close();
      service = await start(
        '$me users-assigned-to-trajectory mission-ended reply-chunk turn proposed\n',
      );
      expect(
        await send(socket, 'reply-chunk\n$r\nx'),
        'refused mission-ended $mission1',
      );
      expect(
        await send(socket, 'turn\n$mine\nx'),
        'refused mission-ended $mission1',
      );
      // With no attaching kinds, a reply-chunk root is unowned again.
      expect(await send(socket, 'reply-chunk\n-\n$mine\nx'), startsWith('ok '));
    });
  });

  group('the sender table', () {
    test('refuses a kind it cannot hold, and a user it cannot find', () {
      for (final bad in [
        '$me started\n',
        '$me tu/rn\n',
        '$me -\n',
        '$me\n',
        'no-such-user-here turn\n',
      ]) {
        expect(
          () => SenderTable.parse(bytesOf(bad)),
          throwsFormatException,
          reason: bad,
        );
      }
    });

    test('takes comments and blank lines', () {
      SenderTable.parse(bytesOf('# who may write what\n\n$me turn\n'));
    });

    test('lists the kinds that attach, on a line of their own', () {
      SenderTable.parse(bytesOf('attaching: reply-chunk x\n$me turn\n'));
      for (final bad in [
        'attaching:\n',
        'attaching: tu/rn\n',
        'attaching: users-assigned-to-trajectory\n',
        'attaching: mission-ended\n',
        'attaching: started\n',
      ]) {
        expect(
          () => SenderTable.parse(bytesOf(bad)),
          throwsFormatException,
          reason: bad,
        );
      }
    });
  });
}
