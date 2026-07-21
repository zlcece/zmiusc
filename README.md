# Zmusic

Zmusic is a cross-platform streaming music player built with Flutter.

## Platforms

- Windows
- Android
- iOS
- macOS

iOS and macOS packaging require macOS, Xcode, and CocoaPods. Windows packaging requires Visual Studio with the Desktop development with C++ workload. Android packaging requires Android SDK cmdline-tools.

## Features

- Add custom stream URLs with title, artist, album, and cover URL.
- Add Navidrome or other Subsonic-compatible servers.
- Test server connectivity with Subsonic `ping`.
- Search songs through Subsonic `search3`.
- Play direct stream URLs and Subsonic `stream` URLs.
- Queue playback, previous/next, seek, and volume controls.
- Persist server and custom stream configuration locally.
- Store server passwords with Flutter secure storage instead of plain preferences.

## Navidrome

Use the base server URL, for example:

```text
https://music.example.com
http://192.168.1.20:4533
```

Zmusic calls `/rest/*.view` endpoints and uses Subsonic token authentication with `u`, `t`, `s`, `v`, `c`, and `f=json`.

## Development

```powershell
flutter pub get
flutter analyze
flutter test
flutter run -d windows
# Run this command on macOS:
flutter run -d macos
```

Local HTTP streams are enabled for Android, iOS, and macOS because self-hosted music servers often run on LAN HTTP. Prefer HTTPS when exposing a server outside your trusted network.
