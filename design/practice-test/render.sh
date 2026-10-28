#!/bin/zsh
# Renders every frame in src/ to renders/<name>.png at 3x: 1320x2868, the App Store 6.9" size.
# Needs Google Chrome and macOS (the quote serif is the system New York font file).
set -euo pipefail
cd "${0:A:h}"

chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
mkdir -p renders

for page in src/*.html; do
  name=${page:t:r}
  "$chrome" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files \
    --force-device-scale-factor=3 --window-size=440,956 --virtual-time-budget=3000 \
    --screenshot="$PWD/renders/$name.png" "file://$PWD/$page" >/dev/null 2>&1
  echo "renders/$name.png"
done
