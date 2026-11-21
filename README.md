# is_logbook

An add-only logbook of bytes. Each entry is chained to the one before it and
names the bytes and the hash of the code that wrote it. It is small enough to
read in one sitting: nothing checks it as it runs, so a person reads it
instead, and every entry names the code they read.

```dart
import 'dart:convert';
import 'dart:io';

import 'package:is_logbook/is_logbook.dart';

void main() {
  final logbook = Logbook.open(Directory('logbook'))!;
  final id = logbook.add(utf8.encode('hello'));
  print('$id, written by ${logbook.codeHash}');
  logbook.close();
}
```

## What it keeps

One directory, which it only ever adds to:

- **Objects** in `objects/<2>/<62>`: bytes named by their sha256, kept whole.
  Each is written when that name is absent or no longer holds them, and
  checked against its name whenever it is read (`CorruptObject` if it no
  longer matches). The same bytes are the same object whoever wrote them, so
  two logbooks merge by copying objects in, and an object missing or damaged
  here is restored by copying its file in from another copy of the logbook.
- **The entries** in `entries`: one for every `add`, even of bytes already
  kept, each added before its object. An entry says nothing of what the bytes
  are; that is for whoever adds them to write into them. Each entry is three
  names, 96 bytes:

  | bytes | what |
  |---|---|
  | 0–31 | the sha256 of the entry before it |
  | 32–63 | the hash of the code that wrote it |
  | 64–95 | the object's id |

  The first entry names, as the entry before it, the sha256 of
  `is_logbook/1`, the logbook format's name. An entry torn by a crash is cut
  off before the logbook writes again: its add never returned, and its
  object, written after it, was never kept.

- **`lock`**, empty, which processes take turns through: see below.
- **`writer.<pid>`**, while a logbook has the directory open: see below.

`check()` says which entries do not name the entry before them, and which
name an object that is not in `objects/` (`Broken`), or that there is no
logbook (`NoLogbook`), or that every entry chains and its object is here
(`Intact`), with the logbook's `head`: the hash of its last entry. Whether an
object still holds its bytes is checked each time it is read.

The chain is a checksum against damage and drift: a crash, a bug, a failing
disk, or code nobody reviewed. It proves nothing to anyone else, and it is not
proof against someone set on editing it: entries cut from the end leave a
logbook that is still `Intact`, and sha256 has no secret, so whoever can write
the file can recompute it.

Whatever can write the logbook's directory, this package's code or `approved`
can change what the logbook says, by mistake or otherwise, and the chain
cannot tell. A logbook whose code is reloaded in place keeps the hash it
computed when it opened.

There is one writer per directory. `Logbook.open` creates `writer.<pid>` only
if it is absent, so a second logbook in the same process, in any isolate,
cannot open the directory until the first calls `close()`, and a logbook
cannot be sent to another isolate, since sending would copy it. The logbook
holds a lock on its `writer.<pid>` while open, so one left by a process that
ended without closing, which no lock holds, is deleted when a logbook in
another process next opens the directory. Dart has no
append that cannot overwrite, and two writers in one process would write over
each other's entries. Separate processes take turns at each entry through a
lock on `lock`, a file nothing else has a reason to open: closing any
descriptor on a file gives up every lock its process holds on that file, so a
lock on `entries` would end whenever anything in the process read them. A
relative directory is resolved when the logbook opens.

## Checking it

The code hash is the sha256 of what `shasum -a 256` prints for the `lib/`
files of this package and of the `is_content_id` it runs with, each path
under its package's name, so it can be checked without running any of its
code. From the root of this package, or of an app that uses it, after
`dart pub get`:

    (cd .dart_tool && for p in is_content_id is_logbook; do
      r=$(sed -n "/\"name\": \"$p\"/{n;s|.*\"rootUri\": \"\(file://\)\{0,1\}\(.*\)\",|\2|p;}" package_config.json)
      (cd "$r/lib" && find . -type f -name '*.dart' -print0 | LC_ALL=C sort -z |
        xargs -0 shasum -a 256 | sed "s|  \./|  ./$p/|")
    done | shasum -a 256)

The logbook computes the same hash from its own source when it opens. Add the
hash you checked to `approved` beside the entries, one per line: the line
`shasum` prints will do as it is, and anything after the hash on its line is
yours, such as when you checked it. Every entry names the code that wrote it,
so which entries came from code you checked is read from `approved` whenever
the logbook is read (`approved()`), never written into the entries: approving
a hash covers what it already wrote, and deleting its line takes that back.
The logbook reads `approved` and never writes it.

