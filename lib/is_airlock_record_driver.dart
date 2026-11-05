/// The record driver: the one driver whose effects the airlock does not
/// decide, since deciding them would need a record of their own. It keeps
/// two things in one directory and only ever adds to them.
///
/// OBJECTS, `objects/<2>/<62>`: bytes named by their sha256, written only if
/// that name is absent and checked against it whenever they are read. The
/// same bytes are the same object whichever home or driver wrote them, so two
/// stores merge by copying each other's objects in.
///
/// THE RECORD, `record`: one line for each object this driver writes, added
/// before the object is. A line holds the hash of the line before it, this
/// driver's own hash, whether the person approved that hash, and the object's
/// id. A line that is changed or removed breaks the chain at the line after
/// it ([RecordDriver.firstBrokenLine]).
///
/// THE DRIVER'S HASH is the sha256 of what `shasum -a 256` prints for this
/// package's `lib/` files, so the person can compute it without running this
/// code, from the package's root:
///
///     cd lib &&
///       find . -name '*.dart' | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256
///
/// The hash they approve goes in the `approved` file beside the record. This
/// driver reads that file and never writes it.
///
/// It imports only `dart:io`, `dart:isolate` and `package:crypto`, because
/// everything it imports is part of what the person checks. An import added
/// here changes the hash like any other edit, so the person sees it.
/// Everything is synchronous: a caller records what it is about to do before
/// it does it, and one write must not interleave with another.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

final _sha256Hex = RegExp(r'^[0-9a-f]{64}$');

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

/// A sha256 in lower-case hex. Each kind below is made only by this library:
/// from bytes it hashes, or by `parse` where a name is read back, so code
/// holding one never asks whether it is valid. Classes, not extension types,
/// since a `String` can be cast to an extension type and skip both.
abstract final class _Digest {
  const _Digest(this.hex);
  final String hex;

  @override
  bool operator ==(Object other) =>
      other is _Digest && other.runtimeType == runtimeType && other.hex == hex;

  @override
  int get hashCode => hex.hashCode;

  @override
  String toString() => hex;
}

/// An object's name: the sha256 of its bytes.
final class ObjectId extends _Digest {
  const ObjectId._(super.hex);

  /// The id [bytes] are stored under.
  factory ObjectId.of(List<int> bytes) => ObjectId._(_sha(bytes));

  /// [s] as an id, read back; null when it is not a sha256 in hex.
  static ObjectId? parse(String s) =>
      _sha256Hex.hasMatch(s) ? ObjectId._(s) : null;
}

/// The sha256 of a record driver's own code (see the library comment).
final class DriverHash extends _Digest {
  const DriverHash._(super.hex);

  static DriverHash? parse(String s) =>
      _sha256Hex.hasMatch(s) ? DriverHash._(s) : null;
}

/// The sha256 of one record line and its newline.
final class LineHash extends _Digest {
  const LineHash._(super.hex);

  /// [line]'s hash.
  factory LineHash.of(String line) => LineHash._(_sha('$line\n'.codeUnits));

  static LineHash? parse(String s) =>
      _sha256Hex.hasMatch(s) ? LineHash._(s) : null;

  /// What the first line names as the line before it.
  static final origin = LineHash._('0' * 64);
}

/// Whether the driver that wrote a line was the one the person approved.
enum Review {
  approved,
  unreviewed;

  static Review? parse(String s) {
    for (final r in values) {
      if (r.name == s) return r;
    }
    return null;
  }
}

/// One line of the record: `<previous> <driver> <review> <object>`.
final class RecordLine {
  const RecordLine(this.previous, this.driver, this.review, this.object);

  final LineHash previous;
  final DriverHash driver;
  final Review review;
  final ObjectId object;

  static RecordLine? parse(String line) => switch (line.split(' ')) {
    [final p, final d, final r, final o] => switch ((
      LineHash.parse(p),
      DriverHash.parse(d),
      Review.parse(r),
      ObjectId.parse(o),
    )) {
      (final p?, final d?, final r?, final o?) => RecordLine(p, d, r, o),
      _ => null,
    },
    _ => null,
  };

  @override
  String toString() =>
      '${previous.hex} ${driver.hex} ${review.name} ${object.hex}';
}

/// Stored bytes that no longer hash to their name: torn, edited or damaged.
/// Never repaired: the bytes the name stood for are gone.
final class CorruptObject implements Exception {
  const CorruptObject(this.id);
  final ObjectId id;

  @override
  String toString() => 'CorruptObject: ${id.hex} does not hash to its name';
}

final class RecordDriver {
  RecordDriver._(this.dir, this.hash);

  /// Holds `objects/`, `record` and `approved`.
  final Directory dir;

  /// This driver's own hash, computed from its source when it opened.
  final DriverHash hash;

