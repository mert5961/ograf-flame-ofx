// OGraf package discovery and manifest reading for the Flame OFX plugin.
#pragma once
#include <string>
#include <vector>

namespace ograf {

enum class FieldKind { Text, Color, Number, Integer, Boolean };

struct Field {
  std::string key;       // manifest schema property key
  std::string label;     // operator label ("Name", "Accent colour")
  FieldKind kind = FieldKind::Text;
  std::string defText;   // Text default, or "#rrggbb" for Color
  double defNumber = 0;  // Number / Integer / Boolean default
};

struct Template {
  std::string zipPath;
  std::string manifestEntry;  // path of *.ograf.json inside the zip
  std::string id;             // manifest id
  std::string name;           // manifest name (shown in Flame)
  std::string mainPath;       // manifest "main", relative to the package root
  int width = 1920, height = 1080;
  double frameRate = 25;
  double playMs = 0, stopMs = 0;
  bool supportsNonRealTime = false;
  std::vector<Field> fields;
};

// Template folders: $OGRAF_TEMPLATES (colon separated), the "templateDirs" array in
// ~/Library/Application Support/OGraf Flame/config.json, else ~/ograf-studio/out and
// ~/Documents/OGraf Studio/Projects.
std::vector<std::string> TemplateDirs();

// Finds every *.ograf.zip (up to 3 folders deep) and reads its manifest.
std::vector<Template> ScanTemplates();

// Reads one package's manifest. Returns false with a message on failure.
bool ReadTemplate(const std::string& zipPath, Template& out, std::string& error);

// Extracts the package (once per zip size+mtime) under ~/Library/Caches/OGrafFlame and
// returns the folder that contains the manifest.
bool ExtractTemplate(const Template& t, std::string& packageRoot, std::string& error);

void Log(const char* format, ...) __attribute__((format(printf, 1, 2)));

}  // namespace ograf
