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
  List<JobSummary> additionalJobs = const [],
  Future<void> Function(JobSummary job)? onRetry,
  Future<void> Function()? onRefresh,
  http.Client? client,
  Size surfaceSize = const Size(900, 1200),
}) async {
  await tester.binding.setSurfaceSize(surfaceSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final api = ApiClient(
    // 渲染阶段不发请求，默认给个永远不该被调用的 client。
    client: client ?? MockClient((_) async => http.Response('不该发请求', 500)),
  )..apiToken = 'test-token';
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: JobListSection(
            api: api,
            jobs: [job, ...additionalJobs],
            onRefresh: onRefresh ?? () async {},
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

  testWidgets('失败的任务：显示重试按钮，不再展示单个删除按钮', (tester) async {
    await _pumpList(tester, _job(status: 'failed'));

    expect(find.text('重试'), findsOneWidget);
    expect(find.text('删除任务'), findsNothing);
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

  testWidgets('列表头部用清空按钮替代刷新按钮，执行前要求确认', (tester) async {
    var clearCallCount = 0;
    await _pumpList(
      tester,
      _job(status: 'failed'),
      client: MockClient((request) async {
        clearCallCount++;
        return http.Response('', 500);
      }),
    );

    expect(find.byTooltip('刷新任务列表'), findsNothing);
    expect(find.byTooltip('清空任务列表'), findsOneWidget);

    await tester.tap(find.byTooltip('清空任务列表'));
    await tester.pumpAndSettle();

    expect(find.text('清空任务列表'), findsOneWidget);
    expect(find.text('当前共 1 个已结束任务'), findsOneWidget);
    expect(clearCallCount, 0);

    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(clearCallCount, 0);
  });

  testWidgets('仅有排队或准备中的任务时禁用清空且不发请求', (tester) async {
    var clearCallCount = 0;
    await _pumpList(
      tester,
      _job(status: 'queued'),
      additionalJobs: [_job(status: 'preparing')],
      client: MockClient((request) async {
        clearCallCount++;
        return http.Response('', 500);
      }),
    );

    final clearButton = tester.widget<IconButton>(
      find
          .ancestor(
            of: find.byTooltip('没有可清理的已结束任务'),
            matching: find.byType(IconButton),
          )
          .first,
    );
    expect(clearButton.onPressed, isNull);
    expect(clearCallCount, 0);
  });

  testWidgets('混合任务时确认框只统计已结束任务并保留其他任务', (tester) async {
    await _pumpList(
      tester,
      _job(status: 'failed'),
      additionalJobs: [
        _job(status: 'completed'),
        _job(status: 'queued'),
        _job(status: 'translating'),
      ],
    );

    await tester.tap(find.byTooltip('清空任务列表'));
    await tester.pumpAndSettle();

    expect(find.text('当前共 2 个已结束任务'), findsOneWidget);
    expect(
      find.text('将清理所有已结束任务，并删除相应的源文件与译文产物。排队中和正在处理的任务会保留，该操作不可撤销。'),
      findsOneWidget,
    );
  });

  testWidgets('确认清空后删除任务并刷新列表', (tester) async {
    var refreshCount = 0;
    await _pumpList(
      tester,
      _job(status: 'failed'),
      client: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.toString(), '$baseUrl/api/jobs/cleanup');
        expect(request.headers['X-RetainPDF-Token'], 'test-token');
        expect(request.headers['content-type'], 'application/json');
        expect(request.body, '{"keep_latest":0}');
        return http.Response(
          '{"removed_count":1,"removed":["job-1"]}',
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
      onRefresh: () async => refreshCount++,
    );

    await tester.tap(find.byTooltip('清空任务列表'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '清空'));
    await tester.pumpAndSettle();

    expect(refreshCount, 1);
  });

  testWidgets('存在已完成任务时显示已完成徽标和批量选择按钮', (tester) async {
    await _pumpList(
      tester,
      JobSummary(
        jobId: 'job-1',
        filename: 'done.pdf',
        status: 'completed',
        step: 'completed',
        message: '全部完成',
        targetLanguage: 'zh-CN',
        pages: '1-3',
        skipPages: '',
        pageCount: 3,
        translatedPdfUrl: '/files/done.pdf',
      ),
      additionalJobs: [_job(status: 'translating')],
    );

    expect(find.text('1 个已完成'), findsOneWidget);
    expect(find.byTooltip('批量选择'), findsOneWidget);
    expect(find.byTooltip('批量下载已完成任务'), findsNothing);
    expect(find.text('查看 PDF'), findsOneWidget);
  });

  testWidgets('点击查看 PDF 按钮时请求下载并在出错时显示错误', (tester) async {
    await _pumpList(
      tester,
      JobSummary(
        jobId: 'job-1',
        filename: 'done.pdf',
        status: 'completed',
        step: 'completed',
        message: '全部完成',
        targetLanguage: 'zh-CN',
        pages: '1-3',
        skipPages: '',
        pageCount: 3,
        translatedPdfUrl: '/files/done.pdf',
      ),
      client: MockClient((request) async {
        return http.Response('Not Found', 404);
      }),
    );

    await tester.tap(find.text('查看 PDF'));
    await tester.pumpAndSettle();

    expect(find.textContaining('HTTP 404'), findsOneWidget);
  });

  testWidgets('开启批量选择模式后展示多选操作栏与 Checkbox 并支持全选/取消全选', (tester) async {
    await _pumpList(
      tester,
      JobSummary(
        jobId: 'job-1',
        filename: 'done1.pdf',
        status: 'completed',
        step: 'completed',
        message: '',
        targetLanguage: 'zh-CN',
        pages: '',
        skipPages: '',
        pageCount: 1,
        translatedPdfUrl: '/files/done1.pdf',
      ),
      additionalJobs: [
        JobSummary(
          jobId: 'job-2',
          filename: 'done2.pdf',
          status: 'completed',
          step: 'completed',
          message: '',
          targetLanguage: 'en',
          pages: '',
          skipPages: '',
          pageCount: 2,
          translatedPdfUrl: '/files/done2.pdf',
        ),
      ],
    );

    // 点击批量选择
    await tester.tap(find.byTooltip('批量选择'));
    await tester.pumpAndSettle();

    // 默认全选可下载任务
    expect(find.text('已选中 2 / 2 项'), findsOneWidget);
    expect(find.text('下载选中 (2)'), findsOneWidget);
    expect(find.text('删除 (2)'), findsOneWidget);
    expect(find.text('取消全选'), findsOneWidget);

    // 取消全选
    await tester.tap(find.text('取消全选'));
    await tester.pumpAndSettle();

    expect(find.text('已选中 0 / 2 项'), findsOneWidget);
    expect(find.text('全选'), findsOneWidget);
    expect(find.text('下载选中'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);

    // 重新全选
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();

    expect(find.text('已选中 2 / 2 项'), findsOneWidget);
    expect(find.text('下载选中 (2)'), findsOneWidget);
    expect(find.text('删除 (2)'), findsOneWidget);

    // 退出多选
    await tester.tap(find.byTooltip('退出多选'));
    await tester.pumpAndSettle();

    expect(find.text('已选中 2 / 2 项'), findsNothing);
  });

  testWidgets('批量删除任务：弹出确认框并在确认后调用 DELETE 接口', (tester) async {
    final deletedJobIds = <String>[];
    var refreshCount = 0;

    await _pumpList(
      tester,
      JobSummary(
        jobId: 'job-1',
        filename: 'done1.pdf',
        status: 'completed',
        step: 'completed',
        message: '',
        targetLanguage: 'zh-CN',
        pages: '',
        skipPages: '',
        pageCount: 1,
        translatedPdfUrl: '/files/done1.pdf',
      ),
      additionalJobs: [
        JobSummary(
          jobId: 'job-2',
          filename: 'failed2.pdf',
          status: 'failed',
          step: 'failed',
          message: '错误',
          targetLanguage: 'en',
          pages: '',
          skipPages: '',
          pageCount: 2,
          translatedPdfUrl: '',
        ),
      ],
      onRefresh: () async {
        refreshCount++;
      },
      client: MockClient((request) async {
        if (request.method == 'DELETE') {
          final uri = request.url.toString();
          final id = uri.substring(uri.lastIndexOf('/') + 1);
          deletedJobIds.add(id);
          return http.Response('', 204);
        }
        return http.Response('Not Found', 404);
      }),
    );

    // 开启批量选择
    await tester.tap(find.byTooltip('批量选择'));
    await tester.pumpAndSettle();

    expect(find.text('已选中 2 / 2 项'), findsOneWidget);
    expect(find.text('下载选中 (1)'), findsOneWidget);
    expect(find.text('删除 (2)'), findsOneWidget);

    // 点击删除按钮
    await tester.tap(find.text('删除 (2)'));
    await tester.pumpAndSettle();

    // 弹出确认弹窗
    expect(find.text('批量删除任务'), findsOneWidget);
    expect(find.textContaining('将删除选中的 2 个任务'), findsOneWidget);

    // 点击确认弹窗中的“删除”按钮
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(deletedJobIds, containsAll(['job-1', 'job-2']));
    expect(refreshCount, 1);
  });

  testWidgets('待处理任务开始运行后自动退出多选模式', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = ApiClient(
      client: MockClient((_) async => http.Response('不该发请求', 500)),
    )..apiToken = 'test-token';

    Widget buildList(JobSummary job) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: JobListSection(
            api: api,
            jobs: [job],
            onRefresh: () async {},
            onRetry: (_) async {},
          ),
        ),
      ),
    );

    await tester.pumpWidget(buildList(_job(status: 'queued')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('批量选择'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('退出多选'), findsWidgets);
    expect(find.byType(Checkbox), findsOneWidget);

    await tester.pumpWidget(buildList(_job(status: 'translating')));
    await tester.pumpAndSettle();

    expect(find.byTooltip('退出多选'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('最小窗口宽度下任务操作栏不会溢出', (tester) async {
    await _pumpList(
      tester,
      JobSummary(
        jobId: 'job-1',
        filename: 'done.pdf',
        status: 'completed',
        step: 'completed',
        message: '全部完成',
        targetLanguage: 'zh-CN',
        pages: '1-3',
        skipPages: '',
        pageCount: 3,
        translatedPdfUrl: '/files/done.pdf',
      ),
      surfaceSize: const Size(300, 1200),
    );

    expect(find.text('另存为…'), findsOneWidget);
    expect(find.text('查看 PDF'), findsOneWidget);

    await tester.tap(find.byTooltip('批量选择'));
    await tester.pumpAndSettle();

    expect(find.text('下载选中 (1)'), findsOneWidget);
    expect(find.text('删除 (1)'), findsOneWidget);
    expect(find.byTooltip('退出多选'), findsWidgets);
  });
}
