#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>
#include <vector>

#include "win32_window.h"
#include "system_media_controls.h"

constexpr ULONG_PTR kZmusicFileOpenCopyDataId = 0x5A4D5553;

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project,
                         std::vector<std::string> initial_files = {});
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;
  std::vector<std::string> initial_files_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      media_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      file_drop_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      windows_settings_channel_;
  std::unique_ptr<SystemMediaControls> system_media_controls_;

  void SendSystemMediaCommand(WPARAM command);
  void SendDroppedFiles(WPARAM drop_handle);
  void SendCopiedFilePaths(const COPYDATASTRUCT& copy_data);
  void SendInitialFiles();
  void SendFilePaths(flutter::EncodableList paths);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
