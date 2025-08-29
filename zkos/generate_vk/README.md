# Generate VK

Tool to generate verification keys (and solidity files) for zksync os.

## Usage

By default - it will load the settings.env from the given version directory, create VK + solidity file and put it there.

```shell
./generate.sh versions/2025-08-29
```

If you want to have a new set of versions, please create a new dir and put the proper settings inside.