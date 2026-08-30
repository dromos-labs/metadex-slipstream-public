// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {UnitMetaquoterLiquidityBase} from 'test/unit/concrete/Metaquoter/MetaquoterLiquidityBase.sol';

import {ICLPoolConstants} from 'contracts/core/interfaces/pool/ICLPoolConstants.sol';
import {ICLPoolState} from 'contracts/core/interfaces/pool/ICLPoolState.sol';
import {SqrtPriceMath} from 'contracts/core/libraries/SqrtPriceMath.sol';
import {TickMath} from 'contracts/core/libraries/TickMath.sol';

import {IV3FactoryRegistry} from 'contracts/periphery/interfaces/IV3FactoryRegistry.sol';
import {LiquidityAmounts} from 'contracts/periphery/libraries/LiquidityAmounts.sol';

contract UnitMetaquoterQuoteAddClLiquidityV3 is UnitMetaquoterLiquidityBase {
  /// @dev The spacing every range in this suite is aligned to.
  int24 internal constant _TICK_SPACING = 60;

  /// @dev A range straddling tick 0.
  int24 internal constant _TICK_LOWER = -600;
  int24 internal constant _TICK_UPPER = 600;

  /// @dev A range sitting entirely above tick 0, i.e. a price below it.
  int24 internal constant _RANGE_ABOVE_LOWER = 600;
  int24 internal constant _RANGE_ABOVE_UPPER = 1200;

  /// @dev A range sitting entirely below tick 0, i.e. a price above it.
  int24 internal constant _RANGE_BELOW_LOWER = -1200;
  int24 internal constant _RANGE_BELOW_UPPER = -600;

  /// @dev Deposit band the fuzzed quotes stay in: large enough that neither side rounds to zero liquidity, small
  ///      enough that the liquidity these ranges imply stays well inside uint128.
  uint256 internal constant _MIN_DEPOSIT = 1e6;
  uint256 internal constant _MAX_DEPOSIT = 1e27;

  /// @dev The largest liquidity a single mint can pass through the pool's `int128` cast.
  uint128 internal constant _MAX_LIQUIDITY = uint128(type(int128).max);

  /// @dev Margin kept away from both ends of the over-the-maximum liquidity band. Deriving a token0 budget from a
  ///      target liquidity and sizing it back rounds each step, so the recomputed liquidity lands within a few
  ///      billion of the target; this keeps it above `_MAX_LIQUIDITY` and inside `uint128` regardless.
  uint256 internal constant _LIQUIDITY_SLACK = 1e18;

  /// @dev The quote one token of each side buys over the (-600, 1200) range at tick 0.
  uint256 internal constant _PINNED_LIQUIDITY = 17_172_499_436_199_171_223;
  uint256 internal constant _PINNED_ADD_AMOUNT0 = 1e18;
  uint256 internal constant _PINNED_ADD_AMOUNT1 = 507_499_062_659_971_020;

  function test_WhenThePoolIsNotARegisteredTarget(
    address _registry,
    address _factory,
    address _pool,
    int24 _tickLower,
    int24 _tickUpper,
    uint256 _amount0Desired,
    uint256 _amount1Desired
  ) external {
    // The registry resolves the pool to the zero factory, i.e. it is not a registered target, so `validateClPool`
    // reverts before the range or the live price is read.
    _bootstrap(_registry, _factory, _pool);

    _mockAndExpect(
      _registry, abi.encodeWithSelector(IV3FactoryRegistry.targetToFactory.selector, _pool), abi.encode(address(0))
    );

    // it reverts with IP
    vm.expectRevert(bytes('IP'));
    _quoter.quoteAddClLiquidityV3(_pool, _tickLower, _tickUpper, _amount0Desired, _amount1Desired);
  }

  modifier givenThePoolIsARegisteredTarget() {
    _;
  }

  function test_WhenTheTargetFactoryIsNotApproved(
    address _registry,
    address _factory,
    address _pool,
    int24 _tickLower,
    int24 _tickUpper,
    uint256 _amount0Desired,
    uint256 _amount1Desired
  ) external givenThePoolIsARegisteredTarget {
    // The pool resolves to a factory, but the registry has not approved it, so `validateClPool` reverts before the
    // range or the live price is read.
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
    _quoter.quoteAddClLiquidityV3(_pool, _tickLower, _tickUpper, _amount0Desired, _amount1Desired);
  }

  modifier givenTheTargetFactoryIsApproved() {
    _;
  }

  function test_WhenThePoolTypeIsNotCL(
    address _registry,
    address _factory,
    address _pool,
    int24 _tickLower,
    int24 _tickUpper,
    uint256 _amount0Desired,
    uint256 _amount1Desired
  ) external givenThePoolIsARegisteredTarget givenTheTargetFactoryIsApproved {
    // A V2 pool of an approved factory: the type gate rejects it before any CL getter it does not implement is
    // reached, so `tickSpacing` and `slot0` are left unmocked deliberately.
    _bootstrap(_registry, _factory, _pool);
    _mockValidPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE);

    // it reverts with PT
    vm.expectRevert(bytes('PT'));
    _quoter.quoteAddClLiquidityV3(_pool, _tickLower, _tickUpper, _amount0Desired, _amount1Desired);
  }

  modifier givenThePoolTypeIsCL() {
    _;
  }

  function test_WhenTheLowerTickIsNotBelowTheUpperTick(
    address _registry,
    address _factory,
    address _pool,
    int24 _tickLower,
    int24 _tickUpper,
    uint256 _amount0Desired,
    uint256 _amount1Desired
  ) external givenThePoolIsARegisteredTarget givenTheTargetFactoryIsApproved givenThePoolTypeIsCL {
    // An inverted or degenerate range fails first, so the spacing is never read: equality is rejected alongside
    // inversion, exactly as the pool's `checkTicks` does.
    _bootstrap(_registry, _factory, _pool);
    _tickLower = int24(bound(int256(_tickLower), int256(_tickUpper), int256(type(int24).max)));

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);

    // it reverts with TLU
    vm.expectRevert(bytes('TLU'));
    _quoter.quoteAddClLiquidityV3(_pool, _tickLower, _tickUpper, _amount0Desired, _amount1Desired);
  }

  function test_WhenTheLowerTickIsBelowTheMinimumTick(
    address _registry,
    address _factory,
    address _pool,
    int24 _tickLower,
    int24 _tickUpper,
    uint256 _amount0Desired,
    uint256 _amount1Desired
  ) external givenThePoolIsARegisteredTarget givenTheTargetFactoryIsApproved givenThePoolTypeIsCL {
    // Below MIN_TICK the square-root price the range implies does not exist, so the bound is checked before anything
    // is derived from it. The upper tick only has to clear the lower one for the lower bound to be the failing check.
    _bootstrap(_registry, _factory, _pool);
    _tickLower = int24(bound(int256(_tickLower), int256(type(int24).min), int256(TickMath.MIN_TICK) - 1));
    _tickUpper = int24(bound(int256(_tickUpper), int256(_tickLower) + 1, int256(type(int24).max)));

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);

    // it reverts with TLM
    vm.expectRevert(bytes('TLM'));
    _quoter.quoteAddClLiquidityV3(_pool, _tickLower, _tickUpper, _amount0Desired, _amount1Desired);
  }

  function test_WhenTheUpperTickIsAboveTheMaximumTick(
    address _registry,
    address _factory,
    address _pool,
    int24 _tickLower,
    int24 _tickUpper,
    uint256 _amount0Desired,
    uint256 _amount1Desired
  ) external givenThePoolIsARegisteredTarget givenTheTargetFactoryIsApproved givenThePoolTypeIsCL {
    // The lower tick is held inside the valid band so only the upper bound can fail.
    _bootstrap(_registry, _factory, _pool);
    _tickUpper = int24(bound(int256(_tickUpper), int256(TickMath.MAX_TICK) + 1, int256(type(int24).max)));
    _tickLower = int24(bound(int256(_tickLower), int256(TickMath.MIN_TICK), int256(TickMath.MAX_TICK)));

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);

    // it reverts with TUM
    vm.expectRevert(bytes('TUM'));
    _quoter.quoteAddClLiquidityV3(_pool, _tickLower, _tickUpper, _amount0Desired, _amount1Desired);
  }

  function test_WhenTheLowerTickIsNotAlignedToTheTickSpacing(
    address _registry,
    address _factory,
    address _pool,
    int24 _tickLower,
    uint256 _amount0Desired,
    uint256 _amount1Desired
  ) external givenThePoolIsARegisteredTarget givenTheTargetFactoryIsApproved givenThePoolTypeIsCL {
    // The fuzzed lower tick is pulled back to a spacing boundary and stepped one tick off it, so the range clears
    // every bound and only the alignment fails. No position the pool holds can sit on such a tick.
    _bootstrap(_registry, _factory, _pool);
    _tickLower =
      int24(bound(int256(_tickLower), int256(TickMath.MIN_TICK) + int256(_TICK_SPACING), -int256(_TICK_SPACING)));
    _tickLower = (_tickLower / _TICK_SPACING) * _TICK_SPACING - 1;

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(_TICK_SPACING));

    // it reverts with TS
    vm.expectRevert(bytes('TS'));
    _quoter.quoteAddClLiquidityV3(_pool, _tickLower, _TICK_UPPER, _amount0Desired, _amount1Desired);
  }

  function test_WhenTheUpperTickIsNotAlignedToTheTickSpacing(
    address _registry,
    address _factory,
    address _pool,
    int24 _tickUpper,
    uint256 _amount0Desired,
    uint256 _amount1Desired
  ) external givenThePoolIsARegisteredTarget givenTheTargetFactoryIsApproved givenThePoolTypeIsCL {
    // Same construction on the other side of the range: the lower tick is aligned, so the conjunction can only fail
    // on the upper one.
    _bootstrap(_registry, _factory, _pool);
    _tickUpper =
      int24(bound(int256(_tickUpper), int256(_TICK_SPACING), int256(TickMath.MAX_TICK) - int256(_TICK_SPACING)));
    _tickUpper = (_tickUpper / _TICK_SPACING) * _TICK_SPACING + 1;

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(_TICK_SPACING));

    // it reverts with TS
    vm.expectRevert(bytes('TS'));
    _quoter.quoteAddClLiquidityV3(_pool, _TICK_LOWER, _tickUpper, _amount0Desired, _amount1Desired);
  }

  modifier givenTheTickRangeIsValid() {
    _;
  }

  function test_WhenOneDesiredSideIsZeroInsideTheRange(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amount0Desired
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenThePoolTypeIsCL
    givenTheTickRangeIsValid
  {
    // An in-range position needs both tokens, so the sizing takes the smaller of the two sides: a zero token1 side
    // pins the liquidity at zero however much token0 is offered, and the quote refuses to describe an empty mint.
    _bootstrap(_registry, _factory, _pool);
    _amount0Desired = bound(_amount0Desired, 1, _MAX_DEPOSIT);

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(_TICK_SPACING));
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(TickMath.getSqrtRatioAtTick(int24(0)), int24(0), uint16(0), uint16(0), uint16(0), true)
    );

    // it reverts with ILM
    vm.expectRevert(bytes('ILM'));
    _quoter.quoteAddClLiquidityV3(_pool, _TICK_LOWER, _TICK_UPPER, _amount0Desired, 0);
  }

  function test_WhenTheDesiredAmountsSizeLiquidityAboveTheInt128Maximum(
    address _registry,
    address _factory,
    address _pool,
    uint128 _targetLiquidity,
    uint256 _amount1Desired
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenThePoolTypeIsCL
    givenTheTickRangeIsValid
  {
    // `mint` casts the liquidity to `int128` before applying it, so a position sized above that maximum reverts at
    // execution without a reason string. The whole range sits above the price, so a single-sided token0 budget sizes
    // it alone: the budget is what the range costs at a target liquidity fuzzed above the maximum, and the token1
    // side is ignored so it is fuzzed unbounded.
    _bootstrap(_registry, _factory, _pool);
    _targetLiquidity = uint128(
      bound(
        uint256(_targetLiquidity),
        uint256(_MAX_LIQUIDITY) + _LIQUIDITY_SLACK,
        uint256(type(uint128).max) - _LIQUIDITY_SLACK
      )
    );
    uint256 _amount0Desired = SqrtPriceMath.getAmount0Delta(
      TickMath.getSqrtRatioAtTick(_RANGE_ABOVE_LOWER),
      TickMath.getSqrtRatioAtTick(_RANGE_ABOVE_UPPER),
      _targetLiquidity,
      true
    );
    // The sizing the quote runs is recomputed here: it returns, so the budget does not overflow the `uint128`
    // downcast inside `LiquidityAmounts`, and it clears the maximum, so the quote's own guard is what rejects it.
    assertGt(
      uint256(
        LiquidityAmounts.getLiquidityForAmount0(
          TickMath.getSqrtRatioAtTick(_RANGE_ABOVE_LOWER),
          TickMath.getSqrtRatioAtTick(_RANGE_ABOVE_UPPER),
          _amount0Desired
        )
      ),
      uint256(_MAX_LIQUIDITY)
    );

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(_TICK_SPACING));
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(TickMath.getSqrtRatioAtTick(int24(0)), int24(0), uint16(0), uint16(0), uint16(0), true)
    );

    // it reverts with LTM
    vm.expectRevert(bytes('LTM'));
    _quoter.quoteAddClLiquidityV3(_pool, _RANGE_ABOVE_LOWER, _RANGE_ABOVE_UPPER, _amount0Desired, _amount1Desired);
  }

  function test_WhenThePriceIsInsideTheRange(
    address _registry,
    address _factory,
    address _pool,
    int24 _tick,
    uint256 _amount0Desired,
    uint256 _amount1Desired
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenThePoolTypeIsCL
    givenTheTickRangeIsValid
  {
    // The price is held strictly inside the range so neither half of the split degenerates, and the tick is fuzzed
    // across it so the assertions follow the split rather than one pinned point on it.
    _bootstrap(_registry, _factory, _pool);
    _tick = int24(bound(int256(_tick), int256(_TICK_LOWER) + 1, int256(_TICK_UPPER) - 1));
    _amount0Desired = bound(_amount0Desired, _MIN_DEPOSIT, _MAX_DEPOSIT);
    _amount1Desired = bound(_amount1Desired, _MIN_DEPOSIT, _MAX_DEPOSIT);
    uint160 _sqrtPriceX96 = TickMath.getSqrtRatioAtTick(_tick);

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(_TICK_SPACING));
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(_sqrtPriceX96, _tick, uint16(0), uint16(0), uint16(0), true)
    );

    (uint256 _amount0, uint256 _amount1, uint128 _liquidity) =
      _quoter.quoteAddClLiquidityV3(_pool, _TICK_LOWER, _TICK_UPPER, _amount0Desired, _amount1Desired);

    // it returns the liquidity the position manager would mint
    assertEq(
      uint256(_liquidity),
      uint256(
        LiquidityAmounts.getLiquidityForAmounts(
          _sqrtPriceX96,
          TickMath.getSqrtRatioAtTick(_TICK_LOWER),
          TickMath.getSqrtRatioAtTick(_TICK_UPPER),
          _amount0Desired,
          _amount1Desired
        )
      )
    );
    // it returns both amounts rounded up at the live price
    assertEq(
      _amount0, SqrtPriceMath.getAmount0Delta(_sqrtPriceX96, TickMath.getSqrtRatioAtTick(_TICK_UPPER), _liquidity, true)
    );
    assertEq(
      _amount1, SqrtPriceMath.getAmount1Delta(TickMath.getSqrtRatioAtTick(_TICK_LOWER), _sqrtPriceX96, _liquidity, true)
    );
    assertGt(_amount0, 0);
    assertGt(_amount1, 0);
    // The sizing floors the liquidity, so neither leg can be valued above what was offered by more than its rounding
    // adds back: the token1 leg rounds up once and therefore never exceeds its side, while the token0 leg rounds up
    // twice and could in principle land a single wei above it.
    assertLe(_amount1, _amount1Desired);
    assertLe(_amount0, _amount0Desired + 1);
  }

  function test_WhenTheAmountsAreComparedToTheBurnValuation(
    address _registry,
    address _factory,
    address _pool,
    int24 _tick,
    uint256 _amount0Desired,
    uint256 _amount1Desired
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenThePoolTypeIsCL
    givenTheTickRangeIsValid
  {
    // The mint callback pulls the rounded-up amounts, so a quote sized off `LiquidityAmounts`' rounded-down valuation
    // would under-report by up to a wei a side and revert the mint it was used to approve. The quote must sit at or
    // above that valuation, and never more than the single wei each rounding step can add.
    _bootstrap(_registry, _factory, _pool);
    _tick = int24(bound(int256(_tick), int256(_TICK_LOWER) + 1, int256(_TICK_UPPER) - 1));
    _amount0Desired = bound(_amount0Desired, _MIN_DEPOSIT, _MAX_DEPOSIT);
    _amount1Desired = bound(_amount1Desired, _MIN_DEPOSIT, _MAX_DEPOSIT);

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(_TICK_SPACING));
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(TickMath.getSqrtRatioAtTick(_tick), _tick, uint16(0), uint16(0), uint16(0), true)
    );

    (uint256 _amount0, uint256 _amount1, uint128 _liquidity) =
      _quoter.quoteAddClLiquidityV3(_pool, _TICK_LOWER, _TICK_UPPER, _amount0Desired, _amount1Desired);

    (uint256 _roundedDown0, uint256 _roundedDown1) = LiquidityAmounts.getAmountsForLiquidity(
      TickMath.getSqrtRatioAtTick(_tick),
      TickMath.getSqrtRatioAtTick(_TICK_LOWER),
      TickMath.getSqrtRatioAtTick(_TICK_UPPER),
      _liquidity
    );

    // it returns amounts at most one wei above the rounded down ones
    assertGe(_amount0, _roundedDown0);
    assertGe(_amount1, _roundedDown1);
    assertLe(_amount0 - _roundedDown0, 1);
    assertLe(_amount1 - _roundedDown1, 1);
  }

  function test_WhenThePriceIsBelowTheRange(
    address _registry,
    address _factory,
    address _pool,
    int24 _tick,
    uint256 _amount0Desired,
    uint256 _amount1Desired
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenThePoolTypeIsCL
    givenTheTickRangeIsValid
  {
    // The whole range sits above the price, so the position is pure token0 and the token1 side of the request is
    // ignored entirely: it is fuzzed unbounded to prove the quote never reads it.
    _bootstrap(_registry, _factory, _pool);
    _tick = int24(bound(int256(_tick), int256(TickMath.MIN_TICK), int256(_RANGE_ABOVE_LOWER) - 1));
    _amount0Desired = bound(_amount0Desired, _MIN_DEPOSIT, _MAX_DEPOSIT);

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(_TICK_SPACING));
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(TickMath.getSqrtRatioAtTick(_tick), _tick, uint16(0), uint16(0), uint16(0), true)
    );

    (uint256 _amount0, uint256 _amount1, uint128 _liquidity) =
      _quoter.quoteAddClLiquidityV3(_pool, _RANGE_ABOVE_LOWER, _RANGE_ABOVE_UPPER, _amount0Desired, _amount1Desired);

    // it sizes the liquidity from amount0Desired alone
    assertEq(
      uint256(_liquidity),
      uint256(
        LiquidityAmounts.getLiquidityForAmount0(
          TickMath.getSqrtRatioAtTick(_RANGE_ABOVE_LOWER),
          TickMath.getSqrtRatioAtTick(_RANGE_ABOVE_UPPER),
          _amount0Desired
        )
      )
    );
    assertEq(
      _amount0,
      SqrtPriceMath.getAmount0Delta(
        TickMath.getSqrtRatioAtTick(_RANGE_ABOVE_LOWER),
        TickMath.getSqrtRatioAtTick(_RANGE_ABOVE_UPPER),
        _liquidity,
        true
      )
    );
    assertGt(_amount0, 0);
    // it returns zero as amount1
    assertEq(_amount1, 0);
  }

  function test_WhenThePriceIsAboveTheRange(
    address _registry,
    address _factory,
    address _pool,
    int24 _tick,
    uint256 _amount0Desired,
    uint256 _amount1Desired
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenThePoolTypeIsCL
    givenTheTickRangeIsValid
  {
    // The mirror image: the whole range sits below the price, so the position is pure token1 and the token0 side of
    // the request is ignored.
    _bootstrap(_registry, _factory, _pool);
    _tick = int24(bound(int256(_tick), int256(_RANGE_BELOW_UPPER), int256(TickMath.MAX_TICK)));
    _amount1Desired = bound(_amount1Desired, _MIN_DEPOSIT, _MAX_DEPOSIT);

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(_TICK_SPACING));
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(TickMath.getSqrtRatioAtTick(_tick), _tick, uint16(0), uint16(0), uint16(0), true)
    );

    (uint256 _amount0, uint256 _amount1, uint128 _liquidity) =
      _quoter.quoteAddClLiquidityV3(_pool, _RANGE_BELOW_LOWER, _RANGE_BELOW_UPPER, _amount0Desired, _amount1Desired);

    // it sizes the liquidity from amount1Desired alone
    assertEq(
      uint256(_liquidity),
      uint256(
        LiquidityAmounts.getLiquidityForAmount1(
          TickMath.getSqrtRatioAtTick(_RANGE_BELOW_LOWER),
          TickMath.getSqrtRatioAtTick(_RANGE_BELOW_UPPER),
          _amount1Desired
        )
      )
    );
    assertEq(
      _amount1,
      SqrtPriceMath.getAmount1Delta(
        TickMath.getSqrtRatioAtTick(_RANGE_BELOW_LOWER),
        TickMath.getSqrtRatioAtTick(_RANGE_BELOW_UPPER),
        _liquidity,
        true
      )
    );
    assertGt(_amount1, 0);
    // it returns zero as amount0
    assertEq(_amount0, 0);
  }

  function test_WhenTheUnboundedSideIsTheMaximumUint256BelowTheRange(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amount0Desired
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenThePoolTypeIsCL
    givenTheTickRangeIsValid
  {
    // The one-sided flow the interface documents: the caller supplies a token0 budget and hands the other side the
    // maximum sentinel. With the whole range above the price the sizing never reads the sentinel side, so the quote
    // is the token0 budget alone and the sentinel costs nothing.
    _bootstrap(_registry, _factory, _pool);
    _amount0Desired = bound(_amount0Desired, _MIN_DEPOSIT, _MAX_DEPOSIT);

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(_TICK_SPACING));
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(TickMath.getSqrtRatioAtTick(int24(0)), int24(0), uint16(0), uint16(0), uint16(0), true)
    );

    (uint256 _amount0, uint256 _amount1, uint128 _liquidity) =
      _quoter.quoteAddClLiquidityV3(_pool, _RANGE_ABOVE_LOWER, _RANGE_ABOVE_UPPER, _amount0Desired, type(uint256).max);

    // it quotes the bounded side alone
    assertEq(
      uint256(_liquidity),
      uint256(
        LiquidityAmounts.getLiquidityForAmount0(
          TickMath.getSqrtRatioAtTick(_RANGE_ABOVE_LOWER),
          TickMath.getSqrtRatioAtTick(_RANGE_ABOVE_UPPER),
          _amount0Desired
        )
      )
    );
    assertGt(_amount0, 0);
    assertEq(_amount1, 0);
  }

  function test_WhenTheUnboundedSideIsTheMaximumUint256InsideTheRange(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amount0Desired
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenThePoolTypeIsCL
    givenTheTickRangeIsValid
  {
    // In range the sentinel is not inert: the sizing runs it through `FullMath.mulDiv`, whose high product word is
    // about 2^96 while the denominator is only the range's square-root price delta, so the unnamed
    // `require(denominator > prod1)` fails. The unbounded side has to be a large finite amount, not the literal
    // maximum, whenever the price sits inside the range.
    _bootstrap(_registry, _factory, _pool);
    _amount0Desired = bound(_amount0Desired, _MIN_DEPOSIT, _MAX_DEPOSIT);

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(_TICK_SPACING));
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(TickMath.getSqrtRatioAtTick(int24(0)), int24(0), uint16(0), uint16(0), uint16(0), true)
    );

    // it reverts without a reason
    vm.expectRevert(bytes(''));
    _quoter.quoteAddClLiquidityV3(_pool, _TICK_LOWER, _TICK_UPPER, _amount0Desired, type(uint256).max);
  }

  function test_WhenThePriceSitsAtTheUpperTickRatioWithTheTickOneBelow(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amount0Desired,
    uint256 _amount1Desired
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenThePoolTypeIsCL
    givenTheTickRangeIsValid
  {
    // A swap that lands exactly on a tick boundary going down leaves `slot0` reporting the price of that boundary
    // while the tick lags one below it, so the sizing (which branches on the price) calls the range spent while the
    // amounts (which branch on the tick) take the in-range split. The two still agree: the in-range token0 leg spans
    // the price to the upper tick, which is now empty. The token0 side of the request is ignored, so it is fuzzed
    // unbounded.
    _bootstrap(_registry, _factory, _pool);
    _amount1Desired = bound(_amount1Desired, _MIN_DEPOSIT, _MAX_DEPOSIT);

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(_TICK_SPACING));
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(TickMath.getSqrtRatioAtTick(_TICK_UPPER), _TICK_UPPER - 1, uint16(0), uint16(0), uint16(0), true)
    );

    (uint256 _amount0, uint256 _amount1, uint128 _liquidity) =
      _quoter.quoteAddClLiquidityV3(_pool, _TICK_LOWER, _TICK_UPPER, _amount0Desired, _amount1Desired);

    // it returns zero as amount0
    assertEq(_amount0, 0);
    assertEq(
      _amount1,
      SqrtPriceMath.getAmount1Delta(
        TickMath.getSqrtRatioAtTick(_TICK_LOWER), TickMath.getSqrtRatioAtTick(_TICK_UPPER), _liquidity, true
      )
    );
    assertGt(_amount1, 0);
  }

  function test_WhenTheTickIsTheLowerTickWithThePriceInsideIt(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amount0Desired,
    uint256 _amount1Desired
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenThePoolTypeIsCL
    givenTheTickRangeIsValid
  {
    // The lower edge of the split, pinned rather than fuzzed: the tick equals the lower tick while the price sits
    // inside it, which is where the pool lands after any swap into that tick. `_modifyPosition` calls this in range
    // and pulls both sides, so the branch is strict — reading it as "at or below the lower tick" would hand back a
    // pure token0 position and understate the token1 the mint costs.
    _bootstrap(_registry, _factory, _pool);
    _amount0Desired = bound(_amount0Desired, _MIN_DEPOSIT, _MAX_DEPOSIT);
    _amount1Desired = bound(_amount1Desired, _MIN_DEPOSIT, _MAX_DEPOSIT);
    uint160 _sqrtPriceX96 = _sqrtPriceInsideTick(_TICK_LOWER);

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(_TICK_SPACING));
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(_sqrtPriceX96, _TICK_LOWER, uint16(0), uint16(0), uint16(0), true)
    );

    (uint256 _amount0, uint256 _amount1, uint128 _liquidity) =
      _quoter.quoteAddClLiquidityV3(_pool, _TICK_LOWER, _TICK_UPPER, _amount0Desired, _amount1Desired);

    // it returns both amounts rounded up at the live price
    assertEq(
      _amount0, SqrtPriceMath.getAmount0Delta(_sqrtPriceX96, TickMath.getSqrtRatioAtTick(_TICK_UPPER), _liquidity, true)
    );
    assertEq(
      _amount1, SqrtPriceMath.getAmount1Delta(TickMath.getSqrtRatioAtTick(_TICK_LOWER), _sqrtPriceX96, _liquidity, true)
    );
    // it returns both sides nonzero
    assertGt(_amount0, 0);
    assertGt(_amount1, 0);
  }

  function test_WhenTheTickIsTheUpperTickWithThePriceInsideIt(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amount0Desired,
    uint256 _amount1Desired
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenThePoolTypeIsCL
    givenTheTickRangeIsValid
  {
    // The upper edge of the same split: the tick equals the upper tick, so the range is spent and `_modifyPosition`
    // values it in token1 alone, over the whole range rather than up to the live price. The token0 side of the
    // request is ignored, so it is fuzzed and only the token1 one binds.
    _bootstrap(_registry, _factory, _pool);
    _amount0Desired = bound(_amount0Desired, _MIN_DEPOSIT, _MAX_DEPOSIT);
    _amount1Desired = bound(_amount1Desired, _MIN_DEPOSIT, _MAX_DEPOSIT);

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(_TICK_SPACING));
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(_sqrtPriceInsideTick(_TICK_UPPER), _TICK_UPPER, uint16(0), uint16(0), uint16(0), true)
    );

    (uint256 _amount0, uint256 _amount1, uint128 _liquidity) =
      _quoter.quoteAddClLiquidityV3(_pool, _TICK_LOWER, _TICK_UPPER, _amount0Desired, _amount1Desired);

    // it returns zero as amount0
    assertEq(_amount0, 0);
    assertEq(
      _amount1,
      SqrtPriceMath.getAmount1Delta(
        TickMath.getSqrtRatioAtTick(_TICK_LOWER), TickMath.getSqrtRatioAtTick(_TICK_UPPER), _liquidity, true
      )
    );
    assertGt(_amount1, 0);
  }

  function test_WhenTheQuoteIsTakenAtAPinnedPriceAndRange(
    address _registry,
    address _factory,
    address _pool
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenThePoolTypeIsCL
    givenTheTickRangeIsValid
  {
    // Pinned so the assertions check concrete amounts rather than a restatement of the libraries the quote uses: one
    // token of each side offered into a deliberately lopsided range (-600, 1200) at tick 0, where the square-root
    // price is exactly 2**96. The range reaches further above the price than below it, so token0 is the binding side
    // and is taken whole while token1 is trimmed to roughly half the token offered.
    _bootstrap(_registry, _factory, _pool);

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(_TICK_SPACING));
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(TickMath.getSqrtRatioAtTick(int24(0)), int24(0), uint16(0), uint16(0), uint16(0), true)
    );

    (uint256 _amount0, uint256 _amount1, uint128 _liquidity) =
      _quoter.quoteAddClLiquidityV3(_pool, _TICK_LOWER, _RANGE_ABOVE_UPPER, 1e18, 1e18);

    // it returns the amounts the mint callback would pull
    assertEq(uint256(_liquidity), _PINNED_LIQUIDITY);
    assertEq(_amount0, _PINNED_ADD_AMOUNT0);
    assertEq(_amount1, _PINNED_ADD_AMOUNT1);
  }
}
