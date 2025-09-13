# Testnet CTM calldata generator

```shell
DEPLOYER_PRIVATE_KEY=xxx GOVERNANCE_PRIVATE_KEY=yyy ./generator.sh
```

This will create a wallets.yaml file with your private keys (WARNING - be very careful here), and run the tool.

zkstack tool will be by default taken from `origin/main`, and contracts will be taken from `origin/zksync-os-integration` branch.

It will first try to deploy a CTM, and then will generate calldata to add this CTM to Bridgehub.
