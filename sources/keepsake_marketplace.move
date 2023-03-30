// Copyright (c) 2022, Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module keepsake::keepsake_marketplace {
    use std::option::{Self, Option};
    use std::type_name::{Self, TypeName};
    use sui::clock::{Self, Clock};
    
    use sui::tx_context::{Self, TxContext};
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::event;
    use sui::dynamic_object_field as dof;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::balance::{Self, Balance};
    use sui::package;

    use nft_protocol::transfer_allowlist::{Self, Allowlist, CollectionControlCap};
    use nft_protocol::nft::{Self, Nft};
    use nft_protocol::collection::{Collection};
    use nft_protocol::royalty::{Self};
    use nft_protocol::utils::{Self as nft_utils};

    friend keepsake::lending;
    
    const MaxFee: u16 = 2000; // 20%! Way too high, this is mostly to prevent accidents, like adding an extra 0
    const MaxWalletFee: u16 = 125;

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

    struct Wallet has key, store {
        id: UID,
        owner: address,
        fee: u16,
        fee_balance: Balance<SUI>,
    }

    struct Marketplace has key {
        id: UID,
        owner: address,
        fee: u16,
        fee_balance: Balance<SUI>,
        collateralFee: u64,
    }

    // OTW
    struct KEEPSAKE_MARKETPLACE has drop {}

    struct Witness has drop {}

    /// A single listing which contains the listed item and its price in [`Coin<C>`].
    // Potential improvement: make each listing part of a smaller shared object (e.g. per type, per seller, etc.)
    // store market details in the listing to prevent any need to interact with the Marketplace shared object?
    struct Listing<phantom T: key + store> has key, store {
        id: UID,
        item_id: ID,
        ask: u64, // Coin<C>
        owner: address,
        seller_wallet: Option<ID>,
    }

    struct AuctionListing<phantom T: key + store> has key, store {
        id: UID,
        item_id: ID,
        bid: Balance<SUI>,
        collateral: Balance<SUI>,
        min_bid: u64,
        min_bid_increment: u64,
        starts: u64,
        expires: u64,
        owner: address,
        bidder: address,
        seller_wallet: Option<ID>,
        buyer_wallet: Option<ID>,
    }

    struct WonAuction<T: key> {
        item: T,
        bidder: address
    }

    struct ListItemEvent has copy, drop {
        /// ID of the `Nft` that was listed
        item_id: ID,
        ask: u64,
        auction: bool,
        /// Type name of `Nft<C>` one-time witness `C`
        /// Intended to allow users to filter by collections of interest.
        type_name: TypeName,
    }

    struct DelistItemEvent has copy, drop {
        /// ID of the `Nft` that was listed
        item_id: ID,
        sale_price: u64,
        sold: bool,
        /// Type name of `Nft<C>` one-time witness `C`
        /// Intended to allow users to filter by collections of interest.
        type_name: TypeName,
    }

    fun init(otw: KEEPSAKE_MARKETPLACE, ctx: &mut TxContext) {
        package::claim_and_keep(otw, ctx);
        let id = object::new(ctx);

        let marketplace = Marketplace {
            id,
            owner: tx_context::sender(ctx),
            fee: 0,
            fee_balance: balance::zero<SUI>(),
            collateralFee: 0,
        };
        
        transfer::share_object(marketplace);
        let allowlist = transfer_allowlist::create<Witness>(& Witness {}, ctx);
        transfer::public_share_object(allowlist);
    }

    public entry fun updateMarket(
        marketplace: &mut Marketplace,
        owner: address,
        fee: u16,
        collateralFee: u64,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == marketplace.owner, ENotOwner);
        // collateral must be even for an even split
        assert!(collateralFee % 2 == 0, EAmountIncorrect);
        assert!(fee <= MaxFee, EAmountIncorrect);
        marketplace.owner = owner;
        marketplace.fee = fee;
        marketplace.collateralFee = collateralFee;
    }

    public entry fun createWallet(
        marketplace: &mut Marketplace,
        owner: address,
        fee: u16,
        ctx: &mut TxContext
    ) {
        assert!(fee <= MaxWalletFee, EAmountIncorrect);
        let id = object::new(ctx);
        let wallet = Wallet {
            id,
            owner,
            fee,
            fee_balance: balance::zero<SUI>(),
        };
        let id = object::id(&wallet); 
        dof::add(&mut marketplace.id, id, wallet);
    }

    public entry fun updateWallet(
        marketplace: &mut Marketplace,
        wallet_id: ID,
        owner: address,
        fee: u16,
        ctx: &mut TxContext
    ) {
        assert!(fee <= MaxWalletFee, EAmountIncorrect);
        let wallet = dof::borrow_mut<ID, Wallet>(&mut marketplace.id, wallet_id);
        assert!(tx_context::sender(ctx) == wallet.owner, ENotOwner);
        wallet.fee = fee;
        wallet.owner = owner;
    }

    public entry fun withdraw_from_wallet(
        marketplace: &mut Marketplace,
        wallet_id: ID,
        to: address,
        max: u64,
        ctx: &mut TxContext
    ) {
        let wallet = dof::borrow_mut<ID, Wallet>(&mut marketplace.id, wallet_id);
        assert!(tx_context::sender(ctx) == wallet.owner, ENotOwner);
        let balance = sui::balance::value(&wallet.fee_balance);
        if(max > balance){
            balance = max;
        };
        let newCoin = coin::take(&mut wallet.fee_balance, balance, ctx);
        transfer::public_transfer(newCoin, to);
    }
    
    public entry fun withdraw(
        marketplace: &mut Marketplace,
        to: address,
        max: u64,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == marketplace.owner, ENotOwner);
        let balance = sui::balance::value(&marketplace.fee_balance);
        if(max > balance){
            balance = max;
        };
        let newCoin = coin::take(&mut marketplace.fee_balance, balance, ctx);
        transfer::public_transfer(newCoin, to);
    }

    public entry fun add_to_allowlist<C>(
        allowlist: &mut Allowlist,
        collection_auth: &CollectionControlCap<C>
    ) {
        transfer_allowlist::insert_collection_with_cap<C, Witness>(& Witness {}, collection_auth, allowlist);
    }

    public entry fun add_authority_to_allowlist<Auth>(
        marketplace: &mut Marketplace,
        allowlist: &mut Allowlist,
        ctx: &mut TxContext
    ) {
        assert!(tx_context::sender(ctx) == marketplace.owner, ENotOwner);
        transfer_allowlist::insert_authority<Witness, Auth>(Witness {}, allowlist);
    }

    public entry fun list_with_wallet<T: key + store>(
        marketplace: &mut Marketplace,
        item: T,
        ask: u64,
        wallet: ID,
        ctx: &mut TxContext
    ) {
        list_and_get_id(marketplace, item, ask, option::some<ID>(wallet), ctx);
    }

    /// List an item at the Marketplace.
    public entry fun list<T: key + store>(
        marketplace: &mut Marketplace,
        item: T,
        ask: u64,
        ctx: &mut TxContext
    ) {
        list_and_get_id(marketplace, item, ask, option::none<ID>(), ctx);
    }

    public fun list_and_get_id<T: key + store>(
        marketplace: &mut Marketplace,
        item: T,
        ask: u64,
        seller_wallet: Option<ID>,
        ctx: &mut TxContext
    ): ID {
        event::emit(ListItemEvent {
            item_id: object::id(&item),
            ask,
            auction: false,
            type_name: type_name::get<T>(),
        });

        let item_id = object::id<T>(&item);

        let id = object::new(ctx);
        let listing = Listing<T> {
            id,
            item_id,
            ask,
            owner: tx_context::sender(ctx),
            seller_wallet,
        };
        let id = object::id(&listing); 
        dof::add(&mut marketplace.id, id, listing);
        dof::add(&mut marketplace.id, item_id, item);
        id
    }
    
    public fun adjust_listing<T: key + store>(
        marketplace: &mut Marketplace,
        item_id: ID,
        ask: u64,
        ctx: &mut TxContext
    ) {
        let listing = dof::borrow_mut<ID, Listing<T>>(&mut marketplace.id, item_id);
        listing.ask = ask;
        assert!(tx_context::sender(ctx) == listing.owner, ENotOwner);
    }

    /// Remove listing and get an item back. Only owner can do that.
    public fun delist<T: key + store>(
        marketplace: &mut Marketplace,
        listing_id: ID,
        ctx: &mut TxContext
    ): T {
        let listing = dof::remove<ID, Listing<T>>(&mut marketplace.id, listing_id);
        let Listing { id, item_id, ask: _, owner, seller_wallet: _ } = listing;
        let item = dof::remove<ID, T>(&mut marketplace.id, item_id);
        object::delete(id);

        assert!(tx_context::sender(ctx) == owner, ENotOwner);

        event::emit(DelistItemEvent {
            item_id: item_id,
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
        transfer::public_transfer(item, tx_context::sender(ctx));
    }

    // Send payments to the seller, marketplace, and seller wallet
    fun send_payments(
        marketplace: &mut Marketplace,
        paid: &mut Coin<SUI>,
        sent: u64,
        ask: u64,
        buyer_wallet_id: Option<ID>,
        seller_wallet_id: Option<ID>,
        ctx: &mut TxContext
    ): u64 {
        assert!(ask <= sent, EAmountIncorrect);
        let marketFee = (ask * (marketplace.fee as u64)) / 10000u64;
        let toTake = ask - marketFee;

        // take our share
        let marketCoin = coin::split<SUI>(paid, marketFee, ctx);
        coin::put(&mut marketplace.fee_balance, marketCoin);

        if(option::is_some<ID>(& seller_wallet_id)){
            // take seller wallet's portion from seller's cut
            let wallet = dof::borrow_mut<ID, Wallet>(&mut marketplace.id, option::extract<ID>(&mut seller_wallet_id));
            let walletFee = (ask * (wallet.fee as u64)) / 10000u64;
            toTake = toTake - walletFee;
            let walletCoin = coin::split<SUI>(paid, walletFee, ctx);
            coin::put<SUI>(&mut wallet.fee_balance, walletCoin);
        };

        if(option::is_some<ID>(& buyer_wallet_id)){
            // take seller wallet's portion from seller's cut
            let wallet = dof::borrow_mut<ID, Wallet>(&mut marketplace.id, option::extract<ID>(&mut buyer_wallet_id));
            let walletFee = (ask * (wallet.fee as u64)) / 10000u64;

            // Buyer has to pay extra, as seller doesn't consent to a buyers fee
            assert!(ask + walletFee <= sent, EAmountIncorrect);

            let walletCoin = coin::split<SUI>(paid, walletFee, ctx);
            coin::put<SUI>(&mut wallet.fee_balance, walletCoin);
        };

        toTake
    }

    fun send_royalty_payments<T>(
        marketplace: &mut Marketplace,
        paid: Coin<SUI>,
        ask: u64,
        collection: &mut Collection<T>,
        buyer_wallet_id: Option<ID>,
        seller_wallet_id: Option<ID>,
        owner: address,
        ctx: &mut TxContext
    ) {
        let sent = coin::value(&paid);
        let toTake = send_payments(marketplace, &mut paid, sent, ask, buyer_wallet_id, seller_wallet_id, ctx);

        let beforeRoyalty = coin::value(&paid);
        royalty::collect_royalty<T, SUI>(collection, coin::balance_mut<SUI>(&mut paid), ask);
        let remaining = coin::value(&paid);

        toTake = toTake - (beforeRoyalty - remaining);

        // if amount is exact, can skip splitting the amount
        if(remaining == toTake){
            transfer::public_transfer(paid, owner);
        } else {
            transfer::public_transfer(coin::split(&mut paid, toTake, ctx), owner);
            transfer::public_transfer(paid, tx_context::sender(ctx));
        };
    }

    fun handle_listing_collateral(
        collateral: Balance<SUI>,
        owner: address,
        ctx: &mut TxContext
    ) {
        let fee = coin::from_balance(collateral, ctx);
        let feeVal = coin::value(&fee);
        if(feeVal > 0){
            transfer::public_transfer(fee, owner);
        } else {
            coin::destroy_zero(fee);
        };
    }

    fun handle_unlisting_collateral(
        collateral: Balance<SUI>,
        bidder: address,
        bid: Balance<SUI>,
        market_owner: address,
        ctx: &mut TxContext
    ) {
        let fee = coin::from_balance(collateral, ctx);
        let feeVal = coin::value(&fee);

        let paid = coin::from_balance<SUI>(bid, ctx);
        let paidVal = coin::value(&paid);
        if(feeVal > 0){
            // Take the fee, divide it among market owner, and bidder
            if(paidVal > 0){
                transfer::public_transfer(coin::split(&mut fee, feeVal / 2, ctx), market_owner);
            };
            transfer::public_transfer(fee, bidder);
        } else {
            coin::destroy_zero(fee);
        };

        if(paidVal > 0){
            transfer::public_transfer(paid, bidder);
        } else {
            coin::destroy_zero(paid);
        };
    }

    /// Purchase an item using a known Listing. Payment is done in Coin<SUI>.
    /// Amount paid must match the requested amount. If conditions are met,
    /// owner of the item gets the payment and buyer receives their item.
    public fun buy<T: key + store>(
        marketplace: &mut Marketplace,
        listing_id: ID,
        paid: Coin<SUI>,
        buyer_wallet: Option<ID>,
        ctx: &mut TxContext
    ): T {
        nft_utils::assert_not_nft_protocol_type<T>();

        let listing = dof::remove<ID, Listing<T>>(&mut marketplace.id, listing_id);
        let Listing { id, item_id, ask, owner, seller_wallet } = listing;
        let item = dof::remove<ID, T>(&mut marketplace.id, item_id);
        object::delete(id);

        event::emit(DelistItemEvent {
            item_id: item_id,
            sale_price: ask,
            sold: true,
            type_name: type_name::get<T>(),
        });

        let sent = coin::value(&paid);
        let toTake = send_payments(marketplace, &mut paid, sent, ask, buyer_wallet, seller_wallet, ctx);

        let remaining = coin::value(&paid);
        // if amount is exact, can skip splitting the amount
        if(remaining == toTake){
            transfer::public_transfer(paid, owner);
        } else {
            transfer::public_transfer(coin::split(&mut paid, toTake, ctx), owner);
            transfer::public_transfer(paid, tx_context::sender(ctx));
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
        transfer::public_transfer(buy<T>(marketplace, listing_id, paid, option::none<ID>(), ctx), tx_context::sender(ctx))
    }

    public fun buy_standard<T>(
        marketplace: &mut Marketplace,
        listing_id: ID,
        paid: Coin<SUI>,
        buyer_wallet: Option<ID>,
        allowlist: & Allowlist,
        collection: &mut Collection<T>,
        recipient: address,
        ctx: &mut TxContext
    ): Nft<T> {
        let listing = dof::remove<ID, Listing<Nft<T>>>(&mut marketplace.id, listing_id);

        

        let Listing { id, item_id, ask, owner, seller_wallet } = listing;
        let item = dof::remove<ID, Nft<T>>(&mut marketplace.id, item_id);
        object::delete(id);

        event::emit(DelistItemEvent {
            item_id: item_id,
            sale_price: ask,
            sold: true,
            type_name: type_name::get<Nft<T>>(),
        });

        nft::change_logical_owner<T, Witness>(&mut item, recipient, Witness {}, allowlist);

        send_royalty_payments<T>(marketplace, paid, ask, collection, buyer_wallet, seller_wallet, owner, ctx);

        item
    }

    public entry fun buy_standard_and_take<T>(
        marketplace: &mut Marketplace,
        listing_id: ID,
        paid: Coin<SUI>,
        allowlist: & Allowlist,
        collection: &mut Collection<T>,
        ctx: &mut TxContext
    ) {
        let nft = buy_standard<T>(marketplace, listing_id, paid,  option::none<ID>(), allowlist, collection, tx_context::sender(ctx), ctx);
        transfer::public_transfer(nft, tx_context::sender(ctx));
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
        transfer::public_transfer(collateral, tx_context::sender(ctx));

        let id = object::new(ctx);
        let item_id = object::id<T>(&item);
        let listing = AuctionListing<T> {
            id,
            item_id,
            min_bid,
            bid: balance::zero<SUI>(),
            collateral: balance,
            min_bid_increment: min_bid_increment,
            starts,
            expires,
            owner: tx_context::sender(ctx),
            bidder: tx_context::sender(ctx),
            seller_wallet: option::none<ID>(),
            buyer_wallet: option::none<ID>(),
        };
        let id = object::id(&listing); 
        dof::add(&mut marketplace.id, id, listing);
        dof::add(&mut marketplace.id, item_id, item);
    }
    
    public entry fun bid<T: key + store>(
        marketplace: &mut Marketplace,
        listing_id: ID,
        paid: Coin<SUI>,
        new_bid: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {

        let listing = dof::borrow_mut<ID, AuctionListing<T>>(&mut marketplace.id, listing_id);
        let oldBid = balance::value(&listing.bid);
        assert!(new_bid >= oldBid + listing.min_bid_increment, EAmountIncorrect);
        assert!(new_bid >= listing.min_bid, EAmountIncorrect);

        let currentTime = clock::timestamp_ms(clock);
        assert!(listing.expires >= currentTime, ETooLate);
        assert!(listing.starts <= currentTime, ETooEarly);

        // send old bid back to bidder
        if(oldBid > 0){
            transfer::public_transfer(coin::take<SUI>(&mut listing.bid, oldBid, ctx), listing.bidder);
        };
        let newCoin = coin::split<SUI>(&mut paid, new_bid, ctx);
        coin::put<SUI>(&mut listing.bid, newCoin);
        transfer::public_transfer(paid, tx_context::sender(ctx));

        listing.bidder =  tx_context::sender(ctx);
    }

    public entry fun bid_with_wallet<T: key + store>(
        marketplace: &mut Marketplace,
        listing_id: ID,
        paid: Coin<SUI>,
        new_bid: u64,
        clock: &Clock,
        wallet_id: ID,
        ctx: &mut TxContext
    ) {

        let listing = dof::borrow_mut<ID, AuctionListing<T>>(&mut marketplace.id, listing_id);
        let oldBid = balance::value(&listing.bid);
        assert!(new_bid >= oldBid + listing.min_bid_increment, EAmountIncorrect);
        assert!(new_bid >= listing.min_bid, EAmountIncorrect);

        let currentTime = clock::timestamp_ms(clock);
        assert!(listing.expires >= currentTime, ETooLate);
        assert!(listing.starts <= currentTime, ETooEarly);

        // send old bid back to bidder
        if(oldBid > 0){
            transfer::public_transfer(coin::take<SUI>(&mut listing.bid, oldBid, ctx), listing.bidder);
        };
        let newCoin = coin::split<SUI>(&mut paid, new_bid, ctx);
        coin::put<SUI>(&mut listing.bid, newCoin);
        transfer::public_transfer(paid, tx_context::sender(ctx));

        listing.bidder =  tx_context::sender(ctx);
        option::fill<ID>(&mut listing.buyer_wallet, wallet_id);
    }

    public fun complete_auction<T: key + store>(
        marketplace: &mut Marketplace,
        listing_id: ID,
        clock: &Clock,
        ctx: &mut TxContext
    ): WonAuction<T> {
        let listing = dof::remove<ID, AuctionListing<T>>(&mut marketplace.id, listing_id);
        let AuctionListing { id, item_id, bid, collateral, min_bid_increment: _, owner, bidder, min_bid, starts: _, expires, seller_wallet, buyer_wallet } = listing;
        let item = dof::remove<ID, T>(&mut marketplace.id, item_id);
        object::delete(id);
        let finalBid = balance::value(&bid);
        let paid = coin::from_balance<SUI>(bid, ctx);
        
        nft_utils::assert_not_nft_protocol_type<T>();

        event::emit(DelistItemEvent {
            item_id: item_id,
            sale_price: finalBid,
            sold: true,
            type_name: type_name::get<T>(),
        });

        assert!(finalBid >= min_bid, ENoBid);
        let currentTime = clock::timestamp_ms(clock);
        assert!(expires < currentTime, ETooEarly);
        
        handle_listing_collateral(collateral, owner, ctx);

        let sent = coin::value(&paid);
        let toTake = send_payments(marketplace, &mut paid, sent, finalBid, buyer_wallet, seller_wallet, ctx);

        let remaining = coin::value(&paid);
        // if amount is exact, can skip splitting the amount
        if(remaining == toTake){
            transfer::public_transfer(paid, owner);
        } else {
            transfer::public_transfer(coin::split(&mut paid, toTake, ctx), owner);
            transfer::public_transfer(paid, tx_context::sender(ctx));
        };

        WonAuction{ item, bidder }
    }

    public entry fun complete_auction_and_take<T: key + store>(
        marketplace: &mut Marketplace,
        listing_id: ID,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let WonAuction<T> {item, bidder} = complete_auction(marketplace, listing_id, clock, ctx);
        transfer::public_transfer(item, bidder);
    }

    
    public fun complete_auction_standard<T>(
        marketplace: &mut Marketplace,
        listing_id: ID,
        clock: &Clock,
        allowlist: & Allowlist,
        collection: &mut Collection<T>,
        ctx: &mut TxContext
    ): WonAuction<Nft<T>> {
        let listing = dof::remove<ID, AuctionListing<Nft<T>>>(&mut marketplace.id, listing_id);
        let AuctionListing { id, item_id, bid, collateral, min_bid_increment: _, owner, bidder, min_bid, starts: _, expires, seller_wallet, buyer_wallet } = listing;
        let item = dof::remove<ID, Nft<T>>(&mut marketplace.id, item_id);
        let finalBid = balance::value(&bid);

        event::emit(DelistItemEvent {
            item_id: object::id(&item),
            sale_price: finalBid,
            sold: true,
            type_name: type_name::get<Nft<T>>(),
        });

        assert!(finalBid >= min_bid, ENoBid);
        let currentTime = clock::timestamp_ms(clock);
        assert!(expires < currentTime, ETooEarly);

        handle_listing_collateral(collateral, owner, ctx);

        let paid = coin::from_balance<SUI>(bid, ctx);
        send_royalty_payments<T>(marketplace, paid, finalBid, collection, buyer_wallet, seller_wallet, owner, ctx);
        
        object::delete(id);
        nft::change_logical_owner(&mut item, bidder, Witness {}, allowlist);
        WonAuction<Nft<T>>{ item, bidder }
    }

    public entry fun complete_auction_and_take_standard<T>(
        marketplace: &mut Marketplace,
        listing_id: ID,
        clock: &Clock,
        allowlist: & Allowlist,
        collection: &mut Collection<T>,
        ctx: &mut TxContext
    ) {
        let WonAuction<Nft<T>> {item, bidder} = complete_auction_standard<T>(marketplace, listing_id, clock, allowlist, collection, ctx);
        transfer::public_transfer(item, bidder);
    }

    /// Remove listing and get an item back. Only owner can do that.
    public fun deauction<T: key + store>(
        marketplace: &mut Marketplace,
        listing: AuctionListing<T>,
        clock: &Clock,
        ctx: &mut TxContext
    ): T {
        let AuctionListing { id, item_id, bid, bidder, min_bid_increment: _, expires, starts: _, min_bid: _, collateral, owner, seller_wallet: _, buyer_wallet: _ } = listing;
        let item = dof::remove<ID, T>(&mut marketplace.id, item_id);
        
        event::emit(DelistItemEvent {
            item_id: object::id(&item),
            sale_price: 0,
            sold: false,
            type_name: type_name::get<T>(),
        });

        handle_unlisting_collateral(
            collateral,
            bidder,
            bid,
            marketplace.owner,
            ctx,
        );

        assert!(tx_context::sender(ctx) == owner, ENotOwner);
        let currentTime = clock::timestamp_ms(clock);
        assert!(expires < currentTime, ETooEarly);
        object::delete(id);
        item
    }

    /// Call [`delist`] and transfer item to the sender.
    public entry fun deauction_and_take<T: key + store>(
        marketplace: &mut Marketplace,
        listing_id: ID,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let listing = dof::remove<ID, AuctionListing<T>>(&mut marketplace.id, listing_id);
        let item = deauction(marketplace, listing, clock, ctx);
        transfer::public_transfer(item, tx_context::sender(ctx));
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
