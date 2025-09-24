# Deploying new verifier with VK to stage, testnet or localnet

The code will build the verifiers from a given tag, deploy them and then prepare the calldata for registering them.

Main variables:

* verifier_id -- this is the identifier (uint32) for the new verifiers (can be whatever, but by convention we use execution version).
* bridgehub address, chain id -- L2 chain (and its bridgehub) where we want to add verifier
* deployer key - key used to deploy the contracts (doesn't need any permissions, just gas)
* era_contracts_tag - tag from era-contract that will be used for contracts (must be a tag, not a commit).

At the end, the script will print command (or calldata), that has to be run by the CTM owner.


Example steps for testnet:


* start anvil with cloned testnet:

```shell
 anvil --fork-url https://eth-sepolia.g.alchemy.com/v2/XXX
```

Then run with these arguments (deployer is example anvil rich account)

```shell
 VERIFIER_ID=1 CHAIN_ID=8022833 BRIDGEHUB_ADDRESS=0xc4fd2580c3487bba18d63f50301020132342fdbd
 RPC_URL=http://localhost:8545 DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 ERA_CONTRACTS_TAG=zkos-v0.29.6 ./update.sh
```

The resulting calldata (or cast command) can be tested by impersonating owner account:

```shell
cast rpc anvil_impersonateAccount XXX

cast send ... --unlocked
```

where XXX is the CTM owner that script prints.