/// A journal's one writer, which other processes send entries to over a Unix
/// socket. It checks two things before it adds anything: that the sender's
/// user may write the entry's kind, and that the entry follows the tip of
/// its chain.
///
/// A request is the bytes to record, which start with a header the service
/// reads and keeps:
///
///     <kind>\n<follows>\n<the rest>
///
/// `<kind>` is a name the sender table lists for the sender's user, and
/// `<follows>` is the hash of the entry this one follows, or `-` to start a
/// chain. The sender closes its side when it has sent the request, and the
/// service answers one line: `ok <entry hash>`, or `refused <why>`, which
/// for an entry that is not its chain's tip names the tip, so the sender can
/// read it and try again. What it refuses it does not add.
///
/// The service reads the sender's user from the socket, as the kernel
/// reports it, never from the request. On every start it adds an entry of
/// kind `started` holding the sender table in force, so the record shows
/// who was allowed to write what. Kinds mean nothing to the service: which
/// names exist is the table's to say.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'is_journal.dart';

/// The kind of an entry: a name of letters, digits, `.`, `_` and `-`. Not
/// `-`, which reads as "follows nothing", and not [started], which only the
/// service writes.
final class Kind {
  Kind._(this.name);

  final String name;

  /// The kind of the entry the service adds on every start.
  static final started = Kind._('started');

  static final _name = RegExp(r'^[A-Za-z0-9._-]+$');

  /// [s] as a kind a sender may write; null unless it is one.
  static Kind? parse(String s) =>
      s != '-' && s != started.name && _name.hasMatch(s) ? Kind._(s) : null;

  @override
  bool operator ==(Object other) => other is Kind && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => name;
}

/// Which kinds each user may send: a line per user, the user's name or id
/// and then the kinds, separated by spaces. Blank lines and lines starting
/// with `#` are skipped.
final class SenderTable {
  SenderTable._(this.bytes, this._kinds);

  /// The table as it was read, which the `started` entry holds.
  final Uint8List bytes;
  final Map<int, Set<Kind>> _kinds;

  /// [bytes] as a table. Throws a [FormatException] naming the line when a
  /// line has no kinds, a kind is not one [Kind.parse] takes, or a user is
  /// not one [uidOf] finds. [uidOf] defaults to a number as itself and a
  /// name as `id -u` prints it.
  static SenderTable parse(
    Uint8List bytes, {
    int? Function(String user) uidOf = _uidOf,
  }) {
    final kinds = <int, Set<Kind>>{};
    final lines = utf8.decode(bytes).split('\n');
    for (var n = 0; n < lines.length; n++) {
      final words = lines[n].trim().split(RegExp(r'\s+'));
      if (words.first.isEmpty || words.first.startsWith('#')) continue;
      if (words.length < 2) {
        throw FormatException('line ${n + 1}: ${words.first} has no kinds');
      }
      final uid = uidOf(words.first);
      if (uid == null) {
        throw FormatException('line ${n + 1}: no user ${words.first}');
      }
      for (final word in words.skip(1)) {
        final kind = Kind.parse(word);
        if (kind == null) {
          throw FormatException('line ${n + 1}: $word is not a kind');
        }
        (kinds[uid] ??= {}).add(kind);
      }
    }
    return SenderTable._(bytes, kinds);
  }

  static int? _uidOf(String user) {
    if (int.tryParse(user) case final uid?) return uid;
    final r = Process.runSync('id', ['-u', user]);
    return r.exitCode == 0 ? int.tryParse(r.stdout.toString().trim()) : null;
  }

  /// Whether the user [uid] may send [kind].
  bool allows(int uid, Kind kind) => _kinds[uid]?.contains(kind) ?? false;
}

/// The writer of [journal], listening on [socket].
final class JournalService {
  JournalService._(this.journal, this._senders, this._socket, this._server);

  /// The largest request it reads, in bytes.
  static const maxRequest = 64 << 20;

  final Journal journal;
  final SenderTable _senders;
  final File _socket;
  final ServerSocket _server;

  /// Each entry in a chain, mapped to the entry that starts its chain.
  final _chainOf = <EntryHash, EntryHash>{};

  /// Each chain's start, mapped to its tip.
  final _tipOf = <EntryHash, EntryHash>{};

  /// Starts writing [journal] for the senders in [senders], listening on
  /// [socket]. Reads the chains back from the journal, then adds the
  /// `started` entry. Throws a [StateError] when another service is
  /// listening on [socket]; a socket file nothing listens on is replaced.
  static Future<JournalService> start(
    Journal journal,
    SenderTable senders,
    File socket,
  ) async {
    final address = InternetAddress(
      socket.path,
      type: InternetAddressType.unix,
    );
    if (socket.existsSync()) {
      try {
        (await Socket.connect(address, 0)).destroy();
        throw StateError('a service is already listening on ${socket.path}');
      } on SocketException {
        socket.deleteSync();
      }
    }
    final server = await ServerSocket.bind(address, 0);
    final service = JournalService._(journal, senders, socket, server)
      .._load()
      .._append(Kind.started, null, senders.bytes);
    server.listen(service._serve);
    return service;
  }

