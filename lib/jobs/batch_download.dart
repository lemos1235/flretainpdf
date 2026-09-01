import 'dart:io';

import '../api/api_client.dart';

/// 批量下载时要取哪些产物。对照件是任务完成后另外合成的，所以可能只有一部分
/// 任务有；[both] 会把两种产物都存下来，缺哪种就跳过哪种。
enum BatchDownloadKind {
  translated('仅译文'),
  compare('仅对照'),
  both('译文 + 对照');

  const BatchDownloadKind(this.label);

  final String label;
}

/// 一份待下载的产物：同一个任务在 [BatchDownloadKind.both] 下会拆成两份。
class BatchDownloadItem {
  const BatchDownloadItem({
    required this.job,
    required this.url,
    required this.fileName,
    required this.compare,
  });

  final JobSummary job;
  final String url;
  final String fileName;
  final bool compare;

  /// 出错时的提示用原始文件名，对照件再标一下，免得两条错误看着一模一样。
  String get label => compare ? '${job.filename}（对照）' : job.filename;
}

/// 按 [kind] 把任务摊平成待下载的产物清单，缺对应产物的任务自动略过。
List<BatchDownloadItem> resolveBatchDownloadItems(
  List<JobSummary> jobs,
  BatchDownloadKind kind,
) {
  final items = <BatchDownloadItem>[];
  for (final job in jobs.where((job) => job.status == 'completed')) {
    if (kind != BatchDownloadKind.compare && job.translatedPdfUrl.isNotEmpty) {
      items.add(
        BatchDownloadItem(
          job: job,
          url: job.translatedPdfUrl,
          fileName: suggestPdfFileName(job),
          compare: false,
        ),
      );
    }
    if (kind != BatchDownloadKind.translated && job.comparePdfUrl.isNotEmpty) {
      items.add(
        BatchDownloadItem(
          job: job,
          url: job.comparePdfUrl,
          fileName: suggestPdfFileName(job, compare: true),
          compare: true,
        ),
      );
    }
  }
  return items;
}

/// 批量下载的结果汇总
class BatchDownloadResult {
  const BatchDownloadResult({
    required this.total,
    required this.succeeded,
    required this.failed,
    required this.errors,
    required this.targetDirectory,
  });

  final int total;
  final int succeeded;
  final int failed;
  final List<String> errors;
  final String targetDirectory;

  bool get isAllSuccess => failed == 0 && succeeded > 0;
}

/// 保存对话框和批量保存时的推荐文件名。[compare] 为真时给对照件再加一个
/// `-compare` 后缀，免得和同一任务的译文件重名。
String suggestPdfFileName(JobSummary job, {bool compare = false}) {
  final name = job.filename.trim().isEmpty ? 'translated' : job.filename.trim();
  final base = name.toLowerCase().endsWith('.pdf')
      ? name.substring(0, name.length - 4)
      : name;
  final language = job.targetLanguage.trim();
  final safeBase = base.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  final effectiveBase = safeBase.isEmpty ? 'translated' : safeBase;
  final safeLang = language.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  final suffix = compare ? '-compare' : '';
  return safeLang.isEmpty
      ? '$effectiveBase-translated$suffix.pdf'
      : '$effectiveBase-$safeLang$suffix.pdf';
}

/// 在指定目录中生成不重名的文件路径
File resolveUniqueFile(String directoryPath, String originalFileName) {
  final dir = Directory(directoryPath);
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }

  final separator = dir.path.endsWith(Platform.pathSeparator)
      ? ''
      : Platform.pathSeparator;

  var candidateName = originalFileName;
  var file = File('${dir.path}$separator$candidateName');
  if (!file.existsSync()) {
    return file;
  }

  final dotIndex = originalFileName.lastIndexOf('.');
  final String base;
  final String ext;
  if (dotIndex > 0) {
    base = originalFileName.substring(0, dotIndex);
    ext = originalFileName.substring(dotIndex);
  } else {
    base = originalFileName;
    ext = '';
  }

  var counter = 1;
  while (file.existsSync()) {
    candidateName = '$base ($counter)$ext';
    file = File('${dir.path}$separator$candidateName');
    counter++;
  }
  return file;
}

