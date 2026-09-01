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
  String compareUrl = '',
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
    comparePdfUrl: compareUrl,
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

  group('resolveBatchDownloadItems', () {
    final jobs = [
      _createJob(
        jobId: '1',
        filename: 'both.pdf',
        status: 'completed',
        url: '/files/1.pdf',
        compareUrl: '/files/1-compare.pdf',
      ),
      _createJob(
        jobId: '2',
        filename: 'only-translated.pdf',
        status: 'completed',
        url: '/files/2.pdf',
      ),
      _createJob(
        jobId: '3',
        filename: 'unfinished.pdf',
        status: 'translating',
        url: '',
        compareUrl: '/files/3-compare.pdf',
      ),
    ];

    test('仅译文只取译文件', () {
      final items = resolveBatchDownloadItems(
        jobs,
        BatchDownloadKind.translated,
      );
      expect(items.map((item) => item.url), ['/files/1.pdf', '/files/2.pdf']);
      expect(items.first.fileName, 'both-zh-CN.pdf');
    });

    test('仅对照只取已合成对照件的任务', () {
      final items = resolveBatchDownloadItems(jobs, BatchDownloadKind.compare);
      expect(items.map((item) => item.url), ['/files/1-compare.pdf']);
      expect(items.single.fileName, 'both-zh-CN-compare.pdf');
    });

    test('译文 + 对照把同一任务拆成两份，缺对照件的只出译文', () {
      final items = resolveBatchDownloadItems(jobs, BatchDownloadKind.both);
      expect(items.map((item) => item.url), [
        '/files/1.pdf',
        '/files/1-compare.pdf',
        '/files/2.pdf',
      ]);
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
      expect(
        file.path,
        equals('${tempDir.path}${Platform.pathSeparator}out.pdf'),
      );
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
      final pathWithTrailingSeparator =
          '${tempDir.path}${Platform.pathSeparator}';
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
        _createJob(jobId: '3', filename: 'doc3.pdf', status: 'failed', url: ''),
      ];

      final progressList = <String>[];
      final api = ApiClient(
        client: MockClient((request) async {
          return http.Response.bytes(Uint8List.fromList([1, 2, 3, 4]), 200);
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
      expect(
        File('${tempDir.path}${Platform.pathSeparator}doc1-zh-CN.pdf')
            .existsSync(),
        isTrue,
      );
      expect(
        File('${tempDir.path}${Platform.pathSeparator}doc2-zh-CN.pdf')
            .existsSync(),
        isTrue,
      );
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
      expect(
        File('${tempDir.path}${Platform.pathSeparator}doc2-zh-CN.pdf')
            .existsSync(),
        isTrue,
      );
    });
  });

  group('runBatchDownload 的产物类型', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync(
        'batch_download_kind_test_',
      );
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('译文 + 对照会各存一份，文件名不冲突', () async {
      final jobs = [
        _createJob(
          jobId: '1',
          filename: 'doc.pdf',
          status: 'completed',
          url: '/files/doc.pdf',
          compareUrl: '/files/doc-compare.pdf',
        ),
      ];

      final requested = <String>[];
      final api = ApiClient(
        client: MockClient((request) async {
          requested.add(request.url.path);
          return http.Response.bytes(Uint8List.fromList([1, 2]), 200);
        }),
      )..apiToken = 'token';

      final result = await runBatchDownload(
        api: api,
        jobs: jobs,
        kind: BatchDownloadKind.both,
        targetDirectory: tempDir.path,
      );

      expect(requested, ['/files/doc.pdf', '/files/doc-compare.pdf']);
      expect(result.total, 2);
      expect(result.succeeded, 2);
      final separator = Platform.pathSeparator;
      expect(
        File('${tempDir.path}${separator}doc-zh-CN.pdf').existsSync(),
        isTrue,
      );
      expect(
        File('${tempDir.path}${separator}doc-zh-CN-compare.pdf').existsSync(),
        isTrue,
      );
    });

    test('对照件下载失败时错误里标出是对照件', () async {
      final jobs = [
        _createJob(
          jobId: '1',
          filename: 'doc.pdf',
          status: 'completed',
          url: '/files/doc.pdf',
          compareUrl: '/files/doc-compare.pdf',
        ),
      ];

      final api = ApiClient(
        client: MockClient((request) async => http.Response('Not Found', 404)),
      )..apiToken = 'token';

      final result = await runBatchDownload(
        api: api,
        jobs: jobs,
        kind: BatchDownloadKind.compare,
        targetDirectory: tempDir.path,
      );

      expect(result.failed, 1);
      expect(result.errors.single, contains('doc.pdf（对照）'));
    });
  });

  // 只测到落盘为止：`viewPdfArtifact` 的最后一步会调 `open`/`xdg-open` 把
  // 文件交给系统默认程序，跑测试时会真的弹出一个 PDF 阅读器窗口。
  group('downloadPdfArtifactForPreview', () {
    test('正确下载产物并写入预览临时文件', () async {
      final job = _createJob(
        jobId: 'test-job-99',
        filename: 'preview_doc.pdf',
        status: 'completed',
        url: '/files/preview_doc.pdf',
      );

      final api = ApiClient(
        client: MockClient((request) async {
          expect(request.url.path, '/files/preview_doc.pdf');
          return http.Response.bytes(Uint8List.fromList([37, 80, 68, 70]), 200);
        }),
      )..apiToken = 'token';

      final targetFile = await downloadPdfArtifactForPreview(
        api: api,
        job: job,
      );

      final previewDir = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}retainpdf_preview',
      );
      expect(
        targetFile.path,
        '${previewDir.path}${Platform.pathSeparator}test-job-99_preview_doc-zh-CN.pdf',
      );
      expect(targetFile.existsSync(), isTrue);
      expect(await targetFile.readAsBytes(), [37, 80, 68, 70]);

      // 清理测试产物
      if (targetFile.existsSync()) {
        targetFile.deleteSync();
      }
    });
  });
}
