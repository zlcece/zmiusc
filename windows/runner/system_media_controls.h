#ifndef RUNNER_SYSTEM_MEDIA_CONTROLS_H_
#define RUNNER_SYSTEM_MEDIA_CONTROLS_H_

#include <windows.h>

#include <memory>
#include <string>

constexpr UINT kSystemMediaCommandMessage = WM_APP + 0x120;
constexpr UINT kSystemMediaVolumeMessage = WM_APP + 0x121;

enum class SystemMediaCommand : WPARAM {
  kPlay = 1,
  kPause = 2,
  kPlayPause = 3,
  kNext = 4,
  kPrevious = 5,
  kExit = 6,
};

struct SystemMediaState {
  bool has_track = false;
  bool is_playing = false;
  bool can_skip_previous = false;
  bool can_skip_next = false;
  double volume = 0.55;
  std::string title;
  std::string artist;
  std::string album;
  std::string artwork_path;
};

class SystemMediaControls {
 public:
  SystemMediaControls();
  ~SystemMediaControls();

  bool Initialize(HWND window);
  void Update(const SystemMediaState& state);
  void Clear();
  bool available() const;
  bool ShowTrayPlayerPopup();
  bool HandleWindowMessage(UINT message,
                           WPARAM wparam,
                           LPARAM lparam,
                           LRESULT* result);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

const char* SystemMediaCommandName(WPARAM command);

#endif  // RUNNER_SYSTEM_MEDIA_CONTROLS_H_
