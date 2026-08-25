#include "llama.h"

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <thread>

int main(int argc, char ** argv) {
    if (argc != 3) {
        std::fprintf(stderr, "Usage: %s INPUT.gguf OUTPUT.gguf\n", argv[0]);
        return 2;
    }
    if (!std::filesystem::exists(argv[1])) {
        std::fprintf(stderr, "Input model does not exist: %s\n", argv[1]);
        return 2;
    }
    if (std::filesystem::exists(argv[2])) {
        std::fprintf(stderr, "Refusing to overwrite existing output: %s\n", argv[2]);
        return 2;
    }

    llama_model_quantize_params params = llama_model_quantize_default_params();
    params.nthread = static_cast<int32_t>(std::max(
        1u, std::min(8u, std::thread::hardware_concurrency())));
    params.ftype = LLAMA_FTYPE_MOSTLY_Q4_K_M;
    params.allow_requantize = true;
    params.quantize_output_tensor = true;

    const uint32_t status = llama_model_quantize(argv[1], argv[2], &params);
    if (status != 0) {
        std::fprintf(stderr, "Quantization failed with code %u\n", status);
        return 1;
    }
    std::fprintf(stderr, "Created Q4_K_M model: %s\n", argv[2]);
    return 0;
}
