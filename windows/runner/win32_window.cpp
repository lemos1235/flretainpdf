#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>

#include "app_constants.h"
#include "resource.h"
#include "single_instance.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

/// Registry key for app theme preference.
///
/// A value of 0 indicates apps should use dark mode. A non-zero or missing
/// value indicates apps should use light mode.
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
  L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

// The number of Win32Window objects that currently exist.
static int g_active_window_count = 0;

using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

// Scale helper to convert logical scaler values to physical using passed in
// scale factor
int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

// Dynamically loads the |EnableNonClientDpiScaling| from the User32 module.
// This API is only needed for PerMonitor V1 awareness mode.
void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) {
    return;
  }
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling != nullptr) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

// 窗口位置的持久化位置。存到 HKCU 而不是文件，免得受工作目录/安装目录权限影响。
constexpr const wchar_t kWindowPlacementRegKey[] =
    L"Software\\flretainpdf\\WindowPlacement";
constexpr const wchar_t kPlacementValueName[] = L"NormalPosition";
constexpr const wchar_t kMaximizedValueName[] = L"Maximized";

// 判定「窗口还抓得住」时探测的标题栏区域（物理像素，够粗略即可）。
constexpr LONG kCaptionProbeHeight = 32;
constexpr LONG kCaptionProbeInset = 8;

// WINDOWPLACEMENT::rcNormalPosition 用的是工作区坐标，而 MonitorFromRect 要的是
// 屏幕坐标。任务栏在底部时两者原点重合，被拖到顶部或左侧时会差一个任务栏厚度。
// 这里按主显示器工作区的原点平移回屏幕坐标，仅用于查显示器，不改写保存的值。
RECT WorkspaceToScreen(const RECT& rect) {
  RECT work_area{};
  if (!SystemParametersInfo(SPI_GETWORKAREA, 0, &work_area, 0)) {
    return rect;
  }
  return RECT{rect.left + work_area.left, rect.top + work_area.top,
              rect.right + work_area.left, rect.bottom + work_area.top};
}

// 读取上次退出时保存的窗口位置。
// 返回 false 表示没有可用记录（首次启动，或记录指向的显示器已不存在）。
bool LoadSavedPlacement(RECT* normal_position, bool* maximized) {
  RECT saved{};
  DWORD size = sizeof(saved);
  if (RegGetValue(HKEY_CURRENT_USER, kWindowPlacementRegKey,
                  kPlacementValueName, RRF_RT_REG_BINARY, nullptr, &saved,
                  &size) != ERROR_SUCCESS ||
      size != sizeof(saved)) {
    return false;
  }
  if (saved.right <= saved.left || saved.bottom <= saved.top) {
    return false;
  }
  // 显示器可能被拔掉或分辨率变了，落在屏幕外的记录直接作废。
  // 这里只拿标题栏那条带去判定：整窗口有交集是不够的——右下角剩一个像素
  // 也算「有交集」，但那种窗口标题栏在屏幕外，用户没法用鼠标把它拖回来。
  const RECT screen_rect = WorkspaceToScreen(saved);
  RECT caption{screen_rect.left + kCaptionProbeInset, screen_rect.top,
               screen_rect.right - kCaptionProbeInset,
               screen_rect.top + kCaptionProbeHeight};
  if (caption.right <= caption.left) {
    caption.left = screen_rect.left;
    caption.right = screen_rect.right;
  }
  if (MonitorFromRect(&caption, MONITOR_DEFAULTTONULL) == nullptr) {
    return false;
  }

  DWORD maximized_value = 0;
  DWORD maximized_size = sizeof(maximized_value);
  RegGetValue(HKEY_CURRENT_USER, kWindowPlacementRegKey, kMaximizedValueName,
              RRF_RT_REG_DWORD, nullptr, &maximized_value, &maximized_size);

  *normal_position = saved;
  *maximized = maximized_value != 0;
  return true;
}

// 保存窗口位置。用 WINDOWPLACEMENT 而不是 GetWindowRect，
// 这样窗口处于最大化/最小化时记下的仍是还原后的正常尺寸。
void SaveWindowPlacement(HWND window) {
  WINDOWPLACEMENT placement{};
  placement.length = sizeof(placement);
  if (!GetWindowPlacement(window, &placement)) {
    return;
  }

  HKEY key = nullptr;
  if (RegCreateKeyEx(HKEY_CURRENT_USER, kWindowPlacementRegKey, 0, nullptr,
                     REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nullptr, &key,
                     nullptr) != ERROR_SUCCESS) {
    return;
  }

  RegSetValueEx(key, kPlacementValueName, 0, REG_BINARY,
                reinterpret_cast<const BYTE*>(&placement.rcNormalPosition),
                sizeof(placement.rcNormalPosition));
  // 不能用 showCmd 判最大化：窗口已隐藏时它是 SW_HIDE，销毁路径上必然读错。
  // IsZoomed 读的是 WS_MAXIMIZE 样式，ShowWindow(SW_HIDE) 只清 WS_VISIBLE，
  // 不动它，所以任何时机都准。最小化状态下退出时 WS_MAXIMIZE 已被清掉，
  // 「还原后应为最大化」这层信息则由 WPF_RESTORETOMAXIMIZED 提供。
  DWORD maximized = (IsZoomed(window) ||
                     (placement.flags & WPF_RESTORETOMAXIMIZED) != 0)
                        ? 1
                        : 0;
  RegSetValueEx(key, kMaximizedValueName, 0, REG_DWORD,
                reinterpret_cast<const BYTE*>(&maximized), sizeof(maximized));
  RegCloseKey(key);
}

