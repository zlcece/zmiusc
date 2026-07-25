#include "flutter_window.h"

#include <algorithm>
#include <optional>
#include <shellapi.h>
#include <utility>
#include <windowsx.h>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

constexpr wchar_t kStartupRegistryKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kStartupValueName[] = L"Zmusic";

bool ReadBool(const flutter::EncodableMap& values, const char* key) {
  const auto iterator = values.find(flutter::EncodableValue(key));
  if (iterator == values.end()) {
    return false;
  }
  const bool* value = std::get_if<bool>(&iterator->second);
  return value != nullptr && *value;
}

std::string ReadString(const flutter::EncodableMap& values, const char* key) {
  const auto iterator = values.find(flutter::EncodableValue(key));
  if (iterator == values.end()) {
    return std::string();
  }
  const std::string* value = std::get_if<std::string>(&iterator->second);
  return value == nullptr ? std::string() : *value;
}

bool SetLaunchAtStartup(bool enabled) {
  HKEY key = nullptr;
  LONG result = ERROR_SUCCESS;
  if (enabled) {
    result = ::RegCreateKeyExW(HKEY_CURRENT_USER, kStartupRegistryKey, 0,
                               nullptr, REG_OPTION_NON_VOLATILE, KEY_SET_VALUE,
                               nullptr, &key, nullptr);
    if (result != ERROR_SUCCESS) {
      return false;
    }

    std::wstring executable_path(32768, L'\0');
    const DWORD path_length = ::GetModuleFileNameW(
        nullptr, executable_path.data(),
        static_cast<DWORD>(executable_path.size()));
    if (path_length == 0 ||
        path_length >= static_cast<DWORD>(executable_path.size())) {
      ::RegCloseKey(key);
      return false;
    }
    executable_path.resize(path_length);
    const std::wstring command = L"\"" + executable_path + L"\"";
    result = ::RegSetValueExW(
        key, kStartupValueName, 0, REG_SZ,
        reinterpret_cast<const BYTE*>(command.c_str()),
        static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  } else {
    result = ::RegOpenKeyExW(HKEY_CURRENT_USER, kStartupRegistryKey, 0,
                             KEY_SET_VALUE, &key);
    if (result == ERROR_FILE_NOT_FOUND) {
      return true;
    }
    if (result != ERROR_SUCCESS) {
      return false;
    }
    result = ::RegDeleteValueW(key, kStartupValueName);
    if (result == ERROR_FILE_NOT_FOUND) {
      result = ERROR_SUCCESS;
    }
  }

  ::RegCloseKey(key);
  return result == ERROR_SUCCESS;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             std::vector<std::string> initial_files)
    : project_(project), initial_files_(std::move(initial_files)) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  file_drop_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.zmusic.app/file_drop",
          &flutter::StandardMethodCodec::GetInstance());
  windows_settings_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.zmusic.app/windows_settings",
          &flutter::StandardMethodCodec::GetInstance());
  windows_settings_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "showTrayPlayer") {
          result->Success(flutter::EncodableValue(
              system_media_controls_ &&
              system_media_controls_->ShowTrayPlayerPopup()));
          return;
        }
        if (call.method_name() != "setLaunchAtStartup") {
          result->NotImplemented();
          return;
        }
        const bool* enabled = std::get_if<bool>(call.arguments());
        if (enabled == nullptr) {
          result->Error("invalid-arguments", "Expected a boolean value.");
          return;
        }
        if (!SetLaunchAtStartup(*enabled)) {
          result->Error("registry-write-failed",
                        "Unable to update the Windows startup entry.");
          return;
        }
        result->Success();
      });
  DragAcceptFiles(GetHandle(), TRUE);
  system_media_controls_ = std::make_unique<SystemMediaControls>();
  system_media_controls_->Initialize(GetHandle());
  media_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "com.zmusic.app/media_session",
          &flutter::StandardMethodCodec::GetInstance());
  media_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<
                 flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "initialize") {
          result->Success(flutter::EncodableValue(
              system_media_controls_ && system_media_controls_->available()));
          return;
        }
        if (call.method_name() == "clear") {
          if (system_media_controls_) {
            system_media_controls_->Clear();
          }
          result->Success();
          return;
        }
        if (call.method_name() == "updateState") {
          const auto* values =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (values == nullptr) {
            result->Error("invalid-arguments", "Expected a state map.");
            return;
          }
          if (system_media_controls_) {
            SystemMediaState state;
            state.has_track = ReadBool(*values, "hasTrack");
            state.is_playing = ReadBool(*values, "isPlaying");
            state.can_skip_previous =
                ReadBool(*values, "canSkipPrevious");
            state.can_skip_next = ReadBool(*values, "canSkipNext");
            const auto volume_iterator =
                values->find(flutter::EncodableValue("volume"));
            if (volume_iterator != values->end()) {
              if (const auto* volume =
                      std::get_if<double>(&volume_iterator->second)) {
                state.volume = *volume;
              }
            }
            state.title = ReadString(*values, "title");
            state.artist = ReadString(*values, "artist");
            state.album = ReadString(*values, "album");
            state.artwork_path = ReadString(*values, "artworkPath");
            system_media_controls_->Update(state);
          }
          result->Success();
          return;
        }
        result->NotImplemented();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([this]() {
    this->Show();
    this->SendInitialFiles();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  DragAcceptFiles(GetHandle(), FALSE);
  file_drop_channel_.reset();
  windows_settings_channel_.reset();
  media_channel_.reset();
  system_media_controls_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (system_media_controls_) {
    LRESULT result = 0;
    if (system_media_controls_->HandleWindowMessage(message, wparam, lparam,
                                                     &result)) {
      return result;
    }
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_COPYDATA: {
      const auto* copy_data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
      if (copy_data != nullptr &&
          copy_data->dwData == kZmusicFileOpenCopyDataId) {
        SendCopiedFilePaths(*copy_data);
        return TRUE;
      }
      break;
    }
    case WM_DROPFILES:
      SendDroppedFiles(wparam);
      return 0;
    case kSystemMediaCommandMessage:
      SendSystemMediaCommand(wparam);
      return 0;
    case kSystemMediaVolumeMessage:
      SendSystemMediaVolume(wparam);
      return 0;
    case WM_APPCOMMAND:
      if (!system_media_controls_ || !system_media_controls_->available()) {
        switch (GET_APPCOMMAND_LPARAM(lparam)) {
          case APPCOMMAND_MEDIA_PLAY_PAUSE:
            SendSystemMediaCommand(
                static_cast<WPARAM>(SystemMediaCommand::kPlayPause));
            return TRUE;
          case APPCOMMAND_MEDIA_PLAY:
            SendSystemMediaCommand(
                static_cast<WPARAM>(SystemMediaCommand::kPlay));
            return TRUE;
          case APPCOMMAND_MEDIA_PAUSE:
            SendSystemMediaCommand(
                static_cast<WPARAM>(SystemMediaCommand::kPause));
            return TRUE;
          case APPCOMMAND_MEDIA_NEXTTRACK:
            SendSystemMediaCommand(
                static_cast<WPARAM>(SystemMediaCommand::kNext));
            return TRUE;
          case APPCOMMAND_MEDIA_PREVIOUSTRACK:
            SendSystemMediaCommand(
                static_cast<WPARAM>(SystemMediaCommand::kPrevious));
            return TRUE;
        }
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::SendDroppedFiles(WPARAM drop_handle) {
  HDROP drop = reinterpret_cast<HDROP>(drop_handle);
  const UINT file_count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  flutter::EncodableList paths;
  paths.reserve(file_count);

  for (UINT index = 0; index < file_count; ++index) {
    const UINT path_length = DragQueryFileW(drop, index, nullptr, 0);
    std::wstring path(path_length + 1, L'\0');
    const UINT copied =
        DragQueryFileW(drop, index, path.data(), path_length + 1);
    if (copied == 0) {
      continue;
    }
    path.resize(copied);
    paths.emplace_back(Utf8FromUtf16(path.c_str()));
  }
  DragFinish(drop);

  SendFilePaths(std::move(paths));
}

void FlutterWindow::SendCopiedFilePaths(const COPYDATASTRUCT& copy_data) {
  if (copy_data.lpData == nullptr || copy_data.cbData == 0) {
    return;
  }
  const auto* current = static_cast<const char*>(copy_data.lpData);
  const auto* end = current + copy_data.cbData;
  flutter::EncodableList paths;
  while (current < end) {
    const auto* separator = std::find(current, end, '\0');
    if (separator != current) {
      paths.emplace_back(std::string(current, separator));
    }
    if (separator == end) {
      break;
    }
    current = separator + 1;
  }
  SendFilePaths(std::move(paths));
}

void FlutterWindow::SendInitialFiles() {
  flutter::EncodableList paths;
  paths.reserve(initial_files_.size());
  for (auto& path : initial_files_) {
    paths.emplace_back(std::move(path));
  }
  initial_files_.clear();
  SendFilePaths(std::move(paths));
}

void FlutterWindow::SendFilePaths(flutter::EncodableList paths) {
  if (file_drop_channel_ == nullptr || paths.empty()) {
    return;
  }
  file_drop_channel_->InvokeMethod(
      "openFiles",
      std::make_unique<flutter::EncodableValue>(std::move(paths)));
}

void FlutterWindow::SendSystemMediaCommand(WPARAM command) {
  if (!media_channel_) {
    return;
  }
  const char* name = SystemMediaCommandName(command);
  if (name == nullptr) {
    return;
  }
  media_channel_->InvokeMethod(
      "mediaButton",
      std::make_unique<flutter::EncodableValue>(std::string(name)));
}

void FlutterWindow::SendSystemMediaVolume(WPARAM volume) {
  if (!media_channel_) {
    return;
  }
  const double normalized =
      std::clamp(static_cast<double>(volume) / 1000.0, 0.0, 1.0);
  media_channel_->InvokeMethod(
      "setVolume", std::make_unique<flutter::EncodableValue>(normalized));
}
