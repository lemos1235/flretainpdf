import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import '../settings/task_concurrency.dart';
import 'runtime_installer.dart';
import 'runtime_layout.dart';

/// 服务监听的端口。要和 [baseUrl] 对得上。
const kServerPort = 40010;

/// 等 `/health` 就绪的总时限。首次启动要读 45 MB 的 typst 和字体，给宽一点。
const _readyTimeout = Duration(seconds: 20);
const _probeInterval = Duration(milliseconds: 250);

enum BackendPhase { probing, installing, launching, waiting, ready, failed }

/// 内置服务子进程的生命周期管理。
class BackendService extends ChangeNotifier {
  BackendService({
    required ApiClient api,
    RuntimeInstaller? installer,
    int Function()? maxConcurrentTasks,
  }) : _installer = installer ?? RuntimeInstaller(),
       _maxConcurrentTasks =
           maxConcurrentTasks ?? (() => kDefaultMaxConcurrentTasks),
       // ignore: prefer_initializing_formals — 具名参数不能用私有字段名
       _api = api;


  final ApiClient _api;
  final RuntimeInstaller _installer;

  /// 同时执行的任务数上限，spawn 的那一刻现取 —— 用户可能在服务失败重试之前
  /// 刚在设置页改过，取回调而不是取值就是为了拿到最新的那个。
  final int Function() _maxConcurrentTasks;

  BackendPhase _phase = BackendPhase.probing;
  String _message = '正在检查服务…';
  String _detail = '';

  Process? _process;
  File? _pidFile;
  Future<void>? _pending;
  bool _disposed = false;

  /// 子进程日志的环形缓冲，失败时拼进 [detail] 给用户看。
  final _logLines = <String>[];
  static const _maxLogLines = 50;

  BackendPhase get phase => _phase;

  /// 给用户看的一句话状态。
  String get message => _message;

  /// 诊断信息：命令行、环境变量、子进程日志尾。
  String get detail => _detail;

  bool get isReady => _phase == BackendPhase.ready;

  bool get hasFailed => _phase == BackendPhase.failed;

  /// 幂等：重复调用返回同一个 Future。
  Future<void> start() {
    return _pending ??= _run().whenComplete(() {
      _pending = null;
    });
  }

  Future<void> retry() {
    if (_phase == BackendPhase.ready) {
      return Future.value();
    }
    return start();
  }

  Future<void> _run() async {
    _logLines.clear();
    _update(BackendPhase.probing, '正在检查服务…', detail: '');
    try {
      // 收上次留下的僵尸进程，纯属打扫，出什么岔子都不该挡住启动。
      try {
        await _reapOrphan();
      } catch (_) {}

      _update(BackendPhase.installing, '正在准备运行环境…');
      final layout = await _installer.ensureInstalled(
        onStep: (step) => _update(BackendPhase.installing, step),
      );

      _update(BackendPhase.launching, '正在启动服务…');
      await _spawn(layout);

      _update(BackendPhase.waiting, '等待服务就绪…');
      await _waitReady();
    } on RuntimeInstallException catch (error) {
      _fail(error.message, detail: error.detail);
    } on ProcessException catch (error) {
      _fail(
        '无法执行服务程序。',
        detail: '${error.executable}\n${error.message}（errno ${error.errorCode}）',
      );
    } catch (error) {
      _fail('启动服务时出错。', detail: '$error');
    }
  }

  /// 上次退出没清干净的子进程：pid 文件还在但端口探不通，说明它挂死了，收掉。
  /// 探得通的情况在 [_run] 里会走 adopt 分支，不动它。
  Future<void> _reapOrphan() async {
    final support = await _installer.supportDirectory();
    final file = File(
      '${support.path}${Platform.pathSeparator}runtime'
      '${Platform.pathSeparator}server.pid',
    );
    _pidFile = file;
    if (!file.existsSync()) {
      return;
    }
    final pid = int.tryParse(file.readAsStringSync().trim());
    if (pid != null && pid > 1 && await _isServerProcess(pid)) {
      try {
        if (Platform.isWindows) {
          await Process.run('taskkill', ['/PID', '$pid', '/F']);
        } else {
          Process.killPid(pid, ProcessSignal.sigkill);
        }
      } catch (_) {}
      // 端口不是 kill 完立刻就还回来的，等它真的从进程表里消失再往下走，
      // 否则新进程 bind 40010 会失败，白等一轮 20 秒超时。
      await _waitProcessGone(pid);
    }
    try {
      file.deleteSync();
    } catch (_) {}
  }

