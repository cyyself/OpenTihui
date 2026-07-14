//
//  LlamaBridge.mm
//  openTihui
//

#import "LlamaBridge.h"

#import <llama/llama.h>
#import <llama/mtmd.h>
#import <llama/mtmd-helper.h>
#import <Metal/Metal.h>

#include <vector>
#include <string>
#include <atomic>
#include <cstring>
#include <chrono>
#import <os/lock.h>

#pragma mark - Small value types

static bool llamachat_load_progress(float progress, void *user_data) {
    LlamaBridge *bridge = (__bridge LlamaBridge *)user_data;
    void (^handler)(float) = bridge.onLoadProgress;
    if (handler) handler(progress);
    return true;   // continue loading
}

#pragma mark - Log capture

// llama.cpp/ggml route their logs through a single callback. We append into a
// capped ring buffer the app can show in Settings ▸ Logs, and still echo to
// stderr so the Xcode console keeps working.
static NSMutableString *gLogBuffer;
static os_unfair_lock   gLogLock = OS_UNFAIR_LOCK_INIT;
static const NSUInteger kLogCap  = 256 * 1024;   // keep the most recent ~256 KB

static void llamachat_log_capture(enum ggml_log_level level, const char *text, void *user) {
    (void)level; (void)user;
    if (!text) return;
    NSString *chunk = [NSString stringWithUTF8String:text];
    if (!chunk) return;
    os_unfair_lock_lock(&gLogLock);
    if (!gLogBuffer) gLogBuffer = [NSMutableString string];
    [gLogBuffer appendString:chunk];
    if (gLogBuffer.length > kLogCap) {
        [gLogBuffer deleteCharactersInRange:NSMakeRange(0, gLogBuffer.length - kLogCap)];
    }
    os_unfair_lock_unlock(&gLogLock);
    fputs(text, stderr);
}

@implementation LMModelInfo
@end

@implementation LMGenerationParams
+ (instancetype)defaults {
    LMGenerationParams *p = [LMGenerationParams new];
    p.maxTokens     = 512;
    p.temperature   = 0.7f;
    p.topP          = 0.95f;
    p.topK          = 40;
    p.minP          = 0.05f;
    p.repeatPenalty = 1.1f;
    p.repeatLastN   = 64;
    p.seed          = LLAMA_DEFAULT_SEED;
    p.thinkBudget   = 0;
    return p;
}
@end

#pragma mark - LlamaBridge

@implementation LlamaBridge {
    llama_model   *_model;
    llama_context *_lctx;
    const llama_vocab *_vocab;
    mtmd_context  *_mctx;          // null for text-only models

    int  _nPastInternal;
    int  _nKeepInternal;
    int  _nCtxInternal;
    int  _nGpuLayersUsed;
    BOOL _compressionEnabled;
    BOOL _canShift;               // false for M-RoPE models (Qwen-VL): seq_add unsupported

    std::atomic<bool> _stopRequested;

    // accumulates raw bytes from token pieces until they form valid UTF-8
    std::vector<char> _pieceBuffer;
}

+ (NSString *)mediaMarker {
    return [NSString stringWithUTF8String:mtmd_default_marker()];
}

+ (BOOL)gpuOffloadSupported {
    if (!llama_supports_gpu_offload()) return NO;
#if TARGET_OS_SIMULATOR
    return NO;   // ggml-metal is unreliable in the Simulator
#else
    // `llama_supports_gpu_offload()` only reports that a Metal backend exists, not
    // that the GPU is capable enough. ggml-metal's kernels need SIMD-group ops that
    // are reliable only on Apple7 GPUs (A14 / M1 and newer); older GPUs (e.g. A12Z)
    // compile the pipelines but then hit GPU address faults. ggml-metal doesn't
    // refuse such devices itself, so we gate here and fall back to CPU — same
    // threshold as ggml-org/whisper.cpp#1547.
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    if (!dev) return NO;
    BOOL capable = [dev supportsFamily:MTLGPUFamilyApple7];
    if (!capable) {
        NSString *note = @"openTihui: GPU below Apple7 — using CPU to avoid Metal faults.\n";
        os_unfair_lock_lock(&gLogLock);
        if (!gLogBuffer) gLogBuffer = [NSMutableString string];
        [gLogBuffer appendString:note];
        os_unfair_lock_unlock(&gLogLock);
        fputs(note.UTF8String, stderr);
    }
    return capable;
#endif
}

