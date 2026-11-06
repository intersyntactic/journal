/// Adds entries to a journal from a process of its own, for the test that
/// processes writing one journal take turns. Arguments: the journal's
/// directory and how many to add. Prints `open` once it can add.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:is_journal/is_journal.dart';

Future<void> main(List<String> args) async {
  final journal = Journal.open(Directory(args[0]))!;
  stdout.writeln('open');
  await stdout.flush();
  for (var i = 0; i < int.parse(args[1]); i++) {
    journal.add(Uint8List.fromList('other $i'.codeUnits));
  }
  journal.close();
}
