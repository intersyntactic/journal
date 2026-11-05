# is_airlock_record_driver

The driver that writes intersyntactic's airlock record: the record of what
leaves a person's home, written before it goes. This is the one driver whose
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
  print('$id, written by ${driver.hash} (${driver.review.name})');
}
```

## What it keeps

One directory, which it only ever adds to:

- **Objects** in `objects/<2>/<62>`: bytes named by their sha256. Each is
  written only if that name is absent, and checked against its name whenever
  it is read (`CorruptObject` if it no longer matches). The same bytes are the
  same object whoever wrote them, so two records merge by copying objects in.
- **The entries** in `entries`: one for each object written, added before
  the object is. Each entry is 97 bytes:

  | bytes | what |
  |---|---|
  | 0–31 | the sha256 of the entry before it |
  | 32–63 | the driver's own hash |
  | 64–95 | the object's id |
  | 96 | `A` (approved) or `U` (unreviewed) |

  The first entry names, as the entry before it, the sha256 of
  `is_airlock_record_driver/1`, the record format's name. The review byte is
  last, so an entry torn by a crash is missing it; the driver pads a torn tail
  with zeros before it writes again, and a zero is neither review.

`check()` says which entries do not parse or do not name the entry before
them (`Broken`), or that there is no record (`NoRecord`), or that every entry
chains (`Intact`), with the record's `head`: the hash of its last entry. An
entry removed from the end leaves a shorter record that still chains, so to
notice that, keep the head somewhere the driver cannot write and compare.

## Checking it

The driver's hash is the sha256 of what `shasum -a 256` prints for its `lib/`
files, so it can be checked without running any of its code. From the
package's root:

    (cd lib && find . -type f -name '*.dart' -print0 |
      LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256)

The driver computes the same hash from its own source when it opens. Write the
hash you checked to `approved` beside the record (the line `shasum` prints will
do as it is), and every entry from then on says `A`. Until then, and whenever
the driver's code changes, its entries say `U`. The driver reads `approved` and
never writes it.

`RecordDriver.open` returns null when the driver cannot compute its hash the
way that command does: in a build with no source on disk, or when `lib/` holds
a link or a file name `shasum` would print differently. A driver that cannot
name itself writes nothing.

The record can be checked without the driver too. From the record's
directory, in bash:

    p=$(printf 'is_airlock_record_driver/1' | shasum -a 256 | cut -c1-64); n=0
    while read -r e; do
      n=$((n + 1))
      case "${#e}:${e:0:64}:${e:192}" in
        "194:$p:41" | "194:$p:55") ;;
        *) echo "entry $n is broken" ;;
      esac
      p=$(printf %s "$e" | xxd -r -p | shasum -a 256 | cut -c1-64)
    done < <(xxd -p -c 97 entries)
    echo "$n entries, head $p"

## What it imports

`dart:io`, `dart:isolate`, `dart:typed_data` and its own `content_id.dart`,
and nothing else, because everything it imports is part of what the person
checks, and a package's code would be outside the hash. `content_id.dart` holds
`ObjectId`, `EntryHash`, `DriverHash` and the sha256 they are made with. It
imports only `dart:typed_data`, so it can be used where `dart:io` cannot.