`Logbook.open` returns null when the logbook cannot compute its hash the way
that command does: when `lib/` holds a link or a file name `shasum` would
print differently, or in a compiled build not given the hash. A logbook that
cannot name its code writes nothing. Give a compiled build its hash when you
compile it:

    dart compile exe $(dart run is_logbook:code_hash) bin/main.dart

The logbook can be checked without this package too. From the logbook's
directory, in bash:

    if [ ! -f entries ]; then echo "no logbook here"
    elif ! command -v xxd > /dev/null; then echo "this needs xxd"
    else
      p=$(printf 'is_logbook/1' | shasum -a 256 | cut -c1-64); n=0
      while read -r e; do
        [ ${#e} = 192 ] || { echo "$((${#e} / 2)) bytes after the last whole entry"; break; }
        n=$((n + 1)); o=${e:128:64}
        [ "${e:0:64}" = "$p" ] || echo "entry $n is broken"
        [ -f "objects/${o:0:2}/${o:2}" ] || echo "entry $n's object is missing"
        p=$(printf %s "$e" | xxd -r -p | shasum -a 256 | cut -c1-64)
      done < <(xxd -p -c 96 entries)
      echo "$n entries, head $p"
    fi

## One writer, many senders

`package:is_logbook/service.dart` is a logbook's one writer, which other
processes send entries to over a Unix socket. A request is the bytes to
record, starting with `<kind>\n<previous>\n`: a kind the sender's user may
write, and the entry before this one in its chain, or `-` to start a chain.
The service reads the user from the socket, refuses a kind the sender table
doesn't give that user, refuses bytes it already holds
(`refused duplicate <id>`), and refuses an entry whose previous isn't its
chain's tip, naming the tip. It answers `ok <id>` or `refused <why>`. On
every start it adds a `started` entry holding the sender table in force,
naming the last `started` as its previous.

An entry's id is the sha256 of the bytes sent, header and all: the
`ObjectId` of what it records. A sender can compute it before sending, and
every reader and every copy of the logbook computes the same one. Since the
bytes are the identity, two entries with the same kind, previous and body are
one entry: a writer that means two makes the bytes differ. A resend of bytes
that got in is answered `refused duplicate <id>`, which says they are in, so
resending after a lost answer is safe. The 96 bytes that chain the logbook
(above) are its own check, and never an id on the socket.

`ok` means the entry and its bytes outlast the service crashing or being
killed. It does not promise they outlast a power cut: the rename that puts the
bytes in place is not flushed to its folder, which Dart has no call for. A
power cut can leave an entry whose bytes are missing, so you know something
was recorded but not what. `check()` reports it, as an entry whose object is
missing. This is chosen, not overlooked: a sender that acts after `ok` is
covered against crashes, and a power cut on the logbook's machine is rare
enough to accept a reported hole. What closing it would take, measured, is in
[issue 13](https://github.com/intersyntactic/logbook/issues/13).

    LOGBOOK_DIR=/var/lib/record LOGBOOK_SOCKET=/run/record/logbook.sock \
      LOGBOOK_SENDERS=/etc/record/senders dart run is_logbook:service

The sender table has one line per user, then the kinds that user may send:

    airlock witnessed decided returned narrowed
    loop turn

### Chains a trajectory owns

Most chains take an entry from any user the table lets send its kind. A
trajectory's chain is different: only one user may extend it. Three kinds
mean something to the service for this, and every other kind still means
nothing:

- `users-assigned-to-trajectory` starts a trajectory's chain (its previous
  must be `-`). Its body is exactly
  `{"trajectory","mission","loopUser","suit"}`: the trajectory and mission
  as 64 lower-case hex, the two users as names or uids. From then on, an
  entry on that chain is refused (`refused not-owner`) unless its sender is
  the `loopUser`. The service refuses a `users-assigned-to-trajectory` for
  a trajectory that was ever assigned before
  (`users-assigned-again <trajectory>`), for a trajectory already closed
  (`trajectory-closed <trajectory>`) or a mission already ended
  (`mission-ended <mission>`), a user it cannot find (`no-user`), and a user
  an open trajectory already holds, as either its loop user or its suit
  (`in-use`). A trajectory's two users are never the same user.
- `mission-ended` closes a mission: every chain whose
  `users-assigned-to-trajectory` names that mission, and every chain
  attached to one, refuses further entries
  (`refused mission-ended <mission>`), and their users are free again. Its
  body is a JSON object whose `mission` is 64 lower-case hex; the service
  reads nothing else in it. It takes the tip check like any entry, so it can
  follow the decisions before it on one chain. Ending a mission twice
  changes nothing.
- `trajectory-closed` closes one trajectory as `mission-ended` closes a
  mission: its chain and every chain attached to it refuse further entries
  (`refused trajectory-closed <trajectory>`), and its users are free again.
  Its body is a JSON object whose `trajectory` is 64 lower-case hex; the
  service reads nothing else in it (`trajectory-closed-body` when it has
  none). A trajectory can be closed before its users are assigned: its
  `users-assigned-to-trajectory` is then refused. Closing a trajectory twice
  changes nothing.

A kind the table lists on an `attaching:` line starts a chain of its own
that belongs to a trajectory, such as a reply sent in chunks beside the
turns. Its first body line names its parent: an entry's id and a newline. It
is refused unless the parent is on a chain a trajectory owns and the sender
is that trajectory's loop user, and it closes with the trajectory's mission:

    attaching: reply-chunk
    loop-launcher users-assigned-to-trajectory
    docking-station mission-ended trajectory-closed

Who owns what is read back from the logbook on every start, so a restart
refuses exactly what the service refused before it. Each attached chain is
judged by the `attaching:` line of the table in force when it was added,
which the `started` entry before it holds.

A test can start the service with users this machine does not have, by
passing `LogbookService.start` a `uidOf` that maps names to uids. That
replaces looking a name up, not being that user: the service still compares
the uid of whoever is on the other end of the socket with the loop user's,
and no process can choose its own. So a test that writes past a
`users-assigned-to-trajectory` maps the loop user to its own uid; the suit,
which never writes, can be any number:

    final uids = {'loop-1': UserId.parse(myUid)!, 'suit-1': UserId.parse(5001)!};
    LogbookService.start(logbook, table, socket, uidOf: (user) => uids[user]);

Who is on the other end of the socket is read by
[`is_unix_socket_user_check`](https://github.com/intersyntactic/unix_socket_user_check)'s
`SocketUserReader`, from the kernel's `SO_PEERCRED` (Linux) or
`LOCAL_PEERCRED` (macOS). A user it cannot name is refused. Users are
`UserId`s, which cannot be 65534 (the overflow uid a user unmapped in the
service's user namespace reads as), `nobody` or `(uid_t)-1`, so a sender
table or a `users-assigned-to-trajectory` naming one is refused rather than
letting in every unmapped user. A test can pass `LogbookService.start` a
`socketUserReader` that fakes the socket read, to be any user.

Given `LOGBOOK_READ_SOCKET`, it also listens for readers there, who can only
read. The logbook publishes each entry it keeps, and a reader subscribes to
it. A reader sends one line:

- `subscribe <kinds> from <entry>`: every entry of those kinds (`*`, or
  names joined by commas) after `<entry>` (`start` for the logbook's start),
  then each new one as it is added, while the reader stays connected. Each
  comes as `entry <id> <kind> <previous> <length>`, a newline, and exactly
  `<length>` bytes as recorded, which need not end in a newline; their
  sha256 is `<id>`, so a reader checks every one. Between the
  backlog and the first new entry comes one line, `caught-up <head>`: the
  logbook's last entry of any kind when the backlog ended, or `start`, which
  is also a place to subscribe from next time.
- `tip <entry>`: answered `tip <id>`, the tip of that entry's chain.
- `get <entry>`: that entry, as `subscribe` sends it, with one more word
  after the length: the 96 bytes that record it, in hex, whose bytes 64–95
  are `<entry>`, for a reader that also checks the logbook's chain. The
  bytes prove themselves: their sha256 is `<entry>`. An entry written
  without a header comes with `-` for
  its kind and its previous. Otherwise one line: `none <entry>` when the logbook
  holds no such entry, `unreadable <entry> missing` or `corrupt` when it
  does but its bytes are gone or changed, or `failed <why>` when they could
  not be read.

`<id>` is the id `ok` answered when the entry was written. A reader keeps
its side of the connection open until the answer has come: the service
closes it after `tip` and `get`.

## What it imports

`dart:convert`, `dart:io`, `dart:isolate`, `dart:typed_data` and
[`is_content_id`](https://pub.dev/packages/is_content_id), which holds
`ObjectId`, `FileSetId` and the sha256 every name is made with. The logbook
re-exports it, and its code is in the code hash, so a new version of it
changes the hash.
