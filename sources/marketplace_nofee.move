// Copyright (c) 2022, Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module keepsake::marketplace_nofee {
    use std::type_name::{Self, TypeName};
    
    use sui::tx_context::{Self, TxContext};
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::event;
    use sui::dynamic_object_field as ofield;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::balance::{Self, Balance};

    use nft_protocol::transfer_allowlist::{Self, Allowlist, CollectionControlCap};
    use nft_protocol::nft::{Self, Nft};
    use nft_protocol::utils::{Self as nft_utils};
    // use nfts::fixed_price::{Self};
    // use nfts::dutch_auction::{Self};

    friend keepsake::lending;
    
    const MaxFee: u16 = 2000; // 20%! Way too high, this is mostly to prevent accidents, like adding an extra 0

    // For when amount paid does not match the expected.
    const EAmountIncorrect: u64 = 135289670000;
    // For when someone tries to delist without ownership.
    const ENotOwner: u64 = 135289670000 + 1;
    // For when someone tries to use fallback functions for a standardized NFT.
    const EMustUseStandard: u64 = 135289670000 + 2;
    const EMustNotUseStandard: u64 = 135289670000 + 3;
    // For auctions
    const ETooLate: u64 = 135289670000 + 100;
    const ETooEarly: u64 = 135289670000 + 101;
    const ENoBid: u64 = 135289670000 + 102;
    

    struct Marketplace has key {
        id: UID,
        owner: address,
        fee: u16,
        feeBalance: Balance<SUI>,
        collateralFee: u64,
    }

    struct Witness has drop {}

    /// A single listing which contains the listed item and its price in [`Coin<C>`].
    // Potential improvement: make each listing part of a smaller shared object (e.g. per type, per seller, etc.)
    // store market details in the listing to prevent any need to interact with the Marketplace shared object?
    struct Listing<T: key + store> has key, store {
        id: UID,
        item: T,
        ask: u64, // Coin<C>
        owner: address,
    }

    struct AuctionListing<T: key + store> has key, store {
        id: UID,
        item: T,
        bid: Balance<SUI>,
        collateral: Balance<SUI>,
        min_bid: u64,
        min_bid_increment: u64,
        starts: u64,
        expires: u64,
        owner: address,
        bidder: address,
    }

    struct WonAuction<T: key> {
        item: T,
        bidder: address
    }

    struct ListNftEvent has copy, drop {
        /// ID of the `Nft` that was listed
        nft_id: ID,
        ask: u64,
        auction: bool,
        /// Type name of `Nft<C>` one-time witness `C`
        /// Intended to allow users to filter by collections of interest.
        type_name: TypeName,
    }

    struct DelistNftEvent has copy, drop {
        /// ID of the `Nft` that was listed
        nft_id: ID,
        sale_price: u64,
        sold: bool,
        /// Type name of `Nft<C>` one-time witness `C`
        /// Intended to allow users to filter by collections of interest.
        type_name: TypeName,
    }

    /// Create a new shared Marketplace.
    public entry fun create(
        owner: address,
        fee: u16,
        collateralFee: u64,
        ctx: &mut TxContext
    ) {
        let id = object::new(ctx);
        assert!(fee <= MaxFee, EAmountIncorrect);
        // collateral must be even for an even split
        assert!(collateralFee % 2 == 0, EAmountIncorrect);

        let marketplace = Marketplace {
            id,
            owner,
            fee,
            feeBalance: balance::zero<SUI>(),
            collateralFee,
        };
        transfer::share_object(marketplace);
        
        let allowlist = transfer_allowlist::create<Witness>(& Witness {}, ctx);
        transfer::share_object(allowlist);
    }

    public entry fun updateMarket(
        marketplace: &mut Marketplace,
        owner: address,
        fee: u16,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == marketplace.owner, ENotOwner);
        assert!(fee <= MaxFee, EAmountIncorrect);
        marketplace.fee = fee;
        marketplace.owner = owner;
    }

    public entry fun withdraw(
        marketplace: &mut Marketplace,
        to: address,
        max: u64,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == marketplace.owner, ENotOwner);
        let balance = sui::balance::value(&marketplace.feeBalance);
        if(max > balance){
            balance = max;
        };
        let newCoin = coin::take(&mut marketplace.feeBalance, balance, ctx);
        transfer::transfer(newCoin, to);
    }

    public entry fun add_to_allowlist<C>(allowlist: &mut Allowlist, collection_auth: &CollectionControlCap<C>) {
        transfer_allowlist::insert_collection_with_cap<C, Witness>(& Witness {}, collection_auth, allowlist);
    }

    /// List an item at the Marketplace.
    public entry fun list<T: key + store>(
        marketplace: &mut Marketplace,
        item: T,
        ask: u64,
        ctx: &mut TxContext
    ) {
        list_and_get_id(marketplace, item, ask, ctx);
    }

    public fun list_and_get_id<T: key + store>(
        marketplace: &mut Marketplace,
        item: T,
        ask: u64,
        ctx: &mut TxContext
    ): ID {
        event::emit(ListNftEvent {
            nft_id: object::id(&item),
            ask,
            auction: false,
            type_name: type_name::get<T>(),
        });
        let id = object::new(ctx);
        let listing = Listing<T> {
            id,
            item,
            ask,
            owner: tx_context::sender(ctx),
        };
        let id = object::id(&listing); 
        ofield::add(&mut marketplace.id, id, listing);
        id
    }
    
    public fun adjust_listing<T: key + store>(
        marketplace: &mut Marketplace,
        listing_id: ID,
        ask: u64,
        ctx: &mut TxContext
    ) {
        let listing = ofield::borrow_mut<ID, Listing<T>>(&mut marketplace.id, listing_id);
        listing.ask = ask;
        assert!(tx_context::sender(ctx) == listing.owner, ENotOwner);
    }

    /// Remove listing and get an item back. Only owner can do that.
    public fun delist<T: key + store>(
        marketplace: &mut Marketplace,
        listing_id: ID,
        ctx: &mut TxContext
    ): T {
        let listing = ofield::remove<ID, Listing<T>>(&mut marketplace.id, listing_id);
        let Listing { id, item, ask: _, owner } = listing;
        object::delete(id);

        assert!(tx_context::sender(ctx) == owner, ENotOwner);

        event::emit(DelistNftEvent {
            nft_id: object::id(&item),
            sale_price: 0,
            sold: false,
            type_name: type_name::get<T>(),
        });

        item
    }

    /// Call [`delist`] and transfer item to the sender.
    public entry fun delist_and_take<T: key + store>(
        marketplace: &mut Marketplace,
        listing_id: ID,
        ctx: &mut TxContext
    ) {
        let item = delist<T>(marketplace, listing_id, ctx);
        transfer::transfer(item, tx_context::sender(ctx));
    }

    /// Purchase an item using a known Listing. Payment is done in Coin<SUI>.
    /// Amount paid must match the requested amount. If conditions are met,
    /// owner of the item gets the payment and buyer receives their item.
    public fun buy<T: key + store>(
        marketplace: &mut Marketplace,
        listing_id: ID,
        paid: Coin<SUI>,
        ctx: &mut TxContext
    ): T {
        nft_utils::assert_not_nft_protocol_type<T>();

        let listing = ofield::remove<ID, Listing<T>>(&mut marketplace.id, listing_id);

        let Listing { id, item, ask, owner } = listing;
        object::delete(id);

        event::emit(DelistNftEvent {
            nft_id: object::id(&item),
            sale_price: ask,
            sold: true,
            type_name: type_name::get<T>(),
        });

        let sent = coin::value(&paid);
        assert!(ask <= sent, EAmountIncorrect);
        let marketFee = (ask * (marketplace.fee as u64)) / 10000u64;

        // take our share
        let marketCoin = coin::split<SUI>(&mut paid, marketFee, ctx);
        coin::put(&mut marketplace.feeBalance, marketCoin);
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
    public entry fun buy_and_take<T: key + store>(
        marketplace: &mut Marketplace,
        listing_id: ID,
        paid: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        transfer::transfer(buy<T>(marketplace, listing_id, paid, ctx), tx_context::sender(ctx))
    }

    public fun buy_standard<C>(
        marketplace: &mut Marketplace,
        listing_id: ID,
        paid: Coin<SUI>,
        allowlist: & Allowlist,
        recipient: address,
        ctx: &mut TxContext
    ): Nft<C> {
        let listing = ofield::remove<ID, Listing<Nft<C>>>(&mut marketplace.id, listing_id);

        let Listing { id, item, ask, owner } = listing;
        object::delete(id);

        event::emit(DelistNftEvent {
            nft_id: object::id(&item),
            sale_price: ask,
            sold: true,
            type_name: type_name::get<Nft<C>>(),
        });

        let sent = coin::value(&paid);
        assert!(ask <= sent, EAmountIncorrect);
        let marketFee = (ask * (marketplace.fee as u64)) / 10000u64;

        // take our share
        let marketCoin = coin::split<SUI>(&mut paid, marketFee, ctx);
        coin::put(&mut marketplace.feeBalance, marketCoin);
        // if amount is exact, can skip splitting the amount
        if(sent > ask){
            transfer::transfer(coin::split(&mut paid, ask - marketFee, ctx), owner);
            transfer::transfer(paid, tx_context::sender(ctx));
        } else {
            transfer::transfer(paid, owner);
        };
        nft::change_logical_owner(&mut item, recipient, Witness {}, allowlist);

        item
    }

    public entry fun buy_standard_and_take<C>(
        marketplace: &mut Marketplace,
        listing_id: ID,
        paid: Coin<SUI>,
        allowlist: & Allowlist,
        ctx: &mut TxContext
    ) {
        let nft = buy_standard<C>(marketplace, listing_id, paid, allowlist, tx_context::sender(ctx), ctx);
        transfer::transfer(nft, tx_context::sender(ctx));
    }

    public entry fun auction<T: key + store>(
        marketplace: &mut Marketplace,
        item: T,
        min_bid: u64,
        min_bid_increment: u64,
        starts: u64,
        expires: u64,
        collateral: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        let balance = coin::into_balance(coin::split<SUI>(&mut collateral, marketplace.collateralFee, ctx));
        transfer::transfer(collateral, tx_context::sender(ctx));

        let id = object::new(ctx);
        let listing = AuctionListing<T> {
            id,
            item,
            min_bid,
            bid: balance::zero<SUI>(),
            collateral: balance,
            min_bid_increment: min_bid_increment,
            starts,
            expires,
            owner: tx_context::sender(ctx),
            bidder: tx_context::sender(ctx),
        };
        let id = object::id(&listing); 
        ofield::add(&mut marketplace.id, id, listing);
    }
    
    public entry fun bid<T: key + store>(
        marketplace: &mut Marketplace,
        listing_id: ID,
        paid: Coin<SUI>,
        new_bid: u64,
        ctx: &mut TxContext
    ) {

        let listing = ofield::borrow_mut<ID, AuctionListing<T>>(&mut marketplace.id, listing_id);
        let oldBid = balance::value(&listing.bid);
        // TODO: DEVNET ONLY. epoch on devnet seems to always return 0;
        // assert!(listing.expires > tx_context::epoch(ctx), ETooLate);
        // assert!(listing.starts < tx_context::epoch(ctx), ETooEarly);
        assert!(new_bid > oldBid + listing.min_bid_increment, EAmountIncorrect);
        assert!(new_bid >= listing.min_bid, EAmountIncorrect);

        if(oldBid > 0){
            transfer::transfer(coin::take<SUI>(&mut listing.bid, oldBid, ctx), listing.bidder);
        };
        let newCoin = coin::split<SUI>(&mut paid, new_bid, ctx);
        coin::put<SUI>(&mut listing.bid, newCoin);
        transfer::transfer(paid, tx_context::sender(ctx));

        listing.bidder =  tx_context::sender(ctx);
    }

    public fun complete_auction<T: key + store>(
        marketplace: &mut Marketplace,
        listing_id: ID,
        ctx: &mut TxContext
    ): WonAuction<T> {
        let listing = ofield::remove<ID, AuctionListing<T>>(&mut marketplace.id, listing_id);
        let AuctionListing { id, item, bid, collateral, min_bid_increment: _, owner, bidder, min_bid, starts: _, expires: _ } = listing;
        let finalBid = balance::value(&bid);
        
        nft_utils::assert_not_nft_protocol_type<T>();

        event::emit(DelistNftEvent {
            nft_id: object::id(&item),
            sale_price: finalBid,
            sold: true,
            type_name: type_name::get<T>(),
        });

        assert!(finalBid >= min_bid, ENoBid);
        // TODO: DEVNET ONLY. epoch on devnet seems to always return 0;
        //assert!(expires < tx_context::epoch(ctx), ETooEarly);
        //assert!(starts > tx_context::epoch(ctx), ETooLate);
        
        let fee = coin::from_balance(collateral, ctx);
        let feeVal = coin::value(&fee);
        if(feeVal > 0){
            transfer::transfer(fee, owner);
        } else {
            coin::destroy_zero(fee);
        };

        let paid = coin::from_balance<SUI>(bid, ctx);
        let marketFee = (finalBid * (marketplace.fee as u64)) / 10000u64;
        let marketCoin = coin::split<SUI>(&mut paid, marketFee, ctx);
        coin::put<SUI>(&mut marketplace.feeBalance, marketCoin);
        transfer::transfer(paid, owner);
        object::delete(id);
        WonAuction{ item, bidder }
    }

    public entry fun complete_auction_and_take<T: key + store>(
        marketplace: &mut Marketplace,
        listing_id: ID,
        ctx: &mut TxContext
    ) {
        let WonAuction<T> {item, bidder} = complete_auction(marketplace, listing_id, ctx);
        transfer::transfer(item, bidder);
    }

    
    public fun complete_auction_standard<C>(
        marketplace: &mut Marketplace,
        listing_id: ID,
        allowlist: & Allowlist,
        ctx: &mut TxContext
    ): WonAuction<Nft<C>> {
        let listing = ofield::remove<ID, AuctionListing<Nft<C>>>(&mut marketplace.id, listing_id);
        let AuctionListing { id, item, bid, collateral, min_bid_increment: _, owner, bidder, min_bid, starts: _, expires: _ } = listing;
        let finalBid = balance::value(&bid);

        event::emit(DelistNftEvent {
            nft_id: object::id(&item),
            sale_price: finalBid,
            sold: true,
            type_name: type_name::get<Nft<C>>(),
        });

        assert!(finalBid >= min_bid, ENoBid);
        // TODO: DEVNET ONLY. epoch on devnet seems to always return 0;
        //assert!(expires < tx_context::epoch(ctx), ETooEarly);
        //assert!(starts > tx_context::epoch(ctx), ETooLate);
        
        let fee = coin::from_balance(collateral, ctx);
        let feeVal = coin::value(&fee);
        if(feeVal > 0){
            transfer::transfer(fee, owner);
        } else {
            coin::destroy_zero(fee);
        };

        let paid = coin::from_balance<SUI>(bid, ctx);
        let marketFee = (finalBid * (marketplace.fee as u64)) / 10000u64;
        let marketCoin = coin::split<SUI>(&mut paid, marketFee, ctx);
        coin::put<SUI>(&mut marketplace.feeBalance, marketCoin);
        transfer::transfer(paid, owner);
        object::delete(id);
        nft::change_logical_owner(&mut item, bidder, Witness {}, allowlist);
        WonAuction<Nft<C>>{ item, bidder }
    }


    public entry fun complete_auction_and_take_standard<C>(
        marketplace: &mut Marketplace,
        listing_id: ID,
        allowlist: & Allowlist,
        ctx: &mut TxContext
    ) {
        let WonAuction<Nft<C>> {item, bidder} = complete_auction_standard<C>(marketplace, listing_id, allowlist, ctx);
        transfer::transfer(item, bidder);
    }




    /// Remove listing and get an item back. Only owner can do that.
    public fun deauction<T: key + store>(
        marketplace: &mut Marketplace,
        listing: AuctionListing<T>,
        ctx: &mut TxContext
    ): T {
        let AuctionListing { id, item, bid, bidder, min_bid_increment: _, expires: _, starts: _, min_bid: _, collateral, owner } = listing;
        
        event::emit(DelistNftEvent {
            nft_id: object::id(&item),
            sale_price: 0,
            sold: false,
            type_name: type_name::get<T>(),
        });

        let fee = coin::from_balance(collateral, ctx);
        let feeVal = coin::value(&fee);
        let paid = coin::from_balance<SUI>(bid, ctx);
        let paidVal = coin::value(&paid);

        if(feeVal > 0){
            // Take the fee, divide it among market owner, and bidder
            if(paidVal > 0){
                transfer::transfer(coin::split(&mut fee, feeVal / 2, ctx), marketplace.owner);
            };
            transfer::transfer(fee, bidder);
        } else {
            coin::destroy_zero(fee);
        };

        if(paidVal > 0){
            transfer::transfer(paid, bidder);
        } else {
            coin::destroy_zero(paid);
        };

        assert!(tx_context::sender(ctx) == owner, ENotOwner);
        // assert!(expires > tx_context::epoch(ctx) || expires == 0, ETooEarly);
        object::delete(id);
        item
    }

    /// Call [`delist`] and transfer item to the sender.
    public entry fun deauction_and_take<T: key + store>(
        marketplace: &mut Marketplace,
        listing_id: ID,
        ctx: &mut TxContext
    ) {
        let listing = ofield::remove<ID, AuctionListing<T>>(&mut marketplace.id, listing_id);
        let item = deauction(marketplace, listing, ctx);
        transfer::transfer(item, tx_context::sender(ctx));
    }

    public(friend) fun getWitness(): Witness {
        Witness {}
    }

    // getter functions for contracts to get info about our marketplace.
    public fun owner(
        market: &Marketplace,
    ): address {
        market.owner
    }

    public fun fee(
        market: &Marketplace,
    ): u16 {
        market.fee
    }

    public fun collateralFee(
        market: &Marketplace,
    ): u64 {
        market.collateralFee
    }

}
