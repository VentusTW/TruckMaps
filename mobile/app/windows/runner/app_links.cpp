#include "app_links.h"

#include <utility>
#include <vector>

#include "utils.h"

namespace app_links {

namespace {

constexpr wchar_t kWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kWindowTitle[] = L"TruckMaps";
constexpr wchar_t kSchemeKey[] = L"Software\\Classes\\truckmaps";
constexpr wchar_t kCommandKey[] = L"Software\\Classes\\truckmaps\\shell\\open\\command";

bool SetString(HKEY key, const wchar_t* name, const std::wstring& value) {
  const DWORD bytes = static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t));
  return ::RegSetValueExW(key, name, 0, REG_SZ,
                          reinterpret_cast<const BYTE*>(value.c_str()),
                          bytes) == ERROR_SUCCESS;
}

bool WriteKey(const wchar_t* path,
              const std::vector<std::pair<const wchar_t*, std::wstring>>& values) {
  HKEY key = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, path, 0, nullptr, 0, KEY_WRITE,
                        nullptr, &key, nullptr) != ERROR_SUCCESS) {
    return false;
  }
  bool ok = true;
  for (const auto& [name, value] : values) {
    ok = SetString(key, name, value) && ok;
  }
  ::RegCloseKey(key);
  return ok;
}

}  // namespace

std::string LinkFromCommandLine() {
  for (const std::string& argument : GetCommandLineArguments()) {
    if (argument.rfind("truckmaps:", 0) == 0) {
      return argument;
    }
  }
  return std::string();
}

void RegisterScheme() {
  wchar_t exe[MAX_PATH];
  const DWORD length = ::GetModuleFileNameW(nullptr, exe, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    return;
  }
  const std::wstring command = L"\"" + std::wstring(exe, length) + L"\" \"%1\"";
  if (WriteKey(kSchemeKey, {{nullptr, L"URL:TruckMaps"}, {L"URL Protocol", L""}})) {
    WriteKey(kCommandKey, {{nullptr, command}});
  }
}

bool ForwardToRunningInstance(const std::string& link) {
  HWND window = ::FindWindowW(kWindowClass, kWindowTitle);
  if (window == nullptr) {
    return false;
  }
  COPYDATASTRUCT data{};
  data.dwData = kCopyDataId;
  data.cbData = static_cast<DWORD>(link.size());
  data.lpData = const_cast<char*>(link.data());
  ::SendMessageW(window, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&data));
  if (::IsIconic(window)) {
    ::ShowWindow(window, SW_RESTORE);
  }
  ::SetForegroundWindow(window);
  return true;
}

}  // namespace app_links
