#include "flutter_window.h"

#include <optional>
#include <shellapi.h>
#include <string>
#include <variant>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"
#include <flutter/standard_method_codec.h>

namespace {

constexpr wchar_t kWindowRegistryPath[] =
    L"Software\\filesmanagers\\FileManager";
constexpr UINT kTrayMessage = WM_APP + 42;
constexpr UINT_PTR kTrayIconId = 1001;
constexpr UINT kTrayExitCommand = 40001;
constexpr UINT kMiniPreviousCommand = 40101;
constexpr UINT kMiniPlayPauseCommand = 40102;
constexpr UINT kMiniNextCommand = 40103;
constexpr UINT kMiniStopCommand = 40104;
constexpr UINT kMiniRestoreCommand = 40105;
constexpr wchar_t kMiniPlayerClass[] = L"FilesManagersMiniPlayerWindow";

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return std::wstring();
  }
  int size = MultiByteToWideChar(CP_UTF8, 0, value.c_str(),
                                 static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0) {
    return std::wstring();
  }
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.c_str(),
                      static_cast<int>(value.size()), result.data(), size);
  return result;
}

void SaveWindowPlacement(HWND hwnd) {
  if (hwnd == nullptr || IsIconic(hwnd)) {
    return;
  }
  RECT rect{};
  if (!GetWindowRect(hwnd, &rect)) {
    return;
  }
  const DWORD width = static_cast<DWORD>(rect.right - rect.left);
  const DWORD height = static_cast<DWORD>(rect.bottom - rect.top);
  if (width < 320 || height < 240) {
    return;
  }
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kWindowRegistryPath, 0, nullptr, 0,
                      KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
    return;
  }
  const DWORD x = static_cast<DWORD>(rect.left);
  const DWORD y = static_cast<DWORD>(rect.top);
  RegSetValueExW(key, L"x", 0, REG_DWORD,
                 reinterpret_cast<const BYTE*>(&x), sizeof(x));
  RegSetValueExW(key, L"y", 0, REG_DWORD,
                 reinterpret_cast<const BYTE*>(&y), sizeof(y));
  RegSetValueExW(key, L"width", 0, REG_DWORD,
                 reinterpret_cast<const BYTE*>(&width), sizeof(width));
  RegSetValueExW(key, L"height", 0, REG_DWORD,
                 reinterpret_cast<const BYTE*>(&height), sizeof(height));
  RegCloseKey(key);
}

bool ReadBool(const flutter::EncodableMap& map, const char* key,
              bool default_value = false) {
  auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) {
    return default_value;
  }
  const auto* value = std::get_if<bool>(&it->second);
  return value == nullptr ? default_value : *value;
}

std::string ReadString(const flutter::EncodableMap& map, const char* key) {
  auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) {
    return std::string();
  }
  const auto* value = std::get_if<std::string>(&it->second);
  return value == nullptr ? std::string() : *value;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

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
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "filesmanagers/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "setTopMost") {
          const auto* enabled = std::get_if<bool>(call.arguments());
          if (enabled == nullptr) {
            result->Error("bad_args", "Expected boolean topmost flag.");
            return;
          }
          SetWindowPos(GetHandle(), *enabled ? HWND_TOPMOST : HWND_NOTOPMOST,
                       0, 0, 0, 0,
                       SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
          result->Success();
          return;
        }
        if (call.method_name() == "setMinimizeToTrayOnClose") {
          const auto* enabled = std::get_if<bool>(call.arguments());
          if (enabled == nullptr) {
            result->Error("bad_args", "Expected boolean tray flag.");
            return;
          }
          minimize_to_tray_on_close_ = *enabled;
          result->Success();
          return;
        }
        if (call.method_name() == "updateMiniPlayer") {
          const auto* map =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (map == nullptr) {
            result->Error("bad_args", "Expected mini-player state map.");
            return;
          }
          UpdateMiniPlayerState(ReadBool(*map, "active"),
                                ReadBool(*map, "playing"),
                                ReadString(*map, "title"));
          result->Success();
          return;
        }
        if (call.method_name() != "setTitle") {
          result->NotImplemented();
          return;
        }
        const auto* title = std::get_if<std::string>(call.arguments());
        if (title == nullptr) {
          result->Error("bad_args", "Expected UTF-8 title string.");
          return;
        }
        SetWindowText(GetHandle(), Utf8ToWide(*title).c_str());
        result->Success();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  SaveWindowPlacement(GetHandle());
  HideMiniPlayer();
  if (mini_player_window_ != nullptr) {
    DestroyWindow(mini_player_window_);
    mini_player_window_ = nullptr;
    mini_title_label_ = nullptr;
    mini_play_button_ = nullptr;
  }
  RemoveTrayIcon();
  if (flutter_controller_) {
    window_channel_ = nullptr;
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::AddTrayIcon() {
  if (tray_icon_added_) {
    return;
  }
  NOTIFYICONDATAW nid{};
  nid.cbSize = sizeof(nid);
  nid.hWnd = GetHandle();
  nid.uID = kTrayIconId;
  nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  nid.uCallbackMessage = kTrayMessage;
  nid.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(nid.szTip, L"Files Managers");
  if (Shell_NotifyIconW(NIM_ADD, &nid)) {
    tray_icon_added_ = true;
  }
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_icon_added_) {
    return;
  }
  NOTIFYICONDATAW nid{};
  nid.cbSize = sizeof(nid);
  nid.hWnd = GetHandle();
  nid.uID = kTrayIconId;
  Shell_NotifyIconW(NIM_DELETE, &nid);
  tray_icon_added_ = false;
}