+ (NSString *)collectedLog {
    os_unfair_lock_lock(&gLogLock);
    NSString *copy = gLogBuffer ? [gLogBuffer copy] : @"";
    os_unfair_lock_unlock(&gLogLock);
    return copy;
}

+ (void)clearLog {
    os_unfair_lock_lock(&gLogLock);
    [gLogBuffer setString:@""];
    os_unfair_lock_unlock(&gLogLock);
}

- (instancetype)init {
    if (self = [super init]) {
        _model = nullptr;
        _lctx = nullptr;
        _mctx = nullptr;
        _vocab = nullptr;
        _stopRequested = false;
    }
    return self;
}

- (void)dealloc {
    [self unload];
}

- (BOOL)isLoaded { return _model != nullptr && _lctx != nullptr; }
- (int)nPast    { return _nPastInternal; }
- (int)nKeep    { return _nKeepInternal; }
- (int)nCtx     { return _nCtxInternal; }

#pragma mark Loading

- (BOOL)loadModelAtPath:(NSString *)modelPath
             mmprojPath:(nullable NSString *)mmprojPath
                   nCtx:(int)nCtx
             nGpuLayers:(int)nGpuLayers
     compressionEnabled:(BOOL)compressionEnabled
                  error:(NSError **)error {
    [self unload];

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        llama_log_set(llamachat_log_capture, NULL);   // capture llama + ggml logs
        llama_backend_init();
    });

    _compressionEnabled = compressionEnabled;

    // ---- model ----
    // Only request GPU offload if the runtime actually supports it (e.g. real
    // device); otherwise force CPU so the Simulator doesn't silently mislead.
    if (nGpuLayers > 0 && !llama_supports_gpu_offload()) {
        nGpuLayers = 0;
    }
    _nGpuLayersUsed = nGpuLayers;

    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = nGpuLayers;
    if (self.onLoadProgress) {
        mparams.progress_callback = llamachat_load_progress;
        mparams.progress_callback_user_data = (__bridge void *)self;
    }

    _model = llama_model_load_from_file(modelPath.fileSystemRepresentation, mparams);
    if (!_model) {
        [self failWith:error msg:@"Failed to load model file."];
        return NO;
    }
    _vocab = llama_model_get_vocab(_model);

    // ---- context ----
    int n_threads = (int)MAX(1, MIN(8, (int)[NSProcessInfo processInfo].processorCount - 2));
    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx          = (uint32_t)nCtx;
    cparams.n_batch        = 512;
    cparams.n_threads      = n_threads;
    cparams.n_threads_batch = n_threads;

    _lctx = llama_init_from_model(_model, cparams);
    if (!_lctx) {
        [self failWith:error msg:@"Failed to create inference context."];
        [self unload];
        return NO;
    }
    _nCtxInternal = (int)llama_n_ctx(_lctx);
    _nPastInternal = 0;
    _nKeepInternal = 0;

    // ---- multimodal projector (optional) ----
    if (mmprojPath.length > 0) {
        mtmd_context_params mp = mtmd_context_params_default();
        mp.use_gpu        = (nGpuLayers > 0);
        mp.print_timings  = false;
        mp.n_threads      = n_threads;
        mp.media_marker   = mtmd_default_marker();
        mp.warmup         = false;   // skip the heavy warmup encode so loading stays light
        _mctx = mtmd_init_from_file(mmprojPath.fileSystemRepresentation, _model, mp);
        if (!_mctx) {
            [self failWith:error msg:@"Failed to load multimodal projector (mmproj)."];
            [self unload];
            return NO;
        }
    }

    // Context-shift compaction uses llama_memory_seq_add, which ggml only
    // supports when n_pos_per_embd == 1. M-RoPE models (e.g. Qwen-VL) use
    // multi-dimensional positions, so shifting must be disabled for them.
    _canShift = _mctx ? !mtmd_decode_use_mrope(_mctx) : YES;

    return YES;
}

