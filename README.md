# Proving a Soroban lock with Inference

Can we prove what a public Rust/Soroban method does to custody and authorization by giving Inference the ordinary contract Wasm and a short specification?

[The contract](src/lib.rs) has one public method, `create_lock(owner, token, amount, unlock_time)`. The owner authorizes the call. The method checks the amount and deadline, transfers the tokens to the contract and stores a lock under the owner/token pair. This example exists only to discuss verification and has no withdrawal method.

**Current result with infc 0.0.6.** The [Inference specification](proof/create_lock.inf) parses and type-checks. The backend stops before emitting a Rocq obligation for either property. Both commands below reproduce a missing capability.

## What the prover should establish

For every `u64` amount, ledger timestamp and unlock time with `amount > 0` and `unlock_time > now`, start with distinct owner and locker addresses, a standard Stellar Asset Contract, owner balance equal to the symbolic amount, locker balance zero and no existing lock. Assume a valid ledger, live entries and sufficient execution resources.

| Owner's authorization | Required outcome |
| --- | --- |
| Exact call and its nested token transfer | The invocation succeeds and consumes that authorization tree. The owner ends with zero, the locker receives the entire amount, and the stored record contains exactly the supplied amount and deadline. |
| No grant, or a grant for any different `u64` amount | The invocation fails, both balances retain their initial values and the lock remains absent. |

The success property also requires the call to complete. An implementation that rejects every invocation would violate it. The funding assumption scopes the claim to a fresh, fully funded owner. There is no table of example amounts.

## Reproduce with the stock compiler

From this repository's root, with [infc 0.0.6](https://github.com/Inferara/inference/releases/tag/v0.0.6) on PATH, use the included [compiled contract](artifacts/locker.wasm).

**1. Submit the universal properties.**

```sh
infc proof/create_lock.inf --mode proof \
  --wasm-dep locker=artifacts/locker.wasm --out-dir target/proof
```

Observed diagnostic: `Host imports are not yet modeled in the proof translation.` The `host::soroban` declarations in the spec describe a **proposed proof interface**. They have no mock implementation. Each balance or lock observer must read the actual modeled state after the call. The exact-grant observer must compare the consumed authorization trace with the installed grant. The fallible binding must dispatch the same Wasm export and expose failure after transaction rollback.

**2. Isolate the linker without any proof-host declarations.**

```sh
infc repro/link_only.inf --mode proof \
  --wasm-dep locker=artifacts/locker.wasm --out-dir target/link
```

Observed diagnostic: ``merged function transitively imports `a::0`, which has no body to merge``. This is the contract's call to [Soroban require_auth](https://docs.rs/crate/soroban-env-common/29.0.1/source/env.json). The probe only forwards the four raw ABI words to the actual export. This isolates the linking issue from ledger setup and assertions.

## What would make this usable

1. **Generate typed bindings from the embedded contract spec.** The author should write a call using addresses and the full `u64` domain. Binding generation can handle tagged `Val` words, host objects and the encoded void result. Token balances use signed 128-bit amounts.
2. **Supply a proof-time Soroban ledger.** A symbolic funded state, the ledger clock, persistent storage and a standard token model would let the verifier derive the state transition of the linked contract. The contract can rely on the standard asset's specified transfer semantics. State this dependency as a proof assumption.
3. **Expose the invocation result and authorization trace.** The author needs to express who must authorize which arguments and nested calls, then observe success, failure and rolled-back state. A missing proof model should identify the unresolved host operation.

A useful acceptance check would be to discharge both properties on these contract bytes, then show a counterexample when the contract records the wrong amount. Today the Rust contract builds and both proof attempts stop at the diagnostics above.

## Rebuild the Wasm

Use Rust 1.96.0, the `wasm32v1-none` target, and Stellar CLI 27.0.0 with optimization support.

```sh
stellar contract build --locked --optimize --out-dir target/contract
cmp artifacts/locker.wasm target/contract/inference_formal_demo.wasm
```

The reference build exports one contract method, `create_lock`. The committed artifact is 1,477 bytes. Its SHA-256 is `9f91b545f8bcdb1230263e2791f25b64f4a8445d6f44e0d96a3c6312b97f80b2`.
