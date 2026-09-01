import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../prefs_scope.dart';
import '../theme/app_theme.dart';
import '../widgets/labeled_field.dart';
import 'page_selection.dart';

/// 常用目标语言预设列表
const _popularLanguages = [
  (code: 'zh-CN', label: '中文'),
  (code: 'en', label: '英文'),
  (code: 'ja', label: '日文'),
  (code: 'ko', label: '韩文'),
];

String _formatLanguageBadge(String code) {
  for (final lang in _popularLanguages) {
    if (lang.code.toLowerCase() == code.toLowerCase()) {
      return '${lang.label} ($code)';
    }
  }
  return code;
}

const _translationExpandedKey = 'retainpdf-rs.section.translation-expanded';
const _advancedExpandedKey = 'retainpdf-rs.section.advanced-expanded';

/// 「文档相关」这组参数的字段名清单：创建任务的 multipart 字段、重试接口的
/// JSON 字段、表单本地持久化（job_form_section.dart 的 `_configFields`）都是
/// 同一份字段，共用这份清单，别再各处各写一遍。
const jobSettingsFieldKeys = [
  'translation_target_language',
  'pages',
  'skip_pages',
  'extract_backend',
  'formula_recognition_enabled',
  'table_recognition_enabled',
  'ocr_enabled',
];

/// 桌面端的原生启发式方案不再接入独立表格识别服务；原生表格识别仅保留在
/// web 客户端。这里的公式、表格和 OCR 开关因此都只对 MinerU 生效。
const _mineruOnlyRecognitionFieldKeys = {
  'formula_recognition_enabled',
  'table_recognition_enabled',
  'ocr_enabled',
};

/// 创建任务表单里和单个文档相关的那组参数：字段状态和它们的渲染抽在这里。
///
/// 只管和单个文档相关的参数；模型接入信息和 MinerU 的地址/Token 属于全局配置，
/// 放在设置页（`AppSettings`）里，由调用方在提交时合进来。
class JobSettingsController {
  final targetLanguage = TextEditingController(text: 'zh-CN');
  final pages = TextEditingController();
  final skipPages = TextEditingController();

  String extractBackend = 'native';
  bool formulaRecognitionEnabled = false;
  bool tableRecognitionEnabled = false;
  bool ocrEnabled = false;

  List<TextEditingController> get _all => [targetLanguage, pages, skipPages];

  void applyConfig(AppConfig config) {
    if (config.translationDefaultTargetLanguage.isNotEmpty) {
      targetLanguage.text = config.translationDefaultTargetLanguage;
    } else if (targetLanguage.text.isEmpty) {
      targetLanguage.text = 'zh-CN';
    }
  }

  /// 页码相关的本地校验，提交前先过一遍。合法时返回空串。
  String validatePages() {
    final error = validatePageSelection(pages.text, '翻译页码');
    if (error.isNotEmpty) {
      return error;
    }
    return validatePageSelection(skipPages.text, '跳过页码');
  }

  /// 单一数据源：[toMultipartFields] 和 [toRetryFields] 都从这里派生，
  /// 不再各自维护一份字段清单。键必须和 [jobSettingsFieldKeys] 完全对应，
  /// 下面的断言在测试/调试构建里会盯着这一点，防止新增字段时漏改。
  Map<String, Object> get _fieldValues {
    final values = <String, Object>{
      'translation_target_language': targetLanguage.text.trim(),
      'pages': pages.text.trim(),
      'skip_pages': skipPages.text.trim(),
      'extract_backend': extractBackend,
      'formula_recognition_enabled': formulaRecognitionEnabled,
      'table_recognition_enabled': tableRecognitionEnabled,
      'ocr_enabled': ocrEnabled,
    };
    assert(
      values.length == jobSettingsFieldKeys.length &&
          jobSettingsFieldKeys.every(values.containsKey),
      '_fieldValues 的键和 jobSettingsFieldKeys 没对齐',
    );
    return values;
  }

