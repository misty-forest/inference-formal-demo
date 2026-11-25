#!/bin/sh
set -eu
cd "$(dirname "$0")"
infc proof/create_lock.inf --mode proof --proof-subject artifacts/locker.wasm --out-dir target/proof
cd target/proof
coqc create_lock.v
coqchk -silent create_lock
