#include "httplib.h"
#include "llama.h"
#include "qwen3_asr.h"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cctype>
#include <cmath>
#include <csignal>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <signal.h>
#include <unistd.h>

namespace {

constexpr int kSampleRate = 16000;
constexpr int kDefaultPort = 39173;
constexpr int kMaxAudioSeconds = 30;
constexpr std::uintmax_t kMaximumRuntimeLogBytes = 8 * 1024 * 1024;
constexpr int kTranslationDraftWindow = 16;
constexpr int kMinimumTranslationDraftTokens = 10;

struct Options {
    std::string host = "127.0.0.1";
    std::string model_path;
    std::string translation_model;
    std::string log_path;
    int port = kDefaultPort;
    int threads = std::max(1u, std::min(8u, std::thread::hardware_concurrency()));
    pid_t parent_pid = 0;
    bool mock = false;
};

std::mutex g_runtime_log_mutex;

void rotate_runtime_log_if_needed(const std::string & path, bool force_open = false) {
    if (path.empty()) return;

    std::lock_guard<std::mutex> lock(g_runtime_log_mutex);
    const std::filesystem::path log_path(path);
    const std::filesystem::path previous_path = path + ".1";
    std::error_code error;
    std::filesystem::create_directories(log_path.parent_path(), error);
    error.clear();
    const std::uintmax_t current_size = std::filesystem::exists(log_path, error)
        ? std::filesystem::file_size(log_path, error)
        : 0;
    const bool should_rotate = !error && current_size >= kMaximumRuntimeLogBytes;
    if (!force_open && !should_rotate) return;

    std::fflush(stderr);
    if (should_rotate) {
        std::filesystem::remove(previous_path, error);
        error.clear();
        std::filesystem::rename(log_path, previous_path, error);
    }
    if (std::freopen(path.c_str(), "a", stderr)) {
        std::setvbuf(stderr, nullptr, _IOLBF, 0);
    }
}

struct Runtime {
    qwen3_asr::Qwen3ASR engine;
    std::mutex inference_mutex;
    llama_model * translation_model = nullptr;
    llama_context * translation_context = nullptr;
    llama_sampler * translation_sampler = nullptr;
    std::mutex translation_mutex;
    std::mutex debug_log_mutex;
    std::string error;
    std::string translation_error;
    std::uint64_t translation_utterance_id = 0;
    std::string translation_source_text;
    std::string translation_target_language;
    std::string translation_cached_text;
    std::vector<llama_token> translation_draft_tokens;
    bool loaded = false;
    bool translation_loaded = false;
    bool mock = false;