- (BOOL)resizeContextTo:(int)nCtx didPreserve:(BOOL *)didPreserve error:(NSError **)error {
    if (didPreserve) *didPreserve = NO;
    if (!_model) { [self failWith:error msg:@"No model loaded."]; return NO; }
    if (nCtx == _nCtxInternal) { if (didPreserve) *didPreserve = YES; return YES; }

    // Serialize the current KV cache (seq 0) so it can be restored after resize,
    // but only if the new window is large enough to hold the cached tokens.
    std::vector<uint8_t> state;
    bool tryPreserve = (_nPastInternal > 0 && nCtx >= _nPastInternal);
    if (tryPreserve) {
        size_t sz = llama_state_seq_get_size(_lctx, 0);
        state.resize(sz);
        size_t written = llama_state_seq_get_data(_lctx, state.data(), sz, 0);
        if (written == 0) tryPreserve = false;
    }

    int n_threads = (int)MAX(1, MIN(8, (int)[NSProcessInfo processInfo].processorCount - 2));
    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx           = (uint32_t)nCtx;
    cparams.n_batch         = 512;
    cparams.n_threads       = n_threads;
    cparams.n_threads_batch = n_threads;

    llama_context *newCtx = llama_init_from_model(_model, cparams);
    if (!newCtx) { [self failWith:error msg:@"Failed to resize context."]; return NO; }

    llama_context *old = _lctx;
    _lctx = newCtx;
    if (old) llama_free(old);
    _nCtxInternal = (int)llama_n_ctx(_lctx);
    _pieceBuffer.clear();

    if (tryPreserve) {
        size_t read = llama_state_seq_set_data(_lctx, state.data(), state.size(), 0);
        if (read > 0) {
            // KV migrated; positions/counters stay as they were — no replay needed.
            if (didPreserve) *didPreserve = YES;
            return YES;
        }
    }
    // Could not migrate: start from an empty cache (caller replays).
    _nPastInternal = 0;
    _nKeepInternal = 0;
    return YES;
}

- (void)unload {
    // Null the pointers *before* freeing so a concurrent reader (e.g. the UI
    // thread) never observes a dangling non-null pointer mid-free.
    mtmd_context  *mctx  = _mctx;  _mctx  = nullptr;
    llama_context *lctx  = _lctx;  _lctx  = nullptr;
    llama_model   *model = _model; _model = nullptr;
    _vocab = nullptr;
    if (mctx)  mtmd_free(mctx);
    if (lctx)  llama_free(lctx);
    if (model) llama_model_free(model);
    _nPastInternal = _nKeepInternal = _nCtxInternal = 0;
    _pieceBuffer.clear();
}

- (LMModelInfo *)modelInfo {
    if (!_model) return nil;
    LMModelInfo *info = [LMModelInfo new];
    char buf[256] = {0};
    llama_model_desc(_model, buf, sizeof(buf));
    info.desc       = [NSString stringWithUTF8String:buf] ?: @"";
    info.sizeBytes  = llama_model_size(_model);
    info.nParams    = llama_model_n_params(_model);
    info.nCtxTrain  = llama_model_n_ctx_train(_model);
    info.supportsVision = _mctx ? mtmd_support_vision(_mctx) : NO;
    info.supportsAudio  = _mctx ? mtmd_support_audio(_mctx)  : NO;
    info.usingGPU       = (_nGpuLayersUsed > 0);
    info.backend        = info.usingGPU ? @"Metal" : @"CPU";
    const char *tmpl    = llama_model_chat_template(_model, NULL);
    info.chatTemplate   = tmpl ? ([NSString stringWithUTF8String:tmpl] ?: @"") : @"";
    return info;
}

#pragma mark Helpers

- (void)failWith:(NSError **)error msg:(NSString *)msg {
    if (error) {
        *error = [NSError errorWithDomain:@"LlamaBridge" code:1
                                 userInfo:@{NSLocalizedDescriptionKey: msg ?: @"Unknown error"}];
    }
}

