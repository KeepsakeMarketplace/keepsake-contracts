// Copyright (c) 2022, Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module nfts::meta_nft {
    use std::ascii::{Self, String};
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    /// Basic NFT
    struct MetaNFT has key, store {
        id: UID,
        name: String,
        description: String,
        url: String,
    }

    struct MetaNFTIssuerCap has key, store {
        id: UID,
        /// Number of NFT<MetaNFT>'s in circulation. Fluctuates with minting and burning.
        /// A maximum of `MAX_SUPPLY` NFT<MetaNFT>'s can exist at a given time.
        supply: u64,
        /// Total number of NFT<MetaNFT>'s that have been issued. Always <= `supply`.
        /// The next NFT<MetaNFT> to be issued will have the value of the counter.
        issued_counter: u64,
    }

    /// Created more than the maximum supply of MetaNFT NFT's
    const ETooManyNums: u64 = 0;

    /// Create a unique issuer cap and give it to the transaction sender
    fun init(ctx: &mut TxContext) {
        let issuer_cap = MetaNFTIssuerCap {
            id: object::new(ctx),
            supply: 0,
            issued_counter: 0,
        };
        transfer::transfer(issuer_cap, tx_context::sender(ctx))
    }

    /// Create a new `MetaNFT` NFT. Aborts if `MAX_SUPPLY` NFT's have already been issued
    public entry fun mint(cap: &mut MetaNFTIssuerCap,
        name: vector<u8>,
        description: vector<u8>,
        image: vector<u8>,
        ctx: &mut TxContext) {
        let n = cap.issued_counter;
        cap.issued_counter = n + 1;
        cap.supply = cap.supply + 1;
        let newNFT = MetaNFT {
            id: object::new(ctx),
            name: ascii::string(name),
            description: ascii::string(description),
            url: ascii::string(image)
        };
        transfer::transfer(newNFT, tx_context::sender(ctx))
    }

    /// Burn `nft`. This reduces the supply.
    /// Note: if we burn (e.g.) the NFT<MetaNFT> for 7, that means
    /// no MetaNFT with the value 7 can exist again! But if the supply
    /// is maxed out, burning will allow us to mint new MetaNFT's with
    /// higher values.
    public entry fun burn(cap: &mut MetaNFTIssuerCap, nft: MetaNFT) {
        let MetaNFT { id,
            name: _,
            description: _,
            url: _ } = nft;
        cap.supply = cap.supply - 1;
        object::delete(id);
    }
}
