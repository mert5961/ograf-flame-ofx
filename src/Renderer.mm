// CEF (embedded Chromium) renderer running inside the host application's process.
//
// macOS rules this follows:
//  - CEF must initialise and run on the main thread, which belongs to the host (Flame). CEF is
//    started with an external message pump and serviced from the main dispatch queue, so it
//    shares the host's run loop instead of owning it.
//  - CEF requires NSApp to implement CefAppProtocol; the methods are added at runtime.
//  - OFX renders arrive on host render threads: they hand work to the main thread and wait with
//    a timeout, so a stuck page can never hang the host.
#import <Cocoa/Cocoa.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <sys/stat.h>
#include <errno.h>
#include <signal.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <map>
#include <memory>
#include <mutex>

#include "Package.h"
#include "Renderer.h"
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_render_handler.h"
#include "include/cef_request_handler.h"
#include "include/cef_resource_request_handler.h"
#include "include/wrapper/cef_library_loader.h"
#include "include/wrapper/cef_stream_resource_handler.h"

namespace ograf {
namespace {

constexpr const char* kOrigin = "https://ograf.local/";
// Chromium presents a frame progressively as its raster tiles finish, and a repaint request can
// return the previous frame before the new one has been drawn; either way the missing tiles are
// fully transparent. A frame is therefore only accepted once the view has stopped changing for
// kSettleMs after the page reported it ready.
constexpr double kSettleMs = 40;
constexpr double kMaxSettleMs = 1000;

double NowMs() {
  return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

// ---------- NSApp protocol (required by CEF on macOS) ----------
BOOL g_handlingSendEvent = NO;
BOOL IsHandlingSendEvent(id, SEL) { return g_handlingSendEvent; }
void SetHandlingSendEvent(id, SEL, BOOL value) { g_handlingSendEvent = value; }

void EnsureAppProtocol() {
  NSApplication* app = [NSApplication sharedApplication];
  Class cls = [app class];
  if (![app respondsToSelector:@selector(isHandlingSendEvent)]) {
    std::string types = std::string(@encode(BOOL)) + "@:";
    class_addMethod(cls, @selector(isHandlingSendEvent), (IMP)IsHandlingSendEvent, types.c_str());
  }
  if (![app respondsToSelector:@selector(setHandlingSendEvent:)]) {
    std::string types = std::string("v@:") + @encode(BOOL);
    class_addMethod(cls, @selector(setHandlingSendEvent:), (IMP)SetHandlingSendEvent,
                    types.c_str());
  }
  class_addProtocol(cls, @protocol(CrAppProtocol));
  class_addProtocol(cls, @protocol(CrAppControlProtocol));
  class_addProtocol(cls, @protocol(CefAppProtocol));
}

// ---------- paths ----------
std::string BundlePath() {
  Dl_info info{};
  dladdr(reinterpret_cast<void*>(&RenderFrame), &info);
  std::string p = info.dli_fname ? info.dli_fname : "";
  for (int i = 0; i < 3; i++) p = p.substr(0, p.find_last_of('/'));  // Contents/MacOS/<bin>
  return p;
}

std::string HomeDir() {
  const char* h = getenv("HOME");
  return h ? h : "/tmp";
}

std::string JsString(const std::string& s) {
  std::string out = "\"";
  for (unsigned char c : s) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20) {
          char buf[8];
          snprintf(buf, sizeof buf, "\\u%04x", c);
          out += buf;
        } else {
          out += static_cast<char>(c);
        }
    }
  }
  return out + "\"";
}

std::string MimeFor(const std::string& path) {
  static const std::map<std::string, std::string> types = {
      {"js", "text/javascript"},  {"mjs", "text/javascript"}, {"json", "application/json"},
      {"html", "text/html"},      {"css", "text/css"},        {"png", "image/png"},
      {"jpg", "image/jpeg"},      {"jpeg", "image/jpeg"},     {"gif", "image/gif"},
      {"webp", "image/webp"},     {"svg", "image/svg+xml"},   {"ttf", "font/ttf"},
      {"otf", "font/otf"},        {"woff", "font/woff"},      {"woff2", "font/woff2"},
      {"txt", "text/plain"},      {"wasm", "application/wasm"}, {"mp4", "video/mp4"},
      {"webm", "video/webm"},     {"mp3", "audio/mpeg"},      {"wav", "audio/wav"}};
  auto dot = path.find_last_of('.');
  if (dot != std::string::npos) {
    std::string ext = path.substr(dot + 1);
    for (char& c : ext) c = static_cast<char>(tolower(c));
    auto it = types.find(ext);
    if (it != types.end()) return it->second;
  }
  return "application/octet-stream";
}

