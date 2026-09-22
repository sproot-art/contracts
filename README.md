# sproot.art contracts

Public mirror of the Solidity source for sproot.art's smart contracts, kept
for auditors and anyone verifying deployed bytecode. This repo does not
include tests, deployment scripts, or history from the private development
repo — it's a build-ready source snapshot.

## Build

```sh
git submodule update --init --recursive
forge build
```

## Audit reports

See [`reports/`](./reports) for published audit reports.
