/// Authorised fund release, as an escrow the contract enforces.
///
/// A `Treasury<T>` holds the funds. The holder of its `AdminCap` approves a
/// grant: an amount, a recipient and a deadline. Approval reserves the amount
/// inside the treasury, so from that moment the recipient no longer depends on
/// the admin: they claim the grant themselves, and nobody, the admin included,
/// can spend reserved funds or revoke the grant before its deadline. After the
/// deadline anyone can expire an unclaimed grant, which frees the reservation.
///
/// Invariant: `balance >= reserved` at the end of every function.
module boris_boarman::fund_release;

use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::event;
use sui::table::{Self, Table};

#[error]
const EWrongTreasury: vector<u8> = b"This AdminCap belongs to another treasury";
#[error]
const EZeroAmount: vector<u8> = b"Amount must be greater than zero";
#[error]
const EInsufficientFunds: vector<u8> = b"Not enough unreserved funds in the treasury";
#[error]
const EDeadlinePassed: vector<u8> = b"Deadline must be in the future";
#[error]
const EGrantNotFound: vector<u8> = b"No grant with this id";
#[error]
const ENotRecipient: vector<u8> = b"Only the grant's recipient can claim it";
#[error]
const EGrantExpired: vector<u8> = b"The grant's deadline has passed";
#[error]
const EGrantNotExpired: vector<u8> = b"The grant can still be claimed";

/// Shared object holding the funds and the open grants.
public struct Treasury<phantom T> has key {
    id: UID,
    balance: Balance<T>,
    /// Sum of the amounts of all open grants.
    reserved: u64,
    grants: Table<u64, Grant>,
    next_grant_id: u64,
}

/// Authority over one treasury. Transferring it hands over the admin role.
public struct AdminCap has key, store {
    id: UID,
    treasury_id: ID,
}

/// An approved, unclaimed release. Removed from the table once claimed or
/// expired, so its storage is refunded.
public struct Grant has store, drop {
    recipient: address,
    amount: u64,
    deadline_ms: u64,
}

public struct TreasuryCreated has copy, drop { treasury_id: ID }
public struct Deposited has copy, drop { treasury_id: ID, amount: u64 }
public struct Withdrawn has copy, drop { treasury_id: ID, amount: u64 }
public struct GrantApproved has copy, drop {
    treasury_id: ID,
    grant_id: u64,
    recipient: address,
    amount: u64,
    deadline_ms: u64,
}
public struct GrantClaimed has copy, drop {
    treasury_id: ID,
    grant_id: u64,
    recipient: address,
    amount: u64,
    timestamp_ms: u64,
}
public struct GrantExpired has copy, drop {
    treasury_id: ID,
    grant_id: u64,
    amount: u64,
    timestamp_ms: u64,
}

/// Creates and shares an empty treasury for coin type `T`, and returns the
/// capability that administers it.
public fun new<T>(ctx: &mut TxContext): AdminCap {
    let treasury = Treasury<T> {
        id: object::new(ctx),
        balance: balance::zero(),
        reserved: 0,
        grants: table::new(ctx),
        next_grant_id: 0,
    };
    let treasury_id = object::id(&treasury);
    event::emit(TreasuryCreated { treasury_id });
    transfer::share_object(treasury);
    AdminCap { id: object::new(ctx), treasury_id }
}

/// Adds funds. Anyone can fund a treasury.
public fun deposit<T>(treasury: &mut Treasury<T>, payment: Coin<T>) {
    let amount = payment.value();
    assert!(amount > 0, EZeroAmount);
    treasury.balance.join(payment.into_balance());
    event::emit(Deposited { treasury_id: object::id(treasury), amount });
}

/// Takes back funds that no grant has reserved.
public fun withdraw<T>(
    treasury: &mut Treasury<T>,
    cap: &AdminCap,
    amount: u64,
    ctx: &mut TxContext,
): Coin<T> {
    assert_cap(treasury, cap);
    assert!(amount > 0, EZeroAmount);
    assert!(amount <= treasury.available(), EInsufficientFunds);
    event::emit(Withdrawn { treasury_id: object::id(treasury), amount });
    coin::take(&mut treasury.balance, amount, ctx)
}