std::string PercentDecode(const std::string& s) {
  std::string out;
  for (size_t i = 0; i < s.size(); i++) {
    if (s[i] == '%' && i + 2 < s.size() && isxdigit(s[i + 1]) && isxdigit(s[i + 2])) {
      out += static_cast<char>(std::stoi(s.substr(i + 1, 2), nullptr, 16));
      i += 2;
    } else {
      out += s[i];
    }
  }
  return out;
}

// ---------- pending frame request ----------
struct Pending {
  FrameRequest request;
  int id = 0;
  void* session = nullptr;
  bool waitingForPaint = false;
  double readyAt = 0;    // when the page reported the frame ready
  double changedAt = 0;  // when the view last showed different pixels
  bool painted = false;  // `pixels` holds a paint received while waiting
  std::atomic<bool> done{false};
  bool ok = false;
  std::string error;
  std::vector<uint8_t> pixels;
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
};

// All of the following are touched on the main thread only.
int g_cefState = 0;  // 0 = not started, 1 = running, -1 = failed
std::string g_cefError;
std::shared_ptr<Pending> g_pending;
bool g_pumping = false;

void Complete(const std::shared_ptr<Pending>& p, bool ok, const std::string& error) {
  if (!p || p->done) return;
  p->ok = ok;
  p->error = error;
  p->done = true;
  if (g_pending == p) g_pending.reset();
  dispatch_semaphore_signal(p->semaphore);
}

// Completes `p` once the view has been unchanged for kSettleMs (see kSettleMs). Returns true
// when `p` is finished. Main thread only.
bool CheckSettle(const std::shared_ptr<Pending>& p) {
  if (p->done) return true;
  if (!p->waitingForPaint) return false;
  double now = NowMs();
  if (p->painted && now - p->changedAt >= kSettleMs) {
    Complete(p, true, "");
  } else if (now - p->readyAt >= kMaxSettleMs) {
    if (!p->painted) {
      Complete(p, false, "Chromium did not paint the frame");
    } else {
      Log("frame %d: view still changing after %.0f ms, using the latest paint", p->id, kMaxSettleMs);
      Complete(p, true, "");
    }
  }
  return p->done;
}

// Re-checks `p` on the main queue until it settles. A render called on the main thread blocks
// that queue, so its pump loop also calls CheckSettle directly.
void WaitForSettle(std::shared_ptr<Pending> p) {
  if (CheckSettle(p)) return;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    WaitForSettle(p);
  });
}

int g_pumpCount = 0;
void PumpOnce() {
  if (g_pumping || g_cefState != 1) return;
  g_pumping = true;
  auto t0 = std::chrono::steady_clock::now();
  bool verbose = getenv("OGRAF_VERBOSE") != nullptr;
  if (verbose && g_pumpCount < 8) Log("pump %d begin", g_pumpCount);
  CefDoMessageLoopWork();
  double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
  g_pumping = false;
  ++g_pumpCount;
  if (verbose && (g_pumpCount <= 8 || g_pumpCount % 150 == 0 || ms > 200)) Log("pump %d took %.1f ms", g_pumpCount, ms);
}

void ScheduleWork(int64_t delayMs) {
  if (delayMs < 0) delayMs = 0;
  if (delayMs > 1000) delayMs = 1000;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delayMs * NSEC_PER_MSEC), dispatch_get_main_queue(),
                 ^{
                   PumpOnce();
                 });
}

