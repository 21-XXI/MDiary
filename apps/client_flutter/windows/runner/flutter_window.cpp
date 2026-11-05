#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <algorithm>
#include <cstdio>
#include <optional>
#include <string>
#include <vector>

// GDI+ headers expect min/max macros; the build defines NOMINMAX.
#ifndef min
#define min(a, b) (((a) < (b)) ? (a) : (b))
#endif
#ifndef max
#define max(a, b) (((a) > (b)) ? (a) : (b))
#endif
#include <gdiplus.h>
#undef min
#undef max

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

int GetEncoderClsid(const WCHAR* mime, CLSID* clsid) {
  UINT count = 0;
  UINT size = 0;
  Gdiplus::GetImageEncodersSize(&count, &size);
  if (size == 0) {
    return -1;
  }
  std::vector<BYTE> buffer(size);
  auto* codecs = reinterpret_cast<Gdiplus::ImageCodecInfo*>(buffer.data());
  Gdiplus::GetImageEncoders(count, size, codecs);
  for (UINT i = 0; i < count; ++i) {
    if (wcscmp(codecs[i].MimeType, mime) == 0) {
      *clsid = codecs[i].Clsid;
      return static_cast<int>(i);
    }
  }
  return -1;
}

bool EnsureGdiplus() {
  static ULONG_PTR token = 0;
  static bool ready = false;
  if (!ready) {
    Gdiplus::GdiplusStartupInput input;
    ready = Gdiplus::GdiplusStartup(&token, &input, nullptr) == Gdiplus::Ok;
  }
  return ready;
}

// Reads CF_BITMAP from the clipboard and encodes it as PNG.
bool ReadClipboardImagePng(std::vector<uint8_t>* out) {
  if (!EnsureGdiplus()) {
    return false;
  }
  if (!OpenClipboard(nullptr)) {
    return false;
  }
  bool ok = false;
  HBITMAP handle = static_cast<HBITMAP>(GetClipboardData(CF_BITMAP));
  if (handle != nullptr) {
    Gdiplus::Bitmap bitmap(handle, nullptr);
    CLSID encoder;
    if (bitmap.GetLastStatus() == Gdiplus::Ok &&
        GetEncoderClsid(L"image/png", &encoder) >= 0) {
      IStream* stream = nullptr;
      if (CreateStreamOnHGlobal(nullptr, TRUE, &stream) == S_OK) {
        if (bitmap.Save(stream, &encoder, nullptr) == Gdiplus::Ok) {
          STATSTG stat;
          if (stream->Stat(&stat, STATFLAG_NONAME) == S_OK &&
              stat.cbSize.QuadPart > 0) {
            HGLOBAL memory = nullptr;
            if (GetHGlobalFromStream(stream, &memory) == S_OK) {
              void* data = GlobalLock(memory);
              if (data != nullptr) {
                const auto* bytes = static_cast<uint8_t*>(data);
                out->assign(bytes, bytes + stat.cbSize.QuadPart);
                ok = true;
                GlobalUnlock(memory);
              }
            }
          }
        }
        stream->Release();
      }
    }
  }
  CloseClipboard();
  return ok && !out->empty();
}

// Opens a file/folder/URL through ShellExecuteW. Paths never go through
// cmd.exe parsing, so spaces, quotes and '&' are safe.
bool OpenWithShell(const std::string& utf8_path) {
  const int length =
      MultiByteToWideChar(CP_UTF8, 0, utf8_path.c_str(), -1, nullptr, 0);
  if (length <= 1) {
    return false;
  }
  std::wstring wide(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8_path.c_str(), -1, wide.data(), length);
  wide.resize(static_cast<size_t>(length) - 1);
  const HINSTANCE result =
      ShellExecuteW(nullptr, L"open", wide.c_str(), nullptr, nullptr,
                    SW_SHOWNORMAL);
  return reinterpret_cast<INT_PTR>(result) > 32;
}

// Window geometry memory: written next to the exe on close, restored on start.
// Format: "x,y,width,height,maximized" (maximized is 0 or 1).
std::wstring WindowBoundsPath() {
  wchar_t module_path[MAX_PATH] = {};
  const DWORD length = ::GetModuleFileNameW(nullptr, module_path, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    return std::wstring();
  }
  std::wstring path(module_path, length);
  const size_t slash = path.find_last_of(L"\\/");
  if (slash == std::wstring::npos) {
    return std::wstring();
  }
  return path.substr(0, slash + 1) + L"mdiary-window.txt";
}

bool LoadWindowBounds(RECT* bounds, bool* maximized) {
  const std::wstring path = WindowBoundsPath();
  if (path.empty()) {
    return false;
  }
  HANDLE file = ::CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
                              nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                              nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return false;
  }
  char buffer[128] = {};
  DWORD read = 0;
  const BOOL ok = ::ReadFile(file, buffer, sizeof(buffer) - 1, &read, nullptr);
  ::CloseHandle(file);
  if (!ok || read == 0) {
    return false;
  }
  int x = 0;
  int y = 0;
  int width = 0;
  int height = 0;
  int zoomed = 0;
  if (::sscanf_s(buffer, "%d,%d,%d,%d,%d", &x, &y, &width, &height, &zoomed) !=
      5) {
    return false;
  }
  if (width < 720 || height < 520) {
    return false;
  }
  bounds->left = x;
  bounds->top = y;
  bounds->right = x + width;
  bounds->bottom = y + height;
  *maximized = zoomed != 0;
  return true;
}

