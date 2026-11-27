import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The reason is safe to display. Never retain a native error containing a key,
/// session, SQL statement or a private filesystem path in this exception.
class LocalDataException implements Exception {
  const LocalDataException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract interface class DeviceSecrets {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class NativeDeviceSecrets implements DeviceSecrets {
  const NativeDeviceSecrets();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false, migrateWithBackup: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
      synchronizable: false,
    ),
  );

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (_) {
      throw const LocalDataException('无法读取设备安全存储，请解锁设备后重试。');
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
      if (await _storage.read(key: key) != value) {
        throw const LocalDataException('设备安全存储未能保存数据，请重试。');
      }
    } catch (_) {
      throw const LocalDataException('设备安全存储未能保存数据，请重试。');
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
      if (await _storage.read(key: key) != null) {
        throw const LocalDataException('设备安全存储未能完成清理，请重试。');
      }
    } catch (_) {
      throw const LocalDataException('设备安全存储未能完成清理，请重试。');
    }
  }
}
