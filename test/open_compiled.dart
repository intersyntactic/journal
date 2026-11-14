/// Opens a journal and adds one entry, for the tests that a compiled build
/// names its code. Argument: the journal's directory. Prints the code hash
/// the journal opened with, or `null` when it would not open.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:is_journal/is_journal.dart';

void main(List<String> args) {
  final journal = Journal.open(Directory(args[0]));
  if (journal == null) {
    stdout.writeln('null');
    return;
  }
  journal.add(Uint8List.fromList('compiled'.codeUnits));
  stdout.writeln(journal.codeHash.hex);
  journal.close();
}
