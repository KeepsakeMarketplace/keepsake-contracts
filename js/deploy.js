const { Ed25519Keypair, JsonRpcProvider, TransactionBlock, normalizeSuiObjectId, devnetConnection, RawSigner } = require('@mysten/sui.js');
const fs = require('fs/promises');
const {wait, getUserCoins, processTxResults, getItemByType} = require("./utils");
const { execSync } = require('child_process');

const args = process.argv.slice(2);
let provider = new JsonRpcProvider(devnetConnection);

let keypair = Ed25519Keypair.fromSecretKey(Buffer.from(process.env.pkey, "base64").slice(1), {skipValidation: true});
const address = keypair.getPublicKey().toSuiAddress();
const elements_file = `./alchemy_elements.json`;
console.log(address);
const signer = new RawSigner(keypair, provider);

const deploy = async() => {
    const module_name = process.env.module_name;
    const module_folder = `./build/${module_name}/bytecode_modules`;
    const contracts = (await fs.readdir(module_folder)).filter((contract) => {
        return(contract.split('.').pop() == "mv") ;
    });

    // Generate a new Keypair
    // let keypair = new Ed25519Keypair();
    // console.log(keypair.keypair.secretKey);
    // console.log(Buffer.from(keypair.keypair.secretKey).toString('hex'));
    const signer = new RawSigner(keypair, provider);

    const compiledModulesAndDependencies = JSON.parse(
      execSync(
        `sui move build --dump-bytecode-as-base64`,
        { encoding: 'utf-8' },
      ),
    );
    

    const gasBudget = 30000;

    try {
        let tx = new TransactionBlock();
        tx.setGasBudget(gasBudget);
        const publishedItems = tx.publish(
            compiledModulesAndDependencies.modules.map((m) => Array.from(Uint8Array.from(Buffer.from(m, 'base64')))),
            compiledModulesAndDependencies.dependencies.map((addr) =>
              normalizeSuiObjectId(addr),
            ));
        const upgradeCap = publishedItems[0];

        tx.transferObjects( [upgradeCap], tx.pure(address));
        
        const info = await signer.signAndExecuteTransactionBlock({transactionBlock: tx, options: {showEffects:true}, requestType: 'WaitForEffectsCert'});
        
        if(info.effects?.status?.status !== 'success') {
            console.log(info);
            return;
        }
        const created = info.effects.created.map((item) => item.reference.objectId);
        const createdInfo = await provider.multiGetObjects({ids: created, options: {showContent: true, showType: true, showOwner: true}});

        let packageObjectId = false;
        let createdObjects = []

        createdInfo.forEach((item) => {
            if(item.data.type === "package"){
                packageObjectId = item.data.objectId;
            } else {
                createdObjects.push({ type: item.data.type, objectId: item.data.objectId,  owner: item.data.owner });
            }
        });
        const deployed = await fs.readFile(`./deployed_modules/output.json`).then((rawdata) => JSON.parse(rawdata));
        deployed[module_name] = { packageObjectId, createdObjects};
        await fs.writeFile(`./deployed_modules/output.json`, JSON.stringify(deployed,null,'\t'));

        const newMarket = getItemByType(createdObjects, "keepsake_marketplace::Marketplace");
        const allowlist = getItemByType(createdObjects, "Allowlist");

        tx = new TransactionBlock();
        tx.moveCall({
            target: `${packageObjectId}::keepsake_marketplace::updateMarket`,
            typeArguments: [],
            arguments: [tx.object(newMarket), tx.pure(address), tx.pure("250"), tx.pure("10000")]
        });
        tx.setGasBudget(gasBudget);
        await signer.signAndExecuteTransactionBlock({transactionBlock: tx, requestType: 'WaitForEffectsCert'});
        await wait(5000);
        
        tx = new TransactionBlock();
        tx.moveCall({
            target: `${packageObjectId}::keepsake_marketplace::add_authority_to_allowlist`,
            typeArguments: [`${packageObjectId}::lending::Witness`],
            arguments: [tx.object(newMarket), tx.object(allowlist)],
        });

        tx.setGasBudget(gasBudget);
        await signer.signAndExecuteTransactionBlock({transactionBlock: tx, requestType: 'WaitForEffectsCert'});
        await wait(5000);

        await fs.writeFile(`./deployed_modules/output.json`, JSON.stringify(deployed, null,'\t'));
        console.log(packageObjectId);
    } catch(e) {
        console.log(e);
    }
};

