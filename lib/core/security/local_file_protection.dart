import 'dart:io';

import 'package:flutter/services.dart';

import 'device_secrets.dart';

Future<void> protectLocalFiles(Directory directory) async {
  if (!Platform.isIOS) return;
  try {
    await const MethodChannel(
      'learning_planet/local_file_protection',
    ).invokeMethod<void>('protect', {'path': directory.path});
  } catch (_) {
    throw const LocalDataException('本机文件保护未能启用，请解锁设备后重试。');
  }
}
