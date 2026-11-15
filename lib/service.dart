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
  File? _readSocket;
  ServerSocket? _readServer;

  /// Each entry in a chain, mapped to the entry that starts its chain.
  final _chainOf = <EntryHash, EntryHash>{};

  /// Each chain's start, mapped to its tip.
  final _tipOf = <EntryHash, EntryHash>{};

  /// Every entry with a header, in the journal's order, and where each is.
  final _order = <_Indexed>[];
  final _at = <EntryHash, int>{};

  /// The readers following entries as they are added.
  final _followers = <_Follower>{};

  /// Starts writing [journal] for the senders in [senders], listening on
  /// [socket], and for readers on [readSocket] when it is given. Reads the
  /// chains back from the journal, then adds the `started` entry. Throws a
  /// [StateError] when another service is listening on either socket; a
  /// socket file nothing listens on is replaced.
  static Future<JournalService> start(
    Journal journal,
    SenderTable senders,
    File socket, {
    File? readSocket,
  }) async {
    final service = JournalService._(
      journal,
      senders,
      socket,
      await _bind(socket),
    );
    if (readSocket != null) {
      service._readServer = await _bind(readSocket);
      service._readSocket = readSocket;
      service._readServer!.listen(service._serveReader);
    }
    service
      .._load()
      .._append(Kind.started, null, senders.bytes);
    service._server.listen(service._serve);
    return service;
  }

  static Future<ServerSocket> _bind(File socket) async {
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
    return ServerSocket.bind(address, 0);
  }

  /// Stops listening, ends the readers following it, removes the sockets
  /// and closes the journal.
  Future<void> close() async {
    await _server.close();
    await _readServer?.close();
    for (final follower in _followers.toList()) {
      follower.socket.destroy();
    }
    _followers.clear();
    for (final socket in [_socket, ?_readSocket]) {
      if (socket.existsSync()) socket.deleteSync();
    }
    journal.close();
  }

  /// Reads the chains from the entries' headers. An entry whose object is
  /// missing or has no header is in no chain, and nothing can follow it.
  void _load() {
    _chainOf.clear();
    _tipOf.clear();
    _order.clear();
    _at.clear();
    final entries = File('${journal.dir.path}/entries');
    if (!entries.existsSync()) return;
    final raw = entries.readAsBytesSync();
    for (var at = 0; at + JournalEntry.length <= raw.length;) {
      final bytes = Uint8List.sublistView(raw, at, at += JournalEntry.length);
      final objectId = JournalEntry.parse(bytes)!.object;
      final Uint8List? object;
      try {
        object = journal.get(objectId);
      } on CorruptObject {
        continue;
      }
      final header = object == null ? null : _Header.parse(object);
      if (header == null) continue;
      final entry = EntryHash.of(bytes);
      _index(entry, header, objectId);
      final follows = header.follows;
      if (follows != null && !_isTip(follows)) continue;
      _link(entry, follows);
    }
  }

  void _index(EntryHash entry, _Header header, ObjectId object) {
    _at[entry] = _order.length;
    _order.add(_Indexed(entry, header, object));
  }

  /// Indexes and links [entry], just added, and sends it to the readers
  /// following its kind.
  void _added(EntryHash entry, _Header header, Uint8List bytes) {
    _index(entry, header, ObjectId.of(bytes));
    _link(entry, header.follows);
    for (final follower in _followers) {
      if (follower.wants(header.kind)) {
        _send(follower.socket, entry, header, bytes);
      }
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
    final bytes = Uint8List.fromList([
      ...utf8.encode('$kind\n${follows?.hex ?? '-'}\n'),
      ...rest,
    ]);
    final entry = journal.addEntry(bytes);
    _added(entry, _Header(kind, follows), bytes);
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
      _added(entry, header, request);
      return 'ok ${entry.hex}';
    } on FileSystemException catch (e) {
      // The entry may be in even though the add failed: read the chains
      // back rather than guess.
      _load();
      return 'failed ${e.message}';
    }
  }
}

