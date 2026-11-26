#!/bin/sh
set -eu
if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [locker.wasm]" >&2
    exit 2
fi
caller_dir=$PWD
cd "$(dirname "$0")/../.."
out=target/ice
mkdir -p "$out"
hash=34b68322200c48b70645b06af1e49ac8d7137eea8d60c8b01345da5b30d411c8
wasm="$out/locker.wasm"
if [ "$#" -eq 1 ]; then
    case "$1" in
        /*) wasm=$1 ;;
        *) wasm="$caller_dir/$1" ;;
    esac
else
    stellar contract fetch --rpc-url https://mainnet.sorobanrpc.com \
        --network-passphrase 'Public Global Stellar Network ; September 2015' \
        --wasm-hash "$hash" --out-file "$wasm"
fi
printf '%s  %s\n' "$hash" "$wasm" | shasum -a 256 -c -
infc repro/ice/shelves.inf --mode proof --proof-subject "$wasm" --out-dir "$out"
cd "$out"
coqc shelves.v
coqchk -silent shelves
