#!/usr/bin/env bash
#
# Builds llama.xcframework (libllama + libmtmd, Metal, Accelerate) for SynapLink.
#
# Based on llama.cpp's upstream build-xcframework.sh, with SynapLink-specific changes:
#   - Slices: iOS device (arm64), iOS simulator (arm64 + x86_64), macOS
#     (arm64 + x86_64). No visionOS/tvOS. The x86_64 slices matter: the dev
#     Mac is Intel, so the simulator and the desktop test harness run x86_64.
#   - libmtmd (multimodal: vision + audio projectors, incl. Gemma 4) is compiled in
#     and its headers (mtmd.h, mtmd-helper.h) ship in the framework umbrella.
#   - MTMD_VIDEO=OFF: video support shells out to an ffmpeg binary — not a thing on iOS.
#   - Build dirs live under build/llama-* in the repo root, NOT inside the submodule,
#     so third_party/llama.cpp stays pristine at its pinned tag.
#
# Usage: scripts/build-llama-xcframework.sh
# Output: Frameworks/llama.xcframework

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LLAMA_SRC="${REPO_ROOT}/third_party/llama.cpp"
BUILD_ROOT="${REPO_ROOT}/build"
OUT_DIR="${REPO_ROOT}/Frameworks"

# llama.cpp lives in a git submodule; the gitlink is the authoritative pin.
# LLAMA_TAG/LLAMA_COMMIT are the human-readable mirror of that pin — the
# check below fails the build if they drift from the actual checkout. The
# comparison uses the commit SHA, not the tag: shallow submodule clones
# (CI, .gitmodules shallow=true) don't fetch tag objects. Bump all three
# together; verify Gemma 4 mtmd support is still present after any upgrade.
LLAMA_TAG="b9596"
LLAMA_COMMIT="18ef86ecec723361362a332a79b4d913fd724d40"

if [[ ! -f "${LLAMA_SRC}/CMakeLists.txt" ]]; then
    echo "== Initialising llama.cpp submodule =="
    git -C "${REPO_ROOT}" submodule update --init --depth 1 third_party/llama.cpp
fi

CHECKED_OUT="$(git -C "${LLAMA_SRC}" rev-parse HEAD 2>/dev/null || true)"
if [[ "${CHECKED_OUT}" != "${LLAMA_COMMIT}" ]]; then
    echo "error: third_party/llama.cpp is at '${CHECKED_OUT:-unknown}', expected ${LLAMA_COMMIT} (${LLAMA_TAG})" >&2
    echo "       if you bumped the submodule, update LLAMA_TAG/LLAMA_COMMIT in this script;" >&2
    echo "       otherwise run: git submodule update --init third_party/llama.cpp" >&2
    exit 1
fi

IOS_MIN_OS_VERSION=16.4
MACOS_MIN_OS_VERSION=13.3

COMMON_C_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument -g"
COMMON_CXX_FLAGS="${COMMON_C_FLAGS}"

COMMON_CMAKE_ARGS=(
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY=""
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
    -DCMAKE_XCODE_ATTRIBUTE_DEBUG_INFORMATION_FORMAT="dwarf-with-dsym"
    -DCMAKE_XCODE_ATTRIBUTE_GCC_GENERATE_DEBUGGING_SYMBOLS=YES
    -DCMAKE_XCODE_ATTRIBUTE_COPY_PHASE_STRIP=NO
    -DCMAKE_XCODE_ATTRIBUTE_STRIP_INSTALLED_PRODUCT=NO
    -DCMAKE_XCODE_ATTRIBUTE_DEVELOPMENT_TEAM=ggml
    -DBUILD_SHARED_LIBS=OFF
    -DLLAMA_BUILD_COMMON=ON
    -DLLAMA_BUILD_TOOLS=ON
    -DLLAMA_BUILD_EXAMPLES=OFF
    -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_SERVER=OFF
    -DLLAMA_OPENSSL=OFF
    -DLLAMA_CURL=OFF
    -DMTMD_VIDEO=OFF
    -DGGML_METAL=ON
    -DGGML_METAL_EMBED_LIBRARY=ON
    -DGGML_METAL_USE_BF16=ON
    -DGGML_BLAS_DEFAULT=ON
    -DGGML_NATIVE=OFF
    -DGGML_OPENMP=OFF
    -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}"
    -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}"
)

