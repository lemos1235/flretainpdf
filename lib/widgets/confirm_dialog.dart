import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 桌面小窗口用的紧凑确认框：固定窄宽度、左侧图标徽标、右下角一对按钮。
/// 相比 Material 默认的 `AlertDialog`，去掉了过大的内边距与标题字号，
/// 让它在 800x628 的窗口里不至于喧宾夺主。
class AppConfirmDialog extends StatelessWidget {
  const AppConfirmDialog({
    super.key,
    required this.title,
    required this.message,
    this.detail,
    this.icon = Icons.help_outline,
    this.confirmLabel = '确定',
    this.cancelLabel = '取消',
    this.destructive = false,
  });

  final String title;
  final String message;

  /// 需要单独突出的对象（比如文件名），会以等宽的强调块单独占一行。
  final String? detail;
  final IconData icon;
  final String confirmLabel;
  final String cancelLabel;

  /// 破坏性操作用红色系强调，否则走主题强调色。
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final accent = destructive
        ? theme.colorScheme.error
        : theme.colorScheme.primary;
    final badgeBackground = destructive
        ? colors.dangerSubtle
        : colors.accentSubtle;

    // 窗口可以从 740 宽拉到全屏，固定宽度在大屏上会显得过分袖珍；
    // 让宽度跟着窗口走，间距同步放松一点，字号与图标保持不变。
    final windowWidth = MediaQuery.sizeOf(context).width;
    final width = (windowWidth * 0.42).clamp(340.0, 520.0);
    final scale = (width / 360).clamp(1.0, 1.35);

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: Padding(
          padding: EdgeInsets.all(18 * scale),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: badgeBackground,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(icon, size: 17, color: accent),
                  ),
                  SizedBox(width: 12 * scale),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: EdgeInsets.only(top: 4 * scale),
                          child: Text(
                            title,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        SizedBox(height: 6 * scale),
                        Text(
                          message,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 12.5,
                            height: 1.5,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (detail case final detail?) ...[
                SizedBox(height: 12 * scale),
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: 10 * scale,
                    vertical: 8 * scale,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondary,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
              SizedBox(height: 18 * scale),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.onSurfaceVariant,
                      padding: EdgeInsets.symmetric(
                        horizontal: 14 * scale,
                        vertical: 8 * scale,
                      ),
                      textStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(cancelLabel),
                  ),
                  SizedBox(width: 8 * scale),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: destructive
                          ? theme.colorScheme.onError
                          : theme.colorScheme.onPrimary,
                      padding: EdgeInsets.symmetric(
                        horizontal: 16 * scale,
                        vertical: 9 * scale,
                      ),
                      textStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text(confirmLabel),
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

/// 弹出确认框，用户取消或按 Esc 关闭时返回 false。
Future<bool> showAppConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String? detail,
  IconData icon = Icons.help_outline,
  String confirmLabel = '确定',
  String cancelLabel = '取消',
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AppConfirmDialog(
      title: title,
      message: message,
      detail: detail,
      icon: icon,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      destructive: destructive,
    ),
  );
  return result ?? false;
}
