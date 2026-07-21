#ifndef RUNNER_SYSTEM_MEDIA_CONTROLS_H_
#define RUNNER_SYSTEM_MEDIA_CONTROLS_H_

#include <windows.h>

#include <memory>
#include <string>

constexpr UINT kSystemMediaCommandMessage = WM_APP + 0x120;

enum class SystemMediaCommand : WPARAM {
  kPlay = 1,
  kPause = 2,
  kPlayPause = 3,
  kNext = 4,
  kPrevious = 5,
};

struct SystemMediaState {
  bool has_track = false;
  bool is_playing = false;
  bool can_skip_previous = false;
  bool can_skip_next = false;
  std::string title;
  std::string artist;
  std::string album;
};

class SystemMediaControls {
 public:
  SystemMediaControls();
  ~SystemMediaControls();

  bool Initialize(HWND window);
  void Update(const SystemMediaState& state);
  void Clear();
  bool available() const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

const char* SystemMediaCommandName(WPARAM command);

#endif  // RUNNER_SYSTEM_MEDIA_CONTROLS_H_
