/// Runs a journal's one writer (see `package:is_journal/service.dart`):
///
///     JOURNAL_DIR=/var/lib/record JOURNAL_SOCKET=/run/record/journal.sock \
///       JOURNAL_SENDERS=/etc/record/senders dart run is_journal:service
///
/// Exits 78 when it cannot start as configured, and closes cleanly on
/// SIGTERM or SIGINT.
library;

import 'dart:async';
import 'dart:io';

import 'package:is_journal/is_journal.dart';
import 'package:is_journal/service.dart';

Future<void> main() async {
  final env = Platform.environment;
  final [dir, socket, senders] = [
    for (final name in ['JOURNAL_DIR', 'JOURNAL_SOCKET', 'JOURNAL_SENDERS'])
      env[name] ?? _fail('$name is not set'),
  ];
  final SenderTable table;
  try {
    table = SenderTable.parse(File(senders).readAsBytesSync());
  } on Exception catch (e) {
    _fail('$senders: $e');
  }
  final journal =
      Journal.open(Directory(dir)) ??
      _fail('the journal cannot name its own code; see the README');
  final JournalService service;
  try {
    service = await JournalService.start(journal, table, File(socket));
  } on Object catch (e) {
    journal.close();
    _fail('$e');
  }
  stdout.writeln('writing $dir, listening on $socket');
  final stop = Completer<void>();
  for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
    signal.watch().listen((_) {
      if (!stop.isCompleted) stop.complete();
    });
  }
  await stop.future;
  await service.close();
  exit(0);
}

Never _fail(String why) {
  stderr.writeln('is_journal service: $why');
  exit(78);
}