// ---------- CEF application ----------
class App : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

  void OnBeforeCommandLineProcessing(const CefString& processType,
                                     CefRefPtr<CefCommandLine> cl) override {
    if (!processType.empty()) return;
    for (const char* sw : {"disable-gpu", "disable-gpu-compositing", "use-mock-keychain",
                           "disable-background-timer-throttling", "disable-renderer-backgrounding",
                           "disable-backgrounding-occluded-windows", "mute-audio", "no-first-run",
                           "disable-component-update", "hide-scrollbars",
                           // Deterministic frames: never draw before every tile is rasterized and
                           // every image is decoded. Without these the compositor can present a
                           // frame with unfinished tiles, which come out as transparent blocks.
                           "run-all-compositor-stages-before-draw", "disable-checker-imaging",
                           "disable-image-animation-resync", "disable-threaded-animation",
                           "disable-new-content-rendering-timeout"})
      cl->AppendSwitch(sw);
    cl->AppendSwitchWithValue("force-color-profile", "srgb");
  }

  void OnScheduleMessagePumpWork(int64_t delayMs) override { ScheduleWork(delayMs); }

 private:
  IMPLEMENT_REFCOUNTING(App);
};

// ---------- one off-screen browser per package ----------
class Session : public CefClient,
                public CefRenderHandler,
                public CefLoadHandler,
                public CefDisplayHandler,
                public CefRequestHandler,
                public CefResourceRequestHandler {
 public:
  enum class State { Loading, Mounting, Ready, Failed };

  Session(std::string root, std::string mainPath, int w, int h)
      : root_(std::move(root)), main_(std::move(mainPath)), width_(w), height_(h) {}

  void Create() {
    CefWindowInfo window;
    window.SetAsWindowless(nullptr);
    CefBrowserSettings settings;
    settings.windowless_frame_rate = 60;
    settings.background_color = CefColorSetARGB(0, 0, 0, 0);
    browser_ = CefBrowserHost::CreateBrowserSync(window, this, std::string(kOrigin) + "__host.html",
                                                 settings, nullptr, nullptr);
    if (!browser_) Fail("could not create the Chromium browser");
    else Log("browser %d created for %s", browser_->GetIdentifier(), root_.c_str());
  }

  State state() const { return state_; }
  const std::string& error() const { return error_; }

  // Called when a request for this session becomes current.
  void Start(const std::shared_ptr<Pending>& p) {
    if (state_ == State::Ready) RunFrame(p);
    else if (state_ == State::Failed) Complete(p, false, error_);
    // Otherwise RunFrame happens once the graphic is mounted.
  }

  // CefClient
  CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  // CefRenderHandler
  void GetViewRect(CefRefPtr<CefBrowser>, CefRect& rect) override {
    rect = CefRect(0, 0, width_, height_);
  }
  bool GetScreenInfo(CefRefPtr<CefBrowser>, CefScreenInfo& info) override {
    info.device_scale_factor = 1.0f;
    info.depth = 24;
    info.depth_per_component = 8;
    info.rect = CefRect(0, 0, width_, height_);
    info.available_rect = info.rect;
    return true;
  }
  void OnPaint(CefRefPtr<CefBrowser>, PaintElementType type, const RectList&, const void* buffer,
               int w, int h) override {
    auto p = g_pending;
    if (type != PET_VIEW || !p || p->session != this || !p->waitingForPaint) return;
    if (w != width_ || h != height_) {
      Complete(p, false, "unexpected paint size " + std::to_string(w) + "x" + std::to_string(h));
      return;
    }
    const auto* bytes = static_cast<const uint8_t*>(buffer);
    const size_t size = static_cast<size_t>(w) * h * 4;
    if (!p->painted || memcmp(p->pixels.data(), bytes, size) != 0) {
      p->pixels.assign(bytes, bytes + size);
      p->changedAt = NowMs();
    }
    p->painted = true;
  }

  // CefLoadHandler
  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int status) override {
    Log("load end: %s status %d (main %d)", frame->GetURL().ToString().c_str(), status, frame->IsMain() ? 1 : 0);
    if (!frame->IsMain() || state_ != State::Loading) return;
    state_ = State::Mounting;
    std::string mainUrl = std::string(kOrigin) + main_;
    std::string js =
        "(async()=>{try{const mod=await import(" + JsString(mainUrl) +
        ");const tag='ograf-graphic-render';if(!customElements.get(tag))customElements.define(tag,"
        "mod.default);const el=document.createElement(tag);el.style.cssText='position:absolute;"
        "inset:0;width:" +
        std::to_string(width_) + "px;height:" + std::to_string(height_) +
        "px;display:block';document.getElementById('host').appendChild(el);window.__g=el;"
        "await document.fonts.ready;console.log('__OGRAF_MOUNTED__');}catch(e){console.log("
        "'__OGRAF_ERR__:mount:'+(e&&e.stack||e));}})();";
    frame->ExecuteJavaScript(js, std::string(kOrigin) + "__mount.js", 0);
  }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, ErrorCode, const CefString& text,
                   const CefString& url) override {
    if (frame->IsMain()) Fail("page failed to load (" + text.ToString() + ") " + url.ToString());
  }

  // CefDisplayHandler
  bool OnConsoleMessage(CefRefPtr<CefBrowser>, cef_log_severity_t level, const CefString& message,
                        const CefString& source, int line) override {
    std::string m = message.ToString();
    if (getenv("OGRAF_VERBOSE")) Log("console[%d]: %s", level, m.substr(0, 300).c_str());
    if (m == "__OGRAF_MOUNTED__") {
      state_ = State::Ready;
      Log("graphic mounted: %s", root_.c_str());
      if (g_pending && g_pending->session == this) RunFrame(g_pending);
      return true;
    }
    if (m.rfind("__OGRAF_ERR__:mount:", 0) == 0) {
      Fail("graphic failed to load: " + m.substr(20));
      return true;
    }
    if (m.rfind("__OGRAF_DONE__:", 0) == 0) {
      int id = atoi(m.c_str() + 15);
      auto p = g_pending;
      if (p && p->session == this && p->id == id) {
        p->waitingForPaint = true;
        p->readyAt = p->changedAt = NowMs();
        browser_->GetHost()->Invalidate(PET_VIEW);
        WaitForSettle(p);
      }
      return true;
    }
    if (m.rfind("__OGRAF_ERR__:", 0) == 0) {
      int id = atoi(m.c_str() + 14);
      auto p = g_pending;
      if (p && p->session == this && p->id == id) Complete(p, false, "graphic error: " + m.substr(14));
      return true;
    }
    if (level >= LOGSEVERITY_WARNING)
      Log("console: %s (%s:%d)", m.c_str(), source.ToString().c_str(), line);
    return false;
  }

  // CefRequestHandler: serve this package from https://ograf.local/
  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, CefRefPtr<CefRequest> request, bool, bool,
      const CefString&, bool&) override {
    return request->GetURL().ToString().rfind(kOrigin, 0) == 0 ? this : nullptr;
  }

  // CefResourceRequestHandler (IO thread; reads only immutable members)
  CefRefPtr<CefResourceHandler> GetResourceHandler(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
                                                   CefRefPtr<CefRequest> request) override {
    std::string path = request->GetURL().ToString().substr(strlen(kOrigin));
    path = PercentDecode(path.substr(0, path.find_first_of("?#")));
    CefResponse::HeaderMap headers;
    headers.insert({"Cache-Control", "no-store"});
    if (path == "__host.html") {
      std::string html =
          "<!doctype html><html><head><meta charset=\"utf-8\"><style>html,body{margin:0;padding:0;"
          "background:transparent;overflow:hidden;width:" +
          std::to_string(width_) + "px;height:" + std::to_string(height_) +
          "px}#host{position:absolute;inset:0}</style></head><body><div id=\"host\"></div></body>"
          "</html>";
      return new CefStreamResourceHandler(
          200, "OK", "text/html", headers,
          CefStreamReader::CreateForData(html.data(), html.size()));
    }
    struct stat st {};
    std::string file = root_ + "/" + path;
    if (path.empty() || path.find("..") != std::string::npos || stat(file.c_str(), &st) != 0 ||
        !S_ISREG(st.st_mode)) {
      static const char kMissing[] = "not found";
      return new CefStreamResourceHandler(404, "Not Found", "text/plain", headers,
                                          CefStreamReader::CreateForData((void*)kMissing, 9));
    }
    return new CefStreamResourceHandler(200, "OK", MimeFor(file), headers,
                                        CefStreamReader::CreateForFile(file));
  }

 private:
  void Fail(const std::string& message) {
    state_ = State::Failed;
    error_ = message;
    Log("session failed: %s", message.c_str());
    if (g_pending && g_pending->session == this) Complete(g_pending, false, message);
  }

  void RunFrame(const std::shared_ptr<Pending>& p) {
    const FrameRequest& r = p->request;
    char ts[64];
    snprintf(ts, sizeof ts, "%.6f", r.timestampMs);
    std::string id = std::to_string(p->id);
    std::string js =
        "(async()=>{try{const g=window.__g;const S=" + r.scheduleJson +
        ";const K=JSON.stringify(S);if(!window.__loaded){await g.load({renderType:'non-realtime',"
        "data:" +
        r.dataJson +
        "});window.__loaded=true;}if(window.__key!==K){await g.setActionsSchedule({schedule:S});"
        "window.__key=K;}await g.goToTime({timestamp:" +
        ts +
        "});const I=[],q=n=>{for(const e of n.querySelectorAll('*')){if(e instanceof "
        "HTMLImageElement||e instanceof SVGImageElement)I.push(e);if(e.shadowRoot)q(e.shadowRoot);}};"
        "q(document);await Promise.all(I.map(i=>i.decode?i.decode().catch(()=>{}):0));"
        "await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));"
        "console.log('__OGRAF_DONE__:" +
        id + "');}catch(e){console.log('__OGRAF_ERR__:" + id + ":'+(e&&e.stack||e));}})();";
    browser_->GetMainFrame()->ExecuteJavaScript(js, std::string(kOrigin) + "__frame.js", 0);
  }

  const std::string root_, main_;
  const int width_, height_;
  CefRefPtr<CefBrowser> browser_;
  State state_ = State::Loading;
  std::string error_;

  IMPLEMENT_REFCOUNTING(Session);
};

