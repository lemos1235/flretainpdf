#include "single_instance.h"

#include <cwchar>

#include "app_constants.h"

namespace {

// 互斥体放在 Local\ 命名空间，作用域是当前登录会话：
// 同一用户重复双击 exe 会被拦截，而多用户/远程会话各自仍可开一个实例。
constexpr const wchar_t kSingleInstanceMutexName[] =
    L"Local\\flretainpdf.single-instance";

constexpr const wchar_t kActivateMessageName[] =
    L"flretainpdf.activate-existing-instance";

// 互斥体已存在但窗口还没建好时的等待上限：老实例可能正处于启动过程中。
constexpr int kFindWindowRetries = 20;
constexpr DWORD kFindWindowRetryIntervalMs = 100;

struct FindWindowContext {
  const wchar_t* title;
  DWORD excluded_process_id;
  HWND result;
};

BOOL CALLBACK FindMainWindow(HWND window, LPARAM lparam) {
  auto* context = reinterpret_cast<FindWindowContext*>(lparam);

  DWORD process_id = 0;
  GetWindowThreadProcessId(window, &process_id);
  if (process_id == context->excluded_process_id) {
    return TRUE;
  }

  wchar_t class_name[256] = {};
  if (GetClassName(window, class_name, ARRAYSIZE(class_name)) == 0 ||
      wcscmp(class_name, kWindowClassName) != 0) {
    return TRUE;
  }

  // 窗口类名是 Flutter 所有 Windows 应用共用的，还要靠标题区分本应用。
  wchar_t window_title[256] = {};
  if (GetWindowText(window, window_title, ARRAYSIZE(window_title)) == 0 ||
      wcscmp(window_title, context->title) != 0) {
    return TRUE;
  }

  context->result = window;
  return FALSE;
}

}  // namespace

UINT GetActivateExistingInstanceMessage() {
  static const UINT message = RegisterWindowMessage(kActivateMessageName);
  return message;
}

bool ActivateExistingInstanceIfRunning(const std::wstring& window_title) {
  // 故意不释放句柄：互斥体要一直被本进程持有到退出。
  HANDLE mutex = CreateMutex(nullptr, TRUE, kSingleInstanceMutexName);
  const DWORD create_error = GetLastError();
  if (mutex != nullptr) {
    if (create_error != ERROR_ALREADY_EXISTS) {
      return false;
    }
    // 互斥体已存在，本进程不拥有它，句柄可以立即还掉。
    CloseHandle(mutex);
  } else if (create_error != ERROR_ACCESS_DENIED) {
    return false;
  }
  // ERROR_ACCESS_DENIED 说明互斥体存在但本进程无权打开，
  // 典型情形是老实例以管理员身份运行——这同样属于「已有实例」。

  // 老实例可能正在启动、窗口还没建出来。这里等一小会儿再放弃，
  // 否则用户看到的就是「双击图标毫无反应」。
  HWND existing = nullptr;
  for (int i = 0; i < kFindWindowRetries && existing == nullptr; ++i) {
    FindWindowContext context{window_title.c_str(), GetCurrentProcessId(),
                              nullptr};
    EnumWindows(FindMainWindow, reinterpret_cast<LPARAM>(&context));
    existing = context.result;
    if (existing == nullptr && i + 1 < kFindWindowRetries) {
      Sleep(kFindWindowRetryIntervalMs);
    }
  }
  if (existing == nullptr) {
    // 始终没找到窗口也要退出，宁可这一次点击没反应，也不能开出第二个实例。
    return true;
  }

  // 前台权限属于刚被用户启动的本进程，先转让给老实例，
  // 它才能真正把窗口抢到最前，否则只会闪任务栏图标。
  // 已知限制：老实例若以管理员身份运行，UIPI 会静默拦掉这条
  // 低完整性→高完整性的 PostMessage，窗口不会前置（但也不会多开实例）。
  // 本应用不需要提权运行，所以不额外做 ChangeWindowMessageFilterEx 放行。
  DWORD process_id = 0;
  GetWindowThreadProcessId(existing, &process_id);
  AllowSetForegroundWindow(process_id);
  PostMessage(existing, GetActivateExistingInstanceMessage(), 0, 0);
  return true;
}
