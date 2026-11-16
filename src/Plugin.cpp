// OFX entry points.
//  - Every OGraf template found in the template folders becomes its own named effect, with one
//    control per template field (fixed when Flame loads plugins at startup).
//  - One generic "OGraf Template" effect picks any .ograf.zip at run time and relabels a pool of
//    spare controls to that template's fields, so new templates work without restarting Flame.
#include <sys/stat.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "Package.h"
#include "Renderer.h"
#include "Timing.h"
#include "json.hpp"
#include "ofxCore.h"
#include "ofxImageEffect.h"
#include "ofxMessage.h"
#include "ofxParam.h"
#include "ofxProperty.h"

using nlohmann::json;
using namespace ograf;

#define OGRAF_EXPORT extern "C" __attribute__((visibility("default")))

namespace {

constexpr int kMaxPlugins = 64;  // named templates + the generic node

OfxHost* gHost = nullptr;
const OfxPropertySuiteV1* gProp = nullptr;
const OfxImageEffectSuiteV1* gEffect = nullptr;
const OfxParameterSuiteV1* gParam = nullptr;
const OfxMessageSuiteV1* gMessage = nullptr;

std::vector<Template> gTemplates;  // named effects; index == plugin index
std::vector<std::string> gIdentifiers;
OfxPlugin gPlugins[kMaxPlugins];
int gPluginCount = 0;
int gGenericIndex = -1;
bool gScanned = false;

const char* kParamTemplate = "ograf_template";
const char* kParamInFrames = "ograf_inFrames";
const char* kParamOutFrames = "ograf_outFrames";
const char* kParamPlayOut = "ograf_playOut";
const char* kParamOffset = "ograf_startOffset";
const char* kParamComposite = "ograf_composite";

// Spare-control pools of the generic node.
struct Pool {
  FieldKind kind;
  const char* prefix;
  const char* label;
  int count;
};
const Pool kPools[] = {{FieldKind::Text, "text_", "Text", 8},
                       {FieldKind::Color, "color_", "Colour", 4},
                       {FieldKind::Number, "number_", "Number", 4},
                       {FieldKind::Boolean, "toggle_", "Toggle", 4}};

FieldKind PoolKind(FieldKind k) { return k == FieldKind::Integer ? FieldKind::Number : k; }

// A template field and the parameter that drives it.
struct Binding {
  Field field;
  std::string param;
  FieldKind paramKind;
};

std::vector<Binding> Bindings(const Template& t, bool generic) {
  std::vector<Binding> out;
  if (!generic) {
    for (const Field& f : t.fields) out.push_back({f, "field_" + f.key, f.kind});
    return out;
  }
  std::map<FieldKind, int> used;
  for (const Field& f : t.fields) {
    FieldKind k = PoolKind(f.kind);
    for (const Pool& p : kPools) {
      if (p.kind != k) continue;
      int n = ++used[k];
      if (n <= p.count) out.push_back({f, p.prefix + std::to_string(n), k});
      else Log("template %s: no spare %s control left for field %s", t.name.c_str(), p.label, f.key.c_str());
    }
  }
  return out;
}

// Manifest cache for run-time template paths (generic node).
bool CachedTemplate(const std::string& path, Template& out, std::string& error) {
  static std::mutex m;
  static std::map<std::string, std::pair<std::string, Template>> cache;
  struct stat st {};
  if (path.empty()) {
    error = "no template selected";
    return false;
  }
  if (stat(path.c_str(), &st) != 0) {
    error = "template not found: " + path;
    return false;
  }
  std::string stamp = std::to_string(st.st_size) + ":" + std::to_string(st.st_mtimespec.tv_sec);
  std::lock_guard<std::mutex> lock(m);
  auto it = cache.find(path);
  if (it != cache.end() && it->second.first == stamp) {
    out = it->second.second;
    return true;
  }
  if (!ReadTemplate(path, out, error)) return false;
  if (!out.supportsNonRealTime) {
    error = "this package is real-time only; export it with the Non-real-time or Dual profile";
    return false;
  }
  cache[path] = {stamp, out};
  return true;
}

std::string Identifier(const Template& t) {
  std::string base = t.id.empty() ? t.name : t.id;
  std::string out;
  for (char c : base) out += isalnum(static_cast<unsigned char>(c)) ? c : '_';
  return "org.ograf.flame." + out;
}

int TemplateFrames(double ms, double fps) {
  return ms > 0 ? std::max(1, static_cast<int>(std::lround(ms / 1000.0 * fps))) : 1;
}

void SetHost(OfxHost* host) { gHost = host; }

OfxStatus OnLoad() {
  if (!gHost) return kOfxStatErrMissingHostFeature;
  gProp = static_cast<const OfxPropertySuiteV1*>(gHost->fetchSuite(gHost->host, kOfxPropertySuite, 1));
  gEffect = static_cast<const OfxImageEffectSuiteV1*>(
      gHost->fetchSuite(gHost->host, kOfxImageEffectSuite, 1));
  gParam = static_cast<const OfxParameterSuiteV1*>(gHost->fetchSuite(gHost->host, kOfxParameterSuite, 1));
  gMessage = static_cast<const OfxMessageSuiteV1*>(gHost->fetchSuite(gHost->host, kOfxMessageSuite, 1));
  return gProp && gEffect && gParam ? kOfxStatOK : kOfxStatErrMissingHostFeature;
}

// ---------- describe ----------
OfxStatus Describe(const Template* t, OfxImageEffectHandle effect) {
  OfxPropertySetHandle props;
  gEffect->getPropertySet(effect, &props);
  std::string label = t ? t->name : "OGraf Template";
  std::string description = t ? "OGraf template rendered with embedded Chromium.\n" + t->zipPath
                              : "Renders any OGraf .ograf.zip (Non-real-time or Dual profile) with "
                                "embedded Chromium. Pick the file in Template.";
  gProp->propSetString(props, kOfxPropLabel, 0, label.c_str());
  gProp->propSetString(props, kOfxImageEffectPluginPropGrouping, 0, "OGraf");
  gProp->propSetString(props, kOfxPropPluginDescription, 0, description.c_str());
  gProp->propSetString(props, kOfxImageEffectPropSupportedContexts, 0, kOfxImageEffectContextFilter);
  gProp->propSetString(props, kOfxImageEffectPropSupportedContexts, 1, kOfxImageEffectContextGeneral);
  gProp->propSetString(props, kOfxImageEffectPropSupportedContexts, 2, kOfxImageEffectContextGenerator);
  const char* depths[] = {kOfxBitDepthFloat, kOfxBitDepthHalf, kOfxBitDepthShort, kOfxBitDepthByte};
  for (int i = 0; i < 4; i++) gProp->propSetString(props, kOfxImageEffectPropSupportedPixelDepths, i, depths[i]);
  gProp->propSetInt(props, kOfxImageEffectPropSupportsTiles, 0, 0);
  gProp->propSetInt(props, kOfxImageEffectPropSupportsMultipleClipDepths, 0, 0);
  gProp->propSetInt(props, kOfxImageEffectPluginPropHostFrameThreading, 0, 0);
  gProp->propSetInt(props, kOfxImageEffectPluginPropFieldRenderTwiceAlways, 0, 0);
  gProp->propSetString(props, kOfxImageEffectPluginRenderThreadSafety, 0, kOfxImageEffectRenderUnsafe);
  return kOfxStatOK;
}

void DefineClip(OfxImageEffectHandle effect, const char* name, bool optional) {
  OfxPropertySetHandle clip;
  gEffect->clipDefine(effect, name, &clip);
  gProp->propSetString(clip, kOfxImageEffectPropSupportedComponents, 0, kOfxImageComponentRGBA);
  gProp->propSetInt(clip, kOfxImageClipPropOptional, 0, optional ? 1 : 0);
  gProp->propSetInt(clip, kOfxImageEffectPropSupportsTiles, 0, 0);
}

OfxPropertySetHandle DefineFieldParam(OfxParamSetHandle params, FieldKind kind, const std::string& name,
                                      const std::string& label, const Field* def) {
  OfxPropertySetHandle p = nullptr;
  switch (kind) {
    case FieldKind::Text:
      gParam->paramDefine(params, kOfxParamTypeString, name.c_str(), &p);
      gProp->propSetString(p, kOfxParamPropDefault, 0, def ? def->defText.c_str() : "");
      gProp->propSetString(p, kOfxParamPropStringMode, 0, kOfxParamStringIsSingleLine);
      gProp->propSetInt(p, kOfxParamPropAnimates, 0, 0);
      break;
    case FieldKind::Color: {
      unsigned r = 255, g = 255, b = 255;
      if (def) sscanf(def->defText.c_str(), "#%02x%02x%02x", &r, &g, &b);
      gParam->paramDefine(params, kOfxParamTypeRGB, name.c_str(), &p);
      gProp->propSetDouble(p, kOfxParamPropDefault, 0, r / 255.0);
      gProp->propSetDouble(p, kOfxParamPropDefault, 1, g / 255.0);
      gProp->propSetDouble(p, kOfxParamPropDefault, 2, b / 255.0);
      break;
    }
    case FieldKind::Number:
      gParam->paramDefine(params, kOfxParamTypeDouble, name.c_str(), &p);
      gProp->propSetDouble(p, kOfxParamPropDefault, 0, def ? def->defNumber : 0);
      gProp->propSetDouble(p, kOfxParamPropDisplayMin, 0, std::min(0.0, def ? def->defNumber : 0));
      gProp->propSetDouble(p, kOfxParamPropDisplayMax, 0, std::max(100.0, def ? def->defNumber * 2 : 0));
      break;
    case FieldKind::Integer:
      gParam->paramDefine(params, kOfxParamTypeInteger, name.c_str(), &p);
      gProp->propSetInt(p, kOfxParamPropDefault, 0, def ? static_cast<int>(def->defNumber) : 0);
      break;
    case FieldKind::Boolean:
      gParam->paramDefine(params, kOfxParamTypeBoolean, name.c_str(), &p);
      gProp->propSetInt(p, kOfxParamPropDefault, 0, def && def->defNumber != 0 ? 1 : 0);
      break;
  }
  gProp->propSetString(p, kOfxPropLabel, 0, label.c_str());
  return p;
}

OfxStatus DescribeInContext(const Template* t, OfxImageEffectHandle effect, OfxPropertySetHandle inArgs) {
  char* context = nullptr;
  gProp->propGetString(inArgs, kOfxImageEffectPropContext, 0, &context);
  std::string ctx = context ? context : "";
  DefineClip(effect, kOfxImageEffectOutputClipName, false);
  if (ctx != kOfxImageEffectContextGenerator)
    DefineClip(effect, kOfxImageEffectSimpleSourceClipName, ctx == kOfxImageEffectContextGeneral);

  OfxParamSetHandle params;
  gEffect->getParamSet(effect, &params);
  OfxPropertySetHandle p;

  if (t) {
    for (const Field& f : t->fields) {
      p = DefineFieldParam(params, f.kind, "field_" + f.key, f.label, &f);
      gProp->propSetString(p, kOfxParamPropHint, 0, ("OGraf field \"" + f.key + "\"").c_str());
    }
  } else {
    gParam->paramDefine(params, kOfxParamTypeString, kParamTemplate, &p);
    gProp->propSetString(p, kOfxPropLabel, 0, "Template");
    gProp->propSetString(p, kOfxParamPropHint, 0,
                         "An OGraf .ograf.zip exported with the Non-real-time or Dual profile.");
    gProp->propSetString(p, kOfxParamPropStringMode, 0, kOfxParamStringIsFilePath);
    gProp->propSetInt(p, kOfxParamPropStringFilePathExists, 0, 1);
    gProp->propSetString(p, kOfxParamPropDefault, 0, "");
    gProp->propSetInt(p, kOfxParamPropAnimates, 0, 0);
    for (const Pool& pool : kPools)
      for (int i = 1; i <= pool.count; i++) {
        p = DefineFieldParam(params, pool.kind, pool.prefix + std::to_string(i),
                             std::string(pool.label) + " " + std::to_string(i), nullptr);
        gProp->propSetInt(p, kOfxParamPropSecret, 0, 1);  // shown once a template uses it
      }
  }

  // Timing.
  int inDef = t ? TemplateFrames(t->playMs, t->frameRate) : 30;
  int outDef = t ? TemplateFrames(t->stopMs, t->frameRate) : 20;
  gParam->paramDefine(params, kOfxParamTypeInteger, kParamInFrames, &p);
  gProp->propSetString(p, kOfxPropLabel, 0, "In Duration");
  gProp->propSetString(p, kOfxParamPropHint, 0,
                       "Length of the In animation in frames. The template's own timing is scaled to fit.");
  gProp->propSetInt(p, kOfxParamPropDefault, 0, inDef);
  gProp->propSetInt(p, kOfxParamPropMin, 0, 1);
  gProp->propSetInt(p, kOfxParamPropDisplayMin, 0, 1);
  gProp->propSetInt(p, kOfxParamPropDisplayMax, 0, 150);
  gProp->propSetInt(p, kOfxParamPropAnimates, 0, 0);

  gParam->paramDefine(params, kOfxParamTypeInteger, kParamOutFrames, &p);
  gProp->propSetString(p, kOfxPropLabel, 0, "Out Duration");
  gProp->propSetString(p, kOfxParamPropHint, 0,
                       "Length of the Out animation in frames; it ends on the last frame of the clip.");
  gProp->propSetInt(p, kOfxParamPropDefault, 0, outDef);
  gProp->propSetInt(p, kOfxParamPropMin, 0, 1);
  gProp->propSetInt(p, kOfxParamPropDisplayMin, 0, 1);
  gProp->propSetInt(p, kOfxParamPropDisplayMax, 0, 150);
  gProp->propSetInt(p, kOfxParamPropAnimates, 0, 0);

  gParam->paramDefine(params, kOfxParamTypeBoolean, kParamPlayOut, &p);
  gProp->propSetString(p, kOfxPropLabel, 0, "Play Out");
  gProp->propSetString(p, kOfxParamPropHint, 0,
                       "Play the Out animation so it finishes on the last frame of the clip.");
  gProp->propSetInt(p, kOfxParamPropDefault, 0, 1);
  gProp->propSetInt(p, kOfxParamPropAnimates, 0, 0);

  gParam->paramDefine(params, kOfxParamTypeInteger, kParamOffset, &p);
  gProp->propSetString(p, kOfxPropLabel, 0, "Start Offset");
  gProp->propSetString(p, kOfxParamPropHint, 0, "Frames to wait after the clip start before the In.");
  gProp->propSetInt(p, kOfxParamPropDefault, 0, 0);
  gProp->propSetInt(p, kOfxParamPropDisplayMin, 0, 0);
  gProp->propSetInt(p, kOfxParamPropDisplayMax, 0, 250);
  gProp->propSetInt(p, kOfxParamPropAnimates, 0, 0);

  if (ctx != kOfxImageEffectContextGenerator) {
    gParam->paramDefine(params, kOfxParamTypeBoolean, kParamComposite, &p);
    gProp->propSetString(p, kOfxPropLabel, 0, "Over Source");
    gProp->propSetString(p, kOfxParamPropHint, 0,
                         "On: graphic composited over the source clip. Off: graphic only, with alpha.");
    gProp->propSetInt(p, kOfxParamPropDefault, 0, 1);
    gProp->propSetInt(p, kOfxParamPropAnimates, 0, 0);
  }
  return kOfxStatOK;
}

// ---------- instance helpers ----------
OfxParamHandle Param(OfxImageEffectHandle effect, const std::string& name) {
  OfxParamSetHandle params;
  gEffect->getParamSet(effect, &params);
  OfxParamHandle h = nullptr;
  gParam->paramGetHandle(params, name.c_str(), &h, nullptr);
  return h;
}

std::string StringParam(OfxImageEffectHandle effect, const char* name) {
  OfxParamHandle h = Param(effect, name);
  char* s = nullptr;
  if (h) gParam->paramGetValue(h, &s);
  return s ? s : "";
}

int IntParam(OfxImageEffectHandle effect, const char* name, int fallback) {
  OfxParamHandle h = Param(effect, name);
  int v = fallback;
  if (h) gParam->paramGetValue(h, &v);
  return v;
}

bool ClipConnected(OfxImageEffectHandle effect, const char* name, OfxImageClipHandle* clip) {
  if (gEffect->clipGetHandle(effect, name, clip, nullptr) != kOfxStatOK) return false;
  OfxPropertySetHandle props;
  gEffect->clipGetPropertySet(*clip, &props);
  int connected = 0;
  gProp->propGetInt(props, kOfxImageClipPropConnected, 0, &connected);
  return connected != 0;
}

double EffectFps(OfxImageEffectHandle effect, double fallback) {
  OfxPropertySetHandle fx;
  gEffect->getPropertySet(effect, &fx);
  double fps = 0;
  gProp->propGetDouble(fx, kOfxImageEffectPropFrameRate, 0, &fps);
  return fps > 0 ? fps : fallback;
}

std::string ColorHex(double r, double g, double b) {
  auto c = [](double v) { return static_cast<int>(std::lround(std::clamp(v, 0.0, 1.0) * 255)); };
  char buf[8];
  snprintf(buf, sizeof buf, "#%02x%02x%02x", c(r), c(g), c(b));
  return buf;
}

json FieldData(const std::vector<Binding>& bindings, OfxImageEffectHandle effect, double time) {
  json data = json::object();
  for (const Binding& b : bindings) {
    OfxParamHandle h = Param(effect, b.param);
    if (!h) continue;
    switch (b.paramKind) {
      case FieldKind::Text: {
        char* s = nullptr;
        gParam->paramGetValueAtTime(h, time, &s);
        data[b.field.key] = s ? s : "";
        break;
      }
      case FieldKind::Color: {
        double r = 1, g = 1, bl = 1;
        gParam->paramGetValueAtTime(h, time, &r, &g, &bl);
        data[b.field.key] = ColorHex(r, g, bl);
        break;
      }
      case FieldKind::Number: {
        double v = 0;
        gParam->paramGetValueAtTime(h, time, &v);
        if (b.field.kind == FieldKind::Integer) data[b.field.key] = static_cast<long long>(std::lround(v));
        else data[b.field.key] = v;
        break;
      }
      case FieldKind::Integer: {
        int v = 0;
        gParam->paramGetValueAtTime(h, time, &v);
        data[b.field.key] = v;
        break;
      }
      case FieldKind::Boolean: {
        int v = 0;
        gParam->paramGetValueAtTime(h, time, &v);
        data[b.field.key] = v != 0;
        break;
      }
    }
  }
  return data;
}

// Generic node: relabel/show the spare controls for the chosen template. When `reset` is set
// (the artist just picked a template), also load the template's defaults and timing.
void ApplyTemplateToControls(OfxImageEffectHandle effect, bool reset) {
  Template t;
  std::string error;
  bool have = CachedTemplate(StringParam(effect, kParamTemplate), t, error);
  std::map<std::string, const Binding*> bound;
  std::vector<Binding> bindings;
  if (have) bindings = Bindings(t, true);
  for (const Binding& b : bindings) bound[b.param] = &b;

  for (const Pool& pool : kPools)
    for (int i = 1; i <= pool.count; i++) {
      std::string name = pool.prefix + std::to_string(i);
      OfxParamHandle h = Param(effect, name);
      if (!h) continue;
      OfxPropertySetHandle props;
      gParam->paramGetPropertySet(h, &props);
      auto it = bound.find(name);
      if (it == bound.end()) {
        gProp->propSetInt(props, kOfxParamPropSecret, 0, 1);
        gProp->propSetString(props, kOfxPropLabel, 0, (std::string(pool.label) + " " + std::to_string(i)).c_str());
        continue;
      }
      const Field& f = it->second->field;
      gProp->propSetString(props, kOfxPropLabel, 0, f.label.c_str());
      gProp->propSetString(props, kOfxParamPropHint, 0, ("OGraf field \"" + f.key + "\"").c_str());
      gProp->propSetInt(props, kOfxParamPropSecret, 0, 0);
      if (!reset) continue;
      switch (pool.kind) {
        case FieldKind::Text: gParam->paramSetValue(h, f.defText.c_str()); break;
        case FieldKind::Color: {
          unsigned r = 255, g = 255, b = 255;
          sscanf(f.defText.c_str(), "#%02x%02x%02x", &r, &g, &b);
          gParam->paramSetValue(h, r / 255.0, g / 255.0, b / 255.0);
          break;
        }
        case FieldKind::Number: gParam->paramSetValue(h, f.defNumber); break;
        case FieldKind::Boolean: gParam->paramSetValue(h, f.defNumber != 0 ? 1 : 0); break;
        default: break;
      }
    }
  if (have && reset) {
    double fps = EffectFps(effect, t.frameRate);
    if (OfxParamHandle h = Param(effect, kParamInFrames)) gParam->paramSetValue(h, TemplateFrames(t.playMs, fps));
    if (OfxParamHandle h = Param(effect, kParamOutFrames)) gParam->paramSetValue(h, TemplateFrames(t.stopMs, fps));
  }
  if (!have && !StringParam(effect, kParamTemplate).empty()) Log("generic node: %s", error.c_str());
}

struct Image {
  OfxPropertySetHandle handle = nullptr;
  uint8_t* data = nullptr;
  int bounds[4] = {0, 0, 0, 0};
  int rowBytes = 0;
  std::string depth;
  bool Load(OfxImageClipHandle clip, double time) {
    if (gEffect->clipGetImage(clip, time, nullptr, &handle) != kOfxStatOK) return false;
    void* ptr = nullptr;
    gProp->propGetPointer(handle, kOfxImagePropData, 0, &ptr);
    data = static_cast<uint8_t*>(ptr);
    gProp->propGetIntN(handle, kOfxImagePropBounds, 4, bounds);
    gProp->propGetInt(handle, kOfxImagePropRowBytes, 0, &rowBytes);
    char* d = nullptr;
    gProp->propGetString(handle, kOfxImageEffectPropPixelDepth, 0, &d);
    depth = d ? d : "";
    return data != nullptr;
  }
  ~Image() {
    if (handle) gEffect->clipReleaseImage(handle);
  }
  int BytesPerChannel() const {
    if (depth == kOfxBitDepthFloat) return 4;
    if (depth == kOfxBitDepthHalf || depth == kOfxBitDepthShort) return 2;
    return 1;
  }
  uint8_t* Pixel(int x, int y) const {
    return data + static_cast<ptrdiff_t>(y - bounds[1]) * rowBytes +
           static_cast<ptrdiff_t>(x - bounds[0]) * 4 * BytesPerChannel();
  }
  bool Contains(int x, int y) const {
    return x >= bounds[0] && x < bounds[2] && y >= bounds[1] && y < bounds[3];
  }
  void Read(int x, int y, float rgba[4]) const {
    const uint8_t* p = Pixel(x, y);
    for (int c = 0; c < 4; c++) {
      if (depth == kOfxBitDepthFloat) rgba[c] = reinterpret_cast<const float*>(p)[c];
      else if (depth == kOfxBitDepthHalf) rgba[c] = static_cast<float>(reinterpret_cast<const __fp16*>(p)[c]);
      else if (depth == kOfxBitDepthShort) rgba[c] = reinterpret_cast<const uint16_t*>(p)[c] / 65535.0f;
      else rgba[c] = p[c] / 255.0f;
    }
  }
  void Write(int x, int y, const float rgba[4]) const {
    uint8_t* p = Pixel(x, y);
    for (int c = 0; c < 4; c++) {
      float v = rgba[c];
      if (depth == kOfxBitDepthFloat) reinterpret_cast<float*>(p)[c] = v;
      else if (depth == kOfxBitDepthHalf) reinterpret_cast<__fp16*>(p)[c] = static_cast<__fp16>(v);
      else if (depth == kOfxBitDepthShort)
        reinterpret_cast<uint16_t*>(p)[c] = static_cast<uint16_t>(std::lround(std::clamp(v, 0.f, 1.f) * 65535));
      else p[c] = static_cast<uint8_t>(std::lround(std::clamp(v, 0.f, 1.f) * 255));
    }
  }
};

void PostError(OfxImageEffectHandle effect, const std::string& message) {
  Log("render error: %s", message.c_str());
  if (gMessage) gMessage->message(effect, kOfxMessageError, nullptr, "OGraf: %s", message.c_str());
}

// ---------- render ----------
OfxStatus Render(const Template* named, OfxImageEffectHandle effect, OfxPropertySetHandle inArgs) {
  double time = 0;
  int window[4];
  double scale[2] = {1, 1};
  gProp->propGetDouble(inArgs, kOfxPropTime, 0, &time);
  gProp->propGetIntN(inArgs, kOfxImageEffectPropRenderWindow, 4, window);
  gProp->propGetDoubleN(inArgs, kOfxImageEffectPropRenderScale, 2, scale);

  OfxImageClipHandle outClip, srcClip = nullptr;
  gEffect->clipGetHandle(effect, kOfxImageEffectOutputClipName, &outClip, nullptr);
  Image out;
  if (!out.Load(outClip, time)) return kOfxStatFailed;

  bool composite = IntParam(effect, kParamComposite, 0) != 0;
  Image src;
  bool haveSource = ClipConnected(effect, kOfxImageEffectSimpleSourceClipName, &srcClip) && src.Load(srcClip, time);

  // Which template?
  Template genericTemplate;
  const Template* t = named;
  std::string error;
  if (!t) {
    if (!CachedTemplate(StringParam(effect, kParamTemplate), genericTemplate, error)) {
      // No template yet: pass the source through (or transparent) rather than failing.
      for (int y = window[1]; y < window[3]; y++)
        for (int x = window[0]; x < window[2]; x++) {
          if (!out.Contains(x, y)) continue;
          float px[4] = {0, 0, 0, 0};
          if (composite && haveSource && src.Contains(x, y)) src.Read(x, y, px);
          out.Write(x, y, px);
        }
      return kOfxStatOK;
    }
    t = &genericTemplate;
  }

  // Timing: In at the start of the effect's frame range (+ offset), Out ending on its last frame.
  OfxPropertySetHandle fx;
  gEffect->getPropertySet(effect, &fx);
  double range[2] = {0, 0};
  double fps = 0;
  if (haveSource) {
    OfxPropertySetHandle cp;
    gEffect->clipGetPropertySet(srcClip, &cp);
    gProp->propGetDoubleN(cp, kOfxImageEffectPropFrameRange, 2, range);
    gProp->propGetDouble(cp, kOfxImageEffectPropFrameRate, 0, &fps);
  } else {
    gProp->propGetDoubleN(fx, kOfxImageEffectPropFrameRange, 2, range);
    gProp->propGetDouble(fx, kOfxImageEffectPropFrameRate, 0, &fps);
  }
  if (!(fps > 0)) fps = t->frameRate;
  int offset = IntParam(effect, kParamOffset, 0);
  TimingInput ti{time - range[0] - offset,
                 range[1] - range[0] - offset,
                 fps,
                 static_cast<double>(IntParam(effect, kParamInFrames, TemplateFrames(t->playMs, fps))),
                 static_cast<double>(IntParam(effect, kParamOutFrames, TemplateFrames(t->stopMs, fps))),
                 t->playMs,
                 t->stopMs,
                 IntParam(effect, kParamPlayOut, 1) != 0 && range[1] > range[0]};
  TimingResult tr = MapTiming(ti);

  json data = FieldData(Bindings(*t, named == nullptr), effect, time);
  json schedule = json::array();
  schedule.push_back({{"timestamp", 0}, {"action", {{"type", "updateAction"}, {"params", {{"data", data}}}}}});
  schedule.push_back({{"timestamp", 0}, {"action", {{"type", "playAction"}, {"params", json::object()}}}});
  if (tr.stopAtMs >= 0)
    schedule.push_back({{"timestamp", tr.stopAtMs}, {"action", {{"type", "stopAction"}, {"params", json::object()}}}});

  std::vector<uint8_t> pixels;
  if (tr.visible) {
    std::string root;
    if (!ExtractTemplate(*t, root, error)) {
      PostError(effect, error);
      return kOfxStatFailed;
    }
    FrameRequest req;
    req.packageRoot = root;
    req.mainPath = t->mainPath;
    req.width = t->width;
    req.height = t->height;
    req.dataJson = data.dump(-1, ' ', true);
    req.scheduleJson = schedule.dump(-1, ' ', true);
    req.timestampMs = tr.templateMs;
    if (!RenderFrame(req, pixels, error)) {
      PostError(effect, error);
      return kOfxStatFailed;
    }
  }

  // Map the project frame (canonical coordinates) onto the graphic's pixels.
  double extent[2] = {static_cast<double>(t->width), static_cast<double>(t->height)};
  double origin[2] = {0, 0};
  gProp->propGetDoubleN(fx, kOfxImageEffectPropProjectExtent, 2, extent);
  gProp->propGetDoubleN(fx, kOfxImageEffectPropProjectOffset, 2, origin);
  const int W = t->width, H = t->height;
  auto sample = [&](double gx, double gy, float rgba[4]) {
    // Bilinear sample of premultiplied BGRA (top row first).
    gx -= 0.5;
    gy -= 0.5;
    int x0 = static_cast<int>(std::floor(gx)), y0 = static_cast<int>(std::floor(gy));
    double ax = gx - x0, ay = gy - y0;
    float acc[4] = {0, 0, 0, 0};
    for (int j = 0; j < 2; j++)
      for (int i = 0; i < 2; i++) {
        int x = x0 + i, y = y0 + j;
        double w = (i ? ax : 1 - ax) * (j ? ay : 1 - ay);
        if (w <= 0 || x < 0 || y < 0 || x >= W || y >= H) continue;
        const uint8_t* p = &pixels[(static_cast<size_t>(y) * W + x) * 4];
        acc[0] += static_cast<float>(w * p[2] / 255.0);
        acc[1] += static_cast<float>(w * p[1] / 255.0);
        acc[2] += static_cast<float>(w * p[0] / 255.0);
        acc[3] += static_cast<float>(w * p[3] / 255.0);
      }
    std::copy(acc, acc + 4, rgba);
  };

  for (int y = window[1]; y < window[3]; y++) {
    double cy = (y + 0.5) / scale[1];
    double gy = (1.0 - (cy - origin[1]) / extent[1]) * H;  // OFX rows go bottom-up
    for (int x = window[0]; x < window[2]; x++) {
      if (!out.Contains(x, y)) continue;
      float g[4] = {0, 0, 0, 0};
      if (!pixels.empty()) {
        double cx = (x + 0.5) / scale[0];
        sample((cx - origin[0]) / extent[0] * W, gy, g);
      }
      if (composite && haveSource && src.Contains(x, y)) {
        float s[4];
        src.Read(x, y, s);
        for (int c = 0; c < 4; c++) g[c] = g[c] + s[c] * (1.0f - g[3]);
      }
      out.Write(x, y, g);
    }
  }
  return kOfxStatOK;
}

OfxStatus GetRegionOfDefinition(OfxImageEffectHandle effect, OfxPropertySetHandle outArgs) {
  OfxPropertySetHandle fx;
  gEffect->getPropertySet(effect, &fx);
  double extent[2] = {1920, 1080}, origin[2] = {0, 0};
  gProp->propGetDoubleN(fx, kOfxImageEffectPropProjectExtent, 2, extent);
  gProp->propGetDoubleN(fx, kOfxImageEffectPropProjectOffset, 2, origin);
  double rod[4] = {origin[0], origin[1], origin[0] + extent[0], origin[1] + extent[1]};
  gProp->propSetDoubleN(outArgs, kOfxImageEffectPropRegionOfDefinition, 4, rod);
  return kOfxStatOK;
}

OfxStatus GetClipPreferences(OfxPropertySetHandle outArgs) {
  gProp->propSetString(outArgs, kOfxImageEffectPropPreMultiplication, 0, kOfxImagePreMultiplied);
  gProp->propSetInt(outArgs, kOfxImageEffectFrameVarying, 0, 1);
  return kOfxStatOK;
}

OfxStatus InstanceChanged(OfxImageEffectHandle effect, OfxPropertySetHandle inArgs) {
  char* name = nullptr;
  char* reason = nullptr;
  gProp->propGetString(inArgs, kOfxPropName, 0, &name);
  gProp->propGetString(inArgs, kOfxPropChangeReason, 0, &reason);
  if (name && !strcmp(name, kParamTemplate)) {
    bool userEdit = reason && !strcmp(reason, kOfxChangeUserEdited);
    Log("generic node: template changed (%s)", reason ? reason : "?");
    ApplyTemplateToControls(effect, userEdit);
    return kOfxStatOK;
  }
  return kOfxStatReplyDefault;
}

OfxStatus MainEntry(int index, const char* action, const void* handle, OfxPropertySetHandle inArgs,
                    OfxPropertySetHandle outArgs) {
  const bool generic = index == gGenericIndex;
  if (!generic && (index < 0 || index >= static_cast<int>(gTemplates.size()))) return kOfxStatFailed;
  const Template* t = generic ? nullptr : &gTemplates[index];
  auto effect = static_cast<OfxImageEffectHandle>(const_cast<void*>(handle));
  try {
    if (!strcmp(action, kOfxActionLoad)) return OnLoad();
    if (!strcmp(action, kOfxActionDescribe)) return Describe(t, effect);
    if (!strcmp(action, kOfxImageEffectActionDescribeInContext)) return DescribeInContext(t, effect, inArgs);
    if (!strcmp(action, kOfxImageEffectActionRender)) return Render(t, effect, inArgs);
    if (!strcmp(action, kOfxImageEffectActionGetClipPreferences)) return GetClipPreferences(outArgs);
    if (!strcmp(action, kOfxImageEffectActionGetRegionOfDefinition)) {
      OfxImageClipHandle src;
      if (ClipConnected(effect, kOfxImageEffectSimpleSourceClipName, &src)) return kOfxStatReplyDefault;
      return GetRegionOfDefinition(effect, outArgs);
    }
    if (generic && !strcmp(action, kOfxActionCreateInstance)) {
      ApplyTemplateToControls(effect, false);  // labels are not saved with the project
      return kOfxStatOK;
    }
    if (generic && !strcmp(action, kOfxActionInstanceChanged)) return InstanceChanged(effect, inArgs);
  } catch (const std::exception& e) {
    Log("action %s failed: %s", action, e.what());
    return kOfxStatFailed;
  }
  return kOfxStatReplyDefault;
}

template <int I>
OfxStatus MainEntryN(const char* action, const void* handle, OfxPropertySetHandle in, OfxPropertySetHandle out) {
  return MainEntry(I, action, handle, in, out);
}

template <int... I>
constexpr std::array<OfxPluginEntryPoint*, sizeof...(I)> MakeEntries(std::integer_sequence<int, I...>) {
  return {&MainEntryN<I>...};
}
constexpr auto kEntries = MakeEntries(std::make_integer_sequence<int, kMaxPlugins>{});

void ScanOnce() {
  if (gScanned) return;
  gScanned = true;
  gTemplates = ScanTemplates();
  if (gTemplates.size() > kMaxPlugins - 1) gTemplates.resize(kMaxPlugins - 1);
  gIdentifiers.clear();
  for (const auto& t : gTemplates) gIdentifiers.push_back(Identifier(t));
  gIdentifiers.push_back("org.ograf.flame.generic");
  gGenericIndex = static_cast<int>(gTemplates.size());
  gPluginCount = gGenericIndex + 1;
  for (int i = 0; i < gPluginCount; i++)
    gPlugins[i] = OfxPlugin{kOfxImageEffectPluginApi, 1, gIdentifiers[i].c_str(), 1, 0, SetHost, kEntries[i]};
  Log("OGraf Flame: %zu named template(s) + generic node", gTemplates.size());
}

}  // namespace

OGRAF_EXPORT int OfxGetNumberOfPlugins(void) {
  ScanOnce();
  return gPluginCount;
}

OGRAF_EXPORT OfxPlugin* OfxGetPlugin(int nth) {
  ScanOnce();
  return nth >= 0 && nth < gPluginCount ? &gPlugins[nth] : nullptr;
}
