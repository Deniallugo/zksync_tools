# Blockchain operator

A simple python based flask dashboard that gives you the basic info about the blockchain that you're running.

Currently supported features:

* batch page - showing information about batches that were committed, including their pubdata.

## Current status
Adding support for shared bridges.

Support for blobs is not there yet.

You can build a docker image via:

```shell
docker build -t hyperexplorer .
```