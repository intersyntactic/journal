# Changelog

## 0.1.0

- First release: `RecordDriver`, with `RecordEntry`, `EntryHash`,
  `DriverHash`, `RecordCheck` (`NoRecord`, `Intact`, `Broken`) and
  `CorruptObject`, on `is_content_id`'s `ObjectId` and sha256. Every `put`
  adds an entry of three names, in record format 2, and `open` claims the
  directory for its process until `close`. Which drivers the person approved
  is read from `approved` by `approved()`, never written into an entry.
