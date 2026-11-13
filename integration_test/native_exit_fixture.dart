import 'package:flutter/material.dart';

// Only the dedicated API36 emulator harness builds this entry point. The
// independent native Activity exercises the production diagnostic handler.
void main() => runApp(
  const MaterialApp(
    home: Scaffold(body: Center(child: Text('系统退出记录本机验证'))),
  ),
);
