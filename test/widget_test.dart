import 'package:flutter_test/flutter_test.dart';
import 'package:learning_planet/app/app.dart';

void main() {
  testWidgets('首页展示今日任务和自动错题复习入口', (tester) async {
    await tester.pumpWidget(const LearningPlanetApp());

    expect(find.text('今日任务'), findsOneWidget);
    expect(find.text('今日错题复习'), findsOneWidget);
    expect(find.text('复习'), findsOneWidget);
  });
}
