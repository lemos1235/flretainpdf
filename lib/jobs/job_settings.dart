import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../prefs_scope.dart';
import '../theme/app_theme.dart';
import '../widgets/feature_card.dart';
import '../widgets/labeled_field.dart';
import 'page_selection.dart';

/// 两块折叠卡片的展开状态，跨会话记住用户的展开习惯。
const _translationExpandedKey = 'retainpdf-rs.section.translation-expanded';
const _advancedExpandedKey = 'retainpdf-rs.section.advanced-expanded';

/// 「文档相关」这组参数的字段名清单：创建任务的 multipart 字段、重试接口的
/// JSON 字段、表单本地持久化（job_form_section.dart 的 `_configFields`）都是
/// 同一份字段，共用这份清单，别再各处各写一遍。
const jobSettingsFieldKeys = [
  'translation_target_language',
  'pages',
  'skip_pages',
  'table_recognition_base_url',
  'table_recognition_flavor',
  'extract_backend',
  'formula_recognition_enabled',
  'table_recognition_enabled',
  'ocr_enabled',
];

/// 创建任务表单里和单个文档相关的那组参数：字段状态和它们的渲染抽在这里。
///
/// 只管和单个文档相关的参数；模型接入信息和 MinerU 的地址/Token 属于全局配置，
/// 放在设置页（`AppSettings`）里，由调用方在提交时合进来。
class JobSettingsController {
  final targetLanguage = TextEditingController(text: 'zh-CN');
  final pages = TextEditingController();
  final skipPages = TextEditingController();
  final tableRecognitionBaseUrl = TextEditingController();

  String extractBackend = 'native';
  String tableRecognitionFlavor = 'lattice';
  bool formulaRecognitionEnabled = false;
  bool tableRecognitionEnabled = false;
  bool ocrEnabled = false;

  List<TextEditingController> get _all => [
    targetLanguage,
    pages,
    skipPages,
    tableRecognitionBaseUrl,
  ];

  void applyConfig(AppConfig config) {
    if (config.translationDefaultTargetLanguage.isNotEmpty) {
      targetLanguage.text = config.translationDefaultTargetLanguage;
    } else if (targetLanguage.text.isEmpty) {
      targetLanguage.text = 'zh-CN';
    }
    tableRecognitionBaseUrl.text = config.tableRecognitionBaseUrl;
    tableRecognitionFlavor = _flavorOr(config.tableRecognitionFlavor);
  }

  String _flavorOr(String value) => value == 'stream' ? 'stream' : 'lattice';

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
      'table_recognition_base_url': tableRecognitionBaseUrl.text.trim(),
      'table_recognition_flavor': tableRecognitionFlavor,
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
  Map<String, dynamic> toRetryFields() => Map.of(_fieldValues);

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
        (isMineru ||
            settings.formulaRecognitionEnabled ||
            settings.tableRecognitionEnabled ||
            settings.ocrEnabled);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 核心翻译参数折叠卡片
        _CollapsibleCard(
          icon: Icons.translate_outlined,
          title: '翻译参数',
          // 折叠时也能一眼看到译入语言
          badge: targetLanguage.isEmpty ? null : targetLanguage,
          expanded: _translationExpanded,
          onToggle: () => setState(() {
            _translationExpanded = !_translationExpanded;
            _prefs.setBool(_translationExpandedKey, _translationExpanded);
          }),
          children: [
            // 目标语言输入框
            LabeledField(
              controller: settings.targetLanguage,
              // 自己也要重建，徽章才跟着输入走
              onChanged: () => setState(widget.onChanged),
              label: '目标语言',
              hint: '例如 zh-CN, en, ja',
              bottomPadding: 8,
            ),

            // 页码范围
            LabeledField(
              controller: settings.pages,
              onChanged: widget.onChanged,
              label: '翻译页码（留空即全篇）',
              hint: '例如 1-10,11,13 或 5-',
              bottomPadding: 8,
            ),

            // 跳过页码
            LabeledField(
              controller: settings.skipPages,
              onChanged: widget.onChanged,
              label: '跳过页码（不翻译）',
              hint: '例如 1,3-4',
              last: true,
            ),
          ],
        ),
        const SizedBox(height: 10),

        // 高级识别选项折叠卡片
        _CollapsibleCard(
          icon: Icons.tune_outlined,
          title: '版面识别',
          badge: isMineru ? 'MinerU' : '原生',
          badgeHighlighted: isMineru,
          expanded: advancedExpanded,
          onToggle: () => setState(() {
            _advancedExpanded = !advancedExpanded;
            _prefs.setBool(_advancedExpandedKey, !advancedExpanded);
          }),
          children: [
            Text(
              '版面提取方案',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 12,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: _BackendChoice(
                    title: '原生启发式',
                    selected: !isMineru,
                    onTap: () => _onBackendChanged('native'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _BackendChoice(
                    title: 'MinerU',
                    selected: isMineru,
                    onTap: () => _onBackendChanged('mineru'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            Text(
              '内容保护与增强识别',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 12,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 6),
            FeatureCard(
              title: '公式识别',
              value: settings.formulaRecognitionEnabled,
              onChanged: (value) {
                settings.formulaRecognitionEnabled = value;
                widget.onChanged();
              },
            ),
            if (isMineru) ...[
              const SizedBox(height: 6),
              FeatureCard(
                title: '表格识别',
                value: settings.tableRecognitionEnabled,
                onChanged: (value) {
                  settings.tableRecognitionEnabled = value;
                  widget.onChanged();
                },
              ),
              const SizedBox(height: 6),
              FeatureCard(
                title: 'OCR 识别',
                value: settings.ocrEnabled,
                onChanged: (value) {
                  settings.ocrEnabled = value;
                  widget.onChanged();
                },
              ),
            ],
          ],
        ),
      ],
    );
  }

  void _onBackendChanged(String value) {
    widget.settings.extractBackend = value;
    if (value != 'mineru') {
      widget.settings.ocrEnabled = false;
      widget.settings.tableRecognitionEnabled = false;
    }
    widget.onChanged();
  }
}

/// 参数分组用的折叠卡片：头部一行（图标 + 标题 + 可选徽章 + 箭头），
/// 展开后用分割线接内容。翻译参数和高级识别两块共用同一套外观。
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(icon, size: 16, color: theme.colorScheme.primary),
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
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: badgeHighlighted
                            ? theme.colorScheme.primary
                            : theme.colorScheme.secondary,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        badge,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: badgeHighlighted
                              ? theme.colorScheme.onPrimary
                              : theme.colorScheme.onSecondary,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 6),
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),

          // 展开内容：用 AnimatedSize 包一层，状态变化（比如版面识别卡片
          // 会随网络配置回来后的字段推断展开）是平滑过渡而不是硬切换。
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: !expanded
                ? const SizedBox(width: double.infinity)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Divider(height: 1),
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

/// 提取方案横向快速切换卡片
class _BackendChoice extends StatelessWidget {
  const _BackendChoice({
    required this.title,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? app.accentSubtle : theme.colorScheme.surfaceContainer,
          border: Border.all(
            color: selected ? app.accentBorder : theme.dividerColor,
            width: selected ? 1.2 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          title,
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: selected ? app.accentText : theme.colorScheme.onSurface,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

