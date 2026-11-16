// Minimal OFX host for testing the plugin outside Flame: loads the bundle, describes every
// effect, then drives a named effect and the generic effect through CreateInstance,
// InstanceChanged and Render (from a background thread, as a host render thread would).
//
//   ograf_mockhost <OGrafFlame.ofx.bundle> <template.ograf.zip> <outDir>
#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <dlfcn.h>

#include <cmath>
#include <cstdarg>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "ofxCore.h"
#include "ofxImageEffect.h"
#include "ofxMessage.h"
#include "ofxParam.h"
#include "ofxProperty.h"

// ---------- properties ----------
struct Props {
  std::map<std::string, std::vector<std::string>> s;
  std::map<std::string, std::vector<double>> d;
  std::map<std::string, std::vector<int>> i;
  std::map<std::string, std::vector<void*>> p;
};
static Props* P(OfxPropertySetHandle h) { return reinterpret_cast<Props*>(h); }
template <class T> static void Put(std::vector<T>& v, int idx, T val) {
  if (static_cast<int>(v.size()) <= idx) v.resize(idx + 1);
  v[idx] = val;
}
static OfxStatus SetPtr(OfxPropertySetHandle h, const char* n, int x, void* v) { Put(P(h)->p[n], x, v); return kOfxStatOK; }
static OfxStatus SetStr(OfxPropertySetHandle h, const char* n, int x, const char* v) { Put(P(h)->s[n], x, std::string(v)); return kOfxStatOK; }
static OfxStatus SetDbl(OfxPropertySetHandle h, const char* n, int x, double v) { Put(P(h)->d[n], x, v); return kOfxStatOK; }
static OfxStatus SetInt(OfxPropertySetHandle h, const char* n, int x, int v) { Put(P(h)->i[n], x, v); return kOfxStatOK; }
static OfxStatus SetPtrN(OfxPropertySetHandle h, const char* n, int c, void* const* v) { for (int k = 0; k < c; k++) SetPtr(h, n, k, v[k]); return kOfxStatOK; }
static OfxStatus SetStrN(OfxPropertySetHandle h, const char* n, int c, const char* const* v) { for (int k = 0; k < c; k++) SetStr(h, n, k, v[k]); return kOfxStatOK; }
static OfxStatus SetDblN(OfxPropertySetHandle h, const char* n, int c, const double* v) { for (int k = 0; k < c; k++) SetDbl(h, n, k, v[k]); return kOfxStatOK; }
static OfxStatus SetIntN(OfxPropertySetHandle h, const char* n, int c, const int* v) { for (int k = 0; k < c; k++) SetInt(h, n, k, v[k]); return kOfxStatOK; }
template <class T> static OfxStatus Get(std::map<std::string, std::vector<T>>& m, const char* n, int x, T* out) {
  auto it = m.find(n);
  if (it == m.end() || static_cast<int>(it->second.size()) <= x) return kOfxStatErrUnknown;
  *out = it->second[x];
  return kOfxStatOK;
}
static OfxStatus GetPtr(OfxPropertySetHandle h, const char* n, int x, void** v) { return Get(P(h)->p, n, x, v); }
static OfxStatus GetStr(OfxPropertySetHandle h, const char* n, int x, char** v) {
  auto it = P(h)->s.find(n);
  if (it == P(h)->s.end() || static_cast<int>(it->second.size()) <= x) return kOfxStatErrUnknown;
  *v = const_cast<char*>(it->second[x].c_str());
  return kOfxStatOK;
}
static OfxStatus GetDbl(OfxPropertySetHandle h, const char* n, int x, double* v) { return Get(P(h)->d, n, x, v); }
static OfxStatus GetInt(OfxPropertySetHandle h, const char* n, int x, int* v) { return Get(P(h)->i, n, x, v); }
static OfxStatus GetPtrN(OfxPropertySetHandle h, const char* n, int c, void** v) { for (int k = 0; k < c; k++) if (GetPtr(h, n, k, &v[k])) return kOfxStatErrUnknown; return kOfxStatOK; }
static OfxStatus GetStrN(OfxPropertySetHandle h, const char* n, int c, char** v) { for (int k = 0; k < c; k++) if (GetStr(h, n, k, &v[k])) return kOfxStatErrUnknown; return kOfxStatOK; }
static OfxStatus GetDblN(OfxPropertySetHandle h, const char* n, int c, double* v) { for (int k = 0; k < c; k++) if (GetDbl(h, n, k, &v[k])) return kOfxStatErrUnknown; return kOfxStatOK; }
static OfxStatus GetIntN(OfxPropertySetHandle h, const char* n, int c, int* v) { for (int k = 0; k < c; k++) if (GetInt(h, n, k, &v[k])) return kOfxStatErrUnknown; return kOfxStatOK; }
static OfxStatus Reset(OfxPropertySetHandle, const char*) { return kOfxStatOK; }
static OfxStatus Dim(OfxPropertySetHandle h, const char* n, int* c) {
  Props* p = P(h);
  if (p->s.count(n)) *c = (int)p->s[n].size();
  else if (p->d.count(n)) *c = (int)p->d[n].size();
  else if (p->i.count(n)) *c = (int)p->i[n].size();
  else if (p->p.count(n)) *c = (int)p->p[n].size();
  else return kOfxStatErrUnknown;
  return kOfxStatOK;
}

