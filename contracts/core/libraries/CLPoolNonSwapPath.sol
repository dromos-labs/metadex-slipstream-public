// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import {FixedPoint128} from './FixedPoint128.sol';
import {FullMath} from './FullMath.sol';
import {LiquidityMath} from './LiquidityMath.sol';
import {LowGasSafeMath} from './LowGasSafeMath.sol';
import {Oracle} from './Oracle.sol';
import {Position} from './Position.sol';
import {SafeCast} from './SafeCast.sol';
import {SqrtPriceMath} from './SqrtPriceMath.sol';
import {Tick} from './Tick.sol';
import {TickBitmap} from './TickBitmap.sol';
import {TickMath} from './TickMath.sol';
import {TransferHelper} from './TransferHelper.sol';
import {SwapHookLib} from './hook/SwapHookLib.sol';

import {ICLFactory} from '../interfaces/ICLFactory.sol';
import {IERC20Minimal} from '../interfaces/IERC20Minimal.sol';
import {IFactoryRegistry} from '../interfaces/IFactoryRegistry.sol';
import {ICLFlashCallback} from '../interfaces/callback/ICLFlashCallback.sol';
import {ICLMintCallback} from '../interfaces/callback/ICLMintCallback.sol';
import {ISwapHook} from '../interfaces/hook/ISwapHook.sol';

import {CLPool} from '../CLPool.sol';

