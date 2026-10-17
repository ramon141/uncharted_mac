#!/usr/bin/env bash
# macOS (Apple Silicon): builds the x86_64 dependency prefix build-macos.sh links against.
# The PS4 code is x86-64, so the whole port is an x86_64 program running under Rosetta 2;
# Homebrew no longer installs Intel packages on macOS, conda-forge (osx-64) still does.
#   bash packaging/macos/setup-deps.sh            # prefix in ~/.uncharted-x86
# Needs: Xcode command line tools, Homebrew (arm64) for the host tools, Rosetta 2, macOS 26
# (the KosmicKrisp Vulkan driver).
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
prefix=${BB_MAC_PREFIX:-$HOME/.uncharted-x86}
src=${BB_MAC_SRC:-$HOME/.uncharted-x86-src}
mkdir -p "$src"

# Host tools (native arm64 is fine: they only run during the build).
brew install micromamba cmake ninja glslang pkg-config

# Libraries from conda-forge, x86_64.
export MAMBA_ROOT_PREFIX=${MAMBA_ROOT_PREFIX:-$HOME/.micromamba}
if [[ ! -d $prefix/conda-meta ]]; then
    micromamba create -y -p "$prefix" --platform osx-64 -c conda-forge \
        sdl3 ffmpeg fmt xxhash libprotobuf protobuf openssl zlib nlohmann_json libboost-headers \
        libvulkan-loader pkg-config
fi

fetch() { # directory, GitHub repository, tag
    if [[ ! -d $src/$1 ]]; then
        mkdir -p "$src/$1"
        curl -sfL "https://codeload.github.com/$2/tar.gz/$3" | tar xz --strip-components=1 -C "$src/$1"
    fi
}
x86=(-G Ninja -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
     -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5)
build() { # directory, extra CMake options...
    local dir=$1; shift
    cmake -S "$src/$dir" -B "$src/$dir/build" "${x86[@]}" "$@" >/dev/null
    cmake --build "$src/$dir/build" >/dev/null
    cmake --install "$src/$dir/build" >/dev/null
    echo "Installed $dir"
}

# Vulkan headers matching the loader (conda-forge's are too old for the renderer).
fetch vulkan-headers KhronosGroup/Vulkan-Headers v1.4.357 && build vulkan-headers
fetch vma GPUOpen-LibrariesAndSDKs/VulkanMemoryAllocator v3.3.0 && build vma
fetch robin-map Tessil/robin-map v1.3.0 && build robin-map
fetch zycore zyantific/zycore-c v1.5.0 && build zycore -DZYCORE_BUILD_SHARED_LIB=OFF
fetch zydis zyantific/zydis v4.1.1
rm -rf "$src/zydis/dependencies/zycore" && ln -s "$src/zycore" "$src/zydis/dependencies/zycore"
build zydis -DZYDIS_BUILD_TOOLS=OFF -DZYDIS_BUILD_EXAMPLES=OFF -DZYDIS_BUILD_SHARED_LIB=OFF
fetch epoll-shim jiixyj/epoll-shim v0.0.20240608 && build epoll-shim -DBUILD_TESTING=OFF
fetch miniupnp miniupnp/miniupnp miniupnpc_2_3_3
cmake -S "$src/miniupnp/miniupnpc" -B "$src/miniupnp/build" "${x86[@]}" -DUPNPC_BUILD_SHARED=OFF \
    -DUPNPC_BUILD_TESTS=OFF -DUPNPC_BUILD_SAMPLE=OFF >/dev/null
cmake --build "$src/miniupnp/build" >/dev/null && cmake --install "$src/miniupnp/build" >/dev/null
echo "Installed miniupnpc"

# mimalloc with all of its memory in [4 GiB, 32 GiB): the guest packs host pointers into 40
# bits (see mimalloc-low-window.patch). Replaces malloc for the whole bb-probe process.
if [[ ! -d $src/mimalloc ]]; then
    fetch mimalloc microsoft/mimalloc v2.2.4
    patch -d "$src/mimalloc" -p1 < "$here/mimalloc-low-window.patch"
fi
build mimalloc -DMI_OVERRIDE=ON -DMI_OSX_ZONE=ON -DMI_OSX_INTERPOSE=ON -DMI_BUILD_STATIC=OFF \
    -DMI_BUILD_OBJECT=OFF -DMI_BUILD_TESTS=OFF \
    "-DCMAKE_C_FLAGS=-DMI_BB_LOW_BASE=0x100000000ULL -DMI_BB_LOW_END=0x800000000ULL"

# KosmicKrisp (Mesa's Vulkan driver on Metal; MoltenVK lacks robustBufferAccess2, which the
# renderer requires). x86_64 builds come with shadPS4's macOS release; the file is checked.
kk=$prefix/lib/libvulkan_kosmickrisp.dylib
kk_sha=01219ee21267301a0a2b598498fb84e45f2686b82e62ab32391bcd52c7895241
if [[ ! -f $kk ]] || [[ $(shasum -a 256 "$kk" | cut -d' ' -f1) != "$kk_sha" ]]; then
    tmp=$(mktemp -d)
    curl -sfL -o "$tmp/shadps4.zip" \
        https://github.com/shadps4-emu/shadPS4/releases/download/v.0.20.0/shadps4-macos-sdl-2026-0.20.0.zip
    unzip -q -o "$tmp/shadps4.zip" libvulkan_kosmickrisp.dylib -d "$tmp"
    [[ $(shasum -a 256 "$tmp/libvulkan_kosmickrisp.dylib" | cut -d' ' -f1) == "$kk_sha" ]] ||
        { echo 'KosmicKrisp download does not match the expected file.' >&2; exit 1; }
    cp "$tmp/libvulkan_kosmickrisp.dylib" "$kk"
    rm -rf "$tmp"
fi
mkdir -p "$prefix/share/vulkan/icd.d"
cat > "$prefix/share/vulkan/icd.d/kosmickrisp_mesa_icd.json" <<'EOF'
{
    "ICD": {
        "api_version": "1.4.363",
        "library_path": "../../../lib/libvulkan_kosmickrisp.dylib"
    },
    "file_format_version": "1.0.1"
}
EOF
echo "Dependencies ready in $prefix"