// ---------- parameters ----------
struct Param {
  std::string type;
  Props props;
  double d[3] = {0, 0, 0};
  int i = 0;
  std::string s;
};
struct ParamSet {
  std::map<std::string, std::unique_ptr<Param>> params;
  Props props;
};
static OfxStatus ParamDefine(OfxParamSetHandle set, const char* type, const char* name, OfxPropertySetHandle* props) {
  auto& p = reinterpret_cast<ParamSet*>(set)->params[name];
  p = std::make_unique<Param>();
  p->type = type;
  if (props) *props = reinterpret_cast<OfxPropertySetHandle>(&p->props);
  return kOfxStatOK;
}
static OfxStatus ParamGetHandle(OfxParamSetHandle set, const char* name, OfxParamHandle* h, OfxPropertySetHandle* props) {
  auto& m = reinterpret_cast<ParamSet*>(set)->params;
  auto it = m.find(name);
  if (it == m.end()) return kOfxStatErrUnknown;
  *h = reinterpret_cast<OfxParamHandle>(it->second.get());
  if (props) *props = reinterpret_cast<OfxPropertySetHandle>(&it->second->props);
  return kOfxStatOK;
}
static OfxStatus ParamSetProps(OfxParamSetHandle set, OfxPropertySetHandle* props) { *props = reinterpret_cast<OfxPropertySetHandle>(&reinterpret_cast<ParamSet*>(set)->props); return kOfxStatOK; }
static OfxStatus ParamProps(OfxParamHandle h, OfxPropertySetHandle* props) { *props = reinterpret_cast<OfxPropertySetHandle>(&reinterpret_cast<Param*>(h)->props); return kOfxStatOK; }
static OfxStatus GetV(Param* p, va_list ap) {
  if (p->type == kOfxParamTypeString) *va_arg(ap, char**) = const_cast<char*>(p->s.c_str());
  else if (p->type == kOfxParamTypeRGB) for (int k = 0; k < 3; k++) *va_arg(ap, double*) = p->d[k];
  else if (p->type == kOfxParamTypeDouble) *va_arg(ap, double*) = p->d[0];
  else *va_arg(ap, int*) = p->i;
  return kOfxStatOK;
}
static OfxStatus SetV(Param* p, va_list ap) {
  if (p->type == kOfxParamTypeString) p->s = va_arg(ap, char*);
  else if (p->type == kOfxParamTypeRGB) for (int k = 0; k < 3; k++) p->d[k] = va_arg(ap, double);
  else if (p->type == kOfxParamTypeDouble) p->d[0] = va_arg(ap, double);
  else p->i = va_arg(ap, int);
  return kOfxStatOK;
}
static OfxStatus ParamGetValue(OfxParamHandle h, ...) { va_list ap; va_start(ap, h); auto r = GetV(reinterpret_cast<Param*>(h), ap); va_end(ap); return r; }
static OfxStatus ParamGetValueAtTime(OfxParamHandle h, OfxTime t, ...) { va_list ap; va_start(ap, t); auto r = GetV(reinterpret_cast<Param*>(h), ap); va_end(ap); return r; }
static OfxStatus ParamSetValue(OfxParamHandle h, ...) { va_list ap; va_start(ap, h); auto r = SetV(reinterpret_cast<Param*>(h), ap); va_end(ap); return r; }
static OfxStatus ParamUnsupported(...) { return kOfxStatErrUnsupported; }

