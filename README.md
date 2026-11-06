# is_journal

An add-only journal of bytes. A caller adds what it is about to act on before
it acts, and each entry is chained to the one before it and names the hash of
the code that wrote it. It is small enough to read in one sitting, because the
point of a journal is that nothing checks it as it runs: a person reads it
instead.

```dart
import 'dart:convert';
import 'dart:io';

import 'package:is_journal/is_journal.dart';

void main() {
  final journal = Journal.open(Directory('journal'))!;
  final id = journal.add(utf8.encode('what went up'));
  print('$id, written by ${journal.codeHash}');
  journal.close();
}
```

In [intersyntactic](https://github.com/enspyrco/intersyntactic) it is the
airlock's record driver: the one driver whose effects the airlock does not
decide, since deciding them would need a record of their own. The airlock adds
each effect it is asked to hand to a driver, whether it hands it over or
refuses it, before anything acts on it.

## What it keeps

One directory, which it only ever adds to:

- **Objects** in `objects/<2>/<62>`: bytes named by their sha256, kept whole.
  Each is written when that name is absent or no longer holds them, and
  checked against its name whenever it is read (`CorruptObject` if it no
  longer matches). The same bytes are the same object whoever wrote them, so
  two journals merge by copying objects in, and an object missing or damaged
  here is restored by copying its file in from another copy of the journal.
- **The entries** in `entries`: one for every `add`, that is, each time a
  caller records bytes before it acts on them (sends, reads or decides them),
  even bytes already stored, added before the object. An entry says nothing of
  what the bytes are: whether they went out, came in or were refused is for
  the caller to write into them, so a caller adds one entry for each thing
  that crosses: the bytes as they are handed over, with whatever it says
  about them. Each entry is three names, 96 bytes:

  | bytes | what |
  |---|---|
  | 0–31 | the sha256 of the entry before it |
  | 32–63 | the hash of the code that wrote it |
  | 64–95 | the object's id |

  The first entry names, as the entry before it, the sha256 of
  `is_journal/1`, the journal format's name. An entry torn by a crash is
  padded with zeros before the journal writes again, so its object id, cut
  short, names no object here.

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
cannot tell. So run what the journal watches as an OS user that cannot write
them, in a process that cannot reload this code: a journal reloaded in place
keeps the hash it computed when it opened. A separate user stops a mistaken
program, or another writer, from changing the journal. It is not a sandbox,
and does not contain a program set on getting out of it.

There is one writer per directory. `Journal.open` creates `writer.<pid>` only
if it is absent, so a second journal in the same process, in any isolate,
cannot open the directory until the first calls `close()`. Dart has no append
that cannot overwrite, and two writers in one process would write over each
other's entries. Separate processes take turns at each entry through a lock.

## Checking it

The code hash is the sha256 of what `shasum -a 256` prints for this package's
`lib/` files, so it can be checked without running any of its code. From the
package's root:

    (cd lib && find . -type f -name '*.dart' -print0 |
      LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256)

The journal computes the same hash from its own source when it opens. Add the
hash you checked to `approved` beside the entries, one per line: the line
`shasum` prints will do as it is, and anything after the hash on its line is
yours, such as when you checked it. Every entry names the code that wrote it,
so which entries came from code you checked is read from `approved` whenever
the journal is read (`approved()`), never written into the entries: approving
a hash covers what it already wrote, and deleting its line takes that back.
The journal reads `approved` and never writes it.

`Journal.open` returns null when the journal cannot compute its hash the way
that command does: in a build with no source on disk, or when `lib/` holds a
link or a file name `shasum` would print differently. A journal that cannot
name its code writes nothing.

The journal can be checked without this package too. From the journal's
directory, in bash:

    p=$(printf 'is_journal/1' | shasum -a 256 | cut -c1-64); n=0
    while read -r e; do
      [ ${#e} = 192 ] || { echo "$((${#e} / 2)) bytes after the last whole entry"; break; }
      n=$((n + 1)); o=${e:128:64}
      [ "${e:0:64}" = "$p" ] || echo "entry $n is broken"
      [ -f "objects/${o:0:2}/${o:2}" ] || echo "entry $n's object is missing"
      p=$(printf %s "$e" | xxd -r -p | shasum -a 256 | cut -c1-64)
    done < <(xxd -p -c 96 entries)
    echo "$n entries, head $p"

## What it imports

`dart:io`, `dart:isolate`, `dart:typed_data` and
[`is_content_id`](https://pub.dev/packages/is_content_id), which holds
`ObjectId` and the sha256 every name is made with. The journal re-exports it,
so importing the journal gives you `ObjectId` too. The code hash names this
package's own `lib/` only: `is_content_id` comes from pub.dev, and an app's
`pubspec.lock` records the version it resolved and the sha256 of that
version's archive.
