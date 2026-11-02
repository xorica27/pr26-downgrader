#!/bin/bash
# Download a pinned, checksum-verified standalone CPython for both Apple Silicon
# and Intel, trim it to what the engine needs, and merge the two into one
# universal runtime at build/python-universal.
#
# Source: https://github.com/astral-sh/python-build-standalone
set -euo pipefail

PY_VERSION="3.12.16"
PBS_RELEASE="20261026"
SHA_ARM64="353d5f1b4fd2715e7053f12f068435d5bbad16b91e057006b5d01e0925709a7e"
SHA_X86_64="37c38fda76fec1fbf310adcbafb7f0d96af13b5511bf8ea954c3aa8eec185734"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/build/python-cache"
OUT="$ROOT/build/python-universal"
STAMP="$OUT/.stamp"
WANT_STAMP="$PY_VERSION+$PBS_RELEASE"

if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANT_STAMP" ]; then
    echo "Python runtime up to date ($WANT_STAMP)"
    exit 0
fi

mkdir -p "$CACHE"

fetch() {  # arch sha
    local arch="$1" sha="$2"
    local name="cpython-$PY_VERSION+$PBS_RELEASE-$arch-apple-darwin-install_only_stripped.tar.gz"
    local file="$CACHE/$name"
    if [ ! -f "$file" ]; then
        echo "Downloading $name…" >&2
        curl -fsSL --retry 3 -o "$file.part" \
            "https://github.com/astral-sh/python-build-standalone/releases/download/$PBS_RELEASE/$name"
        mv "$file.part" "$file"
    fi
    echo "$sha  $file" | shasum -a 256 -c - >/dev/null || {
        echo "error: checksum mismatch for $name" >&2
        rm -f "$file"
        exit 1
    }
    rm -rf "$CACHE/$arch"
    mkdir -p "$CACHE/$arch"
    tar -xzf "$file" -C "$CACHE/$arch"
    trim "$CACHE/$arch/python"
}

trim() {  # prefix
    local p="$1"
    local lib="$p/lib/python3.12"
    # The python executable is statically linked; libpython and Tcl/Tk are unused.
    rm -rf "$p/include" "$p/share" "$p/lib/pkgconfig" \
        "$p/lib/libpython3.12.dylib" "$p/lib"/libtcl* "$p/lib"/tcl* "$p/lib"/tk* \
        "$p/lib"/itcl* "$p/lib"/thread*
    find "$p/bin" -mindepth 1 ! -name python3.12 -delete
    ln -s python3.12 "$p/bin/python3"
    # Stdlib packages the engine never imports.
    rm -rf "$lib"/{site-packages,ensurepip,idlelib,tkinter,turtledemo,lib2to3,pydoc_data,test} \
        "$lib"/{unittest,venv,sqlite3,curses,dbm,wsgiref,xmlrpc,asyncio,multiprocessing} \
        "$lib"/{email,http,concurrent,html,zoneinfo,tomllib,__phello__} \
        "$lib"/config-3.12-darwin "$lib"/turtle.py "$lib"/pydoc.py
    find "$lib/lib-dynload" \( -name '_tkinter*' -o -name '_sqlite3*' -o -name '_curses*' \
        -o -name '_dbm*' -o -name '_gdbm*' -o -name '_test*' -o -name 'xx*' \) -delete
    find "$p" -name __pycache__ -type d -prune -exec rm -rf {} +
}

fetch aarch64 "$SHA_ARM64"
fetch x86_64 "$SHA_X86_64"

echo "Merging into a universal runtime…" >&2
rm -rf "$OUT"
cp -R "$CACHE/aarch64/python" "$OUT"
( cd "$CACHE/aarch64/python" && find . -type f ) | while read -r rel; do
    if file "$OUT/$rel" | grep -q 'Mach-O'; then
        lipo -create "$CACHE/aarch64/python/$rel" "$CACHE/x86_64/python/$rel" -output "$OUT/$rel"
    fi
done

# Precompile the stdlib. The bundle is signed, so Python must never write
# bytecode at runtime; unchecked-hash .pyc files stay valid without mtimes.
"$OUT/bin/python3" -I -m compileall -q --invalidation-mode unchecked-hash \
    "$OUT/lib/python3.12" >/dev/null

echo "$WANT_STAMP" > "$STAMP"
echo "Python runtime ready: $OUT ($(du -sh "$OUT" | cut -f1))" >&2
