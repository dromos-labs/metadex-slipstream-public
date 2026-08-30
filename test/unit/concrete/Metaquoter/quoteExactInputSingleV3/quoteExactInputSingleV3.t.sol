// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {UnitMetaquoterBase} from 'test/unit/concrete/Metaquoter/MetaquoterBase.sol';

import {ICLPoolActions} from 'contracts/core/interfaces/pool/ICLPoolActions.sol';
import {ICLPoolConstants} from 'contracts/core/interfaces/pool/ICLPoolConstants.sol';
import {ICLPoolState} from 'contracts/core/interfaces/pool/ICLPoolState.sol';

import {IV3FactoryRegistry} from 'contracts/periphery/interfaces/IV3FactoryRegistry.sol';

contract UnitMetaquoterQuoteExactInputSingleV3 is UnitMetaquoterBase {
  function test_WhenThePoolFactoryIsNotApproved(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountIn,
    uint160 _sqrtPriceLimitX96
  ) external {
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
    _quoter.quoteExactInputSingleV3(_pool, _tokenLow, _amountIn, _sqrtPriceLimitX96);
  }

  modifier givenThePoolFactoryIsApproved() {
    _;
  }

  function test_WhenThePoolIsNotARegisteredTarget(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountIn,
    uint160 _sqrtPriceLimitX96
  ) external givenThePoolFactoryIsApproved {
    _bootstrap(_registry, _factory, _pool);

    _mockAndExpect(
      _registry, abi.encodeWithSelector(IV3FactoryRegistry.targetToFactory.selector, _pool), abi.encode(address(0))
    );

    // it reverts with IP
    vm.expectRevert(bytes('IP'));
    _quoter.quoteExactInputSingleV3(_pool, _tokenLow, _amountIn, _sqrtPriceLimitX96);
  }

  modifier givenThePoolIsARegisteredTarget() {
    _;
  }

  function test_WhenThePoolTypeIsNotCL(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountIn,
    uint160 _sqrtPriceLimitX96
  ) external givenThePoolFactoryIsApproved givenThePoolIsARegisteredTarget {
    _bootstrap(_registry, _factory, _pool);
    _mockPool(_registry, _factory, _pool, _V2_STABLE_POOL_TYPE, _tokenLow, _tokenHigh);

    // it reverts with PT
    vm.expectRevert(bytes('PT'));
    _quoter.quoteExactInputSingleV3(_pool, _tokenLow, _amountIn, _sqrtPriceLimitX96);
  }

  modifier givenThePoolTypeIsCL() {
    _;
  }

  function test_WhenTokenInIsNotAPoolToken(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountIn,
    uint160 _sqrtPriceLimitX96
  ) external givenThePoolFactoryIsApproved givenThePoolIsARegisteredTarget givenThePoolTypeIsCL {
    _bootstrap(_registry, _factory, _pool);
    _mockPool(_registry, _factory, _pool, _CL_POOL_TYPE, _tokenLow, _tokenHigh);

    // it reverts with TI
    vm.expectRevert(bytes('TI'));
    _quoter.quoteExactInputSingleV3(_pool, _tokenMid, _amountIn, _sqrtPriceLimitX96);
  }

  modifier givenTokenInIsAPoolToken() {
    _;
  }

  modifier givenNoPriceLimit() {
    _;
  }

  function test_WhenTokenInIsToken0(
    address _registry,
    address _factory,
    uint256 _amountIn,
    uint256 _outputSent
  )
    external
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenThePoolTypeIsCL
    givenTokenInIsAPoolToken
    givenNoPriceLimit
  {
    _bootstrapProbe(_registry, _factory);
    _amountIn = bound(_amountIn, 1, uint256(type(int256).max));
    _outputSent = bound(_outputSent, 1, uint256(type(int256).max));
    vm.assume(_outputSent != _INPUT_OWED);
    // the probe delivers _outputSent of the output token and charges INPUT_OWED of the input token
    _probe.configure(_INPUT_OWED, _outputSent, _SQRT_PRICE_AFTER, 0);

    // it simulates the swap zeroForOne with the minimum price limit
    vm.expectCall(
      address(_probe),
      abi.encodeWithSelector(
        ICLPoolActions.swap.selector,
        address(_quoter),
        true,
        int256(_amountIn),
        _MIN_PRICE_LIMIT,
        abi.encode(address(_probe), true, uint256(0))
      )
    );
    (uint256 _amountOut, uint160 _sqrtPriceX96After, uint32 _initializedTicksCrossed) =
      _quoter.quoteExactInputSingleV3(address(_probe), _tokenLow, _amountIn, 0);

    // it returns the output amount the pool sent as the decoded quote, with the initialized ticks crossed
    assertEq(_amountOut, _outputSent);
    assertEq(uint256(_sqrtPriceX96After), _SQRT_PRICE_AFTER);
    assertEq(uint256(_initializedTicksCrossed), 0);
  }

  function test_WhenTokenInIsToken1(
    address _registry,
    address _factory,
    uint256 _amountIn,
    uint256 _outputSent
  )
    external
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenThePoolTypeIsCL
    givenTokenInIsAPoolToken
    givenNoPriceLimit
  {
    _bootstrapProbe(_registry, _factory);
    _amountIn = bound(_amountIn, 1, uint256(type(int256).max));
    _outputSent = bound(_outputSent, 1, uint256(type(int256).max));
    vm.assume(_outputSent != _INPUT_OWED);
    _probe.configure(_INPUT_OWED, _outputSent, _SQRT_PRICE_AFTER, 0);

    // it simulates the swap oneForZero with the maximum price limit
    vm.expectCall(
      address(_probe),
      abi.encodeWithSelector(
        ICLPoolActions.swap.selector,
        address(_quoter),
        false,
        int256(_amountIn),
        _MAX_PRICE_LIMIT,
        abi.encode(address(_probe), true, uint256(0))
      )
    );
    (uint256 _amountOut, uint160 _sqrtPriceX96After, uint32 _initializedTicksCrossed) =
      _quoter.quoteExactInputSingleV3(address(_probe), _tokenHigh, _amountIn, 0);

    // it returns the output amount the pool sent as the decoded quote, with the initialized ticks crossed
    assertEq(_amountOut, _outputSent);
    assertEq(uint256(_sqrtPriceX96After), _SQRT_PRICE_AFTER);
    assertEq(uint256(_initializedTicksCrossed), 0);
  }

  modifier givenAPriceLimit() {
    _;
  }

  function test_WhenTheInputSwapIsSimulated(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountIn,
    uint160 _sqrtPriceLimitX96
  )
    external
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenThePoolTypeIsCL
    givenTokenInIsAPoolToken
    givenAPriceLimit
  {
    _bootstrap(_registry, _factory, _pool);
    _amountIn = bound(_amountIn, 1, uint256(type(int256).max));
    _sqrtPriceLimitX96 = uint160(bound(uint256(_sqrtPriceLimitX96), 1, type(uint160).max));

    // pinned so the assertion checks a concrete decoded quote, not a value tied to the mock
    uint256 _expectedAmountOut = 2e18;

    _mockPool(_registry, _factory, _pool, _CL_POOL_TYPE, _tokenLow, _tokenHigh);
    // it forwards the price limit to the pool
    // (the swap mock only matches calldata carrying the provided limit)
    vm.mockCallRevert(
      _pool,
      abi.encodeWithSelector(
        ICLPoolActions.swap.selector,
        address(_quoter),
        true,
        int256(_amountIn),
        _sqrtPriceLimitX96,
        abi.encode(_pool, true, uint256(0))
      ),
      abi.encode(_expectedAmountOut, uint160(0), int24(0))
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(uint160(0), int24(0), uint16(0), uint16(0), uint16(0), false)
    );
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(int24(1)));
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolState.tickBitmap.selector, int16(0)), abi.encode(uint256(0)));

    (uint256 _amountOut,,) = _quoter.quoteExactInputSingleV3(_pool, _tokenLow, _amountIn, _sqrtPriceLimitX96);

    assertEq(_amountOut, _expectedAmountOut);
  }

  function test_WhenThePoolSwapDoesNotRevert(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountIn,
    int256 _amount0Delta,
    int256 _amount1Delta
  )
    external
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenThePoolTypeIsCL
    givenTokenInIsAPoolToken
  {
    // Unreachable against a genuine CL pool (its callback always reverts), but the branch exists: a swap that
    // returns instead of reverting produced no quote to decode, so the quoter fails loud rather than returning a
    // zeroed quote an integrator could mistake for a real one. The returned deltas are ignored, so they are free to
    // fuzz.
    _bootstrap(_registry, _factory, _pool);
    _amountIn = bound(_amountIn, 1, uint256(type(int256).max));

    _mockPool(_registry, _factory, _pool, _CL_POOL_TYPE, _tokenLow, _tokenHigh);
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(
        ICLPoolActions.swap.selector,
        address(_quoter),
        true,
        int256(_amountIn),
        _MIN_PRICE_LIMIT,
        abi.encode(_pool, true, uint256(0))
      ),
      abi.encode(_amount0Delta, _amount1Delta)
    );

    // it reverts with NC
    vm.expectRevert(bytes('NC'));
    _quoter.quoteExactInputSingleV3(_pool, _tokenLow, _amountIn, 0);
  }

  function test_WhenThePoolRevertsWithAReasonString(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountIn
  )
    external
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenThePoolTypeIsCL
    givenTokenInIsAPoolToken
  {
    _bootstrap(_registry, _factory, _pool);
    _amountIn = bound(_amountIn, 1, uint256(type(int256).max));

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
      abi.encodeWithSignature('Error(string)', 'SPL')
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(uint160(0), int24(0), uint16(0), uint16(0), uint16(0), false)
    );

    // it bubbles the reason string
    vm.expectRevert(bytes('SPL'));
    _quoter.quoteExactInputSingleV3(_pool, _tokenLow, _amountIn, 0);
  }

  function test_WhenThePoolRevertsWithAPayloadShorterThanAnErrorString(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountIn
  )
    external
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenThePoolTypeIsCL
    givenTokenInIsAPoolToken
  {
    _bootstrap(_registry, _factory, _pool);
    _amountIn = bound(_amountIn, 1, uint256(type(int256).max));

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
      abi.encodeWithSelector(bytes4(0xdeadbeef))
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(uint160(0), int24(0), uint16(0), uint16(0), uint16(0), false)
    );

    // it reverts with Unexpected error
    vm.expectRevert(bytes('Unexpected error'));
    _quoter.quoteExactInputSingleV3(_pool, _tokenLow, _amountIn, 0);
  }

  function test_WhenTheSwapCrossesInitializedTicks(
    address _registry,
    address _factory,
    uint256 _amountIn
  )
    external
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenThePoolTypeIsCL
    givenTokenInIsAPoolToken
  {
    _bootstrapProbe(_registry, _factory);
    _amountIn = bound(_amountIn, 1, uint256(type(int256).max));
    _probe.configure(_INPUT_OWED, _OUTPUT_SENT, _SQRT_PRICE_AFTER, 0);
    // selling token1 walks the tick up from 0 to 5, crossing the three initialized ticks in between
    _probe.configureCrossing(5, 0, (1 << 1) | (1 << 2) | (1 << 3));

    (,, uint32 _initializedTicksCrossed) = _quoter.quoteExactInputSingleV3(address(_probe), _tokenHigh, _amountIn, 0);

    // it returns the number of initialized ticks crossed
    assertEq(uint256(_initializedTicksCrossed), 3);
  }

  function test_WhenTheSwapStartsOnAnInitializedTick(
    address _registry,
    address _factory,
    uint256 _amountIn
  )
    external
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenThePoolTypeIsCL
    givenTokenInIsAPoolToken
  {
    _bootstrapProbe(_registry, _factory);
    _amountIn = bound(_amountIn, 1, uint256(type(int256).max));
    _probe.configure(_INPUT_OWED, _OUTPUT_SENT, _SQRT_PRICE_AFTER, 0);
    // same upward walk, but ticks 0 and 5 are initialized too: the tick the swap starts on is not crossed, so of the
    // five initialized ticks in range only four are counted
    _probe.configureCrossing(5, 0, (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 5));

    (,, uint32 _initializedTicksCrossed) = _quoter.quoteExactInputSingleV3(address(_probe), _tokenHigh, _amountIn, 0);

    // it excludes the starting tick from the count
    assertEq(uint256(_initializedTicksCrossed), 4);
  }

  function test_WhenADownwardSwapEndsOnAnInitializedTick(
    address _registry,
    address _factory,
    uint256 _amountIn
  )
    external
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenThePoolTypeIsCL
    givenTokenInIsAPoolToken
  {
    _bootstrapProbe(_registry, _factory);
    _amountIn = bound(_amountIn, 1, uint256(type(int256).max));
    _probe.configure(_INPUT_OWED, _OUTPUT_SENT, _SQRT_PRICE_AFTER, 5);
    // selling token0 walks the tick down from 5 to 0; the tick it lands on is not crossed, so of the four initialized
    // ticks in range only three are counted
    _probe.configureCrossing(0, 0, (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3));

    (,, uint32 _initializedTicksCrossed) = _quoter.quoteExactInputSingleV3(address(_probe), _tokenLow, _amountIn, 0);

    // it excludes the ending tick from the count
    assertEq(uint256(_initializedTicksCrossed), 3);
  }
}
