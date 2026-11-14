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

void main() {
  final me = Process.runSync('id', ['-un']).stdout.toString().trim();
  late Directory dir;
  late File socket;
  late JournalService service;

  /// A service on [dir] whose sender table is [table].
  Future<JournalService> start(String table) async => JournalService.start(
    Journal.open(dir)!,
    SenderTable.parse(bytesOf(table)),
    socket,
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
    service = await start('$me turn\nroot decided\n');
  });
  tearDown(() async {
    await service.close();
    dir.deleteSync(recursive: true);
  });

  test('starts with an entry holding the sender table in force', () {
    expect(object(1), 'started\n-\n$me turn\nroot decided\n');
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
  });
}
