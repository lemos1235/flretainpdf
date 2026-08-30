import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 自定义紧凑开关控件 (36x20) - Claude 风格圆润微动效开关
class AppSwitch extends StatelessWidget {
  const AppSwitch({
    super.key,
    required this.value,
    this.onChanged,
    this.width = 36.0,
    this.height = 20.0,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final enabled = onChanged != null;

    final inactiveTrackColor = isDark
        ? const Color(0xFF45433E)
        : const Color(0xFFE2DDD5);
    final activeTrackColor = theme.colorScheme.primary;

    final thumbSize = height - 4.0;

    return Semantics(
      toggled: value,
      child: GestureDetector(
        onTap: enabled ? () => onChanged!(!value) : null,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeInOut,
          width: width,
          height: height,
          padding: const EdgeInsets.all(2.0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(height / 2),
            color: value ? activeTrackColor : inactiveTrackColor,
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeInOut,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: thumbSize,
              height: thumbSize,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Color(0x26000000),
                    offset: Offset(0, 1),
                    blurRadius: 2,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 对应 `.feature-card`：开关 + 标题 + 说明，打开后整块高亮（Claude 风格）。
class FeatureCard extends StatelessWidget {
  const FeatureCard({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.icon,
    this.description,
    this.children = const [],
    this.enabled = true,
  });

  final String title;
  final IconData? icon;
  final String? description;
  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  /// 开关打开后才展开的附加字段。
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppColors.of(context);
    final isActive = enabled && value;

    Widget card = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isActive ? app.accentSubtle : theme.colorScheme.surfaceContainer,
        border: Border.all(
          color: isActive ? app.accentBorder : theme.dividerColor,
          width: isActive ? 1.2 : 1,
        ),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: enabled ? () => onChanged(!value) : null,
            borderRadius: BorderRadius.circular(6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: isActive
                          ? theme.colorScheme.primary.withValues(alpha: 0.12)
                          : theme.colorScheme.secondary.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      icon,
                      size: 14,
                      color: isActive
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontSize: 12.5,
                          color: theme.colorScheme.onSurface,
                          height: 1.2,
                        ),
                      ),
                      if (description case final description?) ...[
                        const SizedBox(height: 2),
                        Text(
                          description,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontSize: 10.5,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                AppSwitch(value: value, onChanged: enabled ? onChanged : null),
              ],
            ),
          ),
          if (isActive && children.isNotEmpty) ...[
            const SizedBox(height: 8),
            Divider(height: 1, color: theme.dividerColor),
            const SizedBox(height: 8),
            ...children,
          ],
        ],
      ),
    );

    if (!enabled) {
      card = Opacity(opacity: 0.45, child: card);
    }
    return card;
  }
}