// Copies descriptor defaults into values (what a host does when it creates an instance).
static void ApplyDefaults(ParamSet& set) {
  for (auto& [name, p] : set.params) {
    Props& pr = p->props;
    if (p->type == kOfxParamTypeString) p->s = pr.s[kOfxParamPropDefault].empty() ? "" : pr.s[kOfxParamPropDefault][0];
    else if (p->type == kOfxParamTypeRGB || p->type == kOfxParamTypeDouble)
      for (size_t k = 0; k < pr.d[kOfxParamPropDefault].size(); k++) p->d[k] = pr.d[kOfxParamPropDefault][k];
    else if (!pr.i[kOfxParamPropDefault].empty()) p->i = pr.i[kOfxParamPropDefault][0];
  }
}

// ---------- effect / clips / images ----------
struct Clip {
  Props props;
  bool connected = false;
};
struct Effect {
  Props props;
  ParamSet params;
  std::map<std::string, std::unique_ptr<Clip>> clips;
  std::vector<float> output;  // RGBA float, bottom row first
  Props outputImage;
};
static Effect* E(OfxImageEffectHandle h) { return reinterpret_cast<Effect*>(h); }
static OfxStatus GetPropertySet(OfxImageEffectHandle h, OfxPropertySetHandle* p) { *p = reinterpret_cast<OfxPropertySetHandle>(&E(h)->props); return kOfxStatOK; }
static OfxStatus GetParamSet(OfxImageEffectHandle h, OfxParamSetHandle* p) { *p = reinterpret_cast<OfxParamSetHandle>(&E(h)->params); return kOfxStatOK; }
static OfxStatus ClipDefine(OfxImageEffectHandle h, const char* name, OfxPropertySetHandle* p) {
  auto& c = E(h)->clips[name];
  c = std::make_unique<Clip>();
  *p = reinterpret_cast<OfxPropertySetHandle>(&c->props);
  return kOfxStatOK;
}
static OfxStatus ClipGetHandle(OfxImageEffectHandle h, const char* name, OfxImageClipHandle* clip, OfxPropertySetHandle* p) {
  auto it = E(h)->clips.find(name);
  if (it == E(h)->clips.end()) return kOfxStatErrBadIndex;
  *clip = reinterpret_cast<OfxImageClipHandle>(it->second.get());
  if (p) *p = reinterpret_cast<OfxPropertySetHandle>(&it->second->props);
  return kOfxStatOK;
}
static OfxStatus ClipGetPropertySet(OfxImageClipHandle clip, OfxPropertySetHandle* p) { *p = reinterpret_cast<OfxPropertySetHandle>(&reinterpret_cast<Clip*>(clip)->props); return kOfxStatOK; }
static Effect* gCurrent = nullptr;
static OfxStatus ClipGetImage(OfxImageClipHandle clip, OfxTime, const OfxRectD*, OfxPropertySetHandle* image) {
  Clip* c = reinterpret_cast<Clip*>(clip);
  if (c != gCurrent->clips[kOfxImageEffectOutputClipName].get()) return kOfxStatFailed;  // no source image
  Props& img = gCurrent->outputImage;
  int bounds[4] = {0, 0, 1920, 1080};
  SetIntN(reinterpret_cast<OfxPropertySetHandle>(&img), kOfxImagePropBounds, 4, bounds);
  SetInt(reinterpret_cast<OfxPropertySetHandle>(&img), kOfxImagePropRowBytes, 0, 1920 * 16);
  SetStr(reinterpret_cast<OfxPropertySetHandle>(&img), kOfxImageEffectPropPixelDepth, 0, kOfxBitDepthFloat);
  SetStr(reinterpret_cast<OfxPropertySetHandle>(&img), kOfxImageEffectPropComponents, 0, kOfxImageComponentRGBA);
  SetPtr(reinterpret_cast<OfxPropertySetHandle>(&img), kOfxImagePropData, 0, gCurrent->output.data());
  *image = reinterpret_cast<OfxPropertySetHandle>(&img);
  return kOfxStatOK;
}
static OfxStatus ClipReleaseImage(OfxPropertySetHandle) { return kOfxStatOK; }
static OfxStatus Message(void*, const char* type, const char*, const char* format, ...) {
  va_list ap;
  va_start(ap, format);
  printf("  [host message %s] ", type);
  vprintf(format, ap);
  printf("\n");
  va_end(ap);
  return kOfxStatOK;
}