  /// pid 文件是上次运行留下的，机器重启或隔了很久之后，这个号码很可能已经被
  /// 系统分配给别的程序了 —— 直接 SIGKILL 就成了杀用户自己的进程，代价远大于
  /// 留一个僵尸。所以先按进程名确认确实是我们的服务，查不出来就当成不是。
  Future<bool> _isServerProcess(int pid) async {
    try {
      if (Platform.isWindows) {
        final result = await Process.run('tasklist', [
          '/FI',
          'PID eq $pid',
          '/NH',
          '/FO',
          'CSV',
        ]);
        return '${result.stdout}'.toLowerCase().contains(
          serverExeName.toLowerCase(),
        );
      }
      final result = await Process.run('ps', ['-p', '$pid', '-o', 'comm=']);
      if (result.exitCode != 0) {
        return false; // 进程压根不存在，ps 返回非 0。
      }
      // macOS 的 comm 给的是完整路径，取最后一段比。
      return '${result.stdout}'.trim().split('/').last == serverExeName;
    } catch (_) {
      return false;
    }
  }

  Future<void> _waitProcessGone(int pid) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      if (!await _isServerProcess(pid)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> _spawn(RuntimeLayout layout) async {
    final dataDir = await _installer.dataDirectory();
    dataDir.createSync(recursive: true);

    // Each launch gets a fresh random token so an old/leaked value can't be
    // replayed.  The same value is set on [_api] so all our requests match.
    final token = _generateToken();
    _api.apiToken = token;

    final environment = {
      'APP_PORT': '$kServerPort',
      // 不用默认的 0.0.0.0：那会触发 macOS 的「允许接受传入网络连接」弹窗。
      'APP_BIND_HOST': '127.0.0.1',
      'APP_DATA_DIR': dataDir.path,
      'APP_FONT_PATH': layout.fontsDir,
      'TYPST_PACKAGE_PATH': layout.packagesDir,
      'TYPST_BIN': layout.typstExe,
      'APP_API_TOKEN': token,
      // 服务端据此建一个容量固定的信号量：超出的任务停在 queued 上排队，
      // 轮到了自动开始。容量在进程启动时就定死了，所以设置页改完要重启才生效。
      'APP_MAX_CONCURRENT_TASKS': '${_maxConcurrentTasks()}',
    };
    // Exclude the token from diagnostic output to avoid leaking it.
    _detail =
        '${layout.serverExe}\n'
        '${environment.entries.where((e) => e.key != 'APP_API_TOKEN').map((e) => '${e.key}=${e.value}').join('\n')}';

    final process = await Process.start(
      layout.serverExe,
      const [],
      workingDirectory: layout.root.path,
      environment: environment,
    );
    _process = process;
    _pidFile?.parent.createSync(recursive: true);
    _pidFile?.writeAsStringSync('${process.pid}');

    _pipe(process.stdout);
    _pipe(process.stderr);
    unawaited(
      process.exitCode.then((code) {
        if (_process != process) {
          return;
        }
        _process = null;
        // 就绪之前就退了，没必要干等 20 秒超时，直接报错并带上日志尾。
        if (_phase != BackendPhase.ready) {
          _fail('服务进程意外退出（退出码 $code）。', detail: _logTail());
        }
      }),
    );
  }

  void _pipe(Stream<List<int>> stream) {
    stream
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
          if (_logLines.length >= _maxLogLines) {
            _logLines.removeAt(0);
          }
          _logLines.add(line);
          if (kDebugMode) {
            debugPrint('[retainpdf-rs] $line');
          }
        }, onError: (_) {});
  }

  Future<void> _waitReady() async {
    final deadline = DateTime.now().add(_readyTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_phase == BackendPhase.failed || _disposed) {
        return; // 进程已经退了，_spawn 的 exitCode 回调报过错了。
      }
      if (await _api.health()) {
        _update(BackendPhase.ready, '服务已就绪。');
        return;
      }
      await Future<void>.delayed(_probeInterval);
    }
    await _stopProcess();
    _fail(
      '服务在 ${_readyTimeout.inSeconds} 秒内没有就绪。',
      detail: _logTail(),
    );
  }

  String _logTail() {
    final head = _detail.isEmpty ? '' : '$_detail\n\n';
    if (_logLines.isEmpty) {
      return '$head子进程没有输出任何日志。';
    }
    return '$head${_logLines.join('\n')}';
  }

  /// App 退出时调用，收掉服务子进程。
  Future<void> shutdown() async {
    await _stopProcess();
  }

  Future<void> _stopProcess() async {
    final process = _process;
    _process = null;
    if (process != null) {
      process.kill(ProcessSignal.sigterm);
      await process.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -9;
        },
      );
    }
    try {
      final pidFile = _pidFile;
      if (pidFile != null && pidFile.existsSync()) {
        pidFile.deleteSync();
      }
    } catch (_) {}
  }

  void _fail(String message, {String detail = ''}) {
    _update(BackendPhase.failed, message, detail: detail);
  }

  void _update(BackendPhase phase, String message, {String? detail}) {
    if (_disposed) {
      return;
    }
    _phase = phase;
    _message = message;
    if (detail != null) {
      _detail = detail;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(shutdown());
    super.dispose();
  }
}

/// 48-char hex string from a cryptographically secure PRNG — good enough for
/// a localhost-only bearer token that changes every launch.
String _generateToken() {
  final random = Random.secure();
  return List.generate(24, (_) => random.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
}
