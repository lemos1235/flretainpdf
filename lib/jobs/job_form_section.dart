import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/api_client.dart';
import '../settings/app_settings.dart';
import '../theme/app_theme.dart';
import '../widgets/app_panel.dart';
import '../widgets/status_text.dart';
import 'job_settings.dart';

/// 表单里需要跨次启动记住的字段。模型配置和 MinerU 的地址/Token 已经挪到
/// 设置页，由 `AppSettings` 自己存（v6 → v7 就是为此拆的）。
const _configFields = [
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
/// 三个识别开关按 'true'/'false' 存成字符串，和其它字段共用一套读写。
const _storageKey = 'retainpdf-rs.form-config.v7';

/// v6 里除了上面这些字段，还混着现在归设置页管的模型配置；这里只读自己那部分。
const _legacyStorageKey = 'retainpdf-rs.form-config.v6';

class JobFormSection extends StatefulWidget {
  const JobFormSection({
    super.key,
    required this.api,
    required this.onJobCreated,
  });

  final ApiClient api;
  final Future<void> Function() onJobCreated;

  @override
  State<JobFormSection> createState() => _JobFormSectionState();
}

class _JobFormSectionState extends State<JobFormSection> {
  final _settings = JobSettingsController();
  SharedPreferences? _prefs;
  String? _filePath;
  String? _fileName;
  int? _fileSize;
  bool _submitting = false;
  String _status = '';
  bool _statusIsError = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _settings.dispose();
    super.dispose();
  }

  /// 先拿服务端默认值打底，再让本地存过的配置覆盖上去 —— 顺序和 webapp 一致。
  Future<void> _bootstrap() async {
    try {
      final config = await widget.api.fetchConfig();
      if (!mounted) {
        return;
      }
      setState(() => _settings.applyConfig(config));
    } catch (error) {
      if (mounted) {
        _setStatus(describeError(error), isError: true);
      }
    }
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) {
      return;
    }
    _prefs = prefs;
    setState(() => _loadStoredConfig(prefs));
  }

  void _loadStoredConfig(SharedPreferences prefs) {
    final raw =
        prefs.getString(_storageKey) ?? prefs.getString(_legacyStorageKey);
    if (raw == null) {
      return;
    }
    Map<String, dynamic> stored;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return;
      }
      stored = decoded;
    } catch (_) {
      return;
    }
    for (final field in _configFields) {
      final value = stored[field];
      // 空字符串不覆盖服务端默认值，与 webapp 的 loadStoredConfig 行为一致。
      if (value is String && value.trim().isNotEmpty) {
        _setField(field, value);
      }
    }
  }

  void _persistConfig() {
    final prefs = _prefs;
    if (prefs == null) {
      return;
    }
    final payload = {
      for (final field in _configFields) field: _getField(field),
    };
    prefs.setString(_storageKey, jsonEncode(payload));
  }

  String _getField(String field) {
    switch (field) {
      case 'translation_target_language':
        return _settings.targetLanguage.text;
      case 'pages':
        return _settings.pages.text;
      case 'skip_pages':
        return _settings.skipPages.text;
      case 'table_recognition_base_url':
        return _settings.tableRecognitionBaseUrl.text;
      case 'table_recognition_flavor':
        return _settings.tableRecognitionFlavor;
      case 'extract_backend':
        return _settings.extractBackend;
      case 'formula_recognition_enabled':
        return '${_settings.formulaRecognitionEnabled}';
      case 'table_recognition_enabled':
        return '${_settings.tableRecognitionEnabled}';
      case 'ocr_enabled':
        return '${_settings.ocrEnabled}';
      default:
        return '';
    }
  }

  void _setField(String field, String value) {
    switch (field) {
      case 'translation_target_language':
        _settings.targetLanguage.text = value;
      case 'pages':
        _settings.pages.text = value;
      case 'skip_pages':
        _settings.skipPages.text = value;
      case 'table_recognition_base_url':
        _settings.tableRecognitionBaseUrl.text = value;
      case 'table_recognition_flavor':
        _settings.tableRecognitionFlavor = value;
      case 'extract_backend':
        _settings.extractBackend = value;
      case 'formula_recognition_enabled':
        _settings.formulaRecognitionEnabled = value == 'true';
      case 'table_recognition_enabled':
        _settings.tableRecognitionEnabled = value == 'true';
      case 'ocr_enabled':
        _settings.ocrEnabled = value == 'true';
    }
  }

  Future<void> _pickFile() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    final path = picked?.path;
    if (picked == null || path == null) {
      return;
    }
    final size = await picked.length();
    if (!mounted) {
      return;
    }
    setState(() {
      _filePath = path;
      _fileName = picked.name;
      _fileSize = size;
    });
  }

  /// 拖进来的可能是多个文件或非 PDF，只认第一个 .pdf，其余忽略并提示。
  Future<void> _acceptDroppedFiles(List<DropItem> items) async {
    final pdf = items.where((item) => item.path.toLowerCase().endsWith('.pdf'));
    if (pdf.isEmpty) {
      _setStatus('只支持拖入 PDF 文件。', isError: true);
      return;
    }
    final file = File(pdf.first.path);
    final size = await file.length();
    if (!mounted) {
      return;
    }
    setState(() {
      _filePath = file.path;
      _fileName = pdf.first.name;
      _fileSize = size;
      _status = '';
      _statusIsError = false;
    });
  }

  void _clearFile() {
    setState(() {
      _filePath = null;
      _fileName = null;
      _fileSize = null;
    });
  }

  Future<void> _submit() async {
    final appSettings = AppSettingsScope.of(context);
    final filePath = _filePath;
    if (filePath == null) {
      _setStatus('请先选择 PDF 文件。', isError: true);
      return;
    }
    final pagesError = _settings.validatePages();
    if (pagesError.isNotEmpty) {
      _setStatus(pagesError, isError: true);
      return;
    }

    setState(() => _submitting = true);
    _setStatus('正在创建任务...');
    try {
      // 文档相关的参数来自本表单，模型/MinerU 的接入信息来自设置页。
      final jobId = await widget.api.createJob(
        filePath: filePath,
        fields: {
          ..._settings.toMultipartFields(),
          ...appSettings.toMultipartFields(),
        },
      );
      if (!mounted) {
        return;
      }
      debugPrint('任务 $jobId 已创建，正在后台处理。');
       _setStatus('');
      _clearFile();
      await widget.onJobCreated();
    } catch (error) {
      if (mounted) {
        _setStatus(describeError(error), isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  void _setStatus(String message, {bool isError = false}) {
    setState(() {
      _status = message;
      _statusIsError = isError;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppPanel(
      title: '创建翻译任务',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _FileDropzone(
            fileName: _fileName,
            fileSize: _fileSize,
            onPick: _pickFile,
            onClear: _clearFile,
            onDropFiles: _acceptDroppedFiles,
          ),
          const SizedBox(height: 12),
          JobSettingsFields(
            settings: _settings,
            onChanged: () {
              setState(() {});
              _persistConfig();
            },
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: _submitting ? null : _submit,
            icon: const Icon(Icons.auto_awesome, size: 16),
            label: Text(_submitting ? '正在创建…' : '开始翻译'),
          ),
          if (_status.isNotEmpty) ...[
            const SizedBox(height: 8),
            StatusText(message: _status, isError: _statusIsError),
          ],
        ],
      ),
    );
  }
}

/// 对应 webapp 的 `.file-dropzone`：未选文件时是紧凑的点选/拖放区，
/// 选中后收成一行文件信息（此时仍可拖入新文件替换）。
class _FileDropzone extends StatefulWidget {
  const _FileDropzone({
    required this.fileName,
    required this.fileSize,
    required this.onPick,
    required this.onClear,
    required this.onDropFiles,
  });

  final String? fileName;
  final int? fileSize;
  final VoidCallback onPick;
  final VoidCallback onClear;
  final Future<void> Function(List<DropItem> items) onDropFiles;

  @override
  State<_FileDropzone> createState() => _FileDropzoneState();
}

class _FileDropzoneState extends State<_FileDropzone> {
  /// 文件悬在区域上方时高亮描边，给一个「可以松手了」的反馈。
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppColors.of(context);
    final selected = widget.fileName != null;
    final highlighted = selected || _dragging;

    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        widget.onDropFiles(details.files);
      },
      child: InkWell(
        onTap: selected ? null : widget.onPick,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: selected
              ? const EdgeInsets.symmetric(horizontal: 12, vertical: 10)
              : const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          decoration: BoxDecoration(
            color: highlighted ? app.accentSubtle : theme.colorScheme.surface,
            border: Border.all(
              color: highlighted ? app.accentBorder : theme.dividerColor,
              width: highlighted ? 1.2 : 1,
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: selected ? _selected(context) : _empty(context),
        ),
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: theme.colorScheme.secondary.withValues(alpha: 0.5),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(
            Icons.upload_file_outlined,
            size: 16,
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          _dragging ? '松手即可加入' : '点击或拖入 PDF 文件',
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            fontSize: 13,
            height: 1.2,
          ),
        ),
      ],
    );
  }

  Widget _selected(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
          ),
          alignment: Alignment.center,
          child: Icon(
            Icons.description_outlined,
            size: 18,
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                widget.fileName!,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  height: 1.2,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                formatFileSize(widget.fileSize ?? 0),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 11,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
        Semantics(
          label: '移除文件',
          button: true,
          child: IconButton(
            icon: const Icon(Icons.close, size: 16),
            tooltip: '移除文件',
            onPressed: widget.onClear,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ),
      ],
    );
  }
}

String formatFileSize(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

