import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:drift/drift.dart' show QueryExecutor;
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart';

import 'device_secrets.dart';

/// Only [open] creates production executors. Tests may still use memory SQLite.
/// The key is generated on the device and is never derived from the family PIN.
class EncryptedDatabase {
  static const keyName = 'learning_planet.database.key.v1';
  static const fileName = 'learning_planet.encrypted.sqlite';
  static const legacyName = 'learning_planet.sqlite';
  static final _keyPattern = RegExp(r'^[0-9a-f]{64}$');
  static Future<void> _opening = Future.value();

  static Future<QueryExecutor> open(
    Directory directory,
    DeviceSecrets secrets,
  ) {
    // Serialize key creation and migration in this process, including retries.
    final operation = _opening.then((_) => _open(directory, secrets));
    _opening = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  static Future<QueryExecutor> _open(
    Directory directory,
    DeviceSecrets secrets,
  ) async {
    final file = File('${directory.path}${Platform.pathSeparator}$fileName');
    final temporary = File('${file.path}.migrating');
    String? key;
    try {
      await directory.create(recursive: true);
      key = await secrets.read(keyName);
      if (key == null) {
        // A missing/locked key must never silently replace an existing key.
        if (await file.exists() || await temporary.exists()) {
          throw const LocalDataException(
            '未找到本机数据密钥。已保留本机资料，请使用原设备解锁后重试；请勿卸载或清除应用数据。',
          );
        }
        final random = Random.secure();
        key = List.generate(
          32,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
        await secrets.write(keyName, key);
        if (await secrets.read(keyName) != key) {
          throw const LocalDataException('本机数据密钥未能保存，请重试。');
        }
      }
      if (!_keyPattern.hasMatch(key)) {
        throw const LocalDataException('本机数据密钥异常，资料已保留，请重试。');
      }
      final databaseKey = key;
      // The isolate only receives the directory and key, never the keychain
      // plugin. Finish migration under the opening lock, before Drift opens.
      final path = directory.path;
      await Isolate.run(() => prepareFiles(path, databaseKey));
      return NativeDatabase.createInBackground(
        file,
        setup: (db) => configure(db, databaseKey),
      );
    } on LocalDataException {
      rethrow;
    } catch (_) {
      throw const LocalDataException('无法准备本机加密存储，资料已保留，请重试。');
    }
  }

  static void configure(Database db, String key) {
    if (!_keyPattern.hasMatch(key) || db.select('PRAGMA cipher').isEmpty) {
      // This check is mandatory in release builds too. No plaintext fallback.
      throw const LocalDataException('此版本缺少本机加密组件，请更新应用。');
    }
    db.execute("PRAGMA cipher = 'chacha20'");
    db.execute("PRAGMA key = 'raw:$key'");
    db.select('SELECT count(*) FROM sqlite_master'); // Actually checks the key.
    db.execute('PRAGMA temp_store = MEMORY');
    db.execute('PRAGMA secure_delete = ON');
    db.execute('PRAGMA busy_timeout = 5000');
  }

  static void _verify(File file, String key) {
    if (!file.existsSync() || file.lengthSync() == 0) {
      throw const LocalDataException('本机数据文件不完整，资料已保留。');
    }
    final db = sqlite3.open(file.path, mode: OpenMode.readOnly);
    try {
      configure(db, key);
      final rows = db.select('PRAGMA integrity_check');
      if (rows.length != 1 || rows.single.values.single != 'ok') {
        throw const LocalDataException('本机数据校验失败，资料已保留。');
      }
    } finally {
      db.close();
    }
  }

  static String _sqlString(String value) => value.replaceAll("'", "''");

  /// Kept separately so the real native migration can be tested at restart
  /// boundaries. A valid final database always wins over a leftover old copy.
  static void prepareFiles(String directory, String key) {
    final file = File('$directory${Platform.pathSeparator}$fileName');
    final legacy = File('$directory${Platform.pathSeparator}$legacyName');
    final temporary = File('${file.path}.migrating');
    try {
      if (file.existsSync()) {
        _verify(file, key);
      } else if (legacy.existsSync()) {
        // The original remains authoritative until the encrypted copy has
        // passed integrity checks and has been atomically renamed.
        final old = sqlite3.open(legacy.path);
        try {
          if (old.select('PRAGMA cipher').isEmpty) {
            throw const LocalDataException('此版本缺少本机加密组件，请更新应用。');
          }
          old.select('SELECT count(*) FROM sqlite_master');
          old.execute('PRAGMA temp_store = MEMORY');
          _removeDatabaseFiles(temporary);
          old.execute("VACUUM INTO '${_sqlString(temporary.path)}'");
        } finally {
          old.close();
        }
        final copy = sqlite3.open(temporary.path);
        try {
          copy.execute('PRAGMA journal_mode = DELETE');
          copy.execute("PRAGMA cipher = 'chacha20'");
          copy.execute("PRAGMA rekey = 'raw:$key'");
        } finally {
          copy.close();
        }
        _verify(temporary, key);
        temporary.renameSync(file.path);
        _verify(file, key);
      } else if (temporary.existsSync() && temporary.lengthSync() != 0) {
        // Never discard a sole remaining copy after an interrupted migration.
        _verify(temporary, key);
        temporary.renameSync(file.path);
      } else {
        // A killed first launch / full disk can leave a zero-byte staging
        // file. It contains no database, but a nonempty journal could still
        // hold recoverable content, so only retry creation without sidecars.
        for (final suffix in ['-wal', '-shm', '-journal']) {
          final sidecar = File('${temporary.path}$suffix');
          if (sidecar.existsSync() && sidecar.lengthSync() != 0) {
            throw const LocalDataException('本机数据文件不完整，资料已保留。');
          }
        }
        _removeDatabaseFiles(temporary);
        // Create a nonempty encrypted file before handing it to Drift. This
        // avoids treating a zero-byte interrupted initial open as a database.
        final fresh = sqlite3.open(temporary.path);
        try {
          configure(fresh, key);
          fresh.execute('VACUUM');
        } finally {
          fresh.close();
        }
        _verify(temporary, key);
        temporary.renameSync(file.path);
      }
      // All deletions are specific app-owned files, and occur only after a
      // verified encrypted copy exists. Fail closed if cleanup cannot finish.
      _removeDatabaseFiles(legacy);
      _removeDatabaseFiles(temporary);
    } on LocalDataException {
      rethrow;
    } catch (_) {
      throw const LocalDataException('本机数据暂时无法解锁或迁移，资料已保留。请确认设备已解锁、存储空间充足后重试。');
    }
  }

  static void _removeDatabaseFiles(File file) {
    // Sidecars first, main file last: a retry can still identify old data.
    for (final suffix in ['-wal', '-shm', '-journal', '']) {
      final entry = File('${file.path}$suffix');
      if (entry.existsSync()) entry.deleteSync();
    }
  }
}