void FlutterWindow::RestoreFromTray() {
  HideMiniPlayer();
  RemoveTrayIcon();
  ShowWindow(GetHandle(), SW_SHOWNORMAL);
  SetForegroundWindow(GetHandle());
}

void FlutterWindow::ShowTrayMenu() {
  POINT point{};
  GetCursorPos(&point);
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }
  AppendMenuW(menu, MF_STRING, kTrayExitCommand, L"Exit");
  SetForegroundWindow(GetHandle());
  const UINT command = TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON, point.x, point.y, 0,
      GetHandle(), nullptr);
  DestroyMenu(menu);
  if (command == kTrayExitCommand) {
    exiting_from_tray_ = true;
    RemoveTrayIcon();
    DestroyWindow(GetHandle());
  }
}

void FlutterWindow::SendMediaCommand(const std::string& command) {
  if (!window_channel_) {
    return;
  }
  window_channel_->InvokeMethod(
      "mediaControl", std::make_unique<flutter::EncodableValue>(command));
}

void FlutterWindow::UpdateMiniPlayerState(bool active, bool playing,
                                          const std::string& title) {
  media_active_ = active;
  media_playing_ = playing;
  media_title_ = Utf8ToWide(title.empty() ? "Files Managers media" : title);
  UpdateMiniPlayerControls();
  UpdateMiniPlayerVisibility();
}

void FlutterWindow::UpdateMiniPlayerVisibility() {
  if (tray_icon_added_ && media_active_ && !IsWindowVisible(GetHandle())) {
    ShowMiniPlayer();
  } else {
    HideMiniPlayer();
  }
}

void FlutterWindow::EnsureMiniPlayerWindow() {
  if (mini_player_window_ != nullptr) {
    return;
  }

  static bool registered = false;
  if (!registered) {
    WNDCLASSW window_class{};
    window_class.lpfnWndProc = FlutterWindow::MiniPlayerWndProc;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.lpszClassName = kMiniPlayerClass;
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    RegisterClassW(&window_class);
    registered = true;
  }

  RECT work_area{};
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work_area, 0);
  const int width = 340;
  const int height = 116;
  const int x = work_area.right - width - 18;
  const int y = work_area.bottom - height - 18;

  mini_player_window_ = CreateWindowExW(
      WS_EX_TOOLWINDOW | WS_EX_TOPMOST, kMiniPlayerClass, L"Files Managers",
      WS_POPUP | WS_BORDER, x, y, width, height, GetHandle(), nullptr,
      GetModuleHandle(nullptr), this);
  if (mini_player_window_ == nullptr) {
    return;
  }

  mini_title_label_ = CreateWindowExW(
      0, L"STATIC", L"Files Managers media", WS_CHILD | WS_VISIBLE | SS_LEFT,
      12, 10, width - 24, 28, mini_player_window_, nullptr,
      GetModuleHandle(nullptr), nullptr);
  CreateWindowExW(0, L"BUTTON", L"Prev", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                  12, 58, 58, 34, mini_player_window_,
                  reinterpret_cast<HMENU>(
                      static_cast<UINT_PTR>(kMiniPreviousCommand)),
                  GetModuleHandle(nullptr), nullptr);
  mini_play_button_ = CreateWindowExW(
      0, L"BUTTON", L"Play", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 78, 58, 66,
      34, mini_player_window_,
      reinterpret_cast<HMENU>(static_cast<UINT_PTR>(kMiniPlayPauseCommand)),
      GetModuleHandle(nullptr), nullptr);
  CreateWindowExW(0, L"BUTTON", L"Next", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                  152, 58, 58, 34, mini_player_window_,
                  reinterpret_cast<HMENU>(
                      static_cast<UINT_PTR>(kMiniNextCommand)),
                  GetModuleHandle(nullptr), nullptr);
  CreateWindowExW(0, L"BUTTON", L"Stop", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                  218, 58, 54, 34, mini_player_window_,
                  reinterpret_cast<HMENU>(
                      static_cast<UINT_PTR>(kMiniStopCommand)),
                  GetModuleHandle(nullptr), nullptr);
  CreateWindowExW(0, L"BUTTON", L"Open", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON,
                  280, 58, 48, 34, mini_player_window_,
                  reinterpret_cast<HMENU>(
                      static_cast<UINT_PTR>(kMiniRestoreCommand)),
                  GetModuleHandle(nullptr), nullptr);
  UpdateMiniPlayerControls();
}

