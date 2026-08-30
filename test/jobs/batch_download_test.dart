import 'dart:io';
import 'dart:typed_data';

import 'package:flretainpdf/api/api_client.dart';
import 'package:flretainpdf/jobs/batch_download.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

JobSummary _createJob({
  required String jobId,
  required String filename,
  required String status,
  required String url,
  String targetLang = 'zh-CN',
}) {
  return JobSummary(
    jobId: jobId,
    filename: filename,
    status: status,
    step: status,
    message: '',
    targetLanguage: targetLang,
    pages: '',
    skipPages: '',
    pageCount: 1,
    translatedPdfUrl: url,
  );
}

void main() {
  group('suggestPdfFileName', () {
    test('生成带目标语言后缀的文件名', () {
      final job = _createJob(
        jobId: '1',
        filename: 'report.pdf',
        status: 'completed',
        url: '/files/1.pdf',
        targetLang: 'zh-CN',
      );
      expect(suggestPdfFileName(job), 'report-zh-CN.pdf');
    });

    test('空语言时使用 -translated 后缀', () {
      final job = _createJob(
        jobId: '1',
        filename: 'data.pdf',
        status: 'completed',
        url: '/files/1.pdf',
        targetLang: '',
      );
      expect(suggestPdfFileName(job), 'data-translated.pdf');
    });

    test('过滤文件名中的非法字符', () {
      final job = _createJob(
        jobId: '1',
        filename: 'sample:test/doc?.pdf',
        status: 'completed',
        url: '/files/1.pdf',
        targetLang: 'en:US',
      );
      expect(suggestPdfFileName(job), 'sample_test_doc_-en_US.pdf');
    });

    test('文件名仅为 .pdf 或空格时退回 translated 避免以连字符开头', () {
      final dotPdf = _createJob(
        jobId: '1',
        filename: '.pdf',
        status: 'completed',
        url: '/files/1.pdf',
        targetLang: 'zh-CN',
      );
      expect(suggestPdfFileName(dotPdf), 'translated-zh-CN.pdf');

      final spacePdf = _createJob(
        jobId: '2',
        filename: '   .pdf',
        status: 'completed',
        url: '/files/2.pdf',
        targetLang: 'en',
      );
      expect(suggestPdfFileName(spacePdf), 'translated-en.pdf');
    });
  });

  group('resolveUniqueFile', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('batch_download_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('文件不存在时直接使用原名', () {
      final file = resolveUniqueFile(tempDir.path, 'out.pdf');
      expect(file.path, equals('${tempDir.path}${Platform.pathSeparator}out.pdf'));
    });

    test('文件存在时自动追加递增序号', () {
      final first = File('${tempDir.path}${Platform.pathSeparator}out.pdf');
      first.writeAsStringSync('1');

      final second = resolveUniqueFile(tempDir.path, 'out.pdf');
      expect(
        second.path,
        equals('${tempDir.path}${Platform.pathSeparator}out (1).pdf'),
      );
      second.writeAsStringSync('2');

      final third = resolveUniqueFile(tempDir.path, 'out.pdf');
      expect(
        third.path,
        equals('${tempDir.path}${Platform.pathSeparator}out (2).pdf'),
      );
    });

    test('路径末尾包含分隔符时不会生成双重分隔符', () {
      final pathWithTrailingSeparator = '${tempDir.path}${Platform.pathSeparator}';
      final file = resolveUniqueFile(pathWithTrailingSeparator, 'single.pdf');
      expect(
        file.path,
        equals('${tempDir.path}${Platform.pathSeparator}single.pdf'),
      );
    });
  });

  group('runBatchDownload', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('batch_download_run_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('成功下载所有已完成文件并触发进度回调', () async {
      final jobs = [
        _createJob(
          jobId: '1',
          filename: 'doc1.pdf',
          status: 'completed',
          url: '/files/doc1.pdf',
        ),
        _createJob(
          jobId: '2',
          filename: 'doc2.pdf',
          status: 'completed',
          url: '/files/doc2.pdf',
        ),
        _createJob(
          jobId: '3',
          filename: 'doc3.pdf',
          status: 'failed',
          url: '',
        ),
      ];

      final progressList = <String>[];
      final api = ApiClient(
        client: MockClient((request) async {
          return http.Response.bytes(
            Uint8List.fromList([1, 2, 3, 4]),
            200,
          );
        }),
      )..apiToken = 'token';

      final result = await runBatchDownload(
        api: api,
        jobs: jobs,
        targetDirectory: tempDir.path,
        onProgress: (current, total, filename) {
          progressList.add('$current/$total: $filename');
        },
      );

      expect(result.total, 2);
      expect(result.succeeded, 2);
      expect(result.failed, 0);
      expect(result.isAllSuccess, isTrue);
      expect(progressList.length, 2);
      expect(File('${tempDir.path}${Platform.pathSeparator}doc1-zh-CN.pdf').existsSync(), isTrue);
      expect(File('${tempDir.path}${Platform.pathSeparator}doc2-zh-CN.pdf').existsSync(), isTrue);
    });

    test('部分失败时记录错误并继续处理其余文件', () async {
      final jobs = [
        _createJob(
          jobId: '1',
          filename: 'doc1.pdf',
          status: 'completed',
          url: '/files/doc1.pdf',
        ),
        _createJob(
          jobId: '2',
          filename: 'doc2.pdf',
          status: 'completed',
          url: '/files/doc2.pdf',
        ),
      ];

      final api = ApiClient(
        client: MockClient((request) async {
          if (request.url.path.contains('doc1')) {
            return http.Response('Not Found', 404);
          }
          return http.Response.bytes(Uint8List.fromList([1, 2]), 200);
        }),
      )..apiToken = 'token';

      final result = await runBatchDownload(
        api: api,
        jobs: jobs,
        targetDirectory: tempDir.path,
      );

      expect(result.total, 2);
      expect(result.succeeded, 1);
      expect(result.failed, 1);
      expect(result.errors.length, 1);
      expect(result.errors.first, contains('doc1.pdf'));
      expect(File('${tempDir.path}${Platform.pathSeparator}doc2-zh-CN.pdf').existsSync(), isTrue);
    });
  });
}
