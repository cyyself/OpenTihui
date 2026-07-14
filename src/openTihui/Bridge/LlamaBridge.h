//
//  LlamaBridge.h
//  openTihui
//
//  Objective-C facade over llama.cpp + libmtmd (multimodal).
//  All C++ interop lives in LlamaBridge.mm so the Swift side stays clean.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Static information about a loaded model.
@interface LMModelInfo : NSObject
@property (nonatomic, copy)   NSString *desc;
@property (nonatomic, assign) uint64_t  sizeBytes;
@property (nonatomic, assign) uint64_t  nParams;
@property (nonatomic, assign) int32_t   nCtxTrain;     // context length the model was trained with
@property (nonatomic, assign) BOOL      supportsVision;
@property (nonatomic, assign) BOOL      supportsAudio;
@property (nonatomic, assign) BOOL      usingGPU;       // GPU layers actually offloaded
@property (nonatomic, copy)   NSString *backend;        // "Metal" or "CPU"
@property (nonatomic, copy)   NSString *chatTemplate;   // GGUF's built-in Jinja template ("" if none)
@property (nonatomic, copy)   NSString *loadNotice;     // informational note from load ("" if none)
@end

/// Sampling / decoding parameters for a single generation.
@interface LMGenerationParams : NSObject
@property (nonatomic, assign) int      maxTokens;
@property (nonatomic, assign) float    temperature;
@property (nonatomic, assign) float    topP;
@property (nonatomic, assign) int      topK;
@property (nonatomic, assign) float    minP;
@property (nonatomic, assign) float    repeatPenalty;
@property (nonatomic, assign) int      repeatLastN;
@property (nonatomic, assign) uint32_t seed;
/// Max tokens of `<think>…</think>` reasoning before it is force-closed
/// (llama-server style reasoning budget). 0 = no limit.
@property (nonatomic, assign) int      thinkBudget;
+ (instancetype)defaults;
@end

typedef void (^LMTokenHandler)(NSString *piece);
typedef void (^LMDoneHandler)(BOOL success, NSString * _Nullable errorMessage, NSString * _Nullable stats);

/// Thread-safety: load/generate/reset must not be called concurrently. The
/// Swift `InferenceEngine` actor serializes all access.
@interface LlamaBridge : NSObject

@property (nonatomic, readonly) BOOL isLoaded;
@property (nonatomic, readonly, nullable) LMModelInfo *modelInfo;
@property (nonatomic, readonly) int nPast;   // tokens currently held in the KV cache
@property (nonatomic, readonly) int nKeep;   // protected prefix (system prompt) length
@property (nonatomic, readonly) int nCtx;    // configured context window

/// Invoked (on the loading thread) with model-load progress in [0, 1].
@property (nonatomic, copy, nullable) void (^onLoadProgress)(float progress);

/// Load a GGUF model and (optionally) a multimodal projector.
/// @param mmprojPath  pass nil for a text-only model.
/// @param nGpuLayers  number of layers to offload to Metal (0 = CPU only).
- (BOOL)loadModelAtPath:(NSString *)modelPath
             mmprojPath:(nullable NSString *)mmprojPath
                   nCtx:(int)nCtx
             nGpuLayers:(int)nGpuLayers
     compressionEnabled:(BOOL)compressionEnabled
                  error:(NSError **)error;

- (void)unload;

/// Recreate the inference context with a new window size, keeping the model and
/// projector in memory (no disk reload). Tries to migrate the existing KV cache
/// into the new context so the conversation needs no replay; `didPreserve` is
/// set to YES when that succeeded (otherwise the cache is empty and the caller
/// should replay). Returns NO only on a hard failure.
- (BOOL)resizeContextTo:(int)nCtx didPreserve:(BOOL *)didPreserve error:(NSError **)error;

/// Clear the KV cache, evaluate the (already chat-formatted) system block and
/// pin it as the protected prefix used during context compression.
/// Pass an empty string for no system prompt.
- (BOOL)resetWithSystemPrompt:(NSString *)formattedSystemPrompt error:(NSError **)error;

/// Evaluate a chat-formatted prompt delta (which may contain media markers,
/// default `<__media__>`) together with any attached media, then stream a
/// completion. Blocks the calling thread until generation finishes; callbacks
/// are invoked on the calling thread.
- (void)generateWithPrompt:(NSString *)promptDelta
                imagePaths:(NSArray<NSString *> *)imagePaths
                audioPaths:(NSArray<NSString *> *)audioPaths
                    params:(LMGenerationParams *)params
                   onToken:(LMTokenHandler)onToken
                    onDone:(LMDoneHandler)onDone;

/// Evaluate a chat-formatted prompt delta (optionally with media) into the KV
/// cache WITHOUT generating. Used to replay a saved conversation's history so a
/// switched-to chat keeps its full context. Returns NO on failure.
- (BOOL)evaluatePrompt:(NSString *)promptDelta
            imagePaths:(NSArray<NSString *> *)imagePaths
            audioPaths:(NSArray<NSString *> *)audioPaths
                 error:(NSError **)error;

/// Request the in-flight generation to stop at the next token boundary.
- (void)requestStop;

/// The media marker that must appear in prompts where media should be spliced in.
+ (NSString *)mediaMarker;

/// Whether the current build/runtime can offload to a GPU (Metal). False in most
/// iOS Simulators, true on real devices.
+ (BOOL)gpuOffloadSupported;

/// Captured llama.cpp / ggml log output (most recent ~256 KB), for the in-app
/// log viewer. Logs are collected from backend init onward.
+ (NSString *)collectedLog;
/// Clear the captured log buffer.
+ (void)clearLog;
/// Append an app-side note to the captured log (shown in Settings ▸ Logs).
+ (void)appendLogNote:(NSString *)note;

@end

NS_ASSUME_NONNULL_END
