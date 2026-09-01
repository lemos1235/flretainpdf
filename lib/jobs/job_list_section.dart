import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  bool _batchDeleting = false;

  List<JobSummary> get _selectableJobs =>
      widget.jobs.where(_isClearableJob).toList();

  List<JobSummary> get _downloadableJobs => widget.jobs
      .where(
        (job) => job.status == 'completed' && job.translatedPdfUrl.isNotEmpty,
      )
      .toList();

  void _toggleSelectionMode() {
    setState(() {
      _selectionMode = !_selectionMode;
      if (!_selectionMode) {
        _selectedJobIds.clear();
      } else {
        // 开启多选模式时，默认全选可操作的任务
        _selectedJobIds.addAll(_selectableJobs.map((j) => j.jobId));
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

  void _selectAll() {
    setState(() {
      _selectedJobIds.addAll(_selectableJobs.map((j) => j.jobId));
    });
  }

  void _unselectAll() {
    setState(() {
      _selectedJobIds.clear();
    });
  }

  @override
  void didUpdateWidget(covariant JobListSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    final selectableIds = _selectableJobs.map((job) => job.jobId).toSet();
    _selectedJobIds.retainAll(selectableIds);
    if (_selectionMode && selectableIds.isEmpty) {
      _selectionMode = false;
    }
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
    final selectableJobs = _selectableJobs;
    final selectableCount = selectableJobs.length;
    final validSelectedCount = selectableJobs
        .where((j) => _selectedJobIds.contains(j.jobId))
        .length;
    final selectedDownloadableCount = downloadableJobs
        .where((j) => _selectedJobIds.contains(j.jobId))
        .length;
    final canClear = finishedCount > 0;
    final canBatchOperate = selectableCount > 0;

    return AppPanel(
      title: '任务列表',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 排队中任务指示徽标
          if (waiting > 0) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
              decoration: BoxDecoration(
                color: app.accentSubtle,
                border: Border.all(color: app.accentBorder),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.clock, size: 11, color: app.accentText),
                  const SizedBox(width: 3.5),
                  Text(
                    '$waiting 个排队中',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: app.accentText,
                    ),
                  ),
                ],
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
                  const SizedBox(width: 3.5),
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
          // 总任务数
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
          // 批量选择入口
          if (canBatchOperate || _selectionMode) ...[
            Semantics(
              label: _selectionMode ? '退出批量选择' : '批量选择',
              button: true,
              child: IconButton(
                icon: Icon(
                  _selectionMode
                      ? LucideIcons.checkSquare
                      : LucideIcons.listChecks,
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
          // 清空列表
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
          if (_selectionMode && selectableJobs.isNotEmpty) ...[
            _BatchActionBar(
              totalSelectable: selectableCount,
              selectedCount: validSelectedCount,
              selectedDownloadableCount: selectedDownloadableCount,
              onSelectAll: _selectAll,
              onUnselectAll: _unselectAll,
              onDownloadSelected: _downloadSelectedJobs,
              onDeleteSelected: _deleteSelectedJobs,
              onCancel: _toggleSelectionMode,
              isDownloading: _batchDownloading,
              isDeleting: _batchDeleting,
            ),
            const SizedBox(height: 12),
          ],

          if (jobs.isEmpty)
            const _EmptyJobsView()
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
                  onSelectionChanged: (selected) =>
                      _toggleJobSelection(jobs[i].jobId),
                  onRefresh: widget.onRefresh,
                  onRetry: widget.onRetry,
                ),
              ),
        ],
      ),
    );
  }

  /// 批量下载勾选的任务
  Future<void> _downloadSelectedJobs() async {
    final jobsToDownload = widget.jobs
        .where(
          (j) =>
              _selectedJobIds.contains(j.jobId) &&
              j.status == 'completed' &&
              j.translatedPdfUrl.isNotEmpty,
        )
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

  /// 批量删除勾选的任务
  Future<void> _deleteSelectedJobs() async {
    final jobsToDelete = widget.jobs
        .where((j) => _selectedJobIds.contains(j.jobId) && _isClearableJob(j))
        .toList();

    if (jobsToDelete.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先选择要删除的任务'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    final count = jobsToDelete.length;
    final confirmed = await showAppConfirmDialog(
      context,
      title: '批量删除任务',
      message: '将删除选中的 $count 个任务及其全部文件，该操作不可撤销。',
      detail: count == 1 ? jobsToDelete.first.filename : '共 $count 个任务',
      icon: LucideIcons.trash2,
      confirmLabel: '删除',
      destructive: true,
    );
    if (!confirmed || !mounted) {
      return;
    }

    setState(() => _batchDeleting = true);
    final failedNames = <String>[];
    try {
      await Future.wait(
        jobsToDelete.map((job) async {
          try {
            await widget.api.deleteJob(job.jobId);
            _selectedJobIds.remove(job.jobId);
          } catch (_) {
            failedNames.add(job.filename);
          }
        }),
      );
    } finally {
      await widget.onRefresh().catchError((_) {});
      if (mounted) {
        setState(() {
          _batchDeleting = false;
          if (_selectedJobIds.isEmpty) {
            _selectionMode = false;
          }
        });
        if (failedNames.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '${failedNames.length} 个任务删除失败：${failedNames.join('、')}',
              ),
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    }
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

/// 优雅的空状态视图（Claude 极简美学）
class _EmptyJobsView extends StatelessWidget {
  const _EmptyJobsView();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppColors.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: app.accentSubtle,
              shape: BoxShape.circle,
              border: Border.all(
                color: app.accentBorder.withValues(alpha: 0.4),
              ),
            ),
            alignment: Alignment.center,
            child: Icon(LucideIcons.fileText, size: 22, color: app.accentText),
          ),
          const SizedBox(height: 14),
          Text(
            '还没有任务，上传一个 PDF 开始吧。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

/// 多选模式下的顶部操作工具条
class _BatchActionBar extends StatelessWidget {
  const _BatchActionBar({
    required this.totalSelectable,
    required this.selectedCount,
    required this.selectedDownloadableCount,
    required this.onSelectAll,
    required this.onUnselectAll,
    required this.onDownloadSelected,
    required this.onDeleteSelected,
    required this.onCancel,
    required this.isDownloading,
    required this.isDeleting,
  });

  final int totalSelectable;
  final int selectedCount;
  final int selectedDownloadableCount;
  final VoidCallback onSelectAll;
  final VoidCallback onUnselectAll;
  final VoidCallback onDownloadSelected;
  final VoidCallback onDeleteSelected;
  final VoidCallback onCancel;
  final bool isDownloading;
  final bool isDeleting;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppColors.of(context);
    final isBusy = isDownloading || isDeleting;

    final summary = Text(
      '已选中 $selectedCount / $totalSelectable 项',
      style: theme.textTheme.bodySmall?.copyWith(
        fontWeight: FontWeight.w600,
        color: app.accentText,
        fontSize: 12,
      ),
    );
    final toggleAllButton = TextButton(
      onPressed: !isBusy
          ? (selectedCount < totalSelectable ? onSelectAll : onUnselectAll)
          : null,
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
      child: Text(selectedCount < totalSelectable ? '全选' : '取消全选'),
    );
    final actionButtons = <Widget>[
      FilledButton.icon(
        onPressed: selectedDownloadableCount > 0 && !isBusy
            ? onDownloadSelected
            : null,
        icon: isDownloading
            ? const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(LucideIcons.download, size: 13),
        label: Text(
          selectedDownloadableCount > 0
              ? '下载选中 ($selectedDownloadableCount)'
              : '下载选中',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        style: FilledButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        ),
      ),
      OutlinedButton.icon(
        onPressed: selectedCount > 0 && !isBusy ? onDeleteSelected : null,
        icon: isDeleting
            ? SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: theme.colorScheme.error,
                ),
              )
            : const Icon(LucideIcons.trash2, size: 13),
        label: Text(
          selectedCount > 0 ? '删除 ($selectedCount)' : '删除',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: theme.colorScheme.error,
          side: BorderSide(
            color: selectedCount > 0 && !isBusy
                ? theme.colorScheme.error.withValues(alpha: 0.5)
                : theme.dividerColor,
          ),
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        ),
      ),
      IconButton(
        icon: const Icon(LucideIcons.x, size: 16),
        tooltip: '退出多选',
        onPressed: !isBusy ? onCancel : null,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      ),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: app.accentSubtle,
        border: Border.all(color: app.accentBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 460) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      LucideIcons.listChecks,
                      size: 16,
                      color: app.accentText,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: summary),
                    toggleAllButton,
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 6,
                  runSpacing: 6,
                  children: actionButtons,
                ),
              ],
            );
          }
          return Row(
            children: [
              Icon(LucideIcons.listChecks, size: 16, color: app.accentText),
              const SizedBox(width: 8),
              Expanded(child: summary),
              toggleAllButton,
              const SizedBox(width: 4),
              for (var index = 0; index < actionButtons.length; index++) ...[
                if (index > 0) const SizedBox(width: 6),
                actionButtons[index],
              ],
            ],
          );
        },
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
                    : (result?.isAllSuccess == true
                          ? app.successSubtle
                          : app.dangerSubtle),
                shape: BoxShape.circle,
              ),
              child: Icon(
                _downloading
                    ? LucideIcons.download
                    : (result?.isAllSuccess == true
                          ? LucideIcons.checkCheck
                          : LucideIcons.circleAlert),
                size: 20,
                color: _downloading
                    ? app.accentText
                    : (result?.isAllSuccess == true
                          ? app.success
                          : theme.colorScheme.error),
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
                  _currentFilename.isEmpty
                      ? '准备下载中...'
                      : '正在下载: $_currentFilename',
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
                    color: result.isAllSuccess
                        ? app.successSubtle
                        : app.accentSubtle,
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
                          color: result.isAllSuccess
                              ? app.success
                              : app.accentText,
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
              onPressed: () =>
                  openDirectoryInSystemExplorer(result.targetDirectory),
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

/// 重新设计后的单个任务卡片（Claude UI 美学风格）
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
  bool _saving = false;
  bool _deleting = false;
  bool _retrying = false;
  String? _retryError;
  bool _isHovered = false;

  bool get _isSelectable => _isClearableJob(widget.job);
  bool get _cancelable => isPendingJob(widget.job);
  bool get _retryable => widget.job.status == 'failed';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppColors.of(context);
    final job = widget.job;
    final status = job.status;
    final isCompleted = status == 'completed';
    final isFailed = status == 'failed';
    final isRunningOrQueued = !isCompleted && !isFailed;
    final progress = summarizeJobProgress(job);

    final activeStepIndex = jobSteps.indexWhere(
      (step) => step.id == resolveActiveStepId(job),
    );

    // 卡片背景与边框色彩混合
    final baseBgColor = theme.colorScheme.surfaceContainer;
    final cardBgColor = widget.isSelected
        ? Color.alphaBlend(app.accentSubtle, baseBgColor)
        : baseBgColor;

    Color borderColor = theme.dividerColor;
    if (widget.isSelected) {
      borderColor = theme.colorScheme.primary;
    } else if (isFailed) {
      borderColor = Color.alphaBlend(
        theme.colorScheme.error.withValues(alpha: 0.35),
        cardBgColor,
      );
    } else if (_isHovered) {
      borderColor = theme.colorScheme.outline;
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.selectionMode && _isSelectable
            ? () => widget.onSelectionChanged?.call(!widget.isSelected)
            : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: cardBgColor,
            border: Border.all(
              color: borderColor,
              width: widget.isSelected ? 1.5 : 1,
            ),
            borderRadius: BorderRadius.circular(12),
            boxShadow: _isHovered
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.035),
                      blurRadius: 10,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : const [],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. 卡片头部：状态图标 + 文件名/元数据 + 状态 Badge
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 多选 Checkbox
                  if (widget.selectionMode) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 6, right: 8),
                      child: Checkbox(
                        value: widget.isSelected,
                        onChanged: _isSelectable
                            ? (v) => widget.onSelectionChanged?.call(v ?? false)
                            : null,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ],

                  // 文件状态图标 Avatar
                  _StatusAvatar(status: status),
                  const SizedBox(width: 12),

                  // 文件名与元数据胶囊
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Tooltip(
                          message: job.filename,
                          waitDuration: const Duration(milliseconds: 500),
                          child: Text(
                            job.filename,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                              letterSpacing: -0.2,
                              color: theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                        const SizedBox(height: 5),
                        _buildMetaTags(context, job),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),

                  // 右侧状态 Badge
                  _StatusBadge(status: status),
                ],
              ),

              // 2. 中部主体区域：根据任务状态展示进度条/流水线或报错详情
              if (isRunningOrQueued) ...[
                const SizedBox(height: 12),
                _ProgressBlock(
                  job: job,
                  progress: progress,
                  stepsExpanded: _stepsExpanded,
                  onToggleSteps: () =>
                      setState(() => _stepsExpanded = !_stepsExpanded),
                  activeStepIndex: activeStepIndex,
                ),
              ] else if (isFailed) ...[
                const SizedBox(height: 10),
                _ErrorBlock(
                  message: job.message.isNotEmpty ? job.message : '任务执行失败',
                ),
              ],

              // 3. 错误提示条（如查看/重试抛出的异常）
              if (_retryError case final error?) ...[
                const SizedBox(height: 8),
                StatusText(message: error, isError: true),
              ],

              // 4. 底部操作按钮栏
              if (job.translatedPdfUrl.isNotEmpty ||
                  _retryable ||
                  _cancelable) ...[
                const SizedBox(height: 12),
                _buildActionFooter(context),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 优雅的元数据胶囊标签（Claude 微型标签风格）
  Widget _buildMetaTags(BuildContext context, JobSummary job) {
    final theme = Theme.of(context);
    final items = <Widget>[];

    void addTag({
      required String label,
      IconData? icon,
      Color? customBg,
      Color? customFg,
    }) {
      items.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color:
                customBg ?? theme.colorScheme.secondary.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 11,
                  color: customFg ?? theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 3.5),
              ],
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: customFg ?? theme.colorScheme.onSurfaceVariant,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    height: 1.1,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 目标语言
    if (job.targetLanguage.isNotEmpty) {
      addTag(label: '目标: ${job.targetLanguage}', icon: LucideIcons.languages);
    }

    // 页码范围
    if (job.pages.isNotEmpty) {
      addTag(label: '页码: ${job.pages}', icon: LucideIcons.fileSearch);
    }

    // 跳过页码
    if (job.skipPages.isNotEmpty) {
      addTag(label: '跳过: ${job.skipPages}');
    }

    // 总页数
    if (job.pageCount != null && job.pageCount != 0) {
      addTag(label: '共 ${job.pageCount} 页', icon: LucideIcons.files);
    }

    // 任务 ID 简短标识
    addTag(
      label: '#${job.jobId}',
      customBg: theme.colorScheme.surface.withValues(alpha: 0.8),
    );

    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: items,
    );
  }

  /// 底部按钮操作栏
  Widget _buildActionFooter(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppColors.of(context);
    final job = widget.job;
    final isCompleted = job.status == 'completed';
    final readyLabel = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(LucideIcons.sparkles, size: 12, color: app.accentText),
        const SizedBox(width: 4),
        Text(
          '版式保留译文已就绪',
          style: theme.textTheme.bodySmall?.copyWith(
            color: app.accentText,
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
    final actionButtons = <Widget>[
      if (_retryable)
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            backgroundColor: app.accentSubtle,
            foregroundColor: app.accentText,
            side: BorderSide(color: app.accentBorder),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(7),
            ),
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            textStyle: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          icon: _retrying
              ? const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(LucideIcons.rotateCw, size: 13),
          onPressed: _retrying ? null : _retry,
          label: Text(_retrying ? '正在重试…' : '重试'),
        ),
      if (isCompleted && job.translatedPdfUrl.isNotEmpty)
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            backgroundColor: theme.colorScheme.surface,
            foregroundColor: theme.colorScheme.onSurface,
            side: BorderSide(color: theme.dividerColor),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(7),
            ),
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            textStyle: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          icon: _saving
              ? const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(LucideIcons.download, size: 13),
          onPressed: _saving ? null : _savePdfAs,
          label: Text(_saving ? '保存中…' : '另存为…'),
        ),
      if (isCompleted && job.translatedPdfUrl.isNotEmpty)
        FilledButton.icon(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(7),
            ),
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            textStyle: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          icon: _viewing
              ? const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(LucideIcons.eye, size: 13),
          onPressed: _viewing ? null : _viewPdf,
          label: Text(_viewing ? '正在打开…' : '查看 PDF'),
        ),
      if (_cancelable)
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            backgroundColor: theme.colorScheme.surface,
            foregroundColor: theme.colorScheme.onSurfaceVariant,
            side: BorderSide(color: theme.dividerColor),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(7),
            ),
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            textStyle: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          icon: _deleting
              ? const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(LucideIcons.x, size: 13),
          onPressed: _deleting ? null : _cancel,
          label: Text(_deleting ? '正在取消…' : '取消任务'),
        ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 430) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isCompleted) ...[
                Align(alignment: Alignment.centerLeft, child: readyLabel),
                const SizedBox(height: 8),
              ],
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 6,
                runSpacing: 6,
                children: actionButtons,
              ),
            ],
          );
        }
        return Row(
          children: [
            if (isCompleted) readyLabel,
            const Spacer(),
            for (var index = 0; index < actionButtons.length; index++) ...[
              if (index > 0) const SizedBox(width: 6),
              actionButtons[index],
            ],
          ],
        );
      },
    );
  }

  /// 重试任务
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

  /// 取消排队或准备中的任务
  Future<void> _cancel() async {
    final confirmed = await showAppConfirmDialog(
      context,
      title: '取消任务',
      message: '将取消尚未开始的任务并删除已上传的源文件，该操作不可撤销。',
      detail: widget.job.filename,
      icon: Icons.close,
      confirmLabel: '取消任务',
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
      unawaited(widget.onRefresh().catchError((_) {}));
    } finally {
      if (mounted) {
        setState(() => _deleting = false);
      }
    }
  }

  /// 预览查看 PDF
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

  /// 另存为 PDF
  Future<void> _savePdfAs() async {
    setState(() {
      _saving = true;
      _retryError = null;
    });
    try {
      final savedPath = await savePdfArtifact(api: widget.api, job: widget.job);
      if (savedPath != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已成功保存至: $savedPath'),
            action: SnackBarAction(
              label: '打开文件',
              onPressed: () => openFileInSystemViewer(savedPath),
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => _retryError = describeError(error));
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }
}

/// 状态徽章 Badge（极简胶囊样式）
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

/// 状态图标容器 Avatar
class _StatusAvatar extends StatelessWidget {
  const _StatusAvatar({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppColors.of(context);

    final (bgColor, iconColor, icon) = switch (status) {
      'completed' => (app.successSubtle, app.success, LucideIcons.fileCheck),
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
      _ => (app.accentSubtle, app.accentText, LucideIcons.fileCog),
    };

    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(9),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: 19, color: iconColor),
    );
  }
}

