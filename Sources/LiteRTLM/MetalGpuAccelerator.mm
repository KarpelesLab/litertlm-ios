// Metal GPU Accelerator Adapter for LiteRT-LM
//
// Bridges the open-source TFLite Metal GPU delegate into LiteRT-LM's
// accelerator plugin system. Google's GPU accelerator is closed-source,
// but the underlying Metal delegate that does the actual GPU compute work
// IS open-source in the LiteRT repo.
//
// This file:
// 1. Implements LiteRtAcceleratorDef (the plugin interface)
// 2. Wraps TFLGpuDelegateCreate/Delete from TFLite's Metal delegate
// 3. Overrides the global LiteRtStaticLinkedAcceleratorGpuDef pointer
//    so the runtime finds our adapter instead of trying to dlopen a .dylib

#import <Metal/Metal.h>

// LiteRT accelerator definition (internal API)
#include "litert/c/internal/litert_accelerator_def.h"
#include "litert/c/litert_common.h"
#include "litert/c/litert_environment_options.h"

// TFLite Metal GPU delegate (open-source)
#include "tflite/delegates/gpu/metal_delegate.h"

// ---------------------------------------------------------------------------
// Accelerator callback implementations
// ---------------------------------------------------------------------------

static LiteRtStatus MetalGpu_GetName(LiteRtAccelerator accelerator,
                                     const char** name) {
    *name = "MetalGpu";
    return kLiteRtStatusOk;
}

static LiteRtStatus MetalGpu_GetVersion(LiteRtAccelerator accelerator,
                                        LiteRtApiVersion* version) {
    version->major = 1;
    version->minor = 0;
    version->patch = 0;
    return kLiteRtStatusOk;
}

static LiteRtStatus MetalGpu_GetHardwareSupport(
    LiteRtAccelerator accelerator,
    LiteRtHwAcceleratorSet* supported_hardware) {
    *supported_hardware = kLiteRtHwAcceleratorGpu;
    return kLiteRtStatusOk;
}

static LiteRtStatus MetalGpu_IsJitCompilation(
    LiteRtAccelerator accelerator, bool* does_jit_compilation) {
    // Metal delegate does JIT compilation of shaders
    *does_jit_compilation = true;
    return kLiteRtStatusOk;
}

static LiteRtStatus MetalGpu_CreateDelegate(
    LiteRtRuntimeContext* runtime_context,
    LiteRtEnvironment env,
    LiteRtAccelerator accelerator,
    LiteRtOptions options,
    LiteRtDelegateWrapper* delegate_wrapper) {

    // Check Metal availability
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        return kLiteRtStatusErrorRuntimeFailure;
    }

    // Create TFLite Metal delegate with optimized settings for LLM inference
    TFLGpuDelegateOptions tfl_opts = TFLGpuDelegateOptionsDefault();
    tfl_opts.allow_precision_loss = true;    // FP16 for performance
    tfl_opts.wait_type = TFLGpuDelegateWaitTypePassive;
    tfl_opts.enable_quantization = true;     // Support quantized models

    TfLiteDelegate* delegate = TFLGpuDelegateCreate(&tfl_opts);
    if (!delegate) {
        return kLiteRtStatusErrorRuntimeFailure;
    }

    *delegate_wrapper = (LiteRtDelegateWrapper)delegate;
    return kLiteRtStatusOk;
}

static void MetalGpu_DestroyDelegate(LiteRtRuntimeContext* runtime_context,
                                     LiteRtDelegateWrapper delegate_wrapper) {
    if (delegate_wrapper) {
        TFLGpuDelegateDelete((TfLiteDelegate*)delegate_wrapper);
    }
}

static LiteRtStatus MetalGpu_StartMetrics(LiteRtRuntimeContext* runtime_context,
                                          LiteRtDelegateWrapper delegate,
                                          int detail_level) {
    return kLiteRtStatusOk;
}

static LiteRtStatus MetalGpu_StopMetrics(LiteRtRuntimeContext* runtime_context,
                                         LiteRtDelegateWrapper delegate,
                                         LiteRtMetrics metrics) {
    return kLiteRtStatusOk;
}

// ---------------------------------------------------------------------------
// Accelerator definition struct
// ---------------------------------------------------------------------------

static LiteRtAcceleratorDef kMetalGpuAcceleratorDef = {
    .version = LITERT_ACCELERATOR_DEF_CURRENT_VERSION,

    .get_name = MetalGpu_GetName,
    .get_version = MetalGpu_GetVersion,
    .get_hardware_support = MetalGpu_GetHardwareSupport,
    .is_tflite_delegate_responsible_for_jit_compilation = MetalGpu_IsJitCompilation,
    .create_delegate = MetalGpu_CreateDelegate,
    .destroy_delegate = MetalGpu_DestroyDelegate,
    .start_metrics_collection = MetalGpu_StartMetrics,
    .stop_metrics_collection = MetalGpu_StopMetrics,

    // Custom tensor buffer ops — not needed for basic Metal delegate
    .create_func = nullptr,
    .destroy_func = nullptr,
    .lock_func = nullptr,
    .unlock_func = nullptr,
    .clear_func = nullptr,
    .import_func = nullptr,

    // Device/queue tags — not used
    .device_tag = kLiteRtEnvOptionTagMetalDevice,
    .queue_tag = kLiteRtEnvOptionTagMetalCommandQueue,

    // Supported buffer types
    .num_supported_buffer_types = 0,
    .supported_buffer_types = {},
};

// ---------------------------------------------------------------------------
// Override the global static-linked accelerator pointer
//
// gpu_registry.cc defines:
//   extern "C" LiteRtAcceleratorDef* LiteRtStaticLinkedAcceleratorGpuDef = nullptr;
//
// We provide a constructor that sets it to our Metal adapter before main().
// This way, when the LiteRT-LM runtime checks for a statically linked GPU
// accelerator, it finds ours.
// ---------------------------------------------------------------------------

__attribute__((constructor))
static void RegisterMetalGpuAccelerator(void) {
    extern LiteRtAcceleratorDef* LiteRtStaticLinkedAcceleratorGpuDef;
    LiteRtStaticLinkedAcceleratorGpuDef = &kMetalGpuAcceleratorDef;
}
