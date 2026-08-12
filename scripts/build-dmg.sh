#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
app_dir="${project_dir}/dist/FlowDictation.app"
staging_dir="${project_dir}/dist/dmg-staging"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${project_dir}/Resources/Info.plist")"
architecture="$(uname -m)"
dmg_path="${project_dir}/dist/FlowDictation-${version}-${architecture}.dmg"

"${script_dir}/build-app.sh"

rm -rf "${staging_dir}" "${dmg_path}"
mkdir -p "${staging_dir}"
cp -R "${app_dir}" "${staging_dir}/Flow Dictation.app"
ln -s /Applications "${staging_dir}/Applications"
cp "${project_dir}/README.md" "${staging_dir}/README.md"
cp "${project_dir}/LICENSE" "${staging_dir}/LICENSE"
cp "${project_dir}/THIRD_PARTY_NOTICES.md" "${staging_dir}/THIRD_PARTY_NOTICES.md"

hdiutil create -volname "Flow Dictation" -srcfolder "${staging_dir}" -ov -format UDZO "${dmg_path}"
shasum -a 256 "${dmg_path}" > "${dmg_path}.sha256"
print "Built DMG: ${dmg_path}"
