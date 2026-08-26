#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

#include <string>

// 应用内部约定的窗口消息：已存在的实例收到后把自己的窗口恢复并置前。
// 首次调用时向系统注册，返回值在整个会话内保持不变。
UINT GetActivateExistingInstanceMessage();

// 检测是否已有同一应用的实例在运行。
// 已有实例：激活它的窗口并返回 true，调用方应立即退出。
// 没有实例：占用互斥体（保持到进程结束）并返回 false。
bool ActivateExistingInstanceIfRunning(const std::wstring& window_title);

#endif  // RUNNER_SINGLE_INSTANCE_H_