- (std::vector<llama_token>)tokenize:(NSString *)text addBos:(BOOL)addBos {
    const char *cstr = text.UTF8String;
    int n = (int)strlen(cstr);
    int capacity = n + (addBos ? 1 : 0) + 2;
    std::vector<llama_token> tokens(capacity);
    int count = llama_tokenize(_vocab, cstr, n, tokens.data(), capacity, addBos, true);
    if (count < 0) {
        tokens.resize(-count);
        count = llama_tokenize(_vocab, cstr, n, tokens.data(), (int)tokens.size(), addBos, true);
    }
    tokens.resize(MAX(count, 0));
    return tokens;
}

/// Decode a flat list of tokens, advancing _nPastInternal. Sets logits on the
/// final token when `wantLogits` is true. Returns NO on decode failure.
- (BOOL)decodeTokens:(const std::vector<llama_token> &)tokens wantLogits:(BOOL)wantLogits {
    const int n_batch = 512;
    int total = (int)tokens.size();
    for (int start = 0; start < total; start += n_batch) {
        int count = MIN(n_batch, total - start);

        if (![self ensureRoomFor:count]) return NO;

        llama_batch batch = llama_batch_init(count, 0, 1);
        for (int i = 0; i < count; i++) {
            int idx = batch.n_tokens;
            batch.token[idx]    = tokens[start + i];
            batch.pos[idx]      = _nPastInternal + i;
            batch.n_seq_id[idx] = 1;
            batch.seq_id[idx][0] = 0;
            batch.logits[idx]   = 0;
            batch.n_tokens++;
        }
        bool lastChunk = (start + count >= total);
        if (wantLogits && lastChunk) {
            batch.logits[batch.n_tokens - 1] = 1;
        }
        int rc = llama_decode(_lctx, batch);
        llama_batch_free(batch);
        if (rc != 0) return NO;
        _nPastInternal += count;
    }
    return YES;
}

/// Make room in the KV cache for `nIncoming` more tokens, compressing the
/// middle of the context if compression is enabled. Returns NO if there is no
/// way to fit them.
- (BOOL)ensureRoomFor:(int)nIncoming {
    if (_nPastInternal + nIncoming <= _nCtxInternal) return YES;
    // M-RoPE models can't be position-shifted; let the caller handle the overflow
    // (the app compacts by dropping old turns and replaying).
    if (!_compressionEnabled || !_canShift) return NO;

    int nKeep = MAX(_nKeepInternal, 0);
    llama_memory_t mem = llama_get_memory(_lctx);
    while (_nPastInternal + nIncoming > _nCtxInternal) {
        int n_left = _nPastInternal - nKeep;
        int n_discard = n_left / 2;
        if (n_discard <= 0) break;
        llama_memory_seq_rm (mem, 0, nKeep, nKeep + n_discard);
        llama_memory_seq_add(mem, 0, nKeep + n_discard, _nPastInternal, -n_discard);
        _nPastInternal -= n_discard;
    }
    return (_nPastInternal + nIncoming <= _nCtxInternal);
}

#pragma mark Reset / system prompt

- (BOOL)resetWithSystemPrompt:(NSString *)formattedSystemPrompt error:(NSError **)error {
    if (![self isLoaded]) { [self failWith:error msg:@"No model loaded."]; return NO; }

    llama_memory_clear(llama_get_memory(_lctx), true);
    _nPastInternal = 0;
    _nKeepInternal = 0;
    _pieceBuffer.clear();

    if (formattedSystemPrompt.length > 0) {
        std::vector<llama_token> toks = [self tokenize:formattedSystemPrompt addBos:YES];
        if (!toks.empty()) {
            if (![self decodeTokens:toks wantLogits:NO]) {
                [self failWith:error msg:@"Failed to evaluate system prompt."];
                return NO;
            }
        }
    }
    _nKeepInternal = _nPastInternal;   // protect the system prefix during compression
    return YES;
}

#pragma mark Evaluation (prefill)

/// Shared prompt-evaluation used by both generation and history replay.
- (BOOL)evalPrompt:(NSString *)promptDelta
        imagePaths:(NSArray<NSString *> *)imagePaths
        audioPaths:(NSArray<NSString *> *)audioPaths
        wantLogits:(BOOL)wantLogits
             error:(NSError **)error {
    NSArray<NSString *> *media = [imagePaths arrayByAddingObjectsFromArray:audioPaths];
    if (media.count > 0) {
        return [self evalMultimodal:promptDelta media:media error:error];
    }
    std::vector<llama_token> toks = [self tokenize:promptDelta addBos:(_nPastInternal == 0)];
    if (![self decodeTokens:toks wantLogits:wantLogits]) {
        [self failWith:error msg:@"Context is full and compression is disabled, or evaluation failed."];
        return NO;
    }
    return YES;
}

