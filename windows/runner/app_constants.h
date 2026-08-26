#ifndef RUNNER_APP_CONSTANTS_H_
#define RUNNER_APP_CONSTANTS_H_

// 窗口标识常量集中放在这里：单实例模块要靠它们定位已有实例的窗口，
// 窗口模块要靠它们注册窗口类，两边都只依赖本头文件，不互相引用。

// 顶层窗口的窗口类名。
constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

// 顶层窗口标题。窗口类名是所有 Flutter Windows 应用共用的，
// 单实例查找时还要靠标题区分出本应用。
constexpr const wchar_t kWindowTitle[] = L"PDF Translator";

#endif  // RUNNER_APP_CONSTANTS_H_
