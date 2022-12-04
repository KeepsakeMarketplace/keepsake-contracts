The marketplace contract powering keepsake.

You can deploy it using javascript, be sure to send some sui to the account you use.

To test it:
1) `npm run deploy` (to get a private key you can save in your env file);
2) save the private key, and send some sui to the account address for it.
3) `npm run deploy` (to launch the contract)
4) `npm run call create` (to create a shared marketplace object)
To make a listing and then buy it:
5) `npm run call list` (to mint and list an NFT. Take note of the Listing ID it'll show in the console)
6) `npm run call buy` {listing_object_id}
To run an auction:
7) `npm run call auction` (Currently there's no epochs on devnet, so there are no time limits for an auction.)