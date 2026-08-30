import 'package:flretainpdf/api/api_client.dart';
import 'package:flretainpdf/jobs/job_form_section.dart';
import 'package:flretainpdf/prefs_scope.dart';
import 'package:flretainpdf/settings/app_settings.dart';
import 'package:flretainpdf/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _config = AppConfig(
  translationDefaultTargetLanguage: 'zh-CN',
  translationModel: 'test-model',
  translationBaseUrl: 'http://translator.test',
  tableRecognitionBaseUrl: '',
  tableRecognitionFlavor: 'lattice',
  mineruBaseUrl: '',
  maxConcurrentTasks: 2,
);

class _FakeApi extends ApiClient {
  _FakeApi({this.failPaths = const {}});

  final Set<String> failPaths;
  final List<String> createdPaths = [];

  @override
  Future<AppConfig> fetchConfig() async => _config;

  @override
  Future<String> createJob({
    required String filePath,
    required Map<String, String> fields,
  }) async {
    createdPaths.add(filePath);
    if (failPaths.contains(filePath)) {
      throw Exception('上传失败');
    }
    return 'job-${createdPaths.length}';
  }
}

SelectedPdf _pdf(String path, int size) =>
    SelectedPdf(path: path, name: path.split('/').last, size: size);

Future<JobFormSectionState> _pumpForm(
  WidgetTester tester,
  _FakeApi api, {
  required Future<void> Function() onJobCreated,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final settings = AppSettings();
  addTearDown(settings.dispose);
  addTearDown(api.close);

  await tester.binding.setSurfaceSize(const Size(500, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    PrefsScope(
      prefs: prefs,
      child: AppSettingsScope(
        settings: settings,
        child: MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: SingleChildScrollView(
              child: JobFormSection(api: api, onJobCreated: onJobCreated),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return tester.state<JobFormSectionState>(find.byType(JobFormSection));
}

void main() {
  test('mergeSelectedPdfs 只保留 PDF 并按路径去重', () {
    final merged = mergeSelectedPdfs(
      [_pdf('/a.pdf', 10)],
      [_pdf('/b.pdf', 20), _pdf('/a.pdf', 99), _pdf('/note.txt', 30)],
    );
    expect(merged.map((file) => file.path), ['/a.pdf', '/b.pdf']);
    expect(merged.first.size, 10);
  });

  testWidgets('文件选择区支持展示、移除和清空', (tester) async {
    final state = await _pumpForm(
      tester,
      _FakeApi(),
      onJobCreated: () async {},
    );

    state.addFiles([_pdf('/a.pdf', 1024), _pdf('/b.pdf', 1536)]);
    await tester.pump();

    expect(find.text('已选择 2 个文件 · 共 2.5 KB'), findsOneWidget);
    expect(find.text('a.pdf'), findsOneWidget);
    expect(find.text('b.pdf'), findsOneWidget);

    // 点击第一个文件的删除图标
    await tester.tap(find.byIcon(LucideIcons.x).first);
    await tester.pump();
    expect(state.selectedFiles.map((file) => file.path), ['/b.pdf']);

    await tester.tap(find.text('清空'));
    await tester.pump();
    expect(state.selectedFiles, isEmpty);
  });

  testWidgets('批量提交任务并在失败时保留失败项', (tester) async {
    final api = _FakeApi(failPaths: {'/b.pdf'});
    var refreshCount = 0;
    final state = await _pumpForm(
      tester,
      api,
      onJobCreated: () async => refreshCount++,
    );
    state.addFiles([
      _pdf('/a.pdf', 10),
      _pdf('/b.pdf', 20),
      _pdf('/c.pdf', 30),
    ]);
    await tester.pump();

    await tester.tap(find.text('开始翻译'));
    await tester.pumpAndSettle();

    expect(api.createdPaths, ['/a.pdf', '/b.pdf', '/c.pdf']);
    expect(state.selectedFiles.map((file) => file.path), ['/b.pdf']);
    expect(refreshCount, 1);
  });

  testWidgets('buildRetryFields 在页码合法时返回参数，非法时抛出异常', (tester) async {
    final api = _FakeApi();
    final state = await _pumpForm(tester, api, onJobCreated: () async {});

    final pagesInput = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText == '例如 1-10,11,13 或 5-',
    );
    await tester.enterText(pagesInput, '1-3');
    await tester.pump();

    final retryFields = state.buildRetryFields();
    expect(retryFields['pages'], '1-3');
    expect(retryFields['translation_target_language'], 'zh-CN');

    await tester.enterText(pagesInput, '5-2');
    await tester.pump();

    expect(() => state.buildRetryFields(), throwsA(isA<Exception>()));
  });
}
