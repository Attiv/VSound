#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v xcodegen >/dev/null 2>&1; then
  echo 'XcodeGen is required. Install it with: brew install xcodegen' >&2
  exit 1
fi
xcodegen generate --quiet
vsound_oauth_settings=()
if [[ -n "${VSOUND_GOOGLE_CLIENT_ID:-}" ]]; then
  vsound_oauth_settings+=("VSOUND_GOOGLE_CLIENT_ID=$VSOUND_GOOGLE_CLIENT_ID")
fi
if [[ -n "${VSOUND_DROPBOX_APP_KEY:-}" ]]; then
  vsound_oauth_settings+=("VSOUND_DROPBOX_APP_KEY=$VSOUND_DROPBOX_APP_KEY")
fi
xcodebuild -project VSound.xcodeproj -scheme VSound -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath .build/xcode -quiet "${vsound_oauth_settings[@]}" build
mkdir -p build
rsync -a --delete .build/xcode/Build/Products/Release/VSound.app/ build/VSound.app/
codesign --verify --deep --strict build/VSound.app
echo "Built: $(pwd)/build/VSound.app"
if [[ "${1:-}" == "--run" ]]; then
  open build/VSound.app
fi
