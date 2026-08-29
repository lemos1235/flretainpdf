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
/// 设置页，由 `AppSettings` 自己存（v6 → v7 就是为此拆的）。字段名清单和
/// createJob / retryJob 用的是同一份（见 `jobSettingsFieldKeys`），不再重复写。
const _configFields = jobSettingsFieldKeys;

/// 三个识别开关按 'true'/'false' 存成字符串，和其它字段共用一套读写。
const _storageKey = 'retainpdf-rs.form-config.v7';

/// v6 里除了上面这些字段，还混着现在归设置页管的模型配置；这里只读自己那部分。
const _legacyStorageKey = 'retainpdf-rs.form-config.v6';

/// 文件选择器和拖放入口统一使用的本地 PDF 描述。
///
/// 桌面端上传依赖本地路径，因此路径也作为稳定去重键：同一个文件分批选择或
/// 重复拖入时只保留第一次加入的那一项。
@immutable
class SelectedPdf {
  const SelectedPdf({
    required this.path,
    required this.name,
    required this.size,
  });

  final String path;
  final String name;
  final int size;
}

/// 把新文件追加到已有列表，只保留 PDF，并按本地路径去重、保持首次加入顺序。
List<SelectedPdf> mergeSelectedPdfs(
  Iterable<SelectedPdf> current,
  Iterable<SelectedPdf> incoming,
) {
  final merged = <SelectedPdf>[];
  final knownPaths = <String>{};
  for (final file in [...current, ...incoming]) {
    // 只有 Windows 把两种斜杠视为路径分隔符且通常不区分大小写；POSIX
    // 允许文件名包含反斜杠，macOS 也可能挂载大小写敏感卷，不能按平台误合并。
    final dedupeKey = Platform.isWindows
        ? file.path.replaceAll('/', '\\').toLowerCase()
        : file.path;
    if (file.path.toLowerCase().endsWith('.pdf') && knownPaths.add(dedupeKey)) {
      merged.add(file);
    }
  }
  return merged;
}

class JobFormSection extends StatefulWidget {
  const JobFormSection({
    super.key,
    required this.api,
    required this.onJobCreated,
  });

  final ApiClient api;
  final Future<void> Function() onJobCreated;

  @override
  State<JobFormSection> createState() => JobFormSectionState();
}

class JobFormSectionState extends State<JobFormSection> {
  final _settings = JobSettingsController();
  SharedPreferences? _prefs;
  List<SelectedPdf> _files = const [];
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

