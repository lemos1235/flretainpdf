import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../api/api_client.dart';
import '../theme/app_theme.dart';
import '../widgets/app_panel.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/status_text.dart';
import 'batch_download.dart';
import 'job_status.dart';

class JobListSection extends StatefulWidget {
  const JobListSection({
    super.key,
    required this.api,
    required this.jobs,
    required this.onRefresh,
    required this.onRetry,
  });

  final ApiClient api;
  final List<JobSummary> jobs;
  final Future<void> Function() onRefresh;

  /// 在原任务上重新执行一次，参数取当前表单最新值；源文件用服务端保存的
  /// 那份，与本地是否还留着原文件无关。
  final Future<void> Function(JobSummary job) onRetry;

  @override
  State<JobListSection> createState() => _JobListSectionState();
}

class _JobListSectionState extends State<JobListSection> {
  bool _clearing = false;
  String? _clearError;

  // 多选与批量操作状态
  bool _selectionMode = false;
  final Set<String> _selectedJobIds = <String>{};
  bool _batchDownloading = false;

  List<JobSummary> get _downloadableJobs => widget.jobs
      .where((job) => job.status == 'completed' && job.translatedPdfUrl.isNotEmpty)
      .toList();

  void _toggleSelectionMode() {
    setState(() {
      _selectionMode = !_selectionMode;
      if (!_selectionMode) {
        _selectedJobIds.clear();
      } else {
        // 开启多选模式时，默认选中所有可下载的任务
        _selectedJobIds.addAll(_downloadableJobs.map((j) => j.jobId));
      }
    });
  }

  void _toggleJobSelection(String jobId) {
    setState(() {
      if (_selectedJobIds.contains(jobId)) {
        _selectedJobIds.remove(jobId);
      } else {
        _selectedJobIds.add(jobId);
      }
    });
  }

  void _selectAllDownloadable() {
    setState(() {
      _selectedJobIds.addAll(_downloadableJobs.map((j) => j.jobId));
    });
  }

