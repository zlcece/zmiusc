#include "system_media_controls.h"

#include <dwmapi.h>
#include <shobjidl.h>
#include <systemmediatransportcontrolsinterop.h>
#include <wincodec.h>
#include <wrl/client.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/base.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <utility>

#include "resource.h"
#include "windows_tray_player_popup.h"

namespace {

using Microsoft::WRL::ComPtr;
using winrt::Windows::Media::MediaPlaybackStatus;
using winrt::Windows::Media::MediaPlaybackType;
using winrt::Windows::Media::SystemMediaTransportControls;
using winrt::Windows::Media::SystemMediaTransportControlsButton;

constexpr UINT kPreviousButtonId = 1;
constexpr UINT kPlayPauseButtonId = 2;
constexpr UINT kNextButtonId = 3;
constexpr int kTaskbarIconSize = 32;
constexpr UINT kMaximumArtworkDimension = 640;

UINT TaskbarButtonCreatedMessage() {
  static const UINT message = ::RegisterWindowMessage(L"TaskbarButtonCreated");
  return message;
}

WPARAM CommandForButton(SystemMediaTransportControlsButton button) {
  switch (button) {
    case SystemMediaTransportControlsButton::Play:
      return static_cast<WPARAM>(SystemMediaCommand::kPlay);
    case SystemMediaTransportControlsButton::Pause:
      return static_cast<WPARAM>(SystemMediaCommand::kPause);
    case SystemMediaTransportControlsButton::Next:
      return static_cast<WPARAM>(SystemMediaCommand::kNext);
    case SystemMediaTransportControlsButton::Previous:
      return static_cast<WPARAM>(SystemMediaCommand::kPrevious);
    default:
      return 0;
  }
}

HICON CreateTaskbarIcon(const wchar_t* glyph) {
  BITMAPV5HEADER header{};
  header.bV5Size = sizeof(header);
  header.bV5Width = kTaskbarIconSize;
  header.bV5Height = -kTaskbarIconSize;
  header.bV5Planes = 1;
  header.bV5BitCount = 32;
  header.bV5Compression = BI_BITFIELDS;
  header.bV5RedMask = 0x00FF0000;
  header.bV5GreenMask = 0x0000FF00;
  header.bV5BlueMask = 0x000000FF;
  header.bV5AlphaMask = 0xFF000000;

  void* pixels = nullptr;
  HDC screen = ::GetDC(nullptr);
  HBITMAP color = ::CreateDIBSection(
      screen, reinterpret_cast<BITMAPINFO*>(&header), DIB_RGB_COLORS, &pixels,
      nullptr, 0);
  ::ReleaseDC(nullptr, screen);
  if (color == nullptr || pixels == nullptr) {
    if (color != nullptr) {
      ::DeleteObject(color);
    }
    return nullptr;
  }

  HDC dc = ::CreateCompatibleDC(nullptr);
  HGDIOBJ previous_bitmap = ::SelectObject(dc, color);
  HFONT font = ::CreateFontW(
      22, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET,
      OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
      DEFAULT_PITCH | FF_DONTCARE, L"Segoe MDL2 Assets");
  HGDIOBJ previous_font = ::SelectObject(dc, font);
  ::SetBkMode(dc, TRANSPARENT);
  ::SetTextColor(dc, RGB(255, 255, 255));
  RECT bounds{0, 0, kTaskbarIconSize, kTaskbarIconSize};
  ::DrawTextW(dc, glyph, -1, &bounds,
              DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX);
  ::SelectObject(dc, previous_font);
  ::DeleteObject(font);
  ::SelectObject(dc, previous_bitmap);
  ::DeleteDC(dc);

  auto* values = static_cast<UINT32*>(pixels);
  for (int index = 0; index < kTaskbarIconSize * kTaskbarIconSize; ++index) {
    if ((values[index] & 0x00FFFFFF) != 0) {
      values[index] |= 0xFF000000;
    }
  }

  std::array<BYTE, 128> mask_bits{};
  HBITMAP mask = ::CreateBitmap(kTaskbarIconSize, kTaskbarIconSize, 1, 1,
                                mask_bits.data());
  ICONINFO info{};
  info.fIcon = TRUE;
  info.hbmColor = color;
  info.hbmMask = mask;
  HICON icon = ::CreateIconIndirect(&info);
  ::DeleteObject(mask);
  ::DeleteObject(color);
  return icon;
}

}  // namespace

