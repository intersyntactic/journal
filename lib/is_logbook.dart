/// A logbook: an add-only record of bytes. Each entry is chained to the
/// entry before it and names the bytes and the hash of the code that wrote
/// it. It keeps two things in one directory and only ever adds to them.
///
/// OBJECTS, `objects/<2>/<62>`: bytes named by their sha256 ([ObjectId]),
/// kept whole, written when that name is absent or no longer holds them, and
/// checked against it whenever they are read. The same bytes are the same
/// object whichever logbook wrote them, so two logbooks merge by copying
/// each other's objects in, and an object missing or damaged here is
/// restored by copying its file in from another copy of the logbook.
///
/// THE ENTRIES, `entries`: one for each [Logbook.add], even of bytes already
/// kept, each added before its object. An entry says nothing of what the
/// bytes are; that is for whoever adds them to write into them. An entry is
/// three names, 96 bytes ([LogbookEntry]): the entry before it, the code
/// that wrote it ([Logbook.codeHash]) and the object. An entry that is
/// changed or removed breaks the chain at the entry after it, and an entry
/// whose object
/// is not here is named too ([Logbook.check]). The chain is a checksum
/// against damage and drift, not proof against someone set on editing it:
/// entries cut from the end leave a shorter logbook that still chains, and
/// sha256 has no secret, so whoever can write the file can recompute it.
/// Whatever can write this directory, this package's code or `approved` can
/// change what the logbook says, and the chain cannot tell. A logbook whose
/// code is reloaded in place keeps the [Logbook.codeHash] it opened with.
///
/// ONE WRITER: [Logbook.open] claims the directory for its process by
/// creating `writer.<pid>` there only if it is absent, so no second logbook
/// in the same process, in any isolate, can open it until [Logbook.close].
/// It holds a lock on that file while open, so a claim left by a process
/// that ended without closing, which no lock holds, is deleted when a
/// logbook in another process next opens the directory.
/// Nor can a logbook be sent to another isolate: sending copies it, and the
/// copy would write with no claim of its own. Dart has no append that cannot
/// overwrite, and two writers in one process would write over each other's
/// entries. Processes take turns at each entry
/// through a lock on `lock`, a file nothing else has a reason to open:
/// closing any descriptor on a file gives up every lock its process holds
/// on that file, so a lock on `entries` would end whenever anything in the
/// process read them.
///
/// THE CODE HASH is the [FileSetId] of the `lib/` files of this package and
/// of the `is_content_id` it runs with, each path under its package's name:
/// the sha256 of what `shasum -a 256` prints for them, so the person can
/// compute it without running this code (the README's "Checking it" gives
/// the command). `is_content_id` is in it because it makes every name the
/// logbook writes: a new version of it changes the hash, so the person sees
/// it, whichever version an app resolves.
///
/// A compiled build has no `lib/` to hash, so it is given the hash when it
/// is compiled, by `dart run is_logbook:code_hash`, from the source the
/// compiler reads (the README gives the build line). The binary cannot prove that hash is its own: whoever builds it chooses
/// what goes in, as whoever edits `lib/` chooses what [Logbook.ownHash]
/// returns. What it rules out is the mistake: a build without it does not
/// open, and a run from source refuses a hash that is not its code.
///
/// The hashes they approve go in the `approved` file beside the entries, and
/// whether an entry came from code they checked is read from it whenever
/// the logbook is read ([Logbook.approved]), never written into the entry.
/// The logbook reads that file and never writes it.
///
/// It imports `dart:convert`, `dart:io`, `dart:isolate`, `dart:typed_data`
/// and `is_content_id`, which holds the sha256 every name is made with,
/// [ObjectId] and [FileSetId]. An import added here changes the hash like
/// any other edit, so the person sees it.
///
/// Everything is synchronous: when [Logbook.add] returns, its entry and its
/// bytes have been written and flushed, so they outlast this process
/// crashing, and one write must not interleave with another. They may not
/// outlast a power cut: the renames that keep objects and the first
/// creation of `entries` are not flushed to their folder, which Dart has no
/// call for. [Logbook.check] reports what a power cut lost.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:is_content_id/is_content_id.dart';

