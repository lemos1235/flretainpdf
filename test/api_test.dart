import 'dart:convert';
import 'dart:io';

import 'package:flretainpdf/api/api_client.dart';
import 'package:flretainpdf/jobs/job_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// API 请求现在要求启动令牌；测试 client 不经过 BackendService，需显式注入。
ApiClient _testApi({required http.Client client}) =>
    ApiClient(client: client)..apiToken = 'test-token';

void main() {
  test('列表解析出各字段与产物地址，并附带鉴权头', () async {
    final api = _testApi(
      client: MockClient((request) async {
        expect(request.url.toString(), '$baseUrl/api/jobs');
        expect(request.headers['X-RetainPDF-Token'], 'test-token');
        return http.Response(
          jsonEncode([
            {
              'job_id': 'j1',
              'filename': 'a.pdf',
              'status': 'translating',
              'step': 'translating',
              'message': '已完成 1/3 个单元',
              'target_language': 'zh-CN',
              'pages': '1-3',
              'skip_pages': '',
              'page_count': 3,
              'artifacts': {'translated_pdf_url': '/files/j1.pdf'},
            },
          ]),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final jobs = await api.fetchJobs();
    expect(jobs.single.jobId, 'j1');
    expect(jobs.single.pageCount, 3);
    expect(jobs.single.translatedPdfUrl, '/files/j1.pdf');
    // 后端给的是相对路径，要能拼回可打开的绝对地址。
    expect(
      resolveArtifactUri(jobs.single.translatedPdfUrl).toString(),
      '$baseUrl/files/j1.pdf',
    );
  });

  test('读取服务端配置解析各字段', () async {
    final api = _testApi(
      client: MockClient((request) async {
        expect(request.url.toString(), '$baseUrl/api/config');
        expect(request.headers['X-RetainPDF-Token'], 'test-token');
        return http.Response(
          jsonEncode({
            'translation_default_target_language': 'zh-CN',
            'translation_model': 'gpt-4o',
            'translation_base_url': 'https://api.openai.com/v1',
            'table_recognition_base_url': 'http://table.test',
            'table_recognition_flavor': 'lattice',
            'mineru_base_url': 'http://mineru.test',
            'max_concurrent_tasks': 4,
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final config = await api.fetchConfig();
    expect(config.translationDefaultTargetLanguage, 'zh-CN');
    expect(config.translationModel, 'gpt-4o');
    expect(config.translationBaseUrl, 'https://api.openai.com/v1');
    expect(config.tableRecognitionBaseUrl, 'http://table.test');
    expect(config.tableRecognitionFlavor, 'lattice');
    expect(config.mineruBaseUrl, 'http://mineru.test');
    expect(config.maxConcurrentTasks, 4);
  });

  test('重试任务发送 JSON POST 并解析返回', () async {
    final api = _testApi(
      client: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.toString(), '$baseUrl/api/jobs/j1/retry');
        expect(request.headers['X-RetainPDF-Token'], 'test-token');
        expect(request.headers['content-type'], contains('application/json'));
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['pages'], '1-5');
        return http.Response(
          jsonEncode({
            'job_id': 'j1',
            'filename': 'a.pdf',
            'status': 'pending',
            'step': 'pending',
            'message': '排队中',
            'target_language': 'zh-CN',
            'pages': '1-5',
            'skip_pages': '',
            'page_count': 5,
            'artifacts': {},
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final job = await api.retryJob('j1', {'pages': '1-5'});
    expect(job.jobId, 'j1');
    expect(job.status, 'pending');
    expect(job.pages, '1-5');
  });

  test('创建任务以 multipart 发送文件与字段并返回 job_id', () async {
    final tempDir = Directory.systemTemp.createTempSync('flretainpdf_test_');
    final tempFile = File('${tempDir.path}/sample.pdf')
      ..writeAsBytesSync(utf8.encode('%PDF-1.4 test'));
    addTearDown(() => tempDir.deleteSync(recursive: true));

    final api = _testApi(
      client: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.toString(), '$baseUrl/api/jobs');
        expect(request.headers['X-RetainPDF-Token'], 'test-token');
        expect(
          request.headers['content-type'],
          contains('multipart/form-data'),
        );
        return http.Response(
          jsonEncode({'job_id': 'job-new-123'}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final jobId = await api.createJob(
      filePath: tempFile.path,
      fields: {'translation_target_language': 'zh-CN'},
    );
    expect(jobId, 'job-new-123');
  });

  test('失败响应用 body 里的 error 当提示', () async {
    final api = _testApi(
      client: MockClient(
        (request) async => http.Response(
          jsonEncode({'error': '页码超出文档范围'}),
          400,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );

    expect(
      () => api.fetchJobs(),
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('页码超出文档范围'),
        ),
      ),
    );
  });

  test('清空任务调用 cleanup 接口并要求不保留历史任务', () async {
    final api = _testApi(
      client: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.toString(), '$baseUrl/api/jobs/cleanup');
        expect(request.headers['X-RetainPDF-Token'], 'test-token');
        expect(request.headers['content-type'], 'application/json');
        expect(jsonDecode(request.body), {'keep_latest': 0});
        return http.Response(
          jsonEncode({
            'removed_count': 2,
            'removed': ['j1', 'j2'],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    expect(await api.clearJobs(), 2);
  });

  test('删除任务发 DELETE 到带 id 的地址', () async {
    var called = 0;
    final api = _testApi(
      client: MockClient((request) async {
        called++;
        expect(request.method, 'DELETE');
        expect(request.url.toString(), '$baseUrl/api/jobs/j%201');
        expect(request.headers['X-RetainPDF-Token'], 'test-token');
        return http.Response('', 204);
      }),
    );

    // 204 空 body 也要当成功，不能因为解析不出 JSON 就报错。
    await api.deleteJob('j 1');
    expect(called, 1);
  });

  test('删除失败用 body 里的 error 当提示', () async {
    final api = _testApi(
      client: MockClient(
        (request) async => http.Response(
          jsonEncode({'error': '任务仍在处理中'}),
          409,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );

    await expectLater(
      api.deleteJob('j1'),
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('任务仍在处理中'),
        ),
      ),
    );
  });

  test('multipart 只发送勾选的开关，且值为 on', () {
    final settings = JobSettingsController();
    settings.formulaRecognitionEnabled = true;

    final fields = settings.toMultipartFields();
    expect(fields['formula_recognition_enabled'], 'on');
    // 没勾的开关完全不出现在请求里，与 HTML 表单的行为一致。
    expect(fields.containsKey('table_recognition_enabled'), isFalse);
    expect(fields.containsKey('ocr_enabled'), isFalse);
    expect(fields['extract_backend'], 'native');

    settings.dispose();
  });
}
