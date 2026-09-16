import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/app/app.dart';
import 'package:learning_planet/features/auth_family/data/auth_repository.dart';
import 'package:learning_planet/features/auth_family/domain/auth_session.dart';

void main() {
  testWidgets('未登录时展示邮箱登录并发送验证码', (tester) async {
    final repository = FakeAuthRepository();
    await tester.pumpWidget(LearningPlanetApp(authRepository: repository));
    await tester.pump();

    expect(find.text('登录学习星球'), findsOneWidget);
    await tester.enterText(find.byType(EditableText), 'parent@example.com');
    await tester.tap(find.text('发送登录链接'));
    await tester.pump();

    expect(repository.lastOtpEmail, 'parent@example.com');
    expect(find.text('登录链接已发送，请检查邮箱'), findsOneWidget);
  });

  testWidgets('登录后展示今日任务和自动错题复习入口', (tester) async {
    final repository = FakeAuthRepository(
      const AuthSession(userId: 'parent-1', email: 'parent@example.com'),
    );
    await tester.pumpWidget(LearningPlanetApp(authRepository: repository));
    await tester.pump();

    expect(find.text('今日任务'), findsOneWidget);
    expect(find.text('今日错题复习'), findsOneWidget);
    expect(find.text('复习'), findsOneWidget);
  });
}

class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository([this.currentSession]);

  @override
  final AuthSession? currentSession;
  String? lastOtpEmail;

  @override
  Future<void> sendEmailOtp(String email) async => lastOtpEmail = email;

  @override
  Future<void> signOut() async {}

  @override
  Stream<AuthSession?> watchSession() => Stream.value(currentSession);
}
