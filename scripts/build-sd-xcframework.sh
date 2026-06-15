#!/usr/bin/env bash
#
# Builds sd.xcframework (stable-diffusion.cpp + ggml, Metal) for SynapLink.
#
# The THIRD ggml-based framework (after llama + whisper) — the experimental
# on-device image-generation specialist. Each framework force-loads its own
# ggml; Apple's two-level namespace keeps the three symbol sets private per
# dylib, so they coexist. webp/webm/examples are disabled: we read raw RGB
# from sd_image_t and JPEG-encode in Swift.
#
# Slices: iOS device (arm64), iOS simulator (arm64 + x86_64), macOS
# (arm64 + x86_64) — same Intel-dev-Mac rationale as the other builds.
#
# Usage: scripts/build-sd-xcframework.sh
# Output: Frameworks/sd.xcframework

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SD_SRC="${REPO_ROOT}/third_party/stable-diffusion.cpp"
BUILD_ROOT="${REPO_ROOT}/build"
OUT_DIR="${REPO_ROOT}/Frameworks"

SD_TAG="master"
SD_COMMIT="bb90bfa00f858c7df6502e75f31c4440d4d11fde"

if [[ ! -f "${SD_SRC}/CMakeLists.txt" ]]; then
    echo "== Initialising stable-diffusion.cpp submodule =="
    git -C "${REPO_ROOT}" submodule update --init --depth 1 third_party/stable-diffusion.cpp
fi
# stable-diffusion.cpp needs its own ggml fork submodule to build.
if [[ ! -f "${SD_SRC}/ggml/include/ggml.h" ]]; then
    git -C "${SD_SRC}" submodule update --init --depth 1 ggml
fi

CHECKED_OUT="$(git -C "${SD_SRC}" rev-parse HEAD 2>/dev/null || true)"
if [[ "${CHECKED_OUT}" != "${SD_COMMIT}" ]]; then
    echo "error: third_party/stable-diffusion.cpp is at '${CHECKED_OUT:-unknown}', expected ${SD_COMMIT} (${SD_TAG})" >&2
    echo "       if you bumped the submodule, update SD_COMMIT in this script." >&2
    exit 1
fi

IOS_MIN_OS_VERSION=16.4
MACOS_MIN_OS_VERSION=13.3

COMMON_C_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument -g"

COMMON_CMAKE_ARGS=(
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY=""
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
    -DCMAKE_XCODE_ATTRIBUTE_DEBUG_INFORMATION_FORMAT="dwarf-with-dsym"
    -DCMAKE_XCODE_ATTRIBUTE_DEVELOPMENT_TEAM=ggml
    -DSD_METAL=ON
    -DSD_BUILD_EXAMPLES=OFF
    -DSD_WEBP=OFF
    -DSD_WEBM=OFF
    -DSD_BUILD_SHARED_LIBS=OFF
    -DGGML_METAL_EMBED_LIBRARY=ON
    -DGGML_NATIVE=OFF
    -DGGML_OPENMP=OFF
    -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}"
    -DCMAKE_CXX_FLAGS="${COMMON_C_FLAGS}"
)

FRAMEWORK_HEADERS=(
    "${SD_SRC}/include/stable-diffusion.h"
    "${SD_SRC}/ggml/include/ggml.h"
    "${SD_SRC}/ggml/include/ggml-cpu.h"
    "${SD_SRC}/ggml/include/ggml-backend.h"
    "${SD_SRC}/ggml/include/ggml-alloc.h"
    "${SD_SRC}/ggml/include/ggml-metal.h"
)

configure_and_build() {
    local build_dir=$1; shift
    cmake -B "${build_dir}" -G Xcode "${COMMON_CMAKE_ARGS[@]}" "$@" -S "${SD_SRC}"
    cmake --build "${build_dir}" --config Release --target stable-diffusion -j "$(sysctl -n hw.logicalcpu)" -- -quiet
}

