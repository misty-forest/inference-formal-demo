#!/bin/sh
set -eu
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
out="$here/../../../target/ice-math"
mkdir -p "$out"
hash=34b68322200c48b70645b06af1e49ac8d7137eea8d60c8b01345da5b30d411c8
case $# in
    0) input="$out/mainnet.wasm"
       stellar contract fetch --rpc-url https://mainnet.sorobanrpc.com \
           --network-passphrase 'Public Global Stellar Network ; September 2015' \
           --wasm-hash "$hash" --out-file "$input" ;;
    1) input=$1 ;;
    *) echo "Usage: $0 [mainnet-locker.wasm]" >&2; exit 2 ;;
esac
printf '%s  %s\n' "$hash" "$input" | shasum -a 256 -c -

# Function 156 takes a result pointer and three u64 arguments. Expose each
# result word through a scalar export understood by the Inference frontend.
wasm-tools print "$input" -o "$out/original.wat"
sed '$d' "$out/original.wat" > "$out/view.wat"
for word in lo hi; do
    offset=0
    if [ "$word" = hi ]; then offset=8; fi
    cat >> "$out/view.wat" <<WAT
  (func (export "bucket_$word") (param i64 i64 i64) (result i64)
    global.get 0 i32.const 16 i32.sub global.set 0
    global.get 0 local.get 0 local.get 1 local.get 2 call 156
    global.get 0 i64.load offset=$offset
    global.get 0 i32.const 16 i32.add global.set 0)
WAT
done
echo ')' >> "$out/view.wat"
wasm-tools parse "$out/view.wat" -o "$out/locker.wasm"
wasm-tools validate "$out/locker.wasm"
infc "$here/model/checkpoints.inf" --mode proof -v --out-dir "$out"
infc "$here/locker/bucket.inf" --mode proof --proof-subject "$out/locker.wasm" --out-dir "$out"
echo 'Generated native Inference obligations. Proof status: open.'