FRAMEWORK_HEADERS=(
    "${LLAMA_SRC}/include/llama.h"
    "${LLAMA_SRC}/ggml/include/ggml.h"
    "${LLAMA_SRC}/ggml/include/ggml-opt.h"
    "${LLAMA_SRC}/ggml/include/ggml-alloc.h"
    "${LLAMA_SRC}/ggml/include/ggml-backend.h"
    "${LLAMA_SRC}/ggml/include/ggml-metal.h"
    "${LLAMA_SRC}/ggml/include/ggml-cpu.h"
    "${LLAMA_SRC}/ggml/include/ggml-blas.h"
    "${LLAMA_SRC}/ggml/include/gguf.h"
    "${LLAMA_SRC}/tools/mtmd/mtmd.h"
    "${LLAMA_SRC}/tools/mtmd/mtmd-helper.h"
)

configure_and_build() {
    local build_dir=$1; shift
    cmake -B "${build_dir}" -G Xcode "${COMMON_CMAKE_ARGS[@]}" "$@" -S "${LLAMA_SRC}"
    # Building only the mtmd target pulls in llama/ggml/metal/blas as dependencies
    # and skips the CLI executables.
    cmake --build "${build_dir}" --config Release --target mtmd -j "$(sysctl -n hw.logicalcpu)" -- -quiet
}

# $1 build_dir, $2 release_subdir, $3 platform (ios|macos), $4 sdk, $5 min_version_flag, $6 archs ("arm64" or "arm64 x86_64")
make_framework() {
    local build_dir=$1
    local release_dir=$2
    local platform=$3
    local sdk=$4
    local min_version_flag=$5
    local archs=$6

    local fw="${build_dir}/framework/llama.framework"
    local header_path module_path plist_path install_name

    if [[ "$platform" == "macos" ]]; then
        mkdir -p "${fw}/Versions/A/Headers" "${fw}/Versions/A/Modules" "${fw}/Versions/A/Resources"
        ln -sfh A "${fw}/Versions/Current"
        ln -sfh Versions/Current/Headers "${fw}/Headers"
        ln -sfh Versions/Current/Modules "${fw}/Modules"
        ln -sfh Versions/Current/Resources "${fw}/Resources"
        ln -sfh Versions/Current/llama "${fw}/llama"
        header_path="${fw}/Versions/A/Headers"
        module_path="${fw}/Versions/A/Modules"
        plist_path="${fw}/Versions/A/Resources/Info.plist"
        install_name="@rpath/llama.framework/Versions/Current/llama"
        local output_lib="${fw}/Versions/A/llama"
        local supported_platform="MacOSX" platform_name="macosx" min_os="${MACOS_MIN_OS_VERSION}"
        local device_family=""
    else
        mkdir -p "${fw}/Headers" "${fw}/Modules"
        header_path="${fw}/Headers"
        module_path="${fw}/Modules"
        plist_path="${fw}/Info.plist"
        install_name="@rpath/llama.framework/llama"
        local output_lib="${fw}/llama"
        local supported_platform="iPhoneOS" platform_name="iphoneos" min_os="${IOS_MIN_OS_VERSION}"
        local device_family='
    <key>UIDeviceFamily</key>
    <array>
        <integer>1</integer>
        <integer>2</integer>
    </array>'
        if [[ "$sdk" == "iphonesimulator" ]]; then
            supported_platform="iPhoneSimulator"
            platform_name="iphonesimulator"
        fi
    fi

    cp "${FRAMEWORK_HEADERS[@]}" "${header_path}/"

    cat > "${module_path}/module.modulemap" << 'EOF'
framework module llama {
    umbrella "Headers"

    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "Foundation"

    export *
}
EOF

    cat > "${plist_path}" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>llama</string>
    <key>CFBundleIdentifier</key>
    <string>org.ggml.llama</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>llama</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>${min_os}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>${supported_platform}</string>
    </array>${device_family}
    <key>DTPlatformName</key>
    <string>${platform_name}</string>
</dict>
</plist>
EOF

    local libs=(
        "${build_dir}/src/${release_dir}/libllama.a"
        "${build_dir}/ggml/src/${release_dir}/libggml.a"
        "${build_dir}/ggml/src/${release_dir}/libggml-base.a"
        "${build_dir}/ggml/src/${release_dir}/libggml-cpu.a"
        "${build_dir}/ggml/src/ggml-metal/${release_dir}/libggml-metal.a"
        "${build_dir}/ggml/src/ggml-blas/${release_dir}/libggml-blas.a"
        "${build_dir}/tools/mtmd/${release_dir}/libmtmd.a"
    )

    local temp_dir="${build_dir}/temp"
    mkdir -p "${temp_dir}"
    # libtool sees object files for archs other than the target when combining
    # universal members; those warnings are expected noise.
    xcrun libtool -static -o "${temp_dir}/combined.a" "${libs[@]}" 2> /dev/null

    local arch_flags=""
    for arch in ${archs}; do
        arch_flags+=" -arch ${arch}"
    done

    echo "Creating dynamic library for ${sdk} (${archs})..."
    xcrun -sdk "$sdk" clang++ -dynamiclib \
        -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
        ${arch_flags} \
        ${min_version_flag} \
        -Wl,-force_load,"${temp_dir}/combined.a" \
        -framework Foundation -framework Metal -framework Accelerate \
        -install_name "${install_name}" \
        -o "${output_lib}"

    if [[ "$sdk" == "iphoneos" ]]; then
        xcrun vtool -set-build-version ios ${IOS_MIN_OS_VERSION} ${IOS_MIN_OS_VERSION} -replace \
            -output "${output_lib}" "${output_lib}"
    fi

    mkdir -p "${build_dir}/dSYMs"
    xcrun dsymutil "${output_lib}" -o "${build_dir}/dSYMs/llama.dSYM"
    xcrun strip -S "${output_lib}" -o "${temp_dir}/stripped"
    mv "${temp_dir}/stripped" "${output_lib}"
    rm -rf "${output_lib}.dSYM" "${temp_dir}"
}

