# Changelog

## 0.1.0

- First release: `Journal`, with `JournalEntry`, `EntryHash`, `CodeHash`,
  `JournalCheck` (`NoJournal`, `Intact`, `Broken`) and `CorruptObject`, on
  `is_content_id`'s `ObjectId` and sha256. Every `add` adds an entry of three
  names, in journal format `is_journal/1`, and keeps the bytes whole. `open`
  claims the directory for its process until `close`. Which code the person
  approved is read from `approved` by `approved()`, never written into an
  entry.
