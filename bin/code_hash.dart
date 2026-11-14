/// Prints the define a compiled build needs to name its code, from the
/// is_journal source it is about to compile:
///
///     dart compile exe $(dart run is_journal:code_hash) bin/main.dart
library;

import 'dart:io';

import 'package:is_journal/is_journal.dart';

void main() {
  final hash = Journal.ownHash();
  if (hash == null) {
    stderr.writeln(
      'is_journal cannot hash its own lib/ here (see Journal.ownHash), so a '
      'build cannot name its code.',
    );
    exitCode = 1;
    return;
  }
  stdout.writeln('-D${Journal.builtDefine}=${hash.hex}');
}
