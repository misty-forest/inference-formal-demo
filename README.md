# Checking a Soroban authorization guard with Inference

The [Rust contract](src/lib.rs) exports one method, `create_lock`. We want to catch a change that lets this method return without reaching `owner.require_auth()`. The [Inference fork](https://github.com/misty-forest/inference/pull/3) accepts the deployed-format Wasm and the name of the address to check.

```sh
infc artifacts/locker.wasm --soroban-auth create_lock:owner --out-dir target/proof
coqc target/proof/OwnerAuth.v
```

The first command generates the entire Rocq file. The second checks the proof. The contract author supplies `create_lock:owner`. There is no Rust adapter, fixture, amount bound, or handwritten Rocq file.

| Input to the same check | Rocq result |
| --- | --- |
| Original contract, `create_lock:owner` | `Qed` |
| Original contract, `create_lock:token` | Rejected |
| Delete `owner.require_auth();` and rebuild | Rejected |
| Wrap it in `if amount != u64::MAX { ... }` and rebuild | Rejected, even though the auth import is still present |

## What the proof says

The compiler reads the `owner` argument position from `contractspecv0`. The theorem inspects the WasmCert representation of the actual export. It checks that the function loads the original argument and directly calls Soroban's `a.0` (`require_auth`) with it. In the certified prefix, a path that branches around that call leads to `unreachable`. A callee can trap or diverge before reaching the guard.

This is a structural theorem about this binary. The tactic recognizes a limited set of instruction shapes and may reject a differently optimized contract with equivalent behavior. Proving that Soroban validates a grant for the correct invocation, or that a successful lock moves tokens and persists the right record, requires formal host semantics and a theorem about execution. Those properties remain open.

## Reproduce

Build `infc` from the [compiler change](https://github.com/misty-forest/inference/pull/3). Use Coq 8.20.1 and public [WasmCert-Coq v2.2.0](https://github.com/WasmCert/WasmCert-Coq/tree/v2.2.0) in the active opam switch.

```sh
cargo +1.98.0 install --git https://github.com/misty-forest/inference --rev e427195b2df1f5541bdd744a2ce684b30b89ee14 inference-cli
opam pin add -y coq-wasm 'git+https://github.com/WasmCert/WasmCert-Coq.git#0fd83fa708922721132b6d6737179568d1f1d553'
```

The commands at the top use the [included Wasm](artifacts/locker.wasm). Its SHA-256 is `9f91b545f8bcdb1230263e2791f25b64f4a8445d6f44e0d96a3c6312b97f80b2`. To try a source change, rebuild with the pinned Rust toolchain and Stellar CLI 27, then point `infc` at the new artifact.

```sh
stellar contract build --locked --optimize --out-dir target/contract
infc target/contract/inference_formal_demo.wasm --soroban-auth create_lock:owner --out-dir target/changed
coqc target/changed/OwnerAuth.v
```

## Native Inference specifications

The [sidecar](proof/create_lock.inf) shows how a native universal Inference specification can reference the real export. It constrains a realized return to the Soroban ABI encoding of Void, `2`. The `external fn` declaration resolves to the implementation in `locker.wasm`. It uses the raw `i64` Wasm arguments, including encoded Soroban values.

```sh
infc proof/create_lock.inf --mode proof --proof-subject locker \
  --wasm-dep locker=artifacts/locker.wasm --out-dir target/sidecar
```

This emits upstream's `ValidSpec` goal over the original Wasm with its host imports. The generated skeleton contains `Admitted`. Its return-value claim has **not** been discharged, and the implication alone does not establish that a lock can succeed. Inference documents the verifier implementation and discharger as private dependencies. [Upstream pin](https://github.com/Inferara/inference/blob/be016fc05d2b8a1ff4377dd3a90dc148f99f3694/core/wasm-to-v/wasm-verifier-pin.txt)

The earlier [standalone Z3 experiment](https://github.com/misty-forest/inference-formal-demo/tree/03bc879e1549275cb91c927b6b2b2564e754ddd0) is preserved at its original revision.
