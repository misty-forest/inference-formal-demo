# Prove owner authorization for a Soroban contract

The public Rust method calls `owner.require_auth()`. The contract author writes one clause in [proof/create_lock.inf](proof/create_lock.inf) for the [existing Rust method](src/lib.rs).

```rust
spec Locker {
    create_lock requires auth(owner);
}
```

## Verify

Install the pinned compiler and public WasmCert library in an opam environment with Coq 8.20.1. Run the check from this checkout.

```sh
cargo +1.98.0 install --git https://github.com/misty-forest/inference --rev 07e23ef6233775c2f51634c9ba42943ac5292f23 inference-cli
opam pin add -y coq-wasm 'git+https://github.com/WasmCert/WasmCert-Coq.git#0fd83fa708922721132b6d6737179568d1f1d553'
./verify.sh
```

The [script](verify.sh) runs `infc` on the spec and [the compiled contract](artifacts/locker.wasm), checks the generated proof with `coqc`, then runs `coqchk` on the compiled proof and its dependencies. The Wasm SHA-256 is `9f91b545f8bcdb1230263e2791f25b64f4a8445d6f44e0d96a3c6312b97f80b2`.

## Verify two exports of the ICE Locker on Mainnet

The [ICE specification](repro/ice/shelves.inf) is the entire input written for these two methods.

```rust
spec Locker {
    commit_shelf requires auth(owner);
    rearm_shelf requires auth(owner);
}
```

With Stellar CLI installed, run the same compiler and public kernel on the deployed Wasm.

```sh
./repro/ice/verify.sh
```

The script fetches the contract code by hash, checks its SHA-256, and verifies both theorems in one generated module. For an offline run, pass a local copy of the same Wasm as the script's argument. The expected hash is `34b68322200c48b70645b06af1e49ac8d7137eea8d60c8b01345da5b30d411c8`.

In this build both exports forward the owner and the position ID to one internal function. A third argument distinguishes the two operations. The proof resolves the helper in the instantiated module, tracks the original owner into the helper's parameter, and checks its call to the Soroban auth import. The two generated theorems are `obligation_1_proved` and `obligation_2_proved`.

### What happens with two internal calls?

| Wasm supplied to the same rule | Internal calls before the auth import | Result |
| --- | ---: | --- |
| Mainnet Locker, `commit_shelf` and `rearm_shelf` | 1 | Both owner clauses proved |
| Compiler regression fixture, owner changes parameter position at each call | 2 | Proved. Swapping the operands passed to the last function makes the proof fail |
| Local rebuild of the unchanged ICE Locker, `commit_shelf` | 2 | Could not prove the owner clause |

From an ICE checkout at `ffbb3346c0c5fa1d2759f934442787ab3da833ab`, we built the local artifact with Rust 1.96.0 and Stellar CLI 27.0.0.

```sh
CARGO_PROFILE_RELEASE_LTO=false CARGO_PROFILE_RELEASE_OPT_LEVEL=z \
    stellar contract build --locked --package soroban-token-timelock-contract --out-dir target/local-ice
```

Its Wasm SHA-256 is `d241824b0b4d8734786d2ac41acadd6a2ef09de57fa45fa9a9a76c877aa7dc68`. In that binary `commit_shelf` (254) calls 511, which calls 425, which loads the address from linear memory and calls the auth import (5). Checking this build requires tracking the original owner through stores, an intervening helper call, and loads. The current certificate tracks locals and numeric operands. The tactic cannot construct the certificate for this body. The compiler regression is in [the fork’s CLI tests](https://github.com/misty-forest/inference/blob/07e23ef6233775c2f51634c9ba42943ac5292f23/core/cli/tests/proof_subject.rs#L137).

With that local Wasm, use the same spec directly. The Mainnet script above pins the deployed artifact.

```sh
infc repro/ice/shelves.inf --mode proof --proof-subject "$LOCKER_WASM" --out-dir target/local-ice
coqc target/local-ice/shelves.v
```

## What the theorem says

Take any call to this Wasm export with its four arguments, any admissible deployed instance and host state. If the host refuses every successful `require_auth(owner)` for the original owner in this invocation, `create_lock` cannot return values. The theorem covers all amounts and unlock times. A call can still trap or diverge. It trusts Soroban to interpret a successful return from the bound auth import as authorization.

An ordinary auth test can check the owner and invocation tree for one successful lock. The proof also covers amounts the test never tried, including `u64::MAX`. A method that always traps would satisfy this theorem. Keep the successful-lock test for token balances, stored state, and the actual Soroban auth tree.

The compiler resolves the owner parameter by name from Soroban XDR. WasmCert links the export and the host import in the live store, enters the function with its ABI arguments, and follows the original owner through Wasm frames and branches. Fixing the ABI arity matters because Wasm allows additional operands below the callee's arguments on a caller's stack.

```coq
Theorem obligation_1_proved : obligation_1.
Proof. exact (AuthCertificate.sound _ _ _ guard_1). Qed.
```

Inspect the theorem in the generated module:

```sh
(cd target/proof && echo 'Require Import create_lock. Print Assumptions obligation_1_proved.' | coqtop -quiet)
```

The proof inherits four Coq library assumptions and five WasmCert SIMD primitives. It introduces no project axioms. The generic theorem, its proof tactic, and the Wasm instruction shapes it handles live in the [compiler fork](https://github.com/misty-forest/inference/pull/3).

## Checks on the build

| Spec or change | Kernel result |
| --- | --- |
| `create_lock requires auth(owner)` on the included Wasm | Proved |
| Request authorization of `token` instead | Rejected |
| Rebuild without `owner.require_auth()` | Rejected |
| Rebuild with `if amount != u64::MAX { owner.require_auth(); }` | Rejected |

To check a source change, build with the pinned Rust toolchain and Stellar CLI 27, then verify the new Wasm:

```sh
stellar contract build --locked --optimize --out-dir target/contract
infc proof/create_lock.inf --mode proof --proof-subject target/contract/inference_formal_demo.wasm --out-dir target/changed
coqc target/changed/create_lock.v
```

## Inference integration

The native prover can consume the checked theorem for the same Wasm and clause and report that result in its verification pipeline. The public fork currently produces a stand-alone Rocq proof. Its tactic handles function-only imports, a supported guarded prefix, and finite chains of internal forwarding calls that pass locals or numeric constants. An unsupported program shape can cause proof search to fail even when a contract is safe.
