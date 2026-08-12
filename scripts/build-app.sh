#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
app_dir="${project_dir}/dist/FlowDictation.app"
signing_identity="${FLOW_DICTATION_SIGNING_IDENTITY:-Flow Dictation Local Signing v2}"
whisper_binary="${FLOW_DICTATION_WHISPER_BINARY:-$(command -v whisper-cli || true)}"

if [[ -z "${whisper_binary}" || ! -x "${whisper_binary}" ]]; then
  print -u2 "whisper-cli was not found. Install it with: brew install whisper-cpp"
  exit 1
fi

ggml_prefix="$(brew --prefix ggml 2>/dev/null || true)"
whisper_prefix="$(brew --prefix whisper-cpp 2>/dev/null || true)"
libomp_prefix="$(brew --prefix libomp 2>/dev/null || true)"
if [[ -z "${ggml_prefix}" || -z "${whisper_prefix}" || -z "${libomp_prefix}" ]]; then
  print -u2 "The portable runtime requires the Homebrew whisper-cpp, ggml, and libomp formulae."
  exit 1
fi

cd "${project_dir}"
swift build -c release

sign_args=(--force --sign "${signing_identity}")
if [[ "${signing_identity}" == Developer\ ID\ Application:* ]]; then
  sign_args+=(--options runtime --timestamp)
fi

rm -rf "${app_dir}"
mkdir -p "${app_dir}/Contents/MacOS" "${app_dir}/Contents/Resources/ggml-backends" "${app_dir}/Contents/Frameworks"
cp ".build/release/FlowDictation" "${app_dir}/Contents/MacOS/FlowDictation"
cp "Resources/Info.plist" "${app_dir}/Contents/Info.plist"

# Bundle the whisper.cpp command line runtime and every non-system library it needs.
cp -L "${whisper_binary}" "${app_dir}/Contents/Resources/whisper-cli"
cp -L "${whisper_prefix}/lib/libwhisper.1.dylib" "${app_dir}/Contents/Frameworks/libwhisper.1.dylib"
cp -L "${ggml_prefix}/lib/libggml.0.dylib" "${app_dir}/Contents/Frameworks/libggml.0.dylib"
cp -L "${ggml_prefix}/lib/libggml-base.0.dylib" "${app_dir}/Contents/Frameworks/libggml-base.0.dylib"
cp -L "${libomp_prefix}/lib/libomp.dylib" "${app_dir}/Contents/Frameworks/libomp.dylib"
cp -L "${ggml_prefix}/libexec/"*.so "${app_dir}/Contents/Resources/ggml-backends/"

frameworks="${app_dir}/Contents/Frameworks"
runtime="${app_dir}/Contents/Resources/whisper-cli"
backends="${app_dir}/Contents/Resources/ggml-backends"

# Replace Homebrew paths with app-relative rpaths so the bundle runs on a clean Mac.
for library in "${frameworks}"/*.dylib; do
  install_name_tool -id "@rpath/${library:t}" "${library}"
done

for target in "${runtime}" "${frameworks}"/*.dylib "${backends}"/*.so; do
  for library in "${frameworks}"/*.dylib; do
    install_name_tool -change "${whisper_prefix}/lib/${library:t}" "@rpath/${library:t}" "${target}" 2>/dev/null || true
    install_name_tool -change "${ggml_prefix}/lib/${library:t}" "@rpath/${library:t}" "${target}" 2>/dev/null || true
    install_name_tool -change "${libomp_prefix}/lib/${library:t}" "@rpath/${library:t}" "${target}" 2>/dev/null || true
    install_name_tool -change "/opt/homebrew/opt/whisper-cpp/lib/${library:t}" "@rpath/${library:t}" "${target}" 2>/dev/null || true
    install_name_tool -change "/opt/homebrew/opt/ggml/lib/${library:t}" "@rpath/${library:t}" "${target}" 2>/dev/null || true
    install_name_tool -change "/opt/homebrew/opt/libomp/lib/${library:t}" "@rpath/${library:t}" "${target}" 2>/dev/null || true
  done
done

install_name_tool -add_rpath "@executable_path/../Frameworks" "${runtime}" 2>/dev/null || true
for backend in "${backends}"/*.so; do
  install_name_tool -add_rpath "@loader_path/../../Frameworks" "${backend}" 2>/dev/null || true
done

# Sign nested binaries before sealing the outer app bundle.
for backend in "${backends}"/*.so; do
  codesign "${sign_args[@]}" "${backend}"
done
for library in "${frameworks}"/*.dylib; do
  codesign "${sign_args[@]}" "${library}"
done
codesign "${sign_args[@]}" "${runtime}"
codesign "${sign_args[@]}" "${app_dir}"
codesign --verify --deep --strict "${app_dir}"

print "Built portable app bundle: ${app_dir}"
