import 'dart:io';

/// 释放出来的运行时目录版本号。
///
/// assets/server/ 下的内容有变动时手动 +1：目录名带上版本号，旧版本会在下次
/// 释放时被清理，避免升级后 App 还在用上一版的字体或 typst 包。
const kRuntimeVersion = '1';

/// assets 里运行时资产的根前缀。只剩字体和 typst 包——二进制走原生层了。
const kServerAssetPrefix = 'assets/server/';

/// 服务和 typst 的可执行文件名。除了拼路径，收僵尸进程时还要拿它跟系统里
/// 真实的进程名比对，所以提到顶层共用一份。
String get serverExeName =>
    Platform.isWindows ? 'retainpdf-rs.exe' : 'retainpdf-rs';

String get typstExeName => Platform.isWindows ? 'typst.exe' : 'typst';

/// 二进制所在的目录，由构建期塞进包里（macOS 是 Xcode 的 Embed Server
/// Binaries 阶段，Windows 是 CMake 的 install 规则），运行时只管找。
///
/// 不需要 MethodChannel：[Platform.resolvedExecutable] 给的就是包内的可执行
/// 文件路径，从它往上推即可。
/// - macOS：`Foo.app/Contents/MacOS/foo` → `Contents/Resources/server/`
/// - Windows：`foo.exe` → 同级的 `server\`
Directory get bundledBinaryDir {
  final exeDir = File(Platform.resolvedExecutable).parent;
  if (Platform.isMacOS) {
    // MacOS/ 的上一层是 Contents/。
    return Directory(
      '${exeDir.parent.path}${Platform.pathSeparator}Resources'
      '${Platform.pathSeparator}server',
    );
  }
  return Directory('${exeDir.path}${Platform.pathSeparator}server');
}

/// 运行时的目录约定：
///
/// ```
/// 包内（构建期写死，只读）：
///   <bundle>/server/retainpdf-rs
///   <bundle>/server/typst
///
/// 应用支持目录（首次启动从 assets 释放）：
///   <支持目录>/runtime/<kRuntimeVersion>/
///     fonts/*.otf
///     typst-packages/preview/...
///     .installed.json         释放清单，用来跳过重复释放
/// ```
class RuntimeLayout {
  const RuntimeLayout({required this.root, this.binaryDirectoryOverride});

  /// `<支持目录>/runtime/<版本>`，只放释放出来的字体和 typst 包。
  final Directory root;

  /// 测试注入点：单测跑在 dart 可执行文件里，[bundledBinaryDir] 推不出真实包。
  final Directory? binaryDirectoryOverride;

  static const stampName = '.installed.json';

  Directory get binaryDir => binaryDirectoryOverride ?? bundledBinaryDir;

  String get serverExe =>
      '${binaryDir.path}${Platform.pathSeparator}$serverExeName';

  String get typstExe =>
      '${binaryDir.path}${Platform.pathSeparator}$typstExeName';

  String get fontsDir => _join(['fonts']);

  String get packagesDir => _join(['typst-packages']);

  File get stampFile => File(_join([stampName]));

  String resolve(String relPath) =>
      _join(relPath.split('/').where((part) => part.isNotEmpty).toList());

  String _join(List<String> parts) =>
      [root.path, ...parts].join(Platform.pathSeparator);
}

/// 把 asset key 映射成释放后的相对路径；返回 null 表示这个 asset 不该释放。
String? runtimeRelPathForAsset(String assetKey) {
  if (!assetKey.startsWith(kServerAssetPrefix)) {
    return null;
  }
  final rel = assetKey.substring(kServerAssetPrefix.length);
  if (rel.isEmpty || rel.endsWith('/.gitkeep') || rel == '.gitkeep') {
    return null;
  }
  if (rel.startsWith('binary/')) {
    // 二进制已经改走原生层，pubspec 里也不再声明这个目录。留个显式跳过，
    // 免得哪天有人把声明加回来又悄悄多释放一份。
    return null;
  }
  return rel; // fonts/... 和 typst-packages/... 原样落盘。
}
