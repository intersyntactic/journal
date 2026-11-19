/// A logbook's one writer, which other processes send entries to over a Unix
/// socket. It checks two things before it adds anything: that the sender's
/// user may write the entry's kind, and that the entry names the tip of its
/// chain as previous.
///
/// A request is the bytes to record, which start with a header the service
/// reads and keeps:
///
///     <kind>\n<previous>\n<the rest>
///
/// `<kind>` is a name the sender table lists for the sender's user, and
/// `<previous>` is the id of the entry before this one in its chain, or
/// `-` to start a chain. An entry's id is the sha256 of its bytes, header
/// and all ([ObjectId]): a sender can compute it before sending, and every
/// reader and every copy of the logbook computes the same one. The 96 bytes
/// the logbook chains its entries with are its own check, and never an id
/// here. The sender closes its side when it has sent the request, and the
/// service answers one line: `ok <id>`, or `refused <why>`, which for an
/// entry that is not its chain's tip names the tip, so the sender can read it
/// and try again, and for bytes the logbook already holds is
/// `refused duplicate <id>`. What it refuses it does not add.
///
/// The service reads the sender's user from the socket, as the kernel
/// reports it, never from the request. On every start it adds an entry of
/// kind `started` holding the sender table in force, so the record shows
/// who was allowed to write what. Each `started` names the one before it as
/// previous, so no two are the same bytes. Which names exist is the table's to say,
/// and every kind means nothing to the service but two.
///
/// A trajectory's chain is owned. An entry of kind
/// [Kind.usersAssignedToTrajectory] starts it and names the one user who
/// may extend it, its loop user, and the user that wears its suit. No
/// trajectory is assigned twice, and no user is in use by two open
/// trajectories. An entry of kind [Kind.missionEnded] closes every chain of
/// its mission, and one of kind [Kind.trajectoryClosed] every chain of one
/// trajectory, even one whose users are not assigned yet. A kind the table
/// lists as attaching starts a chain that names its parent entry on its
/// first body line, and belongs to that entry's trajectory. Every other chain takes an entry from any user the
/// table lets send its kind. Who owns what is read back from the logbook on
/// every start, so a restart refuses exactly what the live service did.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'is_logbook.dart';

/// The kind of an entry: a name of letters, digits, `.`, `_` and `-`. Not
/// `-`, which reads as "no previous entry", and not [started], which only the
/// service writes.
final class Kind {
  Kind._(this.name);

  final String name;

  /// The kind of the entry the service adds on every start.
  static final started = Kind._('started');

  /// The kind that roots a trajectory's chain and names the one user who
  /// may extend it (see [LogbookService]).
  static final usersAssignedToTrajectory = Kind._(
    'users-assigned-to-trajectory',
  );

  /// The kind that closes every chain of a mission (see [LogbookService]).
  static final missionEnded = Kind._('mission-ended');

  /// The kind that closes every chain of one trajectory (see
  /// [LogbookService]).
  static final trajectoryClosed = Kind._('trajectory-closed');

  /// The kinds the service reads a body of, which never attach.
  static final _serviceReadsBody = {
    usersAssignedToTrajectory,
    missionEnded,
    trajectoryClosed,
  };

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
///
/// A line `attaching: <kinds>` names the kinds that attach: a chain started
/// by one of them names its parent entry on its first body line and joins
/// that entry's trajectory (see [LogbookService]). No user name holds a
/// `:`, so the line cannot be read as a user's.
final class SenderTable {
  SenderTable._(this.bytes, this._kinds, this.attaching);

  /// The table as it was read, which the `started` entry holds.
  final Uint8List bytes;
  final Map<int, Set<Kind>> _kinds;

  /// The kinds that attach.
  final Set<Kind> attaching;

  static const _attachingLabel = 'attaching:';

