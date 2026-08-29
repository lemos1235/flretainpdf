import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'runtime_layout.dart';

/// 准备运行环境失败，[message] 直接给用户看。
class RuntimeInstallException implements Exception {
  RuntimeInstallException(this.message, {this.detail = ''});

  final String message;
  final String detail;

  @override
  String toString() => message;
}

/// 把 assets/server/ 里的字体和 typst 包释放到应用支持目录，并确认包内的
/// 服务二进制在位。
///
/// 二进制不在这里管：它由构建期直接摆进包内（macOS 的 Contents/Resources、
/// Windows 的 exe 同级目录），已经签过名，运行时直接 exec，不需要也不应该
/// 再复制一份出来。这里只负责那些必须落到可写目录的只读资产。
///
/// 字体加 typst 包约 48 MB，不能每次启动都重写一遍，所以释放完写一份清单
/// `.installed.json`，下次启动只 stat 比对文件大小（十几次 stat，微秒级），
/// 匹配就直接复用。不做哈希——那要读满 48 MB，得不偿失。
class RuntimeInstaller {
  RuntimeInstaller({
    AssetBundle? bundle,
    Future<Directory> Function()? supportDirectory,
    this.binaryDirectoryOverride,
  }) : _bundle = bundle ?? rootBundle,
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final AssetBundle _bundle;
  final Future<Directory> Function() _supportDirectory;

  /// 测试注入点；真机上为 null，走包内那个目录。
  final Directory? binaryDirectoryOverride;

  /// 单飞：UI 上连点重试不该并发释放同一批文件。
  Future<RuntimeLayout>? _pending;

  Future<RuntimeLayout> ensureInstalled({void Function(String)? onStep}) {
    return _pending ??= _ensureInstalled(onStep).whenComplete(() {
      _pending = null;
    });
  }

  /// 应用支持目录，运行时和数据目录都挂在它下面。
  Future<Directory> supportDirectory() => _supportDirectory();

  /// 数据目录：服务子进程的 APP_DATA_DIR。
  Future<Directory> dataDirectory() async {
    final support = await _supportDirectory();
    return Directory('${support.path}${Platform.pathSeparator}data');
  }

  Future<RuntimeLayout> _ensureInstalled(void Function(String)? onStep) async {
    final support = await _supportDirectory();
    final runtimeRoot = Directory(
      '${support.path}${Platform.pathSeparator}runtime',
    );
    final layout = RuntimeLayout(
      root: Directory(
        '${runtimeRoot.path}${Platform.pathSeparator}$kRuntimeVersion',
      ),
      binaryDirectoryOverride: binaryDirectoryOverride,
    );

    _requireBinaries(layout);

    // asset key -> 释放后的相对路径。
    final plan = <String, String>{};
    for (final key in await _serverAssets()) {
      final rel = runtimeRelPathForAsset(key);
      if (rel != null) {
        plan[key] = rel;
      }
    }
    if (plan.isEmpty) {
      throw RuntimeInstallException(
        '安装包里缺少服务运行所需的字体和 typst 包。',
        detail: '匹配 $kServerAssetPrefix 的 asset：0 个',
      );
    }

    if (_isInstalled(layout, plan.values)) {
      return layout;
    }

    onStep?.call('首次启动，正在释放运行环境…');
    await _extract(layout, plan, runtimeRoot);
    return layout;
  }

  /// 包内的二进制是构建期塞进来的，缺了就是打包出了问题，早报比让
  /// Process.start 抛一个没头没脑的 ProcessException 强。
  void _requireBinaries(RuntimeLayout layout) {
    final missing = [
      for (final path in [layout.serverExe, layout.typstExe])
        if (!File(path).existsSync()) path,
    ];
    if (missing.isEmpty) {
      return;
    }
    throw RuntimeInstallException(
      '安装包里缺少内置服务程序。',
      detail: '以下文件不存在：\n${missing.join('\n')}',
    );
  }

  /// 清单里的每个文件都存在且大小对得上，就认为已经装好了。
  bool _isInstalled(RuntimeLayout layout, Iterable<String> relPaths) {
    final stamp = layout.stampFile;
    if (!stamp.existsSync()) {
      return false;
    }
    Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(stamp.readAsStringSync());
      if (decoded is! Map<String, dynamic>) {
        return false;
      }
      data = decoded;
    } catch (_) {
      return false;
    }
    if (data['version'] != kRuntimeVersion) {
      return false;
    }
    final files = data['files'];
    if (files is! Map) {
      return false;
    }
    final expected = relPaths.toSet();
    if (files.length != expected.length || !expected.every(files.containsKey)) {
      return false;
    }
    for (final entry in files.entries) {
      final file = File(layout.resolve(entry.key as String));
      final stat = file.statSync();
      if (stat.type == FileSystemEntityType.notFound ||
          stat.size != entry.value) {
        return false;
      }
    }
    return true;
  }

  Future<void> _extract(
    RuntimeLayout layout,
    Map<String, String> plan,
    Directory runtimeRoot,
  ) async {
    // 先写到兄弟目录再整体 rename，中途崩溃不会留下半套文件被当成装好的。
    final tmp = Directory('${layout.root.path}.tmp');
    if (tmp.existsSync()) {
      tmp.deleteSync(recursive: true);
    }
    tmp.createSync(recursive: true);

    final sizes = <String, int>{};
    for (final entry in plan.entries) {
      final data = await _bundle.load(entry.key);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final target = File(
        [tmp.path, ...entry.value.split('/')].join(Platform.pathSeparator),
      );
      target.parent.createSync(recursive: true);
      await target.writeAsBytes(bytes, flush: true);
      sizes[entry.value] = bytes.length;
    }

    File([tmp.path, RuntimeLayout.stampName].join(Platform.pathSeparator))
        .writeAsStringSync(
          jsonEncode({'version': kRuntimeVersion, 'files': sizes}),
          flush: true,
        );

    if (layout.root.existsSync()) {
      layout.root.deleteSync(recursive: true);
    }
    tmp.renameSync(layout.root.path);

    // 清掉别的版本，免得升级几次之后攒下几百兆。
    if (runtimeRoot.existsSync()) {
      for (final entity in runtimeRoot.listSync()) {
        if (entity is Directory && entity.path != layout.root.path) {
          try {
            entity.deleteSync(recursive: true);
          } catch (_) {}
        }
      }
    }
  }

  Future<List<String>> _serverAssets() async {
    final manifest = await AssetManifest.loadFromAssetBundle(_bundle);
    return manifest
        .listAssets()
        .where((key) => key.startsWith(kServerAssetPrefix))
        .toList();
  }
}
