#[test_only]
module boris_boarman::fund_release_tests;

use boris_boarman::fund_release::{Self, Treasury, AdminCap};
use std::unit_test::{assert_eq, destroy};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::test_scenario::{Self as ts, Scenario};

/// A coin type of our own: the treasury is generic, not SUI-only.
public struct USDX has drop {}

const ADMIN: address = @0xAD;
const ALICE: address = @0xA1;
const BOB: address = @0xB0;
const NEW_ADMIN: address = @0xAE;

const DAY_MS: u64 = 86_400_000;

// === Helpers ===

/// Treasury with `funded` USDX, AdminCap with ADMIN, clock at t = 1 day.
fun setup(funded: u64): (Scenario, Clock) {
    let mut s = ts::begin(ADMIN);
    let cap = fund_release::new<USDX>(s.ctx());
    transfer::public_transfer(cap, ADMIN);
    let mut clock = clock::create_for_testing(s.ctx());
    clock.set_for_testing(DAY_MS);
    if (funded > 0) {
        s.next_tx(ALICE);
        let mut t = s.take_shared<Treasury<USDX>>();
        t.deposit(coin::mint_for_testing<USDX>(funded, s.ctx()));
        ts::return_shared(t);
    };
    (s, clock)
}

/// ADMIN approves `amount` to `recipient`, claimable for one day.
fun approve(s: &mut Scenario, clock: &Clock, recipient: address, amount: u64): u64 {
    s.next_tx(ADMIN);
    let mut t = s.take_shared<Treasury<USDX>>();
    let cap = s.take_from_sender<AdminCap>();
    let id = t.approve(&cap, recipient, amount, clock.timestamp_ms() + DAY_MS, clock);
    s.return_to_sender(cap);
    ts::return_shared(t);
    id
}

fun claim_as(s: &mut Scenario, clock: &Clock, who: address, grant_id: u64) {
    s.next_tx(who);
    let mut t = s.take_shared<Treasury<USDX>>();
    let paid = t.claim(grant_id, clock, s.ctx());
    transfer::public_transfer(paid, who);
    ts::return_shared(t);
}

fun assert_amounts(s: &mut Scenario, balance: u64, reserved: u64) {
    s.next_tx(ADMIN);
    let t = s.take_shared<Treasury<USDX>>();
    assert_eq!(t.balance(), balance);
    assert_eq!(t.reserved(), reserved);
    assert_eq!(t.available(), balance - reserved);
    ts::return_shared(t);
}

fun finish(s: Scenario, clock: Clock) {
    clock.destroy_for_testing();
    s.end();
}

// === Funding ===

#[test]
fun deposit_adds_to_the_unreserved_balance() {
    let (mut s, clock) = setup(1_000);
    assert_amounts(&mut s, 1_000, 0);
    finish(s, clock);
}

#[test, expected_failure(abort_code = fund_release::EZeroAmount)]
fun deposit_of_zero_aborts() {
    let (mut s, _clock) = setup(0);
    s.next_tx(ALICE);
    let mut t = s.take_shared<Treasury<USDX>>();
    t.deposit(coin::zero<USDX>(s.ctx()));
    abort
}

// === Approval reserves funds ===

#[test]
fun approve_reserves_the_amount() {
    let (mut s, clock) = setup(1_000);
    let id = approve(&mut s, &clock, BOB, 400);
    assert_amounts(&mut s, 1_000, 400);

    s.next_tx(ADMIN);
    let t = s.take_shared<Treasury<USDX>>();
    let (recipient, amount, deadline) = t.grant(id);
    assert_eq!(recipient, BOB);
    assert_eq!(amount, 400);
    assert_eq!(deadline, 2 * DAY_MS);
    ts::return_shared(t);
    finish(s, clock);
}

#[test, expected_failure(abort_code = fund_release::EInsufficientFunds)]
fun approve_cannot_reserve_more_than_is_unreserved() {
    let (mut s, clock) = setup(1_000);
    approve(&mut s, &clock, BOB, 700);
    approve(&mut s, &clock, ALICE, 301); // 300 left unreserved
    abort
}

#[test, expected_failure(abort_code = fund_release::EZeroAmount)]
fun approve_of_zero_aborts() {
    let (mut s, clock) = setup(1_000);
    approve(&mut s, &clock, BOB, 0);
    abort
}

