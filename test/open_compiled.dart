/// Opens a logbook and adds one entry, for the tests that a compiled build
/// names its code. Argument: the logbook's directory. Prints the code hash
/// the logbook opened with, or `null` when it would not open.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:is_logbook/is_logbook.dart';

void main(List<String> args) {
  final logbook = Logbook.open(Directory(args[0]));
  if (logbook == null) {
    stdout.writeln('null');
    return;
  }
  logbook.add(Uint8List.fromList('compiled'.codeUnits));
  stdout.writeln(logbook.codeHash.hex);
  logbook.close();
}
