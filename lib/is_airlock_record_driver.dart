/// The record driver: the one driver whose effects the airlock does not
/// decide, since deciding them would need a record of their own. It keeps
/// two things in one directory and only ever adds to them.
///
/// OBJECTS, `objects/<2>/<62>`: bytes named by their sha256 ([ObjectId]),
/// written when that name is absent or no longer holds them, and checked
/// against it whenever they are read. The same bytes are the same object
/// whichever home or driver wrote them, so two stores merge by copying each
/// other's objects in.
///
/// THE ENTRIES, `entries`: one for each [RecordDriver.put], that is, each
/// time bytes are about to leave, whether or not they are already stored.
/// Each is added before its object. An entry is 97 bytes ([RecordEntry]):
/// the hash of the entry before it, this driver's own hash, the object's id,
/// and a byte saying whether the person approved that hash. An entry that is
/// changed or removed breaks the chain at the entry after it
/// ([RecordDriver.check]). The chain is a checksum against damage and drift,
/// not proof against someone set on editing it: entries cut from the end
/// leave a shorter record that still chains, and sha256 has no secret, so
/// whoever can write the file can recompute it.
///
/// ONE WRITER: [RecordDriver.open] claims the directory for its process by
/// creating `writer.<pid>` there only if it is absent, so no second driver
/// in the same process, in any isolate, can open it until
/// [RecordDriver.close]. Dart has no append that cannot overwrite, and two
/// writers in one process would write over each other's entries. Processes
/// take turns at each entry through a lock on `entries`.
///
/// THE DRIVER'S HASH is the sha256 of what `shasum -a 256` prints for this
/// package's `lib/` files, so the person can compute it without running this
/// code, from the package's root:
///
///     (cd lib && find . -type f -name '*.dart' -print0 |
///       LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256)
///
/// The hash they approve goes in the `approved` file beside the record. This
/// driver reads that file and never writes it.
///
/// It imports only `dart:io`, `dart:isolate`, `dart:typed_data` and
/// `content_id.dart` beside it, which holds the sha256 every name is made
/// with. No package: everything it imports is part of what the person
/// checks, and a package's code is outside the hash. An import added here
/// changes the hash like any other edit, so the person sees it.
/// Everything is synchronous: a caller records what it is about to do before
/// it does it, and one write must not interleave with another.
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'content_id.dart';

export 'content_id.dart';

/// A name `shasum` prints as it is: printable ASCII with no backslash.
final _plainName = RegExp(r'^[\x20-\x5b\x5d-\x7e]+$');

/// Whether the driver that wrote an entry was the one the person approved.
/// Its byte ends the entry, and neither is zero, so an entry torn and padded
/// with zeros never reads as either.
enum Review {
  approved(0x41), // 'A'
  unreviewed(0x55); // 'U'

  const Review(this.byte);
  final int byte;

  /// The review [byte] stands for; null for any other byte.
  static Review? fromByte(int byte) {
    for (final r in values) {
      if (r.byte == byte) return r;
    }
    return null;
  }
}

/// One entry of the record: `previous │ driver │ object │ review`, 32 + 32 +
/// 32 + 1 bytes. The review byte is last, so an entry torn anywhere is
/// missing it.
final class RecordEntry {
  const RecordEntry(this.previous, this.driver, this.object, this.review);

  /// An entry's length in bytes.
  static const length = 97;

  final EntryHash previous;
  final DriverHash driver;
  final ObjectId object;
  final Review review;

  /// [bytes] as an entry, read back; null unless they are [length] bytes
  /// ending in a review byte.
  static RecordEntry? parse(Uint8List bytes) {
    if (bytes.length != length) return null;
    return switch ((
      EntryHash.fromDigest(Uint8List.sublistView(bytes, 0, 32)),
      DriverHash.fromDigest(Uint8List.sublistView(bytes, 32, 64)),
      ObjectId.fromDigest(Uint8List.sublistView(bytes, 64, 96)),
      Review.fromByte(bytes[96]),
    )) {
      (final p?, final d?, final o?, final r?) => RecordEntry(p, d, o, r),
      _ => null,
    };
  }