    ~Runtime() {
        if (translation_context) llama_free(translation_context);
        if (translation_sampler) llama_sampler_free(translation_sampler);
        if (translation_model) llama_model_free(translation_model);
    }
};

struct TranslationResult {
    std::string text;
    std::string raw_text;
    std::string target_language;
    std::string error;
    long long elapsed_ms = 0;
    long long prefill_ms = 0;
    long long decode_ms = 0;
    long long sample_ms = 0;
    int generated_tokens = 0;
    int drafted_tokens = 0;
    bool cache_hit = false;
    bool thinking_detected = false;
    bool prompt_echo_detected = false;
    bool special_token_detected = false;
    bool draft_rollback = false;
};

int live_asr_token_budget(std::size_t sample_count) {
    const double seconds = static_cast<double>(sample_count) / kSampleRate;
    return std::clamp(static_cast<int>(std::ceil(seconds * 12.0)) + 32, 64, 160);
}

httplib::Server * g_server = nullptr;

void llama_log_without_backend_sampler_noise(
    ggml_log_level level,
    const char * text,
    void *) {
    if (text && std::strstr(text, "Backend sampler selected token") != nullptr) {
        return;
    }
    (void) level;
    if (text) {
        std::fputs(text, stderr);
        std::fflush(stderr);
    }
}

std::string json_escape(const std::string & value) {
    std::string result;
    result.reserve(value.size() + 16);
    for (const unsigned char ch : value) {
        switch (ch) {
            case '\"': result += "\\\""; break;
            case '\\': result += "\\\\"; break;
            case '\b': result += "\\b"; break;
            case '\f': result += "\\f"; break;
            case '\n': result += "\\n"; break;
            case '\r': result += "\\r"; break;
            case '\t': result += "\\t"; break;
            default:
                if (ch < 0x20) {
                    char buffer[7];
                    std::snprintf(buffer, sizeof(buffer), "\\u%04x", ch);
                    result += buffer;
                } else {
                    result += static_cast<char>(ch);
                }
        }
    }
    return result;
}

std::filesystem::path debug_transcript_log_path() {
    const char * home = std::getenv("HOME");
    const std::filesystem::path base = home && *home
        ? std::filesystem::path(home)
        : std::filesystem::temp_directory_path();
    return base / "Library" / "Logs" / "BabelWave-Debug.jsonl";
}

void append_debug_transcript_log(
    Runtime & runtime,
    std::uint64_t utterance_id,
    std::uint64_t revision,
    double duration,
    const std::string & source_text,
    const std::string & source_language,
    const TranslationResult & translation,
    long long inference_ms,
    long long request_ms) {
    const auto timestamp_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    std::string line =
        "{\"timestamp_unix_ms\":" + std::to_string(timestamp_ms) +
        ",\"utterance_id\":" + std::to_string(utterance_id) +
        ",\"revision\":" + std::to_string(revision) +
        ",\"duration_seconds\":" + std::to_string(duration) +
        ",\"source_language\":\"" + json_escape(source_language) +
        "\",\"target_language\":\"" + json_escape(translation.target_language) +
        "\",\"asr_text\":\"" + json_escape(source_text) +
        "\",\"raw_translation\":\"" + json_escape(translation.raw_text) +
        "\",\"displayed_translation\":\"" + json_escape(translation.text) +
        "\",\"translation_error\":\"" + json_escape(translation.error) +
        "\",\"inference_ms\":" + std::to_string(inference_ms) +
        ",\"translation_ms\":" + std::to_string(translation.elapsed_ms) +
        ",\"request_ms\":" + std::to_string(request_ms) +
        ",\"translation_tokens\":" + std::to_string(translation.generated_tokens) +
        ",\"drafted_tokens\":" + std::to_string(translation.drafted_tokens) +
        ",\"cache_hit\":" + std::string(translation.cache_hit ? "true" : "false") +
        ",\"thinking_detected\":" +
            std::string(translation.thinking_detected ? "true" : "false") +
        ",\"prompt_echo_detected\":" +
            std::string(translation.prompt_echo_detected ? "true" : "false") +
        ",\"special_token_detected\":" +
            std::string(translation.special_token_detected ? "true" : "false") +
        ",\"draft_rollback\":" +
            std::string(translation.draft_rollback ? "true" : "false") + "}\n";

    std::lock_guard<std::mutex> lock(runtime.debug_log_mutex);
    const std::filesystem::path log_path = debug_transcript_log_path();
    const std::filesystem::path previous_path = log_path.string() + ".1";
    std::error_code error;
    std::filesystem::create_directories(log_path.parent_path(), error);
    constexpr std::uintmax_t kMaximumLogBytes = 8 * 1024 * 1024;
    const std::uintmax_t current_size = std::filesystem::exists(log_path, error)
        ? std::filesystem::file_size(log_path, error)
        : 0;
    if (!error && current_size + line.size() > kMaximumLogBytes) {
        std::filesystem::remove(previous_path, error);
        error.clear();
        std::filesystem::rename(log_path, previous_path, error);
    }
    std::ofstream output(log_path, std::ios::binary | std::ios::app);
    if (output) {
        output.write(line.data(), static_cast<std::streamsize>(line.size()));
    }
}

std::string trim_ascii_whitespace(const std::string & value) {
    const auto first = value.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) {
        return {};
    }
    const auto last = value.find_last_not_of(" \t\r\n");
    return value.substr(first, last - first + 1);
}

bool is_chinese_language(const std::string & language) {
    std::string lower = language;
    std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return lower.find("chinese") != std::string::npos || lower.find("cantonese") != std::string::npos ||
        lower == "zh" || lower == "yue";
}

bool is_unknown_language(const std::string & language) {
    std::string lower = trim_ascii_whitespace(language);
    std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return lower.empty() || lower == "none" || lower == "unknown" || lower == "auto";
}

struct ScriptSignals {
    bool han = false;
    bool kana = false;
    bool hangul = false;
};

