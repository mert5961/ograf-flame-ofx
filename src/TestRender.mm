// Exported test hook: renders frames of a package through the same code path the OFX render
// action uses, writing PNGs. Used by the stand-alone harness; Flame never calls it.
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <string>

#include "Package.h"
#include "Renderer.h"

#define OGRAF_EXPORT extern "C" __attribute__((visibility("default")))

static bool WritePng(const std::vector<uint8_t>& bgra, int w, int h, const std::string& path) {
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGDataProviderRef provider = CGDataProviderCreateWithData(nullptr, bgra.data(), bgra.size(), nullptr);
  CGImageRef image = CGImageCreate(w, h, 8, 32, static_cast<size_t>(w) * 4, cs,
                                   (CGBitmapInfo)kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaPremultipliedFirst,
                                   provider, nullptr, false, kCGRenderingIntentDefault);
  NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
  CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
      (__bridge CFURLRef)url, (__bridge CFStringRef)UTTypePNG.identifier, 1, nullptr);
  bool ok = false;
  if (dest) {
    CGImageDestinationAddImage(dest, image, nullptr);
    ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
  }
  CGImageRelease(image);
  CGDataProviderRelease(provider);
  CGColorSpaceRelease(cs);
  return ok;
}

// schedule: play at 0, stop at stopAtMs (< 0 = no stop). Returns 0 on success.
OGRAF_EXPORT int OgrafFlame_TestRender(const char* zipPath, const char* dataJson, double stopAtMs,
                                       const double* timestampsMs, int count, const char* outDir) {
  using namespace ograf;
  Template t;
  std::string error, root;
  if (!ReadTemplate(zipPath, t, error) || !ExtractTemplate(t, root, error)) {
    fprintf(stderr, "template: %s\n", error.c_str());
    return 2;
  }
  std::string data = dataJson && *dataJson ? dataJson : "{}";
  std::string schedule =
      "[{\"timestamp\":0,\"action\":{\"type\":\"updateAction\",\"params\":{\"data\":" + data +
      "}}},{\"timestamp\":0,\"action\":{\"type\":\"playAction\",\"params\":{}}}";
  if (stopAtMs >= 0)
    schedule += ",{\"timestamp\":" + std::to_string(stopAtMs) +
                ",\"action\":{\"type\":\"stopAction\",\"params\":{}}}";
  schedule += "]";
  for (int i = 0; i < count; i++) {
    FrameRequest req{root, t.mainPath, t.width, t.height, data, schedule, timestampsMs[i]};
    std::vector<uint8_t> px;
    NSDate* start = [NSDate date];
    if (!RenderFrame(req, px, error)) {
      fprintf(stderr, "frame %.1f ms: %s\n", timestampsMs[i], error.c_str());
      return 3;
    }
    char name[64];
    snprintf(name, sizeof name, "/frame_%07.1f.png", timestampsMs[i]);
    WritePng(px, t.width, t.height, std::string(outDir) + name);
    printf("rendered %.1f ms in %.0f ms\n", timestampsMs[i], -[start timeIntervalSinceNow] * 1000);
    fflush(stdout);
  }
  return 0;
}