struct SystemMediaControls::Impl {
  HWND window = nullptr;
  SystemMediaTransportControls controls{nullptr};
  winrt::event_token button_pressed_token{};
  bool subscribed = false;
  std::string title;
  std::string artist;
  std::string album;
  std::string artwork_path;
  SystemMediaState state;
  ComPtr<ITaskbarList3> taskbar;
  ComPtr<IWICImagingFactory> imaging_factory;
  HICON previous_icon = nullptr;
  HICON play_icon = nullptr;
  HICON pause_icon = nullptr;
  HICON next_icon = nullptr;
  HBITMAP artwork_bitmap = nullptr;
  UINT artwork_width = 0;
  UINT artwork_height = 0;
  bool taskbar_buttons_added = false;
  std::unique_ptr<WindowsTrayPlayerPopup> tray_popup;

  ~Impl() {
    if (artwork_bitmap != nullptr) {
      ::DeleteObject(artwork_bitmap);
    }
    if (previous_icon != nullptr) {
      ::DestroyIcon(previous_icon);
    }
    if (play_icon != nullptr) {
      ::DestroyIcon(play_icon);
    }
    if (pause_icon != nullptr) {
      ::DestroyIcon(pause_icon);
    }
    if (next_icon != nullptr) {
      ::DestroyIcon(next_icon);
    }
  }

  void InitializeTaskbar(HWND target_window) {
    window = target_window;
    TaskbarButtonCreatedMessage();
    BOOL enabled = TRUE;
    ::DwmSetWindowAttribute(window, DWMWA_FORCE_ICONIC_REPRESENTATION,
                            &enabled, sizeof(enabled));
    ::DwmSetWindowAttribute(window, DWMWA_HAS_ICONIC_BITMAP, &enabled,
                            sizeof(enabled));

    ComPtr<ITaskbarList3> candidate;
    if (SUCCEEDED(::CoCreateInstance(CLSID_TaskbarList, nullptr,
                                     CLSCTX_INPROC_SERVER,
                                     IID_PPV_ARGS(&candidate))) &&
        SUCCEEDED(candidate->HrInit())) {
      taskbar = std::move(candidate);
    }

    previous_icon = CreateTaskbarIcon(L"\uE892");
    play_icon = CreateTaskbarIcon(L"\uE768");
    pause_icon = CreateTaskbarIcon(L"\uE769");
    next_icon = CreateTaskbarIcon(L"\uE893");

    ComPtr<IWICImagingFactory> factory;
    HRESULT result = ::CoCreateInstance(
        CLSID_WICImagingFactory2, nullptr, CLSCTX_INPROC_SERVER,
        IID_PPV_ARGS(&factory));
    if (FAILED(result)) {
      result = ::CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                  CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(&factory));
    }
    if (SUCCEEDED(result)) {
      imaging_factory = std::move(factory);
    }

