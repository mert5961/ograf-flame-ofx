#include "Timing.h"
#include <cstdio>
using namespace ograf;
int fails = 0;
void expect(const char* what, double got, double want) {
  bool ok = got > want - 1e-6 && got < want + 1e-6;
  if (!ok) { fails++; printf("FAIL %s: got %.4f want %.4f\n", what, got, want); }
}
int main() {
  // 100-frame clip (last rel frame 99) at 25 fps, template In 1200 ms / Out 800 ms.
  TimingInput b{0, 99, 25, 30, 20, 1200, 800, true};
  auto at = [&](double f, double inF, double outF, bool out = true) { TimingInput t = b; t.relFrame = f; t.inFrames = inF; t.outFrames = outF; t.playOut = out; return MapTiming(t); };
  // Template timing (30/20) = identity mapping.
  for (double f : {0.0, 15.0, 30.0, 50.0, 79.0, 89.0, 99.0}) expect("identity", at(f, 30, 20).templateMs, f * 40);
  expect("identity stop", at(0, 30, 20).stopAtMs, 79 * 40);
  // Short In (15 frames): halfway through the In = template 600 ms; In ends at frame 15.
  expect("short in mid", at(7.5, 15, 20).templateMs, 600);
  expect("short in end", at(15, 15, 20).templateMs, 1200);
  expect("hold after short in", at(25, 15, 20).templateMs, 1200 + 10 * 40);
  // Long Out (40 frames): Out spans frames 59..99, template stop..stop+800.
  auto o = at(59, 30, 40);
  expect("long out start", o.templateMs, o.stopAtMs);
  expect("long out mid", at(79, 30, 40).templateMs, at(79, 30, 40).stopAtMs + 400);
  expect("long out end", at(99, 30, 40).templateMs, at(99, 30, 40).stopAtMs + 800);
  // Play Out off: hold to the end, no stop.
  expect("no out", at(99, 30, 20, false).templateMs, 1200 + 69 * 40);
  expect("no out stop", at(0, 30, 20, false).stopAtMs, -1);
  // Clip too short for both (20 frames): Out starts right after the In.
  TimingInput s = b; s.lastFrame = 19; s.relFrame = 19; s.inFrames = 15; s.outFrames = 20;
  expect("short clip end", MapTiming(s).templateMs, MapTiming(s).stopAtMs + 800);
  s.relFrame = 15; expect("short clip out start", MapTiming(s).templateMs, MapTiming(s).stopAtMs);
  // Before the In: invisible.
  if (at(-1, 30, 20).visible) { fails++; puts("FAIL before in visible"); }
  printf(fails ? "%d failures\n" : "all timing checks passed\n", fails);
  return fails != 0;
}
