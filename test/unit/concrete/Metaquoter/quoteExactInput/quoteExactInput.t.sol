// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {UnitMetaquoterBase} from 'test/unit/concrete/Metaquoter/MetaquoterBase.sol';

import {ICLPoolActions} from 'contracts/core/interfaces/pool/ICLPoolActions.sol';
import {ICLPoolConstants} from 'contracts/core/interfaces/pool/ICLPoolConstants.sol';
import {ICLPoolState} from 'contracts/core/interfaces/pool/ICLPoolState.sol';

import {IPoolFactoryV3} from 'contracts/periphery/interfaces/IPoolFactoryV3.sol';
import {IV2Pool} from 'contracts/periphery/interfaces/IV2Pool.sol';
import {IV3FactoryRegistry} from 'contracts/periphery/interfaces/IV3FactoryRegistry.sol';

contract UnitMetaquoterQuoteExactInput is UnitMetaquoterBase {
  function test_WhenThePathIsEmpty(address _registry, uint256 _amountIn) external {
    _bootstrapRegistry(_registry);

    // it reverts with EP
    vm.expectRevert(bytes('EP'));
    _quoter.quoteExactInput(new address[](0), _tokenLow, _amountIn);
  }

  modifier givenThePathIsNotEmpty() {
    _;
  }

  function test_WhenAPoolFactoryIsNotApproved(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountIn
  ) external givenThePathIsNotEmpty {
    _bootstrap(_registry, _factory, _pool);

    _mockAndExpect(
      _registry, abi.encodeWithSelector(IV3FactoryRegistry.targetToFactory.selector, _pool), abi.encode(_factory)
    );
    _mockAndExpect(
      _registry,
      abi.encodeWithSelector(IV3FactoryRegistry.isTargetFactoryApproved.selector, _factory),
      abi.encode(false)
    );

    // it reverts with AF
    vm.expectRevert(bytes('AF'));
    _quoter.quoteExactInput(_route(_pool), _tokenLow, _amountIn);
  }

  modifier givenThePoolFactoryIsApproved() {
    _;
  }

  function test_WhenThePoolIsNotARegisteredTarget(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountIn
  ) external givenThePathIsNotEmpty givenThePoolFactoryIsApproved {
    _bootstrap(_registry, _factory, _pool);

    _mockAndExpect(
      _registry, abi.encodeWithSelector(IV3FactoryRegistry.targetToFactory.selector, _pool), abi.encode(address(0))
    );

    // it reverts with IP
    vm.expectRevert(bytes('IP'));
    _quoter.quoteExactInput(_route(_pool), _tokenLow, _amountIn);
  }

  modifier givenThePoolIsARegisteredTarget() {
    _;
  }

  function test_WhenTokenInIsNotATokenOfItsHopPool(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountIn
  ) external givenThePathIsNotEmpty givenThePoolFactoryIsApproved givenThePoolIsARegisteredTarget {
    _bootstrap(_registry, _factory, _pool);
    _mockPool(_registry, _factory, _pool, _CL_POOL_TYPE, _tokenLow, _tokenHigh);

    // it reverts with TI
    vm.expectRevert(bytes('TI'));
    _quoter.quoteExactInput(_route(_pool), _tokenMid, _amountIn);
  }

  modifier givenTokenInIsATokenOfItsHopPool() {
    _;
  }

  function test_WhenTheRouteIsASingleCLPool(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountIn
  )
    external
    givenThePathIsNotEmpty
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenTokenInIsATokenOfItsHopPool
  {
    _bootstrap(_registry, _factory, _pool);
    _amountIn = bound(_amountIn, 1, uint256(type(int256).max));

    // pinned so the assertion checks a concrete decoded quote, not a value tied to the mock
    uint256 _expectedAmountOut = 2e18;
    uint160 _expectedSqrtPrice = uint160(3e18);

    _mockPool(_registry, _factory, _pool, _CL_POOL_TYPE, _tokenLow, _tokenHigh);
    vm.mockCallRevert(
      _pool,
      abi.encodeWithSelector(
        ICLPoolActions.swap.selector,
        address(_quoter),
        true,
        int256(_amountIn),
        _MIN_PRICE_LIMIT,
        abi.encode(_pool, true, uint256(0))
      ),
      abi.encode(_expectedAmountOut, _expectedSqrtPrice, int24(0))
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(uint160(0), int24(0), uint16(0), uint16(0), uint16(0), false)
    );
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(int24(1)));
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolState.tickBitmap.selector, int16(0)), abi.encode(uint256(0)));

    (uint256 _amountOut, uint160[] memory _sqrtPriceX96AfterList, uint32[] memory _initializedTicksCrossedList) =
      _quoter.quoteExactInput(_route(_pool), _tokenLow, _amountIn);

    // it returns the CL quote as amountOut
    assertEq(_amountOut, _expectedAmountOut);
    // it populates the lists at the pool index
    assertEq(_sqrtPriceX96AfterList.length, 1);
    assertEq(_initializedTicksCrossedList.length, 1);
    assertEq(uint256(_sqrtPriceX96AfterList[0]), _expectedSqrtPrice);
    assertEq(uint256(_initializedTicksCrossedList[0]), 0);
  }

  function test_WhenTheRouteIsASingleV2Pool(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountIn
  )
    external
    givenThePathIsNotEmpty
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenTokenInIsATokenOfItsHopPool
  {
    _bootstrap(_registry, _factory, _pool);

    // pinned so the assertion checks a concrete quote, not a value tied to the mock
    uint256 _expectedAmountOut = 2e18;

    _mockPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE, _tokenLow, _tokenHigh);
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(IV2Pool.getAmountOutWithTotalFee.selector, _amountIn, _tokenLow),
      abi.encode(_expectedAmountOut)
    );

    (uint256 _amountOut, uint160[] memory _sqrtPriceX96AfterList, uint32[] memory _initializedTicksCrossedList) =
      _quoter.quoteExactInput(_route(_pool), _tokenLow, _amountIn);

    // it returns the getAmountOutWithTotalFee quote as amountOut
    assertEq(_amountOut, _expectedAmountOut);
    // it leaves the lists zeroed
    assertEq(_sqrtPriceX96AfterList.length, 1);
    assertEq(_initializedTicksCrossedList.length, 1);
    assertEq(uint256(_sqrtPriceX96AfterList[0]), 0);
    assertEq(uint256(_initializedTicksCrossedList[0]), 0);
  }

  function test_WhenTheRouteMixesCLAndV2Pools(
    address _registry,
    address _factory,
    address _pool,
    address _pool2,
    uint256 _amountIn
  )
    external
    givenThePathIsNotEmpty
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenTokenInIsATokenOfItsHopPool
  {
    _bootstrap(_registry, _factory, _pool);
    _sanitize(_pool2);
    vm.assume(_pool2 != _registry && _pool2 != _factory && _pool2 != _pool && _pool2 != address(_quoter));
    _amountIn = bound(_amountIn, 1, uint256(type(int256).max));

    // pinned so the chained hop and final quote are concrete: CL out (7e17) must feed the V2 hop's input
    uint256 _hopAmountOut = 7e17;
    uint256 _expectedAmountOut = 3e18;
    uint160 _expectedSqrtPrice = uint160(5e18);

    // CL hop: tokenLow -> tokenMid, then V2 hop: tokenMid -> tokenHigh.
    _mockPool(_registry, _factory, _pool, _CL_POOL_TYPE, _tokenLow, _tokenMid);
    vm.mockCallRevert(
      _pool,
      abi.encodeWithSelector(
        ICLPoolActions.swap.selector,
        address(_quoter),
        true,
        int256(_amountIn),
        _MIN_PRICE_LIMIT,
        abi.encode(_pool, true, uint256(0))
      ),
      abi.encode(_hopAmountOut, _expectedSqrtPrice, int24(0))
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(uint160(0), int24(0), uint16(0), uint16(0), uint16(0), false)
    );
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(int24(1)));
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolState.tickBitmap.selector, int16(0)), abi.encode(uint256(0)));

    _mockPool(_registry, _factory, _pool2, _V2_STABLE_POOL_TYPE, _tokenMid, _tokenHigh);
    // it chains each hop output into the next hop input
    // (the V2 mock only matches the CL hop's output as its input amount)
    _mockAndExpect(
      _pool2,
      abi.encodeWithSelector(IV2Pool.getAmountOutWithTotalFee.selector, _hopAmountOut, _tokenMid),
      abi.encode(_expectedAmountOut)
    );

    address[] memory _pools = new address[](2);
    _pools[0] = _pool;
    _pools[1] = _pool2;
    (uint256 _amountOut, uint160[] memory _sqrtPriceX96AfterList, uint32[] memory _initializedTicksCrossedList) =
      _quoter.quoteExactInput(_pools, _tokenLow, _amountIn);

    // it populates the lists only at CL indexes
    assertEq(uint256(_sqrtPriceX96AfterList[0]), _expectedSqrtPrice);
    assertEq(uint256(_initializedTicksCrossedList[0]), 0);
    assertEq(uint256(_sqrtPriceX96AfterList[1]), 0);
    assertEq(uint256(_initializedTicksCrossedList[1]), 0);
    // it returns the final amountOut
    assertEq(_amountOut, _expectedAmountOut);
  }

  function test_WhenAPoolReportsAnUnknownPoolType(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountIn
  )
    external
    givenThePathIsNotEmpty
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenTokenInIsATokenOfItsHopPool
  {
    _bootstrap(_registry, _factory, _pool);
    // mocked without _mockPool: the type check short-circuits, so the reads it expects never happen
    vm.mockCall(
      _registry, abi.encodeWithSelector(IV3FactoryRegistry.targetToFactory.selector, _pool), abi.encode(_factory)
    );
    vm.mockCall(
      _registry, abi.encodeWithSelector(IV3FactoryRegistry.isTargetFactoryApproved.selector, _factory), abi.encode(true)
    );
    vm.mockCall(_pool, abi.encodeWithSelector(ICLPoolConstants.POOL_TYPE.selector), abi.encode(bytes32('UNKNOWN')));

    // it does not read the factory pause flag
    // an unsupported label must fail on its own type, not on a getter its factory may not implement
    vm.expectCall(_factory, abi.encodeWithSelector(IPoolFactoryV3.isPaused.selector), 0);

    // it does not read the pool tokens
    vm.expectCall(_pool, abi.encodeWithSelector(ICLPoolConstants.token0.selector), 0);

    // it reverts with PT
    vm.expectRevert(bytes('PT'));
    _quoter.quoteExactInput(_route(_pool), _tokenLow, _amountIn);
  }

  function test_WhenAV2HopQuotesZeroOutput(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountIn
  )
    external
    givenThePathIsNotEmpty
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenTokenInIsATokenOfItsHopPool
  {
    _bootstrap(_registry, _factory, _pool);

    // a hop that rounds to zero cannot execute, and it would also starve every hop downstream of it
    _mockPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE, _tokenLow, _tokenHigh);
    _mockAndExpect(
      _pool, abi.encodeWithSelector(IV2Pool.getAmountOutWithTotalFee.selector, _amountIn, _tokenLow), abi.encode(0)
    );

    // it reverts with IO
    vm.expectRevert(bytes('IO'));
    _quoter.quoteExactInput(_route(_pool), _tokenLow, _amountIn);
  }
}