const contract = async() => {
    const module_name = process.env.module_name;
    const module_file = `./build/${module_name}/bytecode_modules/${args[1]}.mv`;
    const fileData =  await fs.readFile(module_file, 'base64');
    const compiledModule = fileData.toString();

    // Generate a new Keypair
    // let keypair = new Ed25519Keypair();
    // console.log(keypair.keypair.secretKey);

    keypair = Ed25519Keypair.fromSecretKey(Buffer.from(process.env.pkey, "hex"), {skipValidation: true});
    const signer = new RawSigner(keypair, provider);
    // console.log(Buffer.from(keypair.keypair.secretKey).toString('hex'));
    // const address = "0x" + keypair.getPublicKey().toSuiAddress();


    const gasBudget = 10000;
    const toPublish = { compiledModules: [compiledModule], gasBudget };

    try {
        const info = await signer.publish(toPublish, 'WaitForEffectsCert');

        const created = info.EffectsCert.effects.created.map((item) => item.reference.objectId);
        const createdInfo = await provider.multiGetObjects({ids: created});

        let packageObjectId = false;
        let createdObjects = []

        createdInfo.forEach((item) => {
            if(item.details.data?.dataType === "package"){
                packageObjectId = item.details.reference.objectId;
            } else {
                createdObjects.push({ type: item.details.data.type, objectId: item.details.reference.objectId,  owner: item.details.owner.AddressOwner });
            }
        });

        const deployed = await fs.readFile(`./deployed_modules/output.json`).then((rawdata) => JSON.parse(rawdata));
        if(!deployed["individual"]){
            deployed["individual"] = {};
        }
        deployed["individual"][args[1]] = { packageObjectId, createdObjects};
        fs.writeFile(`./deployed_modules/output.json`, JSON.stringify(deployed,null,'\t'));
    } catch(e) {
        console.log(e);
    }
};

const transfer = async() => {
  const objectId = args[1];
  const recipient = args[2] || "0xb758af2061e7c0e55df23de52c51968f6efbc959";
  const unsignedTxn = {
    kind: 'transferObject',
    data: {
      gasBudget: 2000,
      objectId,
      recipient,
    },
  };
  keypair = Ed25519Keypair.fromSecretKey(Buffer.from(process.env.pkey, "hex"), {skipValidation: true});
  const signer = new RawSigner(keypair, provider);
  return signer
    .signAndExecuteTransactionWithRequestType(unsignedTxn, 'WaitForEffectsCert')
    .then((thisTx) => thisTx.EffectsCert.effects);
}

