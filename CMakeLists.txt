cmake_minimum_required(VERSION 3.20)
project(BabelWave VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(BUILD_SHARED_LIBS ON CACHE BOOL "" FORCE)

set(QWEN3_ASR_TEST OFF CACHE BOOL "" FORCE)
set(QWEN3_ASR_TIMING OFF CACHE BOOL "" FORCE)
set(QWEN3_ASR_TOOLS OFF CACHE BOOL "" FORCE)
set(QWEN3_ASR_EXTERNAL_GGML ON CACHE BOOL "" FORCE)
set(LLAMA_BUILD_COMMON OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_APP OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_UI OFF CACHE BOOL "" FORCE)
set(LLAMA_OPENSSL OFF CACHE BOOL "" FORCE)
set(LLAMA_SUBPROCESS OFF CACHE BOOL "" FORCE)
set(GGML_METAL ON CACHE BOOL "" FORCE)
set(GGML_CCACHE OFF CACHE BOOL "" FORCE)

add_subdirectory(third_party/llama.cpp llama-build EXCLUDE_FROM_ALL)
add_subdirectory(third_party/qwen3-asr.cpp qwen3-asr-build EXCLUDE_FROM_ALL)

add_executable(babelwaved Sources/Daemon/main.cpp)
target_include_directories(babelwaved PRIVATE
    third_party/qwen3-asr.cpp/include
    third_party/qwen3-asr.cpp/src
    third_party/qwen3-asr.cpp/third_party
)
target_link_libraries(babelwaved PRIVATE qwen3-asr llama)

add_executable(babelwave-quantize Tools/quantize-model.cpp)
target_include_directories(babelwave-quantize PRIVATE third_party/llama.cpp/include)
target_link_libraries(babelwave-quantize PRIVATE llama)

if(APPLE)
    set_target_properties(babelwaved PROPERTIES
        BUILD_RPATH "@executable_path/../../Frameworks"
        INSTALL_RPATH "@executable_path/../../Frameworks"
    )
    set_target_properties(babelwave-quantize PROPERTIES
        BUILD_RPATH "@executable_path/llama-build/src;@executable_path/llama-build/ggml/src"
    )
endif()