echo "== Configuring & building: iOS simulator (arm64 + x86_64) =="
configure_and_build "${BUILD_ROOT}/llama-ios-sim" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_MIN_OS_VERSION} \
    -DIOS=ON \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphonesimulator \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS=iphonesimulator

echo "== Configuring & building: iOS device (arm64) =="
configure_and_build "${BUILD_ROOT}/llama-ios-device" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_MIN_OS_VERSION} \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS=iphoneos

echo "== Configuring & building: macOS (arm64 + x86_64) =="
configure_and_build "${BUILD_ROOT}/llama-macos" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOS_MIN_OS_VERSION} \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"

echo "== Assembling framework slices =="
make_framework "${BUILD_ROOT}/llama-ios-sim"    "Release-iphonesimulator" "ios"   "iphonesimulator" "-mios-simulator-version-min=${IOS_MIN_OS_VERSION}" "arm64 x86_64"
make_framework "${BUILD_ROOT}/llama-ios-device" "Release-iphoneos"        "ios"   "iphoneos"        "-mios-version-min=${IOS_MIN_OS_VERSION}"           "arm64"
make_framework "${BUILD_ROOT}/llama-macos"      "Release"                 "macos" "macosx"          "-mmacosx-version-min=${MACOS_MIN_OS_VERSION}"      "arm64 x86_64"

echo "== Creating XCFramework =="
rm -rf "${OUT_DIR}/llama.xcframework"
mkdir -p "${OUT_DIR}"
xcrun xcodebuild -create-xcframework \
    -framework "${BUILD_ROOT}/llama-ios-sim/framework/llama.framework" \
    -debug-symbols "${BUILD_ROOT}/llama-ios-sim/dSYMs/llama.dSYM" \
    -framework "${BUILD_ROOT}/llama-ios-device/framework/llama.framework" \
    -debug-symbols "${BUILD_ROOT}/llama-ios-device/dSYMs/llama.dSYM" \
    -framework "${BUILD_ROOT}/llama-macos/framework/llama.framework" \
    -debug-symbols "${BUILD_ROOT}/llama-macos/dSYMs/llama.dSYM" \
    -output "${OUT_DIR}/llama.xcframework"

echo "Done: ${OUT_DIR}/llama.xcframework"
