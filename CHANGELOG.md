# Changelog

## 0.1.0

- First release: `RecordDriver`, with `RecordEntry`, `Review`, `RecordCheck`
  (`NoRecord`, `Intact`, `Broken`) and `CorruptObject`; and
  `content_id.dart`, with `ObjectId`, `EntryHash`, `DriverHash` and the
  sha256 they are made with. Every `put` adds an entry, and `open` claims
  the directory for its process until `close`.
