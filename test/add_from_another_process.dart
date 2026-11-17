/// Adds entries to a logbook from a process of its own, for the test that
/// processes writing one logbook take turns. Arguments: the logbook's
/// directory and how many to add. Prints `open` once it can add.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:is_logbook/is_logbook.dart';

Future<void> main(List<String> args) async {
  final logbook = Logbook.open(Directory(args[0]))!;
  stdout.writeln('open');
  await stdout.flush();
  for (var i = 0; i < int.parse(args[1]); i++) {
    logbook.add(Uint8List.fromList('other $i'.codeUnits));
  }
  logbook.close();
}
