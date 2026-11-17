/// Holds a journal open from a process of its own until it is killed, for
/// the tests that a live process's claim is kept and a dead one's removed.
/// Argument: the journal's directory. Prints `open` once it holds it.
library;

import 'dart:io';

import 'package:is_journal/is_journal.dart';

Future<void> main(List<String> args) async {
  Journal.open(Directory(args[0]))!;
  stdout.writeln('open');
  await stdout.flush();
  // A pending timer keeps the process alive; a future nothing completes
  // does not, and the process would exit, giving up its claim, at once.
  await Future<void>.delayed(const Duration(days: 1));
}