using AdjustWindowRectExForDpi = BOOL __stdcall(LPRECT rect,
                                                DWORD style,
                                                BOOL menu,
                                                DWORD ex_style,
                                                UINT dpi);

// 把客户区尺寸换算成包含标题栏和边框的窗口尺寸。
// 边框宽度本身也随 DPI 变，所以优先用 Win10 1607+ 的 DPI 版本 API。
SIZE ClientSizeToWindowSize(int client_width,
                            int client_height,
                            DWORD style,
                            UINT dpi) {
  // 拖动窗口边框期间 WM_GETMINMAXINFO 是高频消息，函数指针只解析一次。
  // user32.dll 必然已经加载，用 GetModuleHandleW 取句柄即可，不必 LoadLibrary。
  static auto* adjust_for_dpi = reinterpret_cast<AdjustWindowRectExForDpi*>(
      GetProcAddress(GetModuleHandleW(L"user32.dll"),
                     "AdjustWindowRectExForDpi"));

  RECT rect{0, 0, client_width, client_height};
  if (adjust_for_dpi == nullptr ||
      !adjust_for_dpi(&rect, style, FALSE, 0, dpi)) {
    AdjustWindowRect(&rect, style, FALSE);
  }

  return SIZE{rect.right - rect.left, rect.bottom - rect.top};
}

// 把还原出来的窗口尺寸夹到最小尺寸之上。|rect| 是工作区坐标（来自
// rcNormalPosition），查显示器前要先平移回屏幕坐标。
// WM_GETMINMAXINFO 的 ptMinTrackSize 只约束用户拖拽，管不到 SetWindowPlacement
// 直接写进去的 rcNormalPosition；旧版本留下的（当时还没有最小尺寸限制）或被手工
// 改过的记录会让窗口以过小的客户区启动，Flutter 布局随即溢出。
void ClampToMinimumSize(RECT* rect, const Win32Window::Size& minimum_size) {
  if (minimum_size.width == 0 && minimum_size.height == 0) {
    return;
  }
  const RECT screen_rect = WorkspaceToScreen(*rect);
  HMONITOR monitor = MonitorFromRect(&screen_rect, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;
  SIZE minimum = ClientSizeToWindowSize(
      Scale(minimum_size.width, scale_factor),
      Scale(minimum_size.height, scale_factor), WS_OVERLAPPEDWINDOW, dpi);

  if (rect->right - rect->left < minimum.cx) {
    rect->right = rect->left + minimum.cx;
  }
  if (rect->bottom - rect->top < minimum.cy) {
    rect->bottom = rect->top + minimum.cy;
  }
}

// 取窗口所在显示器的 DPI。
UINT GetDpiForCurrentMonitor(HWND window) {
  HMONITOR monitor = MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
  return FlutterDesktopGetDpiForMonitor(monitor);
}

}  // namespace

// Manages the Win32Window's window class registration.
class WindowClassRegistrar {
 public:
  ~WindowClassRegistrar() = default;

  // Returns the singleton registrar instance.
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) {
      instance_ = new WindowClassRegistrar();
    }
    return instance_;
  }

  // Returns the name of the window class, registering the class if it hasn't
  // previously been registered.
  const wchar_t* GetWindowClass();

  // Unregisters the window class. Should only be called if there are no
  // instances of the window.
  void UnregisterWindowClass();

 private:
  WindowClassRegistrar() = default;

  static WindowClassRegistrar* instance_;

  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

const wchar_t* WindowClassRegistrar::GetWindowClass() {
  if (!class_registered_) {
    WNDCLASS window_class{};
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    window_class.style = CS_HREDRAW | CS_VREDRAW;
    window_class.cbClsExtra = 0;
    window_class.cbWndExtra = 0;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.hIcon =
        LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
    window_class.hbrBackground = 0;
    window_class.lpszMenuName = nullptr;
    window_class.lpfnWndProc = Win32Window::WndProc;
    RegisterClass(&window_class);
    class_registered_ = true;
  }
  return kWindowClassName;
}

void WindowClassRegistrar::UnregisterWindowClass() {
  UnregisterClass(kWindowClassName, nullptr);
  class_registered_ = false;
}

