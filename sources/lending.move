
module keepsake::lending {
    use std::option::{Self, Option};

    use sui::dynamic_object_field::{Self as dof};
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::sui::SUI;
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};

    use nft_protocol::safe::{Self, Safe, OwnerCap, TransferCap};
    use nft_protocol::transfer_allowlist::{Allowlist};
    use nft_protocol::collection::{Collection};
    use nft_protocol::royalty::{Self};
    use nft_protocol::nft::{Nft};
    use nft_protocol::utils::{Self as nft_utils};
    use sui::package;

    use keepsake::keepsake_marketplace::{getWitness, Witness};

    struct LENDING has drop {}
    // struct Witness has drop {}

    const ENFTNotFound: u64 = 135289680000;
    const EAmountIncorrect: u64 = 135289680000 + 1;
    const ENotOwner: u64 = 135289680000 + 2;
    const ENotAvailable: u64 = 135289680000 + 3;
    const EWrongDuration: u64 = 135289680000 + 4;
    const EBeforeListingEnd: u64 = 135289680000 + 5;
    const EAfterListingEnd: u64 = 135289680000 + 6;
    const EBeforeLoanEnd: u64 = 135289680000 + 7;

    const MaxFee: u16 = 2000;
    
    struct Marketplace has key {
        id: UID,
        owner: address,
        owner_cap: OwnerCap,
        fee: u16,
        fee_balance: Balance<SUI>,
        gas_cost: u64,
        gas_admin: address,
    }

    struct Loan has key, store {
        id: UID,
        borrower: address,
        expiry: u64,
        cap: TransferCap,
        payment: Coin<SUI>,
        gas_cost: u64,
    }

    struct Listing has key, store {
        id: UID,
        nft_id: ID,
        available: bool,
        ask_per_hour: u64,
        min_duration: u64,
        max_duration: u64,
        owner_safe: ID,
        owner: address,
        starts: u64,
        expires: u64,
        loan_id: Option<ID>,
    }

    struct LoanNftEvent has copy, drop {
        nft_id: ID,
        duration: u64,
    }

    struct ReturnNftEvent has copy, drop {
        nft_id: ID,
        sale_price: u64,
        sold: bool,
    }

    fun init(otw: LENDING,ctx: &mut TxContext) {
        package::claim_and_keep(otw, ctx);
        let id = object::new(ctx);
        let (safe, cap) = safe::new(ctx);
        let marketplace = Marketplace {
            id,
            owner: tx_context::sender(ctx),
            owner_cap: cap,
            fee: 0,
            fee_balance: balance::zero<SUI>(),
            gas_cost: 6000,
            gas_admin: tx_context::sender(ctx),
        };
        
        transfer::public_share_object(safe);
        transfer::share_object(marketplace);
    }

    #[test_only]
    public fun test_init(ctx: &mut TxContext) {
        let id = object::new(ctx);
        let (safe, cap) = safe::new(ctx);
        let marketplace = Marketplace {
            id,
            owner: tx_context::sender(ctx),
            owner_cap: cap,
            fee: 10,
            fee_balance: balance::zero<SUI>(),
            gas_cost: 6000,
            gas_admin: tx_context::sender(ctx),
        };
        
        transfer::share_object(safe);
        transfer::share_object(marketplace);
    }
    
    public entry fun update_market(
        marketplace: &mut Marketplace,
        owner: address,
        fee: u16,
        gas_cost: u64,
        gas_admin: address,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == marketplace.owner, ENotOwner);
        assert!(fee <= MaxFee, EAmountIncorrect);
        marketplace.fee = fee;
        marketplace.owner = owner;
        marketplace.gas_cost = gas_cost;
        marketplace.gas_admin = gas_admin;
    }

    public entry fun stop_lending(
        nft_id: ID,
        marketplace: &mut Marketplace,
        ctx: &mut TxContext,
    ) {
        let marketplace_id = &mut marketplace.id;
        let listing = dof::borrow_mut<ID, Listing>(marketplace_id, nft_id);
        assert!(listing.owner == tx_context::sender(ctx), ENotOwner);
        listing.available = false;
    }

    fun create_listing(
        nft_id: ID,
        safe: &mut Safe,
        marketplace: &mut Marketplace,
        ask_per_hour: u64,
        min_duration: u64,
        max_duration: u64,
        starts: u64,
        expires: u64,
        ctx: &mut TxContext
    ) {
        let id = object::new(ctx);
        let listing = Listing {
            id,
            nft_id,
            available: true,
            ask_per_hour,
            min_duration,
            max_duration,
            owner: tx_context::sender(ctx),
            owner_safe: object::id(safe),
            starts,
            expires,
            loan_id: option::none<ID>(),
        };
        dof::add(&mut marketplace.id, nft_id, listing);
    }

    fun create_loan(
        nft_id: ID,
        duration: u64,
        coin: Coin<SUI>,
        safe: &mut Safe,
        owner_cap: &OwnerCap,
        marketplace: &mut Marketplace,
        ctx: &mut TxContext,
    ) {
        let cap = safe::create_exclusive_transfer_cap(nft_id, owner_cap, safe, ctx);

        let expiry = duration; // + now
        let loan = Loan {
            id: object::new(ctx),
            borrower: tx_context::sender(ctx),
            expiry,
            cap,
            payment: coin,
            gas_cost: marketplace.gas_cost,
        };
        let marketplace_id = &mut marketplace.id;
        let listing = dof::borrow_mut<ID, Listing>(marketplace_id, nft_id);
        option::fill<ID>(&mut listing.loan_id, object::uid_to_inner(& loan.id));
        dof::add<ID, Loan>(marketplace_id, object::uid_to_inner(& loan.id), loan);
    }
    
    fun remove_listing(
        nft_id: ID,
        marketplace: &mut Marketplace
    ): (ID, address) {
        let marketplace_id = &mut marketplace.id;
        let Listing {
            id,
            nft_id: _,
            available: _,
            ask_per_hour: _,
            min_duration: _,
            max_duration: _,
            owner_safe,
            owner,
            starts: _,
            expires: _,
            loan_id
        } = dof::remove<ID, Listing>(marketplace_id, nft_id);
        object::delete(id);
        assert!(option::is_none<ID>(& loan_id), EBeforeLoanEnd);
        (owner_safe, owner)
    }

    fun can_borrow(
        nft_id: ID,
        duration_hours: u64,
        marketplace: &mut Marketplace
    ): u64 {
        let marketplace_id = &mut marketplace.id;
        // fetch listing, determine validity of rental params
        let listing = dof::borrow<ID, Listing>(marketplace_id, nft_id);
        // assert!(now + duration_hours < listing.expires, EAfterListingEnd)
        assert!(duration_hours >= listing.min_duration && duration_hours <= listing.max_duration, EWrongDuration);
        assert!(listing.available, ENotAvailable);
        let required_value = (duration_hours * listing.ask_per_hour) / 24 + marketplace.gas_cost;
        required_value
    }

    public entry fun lend_generic_outside_safe<T: key + store>(
        nft: T,
        safe: &mut Safe,
        marketplace: &mut Marketplace,
        market_safe: &mut Safe,
        ask_per_hour: u64,
        min_duration: u64,
        max_duration: u64,
        starts: u64,
        expires: u64,
        ctx: &mut TxContext,
    ) {
        nft_utils::assert_not_nft_protocol_type<T>();
        let nft_id = object::id<T>(&nft);
        let market_owner_cap = & marketplace.owner_cap;
        
        safe::deposit_generic_nft_privileged<T>(nft, market_owner_cap, market_safe, ctx);

        create_listing(nft_id, safe, marketplace, ask_per_hour, min_duration, max_duration, starts, expires, ctx);
    }

    public entry fun lend_generic<T: key + store>(
        nft_id: ID,
        safe: &mut Safe,
        marketplace: &mut Marketplace,
        market_safe: &mut Safe,
        ask_per_hour: u64,
        min_duration: u64,
        max_duration: u64,
        starts: u64,
        expires: u64,
        owner_cap: &OwnerCap,
        ctx: &mut TxContext,
    ) {
        nft_utils::assert_not_nft_protocol_type<T>();
        
        let cap = safe::create_exclusive_transfer_cap(nft_id, owner_cap, safe, ctx);
        safe::transfer_generic_nft_to_safe<T>(cap, safe, market_safe, ctx);

        create_listing(nft_id, safe, marketplace, ask_per_hour, min_duration, max_duration, starts, expires, ctx);
    }

    public entry fun borrow_generic<T: key + store>(
        nft_id: ID,
        duration_hours: u64,
        paid: Coin<SUI>,
        safe: &mut Safe,
        owner_cap: &OwnerCap,
        marketplace: &mut Marketplace,
        market_safe: &mut Safe,
        ctx: &mut TxContext,
    ) {
        // check the NFT is the right type, and we have it
        nft_utils::assert_not_nft_protocol_type<T>();
        assert!(safe::has_generic_nft<T>(nft_id, market_safe), ENFTNotFound);

        let sent_value = coin::value(&paid);
        let required_value = can_borrow(nft_id, duration_hours, marketplace);

        if(sent_value > required_value){
            transfer::public_transfer(coin::split<SUI>(&mut paid, sent_value - required_value, ctx), tx_context::sender(ctx));
        } else {
            assert!(sent_value == required_value, EAmountIncorrect);
        };

        // move the nft to their safe
        let market_owner_cap = & marketplace.owner_cap;
        let cap = safe::create_exclusive_transfer_cap(nft_id, market_owner_cap, market_safe, ctx);
        safe::transfer_generic_nft_to_safe<T>(cap, market_safe, safe, ctx);

        // create a loan, add it to the listing, and create an exclusive transfer cap so we can take the NFT without involving the borrower
        create_loan(nft_id, duration_hours, paid, safe, owner_cap, marketplace, ctx);
    }

    public entry fun relinquish_generic<T: key + store>(
        nft_id: ID,
        nft_safe: &mut Safe,
        marketplace: &mut Marketplace,
        market_safe: &mut Safe,
        ctx: &mut TxContext,
    ) {
        nft_utils::assert_not_nft_protocol_type<T>();
        assert!(safe::has_generic_nft<T>(nft_id, nft_safe), ENFTNotFound);

        let listing = dof::remove<ID, Listing>(&mut marketplace.id, nft_id);
        let loan_id = option::extract<ID>(&mut listing.loan_id);
        let Loan { id, cap, expiry: _, gas_cost, payment, borrower} = dof::remove<ID, Loan>(&mut marketplace.id, loan_id);
        object::delete(id);
        // refund gas_cost
        let refund = coin::split<SUI>(&mut payment, gas_cost, ctx);
        if(tx_context::sender(ctx) != borrower) {
            transfer::public_transfer(refund, tx_context::sender(ctx));
            // assert!(now > loan.expiry, EBeforeLoanEnd)
        } else {
            transfer::public_transfer(refund, tx_context::sender(ctx));
        };


        // take our share
        let value = coin::value(&payment);
        let marketFee = (value * (marketplace.fee as u64)) / 10000u64;
        let marketCoin = coin::split<SUI>(&mut payment, marketFee, ctx);
        coin::put(&mut marketplace.fee_balance, marketCoin);

        // pay owner
        transfer::public_transfer(payment, listing.owner);

        // move NFT back to safe
        safe::transfer_generic_nft_to_safe<T>(cap, nft_safe, market_safe, ctx);
        dof::add(&mut marketplace.id, nft_id, listing);
    }

    public entry fun relinquish_and_borrow_generic<T: key + store>(
        nft_id: ID,
        nft_safe: &mut Safe,
        duration_hours: u64,
        paid: Coin<SUI>,
        safe: &mut Safe,
        owner_cap: &OwnerCap,
        marketplace: &mut Marketplace,
        market_safe: &mut Safe,
        ctx: &mut TxContext,
    ) {
        relinquish_generic<T>(nft_id, nft_safe, marketplace, market_safe, ctx);
        borrow_generic<T>(nft_id, duration_hours, paid, safe, owner_cap, marketplace, market_safe, ctx);
    }

    public fun finish_lending_generic<T: key + store>(
        nft_id: ID,
        ownerSafe: &mut Safe,
        marketplace: &mut Marketplace,
        market_safe: &mut Safe,
        ctx: &mut TxContext,
    ) {
        assert!(safe::has_generic_nft<T>(nft_id, market_safe), ENFTNotFound);

        let (safe_id, _ ) = remove_listing(nft_id, marketplace);
        assert!(safe_id == object::id(ownerSafe), ENotOwner);

        let market_owner_cap = & marketplace.owner_cap;
        let cap = safe::create_exclusive_transfer_cap(nft_id, market_owner_cap, market_safe, ctx);
        safe::transfer_generic_nft_to_safe<T>(cap, market_safe, ownerSafe, ctx);
    }

    /*
     * standardized NFTs
     */
    public entry fun lend<T>(
        nft_id: ID,
        safe: &mut Safe,
        marketplace: &mut Marketplace,
        market_safe: &mut Safe,
        ask_per_hour: u64,
        min_duration: u64,
        max_duration: u64,
        starts: u64,
        expires: u64,
        owner_cap: &OwnerCap,
        allowlist: &Allowlist,
        ctx: &mut TxContext,
    ) {
        nft_utils::is_nft_protocol_nft_type<T>();

        let cap = safe::create_exclusive_transfer_cap(nft_id, owner_cap, safe, ctx);
        safe::transfer_nft_to_safe<T, Witness>(cap, marketplace.owner, getWitness(), allowlist, safe, market_safe, ctx);
        
        create_listing(nft_id, safe, marketplace, ask_per_hour, min_duration, max_duration, starts, expires, ctx);
    }

    public entry fun lend_outside_safe<T>(
        nft: Nft<T>,
        safe: &mut Safe,
        marketplace: &mut Marketplace,
        market_safe: &mut Safe,
        ask_per_hour: u64,
        min_duration: u64,
        max_duration: u64,
        starts: u64,
        expires: u64,
        ctx: &mut TxContext,
    ) {
        let nft_id = object::id(&nft);
        let market_owner_cap = & marketplace.owner_cap;
        safe::deposit_nft_privileged<T>(nft, market_owner_cap, market_safe, ctx);

        create_listing(nft_id, safe, marketplace, ask_per_hour, min_duration, max_duration, starts, expires, ctx);
    }

    public entry fun borrow<T>(
        nft_id: ID,
        duration_hours: u64,
        paid: Coin<SUI>,
        safe: &mut Safe,
        owner_cap: &OwnerCap,
        marketplace: &mut Marketplace,
        market_safe: &mut Safe,
        allowlist: &Allowlist,
        ctx: &mut TxContext,
    ) {
        // check the NFT is the right type, and we have it
        assert!(safe::has_nft<T>(nft_id, market_safe), ENFTNotFound);

        // fetch listing, determine validity of rental params
        let sent_value = coin::value(&paid);
        let required_value = can_borrow(nft_id, duration_hours, marketplace);

        if(sent_value > required_value){
            transfer::public_transfer(coin::split<SUI>(&mut paid, sent_value - required_value, ctx), tx_context::sender(ctx));
        } else {
            assert!(sent_value == required_value, EAmountIncorrect);
        };

        // move the nft to their safe
        let market_owner_cap = & marketplace.owner_cap;
        let cap = safe::create_exclusive_transfer_cap(nft_id, market_owner_cap, market_safe, ctx);
        safe::transfer_nft_to_safe<T, Witness>(cap, tx_context::sender(ctx), getWitness(), allowlist,  market_safe, safe, ctx);

        // create a loan, add it to the listing, and create an exclusive transfer cap so we can take the NFT without involving the borrower
        create_loan(nft_id, duration_hours, paid, safe, owner_cap, marketplace, ctx);
    }

    public entry fun relinquish<T>(
        nft_id: ID,
        nft_safe: &mut Safe,
        marketplace: &mut Marketplace,
        market_safe: &mut Safe,
        allowlist: &Allowlist,
        collection: &mut Collection<T>,
        ctx: &mut TxContext,
    ) {
        assert!(safe::has_nft<T>(nft_id, nft_safe), ENFTNotFound);
        let marketplace_id = &mut marketplace.id;
        let listing = dof::remove<ID, Listing>(marketplace_id, nft_id);
        let loan_id = option::extract<ID>(&mut listing.loan_id);
        let Loan { id, cap, expiry: _, gas_cost, payment, borrower} = dof::remove<ID, Loan>(marketplace_id, loan_id);
        object::delete(id);
        if(tx_context::sender(ctx) != borrower) {
            // assert!(now > loan.expiry, EBeforeLoanEnd)
        };

        // refund gas_cost
        let refund = coin::split<SUI>(&mut payment, gas_cost, ctx);
        transfer::public_transfer(refund, tx_context::sender(ctx));

        // take our share
        let value = coin::value(&payment);
        let marketFee = (value * (marketplace.fee as u64)) / 10000u64;
        let marketCoin = coin::split<SUI>(&mut payment, marketFee, ctx);
        coin::put(&mut marketplace.fee_balance, marketCoin);
        
        royalty::collect_royalty<T, SUI>(collection, coin::balance_mut<SUI>(&mut payment), value);

        // pay owner
        transfer::public_transfer(payment, listing.owner);

        // move NFT back to safe
        safe::transfer_nft_to_safe<T, Witness>(cap, listing.owner, getWitness(), allowlist, nft_safe, market_safe, ctx);
        dof::add(&mut marketplace.id, nft_id, listing);
    }

    public fun finish_lending<T>(
        nft_id: ID,
        ownerSafe: &mut Safe,
        marketplace: &mut Marketplace,
        market_safe: &mut Safe,
        allowlist: &Allowlist,
        ctx: &mut TxContext,
    ) {
        assert!(safe::has_nft<T>(nft_id, market_safe), ENFTNotFound);

        let (safe_id, _) = remove_listing(nft_id, marketplace);
        assert!(safe_id == object::id(ownerSafe), ENotOwner);

        let market_owner_cap = & marketplace.owner_cap;
        let cap = safe::create_exclusive_transfer_cap(nft_id, market_owner_cap, market_safe, ctx);
        safe::transfer_nft_to_safe<T, Witness>(cap, tx_context::sender(ctx), getWitness(), allowlist, market_safe, ownerSafe, ctx);
    }
}