  /// 创建任务用的 multipart 字段。复刻 HTML 表单语义：勾上的 checkbox 发
  /// "on"，没勾的字段完全不出现在请求里。
  Map<String, String> toMultipartFields() {
    final fields = <String, String>{};
    _fieldValues.forEach((key, value) {
      if (value is bool) {
        if (value) {
          if (extractBackend != 'mineru' &&
              _mineruOnlyRecognitionFieldKeys.contains(key)) {
            return;
          }
          fields[key] = 'on';
        }
      } else {
        fields[key] = value as String;
      }
    });
    return fields;
  }

  /// 重试接口用的 JSON 字段：同一组参数，但布尔值发真正的 JSON 布尔，
  /// 不是 multipart 表单那套「勾上发 'on'，没勾就不出现」的语义。
  /// 原生模式下增强识别开关统一按 false 发送，避免传递无效参数。
  Map<String, dynamic> toRetryFields() {
    final fields = Map<String, Object>.of(_fieldValues);
    if (extractBackend != 'mineru') {
      for (final key in _mineruOnlyRecognitionFieldKeys) {
        fields[key] = false;
      }
    }
    return fields;
  }

  void dispose() {
    for (final controller in _all) {
      controller.dispose();
    }
  }
}

/// 翻译参数 / 版面提取方案 / 增强识别三段字段。
class JobSettingsFields extends StatefulWidget {
  const JobSettingsFields({
    super.key,
    required this.settings,
    required this.onChanged,
  });

  final JobSettingsController settings;

  /// 单选/开关改动后通知外层 setState（顺带触发配置持久化）。
  final VoidCallback onChanged;

  @override
  State<JobSettingsFields> createState() => _JobSettingsFieldsState();
}

class _JobSettingsFieldsState extends State<JobSettingsFields> {
  /// null 表示既没存过、用户这次也没手动折叠/展开过，此时按字段的值推断。
  bool? _advancedExpanded;

  /// 翻译参数是主流程，没存过就默认展开。
  bool _translationExpanded = true;