  /// The entry's [length] bytes, as the record keeps them.
  Uint8List encode() => Uint8List(length)
    ..setAll(0, previous.bytes)
    ..setAll(32, driver.bytes)
    ..setAll(64, object.bytes)
    ..[96] = review.byte;
}

/// What [RecordDriver.check] found.
sealed class RecordCheck {
  const RecordCheck();
}

/// There is no record: nothing was written here, or the record was removed.
final class NoRecord extends RecordCheck {
  const NoRecord();
}

/// Every one of [count] entries names the entry before it. [head] is the
/// last entry's hash ([EntryHash.origin] when there are none). Entries cut
/// from the end leave a record that is still intact.
final class Intact extends RecordCheck {
  const Intact(this.count, this.head);
  final int count;
  final EntryHash head;
}

/// The [entries], numbered from 1, that do not parse or do not name the
/// entry before them: all of them, since checking goes on past a break,
/// each entry against the bytes before it as they are. [torn] counts the
/// bytes after the last whole entry, left by a write a crash cut short.
final class Broken extends RecordCheck {
  const Broken(this.entries, this.torn);
  final List<int> entries;
  final int torn;
}

/// Stored bytes that no longer hash to their name: torn, edited or damaged.
/// [RecordDriver.get] throws it; a [RecordDriver.put] of the bytes the name
/// stands for writes them again.
final class CorruptObject implements Exception {
  const CorruptObject(this.id);
  final ObjectId id;

  @override
  String toString() => 'CorruptObject: ${id.hex} does not hash to its name';
}

final class RecordDriver {
  RecordDriver._(this.dir, this.hash, this._writer);

  /// Holds `objects/`, `entries`, `approved` and, while a driver has it open,
  /// `writer.<pid>`.
  final Directory dir;

  /// This driver's own hash, computed from its source when it opened.
  final DriverHash hash;

  /// This driver's claim on [dir], deleted by [close].
  final File _writer;
  var _open = true;

  /// A record driver writing into [dir], which it claims for this process
  /// until [close] (see the library comment). Throws a [StateError] when
  /// [dir] is already claimed by this process; any other failure to claim it,
  /// such as a folder it cannot write, throws as itself. Null when the driver cannot
  /// name itself the way the library comment does ([ownHash]): every entry
  /// names the driver that wrote it, and a driver that cannot name itself
  /// writes none.
  static RecordDriver? open(Directory dir) {
    final hash = ownHash();
    if (hash == null) return null;
    dir.createSync(recursive: true);
    final writer = File('${dir.path}/writer.$pid');
    try {
      writer.createSync(exclusive: true);
    } on PathExistsException {
      throw StateError(
        '${dir.path} is already open in this process. If no driver here has '
        'it open, a crashed process with the same id left ${writer.path}; '
        'delete it.',
      );
    }
    return RecordDriver._(dir, hash, writer);
  }

  /// Gives up this driver's claim on [dir], so another driver in this
  /// process can open it. This driver writes nothing after.
  void close() {
    if (!_open) return;
    _open = false;
    _writer.deleteSync();
  }

  /// The hash of this package's `lib/` as the library comment computes it.
  /// Null when it cannot be computed exactly that way: the source is not on
  /// disk, as in a compiled build; `lib/` holds a link, which `find` and this
  /// code would walk differently; or a file's name is one `shasum` would
  /// print differently from how it is written.
  static DriverHash? ownHash() {
    final entry = Isolate.resolvePackageUriSync(
      Uri.parse(
        'package:is_airlock_record_driver/is_airlock_record_driver.dart',
      ),
    );
    if (entry == null || !entry.isScheme('file')) return null;
    final lib = File.fromUri(entry).parent.path;
    final names = <String>[];
    for (final f in Directory(
      lib,
    ).listSync(recursive: true, followLinks: false)) {
      if (f is Link) return null;
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final name =
          '.${f.path.substring(lib.length).replaceAll(Platform.pathSeparator, '/')}';
      if (!_plainName.hasMatch(name)) return null;
      names.add(name);
    }
    names.sort();
    final listing = StringBuffer();
    for (final name in names) {
      final bytes = File('$lib${name.substring(1)}').readAsBytesSync();
      listing.write('${ObjectId.of(bytes).hex}  $name\n');
    }
    // Every name is ASCII, so its code units are its bytes.
    return DriverHash.of(Uint8List.fromList(listing.toString().codeUnits));
  }

