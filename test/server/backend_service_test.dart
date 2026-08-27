import 'dart:async';
import 'dart:io';

import 'package:flretainpdf/api/api_client.dart';
import 'package:flretainpdf/server/backend_service.dart';
import 'package:flretainpdf/server/runtime_installer.dart';
import 'package:flretainpdf/server/runtime_layout.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 永远说「装不上」的 installer：让 start() 在真正 spawn 子进程之前就停下来，
/// 单测里不需要（也不该）拉起真的二进制。
class _FailingInstaller extends RuntimeInstaller {
  _FailingInstaller() : super(supportDirectory: () async => throw StateError('不该走到这里'));

  @override
  Future<RuntimeLayout> ensureInstalled({void Function(String)? onStep}) {
    throw RuntimeInstallException('当前平台没有内置服务程序。', detail: '测试桩');
  }
}

/// 装得上：返回一个指向临时目录的 layout，里面摆着假的"服务二进制"。
class _StubInstaller extends RuntimeInstaller {
  _StubInstaller(this.dir) : super(supportDirectory: () async => dir);

  final Directory dir;

  @override
  Future<RuntimeLayout> ensureInstalled({void Function(String)? onStep}) async {
    return RuntimeLayout(
      root: Directory('${dir.path}${Platform.pathSeparator}runtime')
        ..createSync(recursive: true),
      binaryDirectoryOverride: Directory(
        '${dir.path}${Platform.pathSeparator}bin',
      ),
    );
  }
}

/// 同样装不上，但支持目录是真的，好让 _reapOrphan 能读到 pid 文件。
class _InstallerWithSupportDir extends RuntimeInstaller {
  _InstallerWithSupportDir(Directory dir)
    : super(supportDirectory: () async => dir);

  @override
  Future<RuntimeLayout> ensureInstalled({void Function(String)? onStep}) {
    throw RuntimeInstallException('当前平台没有内置服务程序。', detail: '测试桩');
  }
}

ApiClient _api({required bool Function() healthy}) {
  return ApiClient(
    client: MockClient((request) async {
      if (request.url.path == '/health') {
        return http.Response('ok', healthy() ? 200 : 503);
      }
      return http.Response('{}', 200);
    }),
  );
}

void main() {
  test('释放失败时落到 failed 并带上诊断信息', () async {
    final backend = BackendService(
      api: _api(healthy: () => false),
      installer: _FailingInstaller(),
    );

    await backend.start();

    expect(backend.hasFailed, isTrue);
    expect(backend.message, contains('内置服务'));
    expect(backend.detail, '测试桩');
    backend.dispose();
  });

  test('pid 文件里的号码已经属于别的程序时，不去杀它', () async {
    // 拿一个真实存在、但明显不是我们服务的进程当靶子——pid 被系统回收复用
    // 之后就是这个局面，此时误杀的是用户自己的程序。
    final victim = await Process.start('sleep', ['30']);
    addTearDown(() => victim.kill(ProcessSignal.sigkill));
    var victimExited = false;
    unawaited(victim.exitCode.then((_) => victimExited = true));

    final support = Directory.systemTemp.createTempSync('retainpdf-reap');
    addTearDown(() => support.deleteSync(recursive: true));
    final pidFile = File(
      '${support.path}${Platform.pathSeparator}runtime'
      '${Platform.pathSeparator}server.pid',
    );
    pidFile.parent.createSync(recursive: true);
    pidFile.writeAsStringSync('${victim.pid}');

    final backend = BackendService(
      api: _api(healthy: () => false),
      installer: _InstallerWithSupportDir(support),
    );

    await backend.start();

    expect(backend.hasFailed, isTrue); // 装不上，但收僵尸那步已经跑过了。
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(victimExited, isFalse, reason: '不该杀掉不属于我们的进程');
    expect(pidFile.existsSync(), isFalse, reason: '过期的 pid 文件仍然要清掉');
    backend.dispose();
  }, skip: Platform.isWindows ? 'sleep 是 POSIX 命令' : null);

  test('并发上限作为 APP_MAX_CONCURRENT_TASKS 传给服务进程', () async {
    final support = Directory.systemTemp.createTempSync('retainpdf-env');
    addTearDown(() => support.deleteSync(recursive: true));

    // 假二进制：把自己拿到的环境变量抄进文件，然后挂着不退 —— 真的服务在这
    // 一步也是常驻的，提前退出会让 BackendService 报「进程意外退出」。
    final envDump = '${support.path}${Platform.pathSeparator}env.txt';
    final binDir = Directory('${support.path}${Platform.pathSeparator}bin')
      ..createSync(recursive: true);
    final exe = File(
      '${binDir.path}${Platform.pathSeparator}$serverExeName',
    )..writeAsStringSync('#!/bin/sh\nenv > "$envDump"\nsleep 30\n');
    Process.runSync('chmod', ['+x', exe.path]);

    final backend = BackendService(
      api: _api(healthy: () => true),
      installer: _StubInstaller(support),
      maxConcurrentTasks: () => 7,
    );
    addTearDown(backend.dispose);

    await backend.start();

    expect(backend.isReady, isTrue, reason: backend.detail);
    // /health 是 mock 的，一探就通，脚本未必已经写完 env.txt —— 等一下它。
    // 等的是「内容出现」而不是「文件出现」：`env > file` 里的重定向是 shell
    // 在 exec env 之前就做的，文件先被建成空的，输出随后才落进去，只等
    // existsSync 会有一个能读到空串的窗口。
    final dump = File(envDump);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    String contents() => dump.existsSync() ? dump.readAsStringSync() : '';
    while (!contents().contains('APP_MAX_CONCURRENT_TASKS=7') &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(contents(), contains('APP_MAX_CONCURRENT_TASKS=7'));
    // 诊断信息里也要看得到，排查「为什么还在排队」时用得上。
    expect(backend.detail, contains('APP_MAX_CONCURRENT_TASKS=7'));
    await backend.shutdown();
  }, skip: Platform.isWindows ? '假二进制是 sh 脚本' : null);
}
