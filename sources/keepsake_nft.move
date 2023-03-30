module keepsake_nft::keepsake_nft {
    use std::string::String;
    use std::ascii::{String as Ascii};
    use std::vector;

    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::object::{Self, UID, ID};
    use sui::url;
    use sui::coin::{Coin};
    use sui::sui::SUI;
    // use sui::event;
    // use sui::vec_map::{Self, VecMap};

    use nft_protocol::transfer_allowlist::{Self, Allowlist};
    use nft_protocol::collection::{Self};
    use nft_protocol::mint_cap::{MintCap};
    use nft_protocol::nft::{Self, Nft};
    use nft_protocol::listing::{Self, Listing};
    use nft_protocol::display;
    use nft_protocol::royalty;
    use nft_protocol::attributes;
    use nft_protocol::witness::{Self};
    use nft_protocol::limited_fixed_price;
    
    use keepsake::keepsake_marketplace::{Self, Marketplace};

    /// The type identifier of the NFT. The coin will have a type
    /// tag of kind: `Nft<package_object::keepsake_nft::KEEPSAKE>`
    struct KEEPSAKE has store, drop {}
    struct NFTCarrier has key { id: UID, witness: KEEPSAKE }
    struct Witness has drop {}

    fun init(ctx: &mut TxContext) {
        transfer::transfer(
            NFTCarrier { id: object::new(ctx), witness: KEEPSAKE {} },
            tx_context::sender(ctx)
        )
    }

    /// Module initializer is called once on module publish. A treasury
    /// cap is sent to the publisher, who then controls minting and burning
    public entry fun create(
        name: String,
        description: String,
        symbol: String,
        royalty_receiver: address,
        _tags: vector<vector<u8>>,
        royalty_fee_bps: u64, // 10,000 = 100%
        _max_supply: u64,
        carrier: NFTCarrier,
        ctx: &mut TxContext,
    ) {
        let NFTCarrier { id, witness } = carrier;
        object::delete(id);

        let (mint_cap, collection) = collection::create<KEEPSAKE>(
            & witness,
            ctx,
        );
        let delegated_witness = witness::from_witness<KEEPSAKE, Witness>(&Witness {});
        let collectionControlCap = transfer_allowlist::create_collection_cap<KEEPSAKE>(delegated_witness, ctx);
        transfer::public_transfer(collectionControlCap, tx_context::sender(ctx));
        
        display::add_collection_display_domain<KEEPSAKE, KEEPSAKE>(&KEEPSAKE {}, &mut collection, name, description);
        display::add_collection_symbol_domain<KEEPSAKE, KEEPSAKE>(&KEEPSAKE {}, &mut collection, symbol);

        let royalty = royalty::from_address(royalty_receiver, ctx);
        royalty::add_proportional_royalty(
            &mut royalty,
            royalty_fee_bps,
        );
        royalty::add_royalty_domain<KEEPSAKE, KEEPSAKE>(&KEEPSAKE {}, &mut collection, royalty);

        // let tags = tags::empty(ctx);
        // tags::add_tag(&mut tags, tags::art());
        // tags::add_collection_tag_domain(&mut collection, &mut mint_cap, tags);

        transfer::public_share_object(collection);
        transfer::public_transfer(mint_cap, tx_context::sender(ctx));
    }

    public entry fun create_launchpad(
        _mint_cap: &mut MintCap<KEEPSAKE>,
        prices: vector<u64>,
        allowlist: vector<bool>,
        limits: vector<u64>,
        ctx: &mut TxContext
    ) {
        let listing = listing::new(
            tx_context::sender(ctx),
            tx_context::sender(ctx),
            ctx,
        );

        let i = 0;
        let n = vector::length(&prices);
        assert!(vector::length(&prices) == vector::length(&allowlist), 0);

        while (i < n) {
            let delegated_witness = witness::from_witness<KEEPSAKE, Witness>(&Witness {});
            let inventory_id = listing::create_warehouse<KEEPSAKE>(delegated_witness, &mut listing, ctx);
                
            let allowlisted = vector::pop_back<bool>(&mut allowlist);
            let limit = vector::pop_back<u64>(&mut limits);
            let price = vector::pop_back<u64>(&mut prices);

            limited_fixed_price::create_venue<KEEPSAKE, sui::sui::SUI>(
                &mut listing,
                inventory_id,
                allowlisted, // is whitelisted
                price, // price
                limit,
                ctx,
            );
            // nft_protocol::dutch_auction::create_market_on_listing<sui::sui::SUI>(
            //     &mut listing,
            //     inventory_id,
            //     whitelisted, // is whitelisted
            //     price, // reserve price
            //     ctx,
            // );
            i=i+1;
        };
        transfer::public_share_object(listing);
    }

    public entry fun add_launchpad_tier(
        listing: &mut Listing,
        _mint_cap: &mut MintCap<KEEPSAKE>,
        prices: vector<u64>,
        allowlist: vector<bool>,
        limits: vector<u64>,
        ctx: &mut TxContext
    ) {

        let i = 0;
        let n = vector::length(&prices);
        assert!(vector::length(&prices) == vector::length(&allowlist), 0);

        while (i < n) {
            let delegated_witness = witness::from_witness<KEEPSAKE, Witness>(&Witness {});
            let inventory_id = listing::create_warehouse<KEEPSAKE>(delegated_witness, listing, ctx);
                
            let allowlisted = vector::pop_back<bool>(&mut allowlist);
            let limit = vector::pop_back<u64>(&mut limits);
            let price = vector::pop_back<u64>(&mut prices);

            limited_fixed_price::create_venue<KEEPSAKE, sui::sui::SUI>(
                listing,
                inventory_id,
                allowlisted, // is whitelisted
                price, // price
                limit,
                ctx,
            );
            // nft_protocol::dutch_auction::create_market_on_listing<sui::sui::SUI>(
            //     &mut listing,
            //     inventory_id,
            //     whitelisted, // is whitelisted
            //     price, // reserve price
            //     ctx,
            // );
            i=i+1;
        };
    }

    public entry fun set_live(
        listing: &mut Listing,
        venue_id: ID,
        live: bool, 
        ctx: &mut TxContext,
    ) {
        if(live){
            listing::sale_on(listing, venue_id, ctx);
        } else {
            listing::sale_off(listing, venue_id, ctx);
        };
    }

    public entry fun set_multi_live(
        listing: &mut Listing,
        merkets: vector<ID>,
        lives: vector<bool>,
        ctx: &mut TxContext,
    ) {
        let i = 0;
        let n = vector::length(&merkets);
        while (i < n) {
            let live = vector::pop_back<bool>(&mut lives);
            let market = vector::pop_back<ID>(&mut merkets);
            if(live) {
                listing::sale_on(listing, market, ctx);
            } else {
                listing::sale_off(listing, market, ctx);
            };
        }
    }
    // fun archetype(
    //     name: String,
    //     description: String,
    //     url: vector<u8>,
    //     attribute_keys: vector<String>,
    //     attribute_values: vector<String>,
    //     supply: u64,
    //     mint_cap: &mut MintCap<KEEPSAKE>,
    //     ctx: &mut TxContext
    // ) : Archetype<KEEPSAKE>{
    //     let archetype = flyweight::new(supply, mint_cap, ctx);
    //     let nft = flyweight::borrow_nft_mut(&mut archetype, mint_cap);
    //     // display::add_display_domain<KEEPSAKE>(nft, name, description, ctx);
    //     // display::add_url_domain(nft, url::new_unsafe_from_bytes(url), ctx);
    //     // display::add_attributes_domain_from_vec<KEEPSAKE>(nft, attribute_keys, attribute_values, ctx);
    //     archetype
    // }

    // public entry fun mint_data(
    //     name: String,
    //     description: String,
    //     url: vector<u8>,
    //     attribute_keys: vector<String>,
    //     attribute_values: vector<String>,
    //     supply: u64,
    //     mint_cap: &mut MintCap<KEEPSAKE>,
    //     ctx: &mut TxContext,
    // ) {
    //     transfer::share_object(archetype(name, description, url, attribute_keys, attribute_values, supply, mint_cap, ctx));
    // }

    // public entry fun mint_singular_data(
    //     name: String,
    //     description: String,
    //     url: vector<u8>,
    //     attribute_keys: vector<String>,
    //     attribute_values: vector<String>,
    //     mint_cap: &mut MintCap<KEEPSAKE>,
    //     recipient: address,
    //     allowlist: & Allowlist,
    //     ctx: &mut TxContext,
    // ) {
    //     let archetype = archetype(name, description, url, attribute_keys, attribute_values, 1, mint_cap, ctx);
    //     let minted = nft::new<KEEPSAKE>(tx_context::sender(ctx), ctx);
    //     flyweight::set_archetype(ctx, &mut minted, &mut archetype, mint_cap);
    //     nft::change_logical_owner(&mut minted, recipient, KEEPSAKE {}, allowlist);
    //     transfer::transfer(minted, recipient);
    //     transfer::share_object(archetype);
    // }

    fun mint(
        name: String,
        description: String,
        url: vector<u8>,
        attribute_keys: vector<Ascii>,
        attribute_values: vector<Ascii>,
        mint_cap: &mut MintCap<KEEPSAKE>,
        ctx: &mut TxContext,
    ) : Nft<KEEPSAKE> {
        let minted = nft::from_mint_cap(mint_cap, name, url::new_unsafe_from_bytes(url), ctx);
        
        display::add_display_domain<KEEPSAKE, KEEPSAKE>(&KEEPSAKE {}, &mut minted, name, description);

        let delegated_witness = witness::from_witness<KEEPSAKE, Witness>(&Witness {});
        nft::set_url<KEEPSAKE>(delegated_witness, &mut minted, url::new_unsafe_from_bytes(url));

        attributes::add_domain_from_vec<KEEPSAKE, KEEPSAKE>(&KEEPSAKE {}, &mut minted, attribute_keys, attribute_values);
        
        minted
    }

    public entry fun mint_to(
        name: String,
        description: String,
        url: vector<u8>,
        attribute_keys: vector<Ascii>,
        attribute_values: vector<Ascii>,
        mint_cap: &mut MintCap<KEEPSAKE>,
        recipient: address,
        allowlist: & Allowlist,
        count: u8,
        ctx: &mut TxContext,
    ) {
        let i = 0;
        while(i < count) {
            let minted = mint(
                name,
                description,
                url,
                attribute_keys,
                attribute_values,
                mint_cap,
                ctx
            );
            if(tx_context::sender(ctx) != recipient){
                nft::change_logical_owner(&mut minted, recipient, KEEPSAKE {}, allowlist);
            };
            transfer::public_transfer(minted, recipient);
            i=i+1;
        }
    }

    public entry fun mint_and_list(
        name: String,
        description: String,
        url: vector<u8>,
        attribute_keys: vector<Ascii>,
        attribute_values: vector<Ascii>,
        mint_cap: &mut MintCap<KEEPSAKE>,
        _allowlist: & Allowlist,
        count: u8,
        marketplace: &mut Marketplace,
        ask: u64,
        ctx: &mut TxContext
    ) {
        let i = 0;
        while(i < count) {
            let newNFT = mint(
                name,
                description,
                url,
                attribute_keys,
                attribute_values,
                mint_cap,
                ctx
            );
            // nft::change_logical_owner(&mut newNFT, marketplace_nofee::owner(marketplace), KEEPSAKE {}, allowlist);
            keepsake_marketplace::list<Nft<KEEPSAKE>>(marketplace, newNFT, ask, ctx);
            i=i+1;
        }
    }

    public entry fun mint_and_auction(
        name: String,
        description: String,
        url: vector<u8>,
        attribute_keys: vector<Ascii>,
        attribute_values: vector<Ascii>,
        mint_cap: &mut MintCap<KEEPSAKE>,
        _allowlist: & Allowlist,
        marketplace: &mut Marketplace,
        min_bid: u64,
        starts: u64,
        expires: u64,
        collateral: Coin<SUI>,
        min_bid_increment: u64,
        ctx: &mut TxContext
    ) {
        let newNFT = mint(
            name,
            description,
            url,
            attribute_keys,
            attribute_values,
            mint_cap,
            ctx
        );
        // nft::change_logical_owner(&mut newNFT, marketplace_nofee::owner(marketplace), KEEPSAKE {}, allowlist);
        keepsake_marketplace::auction<Nft<KEEPSAKE>>(marketplace, newNFT, min_bid, min_bid_increment, starts, expires, collateral, ctx);
    }

    public entry fun mint_launchpad(
        name: String,
        description: String,
        url: vector<u8>,
        attribute_keys: vector<Ascii>,
        attribute_values: vector<Ascii>,
        mint_cap: &mut MintCap<KEEPSAKE>,
        listing: &mut Listing,
        inventory: ID, // Inventory
        count: u8,
        ctx: &mut TxContext,
    ) {
        let i = 0;
        while(i < count) {
            let nft = mint(
                name,
                description,
                url,
                attribute_keys,
                attribute_values,
                mint_cap,
                ctx
            );
            listing::add_nft<KEEPSAKE>(listing, inventory, nft, ctx);
            i=i+1;
        }
    }
}
