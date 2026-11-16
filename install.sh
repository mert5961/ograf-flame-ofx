#!/bin/bash
# Installs (or removes, with --uninstall) the OGraf OFX plugin for Flame. Needs sudo.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="/Library/OFX/Plugins/OGrafFlame.ofx.bundle"

# Runs a command as root: sudo in a terminal, otherwise the macOS administrator dialog.
as_root() {
  if [[ -t 0 ]]; then
    sudo /bin/bash -c "$1"
  else
    osascript -e "do shell script \"$1\" with prompt \"OGraf plugin for Flame\" with administrator privileges" >/dev/null
  fi
}

if [[ "${1:-}" == "--uninstall" ]]; then
  as_root "rm -rf '$DEST'"
  echo "removed $DEST"
  exit 0
fi

SRC="$HERE/build/OGrafFlame.ofx.bundle"
[[ -d "$SRC" ]] || { echo "build it first: $HERE/build.sh"; exit 1; }
if pgrep -xq flame; then
  echo "Flame is running. Quit Flame first, then run this again."
  exit 1
fi
# Shared Chromium profile used by builds before 0.2 (now one folder per process).
rm -rf "$HOME/Library/Caches/OGrafFlame/chromium"
as_root "rm -rf '$DEST' && cp -R '$SRC' '$DEST' && chown -R root:wheel '$DEST'"
echo "installed $DEST"
echo "Templates are read from: \$OGRAF_TEMPLATES, ~/Library/Application Support/OGraf Flame/config.json"
echo "('templateDirs'), else ~/ograf-studio/out and ~/Documents/OGraf Studio/Projects. Restart Flame for new templates."
echo "Logs: ~/Library/Logs/OGrafFlame.log and OGrafFlame-chromium.log"