const nftprotocol = async() => {
    const module_name = "NftProtocol";
    const module_folder = `./nft-protocol/build/${module_name}/bytecode_modules`;
    const contracts = (await fs.readdir(module_folder)).filter((contract) => {
        return(contract.split('.').pop() == "mv") ;
    });

    // Generate a new Keypair
    // let keypair = new Ed25519Keypair();
    // console.log(keypair.keypair.secretKey);

    keypair = Ed25519Keypair.fromSecretKey(Buffer.from(process.env.pkey, "hex"), {skipValidation: true});
    // console.log(Buffer.from(keypair.keypair.secretKey).toString('hex'));
    const address = "0x" + keypair.getPublicKey().toSuiAddress();
    console.log(address);
    const signer = new RawSigner(keypair, provider);

    const bytecode_promises = contracts.map((file) => {
        return fs.readFile(`${module_folder}/${file}`, 'base64').then((contents) => {
            return contents.toString();
        });
    })
    const compiledModules = await Promise.all(bytecode_promises);

    const gasBudget = 10000;
    const toPublish = { compiledModules, gasBudget };

    try {
        const info = await signer.publish(toPublish, 'WaitForEffectsCert');
        // console.log(info.parsed_data);
        const created = info.EffectsCert.effects.created.map((item) => item.reference.objectId);
        const createdInfo = await provider.multiGetObjects({ids: created});

        let packageObjectId = false;
        let createdObjects = []

        createdInfo.forEach((item) => {
            if(item.details.data.dataType === "package"){
                packageObjectId = item.details.reference.objectId;
            } else {
                createdObjects.push({ type: item.details.data.type, objectId: item.details.reference.objectId,  owner: item.details.owner.AddressOwner });
            }
        });
        const deployed = await fs.readFile(`./deployed_modules/output.json`).then((rawdata) => JSON.parse(rawdata));
        deployed[module_name] = { packageObjectId, createdObjects};
        fs.writeFile(`./deployed_modules/output.json`, JSON.stringify(deployed,null,'\t'));
    } catch(e) {
        console.log(e);
    }
    
}

const sortElements = (ingredientsArr) => {
    let clean = false;
    let sortedElements = ingredientsArr.slice();
    while(!clean) {
        clean = true;
        let ingredientIndex = 0;
        for (const ingredient of sortedElements) {
            const element1 = sortedElements.findIndex((val) => val.name == ingredient.mix[0]);
            const element2 = sortedElements.findIndex((val) => val.name == ingredient.mix[1]);
            if(element1 > ingredientIndex){
                clean = false;
                var b = sortedElements[element1];
                sortedElements[element1] = sortedElements[ingredientIndex];
                sortedElements[ingredientIndex] = b;
            }
            if(element2 > ingredientIndex) {
                var b = sortedElements[element2];
                sortedElements[element2] = sortedElements[ingredientIndex];
                sortedElements[ingredientIndex] = b;
            }
            ingredientIndex++;
        }
    }
    return sortedElements;
}

const alchemy = async () => {
    const force = args[1];
    const ingredientsArr =  await fs.readFile(elements_file).then((rawdata) => JSON.parse(rawdata));

    const sortedElements = sortElements(ingredientsArr);

    const basics = ["fire", "water", "air", "earth"];
    const module_name = process.env.module_name;
    const module_file = `./build/${module_name}/bytecode_modules/alchemy.mv`;
    const fileData =  await fs.readFile(module_file, 'base64');
    const compiledModule = fileData.toString();
    const gasBudget = 10000;
    const toPublish = { compiledModules: [compiledModule], gasBudget };
    const deployed = await fs.readFile(`./deployed_modules/output.json`).then((rawdata) => JSON.parse(rawdata));

    try {
        let packageObjectId;
        let createdObjects;
        if(!deployed.individual.alchemy_nft || force){
            const info = await signer.publish(toPublish, 'WaitForEffectsCert');
            [packageObjectId, createdObjects] = await processTxResults(info, provider);

            if(!deployed["individual"]){
                deployed["individual"] = {};
            }
            deployed.individual.alchemy_nft = { packageObjectId, createdObjects};
            fs.writeFile(`./deployed_modules/output.json`, JSON.stringify(deployed,null,'\t'));
        } else {
            packageObjectId = deployed.individual.alchemy_nft.packageObjectId;
            createdObjects = deployed.individual.alchemy_nft.createdObjects;
        }
        const carrier = getItemByType(createdObjects, "NFTCarrier");
        const baseData = getItemByType(createdObjects, "BaseData");
        let mintAuthority = getItemByType(createdObjects, "MintCap");

        if(!mintAuthority || force) {
            let createCollection = await signer.executeMoveCall({
                packageObjectId,
                module: "alchemy",
                function: 'create',
                /*
                royalty_receiver: address,
                tags: vector<vector<u8>>,
                royalty_fee_bps: u64,
                json: vector<u8>,
                carrier: NFTCarrier,
                */
                typeArguments: [],
                arguments: [
                    address,
                    ["Game", "Alchemy"],
                    100,
                    "ABC",
                    carrier,
                    baseData,
                ],
                gasBudget,
            }, "WaitForEffectsCert");
            let [, collectionObjects] = await processTxResults(createCollection, provider);
            mintAuthority = getItemByType(collectionObjects, "MintCap");
            deployed.individual.alchemy_nft.createdObjects = deployed.individual.alchemy_nft.createdObjects.concat(collectionObjects);
            fs.writeFile(`./deployed_modules/output.json`, JSON.stringify(deployed,null,'\t'));
        }

        if(force) {
            sortedElements.forEach((e, i) => {
                delete sortedElements[i].address;
            });
            fs.writeFile(elements_file, JSON.stringify(sortedElements, null,'\t'));
        }

        let ingredientIndex = 0;
        for (const ingredient of sortedElements) {
            if(!ingredient.address){
                await mintIngredient(ingredient, ingredientIndex, sortedElements, baseData, packageObjectId, signer, provider, gasBudget);
            }
            ingredientIndex++;
        }

        let basicsIndex = 0;
        for (const ingredients of sortedElements) {
            if(basics.includes(ingredients.name)) {
                const contents = await signer.executeMoveCall({
                    packageObjectId,
                    module: "alchemy",
                    function: 'add_to_basics',
                    /*
                    baseData: &mut BaseData,
                    c: &mut Collectible,
                    */
                    typeArguments: [],
                    arguments: [
                        baseData,
                        ingredients.address,
                    ],
                    gasBudget,
                }, "WaitForEffectsCert");
                // let [,add_to_basics] =  await processTxResults(contents, provider);
                await wait(2000);
            }
            basicsIndex++;
        }
        
    } catch(e) {
        console.log(e);
    }
}

