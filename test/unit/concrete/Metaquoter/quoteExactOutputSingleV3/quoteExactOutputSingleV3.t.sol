// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {UnitMetaquoterBase} from 'test/unit/concrete/Metaquoter/MetaquoterBase.sol';

import {ICLPoolActions} from 'contracts/core/interfaces/pool/ICLPoolActions.sol';
import {ICLPoolConstants} from 'contracts/core/interfaces/pool/ICLPoolConstants.sol';
import {ICLPoolState} from 'contracts/core/interfaces/pool/ICLPoolState.sol';

import {IV3FactoryRegistry} from 'contracts/periphery/interfaces/IV3FactoryRegistry.sol';

contract UnitMetaquoterQuoteExactOutputSingleV3 is UnitMetaquoterBase {
  function test_WhenThePoolFactoryIsNotApproved(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountOut,
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
    _quoter.quoteExactOutputSingleV3(_pool, _tokenLow, _amountOut, _sqrtPriceLimitX96);
  }

  modifier givenThePoolFactoryIsApproved() {
    _;
  }

  function test_WhenThePoolIsNotARegisteredTarget(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountOut,
    uint160 _sqrtPriceLimitX96
  ) external givenThePoolFactoryIsApproved {
    _bootstrap(_registry, _factory, _pool);

    _mockAndExpect(
      _registry, abi.encodeWithSelector(IV3FactoryRegistry.targetToFactory.selector, _pool), abi.encode(address(0))
    );

    // it reverts with IP
    vm.expectRevert(bytes('IP'));
    _quoter.quoteExactOutputSingleV3(_pool, _tokenLow, _amountOut, _sqrtPriceLimitX96);
  }

  modifier givenThePoolIsARegisteredTarget() {
    _;
  }

  function test_WhenThePoolTypeIsNotCL(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountOut,
    uint160 _sqrtPriceLimitX96
  ) external givenThePoolFactoryIsApproved givenThePoolIsARegisteredTarget {
    _bootstrap(_registry, _factory, _pool);
    _mockPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE, _tokenLow, _tokenHigh);

    // it reverts with PT
    vm.expectRevert(bytes('PT'));
    _quoter.quoteExactOutputSingleV3(_pool, _tokenLow, _amountOut, _sqrtPriceLimitX96);
  }

  modifier givenThePoolTypeIsCL() {
    _;
  }

  function test_WhenTokenInIsNotAPoolToken(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountOut,
    uint160 _sqrtPriceLimitX96
  ) external givenThePoolFactoryIsApproved givenThePoolIsARegisteredTarget givenThePoolTypeIsCL {
    _bootstrap(_registry, _factory, _pool);
    _mockPool(_registry, _factory, _pool, _CL_POOL_TYPE, _tokenLow, _tokenHigh);

    // it reverts with TI
    vm.expectRevert(bytes('TI'));
    _quoter.quoteExactOutputSingleV3(_pool, _tokenMid, _amountOut, _sqrtPriceLimitX96);
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
    uint256 _amountOut
  )
    external
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenThePoolTypeIsCL
    givenTokenInIsAPoolToken
    givenNoPriceLimit
  {
    _bootstrapProbe(_registry, _factory);
    _amountOut = bound(_amountOut, 1, uint256(type(int256).max));
    vm.assume(_amountOut != _INPUT_OWED);
    // the probe delivers exactly the requested output (else the unconstrained-output OC check reverts) and charges
    // INPUT_OWED, kept distinct from the requested output so a wrong-branch quote that returns the output would fail
    _probe.configure(_INPUT_OWED, _amountOut, _SQRT_PRICE_AFTER, 0);

    // it simulates the swap zeroForOne with the negated amount, the minimum price limit and reversed callback tokens
    vm.expectCall(
      address(_probe),
      abi.encodeWithSelector(
        ICLPoolActions.swap.selector,
        address(_quoter),
        true,
        -int256(_amountOut),
        _MIN_PRICE_LIMIT,
        abi.encode(address(_probe), false, _amountOut)
      )
    );
    (uint256 _amountIn, uint160 _sqrtPriceX96After, uint32 _initializedTicksCrossed) =
      _quoter.quoteExactOutputSingleV3(address(_probe), _tokenLow, _amountOut, 0);

    // it returns the input amount the pool charged as the decoded quote, with the initialized ticks crossed
    assertEq(_amountIn, _INPUT_OWED);
    assertEq(uint256(_sqrtPriceX96After), _SQRT_PRICE_AFTER);
    assertEq(uint256(_initializedTicksCrossed), 0);
  }

  function test_WhenTokenInIsToken1(
    address _registry,
    address _factory,
    uint256 _amountOut
  )
    external
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenThePoolTypeIsCL
    givenTokenInIsAPoolToken
    givenNoPriceLimit
  {
    _bootstrapProbe(_registry, _factory);
    _amountOut = bound(_amountOut, 1, uint256(type(int256).max));
    vm.assume(_amountOut != _INPUT_OWED);
    _probe.configure(_INPUT_OWED, _amountOut, _SQRT_PRICE_AFTER, 0);

    // it simulates the swap oneForZero with the negated amount, the maximum price limit and reversed callback tokens
    vm.expectCall(
      address(_probe),
      abi.encodeWithSelector(
        ICLPoolActions.swap.selector,
        address(_quoter),
        false,
        -int256(_amountOut),
        _MAX_PRICE_LIMIT,
        abi.encode(address(_probe), false, _amountOut)
      )
    );
    (uint256 _amountIn, uint160 _sqrtPriceX96After, uint32 _initializedTicksCrossed) =
      _quoter.quoteExactOutputSingleV3(address(_probe), _tokenHigh, _amountOut, 0);

    // it returns the input amount the pool charged as the decoded quote, with the initialized ticks crossed
    assertEq(_amountIn, _INPUT_OWED);
    assertEq(uint256(_sqrtPriceX96After), _SQRT_PRICE_AFTER);
    assertEq(uint256(_initializedTicksCrossed), 0);
  }

  modifier givenAPriceLimit() {
    _;
  }

  function test_WhenTheOutputSwapIsSimulated(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountOut,
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
    _amountOut = bound(_amountOut, 1, uint256(type(int256).max));
    _sqrtPriceLimitX96 = uint160(bound(uint256(_sqrtPriceLimitX96), 1, type(uint160).max));

    // pinned so the assertion checks a concrete decoded quote, not a value tied to the mock
    uint256 _expectedAmountIn = 2e18;

    _mockPool(_registry, _factory, _pool, _CL_POOL_TYPE, _tokenLow, _tokenHigh);
    // it forwards the price limit to the pool
    // (the swap mock only matches calldata carrying the provided limit)
    vm.mockCallRevert(
      _pool,
      abi.encodeWithSelector(
        ICLPoolActions.swap.selector,
        address(_quoter),
        true,
        -int256(_amountOut),
        _sqrtPriceLimitX96,
        abi.encode(_pool, false, uint256(0))
      ),
      abi.encode(_expectedAmountIn, uint160(0), int24(0))
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(uint160(0), int24(0), uint16(0), uint16(0), uint16(0), false)
    );
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(int24(1)));
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolState.tickBitmap.selector, int16(0)), abi.encode(uint256(0)));

    (uint256 _amountIn,,) = _quoter.quoteExactOutputSingleV3(_pool, _tokenLow, _amountOut, _sqrtPriceLimitX96);

    assertEq(_amountIn, _expectedAmountIn);
  }

  function test_WhenThePoolSwapDoesNotRevert(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountOut,
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
    _amountOut = bound(_amountOut, 1, uint256(type(int256).max));

    _mockPool(_registry, _factory, _pool, _CL_POOL_TYPE, _tokenLow, _tokenHigh);
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(
        ICLPoolActions.swap.selector,
        address(_quoter),
        true,
        -int256(_amountOut),
        _MIN_PRICE_LIMIT,
        abi.encode(_pool, false, _amountOut)
      ),
      abi.encode(_amount0Delta, _amount1Delta)
    );

    // it reverts with NC
    vm.expectRevert(bytes('NC'));
    _quoter.quoteExactOutputSingleV3(_pool, _tokenLow, _amountOut, 0);
  }

  function test_WhenThePoolRevertsWithAReasonString(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountOut
  )
    external
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenThePoolTypeIsCL
    givenTokenInIsAPoolToken
  {
    _bootstrap(_registry, _factory, _pool);
    _amountOut = bound(_amountOut, 1, uint256(type(int256).max));

    _mockPool(_registry, _factory, _pool, _CL_POOL_TYPE, _tokenLow, _tokenHigh);
    vm.mockCallRevert(
      _pool,
      abi.encodeWithSelector(
        ICLPoolActions.swap.selector,
        address(_quoter),
        true,
        -int256(_amountOut),
        _MIN_PRICE_LIMIT,
        abi.encode(_pool, false, _amountOut)
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
    _quoter.quoteExactOutputSingleV3(_pool, _tokenLow, _amountOut, 0);
  }

  function test_WhenThePoolRevertsWithAPayloadShorterThanAnErrorString(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountOut
  )
    external
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenThePoolTypeIsCL
    givenTokenInIsAPoolToken
  {
    _bootstrap(_registry, _factory, _pool);
    _amountOut = bound(_amountOut, 1, uint256(type(int256).max));

    _mockPool(_registry, _factory, _pool, _CL_POOL_TYPE, _tokenLow, _tokenHigh);
    vm.mockCallRevert(
      _pool,
      abi.encodeWithSelector(
        ICLPoolActions.swap.selector,
        address(_quoter),
        true,
        -int256(_amountOut),
        _MIN_PRICE_LIMIT,
        abi.encode(_pool, false, _amountOut)
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
    _quoter.quoteExactOutputSingleV3(_pool, _tokenLow, _amountOut, 0);
  }
}
