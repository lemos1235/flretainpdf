import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../theme/app_theme.dart';
import '../widgets/app_panel.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/status_text.dart';
import 'job_status.dart';

class JobListSection extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppColors.of(context);
    final waiting = jobs.where(isWaitingForSlot).length;
    return AppPanel(
      title: '任务列表',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 有任务在等槽位时单独标出来，免得用户以为卡住了。
          if (waiting > 0) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
          if (jobs.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
          Semantics(
            label: '刷新任务列表',
            button: true,
            child: IconButton(
              icon: const Icon(Icons.refresh, size: 16),
              tooltip: '刷新任务列表',
              onPressed: onRefresh,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            ),
          ),
        ],
      ),
      child: jobs.isEmpty
          ? Container(
              padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondary.withValues(alpha: 0.5),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.inbox_outlined,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 10),
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
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < jobs.length; i++)
                  Padding(
                    padding: EdgeInsets.only(bottom: i < jobs.length - 1 ? 10 : 0),
                    child: _JobCard(
                      api: api,
                      job: jobs[i],
                      onRefresh: onRefresh,
                      onRetry: onRetry,
                    ),
                  ),
              ],
            ),
    );
  }
}

class _JobCard extends StatefulWidget {
  const _JobCard({
    required this.api,
    required this.job,
    required this.onRefresh,
    required this.onRetry,
  });

  final ApiClient api;
  final JobSummary job;
  final Future<void> Function() onRefresh;
  final Future<void> Function(JobSummary job) onRetry;

  @override
  State<_JobCard> createState() => _JobCardState();
}

