#include "windows_tray_player_popup.h"

#include <dwmapi.h>
#include <windowsx.h>
#include <winrt/base.h>

#include <algorithm>
#include <cmath>
#include <utility>

namespace {

constexpr wchar_t kPopupWindowClass[] = L"ZmusicTrayPlayerPopup";
constexpr int kPopupWidth = 236;
constexpr int kPopupHeight = 190;

bool UsesLightTheme() {
  DWORD value = 1;
  DWORD size = sizeof(value);
  const LONG result = ::RegGetValueW(
      HKEY_CURRENT_USER,
      L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
      L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &value, &size);
  return result != ERROR_SUCCESS || value != 0;
}

int Scale(int value, UINT dpi) {
  return ::MulDiv(value, static_cast<int>(dpi), 96);
}

RECT ScaledRect(int left, int top, int right, int bottom, UINT dpi) {
  return RECT{Scale(left, dpi), Scale(top, dpi), Scale(right, dpi),
              Scale(bottom, dpi)};
}

bool Contains(const RECT& rect, POINT point) {
  return ::PtInRect(&rect, point) != FALSE;
}

void DrawCenteredText(HDC dc,
                      const wchar_t* value,
                      RECT bounds,
                      HFONT font,
                      COLORREF color,
                      UINT flags = DT_CENTER | DT_VCENTER | DT_SINGLELINE) {
  HGDIOBJ previous_font = ::SelectObject(dc, font);
  ::SetBkMode(dc, TRANSPARENT);
  ::SetTextColor(dc, color);
  ::DrawTextW(dc, value, -1, &bounds, flags | DT_NOPREFIX);
  ::SelectObject(dc, previous_font);
}

}  // namespace

struct WindowsTrayPlayerPopup::Impl {
  HWND owner = nullptr;
  HWND window = nullptr;
  ActionCallback action_callback;
  VolumeCallback volume_callback;
  WindowsTrayPlayerState state;
  double last_nonzero_volume = 0.55;
  UINT dpi = 96;
  bool dragging_volume = false;

  ~Impl() {
    if (window != nullptr) {
      ::DestroyWindow(window);
    }
  }

  static LRESULT CALLBACK WindowProcedure(HWND hwnd,
                                          UINT message,
                                          WPARAM wparam,
                                          LPARAM lparam) {
    Impl* self = reinterpret_cast<Impl*>(
        ::GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    if (message == WM_NCCREATE) {
      const auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
      self = static_cast<Impl*>(create->lpCreateParams);
      ::SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                          reinterpret_cast<LONG_PTR>(self));
      self->window = hwnd;
    }
    return self == nullptr ? ::DefWindowProcW(hwnd, message, wparam, lparam)
                           : self->HandleMessage(message, wparam, lparam);
  }

  bool Initialize(HWND target_owner,
                  ActionCallback on_action,
                  VolumeCallback on_volume) {
    owner = target_owner;
    action_callback = std::move(on_action);
    volume_callback = std::move(on_volume);
    dpi = ::GetDpiForWindow(owner);
    if (dpi == 0) {
      dpi = 96;
    }

    WNDCLASSW window_class{};
    window_class.style = CS_DROPSHADOW;
    window_class.lpfnWndProc = WindowProcedure;
    window_class.hInstance = ::GetModuleHandleW(nullptr);
    window_class.hCursor = ::LoadCursorW(nullptr, IDC_ARROW);
    window_class.lpszClassName = kPopupWindowClass;
    if (::RegisterClassW(&window_class) == 0 &&
        ::GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
      return false;
    }

    window = ::CreateWindowExW(
        WS_EX_TOOLWINDOW | WS_EX_TOPMOST, kPopupWindowClass, L"", WS_POPUP, 0,
        0, Scale(kPopupWidth, dpi), Scale(kPopupHeight, dpi), owner, nullptr,
        ::GetModuleHandleW(nullptr), this);
    if (window == nullptr) {
      return false;
    }

    constexpr auto kDwmWindowCornerPreference =
        static_cast<DWMWINDOWATTRIBUTE>(33);
    constexpr DWORD kDwmRoundCornerPreference = 2;
    ::DwmSetWindowAttribute(window, kDwmWindowCornerPreference,
                            &kDwmRoundCornerPreference,
                            sizeof(kDwmRoundCornerPreference));
    return true;
  }

