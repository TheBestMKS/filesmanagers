#include "flutter_window.h"

#include <optional>
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <gdiplus.h>
#include <memory>
#include <objidl.h>
#include <shellapi.h>
#include <string>
#include <utility>
#include <vector>
#include <variant>
#include <windowsx.h>

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
constexpr int kMiniWidth = 428;
constexpr int kMiniHeight = 168;
constexpr int kMiniRadius = 24;
constexpr int kMiniArtwork = 132;

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

std::vector<uint8_t> ReadBytes(const flutter::EncodableMap& map,
                               const char* key) {
  auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) {
    return {};
  }
  const auto* value = std::get_if<std::vector<uint8_t>>(&it->second);
  return value == nullptr ? std::vector<uint8_t>() : *value;
}

void AddRoundedRect(Gdiplus::GraphicsPath& path, const Gdiplus::RectF& rect,
                    float radius) {
  path.Reset();
  const float diameter = radius * 2.0f;
  path.AddArc(rect.X, rect.Y, diameter, diameter, 180.0f, 90.0f);
  path.AddArc(rect.GetRight() - diameter, rect.Y, diameter, diameter, 270.0f,
              90.0f);
  path.AddArc(rect.GetRight() - diameter, rect.GetBottom() - diameter, diameter,
              diameter, 0.0f, 90.0f);
  path.AddArc(rect.X, rect.GetBottom() - diameter, diameter, diameter, 90.0f,
              90.0f);
  path.CloseFigure();
}

Gdiplus::RectF MiniButtonRect(UINT command) {
  const float top = 116.0f;
  const float size = 34.0f;
  switch (command) {
    case kMiniPreviousCommand:
      return Gdiplus::RectF(168.0f, top, size, size);
    case kMiniPlayPauseCommand:
      return Gdiplus::RectF(212.0f, top - 4.0f, 42.0f, 42.0f);
    case kMiniNextCommand:
      return Gdiplus::RectF(264.0f, top, size, size);
    case kMiniStopCommand:
      return Gdiplus::RectF(316.0f, top, size, size);
    case kMiniRestoreCommand:
      return Gdiplus::RectF(366.0f, 18.0f, 34.0f, 34.0f);
    default:
      return Gdiplus::RectF();
  }
}

UINT MiniCommandAtPoint(int x, int y) {
  const Gdiplus::PointF point(static_cast<float>(x), static_cast<float>(y));
  for (const UINT command :
       {kMiniPreviousCommand, kMiniPlayPauseCommand, kMiniNextCommand,
        kMiniStopCommand, kMiniRestoreCommand}) {
    const auto rect = MiniButtonRect(command);
    if (point.X >= rect.X && point.X <= rect.GetRight() && point.Y >= rect.Y &&
        point.Y <= rect.GetBottom()) {
      return command;
    }
  }
  return 0;
}

std::unique_ptr<Gdiplus::Bitmap> BitmapFromBytes(
    const std::vector<uint8_t>& bytes) {
  if (bytes.empty()) {
    return nullptr;
  }
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes.size());
  if (memory == nullptr) {
    return nullptr;
  }
  void* data = GlobalLock(memory);
  if (data == nullptr) {
    GlobalFree(memory);
    return nullptr;
  }
  std::memcpy(data, bytes.data(), bytes.size());
  GlobalUnlock(memory);

  IStream* stream = nullptr;
  if (CreateStreamOnHGlobal(memory, TRUE, &stream) != S_OK ||
      stream == nullptr) {
    GlobalFree(memory);
    return nullptr;
  }
  auto bitmap = std::make_unique<Gdiplus::Bitmap>(stream);
  stream->Release();
  if (bitmap->GetLastStatus() != Gdiplus::Ok) {
    return nullptr;
  }
  return bitmap;
}

