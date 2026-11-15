#!/usr/bin/env bash
# Package the unsigned device build into an .ipa, ready for a sideloading tool
# (iloader / Sideloadly) to sign on the user's machine.
#
# Two variants are produced:
#   dsh-go-unsigned.ipa        everything as built, including ShareExtension
#   dsh-go-unsigned-noshare.ipa  without PlugIns/ShareExtension.appex
#
# The second one exists because a free Apple ID (Personal Team) cannot hold the
# extra App ID and provisioning profile an extension needs; signing an .appex
# with a Personal Team profile is what makes SideStore/Sideloadly fail with
# "The app extension is missing a valid provisioning profile."
#
# Usage: tooling/ios/package-ipa.sh [OUTPUT_DIR]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
APP="$ROOT/app/build/ios/iphoneos/Runner.app"
OUT="${1:-$ROOT/dist}"

if [ ! -d "$APP" ]; then
  printf 'No device build at %s. Run this first:\n  (cd app && bash ../tooling/ios/build.sh --release --no-codesign)\n' "$APP" >&2
  exit 1
fi

case "$(file -b "$APP/Runner" 2>/dev/null || true)" in
  *Mach-O*arm64*) ;;
  *) printf 'Refusing to package: %s/Runner is not an arm64 Mach-O (simulator build?).\n' "$APP" >&2
     exit 1 ;;
esac

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd -P)"

package() {
  local name="$1" strip="$2" work
  work="$(mktemp -d)"
  mkdir -p "$work/Payload"
  cp -R "$APP" "$work/Payload/Runner.app"
  if [ "$strip" = yes ]; then
    rm -rf "$work/Payload/Runner.app/PlugIns"
  fi
  rm -f "$OUT/$name"
  ( cd "$work" && zip -qry "$OUT/$name" Payload )
  rm -rf "$work"
  printf '%-32s %10s bytes  sha256=%s\n' "$name" \
    "$(wc -c <"$OUT/$name" | tr -d ' ')" \
    "$(shasum -a 256 "$OUT/$name" | cut -d' ' -f1)"
}

package dsh-go-unsigned.ipa no
package dsh-go-unsigned-noshare.ipa yes

# Remote-only build check, reported not enforced: tooling/ios/prepare-engine.sh is
# skipped on purpose, so the Node host framework should not be inside the app. If it
# ever shows up here, the build silently became a local-engine build (~90 MB bigger)
# and the ipa is no longer "remote host only".
printf '\nContent check (remote-only means no local engine)\n'
for item in Frameworks/DshNodeHost.framework PhoneSelfRunner Frameworks/App.framework; do
  if [ -e "$APP/$item" ]; then
    printf '  present: %s\n' "$item"
  else
    printf '  absent : %s\n' "$item"
  fi
done
printf '  Runner.app: %s MB\n' "$(du -sm "$APP" | cut -f1)"

printf '\nWrote to %s\n' "$OUT"