#[test, expected_failure(abort_code = fund_release::EDeadlinePassed)]
fun approve_with_a_past_deadline_aborts() {
    let (mut s, clock) = setup(1_000);
    s.next_tx(ADMIN);
    let mut t = s.take_shared<Treasury<USDX>>();
    let cap = s.take_from_sender<AdminCap>();
    t.approve(&cap, BOB, 100, clock.timestamp_ms(), &clock);
    abort
}

#[test, expected_failure(abort_code = fund_release::EWrongTreasury)]
fun a_cap_cannot_approve_on_another_treasury() {
    let (mut s, clock) = setup(1_000);
    s.next_tx(ADMIN);
    let cap = s.take_from_sender<AdminCap>();
    let admins_treasury_id = cap.treasury_id();
    s.return_to_sender(cap);
    // ALICE creates her own treasury: her cap does not open ADMIN's.
    s.next_tx(ALICE);
    let alices_cap = fund_release::new<USDX>(s.ctx());
    s.next_tx(ALICE);
    let mut t = s.take_shared_by_id<Treasury<USDX>>(admins_treasury_id);
    t.approve(&alices_cap, ALICE, 100, 2 * DAY_MS, &clock);
    abort
}

// === Claiming ===

#[test]
fun the_recipient_claims_exactly_the_grant() {
    let (mut s, clock) = setup(1_000);
    let id = approve(&mut s, &clock, BOB, 400);
    claim_as(&mut s, &clock, BOB, id);

    s.next_tx(BOB);
    let paid = s.take_from_sender<Coin<USDX>>();
    assert_eq!(paid.value(), 400);
    destroy(paid);
    assert_amounts(&mut s, 600, 0);

    s.next_tx(ADMIN);
    let t = s.take_shared<Treasury<USDX>>();
    assert!(!t.has_grant(id));
    ts::return_shared(t);
    finish(s, clock);
}

#[test]
fun claim_works_up_to_the_deadline_included() {
    let (mut s, mut clock) = setup(1_000);
    let id = approve(&mut s, &clock, BOB, 400);
    clock.increment_for_testing(DAY_MS);
    claim_as(&mut s, &clock, BOB, id);
    assert_amounts(&mut s, 600, 0);
    finish(s, clock);
}

#[test, expected_failure(abort_code = fund_release::ENotRecipient)]
fun only_the_recipient_can_claim() {
    let (mut s, clock) = setup(1_000);
    let id = approve(&mut s, &clock, BOB, 400);
    claim_as(&mut s, &clock, ALICE, id);
    abort
}

#[test, expected_failure(abort_code = fund_release::ENotRecipient)]
fun the_admin_cannot_claim_a_grant_either() {
    let (mut s, clock) = setup(1_000);
    let id = approve(&mut s, &clock, BOB, 400);
    claim_as(&mut s, &clock, ADMIN, id);
    abort
}

#[test, expected_failure(abort_code = fund_release::EGrantNotFound)]
fun a_grant_pays_only_once() {
    let (mut s, clock) = setup(1_000);
    let id = approve(&mut s, &clock, BOB, 400);
    claim_as(&mut s, &clock, BOB, id);
    claim_as(&mut s, &clock, BOB, id);
    abort
}

#[test, expected_failure(abort_code = fund_release::EGrantExpired)]
fun claim_after_the_deadline_aborts() {
    let (mut s, mut clock) = setup(1_000);
    let id = approve(&mut s, &clock, BOB, 400);
    clock.increment_for_testing(DAY_MS + 1);
    claim_as(&mut s, &clock, BOB, id);
    abort
}

#[test, expected_failure(abort_code = fund_release::EGrantNotFound)]
fun views_abort_with_the_module_error_on_an_unknown_grant() {
    let (mut s, _clock) = setup(1_000);
    s.next_tx(ADMIN);
    let t = s.take_shared<Treasury<USDX>>();
    t.grant(7);
    abort
}

// === Reserved funds are out of the admin's reach ===

#[test]
fun withdraw_takes_only_unreserved_funds() {
    let (mut s, clock) = setup(1_000);
    approve(&mut s, &clock, BOB, 400);
    s.next_tx(ADMIN);
    let mut t = s.take_shared<Treasury<USDX>>();
    let cap = s.take_from_sender<AdminCap>();
    let back = t.withdraw(&cap, 600, s.ctx());
    assert_eq!(back.value(), 600);
    destroy(back);
    s.return_to_sender(cap);
    ts::return_shared(t);
    assert_amounts(&mut s, 400, 400);
    finish(s, clock);
}

