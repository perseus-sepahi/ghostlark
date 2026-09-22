#!/bin/sh
# Downloads the two prebuilt core binaries that are not stored in git.
# sing-box (macOS) comes from the official sing-box release; libbox.aar (Android) from the Ghostlark release.
set -e
cd "$(dirname "$0")/.."
VER=1.14.0
REPO="${GHOSTLARK_REPO:-perseus-sepahi/ghostlark}"
mkdir -p Ghostlark/Resources/bin Android_Version/app/libs
if [ ! -x Ghostlark/Resources/bin/sing-box ]; then
  echo "fetching sing-box $VER for macOS arm64"
  curl -L "https://github.com/SagerNet/sing-box/releases/download/v$VER/sing-box-$VER-darwin-arm64.tar.gz" | tar xz -C /tmp
  cp "/tmp/sing-box-$VER-darwin-arm64/sing-box" Ghostlark/Resources/bin/sing-box && chmod +x Ghostlark/Resources/bin/sing-box
fi
if [ ! -f Android_Version/app/libs/libbox.aar ]; then
  echo "fetching libbox.aar from the latest Ghostlark release"
  curl -L "https://github.com/$REPO/releases/latest/download/libbox.aar" -o Android_Version/app/libs/libbox.aar
fi
echo done
