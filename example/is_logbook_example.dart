import 'dart:convert';
import 'dart:io';

import 'package:is_logbook/is_logbook.dart';

void main() {
  final dir = Directory.systemTemp.createTempSync('logbook');
  final logbook = Logbook.open(dir);
  if (logbook == null) {
    print('this build has no source for the logbook to hash');
    return;
  }
  final checked = logbook.approved().contains(logbook.codeHash);
  print('code ${logbook.codeHash} is ${checked ? 'approved' : 'unreviewed'}');

  final id = logbook.add(utf8.encode('hello'));
  print('stored as $id');
  print('read back: ${utf8.decode(logbook.get(id)!)}');
  print('logbook intact: ${logbook.check() is Intact}');
  logbook.close();
}
