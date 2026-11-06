import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:learning_planet/app/startup_gate.dart';
import 'package:learning_planet/core/offline/offline_store.dart';
import 'package:learning_planet/core/security/device_secrets.dart';
import 'package:learning_planet/core/security/encrypted_database.dart';
import 'package:learning_planet/core/security/secure_auth_storage.dart';
import 'package:learning_planet/features/auth_family/data/auth_repository.dart';

class MemorySecrets implements DeviceSecrets {
  final values = <String, String>{};
  bool failWrite = false;
  bool dropWrite = false;
  bool failRead = false;
  @override
  Future<String?> read(String key) async {
    if (failRead) throw StateError('native private detail');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw StateError('native private detail');
    if (!dropWrite) values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

const marker = 'PRIVATE_CHILD_ANSWER_9c73_孩子答案';
const imageMarker = 'PRIVATE_IMAGE_BYTES_a34c';
const fixedKey =
    '1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef';

void expectNoPlaintext(File file) {
  final bytes = latin1.decode(file.readAsBytesSync());
  expect(bytes, isNot(contains(latin1.decode(utf8.encode(marker)))));
  expect(bytes, isNot(contains(imageMarker)));
  expect(bytes.startsWith('SQLite format 3'), isFalse);
}

Future<OfflineStore> openEncrypted(
  Directory directory,
  MemorySecrets secrets,
) async {
  final store = OfflineStore(await EncryptedDatabase.open(directory, secrets));
  try {
    await store.customSelect('SELECT 1').get();
    return store;
  } catch (_) {
    await store.close();
    rethrow;
  }
}

Future<void> seed(OfflineStore store) async {
  await store.write('parent', 'private', {'answer': marker});
  await store.customStatement(
    '''INSERT INTO task_outbox
    (owner,command_id,child_id,task_id,payload,attempts,next_attempt)
    VALUES('parent','command','child','task',?,3,123)''',
    [marker],
  );
  await store.customStatement('INSERT INTO deleted_children VALUES(?)', [
    'removed-child',
  ]);
  await store.customStatement('INSERT INTO deleted_accounts VALUES(?,?)', [
    'removed-parent',
    'job',
  ]);
  await store.customStatement(
    '''INSERT INTO image_drafts
    (owner,draft_id,child_id,family_id,metadata,original,processed,updated_at)
    VALUES('parent','draft','child','family',?,?,?,42)''',
    [
      jsonEncode({'text': marker}),
      Uint8List.fromList(utf8.encode(imageMarker)),
      Uint8List.fromList(utf8.encode(imageMarker)),
    ],
  );
  await store.customStatement(
    'INSERT INTO discarded_image_drafts VALUES(?,?)',
    ['parent', 'discarded'],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late MemorySecrets secrets;
  File finalFile() => File('${directory.path}/${EncryptedDatabase.fileName}');
  File legacyFile() =>
      File('${directory.path}/${EncryptedDatabase.legacyName}');
  File temporaryFile() => File('${finalFile().path}.migrating');
  setUp(() async {
    directory = await Directory.systemTemp.createTemp("planet-加密-'test-");
    secrets = MemorySecrets();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'real bundled cipher persists all tables and rejects missing or wrong keys',
    () async {
      final store = await openEncrypted(directory, secrets);
      await seed(store);
      await store.close();
      expectNoPlaintext(finalFile());
      final key = secrets.values[EncryptedDatabase.keyName]!;
      expect(key, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(key, isNot(fixedKey));
      final raw = sqlite3.open(finalFile().path, mode: OpenMode.readOnly);
      try {
        expect(
          () => raw.select('SELECT * FROM sqlite_master'),
          throwsA(isA<SqliteException>()),
        );
      } finally {
        raw.close();
      }
      final before = finalFile().readAsBytesSync();
      secrets.values[EncryptedDatabase.keyName] = fixedKey;
      await expectLater(
        openEncrypted(directory, secrets),
        throwsA(isA<LocalDataException>()),
      );
      expect(finalFile().readAsBytesSync(), before);
      secrets.values.remove(EncryptedDatabase.keyName);
      await expectLater(
        openEncrypted(directory, secrets),
        throwsA(isA<LocalDataException>()),
      );
      expect(secrets.values, isEmpty);
      expect(finalFile().readAsBytesSync(), before);
      secrets.values[EncryptedDatabase.keyName] = key;
      final reopened = await openEncrypted(directory, secrets);
      expect((await reopened.read('parent', 'private'))!['answer'], marker);
      expect(
        (await reopened.customSelect('SELECT * FROM task_outbox').getSingle())
            .read<int>('attempts'),
        3,
      );
      final draft = await reopened
          .customSelect('SELECT * FROM image_drafts')
          .getSingle();
      expect(utf8.decode(draft.read<Uint8List>('original')), imageMarker);
      expect(await reopened.isChildDeleted('removed-child'), isTrue);
      expect(await reopened.accountDeletionJob('removed-parent'), 'job');
      await reopened.close();
    },
  );

  test(
    'migrates schema4 with blobs and deletion barriers, preserving UUIDs and retry state',
    () async {
      final old = OfflineStore(NativeDatabase(legacyFile()));
      await seed(old);
      await old.close();
      expect(
        latin1.decode(legacyFile().readAsBytesSync()),
        contains(imageMarker),
      );
      final migrated = await openEncrypted(directory, secrets);
      expect((await migrated.read('parent', 'private'))!['answer'], marker);
      expect(
        (await migrated.customSelect('SELECT * FROM task_outbox').getSingle())
            .read<String>('command_id'),
        'command',
      );
      expect(
        (await migrated.customSelect('SELECT * FROM task_outbox').getSingle())
            .read<int>('next_attempt'),
        123,
      );
      expect(
        (await migrated.customSelect('SELECT * FROM image_drafts').getSingle())
            .read<String>('draft_id'),
        'draft',
      );
      expect(
        (await migrated
                .customSelect('SELECT * FROM discarded_image_drafts')
                .getSingle())
            .read<String>('draft_id'),
        'discarded',
      );
      expect(await migrated.isChildDeleted('removed-child'), isTrue);
      expect(await migrated.accountDeletionJob('removed-parent'), 'job');
      await migrated.close();
      expect(legacyFile().existsSync(), isFalse);
      expect(temporaryFile().existsSync(), isFalse);
      expectNoPlaintext(finalFile());
    },
  );

  test('migrates schema1 before upgrading to schema5', () async {
    final old = OfflineStore(NativeDatabase(legacyFile()));
    await old.write('parent', 'private', {'answer': marker});
    for (final table in [
      'deleted_children',
      'deleted_accounts',
      'image_drafts',
      'discarded_image_drafts',
      'family_access',
    ]) {
      await old.customStatement('DROP TABLE $table');
    }
    await old.customStatement('PRAGMA user_version = 1');
    await old.close();
    final migrated = await openEncrypted(directory, secrets);
    expect((await migrated.read('parent', 'private'))!['answer'], marker);
    expect(await migrated.isChildDeleted('missing'), isFalse);
    expect(
      await migrated.customSelect('SELECT * FROM image_drafts').get(),
      isEmpty,
    );
    expect(
      (await migrated.customSelect('PRAGMA user_version').getSingle())
          .data
          .values
          .single,
      5,
    );
    await migrated.close();
    expectNoPlaintext(finalFile());
  });

  test(
    'restart replaces interrupted copy; final encrypted database wins over leftover original',
    () async {
      secrets.values[EncryptedDatabase.keyName] = fixedKey;
      final old = OfflineStore(NativeDatabase(legacyFile()));
      await old.write('parent', 'private', {'answer': marker});
      await old.close();
      final legacy = legacyFile().readAsBytesSync();
      // A crash before rekey left an incomplete plaintext copy.
      temporaryFile().writeAsStringSync('incomplete-private-copy');
      final migrated = await openEncrypted(directory, secrets);
      expect((await migrated.read('parent', 'private'))!['answer'], marker);
      await migrated.write('parent', 'private', {'answer': 'newer work'});
      await migrated.close();
      legacyFile().writeAsBytesSync(legacy);
      temporaryFile().writeAsBytesSync(legacy);
      final restarted = await openEncrypted(directory, secrets);
      expect(
        (await restarted.read('parent', 'private'))!['answer'],
        'newer work',
      );
      await restarted.close();
      expect(legacyFile().existsSync(), isFalse);
      expect(temporaryFile().existsSync(), isFalse);
    },
  );

  test(
    'sole encrypted migration copy is recovered; corruption preserves original',
    () async {
      var store = await openEncrypted(directory, secrets);
      await seed(store);
      await store.close();
      finalFile().renameSync(temporaryFile().path);
      store = await openEncrypted(directory, secrets);
      expect((await store.read('parent', 'private'))!['answer'], marker);
      await store.close();
      legacyFile().writeAsStringSync('old data must survive a bad final file');
      finalFile().writeAsStringSync('corrupted encrypted file');
      await expectLater(
        openEncrypted(directory, secrets),
        throwsA(isA<LocalDataException>()),
      );
      expect(
        legacyFile().readAsStringSync(),
        'old data must survive a bad final file',
      );
      expect(finalFile().readAsStringSync(), 'corrupted encrypted file');
    },
  );

  test(
    'legacy WAL committed rows migrate; encrypted WAL never contains payload',
    () async {
      final old = sqlite3.open(legacyFile().path);
      old.execute('PRAGMA journal_mode=WAL');
      old.execute('CREATE TABLE sample(value TEXT)');
      old.execute('INSERT INTO sample VALUES(?)', [marker]);
      secrets.values[EncryptedDatabase.keyName] = fixedKey;
      // Keep the legacy connection open so the row is only in the WAL at copy time.
      try {
        // Copy/verify under SQLite, but Windows holds open old files. Cleanup can
        // fail here; the verified new DB remains available for a subsequent retry.
        try {
          EncryptedDatabase.prepareFiles(directory.path, fixedKey);
        } on LocalDataException {
          expect(finalFile().existsSync(), isTrue);
        }
      } finally {
        old.close();
      }
      EncryptedDatabase.prepareFiles(directory.path, fixedKey);
      final db = sqlite3.open(finalFile().path);
      try {
        EncryptedDatabase.configure(db, fixedKey);
        expect(db.select('SELECT value FROM sample').single['value'], marker);
        db.execute('PRAGMA journal_mode=WAL');
        db.execute('PRAGMA wal_autocheckpoint=0');
        db.execute('INSERT INTO sample VALUES(?)', [imageMarker]);
        expectNoPlaintext(File('${finalFile().path}-wal'));
        expectNoPlaintext(finalFile());
        expect(db.select('PRAGMA secure_delete').single.values.single, 1);
        expect(db.select('PRAGMA temp_store').single.values.single, 2);
      } finally {
        db.close();
      }
    },
  );

  test(
    'key storage failures cannot create a plaintext database or erase old work',
    () async {
      legacyFile().writeAsStringSync('legacy work');
      secrets.failRead = true;
      await expectLater(
        openEncrypted(directory, secrets),
        throwsA(isA<LocalDataException>()),
      );
      secrets.failRead = false;
      secrets.dropWrite = true;
      await expectLater(
        openEncrypted(directory, secrets),
        throwsA(isA<LocalDataException>()),
      );
      expect(legacyFile().readAsStringSync(), 'legacy work');
      expect(finalFile().existsSync(), isFalse);
      expect(temporaryFile().existsSync(), isFalse);
    },
  );

  test(
    'interrupted first launch retries an empty stage but preserves nonempty sidecars',
    () async {
      secrets.values[EncryptedDatabase.keyName] = fixedKey;
      temporaryFile().writeAsBytesSync([]);
      final journal = File('${temporaryFile().path}-journal');
      journal.writeAsStringSync('possibly recoverable content');
      await expectLater(
        openEncrypted(directory, secrets),
        throwsA(isA<LocalDataException>()),
      );
      expect(journal.readAsStringSync(), 'possibly recoverable content');
      journal.deleteSync();
      final store = await openEncrypted(directory, secrets);
      await store.write('parent', 'private', {'answer': marker});
      await store.close();
      expectNoPlaintext(finalFile());
      expect(secrets.values[EncryptedDatabase.keyName], fixedKey);
    },
  );

  test(
    'secure session and PKCE migration verifies writes before removing legacy values',
    () async {
      final values = SecureAuthValues(
        secrets: secrets,
        backendUrl: 'https://project.supabase.co',
      );
      SharedPreferences.setMockInitialValues({
        values.sessionKey: 'old-session',
        SecureAuthValues.pkceKey: 'old-verifier',
        'task_notifications_enabled': true,
      });
      final session = SecureSessionStorage(values);
      final pkce = SecurePkceStorage(values);
      secrets.failWrite = true;
      await expectLater(
        session.initialize(),
        throwsA(isA<LocalDataException>()),
      );
      expect(
        (await SharedPreferences.getInstance()).getString(values.sessionKey),
        'old-session',
      );
      secrets.failWrite = false;
      await session.initialize();
      expect(await session.accessToken(), 'old-session');
      expect(await pkce.getItem(key: SecureAuthValues.pkceKey), 'old-verifier');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey(values.sessionKey), isFalse);
      expect(prefs.containsKey(SecureAuthValues.pkceKey), isFalse);
      expect(prefs.getBool('task_notifications_enabled'), isTrue);
      await pkce.removeItem(key: SecureAuthValues.pkceKey);
      expect(await pkce.getItem(key: SecureAuthValues.pkceKey), isNull);
    },
  );

  test(
    'serialized auth writes and sign-out tombstone prevent old session resurrection',
    () async {
      final values = SecureAuthValues(
        secrets: secrets,
        backendUrl: 'https://project.supabase.co',
      );
      final session = SecureSessionStorage(values);
      await session.initialize();
      await Future.wait([
        session.persistSession('first'),
        session.persistSession('newest'),
        session.removePersistedSession(),
      ]);
      // Simulate a crash leaving a legacy value after the secure sign-out commit.
      await (await SharedPreferences.getInstance()).setString(
        values.sessionKey,
        'stale-session',
      );
      final restarted = SecureSessionStorage(
        SecureAuthValues(
          secrets: secrets,
          backendUrl: 'https://project.supabase.co',
        ),
      );
      await restarted.initialize();
      expect(await restarted.hasAccessToken(), isFalse);
      expect(
        (await SharedPreferences.getInstance()).containsKey(values.sessionKey),
        isFalse,
      );
      await restarted.persistSession('another-account');
      expect(await restarted.accessToken(), 'another-account');
    },
  );

  test(
    'native secret errors are redacted and Android key reset is disabled',
    () async {
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      Map<dynamic, dynamic>? options;
      messenger.setMockMethodCallHandler(channel, (call) async {
        options = (call.arguments as Map)['options'] as Map;
        throw PlatformException(code: 'locked', message: 'SECRET_KEY_TOKEN');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await expectLater(
        const NativeDeviceSecrets().read('key'),
        throwsA(
          isA<LocalDataException>().having(
            (e) => e.toString(),
            'safe error',
            isNot(contains('SECRET_KEY_TOKEN')),
          ),
        ),
      );
      expect(options!['resetOnError'], 'false');
      expect(options!['migrateWithBackup'], 'true');
    },
  );

  test(
    'delayed persistence cannot restore a signed-out or previous account session',
    () async {
      var current = 'account-one';
      final values = SecureAuthValues(
        secrets: secrets,
        backendUrl: 'https://project.supabase.co',
      );
      final session = SecureSessionStorage(
        values,
        isCurrentSession: (value) => value == current,
      );
      await session.initialize();
      await session.persistSession(current);
      // An old event was queued before account switching but runs afterwards.
      final pending = session.persistSession('account-one');
      current = 'account-two';
      await pending;
      await session.persistSession(current);
      await session.persistSession('account-one');
      expect(await session.accessToken(), 'account-two');
      current = '';
      await session.removePersistedSession();
      await session.persistSession('account-two');
      expect(await session.accessToken(), isNull);
    },
  );

  test(
    'sign-out awaits durable removal and reports secure storage failure',
    () async {
      final client = SupabaseClient('https://project.supabase.co', 'public');
      addTearDown(client.dispose);
      final values = SecureAuthValues(
        secrets: secrets,
        backendUrl: 'https://project.supabase.co',
      );
      final session = SecureSessionStorage(values);
      await session.persistSession('persisted-session');
      final repository = SupabaseAuthRepository(
        client,
        sessionStorage: session,
      );
      secrets.failWrite = true;
      await expectLater(repository.signOut(), throwsStateError);
      secrets.failWrite = false;
      expect(await session.accessToken(), 'persisted-session');
      await repository.signOut();
      expect(await session.accessToken(), isNull);
    },
  );

  testWidgets(
    'startup failure preserves work, shows safe message and permits a single retry',
    (tester) async {
      var attempts = 0;
      final completion = Completer<Widget>();
      await tester.pumpWidget(
        StartupGate(
          load: () {
            attempts++;
            if (attempts == 1) throw const LocalDataException('设备已锁定，请解锁后重试');
            return completion.future;
          },
        ),
      );
      await tester.pump();
      expect(find.text('设备已锁定，请解锁后重试'), findsOneWidget);
      expect(find.text('清除数据'), findsNothing);
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(find.text('重试'), findsNothing);
      expect(attempts, 2);
      completion.complete(const MaterialApp(home: Text('资料已恢复')));
      await tester.pumpAndSettle();
      expect(find.text('资料已恢复'), findsOneWidget);
    },
  );
}
