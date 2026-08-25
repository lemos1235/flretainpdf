import 'package:flutter/material.dart';

/// 表单/弹窗底部那一行状态文案，出错时用 error 色。
class StatusText extends StatelessWidget {
  const StatusText({super.key, required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      message,
      style: theme.textTheme.bodyMedium?.copyWith(
        color: isError
            ? theme.colorScheme.error
            : theme.colorScheme.onSurfaceVariant,
        fontSize: 13,
        height: 1.5,
      ),
    );
  }
}

