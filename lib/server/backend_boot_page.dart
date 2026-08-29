import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/app_panel.dart';
import '../widgets/status_text.dart';
import 'backend_service.dart';

/// 内置服务就绪之前挡在主界面前面的页面。
///
/// 启动通常一两秒就完事，转圈加文案反而闪一下更晃眼，所以进行中就是一块和主页
/// 同色的空白（`scaffoldBackgroundColor` 即 `colorScheme.surface`），看着像窗口
/// 还没画完。只有真出错了才把诊断信息摆出来。
class BackendBootPage extends StatelessWidget {
  const BackendBootPage({super.key, required this.backend});

  final BackendService backend;

  @override
  Widget build(BuildContext context) {
    if (!backend.hasFailed) {
      return const Scaffold(body: SizedBox.expand());
    }
    return Scaffold(
      body: Center(child: _BackendFailure(backend: backend)),
    );
  }
}

class _BackendFailure extends StatelessWidget {
  const _BackendFailure({required this.backend});

  final BackendService backend;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: AppPanel(
          title: '服务未能启动',
          subtitle: '翻译功能依赖本地服务，它没起来的话任务列表和创建任务都用不了。',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              StatusText(message: backend.message, isError: true),
              if (backend.detail.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  constraints: const BoxConstraints(maxHeight: 160),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      backend.detail,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'Menlo',
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                children: [
                  FilledButton(
                    onPressed: backend.retry,
                    child: const Text('重试'),
                  ),
                  const SizedBox(width: 8),
                  if (backend.detail.isNotEmpty)
                    TextButton(
                      onPressed: () => Clipboard.setData(
                        ClipboardData(
                          text: '${backend.message}\n\n${backend.detail}',
                        ),
                      ),
                      child: const Text('复制诊断信息'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