extension on JournalService {
  /// Reads one request line from a reader, then answers it. A reader only
  /// ever reads: nothing it sends reaches [JournalService._answer].
  void _serveReader(Socket socket) {
    final line = BytesBuilder();
    var answered = false;
    socket.listen(
      (chunk) {
        if (answered) return;
        final nl = chunk.indexOf(0x0a);
        line.add(nl < 0 ? chunk : Uint8List.sublistView(chunk, 0, nl));
        if (nl < 0 && line.length <= 4096) return;
        answered = true;
        _read(socket, ascii.decode(line.takeBytes(), allowInvalid: true));
      },
      onDone: () => _drop(socket),
      onError: (Object _) => _drop(socket),
    );
    socket.done.catchError((Object _) => _drop(socket));
  }

  void _drop(Socket socket) {
    _followers.removeWhere((f) => f.socket == socket);
    socket.destroy();
  }

  /// `tip <entry>`, or `follow <kinds> <after>`: `<kinds>` is `*` or names
  /// joined by commas, `<after>` an entry, or `-` for the journal's start.
  void _read(Socket socket, String request) {
    void refuse(String why) {
      socket.add(utf8.encode('refused $why\n'));
      socket.close();
    }

    switch (request.split(' ')) {
      case ['tip', final hex] when EntryHash.parse(hex) != null:
        final start = _chainOf[EntryHash.parse(hex)!];
        if (start == null) return refuse('unknown $hex');
        socket.add(utf8.encode('tip ${_tipOf[start]!.hex}\n'));
        socket.close();
      case ['follow', final kinds, final after]
          when _Follower.parse(socket, kinds) != null &&
              (after == '-' || EntryHash.parse(after) != null):
        final from = after == '-' ? 0 : _at[EntryHash.parse(after)!];
        if (from == null) return refuse('unknown $after');
        final follower = _Follower.parse(socket, kinds)!;
        // Sent, marked and registered in one synchronous step, so no entry
        // added meanwhile is missed, sent twice, or lands unseen between
        // the backlog and the live entries.
        for (final indexed in _order.skip(after == '-' ? 0 : from + 1)) {
          if (!follower.wants(indexed.header.kind)) continue;
          final bytes = journal.get(indexed.object);
          if (bytes != null) {
            _send(socket, indexed.entry, indexed.header, bytes);
          }
        }
        final head = _order.isEmpty ? '-' : _order.last.entry.hex;
        socket.add(utf8.encode('caught-up $head\n'));
        _followers.add(follower);
      case _:
        refuse('not-a-request');
    }
  }
}

/// Writes one entry to a reader: `entry <hash> <kind> <follows> <length>`,
/// a newline, and its bytes exactly as recorded.
void _send(Socket socket, EntryHash entry, _Header header, Uint8List bytes) {
  socket
    ..add(
      utf8.encode(
        'entry ${entry.hex} ${header.kind} ${header.follows?.hex ?? '-'} '
        '${bytes.length}\n',
      ),
    )
    ..add(bytes);
}

/// An entry the service knows: its hash, its header, and its object.
final class _Indexed {
  _Indexed(this.entry, this.header, this.object);

  final EntryHash entry;
  final _Header header;
  final ObjectId object;
}

/// A reader following [kinds] (null for every kind) on [socket].
final class _Follower {
  _Follower(this.socket, this.kinds);

  final Socket socket;
  final Set<String>? kinds;

  static _Follower? parse(Socket socket, String kinds) {
    if (kinds == '*') return _Follower(socket, null);
    final names = kinds.split(',');
    return names.every((n) => n == Kind.started.name || Kind.parse(n) != null)
        ? _Follower(socket, names.toSet())
        : null;
  }

  bool wants(Kind kind) => kinds?.contains(kind.name) ?? true;
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
