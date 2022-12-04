// Copyright (c) 2022, Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module nfts::marketplace_nofee {
    use sui::tx_context::{Self, TxContext};
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::dynamic_object_field as ofield;
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};

    // For when amount paid does not match the expected.
    const EAmountIncorrect: u64 = 0;
    // For when someone tries to delist without ownership.
    const ENotOwner: u64 = 1;

    // For auctions
    const ETooLate: u64 = 2;
    const ETooEarly: u64 = 3;
    const ENoBid: u64 = 4;

    struct Marketplace has key {
        id: UID,
        fee: u8,
        owner: address,
    }

    /// A single listing which contains the listed item and its price in [`Coin<C>`].
    struct Listing<T: key + store, phantom C> has key, store {
        id: UID,
        item: T,
        ask: u64, // Coin<C>
        owner: address,
    }

    struct AuctionListing<T: key + store, phantom C> has key, store {
        id: UID,
        item: T,
        bid: Balance<C>,
        min_bid: u64,
        starts: u64,
        expires: u64,
        owner: address,
        bidder: address,
    }

    public entry fun split_and_transfer<C>(from: Coin<C>, amount: u64, recipient: address, ctx: &mut TxContext) {
        transfer::transfer(coin::split(&mut from, amount, ctx), recipient);
        transfer::transfer(from, tx_context::sender(ctx))
    }

    /// Create a new shared Marketplace.
    public entry fun create(owner: address, fee: u8, ctx: &mut TxContext) {
        let id = object::new(ctx);

        let market_place = Marketplace {
            id,
            fee,
            owner,
        };
        transfer::share_object(market_place);
        // transfer::transfer(market_place, tx_context::sender(ctx));
    }

    /// List an item at the Marketplace.
    public entry fun list<T: key + store, C>(
        _marketplace: &mut Marketplace,
        item: T,
        ask: u64,
        ctx: &mut TxContext
    ) {
        let id = object::new(ctx);
        let listing = Listing<T, C> {
            id,
            item,
            ask,
            owner: tx_context::sender(ctx),
        };
        let id = object::id(&listing); 
        ofield::add(&mut _marketplace.id, id, listing);
    }

    public fun sclist<T: key + store, C>(
        _marketplace: &mut Marketplace,
        item: T,
        ask: u64,
        ctx: &mut TxContext
    ): ID {
        let id = object::new(ctx);
        let listing = Listing<T, C> {
            id,
            item,
            ask,
            owner: tx_context::sender(ctx),
        };
        let id = object::id(&listing); 
        ofield::add(&mut _marketplace.id, id, listing);
        id
    }
    
    public fun adjust_listing<T: key + store, C>(
        _marketplace: &mut Marketplace,
        listing_id: ID,
        ask: u64,
        ctx: &mut TxContext
    ) {
        let listing = ofield::borrow_mut<ID, Listing<T, C>>(&mut _marketplace.id, listing_id);
        listing.ask = ask;
        assert!(tx_context::sender(ctx) == listing.owner, ENotOwner);
    }

    /// Remove listing and get an item back. Only owner can do that.
    public fun delist<T: key + store, C>(
        _marketplace: &mut Marketplace,
        listing_id: ID,
        ctx: &mut TxContext
    ): T {
        let listing = ofield::remove<ID, Listing<T, C>>(&mut _marketplace.id, listing_id);
        let Listing { id, item, ask: _, owner } = listing;
        object::delete(id);

        assert!(tx_context::sender(ctx) == owner, ENotOwner);

        item
    }

    /// Call [`delist`] and transfer item to the sender.
    public entry fun delist_and_take<T: key + store, C>(
        _marketplace: &mut Marketplace,
        listing_id: ID,
        ctx: &mut TxContext
    ) {
        let item = delist<T, C>(_marketplace, listing_id, ctx);
        transfer::transfer(item, tx_context::sender(ctx));
    }

    /// Purchase an item using a known Listing. Payment is done in Coin<C>.
    /// Amount paid must match the requested amount. If conditions are met,
    /// owner of the item gets the payment and buyer receives their item.
    public fun buy<T: key + store, C>(
        _marketplace: &mut Marketplace,
        listing_id: ID,
        paid: Coin<C>,
        ctx: &mut TxContext
    ): T {
        let listing = ofield::remove<ID, Listing<T, C>>(&mut _marketplace.id, listing_id);
        
        let Listing { id, item, ask, owner } = listing;
        object::delete(id);

        let sent = coin::value(&paid);
        assert!(ask <= sent, EAmountIncorrect);
        let marketFee = (ask * (_marketplace.fee as u64)) / 10000u64;

        // take our share
        let marketCoin = coin::split<C>(&mut paid, marketFee, ctx);
        transfer::transfer(marketCoin, _marketplace.owner);
        // if amount is exact, can skip splitting the amount
        if(sent > ask){
            transfer::transfer(coin::split(&mut paid, ask - marketFee, ctx), owner);
            transfer::transfer(paid, tx_context::sender(ctx));
        } else {
            transfer::transfer(paid, owner);
        };

        item
    }

    /// Call [`buy`] and transfer item to the sender.
    public entry fun buy_and_take<T: key + store, C>(
        _marketplace: &mut Marketplace,
        listing_id: ID,
        paid: Coin<C>,
        ctx: &mut TxContext
    ) {
        transfer::transfer(buy<T,C>(_marketplace, listing_id, paid, ctx), tx_context::sender(ctx))
    }

    public entry fun auction<T: key + store, C>(
        _marketplace: &mut Marketplace,
        item: T,
        min_bid: u64,
        starts: u64,
        expires: u64,
        ctx: &mut TxContext
    ) {
        let id = object::new(ctx);
        let listing = AuctionListing<T, C> {
            id,
            item,
            min_bid,
            bid: balance::zero<C>(),
            starts,
            expires,
            owner: tx_context::sender(ctx),
            bidder: tx_context::sender(ctx),
        };
        let id = object::id(&listing); 
        ofield::add(&mut _marketplace.id, id, listing);
    }
    
    public entry fun bid<T: key + store, C>(
        _marketplace: &mut Marketplace,
        listing_id: ID,
        paid: Coin<C>,
        new_bid: u64,
        ctx: &mut TxContext
    ) {

        let listing = ofield::borrow_mut<ID, AuctionListing<T, C>>(&mut _marketplace.id, listing_id);
        let oldBid = sui::balance::value(&listing.bid);
        // TODO: TESTNET ONLY. epoch on testnet seems to always return 0;
        // assert!(listing.expires > tx_context::epoch(ctx), ETooLate);
        // assert!(listing.starts < tx_context::epoch(ctx), ETooEarly);
        assert!(new_bid > oldBid, EAmountIncorrect);
        assert!(new_bid >= listing.min_bid, EAmountIncorrect);

        if(oldBid > 0){
            transfer::transfer(sui::coin::take<C>(&mut listing.bid, oldBid, ctx), listing.bidder);
        };
        let newCoin = coin::split<C>(&mut paid, new_bid, ctx);
        coin::put<C>(&mut listing.bid, newCoin);
        transfer::transfer(paid, tx_context::sender(ctx));

        listing.bidder =  tx_context::sender(ctx);
    }

    public fun complete_auction<T: key + store, C>(
        _marketplace: &mut Marketplace,
        listing_id: ID,
        ctx: &mut TxContext
    ): T {
        let listing = ofield::remove<ID, AuctionListing<T, C>>(&mut _marketplace.id, listing_id);
        let AuctionListing { id, item, bid, owner, bidder, min_bid, starts: _, expires: _ } = listing;
        assert!(bidder == tx_context::sender(ctx), ENotOwner);
        let finalBid = sui::balance::value(&bid);

        assert!(finalBid >= min_bid, ENoBid);
        // TODO: TESTNET ONLY. epoch on testnet seems to always return 0;
        //assert!(expires < tx_context::epoch(ctx), ETooEarly);
        //assert!(starts > tx_context::epoch(ctx), ETooLate);

        let paid = sui::coin::from_balance<C>(bid, ctx);
        let marketFee = (finalBid * (_marketplace.fee as u64)) / 10000u64;
        transfer::transfer(coin::split(&mut paid, marketFee, ctx), _marketplace.owner);
        transfer::transfer(paid, owner);
        object::delete(id);
        item
    }

    public entry fun complete_auction_and_take<T: key + store, C>(
        _marketplace: &mut Marketplace,
        listing_id: ID,
        ctx: &mut TxContext
    ) {
        transfer::transfer(complete_auction<T, C>(_marketplace, listing_id, ctx), tx_context::sender(ctx));
    }


    /// Remove listing and get an item back. Only owner can do that.
    public fun deauction<T: key + store, C>(
        _marketplace: &mut Marketplace,
        listing: AuctionListing<T,C>,
        ctx: &mut TxContext
    ): T {
        let AuctionListing { id, item, bid, bidder, expires: _, starts: _, min_bid: _, owner } = listing;

        let paid = sui::coin::from_balance<C>(bid, ctx);
        transfer::transfer(paid, bidder);
        assert!(tx_context::sender(ctx) == owner, ENotOwner);
        // assert!(expires > tx_context::epoch(ctx) || expires == 0, ETooEarly);
        object::delete(id);
        item
    }

    /// Call [`delist`] and transfer item to the sender.
    public entry fun deauction_and_take<T: key + store, C>(
        _marketplace: &mut Marketplace,
        listing_id: ID,
        ctx: &mut TxContext
    ) {
        let listing = ofield::remove<ID, AuctionListing<T, C>>(&mut _marketplace.id, listing_id);
        let item = deauction(_marketplace, listing, ctx);
        transfer::transfer(item, tx_context::sender(ctx));
    }
}