const mintIngredient = async (ingredient, ingredientIndex, sortedElements, baseData, packageObjectId, signer, provider, gasBudget) => {
    await wait(4000);
    const mix = [];
    if(ingredient.mix.length !== 0){
        // check mintResults for NFT that matches names of mix elements
        const element1 = sortedElements.find((val) => val.name == ingredient.mix[0]).address;
        const element2 = sortedElements.find((val) => val.name == ingredient.mix[1]).address;
        mix.push(element1);
        mix.push(element2);
    } 
    const contents = await signer.executeMoveCall({
        packageObjectId,
        module: "alchemy",
        function: 'mint_data',
        /*
        name: vector<u8>,
        description: vector<u8>,
        url: vector<u8>,
        attribute_keys: vector<vector<u8>>,
        attribute_values: vector<vector<u8>>,
        baseData: &mut BaseData,
        */
        typeArguments: [],
        arguments: [
            ingredient.name,
            "",
            `https://alchemy.keepsake.gg/elements/${ingredient.name}.svg`,
            [],
            [],
            baseData,
        ],
        gasBudget,
    }, "WaitForEffectsCert");
    let [, resolvedContents] = await processTxResults(contents, provider);
    if(!resolvedContents){
        console.log(contents.EffectsCert.effects);
    }
    let newElement = getItemByType(resolvedContents, "Archetype<ELEMENTS>");
    sortedElements[ingredientIndex].address = newElement;
    if(mix.length > 1){
        await wait(2000);

        const contents2 = await signer.executeMoveCall({
            packageObjectId,
            module: "alchemy",
            function: 'mint_combination',
            /*
            baseData: &mut BaseData,
            from1: ID,
            from2: ID,
            to: ID,
            ctx: &mut TxContext
            */
            typeArguments: [],
            arguments: [
                baseData,
                mix[0],
                mix[1],
                newElement
            ],
            gasBudget,
        }, "WaitForEffectsCert");
    }

    fs.writeFile(elements_file, JSON.stringify(sortedElements, null,'\t'));
};


if(args[0]){
    eval(args[0] + "()");
}
