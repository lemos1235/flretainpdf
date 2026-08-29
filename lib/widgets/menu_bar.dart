import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 左侧导航栏能切换的两个页面。
enum AppSection { home, settings }

/// 桌面端的窄导航栏：一条 54px 宽的竖条，两个按钮垂直居中排布。
class AppMenuBar extends StatelessWidget {
  const AppMenuBar({super.key, required this.current, required this.onSelect});

  final AppSection current;
  final ValueChanged<AppSection> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 54,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(right: BorderSide(color: theme.dividerColor)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 16),
          // 顶部品牌 Logo
          SvgPicture.asset(
            'assets/images/logo.svg',
            width: 34,
            height: 34,
            theme: SvgTheme(currentColor: theme.colorScheme.primary),
          ),
          const SizedBox(height: 24),
          _MenuButton(
            icon: LucideIcons.house,
            label: '主页',
            selected: current == AppSection.home,
            onPress: () => onSelect(AppSection.home),
          ),
          const SizedBox(height: 10),
          _MenuButton(
            icon: LucideIcons.settings,
            label: '设置',
            selected: current == AppSection.settings,
            onPress: () => onSelect(AppSection.settings),
          ),
          const Spacer(),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _MenuButton extends StatefulWidget {
  const _MenuButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPress,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onPress;

  @override
  State<_MenuButton> createState() => _MenuButtonState();
}

class _MenuButtonState extends State<_MenuButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = widget.selected;

    // 避免 Colors.transparent (RGB 为 0,0,0) 插值时经过发黑发暗的中间色，
    // 使用与目标背景相同 RGB、仅透明度为 0 的颜色做平滑淡入淡出。
    final background = selected
        ? theme.colorScheme.primary
        : _hovered
        ? theme.colorScheme.secondary
        : theme.colorScheme.secondary.withValues(alpha: 0.0);

    final foreground = selected
        ? theme.colorScheme.onPrimary
        : _hovered
        ? theme.colorScheme.onSurface
        : theme.colorScheme.onSurfaceVariant;

    return Semantics(
      label: widget.label,
      button: true,
      selected: selected,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        hitTestBehavior: HitTestBehavior.opaque,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPress,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeInOut,
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Icon(widget.icon, size: 18, color: foreground),
          ),
        ),
      ),
    );
  }
}