static OfxPropertySuiteV1 gPropSuite;
static OfxParameterSuiteV1 gParamSuite;
static OfxImageEffectSuiteV1 gEffectSuite;
static OfxMessageSuiteV1 gMessageSuite;
static Props gHostProps;
static const void* FetchSuite(OfxPropertySetHandle, const char* name, int) {
  if (!strcmp(name, kOfxPropertySuite)) return &gPropSuite;
  if (!strcmp(name, kOfxParameterSuite)) return &gParamSuite;
  if (!strcmp(name, kOfxImageEffectSuite)) return &gEffectSuite;
  if (!strcmp(name, kOfxMessageSuite)) return &gMessageSuite;
  return nullptr;
}

static void SetupSuites() {
  gPropSuite.propSetPointer = SetPtr; gPropSuite.propSetString = SetStr; gPropSuite.propSetDouble = SetDbl;
  gPropSuite.propSetInt = SetInt; gPropSuite.propSetPointerN = SetPtrN; gPropSuite.propSetStringN = SetStrN;
  gPropSuite.propSetDoubleN = SetDblN; gPropSuite.propSetIntN = SetIntN; gPropSuite.propGetPointer = GetPtr;
  gPropSuite.propGetString = GetStr; gPropSuite.propGetDouble = GetDbl; gPropSuite.propGetInt = GetInt;
  gPropSuite.propGetPointerN = GetPtrN; gPropSuite.propGetStringN = GetStrN; gPropSuite.propGetDoubleN = GetDblN;
  gPropSuite.propGetIntN = GetIntN; gPropSuite.propReset = Reset; gPropSuite.propGetDimension = Dim;
  gParamSuite.paramDefine = ParamDefine; gParamSuite.paramGetHandle = ParamGetHandle;
  gParamSuite.paramSetGetPropertySet = ParamSetProps; gParamSuite.paramGetPropertySet = ParamProps;
  gParamSuite.paramGetValue = ParamGetValue; gParamSuite.paramGetValueAtTime = ParamGetValueAtTime;
  gParamSuite.paramSetValue = ParamSetValue;
  gEffectSuite.getPropertySet = GetPropertySet; gEffectSuite.getParamSet = GetParamSet;
  gEffectSuite.clipDefine = ClipDefine; gEffectSuite.clipGetHandle = ClipGetHandle;
  gEffectSuite.clipGetPropertySet = ClipGetPropertySet; gEffectSuite.clipGetImage = ClipGetImage;
  gEffectSuite.clipReleaseImage = ClipReleaseImage;
  gMessageSuite.message = Message;
}

static void SavePng(const std::vector<float>& rgba, const std::string& path) {
  std::vector<uint8_t> px(1920 * 1080 * 4);
  for (int y = 0; y < 1080; y++)
    for (int x = 0; x < 1920; x++)
      for (int c = 0; c < 4; c++) {
        float v = rgba[((size_t)(1079 - y) * 1920 + x) * 4 + c];  // OFX is bottom-up
        px[((size_t)y * 1920 + x) * 4 + c] = (uint8_t)std::lround(std::fmin(1, std::fmax(0, v)) * 255);
      }
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(px.data(), 1920, 1080, 8, 1920 * 4, cs, kCGImageAlphaPremultipliedLast);
  CGImageRef img = CGBitmapContextCreateImage(ctx);
  NSURL* url = [NSURL fileURLWithPath:@(path.c_str())];
  CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (__bridge CFStringRef)UTTypePNG.identifier, 1, nullptr);
  CGImageDestinationAddImage(d, img, nullptr);
  CGImageDestinationFinalize(d);
  CFRelease(d); CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs);
}

