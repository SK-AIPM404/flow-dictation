#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 ]]; then
  print -u2 "Usage: $0 /absolute/path/to/FlowDictation-<version>-<architecture>.dmg"
  exit 64
fi

dmg_path="${1:A}"
profile="${FLOW_DICTATION_NOTARY_PROFILE:-FlowDictationNotary}"

if [[ ! -f "${dmg_path}" ]]; then
  print -u2 "DMG not found: ${dmg_path}"
  exit 66
fi

xcrun notarytool submit "${dmg_path}" --keychain-profile "${profile}" --wait
xcrun stapler staple "${dmg_path}"
spctl -a -vv -t open "${dmg_path}"
print "Notarized and stapled: ${dmg_path}"
