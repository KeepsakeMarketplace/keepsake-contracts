const { Ed25519Keypair, JsonRpcProvider, RawSigner } = require('@mysten/sui.js');
const fs = require('fs/promises');
const utils  = require("./utils");
  
const args = process.argv.slice(2);
let provider = new JsonRpcProvider('https://fullnode.devnet.sui.io:443');

if(!process.env.pkey){
    console.log("No key detected.,Generating a new one. Please put it in your .env file")
    let keypair = new Ed25519Keypair();
    console.log("New key: " + Buffer.from(keypair.keypair.secretKey).toString('hex'));
    const address = "0x" + keypair.getPublicKey().toSuiAddress();
    console.log("using address: " + address);
    return;
}

let keypair = Ed25519Keypair.fromSecretKey(Buffer.from(process.env.pkey, "hex"), {skipValidation: true});
const address = "0x" + keypair.getPublicKey().toSuiAddress();
console.log("using address: " + address);
const signer = new RawSigner(keypair, provider);
const gasBudget = 10000;


const deploy = async() => {
    const module_name = process.env.module_name;
    const module_folder = `./build/${module_name}/bytecode_modules`;
    const contracts = (await fs.readdir(module_folder)).filter((contract) => {
        return(contract.split('.').pop() == "mv") ;
    });

    const bytecode_promises = contracts.map((file) => {
        return fs.readFile(`${module_folder}/${file}`, 'base64').then((contents) => {
            return contents.toString();
        });
    })
    const compiledModules = await Promise.all(bytecode_promises);

    const toPublish = { compiledModules, gasBudget };

    try {
        const info = await signer.publish(toPublish, 'WaitForEffectsCert');
        const created = info.EffectsCert.effects.effects.created.map((item) => item.reference.objectId);
        await utils.wait(5000);
        const createdInfo = await provider.getObjectBatch(created);

        let packageObjectId = false;
        let createdObjects = []

        createdInfo.forEach((item) => {
            if(item.details.data?.dataType === "package"){
                packageObjectId = item.details.reference.objectId;
            } else {
                createdObjects.push({ type: item.details.data?.type, objectId: item.details.reference.objectId,  owner: item.details.owner.AddressOwner });
            }
        });
        const deployed = await fs.readFile(`./deployed_modules/output.json`).then((rawdata) => JSON.parse(rawdata));
        deployed[module_name] = { packageObjectId, createdObjects};
        fs.writeFile(`./deployed_modules/output.json`, JSON.stringify(deployed,null,'\t'));
        console.log("Successfully deployed at: " + packageObjectId);
    } catch(e) {
        console.log(e);
    }
};

const contract = async() => {
    const module_name = process.env.module_name;
    const module_file = `./build/${module_name}/bytecode_modules/${args[1]}.mv`;
    const fileData =  await fs.readFile(module_file, 'base64');
    const compiledModule = fileData.toString();

    const toPublish = { compiledModules: [compiledModule], gasBudget };

    try {
        const info = await signer.publish(toPublish, 'WaitForEffectsCert');

        const created = info.EffectsCert.effects.effects.created.map((item) => item.reference.objectId);
        await utils.wait(5000);
        const createdInfo = await provider.getObjectBatch(created);

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
        console.log("Successfully deployed at: " + packageObjectId);
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
    .then((thisTx) => thisTx.EffectsCert.effects.effects);
}

eval((args[0] || "deploy") + "()");