  /// [bytes] as a table. Throws a [FormatException] naming the line when a
  /// line has no kinds, a kind is not one [Kind.parse] takes, an attaching
  /// kind is one whose body the service reads (such as
  /// [Kind.missionEnded]), or a
  /// user is not one [uidOf] finds. [uidOf] defaults to a number as itself
  /// and a name as `id -u` prints it.
  static SenderTable parse(
    Uint8List bytes, {
    int? Function(String user) uidOf = _uidOfUser,
  }) {
    final kinds = <int, Set<Kind>>{};
    final attaching = <Kind>{};
    final lines = utf8.decode(bytes).split('\n');
    for (var n = 0; n < lines.length; n++) {
      final words = lines[n].trim().split(RegExp(r'\s+'));
      if (words.first.isEmpty || words.first.startsWith('#')) continue;
      if (words.length < 2) {
        throw FormatException('line ${n + 1}: ${words.first} has no kinds');
      }
      if (words.first == _attachingLabel) {
        for (final word in words.skip(1)) {
          final kind = Kind.parse(word);
          if (kind == null || Kind._serviceReadsBody.contains(kind)) {
            throw FormatException('line ${n + 1}: $word cannot attach');
          }
          attaching.add(kind);
        }
        continue;
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
    return SenderTable._(bytes, kinds, attaching);
  }

  /// The attaching kinds of the table [bytes], as a `started` entry holds
  /// it, read back without looking any user up: what attached when an entry
  /// was added is what the table in force then said. Never throws: a kind
  /// it cannot read attaches nothing.
  static Set<Kind> attachingIn(Uint8List bytes) => {
    for (final line in utf8.decode(bytes, allowMalformed: true).split('\n'))
      if (line.trim().split(RegExp(r'\s+')) case [
        _attachingLabel,
        ...final words,
      ])
        for (final word in words)
          if (Kind.parse(word) case final kind?
              when !Kind._serviceReadsBody.contains(kind))
            kind,
  };

  /// Whether the user [uid] may send [kind].
  bool allows(int uid, Kind kind) => _kinds[uid]?.contains(kind) ?? false;
}

/// [user] as a uid: a number as itself, a name as `id -u` prints it. Null
/// when there is no such user.
int? _uidOfUser(String user) {
  if (int.tryParse(user) case final uid?) return uid;
  final r = Process.runSync('id', ['-u', user]);
  return r.exitCode == 0 ? int.tryParse(r.stdout.toString().trim()) : null;
}

/// The writer of [logbook], listening on [socket].
final class LogbookService {
  LogbookService._(
    this.logbook,
    this._senders,
    this._socket,
    this._server,
    this._uidOf,
  );

  /// The largest request it reads, in bytes.
  static const maxRequest = 64 << 20;

  final Logbook logbook;
  final SenderTable _senders;
  final File _socket;
  final ServerSocket _server;
  final int? Function(String user) _uidOf;
  File? _readSocket;
  ServerSocket? _readServer;

  /// Each entry in a chain, mapped to the entry that starts its chain.
  final _chainOf = <ObjectId, ObjectId>{};

  /// Each chain's start, mapped to its tip.
  final _tipOf = <ObjectId, ObjectId>{};

  /// Every entry with a header, in the logbook's order, and where each is.
  final _order = <_Indexed>[];
  final _at = <ObjectId, int>{};

  /// Every entry in the logbook, by id, as the 96 bytes that record it,
  /// whether or not its bytes can be read: an entry whose bytes are lost was
  /// still recorded.
  final _entries = <ObjectId, Uint8List>{};

  /// The logbook's last 96 bytes, which the next ones name as the ones
  /// before.
  var _head = EntryHash.origin;

  /// The last `started` entry, which the next one names as previous.
  ObjectId? _lastStarted;

  /// Every trajectory ever assigned, by its id.
  final _trajectories = <_TrajectoryId, _Trajectory>{};

  /// Each chain the trajectory that owns it, by the chain's start: its
  /// `users-assigned-to-trajectory` root, or an attached root.
  final _trajectoryOf = <ObjectId, _Trajectory>{};

  /// The missions a `mission-ended` closed.
  final _endedMissions = <_MissionId>{};

  /// The trajectories a `trajectory-closed` closed, whether or not their users were assigned.
  final _closedTrajectories = <_TrajectoryId>{};

  /// The kinds that attach, as the last `started` entry's table says.
  var _attaching = <Kind>{};

  /// Users looked up since the chains were last read back.
  final _uids = <String, int?>{};

  /// The readers subscribed to entries as they are added.
  final _subscribers = <_Subscriber>{};

  /// Starts writing [logbook] for the senders in [senders], listening on
  /// [socket], and for readers on [readSocket] when it is given. Reads the
  /// chains back from the logbook, then adds the `started` entry. Throws a
  /// [StateError] when another service is listening on either socket; a
  /// socket file nothing listens on is replaced. [uidOf] finds the users a
  /// `users-assigned-to-trajectory` names, as [SenderTable.parse]'s does.
  static Future<LogbookService> start(
    Logbook logbook,
    SenderTable senders,
    File socket, {
    File? readSocket,
    int? Function(String user) uidOf = _uidOfUser,
  }) async {
    final service = LogbookService._(
      logbook,
      senders,
      socket,
      await _bind(socket),
      uidOf,
    );
    if (readSocket != null) {
      service._readServer = await _bind(readSocket);
      service._readSocket = readSocket;
      service._readServer!.listen(service._serveReader);
    }
    service._load();
    service._append(Kind.started, service._lastStarted, senders.bytes);
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

  /// Stops listening, ends its subscribers, removes the sockets
  /// and closes the logbook.
  Future<void> close() async {
    await _server.close();
    await _readServer?.close();
    for (final subscriber in _subscribers.toList()) {
      subscriber.socket.destroy();
    }
    _subscribers.clear();
    for (final socket in [_socket, ?_readSocket]) {
      if (socket.existsSync()) socket.deleteSync();
    }
    logbook.close();
  }

  /// Reads the entries back, and the chains from their headers. An entry
  /// whose object is missing or has no header is in no chain, and no entry
  /// can name it as previous, but `get` still finds it.
  void _load() {
    _chainOf.clear();
    _tipOf.clear();
    _order.clear();
    _at.clear();
    _entries.clear();
    _head = EntryHash.origin;
    _lastStarted = null;
    _trajectories.clear();
    _trajectoryOf.clear();
    _endedMissions.clear();
    _closedTrajectories.clear();
    _attaching = {};
    _uids.clear();
    final entries = File('${logbook.dir.path}/entries');
    if (!entries.existsSync()) return;
    final raw = entries.readAsBytesSync();
    for (var at = 0; at + LogbookEntry.length <= raw.length;) {
      final bytes = Uint8List.sublistView(raw, at, at += LogbookEntry.length);
      final entry = LogbookEntry.parse(bytes)!.object;
      _head = EntryHash.of(bytes);
      _entries[entry] = bytes;
      final Uint8List? object;
      try {
        object = logbook.get(entry);
      } on CorruptObject {
        continue;
      }
      final header = object == null ? null : _Header.parse(object);
      if (header == null) continue;
      _index(entry, header);
      final previous = header.previous;
      if (previous != null && !_isTip(previous)) continue;
      _link(entry, previous);
      _own(entry, header, object!);
    }
  }

  void _index(ObjectId entry, _Header header) {
    _at[entry] = _order.length;
    _order.add(_Indexed(entry, header));
  }

  /// Indexes and links [bytes], just added as the 96 bytes [link], and sends
  /// them to the readers subscribed to their kind.
  void _added(EntryHash link, _Header header, Uint8List bytes) {
    final entry = ObjectId.of(bytes);
    final raw = LogbookEntry(_head, logbook.codeHash, entry).encode();
    if (EntryHash.of(raw) == link) {
      _entries[entry] = raw;
      _head = link;
      _index(entry, header);
      _link(entry, header.previous);
      _own(entry, header, bytes);
    } else {
      // Something else wrote to the logbook since: read it all back.
      _load();
    }
    for (final subscriber in _subscribers) {
      if (subscriber.wants(header.kind)) {
        _send(subscriber.socket, entry, header, bytes);
      }
    }
  }

  /// What [entry], just linked, does to who owns which chain: a
  /// `users-assigned-to-trajectory` root hands its chain to a trajectory, an
  /// attached root joins its parent's trajectory, a `mission-ended` closes a
  /// mission, and a `started` sets the kinds that attach. The same for an
  /// entry added now and one read back, so a restart refuses what the live
  /// service did. Whatever it cannot read was refused when it was sent, and
  /// owns nothing.
  void _own(ObjectId entry, _Header header, Uint8List bytes) {
    final body = _bodyOf(bytes);
    final kind = header.kind;
    if (kind == Kind.started) {
      _attaching = SenderTable.attachingIn(body);
      _lastStarted = entry;
    } else if (kind == Kind.missionEnded) {
      if (_MissionId.missionEndedIn(body) case final mission?) {
        _endedMissions.add(mission);
      }
    } else if (kind == Kind.trajectoryClosed) {
      if (_TrajectoryId.trajectoryClosedIn(body) case final trajectory?) {
        _closedTrajectories.add(trajectory);
      }
    } else if (header.previous != null) {
      return;
    } else if (kind == Kind.usersAssignedToTrajectory) {
      if (_UsersAssigned.parse(body) case final a?) {
        final trajectory = _Trajectory(
          a.trajectory,
          a.mission,
          _uid(a.loopUser),
          _uid(a.suit),
        );
        _trajectories[a.trajectory] = trajectory;
        _trajectoryOf[entry] = trajectory;
      }
    } else if (_attaching.contains(kind)) {
      if (_parentIn(body) case final parent?) {
        if (_trajectoryOf[_chainOf[parent]] case final trajectory?) {
          _trajectoryOf[entry] = trajectory;
        }
      }
    }
  }

  /// Why [header], sent by [uid], breaks a trajectory's ownership; null when it
  /// does not. Called after the tip check, so a previous entry is a tip.
  String? _ownership(int uid, _Header header, Uint8List request) {
    final body = _bodyOf(request);
    final kind = header.kind;
    String? owned(_Trajectory? trajectory) => switch (trajectory) {
      null => null,
      _ when _endedMissions.contains(trajectory.mission) =>
        'mission-ended ${trajectory.mission.hex}',
      _ when _closedTrajectories.contains(trajectory.id) =>
        'trajectory-closed ${trajectory.id.hex}',
      _ when trajectory.loopUser != uid => 'not-owner',
      _ => null,
    };

    if (kind == Kind.missionEnded && _MissionId.missionEndedIn(body) == null) {
      return 'mission-ended-body';
    }
    if (kind == Kind.trajectoryClosed &&
        _TrajectoryId.trajectoryClosedIn(body) == null) {
      return 'trajectory-closed-body';
    }
    if (header.previous case final previous?) {
      if (kind == Kind.usersAssignedToTrajectory) {
        return 'users-assigned-not-root';
      }
      return owned(_trajectoryOf[_chainOf[previous]]);
    }
    if (kind == Kind.usersAssignedToTrajectory) {
      return _refuseUsersAssigned(body);
    }
    if (!_attaching.contains(kind)) return null;
    final parent = _parentIn(body);
    if (parent == null) return 'no-parent';
    final start = _chainOf[parent];
    if (start == null) return 'unknown ${parent.hex}';
    final trajectory = _trajectoryOf[start];
    return trajectory == null ? 'parent-unowned' : owned(trajectory);
  }

  /// Why a `users-assigned-to-trajectory` with [body] cannot root a
  /// trajectory's chain: its body is not one, its trajectory was assigned
  /// before, it was closed or its mission ended, a user it names is not one, or an
  /// open trajectory holds either user. A trajectory's two users are never
  /// the same user, and no user is in use by two open trajectories, as
  /// either.
  String? _refuseUsersAssigned(Uint8List body) {
    final a = _UsersAssigned.parse(body);
    if (a == null) return 'users-assigned-body';
    if (_trajectories.containsKey(a.trajectory)) {
      return 'users-assigned-again ${a.trajectory.hex}';
    }
    // A trajectory can be closed before its users are assigned.
    if (_closedTrajectories.contains(a.trajectory)) {
      return 'trajectory-closed ${a.trajectory.hex}';
    }
    if (_endedMissions.contains(a.mission)) {
      return 'mission-ended ${a.mission.hex}';
    }
    final loopUser = _uid(a.loopUser);
    if (loopUser == null) return 'no-user ${a.loopUser}';
    final suit = _uid(a.suit);
    if (suit == null) return 'no-user ${a.suit}';
    if (loopUser == suit) return 'in-use ${a.suit}';
    for (final open in _trajectories.values) {
      if (_endedMissions.contains(open.mission) ||
          _closedTrajectories.contains(open.id)) {
        continue;
      }
      final inUse = {open.loopUser, open.suit};
      if (inUse.contains(loopUser)) return 'in-use ${a.loopUser}';
      if (inUse.contains(suit)) return 'in-use ${a.suit}';
    }
    return null;
  }

  int? _uid(String user) => _uids.putIfAbsent(user, () => _uidOf(user));

  bool _isTip(ObjectId entry) => switch (_chainOf[entry]) {
    final start? => _tipOf[start] == entry,
    null => false,
  };

  void _link(ObjectId entry, ObjectId? previous) {
    final start = previous == null ? entry : _chainOf[previous]!;
    _chainOf[entry] = start;
    _tipOf[start] = entry;
  }

  void _append(Kind kind, ObjectId? previous, Uint8List rest) {
    final bytes = Uint8List.fromList([
      ...utf8.encode('$kind\n${previous?.hex ?? '-'}\n'),
      ...rest,
    ]);
    _added(logbook.addEntry(bytes), _Header(kind, previous), bytes);
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
    final entry = ObjectId.of(request);
    if (_entries.containsKey(entry)) return 'refused duplicate ${entry.hex}';
    final previous = header.previous;
    if (previous != null) {
      final start = _chainOf[previous];
      if (start == null) return 'refused unknown ${previous.hex}';
      if (_tipOf[start] != previous) {
        return 'refused not-tip ${_tipOf[start]!.hex}';
      }
    }
    if (_ownership(uid, header, request) case final why?) {
      return 'refused $why';
    }
    try {
      _added(logbook.addEntry(request), header, request);
      return 'ok ${entry.hex}';
    } on FileSystemException catch (e) {
      // The entry may be in even though the add failed: read the chains
      // back rather than guess.
      _load();
      return 'failed ${e.message}';
    }
  }
}

extension on LogbookService {
  /// Reads one request line from a reader, then answers it. A reader only
  /// ever reads: nothing it sends reaches [LogbookService._answer].
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
    _subscribers.removeWhere((f) => f.socket == socket);
    socket.destroy();
  }

  /// `get <entry>`, `tip <entry>`, or `subscribe <kinds> from <entry>`:
  /// `<kinds>` is `*` or names joined by commas, and what comes after `from`
  /// is an entry, or `start` for the logbook's start.
  void _read(Socket socket, String request) {
    void refuse(String why) {
      socket.add(utf8.encode('refused $why\n'));
      socket.close();
    }

    switch (request.split(' ')) {
      case ['get', final hex] when ObjectId.parse(hex) != null:
        _get(socket, ObjectId.parse(hex)!);
      case ['tip', final hex] when ObjectId.parse(hex) != null:
        final start = _chainOf[ObjectId.parse(hex)!];
        if (start == null) return refuse('unknown $hex');
        socket.add(utf8.encode('tip ${_tipOf[start]!.hex}\n'));
        socket.close();
      case ['subscribe', final kinds, 'from', final after]
          when _Subscriber.parse(socket, kinds) != null &&
              _SubscribeFrom.parse(after) != null:
        final skip = switch (_SubscribeFrom.parse(after)!) {
          _FromStart() => 0,
          _FromAfter(:final entry) => switch (_at[entry]) {
            final at? => at + 1,
            null => null,
          },
        };
        if (skip == null) return refuse('unknown $after');
        final subscriber = _Subscriber.parse(socket, kinds)!;
        // Sent, marked and registered in one synchronous step, so no entry
        // added meanwhile is missed, sent twice, or lands unseen between
        // the backlog and the live entries.
        for (final indexed in _order.skip(skip)) {
          if (!subscriber.wants(indexed.header.kind)) continue;
          final bytes = logbook.get(indexed.entry);
          if (bytes != null) {
            _send(socket, indexed.entry, indexed.header, bytes);
          }
        }
        final head = _order.isEmpty ? 'start' : _order.last.entry.hex;
        socket.add(utf8.encode('caught-up $head\n'));
        _subscribers.add(subscriber);
      case _:
        refuse('not-a-request');
    }
  }

  /// Sends [entry] as `subscribe` does, with the 96 bytes that record it in
  /// hex after the length. The bytes alone prove themselves: they hash to
  /// [entry]. The 96 bytes name [entry] as their object, for a reader that
  /// also checks the logbook's chain. An entry with
  /// no header has `-` for its kind, which no kind can be. Otherwise one
  /// line: `none` when the logbook holds no such entry, `unreadable` when
  /// it does but its object is `missing` or `corrupt`, `failed` when the
  /// object could not be read.
  void _get(Socket socket, ObjectId entry) {
    void answer(String line) {
      socket.add(utf8.encode('$line\n'));
      socket.close();
    }

    final raw = _entries[entry];
    if (raw == null) return answer('none ${entry.hex}');
    final Uint8List? bytes;
    try {
      bytes = logbook.get(entry);
    } on CorruptObject {
      return answer('unreadable ${entry.hex} corrupt');
    } on FileSystemException catch (e) {
      return answer('failed ${e.message.replaceAll('\n', ' ')}');
    }
    if (bytes == null) return answer('unreadable ${entry.hex} missing');
    final header = _Header.parse(bytes);
    final hex = raw.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    socket
      ..add(
        utf8.encode(
          'entry ${entry.hex} ${header?.kind ?? '-'} '
          '${header?.previous?.hex ?? '-'} ${bytes.length} $hex\n',
        ),
      )
      ..add(bytes)
      ..close();
  }
}

/// Writes one entry to a reader: `entry <id> <kind> <previous> <length>`,
/// a newline, and its bytes exactly as recorded.
void _send(Socket socket, ObjectId entry, _Header header, Uint8List bytes) {
  socket
    ..add(
      utf8.encode(
        'entry ${entry.hex} ${header.kind} ${header.previous?.hex ?? '-'} '
        '${bytes.length}\n',
      ),
    )
    ..add(bytes);
}

/// An entry the service knows: its id and its header.
final class _Indexed {
  _Indexed(this.entry, this.header);

  final ObjectId entry;
  final _Header header;
}

/// A reader subscribed to [kinds] (null for every kind) on [socket].
final class _Subscriber {
  _Subscriber(this.socket, this.kinds);

  final Socket socket;
  final Set<String>? kinds;

  static _Subscriber? parse(Socket socket, String kinds) {
    if (kinds == '*') return _Subscriber(socket, null);
    final names = kinds.split(',');
    return names.every((n) => n == Kind.started.name || Kind.parse(n) != null)
        ? _Subscriber(socket, names.toSet())
        : null;
  }

  bool wants(Kind kind) => kinds?.contains(kind.name) ?? true;
}

/// Where a subscription starts: the logbook's start, or just after an entry.
sealed class _SubscribeFrom {
  const _SubscribeFrom();

  /// `start`, or an entry's id; null when [word] is neither.
  static _SubscribeFrom? parse(String word) => word == 'start'
      ? const _FromStart()
      : switch (ObjectId.parse(word)) {
          final entry? => _FromAfter(entry),
          null => null,
        };
}

final class _FromStart extends _SubscribeFrom {
  const _FromStart();
}

final class _FromAfter extends _SubscribeFrom {
  const _FromAfter(this.entry);

  final ObjectId entry;
}

/// The id of a trajectory, which only one
/// `users-assigned-to-trajectory` ever names.
final class _TrajectoryId extends Sha256Name {
  _TrajectoryId._(super.digest);

  static _TrajectoryId? parse(String s) => switch (Sha256Name.digestOfHex(s)) {
    final d? => _TrajectoryId._(d),
    null => null,
  };

  /// The trajectory a `trajectory-closed` entry's [body] names: a JSON object
  /// whose `trajectory` is a trajectory id. The rest of the body is the
  /// docking station's to read. Null when it names none.
  static _TrajectoryId? trajectoryClosedIn(Uint8List body) =>
      switch (_json(body)) {
        {'trajectory': final String trajectory} => parse(trajectory),
        _ => null,
      };
}

/// The id of a mission, which a `mission-ended` closes.
final class _MissionId extends Sha256Name {
  _MissionId._(super.digest);

  static _MissionId? parse(String s) => switch (Sha256Name.digestOfHex(s)) {
    final d? => _MissionId._(d),
    null => null,
  };

  /// The mission a `mission-ended` entry's [body] names: a JSON object whose
  /// `mission` is a mission id. The rest of the body is the docking
  /// station's to read. Null when it names none.
  static _MissionId? missionEndedIn(Uint8List body) => switch (_json(body)) {
    {'mission': final String mission} => parse(mission),
    _ => null,
  };
}

/// [body] as JSON, or null when it is not.
Object? _json(Uint8List body) {
  try {
    return jsonDecode(utf8.decode(body));
  } on FormatException {
    return null;
  }
}

/// A trajectory as its `users-assigned-to-trajectory` entry handed it
/// out: its id, its mission, the one user who may extend its chains, and the
/// user that wears its suit. A user that could not be found is null, and
/// matches no sender.
final class _Trajectory {
  _Trajectory(this.id, this.mission, this.loopUser, this.suit);

  final _TrajectoryId id;
  final _MissionId mission;
  final int? loopUser;
  final int? suit;
}

/// A `users-assigned-to-trajectory` entry's body, read strictly: exactly
/// `{"trajectory","mission","loopUser","suit"}`, the ids in lower-case
/// hex and the users as names or uids.
final class _UsersAssigned {
  _UsersAssigned(this.trajectory, this.mission, this.loopUser, this.suit);

  final _TrajectoryId trajectory;
  final _MissionId mission;
  final String loopUser;
  final String suit;

  /// A user's name or uid, never one `id` could read as an option.
  static final _user = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9._-]*$');

  static _UsersAssigned? parse(Uint8List body) {
    final json = _json(body);
    if (json
        case {
          'trajectory': final String trajectory,
          'mission': final String mission,
          'loopUser': final String loopUser,
          'suit': final String suit,
        }
        when json.length == 4 &&
            _user.hasMatch(loopUser) &&
            _user.hasMatch(suit)) {
      return switch ((
        _TrajectoryId.parse(trajectory),
        _MissionId.parse(mission),
      )) {
        (final t?, final m?) => _UsersAssigned(t, m, loopUser, suit),
        _ => null,
      };
    }
    return null;
  }
}

/// What follows an entry's two header lines.
Uint8List _bodyOf(Uint8List bytes) {
  final first = bytes.indexOf(0x0a);
  return Uint8List.sublistView(bytes, bytes.indexOf(0x0a, first + 1) + 1);
}

/// The parent an attached root names on its body's first line: an entry's
/// id and a newline. Null when it names none.
ObjectId? _parentIn(Uint8List body) {
  final nl = body.indexOf(0x0a);
  if (nl < 0) return null;
  return ObjectId.parse(
    ascii.decode(Uint8List.sublistView(body, 0, nl), allowInvalid: true),
  );
}

/// The first two lines of an entry the service writes: its kind and the
/// entry before it in its chain, null for none.
final class _Header {
  _Header(this.kind, this.previous);

  final Kind kind;
  final ObjectId? previous;

  static _Header? parse(Uint8List bytes) {
    final first = bytes.indexOf(0x0a);
    if (first < 0) return null;
    final second = bytes.indexOf(0x0a, first + 1);
    if (second < 0) return null;
    final kindText = ascii.decode(bytes.sublist(0, first), allowInvalid: true);
    final kind = kindText == Kind.started.name
        ? Kind.started
        : Kind.parse(kindText);
    final previousText = ascii.decode(
      bytes.sublist(first + 1, second),
      allowInvalid: true,
    );
    final previous = previousText == '-' ? null : ObjectId.parse(previousText);
    if (kind == null || (previousText != '-' && previous == null)) return null;
    return _Header(kind, previous);
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
