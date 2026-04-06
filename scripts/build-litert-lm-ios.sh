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

    # Also build proto + CXX bridge targets directly (without the
    # apple_static_library platform transition) so generated headers
    # (.pb.h, .rs.h) land in the predictable bazel-bin path for collection.
    log "Building proto + generated header targets..."
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
        -- \
        -//python/... \
        -//schema/py:* \
        -//kotlin/... 2>/dev/null || true

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

    local bazel_bin
    bazel_bin="$(bazel info bazel-bin --config="${config_label}" 2>/dev/null || true)"
    if [ -z "${bazel_bin}" ]; then
        bazel_bin="$(bazel info bazel-bin 2>/dev/null || echo "bazel-bin")"
    fi
    local bazel_external
    bazel_external="$(bazel info output_base 2>/dev/null)/external"

    # -----------------------------------------------------------------------
    # A) ALL runtime/ source headers (not just a hardcoded list)
    # -----------------------------------------------------------------------
    log "Copying all runtime/ source headers..."
    (find runtime -name '*.h' 2>/dev/null | while read -r f; do
        mkdir -p "${dest_headers}/$(dirname "$f")"
        cp "$f" "${dest_headers}/$f"
    done) || true

    # -----------------------------------------------------------------------
    # B) Generated headers from bazel-out (proto .pb.h, build_config.h, etc.)
    #    apple_static_library does a platform transition, so generated files
    #    land in a different bazel-out/<config>/ subdir than bazel info reports.
    #    Search ALL of bazel-out for runtime/ generated headers.
    # -----------------------------------------------------------------------
    log "Copying generated headers from bazel-bin and bazel-out..."
    local output_base
    output_base="$(bazel info output_base 2>/dev/null)"
    local execroot="${output_base}/execroot/litert_lm"

    # First: collect from the predictable bazel-bin path (proto targets built
    # without apple_static_library transition land here)
    if [ -d "${bazel_bin}/runtime" ]; then
        log "  Copying from bazel-bin/runtime/..."
        (cd "${bazel_bin}" && find runtime -name '*.h' 2>/dev/null | while read -r f; do
            mkdir -p "${dest_headers}/$(dirname "$f")"
            cp "$f" "${dest_headers}/$f" 2>/dev/null || true
        done) || true
    fi

    # Second: also search ALL bazel-out config dirs for generated runtime/ headers
    # (catches anything from the apple_static_library platform transition)
    (find "${execroot}/bazel-out" -path "*/bin/runtime/*.h" \
        -not -path '*-exec-*' \
        -not -path '*/external/*' \
        -not -path '*darwin_arm64-opt/bin/*' \
        -not -path '*_virtual_includes*' \
        -type f \
        2>/dev/null | while read -r f; do
        local rel
        rel=$(echo "$f" | sed -n 's|.*/bin/\(runtime/.*\)|\1|p')
        if [ -n "${rel}" ] && [ ! -f "${dest_headers}/${rel}" ]; then
            mkdir -p "${dest_headers}/$(dirname "$rel")"
            cp "$f" "${dest_headers}/$rel" 2>/dev/null || true
        fi
    done) || true

    # Debug: verify proto headers were found
    local proto_count
    proto_count=$(find "${dest_headers}/runtime/proto" -name '*.pb.h' 2>/dev/null | wc -l | tr -d ' ')
    log "  Found ${proto_count} proto-generated headers"

    # Rust CXX bridge generated headers (e.g. minijinja_template.rs.h)
    log "  Collecting Rust CXX bridge generated headers..."
    (find "${execroot}/bazel-out" -name '*.rs.h' \
        -path '*/bin/runtime/*' \
        -not -path '*-exec-*' \
        -not -path '*darwin_arm64-opt/bin/*' \
        -type f 2>/dev/null | while read -r f; do
        local rel
        rel=$(echo "$f" | sed -n 's|.*/bin/\(runtime/.*\)|\1|p')
        if [ -n "${rel}" ] && [ ! -f "${dest_headers}/${rel}" ]; then
            log "    Found: ${rel}"
            mkdir -p "${dest_headers}/$(dirname "$rel")"
            cp "$f" "${dest_headers}/$rel" 2>/dev/null || true
        fi
    done) || true
    # Also check bazel-bin directly
    (find "${bazel_bin}" -name '*.rs.h' -path '*/runtime/*' -type f 2>/dev/null | while read -r f; do
        local rel="${f#"${bazel_bin}/"}"
        if [ ! -f "${dest_headers}/${rel}" ]; then
            log "    Found in bazel-bin: ${rel}"
            mkdir -p "${dest_headers}/$(dirname "$rel")"
            cp "$f" "${dest_headers}/$rel" 2>/dev/null || true
        fi
    done) || true

    # -----------------------------------------------------------------------
    # C) External dependency headers
    # -----------------------------------------------------------------------

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

    # LiteRT headers (all of them, no limit)
    if [ -d "${bazel_external}/litert" ]; then
        log "Copying LiteRT headers..."
        for subdir in litert tflite; do
            if [ -d "${bazel_external}/litert/${subdir}" ]; then
                (cd "${bazel_external}/litert" && find "${subdir}" -name '*.h' 2>/dev/null | while read -r f; do
                    mkdir -p "${dest_headers}/$(dirname "$f")"
                    cp "$f" "${dest_headers}/$f"
                done) || true
            fi
        done
        # Also copy generated headers from LiteRT's bazel-bin output
        # These may be at: bazel-out/<config>-opt/bin/external/litert/
        local output_base_local
        output_base_local="$(bazel info output_base 2>/dev/null)"
        local execroot_local="${output_base_local}/execroot/litert_lm"
        for litert_genbin in \
            "${execroot_local}/bazel-out/${config_label}-opt/bin/external/litert" \
            "${bazel_bin}/external/litert" \
            "${execroot_local}/bazel-out/ios_arm64-opt/bin/external/litert" \
            "${execroot_local}/bazel-out/ios_sim_arm64-opt/bin/external/litert"; do
            if [ -d "${litert_genbin}" ]; then
                log "Copying LiteRT generated headers from ${litert_genbin}..."
                (cd "${litert_genbin}" && find . -name '*.h' 2>/dev/null | while read -r f; do
                    local rel="${f#./}"
                    mkdir -p "${dest_headers}/$(dirname "$rel")"
                    cp "$f" "${dest_headers}/$rel"
                done) || true
                break  # found one, done
            fi
        done
    fi

    # Broad fallback: find build_config.h anywhere in bazel output.
    # _virtual_includes are dangling symlinks — skip them, find real files only.
    if [ ! -f "${dest_headers}/litert/build_common/build_config.h" ]; then
        log "build_config.h not found yet, searching broadly (real files only)..."
        local found_bc=""
        found_bc=$(find "${output_base}" -name 'build_config.h' \
            -path '*/litert/build_common/*' \
            -not -path '*_virtual_includes*' \
            -type f 2>/dev/null | head -1) || true
        if [ -n "${found_bc}" ]; then
            log "  Found build_config.h at: ${found_bc}"
            mkdir -p "${dest_headers}/litert/build_common"
            cp "${found_bc}" "${dest_headers}/litert/build_common/build_config.h"
        else
            # Last resort: generate a minimal stub
            log "  WARNING: build_config.h not found, generating minimal stub"
            mkdir -p "${dest_headers}/litert/build_common"
            cat > "${dest_headers}/litert/build_common/build_config.h" << 'STUBEOF'
