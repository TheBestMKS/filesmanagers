#include "flutter_window.h"

#include <optional>
#include <string>
#include <variant>

#include "flutter/generated_plugin_registrant.h"
#include <flutter/standard_method_codec.h>

namespace {

constexpr wchar_t kWindowRegistryPath[] =
    L"Software\\SecureVault\\FileManager";

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
          flutter_controller_->engine()->messenger(), "secure_vault/window",
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
  if (flutter_controller_) {
    window_channel_ = nullptr;
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_EXITSIZEMOVE:
      SaveWindowPlacement(hwnd);
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