  void _unselectAll() {
    setState(() {
      _selectedJobIds.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppColors.of(context);
    final jobs = widget.jobs;
    final waiting = jobs.where(isWaitingForSlot).length;
    final finishedCount = jobs.where(_isFinishedJob).length;
    final downloadableJobs = _downloadableJobs;
    final downloadableCount = downloadableJobs.length;
    final validSelectedCount = downloadableJobs
        .where((j) => _selectedJobIds.contains(j.jobId))
        .length;
    final canClear = finishedCount > 0;
    final canBatchDownload = downloadableCount > 0;

    return AppPanel(
      title: '任务列表',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 有任务在等槽位时单独标出来，免得用户以为卡住了。
          if (waiting > 0) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
              decoration: BoxDecoration(
                color: app.accentSubtle,
                border: Border.all(color: app.accentBorder),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$waiting 个排队中',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: app.accentText,
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          // 已完成任务数徽标
          if (downloadableCount > 0) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
              decoration: BoxDecoration(
                color: app.successSubtle,
                border: Border.all(color: app.success.withValues(alpha: 0.25)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.check, size: 11, color: app.success),
                  const SizedBox(width: 3),
                  Text(
                    '$downloadableCount 个已完成',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: app.success,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
          ],
          if (jobs.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondary,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${jobs.length}',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSecondary,
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          // 批量下载按钮 / 批量选择入口
          if (canBatchDownload) ...[
            Semantics(
              label: '批量下载',
              button: true,
              child: IconButton(
                icon: const Icon(LucideIcons.download, size: 16),
                tooltip: '批量下载已完成任务',
                onPressed: _batchDownloading ? null : _triggerBatchDownloadDirectly,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
            ),
            Semantics(
              label: _selectionMode ? '退出批量选择' : '批量选择',
              button: true,
              child: IconButton(
                icon: Icon(
                  _selectionMode ? LucideIcons.checkSquare : LucideIcons.listChecks,
                  size: 16,
                  color: _selectionMode ? theme.colorScheme.primary : null,
                ),
                tooltip: _selectionMode ? '退出批量选择' : '批量选择',
                onPressed: _toggleSelectionMode,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
            ),
            const SizedBox(width: 2),
          ],
          Semantics(
            label: '清空任务列表',
            button: true,
            child: IconButton(
              icon: _clearing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.delete_sweep_outlined, size: 16),
              tooltip: canClear ? '清空任务列表' : '没有可清理的已结束任务',
              onPressed: canClear && !_clearing ? _clearJobs : null,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            ),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_clearError case final error?) ...[
            StatusText(message: error, isError: true),
            const SizedBox(height: 10),
          ],

          // 多选模式操作栏
          if (_selectionMode && downloadableJobs.isNotEmpty) ...[
            _BatchActionBar(
              totalDownloadable: downloadableCount,
              selectedCount: validSelectedCount,
              onSelectAll: _selectAllDownloadable,
              onUnselectAll: _unselectAll,
              onDownloadSelected: _downloadSelectedJobs,
              onCancel: _toggleSelectionMode,
              isDownloading: _batchDownloading,
            ),
            const SizedBox(height: 12),
          ],

          if (jobs.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 16),
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondary.withValues(alpha: 0.5),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      LucideIcons.inbox,
                      size: 24,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '还没有任务，上传一个 PDF 开始吧。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            )
          else
            for (var i = 0; i < jobs.length; i++)
              Padding(
                padding: EdgeInsets.only(bottom: i < jobs.length - 1 ? 12 : 0),
                child: _JobCard(
                  key: ValueKey(jobs[i].jobId),
                  api: widget.api,
                  job: jobs[i],
                  selectionMode: _selectionMode,
                  isSelected: _selectedJobIds.contains(jobs[i].jobId),
                  onSelectionChanged: (selected) => _toggleJobSelection(jobs[i].jobId),
                  onRefresh: widget.onRefresh,
                  onRetry: widget.onRetry,
                ),
              ),
        ],
      ),
    );
  }

  /// 直接批量下载所有已完成任务
  Future<void> _triggerBatchDownloadDirectly() async {
    final jobsToDownload = _downloadableJobs;
    if (jobsToDownload.isEmpty) {
      return;
    }
    await _executeBatchDownload(jobsToDownload);
  }

  /// 批量下载勾选的任务
  Future<void> _downloadSelectedJobs() async {
    final jobsToDownload = widget.jobs
        .where((j) => _selectedJobIds.contains(j.jobId) && j.status == 'completed' && j.translatedPdfUrl.isNotEmpty)
        .toList();

    if (jobsToDownload.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先选择已完成的任务'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    await _executeBatchDownload(jobsToDownload);
  }

  /// 执行批量下载主流程：选择目录 -> 展示下载弹窗 -> 下载文件 -> 报告结果
  Future<void> _executeBatchDownload(List<JobSummary> jobsToDownload) async {
    final outputDirectory = await FilePicker.getDirectoryPath(
      dialogTitle: '选择译文 PDF 保存文件夹',
    );

    if (outputDirectory == null || !mounted) {
      return;
    }

    setState(() => _batchDownloading = true);

    try {
      final result = await showDialog<BatchDownloadResult>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => _BatchDownloadDialog(
          api: widget.api,
          jobs: jobsToDownload,
          targetDirectory: outputDirectory,
        ),
      );

      if (result != null && mounted && result.succeeded > 0) {
        // 下载完成后若还在多选模式，退出多选模式
        if (_selectionMode) {
          setState(() {
            _selectionMode = false;
            _selectedJobIds.clear();
          });
        }
      }
    } finally {
      if (mounted) {
        setState(() => _batchDownloading = false);
      }
    }
  }

  Future<void> _clearJobs() async {
    final finishedCount = widget.jobs.where(_isFinishedJob).length;
    final confirmed = await showAppConfirmDialog(
      context,
      title: '清空任务列表',
      message: '将清理所有已结束任务，并删除相应的源文件与译文产物。排队中和正在处理的任务会保留，该操作不可撤销。',
      detail: '当前共 $finishedCount 个已结束任务',
      icon: Icons.delete_sweep_outlined,
      confirmLabel: '清空',
      destructive: true,
    );
    if (!confirmed || !mounted) {
      return;
    }

    setState(() {
      _clearing = true;
      _clearError = null;
    });
    try {
      await widget.api.clearJobs();
    } catch (error) {
      if (mounted) {
        setState(() => _clearError = describeError(error));
      }
    } finally {
      await widget.onRefresh().catchError((_) {});
      if (mounted) {
        setState(() => _clearing = false);
      }
    }
  }
}

bool _isFinishedJob(JobSummary job) =>
    job.status == 'completed' || job.status == 'failed';

bool _isClearableJob(JobSummary job) =>
    _isFinishedJob(job) || isPendingJob(job);

/// 多选模式下的顶部操作工具条
class _BatchActionBar extends StatelessWidget {
  const _BatchActionBar({
    required this.totalDownloadable,
    required this.selectedCount,
    required this.onSelectAll,
    required this.onUnselectAll,
    required this.onDownloadSelected,
    required this.onCancel,
    required this.isDownloading,
  });

  final int totalDownloadable;
  final int selectedCount;
  final VoidCallback onSelectAll;
  final VoidCallback onUnselectAll;
  final VoidCallback onDownloadSelected;
  final VoidCallback onCancel;
  final bool isDownloading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppColors.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: app.accentSubtle,
        border: Border.all(color: app.accentBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.listChecks, size: 16, color: app.accentText),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '已选中 $selectedCount / $totalDownloadable 项',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: app.accentText,
                fontSize: 12,
              ),
            ),
          ),
          TextButton(
            onPressed: selectedCount < totalDownloadable ? onSelectAll : onUnselectAll,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            child: Text(selectedCount < totalDownloadable ? '全选' : '取消全选'),
          ),
          const SizedBox(width: 4),
          FilledButton.icon(
            onPressed: selectedCount > 0 && !isDownloading ? onDownloadSelected : null,
            icon: isDownloading
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(LucideIcons.download, size: 13),
            label: Text(
              selectedCount > 0 ? '下载选中 ($selectedCount)' : '下载选中',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(LucideIcons.x, size: 16),
            tooltip: '退出多选',
            onPressed: onCancel,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ],
      ),
    );
  }
}

