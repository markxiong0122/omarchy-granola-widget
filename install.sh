#!/usr/bin/env bash
# Install the Meeting Notes bar widget and its "Enhanced notes" recorder action.
#
# Run this from the repo root:
#
#   ./install.sh
#
# It is safe to run again: the plugin is symlinked, the bar entry is only added
# when missing, and the action is only appended when it is not already in the
# recorder's config.toml. It never edits your Hyprland keybindings.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
plugin_id="markxiong.meeting-notes"
plugins_dir="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"
plugin_link="$plugins_dir/$plugin_id"
recorder_config="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-meeting-recorder/config.toml"
notes_config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy-meeting-notes"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

command -v omarchy >/dev/null 2>&1 || die "omarchy not found; this is for Omarchy"
command -v omarchy-shell >/dev/null 2>&1 || die "omarchy-shell not found; start the Omarchy shell first"

[[ -f "$here/manifest.json" ]] || die "run this from the omarchy-meeting-notes folder"

say "==> Checking the plugin manifest"
omarchy plugin validate "$here" >/dev/null

say "==> Linking the plugin into $plugins_dir"
mkdir -p "$plugins_dir" "$HOME/Documents/Meetings" "$notes_config_dir"
chmod +x "$here/bin/enhanced-notes" \
  "$here/bin/meeting-notes-index" \
  "$here/bin/granola-index" \
  "$here/bin/granola-oauth" \
  "$here/bin/meeting-active" \
  "$here/bin/recorder-chip" \
  "$here/bin/start-recording" \
  "$here/bin/granola-linux" \
  "$here/bin/granola-engine"
ln -sfn "$here" "$plugin_link"

say "==> Making the recorder float as a chip"
hypr_windows="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/windows.lua"
if ! grep -q 'OmarchyMeetingRecorder' "$hypr_windows" 2>/dev/null; then
  mkdir -p "$(dirname "$hypr_windows")"
  cat >> "$hypr_windows" <<'LUA'

-- Meeting Notes: the recorder's compact strip is a floating chip, not a tile.
o.window({ class = "^com\\.jankeesvw\\.OmarchyMeetingRecorder$" }, { float = true })
o.window({ class = "^com\\.jankeesvw\\.OmarchyMeetingRecorder$" }, { center = true })
LUA
  say "    added the rule to $hypr_windows"
fi
hyprctl reload >/dev/null 2>&1 || true

say "==> Rescanning the shell"
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

say "==> Enabling the bar widget"
enabled="$(omarchy plugin list --json 2>/dev/null | python3 -c '
import json, sys
try:
    plugins = json.load(sys.stdin)
except Exception:
    print("no")
    raise SystemExit
print("yes" if any(p.get("id") == "markxiong.meeting-notes" and p.get("enabled") for p in plugins) else "no")
')"
if [[ "$enabled" == "yes" ]]; then
  say "    already enabled"
else
  omarchy plugin enable "$plugin_id" --section right
fi

say "==> Adding the \"Enhanced notes\" action"
python3 - "$recorder_config" "$here/bin/enhanced-notes" <<'PY'
import sys
from pathlib import Path

config = Path(sys.argv[1])
action = Path(sys.argv[2])
text = config.read_text(encoding="utf-8") if config.is_file() else ""
if 'name = "Enhanced notes"' in text:
    print("    already configured")
    raise SystemExit
config.parent.mkdir(parents=True, exist_ok=True)
block = (
    "\n# Granola-style notes for every meeting (markxiong.meeting-notes)\n"
    "[[action]]\n"
    'name = "Enhanced notes"\n'
    f'command = "{action}"\n'
    "auto = true\n"
)
with config.open("a", encoding="utf-8") as handle:
    handle.write(block)
print(f"    wrote {config}")
PY

if [[ ! -f "$notes_config_dir/granola.json" ]]; then
  cat > "$notes_config_dir/granola.json" <<'JSON'
{
  "apiKey": "",
  "apiUrl": "https://public-api.granola.ai"
}
JSON
fi
chmod 600 "$notes_config_dir/granola.json" 2>/dev/null || true

say ""
say "Meeting Notes is installed."

if ! command -v omarchy-meeting-recorder >/dev/null 2>&1; then
  say ""
  say "Meeting Recorder itself is not installed yet; the recorder controls stay disabled"
  say "until it is. Install it with:"
  say ""
  say "    omarchy pkg add omarchy-meeting-recorder-bin"
  say ""
  read -r -p "Run that now? [y/N] " reply || reply=""
  if [[ "$reply" =~ ^[Yy]$ ]]; then
    omarchy pkg add omarchy-meeting-recorder-bin
  else
    say "Skipped. Re-run ./install.sh after installing it to check everything."
  fi
fi

say ""
if command -v granola >/dev/null 2>&1; then
  say "Granola for Linux: installed"
else
  say "Granola for Linux is not installed. The plugin can build it from the"
  say "official DMG (about 400 MB of downloads, a few minutes):"
  say "    $here/bin/granola-linux --latest"
  say "Then sign in once and test that system audio reaches the transcript."
fi

say ""
say "Open the panel from the bar (note icon on the right) or with:"
say "    omarchy-shell shell toggle $plugin_id"
say ""
say "Optional keybinding: add this to ~/.config/hypr/bindings.lua"
say "    o.bind(\"SUPER + ALT + M\", \"Meeting notes\", \"omarchy-shell shell toggle $plugin_id\")"
say ""
say "Meetings live in ~/Documents/Meetings. Each one gets transcript.md, and the"
say "Enhanced notes action writes enhanced.md beside it when the transcript is done."
say ""
say "Meeting detection needs nothing: when another app opens the microphone,"
say "a small popup offers to start recording. No calendar account involved."
say ""
say "Granola (read-only): connect with"
say "  $here/bin/granola-oauth --connect"
say "That opens Granola's device page; the panel then shows your notes alongside"
say "local meetings. An API key in $notes_config_dir/granola.json is optional."
