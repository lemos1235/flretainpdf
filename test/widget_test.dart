import 'dart:convert';

import 'package:flretainpdf/api/api_client.dart';
import 'package:flretainpdf/jobs/job_status.dart';
import 'package:flretainpdf/jobs/page_selection.dart';
import 'package:flretainpdf/main.dart';
import 'package:flutter/material.dart';
import 'package:flretainpdf/server/backend_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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

/// 主界面挂载的前提是内置服务已就绪。这里让 /health 直接答 200，
/// BackendService 会走「复用已在运行的服务」分支，不碰子进程和文件系统。
RetainPdfApp _app() {
  final api = ApiClient(
    client: MockClient((request) async {
      final path = request.url.path;
      if (path == '/health') {
        return http.Response('ok', 200);
      }
      if (path == '/api/jobs') {
        return http.Response(
          '[]',
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      return http.Response(
        jsonEncode(const <String, dynamic>{}),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }),
  );
  return RetainPdfApp(api: api, backend: BackendService(api: api));
}

void main() {
  // 没有这行 SharedPreferences.getInstance() 在测试环境里永远不会 resolve
  // （没有平台通道可用），RetainPdfApp 现在要等 prefs 就绪才挂主界面，
  // 不 mock 的话界面会一直停在启动页。
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('导航栏能在主页和设置页之间切换', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    // 未选中的那一页在 IndexedStack 里是 offstage，find 默认不会看到。
    expect(find.text('偏好设置'), findsNothing);

    await tester.tap(find.bySemanticsLabel('设置'));
    await tester.pumpAndSettle();

    expect(find.text('偏好设置'), findsOneWidget);
    expect(find.text('翻译大模型配置'), findsOneWidget);
    expect(find.text('MinerU 版面识别服务'), findsOneWidget);
    expect(find.text('创建翻译任务'), findsNothing);

    await tester.tap(find.bySemanticsLabel('主页'));
    await tester.pumpAndSettle();

    expect(find.text('创建翻译任务'), findsOneWidget);
    expect(find.text('任务列表'), findsOneWidget);
  });

  testWidgets('外观设置切换到夜间后整体主题变暗', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('设置'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('夜间'));
    await tester.pumpAndSettle();

    expect(find.text('外观'), findsOneWidget);
    expect(
      Theme.of(tester.element(find.text('外观'))).brightness,
      Brightness.light,
    );

    await tester.tap(find.text('夜间'));
    await tester.pumpAndSettle();

    expect(
      Theme.of(tester.element(find.text('外观'))).brightness,
      Brightness.dark,
    );
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