/// 批量下载进度及结果弹窗
class _BatchDownloadDialog extends StatefulWidget {
  const _BatchDownloadDialog({
    required this.api,
    required this.jobs,
    required this.targetDirectory,
  });

  final ApiClient api;
  final List<JobSummary> jobs;
  final String targetDirectory;

  @override
  State<_BatchDownloadDialog> createState() => _BatchDownloadDialogState();
}

class _BatchDownloadDialogState extends State<_BatchDownloadDialog> {
  int _current = 0;
  int _total = 0;
  String _currentFilename = '';
  BatchDownloadResult? _result;
  bool _downloading = true;

  @override
  void initState() {
    super.initState();
    _startDownload();
  }

  Future<void> _startDownload() async {
    _total = widget.jobs.length;
    try {
      final result = await runBatchDownload(
        api: widget.api,
        jobs: widget.jobs,
        targetDirectory: widget.targetDirectory,
        onProgress: (current, total, filename) {
          if (mounted) {
            setState(() {
              _current = current;
              _total = total;
              _currentFilename = filename;
            });
          }
        },
      );

      if (mounted) {
        setState(() {
          _result = result;
          _downloading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _result = BatchDownloadResult(
            total: _total,
            succeeded: 0,
            failed: _total,
            errors: [describeError(e)],
            targetDirectory: widget.targetDirectory,
          );
          _downloading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppColors.of(context);
    final result = _result;

    return PopScope(
      canPop: !_downloading,
      child: AlertDialog(
        title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _downloading
                  ? app.accentSubtle
                  : (result?.isAllSuccess == true ? app.successSubtle : app.dangerSubtle),
              shape: BoxShape.circle,
            ),
            child: Icon(
              _downloading
                  ? LucideIcons.download
                  : (result?.isAllSuccess == true ? LucideIcons.checkCheck : LucideIcons.circleAlert),
              size: 20,
              color: _downloading
                  ? app.accentText
                  : (result?.isAllSuccess == true ? app.success : theme.colorScheme.error),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            _downloading ? '正在批量下载' : '批量下载完成',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ],
      ),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_downloading) ...[
              Text(
                '进度: $_current / $_total',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _currentFilename.isEmpty ? '准备下载中...' : '正在下载: $_currentFilename',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _total > 0 ? _current / _total : null,
                  minHeight: 8,
                ),
              ),
            ] else if (result != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: result.isAllSuccess ? app.successSubtle : app.accentSubtle,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: result.isAllSuccess
                        ? app.success.withValues(alpha: 0.3)
                        : app.accentBorder,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '已成功保存 ${result.succeeded} 个文件至：',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: result.isAllSuccess ? app.success : app.accentText,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      result.targetDirectory,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontFamily: 'monospace',
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (result.errors.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  '部分文件下载失败 (${result.failed} 个)：',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  constraints: const BoxConstraints(maxHeight: 120),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: theme.dividerColor),
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: result.errors.length,
                    itemBuilder: (ctx, idx) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        result.errors[idx],
                        style: TextStyle(
                          color: theme.colorScheme.error,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
      actions: [
        if (!_downloading && result != null) ...[
          OutlinedButton.icon(
            onPressed: () => openDirectoryInSystemExplorer(result.targetDirectory),
            icon: const Icon(LucideIcons.folderOpen, size: 14),
            label: const Text('打开所在文件夹'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(result),
            child: const Text('完成'),
          ),
        ],
      ],
    ),
    );
  }
}

/// 单个任务卡片
class _JobCard extends StatefulWidget {
  const _JobCard({
    super.key,
    required this.api,
    required this.job,
    required this.onRefresh,
    required this.onRetry,
    this.selectionMode = false,
    this.isSelected = false,
    this.onSelectionChanged,
  });

  final ApiClient api;
  final JobSummary job;
  final Future<void> Function() onRefresh;
  final Future<void> Function(JobSummary job) onRetry;
  final bool selectionMode;
  final bool isSelected;
  final ValueChanged<bool>? onSelectionChanged;

  @override
  State<_JobCard> createState() => _JobCardState();
}

class _JobCardState extends State<_JobCard> {
  bool _stepsExpanded = false;
  bool _viewing = false;
  bool _deleting = false;
  bool _retrying = false;
  String? _retryError;
  bool _isHovered = false;

  bool get _isDownloadable =>
      widget.job.status == 'completed' && widget.job.translatedPdfUrl.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppColors.of(context);
    final job = widget.job;
    final progress = summarizeJobProgress(job);
    final activeStepIndex = jobSteps.indexWhere(
      (step) => step.id == resolveActiveStepId(job),
    );

    final status = job.status;
    final isCompleted = status == 'completed';
    final isFailed = status == 'failed';

    // 预先将半透明强调色与卡片底色混合为完全不透明纯色，
    // 避免 AnimatedContainer 在不透明色与半透明色之间做 Color.lerp 时
    // 因 Alpha 与 RGB 线性插值产生中间帧过冲变深（先变暗再变浅）的问题。
    final cardBgColor = widget.isSelected
        ? Color.alphaBlend(app.accentSubtle, theme.colorScheme.surface)
        : theme.colorScheme.surface;

    // 卡片边框颜色
    Color borderColor = theme.dividerColor;
    if (widget.isSelected) {
      borderColor = theme.colorScheme.primary;
    } else if (isFailed) {
      borderColor = theme.colorScheme.error.withValues(alpha: 0.35);
    } else if (_isHovered) {
      borderColor = theme.colorScheme.outline;
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cardBgColor,
          border: Border.all(color: borderColor, width: widget.isSelected ? 1.5 : 1),
          borderRadius: BorderRadius.circular(12),
          boxShadow: _isHovered
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.03),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : const [],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 头部：多选框 + 状态图标 + 文件名/元数据 + 状态 Badge
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // 多选模式下的 Checkbox
                if (widget.selectionMode) ...[
                  Checkbox(
                    value: widget.isSelected,
                    onChanged: _isDownloadable
                        ? (v) => widget.onSelectionChanged?.call(v ?? false)
                        : null,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  const SizedBox(width: 8),
                ],

                // 状态/文件类型小图标
                _StatusAvatar(status: status),
                const SizedBox(width: 10),

                // 文件名与元数据
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Tooltip(
                        message: job.filename,
                        waitDuration: const Duration(milliseconds: 600),
                        child: Text(
                          job.filename,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            fontSize: 13.5,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                      const SizedBox(height: 3),
                      _buildMetaTags(context, job),
                    ],
                  ),
                ),
                const SizedBox(width: 8),

                // 状态 Badge
                _StatusBadge(status: status),
              ],
            ),

            // 进行中 / 排队中 / 失败状态的进度展示
            if (!isCompleted) ...[
              const SizedBox(height: 12),
              _Progress(job: job, progress: progress),
              const SizedBox(height: 8),

              // 步骤消息（紧凑单行 + 点击展开）
              InkWell(
                onTap: () => setState(() => _stepsExpanded = !_stepsExpanded),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(
                        _stepsExpanded
                            ? LucideIcons.chevronDown
                            : LucideIcons.chevronRight,
                        size: 15,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          formatJobMessage(job),
                          maxLines: _stepsExpanded ? 5 : 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: isFailed
                                ? theme.colorScheme.error
                                : theme.colorScheme.onSurfaceVariant,
                            fontSize: 12,
                            fontWeight: isFailed ? FontWeight.w500 : FontWeight.normal,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // 展开的步骤流水线
              if (_stepsExpanded) ...[
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.dividerColor),
                  ),
                  child: Column(
                    children: [
                      for (var index = 0; index < jobSteps.length; index++)
                        _Step(
                          step: jobSteps[index],
                          state: resolveStepState(job, index, activeStepIndex),
                        ),
                    ],
                  ),
                ),
              ],
            ],

