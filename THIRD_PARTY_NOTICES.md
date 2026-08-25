# Third-party notices

BabelWave currently vendors the inference core from
[`predict-woo/qwen3-asr.cpp`](https://github.com/predict-woo/qwen3-asr.cpp),
commit `6dcc586e5073fd6e85ee5728e75f0903d6c70c6c`, under the MIT License.
The build replaces that snapshot's GGML target with the single shared backend
from [`ggml-org/llama.cpp`](https://github.com/ggml-org/llama.cpp), commit
`f280b26983ad0fdb705a0d9ebf0503e76f2899b0`, under the MIT License.

The translation model is the Apache-2.0 licensed official
[`Qwen/Qwen3-1.7B-GGUF`](https://huggingface.co/Qwen/Qwen3-1.7B-GGUF), revision
`90862c4b9d2787eaed51d12237eafdfe7c5f6077`.

The corresponding license texts remain in the vendored source directories.
