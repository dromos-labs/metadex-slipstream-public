// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity =0.7.6;
pragma abicoder v2;

import {TestERC20} from 'contracts/periphery/test/TestERC20.sol';

contract MockLeafVoter {
  TestERC20 public immutable receiptToken;

  constructor(TestERC20 _receiptToken) {
    receiptToken = _receiptToken;
  }

  function mintEmissions(address[] calldata _recipients, uint128[] calldata _amounts) external {
    for (uint256 i = 0; i < _recipients.length; i++) {
      receiptToken.mint(_recipients[i], _amounts[i]);
    }
  }
}
