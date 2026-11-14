/// A journal: an add-only record of bytes. Each entry is chained to the
/// entry before it and names the bytes and the hash of the code that wrote
/// it. It keeps two things in one directory and only ever adds to them.
///
/// OBJECTS, `objects/<2>/<62>`: bytes named by their sha256 ([ObjectId]),
/// kept whole, written when that name is absent or no longer holds them, and
/// checked against it whenever they are read. The same bytes are the same
/// object whichever journal wrote them, so two journals merge by copying
/// each other's objects in, and an object missing or damaged here is
/// restored by copying its file in from another copy of the journal.
///
/// THE ENTRIES, `entries`: one for each [Journal.add], even of bytes already
/// kept, each added before its object. An entry says nothing of what the
/// bytes are; that is for whoever adds them to write into them. An entry is
/// three names, 96 bytes ([JournalEntry]): the entry before it, the code
/// that wrote it ([Journal.codeHash]) and the object. An entry that is
/// changed or removed breaks the chain at the entry after it, and an entry
/// whose object
/// is not here is named too ([Journal.check]). The chain is a checksum
/// against damage and drift, not proof against someone set on editing it:
/// entries cut from the end leave a shorter journal that still chains, and
/// sha256 has no secret, so whoever can write the file can recompute it.
/// Whatever can write this directory, this package's code or `approved` can
/// change what the journal says, and the chain cannot tell. A journal whose
/// code is reloaded in place keeps the [Journal.codeHash] it opened with.
///
/// ONE WRITER: [Journal.open] claims the directory for its process by
/// creating `writer.<pid>` there only if it is absent, so no second journal
/// in the same process, in any isolate, can open it until [Journal.close].
/// Nor can a journal be sent to another isolate: sending copies it, and the
/// copy would write with no claim of its own. Dart has no append that cannot
/// overwrite, and two writers in one process would write over each other's
/// entries. Processes take turns at each entry
/// through a lock on `lock`, a file nothing else has a reason to open:
/// closing any descriptor on a file gives up every lock its process holds
/// on that file, so a lock on `entries` would end whenever anything in the
/// process read them.
///
/// THE CODE HASH is the [FileSetId] of this package's `lib/` files: the
/// sha256 of what `shasum -a 256` prints for them, so the person can compute
/// it without running this code, from the package's root:
///
///     (cd lib && find . -type f -name '*.dart' -print0 |
///       LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256)
///
/// A compiled build has no `lib/` to hash, so it is given the hash when it
/// is compiled, from the source the compiler reads:
///
///     dart compile exe $(dart run is_journal:code_hash) bin/main.dart
///
/// The binary cannot prove that hash is its own: whoever builds it chooses
/// what goes in, as whoever edits `lib/` chooses what [Journal.ownHash]
/// returns. What it rules out is the mistake: a build without it does not
/// open, and a run from source refuses a hash that is not its code.
///
/// The hashes they approve go in the `approved` file beside the entries, and
/// whether an entry came from code they checked is read from it whenever
/// the journal is read ([Journal.approved]), never written into the entry.
/// The journal reads that file and never writes it.
///
/// It imports `dart:convert`, `dart:io`, `dart:isolate`, `dart:typed_data`
/// and `is_content_id` 0.2.0, exactly, which holds the sha256 every name is
/// made with, [ObjectId] and [FileSetId]. The code hash names this package's
/// own code, and this comment names the one `is_content_id` it runs with, so
/// moving that pin changes the hash. An app's `dependency_overrides` can
/// still swap it, and its `pubspec.lock` records the version it resolved and
/// the sha256 of that version's archive.
/// An import added here changes the hash like any other edit, so the person
/// sees it.
///
/// Everything is synchronous: when [Journal.add] returns, its entry and its
/// bytes have been written and flushed, so they outlast this process
/// crashing, and one write must not interleave with another. They may not
/// outlast a power cut: the renames that keep objects and the first
/// creation of `entries` are not flushed to their folder, which Dart has no
/// call for. [Journal.check] reports what a power cut lost.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:is_content_id/is_content_id.dart';

