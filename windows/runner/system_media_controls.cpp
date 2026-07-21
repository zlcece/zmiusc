#include "system_media_controls.h"

#include <systemmediatransportcontrolsinterop.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/base.h>

namespace {

using winrt::Windows::Media::MediaPlaybackStatus;
using winrt::Windows::Media::MediaPlaybackType;
using winrt::Windows::Media::SystemMediaTransportControls;
using winrt::Windows::Media::SystemMediaTransportControlsButton;

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

}  // namespace

struct SystemMediaControls::Impl {
  HWND window = nullptr;
  SystemMediaTransportControls controls{nullptr};
  winrt::event_token button_pressed_token{};
  bool subscribed = false;
  std::string title;
  std::string artist;
  std::string album;
};

SystemMediaControls::SystemMediaControls() : impl_(std::make_unique<Impl>()) {}

SystemMediaControls::~SystemMediaControls() {
  if (!impl_->controls) {
    return;
  }
  try {
    if (impl_->subscribed) {
      impl_->controls.ButtonPressed(impl_->button_pressed_token);
    }
    impl_->controls.IsEnabled(false);
  } catch (...) {
  }
}

bool SystemMediaControls::Initialize(HWND window) {
  if (impl_->controls) {
    return true;
  }
  try {
    auto interop = winrt::get_activation_factory<
        SystemMediaTransportControls, ISystemMediaTransportControlsInterop>();
    winrt::check_hresult(interop->GetForWindow(
        window, winrt::guid_of<SystemMediaTransportControls>(),
        winrt::put_abi(impl_->controls)));
    impl_->window = window;
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
  if (!impl_->controls) {
    return;
  }
  try {
    impl_->controls.IsEnabled(state.has_track);
    impl_->controls.IsPlayEnabled(state.has_track);
    impl_->controls.IsPauseEnabled(state.has_track);
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
  if (!impl_->controls) {
    return;
  }
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

bool SystemMediaControls::available() const {
  return static_cast<bool>(impl_->controls);
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
  }
  return nullptr;
}
