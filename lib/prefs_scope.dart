import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 启动时在 `runApp` 之前预取好的 [SharedPreferences] 单例。
///
/// 挂在这个 scope 之下的 widget 可以在 `initState`/`didChangeDependencies`
/// 阶段就同步读到本地存过的值，不必再各自 await 一次
/// `SharedPreferences.getInstance()` —— 那样会导致首帧先按猜测的默认值渲染，
/// 等 Future 回来又 setState 成真实值，界面就跟着闪一下。
class PrefsScope extends InheritedWidget {
  const PrefsScope({super.key, required this.prefs, required super.child});

  /// 启动早期（测试里没注入、要自己异步取一次时）可能还没就绪。为了让
  /// scope 始终挂在树上、不因为 prefs 到位而改变树形导致整棵子树重建，
  /// 这里允许为 null；真正要用的地方由 [of] 断言拦住。
  final SharedPreferences? prefs;

  static SharedPreferences of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<PrefsScope>();
    assert(scope != null, 'PrefsScope 不在当前 context 之上');
    assert(scope!.prefs != null, 'PrefsScope 里的 SharedPreferences 还没就绪');
    return scope!.prefs!;
  }

  @override
  bool updateShouldNotify(PrefsScope oldWidget) => prefs != oldWidget.prefs;
}