- (BOOL)evaluatePrompt:(NSString *)promptDelta
            imagePaths:(NSArray<NSString *> *)imagePaths
            audioPaths:(NSArray<NSString *> *)audioPaths
                 error:(NSError **)error {
    if (![self isLoaded]) { [self failWith:error msg:@"No model loaded."]; return NO; }
    _pieceBuffer.clear();
    return [self evalPrompt:promptDelta imagePaths:imagePaths audioPaths:audioPaths wantLogits:NO error:error];
}

#pragma mark Generation

- (void)requestStop { _stopRequested = true; }

- (void)generateWithPrompt:(NSString *)promptDelta
                imagePaths:(NSArray<NSString *> *)imagePaths
                audioPaths:(NSArray<NSString *> *)audioPaths
                    params:(LMGenerationParams *)params
                   onToken:(LMTokenHandler)onToken
                    onDone:(LMDoneHandler)onDone {
    _stopRequested = false;
    _pieceBuffer.clear();

    if (![self isLoaded]) {
        if (onDone) onDone(NO, @"No model loaded.", nil);
        return;
    }

    if (![self evalPrompt:promptDelta imagePaths:imagePaths audioPaths:audioPaths wantLogits:YES error:nil]) {
        if (onDone) onDone(NO, @"Context is full and compression is disabled, or evaluation failed.", nil);
        return;
    }

    // ---- sampler chain ----
    llama_sampler *smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    if (params.repeatPenalty != 1.0f) {
        llama_sampler_chain_add(smpl, llama_sampler_init_penalties(params.repeatLastN, params.repeatPenalty, 0.0f, 0.0f));
    }
    if (params.temperature <= 0.0f) {
        llama_sampler_chain_add(smpl, llama_sampler_init_greedy());
    } else {
        if (params.topK > 0)      llama_sampler_chain_add(smpl, llama_sampler_init_top_k(params.topK));
        if (params.topP < 1.0f)   llama_sampler_chain_add(smpl, llama_sampler_init_top_p(params.topP, 1));
        if (params.minP > 0.0f)   llama_sampler_chain_add(smpl, llama_sampler_init_min_p(params.minP, 1));
        llama_sampler_chain_add(smpl, llama_sampler_init_temp(params.temperature));
        llama_sampler_chain_add(smpl, llama_sampler_init_dist(params.seed));
    }

    int    nGenerated = 0;
    double tStart = [self nowMillis];

    // Reasoning budget: cap the length of the <think>…</think> block.
    const bool enforceThink = params.thinkBudget > 0;
    bool thinkOpen = false, thinkClosed = false;
    std::string genAccum;

    while (nGenerated < params.maxTokens && !_stopRequested) {
        llama_token tok = llama_sampler_sample(smpl, _lctx, -1);

        if (llama_vocab_is_eog(_vocab, tok)) break;

        NSString *piece = [self pieceForToken:tok];
        if (piece.length > 0 && onToken) onToken(piece);

        // feed the sampled token back in
        if (![self ensureRoomFor:1]) break;
        llama_batch batch = llama_batch_init(1, 0, 1);
        batch.token[0]     = tok;
        batch.pos[0]       = _nPastInternal;
        batch.n_seq_id[0]  = 1;
        batch.seq_id[0][0] = 0;
        batch.logits[0]    = 1;
        batch.n_tokens     = 1;
        int rc = llama_decode(_lctx, batch);
        llama_batch_free(batch);
        if (rc != 0) break;
        _nPastInternal += 1;
        nGenerated += 1;

        // Force-close an over-budget reasoning block, then continue with the answer.
        if (enforceThink && !thinkClosed) {
            if (piece.length > 0) genAccum += piece.UTF8String;
            if (!thinkOpen && genAccum.find("<think>") != std::string::npos) thinkOpen = true;
            if (thinkOpen && genAccum.find("</think>") != std::string::npos) {
                thinkClosed = true;
            } else if (thinkOpen && nGenerated >= params.thinkBudget) {
                NSString *close = @"\n</think>\n\n";
                if (onToken) onToken(close);
                std::vector<llama_token> ct = [self tokenize:close addBos:NO];
                [self decodeTokens:ct wantLogits:YES];
                thinkClosed = true;
            }
        }
    }

    llama_sampler_free(smpl);

    double tEnd = [self nowMillis];
    double secs = (tEnd - tStart) / 1000.0;
    double tps = secs > 0 ? nGenerated / secs : 0;
    NSString *stats = [NSString stringWithFormat:@"%d tokens · %.1f tok/s · ctx %d/%d",
                       nGenerated, tps, _nPastInternal, _nCtxInternal];
    if (onDone) onDone(YES, nil, stats);
}