std::map<std::string, CefRefPtr<Session>> g_sessions;

// Chromium locks its profile folder, so every host process (two Flame sessions, a background
// render, a test) gets its own. Folders of processes that are no longer running are removed.
std::string ProcessCacheDir() {
  std::string base = HomeDir() + "/Library/Caches/OGrafFlame/chromium-profiles";
  NSFileManager* fm = [NSFileManager defaultManager];
  NSString* baseNs = [NSString stringWithUTF8String:base.c_str()];
  [fm createDirectoryAtPath:baseNs withIntermediateDirectories:YES attributes:nil error:nil];
  for (NSString* name in [fm contentsOfDirectoryAtPath:baseNs error:nil]) {
    NSString* path = [baseNs stringByAppendingPathComponent:name];
    pid_t pid = static_cast<pid_t>(name.intValue);
    bool numeric = pid > 0 && [[NSString stringWithFormat:@"%d", pid] isEqualToString:name];
    if (!numeric) continue;
    if (pid != getpid() && kill(pid, 0) != 0 && errno == ESRCH) [fm removeItemAtPath:path error:nil];
  }
  return base + "/" + std::to_string(getpid());
}

bool EnsureCef(std::string& error) {
  if (g_cefState == 1) return true;
  if (g_cefState == -1) {
    error = g_cefError;
    return false;
  }
  g_cefState = -1;
  std::string bundle = BundlePath();
  std::string framework = bundle + "/Contents/Frameworks/Chromium Embedded Framework.framework";
  Log("starting Chromium from %s", bundle.c_str());
  if (!cef_load_library((framework + "/Chromium Embedded Framework").c_str())) {
    g_cefError = error = "could not load " + framework;
    return false;
  }
  EnsureAppProtocol();

  CefSettings settings;
  settings.no_sandbox = 1;
  settings.external_message_pump = 1;
  settings.multi_threaded_message_loop = 0;
  settings.windowless_rendering_enabled = 1;
  settings.background_color = CefColorSetARGB(0, 0, 0, 0);
  settings.log_severity = getenv("OGRAF_VERBOSE") ? LOGSEVERITY_INFO : LOGSEVERITY_WARNING;
  CefString(&settings.browser_subprocess_path) =
      bundle + "/Contents/Frameworks/OGraf Helper.app/Contents/MacOS/OGraf Helper";
  CefString(&settings.framework_dir_path) = framework;
  CefString(&settings.main_bundle_path) = bundle;
  CefString(&settings.root_cache_path) = ProcessCacheDir();
  CefString(&settings.log_file) = HomeDir() + "/Library/Logs/OGrafFlame-chromium.log";

  static char arg0[] = "OGrafFlame";
  static char* argv[] = {arg0, nullptr};
  CefMainArgs args(1, argv);
  if (!CefInitialize(args, settings, new App(), nullptr)) {
    g_cefError = error = "Chromium failed to initialise (see ~/Library/Logs/OGrafFlame-chromium.log)";
    Log("%s", error.c_str());
    return false;
  }
  g_cefState = 1;
  // Backup pump in case a scheduled wake-up is coalesced away.
  // Static: under ARC a local dispatch source would be released (and stop) at end of scope.
  static dispatch_source_t timer;
  timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                   dispatch_get_main_queue());
  dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 33 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
  dispatch_source_set_event_handler(timer, ^{
    PumpOnce();
  });
  dispatch_resume(timer);
  Log("Chromium started");
  return true;
}

