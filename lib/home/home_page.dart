import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../jobs/job_form_section.dart';
import '../jobs/job_list_section.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.api});

  final ApiClient api;

  @override
  State<HomePage> createState() => _HomePageState();
}

/// 一轮轮询最多触发几个对照合成。存量历史任务可能很多，不设上限会一次性把
/// 请求全压给服务端。
const _autoCompareMaxBatch = 3;

/// 同一个任务最多自动重试几次合成。服务端重启、网络抖动这类瞬时失败值得再试，
/// 但一直失败就别拿轮询反复砸服务端了。
const _autoCompareMaxAttempts = 3;

class _HomePageState extends State<HomePage> {
  ApiClient get _api => widget.api;
  Timer? _pollTimer;
  List<JobSummary> _jobs = const [];
  String _listError = '';
  final _formKey = GlobalKey<JobFormSectionState>();

  /// 本次运行里不再自动合成对照的任务：合成成功的，以及失败次数已经到顶的。
  /// 免得三秒一次的轮询对同一个任务反复 POST。任务重新跑起来时会被清掉，那时
  /// 算新一轮。
  final Set<String> _comparedJobs = <String>{};

  /// 各任务自动合成连续失败的次数，到 [_autoCompareMaxAttempts] 就不再重试。
  final Map<String, int> _compareFailures = <String, int>{};
  bool _autoCompareRunning = false;

  @override
  void initState() {
    super.initState();
    _refreshJobs();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _refreshJobs(),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshJobs() async {
    try {
      final jobs = await _api.fetchJobs();
      if (!mounted) {
        return;
      }
      setState(() {
        _jobs = jobs;
        _listError = '';
      });
      bool isStale(String jobId) =>
          !jobs.any((job) => job.jobId == jobId && job.status == 'completed');
      _comparedJobs.removeWhere((jobId) => isStale(jobId));
      _compareFailures.removeWhere((jobId, _) => isStale(jobId));
      unawaited(_runAutoCompareQueue());
    } catch (error) {
      if (mounted) {
        setState(() => _listError = describeError(error));
      }
    }
  }

  /// 任务完成后自动合成对照 PDF。服务端是同步合成的，返回时地址就有了，直接
  /// 补进本地列表让「对照 PDF」按钮立刻出现，不必干等下一轮轮询。
  Future<void> _runAutoCompareQueue() async {
    if (_autoCompareRunning) {
      return;
    }
    _autoCompareRunning = true;
    // 失败的任务会被放回队列，本轮里得记着别再挑第二次，不然三个名额可能全
    // 花在同一个任务上。
    final attempted = <String>{};
    try {
      for (var processed = 0; processed < _autoCompareMaxBatch; processed++) {
        final pending = _jobs
            .where(
              (job) =>
                  job.status == 'completed' &&
                  job.comparePdfUrl.isEmpty &&
                  !_comparedJobs.contains(job.jobId) &&
                  !attempted.contains(job.jobId),
            )
            .toList();
        if (pending.isEmpty) {
          break;
        }
        final target = pending.first;
        attempted.add(target.jobId);
        // 先占位，免得请求还在飞的时候下一轮轮询又挑中同一个任务。
        _comparedJobs.add(target.jobId);
        try {
          final result = await _api.generateComparePdf(target.jobId);
          _compareFailures.remove(target.jobId);
          if (!mounted) {
            return;
          }
          _applyComparePdfUrl(target.jobId, result.comparePdfUrl);
        } catch (error) {
          // 合成失败不打扰用户：按钮本来就没出现。可重试的失败放回队列等下一
          // 轮轮询再试，连续失败到顶就留在集合里不再自动重试。
          if (_isRetriableCompareError(error)) {
            final failures = (_compareFailures[target.jobId] ?? 0) + 1;
            _compareFailures[target.jobId] = failures;
            if (failures < _autoCompareMaxAttempts) {
              _comparedJobs.remove(target.jobId);
            }
          }
        }
        if (!mounted) {
          return;
        }
      }
    } finally {
      _autoCompareRunning = false;
    }
  }

  /// 把刚合成好的对照件地址补进本地任务列表。轮询期间任务可能已经被删掉或
  /// 重跑，所以按 id 找，找不到就算了，下一轮轮询自会带回真实状态。
  void _applyComparePdfUrl(String jobId, String comparePdfUrl) {
    if (comparePdfUrl.isEmpty) {
      return;
    }
    final index = _jobs.indexWhere((job) => job.jobId == jobId);
    if (index < 0 || _jobs[index].comparePdfUrl == comparePdfUrl) {
      return;
    }
    final updated = List<JobSummary>.of(_jobs);
    updated[index] = updated[index].copyWith(comparePdfUrl: comparePdfUrl);
    setState(() => _jobs = updated);
  }

  /// 合成失败值不值得下一轮再试。404 是「任务不存在 / 尚未完成 / 译文缺失」，
  /// 这些在任务重跑之前不会变，重试只是白费请求；409（合成期间状态或译文变了）
  /// 和 5xx、网络故障都是瞬时的，值得再试。
  bool _isRetriableCompareError(Object error) {
    if (error is ApiException) {
      return error.statusCode != 404;
    }
    return true;
  }

  /// 在原任务上重试：源文件用服务端保存的那份，参数取当前表单的最新值。
  /// 服务端把任务请求和源文件都落了盘，应用重启、任务被打断也不影响重试，
  /// 所以这里不需要任何本地记忆。
  Future<void> _retryJob(JobSummary job) async {
    final fields = _formKey.currentState?.buildRetryFields() ?? const {};
    await _api.retryJob(job.jobId, fields);
    await _refreshJobs();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 左栏：任务创建控制台
        SizedBox(
          width: 384,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
            children: [
              JobFormSection(
                key: _formKey,
                api: _api,
                onJobCreated: _refreshJobs,
              ),
            ],
          ),
        ),
        // 中间分隔线
        VerticalDivider(width: 1, thickness: 1, color: theme.dividerColor),
        // 右栏：任务管理与进度中心
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(8, 16, 16, 16),
            children: [
              if (_listError.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.error.withValues(alpha: 0.08),
                    border: Border.all(
                      color: theme.colorScheme.error.withValues(alpha: 0.25),
                    ),
                    borderRadius: BorderRadius.circular(10),
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
                              '任务列表刷新失败',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.error,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _listError,
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
              JobListSection(
                api: _api,
                jobs: _jobs,
                onRefresh: _refreshJobs,
                onRetry: _retryJob,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
