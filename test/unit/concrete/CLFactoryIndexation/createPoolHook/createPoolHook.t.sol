pragma solidity ^0.7.6;
pragma abicoder v2;

import {UnitCLFactoryIndexation} from '../CLFactoryIndexation.t.sol';

contract UnitCLFactoryIndexationCreatePoolHook is UnitCLFactoryIndexation {
  function test_WhenTokenAIsPresentInTokenIndexSet(
    address _tokenA,
    address _tokenB,
    address _pool,
    uint48 _timestamp
  ) external {
    vm.assume(_tokenA != _tokenB);

    _tokenIndex_push({_token: _tokenA});
    // `tokenA` is already present
    assertEq(_tokenIndex_get(0), _tokenA);
    assertEq(clFactoryIndexation.tokenIndexLength(), 1);

    vm.warp(_timestamp);
    clFactoryIndexation.createPoolHook(_tokenA, _tokenB, _pool);

    _validatePoolIndexesPush(_tokenA, _tokenB, _pool, _timestamp);

    // it adds tokenB to tokenIndex
    assertEq(_tokenB, _tokenIndex_get(1));
    assertEq(clFactoryIndexation.tokenIndexLength(), 2); // `tokenA` wasn't added the second time.
  }

  function test_WhenTokenBIsPresentInTokenIndexSet(
    address _tokenA,
    address _tokenB,
    address _pool,
    uint48 _timestamp
  ) external {
    vm.assume(_tokenA != _tokenB);

    _tokenIndex_push({_token: _tokenB});
    // `tokenB` is already present
    assertEq(_tokenIndex_get(0), _tokenB);
    assertEq(clFactoryIndexation.tokenIndexLength(), 1);

    vm.warp(_timestamp);
    clFactoryIndexation.createPoolHook(_tokenA, _tokenB, _pool);

    _validatePoolIndexesPush(_tokenA, _tokenB, _pool, _timestamp);

    // it adds tokenA to tokenIndex
    assertEq(_tokenA, _tokenIndex_get(1)); // at index 1.
    assertEq(clFactoryIndexation.tokenIndexLength(), 2); // `tokenB` wasn't added the second time.
  }

  function test_WhenTokenAAndTokenBArePresentInTokenIndexSet(
    address _tokenA,
    address _tokenB,
    address _pool,
    uint48 _timestamp
  ) external {
    vm.assume(_tokenA != _tokenB);

    _tokenIndex_push({_token: _tokenA});
    _tokenIndex_push({_token: _tokenB});

    // `tokenA/B` are already present
    assertEq(_tokenIndex_get(0), _tokenA);
    assertEq(_tokenIndex_get(1), _tokenB);
    assertEq(clFactoryIndexation.tokenIndexLength(), 2);

    vm.warp(_timestamp);
    clFactoryIndexation.createPoolHook(_tokenA, _tokenB, _pool);

    _validatePoolIndexesPush(_tokenA, _tokenB, _pool, _timestamp);

    // tokenIndex length unchanged => A/B tokens weren't pushed
    assertEq(clFactoryIndexation.tokenIndexLength(), 2);
  }

  function test_WhenTokenAAndBArentPresentInTokenIndexSet(
    address _tokenA,
    address _tokenB,
    address _pool,
    uint48 _timestamp
  ) external {
    vm.assume(_tokenA != _tokenB);

    assertEq(clFactoryIndexation.tokenIndexLength(), 0); // no tokens in the set

    vm.warp(_timestamp);
    clFactoryIndexation.createPoolHook(_tokenA, _tokenB, _pool);

    _validatePoolIndexesPush(_tokenA, _tokenB, _pool, _timestamp);

    assertEq(clFactoryIndexation.tokenIndexLength(), 2);

    // it adds tokenA to tokenIndex
    assertEq(_tokenA, _tokenIndex_get(0));

    // it adds tokenB to tokenIndex
    assertEq(_tokenB, _tokenIndex_get(1));
  }

  /*////////////////////////////////////////////////////////////
                             TEST HELPER
  ////////////////////////////////////////////////////////////*/

  /// @notice Validates common paths of presented tests.
  /// @param _timestamp A timestamp to which the current time was set in top-level test functions.
  function _validatePoolIndexesPush(address _tokenA, address _tokenB, address _pool, uint48 _timestamp) internal view {
    uint256 _poolByTokenAIndexLen = clFactoryIndexation.poolByTokenIndexLength(_tokenA);
    uint256 _poolByTokenBIndexLen = clFactoryIndexation.poolByTokenIndexLength(_tokenB);
    uint256 _poolsIndexLen = clFactoryIndexation.poolsIndexLength();

    // it pushes pool keyed by tokenA to poolByTokenIndex
    assertEq(_pool, clFactoryIndexation.poolByTokenIndex(_tokenA, (_poolByTokenAIndexLen - 1)));

    // it pushes pool keyed by tokenB to poolByTokenIndex
    assertEq(_pool, clFactoryIndexation.poolByTokenIndex(_tokenB, (_poolByTokenBIndexLen - 1)));

    // it pushes pool and timestamp to poolsIndex
    (address _poolAt0, uint48 _t) = clFactoryIndexation.poolsIndex(_poolsIndexLen - 1);
    assertEq(_poolAt0, _pool);
    assertEq(uint256(_t), uint256(_timestamp));
  }
}