  /// Stops listening, removes the socket and closes the journal.
  Future<void> close() async {
    await _server.close();
    if (_socket.existsSync()) _socket.deleteSync();
    journal.close();
  }

  /// Reads the chains from the entries' headers. An entry whose object is
  /// missing or has no header is in no chain, and nothing can follow it.
  void _load() {
    _chainOf.clear();
    _tipOf.clear();
    final entries = File('${journal.dir.path}/entries');
    if (!entries.existsSync()) return;
    final raw = entries.readAsBytesSync();
    for (var at = 0; at + JournalEntry.length <= raw.length;) {
      final bytes = Uint8List.sublistView(raw, at, at += JournalEntry.length);
      final Uint8List? object;
      try {
        object = journal.get(JournalEntry.parse(bytes)!.object);
      } on CorruptObject {
        continue;
      }
      final header = object == null ? null : _Header.parse(object);
      if (header == null) continue;
      final follows = header.follows;
      if (follows != null && !_isTip(follows)) continue;
      _link(EntryHash.of(bytes), follows);
    }
  }

  bool _isTip(EntryHash entry) => switch (_chainOf[entry]) {
    final start? => _tipOf[start] == entry,
    null => false,
  };

  void _link(EntryHash entry, EntryHash? follows) {
    final start = follows == null ? entry : _chainOf[follows]!;
    _chainOf[entry] = start;
    _tipOf[start] = entry;
  }

  EntryHash _append(Kind kind, EntryHash? follows, Uint8List rest) {
    final header = '$kind\n${follows?.hex ?? '-'}\n';
    final entry = journal.addEntry(
      Uint8List.fromList([...utf8.encode(header), ...rest]),
    );
    _link(entry, follows);
    return entry;
  }

  Future<void> _serve(Socket socket) async {
    final uid = _peerUid(socket);
    final request = BytesBuilder(copy: false);
    var tooLarge = false;
    try {
      await for (final chunk in socket) {
        if (request.length + chunk.length > maxRequest) {
          tooLarge = true;
          break;
        }
        request.add(chunk);
      }
      final answer = tooLarge
          ? 'refused too-large'
          : _answer(uid, request.takeBytes());
      socket.add(utf8.encode('$answer\n'));
      await socket.close();
    } on SocketException {
      socket.destroy();
    }
  }

  /// Checks [request] from the user [uid] and adds it, all in one
  /// synchronous step, so no other request comes between the check and the
  /// add.
  String _answer(int? uid, Uint8List request) {
    final header = _Header.parse(request);
    if (header == null) return 'refused no-header';
    final Kind(:name) = header.kind;
    if (uid == null || !_senders.allows(uid, header.kind)) {
      return 'refused kind $name for user ${uid ?? 'unknown'}';
    }
    final follows = header.follows;
    if (follows != null) {
      final start = _chainOf[follows];
      if (start == null) return 'refused unknown ${follows.hex}';
      if (_tipOf[start] != follows) {
        return 'refused not-tip ${_tipOf[start]!.hex}';
      }
    }
    try {
      final entry = journal.addEntry(request);
      _link(entry, follows);
      return 'ok ${entry.hex}';
    } on FileSystemException catch (e) {
      // The entry may be in even though the add failed: read the chains
      // back rather than guess.
      _load();
      return 'failed ${e.message}';
    }
  }
}

/// The first two lines of an entry the service writes: its kind and the
/// entry it follows, null for none.
final class _Header {
  _Header(this.kind, this.follows);

  final Kind kind;
  final EntryHash? follows;

  static _Header? parse(Uint8List bytes) {
    final first = bytes.indexOf(0x0a);
    if (first < 0) return null;
    final second = bytes.indexOf(0x0a, first + 1);
    if (second < 0) return null;
    final kindText = ascii.decode(bytes.sublist(0, first), allowInvalid: true);
    final kind = kindText == Kind.started.name
        ? Kind.started
        : Kind.parse(kindText);
    final followsText = ascii.decode(
      bytes.sublist(first + 1, second),
      allowInvalid: true,
    );
    final follows = followsText == '-' ? null : EntryHash.parse(followsText);
    if (kind == null || (followsText != '-' && follows == null)) return null;
    return _Header(kind, follows);
  }
}

/// The user on the other end of [socket], as the kernel reports it: Linux's
/// `SO_PEERCRED`, macOS's `LOCAL_PEERCRED`. Null where neither is known.
int? _peerUid(Socket socket) {
  try {
    if (Platform.isLinux) {
      final ucred = socket.getRawOption(RawSocketOption(1, 17, Uint8List(12)));
      return ByteData.sublistView(ucred).getUint32(4, Endian.host);
    }
    if (Platform.isMacOS) {
      final xucred = socket.getRawOption(RawSocketOption(0, 1, Uint8List(76)));
      return ByteData.sublistView(xucred).getUint32(4, Endian.host);
    }
  } on SocketException {
    return null;
  }
  return null;
}