#[test, expected_failure(abort_code = fund_release::EInsufficientFunds)]
fun withdraw_cannot_touch_reserved_funds() {
    let (mut s, clock) = setup(1_000);
    approve(&mut s, &clock, BOB, 400);
    s.next_tx(ADMIN);
    let mut t = s.take_shared<Treasury<USDX>>();
    let cap = s.take_from_sender<AdminCap>();
    let _back = t.withdraw(&cap, 601, s.ctx());
    abort
}

#[test]
fun a_grant_survives_the_admin_role_changing_hands() {
    let (mut s, clock) = setup(1_000);
    let id = approve(&mut s, &clock, BOB, 400);
    // ADMIN hands the cap over; the new admin drains what it can.
    s.next_tx(ADMIN);
    let cap = s.take_from_sender<AdminCap>();
    transfer::public_transfer(cap, NEW_ADMIN);
    s.next_tx(NEW_ADMIN);
    let mut t = s.take_shared<Treasury<USDX>>();
    let cap = s.take_from_sender<AdminCap>();
    let unreserved = t.available();
    destroy(t.withdraw(&cap, unreserved, s.ctx()));
    s.return_to_sender(cap);
    ts::return_shared(t);
    // BOB's grant is still fully backed.
    claim_as(&mut s, &clock, BOB, id);
    assert_amounts(&mut s, 0, 0);
    finish(s, clock);
}

// === Expiry ===

#[test]
fun anyone_can_expire_a_lapsed_grant() {
    let (mut s, mut clock) = setup(1_000);
    let id = approve(&mut s, &clock, BOB, 400);
    clock.increment_for_testing(DAY_MS + 1);
    s.next_tx(ALICE);
    let mut t = s.take_shared<Treasury<USDX>>();
    t.expire(id, &clock);
    assert!(!t.has_grant(id));
    ts::return_shared(t);
    assert_amounts(&mut s, 1_000, 0);
    finish(s, clock);
}

#[test, expected_failure(abort_code = fund_release::EGrantNotExpired)]
fun a_live_grant_cannot_be_expired() {
    let (mut s, mut clock) = setup(1_000);
    let id = approve(&mut s, &clock, BOB, 400);
    clock.increment_for_testing(DAY_MS);
    s.next_tx(ADMIN);
    let mut t = s.take_shared<Treasury<USDX>>();
    t.expire(id, &clock);
    abort
}

// === Accounting across many grants ===

#[test]
fun reservations_add_up_across_grants() {
    let (mut s, mut clock) = setup(1_000);
    let a = approve(&mut s, &clock, ALICE, 250);
    let b = approve(&mut s, &clock, BOB, 300);
    let c = approve(&mut s, &clock, BOB, 450);
    assert_amounts(&mut s, 1_000, 1_000);

    claim_as(&mut s, &clock, BOB, b);
    assert_amounts(&mut s, 700, 700);

    clock.increment_for_testing(DAY_MS + 1);
    s.next_tx(BOB);
    let mut t = s.take_shared<Treasury<USDX>>();
    t.expire(a, &clock);
    ts::return_shared(t);
    assert_amounts(&mut s, 700, 450);

    s.next_tx(BOB);
    let mut t = s.take_shared<Treasury<USDX>>();
    t.expire(c, &clock);
    ts::return_shared(t);
    assert_amounts(&mut s, 700, 0);
    finish(s, clock);
}

// === Edges ===

#[test, expected_failure(abort_code = fund_release::EZeroAmount)]
fun withdraw_of_zero_aborts() {
    let (mut s, _clock) = setup(1_000);
    s.next_tx(ADMIN);
    let mut t = s.take_shared<Treasury<USDX>>();
    let cap = s.take_from_sender<AdminCap>();
    let _back = t.withdraw(&cap, 0, s.ctx());
    abort
}

#[test, expected_failure(abort_code = fund_release::EGrantNotFound)]
fun expiring_an_unknown_grant_aborts() {
    let (mut s, clock) = setup(1_000);
    s.next_tx(ALICE);
    let mut t = s.take_shared<Treasury<USDX>>();
    t.expire(3, &clock);
    abort
}
