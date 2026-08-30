// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {FixedPoint128} from 'contracts/core/libraries/FixedPoint128.sol';
import {FullMath} from 'contracts/core/libraries/FullMath.sol';

import {CLPool} from 'contracts/core/CLPool.sol';

import {ICLPoolConstants} from 'contracts/core/interfaces/pool/ICLPoolConstants.sol';
import {ICLPoolState} from 'contracts/core/interfaces/pool/ICLPoolState.sol';
import {ICLGauge} from 'contracts/gauge/interfaces/ICLGauge.sol';

import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import '../../../BaseFixture.sol';

abstract contract CLPoolTest is BaseFixture {
  using stdStorage for StdStorage;

  address internal tokenA = makeAddr('tokenA');
  address internal tokenB = makeAddr('tokenB');

  uint256 internal _FEE_CEIL;
  uint256 internal _DENOMINATOR;

  CLPool internal clPool;

  function setUp() public virtual override {
    super.setUp(); // BaseFixture.setUp()

    clPool = CLPool(
      poolFactory.createPool({
        tokenA: tokenA, tokenB: tokenB, tickSpacing: TICK_SPACING_60, sqrtPriceX96: encodePriceSqrt(1, 1)
      })
    );

    _FEE_CEIL = clPool.SWAP_FEE_CEIL();
    _DENOMINATOR = clPool.DENOMINATOR();
  }

  /*///////////////////////////////////////////////////////////////
                      STORAGE HELPERS
  //////////////////////////////////////////////////////////////*/

  function _setSlot0SqrtPrice(address _pool, uint160 _sqrtPriceX96) internal {
    stdstore.target(_pool).enable_packed_slots().sig(ICLPoolState.slot0.selector).depth(0)
      .checked_write(uint256(_sqrtPriceX96));
  }

  function _setSlot0Tick(address _pool, int24 _tick) internal {
    uint256 _slot = stdstore.target(_pool).sig(ICLPoolState.slot0.selector).enable_packed_slots().find();

    bytes32 _word = vm.load(_pool, bytes32(_slot));

    // For integer raw form is two's-complement.
    uint256 _rawTick = uint256(uint24(_tick));

    // Tick is packed after sqrtPriceX96 (20 bytes = 160 bits).
    uint256 _updated = (uint256(_word) & ~(uint256(type(uint24).max) << 160)) | (_rawTick << 160);

    vm.store(_pool, bytes32(_slot), bytes32(_updated));
  }

  function _setSlot0Unlocked(address _pool, bool _value) internal {
    stdstore.target(_pool).enable_packed_slots().sig(ICLPoolState.slot0.selector).depth(5).checked_write(_value);
  }

  function _setFeeGrowthGlobal0X128(address _pool, uint256 _value) internal {
    _set(_pool, _value, ICLPoolState.feeGrowthGlobal0X128.selector);
  }

  function _setFeeGrowthGlobal1X128(address _pool, uint256 _value) internal {
    _set(_pool, _value, ICLPoolState.feeGrowthGlobal1X128.selector);
  }

  function _setTickFeeGrowthOutside0X128(address _pool, int256 _tick, uint256 _value) internal {
    stdstore.target(_pool).enable_packed_slots().sig(ICLPoolState.ticks.selector).with_key(bytes32(_tick)).depth(3)
      .checked_write(_value);
  }

  function _setTickFeeGrowthOutside1X128(address _pool, int256 _tick, uint256 _value) internal {
    stdstore.target(_pool).enable_packed_slots().sig(ICLPoolState.ticks.selector).with_key(bytes32(_tick)).depth(4)
      .checked_write(_value);
  }

  function _setLiquidity(address _pool, uint128 _value) internal {
    stdstore.target(_pool).sig(ICLPoolState.liquidity.selector).enable_packed_slots().checked_write(_value);
  }

  function _setStakedLiquidity(address _pool, uint128 _value) internal {
    stdstore.target(_pool).sig(ICLPoolState.stakedLiquidity.selector).enable_packed_slots().checked_write(_value);
  }

  /// @notice Sets rewardGrowthGlobalX128 in the storage of a pool
  function _setPreviousRewardGrowthGlobalX128(address _pool, uint256 _previousRewardGrowthGlobalX128) internal {
    _set(address(_pool), _previousRewardGrowthGlobalX128, ICLPoolState.rewardGrowthGlobalX128.selector);
  }

  /// @notice Sets rollover in the storage of a pool
  function _setPreviousRollover(address _pool, uint256 _previousRollover) internal {
    _set(address(_pool), _previousRollover, ICLPoolState.rollover.selector);
  }

  /// @notice Sets lastUpdated in the packed slots of a pool
  function _setLastUpdated(address _pool, uint48 _lastUpdated) internal {
    _setPacked(address(_pool), _lastUpdated, ICLPoolState.lastUpdated.selector);
  }

  /// @notice Sets secondsPerStakedLiquidityCumulativeX128 in the storage of a pool
  function _setSecondsPerStakedLiquidityCumulativeX128(address _pool, uint160 _cumulative) internal {
    _setPacked(address(_pool), _cumulative, ICLPoolState.secondsPerStakedLiquidityCumulativeX128.selector);
  }

  /// @notice Sets the gauge address in the storage of a pool
  function _setGauge(address _pool, address _gauge) internal {
    _set(address(_pool), uint256(uint160(_gauge)), ICLPoolConstants.gauge.selector);
  }

  /// @notice Mocks a call and expects it to be made
  function _mockAndExpect(address _receiver, bytes memory _calldata, bytes memory _returned) internal {
    vm.mockCall(_receiver, _calldata, _returned);
    vm.expectCall(_receiver, _calldata);
  }

  /// @notice Sets a value in the storage of a contract
  function _set(address _contract, uint256 _value, bytes4 _sig) internal {
    stdstore.target(_contract).sig(_sig).checked_write(_value);
  }

  /// @notice Sets a value in the packed slots of a contract
  function _setPacked(address _contract, uint256 _value, bytes4 _sig) internal {
    stdstore.target(_contract).enable_packed_slots().sig(_sig).checked_write(_value);
  }

  /*///////////////////////////////////////////////////////////////
                      HELPERS
  //////////////////////////////////////////////////////////////*/

  /// @dev Wrapper for {CLPool.calculateFees | CLPool.splitFees | CLPool.applyUnstakedFee}
  function _calculateFees(
    uint256 _feeAmount,
    uint128 _liquidity,
    uint128 _stakedLiquidity
  ) internal view returns (uint256 _feeGrowthGlobalX128, uint256 _stakedFeeAmount) {
    // only staked
    if (_liquidity == _stakedLiquidity) {
      _stakedFeeAmount = _feeAmount;
    }
    // only non-staked
    else if (_stakedLiquidity == 0) {
      uint256 _stakedFee = FullMath.mulDivRoundingUp(_feeAmount, clPool.unstakedFee(), _DENOMINATOR);
      uint256 _unstakedFeeAmount = _feeAmount - _stakedFee;
      _stakedFeeAmount = _stakedFee;

      _feeGrowthGlobalX128 = FullMath.mulDiv(_unstakedFeeAmount, FixedPoint128.Q128, _liquidity);
    }
    // staked > 0 & non-staked > 0
    else {
      _stakedFeeAmount = FullMath.mulDivRoundingUp(_feeAmount, _stakedLiquidity, _liquidity);

      uint256 _unstakedFeeAmount = _feeAmount - _stakedFeeAmount;
      uint256 _stakedFee = FullMath.mulDivRoundingUp(_unstakedFeeAmount, clPool.unstakedFee(), _DENOMINATOR);
      _unstakedFeeAmount -= _stakedFee;
      _stakedFeeAmount = _stakedFeeAmount + _stakedFee;

      _feeGrowthGlobalX128 = FullMath.mulDiv(_unstakedFeeAmount, FixedPoint128.Q128, (_liquidity - _stakedLiquidity));
    }
  }
}