ScriptSignals inspect_script_signals(const std::string & text) {
    ScriptSignals signals;
    for (std::size_t index = 0; index < text.size();) {
        const auto first = static_cast<unsigned char>(text[index]);
        std::uint32_t codepoint = 0;
        std::size_t length = 1;
        if ((first & 0xe0) == 0xc0 && index + 1 < text.size()) {
            codepoint = first & 0x1f;
            length = 2;
        } else if ((first & 0xf0) == 0xe0 && index + 2 < text.size()) {
            codepoint = first & 0x0f;
            length = 3;
        } else if ((first & 0xf8) == 0xf0 && index + 3 < text.size()) {
            codepoint = first & 0x07;
            length = 4;
        } else {
            ++index;
            continue;
        }
        for (std::size_t offset = 1; offset < length; ++offset) {
            const auto continuation = static_cast<unsigned char>(text[index + offset]);
            if ((continuation & 0xc0) != 0x80) {
                length = offset;
                break;
            }
            codepoint = (codepoint << 6) | (continuation & 0x3f);
        }
        if ((codepoint >= 0x3400 && codepoint <= 0x4dbf) ||
            (codepoint >= 0x4e00 && codepoint <= 0x9fff) ||
            (codepoint >= 0xf900 && codepoint <= 0xfaff)) {
            signals.han = true;
        }
        if ((codepoint >= 0x3040 && codepoint <= 0x30ff) ||
            (codepoint >= 0x31f0 && codepoint <= 0x31ff) ||
            (codepoint >= 0xff66 && codepoint <= 0xff9d)) {
            signals.kana = true;
        }
        if ((codepoint >= 0x1100 && codepoint <= 0x11ff) ||
            (codepoint >= 0x3130 && codepoint <= 0x318f) ||
            (codepoint >= 0xa960 && codepoint <= 0xa97f) ||
            (codepoint >= 0xac00 && codepoint <= 0xd7af) ||
            (codepoint >= 0xd7b0 && codepoint <= 0xd7ff)) {
            signals.hangul = true;
        }
        index += length;
    }
    return signals;
}

std::string token_to_piece(const llama_vocab * vocab, llama_token token) {
    std::vector<char> buffer(256);
    int length = llama_token_to_piece(vocab, token, buffer.data(), buffer.size(), 0, true);
    if (length < 0) {
        buffer.resize(static_cast<std::size_t>(-length));
        length = llama_token_to_piece(vocab, token, buffer.data(), buffer.size(), 0, true);
    }
    return length > 0 ? std::string(buffer.data(), static_cast<std::size_t>(length)) : std::string{};
}

bool load_translation_model(Runtime & runtime, const std::string & path, int threads) {
    if (path.empty()) {
        runtime.translation_error = "Translation model path is not configured";
        return false;
    }
    if (!std::filesystem::exists(path)) {
        runtime.translation_error = "Translation model not found: " + path;
        return false;
    }

    llama_log_set(llama_log_without_backend_sampler_noise, nullptr);
    ggml_backend_load_all();
    llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = -1;
    runtime.translation_model = llama_model_load_from_file(path.c_str(), model_params);
    if (!runtime.translation_model) {
        runtime.translation_error = "llama.cpp could not load the translation model";
        return false;
    }

    runtime.translation_sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(runtime.translation_sampler, llama_sampler_init_greedy());
    llama_sampler_seq_config sampler_config = {
        .seq_id = 0,
        .sampler = runtime.translation_sampler,
    };

    llama_context_params context_params = llama_context_default_params();
    // Live subtitle prompts are small. The old 1536-token context allocated a
    // 168 MiB Metal KV cache and cleared it for every sentence.
    context_params.n_ctx = 512;
    context_params.n_batch = 256;
    context_params.n_ubatch = 256;
    // Translation emits one sequence. Reserve only enough output rows to verify
    // one prior-revision draft window instead of the old 256-row default.
    context_params.n_outputs_max = kTranslationDraftWindow;
    context_params.n_outputs_max_per_seq = kTranslationDraftWindow;
    context_params.n_threads = threads;
    context_params.n_threads_batch = threads;
    context_params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED;
    context_params.offload_kqv = true;
    context_params.op_offload = true;
    context_params.no_perf = true;
    // Run greedy selection in the backend graph. Without this, every token
    // synchronizes and copies the full 151k-token vocabulary to the CPU before
    // selecting the maximum logit.
    context_params.samplers = &sampler_config;
    context_params.n_samplers = 1;
    runtime.translation_context = llama_init_from_model(runtime.translation_model, context_params);
    if (!runtime.translation_context) {
        runtime.translation_error = "llama.cpp could not create the translation context";
        llama_sampler_free(runtime.translation_sampler);
        runtime.translation_sampler = nullptr;
        llama_model_free(runtime.translation_model);
        runtime.translation_model = nullptr;
        return false;
    }

    runtime.translation_loaded = true;
    return true;
}

