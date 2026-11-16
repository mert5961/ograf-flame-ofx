#!/bin/bash
# Downloads the build dependencies into third_party/ (not committed) and builds CEF's C++ wrapper.
#   CEF (Chromium Embedded Framework) minimal distribution, macOS arm64 — checksum verified
#   OpenFX SDK headers (OFX_Release_1.5)
#   nlohmann/json single header (v3.11.3)
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TP="$HERE/third_party"
CEF_NAME="cef_binary_156.0.30+g6028375+chromium-156.0.8078.96_macosarm64_minimal"
CEF_SHA1="6393d8a838d3b29f6b6939b970b5931dde2082aa"
mkdir -p "$TP"

if [[ ! -f "$TP/cef/build/libcef_dll_wrapper/libcef_dll_wrapper.a" ]]; then
  mkdir -p "$TP/dl"
  if [[ ! -f "$TP/dl/cef.tar.bz2" ]] || ! echo "$CEF_SHA1  $TP/dl/cef.tar.bz2" | shasum -c - >/dev/null 2>&1; then
    echo "downloading CEF (~135 MB)..."
    curl --fail -L -o "$TP/dl/cef.tar.bz2" \
      "https://cef-builds.spotifycdn.com/$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$CEF_NAME.tar.bz2")"
    echo "$CEF_SHA1  $TP/dl/cef.tar.bz2" | shasum -c -
  fi
  rm -rf "$TP/cef" && mkdir -p "$TP/cef"
  tar -xjf "$TP/dl/cef.tar.bz2" -C "$TP/cef" --strip-components 1
  echo "building libcef_dll_wrapper..."
  cmake -S "$TP/cef" -B "$TP/cef/build" -G "Unix Makefiles" -DPROJECT_ARCH=arm64 -DCMAKE_BUILD_TYPE=Release >/dev/null
  cmake --build "$TP/cef/build" --target libcef_dll_wrapper -j "$(sysctl -n hw.ncpu)" >/dev/null
fi

if [[ ! -f "$TP/openfx/include/ofxImageEffect.h" ]]; then
  rm -rf "$TP/openfx"
  git -c advice.detachedHead=false clone -q --depth 1 --branch OFX_Release_1.5 \
    https://github.com/AcademySoftwareFoundation/openfx.git "$TP/openfx"
fi

if [[ ! -f "$TP/json/json.hpp" ]]; then
  mkdir -p "$TP/json"
  curl --fail -sL -o "$TP/json/json.hpp" https://github.com/nlohmann/json/releases/download/v3.11.3/json.hpp
fi
echo "dependencies ready in $TP"
