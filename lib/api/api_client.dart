import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// 服务实际监听的地址。默认端口，[BackendService] 在探测到端口被占用后
/// 会改写成实际找到的那个。
String baseUrl = 'http://127.0.0.1:40010';

const _tokenHeader = 'X-RetainPDF-Token';

/// `/api/config` 的返回，用来给表单填服务端默认值。
class AppConfig {
  const AppConfig({
    required this.translationDefaultTargetLanguage,
    required this.translationModel,
    required this.translationBaseUrl,
    required this.tableRecognitionBaseUrl,
    required this.tableRecognitionFlavor,
    required this.mineruBaseUrl,
    required this.maxConcurrentTasks,
  });

  final String translationDefaultTargetLanguage;
  final String translationModel;
  final String translationBaseUrl;
  final String tableRecognitionBaseUrl;
  final String tableRecognitionFlavor;
  final String mineruBaseUrl;

  /// 服务进程**当前**生效的同时执行任务数上限。它是启动时由环境变量定死的，
  /// 所以设置页拿它和本地存的值比对，不一样就提示「重启后生效」。
  /// 老版本服务不返回这个字段，那时是 0，按「不知道」处理。
  final int maxConcurrentTasks;

  factory AppConfig.fromJson(Map<String, dynamic> json) {
    return AppConfig(
      translationDefaultTargetLanguage: _string(
        json['translation_default_target_language'],
      ),
      translationModel: _string(json['translation_model']),
      translationBaseUrl: _string(json['translation_base_url']),
      tableRecognitionBaseUrl: _string(json['table_recognition_base_url']),
      tableRecognitionFlavor: _string(json['table_recognition_flavor']),
      mineruBaseUrl: _string(json['mineru_base_url']),
      maxConcurrentTasks: json['max_concurrent_tasks'] is num
          ? (json['max_concurrent_tasks'] as num).toInt()
          : 0,
    );
  }
}

/// `/api/jobs` 列表里的一项。
class JobSummary {
  const JobSummary({
    required this.jobId,
    required this.filename,
    required this.status,
    required this.step,
    required this.message,
    required this.targetLanguage,
    required this.pages,
    required this.skipPages,
    required this.pageCount,
    required this.translatedPdfUrl,
  });

  final String jobId;
  final String filename;
  final String status;
  final String step;
  final String message;
  final String targetLanguage;
  final String pages;
  final String skipPages;
  final int? pageCount;
  final String translatedPdfUrl;

  factory JobSummary.fromJson(Map<String, dynamic> json) {
    final artifacts = json['artifacts'];
    return JobSummary(
      jobId: _string(json['job_id']),
      filename: _string(json['filename']),
      status: _string(json['status']),
      step: _string(json['step']),
      message: _string(json['message']),
      targetLanguage: _string(json['target_language']),
      pages: _string(json['pages']),
      skipPages: _string(json['skip_pages']),
      pageCount: json['page_count'] is num
          ? (json['page_count'] as num).toInt()
          : null,
      translatedPdfUrl: artifacts is Map
          ? _string(artifacts['translated_pdf_url'])
          : '',
    );
  }
}

class ApiClient {
  ApiClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// The token sent with every `/api/*` request.  Set by [BackendService]
  /// with a per-launch random value before the server is ready.
  late String apiToken;

  /// Token header attached to every `/api/*` request.  The `/health` endpoint
  /// is unauthenticated so it does NOT use this.
  Map<String, String> get _authHeaders => {_tokenHeader: apiToken};