/// @notice Externally linked implementations of non-swap CLPool paths.
/// @dev CLPool keeps its public entry points and delegates only the function bodies declared here.
library CLPoolNonSwapPath {
  using LowGasSafeMath for uint256;
  using SafeCast for int256;
  using Tick for mapping(int24 => Tick.Info);
  using TickBitmap for mapping(int16 => uint256);
  using Position for mapping(bytes32 => Position.Info);
  using Position for Position.Info;
  using Oracle for Oracle.Observation[65_535];
  using SwapHookLib for address;

  event Initialize(uint160 sqrtPriceX96, int24 tick);
  event IncreaseObservationCardinalityNext(uint16 observationCardinalityNextOld, uint16 observationCardinalityNextNew);
  event Flash(
    address indexed sender, address indexed recipient, uint256 amount0, uint256 amount1, uint256 paid0, uint256 paid1
  );
  event Mint(
    address sender,
    address indexed owner,
    int24 indexed tickLower,
    int24 indexed tickUpper,
    uint128 amount,
    uint256 amount0,
    uint256 amount1
  );
  event Burn(
    address indexed owner,
    int24 indexed tickLower,
    int24 indexed tickUpper,
    uint128 amount,
    uint256 amount0,
    uint256 amount1
  );
  event Collect(
    address indexed owner,
    address recipient,
    int24 indexed tickLower,
    int24 indexed tickUpper,
    uint128 amount0,
    uint128 amount1
  );
  event CollectFees(address indexed recipient, uint128 amount0, uint128 amount1);

  struct FlashInput {
    address token0;
    address token1;
    address factory;
    int24 tickSpacing;
    uint128 liquidity;
    uint128 stakedLiquidity;
    address recipient;
    uint256 amount0;
    uint256 amount1;
  }

  struct ModifyPositionInput {
    address owner;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint128 maxLiquidityPerTick;
    uint256 feeGrowthGlobal0X128;
    uint256 feeGrowthGlobal1X128;
    uint256 rewardGrowthGlobalX128;
    address gauge;
    int24 tickSpacing;
    uint128 amount;
  }

  struct PositionObservation {
    int56 tickCumulative;
    uint160 secondsPerLiquidityCumulativeX128;
    int24 currentTick;
    int128 liquidityDelta;
  }

  struct StakeInput {
    address nft;
    int24 tickLower;
    int24 tickUpper;
    int24 tick;
    int128 stakedLiquidityDelta;
    uint256 feeGrowthGlobal0X128;
    uint256 feeGrowthGlobal1X128;
  }

  struct SnapshotInput {
    int24 tickLower;
    int24 tickUpper;
    int24 tick;
    uint16 observationIndex;
    uint16 observationCardinality;
    uint128 liquidity;
  }

  function initializeSlot0(
    CLPool.Slot0 storage slot0,
    Oracle.Observation[65_535] storage observations,
    uint160 sqrtPriceX96,
    int24 tick,
    int24 tickSpacing
  ) external returns (uint128 maxLiquidityPerTick) {
    (uint16 cardinality, uint16 cardinalityNext) = observations.initialize(uint32(block.timestamp));

    slot0.sqrtPriceX96 = sqrtPriceX96;
    slot0.tick = tick;
    slot0.observationIndex = 0;
    slot0.observationCardinality = cardinality;
    slot0.observationCardinalityNext = cardinalityNext;
    slot0.unlocked = true;

    emit Initialize(sqrtPriceX96, tick);
    return Tick.tickSpacingToMaxLiquidityPerTick(tickSpacing);
  }

  function flashFee(
    ISwapHook.FlashParams memory flashParams,
    address factory,
    int24 tickSpacing
  ) external view returns (uint24) {
    address pool = address(this);
    return ICLFactory(factory).getPoolSwapHook(pool).getFlashFee(pool, flashParams, factory, tickSpacing);
  }

  function beforeSwapFee(
    ISwapHook.SwapParams memory swapParams,
    address factory,
    int24 tickSpacing
  ) external view returns (uint24) {
    address pool = address(this);
    return ICLFactory(factory).getPoolSwapHook(pool).getBeforeSwapFee(pool, swapParams, factory, tickSpacing);
  }

  function afterSwapFee(
    ISwapHook.SwapParams memory swapParams,
    ISwapHook.AfterSwapParams memory afterSwapParams,
    address factory
  ) external view returns (uint24) {
    address pool = address(this);
    return ICLFactory(factory).getPoolSwapHook(pool).getAfterSwapFee(pool, swapParams, afterSwapParams);
  }

  function stakePositions(
    mapping(bytes32 => Position.Info) storage positions,
    mapping(int24 => Tick.Info) storage ticks,
    address nft,
    int24 tickLower,
    int24 tickUpper,
    int24 tick,
    int128 stakedLiquidityDelta,
    uint256 feeGrowthGlobal0X128,
    uint256 feeGrowthGlobal1X128
  ) external {
    _stakePositions(
      positions,
      ticks,
      StakeInput({
        nft: nft,
        tickLower: tickLower,
        tickUpper: tickUpper,
        tick: tick,
        stakedLiquidityDelta: stakedLiquidityDelta,
        feeGrowthGlobal0X128: feeGrowthGlobal0X128,
        feeGrowthGlobal1X128: feeGrowthGlobal1X128
      })
    );
  }

  function _stakePositions(
    mapping(bytes32 => Position.Info) storage positions,
    mapping(int24 => Tick.Info) storage ticks,
    StakeInput memory input
  ) private {
    Position.Info storage nftPosition = positions.get(input.nft, input.tickLower, input.tickUpper);
    Position.Info storage gaugePosition = positions.get(msg.sender, input.tickLower, input.tickUpper);
    (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = ticks.getFeeGrowthInside(
      input.tickLower, input.tickUpper, input.tick, input.feeGrowthGlobal0X128, input.feeGrowthGlobal1X128
    );
    nftPosition.update(-input.stakedLiquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128, false);
    gaugePosition.update(input.stakedLiquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128, true);
    if (ticks[input.tickLower].initialized) ticks.updateStake(input.tickLower, input.stakedLiquidityDelta, false);
    if (ticks[input.tickUpper].initialized) ticks.updateStake(input.tickUpper, input.stakedLiquidityDelta, true);
  }

  function snapshotCumulativesInside(
    mapping(int24 => Tick.Info) storage ticks,
    Oracle.Observation[65_535] storage observations,
    int24 tickLower,
    int24 tickUpper,
    int24 tick,
    uint16 observationIndex,
    uint16 observationCardinality,
    uint128 liquidity
  ) external view returns (int56 tickCumulativeInside, uint160 secondsPerLiquidityInsideX128, uint32 secondsInside) {
    return _snapshotCumulativesInside(
      ticks,
      observations,
      SnapshotInput({
        tickLower: tickLower,
        tickUpper: tickUpper,
        tick: tick,
        observationIndex: observationIndex,
        observationCardinality: observationCardinality,
        liquidity: liquidity
      })
    );
  }

  function _snapshotCumulativesInside(
    mapping(int24 => Tick.Info) storage ticks,
    Oracle.Observation[65_535] storage observations,
    SnapshotInput memory input
  ) private view returns (int56 tickCumulativeInside, uint160 secondsPerLiquidityInsideX128, uint32 secondsInside) {
    _checkTicks(input.tickLower, input.tickUpper);
    Tick.Info storage lower = ticks[input.tickLower];
    Tick.Info storage upper = ticks[input.tickUpper];
    require(lower.initialized);
    require(upper.initialized);

    if (input.tick < input.tickLower) {
      return (
        lower.tickCumulativeOutside - upper.tickCumulativeOutside,
        lower.secondsPerLiquidityOutsideX128 - upper.secondsPerLiquidityOutsideX128,
        lower.secondsOutside - upper.secondsOutside
      );
    }
    if (input.tick >= input.tickUpper) {
      return (
        upper.tickCumulativeOutside - lower.tickCumulativeOutside,
        upper.secondsPerLiquidityOutsideX128 - lower.secondsPerLiquidityOutsideX128,
        upper.secondsOutside - lower.secondsOutside
      );
    }
    (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) = observations.observeSingle(
      uint32(block.timestamp), 0, input.tick, input.observationIndex, input.liquidity, input.observationCardinality
    );
    return (
      tickCumulative - lower.tickCumulativeOutside - upper.tickCumulativeOutside,
      secondsPerLiquidityCumulativeX128 - lower.secondsPerLiquidityOutsideX128 - upper.secondsPerLiquidityOutsideX128,
      uint32(block.timestamp) - lower.secondsOutside - upper.secondsOutside
    );
  }

  function getFeeGrowthInside(
    mapping(int24 => Tick.Info) storage ticks,
    int24 tickLower,
    int24 tickUpper,
    int24 tickCurrent,
    uint256 feeGrowthGlobal0X128,
    uint256 feeGrowthGlobal1X128
  ) external view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
    _checkTicks(tickLower, tickUpper);
    return ticks.getFeeGrowthInside(tickLower, tickUpper, tickCurrent, feeGrowthGlobal0X128, feeGrowthGlobal1X128);
  }

  function getRewardGrowthInside(
    mapping(int24 => Tick.Info) storage ticks,
    int24 tickLower,
    int24 tickUpper,
    int24 tickCurrent,
    uint256 rewardGrowthGlobalX128,
    uint256 storedRewardGrowthGlobalX128
  ) external view returns (uint256 rewardGrowthInsideX128) {
    _checkTicks(tickLower, tickUpper);
    if (rewardGrowthGlobalX128 == 0) rewardGrowthGlobalX128 = storedRewardGrowthGlobalX128;
    return ticks.getRewardGrowthInside(tickLower, tickUpper, tickCurrent, rewardGrowthGlobalX128);
  }

  function increaseObservationCardinalityNext(
    Oracle.Observation[65_535] storage observations,
    CLPool.Slot0 storage slot0,
    uint16 observationCardinalityNext
  ) external {
    uint16 observationCardinalityNextOld = slot0.observationCardinalityNext;
    uint16 observationCardinalityNextNew = observations.grow(observationCardinalityNextOld, observationCardinalityNext);
    slot0.observationCardinalityNext = observationCardinalityNextNew;
    if (observationCardinalityNextOld != observationCardinalityNextNew) {
      emit IncreaseObservationCardinalityNext(observationCardinalityNextOld, observationCardinalityNextNew);
    }
  }

  function _checkTicks(int24 tickLower, int24 tickUpper) private pure {
    require(tickLower < tickUpper, 'TLU');
    require(tickLower >= TickMath.MIN_TICK, 'TLM');
    require(tickUpper <= TickMath.MAX_TICK, 'TUM');
  }

  function modifyPositionForMint(
    mapping(bytes32 => Position.Info) storage positions,
    mapping(int24 => Tick.Info) storage ticks,
    mapping(int16 => uint256) storage tickBitmap,
    Oracle.Observation[65_535] storage observations,
    CLPool.Slot0 storage slot0,
    ModifyPositionInput memory input
  ) external returns (uint128 liquidityAfter, uint256 amount0, uint256 amount1) {
    require(input.amount > 0);

    int256 amount0Int;
    int256 amount1Int;
    (liquidityAfter, amount0Int, amount1Int) =
      _modifyPosition(positions, ticks, tickBitmap, observations, slot0, input, int256(input.amount).toInt128());

    amount0 = uint256(amount0Int);
    amount1 = uint256(amount1Int);
  }

  function settleMint(
    ModifyPositionInput memory input,
    uint256 amount0,
    uint256 amount1,
    address token0,
    address token1,
    bytes calldata data
  ) external {
    uint256 balance0Before;
    uint256 balance1Before;
    if (amount0 > 0) balance0Before = _balance(token0);
    if (amount1 > 0) balance1Before = _balance(token1);
    ICLMintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);
    if (amount0 > 0) require(balance0Before.add(amount0) <= _balance(token0), 'M0');
    if (amount1 > 0) require(balance1Before.add(amount1) <= _balance(token1), 'M1');

    emit Mint(msg.sender, input.owner, input.tickLower, input.tickUpper, input.amount, amount0, amount1);
  }

  function burn(
    mapping(bytes32 => Position.Info) storage positions,
    mapping(int24 => Tick.Info) storage ticks,
    mapping(int16 => uint256) storage tickBitmap,
    Oracle.Observation[65_535] storage observations,
    CLPool.Slot0 storage slot0,
    ModifyPositionInput memory input
  ) external returns (uint128 liquidityAfter, uint256 amount0, uint256 amount1) {
    int256 amount0Int;
    int256 amount1Int;
    (liquidityAfter, amount0Int, amount1Int) =
      _modifyPosition(positions, ticks, tickBitmap, observations, slot0, input, -int256(input.amount).toInt128());

    amount0 = uint256(-amount0Int);
    amount1 = uint256(-amount1Int);

    if (amount0 > 0 || amount1 > 0) {
      _creditBurnedTokens(positions, input, uint128(amount0), uint128(amount1));
    }

    emit Burn(input.owner, input.tickLower, input.tickUpper, input.amount, amount0, amount1);
  }

  function _creditBurnedTokens(
    mapping(bytes32 => Position.Info) storage positions,
    ModifyPositionInput memory input,
    uint128 amount0,
    uint128 amount1
  ) private {
    Position.Info storage position = positions.get(input.owner, input.tickLower, input.tickUpper);
    (position.tokensOwed0, position.tokensOwed1) = (position.tokensOwed0 + amount0, position.tokensOwed1 + amount1);
  }

  function collect(
    mapping(bytes32 => Position.Info) storage positions,
    address recipient,
    int24 tickLower,
    int24 tickUpper,
    uint128 amount0Requested,
    uint128 amount1Requested,
    address owner,
    address token0,
    address token1
  ) external returns (uint128 amount0, uint128 amount1) {
    Position.Info storage position = positions.get(owner, tickLower, tickUpper);
    amount0 = amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : amount0Requested;
    amount1 = amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : amount1Requested;
    if (amount0 > 0) {
      position.tokensOwed0 -= amount0;
      TransferHelper.safeTransfer(token0, recipient, amount0);
    }
    if (amount1 > 0) {
      position.tokensOwed1 -= amount1;
      TransferHelper.safeTransfer(token1, recipient, amount1);
    }
    emit Collect(owner, recipient, tickLower, tickUpper, amount0, amount1);
  }

  function collectFees(
    CLPool.GaugeFees storage gaugeFees,
    address recipient,
    address token0,
    address token1
  ) external returns (uint128 amount0, uint128 amount1) {
    amount0 = gaugeFees.token0;
    amount1 = gaugeFees.token1;
    if (amount0 > 1) {
      gaugeFees.token0 = 1;
      TransferHelper.safeTransfer(token0, recipient, --amount0);
    } else {
      amount0 = 0;
    }
    if (amount1 > 1) {
      gaugeFees.token1 = 1;
      TransferHelper.safeTransfer(token1, recipient, --amount1);
    } else {
      amount1 = 0;
    }
    emit CollectFees(recipient, amount0, amount1);
  }

  function _modifyPosition(
    mapping(bytes32 => Position.Info) storage positions,
    mapping(int24 => Tick.Info) storage ticks,
    mapping(int16 => uint256) storage tickBitmap,
    Oracle.Observation[65_535] storage observations,
    CLPool.Slot0 storage slot0,
    ModifyPositionInput memory input,
    int128 liquidityDelta
  ) private returns (uint128 liquidityAfter, int256 amount0, int256 amount1) {
    _checkTicks(input.tickLower, input.tickUpper);

    CLPool.Slot0 memory currentSlot0 = slot0;
    _updatePosition(positions, ticks, tickBitmap, observations, currentSlot0, input, liquidityDelta);

    liquidityAfter = input.liquidity;
    if (liquidityDelta != 0) {
      if (currentSlot0.tick < input.tickLower) {
        amount0 = SqrtPriceMath.getAmount0Delta(
          TickMath.getSqrtRatioAtTick(input.tickLower), TickMath.getSqrtRatioAtTick(input.tickUpper), liquidityDelta
        );
      } else if (currentSlot0.tick < input.tickUpper) {
        (slot0.observationIndex, slot0.observationCardinality) = observations.write(
          currentSlot0.observationIndex,
          uint32(block.timestamp),
          currentSlot0.tick,
          input.liquidity,
          currentSlot0.observationCardinality,
          currentSlot0.observationCardinalityNext
        );

        amount0 = SqrtPriceMath.getAmount0Delta(
          currentSlot0.sqrtPriceX96, TickMath.getSqrtRatioAtTick(input.tickUpper), liquidityDelta
        );
        amount1 = SqrtPriceMath.getAmount1Delta(
          TickMath.getSqrtRatioAtTick(input.tickLower), currentSlot0.sqrtPriceX96, liquidityDelta
        );

        liquidityAfter = LiquidityMath.addDelta(input.liquidity, liquidityDelta);
      } else {
        amount1 = SqrtPriceMath.getAmount1Delta(
          TickMath.getSqrtRatioAtTick(input.tickLower), TickMath.getSqrtRatioAtTick(input.tickUpper), liquidityDelta
        );
      }
    }
  }

  function _updatePosition(
    mapping(bytes32 => Position.Info) storage positions,
    mapping(int24 => Tick.Info) storage ticks,
    mapping(int16 => uint256) storage tickBitmap,
    Oracle.Observation[65_535] storage observations,
    CLPool.Slot0 memory currentSlot0,
    ModifyPositionInput memory input,
    int128 liquidityDelta
  ) private {
    bool flippedLower;
    bool flippedUpper;
    if (liquidityDelta != 0) {
      PositionObservation memory observation;
      observation.currentTick = currentSlot0.tick;
      observation.liquidityDelta = liquidityDelta;
      (observation.tickCumulative, observation.secondsPerLiquidityCumulativeX128) = observations.observeSingle(
        uint32(block.timestamp),
        0,
        currentSlot0.tick,
        currentSlot0.observationIndex,
        input.liquidity,
        currentSlot0.observationCardinality
      );

      flippedLower = _updateLowerTick(ticks, input, observation);
      flippedUpper = _updateUpperTick(ticks, input, observation);

      if (flippedLower) tickBitmap.flipTick(input.tickLower, input.tickSpacing);
      if (flippedUpper) tickBitmap.flipTick(input.tickUpper, input.tickSpacing);
    }

    (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = ticks.getFeeGrowthInside(
      input.tickLower, input.tickUpper, currentSlot0.tick, input.feeGrowthGlobal0X128, input.feeGrowthGlobal1X128
    );

    Position.Info storage position = positions.get(input.owner, input.tickLower, input.tickUpper);
    bool staked = (input.owner == input.gauge) && (input.owner != address(0));
    position.update(liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128, staked);

    if (liquidityDelta < 0) {
      if (flippedLower) ticks.clear(input.tickLower);
      if (flippedUpper) ticks.clear(input.tickUpper);
    }
  }

  function _updateLowerTick(
    mapping(int24 => Tick.Info) storage ticks,
    ModifyPositionInput memory input,
    PositionObservation memory observation
  ) private returns (bool) {
    return ticks.update(
      input.tickLower,
      observation.currentTick,
      observation.liquidityDelta,
      input.feeGrowthGlobal0X128,
      input.feeGrowthGlobal1X128,
      input.rewardGrowthGlobalX128,
      observation.secondsPerLiquidityCumulativeX128,
      observation.tickCumulative,
      uint32(block.timestamp),
      false,
      input.maxLiquidityPerTick
    );
  }

  function _updateUpperTick(
    mapping(int24 => Tick.Info) storage ticks,
    ModifyPositionInput memory input,
    PositionObservation memory observation
  ) private returns (bool) {
    return ticks.update(
      input.tickUpper,
      observation.currentTick,
      observation.liquidityDelta,
      input.feeGrowthGlobal0X128,
      input.feeGrowthGlobal1X128,
      input.rewardGrowthGlobalX128,
      observation.secondsPerLiquidityCumulativeX128,
      observation.tickCumulative,
      uint32(block.timestamp),
      true,
      input.maxLiquidityPerTick
    );
  }

  function validateGaugeFactory(address factoryRegistry, address factory) external view {
    address gaugeFactory = IFactoryRegistry(factoryRegistry).targetFactoryToGaugeFactory(factory);
    require(msg.sender == gaugeFactory, 'NGF');
  }

  function flash(
    CLPool.GaugeFees storage gaugeFees,
    FlashInput memory input,
    bytes calldata data
  ) external returns (uint256 feeGrowthDelta0, uint256 feeGrowthDelta1) {
    require(input.liquidity > 0, 'L');

    (uint256 fee0, uint256 fee1) = _flashFees(input, data);
    uint256 balance0Before = _balance(input.token0);
    uint256 balance1Before = _balance(input.token1);

    if (input.amount0 > 0) TransferHelper.safeTransfer(input.token0, input.recipient, input.amount0);
    if (input.amount1 > 0) TransferHelper.safeTransfer(input.token1, input.recipient, input.amount1);

    ICLFlashCallback(msg.sender).uniswapV3FlashCallback(fee0, fee1, data);

    uint256 paid0 = _paid(input.token0, balance0Before, fee0, 'F0');
    uint256 paid1 = _paid(input.token1, balance1Before, fee1, 'F1');

    feeGrowthDelta0 = _accrueGaugeFee(gaugeFees, input, paid0, true);
    feeGrowthDelta1 = _accrueGaugeFee(gaugeFees, input, paid1, false);

    emit Flash(msg.sender, input.recipient, input.amount0, input.amount1, paid0, paid1);
  }

  function _flashFees(FlashInput memory input, bytes memory data) private returns (uint256 fee0, uint256 fee1) {
    uint24 feePips = ICLFactory(input.factory)
      .getPoolSwapHook(address(this))
      .beforeFlash(
        ISwapHook.FlashParams({
          caller: msg.sender, recipient: input.recipient, amount0: input.amount0, amount1: input.amount1, data: data
        }),
        input.factory,
        input.tickSpacing
      );
    fee0 = FullMath.mulDivRoundingUp(input.amount0, feePips, SwapHookLib._DENOMINATOR);
    fee1 = FullMath.mulDivRoundingUp(input.amount1, feePips, SwapHookLib._DENOMINATOR);
  }

  function _balance(address token) private view returns (uint256) {
    (bool success, bytes memory data) =
      token.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
    require(success && data.length >= 32);
    return abi.decode(data, (uint256));
  }

  function _paid(
    address token,
    uint256 balanceBefore,
    uint256 fee,
    string memory error
  ) private view returns (uint256) {
    uint256 balanceAfter = _balance(token);
    require(balanceBefore.add(fee) <= balanceAfter, error);
    return balanceAfter - balanceBefore;
  }

  function _accrueGaugeFee(
    CLPool.GaugeFees storage gaugeFees,
    FlashInput memory input,
    uint256 paid,
    bool zeroForOne
  ) private returns (uint256 feeGrowthDelta) {
    if (paid == 0) return 0;

    uint256 stakedFeeAmount;
    (feeGrowthDelta, stakedFeeAmount) = _calculateFees(paid, input.liquidity, input.stakedLiquidity, input.factory);
    if (uint128(stakedFeeAmount) > 0) {
      if (zeroForOne) gaugeFees.token0 += uint128(stakedFeeAmount);
      else gaugeFees.token1 += uint128(stakedFeeAmount);
    }
  }

  function _calculateFees(
    uint256 feeAmount,
    uint128 liquidity,
    uint128 stakedLiquidity,
    address factory
  ) private view returns (uint256 feeGrowthGlobalX128, uint256 stakedFeeAmount) {
    if (liquidity == stakedLiquidity) {
      stakedFeeAmount = feeAmount;
    } else if (stakedLiquidity == 0) {
      (uint256 unstakedFeeAmount, uint256 stakedFee) = _applyUnstakedFees(feeAmount, 0, factory);
      feeGrowthGlobalX128 = FullMath.mulDiv(unstakedFeeAmount, FixedPoint128.Q128, liquidity);
      stakedFeeAmount = stakedFee;
    } else {
      (uint256 unstakedFeeAmount, uint256 stakedFee) = _splitFees(feeAmount, liquidity, stakedLiquidity, factory);
      feeGrowthGlobalX128 = FullMath.mulDiv(unstakedFeeAmount, FixedPoint128.Q128, liquidity - stakedLiquidity);
      stakedFeeAmount = stakedFee;
    }
  }

  function _splitFees(
    uint256 feeAmount,
    uint128 liquidity,
    uint128 stakedLiquidity,
    address factory
  ) private view returns (uint256 unstakedFeeAmount, uint256 stakedFeeAmount) {
    stakedFeeAmount = FullMath.mulDivRoundingUp(feeAmount, stakedLiquidity, liquidity);
    return _applyUnstakedFees(feeAmount - stakedFeeAmount, stakedFeeAmount, factory);
  }

  function _applyUnstakedFees(
    uint256 unstakedFeeAmount,
    uint256 stakedFeeAmount,
    address factory
  ) private view returns (uint256, uint256) {
    uint256 stakedFee = FullMath.mulDivRoundingUp(
      unstakedFeeAmount, ICLFactory(factory).getUnstakedFee(address(this)), 1_000_000
    );
    return (unstakedFeeAmount - stakedFee, stakedFeeAmount + stakedFee);
  }
}