TranslationResult translate_locally(
    Runtime & runtime,
    const std::string & source_text,
    const std::string & source_language,
    std::uint64_t utterance_id = 0) {
    TranslationResult result;
    const ScriptSignals scripts = inspect_script_signals(source_text);
    const bool source_is_chinese = is_chinese_language(source_language) ||
        (is_unknown_language(source_language) && scripts.han && !scripts.kana && !scripts.hangul);
    result.target_language = source_is_chinese ? "English" : "Chinese";
    // Silence and low-confidence audio can legitimately produce no ASR text.
    // Never send an empty user turn to the translation model: with only the
    // system instruction left in the prompt, small models may translate or
    // echo that instruction as though it were the subtitle.
    if (source_text.empty()) {
        return result;
    }
    if (!runtime.translation_loaded) {
        result.error = runtime.translation_error.empty() ? "Translation model is unavailable" : runtime.translation_error;
        return result;
    }

    const std::string system =
        "Translate live subtitles into natural " + result.target_language +
        ". Preserve names, numbers, tone, and meaning. Translate only given text; "
        "never complete it. Output only translation.";
    const std::string user = source_text + "\n/no_think";
    const llama_chat_message messages[] = {
        {"system", system.c_str()},
        {"user", user.c_str()},
    };

    const char * chat_template = llama_model_chat_template(runtime.translation_model, nullptr);
    int formatted_length = llama_chat_apply_template(chat_template, messages, 2, true, nullptr, 0);
    if (formatted_length <= 0) {
        result.error = "llama.cpp could not apply the model chat template";
        return result;
    }
    std::vector<char> formatted(static_cast<std::size_t>(formatted_length) + 1);
    formatted_length = llama_chat_apply_template(
        chat_template, messages, 2, true, formatted.data(), static_cast<int32_t>(formatted.size()));
    if (formatted_length <= 0) {
        result.error = "llama.cpp could not format the translation prompt";
        return result;
    }
    const std::string prompt(formatted.data(), static_cast<std::size_t>(formatted_length));

    const auto started = std::chrono::steady_clock::now();
    std::lock_guard<std::mutex> lock(runtime.translation_mutex);
    const bool same_utterance = utterance_id != 0 &&
        runtime.translation_utterance_id == utterance_id &&
        runtime.translation_target_language == result.target_language;
    if (same_utterance && runtime.translation_source_text == source_text &&
        !runtime.translation_cached_text.empty()) {
        result.text = runtime.translation_cached_text;
        result.raw_text = runtime.translation_cached_text;
        result.generated_tokens = static_cast<int>(runtime.translation_draft_tokens.size());
        result.cache_hit = true;
        result.elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - started).count();
        return result;
    }
    const std::vector<llama_token> draft_tokens = same_utterance
        ? runtime.translation_draft_tokens
        : std::vector<llama_token>{};

    // Reset positions without zero-filling the whole Metal KV allocation. The
    // new prompt overwrites every referenced position, so stale data is never
    // visible to the model.
    llama_memory_clear(llama_get_memory(runtime.translation_context), false);
    llama_sampler_reset(runtime.translation_sampler);

    const llama_vocab * vocab = llama_model_get_vocab(runtime.translation_model);
    const int token_count = -llama_tokenize(vocab, prompt.c_str(), prompt.size(), nullptr, 0, true, true);
    const int max_output_tokens = std::clamp(token_count + 32, 64, 160);
    if (token_count <= 0 ||
        token_count + max_output_tokens > static_cast<int>(llama_n_ctx(runtime.translation_context))) {
        result.error = "Translation prompt exceeds the local context";
        return result;
    }
    std::vector<llama_token> tokens(static_cast<std::size_t>(token_count));
    if (llama_tokenize(vocab, prompt.c_str(), prompt.size(), tokens.data(), token_count, true, true) < 0) {
        result.error = "llama.cpp could not tokenize the translation prompt";
        return result;
    }

    std::vector<llama_token> output_tokens;
    output_tokens.reserve(static_cast<std::size_t>(max_output_tokens));
    auto append_output = [&](llama_token token) {
        output_tokens.push_back(token);
        result.text += token_to_piece(vocab, token);
        result.generated_tokens = static_cast<int>(output_tokens.size());
    };
    auto decode_and_measure = [&](llama_batch decode_batch, bool prefill) {
        const auto decode_started = std::chrono::steady_clock::now();
        const int status = llama_decode(runtime.translation_context, decode_batch);
        const auto decode_elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - decode_started).count();
        if (prefill) {
            result.prefill_ms += decode_elapsed;
        } else {
            result.decode_ms += decode_elapsed;
        }
        return status;
    };
    auto sample_and_measure = [&](int output_index) {
        const auto sample_started = std::chrono::steady_clock::now();
        const llama_token sampled = llama_sampler_sample(
            runtime.translation_sampler, runtime.translation_context, output_index);
        result.sample_ms += std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - sample_started).count();
        return sampled;
    };

    llama_batch batch = llama_batch_get_one(tokens.data(), token_count);
    int decode_status = decode_and_measure(batch, true);
    if (decode_status != 0) {
        result.error = "llama.cpp decode failed with code " + std::to_string(decode_status);
    } else {
        llama_token token = sample_and_measure(-1);
        if (!llama_vocab_is_eog(vocab, token)) {
            append_output(token);
            batch = llama_batch_get_one(&output_tokens.back(), 1);
        }
    }

    bool reached_eog = output_tokens.empty() && result.error.empty();
    if (!reached_eog && result.error.empty() &&
        draft_tokens.size() >= kMinimumTranslationDraftTokens &&
        output_tokens.front() == draft_tokens.front() &&
        output_tokens.size() < static_cast<std::size_t>(max_output_tokens)) {
        const int draft_input_count = std::min<int>(
            kTranslationDraftWindow,
            static_cast<int>(draft_tokens.size()));
        llama_batch draft_batch = llama_batch_init(draft_input_count, 0, 1);
        draft_batch.n_tokens = draft_input_count;
        for (int index = 0; index < draft_input_count; ++index) {
            draft_batch.token[index] = draft_tokens[static_cast<std::size_t>(index)];
            draft_batch.pos[index] = token_count + index;
            draft_batch.n_seq_id[index] = 1;
            draft_batch.seq_id[index][0] = 0;
            draft_batch.logits[index] = 1;
        }

        decode_status = decode_and_measure(draft_batch, false);
        if (decode_status != 0) {
            result.error = "llama.cpp draft decode failed with code " + std::to_string(decode_status);
        } else {
            for (int index = 0;
                 index < draft_input_count &&
                 output_tokens.size() < static_cast<std::size_t>(max_output_tokens);
                 ++index) {
                const llama_token predicted = sample_and_measure(index);
                const int next_draft_index = index + 1;
                if (llama_vocab_is_eog(vocab, predicted)) {
                    reached_eog = true;
                    llama_memory_seq_rm(
                        llama_get_memory(runtime.translation_context),
                        0,
                        token_count + index + 1,
                        -1);
                    break;
                }

                append_output(predicted);
                if (next_draft_index < static_cast<int>(draft_tokens.size()) &&
                    predicted == draft_tokens[static_cast<std::size_t>(next_draft_index)]) {
                    ++result.drafted_tokens;
                    continue;
                }

                // The model rejected the old revision at this token. Keep only
                // the verified prefix in KV and resume ordinary greedy decode.
                if (!llama_memory_seq_rm(
                        llama_get_memory(runtime.translation_context),
                        0,
                        token_count + index + 1,
                        -1)) {
                    result.error = "llama.cpp could not roll back a rejected translation draft";
                }
                result.draft_rollback = index + 1 < draft_input_count;
                break;
            }
        }
        llama_batch_free(draft_batch);
        if (!reached_eog && result.error.empty() && !output_tokens.empty()) {
            batch = llama_batch_get_one(&output_tokens.back(), 1);
        }
    }

    while (!reached_eog && result.error.empty() &&
           output_tokens.size() < static_cast<std::size_t>(max_output_tokens)) {
        decode_status = decode_and_measure(batch, false);
        if (decode_status != 0) {
            result.error = "llama.cpp decode failed with code " + std::to_string(decode_status);
            break;
        }
        const llama_token token = sample_and_measure(-1);
        if (llama_vocab_is_eog(vocab, token)) {
            reached_eog = true;
            break;
        }
        append_output(token);
        batch = llama_batch_get_one(&output_tokens.back(), 1);
    }
    result.elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - started).count();

    result.raw_text = result.text;
    result.thinking_detected = result.raw_text.find("<think") != std::string::npos ||
        result.raw_text.find("</think>") != std::string::npos;
    result.prompt_echo_detected =
        result.raw_text.find("Translate live subtitles") != std::string::npos ||
        result.raw_text.find("Preserve names, numbers") != std::string::npos ||
        result.raw_text.find("Output only translation") != std::string::npos;
    result.special_token_detected = result.raw_text.find("<|im_") != std::string::npos ||
        result.raw_text.find("<|endoftext|>") != std::string::npos;

    const std::size_t thinking_end = result.text.rfind("</think>");
    if (thinking_end != std::string::npos) {
        result.text.erase(0, thinking_end + std::string("</think>").size());
    }
    result.text = trim_ascii_whitespace(result.text);
    if (result.prompt_echo_detected) {
        result.text.clear();
        result.error = "The local translation model echoed its system prompt";
    } else if (result.special_token_detected) {
        result.text.clear();
        result.error = "The local translation model returned internal control tokens";
    }
    if (result.text.empty()) {
        if (result.error.empty()) result.error = "The local translation model returned an empty result";
    } else if (result.error.empty() && utterance_id != 0) {
        runtime.translation_utterance_id = utterance_id;
        runtime.translation_source_text = source_text;
        runtime.translation_target_language = result.target_language;
        runtime.translation_cached_text = result.text;
        runtime.translation_draft_tokens = std::move(output_tokens);
    }
    return result;
}