    tray_popup = std::make_unique<WindowsTrayPlayerPopup>();
    tray_popup->Initialize(
        window,
        [this](TrayPlayerAction action) {
          SystemMediaCommand command = SystemMediaCommand::kPlayPause;
          switch (action) {
            case TrayPlayerAction::kPrevious:
              command = SystemMediaCommand::kPrevious;
              break;
            case TrayPlayerAction::kTogglePlay:
              command = state.is_playing ? SystemMediaCommand::kPause
                                         : SystemMediaCommand::kPlay;
              break;
            case TrayPlayerAction::kNext:
              command = SystemMediaCommand::kNext;
              break;
            case TrayPlayerAction::kExit:
              command = SystemMediaCommand::kExit;
              break;
          }
          ::PostMessage(window, kSystemMediaCommandMessage,
                        static_cast<WPARAM>(command), 0);
        },
        [this](double volume) {
          const auto normalized = static_cast<WPARAM>(
              std::round(std::clamp(volume, 0.0, 1.0) * 1000));
          ::PostMessage(window, kSystemMediaVolumeMessage, normalized, 0);
        });
  }

  void UpdateTrayPopup() const {
    if (!tray_popup) {
      return;
    }
    tray_popup->Update(WindowsTrayPlayerState{
        state.has_track,
        state.is_playing,
        state.can_skip_previous,
        state.can_skip_next,
        state.volume,
        state.title,
    });
  }

  THUMBBUTTON TaskbarButton(UINT id,
                            HICON icon,
                            const wchar_t* tooltip,
                            bool enabled) const {
    THUMBBUTTON button{};
    button.dwMask = THB_ICON | THB_TOOLTIP | THB_FLAGS;
    button.iId = id;
    button.hIcon = icon;
    button.dwFlags = enabled ? THBF_ENABLED : THBF_DISABLED;
    ::wcscpy_s(button.szTip, tooltip);
    return button;
  }

  std::array<THUMBBUTTON, 3> TaskbarButtons() const {
    return {
        TaskbarButton(kPreviousButtonId, previous_icon, L"上一首",
                      state.has_track && state.can_skip_previous),
        TaskbarButton(kPlayPauseButtonId,
                      state.is_playing ? pause_icon : play_icon,
                      state.is_playing ? L"暂停" : L"播放", state.has_track),
        TaskbarButton(kNextButtonId, next_icon, L"下一首",
                      state.has_track && state.can_skip_next),
    };
  }

  void AddTaskbarButtons() {
    if (!taskbar || window == nullptr) {
      return;
    }
    auto buttons = TaskbarButtons();
    if (SUCCEEDED(taskbar->ThumbBarAddButtons(
            window, static_cast<UINT>(buttons.size()), buttons.data()))) {
      taskbar_buttons_added = true;
    }
  }

  void UpdateTaskbarButtons() {
    if (!taskbar || !taskbar_buttons_added) {
      return;
    }
    auto buttons = TaskbarButtons();
    taskbar->ThumbBarUpdateButtons(window, static_cast<UINT>(buttons.size()),
                                   buttons.data());
  }

  void SetWindowTitle() const {
    if (window == nullptr) {
      return;
    }
    ::SetWindowTextW(window, L"Zmusic");
  }

  void ClearArtwork() {
    if (artwork_bitmap != nullptr) {
      ::DeleteObject(artwork_bitmap);
      artwork_bitmap = nullptr;
    }
    artwork_width = 0;
    artwork_height = 0;
  }

  void LoadArtwork(const std::string& path) {
    ClearArtwork();
    if (!imaging_factory || path.empty()) {
      return;
    }

    ComPtr<IWICBitmapDecoder> decoder;
    const auto wide_path = winrt::to_hstring(path);
    if (FAILED(imaging_factory->CreateDecoderFromFilename(
            wide_path.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnLoad,
            &decoder))) {
      return;
    }
    ComPtr<IWICBitmapFrameDecode> frame;
    if (FAILED(decoder->GetFrame(0, &frame))) {
      return;
    }

    UINT source_width = 0;
    UINT source_height = 0;
    if (FAILED(frame->GetSize(&source_width, &source_height)) ||
        source_width == 0 || source_height == 0) {
      return;
    }
    const double scale = std::min(
        1.0, static_cast<double>(kMaximumArtworkDimension) /
                 static_cast<double>(std::max(source_width, source_height)));
    const UINT target_width = std::max(
        1U, static_cast<UINT>(std::round(source_width * scale)));
    const UINT target_height = std::max(
        1U, static_cast<UINT>(std::round(source_height * scale)));

    ComPtr<IWICBitmapScaler> scaler;
    if (FAILED(imaging_factory->CreateBitmapScaler(&scaler)) ||
        FAILED(scaler->Initialize(frame.Get(), target_width, target_height,
                                  WICBitmapInterpolationModeFant))) {
      return;
    }
    ComPtr<IWICFormatConverter> converter;
    if (FAILED(imaging_factory->CreateFormatConverter(&converter)) ||
        FAILED(converter->Initialize(
            scaler.Get(), GUID_WICPixelFormat32bppPBGRA,
            WICBitmapDitherTypeNone, nullptr, 0,
            WICBitmapPaletteTypeCustom))) {
      return;
    }

    BITMAPINFO bitmap_info{};
    bitmap_info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bitmap_info.bmiHeader.biWidth = static_cast<LONG>(target_width);
    bitmap_info.bmiHeader.biHeight = -static_cast<LONG>(target_height);
    bitmap_info.bmiHeader.biPlanes = 1;
    bitmap_info.bmiHeader.biBitCount = 32;
    bitmap_info.bmiHeader.biCompression = BI_RGB;
    void* pixels = nullptr;
    HDC screen = ::GetDC(nullptr);
    HBITMAP bitmap = ::CreateDIBSection(screen, &bitmap_info, DIB_RGB_COLORS,
                                        &pixels, nullptr, 0);
    ::ReleaseDC(nullptr, screen);
    if (bitmap == nullptr || pixels == nullptr) {
      if (bitmap != nullptr) {
        ::DeleteObject(bitmap);
      }
      return;
    }
    const UINT stride = target_width * 4;
    if (FAILED(converter->CopyPixels(nullptr, stride, stride * target_height,
                                     static_cast<BYTE*>(pixels)))) {
      ::DeleteObject(bitmap);
      return;
    }
    artwork_bitmap = bitmap;
    artwork_width = target_width;
    artwork_height = target_height;
  }

  HBITMAP CreatePreviewBitmap(UINT width, UINT height) const {
    if (width == 0 || height == 0) {
      return nullptr;
    }
    BITMAPINFO bitmap_info{};
    bitmap_info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bitmap_info.bmiHeader.biWidth = static_cast<LONG>(width);
    bitmap_info.bmiHeader.biHeight = -static_cast<LONG>(height);
    bitmap_info.bmiHeader.biPlanes = 1;
    bitmap_info.bmiHeader.biBitCount = 32;
    bitmap_info.bmiHeader.biCompression = BI_RGB;
    void* pixels = nullptr;
    HDC screen = ::GetDC(nullptr);
    HBITMAP preview = ::CreateDIBSection(screen, &bitmap_info, DIB_RGB_COLORS,
                                         &pixels, nullptr, 0);
    ::ReleaseDC(nullptr, screen);
    if (preview == nullptr || pixels == nullptr) {
      return nullptr;
    }

    HDC target = ::CreateCompatibleDC(nullptr);
    HGDIOBJ previous_target = ::SelectObject(target, preview);
    RECT bounds{0, 0, static_cast<LONG>(width), static_cast<LONG>(height)};
    HBRUSH background = ::CreateSolidBrush(RGB(10, 20, 17));
    ::FillRect(target, &bounds, background);
    ::DeleteObject(background);

    if (artwork_bitmap != nullptr && artwork_width > 0 && artwork_height > 0) {
      const double scale = std::min(
          static_cast<double>(width) / artwork_width,
          static_cast<double>(height) / artwork_height);
      const int destination_width =
          std::max(1, static_cast<int>(std::round(artwork_width * scale)));
      const int destination_height =
          std::max(1, static_cast<int>(std::round(artwork_height * scale)));
      const int x = (static_cast<int>(width) - destination_width) / 2;
      const int y = (static_cast<int>(height) - destination_height) / 2;
      HDC source = ::CreateCompatibleDC(nullptr);
      HGDIOBJ previous_source = ::SelectObject(source, artwork_bitmap);
      ::SetStretchBltMode(target, HALFTONE);
      ::SetBrushOrgEx(target, 0, 0, nullptr);
      ::StretchBlt(target, x, y, destination_width, destination_height, source,
                   0, 0, artwork_width, artwork_height, SRCCOPY);
      ::SelectObject(source, previous_source);
      ::DeleteDC(source);
    } else {
      HICON app_icon = static_cast<HICON>(::LoadImageW(
          ::GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON), IMAGE_ICON,
          64, 64, LR_DEFAULTCOLOR));
      if (app_icon != nullptr) {
        const int icon_size = static_cast<int>(std::min<UINT>(
            64, std::min(width, height) * 2 / 3));
        ::DrawIconEx(target, (static_cast<int>(width) - icon_size) / 2,
                     (static_cast<int>(height) - icon_size) / 2, app_icon,
                     icon_size, icon_size, 0, nullptr, DI_NORMAL);
        ::DestroyIcon(app_icon);
      }
    }

    ::SelectObject(target, previous_target);
    ::DeleteDC(target);
    return preview;
  }

  void InvalidateThumbnail() const {
    if (window != nullptr) {
      ::DwmInvalidateIconicBitmaps(window);
    }
  }
};

