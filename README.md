# is_airlock_record_driver

The driver that writes intersyntactic's airlock record: the record of what
leaves a person's home, written before it goes. This is the one driver whose
writes the airlock does not decide, since deciding them would need a record of
their own. So it is small enough to read in one sitting, and it names the hash
of its own code on every line it writes.

```dart
import 'dart:convert';
import 'dart:io';

import 'package:is_airlock_record_driver/is_airlock_record_driver.dart';

void main() {
  final record = RecordDriver.open(Directory('record'))!;
  final id = record.put(utf8.encode('what went up'));
  print('$id, written by ${record.hash} (${record.review.name})');
}
```

## What it keeps

One directory, which it only ever adds to:

- **Objects** in `objects/<2>/<62>`: bytes named by their sha256. Each is
  written only if that name is absent, and checked against its name whenever
  it is read (`CorruptObject` if it no longer matches). The same bytes are the
  same object whoever wrote them, so two records merge by copying objects in.
- **The record** in `record`: one line for each object written, added before
  the object is. A line holds the hash of the line before it, the driver's own
  hash, `approved` or `unreviewed`, and the object's id. A line that is changed
  or removed breaks the chain at the line after it, which `firstBrokenLine()`
  finds.

## Checking it

The driver's hash is the sha256 of what `shasum -a 256` prints for its `lib/`
files, so it can be checked without running any of its code. From the
package's root:

    cd lib &&
      find . -name '*.dart' | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256

The driver computes the same hash from its own source when it opens. Write the
hash you checked to `approved` beside the record, and every line from then on
says `approved`. Until then, and whenever the driver's code changes, its lines
say `unreviewed`. The driver reads `approved` and never writes it.

A build with no source on disk cannot hash itself, so `RecordDriver.open`
returns null there: a driver that cannot name itself writes nothing.

## What it imports

`dart:io`, `dart:isolate` and `crypto`, and nothing else, because everything
it imports is part of what the person checks.