#[test_only]
module nfts::marketplaceTests {
    // use std::debug;
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::test_scenario::{Self, Scenario};
    // use nfts::bag::{Self, Bag};
    use nfts::marketplace_nofee::{Self, Marketplace/*, Listing*/};

    struct Kitty has key, store {
        id: UID,
        kitty_id: u8
    }

    fun burn_kitty(kitty: Kitty): u8 {
        let Kitty{ id, kitty_id } = kitty;
        object::delete(id);
        kitty_id
    }

    const ADMIN: address = @0xA55;
    const SELLER: address = @0x00A;
    const BUYER: address = @0x00B;

    fun create_marketplace(scenario: &mut Scenario) {
        test_scenario::next_tx(scenario, ADMIN);
        marketplace_nofee::create(ADMIN, 250, test_scenario::ctx(scenario));
    }
    fun mint_some_coin(scenario: &mut Scenario) {
        test_scenario::next_tx(scenario, ADMIN);
        let coin = coin::mint_for_testing<SUI>(1000, test_scenario::ctx(scenario));
        transfer::transfer(coin, BUYER);
    }

    fun mint_kitty(scenario: &mut Scenario) {
        test_scenario::next_tx(scenario, ADMIN);
        let nft = Kitty { id: object::new(test_scenario::ctx(scenario)), kitty_id: 1 };
        transfer::transfer(nft, SELLER);
    }


