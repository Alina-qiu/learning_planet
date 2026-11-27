import 'package:flutter/material.dart';

// Only the dedicated emulator harness builds this entry point. The real native
// Application remains unchanged; no backend or diagnostic scope is bound by
// Dart. A separate test Activity exercises the real native bridge and lifecycle.
void main() => runApp(
  const MaterialApp(
    home: Scaffold(body: Center(child: Text('原生ANR采集本机验证'))),
  ),
);