void warm_up_models(Runtime & runtime, int threads) {
    if (!runtime.loaded) return;

    const auto started = std::chrono::steady_clock::now();
    // Use a realistic encoder shape so the first real caption does not pay for
    // Metal pipelines that a tiny warm-up graph never touched.
    constexpr int kLiveSegmentSeconds = 8;
    std::vector<float> silence(
        static_cast<std::size_t>(kSampleRate * kLiveSegmentSeconds), 0.0f);
    qwen3_asr::transcribe_params parameters;
    parameters.n_threads = threads;
    parameters.max_tokens = 32;
    parameters.print_progress = false;
    parameters.print_timing = false;
    {
        std::lock_guard<std::mutex> lock(runtime.inference_mutex);
        (void) runtime.engine.transcribe(
            silence.data(), static_cast<int>(silence.size()), parameters);
    }
    if (runtime.translation_loaded) {
        // Warm both translation directions and representative output lengths.
        (void) translate_locally(runtime, "Real-time bilingual subtitles.", "English");
        (void) translate_locally(runtime, "实时双语字幕。", "Chinese");
    }
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - started).count();
    std::fprintf(stderr, "BabelWave inference warm-up completed in %lld ms\n", elapsed);
}

void set_json(httplib::Response & response, int status, const std::string & body) {
    response.status = status;
    response.set_content(body, "application/json; charset=utf-8");
}