/// 进行中/排队中进度模块与折叠流水线
class _ProgressBlock extends StatelessWidget {
  const _ProgressBlock({
    required this.job,
    required this.progress,
    required this.stepsExpanded,
    required this.onToggleSteps,
    required this.activeStepIndex,
  });

  final JobSummary job;
  final JobProgress progress;
  final bool stepsExpanded;
  final VoidCallback onToggleSteps;
  final int activeStepIndex;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppColors.of(context);

    final progressPercent = progress.percent / 100;
    final isWaiting = isWaitingForSlot(job);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 顶部状态描述 + 百分比
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  formatJobMessage(job),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                isWaiting ? '等待中' : progress.value,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: app.accentText,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // 进度条（细长平滑，排队等槽位时进度为 0）
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: progressPercent,
              valueColor: AlwaysStoppedAnimation<Color>(
                theme.colorScheme.primary,
              ),
              backgroundColor: theme.colorScheme.secondary,
              minHeight: 4.5,
            ),
          ),

          const SizedBox(height: 8),

          // 流水线展开/折叠触发栏
          InkWell(
            onTap: onToggleSteps,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
              child: Row(
                children: [
                  Icon(
                    stepsExpanded
                        ? LucideIcons.chevronDown
                        : LucideIcons.chevronRight,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    stepsExpanded
                        ? '收起处理流程'
                        : '查看处理流程 (阶段 ${activeStepIndex + 1}/${jobSteps.length})',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 展开的流水线 Timeline
          if (stepsExpanded) ...[
            const SizedBox(height: 8),
            _PipelineTimeline(job: job, activeStepIndex: activeStepIndex),
          ],
        ],
      ),
    );
  }
}

