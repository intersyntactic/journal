/// Prints the define a compiled build needs to name its code, from the
/// is_logbook source it is about to compile:
///
///     dart compile exe $(dart run is_logbook:code_hash) bin/main.dart
library;

import 'dart:io';

import 'package:is_logbook/is_logbook.dart';

void main() {
  final hash = Logbook.ownHash();
  if (hash == null) {
    stderr.writeln(
      'is_logbook cannot hash its own lib/ here (see Logbook.ownHash), so a '
      'build cannot name its code.',
    );
    exitCode = 1;
    return;
  }
  stdout.writeln('-D${Logbook.builtDefine}=${hash.hex}');
}
