import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api/api_client.dart';
import 'app_shell.dart';
import 'prefs_scope.dart';
import 'server/backend_boot_page.dart';
import 'server/backend_service.dart';
import 'settings/app_settings.dart';
import 'settings/task_concurrency.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  // path_provider 和 Process 都要在 binding 初始化之后才能用。
  WidgetsFlutterBinding.ensureInitialized();
  // 提前拿到 SharedPreferences，这样折叠卡片、表单字段这些依赖本地存储的
  // UI 首帧就能按真实值渲染，不会先展开/填充默认值再被异步读回来的值改掉。
  final prefs = await SharedPreferences.getInstance();
  runApp(RetainPdfApp(prefs: prefs));
}

/// [ApiClient] 和 [AppSettings] 在这里创建：外观设置要驱动 [MaterialApp.themeMode]，
/// 所以 scope 必须挂在 MaterialApp 之上。[BackendService] 同理——它决定了
/// 主界面什么时候能挂上去。
class RetainPdfApp extends StatefulWidget {
  const RetainPdfApp({super.key, this.api, this.backend, this.prefs});

  /// 测试用的注入点：传进来的 [ApiClient] 会同时给 [BackendService] 和界面用。
  final ApiClient? api;
  final BackendService? backend;

  /// `main()` 里预取好传进来的实例；测试没传时自己异步兜底获取一次。
  final SharedPreferences? prefs;

  @override
  State<RetainPdfApp> createState() => _RetainPdfAppState();
}

class _RetainPdfAppState extends State<RetainPdfApp> {
  late final _api = widget.api ?? ApiClient();
  final _settings = AppSettings();
  // 并发上限传的是回调而不是值：服务是在 initState 里就启动的，那时
  // AppSettings 还没 load（它要等服务就绪），所以直接从 prefs 里现取。
  late final _backend =
      widget.backend ??
      BackendService(
        api: _api,
        maxConcurrentTasks: () => readMaxConcurrentTasks(_prefs),
      );

  /// macOS 上关窗退出走 onExitRequested，在这里把服务子进程收掉。
  /// 在 initState 里显式赋值：靠求值一个 late 字段来触发初始化太隐晦，
  /// 哪天被当成无用语句清掉，子进程就静默收不掉了。
  late final AppLifecycleListener _lifecycle;

  bool _settingsLoaded = false;

  /// 测试没注入 prefs 时的兜底：自己异步取一次。真机走 `main()` 预取的那份，
  /// 这里首帧就已经有值，不会再触发一次 setState。
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await _backend.shutdown();
        return AppExitResponse.exit;
      },
    );
    _prefs = widget.prefs;
    if (_prefs == null) {
      SharedPreferences.getInstance().then((prefs) {
        if (mounted) {
          setState(() => _prefs = prefs);
        }
      });
    }
    // 服务没起来时 AppSettings.load 的第一步 fetchConfig 就会失败，
    // 白白丢掉服务端默认值，所以等就绪了再 load。失败后用户点重试成功
    // 也要补上，因此监听而不是只调一次。
    _backend.addListener(_loadSettingsWhenReady);
    // 注入进来的 backend 可能已经是 ready 了，那样不会再有通知，先自己走一次。
    _loadSettingsWhenReady();
    _backend.start();
  }

  void _loadSettingsWhenReady() {
    if (_settingsLoaded || !_backend.isReady) {
      return;
    }
    _settingsLoaded = true;
    _settings.load(_api);
  }

  @override
  void dispose() {
    _backend.removeListener(_loadSettingsWhenReady);
    _lifecycle.dispose();
    _backend.dispose();
    _settings.dispose();
    _api.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // PrefsScope 挂在 MaterialApp 之上：弹窗内容是挂到 Navigator 的 overlay 上的，
    // 要是 scope 只包住 home，弹窗里的 widget 沿树往上就找不到它。
    return PrefsScope(
      prefs: _prefs,
      // PrefsScope 挂在 MaterialApp 之上：弹窗内容是挂到 Navigator 的 overlay 上的，
      // 要是 scope 只包住 home，弹窗里的 widget 沿树往上就找不到它。
      child: AppSettingsScope(
        settings: _settings,
        child: ListenableBuilder(
          listenable: _settings,
          builder: (context, child) => MaterialApp(
            title: 'PDF Translator',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light,
            darkTheme: AppTheme.dark,
            themeMode: _settings.themeMode,
            home: child,
          ),
          // 服务就绪前主界面不挂载，HomePage 的轮询也就不会一直报连不上；
          // 顺带等 prefs 就绪，两者都齐了再挂 AppShell，首帧就能读到真实的
          // 本地存储值，不会有默认值到真实值的闪烁。
          child: ListenableBuilder(
            listenable: _backend,
            builder: (context, shell) {
              if (!_backend.isReady || _prefs == null) {
                return BackendBootPage(backend: _backend);
              }
              return shell!;
            },
            child: AppShell(api: _api),
          ),
        ),
      ),
    );
  }
}