export 'package:is_content_id/is_content_id.dart';

/// The sha256 of one logbook entry.
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
  /// logbook format's name, so a logbook in another format breaks at its
  /// first entry, and anyone can compute it with
  /// `printf 'is_logbook/1' | shasum -a 256`.
  static final origin = EntryHash.of(
    Uint8List.fromList('is_logbook/1'.codeUnits),
  );
}

/// One entry of a logbook, three names: `previous │ code │ object`, 32 bytes
/// each. Whether the person approved [code] is not in it: that is read from
/// `approved` whenever the logbook is read ([Logbook.approved]), so
/// approving a hash covers what it already wrote and removing it takes that
/// back.
final class LogbookEntry {
  const LogbookEntry(this.previous, this.code, this.object);

  /// An entry's length in bytes.
  static const length = 96;

  final EntryHash previous;
  final FileSetId code;
  final ObjectId object;

  /// [bytes] as an entry, read back; null unless they are [length] bytes.
  static LogbookEntry? parse(Uint8List bytes) {
    if (bytes.length != length) return null;
    return switch ((
      EntryHash.fromDigest(Uint8List.sublistView(bytes, 0, 32)),
      FileSetId.fromDigest(Uint8List.sublistView(bytes, 32, 64)),
      ObjectId.fromDigest(Uint8List.sublistView(bytes, 64, 96)),
    )) {
      (final p?, final c?, final o?) => LogbookEntry(p, c, o),
      _ => null,
    };
  }

  /// The entry's [length] bytes, as the logbook keeps them.
  Uint8List encode() => Uint8List(length)
    ..setAll(0, previous.bytes)
    ..setAll(32, code.bytes)
    ..setAll(64, object.bytes);
}

/// What [Logbook.check] found.
sealed class LogbookCheck {
  const LogbookCheck();
}

/// There is no logbook: nothing was written here, or it was removed.
final class NoLogbook extends LogbookCheck {
  const NoLogbook();
}

/// Every one of [count] entries names the entry before it, and an object
/// that is here. [head] is the last entry's hash ([EntryHash.origin] when
/// there are none). Entries cut from the end leave a logbook that is still
/// intact.
final class Intact extends LogbookCheck {
  const Intact(this.count, this.head);
  final int count;
  final EntryHash head;
}

/// The [entries], numbered from 1, that do not name the entry before them:
/// all of them, since checking goes on past a break, each entry against the
/// bytes before it as they are. [torn] counts the bytes after the last whole
/// entry, left by a write a crash cut short, which the next [Logbook.add]
/// cuts off. [missing] numbers the entries whose object is not in
/// `objects/`: a crash between an entry and its object, an object removed
/// since, or an [Logbook.add] still under way in another process. Copying
/// the object's file in from another copy of the logbook restores it.
final class Broken extends LogbookCheck {
  const Broken(this.entries, this.torn, this.missing);
  final List<int> entries;
  final int torn;
  final List<int> missing;
}

/// Stored bytes that no longer hash to their name: torn, edited or damaged.
/// [Logbook.get] throws it; the next [Logbook.add] of the bytes the name
/// stands for writes them back, as does copying the object's file in from
/// another copy of the logbook.
final class CorruptObject implements Exception {
  const CorruptObject(this.id);
  final ObjectId id;

  @override
  String toString() => 'CorruptObject: ${id.hex} does not hash to its name';
}

/// [Logbook.add] recorded its entry but could not keep the bytes [id] names.
/// The entry is in: adding the bytes again records them a second time.
/// [Logbook.check] reports the object missing until it is kept, by copying
/// its file in from another copy of the logbook or by a later add of the
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
final class Logbook {
  Logbook._(this.dir, this.codeHash, this._writer, this._claim);

  /// Holds `objects/`, `entries`, `approved`, `lock` and, while a logbook has
  /// it open, `writer.<pid>`.
  final Directory dir;

  /// The hash of this package's code: computed from its source when the
  /// logbook opened, or, in a compiled build, the one it was given
  /// ([builtDefine]). Every entry it adds names it.
  final FileSetId codeHash;

