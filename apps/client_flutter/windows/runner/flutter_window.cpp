#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <algorithm>
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
  DragAcceptFiles(GetHandle(), FALSE);
  drop_channel_.reset();
  clipboard_channel_.reset();
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