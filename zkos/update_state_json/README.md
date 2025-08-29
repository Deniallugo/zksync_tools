# update state.json

Updates state.json file in zksync-os-server based off the given era-contracts.
 

Example use case:

To generate state & genesis locally:

```
ZKSYNC_OS_SERVER_TAG=v0.1.2 ERA_CONTRACTS_TAG=zkos-v0.29.2 ZKSYNC_ERA_STACK_CLI_TAG=0267d99b366c97b7f70122673113dc30b6d742d3  ./update.sh
```

then (assuming that genesis didn't change), you can test if by running

```shell
anvil --load-state zkos-l1-state.json
```

And on separate screen:

```shell
rm -rf repos/zksync-os-server/db
rm -rf ecosystem/local_v1/chains/era1/db

cd repos/zksync-os-server
general_zkstack_cli_config_dir=../../ecosystem/local_v1/chains/era1 cargo run
```

You can also ask the tool to prepare the zksync-os-server PR for you:

```
COMMIT_CHANGES=true ZKSYNC_OS_SERVER_TAG=be23bef943d4ff44c6af79020d0b3ac15430958c ERA_CONTRACTS_TAG=zkos-v0.29.2 ZKSYNC_ERA_STACK_CLI_TAG=0267d99b366c97b7f70122673113dc30b6d742d3  ./update.sh
```