  /// The name of the define that gives a compiled build its code hash,
  /// which `dart run is_logbook:code_hash` prints in full.
  static const builtDefine = 'is_logbook.code';

  static const _built = String.fromEnvironment(builtDefine);

  /// This logbook's claim on [dir], deleted by [close], and the lock on it
  /// that tells this process is alive.
  final File _writer;
  final RandomAccessFile _claim;
  var _open = true;

  /// A logbook writing into [dir], which it claims for this process until
  /// [close] (see the library comment). Throws a [StateError] when [dir] is
  /// already claimed by this process; any other failure to claim it, such as
  /// a folder it cannot write, throws as itself. Null when this package
  /// cannot name its own code the way the library comment does: from its
  /// source ([ownHash]), or in a compiled build from [builtDefine]. Every
  /// entry names the code that wrote it, and a logbook that cannot name its
  /// code writes none. Throws a [StateError] when [builtDefine] is not a
  /// code hash, or, run from source, is not this code's. A relative [dir] is
  /// resolved when it opens, so the logbook stays where it is when the
  /// working directory moves.
  static Logbook? open(Directory dir) {
    final built = _built.isEmpty ? null : FileSetId.parse(_built);
    final measured = ownHash();
    if ((_built.isNotEmpty && built == null) ||
        (built != null && measured != null && built != measured)) {
      throw StateError(
        'built with -D$builtDefine=$_built, but this code hashes to '
        '${measured?.hex ?? 'nothing'}; build with '
        r'$(dart run is_logbook:code_hash).',
      );
    }
    final codeHash = measured ?? built;
    if (codeHash == null) return null;
    dir = dir.absolute;
    dir.createSync(recursive: true);
    _sweep(dir);
    final writer = File('${dir.path}/writer.$pid');
    while (true) {
      try {
        writer.createSync(exclusive: true);
      } on PathExistsException {
        throw StateError(
          '${dir.path} is already open in this process. If no logbook here '
          'has it open, a crashed process with the same id left '
          '${writer.path}; delete it.',
        );
      }
      final claim = writer.openSync(mode: FileMode.append);
      claim.lockSync(FileLock.blockingExclusive);
      if (writer.existsSync()) return Logbook._(dir, codeHash, writer, claim);
      // Another process's [_sweep] took it, unlocked, for a dead process's
      // and deleted it before this lock: claim it again.
      claim.closeSync();
    }
  }

  /// Deletes the claims of processes that ended without closing: a claim
  /// whose lock nothing holds. It deletes while it holds the lock, so a
  /// process that has just created its claim finds it gone once it locks.
  /// Never this process's own claim, since closing any descriptor on a file
  /// gives up every lock this process holds on it.
  static void _sweep(Directory dir) {
    for (final file in dir.listSync().whereType<File>()) {
      final name = file.uri.pathSegments.last;
      if (!_claimName.hasMatch(name) || name == 'writer.$pid') continue;
      final RandomAccessFile open;
      try {
        open = file.openSync();
      } on FileSystemException {
        continue;
      }
      try {
        open.lockSync(FileLock.shared);
        file.deleteSync();
      } on FileSystemException {
        // Locked by a process that has it open, or already gone.
      } finally {
        open.closeSync();
      }
    }
  }

  static final _claimName = RegExp(r'^writer\.\d+$');

  /// Gives up this logbook's claim on [dir], so another logbook in this
  /// process can open it. This logbook writes nothing after.
  void close() {
    if (!_open) return;
    _open = false;
    try {
      _writer.deleteSync();
    } on PathNotFoundException {
      // Already given up: someone deleted it.
    }
    _claim.closeSync();
  }

  /// The hash of this package's `lib/` and `is_content_id`'s, as the library
  /// comment computes it. Null when it cannot be computed exactly that way:
  /// the source is not on disk, as in a compiled build; a `lib/` holds a
  /// link, which `find` and this code would walk differently; or a file's
  /// name is one `shasum` would print differently from how it is written
  /// ([ListedPath.parse]).
  static FileSetId? ownHash() {
    final files = <ListedPath, ObjectId>{};
    for (final package in const ['is_content_id', 'is_logbook']) {
      if (!_listLib(package, files)) return null;
    }
    return FileSetId.of(files);
  }