# $1 build_dir, $2 platform (ios|macos), $3 sdk, $4 min_version_flag, $5 archs
make_framework() {
    local build_dir=$1 platform=$2 sdk=$3 min_version_flag=$4 archs=$5

    local fw="${build_dir}/framework/sd.framework"
    local header_path module_path plist_path install_name output_lib
    local supported_platform platform_name min_os device_family=""

    if [[ "$platform" == "macos" ]]; then
        mkdir -p "${fw}/Versions/A/Headers" "${fw}/Versions/A/Modules" "${fw}/Versions/A/Resources"
        ln -sfh A "${fw}/Versions/Current"
        ln -sfh Versions/Current/Headers "${fw}/Headers"
        ln -sfh Versions/Current/Modules "${fw}/Modules"
        ln -sfh Versions/Current/Resources "${fw}/Resources"
        ln -sfh Versions/Current/sd "${fw}/sd"
        header_path="${fw}/Versions/A/Headers"; module_path="${fw}/Versions/A/Modules"
        plist_path="${fw}/Versions/A/Resources/Info.plist"; output_lib="${fw}/Versions/A/sd"
        install_name="@rpath/sd.framework/Versions/Current/sd"
        supported_platform="MacOSX"; platform_name="macosx"; min_os="${MACOS_MIN_OS_VERSION}"
    else
        mkdir -p "${fw}/Headers" "${fw}/Modules"
        header_path="${fw}/Headers"; module_path="${fw}/Modules"
        plist_path="${fw}/Info.plist"; output_lib="${fw}/sd"
        install_name="@rpath/sd.framework/sd"
        supported_platform="iPhoneOS"; platform_name="iphoneos"; min_os="${IOS_MIN_OS_VERSION}"
        device_family='
    <key>UIDeviceFamily</key>
    <array>
        <integer>1</integer>
        <integer>2</integer>
    </array>'
        if [[ "$sdk" == "iphonesimulator" ]]; then
            supported_platform="iPhoneSimulator"; platform_name="iphonesimulator"
        fi
    fi

    cp "${FRAMEWORK_HEADERS[@]}" "${header_path}/"

    cat > "${module_path}/module.modulemap" << 'EOF'
framework module sd {
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
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>sd</string>
    <key>CFBundleIdentifier</key><string>org.ggml.sd</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>sd</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>MinimumOSVersion</key><string>${min_os}</string>
    <key>CFBundleSupportedPlatforms</key><array><string>${supported_platform}</string></array>${device_family}
    <key>DTPlatformName</key><string>${platform_name}</string>
</dict>
</plist>
EOF

    # Use the FINAL per-target archives only — NOT Xcode's per-arch
    # intermediates under */Objects-normal/ or */*.build/ (combining those
    # merges duplicate ggml objects → "duplicate symbols" at link).
    local release_dir
    case "$sdk" in
        iphonesimulator) release_dir="Release-iphonesimulator" ;;
        iphoneos)        release_dir="Release-iphoneos" ;;
        *)               release_dir="Release" ;;
    esac
    local libs=(
        "${build_dir}/${release_dir}/libstable-diffusion.a"
        "${build_dir}/ggml/src/${release_dir}/libggml.a"
        "${build_dir}/ggml/src/${release_dir}/libggml-base.a"
        "${build_dir}/ggml/src/${release_dir}/libggml-cpu.a"
        "${build_dir}/ggml/src/ggml-blas/${release_dir}/libggml-blas.a"
        "${build_dir}/ggml/src/ggml-metal/${release_dir}/libggml-metal.a"
    )
    # NOTE: the vendored zip code is already compiled into libstable-diffusion.a,
    # so libzip.a is NOT added here (doing so duplicates its symbols).
    for lib in "${libs[@]}"; do
        if [[ ! -f "${lib}" ]]; then echo "error: missing ${lib}" >&2; exit 1; fi
    done

    local temp_dir="${build_dir}/temp"
    mkdir -p "${temp_dir}"
    xcrun libtool -static -o "${temp_dir}/combined.a" "${libs[@]}" 2> /dev/null

    local arch_flags=""
    for arch in ${archs}; do arch_flags+=" -arch ${arch}"; done

    echo "Creating dynamic library for ${sdk} (${archs})..."
    xcrun -sdk "$sdk" clang++ -dynamiclib \
        -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
        ${arch_flags} ${min_version_flag} \
        -Wl,-force_load,"${temp_dir}/combined.a" \
        -framework Foundation -framework Metal -framework Accelerate \
        -install_name "${install_name}" \
        -o "${output_lib}"

    if [[ "$sdk" == "iphoneos" ]]; then
        xcrun vtool -set-build-version ios ${IOS_MIN_OS_VERSION} ${IOS_MIN_OS_VERSION} -replace \
            -output "${output_lib}" "${output_lib}"
    fi

    mkdir -p "${build_dir}/dSYMs"
    xcrun dsymutil "${output_lib}" -o "${build_dir}/dSYMs/sd.dSYM" 2> /dev/null || true
    xcrun strip -S "${output_lib}" -o "${temp_dir}/stripped"
    mv "${temp_dir}/stripped" "${output_lib}"
    rm -rf "${output_lib}.dSYM" "${temp_dir}"
}

echo "== Configuring & building: iOS simulator (arm64 + x86_64) =="
configure_and_build "${BUILD_ROOT}/sd-ios-sim" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_MIN_OS_VERSION} -DIOS=ON \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphonesimulator \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS=iphonesimulator

echo "== Configuring & building: iOS device (arm64) =="
configure_and_build "${BUILD_ROOT}/sd-ios-device" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_MIN_OS_VERSION} \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS=iphoneos

echo "== Configuring & building: macOS (arm64 + x86_64) =="
configure_and_build "${BUILD_ROOT}/sd-macos" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOS_MIN_OS_VERSION} \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"

echo "== Assembling framework slices =="
make_framework "${BUILD_ROOT}/sd-ios-sim"    "ios"   "iphonesimulator" "-mios-simulator-version-min=${IOS_MIN_OS_VERSION}" "arm64 x86_64"
make_framework "${BUILD_ROOT}/sd-ios-device" "ios"   "iphoneos"        "-mios-version-min=${IOS_MIN_OS_VERSION}"           "arm64"
make_framework "${BUILD_ROOT}/sd-macos"      "macos" "macosx"          "-mmacosx-version-min=${MACOS_MIN_OS_VERSION}"      "arm64 x86_64"

echo "== Creating XCFramework =="
rm -rf "${OUT_DIR}/sd.xcframework"
mkdir -p "${OUT_DIR}"
xcrun xcodebuild -create-xcframework \
    -framework "${BUILD_ROOT}/sd-ios-sim/framework/sd.framework" \
    -debug-symbols "${BUILD_ROOT}/sd-ios-sim/dSYMs/sd.dSYM" \
    -framework "${BUILD_ROOT}/sd-ios-device/framework/sd.framework" \
    -debug-symbols "${BUILD_ROOT}/sd-ios-device/dSYMs/sd.dSYM" \
    -framework "${BUILD_ROOT}/sd-macos/framework/sd.framework" \
    -debug-symbols "${BUILD_ROOT}/sd-macos/dSYMs/sd.dSYM" \
    -output "${OUT_DIR}/sd.xcframework"

echo "Done: ${OUT_DIR}/sd.xcframework"