SystemMediaControls::SystemMediaControls() : impl_(std::make_unique<Impl>()) {}

SystemMediaControls::~SystemMediaControls() {
  if (impl_->controls) {
    try {
      if (impl_->subscribed) {
        impl_->controls.ButtonPressed(impl_->button_pressed_token);
      }
      impl_->controls.IsEnabled(false);
    } catch (...) {
    }
  }
}

bool SystemMediaControls::Initialize(HWND window) {
  if (impl_->window == nullptr) {
    impl_->InitializeTaskbar(window);
  }
  if (impl_->controls) {
    return true;
  }
  try {
    auto interop = winrt::get_activation_factory<
        SystemMediaTransportControls, ISystemMediaTransportControlsInterop>();
    winrt::check_hresult(interop->GetForWindow(
        window, winrt::guid_of<SystemMediaTransportControls>(),
        winrt::put_abi(impl_->controls)));
    impl_->button_pressed_token = impl_->controls.ButtonPressed(
        [window](const SystemMediaTransportControls&,
                 const winrt::Windows::Media::
                     SystemMediaTransportControlsButtonPressedEventArgs& args) {
          try {
            const WPARAM command = CommandForButton(args.Button());
            if (command != 0) {
              ::PostMessage(window, kSystemMediaCommandMessage, command, 0);
            }
          } catch (...) {
          }
        });
    impl_->subscribed = true;
    Clear();
    return true;
  } catch (...) {
    impl_->controls = nullptr;
    return false;
  }
}

