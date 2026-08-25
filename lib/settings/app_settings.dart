import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';

/// 设置页里的字段，跨次启动记住 —— 包括密钥/Token：用户明确要求重开 App
/// 不必重填，所以它们和其它字段一样写进 shared_preferences（明文）。
const _settingsFields = [
  'translation_model',
  'translation_base_url',
  'translation_key',
  'translation_prompt',
  'mineru_base_url',
  'mineru_token',
];
const _storageKey = 'retainpdf-rs.app-settings.v1';

/// 外观模式和上面那些文本字段不同，单独存一个 key，免得和迁移逻辑纠缠。
const _themeModeKey = 'retainpdf-rs.theme-mode';

/// 这些字段以前存在创建任务表单的配置里，第一次启动时顺手迁移过来。
const _legacyFormStorageKey = 'retainpdf-rs.form-config.v6';

/// 全局配置：模型接入信息和 MinerU 的服务地址/Token。
///
/// 它们和具体某个 PDF 无关，所以从「创建任务」表单里挪到了设置页，
/// 创建任务时在提交时读这里的值。全部字段都会存到本地。
class AppSettings extends ChangeNotifier {
  final translationModel = TextEditingController();
  final translationBaseUrl = TextEditingController();
  final translationKey = TextEditingController();
  final translationPrompt = TextEditingController();
  final mineruBaseUrl = TextEditingController();
  final mineruToken = TextEditingController();

  SharedPreferences? _prefs;

  ThemeMode _themeMode = ThemeMode.system;

  /// 外观：跟随系统 / 常亮 / 常暗。
  ThemeMode get themeMode => _themeMode;

  set themeMode(ThemeMode value) {
    if (_themeMode == value) {
      return;
    }
    _themeMode = value;
    _prefs?.setString(_themeModeKey, value.name);
    notifyListeners();
  }

  /// 读服务端默认值失败时的提示，设置页顶部会显示。
  String loadError = '';

  List<TextEditingController> get _persisted => [
    translationModel,
    translationBaseUrl,
    translationKey,
    translationPrompt,
    mineruBaseUrl,
    mineruToken,
  ];

  /// 先拿服务端默认值打底，再让本地存过的配置覆盖上去。
  Future<void> load(ApiClient api) async {
    try {
      final config = await api.fetchConfig();
      translationModel.text = config.translationModel;
      translationBaseUrl.text = config.translationBaseUrl;
      mineruBaseUrl.text = config.mineruBaseUrl;
      loadError = '';
    } catch (error) {
      loadError = describeError(error);
    }

    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    final storedTheme = prefs.getString(_themeModeKey);
    _themeMode = ThemeMode.values.firstWhere(
      (mode) => mode.name == storedTheme,
      orElse: () => ThemeMode.system,
    );
    final stored =
        _read(prefs, _storageKey) ?? _read(prefs, _legacyFormStorageKey);
    if (stored != null) {
      for (final field in _settingsFields) {
        final value = stored[field];
        // 空字符串不覆盖服务端默认值。
        if (value is String && value.trim().isNotEmpty) {
          _setField(field, value);
        }
      }
    }
    for (final controller in _persisted) {
      controller.addListener(_persist);
    }
    notifyListeners();
  }

  Map<String, dynamic>? _read(SharedPreferences prefs, String key) {
    final raw = prefs.getString(key);
    if (raw == null) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  void _persist() {
    final prefs = _prefs;
    if (prefs == null) {
      return;
    }
    final payload = {
      for (final field in _settingsFields) field: _getField(field),
    };
    prefs.setString(_storageKey, jsonEncode(payload));
  }

  String _getField(String field) => switch (field) {
    'translation_model' => translationModel.text,
    'translation_base_url' => translationBaseUrl.text,
    'translation_key' => translationKey.text,
    'translation_prompt' => translationPrompt.text,
    'mineru_base_url' => mineruBaseUrl.text,
    'mineru_token' => mineruToken.text,
    _ => '',
  };

  void _setField(String field, String value) {
    switch (field) {
      case 'translation_model':
        translationModel.text = value;
      case 'translation_base_url':
        translationBaseUrl.text = value;
      case 'translation_key':
        translationKey.text = value;
      case 'translation_prompt':
        translationPrompt.text = value;
      case 'mineru_base_url':
        mineruBaseUrl.text = value;
      case 'mineru_token':
        mineruToken.text = value;
    }
  }

  /// 创建任务用的 multipart 字段（空值也照发，语义同 HTML 表单里的空输入框）。
  Map<String, String> toMultipartFields() => {
    'translation_model': translationModel.text.trim(),
    'translation_base_url': translationBaseUrl.text.trim(),
    'translation_key': translationKey.text.trim(),
    'translation_prompt': translationPrompt.text,
    'mineru_base_url': mineruBaseUrl.text.trim(),
    'mineru_token': mineruToken.text.trim(),
  };

  @override
  void dispose() {
    for (final controller in [
      translationModel,
      translationBaseUrl,
      translationKey,
      translationPrompt,
      mineruBaseUrl,
      mineruToken,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }
}

/// 让任意位置都能拿到那份唯一的 [AppSettings]。
class AppSettingsScope extends InheritedNotifier<AppSettings> {
  const AppSettingsScope({
    super.key,
    required AppSettings settings,
    required super.child,
  }) : super(notifier: settings);

  static AppSettings of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AppSettingsScope>();
    assert(scope != null, 'AppSettingsScope 不在当前 context 之上');
    return scope!.notifier!;
  }
}