void DrawMiniText(Gdiplus::Graphics& graphics, const std::wstring& text,
                  const Gdiplus::RectF& rect, Gdiplus::Font& font,
                  Gdiplus::Brush& brush) {
  Gdiplus::StringFormat format;
  format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
  format.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);
  graphics.DrawString(text.c_str(), -1, &font, rect, &format, &brush);
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
          UpdateMiniPlayerState(
              ReadBool(*map, "active"), ReadBool(*map, "playing"),
              ReadString(*map, "title"), ReadString(*map, "subtitle"),
              ReadString(*map, "kind"), ReadBytes(*map, "artworkBytes"));
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
  }
  if (gdiplus_token_ != 0) {
    Gdiplus::GdiplusShutdown(gdiplus_token_);
    gdiplus_token_ = 0;
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

void FlutterWindow::UpdateMiniPlayerState(
    bool active, bool playing, const std::string& title,
    const std::string& subtitle, const std::string& kind,
    std::vector<uint8_t> artwork_bytes) {
  media_active_ = active;
  media_playing_ = playing;
  media_title_ = Utf8ToWide(title.empty() ? "Files Managers media" : title);
  media_subtitle_ = Utf8ToWide(subtitle);
  media_kind_ = Utf8ToWide(kind);
  media_artwork_bytes_ = std::move(artwork_bytes);
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
  if (gdiplus_token_ == 0) {
    Gdiplus::GdiplusStartupInput input;
    Gdiplus::GdiplusStartup(&gdiplus_token_, &input, nullptr);
  }

  static bool registered = false;
  if (!registered) {
    WNDCLASSW window_class{};
    window_class.style = CS_DROPSHADOW;
    window_class.lpfnWndProc = FlutterWindow::MiniPlayerWndProc;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.lpszClassName = kMiniPlayerClass;
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    RegisterClassW(&window_class);
    registered = true;
  }

  RECT work_area{};
  SystemParametersInfoW(SPI_GETWORKAREA, 0, &work_area, 0);
  const int x = work_area.right - kMiniWidth - 18;
  const int y = work_area.bottom - kMiniHeight - 18;

  mini_player_window_ = CreateWindowExW(
      WS_EX_TOOLWINDOW | WS_EX_TOPMOST, kMiniPlayerClass, L"Files Managers",
      WS_POPUP, x, y, kMiniWidth, kMiniHeight, GetHandle(), nullptr,
      GetModuleHandle(nullptr), this);
  if (mini_player_window_ == nullptr) {
    return;
  }
  HRGN region = CreateRoundRectRgn(0, 0, kMiniWidth + 1, kMiniHeight + 1,
                                   kMiniRadius, kMiniRadius);
  SetWindowRgn(mini_player_window_, region, TRUE);
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
  if (mini_player_window_ == nullptr) {
    return;
  }
  SetWindowTextW(mini_player_window_,
                 media_title_.empty() ? L"Files Managers media"
                                      : media_title_.c_str());
  InvalidateRect(mini_player_window_, nullptr, TRUE);
}

void FlutterWindow::PaintMiniPlayer(HWND window) {
  PAINTSTRUCT ps{};
  HDC hdc = BeginPaint(window, &ps);
  {
    Gdiplus::Graphics graphics(hdc);
    graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    graphics.SetTextRenderingHint(Gdiplus::TextRenderingHintClearTypeGridFit);

    const Gdiplus::RectF bounds(0.0f, 0.0f, static_cast<float>(kMiniWidth),
                                static_cast<float>(kMiniHeight));
    Gdiplus::GraphicsPath card_path;
    AddRoundedRect(card_path, bounds, 24.0f);
    Gdiplus::LinearGradientBrush background(
        bounds, Gdiplus::Color(248, 21, 28, 43),
        Gdiplus::Color(248, 6, 10, 20), 30.0f);
    graphics.FillPath(&background, &card_path);

    Gdiplus::SolidBrush sheen(Gdiplus::Color(34, 255, 255, 255));
    graphics.FillEllipse(&sheen, 230.0f, -110.0f, 260.0f, 210.0f);
    Gdiplus::Pen border(Gdiplus::Color(70, 255, 255, 255), 1.0f);
    graphics.DrawPath(&border, &card_path);

    const Gdiplus::RectF art_rect(18.0f, 18.0f, static_cast<float>(kMiniArtwork),
                                  static_cast<float>(kMiniArtwork));
    Gdiplus::GraphicsPath art_path;
    AddRoundedRect(art_path, art_rect, 18.0f);
    Gdiplus::SolidBrush art_fallback(Gdiplus::Color(255, 31, 41, 62));
    graphics.FillPath(&art_fallback, &art_path);

    auto bitmap = BitmapFromBytes(media_artwork_bytes_);
    if (bitmap != nullptr) {
      const auto state = graphics.Save();
      graphics.SetClip(&art_path);
      const float image_width = static_cast<float>(bitmap->GetWidth());
      const float image_height = static_cast<float>(bitmap->GetHeight());
      float src_x = 0.0f;
      float src_y = 0.0f;
      float src_width = image_width;
      float src_height = image_height;
      const float image_ratio = image_width / std::max(1.0f, image_height);
      const float dest_ratio = art_rect.Width / art_rect.Height;
      if (image_ratio > dest_ratio) {
        src_width = image_height * dest_ratio;
        src_x = (image_width - src_width) / 2.0f;
      } else {
        src_height = image_width / dest_ratio;
        src_y = (image_height - src_height) / 2.0f;
      }
      graphics.DrawImage(bitmap.get(), art_rect, src_x, src_y, src_width,
                         src_height, Gdiplus::UnitPixel);
      graphics.Restore(state);
    } else {
      Gdiplus::LinearGradientBrush placeholder(
          art_rect, Gdiplus::Color(255, 44, 70, 102),
          Gdiplus::Color(255, 20, 28, 44), 45.0f);
      graphics.FillPath(&placeholder, &art_path);
      Gdiplus::FontFamily symbol_family(L"Segoe UI Symbol");
      Gdiplus::Font symbol_font(&symbol_family, 40.0f, Gdiplus::FontStyleBold,
                                Gdiplus::UnitPixel);
      Gdiplus::SolidBrush symbol_brush(Gdiplus::Color(215, 255, 255, 255));
      Gdiplus::StringFormat centered;
      centered.SetAlignment(Gdiplus::StringAlignmentCenter);
      centered.SetLineAlignment(Gdiplus::StringAlignmentCenter);
      const wchar_t* glyph =
          media_kind_ == L"video" ? L"\u25B6" : L"\u266B";
      graphics.DrawString(glyph, -1, &symbol_font, art_rect, &centered,
                          &symbol_brush);
    }
    Gdiplus::Pen art_border(Gdiplus::Color(105, 255, 255, 255), 1.0f);
    graphics.DrawPath(&art_border, &art_path);

    Gdiplus::FontFamily text_family(L"Segoe UI");
    Gdiplus::Font title_font(&text_family, 17.0f, Gdiplus::FontStyleBold,
                             Gdiplus::UnitPixel);
    Gdiplus::Font subtitle_font(&text_family, 12.0f, Gdiplus::FontStyleRegular,
                                Gdiplus::UnitPixel);
    Gdiplus::Font status_font(&text_family, 11.0f, Gdiplus::FontStyleBold,
                              Gdiplus::UnitPixel);
    Gdiplus::SolidBrush title_brush(Gdiplus::Color(246, 255, 255, 255));
    Gdiplus::SolidBrush subtitle_brush(Gdiplus::Color(170, 207, 216, 235));
    Gdiplus::SolidBrush muted_brush(Gdiplus::Color(145, 177, 189, 214));
    DrawMiniText(graphics, media_title_, Gdiplus::RectF(166.0f, 22.0f, 190.0f,
                                                        28.0f),
                 title_font, title_brush);
    const auto subtitle = media_subtitle_.empty()
                              ? std::wstring(L"Files Managers media")
                              : media_subtitle_;
    DrawMiniText(graphics, subtitle, Gdiplus::RectF(166.0f, 54.0f, 230.0f,
                                                    22.0f),
                 subtitle_font, subtitle_brush);

    Gdiplus::RectF pill(166.0f, 84.0f, 92.0f, 22.0f);
    Gdiplus::GraphicsPath pill_path;
    AddRoundedRect(pill_path, pill, 11.0f);
    Gdiplus::SolidBrush pill_brush(
        media_playing_ ? Gdiplus::Color(225, 39, 174, 96)
                       : Gdiplus::Color(175, 108, 117, 132));
    graphics.FillPath(&pill_brush, &pill_path);
    Gdiplus::StringFormat centered;
    centered.SetAlignment(Gdiplus::StringAlignmentCenter);
    centered.SetLineAlignment(Gdiplus::StringAlignmentCenter);
    Gdiplus::SolidBrush pill_text(Gdiplus::Color(242, 255, 255, 255));
    graphics.DrawString(media_playing_ ? L"PLAYING" : L"PAUSED", -1,
                        &status_font, pill, &centered, &pill_text);

    Gdiplus::SolidBrush line_brush(Gdiplus::Color(70, 255, 255, 255));
    graphics.FillRectangle(&line_brush, 166.0f, 105.0f, 220.0f, 1.0f);

    Gdiplus::FontFamily symbol_family(L"Segoe UI Symbol");
    Gdiplus::Font button_font(&symbol_family, 17.0f, Gdiplus::FontStyleRegular,
                              Gdiplus::UnitPixel);
    Gdiplus::Font play_font(&symbol_family, 20.0f, Gdiplus::FontStyleBold,
                            Gdiplus::UnitPixel);
    Gdiplus::SolidBrush button_text(Gdiplus::Color(238, 255, 255, 255));
    for (const UINT command :
         {kMiniPreviousCommand, kMiniPlayPauseCommand, kMiniNextCommand,
          kMiniStopCommand, kMiniRestoreCommand}) {
      const auto rect = MiniButtonRect(command);
      const bool primary = command == kMiniPlayPauseCommand;
      Gdiplus::SolidBrush button_brush(
          primary ? Gdiplus::Color(236, 59, 130, 246)
                  : Gdiplus::Color(82, 255, 255, 255));
      graphics.FillEllipse(&button_brush, rect);
      Gdiplus::Pen button_border(
          primary ? Gdiplus::Color(120, 255, 255, 255)
                  : Gdiplus::Color(70, 255, 255, 255),
          1.0f);
      graphics.DrawEllipse(&button_border, rect);
      const wchar_t* glyph = L"";
      switch (command) {
        case kMiniPreviousCommand:
          glyph = L"\u23EE";
          break;
        case kMiniPlayPauseCommand:
          glyph = media_playing_ ? L"\u23F8" : L"\u25B6";
          break;
        case kMiniNextCommand:
          glyph = L"\u23ED";
          break;
        case kMiniStopCommand:
          glyph = L"\u25A0";
          break;
        case kMiniRestoreCommand:
          glyph = L"\u2197";
          break;
        default:
          break;
      }
      graphics.DrawString(glyph, -1,
                          primary ? &play_font : &button_font, rect,
                          &centered, &button_text);
    }
  }
  EndPaint(window, &ps);
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
    case WM_PAINT:
      self->PaintMiniPlayer(window);
      return 0;
    case WM_ERASEBKGND:
      return 1;
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
    case WM_LBUTTONDBLCLK:
      self->RestoreFromTray();
      return 0;
    case WM_LBUTTONDOWN:
      switch (MiniCommandAtPoint(GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam))) {
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
