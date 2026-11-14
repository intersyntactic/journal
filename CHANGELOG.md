# Changelog

## 0.4.0

The format is unchanged, but every code hash changes: approve 0.4.0's anew.

- The code hash covers the `is_content_id` the journal runs with, not only
  this package: the `lib/` files of both, each path under its package's
  name. A new `is_content_id` changes the hash, whichever version an app
  resolves, `dependency_overrides` included.
- So the dependency is `^0.2.0` again. 0.3.0's exact pin kept any app from
  combining the journal with a library that needs an `is_content_id` fix.
- The README's bash check hashes both packages, finding them through
  `.dart_tool/package_config.json`, from this package's root or an app's.

## 0.3.0

The format is unchanged: journals written by 0.2.0 read the same, and an
entry 0.2.0 padded with zeros stays as it is.

- An entry torn by a crash is cut off before the next entry is written,
  instead of padded with zeros and chained from. Its add never returned and
  its object was never kept, so nothing recorded is lost, and `check()`
  reports the journal `Intact` again rather than `Broken` for good.
- `add` throws `ObjectNotKept`, a `FileSystemException` carrying the id,
  when its entry went in but its object did not, so a caller can tell that
  adding again would record the bytes twice.
- The library comment says what "written and flushed" covers: this process
  crashing, not a power cut, since the renames that keep objects are not
  flushed to their folder.
- A compiled build can keep a journal. `dart run is_journal:code_hash`
  prints `-Dis_journal.code=<hash>` from the source about to be compiled,
  and `Journal.open` uses it when there is no source to hash. Run from
  source, `open` throws a `StateError` when that define is not this code's
  hash.
- Depends on `is_content_id` 0.2.0 exactly, not ^0.2.0, and the library
  comment names that version, so the code hash changes when the pin does: the
  same code hash means the same `is_content_id`. A test fails if
  `pubspec.yaml` and `lib/` disagree, or if the pin becomes a range.

## 0.2.0

The format is unchanged: journals written by 0.1.0 read the same.

- The code hash is an `is_content_id` `FileSetId`, the name of a set of
  files, which `is_content_id` 0.2.0 now holds. `CodeHash` is gone:
  `Journal.codeHash`, `Journal.ownHash()`, `JournalEntry.code` and
  `approved()` are `FileSetId`s. The same `lib/` has the same 32-byte hash.
- Depends on `is_content_id` ^0.2.0, and re-exports it, so `FileSetId` and
  `ListedPath` come with the journal.

Fixes from a review of 0.1.0:

- Processes take turns through a lock on a new file, `lock`, instead of on
  `entries`. Closing any descriptor on a file gives up every lock its process
  holds on it, so anything in a writing process that read `entries` ended the
  lock, and two processes could write at once and break the chain.
- A `Journal` cannot be sent to another isolate. Sending copied it, and the
  copy wrote as a second writer that its claim could not see.
- `open` resolves a relative directory, so the journal stays where it opened
  when the working directory moves.
- `close` succeeds when its `writer.<pid>` is already gone.
- `approved()` reads past bytes that are not UTF-8.
- The README's bash check says when there is no journal, or no `xxd`, rather
  than reporting an empty journal.

## 0.1.0

- First release: `Journal`, with `JournalEntry`, `EntryHash`, `CodeHash`,
  `JournalCheck` (`NoJournal`, `Intact`, `Broken`) and `CorruptObject`, on
  `is_content_id`'s `ObjectId` and sha256. Every `add` adds an entry of three
  names, in journal format `is_journal/1`, and keeps the bytes whole. `open`
  claims the directory for its process until `close`. Which code the person
  approved is read from `approved` by `approved()`, never written into an
  entry.
