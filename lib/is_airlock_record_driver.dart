/// The record driver: the one driver whose effects the airlock does not
/// decide, since deciding them would need a record of their own. It keeps
/// two things in one directory and only ever adds to them.
///
/// OBJECTS, `objects/<2>/<62>`: bytes named by their sha256 ([ObjectId]),
/// kept by [RecordDriver.add] with an entry or [RecordDriver.store] without
/// one, written when that name is absent or no longer holds them, and
/// checked against it whenever they are read. The same bytes are the same
/// object whichever home or driver wrote them, so two stores merge by
/// copying each other's objects in.
///
/// THE ENTRIES, `entries`: one for each [RecordDriver.add], that is, each
/// time a caller records bytes before it acts on them (sends, reads or
/// decides them), whether or not they are already stored. An entry says
/// nothing of what the bytes are: whether they went out, came in or were
/// refused is for the caller to write into them. Each is added before its
/// object. An entry is three names, 96 bytes ([RecordEntry]): the entry
/// before it, this driver's code and the object. An entry that is changed or
/// removed breaks the chain at the entry after it, and an entry whose object
/// is not here is named too ([RecordDriver.check]). The chain is a checksum
/// against damage and drift, not proof against someone set on editing it:
/// entries cut from the end leave a shorter record that still chains, and
/// sha256 has no secret, so whoever can write the file can recompute it. So
/// run what the record watches as a user that can write neither this
/// directory, this driver's code nor `approved`, in a process that cannot
/// reload this driver: a driver reloaded in place keeps the
/// [RecordDriver.hash] it opened with.
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
/// The hashes they approve go in the `approved` file beside the record, and
/// whether an entry came from code they checked is read from it whenever
/// the record is read ([RecordDriver.approved]), never written into the
/// entry. This driver reads that file and never writes it.
///
/// It imports `dart:io`, `dart:isolate`, `dart:typed_data` and
/// `is_content_id`, which holds the sha256 every name is made with and
/// [ObjectId]. The driver's hash names this package's own code only:
/// `is_content_id` comes from pub.dev, and an app's `pubspec.lock` records
/// the version it resolved and the sha256 of that version's archive.
/// An import added here changes the hash like any other edit, so the person
/// sees it.
/// Everything is synchronous: a caller records what it is about to do before
/// it does it, and one write must not interleave with another.
library;

import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:is_content_id/is_content_id.dart';

export 'package:is_content_id/is_content_id.dart';

/// A name `shasum` prints as it is: printable ASCII with no backslash.
final _plainName = RegExp(r'^[\x20-\x5b\x5d-\x7e]+$');

/// The sha256 of one record entry.
final class EntryHash extends Sha256Name {
  EntryHash._(super.digest);

  /// [entry]'s hash.
  factory EntryHash.of(Uint8List entry) => EntryHash._(sha256(entry));

  static EntryHash? parse(String s) => switch (Sha256Name.digestOfHex(s)) {
    final d? => EntryHash._(d),
    null => null,
  };

  static EntryHash? fromDigest(Uint8List digest) =>
      digest.length == 32 ? EntryHash._(digest) : null;

  /// What the first entry names as the entry before it: the sha256 of the
  /// record format's name, so a record in another format breaks at its first
  /// entry, and anyone can compute it with
  /// `printf 'is_airlock_record_driver/2' | shasum -a 256`. Format 1 ended
  /// each entry with a review byte.
  static final origin = EntryHash.of(
    Uint8List.fromList('is_airlock_record_driver/2'.codeUnits),
  );
}

/// The sha256 of a record driver's own code: of the listing `shasum -a 256`
/// prints for its `lib/` files.
final class DriverHash extends Sha256Name {
  DriverHash._(super.digest);

  /// The hash of [listing].
  factory DriverHash.of(Uint8List listing) => DriverHash._(sha256(listing));

  static DriverHash? parse(String s) => switch (Sha256Name.digestOfHex(s)) {
    final d? => DriverHash._(d),
    null => null,
  };

  static DriverHash? fromDigest(Uint8List digest) =>
      digest.length == 32 ? DriverHash._(digest) : null;
}

/// One entry of the record, three names: `previous │ driver │ object`, 32
/// bytes each. Whether the person approved [driver] is not in it: that is
/// read from `approved` whenever the record is read
/// ([RecordDriver.approved]), so approving a hash covers what it already
/// wrote and removing it takes that back.
final class RecordEntry {
  const RecordEntry(this.previous, this.driver, this.object);

  /// An entry's length in bytes.
  static const length = 96;

  final EntryHash previous;
  final DriverHash driver;
  final ObjectId object;

  /// [bytes] as an entry, read back; null unless they are [length] bytes.
  static RecordEntry? parse(Uint8List bytes) {
    if (bytes.length != length) return null;
    return switch ((
      EntryHash.fromDigest(Uint8List.sublistView(bytes, 0, 32)),
      DriverHash.fromDigest(Uint8List.sublistView(bytes, 32, 64)),
      ObjectId.fromDigest(Uint8List.sublistView(bytes, 64, 96)),
    )) {
      (final p?, final d?, final o?) => RecordEntry(p, d, o),
      _ => null,
    };
  }

  /// The entry's [length] bytes, as the record keeps them.
  Uint8List encode() => Uint8List(length)
    ..setAll(0, previous.bytes)
    ..setAll(32, driver.bytes)
    ..setAll(64, object.bytes);
}

/// What [RecordDriver.check] found.
sealed class RecordCheck {
  const RecordCheck();
}

/// There is no record: nothing was written here, or the record was removed.
final class NoRecord extends RecordCheck {
  const NoRecord();
}

