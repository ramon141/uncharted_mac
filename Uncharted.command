#!/usr/bin/env bash
# macOS: double-click to open the launcher. The first time it prepares the x86_64 libraries
# (packaging/macos/setup-deps.sh) and builds the port (build-macos.sh); later it rebuilds only
# when the sources changed.
set -euo pipefail
cd -- "$(dirname -- "$0")"
prefix=${BB_MAC_PREFIX:-$HOME/.uncharted-x86}
if ! /usr/bin/arch -x86_64 /usr/bin/true 2>/dev/null; then
    echo 'Rosetta 2 is needed: softwareupdate --install-rosetta --agree-to-license' >&2; exit 1
fi
if [[ ! -f $prefix/lib/libvulkan_kosmickrisp.dylib || ! -f $prefix/lib/libmimalloc.dylib ]]; then
    bash packaging/macos/setup-deps.sh
fi
if [[ ! -x out/bb-probe || -n $(find src gpu/shim gpu/shadps4 -newer out/bb-probe -type f -print -quit) ]]; then
    bash build-macos.sh
fi
python=$(command -v python3.14 || command -v python3)
if ! "$python" -c 'import tkinter, PIL' 2>/dev/null; then
    brew install python-tk@3.14
    "$python" -m pip install --user --break-system-packages pillow >/dev/null 2>&1 || true
fi
exec "$python" launcher/uncharted_launcher.py
