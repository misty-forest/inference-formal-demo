# Proving a Soroban lock with Inference

[The Rust contract](src/lib.rs) has one public method, `create_lock(owner, token, amount, unlock_time)`. It requires owner authorization, transfers tokens into custody and stores the amount and deadline. The [specification](proof/create_lock.inf) runs against the [compiled contract](artifacts/locker.wasm) using a [symbolic backend in the Inference fork](https://github.com/misty-forest/inference/tree/1743fc54be6e0dad854d42c290f8f2aa9d0154c0/contrib/soroban-proof).

[Implementation PR in the Inference fork](https://github.com/misty-forest/inference/pull/2).

The contract author writes the initial conditions, the permitted invocations and the assertions. For example, these are the actual postconditions after a successful call:

```rust
assert(auth_consumed());
assert(balance_u64(OWNER) == 0);
assert(balance_u64(LOCKER) == amount);
assert(stored_u64(OWNER, TOKEN, field("amount")) == amount);
assert(stored_u64(OWNER, TOKEN, field("unlock_time")) == end);
```

## Run the proof

Install [infc 0.0.6](https://github.com/Inferara/inference/releases/tag/v0.0.6), Stellar CLI 27, WABT (`wasm2wat`) and Python 3.10 or later. From this repository's root:

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install 'git+https://github.com/misty-forest/inference.git@1743fc54be6e0dad854d42c290f8f2aa9d0154c0#subdirectory=contrib/soroban-proof'
infs-soroban-prove artifacts/locker.wasm proof/create_lock.inf
```

Observed output:

```text
PROVED funded_lock (9 admitted symbolic paths)
PROVED unauthorized_lock (8 admitted symbolic paths)
```

The fork compiles the scenarios with `infc` and symbolically executes the resulting instructions together with the supplied contract Wasm. Z3 considers every feasible branch under the preconditions. The numbers count branches through the programs. Each can represent many input values.

## What is proved

For every positive `u64` amount and all `u64` timestamps with `end > now`, start with distinct owner, token and locker identities. The owner holds exactly the requested amount, the locker holds zero and its storage is empty.

| Authorization | Required outcome |
| --- | --- |
| Exact root call and nested transfer | The call succeeds, consumes both grant nodes, moves exactly the requested amount and writes the matching amount and time under the owner/token key. |
| No grant, or a grant for any different amount | The call fails. Both balances retain their initial values and the persistent key remains absent. |

This is a solver-backed proof under a handwritten model of the relevant protocol 29 host calls, one standard asset and transaction rollback. It assumes valid credentials for installed grants, live entries and sufficient execution resources. Signature cryptography, arbitrary token code and pre-existing positions are outside the claim. The model and the Wasm interpreter are trusted prototype code. This backend emits a solver result, without a Rocq certificate.

## Where the functions come from

The fork reads `contractspecv0` and generates bindings for `create_lock`, `try_create_lock` and `authorize_create_lock`. The first two invoke the contract's actual export. The third describes the permitted invocation.

`balance_u64` reads the signed 128-bit balance in the model and checks that it fits in u64. The implemented Soroban `transfer` host call updates the same balance. `stored_u64` reads the map written by the contract's actual storage call, including the field names decoded from Wasm memory. Both observers are supplied by the fork. There are no handwritten contract adapters or external declarations in the spec. [Host implementation](https://github.com/misty-forest/inference/blob/1743fc54be6e0dad854d42c290f8f2aa9d0154c0/contrib/soroban-proof/soroban_proof/ledger.py)

## Try to falsify it

In `src/lib.rs`, change the stored amount to `amount: if amount == u64::MAX { 0 } else { amount }`. Keep the token transfer and the spec unchanged. With Rust 1.96.0 and the `wasm32v1-none` target, rebuild and check the changed artifact:

```sh
stellar contract build --locked --optimize --out-dir target/contract
infs-soroban-prove target/contract/inference_formal_demo.wasm proof/create_lock.inf
```

The verifier exits 1 and reports a counterexample with `amount = 18446744073709551615`, at the assertion on the stored amount. Replaying that input on an independent local Soroban SDK host confirmed that the locker received the full amount and stored zero.

The original optimized Wasm is 1,477 bytes, SHA-256 `9f91b545f8bcdb1230263e2791f25b64f4a8445d6f44e0d96a3c6312b97f80b2`. With the original source, the build command above reproduces it.

The [stock linker reproducer](repro/link_only.inf) remains available to compare the fork with upstream. Stock `infc 0.0.6` invoked as `infc repro/link_only.inf --mode proof --wasm-dep locker=artifacts/locker.wasm --out-dir target/link` stops at Soroban's `a::0` (`require_auth`).