/// Every one of [count] entries names the entry before it, and an object
/// that is here. [head] is the last entry's hash ([EntryHash.origin] when
/// there are none). Entries cut from the end leave a record that is still
/// intact.
final class Intact extends RecordCheck {
  const Intact(this.count, this.head);
  final int count;
  final EntryHash head;
}

/// The [entries], numbered from 1, that do not name the entry before them:
/// all of them, since checking goes on past a break, each entry against the
/// bytes before it as they are. [torn] counts the bytes after the last whole
/// entry, left by a write a crash cut short. [missing] numbers the entries
/// whose object is not in `objects/`: a crash between an entry and its
/// object, an object removed since, an [RecordDriver.add] still under way
/// in another process, or a torn entry padded with zeros, whose object id
/// was cut short. [RecordDriver.store] of those bytes writes the object back
/// without adding an entry.
final class Broken extends RecordCheck {
  const Broken(this.entries, this.torn, this.missing);
  final List<int> entries;
  final int torn;
  final List<int> missing;
}

/// Stored bytes that no longer hash to their name: torn, edited or damaged.
/// [RecordDriver.get] throws it; [RecordDriver.store] of the bytes the name
/// stands for writes them back.
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

  /// The driver hashes the person has approved: the first word of each line
  /// of `approved`, so the line `shasum` prints (`<hash>  -`) goes in as it
  /// is, and the rest of a line is theirs. Read each time it is asked: an
  /// entry came from code they checked when its [RecordEntry.driver] is here.
  Set<DriverHash> approved() {
    final file = File('${dir.path}/approved');
    if (!file.existsSync()) return const {};
    return {
      for (final line in file.readAsLinesSync())
        ?DriverHash.parse(line.trim().split(RegExp(r'\s+')).first),
    };
  }

  File _object(ObjectId id) => File(
    '${dir.path}/objects/${id.hex.substring(0, 2)}/${id.hex.substring(2)}',
  );

  /// Adds an entry naming [bytes], keeps them, and returns their id. A
  /// caller adds what it is about to act on before it acts. Every call adds
  /// an entry, so the same bytes added twice have two entries. The entry goes
  /// in before the object: a crash between the two leaves an entry naming an
  /// object that never arrived, which [check] reports, never bytes kept with
  /// no entry to say they were about to be acted on.
  ObjectId add(Uint8List bytes) {
    if (!_open) throw StateError('this driver is closed');
    final id = ObjectId.of(bytes);
    _enter(id);
    _keep(id, bytes);
    return id;
  }

  /// Keeps [bytes] without an entry and returns their id: the pieces of
  /// something added. A request that resends a whole conversation is kept as
  /// its pieces, each once, and one entry is added for the bytes that say how
  /// they join. [check] does not read inside those bytes, so a missing piece
  /// shows when it is read ([get]). Also how an object that is missing or
  /// damaged is written back, without an entry for something that did not
  /// happen.
  ObjectId store(Uint8List bytes) {
    if (!_open) throw StateError('this driver is closed');
    final id = ObjectId.of(bytes);
    _keep(id, bytes);
    return id;
  }

  /// Writes [bytes] as [id] when that name is absent or no longer holds them.
  /// The temporary file is named for this process, which no other driver
  /// shares.
  void _keep(ObjectId id, Uint8List bytes) {
    final file = _object(id);
    if (file.existsSync() && ObjectId.of(file.readAsBytesSync()) == id) return;
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.$pid.tmp');
    tmp.writeAsBytesSync(bytes, flush: true);
    tmp.renameSync(file.path);
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

  void _enter(ObjectId object) {
    dir.createSync(recursive: true);
    // Locked, so another process writing here chains from this entry rather
    // than from the same one. Closing the file releases the lock.
    final f = File('${dir.path}/entries').openSync(mode: FileMode.append);
    try {
      f.lockSync(FileLock.blockingExclusive);
      final previous = _lastEntry(f);
      final entry = RecordEntry(previous, hash, object);
      f.setPositionSync(f.lengthSync());
      f.writeFromSync(entry.encode());
      f.flushSync();
    } finally {
      f.closeSync();
    }
  }

  /// The hash of [f]'s last entry. A tail shorter than an entry was torn by
  /// a crash: it is padded with zeros to a whole entry and chained from as it
  /// is, so [check] reports it rather than the record losing it. Its object
  /// id, cut short and padded, names no object here unless the zeros
  /// completed it, and then the entry is the one that was being written.
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

  /// Every entry checked against the one before it, and for whether the
  /// object it names is here. Not whether that object still holds its bytes:
  /// that reads every byte ever sent, and [get] checks it on each read.
  RecordCheck check() {
    final file = File('${dir.path}/entries');
    if (!file.existsSync()) return const NoRecord();
    final bytes = file.readAsBytesSync();
    final broken = <int>[];
    final missing = <int>[];
    final here = <ObjectId, bool>{};
    var previous = EntryHash.origin;
    var at = 0;
    for (; at + RecordEntry.length <= bytes.length; at += RecordEntry.length) {
      final n = at ~/ RecordEntry.length + 1;
      final raw = Uint8List.sublistView(bytes, at, at + RecordEntry.length);
      final entry = RecordEntry.parse(raw)!;
      if (entry.previous != previous) broken.add(n);
      if (!here.putIfAbsent(
        entry.object,
        () => _object(entry.object).existsSync(),
      )) {
        missing.add(n);
      }
      previous = EntryHash.of(raw);
    }
    final torn = bytes.length - at;
    return broken.isEmpty && torn == 0 && missing.isEmpty
        ? Intact(at ~/ RecordEntry.length, previous)
        : Broken(broken, torn, missing);
  }
}
