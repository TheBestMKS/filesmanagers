#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>
#include <vector>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void AddTrayIcon();
  void RemoveTrayIcon();
  void RestoreFromTray();
  void ShowTrayMenu();
  void SendMediaCommand(const std::string& command);
  void UpdateMiniPlayerState(bool active, bool playing,
                             const std::string& title,
                             const std::string& subtitle,
                             const std::string& kind,
                             std::vector<uint8_t> artwork_bytes);
  void UpdateMiniPlayerVisibility();
  void EnsureMiniPlayerWindow();
  void ShowMiniPlayer();
  void HideMiniPlayer();
  void UpdateMiniPlayerControls();
  void PaintMiniPlayer(HWND window);
  static LRESULT CALLBACK MiniPlayerWndProc(HWND window, UINT message,
                                            WPARAM wparam, LPARAM lparam);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;
  bool minimize_to_tray_on_close_ = true;
  bool tray_icon_added_ = false;
  bool exiting_from_tray_ = false;
  HWND mini_player_window_ = nullptr;
  bool media_active_ = false;
  bool media_playing_ = false;
  std::wstring media_title_;
  std::wstring media_subtitle_;
  std::wstring media_kind_;
  std::vector<uint8_t> media_artwork_bytes_;
  ULONG_PTR gdiplus_token_ = 0;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
