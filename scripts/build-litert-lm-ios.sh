#!/usr/bin/env bash
set -euo pipefail

# Build LiteRT-LM for iOS (arm64 device + arm64 simulator)
# Produces two xcframeworks:
#   1. LiteRTLM.xcframework — static framework with Obj-C++ wrapper compiled in
#   2. GemmaConstraintProvider.xcframework — optional dynamic framework for tool calling
#
# The consumer just adds LiteRTLM.xcframework and imports LRTEngine.h etc.
# All C++ internals are hidden — only the LRT* Obj-C API is exposed.

LITERT_LM_VERSION="${LITERT_LM_VERSION:-v0.10.1}"
LITERT_LM_REPO="https://github.com/google-ai-edge/LiteRT-LM.git"
WORK_DIR="${WORK_DIR:-$(pwd)/build}"
LITERT_LM_DIR="${WORK_DIR}/LiteRT-LM"
OUTPUT_DIR="${WORK_DIR}/output"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

CACHE_DIR="${HOME}/.cache/bazel-ios"

log() { echo "==> $*"; }

# ---------------------------------------------------------------------------
# 1. Clone LiteRT-LM and inject custom BUILD target
# ---------------------------------------------------------------------------
clone_litert_lm() {
    log "Cloning LiteRT-LM ${LITERT_LM_VERSION}..."
    if [ -d "${LITERT_LM_DIR}" ]; then
        rm -rf "${LITERT_LM_DIR}"
    fi
    git clone --depth 1 --branch "${LITERT_LM_VERSION}" "${LITERT_LM_REPO}" "${LITERT_LM_DIR}"
}

inject_build_target() {
    log "Injecting apple_static_library BUILD target..."
    mkdir -p "${LITERT_LM_DIR}/ios_package"

    cat > "${LITERT_LM_DIR}/ios_package/BUILD" << 'BUILDEOF'
load("@build_bazel_rules_apple//apple:apple.bzl", "apple_static_library")

apple_static_library(
    name = "LiteRTLM",
    minimum_os_version = "13.0",
    platform_type = "ios",
    deps = [
        "//runtime/engine:litert_lm_lib",
        "//runtime/components/rust:minijinja_template_cpp",
    ],
)
BUILDEOF
}

# ---------------------------------------------------------------------------
# 2. Build for a given iOS config
# ---------------------------------------------------------------------------
build_for_config() {
    local config="$1"
    log "Building for config=${config}..."
    cd "${LITERT_LM_DIR}"

    bazel build \
        --config="${config}" \
        --disk_cache="${CACHE_DIR}" \
        --build_tag_filters=-requires-mac-inputs:hard,-no_mac \
        --check_visibility=false \
        //ios_package:LiteRTLM \
        -- \
        -//python/... -//schema/py:* -//kotlin/...

    # Build proto + Rust targets directly for predictable header/lib paths
    log "Building generated header targets..."
    bazel build \
        --config="${config}" \
        --disk_cache="${CACHE_DIR}" \
        --build_tag_filters=-requires-mac-inputs:hard,-no_mac \
        //runtime/proto:engine_cc_proto \
        //runtime/proto:sampler_params_cc_proto \
        //runtime/proto:llm_metadata_cc_proto \
        //runtime/proto:llm_model_type_cc_proto \
        //runtime/proto:token_cc_proto \
        //runtime/proto:litert_lm_metrics_cc_proto \
        //runtime/components:prompt_template \
        //runtime/components/rust:minijinja_template \
        -- \
        -//python/... -//schema/py:* -//kotlin/... 2>/dev/null || true

    log "Build for ${config} complete."
}

# ---------------------------------------------------------------------------
# 3. Collect the static library
# ---------------------------------------------------------------------------
collect_static_lib() {
    local config_label="$1"
    local dest_dir="${OUTPUT_DIR}/${config_label}"
    mkdir -p "${dest_dir}"
    cd "${LITERT_LM_DIR}"

    local output_base
    output_base="$(bazel info output_base 2>/dev/null)"

    log "Searching for apple_static_library output..."
    local found_lib="" best_size=0
    while IFS= read -r -d '' f; do
        local fsize
        fsize=$(stat -f%z "$f" 2>/dev/null || echo "0")
        if [ "${fsize}" -gt "${best_size}" ]; then
            best_size="${fsize}"
            found_lib="$f"
        fi
    done < <(find "${output_base}/execroot" -name 'LiteRTLM*.a' \
        -not -path '*-exec-*' -print0 2>/dev/null)

    if [ -z "${found_lib}" ] || [ "${best_size}" -eq 0 ]; then
        echo "ERROR: Could not find apple_static_library output" >&2
        exit 1
    fi

    log "Found: ${found_lib} (${best_size} bytes)"
    cp "${found_lib}" "${dest_dir}/liblitert_lm.a"
    lipo -info "${dest_dir}/liblitert_lm.a" 2>/dev/null || file "${dest_dir}/liblitert_lm.a"
}

