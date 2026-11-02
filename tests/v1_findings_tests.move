#[test_only]
module boris_boarman::v1_findings_tests {
    use sui::test_scenario as ts;
    use sui::coin;
    use sui::sui::SUI;
    use boris_boarman::FundRelease::{Self, FundingProposals};

    const ADMIN: address = @0xAD;
    const ANYONE: address = @0x99;

    // Finding 1: anyone can file a proposal for any amount, to themselves.
    #[test]
    fun anyone_can_propose_any_amount_to_themselves() {
        let mut s = ts::begin(ADMIN);
        FundRelease::test_init(ts::ctx(&mut s));
        ts::next_tx(&mut s, ANYONE);
        {
            let mut p = ts::take_shared<FundingProposals>(&s);
            FundRelease::create_proposal(&mut p, ANYONE, 18_446_744_073_709_551_615, ts::ctx(&mut s));
            assert!(FundRelease::get_proposal_amount(&p, 0) == 18_446_744_073_709_551_615);
            assert!(FundRelease::get_proposal_status(&p, 0) == 0); // ACTIVE
            ts::return_shared(p);
        };
        ts::end(s);
    }

    // Finding 2: the contract holds nothing. "Releasing" is the admin paying
    // out of its own wallet at release time; an ACTIVE proposal reserves no funds.
    #[test]
    fun release_is_paid_by_the_admin_at_call_time() {
        let mut s = ts::begin(ADMIN);
        FundRelease::test_init(ts::ctx(&mut s));
        ts::next_tx(&mut s, ANYONE);
        {
            let mut p = ts::take_shared<FundingProposals>(&s);
            FundRelease::create_proposal(&mut p, ANYONE, 500, ts::ctx(&mut s));
            ts::return_shared(p);
        };
        // No coin of any kind exists in the contract: the admin must bring one.
        ts::next_tx(&mut s, ADMIN);
        {
            let mut p = ts::take_shared<FundingProposals>(&s);
            let c = coin::mint_for_testing<SUI>(500, ts::ctx(&mut s));
            FundRelease::release_funds(&mut p, 0, c, ts::ctx(&mut s));
            ts::return_shared(p);
        };
        ts::end(s);
    }

    // Finding 3: the views abort on an unknown id with the table's generic
    // error, not the module's EInvalidProposal.
    #[test]
    #[expected_failure(abort_code = sui::dynamic_field::EFieldDoesNotExist)]
    fun views_abort_with_a_foreign_error() {
        let mut s = ts::begin(ADMIN);
        FundRelease::test_init(ts::ctx(&mut s));
        ts::next_tx(&mut s, ADMIN);
        let p = ts::take_shared<FundingProposals>(&s);
        FundRelease::get_proposal_status(&p, 7);
        ts::return_shared(p);
        ts::end(s);
    }
}
