# is_journal

An add-only journal of bytes. Each entry is chained to the one before it and
names the bytes and the hash of the code that wrote it. It is small enough to
read in one sitting: nothing checks it as it runs, so a person reads it
instead, and every entry names the code they read.

```dart
import 'dart:convert';
import 'dart:io';

import 'package:is_journal/is_journal.dart';

void main() {
  final journal = Journal.open(Directory('journal'))!;
  final id = journal.add(utf8.encode('hello'));
  print('$id, written by ${journal.codeHash}');
  journal.close();
}
```

## What it keeps

One directory, which it only ever adds to:

- **Objects** in `objects/<2>/<62>`: bytes named by their sha256, kept whole.
  Each is written when that name is absent or no longer holds them, and
  checked against its name whenever it is read (`CorruptObject` if it no
  longer matches). The same bytes are the same object whoever wrote them, so
  two journals merge by copying objects in, and an object missing or damaged
  here is restored by copying its file in from another copy of the journal.
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
  `is_journal/1`, the journal format's name. An entry torn by a crash is cut
  off before the journal writes again: its add never returned, and its
  object, written after it, was never kept.

- **`lock`**, empty, which processes take turns through: see below.
- **`writer.<pid>`**, while a journal has the directory open: see below.

`check()` says which entries do not name the entry before them, and which
name an object that is not in `objects/` (`Broken`), or that there is no
journal (`NoJournal`), or that every entry chains and its object is here
(`Intact`), with the journal's `head`: the hash of its last entry. Whether an
object still holds its bytes is checked each time it is read.

The chain is a checksum against damage and drift: a crash, a bug, a failing
disk, or code nobody reviewed. It proves nothing to anyone else, and it is not
proof against someone set on editing it: entries cut from the end leave a
journal that is still `Intact`, and sha256 has no secret, so whoever can write
the file can recompute it.

Whatever can write the journal's directory, this package's code or `approved`
can change what the journal says, by mistake or otherwise, and the chain
cannot tell. A journal whose code is reloaded in place keeps the hash it
computed when it opened.

There is one writer per directory. `Journal.open` creates `writer.<pid>` only
if it is absent, so a second journal in the same process, in any isolate,
cannot open the directory until the first calls `close()`, and a journal
cannot be sent to another isolate, since sending would copy it. The journal
holds a lock on its `writer.<pid>` while open, so one left by a process that
ended without closing, which no lock holds, is deleted when a journal in
another process next opens the directory. Dart has no
append that cannot overwrite, and two writers in one process would write over
each other's entries. Separate processes take turns at each entry through a
lock on `lock`, a file nothing else has a reason to open: closing any
descriptor on a file gives up every lock its process holds on that file, so a
lock on `entries` would end whenever anything in the process read them. A
relative directory is resolved when the journal opens.

## Checking it

The code hash is the sha256 of what `shasum -a 256` prints for the `lib/`
files of this package and of the `is_content_id` it runs with, each path
under its package's name, so it can be checked without running any of its
code. From the root of this package, or of an app that uses it, after
`dart pub get`:

    (cd .dart_tool && for p in is_content_id is_journal; do
      r=$(sed -n "/\"name\": \"$p\"/{n;s|.*\"rootUri\": \"\(file://\)\{0,1\}\(.*\)\",|\2|p;}" package_config.json)
      (cd "$r/lib" && find . -type f -name '*.dart' -print0 | LC_ALL=C sort -z |
        xargs -0 shasum -a 256 | sed "s|  \./|  ./$p/|")
    done | shasum -a 256)

The journal computes the same hash from its own source when it opens. Add the
hash you checked to `approved` beside the entries, one per line: the line
`shasum` prints will do as it is, and anything after the hash on its line is
yours, such as when you checked it. Every entry names the code that wrote it,
so which entries came from code you checked is read from `approved` whenever
the journal is read (`approved()`), never written into the entries: approving
a hash covers what it already wrote, and deleting its line takes that back.
The journal reads `approved` and never writes it.

`Journal.open` returns null when the journal cannot compute its hash the way
that command does: when `lib/` holds a link or a file name `shasum` would
print differently, or in a compiled build not given the hash. A journal that
cannot name its code writes nothing. Give a compiled build its hash when you
compile it:

    dart compile exe $(dart run is_journal:code_hash) bin/main.dart

The journal can be checked without this package too. From the journal's
directory, in bash:

    if [ ! -f entries ]; then echo "no journal here"
    elif ! command -v xxd > /dev/null; then echo "this needs xxd"
    else
      p=$(printf 'is_journal/1' | shasum -a 256 | cut -c1-64); n=0
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