/// 执行批量下载并将文件写入指定目录
Future<BatchDownloadResult> runBatchDownload({
  required ApiClient api,
  required List<JobSummary> jobs,
  required String targetDirectory,
  BatchDownloadKind kind = BatchDownloadKind.translated,
  void Function(int current, int total, String currentFilename)? onProgress,
}) async {
  final items = resolveBatchDownloadItems(jobs, kind);

  if (items.isEmpty) {
    return BatchDownloadResult(
      total: 0,
      succeeded: 0,
      failed: 0,
      errors: const [],
      targetDirectory: targetDirectory,
    );
  }

  var succeeded = 0;
  var failed = 0;
  final errors = <String>[];

  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    onProgress?.call(i + 1, items.length, item.fileName);

    try {
      final bytes = await api.downloadArtifact(item.url);
      final file = resolveUniqueFile(targetDirectory, item.fileName);
      await file.writeAsBytes(bytes, flush: true);
      succeeded++;
    } catch (e) {
      failed++;
      errors.add('${item.label}: ${describeError(e)}');
    }
  }

  return BatchDownloadResult(
    total: items.length,
    succeeded: succeeded,
    failed: failed,
    errors: errors,
    targetDirectory: targetDirectory,
  );
}

/// 打开系统文件管理器并定位到指定目录
Future<void> openDirectoryInSystemExplorer(String directoryPath) async {
  try {
    if (Platform.isMacOS) {
      await Process.run('open', [directoryPath]);
    } else if (Platform.isWindows) {
      await Process.run('explorer', [directoryPath]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [directoryPath]);
    }
  } catch (_) {
    // 忽略打开系统文件管理器的异常
  }
}

/// 调用系统默认程序打开指定文件
Future<void> openFileInSystemViewer(String filePath) async {
  try {
    if (Platform.isMacOS) {
      await Process.run('open', [filePath]);
    } else if (Platform.isWindows) {
      await Process.run('cmd.exe', ['/c', 'start', '', filePath]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [filePath]);
    }
  } catch (_) {
    // 忽略打开默认程序的异常
  }
}

/// 把 PDF 产物下载到预览用的临时目录，返回落好盘的文件。[compare] 为真时取
/// 对照件，否则取译文件。
///
/// 单独拆出来是为了能测：[viewPdfArtifact] 的最后一步会拉起系统默认程序，
/// 在测试里就是真的弹出一个 PDF 阅读器窗口。
Future<File> downloadPdfArtifactForPreview({
  required ApiClient api,
  required JobSummary job,
  bool compare = false,
}) async {
  final url = compare ? job.comparePdfUrl : job.translatedPdfUrl;
  final bytes = await api.downloadArtifact(url);
  final tempDir = Directory.systemTemp;
  final previewDir = Directory(
    '${tempDir.path}${Platform.pathSeparator}retainpdf_preview',
  );
  if (!previewDir.existsSync()) {
    previewDir.createSync(recursive: true);
  }
  final baseName = suggestPdfFileName(job, compare: compare);
  // jobId 也得过一遍非法字符：它是拼进路径的，带上分隔符就会写到预览目录之外
  // 去，或者在 Windows 上直接写失败。文件名那半段 suggestPdfFileName 已经洗过。
  final safeJobId = job.jobId.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  final targetFile = File(
    '${previewDir.path}${Platform.pathSeparator}${safeJobId}_$baseName',
  );
  await targetFile.writeAsBytes(bytes, flush: true);
  return targetFile;
}

/// 将 PDF 产物保存到临时目录并使用系统默认程序打开查看。[compare] 为真时打开
/// 对照件，否则打开译文件。
Future<void> viewPdfArtifact({
  required ApiClient api,
  required JobSummary job,
  bool compare = false,
}) async {
  final file = await downloadPdfArtifactForPreview(
    api: api,
    job: job,
    compare: compare,
  );
  await openFileInSystemViewer(file.path);
}
