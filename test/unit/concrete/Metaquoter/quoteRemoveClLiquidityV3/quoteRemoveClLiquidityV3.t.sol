// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {UnitMetaquoterLiquidityBase} from 'test/unit/concrete/Metaquoter/MetaquoterLiquidityBase.sol';

import {ICLPoolConstants} from 'contracts/core/interfaces/pool/ICLPoolConstants.sol';
import {ICLPoolState} from 'contracts/core/interfaces/pool/ICLPoolState.sol';
import {FixedPoint96} from 'contracts/core/libraries/FixedPoint96.sol';
import {FullMath} from 'contracts/core/libraries/FullMath.sol';
import {SqrtPriceMath} from 'contracts/core/libraries/SqrtPriceMath.sol';
import {TickMath} from 'contracts/core/libraries/TickMath.sol';

import {IV3FactoryRegistry} from 'contracts/periphery/interfaces/IV3FactoryRegistry.sol';

contract UnitMetaquoterQuoteRemoveClLiquidityV3 is UnitMetaquoterLiquidityBase {
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

  /// @dev Liquidity band the fuzzed quotes stay in: large enough that neither side of these ranges rounds down to
  ///      nothing, and open all the way to the ceiling a single burn can pass through the pool's `int128` cast.
  uint128 internal constant _MIN_LIQUIDITY = 1e12;
  uint128 internal constant _MAX_LIQUIDITY = uint128(type(int128).max);

  /// @dev Deposit band the add quote used by the round-trip stays in.
  uint256 internal constant _MIN_DEPOSIT = 1e6;
  uint256 internal constant _MAX_DEPOSIT = 1e27;

  /// @dev What burning 1e18 of liquidity over the (-600, 1200) range credits at tick 0.
  uint128 internal constant _PINNED_LIQUIDITY = 1e18;
  uint256 internal constant _PINNED_REMOVE_AMOUNT0 = 58_232_641_306_251_939;
  uint256 internal constant _PINNED_REMOVE_AMOUNT1 = 29_553_010_879_137_169;

  function test_WhenThePoolIsNotARegisteredTarget(
    address _registry,
    address _factory,
    address _pool,
    int24 _tickLower,
    int24 _tickUpper,
    uint128 _liquidity
  ) external {
    // The registry resolves the pool to the zero factory, i.e. it is not a registered target, so `validateClPool`
    // reverts before the range or the live price is read.
    _bootstrap(_registry, _factory, _pool);

    _mockAndExpect(
      _registry, abi.encodeWithSelector(IV3FactoryRegistry.targetToFactory.selector, _pool), abi.encode(address(0))
    );

    // it reverts with IP
    vm.expectRevert(bytes('IP'));
    _quoter.quoteRemoveClLiquidityV3(_pool, _tickLower, _tickUpper, _liquidity);
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
    uint128 _liquidity
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
    _quoter.quoteRemoveClLiquidityV3(_pool, _tickLower, _tickUpper, _liquidity);
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
    uint128 _liquidity
  ) external givenThePoolIsARegisteredTarget givenTheTargetFactoryIsApproved {
    // A V2 pool of an approved factory: the type gate rejects it before any CL getter it does not implement is
    // reached, so `tickSpacing` and `slot0` are left unmocked deliberately.
    _bootstrap(_registry, _factory, _pool);
    _mockValidPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE);

    // it reverts with PT
    vm.expectRevert(bytes('PT'));
    _quoter.quoteRemoveClLiquidityV3(_pool, _tickLower, _tickUpper, _liquidity);
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
    uint128 _liquidity
  ) external givenThePoolIsARegisteredTarget givenTheTargetFactoryIsApproved givenThePoolTypeIsCL {
    // Removals are validated exactly as mints are: no position the pool holds can have an inverted or degenerate
    // range, so a quote describing one is refused rather than valued.
    _bootstrap(_registry, _factory, _pool);
    _tickLower = int24(bound(int256(_tickLower), int256(_tickUpper), int256(type(int24).max)));

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);

    // it reverts with TLU
    vm.expectRevert(bytes('TLU'));
    _quoter.quoteRemoveClLiquidityV3(_pool, _tickLower, _tickUpper, _liquidity);
  }

  function test_WhenTheLowerTickIsBelowTheMinimumTick(
    address _registry,
    address _factory,
    address _pool,
    int24 _tickLower,
    int24 _tickUpper,
    uint128 _liquidity
  ) external givenThePoolIsARegisteredTarget givenTheTargetFactoryIsApproved givenThePoolTypeIsCL {
    // The upper tick only has to clear the lower one for the lower bound to be the failing check.
    _bootstrap(_registry, _factory, _pool);
    _tickLower = int24(bound(int256(_tickLower), int256(type(int24).min), int256(TickMath.MIN_TICK) - 1));
    _tickUpper = int24(bound(int256(_tickUpper), int256(_tickLower) + 1, int256(type(int24).max)));

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);

    // it reverts with TLM
    vm.expectRevert(bytes('TLM'));
    _quoter.quoteRemoveClLiquidityV3(_pool, _tickLower, _tickUpper, _liquidity);
  }

  function test_WhenTheUpperTickIsAboveTheMaximumTick(
    address _registry,
    address _factory,
    address _pool,
    int24 _tickLower,
    int24 _tickUpper,
    uint128 _liquidity
  ) external givenThePoolIsARegisteredTarget givenTheTargetFactoryIsApproved givenThePoolTypeIsCL {
    // The lower tick is held inside the valid band so only the upper bound can fail.
    _bootstrap(_registry, _factory, _pool);
    _tickUpper = int24(bound(int256(_tickUpper), int256(TickMath.MAX_TICK) + 1, int256(type(int24).max)));
    _tickLower = int24(bound(int256(_tickLower), int256(TickMath.MIN_TICK), int256(TickMath.MAX_TICK)));

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);

    // it reverts with TUM
    vm.expectRevert(bytes('TUM'));
    _quoter.quoteRemoveClLiquidityV3(_pool, _tickLower, _tickUpper, _liquidity);
  }

  function test_WhenTheLowerTickIsNotAlignedToTheTickSpacing(
    address _registry,
    address _factory,
    address _pool,
    int24 _tickLower,
    uint128 _liquidity
  ) external givenThePoolIsARegisteredTarget givenTheTargetFactoryIsApproved givenThePoolTypeIsCL {
    // The fuzzed lower tick is pulled back to a spacing boundary and stepped one tick off it, so the range clears
    // every bound and only the alignment fails. Alignment is enforced on removals too: the pool's bitmap only ever
    // flipped spacing-aligned ticks, so an unaligned range cannot describe a position it holds.
    _bootstrap(_registry, _factory, _pool);
    _tickLower =
      int24(bound(int256(_tickLower), int256(TickMath.MIN_TICK) + int256(_TICK_SPACING), -int256(_TICK_SPACING)));
    _tickLower = (_tickLower / _TICK_SPACING) * _TICK_SPACING - 1;

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(_TICK_SPACING));

    // it reverts with TS
    vm.expectRevert(bytes('TS'));
    _quoter.quoteRemoveClLiquidityV3(_pool, _tickLower, _TICK_UPPER, _liquidity);
  }

  function test_WhenTheUpperTickIsNotAlignedToTheTickSpacing(
    address _registry,
    address _factory,
    address _pool,
    int24 _tickUpper,
    uint128 _liquidity
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
    _quoter.quoteRemoveClLiquidityV3(_pool, _TICK_LOWER, _tickUpper, _liquidity);
  }

  modifier givenTheTickRangeIsValid() {
    _;
  }

  function test_WhenTheLiquidityIsZero(
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
    // No removal path executes an empty burn: `decreaseLiquidity` refuses a zero amount outright, and the pool's own
    // `burn(0)` is a poke that credits nothing, so a zero quote would describe a removal that cannot happen. It is
    // refused before the boundary ticks or the live price are read, so those are left unmocked deliberately.
    _bootstrap(_registry, _factory, _pool);

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(_TICK_SPACING));

    // it reverts with ILB
    vm.expectRevert(bytes('ILB'));
    _quoter.quoteRemoveClLiquidityV3(_pool, _TICK_LOWER, _TICK_UPPER, 0);
  }

  function test_WhenTheLiquidityExceedsTheInt128Maximum(
    address _registry,
    address _factory,
    address _pool,
    uint128 _liquidity
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenThePoolTypeIsCL
    givenTheTickRangeIsValid
  {
    // `burn` casts the liquidity to `int128` before applying it, so anything above that maximum reverts at execution
    // without a reason string. The quote refuses it deterministically instead, before the live price is read, so
    // `slot0` is left unmocked deliberately.
    _bootstrap(_registry, _factory, _pool);
    _liquidity = uint128(bound(uint256(_liquidity), uint256(_MAX_LIQUIDITY) + 1, uint256(type(uint128).max)));

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(_TICK_SPACING));

    // it reverts with LTM
    vm.expectRevert(bytes('LTM'));
    _quoter.quoteRemoveClLiquidityV3(_pool, _TICK_LOWER, _TICK_UPPER, _liquidity);
  }

  function test_WhenTheLiquidityExceedsTheGrossLiquidityAtTheLowerTick(
    address _registry,
    address _factory,
    address _pool,
    uint128 _liquidity,
    uint128 _liquidityGrossLower,
    uint128 _liquidityGrossUpper
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenThePoolTypeIsCL
    givenTheTickRangeIsValid
  {
    // The lower tick references less liquidity than the burn would take from it, so no position on this range holds
    // that much and `Tick.update` underflows on the way out. The quote refuses it here instead, mirroring the pool.
    // The upper tick is held above the burn so only the lower one can bind, and the price is never read.
    _bootstrap(_registry, _factory, _pool);
    _liquidity = uint128(bound(uint256(_liquidity), 1, uint256(_MAX_LIQUIDITY)));
    _liquidityGrossLower = uint128(bound(uint256(_liquidityGrossLower), 0, uint256(_liquidity) - 1));
    _liquidityGrossUpper =
      uint128(bound(uint256(_liquidityGrossUpper), uint256(_liquidity), uint256(type(uint128).max)));

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(_TICK_SPACING));
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.ticks.selector, _TICK_LOWER),
      abi.encode(
        _liquidityGrossLower,
        int128(0),
        int128(0),
        uint256(0),
        uint256(0),
        uint256(0),
        int56(0),
        uint160(0),
        uint32(0),
        true
      )
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.ticks.selector, _TICK_UPPER),
      abi.encode(
        _liquidityGrossUpper,
        int128(0),
        int128(0),
        uint256(0),
        uint256(0),
        uint256(0),
        int56(0),
        uint160(0),
        uint32(0),
        true
      )
    );

    // it reverts with LS
    vm.expectRevert(bytes('LS'));
    _quoter.quoteRemoveClLiquidityV3(_pool, _TICK_LOWER, _TICK_UPPER, _liquidity);
  }

  function test_WhenTheLiquidityExceedsTheGrossLiquidityAtTheUpperTick(
    address _registry,
    address _factory,
    address _pool,
    uint128 _liquidity,
    uint128 _liquidityGrossLower,
    uint128 _liquidityGrossUpper
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenThePoolTypeIsCL
    givenTheTickRangeIsValid
  {
    // The mirror image: the lower tick clears the burn and the upper one is what falls short, so the bound has to
    // hold on both boundary ticks rather than on the first one read.
    _bootstrap(_registry, _factory, _pool);
    _liquidity = uint128(bound(uint256(_liquidity), 1, uint256(_MAX_LIQUIDITY)));
    _liquidityGrossLower =
      uint128(bound(uint256(_liquidityGrossLower), uint256(_liquidity), uint256(type(uint128).max)));
    _liquidityGrossUpper = uint128(bound(uint256(_liquidityGrossUpper), 0, uint256(_liquidity) - 1));

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(_TICK_SPACING));
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.ticks.selector, _TICK_LOWER),
      abi.encode(
        _liquidityGrossLower,
        int128(0),
        int128(0),
        uint256(0),
        uint256(0),
        uint256(0),
        int56(0),
        uint160(0),
        uint32(0),
        true
      )
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.ticks.selector, _TICK_UPPER),
      abi.encode(
        _liquidityGrossUpper,
        int128(0),
        int128(0),
        uint256(0),
        uint256(0),
        uint256(0),
        int56(0),
        uint160(0),
        uint32(0),
        true
      )
    );

    // it reverts with LS
    vm.expectRevert(bytes('LS'));
    _quoter.quoteRemoveClLiquidityV3(_pool, _TICK_LOWER, _TICK_UPPER, _liquidity);
  }

  function test_WhenTheCreditedToken1AmountExceedsTheUint128Maximum(
    address _registry,
    address _factory,
    address _pool,
    int24 _tick,
    uint128 _liquidity
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenThePoolTypeIsCL
    givenTheTickRangeIsValid
  {
    // `burn` credits the principal to the position's `tokensOwed` through a `uint128` cast, so an amount above that
    // width is quoted but truncated away at execution and never collectible. The widest spacing-aligned range priced
    // from above holds token1 alone, where `amount1 = liquidity * (sqrtUpper - sqrtLower) / 2**96`: the smallest
    // liquidity clearing the cap is `uint128.max * 2**96 / (sqrtUpper - sqrtLower)`, rounded up so the fuzzed band
    // starts strictly past it. The quote's own library confirms the constructed inputs really do exceed the width.
    _bootstrap(_registry, _factory, _pool);
    int24 _tickLower = (TickMath.MIN_TICK / _TICK_SPACING) * _TICK_SPACING;
    int24 _tickUpper = (TickMath.MAX_TICK / _TICK_SPACING) * _TICK_SPACING;
    uint160 _sqrtLower = TickMath.getSqrtRatioAtTick(_tickLower);
    uint160 _sqrtUpper = TickMath.getSqrtRatioAtTick(_tickUpper);
    _tick = int24(bound(int256(_tick), int256(_tickUpper), int256(TickMath.MAX_TICK)));
    _liquidity = uint128(
      bound(
        uint256(_liquidity),
        FullMath.mulDivRoundingUp(uint256(type(uint128).max), FixedPoint96.Q96, _sqrtUpper - _sqrtLower) + 1,
        _MAX_LIQUIDITY
      )
    );
    assertGt(SqrtPriceMath.getAmount1Delta(_sqrtLower, _sqrtUpper, _liquidity, false), uint256(type(uint128).max));

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(_TICK_SPACING));
    // both boundary ticks reference more liquidity than the burn, so the pool's own bound stays passive here
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.ticks.selector, _tickLower),
      abi.encode(
        type(uint128).max,
        int128(0),
        int128(0),
        uint256(0),
        uint256(0),
        uint256(0),
        int56(0),
        uint160(0),
        uint32(0),
        true
      )
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.ticks.selector, _tickUpper),
      abi.encode(
        type(uint128).max,
        int128(0),
        int128(0),
        uint256(0),
        uint256(0),
        uint256(0),
        int56(0),
        uint160(0),
        uint32(0),
        true
      )
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(TickMath.getSqrtRatioAtTick(_tick), _tick, uint16(0), uint16(0), uint16(0), true)
    );

    // it reverts with AO
    vm.expectRevert(bytes('AO'));
    _quoter.quoteRemoveClLiquidityV3(_pool, _tickLower, _tickUpper, _liquidity);
  }

  function test_WhenTheCreditedToken0AmountExceedsTheUint128Maximum(
    address _registry,
    address _factory,
    address _pool,
    int24 _tick,
    uint128 _liquidity
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenThePoolTypeIsCL
    givenTheTickRangeIsValid
  {
    // The mirror image on the other side: the same range priced from below holds token0 alone, where
    // `amount0 = liquidity * 2**96 * (sqrtUpper - sqrtLower) / (sqrtLower * sqrtUpper)` and the lower tick's tiny
    // square-root price is what inflates it past the width. Inverting that gives
    // `uint128.max * sqrtLower * sqrtUpper / (2**96 * (sqrtUpper - sqrtLower))`, taken in that order so no step
    // truncates to nothing, and rounded up at each one so the fuzzed band starts strictly past the threshold.
    _bootstrap(_registry, _factory, _pool);
    int24 _tickLower = (TickMath.MIN_TICK / _TICK_SPACING) * _TICK_SPACING;
    int24 _tickUpper = (TickMath.MAX_TICK / _TICK_SPACING) * _TICK_SPACING;
    uint160 _sqrtLower = TickMath.getSqrtRatioAtTick(_tickLower);
    uint160 _sqrtUpper = TickMath.getSqrtRatioAtTick(_tickUpper);
    _tick = int24(bound(int256(_tick), int256(TickMath.MIN_TICK), int256(_tickLower) - 1));
    _liquidity = uint128(
      bound(
        uint256(_liquidity),
        FullMath.mulDivRoundingUp(
          FullMath.mulDivRoundingUp(uint256(type(uint128).max), _sqrtLower, FixedPoint96.Q96),
          _sqrtUpper,
          _sqrtUpper - _sqrtLower
        ) + 1,
        _MAX_LIQUIDITY
      )
    );
    assertGt(SqrtPriceMath.getAmount0Delta(_sqrtLower, _sqrtUpper, _liquidity, false), uint256(type(uint128).max));

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(_TICK_SPACING));
    // both boundary ticks reference more liquidity than the burn, so the pool's own bound stays passive here
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.ticks.selector, _tickLower),
      abi.encode(
        type(uint128).max,
        int128(0),
        int128(0),
        uint256(0),
        uint256(0),
        uint256(0),
        int56(0),
        uint160(0),
        uint32(0),
        true
      )
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.ticks.selector, _tickUpper),
      abi.encode(
        type(uint128).max,
        int128(0),
        int128(0),
        uint256(0),
        uint256(0),
        uint256(0),
        int56(0),
        uint160(0),
        uint32(0),
        true
      )
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(TickMath.getSqrtRatioAtTick(_tick), _tick, uint16(0), uint16(0), uint16(0), true)
    );

    // it reverts with AO
    vm.expectRevert(bytes('AO'));
    _quoter.quoteRemoveClLiquidityV3(_pool, _tickLower, _tickUpper, _liquidity);
  }

  function test_WhenThePriceIsInsideTheRange(
    address _registry,
    address _factory,
    address _pool,
    int24 _tick,
    uint128 _liquidity
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenThePoolTypeIsCL
    givenTheTickRangeIsValid
  {
    // The price is held strictly inside the range so the position straddles it, and the tick is fuzzed across the
    // range so the assertions follow the split rather than one pinned point on it.
    _bootstrap(_registry, _factory, _pool);
    _tick = int24(bound(int256(_tick), int256(_TICK_LOWER) + 1, int256(_TICK_UPPER) - 1));
    _liquidity = uint128(bound(uint256(_liquidity), _MIN_LIQUIDITY, _MAX_LIQUIDITY));
    uint160 _sqrtPriceX96 = TickMath.getSqrtRatioAtTick(_tick);

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(_TICK_SPACING));
    // both boundary ticks reference more liquidity than the burn, so the pool's own bound stays passive here
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.ticks.selector, _TICK_LOWER),
      abi.encode(
        type(uint128).max,
        int128(0),
        int128(0),
        uint256(0),
        uint256(0),
        uint256(0),
        int56(0),
        uint160(0),
        uint32(0),
        true
      )
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.ticks.selector, _TICK_UPPER),
      abi.encode(
        type(uint128).max,
        int128(0),
        int128(0),
        uint256(0),
        uint256(0),
        uint256(0),
        int56(0),
        uint160(0),
        uint32(0),
        true
      )
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(_sqrtPriceX96, _tick, uint16(0), uint16(0), uint16(0), true)
    );

    (uint256 _amount0, uint256 _amount1) = _quoter.quoteRemoveClLiquidityV3(_pool, _TICK_LOWER, _TICK_UPPER, _liquidity);

    // it returns both amounts rounded down at the live price
    assertEq(
      _amount0,
      SqrtPriceMath.getAmount0Delta(_sqrtPriceX96, TickMath.getSqrtRatioAtTick(_TICK_UPPER), _liquidity, false)
    );
    assertEq(
      _amount1,
      SqrtPriceMath.getAmount1Delta(TickMath.getSqrtRatioAtTick(_TICK_LOWER), _sqrtPriceX96, _liquidity, false)
    );
    // it returns both sides nonzero
    assertGt(_amount0, 0);
    assertGt(_amount1, 0);
  }

  function test_WhenThePriceIsBelowTheRange(
    address _registry,
    address _factory,
    address _pool,
    int24 _tick,
    uint128 _liquidity
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenThePoolTypeIsCL
    givenTheTickRangeIsValid
  {
    // The whole range sits above the price, so the position was long token0 all the way and the burn credits nothing
    // on the other side.
    _bootstrap(_registry, _factory, _pool);
    _tick = int24(bound(int256(_tick), int256(TickMath.MIN_TICK), int256(_RANGE_ABOVE_LOWER) - 1));
    _liquidity = uint128(bound(uint256(_liquidity), _MIN_LIQUIDITY, _MAX_LIQUIDITY));

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(_TICK_SPACING));
    // both boundary ticks reference more liquidity than the burn, so the pool's own bound stays passive here
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.ticks.selector, _RANGE_ABOVE_LOWER),
      abi.encode(
        type(uint128).max,
        int128(0),
        int128(0),
        uint256(0),
        uint256(0),
        uint256(0),
        int56(0),
        uint160(0),
        uint32(0),
        true
      )
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.ticks.selector, _RANGE_ABOVE_UPPER),
      abi.encode(
        type(uint128).max,
        int128(0),
        int128(0),
        uint256(0),
        uint256(0),
        uint256(0),
        int56(0),
        uint160(0),
        uint32(0),
        true
      )
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(TickMath.getSqrtRatioAtTick(_tick), _tick, uint16(0), uint16(0), uint16(0), true)
    );

    (uint256 _amount0, uint256 _amount1) =
      _quoter.quoteRemoveClLiquidityV3(_pool, _RANGE_ABOVE_LOWER, _RANGE_ABOVE_UPPER, _liquidity);

    // it returns the whole range in token0
    assertEq(
      _amount0,
      SqrtPriceMath.getAmount0Delta(
        TickMath.getSqrtRatioAtTick(_RANGE_ABOVE_LOWER),
        TickMath.getSqrtRatioAtTick(_RANGE_ABOVE_UPPER),
        _liquidity,
        false
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
    uint128 _liquidity
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenThePoolTypeIsCL
    givenTheTickRangeIsValid
  {
    // The mirror image: the whole range sits below the price, so the burn credits token1 only.
    _bootstrap(_registry, _factory, _pool);
    _tick = int24(bound(int256(_tick), int256(_RANGE_BELOW_UPPER), int256(TickMath.MAX_TICK)));
    _liquidity = uint128(bound(uint256(_liquidity), _MIN_LIQUIDITY, _MAX_LIQUIDITY));

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(_TICK_SPACING));
    // both boundary ticks reference more liquidity than the burn, so the pool's own bound stays passive here
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.ticks.selector, _RANGE_BELOW_LOWER),
      abi.encode(
        type(uint128).max,
        int128(0),
        int128(0),
        uint256(0),
        uint256(0),
        uint256(0),
        int56(0),
        uint160(0),
        uint32(0),
        true
      )
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.ticks.selector, _RANGE_BELOW_UPPER),
      abi.encode(
        type(uint128).max,
        int128(0),
        int128(0),
        uint256(0),
        uint256(0),
        uint256(0),
        int56(0),
        uint160(0),
        uint32(0),
        true
      )
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(TickMath.getSqrtRatioAtTick(_tick), _tick, uint16(0), uint16(0), uint16(0), true)
    );

    (uint256 _amount0, uint256 _amount1) =
      _quoter.quoteRemoveClLiquidityV3(_pool, _RANGE_BELOW_LOWER, _RANGE_BELOW_UPPER, _liquidity);

    // it returns the whole range in token1
    assertEq(
      _amount1,
      SqrtPriceMath.getAmount1Delta(
        TickMath.getSqrtRatioAtTick(_RANGE_BELOW_LOWER),
        TickMath.getSqrtRatioAtTick(_RANGE_BELOW_UPPER),
        _liquidity,
        false
      )
    );
    assertGt(_amount1, 0);
    // it returns zero as amount0
    assertEq(_amount0, 0);
  }

  function test_WhenTheTickIsTheLowerTickWithThePriceInsideIt(
    address _registry,
    address _factory,
    address _pool,
    uint128 _liquidity
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenThePoolTypeIsCL
    givenTheTickRangeIsValid
  {
    // The lower edge of the split, pinned rather than fuzzed: the tick equals the lower tick while the price sits
    // inside it, which is where the pool lands after any swap into that tick. `_modifyPosition` calls this in range
    // and credits both sides, so the branch is strict — reading it as "at or below the lower tick" would credit the
    // burn in token0 alone and drop the token1 the position is holding.
    _bootstrap(_registry, _factory, _pool);
    _liquidity = uint128(bound(uint256(_liquidity), _MIN_LIQUIDITY, _MAX_LIQUIDITY));
    uint160 _sqrtPriceX96 = _sqrtPriceInsideTick(_TICK_LOWER);

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(_TICK_SPACING));
    // both boundary ticks reference more liquidity than the burn, so the pool's own bound stays passive here
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.ticks.selector, _TICK_LOWER),
      abi.encode(
        type(uint128).max,
        int128(0),
        int128(0),
        uint256(0),
        uint256(0),
        uint256(0),
        int56(0),
        uint160(0),
        uint32(0),
        true
      )
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.ticks.selector, _TICK_UPPER),
      abi.encode(
        type(uint128).max,
        int128(0),
        int128(0),
        uint256(0),
        uint256(0),
        uint256(0),
        int56(0),
        uint160(0),
        uint32(0),
        true
      )
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(_sqrtPriceX96, _TICK_LOWER, uint16(0), uint16(0), uint16(0), true)
    );

    (uint256 _amount0, uint256 _amount1) = _quoter.quoteRemoveClLiquidityV3(_pool, _TICK_LOWER, _TICK_UPPER, _liquidity);

    // it returns both amounts rounded down at the live price
    assertEq(
      _amount0,
      SqrtPriceMath.getAmount0Delta(_sqrtPriceX96, TickMath.getSqrtRatioAtTick(_TICK_UPPER), _liquidity, false)
    );
    assertEq(
      _amount1,
      SqrtPriceMath.getAmount1Delta(TickMath.getSqrtRatioAtTick(_TICK_LOWER), _sqrtPriceX96, _liquidity, false)
    );
    // it returns both sides nonzero
    assertGt(_amount0, 0);
    assertGt(_amount1, 0);
  }

  function test_WhenTheTickIsTheUpperTickWithThePriceInsideIt(
    address _registry,
    address _factory,
    address _pool,
    uint128 _liquidity
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenThePoolTypeIsCL
    givenTheTickRangeIsValid
  {
    // The upper edge of the same split: the tick equals the upper tick, so the range is spent and the burn credits
    // token1 alone, over the whole range rather than up to the live price.
    _bootstrap(_registry, _factory, _pool);
    _liquidity = uint128(bound(uint256(_liquidity), _MIN_LIQUIDITY, _MAX_LIQUIDITY));

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(_TICK_SPACING));
    // both boundary ticks reference more liquidity than the burn, so the pool's own bound stays passive here
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.ticks.selector, _TICK_LOWER),
      abi.encode(
        type(uint128).max,
        int128(0),
        int128(0),
        uint256(0),
        uint256(0),
        uint256(0),
        int56(0),
        uint160(0),
        uint32(0),
        true
      )
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.ticks.selector, _TICK_UPPER),
      abi.encode(
        type(uint128).max,
        int128(0),
        int128(0),
        uint256(0),
        uint256(0),
        uint256(0),
        int56(0),
        uint160(0),
        uint32(0),
        true
      )
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(_sqrtPriceInsideTick(_TICK_UPPER), _TICK_UPPER, uint16(0), uint16(0), uint16(0), true)
    );

    (uint256 _amount0, uint256 _amount1) = _quoter.quoteRemoveClLiquidityV3(_pool, _TICK_LOWER, _TICK_UPPER, _liquidity);

    // it returns zero as amount0
    assertEq(_amount0, 0);
    assertEq(
      _amount1,
      SqrtPriceMath.getAmount1Delta(
        TickMath.getSqrtRatioAtTick(_TICK_LOWER), TickMath.getSqrtRatioAtTick(_TICK_UPPER), _liquidity, false
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
    // Pinned so the assertions check concrete amounts rather than a restatement of the libraries the quote uses:
    // 1e18 of liquidity over the lopsided range (-600, 1200) at tick 0, where the square-root price is exactly 2**96.
    // The range reaches twice as far above the price as below it, so the token0 leg is worth about twice the token1
    // one. Uncollected fees are out of scope, so this is the principal alone.
    _bootstrap(_registry, _factory, _pool);

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(_TICK_SPACING));
    // both boundary ticks reference more liquidity than the burn, so the pool's own bound stays passive here
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.ticks.selector, _TICK_LOWER),
      abi.encode(
        type(uint128).max,
        int128(0),
        int128(0),
        uint256(0),
        uint256(0),
        uint256(0),
        int56(0),
        uint160(0),
        uint32(0),
        true
      )
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.ticks.selector, _RANGE_ABOVE_UPPER),
      abi.encode(
        type(uint128).max,
        int128(0),
        int128(0),
        uint256(0),
        uint256(0),
        uint256(0),
        int56(0),
        uint160(0),
        uint32(0),
        true
      )
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(TickMath.getSqrtRatioAtTick(int24(0)), int24(0), uint16(0), uint16(0), uint16(0), true)
    );

    (uint256 _amount0, uint256 _amount1) =
      _quoter.quoteRemoveClLiquidityV3(_pool, _TICK_LOWER, _RANGE_ABOVE_UPPER, _PINNED_LIQUIDITY);

    // it returns the amounts the burn would credit
    assertEq(_amount0, _PINNED_REMOVE_AMOUNT0);
    assertEq(_amount1, _PINNED_REMOVE_AMOUNT1);
  }

  function test_WhenTheLiquidityAnAddQuoteSizedIsRemovedAgain(
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
    // Round-tripping the same liquidity through both quotes at one unchanged price: the mint quote rounds every leg
    // up because the pool pulls those amounts, the burn quote rounds them down because the pool credits those, so a
    // position minted and immediately burned gives back at most what it cost and never more than a wei less a side.
    _bootstrap(_registry, _factory, _pool);
    _tick = int24(bound(int256(_tick), int256(_TICK_LOWER) + 1, int256(_TICK_UPPER) - 1));
    _amount0Desired = bound(_amount0Desired, _MIN_DEPOSIT, _MAX_DEPOSIT);
    _amount1Desired = bound(_amount1Desired, _MIN_DEPOSIT, _MAX_DEPOSIT);

    _mockValidPool(_registry, _factory, _pool, _CL_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(_TICK_SPACING));
    // the add quote never reads them; the burn's bound is left passive so the round-trip is what is under test
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.ticks.selector, _TICK_LOWER),
      abi.encode(
        type(uint128).max,
        int128(0),
        int128(0),
        uint256(0),
        uint256(0),
        uint256(0),
        int56(0),
        uint160(0),
        uint32(0),
        true
      )
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.ticks.selector, _TICK_UPPER),
      abi.encode(
        type(uint128).max,
        int128(0),
        int128(0),
        uint256(0),
        uint256(0),
        uint256(0),
        int56(0),
        uint160(0),
        uint32(0),
        true
      )
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(TickMath.getSqrtRatioAtTick(_tick), _tick, uint16(0), uint16(0), uint16(0), true)
    );

    (uint256 _added0, uint256 _added1, uint128 _liquidity) =
      _quoter.quoteAddClLiquidityV3(_pool, _TICK_LOWER, _TICK_UPPER, _amount0Desired, _amount1Desired);
    (uint256 _removed0, uint256 _removed1) =
      _quoter.quoteRemoveClLiquidityV3(_pool, _TICK_LOWER, _TICK_UPPER, _liquidity);

    // it returns at most the amounts the add quote required
    assertLe(_removed0, _added0);
    assertLe(_removed1, _added1);
    // it returns amounts within one wei of them
    assertLe(_added0 - _removed0, 1);
    assertLe(_added1 - _removed1, 1);
  }
}
