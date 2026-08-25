import 'dart:convert';

import 'package:flretainpdf/api/api_client.dart';
import 'package:flretainpdf/jobs/job_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('列表解析出各字段与产物地址', () async {
    final api = ApiClient(
      client: MockClient((request) async {
        expect(request.url.toString(), '$baseUrl/api/jobs');
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

  test('失败响应用 body 里的 error 当提示', () async {
    final api = ApiClient(
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

  test('删除任务发 DELETE 到带 id 的地址', () async {
    var called = 0;
    final api = ApiClient(
      client: MockClient((request) async {
        called++;
        expect(request.method, 'DELETE');
        expect(request.url.toString(), '$baseUrl/api/jobs/j%201');
        return http.Response('', 204);
      }),
    );

    // 204 空 body 也要当成功，不能因为解析不出 JSON 就报错。
    await api.deleteJob('j 1');
    expect(called, 1);
  });

  test('删除失败用 body 里的 error 当提示', () async {
    final api = ApiClient(
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