/// 优雅的纵向连接线时间轴流水线（Claude UI 设计）
class _PipelineTimeline extends StatelessWidget {
  const _PipelineTimeline({required this.job, required this.activeStepIndex});

  final JobSummary job;
  final int activeStepIndex;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        children: [
          for (var i = 0; i < jobSteps.length; i++)
            _TimelineStepRow(
              step: jobSteps[i],
              state: resolveStepState(job, i, activeStepIndex),
              isLast: i == jobSteps.length - 1,
            ),
        ],
      ),
    );
  }
}

class _TimelineStepRow extends StatefulWidget {
  const _TimelineStepRow({
    required this.step,
    required this.state,
    required this.isLast,
  });

  final JobStep step;
  final JobStepState state;
  final bool isLast;

  @override
  State<_TimelineStepRow> createState() => _TimelineStepRowState();
}

class _TimelineStepRowState extends State<_TimelineStepRow>
    with SingleTickerProviderStateMixin {
  late final _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );

  @override
  void initState() {
    super.initState();
    _syncSpin();
  }

  @override
  void didUpdateWidget(_TimelineStepRow oldWidget) {
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

    final (icon, iconColor) = switch (state) {
      JobStepState.done => (LucideIcons.checkCircle2, app.success),
      JobStepState.active => (LucideIcons.refreshCw, app.accentText),
      JobStepState.error => (LucideIcons.xCircle, theme.colorScheme.error),
      JobStepState.pending => (
        LucideIcons.circle,
        theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.35),
      ),
    };

    final isDimmed = state == JobStepState.pending;
    final isActive = state == JobStepState.active;

    final iconWidget = Icon(icon, size: 13, color: iconColor);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左侧：节点图标 + 连接竖线
          SizedBox(
            width: 18,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: isActive
                      ? RotationTransition(turns: _spin, child: iconWidget)
                      : iconWidget,
                ),
                if (!widget.isLast)
                  Expanded(
                    child: Container(
                      width: 1.5,
                      margin: const EdgeInsets.symmetric(vertical: 2),
                      color: state == JobStepState.done
                          ? app.success.withValues(alpha: 0.4)
                          : theme.dividerColor,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),

          // 右侧：阶段文本
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: widget.isLast ? 2 : 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    step.label,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: isActive
                          ? FontWeight.w700
                          : (isDimmed ? FontWeight.w400 : FontWeight.w600),
                      color: isActive
                          ? app.accentText
                          : (isDimmed
                                ? theme.colorScheme.onSurfaceVariant
                                : null),
                      fontSize: 11.5,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      step.detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant.withValues(
                          alpha: isDimmed ? 0.6 : 0.9,
                        ),
                        fontSize: 11,
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

/// 失败错误信息展示块（支持复制与清晰排版）
class _ErrorBlock extends StatelessWidget {
  const _ErrorBlock({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppColors.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: app.dangerSubtle,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.25),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                LucideIcons.circleAlert,
                size: 14,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 6),
              Text(
                '执行中断',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
              const Spacer(),
              InkWell(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: message));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('已复制错误信息到剪贴板'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 2,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        LucideIcons.copy,
                        size: 11,
                        color: theme.colorScheme.error,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '复制错误',
                        style: TextStyle(
                          color: theme.colorScheme.error,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            message,
            style: TextStyle(
              color: theme.colorScheme.error,
              fontSize: 11.5,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}