class _JobCardState extends State<_JobCard> {
  bool _stepsExpanded = false;
  bool _downloading = false;
  bool _deleting = false;
  bool _retrying = false;
  String? _retryError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = AppColors.of(context);
    final job = widget.job;
    final progress = summarizeJobProgress(job);
    final activeStepIndex = jobSteps.indexWhere(
      (step) => step.id == resolveActiveStepId(job),
    );

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 头部：文件名 + 状态 Badge
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      job.filename,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _formatMeta(job),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: switch (job.status) {
                    'completed' => app.successSubtle,
                    'failed' => app.dangerSubtle,
                    _ => theme.colorScheme.secondary,
                  },
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: switch (job.status) {
                      'completed' => app.success.withValues(alpha: 0.3),
                      'failed' => theme.colorScheme.error.withValues(alpha: 0.3),
                      _ => theme.dividerColor,
                    },
                  ),
                ),
                child: Text(
                  formatStatus(job.status),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: switch (job.status) {
                      'completed' => app.success,
                      'failed' => theme.colorScheme.error,
                      _ => theme.colorScheme.onSurfaceVariant,
                    },
                  ),
                ),
              ),
            ],
          ),
          // 进度条与步骤：已完成的任务不必再看这些过程信息，直接省掉。
          if (job.status != 'completed') ...[
            const SizedBox(height: 10),
            _Progress(job: job, progress: progress),
            const SizedBox(height: 8),

            // 步骤提示（紧凑单行 + 点击展开）
            InkWell(
              onTap: () => setState(() => _stepsExpanded = !_stepsExpanded),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Icon(
                      _stepsExpanded
                          ? Icons.keyboard_arrow_down
                          : Icons.keyboard_arrow_right,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        formatJobMessage(job),
                        maxLines: _stepsExpanded ? 5 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // 展开的步骤列表
            if (_stepsExpanded) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(8),
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

          // 操作按钮。跑完的任务能删，还没开跑的能撤（后端把删除待执行
          // 任务当取消处理）；正在跑的后端会拒绝，按钮就别出现了。
          if (job.translatedPdfUrl.isNotEmpty || _retryable || _deletable) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                if (_retryable) ...[
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: app.accentSubtle,
                      foregroundColor: app.accentText,
                      side: BorderSide(color: app.accentBorder),
                      shape: const StadiumBorder(),
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      textStyle: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
                    ),
                    icon: _retrying
                        ? const SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh, size: 13),
                    onPressed: _retrying ? null : _retry,
                    label: Text(_retrying ? '正在重试…' : '重试'),
                  ),
                  const SizedBox(width: 8),
                ],
                if (job.translatedPdfUrl.isNotEmpty)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: app.accentSubtle,
                      foregroundColor: app.accentText,
                      side: BorderSide(color: app.accentBorder),
                      shape: const StadiumBorder(),
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      textStyle: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
                    ),
                    icon: const Icon(Icons.download, size: 13),
                    onPressed: _downloading ? null : _download,
                    label: const Text('下载译文 PDF'),
                  ),
                if (_deletable) ...[
                  if (job.translatedPdfUrl.isNotEmpty && !_retryable)
                    const SizedBox(width: 8),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: theme.colorScheme.surface,
                      foregroundColor: theme.colorScheme.onSurfaceVariant,
                      side: BorderSide(color: theme.dividerColor),
                      shape: const StadiumBorder(),
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      textStyle: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
                    ),
                    icon: _deleting
                        ? const SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            _cancelable
                                ? Icons.close
                                : Icons.delete_outline,
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
    );
  }

  /// 跑完（成功或失败）或还没开跑的任务能删，与 webapp 的按钮显示条件一致。
  bool get _deletable =>
      widget.job.status == 'completed' ||
      widget.job.status == 'failed' ||
      isPendingJob(widget.job);

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
    // 点下按钮那一刻任务还没开跑：文案、以及下面失败后要不要补刷，都看它。
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
        // 还没开跑的任务多半是正好在确认框和请求之间开跑了（后端答「还在处理
        // 中」）。立刻拉一次列表，那个已经不成立的按钮当场消失，不用等下一
        // 轮轮询。这次刷新自己失败了也不能盖掉上面那条真正的错误。
        // 其它状态的失败（连不上服务之类）补刷只会再失败一次，不值当。
        unawaited(widget.onRefresh().catchError((_) {}));
      }
    } finally {
      // 刷新后本卡片可能已经被移除，mounted 判断不能省。
      if (mounted) {
        setState(() => _deleting = false);
      }
    }
  }

  /// 先把产物下下来，再让系统的保存对话框决定落到哪儿。
  Future<void> _download() async {
    setState(() => _downloading = true);
    try {
      final bytes = await widget.api.downloadArtifact(
        widget.job.translatedPdfUrl,
      );
      await FilePicker.saveFile(
        fileName: _suggestedFileName(widget.job),
        bytes: bytes,
        mimeType: 'application/pdf',
        dialogTitle: '保存纯译文 PDF',
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
      );
    } finally {
      if (mounted) {
        setState(() => _downloading = false);
      }
    }
  }
}

/// 保存对话框的默认文件名：原名去掉扩展名，接上目标语言，避免覆盖原件。
String _suggestedFileName(JobSummary job) {
  final name = job.filename.isEmpty ? 'translated' : job.filename;
  final base = name.toLowerCase().endsWith('.pdf')
      ? name.substring(0, name.length - 4)
      : name;
  final language = job.targetLanguage.trim();
  return language.isEmpty ? '$base-translated.pdf' : '$base-$language.pdf';
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
      _spin.repeat();
    } else {
      _spin.stop();
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
      JobStepState.done => (Icons.check_circle_outline, app.success),
      JobStepState.active => (Icons.sync, app.accentText),
      JobStepState.error => (Icons.cancel_outlined, theme.colorScheme.error),
      JobStepState.pending => (
        Icons.radio_button_unchecked,
        theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
      ),
    };
    final dimmed = state == JobStepState.pending;
    final iconWidget = Icon(icon, size: 14, color: color);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.5),
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

String _formatMeta(JobSummary job) {
  final buffer = StringBuffer(
    'ID: ${job.jobId} · 目标: ${job.targetLanguage}',
  );
  if (job.pages.isNotEmpty) {
    buffer.write(' · 页码: ${job.pages}');
  }
  if (job.skipPages.isNotEmpty) {
    buffer.write(' · 跳过: ${job.skipPages}');
  }
  if (job.pageCount != null && job.pageCount != 0) {
    buffer.write(' · 共 ${job.pageCount} 页');
  }
  return buffer.toString();
}

