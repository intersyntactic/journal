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
  void putAll(String prefix, int n) {
    for (var i = 0; i < n; i++) {
      driver.put(bytesOf('$prefix $i'));
    }
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('record_test');
    driver = RecordDriver.open(dir)!;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  group('sha256', () {
    test('gives the FIPS 180-4 examples', () {
      String sha(Uint8List b) => ObjectId.of(b).hex;
      expect(
        sha(bytesOf('')),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(
        sha(bytesOf('abc')),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      expect(
        sha(
          bytesOf('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
        ),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
      expect(
        sha(Uint8List(1000000)..fillRange(0, 1000000, 0x61)),
        'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
      );
    });

    test('agrees with shasum at every length across the block boundaries', () {
      final source = Uint8List.fromList([
        for (var i = 0; i < 130; i++) (i * 167 + 13) & 0xff,
      ]);
      for (var n = 0; n <= 130; n++) {
        File('${dir.path}/m$n').writeAsBytesSync(source.sublist(0, n));
      }
      final theirs = {
        for (final line in LineSplitter.split(bash('shasum -a 256 m*', dir)))
          line.substring(66): line.substring(0, 64),
      };
      for (var n = 0; n <= 130; n++) {
        expect(
          ObjectId.of(source.sublist(0, n)).hex,
          theirs['m$n'],
          reason: '$n bytes',
        );
      }
    });
  });

  group('names', () {
    test('parse takes only a lower-case hex sha256', () {
      final hex = ObjectId.of(bytesOf('x')).hex;
      expect(ObjectId.parse(hex)?.hex, hex);
      expect(ObjectId.parse(hex.toUpperCase()), isNull);
      expect(ObjectId.parse(hex.substring(1)), isNull);
      expect(ObjectId.parse('$hex\n'), isNull);
    });

    test('fromDigest takes only 32 bytes', () {
      expect(ObjectId.fromDigest(Uint8List(32)), isNotNull);
      expect(ObjectId.fromDigest(Uint8List(31)), isNull);
      expect(ObjectId.fromDigest(Uint8List(33)), isNull);
    });

    test('the same 32 bytes as two kinds of name are not equal', () {
      final digest = ObjectId.of(bytesOf('x')).bytes;
      expect(ObjectId.fromDigest(digest), isNot(EntryHash.fromDigest(digest)));
      expect(ObjectId.fromDigest(digest), ObjectId.of(bytesOf('x')));
    });

    test("the record's origin is the sha256 of its format's name", () {
      final printed = bash(
        "printf 'is_airlock_record_driver/1' | shasum -a 256",
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
    test('come back as they went in; sent twice, one object, two entries', () {
      final id = driver.put(bytesOf('what went up'));
      expect(driver.get(id), bytesOf('what went up'));
      expect(driver.put(bytesOf('what went up')), id);
      expect(entriesBytes().length, 2 * RecordEntry.length);
      final objects = Directory('${dir.path}/objects')
          .listSync(recursive: true);
      expect(objects.whereType<File>().length, 1);
    });

    test('that no longer hash to their name throw, until put again', () {
      final id = driver.put(bytesOf('what went up'));
      File(
        '${dir.path}/objects/${id.hex.substring(0, 2)}/${id.hex.substring(2)}',
      ).writeAsStringSync('edited');
      expect(() => driver.get(id), throwsA(isA<CorruptObject>()));
      driver.put(bytesOf('what went up'));
      expect(driver.get(id), bytesOf('what went up'));
    });
  });

  group('one writer', () {
    test('a second open in this process throws until the first closes', () {
      expect(() => RecordDriver.open(dir), throwsStateError);
      driver.close();
      RecordDriver.open(dir)!
        ..put(bytesOf('after'))
        ..close();
      expect(driver.check(), isA<Intact>());
    });

    test('another isolate in this process cannot open it', () async {
      await expectLater(openInAnotherIsolate(dir.path), throwsStateError);
    });

    test('a closed driver writes nothing', () {
      driver.close();
      expect(() => driver.put(bytesOf('late')), throwsStateError);
      expect(entries().existsSync(), isFalse);
    });
  });

  group('the record', () {
    test('holds one 97-byte entry per object, its review byte last', () {
      final id = driver.put(bytesOf('one'));
      final entry = RecordEntry.parse(entriesBytes())!;
      expect(entry.previous, EntryHash.origin);
      expect(entry.driver, driver.hash);
      expect(entry.object, id);
      expect(entry.review, Review.unreviewed);
      expect(entriesBytes().last, 0x55);
    });

    test('says approved from the entry after the shasum line goes in', () {
      driver.put(bytesOf('before'));
      File('${dir.path}/approved').writeAsStringSync('${driver.hash.hex}  -\n');
      driver.put(bytesOf('after'));
      final bytes = entriesBytes();
      expect([bytes[96], bytes[193]], [0x55, 0x41]);
    });

    test('says unreviewed for any other hash in approved', () {
      File('${dir.path}/approved')
          .writeAsStringSync(ObjectId.of(bytesOf('another driver')).hex);
      driver.put(bytesOf('one'));
      expect(entriesBytes().last, 0x55);
    });

    test('is NoRecord before anything is written, Intact when empty', () {
      expect(driver.check(), isA<NoRecord>());
      entries().writeAsBytesSync(const []);
      final check = driver.check() as Intact;
      expect([check.count, check.head], [0, EntryHash.origin]);
    });

    test('is Intact with the last entry as its head', () {
      putAll('step', 5);
      final bytes = entriesBytes();
      final check = driver.check() as Intact;
      expect(check.count, 5);
      expect(
        check.head,
        EntryHash.of(Uint8List.sublistView(bytes, bytes.length - 97)),
      );
    });

    test('breaks at the entry after one that was changed', () {
      putAll('step', 5);
      entries().writeAsBytesSync(entriesBytes()..[97 * 2 + 70] ^= 1);
      final check = driver.check() as Broken;
      expect(
        [check.entries, check.torn],
        [
          [4],
          0,
        ],
      );
    });

    test('still chains with entries cut from the end; only the head tells', () {
      putAll('step', 5);
      final head = (driver.check() as Intact).head;
      entries().writeAsBytesSync(entriesBytes().sublist(0, 97 * 3));
      final check = driver.check() as Intact;
      expect(check.count, 3);
      expect(check.head, isNot(head));
    });

    test('reports a torn tail, then its padded entry, and checks past it', () {
      putAll('before', 3);
      entries().writeAsBytesSync(entriesBytes().sublist(0, 97 * 2 + 50));
      var check = driver.check() as Broken;
      expect([check.entries, check.torn], [<int>[], 50]);

      putAll('after', 3);
      check = driver.check() as Broken;
      expect(
        [check.entries, check.torn],
        [
          [3],
          0,
        ],
      );

      entries().writeAsBytesSync(entriesBytes()..[97 * 4 + 70] ^= 1);
      check = driver.check() as Broken;
      expect(check.entries, [3, 6]);
    });

    test("the README's bash finds what check() finds", () {
      final script = readmeBlock('directory, in bash:');
      putAll('step', 5);
      expect(
        bash(script, dir).trim(),
        '5 entries, head ${(driver.check() as Intact).head.hex}',
      );

      entries().writeAsBytesSync(entriesBytes()..[97 + 70] ^= 1);
      final broken = RegExp(r'entry (\d+) is broken')
          .allMatches(bash(script, dir))
          .map((m) => int.parse(m[1]!))
          .toList();
      expect(broken, (driver.check() as Broken).entries);
      expect(broken, [3]);
    });
  });
}
