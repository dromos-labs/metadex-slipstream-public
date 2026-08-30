# Metadex Slipstream

Smart contracts for [Metadex](https://aero.xyz) concentrated liquidity: pools, gauges, position management, routing, quoting, and configurable swap and fee hooks.

Protocol contracts use Solidity `0.7.6`. Source is under `contracts`.

## Setup

1. Install [Foundry](https://book.getfoundry.sh/getting-started/installation).
2. Install Node.js `22.10.0` or later and Yarn.
3. Copy `.env.example` to `.env` and set the RPC, explorer, and deployment variables you need.
4. Run `yarn install`.

For NatSpec linting, also install `lintspec`:

```bash
cargo install lintspec
```

## Build

```bash
yarn build
```

Hardhat compilation is also available:

```bash
yarn compile
```

## Tests

```bash
yarn test          # Hardhat and Foundry tests
yarn test:hardhat  # Hardhat tests
yarn test:forge    # Foundry tests
```

Foundry uses 256 fuzz runs by default. Use `FOUNDRY_PROFILE=dev` for 64-run local loops; confirm changes with the default profile before merging.

Some fork and deployment-verification tests require the RPC variables documented in `.env.example`.

## Lint and formatting

```bash
yarn fmt:check
yarn format:check
yarn lint:sol
yarn lint:natspec
yarn lint:slither
```

## Deploy

Foundry deployment instructions and chain configuration are documented in [`script/README.md`](script/README.md).

## Audits

Prior audit reports are under [`audits`](audits).

## Licensing

See `LICENSE`, `NOTICE`, and `VERSIONS`. Each source file declares its governing license in an `SPDX-License-Identifier` header; that header controls for the file.

New protocol files use the Dromos Restricted Use License 1.0 (`LicenseRef-Dromos-Restricted-Use-1.0`). This license does not permit production use. Each version converts to GPL-2.0-or-later five years after its first public distribution. Interfaces and inherited files retain the licenses identified in their headers.
