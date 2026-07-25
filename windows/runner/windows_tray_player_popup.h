#ifndef RUNNER_WINDOWS_TRAY_PLAYER_POPUP_H_
#define RUNNER_WINDOWS_TRAY_PLAYER_POPUP_H_

#include <windows.h>

#include <functional>
#include <memory>
#include <string>

enum class TrayPlayerAction {
  kPrevious,
  kTogglePlay,
  kNext,
  kExit,
};

struct WindowsTrayPlayerState {
  bool has_track = false;
  bool is_playing = false;
  bool can_skip_previous = false;
  bool can_skip_next = false;
  double volume = 0.55;
  std::string title;
};

class WindowsTrayPlayerPopup {
 public:
  using ActionCallback = std::function<void(TrayPlayerAction)>;
  using VolumeCallback = std::function<void(double)>;

  WindowsTrayPlayerPopup();
  ~WindowsTrayPlayerPopup();

  bool Initialize(HWND owner,
                  ActionCallback action_callback,
                  VolumeCallback volume_callback);
  void Update(const WindowsTrayPlayerState& state);
  bool Show();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_WINDOWS_TRAY_PLAYER_POPUP_H_
