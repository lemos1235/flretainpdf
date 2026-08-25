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
}
