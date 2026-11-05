# Changelog

## 0.1.0

- First release: `RecordDriver`, with `RecordEntry`, `EntryHash`,
  `DriverHash`, `Review`, `RecordCheck` (`NoRecord`, `Intact`, `Broken`) and
  `CorruptObject`, on `is_content_id`'s `ObjectId` and sha256. Every `put` adds an entry, and `open` claims
  the directory for its process until `close`.
