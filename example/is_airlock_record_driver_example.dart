import 'dart:convert';
import 'dart:io';

import 'package:is_airlock_record_driver/is_airlock_record_driver.dart';

void main() {
  final dir = Directory.systemTemp.createTempSync('record');
  final record = RecordDriver.open(dir);
  if (record == null) {
    print('this build has no source for the driver to hash');
    return;
  }
  print('driver ${record.hash} is ${record.review.name}');

  final id = record.put(utf8.encode('what went up'));
  print('stored as $id');
  print('read back: ${utf8.decode(record.get(id)!)}');
  print('record intact: ${record.firstBrokenLine() == null}');
}