void SystemMediaControls::Update(const SystemMediaState& state) {
  const bool title_changed = state.has_track != impl_->state.has_track ||
                             state.title != impl_->state.title;
  const bool buttons_changed =
      state.has_track != impl_->state.has_track ||
      state.is_playing != impl_->state.is_playing ||
      state.can_skip_previous != impl_->state.can_skip_previous ||
      state.can_skip_next != impl_->state.can_skip_next;
  const bool artwork_changed = state.artwork_path != impl_->artwork_path;
  impl_->state = state;
  impl_->UpdateTrayPopup();
  if (title_changed) {
    impl_->SetWindowTitle();
  }
  if (buttons_changed) {
    impl_->UpdateTaskbarButtons();
  }
  if (artwork_changed) {
    impl_->artwork_path = state.artwork_path;
    impl_->LoadArtwork(state.artwork_path);
    impl_->InvalidateThumbnail();
  }

  if (!impl_->controls) {
    return;
  }
  try {
    impl_->controls.IsEnabled(state.has_track);
    impl_->controls.IsPlayEnabled(state.has_track && !state.is_playing);
    impl_->controls.IsPauseEnabled(state.has_track && state.is_playing);
    impl_->controls.IsPreviousEnabled(state.has_track &&
                                      state.can_skip_previous);
    impl_->controls.IsNextEnabled(state.has_track && state.can_skip_next);

    if (!state.has_track) {
      Clear();
      return;
    }

    impl_->controls.PlaybackStatus(state.is_playing
                                       ? MediaPlaybackStatus::Playing
                                       : MediaPlaybackStatus::Paused);

    if (state.title == impl_->title && state.artist == impl_->artist &&
        state.album == impl_->album) {
      return;
    }
    auto updater = impl_->controls.DisplayUpdater();
    updater.Type(MediaPlaybackType::Music);
    auto properties = updater.MusicProperties();
    properties.Title(winrt::to_hstring(state.title));
    properties.Artist(winrt::to_hstring(state.artist));
    properties.AlbumTitle(winrt::to_hstring(state.album));
    updater.Update();
    impl_->title = state.title;
    impl_->artist = state.artist;
    impl_->album = state.album;
  } catch (...) {
  }
}

