import 'package:flutter/material.dart';
import '../data/economy_commands.dart';

class EconomyPendingCommand extends StatelessWidget {
  const EconomyPendingCommand({
    required this.request,
    required this.busy,
    required this.parent,
    required this.onAction,
    super.key,
  });
  final EconomyCommand request;
  final bool busy, parent;
  final void Function(String) onAction;
  @override
  Widget build(BuildContext context) {
    final locked = request.locked || request.kind == 'adjust' && !parent;
    final done = const ['applied', 'abandoned'].contains(request.status);
    final summary = request.kind == 'redeem'
        ? '兑换申请：${request.display['title']} · ${request.display['cost']}金币'
        : '家长调账：${request.command['coins']}金币 · ${request.command['xp_amount']}XP\n${request.command['reason']}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(locked ? '有一笔家长调账待核对，请返回首页验证 PIN。' : summary),
            if (!locked) ...[
              Text(
                request.status == 'applied'
                    ? '已受理，请查看兑换记录或账本。核对不会重复提交。'
                    : request.status == 'abandoned'
                    ? '未执行的请求已停止。'
                    : '原请求已保存在本机。请先联网核对，再决定重试或停止。',
              ),
              Wrap(
                spacing: 8,
                children: [
                  if (done)
                    TextButton(
                      onPressed: busy ? null : () => onAction('acknowledge'),
                      child: const Text('我已了解'),
                    )
                  else ...[
                    FilledButton.tonal(
                      onPressed: busy ? null : () => onAction('inspect'),
                      child: const Text('核对结果'),
                    ),
                    TextButton(
                      onPressed: busy ? null : () => onAction('submit'),
                      child: const Text('重试原请求'),
                    ),
                    TextButton(
                      onPressed: busy ? null : () => onAction('cancel'),
                      child: const Text('停止未执行请求'),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