# ---------------------------------------------------------------------------
# 4. Collect internal headers (for compiling the wrapper, not shipped)
# ---------------------------------------------------------------------------
collect_internal_headers() {
    local config_label="$1"
    local dest_headers="${OUTPUT_DIR}/${config_label}/internal_headers"
    mkdir -p "${dest_headers}"
    cd "${LITERT_LM_DIR}"

    local bazel_bin output_base bazel_external execroot
    bazel_bin="$(bazel info bazel-bin --config="${config_label}" 2>/dev/null || bazel info bazel-bin 2>/dev/null)"
    output_base="$(bazel info output_base 2>/dev/null)"
    bazel_external="${output_base}/external"
    execroot="${output_base}/execroot/litert_lm"

    # A) runtime/ source headers
    (find runtime -name '*.h' 2>/dev/null | while read -r f; do
        mkdir -p "${dest_headers}/$(dirname "$f")"; cp "$f" "${dest_headers}/$f"
    done) || true

    # B) Generated headers (proto .pb.h)
    if [ -d "${bazel_bin}/runtime" ]; then
        (cd "${bazel_bin}" && find runtime -name '*.h' 2>/dev/null | while read -r f; do
            mkdir -p "${dest_headers}/$(dirname "$f")"; cp "$f" "${dest_headers}/$f" 2>/dev/null || true
        done) || true
    fi
    (find "${execroot}/bazel-out" -path "*/bin/runtime/*.h" \
        -not -path '*-exec-*' -not -path '*/external/*' \
        -not -path '*darwin_arm64-opt/bin/*' -not -path '*_virtual_includes*' \
        -type f 2>/dev/null | while read -r f; do
        local rel; rel=$(echo "$f" | sed -n 's|.*/bin/\(runtime/.*\)|\1|p')
        if [ -n "${rel}" ] && [ ! -f "${dest_headers}/${rel}" ]; then
            mkdir -p "${dest_headers}/$(dirname "$rel")"; cp "$f" "${dest_headers}/$rel" 2>/dev/null || true
        fi
    done) || true

    # C) CXX bridge stub (minijinja_template.rs.h)
    mkdir -p "${dest_headers}/runtime/components/rust"
    cat > "${dest_headers}/runtime/components/rust/minijinja_template.rs.h" << 'RSSTUB'
#pragma once
#include <memory>
#include <string>
namespace rust { inline namespace cxxbridge1 {
template <typename T> class Box {
public:
    Box() noexcept : ptr_(nullptr) {}
    Box(Box &&o) noexcept : ptr_(o.ptr_) { o.ptr_ = nullptr; }
    ~Box() noexcept { ptr_ = nullptr; }
    Box &operator=(Box &&o) & noexcept { ptr_ = o.ptr_; o.ptr_ = nullptr; return *this; }
    T *operator->() const noexcept { return static_cast<T*>(ptr_); }
    T &operator*() const noexcept { return *static_cast<T*>(ptr_); }
private: void *ptr_;
};
}} // namespace rust::cxxbridge1
struct MinijinjaTemplate;
RSSTUB

    # D) build_config.h stub
    mkdir -p "${dest_headers}/litert/build_common"
    cat > "${dest_headers}/litert/build_common/build_config.h" << 'STUBEOF'
#ifndef THIRD_PARTY_ODML_LITERT_LITERT_BUILD_COMMON_BUILD_CONFIG_H_
#define THIRD_PARTY_ODML_LITERT_LITERT_BUILD_COMMON_BUILD_CONFIG_H_
#endif
STUBEOF

    # E) External dep headers: abseil, nlohmann, litert, protobuf, re2
    if [ -d "${bazel_external}/com_google_absl/absl" ]; then
        (cd "${bazel_external}/com_google_absl" && find absl \( -name '*.h' -o -name '*.inc' \) 2>/dev/null | while read -r f; do
            mkdir -p "${dest_headers}/$(dirname "$f")"; cp "$f" "${dest_headers}/$f"
        done) || true
    fi
    if [ -d "${bazel_external}/nlohmann_json" ]; then
        (cd "${bazel_external}/nlohmann_json" && find . \( -name '*.hpp' -o -name '*.h' \) 2>/dev/null | while read -r f; do
            mkdir -p "${dest_headers}/nlohmann_json/$(dirname "$f")"; cp "$f" "${dest_headers}/nlohmann_json/$f"
        done) || true
    fi
    if [ -d "${bazel_external}/litert" ]; then
        for subdir in litert tflite; do
            if [ -d "${bazel_external}/litert/${subdir}" ]; then
                (cd "${bazel_external}/litert" && find "${subdir}" -name '*.h' 2>/dev/null | while read -r f; do
                    mkdir -p "${dest_headers}/$(dirname "$f")"; cp "$f" "${dest_headers}/$f"
                done) || true
            fi
        done
        # LiteRT generated headers
        (find "${execroot}/bazel-out" -path "*/bin/external/litert/*.h" \
            -not -path '*_virtual_includes*' -not -path '*-exec-*' \
            -type f 2>/dev/null | while read -r f; do
            local rel; rel=$(echo "$f" | sed -n 's|.*/external/litert/\(.*\)|\1|p')
            if [ -n "${rel}" ] && [ ! -f "${dest_headers}/${rel}" ]; then
                mkdir -p "${dest_headers}/$(dirname "$rel")"; cp "$f" "${dest_headers}/$rel" 2>/dev/null || true
            fi
        done) || true
    fi
    if [ -d "${bazel_external}/com_google_protobuf/src/google" ]; then
        (cd "${bazel_external}/com_google_protobuf/src" && find google \( -name '*.h' -o -name '*.inc' \) 2>/dev/null | while read -r f; do
            mkdir -p "${dest_headers}/$(dirname "$f")"; cp "$f" "${dest_headers}/$f"
        done) || true
    fi
    if [ -d "${bazel_external}/com_googlesource_code_re2/re2" ]; then
        (cd "${bazel_external}/com_googlesource_code_re2" && find re2 -name '*.h' 2>/dev/null | while read -r f; do
            mkdir -p "${dest_headers}/$(dirname "$f")"; cp "$f" "${dest_headers}/$f"
        done) || true
    fi

    local hc; hc=$(find "${dest_headers}" \( -name '*.h' -o -name '*.hpp' -o -name '*.inc' \) | wc -l | tr -d ' ')
    log "Collected ${hc} internal header files for ${config_label}."
}