  /// Adds the `.dart` files of [package]'s `lib/` to [files], each path
  /// under the package's name. False when they cannot be listed the way the
  /// library comment's command lists them.
  static bool _listLib(String package, Map<ListedPath, ObjectId> files) {
    final entry = Isolate.resolvePackageUriSync(
      Uri.parse('package:$package/$package.dart'),
    );
    if (entry == null || !entry.isScheme('file')) return false;
    final lib = File.fromUri(entry).parent.path;
    for (final f in Directory(
      lib,
    ).listSync(recursive: true, followLinks: false)) {
      if (f is Link) return false;
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final path = ListedPath.parse(
        '$package/${f.path.substring(lib.length + 1).replaceAll(Platform.pathSeparator, '/')}',
      );
      if (path == null) return false;
      files[path] = ObjectId.of(f.readAsBytesSync());
    }
    return true;
  }

  /// The code hashes the person has approved: the first word of each line
  /// of `approved`, so the line `shasum` prints (`<hash>  -`) goes in as it
  /// is, and the rest of a line is theirs, in whatever bytes. Read each time
  /// it is asked: an entry came from code they checked when its
  /// [LogbookEntry.code] is here.
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
  ObjectId add(Uint8List bytes) => _add(bytes).object;

  /// Adds as [add] does, and returns the hash of the entry it wrote, which a
  /// later entry's bytes can name.
  EntryHash addEntry(Uint8List bytes) => _add(bytes).entry;

  ({ObjectId object, EntryHash entry}) _add(Uint8List bytes) {
    if (!_open) throw StateError('this logbook is closed');
    final id = ObjectId.of(bytes);
    final entry = _enter(id);
    try {
      _keep(id, bytes);
    } on FileSystemException catch (e) {
      throw ObjectNotKept(id, e);
    }
    return (object: id, entry: entry);
  }

  /// Writes [bytes] as [id] when that name is absent or no longer holds them.
  /// The temporary file is named for this process, which no other logbook
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

  EntryHash _enter(ObjectId object) {
    dir.createSync(recursive: true);
    // Locked, so another process writing here chains from this entry rather
    // than from the same one. Closing `lock` releases it.
    final lock = File('${dir.path}/lock').openSync(mode: FileMode.append);
    try {
      lock.lockSync(FileLock.blockingExclusive);
      final f = File('${dir.path}/entries').openSync(mode: FileMode.append);
      try {
        final previous = _lastEntry(f);
        final entry = LogbookEntry(previous, codeHash, object).encode();
        f.setPositionSync(f.lengthSync());
        f.writeFromSync(entry);
        f.flushSync();
        return EntryHash.of(entry);
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
    final torn = length % LogbookEntry.length;
    if (torn != 0) {
      length -= torn;
      f.truncateSync(length);
    }
    if (length == 0) return EntryHash.origin;
    f.setPositionSync(length - LogbookEntry.length);
    return EntryHash.of(f.readSync(LogbookEntry.length));
  }

  /// Every entry checked against the one before it, and for whether the
  /// object it names is here. Not whether that object still holds its bytes:
  /// that reads every byte ever added, and [get] checks it on each read.
  LogbookCheck check() {
    final file = File('${dir.path}/entries');
    if (!file.existsSync()) return const NoLogbook();
    final bytes = file.readAsBytesSync();
    final broken = <int>[];
    final missing = <int>[];
    final here = <ObjectId, bool>{};
    var previous = EntryHash.origin;
    var at = 0;
    for (
      ;
      at + LogbookEntry.length <= bytes.length;
      at += LogbookEntry.length
    ) {
      final n = at ~/ LogbookEntry.length + 1;
      final raw = Uint8List.sublistView(bytes, at, at + LogbookEntry.length);
      final entry = LogbookEntry.parse(raw)!;
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
        ? Intact(at ~/ LogbookEntry.length, previous)
        : Broken(broken, torn, missing);
  }
}