            // 失败时的错误信息提示气泡
            if (isFailed && job.message.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: app.dangerSubtle,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.colorScheme.error.withValues(alpha: 0.2)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      LucideIcons.circleAlert,
                      size: 14,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        job.message,
                        style: TextStyle(
                          color: theme.colorScheme.error,
                          fontSize: 11.5,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // 底部操作按钮区域
            if (job.translatedPdfUrl.isNotEmpty || _retryable || _deletable) ...[
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // 重试按钮（失败任务）
                  if (_retryable) ...[
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        backgroundColor: app.accentSubtle,
                        foregroundColor: app.accentText,
                        side: BorderSide(color: app.accentBorder),
                        shape: const StadiumBorder(),
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        textStyle: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      icon: _retrying
                          ? const SizedBox(
                              width: 13,
                              height: 13,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(LucideIcons.rotateCw, size: 13),
                      onPressed: _retrying ? null : _retry,
                      label: Text(_retrying ? '正在重试…' : '重试'),
                    ),
                    const SizedBox(width: 8),
                  ],

                  // 查看 PDF 按钮（已完成任务）
                  if (job.translatedPdfUrl.isNotEmpty) ...[
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        shape: const StadiumBorder(),
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        textStyle: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      icon: _viewing
                          ? const SizedBox(
                              width: 13,
                              height: 13,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(LucideIcons.eye, size: 13),
                      onPressed: _viewing ? null : _viewPdf,
                      label: Text(_viewing ? '正在打开…' : '查看 PDF'),
                    ),
                    const SizedBox(width: 8),
                  ],

                  // 删除 / 取消按钮
                  if (_deletable) ...[
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        backgroundColor: theme.colorScheme.surface,
                        foregroundColor: theme.colorScheme.onSurfaceVariant,
                        side: BorderSide(color: theme.dividerColor),
                        shape: const StadiumBorder(),
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        textStyle: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      icon: _deleting
                          ? const SizedBox(
                              width: 13,
                              height: 13,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              _cancelable ? LucideIcons.x : LucideIcons.trash2,
                              size: 13,
                            ),
                      onPressed: _deleting ? null : _delete,
                      label: Text(
                        _deleting
                            ? (_cancelable ? '正在取消…' : '正在删除…')
                            : (_cancelable ? '取消任务' : '删除任务'),
                      ),
                    ),
                  ],
                ],
              ),
              if (_retryError case final error?) ...[
                const SizedBox(height: 6),
                StatusText(message: error, isError: true),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMetaTags(BuildContext context, JobSummary job) {
    final theme = Theme.of(context);
    final items = <Widget>[];

    void addTag(String text, {IconData? icon}) {
      items.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
          decoration: BoxDecoration(
            color: theme.colorScheme.secondary.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 10, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 3),
              ],
              Text(
                text,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 目标语言
    if (job.targetLanguage.isNotEmpty) {
      addTag('目标: ${job.targetLanguage}', icon: LucideIcons.languages);
    }

    // 页码
    if (job.pages.isNotEmpty) {
      addTag('页码: ${job.pages}');
    }

    // 跳过
    if (job.skipPages.isNotEmpty) {
      addTag('跳过: ${job.skipPages}');
    }

    // 总页数
    if (job.pageCount != null && job.pageCount != 0) {
      addTag('共 ${job.pageCount} 页', icon: LucideIcons.files);
    }

    // 任务 ID
    addTag('#${job.jobId}');

    return Wrap(
      spacing: 5,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: items,
    );
  }

  /// 跑完（成功或失败）或还没开跑的任务能删，与 webapp 的按钮显示条件一致。
  bool get _deletable => _isClearableJob(widget.job);

  /// 还没开跑的任务删掉就是「取消」，按钮和提示都换个说法。文案说「取消任务」
  /// 而不是「取消排队」：`preparing` 的任务并没有在排队，只是还没轮到它开始。
  bool get _cancelable => isPendingJob(widget.job);

  /// 失败的任务都能重试：源文件与原始参数都由服务端保存着。
  bool get _retryable => widget.job.status == 'failed';

  /// 重试即在原任务上重新执行，源文件用服务端保存的那份，参数用当前表单
  /// 的最新值 —— job_id 不变，不会多出一个新任务。
  Future<void> _retry() async {
    setState(() {
      _retrying = true;
      _retryError = null;
    });
    try {
      await widget.onRetry(widget.job);
      await widget.onRefresh();
    } catch (error) {
      if (mounted) {
        setState(() => _retryError = describeError(error));
      }
    } finally {
      if (mounted) {
        setState(() => _retrying = false);
      }
    }
  }

  /// 删除会连带清掉服务端的源文件与产物，先让用户确认一次。
  Future<void> _delete() async {
    final cancelable = _cancelable;
    final confirmed = await showAppConfirmDialog(
      context,
      title: cancelable ? '取消任务' : '删除任务',
      message: cancelable
          ? '将取消尚未开始的任务并删除已上传的源文件，该操作不可撤销。'
          : '将同时删除源文件与全部译文产物，该操作不可撤销。',
      detail: widget.job.filename,
      icon: cancelable ? Icons.close : Icons.delete_outline,
      confirmLabel: cancelable ? '取消任务' : '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) {
      return;
    }

    setState(() => _deleting = true);
    try {
      await widget.api.deleteJob(widget.job.jobId);
      await widget.onRefresh();
    } catch (_) {
      if (cancelable) {
        unawaited(widget.onRefresh().catchError((_) {}));
      }
    } finally {
      if (mounted) {
        setState(() => _deleting = false);
      }
    }
  }

  /// 将译文 PDF 下载至临时目录并使用系统默认 PDF 阅读器打开查看
  Future<void> _viewPdf() async {
    setState(() {
      _viewing = true;
      _retryError = null;
    });
    try {
      await viewPdfArtifact(api: widget.api, job: widget.job);
    } catch (error) {
      if (mounted) {
        setState(() => _retryError = describeError(error));
      }
    } finally {
      if (mounted) {
        setState(() => _viewing = false);
      }
    }
  }
}

/// 状态徽章 Badge
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppColors.of(context);

    final (bgColor, borderColor, textColor, icon) = switch (status) {
      'completed' => (
        app.successSubtle,
        app.success.withValues(alpha: 0.3),
        app.success,
        LucideIcons.check,
      ),
      'failed' => (
        app.dangerSubtle,
        theme.colorScheme.error.withValues(alpha: 0.3),
        theme.colorScheme.error,
        LucideIcons.circleAlert,
      ),
      'queued' => (
        theme.colorScheme.secondary,
        theme.dividerColor,
        theme.colorScheme.onSurfaceVariant,
        LucideIcons.clock,
      ),
      'preparing' => (
        theme.colorScheme.secondary,
        theme.dividerColor,
        theme.colorScheme.onSurfaceVariant,
        LucideIcons.clock,
      ),
      _ => (
        app.accentSubtle,
        app.accentBorder,
        app.accentText,
        LucideIcons.refreshCw,
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: textColor),
          const SizedBox(width: 4),
          Text(
            formatStatus(status),
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }
}

/// 状态图标容器
class _StatusAvatar extends StatelessWidget {
  const _StatusAvatar({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppColors.of(context);

    final (bgColor, iconColor, icon) = switch (status) {
      'completed' => (
        app.successSubtle,
        app.success,
        LucideIcons.fileCheck,
      ),
      'failed' => (
        app.dangerSubtle,
        theme.colorScheme.error,
        LucideIcons.fileX,
      ),
      'queued' || 'preparing' => (
        theme.colorScheme.secondary,
        theme.colorScheme.onSurfaceVariant,
        LucideIcons.fileClock,
      ),
      _ => (
        app.accentSubtle,
        app.accentText,
        LucideIcons.fileCog,
      ),
    };

    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 18, color: iconColor),
    );
  }
}

/// 对应 `.job-progress`：当前阶段 + 进度值 + 进度条，完成/失败时换色。
class _Progress extends StatelessWidget {
  const _Progress({required this.job, required this.progress});

