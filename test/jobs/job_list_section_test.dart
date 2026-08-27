import 'package:flretainpdf/api/api_client.dart';
import 'package:flretainpdf/jobs/job_list_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

JobSummary _job({required String status, String message = ''}) {
  return JobSummary(
    jobId: 'job-1',
    filename: 'a.pdf',
    status: status,
    step: status,
    message: message,
    targetLanguage: 'zh-CN',
    pages: '',
    skipPages: '',
    pageCount: null,
    translatedPdfUrl: '',
  );
}

Future<void> _pumpList(
  WidgetTester tester,
  JobSummary job, {
  Future<void> Function(JobSummary job)? onRetry,
}) async {
  await tester.binding.setSurfaceSize(const Size(900, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: JobListSection(
            // 渲染阶段不发请求，给个永远不该被调用的 client。
            api: ApiClient(
              client: MockClient(
                (_) async => http.Response('不该发请求', 500),
              ),
            ),
            jobs: [job],
            onRefresh: () async {},
            onRetry: onRetry ?? (_) async {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('排队等槽位的任务：徽标和按钮都说「排队 / 取消」', (tester) async {
    await _pumpList(tester, _job(status: 'queued'));

    expect(find.text('排队中'), findsOneWidget);
    expect(find.text('1 个排队中'), findsOneWidget);
    expect(find.text('取消任务'), findsOneWidget);
    expect(find.text('删除任务'), findsNothing);
  });

  testWidgets('刚建好的任务能取消，但不算在排队计数里', (tester) async {
    await _pumpList(tester, _job(status: 'preparing'));

    // 它并没有在等槽位，右上角徽标和排队计数都不该说「排队」，
    // 但删除即取消这一点和 queued 一样。
    expect(find.text('准备中'), findsWidgets);
    expect(find.text('排队中'), findsNothing);
    expect(find.text('1 个排队中'), findsNothing);
    expect(find.text('取消任务'), findsOneWidget);
    expect(find.text('删除任务'), findsNothing);
  });

  testWidgets('跑起来的任务两个按钮都不给', (tester) async {
    await _pumpList(tester, _job(status: 'translating'));

    expect(find.text('取消任务'), findsNothing);
    expect(find.text('删除任务'), findsNothing);
  });

  testWidgets('失败的任务：显示重试按钮', (tester) async {
    await _pumpList(tester, _job(status: 'failed'));

    expect(find.text('重试'), findsOneWidget);
    expect(find.text('删除任务'), findsOneWidget);
  });

  testWidgets('重试失败时把错误显示在卡片上，而不是静默吞掉', (tester) async {
    await _pumpList(
      tester,
      _job(status: 'failed'),
      onRetry: (_) async {
        throw Exception('页码格式不对');
      },
    );

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.text('页码格式不对'), findsOneWidget);
    // 按钮状态要复位，不能卡在「正在重试…」。
    expect(find.text('重试'), findsOneWidget);
  });
}
