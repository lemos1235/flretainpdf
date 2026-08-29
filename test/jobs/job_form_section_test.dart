import 'dart:async';
import 'dart:io';

import 'package:flretainpdf/api/api_client.dart';
import 'package:flretainpdf/jobs/job_form_section.dart';
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
  tableRecognitionBaseUrl: '',
  tableRecognitionFlavor: 'lattice',
  mineruBaseUrl: '',
  maxConcurrentTasks: 2,
);

class _FakeApi extends ApiClient {
  _FakeApi({this.failPaths = const {}, this.createGate});

  final Set<String> failPaths;
  final Completer<void>? createGate;
  final List<String> createdPaths = [];
  final List<Map<String, String>> createdFields = [];

  @override
  Future<AppConfig> fetchConfig() async => _config;

  @override
  Future<String> createJob({
    required String filePath,
    required Map<String, String> fields,
  }) async {
    createdPaths.add(filePath);
    createdFields.add(Map.of(fields));
    await createGate?.future;
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
  test('追加文件时只保留 PDF，按路径去重并保持首次加入顺序', () {
    final merged = mergeSelectedPdfs(
      [_pdf('/a.pdf', 10)],
      [
        _pdf('/b.pdf', 20),
        _pdf('/a.pdf', 99),
        _pdf('/note.txt', 30),
        _pdf('/C.PDF', 40),
      ],
    );

    expect(merged.map((file) => file.path), ['/a.pdf', '/b.pdf', '/C.PDF']);
    expect(merged.first.size, 10);
  });

  test('mergeSelectedPdfs 按当前平台的路径语义去重', () {
    final merged = mergeSelectedPdfs(
      [_pdf(r'C:\docs\a.pdf', 10)],
      [
        _pdf('C:/docs/a.pdf', 20),
        _pdf(r'C:\docs\A.PDF', 30),
        _pdf(r'C:\docs\b.pdf', 40),
      ],
    );

    final expected = Platform.isWindows
        ? [r'C:\docs\a.pdf', r'C:\docs\b.pdf']
        : [
            r'C:\docs\a.pdf',
            'C:/docs/a.pdf',
            r'C:\docs\A.PDF',
            r'C:\docs\b.pdf',
          ];
    expect(merged.map((file) => file.path), expected);
    expect(merged.first.size, 10);
  });

  testWidgets('文件区显示汇总，支持逐项移除和清空', (tester) async {
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
    expect(find.text('继续添加文件'), findsOneWidget);

    await tester.tap(find.byTooltip('移除 a.pdf'));
    await tester.pump();
    expect(state.selectedFiles.map((file) => file.path), ['/b.pdf']);
    expect(find.text('已选择 1 个文件 · 共 1.5 KB'), findsOneWidget);

    await tester.tap(find.text('清空'));
    await tester.pump();
    expect(state.selectedFiles, isEmpty);
    expect(find.text('点击或拖入多个 PDF 文件'), findsOneWidget);
  });

  testWidgets('批量提交按顺序继续处理失败项，并只保留失败文件', (tester) async {
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
    expect(api.createdFields, hasLength(3));
    expect(api.createdFields, everyElement(equals(api.createdFields.first)));
    expect(state.selectedFiles.map((file) => file.path), ['/b.pdf']);
    expect(refreshCount, 1);
    expect(find.textContaining('成功创建 2 个任务，1 个失败：b.pdf：上传失败'), findsOneWidget);
  });

  testWidgets('提交期间禁用文件列表操作', (tester) async {
    final gate = Completer<void>();
    final api = _FakeApi(createGate: gate);
    final state = await _pumpForm(tester, api, onJobCreated: () async {});
    state.addFiles([_pdf('/a.pdf', 10)]);
    await tester.pump();

    await tester.tap(find.text('开始翻译'));
    await tester.pump();

    expect(find.text('正在创建…'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '清空'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '继续添加文件'))
          .onPressed,
      isNull,
    );
    final removeButton = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '移除 a.pdf',
    );
    expect(tester.widget<IconButton>(removeButton).onPressed, isNull);

    gate.complete();
    await tester.pumpAndSettle();
    expect(state.selectedFiles, isEmpty);
  });

  testWidgets('未选择文件时不创建任务', (tester) async {
    final api = _FakeApi();
    await _pumpForm(tester, api, onJobCreated: () async {});

    await tester.tap(find.text('开始翻译'));
    await tester.pump();

    expect(api.createdPaths, isEmpty);
    expect(find.text('请先选择 PDF 文件。'), findsOneWidget);
  });

  testWidgets('页码格式非法时阻止提交并显示错误提示', (tester) async {
    final api = _FakeApi();
    final state = await _pumpForm(tester, api, onJobCreated: () async {});
    state.addFiles([_pdf('/a.pdf', 10)]);
    await tester.pump();

    // 找到包含提示为“例如 1-10,11,13 或 5-”的输入框并输入非法范围
    final pagesInput = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText == '例如 1-10,11,13 或 5-',
    );
    expect(pagesInput, findsOneWidget);
    await tester.enterText(pagesInput, '5-2');
    await tester.pump();

    await tester.tap(find.text('开始翻译'));
    await tester.pump();

    expect(api.createdPaths, isEmpty);
    expect(find.textContaining('起始页不能大于结束页'), findsOneWidget);
  });

  testWidgets('buildRetryFields 在页码合法时返回合并字段，非法时抛出异常', (tester) async {
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

    await tester.enterText(pagesInput, 'bad-page');
    await tester.pump();

    expect(() => state.buildRetryFields(), throwsA(isA<Exception>()));
  });
}