  /// 探一下 `/health`，用来判断服务是不是已经在跑。任何异常都当成「没起来」，
  /// 不往外抛。
  Future<bool> health({
    Duration timeout = const Duration(milliseconds: 800),
  }) async {
    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/health'))
          .timeout(timeout);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<AppConfig> fetchConfig() async {
    final response = await _client.get(
      Uri.parse('$baseUrl/api/config'),
      headers: _authHeaders,
    );
    return AppConfig.fromJson(_decodeObject(response, '读取服务端配置失败'));
  }

  Future<List<JobSummary>> fetchJobs() async {
    final response = await _client.get(
      Uri.parse('$baseUrl/api/jobs'),
      headers: _authHeaders,
    );
    final decoded = _decode(response, '读取任务列表失败');
    if (decoded is! List) {
      throw Exception('读取任务列表失败：返回格式不正确');
    }
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(JobSummary.fromJson)
        .toList();
  }

  /// 表单字段直接按 multipart 发送，字段名与 webapp 的 `name` 属性一一对应。
  /// 复刻 HTML 表单语义：勾上的 checkbox 发 "on"，没勾的字段根本不出现在
  /// 请求里 —— 所以布尔字段由调用方决定放不放进 [fields]。
  Future<String> createJob({
    required String filePath,
    required Map<String, String> fields,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/api/jobs'),
    );
    request.headers.addAll(_authHeaders);
    request.fields.addAll(fields);
    request.files.add(await http.MultipartFile.fromPath('file', filePath));
    final response = await http.Response.fromStream(
      await _client.send(request),
    );
    final payload = _decodeObject(response, '创建任务失败');
    return _string(payload['job_id']);
  }

  /// 让服务端在原任务上重新执行一遍（同一个 job_id，源文件用服务端保存的
  /// 那份，不需要本地文件）。[overrides] 用当前表单的最新参数覆盖任务原本
  /// 保存的请求参数，效果等同于直接创建一个新任务，但不占用新的 job_id。
  Future<JobSummary> retryJob(
    String jobId,
    Map<String, dynamic> overrides,
  ) async {
    final response = await _client.post(
      Uri.parse('$baseUrl/api/jobs/${Uri.encodeComponent(jobId)}/retry'),
      headers: {..._authHeaders, 'Content-Type': 'application/json'},
      body: jsonEncode(overrides),
    );
    return JobSummary.fromJson(_decodeObject(response, '重试任务失败'));
  }

  /// 清空可清理的任务及其源文件与产物。清理接口要求至少提供一个筛选条件，
  /// `keep_latest: 0` 表示不保留任何符合服务端清理条件的历史任务。
  Future<int> clearJobs() async {
    final response = await _client.post(
      Uri.parse('$baseUrl/api/jobs/cleanup'),
      headers: {..._authHeaders, 'Content-Type': 'application/json'},
      body: jsonEncode({'keep_latest': 0}),
    );
    final payload = _decodeObject(response, '清空任务列表失败');
    final removedCount = payload['removed_count'];
    if (removedCount is! num) {
      throw Exception('清空任务列表失败：返回格式不正确');
    }
    return removedCount.toInt();
  }

  /// 删除任务连同它在服务端的源文件与产物。后端对进行中的任务会拒绝，
  /// 界面上也只给已完成 / 失败的任务放按钮。成功时可能是 204 空 body，
  /// 所以这里只校验状态码，不解析返回。
  Future<void> deleteJob(String jobId) async {
    final response = await _client.delete(
      Uri.parse('$baseUrl/api/jobs/${Uri.encodeComponent(jobId)}'),
      headers: _authHeaders,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(_errorMessage(response, '删除任务失败'));
    }
  }

  /// 把产物整份读进内存，交给保存对话框写盘。译文 PDF 体量有限，不做流式。
  Future<Uint8List> downloadArtifact(String url) async {
    final response = await _client.get(
      resolveArtifactUri(url),
      headers: _authHeaders,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('下载失败（HTTP ${response.statusCode}）');
    }
    return response.bodyBytes;
  }

  void close() => _client.close();
}

/// 拼出可直接打开的产物地址：后端给的可能是 `/files/xxx.pdf` 这样的相对路径。
Uri resolveArtifactUri(String url) => Uri.parse(baseUrl).resolve(url);

Map<String, dynamic> _decodeObject(http.Response response, String fallback) {
  final decoded = _decode(response, fallback);
  if (decoded is! Map<String, dynamic>) {
    throw Exception('$fallback：返回格式不正确');
  }
  return decoded;
}

/// 失败时优先用后端 body 里的 `error` 字段做提示，对齐 webapp 的错误展示。
dynamic _decode(http.Response response, String fallback) {
  dynamic decoded;
  try {
    decoded = jsonDecode(utf8.decode(response.bodyBytes));
  } catch (_) {
    decoded = null;
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw Exception(_errorMessage(response, fallback));
  }
  if (decoded == null) {
    throw Exception('$fallback：返回不是合法 JSON');
  }
  return decoded;
}

/// 失败响应的提示文案：优先取 body 里的 `error` 字段，没有就退回 HTTP 状态码。
String _errorMessage(http.Response response, String fallback) {
  dynamic decoded;
  try {
    decoded = jsonDecode(utf8.decode(response.bodyBytes));
  } catch (_) {
    decoded = null;
  }
  final error = decoded is Map ? decoded['error'] : null;
  return error is String && error.isNotEmpty
      ? error
      : '$fallback（HTTP ${response.statusCode}）';
}

String _string(dynamic value) => value is String ? value : '';

/// `Exception: xxx` 的前缀对用户没意义，剥掉；连不上服务时给一句人话。
String describeError(Object error) {
  if (error is SocketException ||
      error is HttpException ||
      error is TimeoutException) {
    return '无法连接到服务 $baseUrl，请确认它已启动。';
  }
  final text = error.toString();
  return text.startsWith('Exception: ') ? text.substring(11) : text;
}
