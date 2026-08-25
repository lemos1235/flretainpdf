import 'dart:convert';
import 'dart:io';

import 'package:flretainpdf/server/runtime_installer.dart';
import 'package:flretainpdf/server/runtime_layout.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 只提供 AssetManifest.bin 和几个小文件，够 RuntimeInstaller 跑完整流程。
class _FakeBundle extends CachingAssetBundle {
  _FakeBundle(this.files);

  final Map<String, String> files;

  @override
  Future<ByteData> load(String key) async {
    if (key == 'AssetManifest.bin') {
      final manifest = {
        for (final path in files.keys)
          path: [
            {'asset': path},
          ],
      };
      return const StandardMessageCodec().encodeMessage(manifest)!;
    }
    final content = files[key];
    if (content == null) {
      throw StateError('缺少 asset：$key');
    }
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(content)));
  }
}

void main() {
  late Directory support;
  late Directory binaries;

  const assets = {
    'assets/images/logo.png': 'not-a-server-asset',
    // 二进制已经改走原生层，就算 manifest 里混进来也不该被释放。
    'assets/server/binary/darwin-arm64/retainpdf-rs': 'should-be-ignored',
    'assets/server/fonts/.gitkeep': '',
    'assets/server/fonts/SourceHanSerifSC-Bold.otf': 'font-bold',
    'assets/server/typst-packages/preview/mitex/0.2.7/lib.typ': 'package',
  };

  RuntimeInstaller installer([Map<String, String>? override]) =>
      RuntimeInstaller(
        bundle: _FakeBundle(override ?? assets),
        supportDirectory: () async => support,
        binaryDirectoryOverride: binaries,
      );

  setUp(() {
    support = Directory.systemTemp.createTempSync('retainpdf-install-test');
    // 模拟构建期塞进包内的那两个可执行文件。
    binaries = Directory.systemTemp.createTempSync('retainpdf-bin-test');
    File('${binaries.path}/$serverExeName').writeAsStringSync('server-binary');
    File('${binaries.path}/$typstExeName').writeAsStringSync('typst-binary');
  });

  tearDown(() {
    for (final dir in [support, binaries]) {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    }
  });

  test('二进制从包内直接取，不再复制到支持目录', () async {
    final layout = await installer().ensureInstalled();

    expect(File(layout.serverExe).readAsStringSync(), 'server-binary');
    expect(File(layout.typstExe).readAsStringSync(), 'typst-binary');
    // 关键：包内那份就是运行时用的那份，支持目录下不该再有一份拷贝。
    expect(layout.serverExe.startsWith(binaries.path), isTrue);
    expect(Directory('${layout.root.path}/bin').existsSync(), isFalse);
  });

  test('首次释放只落字体和 typst 包，跳过二进制与占位文件', () async {
    final layout = await installer().ensureInstalled();

    expect(
      File('${layout.fontsDir}/SourceHanSerifSC-Bold.otf').existsSync(),
      isTrue,
    );
    expect(
      File('${layout.packagesDir}/preview/mitex/0.2.7/lib.typ').existsSync(),
      isTrue,
    );
    expect(Directory('${layout.root.path}/binary').existsSync(), isFalse);
    expect(File('${layout.fontsDir}/.gitkeep').existsSync(), isFalse);

    final stamp = jsonDecode(layout.stampFile.readAsStringSync()) as Map;
    expect(stamp['version'], kRuntimeVersion);
    expect(stamp.containsKey('arch'), isFalse, reason: '架构已经是构建期的事了');
    expect((stamp['files'] as Map).length, 2);
  });

  test('清单对得上就不重复释放', () async {
    final first = await installer().ensureInstalled();
    final font = File('${first.fontsDir}/SourceHanSerifSC-Bold.otf');
    final before = font.lastModifiedSync();

    // lastModified 的分辨率有限，隔开一点再跑第二次。
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    final second = await installer().ensureInstalled();

    expect(second.root.path, first.root.path);
    expect(font.lastModifiedSync(), before);
  });

  test('清单里的大小对不上就重新释放', () async {
    final layout = await installer().ensureInstalled();
    const rel = 'fonts/SourceHanSerifSC-Bold.otf';
    final stamp = jsonDecode(layout.stampFile.readAsStringSync()) as Map;
    (stamp['files'] as Map)[rel] = 999999;
    layout.stampFile.writeAsStringSync(jsonEncode(stamp));

    await Future<void>.delayed(const Duration(milliseconds: 1100));
    final again = await installer().ensureInstalled();
    final fresh = jsonDecode(again.stampFile.readAsStringSync()) as Map;
    expect((fresh['files'] as Map)[rel], 'font-bold'.length);
  });

  test('残留的旧版本目录会被清掉', () async {
    final runtimeRoot = Directory('${support.path}/runtime/legacy')
      ..createSync(recursive: true);
    File('${runtimeRoot.path}/stale').writeAsStringSync('x');

    await installer().ensureInstalled();
    expect(runtimeRoot.existsSync(), isFalse);
  });

  test('包内缺二进制时报可读的错，并指出缺哪个文件', () async {
    File('${binaries.path}/$typstExeName').deleteSync();

    await expectLater(
      installer().ensureInstalled(),
      throwsA(
        isA<RuntimeInstallException>()
            .having((e) => e.message, 'message', contains('缺少内置服务程序'))
            .having((e) => e.detail, 'detail', contains(typstExeName)),
      ),
    );
  });
}
