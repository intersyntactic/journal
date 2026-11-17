/// Holds a logbook open from a process of its own until it is killed, for
/// the tests that a live process's claim is kept and a dead one's removed.
/// Argument: the logbook's directory. Prints `open` once it holds it.
library;

import 'dart:async';
import 'dart:io';

import 'package:is_logbook/is_logbook.dart';

Future<void> main(List<String> args) async {
  Logbook.open(Directory(args[0]))!;
  stdout.writeln('open');
  await stdout.flush();
  await Completer<void>().future;
}
