#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v xcodegen >/dev/null 2>&1; then
  echo 'XcodeGen is required. Install it with: brew install xcodegen' >&2
  exit 1
fi
xcodegen generate --quiet
xcodebuild -project VSound.xcodeproj -scheme VSound -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath .build/xcode -quiet build
mkdir -p build
rsync -a --delete .build/xcode/Build/Products/Release/VSound.app/ build/VSound.app/
codesign --verify --deep --strict build/VSound.app
echo "Built: $(pwd)/build/VSound.app"
if [[ "${1:-}" == "--run" ]]; then
  open build/VSound.app
fi
