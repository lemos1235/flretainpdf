import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'task_concurrency.dart';

/// 同时执行任务数的选择器：一个 −/＋ 步进器加一句解释，
/// 值和服务进程当前用的不一样时，下面多一条「重启后生效」的提示。
class ConcurrencySelector extends StatelessWidget {
  const ConcurrencySelector({
    super.key,
    required this.value,
    required this.onChanged,
    required this.activeValue,
    required this.needsRestart,
  });

  final int value;

  /// 服务进程当前实际生效的上限；0 表示没问到（服务还没就绪或版本太老）。
  final int activeValue;

  final bool needsRestart;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppColors.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainer,
                border: Border.all(color: theme.colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(10),
              ),
              padding: const EdgeInsets.all(2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _StepButton(
                    icon: Icons.remove_rounded,
                    onPressed: value > kMinMaxConcurrentTasks
                        ? () => onChanged(value - 1)
                        : null,
                  ),
                  SizedBox(
                    width: 32,
                    child: Text(
                      '$value',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                  _StepButton(
                    icon: Icons.add_rounded,
                    onPressed: value < kMaxMaxConcurrentTasks
                        ? () => onChanged(value + 1)
                        : null,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '最多同时执行 $value 个任务，多出来的排队等待，'
                '前面的跑完会自动开始。可选 '
                '$kMinMaxConcurrentTasks–$kMaxMaxConcurrentTasks。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
        if (needsRestart) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: app.accentSubtle,
              border: Border.all(color: app.accentBorder),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 16, color: app.accentText),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '已保存，重启应用后生效 —— 内置服务当前仍按 $activeValue 个并发运行。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: app.accentText,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onPressed != null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: 28,
          height: 28,
          child: Icon(
            icon,
            size: 16,
            color: enabled
                ? theme.colorScheme.onSurface
                : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }
}
