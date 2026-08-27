import '../api/api_client.dart';

/// 任务卡片上展示的五个阶段，顺序即进度顺序。移植自 webapp/app.js 的 `jobSteps`。
class JobStep {
  const JobStep(this.id, this.label, this.detail);

  final String id;
  final String label;
  final String detail;
}

const jobSteps = <JobStep>[
  JobStep('queued', '任务排队', '接收文件并准备执行'),
  JobStep('extracting', '文本块分析与提取', '解析页面结构与可翻译文本'),
  JobStep('translating', '批量翻译', '逐页生成目标语言内容'),
  JobStep('rendering', '保留布局渲染', '回填版式并输出译文 PDF'),
  JobStep('completed', '产物就绪', '纯译文 PDF 已可下载'),
];

int? _stepIndex(String id) {
  final index = jobSteps.indexWhere((step) => step.id == id);
  return index < 0 ? null : index;
}

String formatStatus(String status) {
  const mapping = {
    'preparing': '准备中',
    'queued': '排队中',
    'extracting': '分析中',
    'translating': '翻译中',
    'rendering': '排版中',
    'completed': '已完成',
    'failed': '执行失败',
  };
  return mapping[status] ?? status;
}

/// 任务是在等一个执行槽位（而不是刚建好、正在准备）。
///
/// 后端把「还没开跑」拆成了两个状态：`preparing` 是刚创建、马上就要开始，
/// `queued` 是抢不到并发槽位停在队列里。早先两者共用 `queued`，只能从 message
/// 里的措辞反推；现在有了结构化状态，不必再猜。
bool isWaitingForSlot(JobSummary job) => job.status == 'queued';

/// 任务还没开始跑：`preparing`（刚创建）或 `queued`（卡在并发上限上排队）。
/// 后端对这两种一视同仁地允许删除，删除即取消。
bool isPendingJob(JobSummary job) =>
    job.status == 'preparing' || job.status == 'queued';

String formatJobMessage(JobSummary job) {
  if (job.message.trim().isNotEmpty) {
    return job.message;
  }
  const mapping = {
    'preparing': '任务已创建，等待开始处理。',
    'queued': '任务已进入队列，等待开始处理。',
    'extracting': '正在分析页面结构并提取文本。',
    'translating': '正在批量翻译文档内容。',
    'rendering': '正在生成纯译文 PDF。',
    'completed': '全部阶段已完成，可下载译文 PDF。',
    'failed': '任务执行失败，请查看错误信息。',
  };
  return mapping[job.status] ?? '任务状态更新中。';
}

/// 任务卡片顶部那一行「当前阶段 / 进度值 / 百分比」。
class JobProgress {
  const JobProgress(this.label, this.value, this.percent);

  final String label;
  final String value;
  final int percent;
}

JobProgress summarizeJobProgress(JobSummary job) {
  final activeStepIndex = _stepIndex(resolveActiveStepId(job)) ?? 0;
  final totalSteps = jobSteps.length;

  if (job.status == 'completed') {
    return const JobProgress('当前阶段：产物已全部生成', '100%', 100);
  }

  if (job.status == 'failed') {
    final failedStep = jobSteps[activeStepIndex];
    return JobProgress(
      '当前阶段：${failedStep.label}',
      '执行失败',
      _clampProgress((activeStepIndex / totalSteps * 100).round()),
    );
  }

  if (job.status == 'translating') {
    final progress = parseTranslationProgress(job.message, job.pageCount);
    if (progress != null) {
      final withinStep = progress.current / progress.total;
      final percent = (activeStepIndex + withinStep) / totalSteps * 100;
      return JobProgress(
        '当前阶段：批量翻译',
        '${progress.current}/${progress.total} ${progress.unit}',
        _clampProgress(percent.round()),
      );
    }
  }

  // 排队等槽位的任务还没真正开始，进度条留在 0：给它 9% 会让人以为在跑。
  // `preparing` 不走这里 —— 它马上就开跑，和 webapp 一样吃默认的那 9%。
  if (isWaitingForSlot(job)) {
    return const JobProgress('当前阶段：排队等待', '等待中', 0);
  }

  final defaultPercent = (activeStepIndex + 0.45) / totalSteps * 100;
  return JobProgress(
    '当前阶段：${jobSteps[activeStepIndex].label}',
    formatStatus(job.status),
    _clampProgress(defaultPercent.round()),
  );
}

class TranslationProgress {
  const TranslationProgress(this.current, this.total, this.unit);

  final int current;
  final int total;
  final String unit;
}

/// 后端只在 message 里以自然语言汇报翻译进度，这里把它解析回数字。
TranslationProgress? parseTranslationProgress(String message, int? pageCount) {
  final unitMatched = RegExp(r'已完成\s*(\d+)\s*/\s*(\d+)\s*个单元')
      .firstMatch(message);
  if (unitMatched != null) {
    final current = int.parse(unitMatched.group(1)!);
    final total = int.parse(unitMatched.group(2)!);
    if (total > 0) {
      return TranslationProgress(
        current < total ? current : total,
        total,
        '个单元',
      );
    }
  }

  final pageMatched = RegExp(r'第\s*(\d+)\s*/\s*(\d+)\s*页').firstMatch(message);
  if (pageMatched != null) {
    final current = int.parse(pageMatched.group(1)!);
    final total = int.parse(pageMatched.group(2)!);
    if (total > 0) {
      return TranslationProgress(current < total ? current : total, total, '页');
    }
  }

  if (pageCount != null &&
      pageCount > 0 &&
      RegExp(r'共\s*\d+\s*页').hasMatch(message)) {
    return TranslationProgress(0, pageCount, '页');
  }

  return null;
}

int _clampProgress(int value) => value.clamp(0, 100);

String resolveActiveStepId(JobSummary job) {
  if (job.status == 'completed') {
    return 'completed';
  }
  if (_stepIndex(job.step) != null) {
    return job.step;
  }
  if (_stepIndex(job.status) != null) {
    return job.status;
  }
  return 'queued';
}

enum JobStepState { done, active, error, pending }

JobStepState resolveStepState(
  JobSummary job,
  int stepIndex,
  int activeStepIndex,
) {
  if (job.status == 'completed') {
    return JobStepState.done;
  }
  if (job.status == 'failed') {
    if (stepIndex < activeStepIndex) {
      return JobStepState.done;
    }
    return stepIndex == activeStepIndex
        ? JobStepState.error
        : JobStepState.pending;
  }
  if (stepIndex < activeStepIndex) {
    return JobStepState.done;
  }
  return stepIndex == activeStepIndex
      ? JobStepState.active
      : JobStepState.pending;
}