void print_usage(const char * executable) {
    std::fprintf(stderr,
        "Usage: %s [--model PATH] [--host HOST] [--port PORT] [--threads N] "
        "[--translation-model PATH] [--log PATH] [--parent-pid PID] [--mock]\n"
        "\n"
        "BabelWave accepts signed 16-bit little-endian mono PCM at 16 kHz:\n"
        "  POST /v1/transcribe\n"
        "  GET  /health\n",
        executable);
}

bool parse_options(int argc, char ** argv, Options & options) {
    for (int index = 1; index < argc; ++index) {
        const std::string argument = argv[index];
        auto value = [&](const char * name) -> const char * {
            if (index + 1 >= argc) {
                std::fprintf(stderr, "%s requires a value\n", name);
                return nullptr;
            }
            return argv[++index];
        };

        if (argument == "--model") {
            const char * next = value("--model");
            if (!next) return false;
            options.model_path = next;
        } else if (argument == "--translation-model") {
            const char * next = value("--translation-model");
            if (!next) return false;
            options.translation_model = next;
        } else if (argument == "--log") {
            const char * next = value("--log");
            if (!next) return false;
            options.log_path = next;
        } else if (argument == "--host") {
            const char * next = value("--host");
            if (!next) return false;
            options.host = next;
        } else if (argument == "--port") {
            const char * next = value("--port");
            if (!next) return false;
            options.port = std::atoi(next);
        } else if (argument == "--threads") {
            const char * next = value("--threads");
            if (!next) return false;
            options.threads = std::atoi(next);
        } else if (argument == "--parent-pid") {
            const char * next = value("--parent-pid");
            if (!next) return false;
            options.parent_pid = static_cast<pid_t>(std::atoi(next));
        } else if (argument == "--mock") {
            options.mock = true;
        } else if (argument == "--help" || argument == "-h") {
            print_usage(argv[0]);
            std::exit(0);
        } else {
            std::fprintf(stderr, "Unknown argument: %s\n", argument.c_str());
            return false;
        }
    }

    return options.port > 0 && options.port <= 65535 && options.threads > 0 &&
        options.parent_pid >= 0;
}

std::vector<float> decode_pcm16(const std::string & body) {
    std::vector<float> samples(body.size() / 2);
    for (std::size_t index = 0; index < samples.size(); ++index) {
        const auto low = static_cast<std::uint8_t>(body[index * 2]);
        const auto high = static_cast<std::uint8_t>(body[index * 2 + 1]);
        const auto value = static_cast<std::int16_t>(
            static_cast<std::uint16_t>(low) | (static_cast<std::uint16_t>(high) << 8));
        samples[index] = static_cast<float>(value) / 32768.0f;
    }
    return samples;
}

void stop_server(int) {
    if (g_server) {
        g_server->stop();
    }
}

} // namespace

