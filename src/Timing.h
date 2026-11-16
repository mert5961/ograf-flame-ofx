// Maps a frame of the Flame clip onto the OGraf template's own timeline, letting the artist
// choose how long the In and Out take. The hold between them runs in real time.
#pragma once
#include <algorithm>

namespace ograf {

struct TimingInput {
  double relFrame;     // clip frame relative to the In start (time - rangeStart - offset)
  double lastFrame;    // relative index of the clip's last frame
  double fps;          // clip frame rate
  double inFrames;     // desired In length, in clip frames
  double outFrames;    // desired Out length, in clip frames
  double playMs;       // template's own In length
  double stopMs;       // template's own Out length
  bool playOut;        // false: hold to the end of the clip
};

struct TimingResult {
  bool visible;        // false before the In starts
  double templateMs;   // timestamp to pass to goToTime()
  double stopAtMs;     // stopAction timestamp for the schedule (< 0: no stop)
};

inline TimingResult MapTiming(const TimingInput& in) {
  TimingResult r{in.relFrame >= 0, 0, -1};
  const double inF = std::max(1.0, in.inFrames);
  const double outF = std::max(1.0, in.outFrames);
  const double msPerFrame = 1000.0 / (in.fps > 0 ? in.fps : 25);
  // The Out ends on the last frame; it never starts before the In has finished.
  const double outStart = std::max(inF, in.lastFrame - outF);
  const bool hasOut = in.playOut && in.stopMs > 0;
  if (hasOut) r.stopAtMs = in.playMs + (outStart - inF) * msPerFrame;
  const double f = in.relFrame;
  if (!r.visible) return r;
  if (f < inF) {
    r.templateMs = f / inF * in.playMs;
  } else if (!hasOut || f < outStart) {
    r.templateMs = in.playMs + (f - inF) * msPerFrame;
  } else {
    double u = std::min(1.0, (f - outStart) / std::max(1e-9, in.lastFrame - outStart));
    r.templateMs = r.stopAtMs + u * in.stopMs;
  }
  return r;
}

}  // namespace ograf
