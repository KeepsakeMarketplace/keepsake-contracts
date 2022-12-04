const getObjectsInfo = (provider, objectIds) =>
    provider.getObjectBatch(objectIds).then((info) => {
        return info.map((el) => {
            if(el){
            return {
            owner: el.details.owner.AddressOwner,
            data: el.details.data.fields,
            type: el.details.data.type,
            };
          }
        });
    });

const processTxResults = async (txResults, provider) => {
  if(txResults.EffectsCert.effects.effects.created){
    const created = txResults.EffectsCert.effects.effects.created.map((item) => item.reference.objectId);
    await wait (2000);
    const createdInfo = await provider.getObjectBatch(created);
    let packageObjectId = false;
    let createdObjects = []

    createdInfo.forEach((item) => {
        if(item.details.data?.dataType === "package"){
            packageObjectId = item.details.reference.objectId;
        } else {
            createdObjects.push({ type: item.details.data?.type, objectId: item.details.reference?.objectId,  owner: item.details.owner.AddressOwner || item.details.owner.ObjectOwner });
        }
    });
    return [packageObjectId, createdObjects];
  }
  return [null, null];
}

const getItemByType = (collectionObjects, type) => collectionObjects.find(object =>  object.type.includes(type))?.objectId;


const wait = (timeout) => new Promise((resolve, reject) => {
  setTimeout(() => {
    resolve();
  }, timeout);
});

const getUserCoins = async (provider, objects, price) => {
  const items = [];
  objects.forEach((item) => {
    if (item.type == "0x2::coin::Coin<0x2::sui::SUI>") {
      items.push(item.objectId);
    }
  });
  const suiObjects = await getObjectsInfo(provider, items);
  let diff = Number.MAX_VALUE;
  let bestIndex = 0;
  suiObjects.forEach((suiCoin, index) => {
    const thisDiff = parseInt(suiCoin.data.balance) - price;
    if (thisDiff >= 0 && diff >= 0 && thisDiff < diff) {
      diff = thisDiff;
      bestIndex = index;
    }
  });
  return suiObjects[bestIndex];
};

const getAllCoins = async (provider, objects, price) => {
  const items = [];
  objects.forEach((item) => {
    if (item.type == "0x2::coin::Coin<0x2::sui::SUI>") {
      items.push(item.objectId);
    }
  });
  const suiObjects = await getObjectsInfo(provider, items);
  return suiObjects;
};

module.exports = {getAllCoins, getObjectsInfo, getUserCoins, processTxResults, getItemByType, wait}