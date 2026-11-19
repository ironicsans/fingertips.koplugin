#!/bin/zsh
# Launch the KOReader macOS emulator with the plugin, a Clara BW-shaped window
# (same 6" proportions, scaled down), and an isolated settings folder.
#   tools/run.sh          -> interactive: long-press with the mouse and drag
#   tools/run.sh demo     -> scripted run, screenshots into shots/
#                            (FT_DEMO_SCENARIO=main|top|split|arrange|rows2)
EMU="${0:A:h:h}"
ROOT="${EMU:h}"
APP="$EMU/app/KOReader.app"
PLUGINS="$APP/Contents/koreader/plugins"
ln -sfn "$ROOT/fingertip.koplugin" "$PLUGINS/fingertip.koplugin"
ln -sfn "$EMU/dev-plugins/fingertipdemo.koplugin" "$PLUGINS/fingertipdemo.koplugin"
export KO_HOME="${KO_HOME:-$EMU/home}"
export EMULATE_READER_W=758 EMULATE_READER_H=1024 EMULATE_READER_DPI=212
if [[ "$1" == "demo" ]]; then
  export FT_DEMO=1 FT_DEMO_SHOTS="${FT_DEMO_SHOTS:-$EMU/shots}"
  mkdir -p "$FT_DEMO_SHOTS"
  rm -f "$FT_DEMO_SHOTS"/*.png
fi
exec "$APP/Contents/MacOS/koreader" "$EMU/books/selection-test.epub"