  late SharedPreferences _prefs;
  bool _restored = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // PrefsScope 里的实例是 main() 启动时预取好的，这里能同步拿到，
    // 首帧就是真实的展开状态，不会先展开/收起默认值再被 setState 改一次。
    if (!_restored) {
      _restored = true;
      _prefs = PrefsScope.of(context);
      _translationExpanded = _prefs.getBool(_translationExpandedKey) ?? true;
      _advancedExpanded = _prefs.getBool(_advancedExpandedKey);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = widget.settings;
    final isMineru = settings.extractBackend == 'mineru';
    final targetLanguage = settings.targetLanguage.text.trim();
    final advancedExpanded =
        _advancedExpanded ??
        (isMineru &&
            (settings.formulaRecognitionEnabled ||
                settings.tableRecognitionEnabled ||
                settings.ocrEnabled));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 核心翻译参数折叠卡片
        _CollapsibleCard(
          icon: LucideIcons.languages,
          title: '翻译参数',
          // 折叠时也能一眼看到译入语言
          badge: targetLanguage.isEmpty
              ? null
              : _formatLanguageBadge(targetLanguage),
          badgeHighlighted: targetLanguage.isNotEmpty,
          expanded: _translationExpanded,
          onToggle: () => setState(() {
            _translationExpanded = !_translationExpanded;
            _prefs.setBool(_translationExpandedKey, _translationExpanded);
          }),
          children: [
            // 目标语言：Label 与微型快捷胶囊合并为同一行
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  '目标语言',
                  style: fieldLabelStyle(context),
                  strutStyle: fieldLabelStrutStyle,
                ),
                const Spacer(),
                Wrap(
                  spacing: 4,
                  children: _popularLanguages.map((lang) {
                    final isSelected =
                        targetLanguage.toLowerCase() == lang.code.toLowerCase();
                    final app = AppColors.of(context);
                    return InkWell(
                      onTap: () {
                        setState(() {
                          settings.targetLanguage.text = lang.code;
                        });
                        widget.onChanged();
                      },
                      borderRadius: BorderRadius.circular(5),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 140),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? app.accentSubtle
                              : theme.colorScheme.surface,
                          border: Border.all(
                            color: isSelected
                                ? app.accentBorder
                                : theme.dividerColor,
                            width: isSelected ? 1.2 : 1,
                          ),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          lang.label,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: isSelected
                                ? app.accentText
                                : theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
            const SizedBox(height: 5),

            // 目标语言代码输入框
            TextField(
              controller: settings.targetLanguage,
              onChanged: (_) => setState(widget.onChanged),
              style: fieldTextStyle,
              strutStyle: fieldStrutStyle,
              decoration: const InputDecoration(hintText: '例如 zh-CN, en, ja'),
            ),
            const SizedBox(height: 8),

            // 页码设置：翻译页码与跳过页码双列并排，大幅节省纵向高度
            Row(
              children: [
                Expanded(
                  child: LabeledField(
                    controller: settings.pages,
                    onChanged: widget.onChanged,
                    label: '翻译页码',
                    hint: '例如 1-10,11,13 或 5-',
                    last: true,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: LabeledField(
                    controller: settings.skipPages,
                    onChanged: widget.onChanged,
                    label: '跳过页码',
                    hint: '例如 1,3-4',
                    last: true,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 10),

        // 高级版面识别选项折叠卡片
        _CollapsibleCard(
          icon: LucideIcons.scanLine,
          title: '版面识别',
          badge: isMineru
              ? (settings.formulaRecognitionEnabled ||
                        settings.tableRecognitionEnabled ||
                        settings.ocrEnabled
                    ? 'MinerU · 增强已开'
                    : 'MinerU')
              : '原生启发式',
          badgeHighlighted: isMineru,
          expanded: advancedExpanded,
          onToggle: () => setState(() {
            _advancedExpanded = !advancedExpanded;
            _prefs.setBool(_advancedExpandedKey, !advancedExpanded);
          }),
          children: [
            Row(
              children: [
                Text(
                  '版面提取方案',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 11.5,
                    letterSpacing: 0.2,
                  ),
                ),
                const Spacer(),
                Text(
                  isMineru ? '深度模型分析' : '规则快速提取',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.7,
                    ),
                    fontSize: 10.5,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: _BackendChoice(
                    title: '原生启发式',
                    tag: '本地 · 极速',
                    icon: LucideIcons.zap,
                    selected: !isMineru,
                    onTap: () => _onBackendChanged('native'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _BackendChoice(
                    title: 'MinerU',
                    tag: '高精 · 深度',
                    icon: LucideIcons.sparkles,
                    selected: isMineru,
                    onTap: () => _onBackendChanged('mineru'),
                  ),
                ),
              ],
            ),
            if (isMineru) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Text(
                    '内容保护与增强',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 11.5,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '按需点选启用',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.7,
                      ),
                      fontSize: 10.5,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: _FeatureChip(
                      title: '公式识别',
                      icon: LucideIcons.sigma,
                      value: settings.formulaRecognitionEnabled,
                      tooltip: '保留 LaTeX 格式数学公式',
                      onChanged: (val) {
                        setState(() {
                          settings.formulaRecognitionEnabled = val;
                        });
                        widget.onChanged();
                      },
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _FeatureChip(
                      title: '表格识别',
                      icon: LucideIcons.table,
                      value: settings.tableRecognitionEnabled,
                      tooltip: '识别并保留复杂表格结构',
                      onChanged: (val) {
                        setState(() {
                          settings.tableRecognitionEnabled = val;
                        });
                        widget.onChanged();
                      },
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _FeatureChip(
                      title: 'OCR 识别',
                      icon: LucideIcons.scanText,
                      value: settings.ocrEnabled,
                      tooltip: '提取扫描件及图片中的文本',
                      onChanged: (val) {
                        setState(() {
                          settings.ocrEnabled = val;
                        });
                        widget.onChanged();
                      },
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ],
    );
  }

  void _onBackendChanged(String value) {
    setState(() {
      widget.settings.extractBackend = value;
    });
    widget.onChanged();
  }
}

/// 参数分组用的折叠卡片：头部一行（图标 + 标题 + 可选徽章 + 箭头），
/// 展开后用分割线接内容。翻译参数和高级识别两块共用同一套外观（Claude 风格）。
class _CollapsibleCard extends StatelessWidget {
  const _CollapsibleCard({
    required this.icon,
    required this.title,
    required this.expanded,
    required this.onToggle,
    required this.children,
    this.badge,
    this.badgeHighlighted = false,
  });

  final IconData icon;
  final String title;
  final String? badge;

  /// 徽章用主色还是次色，用来区分「非默认」的选择。
  final bool badgeHighlighted;
  final bool expanded;
  final VoidCallback onToggle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppColors.of(context);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 折叠头部
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: badgeHighlighted
                          ? theme.colorScheme.primary.withValues(alpha: 0.12)
                          : theme.colorScheme.secondary.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      icon,
                      size: 14,
                      color: badgeHighlighted
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        height: 1.2,
                      ),
                    ),
                  ),
                  if (badge case final badge?) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: badgeHighlighted
                            ? app.accentSubtle
                            : theme.colorScheme.secondary.withValues(
                                alpha: 0.7,
                              ),
                        border: Border.all(
                          color: badgeHighlighted
                              ? app.accentBorder
                              : theme.dividerColor,
                        ),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        badge,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: badgeHighlighted
                              ? app.accentText
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 4),
                  Icon(
                    expanded ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),

          // 展开内容
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: !expanded
                ? const SizedBox(width: double.infinity)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Divider(height: 1, color: theme.dividerColor),
                      Padding(
                        padding: const EdgeInsets.all(10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: children,
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// 内容保护与增强开关胶囊（Claude 风格轻量微卡片 Toggle Chip）
class _FeatureChip extends StatelessWidget {
  const _FeatureChip({
    required this.title,
    required this.icon,
    required this.value,
    required this.onChanged,
    this.tooltip,
  });

  final String title;
  final IconData icon;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppColors.of(context);

    Widget chip = InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
        decoration: BoxDecoration(
          color: value ? app.accentSubtle : theme.colorScheme.surface,
          border: Border.all(
            color: value ? app.accentBorder : theme.colorScheme.outline,
            width: value ? 1.2 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 13,
              color: value
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: value ? FontWeight.w600 : FontWeight.w500,
                  color: value ? app.accentText : theme.colorScheme.onSurface,
                ),
              ),
            ),
            if (value) ...[
              const SizedBox(width: 3),
              Icon(
                LucideIcons.check,
                size: 11,
                color: theme.colorScheme.primary,
              ),
            ],
          ],
        ),
      ),
    );

    if (tooltip != null) {
      chip = Tooltip(
        message: tooltip!,
        waitDuration: const Duration(milliseconds: 300),
        child: chip,
      );
    }
    return chip;
  }
}

/// 提取方案横向快速切换卡片（Claude 风格 Segmented Hero Card）
class _BackendChoice extends StatelessWidget {
  const _BackendChoice({
    required this.title,
    required this.tag,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String tag;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppColors.of(context);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? app.accentSubtle
              : theme.colorScheme.surfaceContainer,
          border: Border.all(
            color: selected ? app.accentBorder : theme.dividerColor,
            width: selected ? 1.4 : 1,
          ),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  size: 13,
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: selected
                          ? app.accentText
                          : theme.colorScheme.onSurface,
                      fontSize: 12,
                    ),
                  ),
                ),
                if (selected)
                  Icon(
                    LucideIcons.check,
                    size: 13,
                    color: theme.colorScheme.primary,
                  ),
              ],
            ),
            const SizedBox(height: 5),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
              decoration: BoxDecoration(
                color: selected
                    ? theme.colorScheme.primary.withValues(alpha: 0.1)
                    : theme.colorScheme.secondary.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                tag,
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
