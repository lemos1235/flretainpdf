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
              'artifacts': {
                'translated_pdf_url': '/files/j1.pdf',
                'compare_pdf_url': '/files/j1-compare.pdf',
              },
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
    expect(jobs.single.comparePdfUrl, '/files/j1-compare.pdf');
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

  test('合成对照 PDF 发 POST 到带 id 的地址，同步拿回产物地址', () async {
    var called = 0;
    final okApi = _testApi(
      client: MockClient((request) async {
        called++;
        expect(request.method, 'POST');
        expect(request.url.toString(), '$baseUrl/api/jobs/j%201/compare');
        expect(request.headers['X-RetainPDF-Token'], 'test-token');
        return http.Response(
          jsonEncode({
            'compare_pdf_url': '/api/jobs/j 1/artifacts/compare',
            'page_count': 3,
            'generated': true,
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final result = await okApi.generateComparePdf('j 1');
    expect(called, 1);
    expect(result.comparePdfUrl, '/api/jobs/j 1/artifacts/compare');
    expect(result.pageCount, 3);
    expect(result.generated, isTrue);

    // 失败时用 body 里的 error 当提示，并保留状态码：调用方要靠它区分
    // 「重试没意义」（404）和「值得再试」（409、5xx）。
    final failingApi = _testApi(
      client: MockClient(
        (request) async => http.Response(
          jsonEncode({'error': '任务尚未完成，无法生成对照 PDF'}),
          404,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );

    await expectLater(
      failingApi.generateComparePdf('j1'),
      throwsA(
        isA<ApiException>()
            .having((e) => e.statusCode, 'statusCode', 404)
            .having((e) => e.message, 'message', contains('任务尚未完成')),
      ),
    );
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

  test('批量删除按服务端上限分批发送并合并各批结果', () async {
    final batches = <List<String>>[];
    final api = _testApi(
      client: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.toString(), '$baseUrl/api/jobs/batch-delete');
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        final ids = (payload['job_ids'] as List).cast<String>();
        batches.add(ids);
        // 每批的最后一个当成删不掉的，用来验证失败项也会跨批累加。
        final failedId = ids.last;
        final deleted = ids.sublist(0, ids.length - 1);
        return http.Response(
          jsonEncode({
            'deleted_count': deleted.length,
            'deleted': deleted,
            'failed_count': 1,
            'failed': [
              {'job_id': failedId, 'reason': '任务还在处理中，无法删除'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final ids = List.generate(maxBatchDeleteIds + 5, (i) => 'job-$i');
    final result = await api.batchDeleteJobs(ids);

    expect(batches.length, 2);
    expect(batches.first.length, maxBatchDeleteIds);
    expect(batches.last.length, 5);
    expect(result.deletedCount, ids.length - 2);
    expect(result.failedCount, 2);
    expect(result.failed.first.reason, '任务还在处理中，无法删除');
  });

  test('批量删除的空列表不发请求：服务端对空 job_ids 是 400，但这不该算错误', () async {
    var called = 0;
    final api = _testApi(
      client: MockClient((request) async {
        called++;
        return http.Response('{}', 200);
      }),
    );

    final result = await api.batchDeleteJobs(const []);
    expect(called, 0);
    expect(result.deletedCount, 0);
    expect(result.failedCount, 0);
  });

  test('multipart 只发送勾选且当前方案支持的开关，且值为 on', () {
    final settings = JobSettingsController();
    settings.extractBackend = 'mineru';
    settings.formulaRecognitionEnabled = true;
    settings.tableRecognitionEnabled = true;

    var fields = settings.toMultipartFields();
    expect(fields['formula_recognition_enabled'], 'on');
    expect(fields['table_recognition_enabled'], 'on');
    // 没勾的开关完全不出现在请求里，与 HTML 表单的行为一致。
    expect(fields.containsKey('ocr_enabled'), isFalse);
    expect(fields['extract_backend'], 'mineru');
    expect(fields.containsKey('table_recognition_base_url'), isFalse);
    expect(fields.containsKey('table_recognition_flavor'), isFalse);

    // 桌面端原生模式不发送公式、表格、OCR 等 MinerU 识别字段。
    settings.extractBackend = 'native';
    fields = settings.toMultipartFields();
    expect(fields.containsKey('formula_recognition_enabled'), isFalse);
    expect(fields.containsKey('table_recognition_enabled'), isFalse);
    expect(fields.containsKey('ocr_enabled'), isFalse);
    expect(fields['extract_backend'], 'native');

    final retryFields = settings.toRetryFields();
    expect(retryFields['formula_recognition_enabled'], isFalse);
    expect(retryFields['table_recognition_enabled'], isFalse);
    expect(retryFields['ocr_enabled'], isFalse);
    expect(retryFields.containsKey('table_recognition_base_url'), isFalse);
    expect(retryFields.containsKey('table_recognition_flavor'), isFalse);

    settings.dispose();
  });
}