export 'package:is_content_id/is_content_id.dart';

/// The sha256 of one journal entry.
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
  /// journal format's name, so a journal in another format breaks at its
  /// first entry, and anyone can compute it with
  /// `printf 'is_journal/1' | shasum -a 256`.
  static final origin = EntryHash.of(
    Uint8List.fromList('is_journal/1'.codeUnits),
  );
}

/// One entry of a journal, three names: `previous │ code │ object`, 32 bytes
/// each. Whether the person approved [code] is not in it: that is read from
/// `approved` whenever the journal is read ([Journal.approved]), so
/// approving a hash covers what it already wrote and removing it takes that
/// back.
final class JournalEntry {
  const JournalEntry(this.previous, this.code, this.object);

  /// An entry's length in bytes.
  static const length = 96;

  final EntryHash previous;
  final FileSetId code;
  final ObjectId object;

  /// [bytes] as an entry, read back; null unless they are [length] bytes.
  static JournalEntry? parse(Uint8List bytes) {
    if (bytes.length != length) return null;
    return switch ((
      EntryHash.fromDigest(Uint8List.sublistView(bytes, 0, 32)),
      FileSetId.fromDigest(Uint8List.sublistView(bytes, 32, 64)),
      ObjectId.fromDigest(Uint8List.sublistView(bytes, 64, 96)),
    )) {
      (final p?, final c?, final o?) => JournalEntry(p, c, o),
      _ => null,
    };
  }

  /// The entry's [length] bytes, as the journal keeps them.
  Uint8List encode() => Uint8List(length)
    ..setAll(0, previous.bytes)
    ..setAll(32, code.bytes)
    ..setAll(64, object.bytes);
}

/// What [Journal.check] found.
sealed class JournalCheck {
  const JournalCheck();
}

/// There is no journal: nothing was written here, or it was removed.
final class NoJournal extends JournalCheck {
  const NoJournal();
}

/// Every one of [count] entries names the entry before it, and an object
/// that is here. [head] is the last entry's hash ([EntryHash.origin] when
/// there are none). Entries cut from the end leave a journal that is still
/// intact.
final class Intact extends JournalCheck {
  const Intact(this.count, this.head);
  final int count;
  final EntryHash head;
}

/// The [entries], numbered from 1, that do not name the entry before them:
/// all of them, since checking goes on past a break, each entry against the
/// bytes before it as they are. [torn] counts the bytes after the last whole
/// entry, left by a write a crash cut short, which the next [Journal.add]
/// cuts off. [missing] numbers the entries whose object is not in
/// `objects/`: a crash between an entry and its object, an object removed
/// since, or an [Journal.add] still under way in another process. Copying
/// the object's file in from another copy of the journal restores it.
final class Broken extends JournalCheck {
  const Broken(this.entries, this.torn, this.missing);
  final List<int> entries;
  final int torn;
  final List<int> missing;
}

/// Stored bytes that no longer hash to their name: torn, edited or damaged.
/// [Journal.get] throws it; the next [Journal.add] of the bytes the name
/// stands for writes them back, as does copying the object's file in from
/// another copy of the journal.
final class CorruptObject implements Exception {
  const CorruptObject(this.id);
  final ObjectId id;

  @override
  String toString() => 'CorruptObject: ${id.hex} does not hash to its name';
}

/// [Journal.add] recorded its entry but could not keep the bytes [id] names.
/// The entry is in: adding the bytes again records them a second time.
/// [Journal.check] reports the object missing until it is kept, by copying
/// its file in from another copy of the journal or by a later add of the
/// same bytes.
final class ObjectNotKept extends FileSystemException {
  ObjectNotKept(this.id, FileSystemException cause)
    : super(
        'the entry for ${id.hex} is in, but its object was not kept: '
        '${cause.message}',
        cause.path,
        cause.osError,
      );
  final ObjectId id;
}

