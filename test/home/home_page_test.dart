import 'package:flretainpdf/api/api_client.dart';
import 'package:flretainpdf/home/home_page.dart';
import 'package:flretainpdf/prefs_scope.dart';
import 'package:flretainpdf/settings/app_settings.dart';
import 'package:flretainpdf/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _config = AppConfig(
  translationDefaultTargetLanguage: 'zh-CN',
  translationModel: 'test-model',
  translationBaseUrl: 'http://translator.test',
  mineruBaseUrl: '',
  maxConcurrentTasks: 2,
);

JobSummary _job(String jobId, {required String status, String compare = ''}) {
  return JobSummary(
    jobId: jobId,
    filename: '$jobId.pdf',
    status: status,
    step: status,
    message: '',
    targetLanguage: 'zh-CN',
    pages: '',
    skipPages: '',
    pageCount: 1,
    translatedPdfUrl: status == 'completed' ? '/files/$jobId.pdf' : '',
    comparePdfUrl: compare,
  );
}

class _FakeApi extends ApiClient {
  _FakeApi(this.jobs);

  /// 轮询返回的任务列表，测试里可以改它来模拟任务状态变化。
  List<JobSummary> jobs;
  final List<String> compareCalls = [];

  /// 非 null 时 [generateComparePdf] 抛这个状态码的 [ApiException]，用来分别
  /// 模拟可重试（409）和不可重试（404）的失败。
  int? compareFailStatus;

  @override
  Future<AppConfig> fetchConfig() async => _config;

  @override
  Future<List<JobSummary>> fetchJobs() async => jobs;

  @override
  Future<ComparePdfResult> generateComparePdf(String jobId) async {
    compareCalls.add(jobId);
    final status = compareFailStatus;
    if (status != null) {
      throw ApiException(status, '生成对照 PDF 失败');
    }
    return ComparePdfResult(
      comparePdfUrl: '/api/jobs/$jobId/artifacts/compare',
      pageCount: 1,
      generated: true,
    );
  }
}

Future<void> _pumpHome(WidgetTester tester, _FakeApi api) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final settings = AppSettings();
  addTearDown(settings.dispose);
  addTearDown(api.close);

  await tester.binding.setSurfaceSize(const Size(1200, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    PrefsScope(
      prefs: prefs,
      child: AppSettingsScope(
        settings: settings,
        child: MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(body: HomePage(api: api)),
        ),
      ),
    ),
  );
  // HomePage 上挂着 3 秒的轮询定时器，pumpAndSettle 会一直等不到静止。
  await tester.pump();
  await tester.pump();
}

/// 卸载 HomePage，停掉轮询定时器，否则测试结束时会报「仍有 Timer 未完成」。
Future<void> _disposeHome(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
}

void main() {
  testWidgets('任务完成后自动合成对照 PDF，同一任务只触发一次', (tester) async {
    final api = _FakeApi([_job('job-1', status: 'translating')]);
    await _pumpHome(tester, api);

    // 还没跑完的任务不合成。
    expect(api.compareCalls, isEmpty);

    api.jobs = [_job('job-1', status: 'completed')];
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(api.compareCalls, ['job-1']);

    // 后续轮询里服务端还没把地址带回来，也不能重复 POST。
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(api.compareCalls, ['job-1']);

    await _disposeHome(tester);
  });

  testWidgets('已有对照件的任务不再合成，且一轮最多触发三个', (tester) async {
    final api = _FakeApi([
      _job('done', status: 'completed', compare: '/files/done-compare.pdf'),
      _job('job-1', status: 'completed'),
      _job('job-2', status: 'completed'),
      _job('job-3', status: 'completed'),
      _job('job-4', status: 'completed'),
    ]);
    await _pumpHome(tester, api);

    expect(api.compareCalls, ['job-1', 'job-2', 'job-3']);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(api.compareCalls, ['job-1', 'job-2', 'job-3', 'job-4']);

    await _disposeHome(tester);
  });

  testWidgets('合成成功后立刻显示对照 PDF 按钮，不用等下一轮轮询', (tester) async {
    final api = _FakeApi([_job('job-1', status: 'completed')]);
    await _pumpHome(tester, api);

    // 服务端同步返回地址，本地列表当场补上，无需推进 3 秒的轮询定时器。
    expect(api.compareCalls, ['job-1']);
    expect(find.text('对照 PDF'), findsOneWidget);

    await _disposeHome(tester);
  });

  testWidgets('任务尚未完成这类 404 不重试，重试没有意义', (tester) async {
    final api = _FakeApi([_job('job-1', status: 'completed')])
      ..compareFailStatus = 404;
    await _pumpHome(tester, api);
    expect(api.compareCalls, ['job-1']);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(api.compareCalls, ['job-1']);

    await _disposeHome(tester);
  });

  testWidgets('409 这类瞬时失败下一轮轮询会重试，连续失败到顶后不再重试', (tester) async {
    final api = _FakeApi([_job('job-1', status: 'completed')])
      ..compareFailStatus = 409;
    await _pumpHome(tester, api);
    expect(api.compareCalls, ['job-1']);

    // 瞬时失败要放回队列：下一轮轮询再试一次。
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(api.compareCalls, ['job-1', 'job-1']);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(api.compareCalls, ['job-1', 'job-1', 'job-1']);

    // 三次都失败后不再自动重试，免得轮询反复砸服务端。
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(api.compareCalls, ['job-1', 'job-1', 'job-1']);

    await _disposeHome(tester);
  });

  testWidgets('一轮里失败的任务不会挤掉其他任务的名额', (tester) async {
    final api = _FakeApi([
      _job('job-1', status: 'completed'),
      _job('job-2', status: 'completed'),
    ])..compareFailStatus = 409;
    await _pumpHome(tester, api);

    expect(api.compareCalls, ['job-1', 'job-2']);

    await _disposeHome(tester);
  });

  testWidgets('任务重新跑起来后允许再合成一次', (tester) async {
    final api = _FakeApi([_job('job-1', status: 'completed')]);
    await _pumpHome(tester, api);
    expect(api.compareCalls, ['job-1']);

    api.jobs = [_job('job-1', status: 'translating')];
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    api.jobs = [_job('job-1', status: 'completed')];
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(api.compareCalls, ['job-1', 'job-1']);

    await _disposeHome(tester);
  });
}
