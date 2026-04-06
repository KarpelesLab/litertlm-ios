#!/usr/bin/env bash
set -euo pipefail

# Build LiteRT-LM for iOS (arm64 device + arm64 simulator)
# Produces an xcframework with static libraries and headers.
#
# Strategy: inject an apple_static_library BUILD target into the LiteRT-LM
# checkout that bundles all transitive deps into a single .a file per arch.

LITERT_LM_VERSION="${LITERT_LM_VERSION:-v0.10.1}"
LITERT_LM_REPO="https://github.com/google-ai-edge/LiteRT-LM.git"
WORK_DIR="${WORK_DIR:-$(pwd)/build}"
LITERT_LM_DIR="${WORK_DIR}/LiteRT-LM"
OUTPUT_DIR="${WORK_DIR}/output"

# Single shared Bazel disk cache - both iOS builds share exec-config toolchain blobs
CACHE_DIR="${HOME}/.cache/bazel-ios"

log() { echo "==> $*"; }

# ---------------------------------------------------------------------------
# 1. Clone LiteRT-LM and inject our custom BUILD target
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

# Produces a single .a containing litert_lm_lib and ALL transitive deps.
# Build with: bazel build --config=ios_arm64 //ios_package:LiteRTLM
apple_static_library(
    name = "LiteRTLM",
    minimum_os_version = "13.0",
    platform_type = "ios",
    deps = [
        "//runtime/engine:litert_lm_lib",
    ],
)
BUILDEOF

    log "BUILD target injected at ios_package/BUILD"
}

# ---------------------------------------------------------------------------
# 2. Build for a given iOS config using the injected target
# ---------------------------------------------------------------------------
build_for_config() {
    local config="$1"       # e.g. ios_arm64 or ios_sim_arm64

    log "Building for config=${config}..."
    cd "${LITERT_LM_DIR}"

    # apple_static_library handles platform/arch internally, but we still
    # pass the config so that the .bazelrc iOS flags apply (min OS, C++20, etc.)
    bazel build \
        --config="${config}" \
        --disk_cache="${CACHE_DIR}" \
        --build_tag_filters=-requires-mac-inputs:hard,-no_mac \
        //ios_package:LiteRTLM \
        -- \
        -//python/... \
        -//schema/py:* \
        -//kotlin/...

    log "Build for ${config} complete."
}

# ---------------------------------------------------------------------------
# 3. Collect the apple_static_library output
# ---------------------------------------------------------------------------
collect_libs() {
    local config_label="$1"   # e.g. "ios_arm64"
    local dest_dir="${OUTPUT_DIR}/${config_label}"
    mkdir -p "${dest_dir}"

    cd "${LITERT_LM_DIR}"

    log "Collecting library for ${config_label}..."

    cd "${LITERT_LM_DIR}"
    local output_base
    output_base="$(bazel info output_base 2>/dev/null)"

    # apple_static_library produces two files:
    #   LiteRTLM-arm64-apple-ios13.0-fl.a  (per-arch, contains all deps - THIS is what we want)
    #   LiteRTLM_lipo.a  (lipo wrapper - may be empty when using --config override)
    #
    # Search for the per-arch .a file first (the -fl.a suffix), then fall back to _lipo.a
    log "Searching for per-arch static library..."

    local found_lib=""
    local best_size=0

    # Find all LiteRTLM .a files, pick the largest non-lipo one
    while IFS= read -r -d '' f; do
        local fsize
        fsize=$(stat -f%z "$f" 2>/dev/null || stat --format=%s "$f" 2>/dev/null || echo "0")
        log "  candidate: $f (${fsize} bytes)"
        if [ "${fsize}" -gt "${best_size}" ]; then
            best_size="${fsize}"
            found_lib="$f"
        fi
    done < <(find "${output_base}/execroot" -name 'LiteRTLM*.a' \
        -not -path '*-exec-*' \
        -print0 2>/dev/null)

    if [ -z "${found_lib}" ] || [ "${best_size}" -eq 0 ]; then
        echo "ERROR: Could not find non-empty apple_static_library output" >&2
        echo "DEBUG: All .a files in ios_package:" >&2
        find "${output_base}/execroot" -path "*/ios_package/*" -type f 2>/dev/null | head -20 >&2
        echo "DEBUG: All LiteRTLM files:" >&2
        find "${output_base}/execroot" -name "LiteRTLM*" 2>/dev/null | head -20 >&2
        exit 1
    fi

    log "Found library: ${found_lib} (${best_size} bytes)"
    cp "${found_lib}" "${dest_dir}/liblitert_lm.a"

    # Verify architecture
    log "Architecture info:"
    lipo -info "${dest_dir}/liblitert_lm.a" 2>/dev/null || file "${dest_dir}/liblitert_lm.a"
}