  LRESULT HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
    switch (message) {
      case WM_PAINT:
        Paint();
        return 0;
      case WM_ERASEBKGND:
        return 1;
      case WM_ACTIVATE:
        if (LOWORD(wparam) == WA_INACTIVE && !dragging_volume) {
          ::ShowWindow(window, SW_HIDE);
        }
        return 0;
      case WM_KEYDOWN:
        if (wparam == VK_ESCAPE) {
          ::ShowWindow(window, SW_HIDE);
          return 0;
        }
        break;
      case WM_LBUTTONDOWN:
        HandlePointer(POINT{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)}, true);
        return 0;
      case WM_MOUSEMOVE:
        if (dragging_volume) {
          SetVolumeFromPoint(GET_X_LPARAM(lparam));
          return 0;
        }
        break;
      case WM_LBUTTONUP:
        if (dragging_volume) {
          dragging_volume = false;
          ::ReleaseCapture();
          SetVolumeFromPoint(GET_X_LPARAM(lparam));
          return 0;
        }
        break;
      case WM_SETCURSOR:
        ::SetCursor(::LoadCursorW(nullptr, IDC_HAND));
        return TRUE;
      case WM_NCDESTROY:
        {
          const LRESULT result =
              ::DefWindowProcW(window, message, wparam, lparam);
          window = nullptr;
          return result;
        }
    }
    return ::DefWindowProcW(window, message, wparam, lparam);
  }

  void Update(const WindowsTrayPlayerState& value) {
    const bool changed =
        value.has_track != state.has_track ||
        value.is_playing != state.is_playing ||
        value.can_skip_previous != state.can_skip_previous ||
        value.can_skip_next != state.can_skip_next ||
        std::abs(value.volume - state.volume) > 0.0001 ||
        value.title != state.title;
    state = value;
    state.volume = std::clamp(state.volume, 0.0, 1.0);
    if (state.volume > 0) {
      last_nonzero_volume = state.volume;
    }
    if (changed && window != nullptr && ::IsWindowVisible(window)) {
      ::InvalidateRect(window, nullptr, FALSE);
    }
  }

  bool Show() {
    if (window == nullptr) {
      return false;
    }
    dpi = ::GetDpiForWindow(owner);
    if (dpi == 0) {
      dpi = 96;
    }
    const int width = Scale(kPopupWidth, dpi);
    const int height = Scale(kPopupHeight, dpi);
    POINT cursor{};
    ::GetCursorPos(&cursor);
    HMONITOR monitor = ::MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
    MONITORINFO monitor_info{};
    monitor_info.cbSize = sizeof(monitor_info);
    ::GetMonitorInfoW(monitor, &monitor_info);
    int left = cursor.x - width / 2;
    int top = cursor.y - height - Scale(8, dpi);
    left = std::clamp(left, static_cast<int>(monitor_info.rcWork.left),
                      static_cast<int>(monitor_info.rcWork.right) - width);
    top = std::clamp(top, static_cast<int>(monitor_info.rcWork.top),
                     static_cast<int>(monitor_info.rcWork.bottom) - height);

    HRGN region = ::CreateRoundRectRgn(0, 0, width + 1, height + 1,
                                       Scale(10, dpi), Scale(10, dpi));
    if (::SetWindowRgn(window, region, TRUE) == 0) {
      ::DeleteObject(region);
    }
    ::SetWindowPos(window, HWND_TOPMOST, left, top, width, height,
                   SWP_SHOWWINDOW);
    ::SetForegroundWindow(window);
    ::SetFocus(window);
    ::InvalidateRect(window, nullptr, FALSE);
    return true;
  }

  void Paint() const {
    PAINTSTRUCT paint{};
    HDC dc = ::BeginPaint(window, &paint);
    RECT client{};
    ::GetClientRect(window, &client);
    const bool light = UsesLightTheme();
    const COLORREF background = light ? RGB(250, 250, 250) : RGB(34, 38, 37);
    const COLORREF foreground = light ? RGB(75, 75, 75) : RGB(232, 235, 234);
    const COLORREF muted = light ? RGB(155, 155, 155) : RGB(126, 133, 130);
    const COLORREF divider = light ? RGB(220, 220, 220) : RGB(67, 73, 71);
    const COLORREF accent = RGB(35, 145, 111);
    HBRUSH background_brush = ::CreateSolidBrush(background);
    ::FillRect(dc, &client, background_brush);
    ::DeleteObject(background_brush);

    HPEN divider_pen = ::CreatePen(PS_SOLID, 1, divider);
    HGDIOBJ previous_pen = ::SelectObject(dc, divider_pen);
    ::MoveToEx(dc, 0, Scale(92, dpi), nullptr);
    ::LineTo(dc, client.right, Scale(92, dpi));
    ::MoveToEx(dc, 0, Scale(143, dpi), nullptr);
    ::LineTo(dc, client.right, Scale(143, dpi));
    ::SelectObject(dc, previous_pen);
    ::DeleteObject(divider_pen);

    HFONT icon_font = ::CreateFontW(
        Scale(22, dpi), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE,
        L"Segoe MDL2 Assets");
    HFONT text_font = ::CreateFontW(
        Scale(14, dpi), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
        DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
    DrawCircleButton(dc, ScaledRect(31, 9, 69, 47, dpi), L"\uE892",
                     icon_font, state.has_track && state.can_skip_previous,
                     foreground, muted);
    DrawCircleButton(dc, ScaledRect(99, 5, 143, 49, dpi),
                     state.is_playing ? L"\uE769" : L"\uE768", icon_font,
                     state.has_track, foreground, muted);
    DrawCircleButton(dc, ScaledRect(167, 9, 205, 47, dpi), L"\uE893",
                     icon_font, state.has_track && state.can_skip_next,
                     foreground, muted);

    const auto title = state.has_track && !state.title.empty()
                           ? winrt::to_hstring(state.title)
                           : winrt::hstring(L"暂无播放");
    DrawCenteredText(dc, title.c_str(), ScaledRect(12, 55, 224, 87, dpi),
                     text_font, state.has_track ? foreground : muted,
                     DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);

    DrawCenteredText(dc, state.volume <= 0 ? L"\uE74F" : L"\uE767",
                     ScaledRect(8, 101, 38, 133, dpi), icon_font, foreground);
    DrawVolumeSlider(dc, foreground, muted, accent);
    DrawCenteredText(dc, L"退出", ScaledRect(0, 145, kPopupWidth, 188, dpi),
                     text_font, foreground);

    ::DeleteObject(text_font);
    ::DeleteObject(icon_font);
    ::EndPaint(window, &paint);
  }

  void DrawCircleButton(HDC dc,
                        RECT bounds,
                        const wchar_t* glyph,
                        HFONT font,
                        bool enabled,
                        COLORREF foreground,
                        COLORREF muted) const {
    const COLORREF color = enabled ? foreground : muted;
    HPEN pen = ::CreatePen(PS_SOLID, Scale(2, dpi), color);
    HGDIOBJ previous_pen = ::SelectObject(dc, pen);
    HGDIOBJ previous_brush = ::SelectObject(dc, ::GetStockObject(NULL_BRUSH));
    ::Ellipse(dc, bounds.left, bounds.top, bounds.right, bounds.bottom);
    ::SelectObject(dc, previous_brush);
    ::SelectObject(dc, previous_pen);
    ::DeleteObject(pen);
    DrawCenteredText(dc, glyph, bounds, font, color);
  }

  void DrawVolumeSlider(HDC dc,
                        COLORREF foreground,
                        COLORREF muted,
                        COLORREF accent) const {
    const RECT track = VolumeTrack();
    const int center_y = (track.top + track.bottom) / 2;
    HPEN base_pen = ::CreatePen(PS_SOLID, Scale(2, dpi), muted);
    HGDIOBJ previous_pen = ::SelectObject(dc, base_pen);
    ::MoveToEx(dc, track.left, center_y, nullptr);
    ::LineTo(dc, track.right, center_y);
    ::SelectObject(dc, previous_pen);
    ::DeleteObject(base_pen);

    const int thumb_x = track.left + static_cast<int>(
        std::round((track.right - track.left) * state.volume));
    HPEN value_pen = ::CreatePen(PS_SOLID, Scale(2, dpi), accent);
    previous_pen = ::SelectObject(dc, value_pen);
    ::MoveToEx(dc, track.left, center_y, nullptr);
    ::LineTo(dc, thumb_x, center_y);
    ::SelectObject(dc, previous_pen);
    ::DeleteObject(value_pen);
    HBRUSH thumb_brush = ::CreateSolidBrush(foreground);
    HGDIOBJ previous_brush = ::SelectObject(dc, thumb_brush);
    const int radius = Scale(4, dpi);
    ::Ellipse(dc, thumb_x - radius, center_y - radius, thumb_x + radius + 1,
              center_y + radius + 1);
    ::SelectObject(dc, previous_brush);
    ::DeleteObject(thumb_brush);
  }

  RECT VolumeTrack() const {
    return ScaledRect(48, 104, 222, 130, dpi);
  }

  void HandlePointer(POINT point, bool pressed) {
    if (!pressed) {
      return;
    }
    if (Contains(ScaledRect(28, 6, 72, 51, dpi), point)) {
      Dispatch(TrayPlayerAction::kPrevious,
               state.has_track && state.can_skip_previous);
      return;
    }
    if (Contains(ScaledRect(95, 3, 147, 52, dpi), point)) {
      Dispatch(TrayPlayerAction::kTogglePlay, state.has_track);
      return;
    }
    if (Contains(ScaledRect(164, 6, 208, 51, dpi), point)) {
      Dispatch(TrayPlayerAction::kNext,
               state.has_track && state.can_skip_next);
      return;
    }
    if (Contains(ScaledRect(5, 98, 40, 136, dpi), point)) {
      SetVolume(state.volume <= 0 ? last_nonzero_volume : 0);
      return;
    }
    if (Contains(ScaledRect(42, 96, 229, 138, dpi), point)) {
      dragging_volume = true;
      ::SetCapture(window);
      SetVolumeFromPoint(point.x);
      return;
    }
    if (Contains(ScaledRect(0, 143, kPopupWidth, kPopupHeight, dpi), point)) {
      ::ShowWindow(window, SW_HIDE);
      Dispatch(TrayPlayerAction::kExit, true);
    }
  }

  void SetVolumeFromPoint(int x) {
    const RECT track = VolumeTrack();
    const double value = static_cast<double>(x - track.left) /
                         static_cast<double>(track.right - track.left);
    SetVolume(value);
  }

  void SetVolume(double value) {
    state.volume = std::clamp(value, 0.0, 1.0);
    if (state.volume > 0) {
      last_nonzero_volume = state.volume;
    }
    if (volume_callback) {
      volume_callback(state.volume);
    }
    ::InvalidateRect(window, nullptr, FALSE);
  }

  void Dispatch(TrayPlayerAction action, bool enabled) const {
    if (enabled && action_callback) {
      action_callback(action);
    }
  }
};

WindowsTrayPlayerPopup::WindowsTrayPlayerPopup()
    : impl_(std::make_unique<Impl>()) {}

WindowsTrayPlayerPopup::~WindowsTrayPlayerPopup() = default;

bool WindowsTrayPlayerPopup::Initialize(HWND owner,
                                        ActionCallback action_callback,
                                        VolumeCallback volume_callback) {
  return impl_->Initialize(owner, std::move(action_callback),
                           std::move(volume_callback));
}

void WindowsTrayPlayerPopup::Update(const WindowsTrayPlayerState& state) {
  impl_->Update(state);
}

bool WindowsTrayPlayerPopup::Show() {
  return impl_->Show();
}
