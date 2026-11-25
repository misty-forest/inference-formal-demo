# Specify owner authorization on a Soroban Wasm contract

The [specification](proof/create_lock.inf) for the only [public Rust method](src/lib.rs) is:

```rust
spec Locker {
    create_lock requires auth(owner);
}
```

Run the [Inference compiler fork](https://github.com/misty-forest/inference/pull/3) against the [compiled contract](artifacts/locker.wasm):

```sh
infc proof/create_lock.inf --mode proof --proof-subject artifacts/locker.wasm --out-dir target/proof
coqc target/proof/create_lock.v
```

The compiler reads the parameter name and type from Soroban's XDR and matches the signature to the Wasm export. The contract author writes only the clause. There is no adapter, ledger fixture or hand-written Rocq file.

## What is checked, and what remains open

| Generated statement | Evidence |
| --- | --- |
| `guard_1` | Rocq checks that the supported prefix of the actual export calls the Soroban auth import on the original owner. Branches that skip this call go to a trap. |
| `obligation_1` | Every successful execution of this method requires acceptance of the original owner's authorization for this invocation. The proposition is generated and remains **open**. |

The exact operational goal for the prover is:

```coq
Definition obligation_1 : Prop := requires_auth create_lock "create_lock"%string 0%nat.
Goal obligation_1.
```

Slot zero is the original `owner` argument. The [definition of requires_auth](https://github.com/misty-forest/inference/blob/55bc86da21dd4ff33551b9d800978bf07acaa126/core/wasm-to-v/rocq/Authorization.v) uses WasmCert's actual module instantiation and execution relation. It quantifies over hosts, instances, arguments and stores. Remove only successful `require_auth(owner)` transitions in this guest invocation. The remaining executions must never return a value stack from the exported method. An authorization performed internally by another contract during a host-mediated token transfer is outside this invocation. The model trusts Soroban's interpretation of a successful return from the designated auth import.

Rocq also proves that every execution under the restricted host is an execution of the original host (`preserves_execution`). The structural theorem `guard_1` is closed under the global context. The operational definitions use public WasmCert and its standard Coq library assumptions. The remaining work for a native prover is to prove this operational property and connect the resulting theorem to its specification-discharge mechanism. The generated file uses `Abort` for the open goal. A successful `coqc` run certifies `guard_1` only among the two contract claims.

## Controls

| Input | Structural certificate |
| --- | --- |
| Original contract and `auth(owner)` | Accepted |
| Same binary with `auth(token)` | Rejected |
| Rebuild without `owner.require_auth()` | Rejected |
| Rebuild with `if amount != u64::MAX { owner.require_auth(); }` | Rejected |

The structural tactic covers the instruction shapes needed for this example. It can reject a semantically equivalent optimization. The operational goal applies independently of that tactic.

## Reproduce

Use Coq 8.20.1, public WasmCert-Coq v2.2.0 and the pinned fork revision:

```sh
cargo +1.98.0 install --git https://github.com/misty-forest/inference --rev 55bc86da21dd4ff33551b9d800978bf07acaa126 inference-cli
opam pin add -y coq-wasm 'git+https://github.com/WasmCert/WasmCert-Coq.git#0fd83fa708922721132b6d6737179568d1f1d553'
```

The included Wasm has SHA-256 `9f91b545f8bcdb1230263e2791f25b64f4a8445d6f44e0d96a3c6312b97f80b2`. To reproduce a source mutation, rebuild with the pinned Rust toolchain and Stellar CLI 27, then pass the changed Wasm to the same spec:

```sh
stellar contract build --locked --optimize --out-dir target/contract
infc proof/create_lock.inf --mode proof --proof-subject target/contract/inference_formal_demo.wasm --out-dir target/changed
coqc target/changed/create_lock.v
```