# ---------------------------------------------------------------------------
# 4. Collect headers needed for the public API
# ---------------------------------------------------------------------------
collect_headers() {
    local config_label="$1"
    local dest_headers="${OUTPUT_DIR}/${config_label}/headers"
    mkdir -p "${dest_headers}"

    cd "${LITERT_LM_DIR}"

    log "Collecting headers for ${config_label}..."

    # Public API headers from LiteRT-LM runtime
    local -a api_headers=(
        "runtime/engine/engine.h"
        "runtime/engine/engine_factory.h"
        "runtime/engine/engine_settings.h"
        "runtime/engine/io_types.h"
        "runtime/engine/litert_lm_lib.h"
        "runtime/conversation/conversation.h"
        "runtime/conversation/io_types.h"
        "runtime/components/tokenizer.h"
        "runtime/components/prompt_template.h"
        "runtime/components/constrained_decoding/constraint.h"
        "runtime/components/constrained_decoding/constraint_provider.h"
        "runtime/components/constrained_decoding/constraint_provider_config.h"
        "runtime/conversation/model_data_processor/config_registry.h"
        "runtime/conversation/model_data_processor/model_data_processor.h"
        "runtime/executor/executor_settings_base.h"
        "runtime/executor/llm_executor_settings.h"
        "runtime/executor/audio_executor_settings.h"
        "runtime/executor/vision_executor_settings.h"
        "runtime/util/status_macros.h"
        "runtime/util/litert_status_util.h"
        "runtime/util/scoped_file.h"
    )

    for hdr in "${api_headers[@]}"; do
        if [ -f "${hdr}" ]; then
            local dir
            dir="$(dirname "${hdr}")"
            mkdir -p "${dest_headers}/${dir}"
            cp "${hdr}" "${dest_headers}/${dir}/"
        fi
    done

    # Copy proto-generated headers from bazel-bin
    local bazel_bin
    bazel_bin="$(bazel info bazel-bin --config="${config_label}" 2>/dev/null || true)"
    if [ -z "${bazel_bin}" ]; then
        bazel_bin="$(bazel info bazel-bin 2>/dev/null || echo "bazel-bin")"
    fi
    if [ -d "${bazel_bin}/runtime/proto" ]; then
        mkdir -p "${dest_headers}/runtime/proto"
        find "${bazel_bin}/runtime/proto" -name '*.h' -exec cp {} "${dest_headers}/runtime/proto/" \; 2>/dev/null || true
    fi

    # Copy dependency headers from the external workspace
    local bazel_external
    bazel_external="$(bazel info output_base 2>/dev/null)/external"

    # Abseil
    if [ -d "${bazel_external}/com_google_absl/absl" ]; then
        log "Copying abseil headers..."
        (cd "${bazel_external}/com_google_absl" && find absl \( -name '*.h' -o -name '*.inc' \) 2>/dev/null | while read -r f; do
            mkdir -p "${dest_headers}/$(dirname "$f")"
            cp "$f" "${dest_headers}/$f"
        done) || true
    fi

    # nlohmann/json
    if [ -d "${bazel_external}/nlohmann_json" ]; then
        log "Copying nlohmann/json headers..."
        (cd "${bazel_external}/nlohmann_json" && find . \( -name '*.hpp' -o -name '*.h' \) 2>/dev/null | while read -r f; do
            mkdir -p "${dest_headers}/nlohmann_json/$(dirname "$f")"
            cp "$f" "${dest_headers}/nlohmann_json/$f"
        done) || true
    fi

    # LiteRT headers
    if [ -d "${bazel_external}/litert" ]; then
        log "Copying LiteRT headers..."
        for subdir in litert tflite; do
            if [ -d "${bazel_external}/litert/${subdir}" ]; then
                (cd "${bazel_external}/litert" && find "${subdir}" -name '*.h' 2>/dev/null | head -500 | while read -r f; do
                    mkdir -p "${dest_headers}/$(dirname "$f")"
                    cp "$f" "${dest_headers}/$f"
                done) || true
            fi
        done
    fi

    local header_count
    header_count=$(find "${dest_headers}" \( -name '*.h' -o -name '*.hpp' -o -name '*.inc' \) | wc -l | tr -d ' ')
    log "Collected ${header_count} header files for ${config_label}."
}

# ---------------------------------------------------------------------------
# 5. Create xcframework
# ---------------------------------------------------------------------------
create_xcframework() {
    local xcfw_path="${OUTPUT_DIR}/LiteRTLM.xcframework"
    rm -rf "${xcfw_path}"

    log "Creating xcframework..."

    xcodebuild -create-xcframework \
        -library "${OUTPUT_DIR}/ios_arm64/liblitert_lm.a" \
        -headers "${OUTPUT_DIR}/ios_arm64/headers" \
        -library "${OUTPUT_DIR}/ios_sim_arm64/liblitert_lm.a" \
        -headers "${OUTPUT_DIR}/ios_sim_arm64/headers" \
        -output "${xcfw_path}"

    log "xcframework created at ${xcfw_path}"
    ls -la "${xcfw_path}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}"

    clone_litert_lm
    inject_build_target

    # Build ios_arm64 (device)
    build_for_config "ios_arm64"
    collect_libs "ios_arm64"
    collect_headers "ios_arm64"

    # Build ios_sim_arm64 (simulator on Apple Silicon)
    build_for_config "ios_sim_arm64"
    collect_libs "ios_sim_arm64"
    collect_headers "ios_sim_arm64"

    # Package
    create_xcframework

    log "Done! Output in ${OUTPUT_DIR}"
}

main "$@"
