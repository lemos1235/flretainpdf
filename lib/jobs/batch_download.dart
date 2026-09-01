import 'dart:io';

import 'package:file_picker/file_picker.dart';

import '../api/api_client.dart';

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

/// 保存对话框和批量保存时的推荐文件名
String suggestPdfFileName(JobSummary job) {
  final name = job.filename.trim().isEmpty ? 'translated' : job.filename.trim();
  final base = name.toLowerCase().endsWith('.pdf')
      ? name.substring(0, name.length - 4)
      : name;
  final language = job.targetLanguage.trim();
  final safeBase = base.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  final effectiveBase = safeBase.isEmpty ? 'translated' : safeBase;
  final safeLang = language.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  return safeLang.isEmpty
      ? '$effectiveBase-translated.pdf'
      : '$effectiveBase-$safeLang.pdf';
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
  void Function(int current, int total, String currentFilename)? onProgress,
}) async {
  final downloadableJobs = jobs
      .where((j) => j.status == 'completed' && j.translatedPdfUrl.isNotEmpty)
      .toList();

  if (downloadableJobs.isEmpty) {
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

  for (var i = 0; i < downloadableJobs.length; i++) {
    final job = downloadableJobs[i];
    final fileName = suggestPdfFileName(job);
    onProgress?.call(i + 1, downloadableJobs.length, fileName);

    try {
      final bytes = await api.downloadArtifact(job.translatedPdfUrl);
      final file = resolveUniqueFile(targetDirectory, fileName);
      await file.writeAsBytes(bytes, flush: true);
      succeeded++;
    } catch (e) {
      failed++;
      errors.add('${job.filename}: ${describeError(e)}');
    }
  }

  return BatchDownloadResult(
    total: downloadableJobs.length,
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

/// 将译文 PDF 保存到临时目录并使用系统默认程序打开查看
Future<void> viewPdfArtifact({
  required ApiClient api,
  required JobSummary job,
}) async {
  final bytes = await api.downloadArtifact(job.translatedPdfUrl);
  final tempDir = Directory.systemTemp;
  final previewDir = Directory(
    '${tempDir.path}${Platform.pathSeparator}retainpdf_preview',
  );
  if (!previewDir.existsSync()) {
    previewDir.createSync(recursive: true);
  }
  final baseName = suggestPdfFileName(job);
  final targetFile = File(
    '${previewDir.path}${Platform.pathSeparator}${job.jobId}_$baseName',
  );
  await targetFile.writeAsBytes(bytes, flush: true);
  await openFileInSystemViewer(targetFile.path);
}

/// 将译文 PDF 保存到用户选择的本地路径
Future<String?> savePdfArtifact({
  required ApiClient api,
  required JobSummary job,
}) async {
  final bytes = await api.downloadArtifact(job.translatedPdfUrl);
  final defaultName = suggestPdfFileName(job);
  final uri = await FilePicker.saveFile(
    dialogTitle: '保存译文 PDF',
    fileName: defaultName,
    type: FileType.custom,
    allowedExtensions: ['pdf'],
    bytes: bytes,
  );
  if (uri == null) {
    return null;
  }
  try {
    return uri.toFilePath();
  } catch (_) {
    return Uri.decodeFull(uri.path);
  }
}
