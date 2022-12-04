const { Ed25519Keypair, JsonRpcProvider, RawSigner, Base64DataBuffer, PublicKey, bcs  } = require('@mysten/sui.js');
const fs = require('fs');
const utils  = require("./utils");

const args = process.argv.slice(2);

let provider = new JsonRpcProvider('https://fullnode.devnet.sui.io:443');

const module_name = process.env.module_name;

keypair = Ed25519Keypair.fromSecretKey(Buffer.from(process.env.pkey, "hex"), {skipValidation: true});
const address = "0x" + keypair.getPublicKey().toSuiAddress();
console.log("using address: " + address);
const signer = new RawSigner(keypair, provider);

const fileData = fs.readFileSync(`./deployed_modules/output.json`);
const deployed = JSON.parse(fileData);

const moduleInfo = deployed[module_name];
const moduleName = "marketplace_nofee";
const packageObjectId = moduleInfo.packageObjectId;
const bag = moduleInfo.bag;
const market = moduleInfo.market;

const NFTCap = utils.getItemByType(moduleInfo.createdObjects, "MetaNFTIssuerCap");

const create = async() => {

    let module = args[1] || moduleName;

    const newMarketTx = await signer.executeMoveCall({
        packageObjectId,
        module,
        function: 'create',
        typeArguments: [],
        arguments: [address, 250],
        gasBudget: 10000,
    }, "WaitForEffectsCert");
    const created = newMarketTx.EffectsCert.effects.effects.created.map((item) => item.reference.objectId);
    const newMarket = created[0];

    deployed[module_name].market = newMarket;
    fs.writeFileSync(`./deployed_modules/output.json`, JSON.stringify(deployed, null,'\t'));
}

const mint = async() => {
    let objects = await provider.getObjectsOwnedByAddress(address);
    let coin = await utils.getUserCoins(provider, objects, 10000);
    let gasPayment = coin.data.id.id;

    const newNFT = await signer.executeMoveCall({
        packageObjectId,
        module: 'meta_nft',
        function: 'mint',
        typeArguments: [],
        arguments: [
            NFTCap,
            'Keepsake NFT',
            'An Example Keepsake NFT',
            'https://ipfs.io/ipfs/QmZPWWy5Si54R3d26toaqRiqvCH7HkGdXkxwUgCm2oKKM2?filename=img-sq-01.png',
        ],
        gasPayment,
        gasBudget: 10000,
    }, "WaitForEffectsCert").then((res) => {
        return res.EffectsCert.effects.created[0];
    });

    console.log("new nft " + newNFT);
    objects = await provider.getObjectsOwnedByAddress(address);
    coin = await utils.getUserCoins(provider, objects, 10000);
    gasPayment = coin.data.id.id;
    
    await signer.executeMoveCall({
        packageObjectId,
        module: 'dev_utils',
        function: 'transfer',
        typeArguments: [ `${packageObjectId}::meta_nft::MetaNFT`],
        arguments: [
            newNFT,
            args[1],
        ],
        gasPayment,
        gasBudget: 5000,
    }, "WaitForEffectsCert");
};

const list = async () => {
    let objects = await provider.getObjectsOwnedByAddress(address);
    let coin = await utils.getUserCoins(provider, objects, 10000);
    let gasPayment = coin.data.id.id;
    const newNFT2 = await signer.executeMoveCall({
        packageObjectId,
        module: 'meta_nft',
        function: 'mint',
        typeArguments: [],
        arguments: [
            NFTCap,
            'Keepsake NFT',
            'An Example Keepsake NFT',
            'https://ipfs.io/ipfs/QmZPWWy5Si54R3d26toaqRiqvCH7HkGdXkxwUgCm2oKKM2?filename=img-sq-01.png',
        ],
        gasPayment,
        gasBudget: 10000,
    }).then((res) => {
        return res.effects.created[0].reference.objectId;
    });

    const moveCallTxn2 = await signer.executeMoveCall({
        packageObjectId,
        module: moduleName,
        function: 'list',
        typeArguments: [ `${packageObjectId}::meta_nft::MetaNFT`, "0x2::sui::SUI"],
        arguments: [
            market,
            bag,
            newNFT2,
            1200,
        ],
        gasBudget: 10000,
    }).then((res) => {
        return res.effects.created;
    });
    const ListingId = utils.getItemByType(moveCallTxn2, "Listing");
    console.log("Listing ID: " + ListingId);
}

const buy = async () => {
    let buying = args[1];

    let objects = await provider.getObjectsOwnedByAddress(address);
    let coin = await utils.getUserCoins(provider, objects, 10000000);
    coin = coin.data.id.id;
    await signer.executeMoveCall({
        packageObjectId,
        module: "marketplace_nofee",
        function: 'buy_and_take',
        typeArguments: [ `${packageObjectId}::meta_nft::MetaNFT`, "0x2::sui::SUI"],
        arguments: [
            market,
            buying,
            coin,
        ],
        gasBudget: 2000,
    }, "WaitForEffectsCert");
}


const auction = async () => {
    let objects = await provider.getObjectsOwnedByAddress(address);
    let coin = await utils.getUserCoins(provider, objects, 10000);

    const newNFT = await signer.executeMoveCall({
        packageObjectId,
        module: 'meta_nft',
        function: 'mint',
        typeArguments: [],
        arguments: [
            NFTCap,
            'Keepsake NFT',
            'An Example Keepsake NFT',
            'https://ipfs.io/ipfs/QmZPWWy5Si54R3d26toaqRiqvCH7HkGdXkxwUgCm2oKKM2?filename=img-sq-01.png',
        ],
        gasBudget: 1000,
    }).then((res) => {
        return res.effects.created[0].reference.objectId;
    });

    const now = Date.now();

    let bid = 1;

    const auction = await signer.executeMoveCall({
        packageObjectId,
        module: moduleName,
        function: 'auction',
        typeArguments: [ `${packageObjectId}::meta_nft::MetaNFT`, "0x2::sui::SUI"],
        arguments: [
            market,
            newNFT,
            bid,
            now - 6000,
            now + 6000,
        ],
        gasBudget: 1000,
    }, "WaitForEffectsCert").then((res) => {
        return res.effects.created[0].reference.objectId;
    });

    objects = await provider.getObjectsOwnedByAddress(address);
    coin = await utils.getUserCoins(provider, objects, bid);

    await signer.executeMoveCall({
        packageObjectId,
        module: moduleName,
        function: 'bid',
        typeArguments: [ `${packageObjectId}::meta_nft::MetaNFT`, "0x2::sui::SUI"],
        arguments: [
            market,
            auction,
            coin.data.id.id,
            bid,
        ],
        gasBudget: 1000,
    });

    bid += 1;
    objects = await provider.getObjectsOwnedByAddress(address);
    coin = await utils.getUserCoins(provider, objects, bid);

    await signer.executeMoveCall({
        packageObjectId,
        module: moduleName,
        function: 'bid',
        typeArguments: [ `${packageObjectId}::meta_nft::MetaNFT`, "0x2::sui::SUI"],
        arguments: [
            market,
            auction,
            coin.data.id.id,
            bid,
        ],
        gasBudget: 1000,
    });

    const info = await signer.executeMoveCall({
        packageObjectId,
        module: moduleName,
        function: 'complete_auction_and_take',
        typeArguments: [ `${packageObjectId}::meta_nft::MetaNFT`, "0x2::sui::SUI"],
        arguments: [
            market,
            auction,
        ],
        gasBudget: 1000,
    }, "WaitForEffectsCert");
}

eval(args[0] + "()");
