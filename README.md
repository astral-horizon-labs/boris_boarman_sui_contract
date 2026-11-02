# Boris Boarman: authorised fund release on Sui

A Sui Move escrow for releasing funds on approval. An admin approves a grant
(recipient, amount, deadline); the approval **reserves** the amount inside the
treasury, and from that moment the recipient no longer depends on the admin.

- **The recipient claims, nobody pushes.** Only the grant's recipient can
  claim it, up to its deadline.
- **Reserved funds are out of everyone's reach**, the admin included: the admin
  can withdraw or approve only what no grant has reserved, and cannot revoke a
  grant before its deadline.
- **Lapsed grants free their funds.** After the deadline, anyone can expire an
  unclaimed grant; its amount returns to the unreserved balance.
- **Generic over the coin type** (`Treasury<T>`), one `AdminCap` per treasury,
  transferable to hand over the admin role.
- Invariant: `balance >= reserved` after every call.

Written up in [Reviewing my own Move contract, a year later](https://astral-horizon-labs.com/notes/reviewing-my-move-contract),
which explains what was wrong with v1 and why v2 is shaped this way.

## API

Module `boris_boarman::fund_release` ([source](sources/fund_release.move)).

| Function | Who | Effect |
|---|---|---|
| `new<T>(ctx): AdminCap` | anyone | shares an empty `Treasury<T>`, returns its cap |
| `deposit<T>(treasury, coin)` | anyone | adds funds |
| `approve<T>(treasury, cap, recipient, amount, deadline_ms, clock): u64` | cap holder | reserves `amount` for `recipient`, returns the grant id |
| `claim<T>(treasury, grant_id, clock, ctx): Coin<T>` | recipient | pays the grant, until the deadline included |
| `expire<T>(treasury, grant_id, clock)` | anyone | after the deadline, closes the grant and frees its amount |
| `withdraw<T>(treasury, cap, amount, ctx): Coin<T>` | cap holder | takes back unreserved funds only |

Views: `balance`, `reserved`, `available`, `has_grant`, `grant`, `treasury_id`.
Every state change emits an event. Errors are Move 2024 clever errors
(`EInsufficientFunds`: "Not enough unreserved funds in the treasury", ...).

## Testnet

Package [`0x192f…b6cb`](https://suiscan.xyz/testnet/object/0x192ff1cac080085159f04e7727a2629268f79e9ad7ded461c90d379664c9b6cb)
on Sui testnet, exercised end to end:

| Step | Transaction |
|---|---|
| Publish | [`3qG29f…`](https://suiscan.xyz/testnet/tx/3qG29fbVo7di6xaQvpG48F6aECtLwEu3owJTazXfZW6o) |
| Create a `Treasury<SUI>` | [`EFQfmh…`](https://suiscan.xyz/testnet/tx/EFQfmhBzgbKu6FThXykhYQj4yUHKaSUTvSNww9Rg5n4T) |
| Deposit 0.1 SUI, approve two grants (0.05 and 0.02) | [`FcPNWH…`](https://suiscan.xyz/testnet/tx/FcPNWHVxVDC7eAuX6Ja2NuC7j6anV6hmuThwbSJDF5bp) |
| Admin tries to withdraw 0.06 SUI, refused (`EInsufficientFunds`) | [`BM5bHX…`](https://suiscan.xyz/testnet/tx/BM5bHXUuCrhcWZrtyzh1suCZExNrM3qGNmabRok9cT3S) |
| Recipient claims the 0.05 grant | [`HRqZS4…`](https://suiscan.xyz/testnet/tx/HRqZS4UaZ8sx9QaWvjTp4RnkvvAUDPhMWnSNcJLxpieY) |
| The 0.02 grant lapses and is expired | [`J2kr9J…`](https://suiscan.xyz/testnet/tx/J2kr9J8CZHcEDa9bunA4FXw4rqUs4kQuaXtfaWrP4am9) |

## Build and test

```bash
sui move build
sui move test
sui move test --coverage && sui move coverage summary
```

22 tests, 100% line coverage of the module ([tests](tests/fund_release_tests.move)).

## v1

The first version (February 2025) is kept at tag
[`v1-review`](https://github.com/astral-horizon-labs/boris_boarman_sui_contract/tree/v1-review),
with tests that pin down its weaknesses.

## License

MIT, see [LICENSE](LICENSE).
