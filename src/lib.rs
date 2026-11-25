#![no_std]

use soroban_sdk::{contract, contractimpl, contracttype, token, Address, Env};

#[contracttype]
pub struct Lock {
    pub amount: u64,
    pub unlock_time: u64,
}

#[contract]
pub struct Locker;

#[contractimpl]
impl Locker {
    pub fn create_lock(env: Env, owner: Address, token: Address, amount: u64, unlock_time: u64) {
        owner.require_auth();
        assert!(amount > 0 && unlock_time > env.ledger().timestamp());

        let key = (owner.clone(), token.clone());
        let locks = env.storage().persistent();
        assert!(!locks.has(&key));

        token::Client::new(&env, &token).transfer(
            &owner,
            env.current_contract_address(),
            &i128::from(amount),
        );
        let lock = Lock {
            amount,
            unlock_time,
        };
        locks.set(&key, &lock);
    }
}
