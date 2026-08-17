#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kWindowTitle[] = L"Zmusic";
constexpr wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kSingleInstanceMutexName[] = L"Local\\ZmusicSingleInstance";

void ForwardFilesToExistingWindow(
    HWND window, const std::vector<std::string>& arguments) {
  std::string payload;
  for (const auto& argument : arguments) {
    if (argument.empty()) {
      continue;
    }
    payload.append(argument);
    payload.push_back('\0');
  }
  if (payload.empty()) {
    return;
  }

  COPYDATASTRUCT copy_data{};
  copy_data.dwData = kZmusicFileOpenCopyDataId;
  copy_data.cbData = static_cast<DWORD>(payload.size());
  copy_data.lpData = payload.data();
  DWORD_PTR result = 0;
  ::SendMessageTimeout(window, WM_COPYDATA, 0,
                       reinterpret_cast<LPARAM>(&copy_data), SMTO_ABORTIFHUNG,
                       2000, &result);
}

void ActivateExistingWindow(const std::vector<std::string>& arguments) {
  HWND window = ::FindWindow(kWindowClassName, nullptr);
  if (!window) {
    window = ::FindWindow(nullptr, kWindowTitle);
  }
  if (!window) {
    return;
  }

  ForwardFilesToExistingWindow(window, arguments);

  if (::IsIconic(window)) {
    ::ShowWindow(window, SW_RESTORE);
  } else {
    ::ShowWindow(window, SW_SHOW);
  }
  ::SetForegroundWindow(window);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  HANDLE single_instance_mutex =
      ::CreateMutex(nullptr, TRUE, kSingleInstanceMutexName);
  if (!single_instance_mutex) {
    return EXIT_FAILURE;
  }
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    ActivateExistingWindow(command_line_arguments);
    ::CloseHandle(single_instance_mutex);
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(command_line_arguments);

  FlutterWindow window(project, std::move(command_line_arguments));
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1088, 680);
  if (!window.Create(kWindowTitle, origin, size)) {
    ::CloseHandle(single_instance_mutex);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  ::CloseHandle(single_instance_mutex);
  return EXIT_SUCCESS;
}