  Future<void> _pickFiles() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    final files = await Future.wait(
      picked
          .where((file) => file.path != null)
          .map(
            (file) async => SelectedPdf(
              path: file.path!,
              name: file.name,
              size: await file.length(),
            ),
          ),
    );
    if (!mounted || files.isEmpty) {
      return;
    }
    addFiles(files);
  }

  /// 拖入的所有 PDF 都加入列表；非 PDF 会被忽略，整批都无效时才提示错误。
  Future<void> _acceptDroppedFiles(List<DropItem> items) async {
    final pdfItems = items.where(
      (item) => item.path.toLowerCase().endsWith('.pdf'),
    );
    if (pdfItems.isEmpty) {
      _setStatus('只支持拖入 PDF 文件。', isError: true);
      return;
    }
    final files = <SelectedPdf>[];
    for (final item in pdfItems) {
      try {
        final file = File(item.path);
        if (await file.exists() &&
            (await FileSystemEntity.type(item.path)) ==
                FileSystemEntityType.file) {
          files.add(
            SelectedPdf(
              path: file.path,
              name: item.name,
              size: await file.length(),
            ),
          );
        }
      } catch (_) {
        // 忽略无法访问或无法读取大小的文件
      }
    }
    if (!mounted) {
      return;
    }
    if (files.isEmpty) {
      _setStatus('未能读取所选 PDF 文件。', isError: true);
      return;
    }
    addFiles(files);
  }

  /// 公开给测试的统一追加入口；真实选择和拖放也都走这里，避免两套去重逻辑。
  @visibleForTesting
  void addFiles(Iterable<SelectedPdf> files) {
    if (_submitting) {
      return;
    }
    setState(() {
      _files = mergeSelectedPdfs(_files, files);
      _status = '';
      _statusIsError = false;
    });
  }

  @visibleForTesting
  List<SelectedPdf> get selectedFiles => List.unmodifiable(_files);

  void _removeFile(String path) {
    if (_submitting) {
      return;
    }
    setState(() => _files = _files.where((file) => file.path != path).toList());
  }

  void _clearFiles() {
    if (_submitting) {
      return;
    }
    setState(() => _files = const []);
  }

  Future<void> _submit() async {
    final appSettings = AppSettingsScope.of(context);
    final files = List<SelectedPdf>.of(_files);
    if (files.isEmpty) {
      _setStatus('请先选择 PDF 文件。', isError: true);
      return;
    }
    final pagesError = _settings.validatePages();
    if (pagesError.isNotEmpty) {
      _setStatus(pagesError, isError: true);
      return;
    }

    // 整批任务共用提交开始时的参数快照，避免上传到一半时界面字段变化造成
    // 同一批文件使用不同配置。
    final fields = {
      ..._settings.toMultipartFields(),
      ...appSettings.toMultipartFields(),
    };
    final createdPaths = <String>{};
    final failures = <String>[];
    setState(() {
      _submitting = true;
      _status = '';
      _statusIsError = false;
    });

    try {
      // 后端一次只接收一个文件，所以按选择顺序逐个创建；单个失败不阻断后续。
      for (var index = 0; index < files.length; index++) {
        final file = files[index];
        if (!mounted) {
          return;
        }
        _setStatus('正在创建任务 ${index + 1}/${files.length}：${file.name}…');
        try {
          final jobId = await widget.api.createJob(
            filePath: file.path,
            fields: fields,
          );
          createdPaths.add(file.path);
          debugPrint('任务 $jobId 已创建，正在后台处理。');
        } catch (error) {
          failures.add('${file.name}：${describeError(error)}');
        }
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _files = _files
            .where((file) => !createdPaths.contains(file.path))
            .toList();
        if (failures.isEmpty) {
          _status = '已创建 ${createdPaths.length} 个任务，正在后台处理。';
          _statusIsError = false;
        } else {
          _status =
              '成功创建 ${createdPaths.length} 个任务，'
              '${failures.length} 个失败：${failures.join('；')}';
          _statusIsError = true;
        }
      });
      await widget.onJobCreated();
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  /// 供失败任务卡片的「重试」按钮读取：当前表单里的最新参数（文档相关 +
  /// 模型/MinerU 接入信息），和点一次「开始翻译」会发送的完全一样，
  /// 包括页码格式校验 —— 和 [_submit] 一样，非法页码不会被发给后端。
  /// 重试请求发到原任务的 `/retry`，服务端会拿源文件的服务端副本重新跑一遍，
  /// 不需要、也不会用到本地文件路径。
  Map<String, dynamic> buildRetryFields() {
    final pagesError = _settings.validatePages();
    if (pagesError.isNotEmpty) {
      throw Exception(pagesError);
    }
    final appSettings = AppSettingsScope.of(context);
    return {..._settings.toRetryFields(), ...appSettings.toRetryFields()};
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
            files: _files,
            disabled: _submitting,
            onPick: _pickFiles,
            onRemove: _removeFile,
            onClear: _clearFiles,
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

/// 对应 webapp 的 `.file-dropzone`：空状态整块可点；已有文件后展示汇总、
/// 可滚动列表和明确的“继续添加”入口，避免点列表时误弹文件选择器。
class _FileDropzone extends StatefulWidget {
  const _FileDropzone({
    required this.files,
    required this.disabled,
    required this.onPick,
    required this.onRemove,
    required this.onClear,
    required this.onDropFiles,
  });

  final List<SelectedPdf> files;
  final bool disabled;
  final VoidCallback onPick;
  final ValueChanged<String> onRemove;
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
    final selected = widget.files.isNotEmpty;

    return DropTarget(
      onDragEntered: (_) {
        if (!widget.disabled) {
          setState(() => _dragging = true);
        }
      },
      onDragExited: (_) {
        if (_dragging) {
          setState(() => _dragging = false);
        }
      },
      onDragDone: (details) {
        if (_dragging) {
          setState(() => _dragging = false);
        }
        if (!widget.disabled) {
          widget.onDropFiles(details.files);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: _dragging ? app.accentSubtle : theme.colorScheme.surface,
          border: Border.all(
            color: _dragging ? app.accentBorder : theme.dividerColor,
            width: _dragging ? 1.2 : 1,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: selected ? _selected(context) : _empty(context),
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: widget.disabled ? null : widget.onPick,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: Row(
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
            Flexible(
              child: Text(
                _dragging ? '松手即可加入' : '点击或拖入多个 PDF 文件',
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  height: 1.2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _selected(BuildContext context) {
    final theme = Theme.of(context);
    final totalSize = widget.files.fold<int>(
      0,
      (total, file) => total + file.size,
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
            color: theme.colorScheme.surfaceContainer,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '已选择 ${widget.files.length} 个文件 · '
                    '共 ${formatFileSize(totalSize)}',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      fontSize: 11,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: widget.disabled ? null : widget.onClear,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 28),
                  ),
                  child: const Text('清空'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: ListView.separated(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              itemCount: widget.files.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) =>
                  _fileRow(context, widget.files[index]),
            ),
          ),
          const Divider(height: 1),
          TextButton.icon(
            onPressed: widget.disabled ? null : widget.onPick,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              minimumSize: const Size.fromHeight(34),
              shape: const RoundedRectangleBorder(),
            ),
            icon: const Icon(Icons.add, size: 15),
            label: const Text('继续添加文件'),
          ),
        ],
      ),
    );
  }

  Widget _fileRow(BuildContext context, SelectedPdf file) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 7, 4, 7),
      child: Row(
        children: [
          Icon(
            Icons.description_outlined,
            size: 17,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              file.name,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            formatFileSize(file.size),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 10,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 15),
            tooltip: '移除 ${file.name}',
            onPressed: widget.disabled
                ? null
                : () => widget.onRemove(file.path),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ],
      ),
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
