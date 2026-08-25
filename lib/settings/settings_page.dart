import 'package:flutter/material.dart';

import '../widgets/app_panel.dart';
import '../widgets/labeled_field.dart';
import 'app_settings.dart';
import 'appearance_selector.dart';

/// 设置页：放和具体文档无关的全局配置 —— 翻译模型接入信息、MinerU 服务地址。
/// 布局沿用主页的 `.page-shell`（限宽居中 + 卡片），只是内容更窄一些。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = AppSettingsScope.of(context);

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 20),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 700),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 页面头部
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      '偏好设置',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontSize: 18,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.secondary,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: theme.dividerColor),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.check,
                            size: 13,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '修改即时生效',
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: theme.colorScheme.onSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                if (settings.loadError.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.error.withValues(alpha: 0.1),
                      border: Border.all(
                        color: theme.colorScheme.error.withValues(alpha: 0.3),
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          color: theme.colorScheme.error,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '读取服务端默认配置失败',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.error,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                settings.loadError,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

                // 模型配置卡片
                AppPanel(
                  title: '翻译大模型配置',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: LabeledField(
                              controller: settings.translationModel,
                              label: '模型名称',
                              hint: '例如 gpt-4o, claude-3-5-sonnet',
                              bottomPadding: 8,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: LabeledField(
                              controller: settings.translationBaseUrl,
                              label: 'Base URL',
                              hint: '例如 https://api.openai.com/v1',
                              bottomPadding: 8,
                            ),
                          ),
                        ],
                      ),
                      SecretField(
                        controller: settings.translationKey,
                        label: 'API Key',
                        hint: '',
                        bottomPadding: 8,
                      ),
                      LabeledField(
                        controller: settings.translationPrompt,
                        label: '自定义系统提示词（可选）',
                        maxLines: 3,
                        last: true,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // MinerU 版面识别卡片
                AppPanel(
                  title: 'MinerU 版面识别服务',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: LabeledField(
                              controller: settings.mineruBaseUrl,
                              label: 'Base URL',
                              hint: '留空默认 mineru.net',
                              bottomPadding: 8,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: SecretField(
                              controller: settings.mineruToken,
                              label: 'Token 密钥',
                              hint: '',
                              bottomPadding: 8,
                              last: true,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // 外观卡片
                AppPanel(
                  title: '外观',
                  subtitle: '选择界面配色，切换后立即生效并记住。',
                  child: AppearanceSelector(
                    value: settings.themeMode,
                    onChanged: (mode) => settings.themeMode = mode,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

