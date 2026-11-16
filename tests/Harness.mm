// Stand-alone stand-in for Flame: a plain Cocoa app that loads the built .ofx bundle, lists its
// plugins and renders frames from a background thread (as an OFX render thread would).
//
//   ograf_harness <OGrafFlame.ofx.bundle> <template.ograf.zip> <outDir> [--main-thread]
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>

#include <string>
#include <thread>
#include <vector>

typedef int (*CountFn)(void);
typedef int (*TestFn)(const char*, const char*, double, const double*, int, const char*);

int main(int argc, char* argv[]) {
  @autoreleasepool {
    if (argc < 4) {
      fprintf(stderr, "usage: %s <bundle> <zip> <outDir> [--main-thread]\n", argv[0]);
      return 64;
    }
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];

    std::string bundle = argv[1];
    std::string binary = bundle + "/Contents/MacOS/OGrafFlame.ofx";
    void* lib = dlopen(binary.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!lib) {
      fprintf(stderr, "dlopen: %s\n", dlerror());
      return 1;
    }
    auto count = reinterpret_cast<CountFn>(dlsym(lib, "OfxGetNumberOfPlugins"));
    auto test = reinterpret_cast<TestFn>(dlsym(lib, "OgrafFlame_TestRender"));
    printf("OfxGetNumberOfPlugins() = %d\n", count ? count() : -1);

    std::string zip = argv[2], out = argv[3];
    bool onMain = argc > 4 && std::string(argv[4]) == "--main-thread";
    const char* data = "{\"name\":\"Priya Raman\",\"title\":\"Chief Technology Officer\",\"accent\":\"#ff3d7f\"}";
    // In 0-1200 ms, hold, Out 2200-3000 ms.
    std::vector<double> ts = {0, 240, 480, 720, 1000, 1200, 2000, 2400, 2700, 3000};

    auto run = [=]() { return test(zip.c_str(), data, 2200, ts.data(), static_cast<int>(ts.size()), out.c_str()); };
    if (onMain) {
      dispatch_async(dispatch_get_main_queue(), ^{
        int rc = run();
        printf("done rc=%d\n", rc);
        exit(rc);
      });
    } else {
      std::thread([=] {
        int rc = run();
        printf("done rc=%d\n", rc);
        fflush(stdout);
        dispatch_async(dispatch_get_main_queue(), ^{
          exit(rc);
        });
      }).detach();
    }
    [NSApp run];
  }
  return 0;
}
