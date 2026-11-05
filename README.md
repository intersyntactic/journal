# is_airlock_record_driver

The driver that writes intersyntactic's airlock record: what crosses between a
person's home and the outside, either way, and every effect the airlock
decides, each written before anything acts on it. This is the one driver whose
writes the airlock does not decide, since deciding them would need a record of
their own. So it is small enough to read in one sitting, and it names the hash
of its own code in every entry it writes.

```dart
import 'dart:convert';
import 'dart:io';

import 'package:is_airlock_record_driver/is_airlock_record_driver.dart';

void main() {
  final driver = RecordDriver.open(Directory('airlock_record'))!;
  final id = driver.put(utf8.encode('what went up'));
  print('$id, written by ${driver.hash}');
  driver.close();
}
```

## What it keeps

One directory, which it only ever adds to:

- **Objects** in `objects/<2>/<62>`: bytes named by their sha256. Each is
  written when that name is absent or no longer holds them, and checked against
  its name whenever it is read (`CorruptObject` if it no longer matches). The same bytes are the
  same object whoever wrote them, so two records merge by copying objects in.
- **The entries** in `entries`: one for every `put`, that is, each time a
  caller records bytes before it acts on them (sends, reads or decides them),
  even bytes already stored, added before the object. An entry says nothing of
  what the bytes are: whether they went out, came in or were refused is for
  the caller to write into them. Each entry is three names, 96 bytes:

  | bytes | what |
  |---|---|
  | 0–31 | the sha256 of the entry before it |
  | 32–63 | the driver's own hash |
  | 64–95 | the object's id |

  The first entry names, as the entry before it, the sha256 of
  `is_airlock_record_driver/2`, the record format's name. (Format 1 ended each
  entry with a byte saying whether its driver was approved; see below for why
  that is read from `approved` instead.) An entry torn by a crash is padded
  with zeros before the driver writes again, so its object id, cut short,
  names no object here.

- **`writer.<pid>`**, while a driver has the directory open: see below.

`check()` says which entries do not name the entry before them, and which
name an object that is not in `objects/` (`Broken`), or that
there is no record (`NoRecord`), or that every entry chains and its object is
here (`Intact`), with the record's `head`: the hash of its last entry. Whether
an object still holds its bytes is checked each time it is read.

The chain is a checksum against damage and drift: a crash, a bug, a failing
disk, or a driver nobody reviewed. It proves nothing to anyone else, and it is
not proof against someone set on editing it: entries cut from the end leave a
record that is still `Intact`, and sha256 has no secret, so whoever can write
the file can recompute it.

Whatever can write the record's directory, the driver's code or `approved` can
change what the record says, by mistake or otherwise, and the chain cannot
tell. So run what the record watches as an OS user that cannot write them, in a
process that cannot reload the driver: a driver reloaded in place keeps the
hash it computed when it opened. A separate user stops a mistaken program, or
another writer, from changing the record. It is not a sandbox, and does not
contain a program set on getting out of it.

There is one writer per directory. `RecordDriver.open` creates `writer.<pid>`
only if it is absent, so a second driver in the same process, in any isolate,
cannot open the directory until the first calls `close()`. Dart has no append
that cannot overwrite, and two writers in one process would write over each
other's entries. Separate processes take turns at each entry through a lock.

## Checking it

The driver's hash is the sha256 of what `shasum -a 256` prints for its `lib/`
files, so it can be checked without running any of its code. From the
package's root:

    (cd lib && find . -type f -name '*.dart' -print0 |
      LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256)

The driver computes the same hash from its own source when it opens. Add the
hash you checked to `approved` beside the record, one per line: the line
`shasum` prints will do as it is, and anything after the hash on its line is
yours, such as when you checked it. Every entry names the driver that wrote
it, so which entries came from code you checked is read from `approved`
whenever the record is read (`approved()`), never written into the entries:
approving a hash covers what it already wrote, and deleting its line takes
that back. The driver reads `approved` and never writes it.

`RecordDriver.open` returns null when the driver cannot compute its hash the
way that command does: in a build with no source on disk, or when `lib/` holds
a link or a file name `shasum` would print differently. A driver that cannot
name itself writes nothing.

The record can be checked without the driver too. From the record's
directory, in bash:

    p=$(printf 'is_airlock_record_driver/2' | shasum -a 256 | cut -c1-64); n=0
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
`ObjectId` and the sha256 every name is made with. The driver re-exports it,
so importing the driver gives you `ObjectId` too. The driver's hash names the
driver's own `lib/` only: `is_content_id` comes from pub.dev, and an app's
`pubspec.lock` records the version it resolved and the sha256 of that
version's archive.