# ---------------------------------------------------------------------------
# 5. Compile wrapper .mm → .o and merge into the static library
# ---------------------------------------------------------------------------
compile_wrapper() {
    local config_label="$1"
    local dest_dir="${OUTPUT_DIR}/${config_label}"
    local int_headers="${dest_dir}/internal_headers"
    local wrapper_dir="${REPO_ROOT}/Sources/LiteRTLM"

    log "Compiling wrapper for ${config_label}..."

    local target sdk
    case "${config_label}" in
        ios_arm64)     target="arm64-apple-ios13.0";           sdk="iphoneos" ;;
        ios_sim_arm64) target="arm64-apple-ios13.0-simulator"; sdk="iphonesimulator" ;;
    esac
    local sdk_path
    sdk_path="$(xcrun --sdk "${sdk}" --show-sdk-path)"

    local clang_flags=(
        -std=c++20 -fobjc-arc
        -target "${target}" -isysroot "${sdk_path}"
        -I "${int_headers}"
        -I "${int_headers}/nlohmann_json"
        -I "${int_headers}/nlohmann_json/include"
        -I "${wrapper_dir}"
        -Wno-deprecated-declarations
        -fembed-bitcode
    )

    local -a obj_files=()
    for mm_file in "${wrapper_dir}"/*.mm; do
        local obj="${dest_dir}/$(basename "${mm_file}" .mm).o"
        log "  Compiling $(basename "$mm_file")..."
        xcrun --sdk "${sdk}" clang++ "${clang_flags[@]}" -c "$mm_file" -o "$obj"
        obj_files+=("$obj")
    done

    # Merge wrapper .o files into the static library
    log "  Merging wrapper objects into liblitert_lm.a..."
    libtool -static -o "${dest_dir}/liblitert_lm_merged.a" \
        "${dest_dir}/liblitert_lm.a" "${obj_files[@]}" 2>/dev/null
    mv "${dest_dir}/liblitert_lm_merged.a" "${dest_dir}/liblitert_lm.a"

    local libsize; libsize=$(stat -f%z "${dest_dir}/liblitert_lm.a" 2>/dev/null)
    log "  Final library: ${libsize} bytes"
}

# ---------------------------------------------------------------------------
# 6. Prepare public headers (only the LRT* Obj-C API)
# ---------------------------------------------------------------------------
prepare_public_headers() {
    local config_label="$1"
    local pub_headers="${OUTPUT_DIR}/${config_label}/public_headers"
    local wrapper_dir="${REPO_ROOT}/Sources/LiteRTLM"
    mkdir -p "${pub_headers}"

    # Copy only the public Obj-C headers
    for h in "${wrapper_dir}"/LRT*.h; do
        cp "$h" "${pub_headers}/"
    done

    # Create umbrella header
    cat > "${pub_headers}/LiteRTLM.h" << 'UMBRELLA'
#ifndef LITERT_LM_IOS_UMBRELLA_H
#define LITERT_LM_IOS_UMBRELLA_H

#import "LRTTypes.h"
#import "LRTEngine.h"
#import "LRTSession.h"
#import "LRTConversation.h"

#endif /* LITERT_LM_IOS_UMBRELLA_H */
UMBRELLA

    # Create module map
    cat > "${pub_headers}/module.modulemap" << 'MODMAP'
