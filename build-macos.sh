#!/usr/bin/env bash
# macOS (Apple Silicon): the PS4 code is x86-64, so everything is built for x86_64 and runs
# under Rosetta 2. Dependencies come from a conda-forge osx-64 prefix (BB_MAC_PREFIX), the
# Vulkan driver is KosmicKrisp (packaging/macos/setup-deps.sh builds the prefix).
set -euo pipefail
cd -- "$(dirname -- "$0")"
prefix=${BB_MAC_PREFIX:-$HOME/.uncharted-x86}
for needed in libvulkan.dylib libmimalloc.dylib libvulkan_kosmickrisp.dylib; do [[ -f $prefix/lib/$needed ]] || { echo "Missing $prefix: run packaging/macos/setup-deps.sh first." >&2; exit 1; }; done
export PKG_CONFIG_PATH=$prefix/lib/pkgconfig:$prefix/libdata/pkgconfig PKG_CONFIG_LIBDIR=$prefix/lib/pkgconfig:$prefix/libdata/pkgconfig
export CMAKE_PREFIX_PATH=$prefix
arch=(-arch x86_64 -mmacosx-version-min=14.0)
mkdir -p out
cmake -S gpu -B out/gpu -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DBB_PGO=off -DBB_LTO="${BB_LTO:-OFF}" \
    -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DCMAKE_FIND_FRAMEWORK=LAST -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
    -DGLSLANG_COMPILER="$(command -v glslang)" -Wno-dev >/dev/null
if ! ninja -C out/gpu bbgpu > out/gpu-build.log 2>&1; then
    grep -v '^\[' out/gpu-build.log | tail -60 >&2
    echo 'GPU library build failed (full log: out/gpu-build.log)' >&2; exit 1
fi
CC=clang
includes=($(pkg-config --cflags vulkan sdl3))
libraries=($(pkg-config --libs vulkan sdl3))
if [[ ! -f out/libatrac9.a || -n $(find third_party/LibAtrac9/C/src -newer out/libatrac9.a -name '*.c') ]]; then
    rm -rf out/atrac9 && mkdir -p out/atrac9
    for source in third_party/LibAtrac9/C/src/*.c; do
        $CC "${arch[@]}" -std=c99 -O2 -g -w -c "$source" -o "out/atrac9/$(basename "${source%.c}").o"
    done
    ar rcs out/libatrac9.a out/atrac9/*.o
fi
# The PS4 image goes at 0x400000: no 4 GiB __PAGEZERO, no PIE, and the host image moved out of
# the way (same layout as shadPS4 on macOS).
loader=(-Wl,-no_pie -Wl,-pagezero_size,0x1000 -Wl,-image_base,0x20000000000)
probe_only=(-Wl,-segaddr,__BBIMAGE,0x400000) # the image range (probe.c)
gpu=(-Lout/gpu -lbbgpu -Wl,-rpath,@executable_path/gpu -Wl,-rpath,@executable_path/lib -Wl,-rpath,"$PWD/out/gpu")
# The guest packs host pointers into 40 bits: mimalloc, patched to take all its memory from
# [4 GiB, 32 GiB) (packaging/macos/mimalloc-low-window.patch), replaces malloc for the whole process (zone + interposing).
heap=(-L"$prefix/lib" -lmimalloc)
$CC "${arch[@]}" -std=c11 -O2 -g -Wall -Wextra -Werror -pthread "${includes[@]}" -I. -Isrc \
    src/probe.c src/runtime*.c src/vulkan_smoke.c out/libatrac9.a -lm "${heap[@]}" "${gpu[@]}" "${libraries[@]}" "${loader[@]}" "${probe_only[@]}" -o out/bb-probe
# The Vulkan driver beside the executable, where the renderer looks for it (vk_platform.cpp).
cp "$prefix/lib/libvulkan_kosmickrisp.dylib" out/
cat > out/kosmickrisp_mesa_icd.json <<'EOF'
{
    "ICD": {
        "api_version": "1.4.363",
        "library_path": "./libvulkan_kosmickrisp.dylib"
    },
    "file_format_version": "1.0.1"
}
EOF
echo "Built $PWD/out/bb-probe"
$CC "${arch[@]}" -std=c11 -O2 -Wall -Wextra -Werror "${includes[@]}" tools/gpu_capabilities.c "${libraries[@]}" \
    -Wl,-rpath,"$prefix/lib" -o out/bb-gpu-capabilities
if [[ ${1:-} == --test ]]; then
    # Same suites as build.sh --test, linked like bb-probe (low heap, guest address layout).
    common=(-std=c11 -O2 -g -Wall -Wextra -Werror -pthread "${arch[@]}")
    $CC "${common[@]}" "${includes[@]}" -I. -Isrc tests/test_pad.c "${libraries[@]}" -o out/pad-test
    BB_PAD_HOST=1 out/pad-test # the virtual controller part needs the host pad (runtime_pad.c)
    $CC "${common[@]}" "${includes[@]}" -I. -Isrc tests/test_runtime.c src/runtime*.c out/libatrac9.a -lm "${heap[@]}" "${gpu[@]}" \
        "${libraries[@]}" "${loader[@]}" -o out/runtime-test
    out/runtime-test
    $CC "${common[@]}" -Isrc tests/test_file_mods.c -o out/file-mods-test
    out/file-mods-test
    $CC "${common[@]}" "${includes[@]}" -I. -Isrc tests/test_sema.c src/runtime*.c out/libatrac9.a -lm "${heap[@]}" "${gpu[@]}" \
        "${libraries[@]}" "${loader[@]}" -o out/sema-test
    out/sema-test
    $CC "${common[@]}" -I. -Isrc tests/test_content.c src/runtime_content.c -o out/content-test
    out/content-test
fi
