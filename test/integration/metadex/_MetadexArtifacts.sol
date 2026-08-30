// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.30;

// Force the public MetaDEX contracts that Slipstream wires to into the Foundry build.
// Integration tests can deploy them by artifact name via deployCode.
import {FactoryRegistry} from 'metadex/factories/FactoryRegistry.sol';
import {DiscountRegistry} from 'metadex/fees/DiscountRegistry.sol';