void SystemMediaControls::Clear() {
  impl_->state = SystemMediaState{};
  impl_->UpdateTrayPopup();
  impl_->artwork_path.clear();
  impl_->ClearArtwork();
  impl_->SetWindowTitle();
  impl_->UpdateTaskbarButtons();
  impl_->InvalidateThumbnail();

  if (impl_->controls) {
    try {
      impl_->controls.IsEnabled(false);
      impl_->controls.IsPlayEnabled(false);
      impl_->controls.IsPauseEnabled(false);
      impl_->controls.IsPreviousEnabled(false);
      impl_->controls.IsNextEnabled(false);
      impl_->controls.PlaybackStatus(MediaPlaybackStatus::Closed);
      impl_->controls.DisplayUpdater().ClearAll();
      impl_->title.clear();
      impl_->artist.clear();
      impl_->album.clear();
    } catch (...) {
    }
  }
}

bool SystemMediaControls::available() const {
  return static_cast<bool>(impl_->controls);
}

bool SystemMediaControls::ShowTrayPlayerPopup() {
  return impl_->tray_popup && impl_->tray_popup->Show();
}

bool SystemMediaControls::HandleWindowMessage(UINT message,
                                              WPARAM wparam,
                                              LPARAM lparam,
                                              LRESULT* result) {
  if (message == TaskbarButtonCreatedMessage()) {
    impl_->taskbar_buttons_added = false;
    impl_->AddTaskbarButtons();
    if (result != nullptr) {
      *result = 0;
    }
    return true;
  }

  if (message == WM_COMMAND && HIWORD(wparam) == THBN_CLICKED) {
    WPARAM command = 0;
    switch (LOWORD(wparam)) {
      case kPreviousButtonId:
        if (impl_->state.can_skip_previous) {
          command = static_cast<WPARAM>(SystemMediaCommand::kPrevious);
        }
        break;
      case kPlayPauseButtonId:
        if (impl_->state.has_track) {
          command = static_cast<WPARAM>(impl_->state.is_playing
                                            ? SystemMediaCommand::kPause
                                            : SystemMediaCommand::kPlay);
        }
        break;
      case kNextButtonId:
        if (impl_->state.can_skip_next) {
          command = static_cast<WPARAM>(SystemMediaCommand::kNext);
        }
        break;
    }
    if (command != 0 && impl_->window != nullptr) {
      ::PostMessage(impl_->window, kSystemMediaCommandMessage, command, 0);
    }
    if (result != nullptr) {
      *result = 0;
    }
    return true;
  }

  if (message == WM_DWMSENDICONICTHUMBNAIL) {
    const UINT maximum_width = HIWORD(lparam);
    const UINT maximum_height = LOWORD(lparam);
    const UINT side = std::max(1U, std::min(maximum_width, maximum_height));
    HBITMAP bitmap = impl_->CreatePreviewBitmap(side, side);
    if (bitmap != nullptr) {
      ::DwmSetIconicThumbnail(impl_->window, bitmap, 0);
      ::DeleteObject(bitmap);
    }
    if (result != nullptr) {
      *result = 0;
    }
    return true;
  }

  if (message == WM_DWMSENDICONICLIVEPREVIEWBITMAP) {
    RECT bounds{};
    if (::GetClientRect(impl_->window, &bounds)) {
      const LONG client_width = bounds.right - bounds.left;
      const LONG client_height = bounds.bottom - bounds.top;
      const UINT width = client_width > 0 ? static_cast<UINT>(client_width) : 1U;
      const UINT height =
          client_height > 0 ? static_cast<UINT>(client_height) : 1U;
      HBITMAP bitmap = impl_->CreatePreviewBitmap(width, height);
      if (bitmap != nullptr) {
        ::DwmSetIconicLivePreviewBitmap(impl_->window, bitmap, nullptr, 0);
        ::DeleteObject(bitmap);
      }
    }
    if (result != nullptr) {
      *result = 0;
    }
    return true;
  }

  return false;
}

const char* SystemMediaCommandName(WPARAM command) {
  switch (static_cast<SystemMediaCommand>(command)) {
    case SystemMediaCommand::kPlay:
      return "play";
    case SystemMediaCommand::kPause:
      return "pause";
    case SystemMediaCommand::kPlayPause:
      return "playPause";
    case SystemMediaCommand::kNext:
      return "next";
    case SystemMediaCommand::kPrevious:
      return "previous";
    case SystemMediaCommand::kExit:
      return "exit";
  }
  return nullptr;
}