@pragma('vm:isolate-unsendable')
final class Journal {
  Journal._(this.dir, this.codeHash, this._writer);

  /// Holds `objects/`, `entries`, `approved`, `lock` and, while a journal has
  /// it open, `writer.<pid>`.
  final Directory dir;

  /// The hash of this package's code: computed from its source when the
  /// journal opened, or, in a compiled build, the one it was given
  /// ([builtDefine]). Every entry it adds names it.
  final FileSetId codeHash;

  /// The name of the define that gives a compiled build its code hash,
  /// which `dart run is_journal:code_hash` prints in full.
  static const builtDefine = 'is_journal.code';

  static const _built = String.fromEnvironment(builtDefine);

  /// This journal's claim on [dir], deleted by [close].
  final File _writer;
  var _open = true;

  /// A journal writing into [dir], which it claims for this process until
  /// [close] (see the library comment). Throws a [StateError] when [dir] is
  /// already claimed by this process; any other failure to claim it, such as
  /// a folder it cannot write, throws as itself. Null when this package
  /// cannot name its own code the way the library comment does: from its
  /// source ([ownHash]), or in a compiled build from [builtDefine]. Every
  /// entry names the code that wrote it, and a journal that cannot name its
  /// code writes none. Throws a [StateError] when [builtDefine] is not a
  /// code hash, or, run from source, is not this code's. A relative [dir] is
  /// resolved when it opens, so the journal stays where it is when the
  /// working directory moves.
  static Journal? open(Directory dir) {
    final built = _built.isEmpty ? null : FileSetId.parse(_built);
    final measured = ownHash();
    if ((_built.isNotEmpty && built == null) ||
        (built != null && measured != null && built != measured)) {
      throw StateError(
        'built with -D$builtDefine=$_built, but this code hashes to '
        '${measured?.hex ?? 'nothing'}; build with '
        r'$(dart run is_journal:code_hash).',
      );
    }
    final codeHash = measured ?? built;
    if (codeHash == null) return null;
    dir = dir.absolute;
    dir.createSync(recursive: true);
    final writer = File('${dir.path}/writer.$pid');
    try {
      writer.createSync(exclusive: true);
    } on PathExistsException {
      throw StateError(
        '${dir.path} is already open in this process. If no journal here has '
        'it open, a crashed process with the same id left ${writer.path}; '
        'delete it.',
      );
    }
    return Journal._(dir, codeHash, writer);
  }

  /// Gives up this journal's claim on [dir], so another journal in this
  /// process can open it. This journal writes nothing after.
  void close() {
    if (!_open) return;
    _open = false;
    try {
      _writer.deleteSync();
    } on PathNotFoundException {
      // Already given up: someone deleted it.
    }
  }

  /// The hash of this package's `lib/` as the library comment computes it.
  /// Null when it cannot be computed exactly that way: the source is not on
  /// disk, as in a compiled build; `lib/` holds a link, which `find` and this
  /// code would walk differently; or a file's name is one `shasum` would
  /// print differently from how it is written ([ListedPath.parse]).
  static FileSetId? ownHash() {
    final entry = Isolate.resolvePackageUriSync(
      Uri.parse('package:is_journal/is_journal.dart'),
    );
    if (entry == null || !entry.isScheme('file')) return null;
    final lib = File.fromUri(entry).parent.path;
    final files = <ListedPath, ObjectId>{};
    for (final f in Directory(
      lib,
    ).listSync(recursive: true, followLinks: false)) {
      if (f is Link) return null;
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final path = ListedPath.parse(
        f.path
            .substring(lib.length + 1)
            .replaceAll(Platform.pathSeparator, '/'),
      );
      if (path == null) return null;
      files[path] = ObjectId.of(f.readAsBytesSync());
    }
    return FileSetId.of(files);
  }

