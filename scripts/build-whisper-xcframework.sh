#!/usr/bin/env bash
#
# Builds whisper.xcframework (libwhisper + ggml, Metal, Accelerate) for SynapLink.
#
# Sibling to build-llama-xcframework.sh. whisper.cpp is the dedicated on-device
# ASR (speech -> text) for the iPhone 11 tier, where the omni Gemma 4 E2B model
# can't fit. Two ggml-based frameworks coexist in one app: each force-loads its
# OWN copy of ggml, and Apple's two-level namespace keeps the symbol sets
# private to each dylib, so there is no cross-framework ggml clash.
#
# Slices: iOS device (arm64), iOS simulator (arm64 + x86_64), macOS
# (arm64 + x86_64) — same Intel-dev-Mac rationale as the llama build.
#
# Usage: scripts/build-whisper-xcframework.sh
# Output: Frameworks/whisper.xcframework

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WHISPER_SRC="${REPO_ROOT}/third_party/whisper.cpp"
BUILD_ROOT="${REPO_ROOT}/build"
OUT_DIR="${REPO_ROOT}/Frameworks"

# whisper.cpp lives in a git submodule; the gitlink is the authoritative pin.
# WHISPER_TAG/WHISPER_COMMIT mirror it; the check fails the build on drift.
WHISPER_TAG="v1.8.6"
WHISPER_COMMIT="23ee03506a91ac3d3f0071b40e66a430eebdfa1d"

if [[ ! -f "${WHISPER_SRC}/CMakeLists.txt" ]]; then
    echo "== Initialising whisper.cpp submodule =="
    git -C "${REPO_ROOT}" submodule update --init --depth 1 third_party/whisper.cpp
fi

CHECKED_OUT="$(git -C "${WHISPER_SRC}" rev-parse HEAD 2>/dev/null || true)"
if [[ "${CHECKED_OUT}" != "${WHISPER_COMMIT}" ]]; then
    echo "error: third_party/whisper.cpp is at '${CHECKED_OUT:-unknown}', expected ${WHISPER_COMMIT} (${WHISPER_TAG})" >&2
    echo "       if you bumped the submodule, update WHISPER_TAG/WHISPER_COMMIT in this script;" >&2
    echo "       otherwise run: git submodule update --init third_party/whisper.cpp" >&2
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
    -DWHISPER_BUILD_EXAMPLES=OFF
    -DWHISPER_BUILD_TESTS=OFF
    -DWHISPER_BUILD_SERVER=OFF
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
    "${WHISPER_SRC}/include/whisper.h"
    "${WHISPER_SRC}/ggml/include/ggml.h"
    "${WHISPER_SRC}/ggml/include/ggml-cpu.h"
    "${WHISPER_SRC}/ggml/include/ggml-backend.h"
    "${WHISPER_SRC}/ggml/include/ggml-alloc.h"
    "${WHISPER_SRC}/ggml/include/ggml-metal.h"
)

configure_and_build() {
    local build_dir=$1; shift
    cmake -B "${build_dir}" -G Xcode "${COMMON_CMAKE_ARGS[@]}" "$@" -S "${WHISPER_SRC}"
    cmake --build "${build_dir}" --config Release --target whisper -j "$(sysctl -n hw.logicalcpu)" -- -quiet
}

