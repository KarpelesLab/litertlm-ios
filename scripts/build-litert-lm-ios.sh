#!/usr/bin/env bash
set -euo pipefail

# Build LiteRT-LM for iOS (arm64 device + arm64 simulator)
# Produces an xcframework with static libraries and headers.

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
# 1. Clone / update LiteRT-LM
# ---------------------------------------------------------------------------
clone_litert_lm() {
    log "Cloning LiteRT-LM ${LITERT_LM_VERSION}..."
    if [ -d "${LITERT_LM_DIR}" ]; then
        rm -rf "${LITERT_LM_DIR}"
    fi
    git clone --depth 1 --branch "${LITERT_LM_VERSION}" "${LITERT_LM_REPO}" "${LITERT_LM_DIR}"
}

# ---------------------------------------------------------------------------
# 2. Build for a given iOS config
# ---------------------------------------------------------------------------
build_for_config() {
    local config="$1"       # e.g. ios_arm64 or ios_sim_arm64
    local cache_dir="$2"

    log "Building for config=${config}..."
    cd "${LITERT_LM_DIR}"

    bazel build \
        --config="${config}" \
        --disk_cache="${cache_dir}" \
        --build_tag_filters=-requires-mac-inputs:hard,-no_mac \
        //runtime/engine:litert_lm_lib \
        -- \
        -//python/... \
        -//schema/py:* \
        -//kotlin/...

    log "Build for ${config} complete."
}

# ---------------------------------------------------------------------------
# 3. Collect static libraries from bazel-bin into a single .a
# ---------------------------------------------------------------------------
collect_libs() {
    local config_label="$1"   # e.g. "ios_arm64"
    local dest_dir="${OUTPUT_DIR}/${config_label}"
    mkdir -p "${dest_dir}"

    cd "${LITERT_LM_DIR}"

    log "Collecting .a files for ${config_label}..."

    # Resolve the actual bazel-bin path (it's a symlink)
    local bazel_bin
    bazel_bin="$(bazel info bazel-bin 2>/dev/null || echo "bazel-bin")"

    # Find all .a files, excluding test and benchmark artifacts
    local -a archives=()
    while IFS= read -r -d '' f; do
        archives+=("$f")
    done < <(find "${bazel_bin}" -name '*.a' \
        -not -path '*_test*' \
        -not -path '*benchmark*' \
        -not -path '*python*' \
        -not -path '*kotlin*' \
        -not -path '*schema/py*' \
        -print0 2>/dev/null)

    if [ ${#archives[@]} -eq 0 ]; then
        echo "ERROR: No .a files found in ${bazel_bin}" >&2
        exit 1
    fi

    log "Found ${#archives[@]} archives, combining..."

    # Combine all archives into one
    libtool -static -o "${dest_dir}/liblitert_lm.a" "${archives[@]}" 2>/dev/null

    log "Combined library: $(du -h "${dest_dir}/liblitert_lm.a" | cut -f1)"
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
    bazel_bin="$(bazel info bazel-bin 2>/dev/null || echo "bazel-bin")"
    if [ -d "${bazel_bin}/runtime/proto" ]; then
        mkdir -p "${dest_headers}/runtime/proto"
        find "${bazel_bin}/runtime/proto" -name '*.h' -exec cp {} "${dest_headers}/runtime/proto/" \; 2>/dev/null || true
    fi

    # Copy abseil headers from the external workspace
    local bazel_external
    bazel_external="$(bazel info output_base 2>/dev/null)/external"

    # Abseil
    if [ -d "${bazel_external}/com_google_absl" ]; then
        log "Copying abseil headers..."
        mkdir -p "${dest_headers}/absl"
        (cd "${bazel_external}/com_google_absl" && find absl -name '*.h' -o -name '*.inc' | while read -r f; do
            mkdir -p "${dest_headers}/$(dirname "$f")"
            cp "$f" "${dest_headers}/$f"
        done)
    fi

    # nlohmann/json
    if [ -d "${bazel_external}/nlohmann_json" ]; then
        log "Copying nlohmann/json headers..."
        (cd "${bazel_external}/nlohmann_json" && find . -name '*.hpp' -o -name '*.h' | while read -r f; do
            mkdir -p "${dest_headers}/$(dirname "$f")"
            cp "$f" "${dest_headers}/$f"
        done)
    fi

    # LiteRT headers
    if [ -d "${bazel_external}/litert" ]; then
        log "Copying LiteRT headers..."
        mkdir -p "${dest_headers}/litert"
        (cd "${bazel_external}/litert" && find litert -name '*.h' | head -500 | while read -r f; do
            mkdir -p "${dest_headers}/$(dirname "$f")"
            cp "$f" "${dest_headers}/$f"
        done)
        # Also copy tflite headers if present
        if [ -d "${bazel_external}/litert/tflite" ]; then
            (cd "${bazel_external}/litert" && find tflite -name '*.h' | head -200 | while read -r f; do
                mkdir -p "${dest_headers}/$(dirname "$f")"
                cp "$f" "${dest_headers}/$f"
            done)
        fi
    fi

    local header_count
    header_count=$(find "${dest_headers}" -name '*.h' -o -name '*.hpp' -o -name '*.inc' | wc -l)
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