  /// The code hashes the person has approved: the first word of each line
  /// of `approved`, so the line `shasum` prints (`<hash>  -`) goes in as it
  /// is, and the rest of a line is theirs, in whatever bytes. Read each time
  /// it is asked: an entry came from code they checked when its
  /// [JournalEntry.code] is here.
  Set<FileSetId> approved() {
    final file = File('${dir.path}/approved');
    if (!file.existsSync()) return const {};
    return {
      for (final line in file.readAsLinesSync(
        encoding: const Utf8Codec(allowMalformed: true),
      ))
        ?FileSetId.parse(line.trim().split(RegExp(r'\s+')).first),
    };
  }

  File _object(ObjectId id) => File(
    '${dir.path}/objects/${id.hex.substring(0, 2)}/${id.hex.substring(2)}',
  );

  /// Adds an entry naming [bytes], keeps them, and returns their id. Every
  /// call adds an entry, so the same bytes added twice have two entries. The
  /// entry goes in before the object: a crash between the two leaves an
  /// entry naming an object that never arrived, which [check] reports, never
  /// bytes kept with no entry naming them. Throws [ObjectNotKept] when the
  /// entry went in and the object did not.
  ObjectId add(Uint8List bytes) {
    if (!_open) throw StateError('this journal is closed');
    final id = ObjectId.of(bytes);
    _enter(id);
    try {
      _keep(id, bytes);
    } on FileSystemException catch (e) {
      throw ObjectNotKept(id, e);
    }
    return id;
  }

  /// Writes [bytes] as [id] when that name is absent or no longer holds them.
  /// The temporary file is named for this process, which no other journal
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
    // than from the same one. Closing `lock` releases it.
    final lock = File('${dir.path}/lock').openSync(mode: FileMode.append);
    try {
      lock.lockSync(FileLock.blockingExclusive);
      final f = File('${dir.path}/entries').openSync(mode: FileMode.append);
      try {
        final previous = _lastEntry(f);
        final entry = JournalEntry(previous, codeHash, object);
        f.setPositionSync(f.lengthSync());
        f.writeFromSync(entry.encode());
        f.flushSync();
      } finally {
        f.closeSync();
      }
    } finally {
      lock.closeSync();
    }
  }

  /// The hash of [f]'s last entry. A tail shorter than an entry was torn by
  /// a crash, in an add that never returned and whose object, written after
  /// its entry, was never kept: it is cut off, losing nothing recorded. Only
  /// a crash leaves one, since writers take turns through `lock`.
  EntryHash _lastEntry(RandomAccessFile f) {
    var length = f.lengthSync();
    final torn = length % JournalEntry.length;
    if (torn != 0) {
      length -= torn;
      f.truncateSync(length);
    }
    if (length == 0) return EntryHash.origin;
    f.setPositionSync(length - JournalEntry.length);
    return EntryHash.of(f.readSync(JournalEntry.length));
  }

  /// Every entry checked against the one before it, and for whether the
  /// object it names is here. Not whether that object still holds its bytes:
  /// that reads every byte ever added, and [get] checks it on each read.
  JournalCheck check() {
    final file = File('${dir.path}/entries');
    if (!file.existsSync()) return const NoJournal();
    final bytes = file.readAsBytesSync();
    final broken = <int>[];
    final missing = <int>[];
    final here = <ObjectId, bool>{};
    var previous = EntryHash.origin;
    var at = 0;
    for (
      ;
      at + JournalEntry.length <= bytes.length;
      at += JournalEntry.length
    ) {
      final n = at ~/ JournalEntry.length + 1;
      final raw = Uint8List.sublistView(bytes, at, at + JournalEntry.length);
      final entry = JournalEntry.parse(raw)!;
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
        ? Intact(at ~/ JournalEntry.length, previous)
        : Broken(broken, torn, missing);
  }
}
