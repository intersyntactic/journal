import 'dart:convert';
import 'dart:io';

import 'package:is_journal/is_journal.dart';

void main() {
  final dir = Directory.systemTemp.createTempSync('journal');
  final journal = Journal.open(dir);
  if (journal == null) {
    print('this build has no source for the journal to hash');
    return;
  }
  final checked = journal.approved().contains(journal.codeHash);
  print('code ${journal.codeHash} is ${checked ? 'approved' : 'unreviewed'}');

  final id = journal.add(utf8.encode('hello'));
  print('stored as $id');
  print('read back: ${utf8.decode(journal.get(id)!)}');
  print('journal intact: ${journal.check() is Intact}');
  journal.close();
}
