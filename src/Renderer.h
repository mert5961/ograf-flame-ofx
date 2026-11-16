// Embedded Chromium (CEF) renderer for OGraf packages. Callable from any thread; all CEF work
// runs on the host application's main thread.
#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace ograf {

struct FrameRequest {
  std::string packageRoot;   // extracted package folder (contains the manifest)
  std::string mainPath;      // module path relative to packageRoot
  int width = 1920, height = 1080;
  std::string dataJson;      // initial data for load()
  std::string scheduleJson;  // setActionsSchedule() schedule array
  double timestampMs = 0;    // goToTime() timestamp
};

// Renders one frame. On success `bgra` holds width*height premultiplied BGRA pixels, top row
// first. Blocks the calling thread (or pumps CEF when called on the main thread).
bool RenderFrame(const FrameRequest& request, std::vector<uint8_t>& bgra, std::string& error);

}  // namespace ograf