- (BOOL)evalMultimodal:(NSString *)promptDelta media:(NSArray<NSString *> *)mediaPaths error:(NSError **)error {
    if (!_mctx) { [self failWith:error msg:@"Model has no multimodal support."]; return NO; }

    std::vector<mtmd_bitmap *> bitmaps;
    bitmaps.reserve(mediaPaths.count);
    for (NSString *path in mediaPaths) {
        mtmd_helper_bitmap_wrapper w =
            mtmd_helper_bitmap_init_from_file(_mctx, path.fileSystemRepresentation, false);
        if (!w.bitmap) {
            for (auto *b : bitmaps) mtmd_bitmap_free(b);
            [self failWith:error msg:[NSString stringWithFormat:@"Failed to load media: %@", path.lastPathComponent]];
            return NO;
        }
        bitmaps.push_back(w.bitmap);
    }

    mtmd_input_text text;
    text.text          = promptDelta.UTF8String;
    text.add_special   = (_nPastInternal == 0);
    text.parse_special = true;

    mtmd_input_chunks *chunks = mtmd_input_chunks_init();
    int32_t rc = mtmd_tokenize(_mctx, chunks, &text, (const mtmd_bitmap **)bitmaps.data(), bitmaps.size());
    for (auto *b : bitmaps) mtmd_bitmap_free(b);

    if (rc != 0) {
        mtmd_input_chunks_free(chunks);
        [self failWith:error msg:@"Failed to tokenize multimodal prompt (marker/media count mismatch?)."];
        return NO;
    }

    // best-effort compression before a (potentially large) multimodal eval
    size_t needed = mtmd_helper_get_n_tokens(chunks);
    [self ensureRoomFor:(int)needed];

    llama_pos newNPast = _nPastInternal;
    int32_t erc = mtmd_helper_eval_chunks(_mctx, _lctx, chunks, _nPastInternal,
                                          /*seq_id*/ 0, /*n_batch*/ 512,
                                          /*logits_last*/ true, &newNPast);
    mtmd_input_chunks_free(chunks);

    if (erc != 0) {
        [self failWith:error msg:@"Failed to evaluate multimodal input."];
        return NO;
    }
    _nPastInternal = (int)newNPast;
    return YES;
}

/// Convert a token to a UTF-8 string, buffering partial multi-byte sequences.
- (NSString *)pieceForToken:(llama_token)tok {
    char tmp[128];
    int n = llama_token_to_piece(_vocab, tok, tmp, sizeof(tmp), 0, true);
    if (n < 0) return @"";
    _pieceBuffer.insert(_pieceBuffer.end(), tmp, tmp + n);

    NSString *s = [[NSString alloc] initWithBytes:_pieceBuffer.data()
                                           length:_pieceBuffer.size()
                                         encoding:NSUTF8StringEncoding];
    if (s) { _pieceBuffer.clear(); return s; }
    return @"";   // wait for more bytes to complete the code point
}

- (double)nowMillis {
    // Use a monotonic clock that is genuinely in nanoseconds. (dispatch_time
    // returns mach time *units*, which are not nanoseconds on Apple Silicon, so
    // dividing by 1e6 there over-reported tok/s by the mach timebase factor.)
    using namespace std::chrono;
    return duration<double, std::milli>(steady_clock::now().time_since_epoch()).count();
}

@end