static int gFailures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { gFailures++; printf("  FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

static std::unique_ptr<Effect> MakeInstance(OfxPlugin* plugin) {
  auto fx = std::make_unique<Effect>();
  auto h = reinterpret_cast<OfxImageEffectHandle>(fx.get());
  CHECK(plugin->mainEntry(kOfxActionDescribe, h, nullptr, nullptr) == kOfxStatOK, "describe");
  Props in;
  SetStr(reinterpret_cast<OfxPropertySetHandle>(&in), kOfxImageEffectPropContext, 0, kOfxImageEffectContextFilter);
  CHECK(plugin->mainEntry(kOfxImageEffectActionDescribeInContext, h, reinterpret_cast<OfxPropertySetHandle>(&in), nullptr) == kOfxStatOK, "describe in context");
  ApplyDefaults(fx->params);
  double range[2] = {1001, 1100}, extent[2] = {1920, 1080}, origin[2] = {0, 0};
  auto fp = reinterpret_cast<OfxPropertySetHandle>(&fx->props);
  SetDblN(fp, kOfxImageEffectPropFrameRange, 2, range);
  SetDbl(fp, kOfxImageEffectPropFrameRate, 0, 25);
  SetDblN(fp, kOfxImageEffectPropProjectExtent, 2, extent);
  SetDblN(fp, kOfxImageEffectPropProjectOffset, 2, origin);
  for (auto& [name, clip] : fx->clips) SetInt(reinterpret_cast<OfxPropertySetHandle>(&clip->props), kOfxImageClipPropConnected, 0, 0);
  fx->output.assign(1920 * 1080 * 4, 0);
  CHECK(plugin->mainEntry(kOfxActionCreateInstance, h, nullptr, nullptr) != kOfxStatFailed, "create instance");
  return fx;
}

static Param* Get(Effect* fx, const char* name) {
  auto it = fx->params.params.find(name);
  return it == fx->params.params.end() ? nullptr : it->second.get();
}

static double Render(OfxPlugin* plugin, Effect* fx, double time, const std::string& png) {
  gCurrent = fx;
  std::fill(fx->output.begin(), fx->output.end(), 0.f);
  Props in;
  auto ip = reinterpret_cast<OfxPropertySetHandle>(&in);
  int window[4] = {0, 0, 1920, 1080};
  double scale[2] = {1, 1};
  SetDbl(ip, kOfxPropTime, 0, time);
  SetIntN(ip, kOfxImageEffectPropRenderWindow, 4, window);
  SetDblN(ip, kOfxImageEffectPropRenderScale, 2, scale);
  OfxStatus st = plugin->mainEntry(kOfxImageEffectActionRender, reinterpret_cast<OfxImageEffectHandle>(fx), ip, nullptr);
  CHECK(st == kOfxStatOK, "render at %.0f returned %d", time, st);
  double alpha = 0;
  for (size_t k = 3; k < fx->output.size(); k += 4) alpha += fx->output[k];
  if (!png.empty()) SavePng(fx->output, png);
  return alpha;
}

static void RunTests(std::string bundle, std::string zip, std::string out) {
  void* lib = dlopen((bundle + "/Contents/MacOS/OGrafFlame.ofx").c_str(), RTLD_NOW | RTLD_LOCAL);
  if (!lib) { printf("dlopen: %s\n", dlerror()); gFailures++; return; }
  auto count = (int (*)())dlsym(lib, "OfxGetNumberOfPlugins");
  auto get = (OfxPlugin * (*)(int)) dlsym(lib, "OfxGetPlugin");
  SetupSuites();
  static OfxHost host{reinterpret_cast<OfxPropertySetHandle>(&gHostProps), FetchSuite};
  int n = count();
  printf("plugins: %d\n", n);
  OfxPlugin *keynote = nullptr, *generic = nullptr;
  for (int k = 0; k < n; k++) {
    OfxPlugin* p = get(k);
    p->setHost(&host);
    CHECK(p->mainEntry(kOfxActionLoad, nullptr, nullptr, nullptr) == kOfxStatOK, "load %s", p->pluginIdentifier);
    auto fx = std::make_unique<Effect>();
    p->mainEntry(kOfxActionDescribe, reinterpret_cast<OfxImageEffectHandle>(fx.get()), nullptr, nullptr);
    printf("  %-45s \"%s\"\n", p->pluginIdentifier, fx->props.s[kOfxPropLabel][0].c_str());
    if (fx->props.s[kOfxPropLabel][0] == "Keynote Lower Third") keynote = p;
    if (std::string(p->pluginIdentifier) == "org.ograf.flame.generic") generic = p;
  }
  CHECK(keynote && generic, "expected the keynote and generic effects");
  if (!keynote || !generic) return;

  // Named effect: custom fields, In 15 frames, Out 40 frames, clip 1001..1100 (rel 0..99).
  printf("named effect:\n");
  auto fx = MakeInstance(keynote);
  for (auto& [name, p] : fx->params.params) {
    char* label = nullptr;
    GetStr(reinterpret_cast<OfxPropertySetHandle>(&p->props), kOfxPropLabel, 0, &label);
    printf("  param %-20s %-8s \"%s\"\n", name.c_str(), p->type.c_str() + 13, label ? label : "");
  }
  CHECK(Get(fx.get(), "ograf_inFrames")->i == 30 && Get(fx.get(), "ograf_outFrames")->i == 20, "default durations 30/20, got %d/%d", Get(fx.get(), "ograf_inFrames")->i, Get(fx.get(), "ograf_outFrames")->i);
  Get(fx.get(), "field_name")->s = "Mock Host";
  Get(fx.get(), "field_title")->s = "Durations In 15 / Out 40";
  Param* accent = Get(fx.get(), "field_accent");
  accent->d[0] = 1.0; accent->d[1] = 0.6; accent->d[2] = 0.0;
  Get(fx.get(), "ograf_inFrames")->i = 15;
  Get(fx.get(), "ograf_outFrames")->i = 40;
  struct Probe { double time; const char* expect; };
  for (Probe pr : {Probe{1000, "empty"}, {1001, "empty"}, {1008, "partial"}, {1016, "full"}, {1050, "full"},
                   {1060, "partial"}, {1080, "partial"}, {1100, "empty"}}) {
    char name[64];
    snprintf(name, sizeof name, "/named_%d.png", (int)pr.time);
    double a = Render(keynote, fx.get(), pr.time, out + name);
    printf("  frame %.0f: alpha sum %.0f (%s)\n", pr.time, a, pr.expect);
    if (!strcmp(pr.expect, "empty")) CHECK(a < 1, "frame %.0f should be empty", pr.time);
    else CHECK(a > 1000, "frame %.0f should show the graphic", pr.time);
  }

  // Generic effect: pick the template, controls get relabelled with the template's defaults.
  printf("generic effect:\n");
  auto gx = MakeInstance(generic);
  double a0 = Render(generic, gx.get(), 1031, "");
  CHECK(a0 < 1, "generic without a template renders nothing");
  Get(gx.get(), "ograf_template")->s = zip;
  Props in;
  auto ip = reinterpret_cast<OfxPropertySetHandle>(&in);
  SetStr(ip, kOfxPropType, 0, kOfxTypeParameter);
  SetStr(ip, kOfxPropName, 0, "ograf_template");
  SetStr(ip, kOfxPropChangeReason, 0, kOfxChangeUserEdited);
  SetDbl(ip, kOfxPropTime, 0, 1001);
  generic->mainEntry(kOfxActionInstanceChanged, reinterpret_cast<OfxImageEffectHandle>(gx.get()), ip, nullptr);
  for (const char* n : {"text_1", "text_2", "text_3", "color_1", "color_2", "number_1"}) {
    Param* p = Get(gx.get(), n);
    char* label = nullptr;
    int secret = 0;
    GetStr(reinterpret_cast<OfxPropertySetHandle>(&p->props), kOfxPropLabel, 0, &label);
    GetInt(reinterpret_cast<OfxPropertySetHandle>(&p->props), kOfxParamPropSecret, 0, &secret);
    printf("  %-9s label \"%s\" %s value \"%s\"\n", n, label, secret ? "(hidden)" : "(shown) ", p->type == kOfxParamTypeString ? p->s.c_str() : "");
  }
  char* l1 = nullptr;
  GetStr(reinterpret_cast<OfxPropertySetHandle>(&Get(gx.get(), "text_1")->props), kOfxPropLabel, 0, &l1);
  CHECK(l1 && std::string(l1) == "Name", "text_1 relabelled to Name");
  CHECK(Get(gx.get(), "text_1")->s == "ALEX MORGAN", "text_1 default loaded");
  CHECK(Get(gx.get(), "ograf_inFrames")->i == 30, "generic In duration set from template");
  double a1 = Render(generic, gx.get(), 1040, out + "/generic_1040.png");
  printf("  frame 1040: alpha sum %.0f\n", a1);
  CHECK(a1 > 1000, "generic renders the template");
}

int main(int argc, char* argv[]) {
  @autoreleasepool {
    if (argc < 4) { fprintf(stderr, "usage: %s <bundle> <zip> <outDir>\n", argv[0]); return 64; }
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    std::string b = argv[1], z = argv[2], o = argv[3];
    std::thread([=] {
      RunTests(b, z, o);
      printf(gFailures ? "%d FAILURE(S)\n" : "ALL CHECKS PASSED\n", gFailures);
      fflush(stdout);
      dispatch_async(dispatch_get_main_queue(), ^{ exit(gFailures ? 1 : 0); });
    }).detach();
    [NSApp run];
  }
  return 0;
}
