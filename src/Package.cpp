#include "Package.h"

#include <dirent.h>
#include <fcntl.h>
#include <pthread.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <fstream>
#include <mutex>
#include <sstream>

#include "json.hpp"

extern char** environ;

namespace ograf {
namespace {

using nlohmann::json;

std::string Home() {
  const char* h = getenv("HOME");
  return h ? h : "/tmp";
}

bool EndsWith(const std::string& s, const std::string& suffix) {
  return s.size() >= suffix.size() && s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

// Runs a program without a shell and captures stdout.
bool Run(const std::vector<std::string>& argv, std::string* out) {
  int pipefd[2];
  if (pipe(pipefd) != 0) return false;
  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
  posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
  posix_spawn_file_actions_addclose(&actions, pipefd[0]);
  std::vector<char*> args;
  for (const auto& a : argv) args.push_back(const_cast<char*>(a.c_str()));
  args.push_back(nullptr);
  pid_t pid = 0;
  int rc = posix_spawn(&pid, args[0], &actions, nullptr, args.data(), environ);
  posix_spawn_file_actions_destroy(&actions);
  close(pipefd[1]);
  if (rc != 0) {
    close(pipefd[0]);
    return false;
  }
  std::string data;
  char buf[65536];
  ssize_t n;
  while ((n = read(pipefd[0], buf, sizeof buf)) > 0) data.append(buf, static_cast<size_t>(n));
  close(pipefd[0]);
  int status = 0;
  waitpid(pid, &status, 0);
  if (out) *out = std::move(data);
  return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

void Scan(const std::string& dir, int depth, std::vector<std::string>& found) {
  DIR* d = opendir(dir.c_str());
  if (!d) return;
  while (dirent* e = readdir(d)) {
    std::string name = e->d_name;
    if (name.empty() || name[0] == '.') continue;
    std::string path = dir + "/" + name;
    struct stat st {};
    if (stat(path.c_str(), &st) != 0) continue;
    if (S_ISDIR(st.st_mode)) {
      if (depth > 0) Scan(path, depth - 1, found);
    } else if (EndsWith(name, ".ograf.zip")) {
      found.push_back(path);
    }
  }
  closedir(d);
}

std::string ColorDefault(const json& v) {
  if (v.is_string()) {
    std::string s = v.get<std::string>();
    if (s.size() == 7 && s[0] == '#') return s;
    if (s.size() == 9 && s[0] == '#') return s.substr(0, 7);
  }
  return "#ffffff";
}

}  // namespace

void Log(const char* format, ...) {
  static std::mutex m;
  std::lock_guard<std::mutex> lock(m);
  std::string path = Home() + "/Library/Logs/OGrafFlame.log";
  FILE* f = fopen(path.c_str(), "a");
  if (!f) return;
  time_t now = time(nullptr);
  char stamp[32];
  strftime(stamp, sizeof stamp, "%Y-%m-%d %H:%M:%S", localtime(&now));
  fprintf(f, "%s [%s] ", stamp, pthread_main_np() ? "main" : "thread");
  va_list args;
  va_start(args, format);
  vfprintf(f, format, args);
  va_end(args);
  fputc('\n', f);
  fclose(f);
}

std::vector<std::string> TemplateDirs() {
  std::vector<std::string> dirs;
  if (const char* env = getenv("OGRAF_TEMPLATES")) {
    std::stringstream ss(env);
    std::string item;
    while (std::getline(ss, item, ':'))
      if (!item.empty()) dirs.push_back(item);
  }
  std::ifstream cfg(Home() + "/Library/Application Support/OGraf Flame/config.json");
  if (cfg) {
    json j = json::parse(cfg, nullptr, false);
    if (j.is_object() && j.contains("templateDirs") && j["templateDirs"].is_array())
      for (const auto& d : j["templateDirs"])
        if (d.is_string()) dirs.push_back(d.get<std::string>());
  }
  if (dirs.empty()) {
    dirs.push_back(Home() + "/ograf-studio/out");                  // OGraf Studio source checkout
    dirs.push_back(Home() + "/Documents/OGraf Studio/Projects");   // standalone OGraf Studio app
  }
  for (auto& d : dirs)
    if (d.rfind("~/", 0) == 0) d = Home() + d.substr(1);
  return dirs;
}

bool ReadTemplate(const std::string& zipPath, Template& t, std::string& error) {
  std::string listing;
  if (!Run({"/usr/bin/unzip", "-Z1", zipPath}, &listing)) {
    error = "not a readable zip";
    return false;
  }
  std::stringstream ss(listing);
  std::string line, entry;
  while (std::getline(ss, line)) {
    if (EndsWith(line, ".ograf.json") && (entry.empty() || line.size() < entry.size())) entry = line;
  }
  if (entry.empty()) {
    error = "no *.ograf.json manifest";
    return false;
  }
  std::string text;
  if (!Run({"/usr/bin/unzip", "-p", zipPath, entry}, &text)) {
    error = "cannot read manifest";
    return false;
  }
  json m = json::parse(text, nullptr, false);
  if (!m.is_object()) {
    error = "manifest is not valid JSON";
    return false;
  }
  t = Template{};
  t.zipPath = zipPath;
  t.manifestEntry = entry;
  t.id = m.value("id", std::string());
  t.name = m.value("name", std::string("OGraf graphic"));
  t.mainPath = m.value("main", std::string("main.js"));
  t.supportsNonRealTime = m.value("supportsNonRealTime", false);
  while (t.mainPath.rfind("./", 0) == 0) t.mainPath = t.mainPath.substr(2);

  if (m.contains("renderRequirements") && m["renderRequirements"].is_array() &&
      !m["renderRequirements"].empty()) {
    const json& r = m["renderRequirements"][0];
    auto exact = [](const json& v, double fallback) {
      if (v.is_object()) {
        for (const char* k : {"exact", "ideal", "max"})
          if (v.contains(k) && v[k].is_number()) return v[k].get<double>();
      }
      return fallback;
    };
    if (r.contains("resolution")) {
      t.width = static_cast<int>(exact(r["resolution"].value("width", json()), t.width));
      t.height = static_cast<int>(exact(r["resolution"].value("height", json()), t.height));
    }
    if (r.contains("frameRate")) t.frameRate = exact(r["frameRate"], t.frameRate);
  }

  if (m.contains("actionDurations") && m["actionDurations"].is_array()) {
    for (const auto& a : m["actionDurations"]) {
      std::string type = a.value("type", std::string());
      double d = a.value("duration", 0.0);
      if (type == "playAction") {
        double steps = 0;
        if (a.contains("steps") && a["steps"].is_array())
          for (const auto& s : a["steps"]) steps += s.value("duration", 0.0);
        t.playMs = std::max(d, steps);
      } else if (type == "stopAction") {
        t.stopMs = d;
      }
    }
  }

  if (m.contains("schema") && m["schema"].contains("properties") &&
      m["schema"]["properties"].is_object()) {
    for (const auto& [key, p] : m["schema"]["properties"].items()) {
      Field f;
      f.key = key;
      f.label = p.value("title", key);
      std::string type = p.value("type", std::string("string"));
      std::string gdd = p.value("gddType", std::string());
      const json def = p.value("default", json());
      if (gdd.rfind("color", 0) == 0) {
        f.kind = FieldKind::Color;
        f.defText = ColorDefault(def);
      } else if (type == "string") {
        f.kind = FieldKind::Text;
        f.defText = def.is_string() ? def.get<std::string>() : "";
      } else if (type == "number") {
        f.kind = FieldKind::Number;
        f.defNumber = def.is_number() ? def.get<double>() : 0;
      } else if (type == "integer") {
        f.kind = FieldKind::Integer;
        f.defNumber = def.is_number() ? def.get<double>() : 0;
      } else if (type == "boolean") {
        f.kind = FieldKind::Boolean;
        f.defNumber = def.is_boolean() && def.get<bool>() ? 1 : 0;
      } else {
        continue;  // objects/arrays are not exposed in this version
      }
      t.fields.push_back(f);
    }
  }
  return true;
}

std::vector<Template> ScanTemplates() {
  std::vector<std::string> zips;
  for (const auto& d : TemplateDirs()) Scan(d, 3, zips);
  std::vector<Template> out;
  for (const auto& z : zips) {
    Template t;
    std::string error;
    if (!ReadTemplate(z, t, error)) {
      Log("skip %s: %s", z.c_str(), error.c_str());
      continue;
    }
    if (!t.supportsNonRealTime) {
      Log("skip %s: real-time only package", z.c_str());
      continue;
    }
    Log("template \"%s\" (%dx%d @ %.3g fps, %zu fields) from %s", t.name.c_str(), t.width, t.height,
        t.frameRate, t.fields.size(), z.c_str());
    out.push_back(std::move(t));
  }
  return out;
}

bool ExtractTemplate(const Template& t, std::string& packageRoot, std::string& error) {
  struct stat st {};
  if (stat(t.zipPath.c_str(), &st) != 0) {
    error = "template file is missing: " + t.zipPath;
    return false;
  }
  std::string base = t.zipPath.substr(t.zipPath.find_last_of('/') + 1);
  for (char& c : base)
    if (!isalnum(static_cast<unsigned char>(c)) && c != '-' && c != '_' && c != '.') c = '_';
  std::string cache = Home() + "/Library/Caches/OGrafFlame/packages";
  std::string dir = cache + "/" + base + "-" + std::to_string(static_cast<long long>(st.st_size)) +
                    "-" + std::to_string(static_cast<long long>(st.st_mtimespec.tv_sec));
  std::string marker = dir + "/.extracted";
  if (access(marker.c_str(), F_OK) != 0) {
    Run({"/bin/mkdir", "-p", dir}, nullptr);
    if (!Run({"/usr/bin/unzip", "-o", "-q", t.zipPath, "-d", dir}, nullptr)) {
      error = "could not extract " + t.zipPath;
      return false;
    }
    std::ofstream(marker) << "ok";
  }
  auto slash = t.manifestEntry.find_last_of('/');
  packageRoot = slash == std::string::npos ? dir : dir + "/" + t.manifestEntry.substr(0, slash);
  return true;
}

}  // namespace ograf
