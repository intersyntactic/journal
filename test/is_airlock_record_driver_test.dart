import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:is_airlock_record_driver/is_airlock_record_driver.dart';
import 'package:test/test.dart';

Uint8List bytesOf(String s) => utf8.encode(s);

/// The indented block after the README line ending in [marker], so a test
/// runs exactly what the README tells the person to run.
String readmeBlock(String marker) {
  final lines = File('README.md').readAsLinesSync();
  final start = lines.indexWhere((l) => l.endsWith(marker));
  expect(start, isNot(-1), reason: 'the README has no line ending "$marker"');
  return lines
      .skip(start + 2)
      .takeWhile((l) => l.startsWith('    '))
      .map((l) => l.substring(4))
      .join('\n');
}

/// [RecordDriver.open] of [path] from another isolate. Top-level, so the
/// closure sent to it carries [path] and nothing of a test's state.
Future<RecordDriver?> openInAnotherIsolate(String path) =>
    Isolate.run(() => RecordDriver.open(Directory(path)));

String bash(String script, Directory dir) {
  final r = Process.runSync('bash', ['-c', script], workingDirectory: dir.path);
  expect(r.exitCode, 0, reason: r.stderr as String);
  return r.stdout as String;
}

void main() {
  late Directory dir;
  late RecordDriver driver;
  File entries() => File('${dir.path}/entries');
  Uint8List entriesBytes() => entries().readAsBytesSync();
  File object(ObjectId id) => File(
    '${dir.path}/objects/${id.hex.substring(0, 2)}/${id.hex.substring(2)}',
  );
  void addAll(String prefix, int n) {
    for (var i = 0; i < n; i++) {
      driver.add(bytesOf('$prefix $i'));
    }
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('record_test');
    driver = RecordDriver.open(dir)!;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  group('names', () {
    test(
      'an object id and an entry hash with the same bytes are not equal',
      () {
        final digest = ObjectId.of(bytesOf('x')).bytes;
        expect(
          ObjectId.fromDigest(digest),
          isNot(EntryHash.fromDigest(digest)),
        );
      },
    );

    test("the record's origin is the sha256 of its format's name", () {
      final printed = bash(
        "printf 'is_airlock_record_driver/2' | shasum -a 256",
        dir,
      );
      expect(EntryHash.origin.hex, printed.substring(0, 64));
    });
  });

  test("the driver's hash is what the README's command prints", () {
    final printed = bash(readmeBlock("package's root:"), Directory.current);
    expect(RecordDriver.ownHash()!.hex, printed.substring(0, 64));
  });

  group('objects', () {
    test('come back as they went in; added twice, one object, two entries', () {
      final id = driver.add(bytesOf('what went up'));
      expect(driver.get(id), bytesOf('what went up'));
      expect(driver.add(bytesOf('what went up')), id);
      expect(entriesBytes().length, 2 * RecordEntry.length);
      final objects = Directory('${dir.path}/objects')
          .listSync(recursive: true);
      expect(objects.whereType<File>().length, 1);
    });

    test('that no longer hash to their name throw, until stored again', () {
      final id = driver.add(bytesOf('what went up'));
      object(id).writeAsStringSync('edited');
      expect(() => driver.get(id), throwsA(isA<CorruptObject>()));
      driver.store(bytesOf('what went up'));
      expect(driver.get(id), bytesOf('what went up'));
      expect(entriesBytes().length, RecordEntry.length);
    });

    test('stored, are kept with no entry, under the id add gives them', () {
      final id = driver.store(bytesOf('a piece'));
      expect(driver.get(id), bytesOf('a piece'));
      expect(driver.check(), isA<NoRecord>());
      expect(driver.add(bytesOf('a piece')), id);
      expect((driver.check() as Intact).count, 1);
    });
  });

  group('one writer', () {
    test('a second open in this process throws until the first closes', () {
      expect(() => RecordDriver.open(dir), throwsStateError);
      driver.close();
      RecordDriver.open(dir)!
        ..add(bytesOf('after'))
        ..close();
      expect(driver.check(), isA<Intact>());
    });

    test('a folder it cannot write fails as itself, not as already open', () {
      final locked = Directory('${dir.path}/locked')..createSync();
      Process.runSync('chmod', ['555', locked.path]);
      addTearDown(() => Process.runSync('chmod', ['755', locked.path]));
      expect(
        () => RecordDriver.open(locked),
        throwsA(isA<PathAccessException>()),
      );
    });

    test('another isolate in this process cannot open it', () async {
      await expectLater(openInAnotherIsolate(dir.path), throwsStateError);
    });

    test('a closed driver writes nothing', () {
      driver.close();
      expect(() => driver.add(bytesOf('late')), throwsStateError);
      expect(() => driver.store(bytesOf('late')), throwsStateError);
      expect(entries().existsSync(), isFalse);
      expect(Directory('${dir.path}/objects').existsSync(), isFalse);
    });
  });

  group('the record', () {
    test('holds one 96-byte entry per call: before, driver, object', () {
      final id = driver.add(bytesOf('one'));
      expect(entriesBytes().length, 96);
      final entry = RecordEntry.parse(entriesBytes())!;
      expect(entry.previous, EntryHash.origin);
      expect(entry.driver, driver.hash);
      expect(entry.object, id);
    });

    test('approved holds the first word of each line of approved', () {
      expect(driver.approved(), isEmpty);
      final other = DriverHash.parse(ObjectId.of(bytesOf('another')).hex)!;
      File('${dir.path}/approved').writeAsStringSync(
        '${driver.hash.hex}  -\n\n  ${other.hex} checked 5 Nov\nnot a hash\n',
      );
      expect(driver.approved(), {driver.hash, other});
    });

    test('an approval writes nothing, and covers what was already written', () {
      driver.add(bytesOf('same'));
      File('${dir.path}/approved').writeAsStringSync('${driver.hash.hex}  -\n');
      driver.add(bytesOf('same'));
      final bytes = entriesBytes();
      // Added before and after the approval, the two entries differ only in
      // the entry each names before it.
      expect(
        Uint8List.sublistView(bytes, 32, 96),
        Uint8List.sublistView(bytes, 96 + 32, 96 * 2),
      );
      final first = RecordEntry.parse(Uint8List.sublistView(bytes, 0, 96))!;
      expect(driver.approved(), contains(first.driver));
    });

    test('is NoRecord before anything is written, Intact when empty', () {
      expect(driver.check(), isA<NoRecord>());
      entries().writeAsBytesSync(const []);
      final check = driver.check() as Intact;
      expect([check.count, check.head], [0, EntryHash.origin]);
    });

    test('is Intact with the last entry as its head', () {
      addAll('step', 5);
      final bytes = entriesBytes();
      final check = driver.check() as Intact;
      expect(check.count, 5);
      expect(
        check.head,
        EntryHash.of(Uint8List.sublistView(bytes, bytes.length - 96)),
      );
    });

    test('breaks at the entry after one that was changed', () {
      addAll('step', 5);
      entries().writeAsBytesSync(entriesBytes()..[96 * 2 + 70] ^= 1);
      final check = driver.check() as Broken;
      expect(
        [check.entries, check.torn, check.missing],
        [
          [4],
          0,
          // The change was to entry 3's object id, which names no object.
          [3],
        ],
      );
    });

    test('names an entry whose object is gone, until it is stored again', () {
      addAll('step', 3);
      final gone = RecordEntry.parse(
        Uint8List.sublistView(entriesBytes(), 96, 96 * 2),
      )!.object;
      object(gone).deleteSync();
      final check = driver.check() as Broken;
      expect(
        [check.entries, check.torn, check.missing],
        [
          <int>[],
          0,
          [2],
        ],
      );

      // Stored, not added: writing it back is not something crossing.
      driver.store(bytesOf('step 1'));
      expect((driver.check() as Intact).count, 3);
    });

    test('takes the entry before the object, so a failed object is named', () {
      final objects = Directory('${dir.path}/objects')..createSync();
      Process.runSync('chmod', ['555', objects.path]);
      addTearDown(() => Process.runSync('chmod', ['755', objects.path]));
      expect(
        () => driver.add(bytesOf('cannot be kept')),
        throwsA(isA<FileSystemException>()),
      );
      final check = driver.check() as Broken;
      expect(
        [check.entries, check.missing],
        [
          <int>[],
          [1],
        ],
      );
    });

    test('still chains with entries cut from the end; only the head tells', () {
      addAll('step', 5);
      final head = (driver.check() as Intact).head;
      entries().writeAsBytesSync(entriesBytes().sublist(0, 96 * 3));
      final check = driver.check() as Intact;
      expect(check.count, 3);
      expect(check.head, isNot(head));
    });

    test('reports a torn tail, then its padded entry, and checks past it', () {
      addAll('before', 3);
      entries().writeAsBytesSync(entriesBytes().sublist(0, 96 * 2 + 50));
      var check = driver.check() as Broken;
      expect(
        [check.entries, check.torn, check.missing],
        [<int>[], 50, <int>[]],
      );

      // Padded with zeros, entry 3 still names entry 2, but its object id
      // was cut short and names nothing.
      addAll('after', 3);
      check = driver.check() as Broken;
      expect(
        [check.entries, check.torn, check.missing],
        [
          <int>[],
          0,
          [3],
        ],
      );

      entries().writeAsBytesSync(entriesBytes()..[96 * 4 + 70] ^= 1);
      check = driver.check() as Broken;
      expect(
        [check.entries, check.missing],
        [
          [6],
          [3, 5],
        ],
      );
    });

    test("the README's bash finds what check() finds", () {
      final script = readmeBlock('directory, in bash:');
      addAll('step', 5);
      expect(
        bash(script, dir).trim(),
        '5 entries, head ${(driver.check() as Intact).head.hex}',
      );

      entries().writeAsBytesSync(entriesBytes()..[96 + 70] ^= 1);
      final check = driver.check() as Broken;
      expect(bashFinds(script, dir), [check.entries, check.missing, 0]);
      expect(
        [check.entries, check.missing],
        [
          [3],
          [2],
        ],
      );
    });

    test("the README's bash finds what check() finds at a torn entry", () {
      final script = readmeBlock('directory, in bash:');
      addAll('before', 3);
      entries().writeAsBytesSync(entriesBytes().sublist(0, 96 * 2 + 50));
      var check = driver.check() as Broken;
      expect(bashFinds(script, dir), [check.entries, check.missing, 50]);

      addAll('after', 2);
      check = driver.check() as Broken;
      expect(bashFinds(script, dir), [check.entries, check.missing, 0]);
      expect(check.missing, [3]);
    });
  });
}

/// What the README's bash [script] finds: the entries it says are broken,
/// those it says have no object, as [Broken.entries] and [Broken.missing]
/// number them, and the bytes after the last whole entry ([Broken.torn]).
List<Object> bashFinds(String script, Directory dir) {
  final printed = bash(script, dir);
  List<int> numbered(String says) =>
      RegExp('entry (\\d+)$says')
          .allMatches(printed)
          .map((m) => int.parse(m[1]!))
          .toList();
  final torn = RegExp(r'(\d+) bytes after the last whole entry')
      .firstMatch(printed);
  return [
    numbered(' is broken'),
    numbered("'s object is missing"),
    torn == null ? 0 : int.parse(torn[1]!),
  ];
}
