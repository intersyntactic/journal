import 'dart:convert';
import 'dart:io';

import 'package:is_airlock_record_driver/is_airlock_record_driver.dart';

void main() {
  final dir = Directory.systemTemp.createTempSync('airlock_record');
  final driver = RecordDriver.open(dir);
  if (driver == null) {
    print('this build has no source for the driver to hash');
    return;
  }
  final checked = driver.approved().contains(driver.hash);
  print('driver ${driver.hash} is ${checked ? 'approved' : 'unreviewed'}');

  final id = driver.add(utf8.encode('what went up'));
  print('stored as $id');
  print('read back: ${utf8.decode(driver.get(id)!)}');
  print('record intact: ${driver.check() is Intact}');
  driver.close();
}