void FlutterWindow::ShowMiniPlayer() {
  EnsureMiniPlayerWindow();
  if (mini_player_window_ == nullptr) {
    return;
  }
  UpdateMiniPlayerControls();
  ShowWindow(mini_player_window_, SW_SHOWNOACTIVATE);
  SetWindowPos(mini_player_window_, HWND_TOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

void FlutterWindow::HideMiniPlayer() {
  if (mini_player_window_ != nullptr) {
    ShowWindow(mini_player_window_, SW_HIDE);
  }
}

void FlutterWindow::UpdateMiniPlayerControls() {
  if (mini_title_label_ != nullptr) {
    SetWindowTextW(mini_title_label_,
                   media_title_.empty() ? L"Files Managers media"
                                        : media_title_.c_str());
  }
  if (mini_play_button_ != nullptr) {
    SetWindowTextW(mini_play_button_, media_playing_ ? L"Pause" : L"Play");
  }
}

LRESULT CALLBACK FlutterWindow::MiniPlayerWndProc(HWND window, UINT message,
                                                  WPARAM wparam,
                                                  LPARAM lparam) {
  auto* self =
      reinterpret_cast<FlutterWindow*>(GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    self = reinterpret_cast<FlutterWindow*>(create->lpCreateParams);
    SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  }
  if (self == nullptr) {
    return DefWindowProcW(window, message, wparam, lparam);
  }

  switch (message) {
    case WM_COMMAND:
      switch (LOWORD(wparam)) {
        case kMiniPreviousCommand:
          self->SendMediaCommand("previous");
          return 0;
        case kMiniPlayPauseCommand:
          self->SendMediaCommand("playPause");
          return 0;
        case kMiniNextCommand:
          self->SendMediaCommand("next");
          return 0;
        case kMiniStopCommand:
          self->SendMediaCommand("stop");
          return 0;
        case kMiniRestoreCommand:
          self->RestoreFromTray();
          return 0;
        default:
          break;
      }
      break;
    case WM_APPCOMMAND: {
      const int command = GET_APPCOMMAND_LPARAM(lparam);
      switch (command) {
        case APPCOMMAND_MEDIA_NEXTTRACK:
          self->SendMediaCommand("next");
          return 1;
        case APPCOMMAND_MEDIA_PREVIOUSTRACK:
          self->SendMediaCommand("previous");
          return 1;
        case APPCOMMAND_MEDIA_PLAY_PAUSE:
          self->SendMediaCommand("playPause");
          return 1;
        case APPCOMMAND_MEDIA_PLAY:
          self->SendMediaCommand("play");
          return 1;
        case APPCOMMAND_MEDIA_PAUSE:
          self->SendMediaCommand("pause");
          return 1;
        case APPCOMMAND_MEDIA_STOP:
          self->SendMediaCommand("stop");
          return 1;
        default:
          break;
      }
      break;
    }
    case WM_LBUTTONDOWN:
      ReleaseCapture();
      SendMessageW(window, WM_NCLBUTTONDOWN, HTCAPTION, 0);
      return 0;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_APPCOMMAND) {
    const int command = GET_APPCOMMAND_LPARAM(lparam);
    switch (command) {
      case APPCOMMAND_MEDIA_NEXTTRACK:
        SendMediaCommand("next");
        return 1;
      case APPCOMMAND_MEDIA_PREVIOUSTRACK:
        SendMediaCommand("previous");
        return 1;
      case APPCOMMAND_MEDIA_PLAY_PAUSE:
        SendMediaCommand("playPause");
        return 1;
      case APPCOMMAND_MEDIA_PLAY:
        SendMediaCommand("play");
        return 1;
      case APPCOMMAND_MEDIA_PAUSE:
        SendMediaCommand("pause");
        return 1;
      case APPCOMMAND_MEDIA_STOP:
        SendMediaCommand("stop");
        return 1;
      default:
        break;
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
    case WM_CLOSE:
      if (minimize_to_tray_on_close_ && !exiting_from_tray_) {
        SaveWindowPlacement(hwnd);
        AddTrayIcon();
        ShowWindow(hwnd, SW_HIDE);
        UpdateMiniPlayerVisibility();
        return 0;
      }
      break;
    case kTrayMessage:
      if (lparam == WM_LBUTTONDBLCLK || lparam == WM_LBUTTONUP) {
        RestoreFromTray();
        return 0;
      }
      if (lparam == WM_RBUTTONUP || lparam == WM_CONTEXTMENU) {
        ShowTrayMenu();
        return 0;
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_EXITSIZEMOVE:
      SaveWindowPlacement(hwnd);
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
