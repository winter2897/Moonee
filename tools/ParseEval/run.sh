#!/bin/sh
# Builds with xcodebuild (SwiftPM's CLI can't compile MLX's Metal shaders), puts the skill files where
# Bundle.main finds them (next to the binary), runs the eval.
set -e
cd "$(dirname "$0")"
xcodebuild build -scheme ParseEval -configuration Release -destination 'platform=macOS' -derivedDataPath .build/xcode -quiet
bin=.build/xcode/Build/Products/Release
ln -sf "$PWD"/../../Moonee/Resources/Locales/*/*.md "$bin"/
"$bin"/ParseEval "${1:-$PWD/.build/models}"
