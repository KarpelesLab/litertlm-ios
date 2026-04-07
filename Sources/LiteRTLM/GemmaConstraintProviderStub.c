// Stub implementations for GemmaModelConstraintProvider C API.
//
// The real implementation is closed-source and distributed only as a prebuilt
// dynamic library by Google. The upstream ios_arm64 prebuilt is broken
// (tagged as simulator). Since constrained decoding works through the
// open-source llguidance path, these stubs satisfy the linker without
// requiring the closed-source binary.
//
// If Google fixes the prebuilt in the future, this file can be removed and
// the dylib linked instead.

#include <stddef.h>

typedef struct LiteRtLmGemmaModelConstraintProvider
    LiteRtLmGemmaModelConstraintProvider;
typedef struct LiteRtLmConstraint LiteRtLmConstraint;

LiteRtLmGemmaModelConstraintProvider*
LiteRtLmGemmaModelConstraintProvider_Create(
    const char* serialized_sp_model_proto, size_t serialized_sp_model_proto_len,
    const void* options) {
    // Not available — return NULL. Callers handle NULL gracefully.
    return NULL;
}

void LiteRtLmGemmaModelConstraintProvider_Destroy(
    LiteRtLmGemmaModelConstraintProvider* provider) {
    // No-op
}

LiteRtLmConstraint*
LiteRtLmGemmaModelConstraintProvider_CreateConstraintFromTools(
    LiteRtLmGemmaModelConstraintProvider* provider, const char* json_tools_str,
    size_t json_tools_str_len) {
    // Not available — return NULL.
    return NULL;
}

void LiteRtLmConstraint_Destroy(LiteRtLmConstraint* constraint) {
    // No-op
}