void StartOnMain(const std::shared_ptr<Pending>& p) {
  if (p->done) return;
  std::string error;
  if (!EnsureCef(error)) return Complete(p, false, error);
  if (g_pending && g_pending != p) Complete(g_pending, false, "superseded");
  g_pending = p;
  const FrameRequest& r = p->request;
  std::string key = r.packageRoot + "|" + std::to_string(r.width) + "x" + std::to_string(r.height);
  auto it = g_sessions.find(key);
  if (it == g_sessions.end() || it->second->state() == Session::State::Failed) {
    CefRefPtr<Session> session = new Session(r.packageRoot, r.mainPath, r.width, r.height);
    g_sessions[key] = session;
    p->session = session.get();
    session->Create();
    if (!p->done) session->Start(p);
  } else {
    p->session = it->second.get();
    it->second->Start(p);
  }
}

}  // namespace

bool RenderFrame(const FrameRequest& request, std::vector<uint8_t>& bgra, std::string& error) {
  static std::mutex renderMutex;
  static std::atomic<int> counter{0};
  static std::atomic<bool> warmedUp{false};
  std::lock_guard<std::mutex> lock(renderMutex);

  auto p = std::make_shared<Pending>();
  p->request = request;
  p->id = ++counter;
  const double timeoutSec = warmedUp ? 20 : 60;

  if (pthread_main_np()) {
    // Called on the host's main thread: pump CEF ourselves instead of blocking it.
    StartOnMain(p);
    auto deadline = std::chrono::steady_clock::now() + std::chrono::duration<double>(timeoutSec);
    while (!p->done && std::chrono::steady_clock::now() < deadline) {
      PumpOnce();
      if (CheckSettle(p)) break;
      usleep(2000);
    }
    if (!p->done) Complete(p, false, "timed out waiting for Chromium");
  } else {
    dispatch_async(dispatch_get_main_queue(), ^{
      StartOnMain(p);
    });
    long waited = dispatch_semaphore_wait(
        p->semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutSec * NSEC_PER_SEC)));
    if (waited != 0) {
      dispatch_async(dispatch_get_main_queue(), ^{
        Complete(p, false, "timed out");
      });
      error = "timed out waiting for Chromium on the main thread (is the host's main thread busy?)";
      Log("frame %d: %s", p->id, error.c_str());
      return false;
    }
  }
  if (!p->ok) {
    error = p->error;
    Log("frame %d failed: %s", p->id, error.c_str());
    return false;
  }
  warmedUp = true;
  bgra = std::move(p->pixels);
  return true;
}

}  // namespace ograf
