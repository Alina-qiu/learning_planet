import 'package:flutter/material.dart';

import '../features/home/presentation/home_screen.dart';
import 'theme.dart';

class LearningPlanetApp extends StatelessWidget {
  const LearningPlanetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '学习星球',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const HomeScreen(),
    );
  }
}
