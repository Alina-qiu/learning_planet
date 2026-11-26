import 'package:flutter/material.dart';

Future<bool> confirmReplaceImageSelection(BuildContext context) async {
  if (!context.mounted) return false;
  return await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('放弃本机上次未恢复的选图？'),
              content: const Text(
                '保留后，可回到原来的孩子和录入模式恢复。重新选图会放弃上次仍在系统中的选择，已保存的草稿会保留。',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('保留上次选择'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('放弃并重新选图'),
                ),
              ],
            ),
          ) ==
          true &&
      context.mounted;
}