  final JobSummary job;
  final JobProgress progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppColors.of(context);
    final accent = switch (job.status) {
      'completed' => app.success,
      'failed' => theme.colorScheme.error,
      _ => theme.colorScheme.primary,
    };

    final accentTextColor = switch (job.status) {
      'completed' => app.success,
      'failed' => theme.colorScheme.error,
      _ => app.accentText,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  progress.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                    height: 1.2,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                progress.value,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: accentTextColor,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  height: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: progress.percent / 100,
              valueColor: AlwaysStoppedAnimation<Color>(accent),
              backgroundColor: theme.colorScheme.secondary,
              minHeight: 6,
            ),
          ),
        ],
      ),
    );
  }
}

class _Step extends StatefulWidget {
  const _Step({required this.step, required this.state});

  final JobStep step;
  final JobStepState state;

  @override
  State<_Step> createState() => _StepState();
}

class _StepState extends State<_Step> with SingleTickerProviderStateMixin {
  late final _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    _syncSpin();
  }

  @override
  void didUpdateWidget(_Step oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncSpin();
  }

  void _syncSpin() {
    if (widget.state == JobStepState.active) {
      if (!_spin.isAnimating) {
        _spin.repeat();
      }
    } else {
      if (_spin.isAnimating) {
        _spin.stop();
      }
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppColors.of(context);
    final state = widget.state;
    final step = widget.step;

    final (icon, color) = switch (state) {
      JobStepState.done => (LucideIcons.checkCircle2, app.success),
      JobStepState.active => (LucideIcons.refreshCw, app.accentText),
      JobStepState.error => (LucideIcons.xCircle, theme.colorScheme.error),
      JobStepState.pending => (
        LucideIcons.circle,
        theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
      ),
    };
    final dimmed = state == JobStepState.pending;
    final iconWidget = Icon(icon, size: 14, color: color);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          state == JobStepState.active
              ? RotationTransition(turns: _spin, child: iconWidget)
              : iconWidget,
          const SizedBox(width: 8),
          Text(
            step.label,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: dimmed ? FontWeight.w400 : FontWeight.w600,
              color: dimmed ? theme.colorScheme.onSurfaceVariant : null,
              fontSize: 12,
              height: 1.2,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              step.detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
