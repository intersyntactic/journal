# Changelog

## 0.1.1

Fixes from a review of 0.1.0. The format is unchanged: journals written by
0.1.0 read the same.

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
