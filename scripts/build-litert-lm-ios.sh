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

# Bazel disk cache directories (separate per arch to avoid conflicts)
CACHE_ARM64="${HOME}/.cache/bazel-ios-arm64"
CACHE_SIM="${HOME}/.cache/bazel-ios-sim"

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
    local cache_dir="$2"

    log "Building for config=${config}..."
    cd "${LITERT_LM_DIR}"

    # apple_static_library handles platform/arch internally, but we still
    # pass the config so that the .bazelrc iOS flags apply (min OS, C++20, etc.)
    bazel build \
        --config="${config}" \
        --disk_cache="${cache_dir}" \
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

    # apple_static_library output goes to bazel-bin/ios_package/
    # The output name follows: LiteRTLM_<lipo-platform>.a
    # Try multiple possible output paths
    local bazel_bin
    bazel_bin="$(bazel info bazel-bin --config="${config_label}" 2>/dev/null || true)"

    # If that didn't work, try without config (apple_static_library may use host bin)
    if [ -z "${bazel_bin}" ] || [ ! -d "${bazel_bin}" ]; then
        bazel_bin="$(bazel info bazel-bin 2>/dev/null || echo "bazel-bin")"
    fi

    log "Looking in bazel-bin: ${bazel_bin}"

    # apple_static_library produces output in bazel-bin/ios_package/
    # The .a might be named LiteRTLM_lipo.a or similar
    local found_lib=""

    # Search for the output .a file
    while IFS= read -r -d '' f; do
        if [ -z "${found_lib}" ]; then
            found_lib="$f"
        fi
    done < <(find "${bazel_bin}/ios_package" -name '*.a' -print0 2>/dev/null)

    # Broader search if not found in expected location
    if [ -z "${found_lib}" ]; then
        log "Not found in ios_package/, searching broader..."
        local output_base
        output_base="$(bazel info output_base 2>/dev/null)"
        while IFS= read -r -d '' f; do
            if [ -z "${found_lib}" ]; then
                found_lib="$f"
            fi
        done < <(find "${output_base}/execroot" -path "*/ios_package/*" -name '*.a' \
            -not -path '*-exec-*' -print0 2>/dev/null)
    fi

    # Even broader: find any LiteRTLM*.a
    if [ -z "${found_lib}" ]; then
        log "Searching all of bazel-out for LiteRTLM..."
        local output_base
        output_base="$(bazel info output_base 2>/dev/null)"
        while IFS= read -r -d '' f; do
            log "  candidate: $f ($(du -h "$f" | cut -f1))"
            if [ -z "${found_lib}" ]; then
                found_lib="$f"
            fi
        done < <(find "${output_base}/execroot" -name 'LiteRTLM*' -name '*.a' \
            -not -path '*-exec-*' -print0 2>/dev/null)
    fi

    if [ -z "${found_lib}" ]; then
        echo "ERROR: Could not find apple_static_library output" >&2
        echo "DEBUG: Contents of bazel-bin/ios_package/:" >&2
        ls -laR "${bazel_bin}/ios_package/" 2>/dev/null >&2 || echo "  (directory not found)" >&2
        echo "DEBUG: All .a files in output:" >&2
        local output_base
        output_base="$(bazel info output_base 2>/dev/null)"
        find "${output_base}/execroot" -name "*.a" -not -path '*-exec-*' 2>/dev/null | head -30 >&2 || true
        exit 1
    fi

    log "Found library: ${found_lib} ($(du -h "${found_lib}" | cut -f1))"
    cp "${found_lib}" "${dest_dir}/liblitert_lm.a"

    # Verify it's the right architecture
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
    if [ -d "${bazel_external}/com_google_absl" ]; then
        log "Copying abseil headers..."
        (cd "${bazel_external}/com_google_absl" && find absl -name '*.h' -o -name '*.inc' | while read -r f; do
            mkdir -p "${dest_headers}/$(dirname "$f")"
            cp "$f" "${dest_headers}/$f"
        done)
    fi

    # nlohmann/json
    if [ -d "${bazel_external}/nlohmann_json" ]; then
        log "Copying nlohmann/json headers..."
        (cd "${bazel_external}/nlohmann_json" && find include -name '*.hpp' -o -name '*.h' 2>/dev/null | while read -r f; do
            mkdir -p "${dest_headers}/$(dirname "$f")"
            cp "$f" "${dest_headers}/$f"
        done)
        # Also copy top-level headers
        (cd "${bazel_external}/nlohmann_json" && find . -maxdepth 2 -name '*.hpp' -o -name '*.h' 2>/dev/null | while read -r f; do
            mkdir -p "${dest_headers}/$(dirname "$f")"
            cp "$f" "${dest_headers}/$f"
        done)
    fi

    # LiteRT headers
    if [ -d "${bazel_external}/litert" ]; then
        log "Copying LiteRT headers..."
        (cd "${bazel_external}/litert" && find litert tflite -name '*.h' 2>/dev/null | head -700 | while read -r f; do
            mkdir -p "${dest_headers}/$(dirname "$f")"
            cp "$f" "${dest_headers}/$f"
        done)
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
    build_for_config "ios_arm64" "${CACHE_ARM64}"
    collect_libs "ios_arm64"
    collect_headers "ios_arm64"

    # Build ios_sim_arm64 (simulator on Apple Silicon)
    build_for_config "ios_sim_arm64" "${CACHE_SIM}"
    collect_libs "ios_sim_arm64"
    collect_headers "ios_sim_arm64"

    # Package
    create_xcframework

    log "Done! Output in ${OUTPUT_DIR}"
}

main "$@"