  /// A record driver writing into [dir]. Null when it cannot find its own
  /// source to hash, as in a compiled build: every line names the driver
  /// that wrote it, and a driver that cannot name itself writes none.
  static RecordDriver? open(Directory dir) => switch (ownHash()) {
    final hash? => RecordDriver._(dir, hash),
    null => null,
  };

  /// The hash of this package's `lib/` as the library comment computes it,
  /// or null when its source is not on disk.
  static DriverHash? ownHash() {
    final entry = Isolate.resolvePackageUriSync(
      Uri.parse(
        'package:is_airlock_record_driver/is_airlock_record_driver.dart',
      ),
    );
    if (entry == null || !entry.isScheme('file')) return null;
    final lib = File.fromUri(entry).parent.path;
    final names = [
      for (final f in Directory(lib).listSync(recursive: true))
        if (f is File && f.path.endsWith('.dart'))
          '.${f.path.substring(lib.length)}',
    ]..sort();
    final listing = StringBuffer();
    for (final name in names) {
      final bytes = File('$lib${name.substring(1)}').readAsBytesSync();
      listing.write('${_sha(bytes)}  $name\n');
    }
    return DriverHash._(_sha(listing.toString().codeUnits));
  }

  /// Whether this driver is the one in `approved`, read at every line so an
  /// approval counts from the next line on.
  Review get review {
    final file = File('${dir.path}/approved');
    if (!file.existsSync()) return Review.unreviewed;
    final approved = DriverHash.parse(file.readAsStringSync().trim());
    return approved == hash ? Review.approved : Review.unreviewed;
  }

  File _object(ObjectId id) => File(
    '${dir.path}/objects/${id.hex.substring(0, 2)}/${id.hex.substring(2)}',
  );

  /// Adds [bytes] and returns their id. Bytes already here are the same
  /// object, so nothing is written or recorded. Otherwise the line goes in
  /// first: a crash between the two leaves a line naming an object that never
  /// arrived, never an object no line names.
  ObjectId put(List<int> bytes) {
    final id = ObjectId.of(bytes);
    final file = _object(id);
    if (file.existsSync()) return id;
    _record(id);
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.$pid.tmp');
    tmp.writeAsBytesSync(bytes, flush: true);
    tmp.renameSync(file.path);
    return id;
  }

  /// The bytes named [id], or null when they are not here. Throws
  /// [CorruptObject] when they no longer hash to [id].
  List<int>? get(ObjectId id) {
    final file = _object(id);
    if (!file.existsSync()) return null;
    final bytes = file.readAsBytesSync();
    if (ObjectId.of(bytes) != id) throw CorruptObject(id);
    return bytes;
  }

  void _record(ObjectId object) {
    dir.createSync(recursive: true);
    // Locked, so another process writing here chains from this line rather
    // than from the same one. Closing the file releases the lock.
    final f = File('${dir.path}/record').openSync(mode: FileMode.append);
    try {
      f.lockSync(FileLock.blockingExclusive);
      final previous = _lastLine(f);
      final line = RecordLine(previous, hash, review, object);
      f.setPositionSync(f.lengthSync());
      f.writeFromSync('$line\n'.codeUnits);
      f.flushSync();
    } finally {
      f.closeSync();
    }
  }

  /// The hash of [f]'s last line. A last line with no newline was torn by a
  /// crash: it is ended where it stopped and chained from as it is, so
  /// [firstBrokenLine] finds it rather than the record losing it.
  LineHash _lastLine(RandomAccessFile f) {
    final length = f.lengthSync();
    if (length == 0) return LineHash.origin;
    final start = length > 4096 ? length - 4096 : 0;
    f.setPositionSync(start);
    var tail = String.fromCharCodes(f.readSync(length - start));
    if (!tail.endsWith('\n')) {
      f.setPositionSync(length);
      f.writeFromSync('\n'.codeUnits);
      tail += '\n';
    }
    final body = tail.substring(0, tail.length - 1);
    return LineHash.of(body.substring(body.lastIndexOf('\n') + 1));
  }

  /// The number, from 1, of the first line that does not parse or does not
  /// name the line before it; null when every line holds.
  int? firstBrokenLine() {
    final file = File('${dir.path}/record');
    if (!file.existsSync()) return null;
    final lines = String.fromCharCodes(file.readAsBytesSync()).split('\n');
    var previous = LineHash.origin;
    // A whole record ends in a newline, so its last piece is empty.
    for (var i = 0; i < lines.length - 1; i++) {
      final line = RecordLine.parse(lines[i]);
      if (line == null || line.previous != previous) return i + 1;
      previous = LineHash.of(lines[i]);
    }
    return lines.last.isEmpty ? null : lines.length;
  }
}
