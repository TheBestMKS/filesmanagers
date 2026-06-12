# Android Runner

Manual Android runner for the Flutter shell with native `crypt_core`
integration.

## Target Compatibility

- Android 7.0 and newer.
- `minSdk = 24`.
- `targetSdk = 34`.
- `compileSdk = 36`.

## What Is Wired

- Flutter Android embedding v2.
- Kotlin `MainActivity`.
- `System.loadLibrary("crypt_core")`.
- NDK/CMake build that includes `core/crypt_core`.
- Release APK packaging for `armeabi-v7a`, `arm64-v8a`, and `x86_64`.
- Manifest permissions for network access and media/external file browsing.

## Required Local Setup

Create `android/local.properties` from `android/local.properties.example` and set:

- `sdk.dir`
- `flutter.sdk`

The current workstation uses:

```properties
sdk.dir=C:/Users/thebe/AppData/Local/Android/Sdk
flutter.sdk=N:/Codex/filesmanagers/tooling/flutter/flutter
```

## Build Commands

From `app/flutter_shell`:

```powershell
flutter pub get
flutter build apk --release
```

The APK is written to:

```text
build/app/outputs/flutter-apk/app-release.apk
```

## Signing

`release` currently uses the debug signing config so the APK is convenient for
local installation and testing. Replace it with a private release keystore before
publishing.

## File Access

The app exposes Android root, `/storage/emulated/0`, and the hidden app storage
location in the explorer. New Android versions may still require runtime grants
or SAF-style integration for broad phone-file access; this runner currently
declares the required manifest permissions but does not yet show a native
runtime permission prompt.
