#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>
#include <imm.h>

#include "resource.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined in case the developer's machine has a Windows SDK older than
/// version 10.0.22000.0.
/// See: https://docs.microsoft.com/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr int kMinimumWindowWidth = 1088;
constexpr int kMinimumWindowHeight = 680;

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
                         const Size& size) {
  Destroy();

  const wchar_t* window_class =
      WindowClassRegistrar::GetInstance()->GetWindowClass();

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  double scale_factor = dpi / 96.0;

  HWND window = CreateWindow(
      window_class, title.c_str(), WS_OVERLAPPEDWINDOW,
      Scale(origin.x, scale_factor), Scale(origin.y, scale_factor),
      Scale(size.width, scale_factor), Scale(size.height, scale_factor),
      nullptr, nullptr, GetModuleHandle(nullptr), this);

  if (!window) {
    return false;
  }

  UpdateTheme(window);

  return OnCreate();
}

bool Win32Window::Show() {
  return ShowWindow(window_handle_, SW_SHOWNORMAL);
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
  switch (message) {
    case WM_GETMINMAXINFO: {
      auto min_max_info = reinterpret_cast<MINMAXINFO*>(lparam);
      HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      const double scale_factor =
          FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
      min_max_info->ptMinTrackSize.x =
          Scale(kMinimumWindowWidth, scale_factor);
      min_max_info->ptMinTrackSize.y =
          Scale(kMinimumWindowHeight, scale_factor);
      return 0;
    }

    case WM_DESTROY:
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

    case WM_ACTIVATE:
      if (LOWORD(wparam) == WA_INACTIVE) {
        if (ime_requested_) {
          SetImeContextActive(false);
        }
      } else if (child_content_ != nullptr) {
        SetFocus(child_content_);
        if (ime_requested_) {
          SetImeContextActive(true);
        }
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

  SetImeEnabled(false);

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
  if (child_content_ != nullptr && child_content_ != content) {
    SetImeEnabled(false);
  }
  child_content_ = content;
  SetParent(content, window_handle_);
  RECT frame = GetClientArea();

  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, true);

  SetFocus(child_content_);
}

void Win32Window::SetImeEnabled(bool enabled) {
  ime_requested_ = enabled;
  SetImeContextActive(enabled);
}

void Win32Window::SetImeContextActive(bool enabled) {
  if (child_content_ == nullptr || !::IsWindow(child_content_)) {
    DestroyOwnedImeContext();
    ime_context_active_ = false;
    return;
  }

  if (enabled && ime_context_active_ && owned_ime_context_ != nullptr) {
    HIMC current_context = ::ImmGetContext(child_content_);
    if (current_context == owned_ime_context_) {
      ::ImmReleaseContext(child_content_, current_context);
      return;
    }
    if (current_context != nullptr) {
      ::ImmReleaseContext(child_content_, current_context);
    }
    ime_context_active_ = false;
  }

  if (!enabled) {
    DestroyOwnedImeContext();
    ::ImmAssociateContextEx(child_content_, nullptr, 0);
    ime_context_active_ = false;
    return;
  }

  HIMC previous_context = ::ImmGetContext(child_content_);
  if (previous_context != nullptr) {
    ime_open_status_ = ::ImmGetOpenStatus(previous_context) != FALSE;
    DWORD conversion_mode = 0;
    DWORD sentence_mode = 0;
    if (::ImmGetConversionStatus(previous_context, &conversion_mode,
                                 &sentence_mode) != FALSE) {
      ime_conversion_mode_ = conversion_mode;
      ime_sentence_mode_ = sentence_mode;
    }
    ::ImmReleaseContext(child_content_, previous_context);
  }

  if (!DestroyOwnedImeContext()) {
    ime_context_active_ = false;
    return;
  }
  ime_context_active_ = CreateAndAssociateImeContext();
}

bool Win32Window::DestroyOwnedImeContext() {
  if (owned_ime_context_ == nullptr) {
    return true;
  }

  bool context_disassociated =
      owned_ime_window_ == nullptr || !::IsWindow(owned_ime_window_);
  if (!context_disassociated) {
    HIMC current_context = ::ImmGetContext(owned_ime_window_);
    if (current_context != nullptr) {
      ::ImmReleaseContext(owned_ime_window_, current_context);
    }
    if (current_context == owned_ime_context_) {
      ::ImmAssociateContext(owned_ime_window_, replaced_ime_context_);
      current_context = ::ImmGetContext(owned_ime_window_);
      if (current_context != nullptr) {
        ::ImmReleaseContext(owned_ime_window_, current_context);
      }
    }
    context_disassociated = current_context != owned_ime_context_;
  }

  if (context_disassociated &&
      ::ImmDestroyContext(owned_ime_context_) != FALSE) {
    owned_ime_window_ = nullptr;
    owned_ime_context_ = nullptr;
    replaced_ime_context_ = nullptr;
  }
  return owned_ime_context_ == nullptr;
}

bool Win32Window::CreateAndAssociateImeContext() {
  if (child_content_ == nullptr || !::IsWindow(child_content_)) {
    return false;
  }

  // Restoring the thread default before creating a replacement context is
  // useful for preserving the current input method, but is not sufficient to
  // repair a stale TSF session on its own.
  ::ImmAssociateContextEx(child_content_, nullptr, IACE_DEFAULT);

  HIMC new_context = ::ImmCreateContext();
  if (new_context == nullptr) {
    return false;
  }
  if (ime_open_status_.has_value() &&
      ::ImmSetOpenStatus(new_context, ime_open_status_.value()) == FALSE) {
    ::ImmDestroyContext(new_context);
    return false;
  }
  if (ime_conversion_mode_.has_value() && ime_sentence_mode_.has_value()) {
    ::ImmSetConversionStatus(new_context, ime_conversion_mode_.value(),
                             ime_sentence_mode_.value());
  }

  HIMC replaced_context =
      ::ImmAssociateContext(child_content_, new_context);
  HIMC associated_context = ::ImmGetContext(child_content_);
  if (associated_context != nullptr) {
    ::ImmReleaseContext(child_content_, associated_context);
  }
  if (associated_context != new_context) {
    ::ImmAssociateContext(child_content_, replaced_context);
    ::ImmDestroyContext(new_context);
    return false;
  }

  owned_ime_context_ = new_context;
  owned_ime_window_ = child_content_;
  replaced_ime_context_ = replaced_context;
  return true;
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
