import 'package:flretainpdf/api/api_client.dart';
import 'package:flretainpdf/jobs/job_status.dart';
import 'package:flretainpdf/jobs/page_selection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

JobSummary _job({
  String status = 'queued',
  String step = '',
  String message = '',
  int? pageCount,
}) {
  return JobSummary(
    jobId: 'job-1',
    filename: 'a.pdf',
    status: status,
    step: step,
    message: message,
    targetLanguage: 'zh-CN',
    pages: '',
    skipPages: '',
    pageCount: pageCount,
    translatedPdfUrl: '',
  );
}

void main() {
  // 没有这行 SharedPreferences.getInstance() 在测试环境里永远不会 resolve
  // （没有平台通道可用），RetainPdfApp 现在要等 prefs 就绪才挂主界面，
  // 不 mock 的话界面会一直停在启动页。
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('页码校验与 webapp 保持一致', () {
    expect(validatePageSelection('', '翻译页码'), isEmpty);
    expect(validatePageSelection('1-10,11,13', '翻译页码'), isEmpty);
    expect(validatePageSelection('5-', '翻译页码'), isEmpty);
    expect(validatePageSelection('1..10', '翻译页码'), isEmpty);
    expect(validatePageSelection('abc', '翻译页码'), contains('格式不正确'));
    expect(validatePageSelection('5-2', '翻译页码'), contains('起始页不能大于结束页'));
  });

  test('翻译进度从 message 里解析出来', () {
    final unit = parseTranslationProgress('已完成 3/10 个单元', null);
    expect(unit?.current, 3);
    expect(unit?.total, 10);
    expect(unit?.unit, '个单元');

    final page = parseTranslationProgress('正在翻译第 2/4 页', null);
    expect(page?.current, 2);
    expect(page?.unit, '页');

    expect(parseTranslationProgress('共 8 页', 8)?.total, 8);
    expect(parseTranslationProgress('没有数字', null), isNull);
  });

  test('进度百分比覆盖各状态', () {
    expect(summarizeJobProgress(_job(status: 'completed')).percent, 100);
    expect(summarizeJobProgress(_job(status: 'failed')).value, '执行失败');
    expect(
      summarizeJobProgress(_job(status: 'translating', message: '已完成 5/10 个单元'))
          .value,
      '5/10 个单元',
    );
  });

  test('排队等槽位的任务单独展示，进度条不虚假前进', () {
    final waiting = _job(status: 'queued', step: 'queued');
    expect(isWaitingForSlot(waiting), isTrue);
    expect(isPendingJob(waiting), isTrue);
    expect(formatStatus(waiting.status), '排队中');
    expect(summarizeJobProgress(waiting).percent, 0);
    expect(summarizeJobProgress(waiting).value, '等待中');

    // 刚建好、马上就要开跑的任务是另一个状态，进度条照常给默认那一档。
    final fresh = _job(status: 'preparing', step: 'preparing');
    expect(isWaitingForSlot(fresh), isFalse);
    expect(isPendingJob(fresh), isTrue);
    expect(formatStatus(fresh.status), '准备中');
    expect(summarizeJobProgress(fresh).percent, greaterThan(0));
    // step 也认不出 preparing，落回第一个阶段。
    expect(resolveActiveStepId(fresh), 'queued');
  });

  test('步骤状态跟随 step 字段推进', () {
    final job = _job(status: 'translating', step: 'translating');
    final activeIndex = jobSteps.indexWhere(
      (step) => step.id == resolveActiveStepId(job),
    );
    expect(activeIndex, 2);
    expect(resolveStepState(job, 0, activeIndex), JobStepState.done);
    expect(resolveStepState(job, 2, activeIndex), JobStepState.active);
    expect(resolveStepState(job, 3, activeIndex), JobStepState.pending);
    expect(resolveStepState(_job(status: 'failed'), 0, 0), JobStepState.error);
  });
}