void SaveWindowBounds(HWND hwnd) {
  const std::wstring path = WindowBoundsPath();
  if (path.empty()) {
    return;
  }
  WINDOWPLACEMENT placement = {};
  placement.length = sizeof(placement);
  if (!::GetWindowPlacement(hwnd, &placement)) {
    return;
  }
  const RECT rect = placement.rcNormalPosition;
  const int maximized = placement.showCmd == SW_SHOWMAXIMIZED ? 1 : 0;
  char buffer[128] = {};
  const int written = ::sprintf_s(buffer, sizeof(buffer), "%ld,%ld,%ld,%ld,%d",
                                  rect.left, rect.top, rect.right - rect.left,
                                  rect.bottom - rect.top, maximized);
  if (written <= 0) {
    return;
  }
  HANDLE file = ::CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }
  DWORD bytes_written = 0;
  ::WriteFile(file, buffer, static_cast<DWORD>(written), &bytes_written, nullptr);
  ::CloseHandle(file);
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

  // Drag-and-drop import: accept files dropped from Explorer and forward the
  // paths to Dart over "mdiary/drop".
  drop_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "mdiary/drop",
          &flutter::StandardMethodCodec::GetInstance());
  DragAcceptFiles(GetHandle(), TRUE);

  // Paste screenshot: hand Dart the clipboard image as PNG bytes.
  clipboard_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "mdiary/clipboard",
          &flutter::StandardMethodCodec::GetInstance());
  clipboard_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() == "readImagePng") {
          std::vector<uint8_t> png;
          if (ReadClipboardImagePng(&png)) {
            result->Success(flutter::EncodableValue(png));
          } else {
            result->Success(flutter::EncodableValue());
          }
          return;
        }
        result->NotImplemented();
      });

  // Open files/folders/URLs through ShellExecuteW.
  shell_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "mdiary/shell",
          &flutter::StandardMethodCodec::GetInstance());
  shell_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() == "open") {
          const auto* path = std::get_if<std::string>(call.arguments());
          if (path == nullptr) {
            result->Error("bad-args", "path is required");
            return;
          }
          result->Success(flutter::EncodableValue(OpenWithShell(*path)));
          return;
        }
        result->NotImplemented();
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Restore the window geometry from the previous session (if any).
  {
    RECT saved = {};
    bool maximized = false;
    if (LoadWindowBounds(&saved, &maximized)) {
      ::SetWindowPos(GetHandle(), nullptr, saved.left, saved.top,
                     saved.right - saved.left, saved.bottom - saved.top,
                     SWP_NOZORDER | SWP_NOACTIVATE);
      if (maximized) {
        ::ShowWindow(GetHandle(), SW_MAXIMIZE);
      }
    }
  }

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
  SaveWindowBounds(GetHandle());
  DragAcceptFiles(GetHandle(), FALSE);
  drop_channel_.reset();
  clipboard_channel_.reset();
  shell_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::HandleDropFiles(HDROP drop) {
  const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  flutter::EncodableList paths;
  for (UINT index = 0; index < count; ++index) {
    const UINT length = DragQueryFileW(drop, index, nullptr, 0);
    std::wstring buffer(length + 1, L'\0');
    DragQueryFileW(drop, index, buffer.data(), length + 1);
    buffer.resize(length);
    const std::string utf8 = Utf8FromUtf16(buffer.c_str());
    if (!utf8.empty()) {
      paths.emplace_back(utf8);
    }
  }
  DragFinish(drop);
  if (drop_channel_ != nullptr && !paths.empty()) {
    drop_channel_->InvokeMethod(
        "files", std::make_unique<flutter::EncodableValue>(paths));
  }
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

  if (message == WM_GETMINMAXINFO) {
    auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
    UINT dpi = 96;
    HMODULE user32 = ::GetModuleHandleW(L"user32.dll");
    if (user32 != nullptr) {
      auto get_dpi = reinterpret_cast<UINT(WINAPI*)(HWND)>(
          ::GetProcAddress(user32, "GetDpiForWindow"));
      if (get_dpi != nullptr) {
        dpi = get_dpi(hwnd);
      }
    }
    const double scale = dpi == 0 ? 1.0 : dpi / 96.0;
    info->ptMinTrackSize.x = static_cast<LONG>(720 * scale);
    info->ptMinTrackSize.y = static_cast<LONG>(520 * scale);
    return 0;
  }

  if (message == WM_DROPFILES) {
    HandleDropFiles(reinterpret_cast<HDROP>(wparam));
    return 0;
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}