`package:is_journal/service.dart` is a journal's one writer, which other
processes send entries to over a Unix socket. A request is the bytes to
record, starting with `<kind>\n<previous>\n`: a kind the sender's user may
write, and the entry before this one in its chain, or `-` to start a chain.
The service reads the user from the socket, refuses a kind the sender table
doesn't give that user, and refuses an entry whose previous isn't its
chain's tip, naming the tip. It answers `ok <entry hash>` or `refused <why>`. On every start it adds
an entry holding the sender table in force.

`ok` means the entry and its bytes outlast the service crashing or being
killed. It does not promise they outlast a power cut: the rename that puts the
bytes in place is not flushed to its folder, which Dart has no call for. A
power cut can leave an entry whose bytes are missing, so you know something
was recorded but not what. `check()` reports it, as an entry whose object is
missing. This is chosen, not overlooked: a sender that acts after `ok` is
covered against crashes, and a power cut on the journal's machine is rare
enough to accept a reported hole. What closing it would take, measured, is in
[issue 13](https://github.com/intersyntactic/journal/issues/13).

    JOURNAL_DIR=/var/lib/record JOURNAL_SOCKET=/run/record/journal.sock \
      JOURNAL_SENDERS=/etc/record/senders dart run is_journal:service

The sender table has one line per user, then the kinds that user may send:

    airlock witnessed decided returned narrowed
    loop turn

### Chains a journey path owns

Most chains take an entry from any user the table lets send its kind. A
journey path's chain is different: only one user may extend it. Two kinds
mean something to the service for this, and every other kind still means
nothing:

- `assigned` starts a path's chain (its previous must be `-`). Its body is
  exactly `{"journeyPath","journey","loopUser","suit"}`: the path and
  journey as 64 lower-case hex, the two users as names or uids. From then
  on, an entry on that chain is refused (`refused not-owner`) unless its
  sender is the `loopUser`. The service refuses an `assigned` for a path
  that was ever assigned before (`assigned-again`), a user it cannot find
  (`no-user`), and a user an open path already holds, as either its loop
  user or its suit (`in-use`). A path's two users are never the same user.
- `ended` closes a journey: every chain whose `assigned` names that journey,
  and every chain attached to one, refuses further entries
  (`refused closed <journey>`), and their users are free again. Its body is
  a JSON object whose `journey` is 64 lower-case hex; the service reads
  nothing else in it. It takes the tip check like any entry, so it can
  follow the decisions before it on one chain. Ending a journey twice
  changes nothing.

A kind the table lists on an `attaching:` line starts a chain of its own
that belongs to a path, such as a reply sent in chunks beside the turns. Its
first body line names its parent: an entry hash and a newline. It is refused
unless the parent is on a chain a path owns and the sender is that path's
loop user, and it closes with the path's journey:

    attaching: reply-chunk
    launcher assigned
    docking ended

Who owns what is read back from the journal on every start, so a restart
refuses exactly what the service refused before it. Each attached chain is
judged by the `attaching:` line of the table in force when it was added,
which the `started` entry before it holds.

Given `JOURNAL_READ_SOCKET`, it also listens for readers there, who can only
read. The journal publishes each entry it keeps, and a reader subscribes to
it. A reader sends one line:

- `subscribe <kinds> from <entry>`: every entry of those kinds (`*`, or
  names joined by commas) after `<entry>` (`start` for the journal's start),
  then each new one as it is added, while the reader stays connected. Each
  comes as `entry <hash> <kind> <previous> <length>`, a newline, and exactly
  `<length>` bytes as recorded, which need not end in a newline. Between the
  backlog and the first new entry comes one line, `caught-up <head>`: the
  journal's last entry of any kind when the backlog ended, or `start`, which
  is also a place to subscribe from next time.
- `tip <entry>`: answered `tip <hash>`, the tip of that entry's chain.
- `get <entry>`: that entry, as `subscribe` sends it, with one more word
  after the length: the entry's 96 bytes in hex. Check both names: those 96
  bytes hash to `<entry>`, and bytes 64–95 of them are the sha256 of the
  bytes after it. An entry written without a header comes with `-` for
  its kind and its previous. Otherwise one line: `none <entry>` when the journal
  holds no such entry, `unreadable <entry> missing` or `corrupt` when it
  does but its bytes are gone or changed, or `failed <why>` when they could
  not be read.

`<hash>` is the hash `ok` answered when the entry was written. A reader keeps
its side of the connection open until the answer has come: the service
closes it after `tip` and `get`.

## What it imports

`dart:convert`, `dart:io`, `dart:isolate`, `dart:typed_data` and
[`is_content_id`](https://pub.dev/packages/is_content_id), which holds
`ObjectId`, `FileSetId` and the sha256 every name is made with. The journal
re-exports it, and its code is in the code hash, so a new version of it
changes the hash.