#ifndef THIRD_PARTY_ODML_LITERT_LITERT_BUILD_COMMON_BUILD_CONFIG_H_
#define THIRD_PARTY_ODML_LITERT_LITERT_BUILD_COMMON_BUILD_CONFIG_H_
// Auto-generated stub for iOS xcframework build.
// The real build_config.h is generated by Bazel but lives in _virtual_includes
// symlinks that cannot be dereferenced outside the build tree.
#endif  // THIRD_PARTY_ODML_LITERT_LITERT_BUILD_COMMON_BUILD_CONFIG_H_
STUBEOF
        fi
    fi

    # Copy LiteRT generated headers from bazel-out (non-virtual, real files)
    log "Copying LiteRT generated headers from bazel-out..."
    (find "${execroot}/bazel-out" -path "*/bin/external/litert/*.h" \
        -not -path '*_virtual_includes*' \
        -not -path '*-exec-*' \
        -type f 2>/dev/null | while read -r f; do
        # Extract path relative to external/litert/
        local rel
        rel=$(echo "$f" | sed -n 's|.*/external/litert/\(.*\)|\1|p')
        if [ -n "${rel}" ] && [ ! -f "${dest_headers}/${rel}" ]; then
            mkdir -p "${dest_headers}/$(dirname "$rel")"
            cp "$f" "${dest_headers}/$rel" 2>/dev/null || true
        fi
    done) || true

    # Google protobuf headers
    if [ -d "${bazel_external}/com_google_protobuf/src/google" ]; then
        log "Copying protobuf headers..."
        (cd "${bazel_external}/com_google_protobuf/src" && find google \( -name '*.h' -o -name '*.inc' \) 2>/dev/null | while read -r f; do
            mkdir -p "${dest_headers}/$(dirname "$f")"
            cp "$f" "${dest_headers}/$f"
        done) || true
    fi

    # re2
    if [ -d "${bazel_external}/com_googlesource_code_re2/re2" ]; then
        log "Copying re2 headers..."
        (cd "${bazel_external}/com_googlesource_code_re2" && find re2 -name '*.h' 2>/dev/null | while read -r f; do
            mkdir -p "${dest_headers}/$(dirname "$f")"
            cp "$f" "${dest_headers}/$f"
        done) || true
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
