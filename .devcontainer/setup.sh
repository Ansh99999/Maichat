#!/usr/bin/env bash
# Post-create setup for the MaiChat Codespace.
# The base image (ghcr.io/cirruslabs/flutter:stable) already ships Flutter,
# the Android SDK, and a JDK. This script layers on Claude Code and gets the
# project ready to build an APK.
set -euo pipefail

echo "==> Installing Claude Code CLI"
npm install -g @anthropic-ai/claude-code

echo "==> Disabling Flutter analytics"
flutter config --no-analytics >/dev/null 2>&1 || true

echo "==> Fetching Dart/Flutter package deps"
flutter pub get

echo "==> Accepting Android SDK licenses"
yes | flutter doctor --android-licenses >/dev/null 2>&1 || true

echo "==> Pre-caching Android build artifacts"
flutter precache --android || true

echo "==> flutter doctor"
flutter doctor -v || true

echo "==> Restoring Claude state from Google Drive"
if [ -n "${GDRIVE_TOKEN:-}" ]; then
  # New codespace, same memories: pull what the last session pushed. Conservative
  # by design -- newer files win, existing transcripts are never overwritten.
  bash "$(dirname "$0")/drive-sync.sh" pull || echo "    (pull failed; run drive-sync.sh doctor)"
else
  echo "    skipped: GDRIVE_TOKEN not set"
fi

echo
echo "Setup complete."
echo "  - Build a release APK:  flutter build apk --release"
echo "  - Start Claude Code:    claude"
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "  - NOTE: ANTHROPIC_API_KEY is not set. Add it as a Codespaces secret,"
  echo "          or run 'claude' and use /login for subscription auth."
fi
