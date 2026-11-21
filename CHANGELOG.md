# Changelog

## 0.3.0

- **Breaking: users are `UserId`s**, from
  [`is_unix_socket_user_check`](https://pub.dev/packages/is_unix_socket_user_check),
  which the service library re-exports with `SocketUserReader`. `uidOf`
  returns `UserId?` and `SenderTable.allows` takes a `UserId`.
- **A sender table naming 65534, `nobody`, 4294967294 or 4294967295 is
  refused** (`FormatException` `no user ...`), as is a
  `users-assigned-to-trajectory` naming one (`refused no-user ...`). The
  kernel reports a user unmapped in the service's user namespace as 65534,
  so such a line used to let in every unmapped user.
- Who is on the other end of the socket is read by `SocketUserReader`,
  which `LogbookService.start` takes as `socketUserReader` (the running
  kernel's by default), so a test can fake any user.
- **The code hash covers `is_unix_socket_user_check`**, as it covers
  `is_content_id`: it decides who may write, so a new version of it
  changes the hash. The README's command hashes it too.
- The approved code hash changes with this release: `lib/` changed and
  the hash now covers a third package. Approve the new hash before
  running it.

## 0.2.2

- **`trajectory-closed`** (`Kind.trajectoryClosed`) closes one trajectory,
  as `mission-ended` closes a mission: its chain and every chain attached
  to it are refused from then on (`refused trajectory-closed <trajectory>`),
  and its users are free again. The service reads only the body's
  `trajectory` (`refused trajectory-closed-body` when it names none). It
  cannot attach. Closing twice changes nothing, and a restart reads it back.
- A trajectory can be closed before its users are assigned: its
  `users-assigned-to-trajectory` is then refused
  (`refused trajectory-closed <trajectory>`).
- **A `users-assigned-to-trajectory` for a mission already ended is
  refused** (`refused mission-ended <mission>`). It used to be accepted, so a
  loop could start in a closed mission and have every entry refused.
- The code hash changes: `lib/service.dart` changed.

## 0.2.1

- `LogbookService.start` takes `uidOf`, as `SenderTable.parse` does, with
  the real lookup as the default, so a test can start the service with users
  this machine does not have (`suit-1`, `loop-1`). Nothing on the wire
  changes.
- The code hash changes: `lib/service.dart` changed.

## 0.2.0

- **Breaking: the service speaks text ids.** An entry's id on the socket
  is the sha256 of the bytes sent, header and all (`ObjectId`), not the hash
  of the 96 bytes that chain the logbook. That covers `ok`,
  `refused not-tip`, a header's `previous`, an attached root's parent line,
  `get`, `tip`, `subscribe … from`, `caught-up`, and each subscribed
  entry's id. A sender can compute an id before sending, and a reader checks
  every subscribed entry by hashing its bytes. `get` still sends the 96
  bytes, whose bytes 64–95 are the id.
- **Breaking: `refused duplicate <id>`** for bytes the logbook already
  holds, checked before the tip, so a resend after a lost answer learns the
  entry got in. Two entries with the same kind, previous and body are one.
- **Each `started` names the last `started` as previous**, so no two starts
  are the same bytes.
- The 96-byte format and `is_logbook/1` are unchanged; a logbook written by
  0.1.0's service names 96-byte hashes in its headers, which 0.2.0 does not
  read as ids, so a live record starts empty again.
- The code hash changes: `lib/service.dart` changed.

## 0.1.0

The first release as is_logbook. Up to 0.9.0 this package was
[is_journal](https://pub.dev/packages/is_journal); its history is below.

- **Breaking: the package is is_logbook** (repository
  intersyntactic/logbook). The library is `package:is_logbook/is_logbook.dart`,
  the class `Logbook` (and `LogbookEntry`, `LogbookCheck`, `NoLogbook`,
  `LogbookService`), the executables `is_logbook:service` and
  `is_logbook:code_hash`, and the define a compiled build names its code
  with `is_logbook.code`.
- **Breaking: the format is `is_logbook/1`.** The first entry names the
  sha256 of `is_logbook/1` as the entry before it, so no record written by
  is_journal chains here. None is carried over: a logbook starts empty.
- **Breaking: the service reads `LOGBOOK_DIR`, `LOGBOOK_SOCKET`,
  `LOGBOOK_SENDERS` and `LOGBOOK_READ_SOCKET`**, and no longer the
  `JOURNAL_*` names. The README's example sockets are `logbook.sock`.
- The code hash changes: the package is named `is_logbook` in the hash's
  list, and `lib/` changed.
- **Breaking: a journey is now a mission, and a journey path a
  trajectory** (Nick, 17 Nov). The kinds are `users-assigned-to-trajectory`
  (was `users-assigned-to-journey-path`) and `mission-ended` (was
  `journey-ended`). The first one's body is exactly
  `{"trajectory","mission","loopUser","suit"}` (was `journeyPath`,
  `journey`), and the second's names its `mission` (was `journey`).
- Refusals renamed with them: an entry on an ended mission's chain is
  refused `mission-ended <mission>`, and a body that names no mission
  `mission-ended-body`. `users-assigned-again` now names the trajectory.
- No entry of the old kinds was ever written to a live record, and the
  readers don't accept the old names: each reader reads one version.
- Sender tables naming the old kinds must change in the same deploy.
- No kind is newly reserved: only `-` and `started` are refused by
  `Kind.parse`.

# Before the rename: is_journal

## 0.9.0

- **Breaking: two kinds renamed**, under the naming rulings (a name says
  literally what the thing is). `assigned` is now
  `users-assigned-to-journey-path`, and `ended` is now `journey-ended`.
  The old names are no longer special: a sender table may list them as
  ordinary kinds. No entry of either old kind was ever written to a live
  record, so nothing has to read them.
- Refusals renamed with them: `assigned-body`, `assigned-not-root` and
  `assigned-again` are now `users-assigned-body`,
  `users-assigned-not-root` and `users-assigned-again`; `ended-body` is
  `journey-ended-body`; and an entry on an ended journey's chain is
  refused `journey-ended <journey>`, not `closed <journey>` (a closed
  thing can be reopened; an ended journey can't).
- Sender tables naming the old kinds must change in the same deploy.
- No kind is newly reserved: only `-` and `started` are refused by
  `Kind.parse`, as in 0.8.0.
- The code hash changes: `lib/` changed.

## 0.8.0

- **Chain ownership.** An `assigned` entry starts a journey path's chain,
  and only the user it names as `loopUser` may extend that chain. An
  `ended` entry closes every chain of its journey. A kind on the sender
  table's new `attaching:` line starts a chain that names its parent on its
  first body line and belongs to the parent's path. The README's "Chains a
  journey path owns" gives the rules and each refusal.
- `assigned` and `ended` are now refused unless their bodies read as the
  README says. Any other kind is treated as it was.
- A sender table with an `attaching:` line is refused by 0.7.0 and older,
  which read `attaching:` as a user.
- Who owns which chain is rebuilt from the journal on every start.
- The code hash changes: `lib/` changed.

## 0.7.0

- **Breaking, on the read socket:** `follow <kinds> <after>` is now
  `subscribe <kinds> from <entry>`, with `start` for the journal's start in
  place of `-`. The old request is refused (`refused not-a-request`); there
  is no transition. `caught-up` says `start`, not `-`, when there is no
  entry to name. `-` now means only "no previous entry".
- The header's second line is called `<previous>`, not `<follows>`, in the
  docs and the code: the entry before this one in its chain. Only the name
  changed: no byte a writer sends, no entry and no hash differs.
- The code hash changes: `lib/` changed.

## 0.6.0

- The read socket answers `get <entry>`: the entry with its bytes, as
  `follow` sends it, plus its 96 bytes in hex, so a reader can check that
  the entry hashes to its name and the bytes to the object it names. Or
  `none` when the journal holds no such entry, `unreadable … missing|corrupt`
  when it does but its bytes are gone or changed, or `failed`.
- The service indexes every entry, including one whose object is lost or
  that has no header, so `get` never says `none` for an entry that was
  recorded, before or after a restart. When something other than the
  service has written to the journal, it reads the journal back.
- A journal holds a lock on its `writer.<pid>` while open, and opening
  deletes the claims no process holds, left by a process that ended without
  closing (a `SIGKILL`, or running out of memory). A journal 0.5.0 or older
  holds no such lock, so don't open a directory from both at once.
- The code hash changes: `lib/` changed.

## 0.5.0

- `package:is_journal/service.dart` and `dart run is_journal:service`: a
  journal's one writer, which other processes send entries to over a Unix
  socket. It refuses a kind the sender's user may not write (read from the
  socket: `SO_PEERCRED` on Linux, `LOCAL_PEERCRED` on macOS) and an entry
  that does not follow its chain's tip, and adds a `started` entry holding
  the sender table on every start. The checks are in `lib/`, so the code
  hash covers them.
- A read socket (`JOURNAL_READ_SOCKET`, optional), for readers who can only
  read: `follow <kinds> <after>` sends the matching entries after a point
  and then each new one as it is added, and `tip <entry>` answers a chain's
  tip. Every entry comes with the hash `ok` answered for it.
- `Journal.addEntry` adds as `add` does and returns the hash of the entry it
  wrote.

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