/// Approves a release to `recipient`, claimable until `deadline_ms`, and
/// reserves the amount. Returns the grant id.
public fun approve<T>(
    treasury: &mut Treasury<T>,
    cap: &AdminCap,
    recipient: address,
    amount: u64,
    deadline_ms: u64,
    clock: &Clock,
): u64 {
    assert_cap(treasury, cap);
    assert!(amount > 0, EZeroAmount);
    assert!(amount <= treasury.available(), EInsufficientFunds);
    assert!(deadline_ms > clock.timestamp_ms(), EDeadlinePassed);

    let grant_id = treasury.next_grant_id;
    treasury.next_grant_id = grant_id + 1;
    treasury.reserved = treasury.reserved + amount;
    treasury.grants.add(grant_id, Grant { recipient, amount, deadline_ms });

    event::emit(GrantApproved {
        treasury_id: object::id(treasury),
        grant_id,
        recipient,
        amount,
        deadline_ms,
    });
    grant_id
}

/// Pays a grant to its recipient, who must be the sender, before the deadline.
public fun claim<T>(
    treasury: &mut Treasury<T>,
    grant_id: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    assert!(treasury.grants.contains(grant_id), EGrantNotFound);
    let grant = &treasury.grants[grant_id];
    assert!(grant.recipient == ctx.sender(), ENotRecipient);
    let now = clock.timestamp_ms();
    assert!(now <= grant.deadline_ms, EGrantExpired);

    let Grant { recipient, amount, deadline_ms: _ } = treasury.grants.remove(grant_id);
    treasury.reserved = treasury.reserved - amount;

    event::emit(GrantClaimed {
        treasury_id: object::id(treasury),
        grant_id,
        recipient,
        amount,
        timestamp_ms: now,
    });
    coin::take(&mut treasury.balance, amount, ctx)
}

/// Closes a grant whose deadline has passed and frees its reservation. Anyone
/// can call it: it only returns funds to the treasury's unreserved balance.
public fun expire<T>(treasury: &mut Treasury<T>, grant_id: u64, clock: &Clock) {
    assert!(treasury.grants.contains(grant_id), EGrantNotFound);
    let now = clock.timestamp_ms();
    assert!(now > treasury.grants[grant_id].deadline_ms, EGrantNotExpired);

    let Grant { amount, .. } = treasury.grants.remove(grant_id);
    treasury.reserved = treasury.reserved - amount;

    event::emit(GrantExpired {
        treasury_id: object::id(treasury),
        grant_id,
        amount,
        timestamp_ms: now,
    });
}

// === Views ===

/// Funds held, reserved or not.
public fun balance<T>(treasury: &Treasury<T>): u64 { treasury.balance.value() }

/// Funds reserved by open grants.
public fun reserved<T>(treasury: &Treasury<T>): u64 { treasury.reserved }

/// Funds the admin can still approve or withdraw.
public fun available<T>(treasury: &Treasury<T>): u64 {
    treasury.balance.value() - treasury.reserved
}

public fun has_grant<T>(treasury: &Treasury<T>, grant_id: u64): bool {
    treasury.grants.contains(grant_id)
}

/// Recipient, amount and deadline of an open grant.
public fun grant<T>(treasury: &Treasury<T>, grant_id: u64): (address, u64, u64) {
    assert!(treasury.grants.contains(grant_id), EGrantNotFound);
    let grant = &treasury.grants[grant_id];
    (grant.recipient, grant.amount, grant.deadline_ms)
}

public fun treasury_id(cap: &AdminCap): ID { cap.treasury_id }

fun assert_cap<T>(treasury: &Treasury<T>, cap: &AdminCap) {
    assert!(cap.treasury_id == object::id(treasury), EWrongTreasury);
}