  /// Whether this driver is the one in `approved`, read at every entry so an
  /// approval counts from the next entry on. Only the file's first word is
  /// read, so the line `shasum` prints (`<hash>  -`) can go in as it is.
  Review get review {
    final file = File('${dir.path}/approved');
    if (!file.existsSync()) return Review.unreviewed;
    final first = file.readAsStringSync().trim().split(RegExp(r'\s+')).first;
    return DriverHash.parse(first) == hash
        ? Review.approved
        : Review.unreviewed;
  }

  File _object(ObjectId id) => File(
    '${dir.path}/objects/${id.hex.substring(0, 2)}/${id.hex.substring(2)}',
  );

  /// Records that [bytes] are about to leave, keeps them, and returns their
  /// id. Every call adds an entry, so the same bytes sent twice are recorded
  /// twice. The entry goes in before the object: a crash between the two
  /// leaves an entry naming an object that never arrived, never an object no
  /// entry names. The object is written when it is absent or no longer holds
  /// these bytes; the temporary file is named for this process, which no
  /// other driver shares.
  ObjectId put(Uint8List bytes) {
    if (!_open) throw StateError('this driver is closed');
    final id = ObjectId.of(bytes);
    _record(id);
    final file = _object(id);
    if (file.existsSync() && ObjectId.of(file.readAsBytesSync()) == id) {
      return id;
    }
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.$pid.tmp');
    tmp.writeAsBytesSync(bytes, flush: true);
    tmp.renameSync(file.path);
    return id;
  }

  /// The bytes named [id], or null when they are not here. Throws
  /// [CorruptObject] when they no longer hash to [id].
  Uint8List? get(ObjectId id) {
    final file = _object(id);
    if (!file.existsSync()) return null;
    final bytes = file.readAsBytesSync();
    if (ObjectId.of(bytes) != id) throw CorruptObject(id);
    return bytes;
  }

  void _record(ObjectId object) {
    dir.createSync(recursive: true);
    // Locked, so another process writing here chains from this entry rather
    // than from the same one. Closing the file releases the lock.
    final f = File('${dir.path}/entries').openSync(mode: FileMode.append);
    try {
      f.lockSync(FileLock.blockingExclusive);
      final previous = _lastEntry(f);
      final entry = RecordEntry(previous, hash, object, review);
      f.setPositionSync(f.lengthSync());
      f.writeFromSync(entry.encode());
      f.flushSync();
    } finally {
      f.closeSync();
    }
  }

  /// The hash of [f]'s last entry. A tail shorter than an entry was torn by
  /// a crash: it is padded with zeros to a whole entry, which cannot parse
  /// since its review byte is zero, and chained from as it is, so [check]
  /// reports it rather than the record losing it.
  EntryHash _lastEntry(RandomAccessFile f) {
    var length = f.lengthSync();
    final torn = length % RecordEntry.length;
    if (torn != 0) {
      f.setPositionSync(length);
      f.writeFromSync(Uint8List(RecordEntry.length - torn));
      length += RecordEntry.length - torn;
    }
    if (length == 0) return EntryHash.origin;
    f.setPositionSync(length - RecordEntry.length);
    return EntryHash.of(f.readSync(RecordEntry.length));
  }

  /// Every entry checked against the one before it.
  RecordCheck check() {
    final file = File('${dir.path}/entries');
    if (!file.existsSync()) return const NoRecord();
    final bytes = file.readAsBytesSync();
    final broken = <int>[];
    var previous = EntryHash.origin;
    var at = 0;
    for (; at + RecordEntry.length <= bytes.length; at += RecordEntry.length) {
      final raw = Uint8List.sublistView(bytes, at, at + RecordEntry.length);
      final entry = RecordEntry.parse(raw);
      if (entry == null || entry.previous != previous) {
        broken.add(at ~/ RecordEntry.length + 1);
      }
      previous = EntryHash.of(raw);
    }
    final torn = bytes.length - at;
    return broken.isEmpty && torn == 0
        ? Intact(at ~/ RecordEntry.length, previous)
        : Broken(broken, torn);
  }
}
