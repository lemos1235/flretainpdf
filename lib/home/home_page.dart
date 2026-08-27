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

class _HomePageState extends State<HomePage> {
  ApiClient get _api => widget.api;
  Timer? _pollTimer;
  List<JobSummary> _jobs = const [];
  String _listError = '';
  final _formKey = GlobalKey<JobFormSectionState>();

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
    } catch (error) {
      if (mounted) {
        setState(() => _listError = describeError(error));
      }
    }
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
          width: 340,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 14, 7, 14),
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
        VerticalDivider(
          width: 1,
          thickness: 1,
          color: theme.dividerColor,
        ),
        // 右栏：任务管理与进度中心
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(7, 14, 14, 14),
            children: [
              if (_listError.isNotEmpty) ...[
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
                const SizedBox(height: 10),
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

