import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 外观选择：三张带窗口缩略图的卡片（浅色 / 深色 / 跟随系统），
/// 样式参考 Claude Desktop 的「Appearance」——缩略图在上、名字在下，
/// 选中的那张换成强调色描边并在右上角打勾。
class AppearanceSelector extends StatelessWidget {
  const AppearanceSelector({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final ThemeMode value;
  final ValueChanged<ThemeMode> onChanged;

  static const _options = [
    (ThemeMode.light, '白天'),
    (ThemeMode.dark, '夜间'),
    (ThemeMode.system, '跟随系统'),
  ];

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 540),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (index, (mode, label)) in _options.indexed) ...[
            if (index > 0) const SizedBox(width: 12),
            Expanded(
              child: _AppearanceCard(
                mode: mode,
                label: label,
                selected: value == mode,
                onSelect: () => onChanged(mode),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AppearanceCard extends StatelessWidget {
  const _AppearanceCard({
    required this.mode,
    required this.label,
    required this.selected,
    required this.onSelect,
  });

  final ThemeMode mode;
  final String label;
  final bool selected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppColors.of(context);
    return InkWell(
      onTap: onSelect,
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: selected ? app.accentSubtle : Colors.transparent,
              border: Border.all(
                color: selected ? app.accentBorder : theme.dividerColor,
                width: selected ? 1.5 : 1,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: _WindowPreview(mode: mode),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                size: 14,
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected
                      ? theme.colorScheme.onSurface
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 缩略图本体：一个「侧栏 + 内容占位条」的迷你窗口。
/// 跟随系统那张把深色版沿对角线叠在浅色版上，做出半明半暗的效果。
class _WindowPreview extends StatelessWidget {
  const _WindowPreview({required this.mode});

  final ThemeMode mode;

  @override
  Widget build(BuildContext context) {
    return switch (mode) {
      ThemeMode.light => const _MiniWindow(dark: false),
      ThemeMode.dark => const _MiniWindow(dark: true),
      ThemeMode.system => Stack(
        fit: StackFit.expand,
        children: [
          const _MiniWindow(dark: false),
          ClipPath(
            clipper: _DiagonalClipper(),
            child: const _MiniWindow(dark: true),
          ),
        ],
      ),
    };
  }
}

class _MiniWindow extends StatelessWidget {
  const _MiniWindow({required this.dark});

  final bool dark;

  @override
  Widget build(BuildContext context) {
    final scheme = (dark ? AppTheme.dark : AppTheme.light).colorScheme;
    return Container(
      color: scheme.surface,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 左侧导航栏，顶部一个强调色方块代表当前选中项。
          Container(
            width: 18,
            color: scheme.surfaceContainer,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Column(
              children: [
                _Block(color: scheme.primary, height: 6),
                const SizedBox(height: 4),
                _Block(color: scheme.outline, height: 6),
              ],
            ),
          ),
          Container(width: 1, color: scheme.outlineVariant),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Block(color: scheme.onSurface, height: 5, widthFactor: 0.55),
                  const SizedBox(height: 6),
                  // 内容卡片：一块白/深底 + 两行灰条。
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainer,
                        border: Border.all(color: scheme.outlineVariant),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _Block(color: scheme.outline, height: 4),
                          const SizedBox(height: 4),
                          _Block(
                            color: scheme.outline,
                            height: 4,
                            widthFactor: 0.7,
                          ),
                          const Spacer(),
                          Align(
                            alignment: Alignment.centerRight,
                            child: _Block(
                              color: scheme.primary,
                              height: 6,
                              width: 16,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({
    required this.color,
    required this.height,
    this.widthFactor,
    this.width,
  });

  final Color color;
  final double height;
  final double? widthFactor;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final bar = Container(
      height: height,
      width: width,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(height / 2),
      ),
    );
    if (widthFactor == null) {
      return bar;
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(widthFactor: widthFactor, child: bar),
    );
  }
}

/// 从右上角到左下角切一刀，只保留右下那半。
class _DiagonalClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) => Path()
    ..moveTo(size.width, 0)
    ..lineTo(size.width, size.height)
    ..lineTo(0, size.height)
    ..close();

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}