framework module LiteRTLM {
    umbrella header "LiteRTLM.h"
    export *
    module * { export * }
}
MODMAP

    local hc; hc=$(find "${pub_headers}" -name '*.h' | wc -l | tr -d ' ')
    log "Public headers: ${hc} files for ${config_label}"
}

# ---------------------------------------------------------------------------
# 7. Collect prebuilt dylibs
# ---------------------------------------------------------------------------
collect_dylibs() {
    local config_label="$1"
    local dest_dir="${OUTPUT_DIR}/${config_label}"
    cd "${LITERT_LM_DIR}"

    local prebuilt_dir=""
    case "${config_label}" in
        ios_arm64)     prebuilt_dir="prebuilt/ios_arm64" ;;
        ios_sim_arm64) prebuilt_dir="prebuilt/ios_sim_arm64" ;;
    esac
    if [ -n "${prebuilt_dir}" ] && [ -d "${prebuilt_dir}" ]; then
        mkdir -p "${dest_dir}/dylibs"
        find "${prebuilt_dir}" -name '*.dylib' -exec cp {} "${dest_dir}/dylibs/" \; 2>/dev/null || true
        log "Dylibs: $(ls "${dest_dir}/dylibs/" 2>/dev/null | tr '\n' ' ')"
    fi
}

# ---------------------------------------------------------------------------
# 8. Create xcframeworks
# ---------------------------------------------------------------------------
create_xcframeworks() {
    log "Creating LiteRTLM.xcframework (static)..."
    local xcfw="${OUTPUT_DIR}/LiteRTLM.xcframework"
    rm -rf "${xcfw}"

    xcodebuild -create-xcframework \
        -library "${OUTPUT_DIR}/ios_arm64/liblitert_lm.a" \
        -headers "${OUTPUT_DIR}/ios_arm64/public_headers" \
        -library "${OUTPUT_DIR}/ios_sim_arm64/liblitert_lm.a" \
        -headers "${OUTPUT_DIR}/ios_sim_arm64/public_headers" \
        -output "${xcfw}"
    log "Created ${xcfw}"

    # GemmaConstraintProvider dynamic xcframework
    local arm64_dylib="${OUTPUT_DIR}/ios_arm64/dylibs/libGemmaModelConstraintProvider.dylib"
    local sim_dylib="${OUTPUT_DIR}/ios_sim_arm64/dylibs/libGemmaModelConstraintProvider.dylib"
    if [ -f "${arm64_dylib}" ] && [ -f "${sim_dylib}" ]; then
        log "Creating GemmaConstraintProvider.xcframework (dynamic)..."
        local gemma_xcfw="${OUTPUT_DIR}/GemmaConstraintProvider.xcframework"
        rm -rf "${gemma_xcfw}"
        xcodebuild -create-xcframework \
            -library "${arm64_dylib}" \
            -library "${sim_dylib}" \
            -output "${gemma_xcfw}"
        log "Created ${gemma_xcfw}"
    else
        log "WARNING: GemmaConstraintProvider dylib not found for one or both archs"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}"

    clone_litert_lm
    inject_build_target

    for arch in ios_arm64 ios_sim_arm64; do
        build_for_config "${arch}"
        collect_static_lib "${arch}"
        collect_internal_headers "${arch}"
        compile_wrapper "${arch}"
        prepare_public_headers "${arch}"
        collect_dylibs "${arch}"
    done

    create_xcframeworks

    log "Done! Frameworks in ${OUTPUT_DIR}/"
    log "  LiteRTLM.xcframework — main static framework"
    log "  GemmaConstraintProvider.xcframework — optional dynamic framework"
}

main "$@"