    #[test]
    fun buy_kitty() {
        let scenario_val = test_scenario::begin(ADMIN);
        let scenario = &mut scenario_val;
        
        create_marketplace(scenario);
        mint_some_coin(scenario);
        mint_kitty(scenario);
        
        let mkp_val = test_scenario::take_shared<Marketplace>(scenario);
        let mkp = &mut mkp_val;

        
        test_scenario::next_tx(scenario, SELLER);
        let nft = test_scenario::take_from_sender<Kitty>(scenario);
        let listingID = marketplace_nofee::sclist<Kitty, SUI>(mkp, nft, 100, test_scenario::ctx(scenario));
    

        // BUYER takes 100 SUI from his wallet and purchases Kitty.
        test_scenario::next_tx(scenario, BUYER);

        let coin = test_scenario::take_from_sender<Coin<SUI>>(scenario);


        // let listing = test_scenario::take_from_address<Listing<Kitty, SUI>>(scenario, object::id_to_address(&object::id(mkp)));
        
        let payment = coin::take(coin::balance_mut(&mut coin), 100, test_scenario::ctx(scenario));


        // // Do the buy call and expect successful purchase.
        marketplace_nofee::buy_and_take<Kitty, SUI>(mkp, listingID, payment, test_scenario::ctx(scenario));

        // 
        // 
        // test_scenario::return_to_sender(scenario, listing);
        test_scenario::return_shared(mkp_val);
        test_scenario::return_to_sender(scenario, coin);

        test_scenario::end(scenario_val);
    }
}