# $1 build_dir, $2 release_subdir, $3 platform (ios|macos), $4 sdk, $5 min_version_flag, $6 archs
make_framework() {
    local build_dir=$1
    local release_dir=$2
    local platform=$3
    local sdk=$4
    local min_version_flag=$5
    local archs=$6

    local fw="${build_dir}/framework/whisper.framework"
    local header_path module_path plist_path install_name

    if [[ "$platform" == "macos" ]]; then
        mkdir -p "${fw}/Versions/A/Headers" "${fw}/Versions/A/Modules" "${fw}/Versions/A/Resources"
        ln -sfh A "${fw}/Versions/Current"
        ln -sfh Versions/Current/Headers "${fw}/Headers"
        ln -sfh Versions/Current/Modules "${fw}/Modules"
        ln -sfh Versions/Current/Resources "${fw}/Resources"
        ln -sfh Versions/Current/whisper "${fw}/whisper"
        header_path="${fw}/Versions/A/Headers"
        module_path="${fw}/Versions/A/Modules"
        plist_path="${fw}/Versions/A/Resources/Info.plist"
        install_name="@rpath/whisper.framework/Versions/Current/whisper"
        local output_lib="${fw}/Versions/A/whisper"
        local supported_platform="MacOSX" platform_name="macosx" min_os="${MACOS_MIN_OS_VERSION}"
        local device_family=""
    else
        mkdir -p "${fw}/Headers" "${fw}/Modules"
        header_path="${fw}/Headers"
        module_path="${fw}/Modules"
        plist_path="${fw}/Info.plist"
        install_name="@rpath/whisper.framework/whisper"
        local output_lib="${fw}/whisper"
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
framework module whisper {
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
    <string>whisper</string>
    <key>CFBundleIdentifier</key>
    <string>org.ggml.whisper</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>whisper</string>
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
        "${build_dir}/src/${release_dir}/libwhisper.a"
        "${build_dir}/ggml/src/${release_dir}/libggml.a"
        "${build_dir}/ggml/src/${release_dir}/libggml-base.a"
        "${build_dir}/ggml/src/${release_dir}/libggml-cpu.a"
        "${build_dir}/ggml/src/ggml-metal/${release_dir}/libggml-metal.a"
        "${build_dir}/ggml/src/ggml-blas/${release_dir}/libggml-blas.a"
    )

    local temp_dir="${build_dir}/temp"
    mkdir -p "${temp_dir}"
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
    xcrun dsymutil "${output_lib}" -o "${build_dir}/dSYMs/whisper.dSYM"
    xcrun strip -S "${output_lib}" -o "${temp_dir}/stripped"
    mv "${temp_dir}/stripped" "${output_lib}"
    rm -rf "${output_lib}.dSYM" "${temp_dir}"
}

echo "== Configuring & building: iOS simulator (arm64 + x86_64) =="
configure_and_build "${BUILD_ROOT}/whisper-ios-sim" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_MIN_OS_VERSION} \
    -DIOS=ON \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphonesimulator \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS=iphonesimulator

echo "== Configuring & building: iOS device (arm64) =="
configure_and_build "${BUILD_ROOT}/whisper-ios-device" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_MIN_OS_VERSION} \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS=iphoneos

echo "== Configuring & building: macOS (arm64 + x86_64) =="
configure_and_build "${BUILD_ROOT}/whisper-macos" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOS_MIN_OS_VERSION} \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"

echo "== Assembling framework slices =="
make_framework "${BUILD_ROOT}/whisper-ios-sim"    "Release-iphonesimulator" "ios"   "iphonesimulator" "-mios-simulator-version-min=${IOS_MIN_OS_VERSION}" "arm64 x86_64"
make_framework "${BUILD_ROOT}/whisper-ios-device" "Release-iphoneos"        "ios"   "iphoneos"        "-mios-version-min=${IOS_MIN_OS_VERSION}"           "arm64"
make_framework "${BUILD_ROOT}/whisper-macos"      "Release"                 "macos" "macosx"          "-mmacosx-version-min=${MACOS_MIN_OS_VERSION}"      "arm64 x86_64"

echo "== Creating XCFramework =="
rm -rf "${OUT_DIR}/whisper.xcframework"
mkdir -p "${OUT_DIR}"
xcrun xcodebuild -create-xcframework \
    -framework "${BUILD_ROOT}/whisper-ios-sim/framework/whisper.framework" \
    -debug-symbols "${BUILD_ROOT}/whisper-ios-sim/dSYMs/whisper.dSYM" \
    -framework "${BUILD_ROOT}/whisper-ios-device/framework/whisper.framework" \
    -debug-symbols "${BUILD_ROOT}/whisper-ios-device/dSYMs/whisper.dSYM" \
    -framework "${BUILD_ROOT}/whisper-macos/framework/whisper.framework" \
    -debug-symbols "${BUILD_ROOT}/whisper-macos/dSYMs/whisper.dSYM" \
    -output "${OUT_DIR}/whisper.xcframework"

echo "Done: ${OUT_DIR}/whisper.xcframework"