int main(int argc, char ** argv) {
    Options options;
    if (!parse_options(argc, argv, options)) {
        print_usage(argv[0]);
        return 2;
    }

    // Own the runtime log inside the daemon so it can rotate while the menu bar
    // app remains open for days. BabelWave.log and BabelWave.log.1 are each
    // capped at approximately 8 MiB.
    rotate_runtime_log_if_needed(options.log_path, true);

    auto runtime = std::make_shared<Runtime>();
    runtime->mock = options.mock;

    if (!options.mock) {
        if (options.model_path.empty()) {
            runtime->error = "No model path supplied";
        } else if (!std::filesystem::exists(options.model_path)) {
            runtime->error = "Model not found: " + options.model_path;
        } else {
            runtime->loaded = runtime->engine.load_model(options.model_path);
            if (!runtime->loaded) {
                runtime->error = runtime->engine.get_error();
            }
        }
        runtime->translation_loaded = load_translation_model(
            *runtime, options.translation_model, options.threads);
        warm_up_models(*runtime, options.threads);
        rotate_runtime_log_if_needed(options.log_path);
    }

    httplib::Server server;
    g_server = &server;
    std::signal(SIGINT, stop_server);
    std::signal(SIGTERM, stop_server);
    server.set_payload_max_length(
        static_cast<std::size_t>(kSampleRate * kMaxAudioSeconds * sizeof(std::int16_t)));
    server.set_read_timeout(30, 0);
    server.set_write_timeout(120, 0);

    server.Get("/health", [runtime](const httplib::Request &, httplib::Response & response) {
        const std::string mode = runtime->mock ? "mock" :
            (runtime->loaded ? (runtime->translation_loaded ? "qwen3-asr+qwen3-translate" : "qwen3-asr") : "error");
        set_json(response, runtime->loaded || runtime->mock ? 200 : 503,
            "{\"ok\":" + std::string(runtime->loaded || runtime->mock ? "true" : "false") +
            ",\"mode\":\"" + mode +
            "\",\"translation_ready\":" + std::string(runtime->translation_loaded ? "true" : "false") +
            ",\"error\":\"" + json_escape(runtime->error) +
            "\",\"translation_error\":\"" + json_escape(runtime->translation_error) + "\"}");
    });

    server.Post("/v1/transcribe", [runtime, options](const httplib::Request & request, httplib::Response & response) {
        const auto request_started = std::chrono::steady_clock::now();
        if (request.body.empty() || request.body.size() % sizeof(std::int16_t) != 0) {
            set_json(response, 400, "{\"error\":\"Expected non-empty PCM S16LE audio\"}");
            return;
        }

        const std::size_t sample_count = request.body.size() / sizeof(std::int16_t);
        if (sample_count > static_cast<std::size_t>(kSampleRate * kMaxAudioSeconds)) {
            set_json(response, 413, "{\"error\":\"Audio segment exceeds 30 seconds\"}");
            return;
        }

        const double duration = static_cast<double>(sample_count) / kSampleRate;
        const bool debug_logging = request.has_header("X-BabelWave-Debug-Log") &&
            request.get_header_value("X-BabelWave-Debug-Log") != "0";
        if (runtime->mock) {
            char body[256];
            std::snprintf(body, sizeof(body),
                "{\"text\":\"[capture test: %.2f seconds]\","
                "\"translation\":\"[local translation test]\",\"language\":\"mock\","
                "\"duration_seconds\":%.3f,\"inference_ms\":0,\"translation_ms\":0}",
                duration, duration);
            set_json(response, 200, body);
            return;
        }

        if (!runtime->loaded) {
            set_json(response, 503,
                "{\"error\":\"" + json_escape(runtime->error.empty() ? "Model unavailable" : runtime->error) + "\"}");
            return;
        }

        const auto samples = decode_pcm16(request.body);
        qwen3_asr::transcribe_params parameters;
        parameters.n_threads = options.threads;
        parameters.max_tokens = live_asr_token_budget(sample_count);
        parameters.print_progress = false;
        parameters.print_timing = false;
        if (request.has_header("X-BabelWave-Language")) {
            parameters.language = request.get_header_value("X-BabelWave-Language");
        }

        qwen3_asr::transcribe_result result;
        {
            std::lock_guard<std::mutex> lock(runtime->inference_mutex);
            result = runtime->engine.transcribe(samples.data(), static_cast<int>(samples.size()), parameters);
        }
        if (!result.success) {
            set_json(response, 500, "{\"error\":\"" + json_escape(result.error_msg) + "\"}");
            return;
        }

        const std::string source_text = trim_ascii_whitespace(result.text);
        const std::string source_language = trim_ascii_whitespace(result.language);
        std::uint64_t utterance_id = 0;
        std::uint64_t revision = 0;
        if (request.has_header("X-BabelWave-Utterance-ID")) {
            const std::string value = request.get_header_value("X-BabelWave-Utterance-ID");
            char * end = nullptr;
            const unsigned long long parsed = std::strtoull(value.c_str(), &end, 10);
            if (end != value.c_str() && end && *end == '\0') {
                utterance_id = static_cast<std::uint64_t>(parsed);
            }
        }
        if (request.has_header("X-BabelWave-Revision")) {
            const std::string value = request.get_header_value("X-BabelWave-Revision");
            char * end = nullptr;
            const unsigned long long parsed = std::strtoull(value.c_str(), &end, 10);
            if (end != value.c_str() && end && *end == '\0') {
                revision = static_cast<std::uint64_t>(parsed);
            }
        }
        const TranslationResult translation = translate_locally(
            *runtime, source_text, source_language, utterance_id);

        const auto request_elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - request_started).count();
        if (debug_logging) {
            append_debug_transcript_log(
                *runtime,
                utterance_id,
                revision,
                duration,
                source_text,
                source_language,
                translation,
                static_cast<long long>(result.t_total_ms),
                request_elapsed_ms);
        }

        std::string response_body =
            "{\"text\":\"" + json_escape(source_text) +
            "\",\"translation\":\"" + json_escape(translation.text) +
            "\",\"language\":\"" + json_escape(source_language) +
            "\",\"source_language\":\"" + json_escape(source_language) +
            "\",\"target_language\":\"" + json_escape(translation.target_language) +
            "\",\"translation_error\":\"" + json_escape(translation.error) +
            "\",\"duration_seconds\":" + std::to_string(duration) +
            ",\"inference_ms\":" + std::to_string(result.t_total_ms) +
            ",\"mel_ms\":" + std::to_string(result.t_mel_ms) +
            ",\"encode_ms\":" + std::to_string(result.t_encode_ms) +
            ",\"decode_ms\":" + std::to_string(result.t_decode_ms) +
            ",\"translation_ms\":" + std::to_string(translation.elapsed_ms) +
            ",\"translation_prefill_ms\":" + std::to_string(translation.prefill_ms) +
            ",\"translation_decode_ms\":" + std::to_string(translation.decode_ms) +
            ",\"translation_sample_ms\":" + std::to_string(translation.sample_ms) +
            ",\"translation_tokens\":" + std::to_string(translation.generated_tokens) +
            ",\"translation_drafted_tokens\":" + std::to_string(translation.drafted_tokens) +
            ",\"translation_cache_hit\":" + std::string(translation.cache_hit ? "true" : "false") +
            ",\"request_ms\":" + std::to_string(request_elapsed_ms);
        response_body += "}";
        set_json(response, 200, response_body);

        std::fprintf(stderr,
            "caption %.2fs: request=%lld ms asr=%lld (mel=%lld encode=%lld decode=%lld) "
            "translate=%lld (prefill=%lld decode=%lld sample=%lld tokens=%d drafted=%d cache=%s)\n",
            duration,
            request_elapsed_ms,
            static_cast<long long>(result.t_total_ms),
            static_cast<long long>(result.t_mel_ms),
            static_cast<long long>(result.t_encode_ms),
            static_cast<long long>(result.t_decode_ms),
            translation.elapsed_ms,
            translation.prefill_ms,
            translation.decode_ms,
            translation.sample_ms,
            translation.generated_tokens,
            translation.drafted_tokens,
            translation.cache_hit ? "hit" : "miss");
        rotate_runtime_log_if_needed(options.log_path);
    });

    std::fprintf(stderr, "babelwaved listening on http://%s:%d (%s)\n",
        options.host.c_str(), options.port,
        runtime->mock ? "mock" : (runtime->loaded ?
            (runtime->translation_loaded ? "qwen3-asr + embedded llama.cpp translation" : "qwen3-asr only") :
            "model error"));

    std::jthread parent_monitor;
    if (options.parent_pid > 0) {
        parent_monitor = std::jthread([&server, parent_pid = options.parent_pid](std::stop_token stop) {
            while (!stop.stop_requested()) {
                std::this_thread::sleep_for(std::chrono::seconds(1));
                if (stop.stop_requested()) {
                    return;
                }
                if (::kill(parent_pid, 0) == -1 && errno == ESRCH) {
                    server.stop();
                    return;
                }
            }
        });
    }

    const bool listened = server.listen(options.host, options.port);
    if (parent_monitor.joinable()) {
        parent_monitor.request_stop();
    }
    if (!listened) {
        std::fprintf(stderr, "Failed to bind %s:%d\n", options.host.c_str(), options.port);
        return 1;
    }
    return 0;
}
