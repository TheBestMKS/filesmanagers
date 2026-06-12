#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kWindowRegistryPath[] =
    L"Software\\filesmanagers\\FileManager";

DWORD ReadWindowDword(HKEY key, const wchar_t* name, DWORD fallback) {
  DWORD value = fallback;
  DWORD size = sizeof(value);
  if (RegGetValueW(key, nullptr, name, RRF_RT_REG_DWORD, nullptr, &value,
                   &size) == ERROR_SUCCESS) {
    return value;
  }
  return fallback;
}

void LoadSavedWindowBounds(Win32Window::Point* origin,
                           Win32Window::Size* size) {
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kWindowRegistryPath, 0, KEY_READ,
                    &key) != ERROR_SUCCESS) {
    return;
  }
  const DWORD x = ReadWindowDword(key, L"x", static_cast<DWORD>(origin->x));
  const DWORD y = ReadWindowDword(key, L"y", static_cast<DWORD>(origin->y));
  const DWORD width =
      ReadWindowDword(key, L"width", static_cast<DWORD>(size->width));
  const DWORD height =
      ReadWindowDword(key, L"height", static_cast<DWORD>(size->height));
  RegCloseKey(key);
  if (width >= 640 && height >= 420) {
    origin->x = static_cast<int>(x);
    origin->y = static_cast<int>(y);
    size->width = static_cast<int>(width);
    size->height = static_cast<int>(height);
  }
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  LoadSavedWindowBounds(&origin, &size);
  if (!window.Create(
          L"\u0424\u0430\u0439\u043b\u043e\u0432\u044b\u0439 "
          L"\u043c\u0435\u043d\u0435\u0434\u0436\u0435\u0440",
          origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
