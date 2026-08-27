import 'package:shared_preferences/shared_preferences.dart';

/// 同时执行的任务数上限。
///
/// 闸门在服务端：服务进程启动时读 `APP_MAX_CONCURRENT_TASKS` 建一个容量固定的
/// 信号量，超出的任务停在 `queued` 上排队，轮到了自动开始。桌面端只负责把用户
/// 选的数字在 spawn 时传进去 —— 也正因为容量是启动那一刻定死的，改完要等下次
/// 启动才生效，设置页会据此提示。
///
/// 常量单独放一个文件：`BackendService`（spawn 时要用）和 `AppSettings`
/// （持久化 + 界面）都要读它，而这两边互相不该有依赖。
const kDefaultMaxConcurrentTasks = 3;
const kMinMaxConcurrentTasks = 1;

/// 上限比后端的 100 保守得多：桌面端是本机跑，每个任务内部还各有一份
/// `APP_TRANSLATION_CONCURRENCY`（默认 20）的分段并发，两者相乘才是真正打向
/// 翻译 API 的并发量，再往上翻只会换来一片 429。
const kMaxMaxConcurrentTasks = 10;

const kMaxConcurrentTasksKey = 'retainpdf-rs.max-concurrent-tasks';

/// 读本地存的并发上限；没存过或存了越界的值都退回合法区间。
int readMaxConcurrentTasks(SharedPreferences? prefs) {
  final stored = prefs?.getInt(kMaxConcurrentTasksKey);
  return (stored ?? kDefaultMaxConcurrentTasks).clamp(
    kMinMaxConcurrentTasks,
    kMaxMaxConcurrentTasks,
  );
}
