import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 表单里的普通文本框，统一带上分隔间距。
class LabeledField extends StatelessWidget {
  const LabeledField({
    super.key,
    required this.controller,
    required this.label,
    this.onChanged,
    this.hint,
    this.description,
    this.maxLines = 1,
    this.last = false,
    this.bottomPadding = 10,
  });

  final TextEditingController controller;
  final String label;

  /// 需要跟着输入做别的事（比如 setState / 持久化）时传。
  final VoidCallback? onChanged;
  final String? hint;
  final String? description;
  final int maxLines;

  /// 分组里最后一个字段不再留底部间距。
  final bool last;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : bottomPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: fieldLabelStyle(context),
            strutStyle: fieldLabelStrutStyle,
          ),
          const SizedBox(height: 5),
          TextField(
            controller: controller,
            onChanged: onChanged == null ? null : (_) => onChanged!(),
            maxLines: maxLines,
            minLines: maxLines > 1 ? maxLines : null,
            style: fieldTextStyle,
            strutStyle: fieldStrutStyle,
            decoration: InputDecoration(
              hintText: hint,
              helperText: description,
            ),
          ),
        ],
      ),
    );
  }
}

/// 输入框正文样式。行高写死，配合 [fieldStrutStyle] 让输入框高度只由样式决定：
/// 否则「https://mineru.net」这种纯拉丁文本用的是默认字体的行高，而
/// 「留空使用默认 Token」会落到中文回退字体（PingFang 等）上，两者 ascent/descent
/// 不同，同一行里的两个输入框就会差出一两个像素、底边对不齐。
const TextStyle fieldTextStyle = TextStyle(fontSize: 13, height: 1.3);

/// 强制输入框行高，使高度与实际填的是中文还是英文无关。
const StrutStyle fieldStrutStyle = StrutStyle(
  fontSize: 13,
  height: 1.3,
  forceStrutHeight: true,
);

/// 标签同理：中英混排的标签不应该比纯中文标签高，否则会把下面的输入框顶下去。
const StrutStyle fieldLabelStrutStyle = StrutStyle(
  fontSize: 12,
  height: 1.2,
  forceStrutHeight: true,
);

/// 字段标签统一比分组标题（[FormSection]/[AppPanel] 的 title，14~18px 加粗）
/// 小一档：中文字体粗细对比不明显，光靠字重区分层级容易看着一样大，
/// 所以这里用更小的字号 + 偏灰的颜色，让「字段标签」明确从属于「分组标题」。
TextStyle fieldLabelStyle(BuildContext context) {
  final theme = Theme.of(context);
  return theme.textTheme.bodySmall?.copyWith(
        fontWeight: FontWeight.w600,
        fontSize: 12,
        color: theme.colorScheme.onSurface.withValues(alpha: 0.82),
        height: 1.2,
      ) ??
      const TextStyle(fontSize: 12, fontWeight: FontWeight.w600);
}

/// 眼睛按钮占位尺寸：宽度留出图标 + 右侧留白，高度压到不超过一行文本，
/// 保证带按钮的输入框与不带按钮的输入框等高。
const double _secretSuffixWidth = 34;
const double _secretSuffixHeight = 20;

/// API Key / Token 输入框：默认遮挡，输入框内右侧按钮切换明文。
class SecretField extends StatefulWidget {
  const SecretField({
    super.key,
    required this.controller,
    required this.label,
    required this.hint,
    this.description,
    this.last = false,
    this.bottomPadding = 10,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final String? description;
  final bool last;
  final double bottomPadding;

  @override
  State<SecretField> createState() => _SecretFieldState();
}

class _SecretFieldState extends State<SecretField> {
  bool _obscured = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: widget.last ? 0 : widget.bottomPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.label,
            style: fieldLabelStyle(context),
            strutStyle: fieldLabelStrutStyle,
          ),
          const SizedBox(height: 5),
          TextField(
            controller: widget.controller,
            obscureText: _obscured,
            autocorrect: false,
            enableSuggestions: false,
            style: fieldTextStyle,
            strutStyle: fieldStrutStyle,
            decoration: InputDecoration(
              hintText: widget.hint,
              helperText: widget.description,
              // IconButton 自带 40x40 的最小点击区，直接塞进 suffixIcon 会把输入框
              // 顶高一截，导致它和同一行里的普通 LabeledField 高度、基线都对不齐。
              // 这里把按钮的内边距/约束清零，再用 suffixIconConstraints 限制它不超过
              // 文本行高，输入框的高度就只由 contentPadding + 文本决定。
              suffixIconConstraints: const BoxConstraints(
                minWidth: _secretSuffixWidth,
                maxWidth: _secretSuffixWidth,
                minHeight: 0,
                maxHeight: _secretSuffixHeight,
              ),
              suffixIcon: IconButton(
                icon: Icon(
                  _obscured ? LucideIcons.eye : LucideIcons.eyeOff,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                onPressed: () => setState(() => _obscured = !_obscured),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                visualDensity: VisualDensity.compact,
                splashRadius: 16,
                tooltip: _obscured ? '显示内容' : '隐藏内容',
              ),
            ),
          ),
        ],
      ),
    );
  }
}