Win32Window::Win32Window() {
  ++g_active_window_count;
}

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title,
                         const Point& origin,
                         const Size& size,
                         const Size& minimum_size) {
  Destroy();

  minimum_size_ = minimum_size;

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  const SIZE default_size = ClientSizeToWindowSize(
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      WS_OVERLAPPEDWINDOW, dpi);
  RECT window_rect{Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
                   0, 0};
  window_rect.right = window_rect.left + default_size.cx;
  window_rect.bottom = window_rect.top + default_size.cy;

  bool has_saved_placement = LoadSavedPlacement(&window_rect, &start_maximized_);

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW, window_rect.left,
      window_rect.top, window_rect.right - window_rect.left,
      window_rect.bottom - window_rect.top, nullptr, nullptr,
      GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  if (has_saved_placement) {
    ClampToMinimumSize(&window_rect, minimum_size_);

    // 保存的坐标是工作区坐标系，必须走 SetWindowPlacement 才能原样还原；
    // showCmd 用 SW_HIDE 保持窗口不可见，等 Show() 再按需最大化显示。
    WINDOWPLACEMENT placement{};
    placement.length = sizeof(placement);
    placement.showCmd = SW_HIDE;
    // {0,0} 是主显示器左上角的合法坐标，会让副显示器上的窗口最大化时跑回主屏；
    // {-1,-1} 才表示「由系统按窗口所在显示器计算」。
    placement.ptMinPosition = POINT{-1, -1};
    placement.ptMaxPosition = POINT{-1, -1};
    placement.rcNormalPosition = window_rect;
    SetWindowPlacement(window, &placement);
  }

  UpdateTheme(window);

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_,
                    start_maximized_ ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL);
}

// static
LRESULT CALLBACK Win32Window::WndProc(HWND const window,
                                      UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto window_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(window_struct->lpCreateParams));

    auto that = static_cast<Win32Window*>(window_struct->lpCreateParams);
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }

  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT
Win32Window::MessageHandler(HWND hwnd,
                            UINT const message,
                            WPARAM const wparam,
                            LPARAM const lparam) noexcept {
  // 单实例：另一个进程被启动后会把这条消息投递过来，要求本窗口回到前台。
  // 注册失败时返回 0，要排除掉，否则会误吞 WM_NULL。
  const UINT activate_message = GetActivateExistingInstanceMessage();
  if (activate_message != 0 && message == activate_message) {
    ShowWindow(hwnd, IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
    SetForegroundWindow(hwnd);
    return 0;
  }

  switch (message) {
    case WM_DESTROY:
      // 此刻 rcNormalPosition 与 WS_MAXIMIZE 样式都还有效，
      // 所以不管窗口是走 WM_CLOSE 关的还是被直接 DestroyWindow，存这一次就够。
      SaveWindowPlacement(hwnd);
      window_handle_ = nullptr;
      Destroy();
      if (quit_on_close_) {
        PostQuitMessage(0);
      }
      return 0;

    case WM_DPICHANGED: {
      auto newRectSize = reinterpret_cast<RECT*>(lparam);
      LONG newWidth = newRectSize->right - newRectSize->left;
      LONG newHeight = newRectSize->bottom - newRectSize->top;

      SetWindowPos(hwnd, nullptr, newRectSize->left, newRectSize->top, newWidth,
                   newHeight, SWP_NOZORDER | SWP_NOACTIVATE);

      return 0;
    }
    case WM_SIZE: {
      RECT rect = GetClientArea();
      if (child_content_ != nullptr) {
        // Size and position the child window.
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      return 0;
    }

    case WM_GETMINMAXINFO: {
      if (minimum_size_.width == 0 && minimum_size_.height == 0) {
        break;
      }
      UINT dpi = GetDpiForCurrentMonitor(hwnd);
      double scale_factor = dpi / 96.0;
      SIZE minimum = ClientSizeToWindowSize(
          Scale(minimum_size_.width, scale_factor),
          Scale(minimum_size_.height, scale_factor),
          static_cast<DWORD>(GetWindowLongPtr(hwnd, GWL_STYLE)), dpi);
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      info->ptMinTrackSize.x = minimum.cx;
      info->ptMinTrackSize.y = minimum.cy;
      return 0;
    }

    case WM_ACTIVATE:
      if (child_content_ != nullptr) {
        SetFocus(child_content_);
      }
      return 0;

    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      return 0;
  }

  return DefWindowProc(window_handle_, message, wparam, lparam);
}

void Win32Window::Destroy() {
  OnDestroy();

  if (window_handle_) {
    DestroyWindow(window_handle_);
    window_handle_ = nullptr;
  }
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame;
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() {
  return window_handle_;
}

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() {
  // No-op; provided for subclasses.
  return true;
}

void Win32Window::OnDestroy() {
  // No-op; provided for subclasses.
}

void Win32Window::UpdateTheme(HWND const window) {
  DWORD light_mode;
  DWORD light_mode_size = sizeof(light_mode);
  LSTATUS result = RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                               kGetPreferredBrightnessRegValue,
                               RRF_RT_REG_DWORD, nullptr, &light_mode,
                               &light_mode_size);

  if (result == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
