// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import './interfaces/ICLPool.sol';

import './libraries/LowGasSafeMath.sol';
import './libraries/Oracle.sol';
import './libraries/Position.sol';
import './libraries/SafeCast.sol';
import './libraries/Tick.sol';
import './libraries/TickBitmap.sol';

import {CLPoolNonSwapPath as CL} from './libraries/CLPoolNonSwapPath.sol';
import './libraries/FixedPoint128.sol';
import './libraries/FullMath.sol';
import './libraries/LiquidityMath.sol';
import './libraries/SwapMath.sol';
import './libraries/TickMath.sol';
import './libraries/TransferHelper.sol';
import './libraries/hook/SwapHookLib.sol';

import './interfaces/ICLFactory.sol';
import './interfaces/IERC20Minimal.sol';
import './interfaces/IFactoryRegistry.sol';
import './interfaces/callback/ICLSwapCallback.sol';
import './interfaces/hook/ISwapHook.sol';
import {ICLGauge} from 'contracts/gauge/interfaces/ICLGauge.sol';

contract CLPool is ICLPool {
  using LowGasSafeMath for uint256;
  using LowGasSafeMath for int256;
  using SafeCast for uint256;
  using SafeCast for int256;
  using Tick for mapping(int24 => Tick.Info);
  using TickBitmap for mapping(int16 => uint256);
  using Position for mapping(bytes32 => Position.Info);
  using Position for Position.Info;
  using Oracle for Oracle.Observation[65_535];
  using SwapHookLib for address;

  /// @inheritdoc ICLPoolConstants
  address public override factory;
  /// @inheritdoc ICLPoolConstants
  address public override token0;
  /// @inheritdoc ICLPoolConstants
  address public override token1;
  /// @inheritdoc ICLPoolConstants
  address public override gauge;
  /// @inheritdoc ICLPoolConstants
  address public override nft;
  /// @inheritdoc ICLPoolConstants
  address public override factoryRegistry;

  struct Slot0 {
    // the current price
    uint160 sqrtPriceX96;
    // the current tick
    int24 tick;
    // the most-recently updated index of the observations array
    uint16 observationIndex;
    // the current maximum number of observations that are being stored
    uint16 observationCardinality;
    // the next maximum number of observations to store, triggered in observations.write
    uint16 observationCardinalityNext;
    // whether the pool is locked
    bool unlocked;
  }

  /// @inheritdoc ICLPoolState
  Slot0 public override slot0;

  /// @inheritdoc ICLPoolState
  uint256 public override feeGrowthGlobal0X128;
  /// @inheritdoc ICLPoolState
  uint256 public override feeGrowthGlobal1X128;

  /// @inheritdoc ICLPoolState
  uint256 public override rewardGrowthGlobalX128;

  // accumulated gauge fees in token0/token1 units
  struct GaugeFees {
    uint128 token0;
    uint128 token1;
  }

  /// @inheritdoc ICLPoolState
  GaugeFees public override gaugeFees;

  /// @inheritdoc ICLPoolState
  uint256 public override rollover;

  /// @inheritdoc ICLPoolState
  uint128 public override stakedLiquidity;
  /// @inheritdoc ICLPoolState
  uint48 public override lastUpdated;
  /// @inheritdoc ICLPoolConstants
  int24 public override tickSpacing;

  /// @inheritdoc ICLPoolState
  uint128 public override liquidity;
  /// @inheritdoc ICLPoolConstants
  uint128 public override maxLiquidityPerTick;

  /// @inheritdoc ICLPoolState
  mapping(int24 => Tick.Info) public override ticks;
  /// @inheritdoc ICLPoolState
  mapping(int16 => uint256) public override tickBitmap;
  /// @inheritdoc ICLPoolState
  mapping(bytes32 => Position.Info) public override positions;
  /// @inheritdoc ICLPoolState
  Oracle.Observation[65_535] public override observations;

  /// @inheritdoc ICLPoolState
  uint160 public override secondsPerStakedLiquidityCumulativeX128;

  /// @inheritdoc ICLPoolConstants
  uint256 public constant override SWAP_FEE_CEIL = 100_000;
  /// @inheritdoc ICLPoolConstants
  uint256 public constant override DENOMINATOR = 1_000_000;
  /// @inheritdoc ICLPoolConstants
  bytes32 public constant override POOL_TYPE = 'CL';

  /// @dev Mutually exclusive reentrancy protection into the pool to/from a method. This method also prevents entrance
  /// to a function before the pool is initialized. The reentrancy guard is required throughout the contract because
  /// we use balance checks to determine the payment status of interactions such as mint, swap and flash.
  function _lock() private {
    _require(slot0.unlocked, 'LOK');
    slot0.unlocked = false;
  }

  function _unlock() private {
    slot0.unlocked = true;
  }

  function _require(bool condition, string memory error) private pure {
    require(condition, error);
  }

  /// @dev Prevents calling a function from anyone except the gauge associated with this pool
  function _onlyGauge() private view {
    _require(msg.sender == gauge, 'NG');
  }

  /// @dev Prevents calling a function from anyone except the nft manager
  function _onlyNftManager() private view {
    _require(msg.sender == nft, 'NNFT');
  }

  /// @inheritdoc ICLPoolActions
  function initialize(
    address _factory,
    address _token0,
    address _token1,
    int24 _tickSpacing,
    address _factoryRegistry,
    uint160 _sqrtPriceX96
  ) external override {
    require(factory == address(0) && _factory != address(0));
    factory = _factory;
    token0 = _token0;
    token1 = _token1;
    tickSpacing = _tickSpacing;
    factoryRegistry = _factoryRegistry;

    maxLiquidityPerTick =
      CL.initializeSlot0(slot0, observations, _sqrtPriceX96, TickMath.getTickAtSqrtRatio(_sqrtPriceX96), _tickSpacing);
  }

  /// @inheritdoc ICLPoolState
  function beforeSwapFee(ISwapHook.SwapParams memory _swapParams) public view override returns (uint24) {
    return CL.beforeSwapFee(_swapParams, factory, tickSpacing);
  }

  /// @inheritdoc ICLPoolState
  function afterSwapFee(
    ISwapHook.SwapParams memory _swapParams,
    ISwapHook.AfterSwapParams memory _afterSwapParams
  ) external view override returns (uint24) {
    return CL.afterSwapFee(_swapParams, _afterSwapParams, factory);
  }

  /// @inheritdoc ICLPoolState
  function flashFee(ISwapHook.FlashParams memory _flashParams) external view override returns (uint24 _fee) {
    return CL.flashFee(_flashParams, factory, tickSpacing);
  }

  /// @inheritdoc ICLPoolState
  /// @dev This method can be used for "legacy" swap fee modules.
  function fee() external view override returns (uint24) {
    ISwapHook.SwapParams memory _swapParams;
    _swapParams.caller = msg.sender;
    return beforeSwapFee(_swapParams);
  }

  /// @inheritdoc ICLPoolState
  function unstakedFee() public view override returns (uint24) {
    return ICLFactory(factory).getUnstakedFee(address(this));
  }

  /// @dev Common checks for valid tick inputs.
  function checkTicks(int24 tickLower, int24 tickUpper) private pure {
    require(tickLower < tickUpper, 'TLU');
    require(tickLower >= TickMath.MIN_TICK, 'TLM');
    require(tickUpper <= TickMath.MAX_TICK, 'TUM');
  }

  /// @dev Get the pool's balance of token0
  /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
  /// check
  function balance0() private view returns (uint256) {
    return IERC20Minimal(token0).balanceOf(address(this));
  }

  /// @dev Get the pool's balance of token1
  /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
  /// check
  function balance1() private view returns (uint256) {
    return IERC20Minimal(token1).balanceOf(address(this));
  }

  /// @inheritdoc ICLPoolDerivedState
  function snapshotCumulativesInside(
    int24 tickLower,
    int24 tickUpper
  )
    external
    view
    override
    returns (int56 tickCumulativeInside, uint160 secondsPerLiquidityInsideX128, uint32 secondsInside)
  {
    Slot0 memory currentSlot0 = slot0;
    return CL.snapshotCumulativesInside(
      ticks,
      observations,
      tickLower,
      tickUpper,
      currentSlot0.tick,
      currentSlot0.observationIndex,
      currentSlot0.observationCardinality,
      liquidity
    );
  }

  /// @inheritdoc ICLPoolDerivedState
  function observe(uint32[] calldata secondsAgos)
    external
    view
    override
    returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
  {
    return observations.observe(
      uint32(block.timestamp), secondsAgos, slot0.tick, slot0.observationIndex, liquidity, slot0.observationCardinality
    );
  }

  /// @inheritdoc ICLPoolDerivedState
  function getSecondsPerStakedLiquidityCumulativeX128() external view override returns (uint160 _cumulative) {
    _cumulative = secondsPerStakedLiquidityCumulativeX128;
    uint128 _stakedLiquidity = stakedLiquidity;
    if (_stakedLiquidity > 0) {
      _cumulative += _secondsPerStakedLiquidityDelta(block.timestamp - lastUpdated, _stakedLiquidity);
    }
  }

  /// @inheritdoc ICLPoolActions
  function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external override {
    _lock();
    CL.increaseObservationCardinalityNext(observations, slot0, observationCardinalityNext);
    _unlock();
  }

  /// @inheritdoc ICLPoolState
  function getFeeGrowthInside(
    int24 tickLower,
    int24 tickUpper
  ) external view override returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
    return CL.getFeeGrowthInside(ticks, tickLower, tickUpper, slot0.tick, feeGrowthGlobal0X128, feeGrowthGlobal1X128);
  }

  function _modifyPositionInput(
    address owner,
    int24 tickLower,
    int24 tickUpper
  ) private view returns (CL.ModifyPositionInput memory input) {
    input = CL.ModifyPositionInput({
      owner: owner,
      tickLower: tickLower,
      tickUpper: tickUpper,
      liquidity: liquidity,
      maxLiquidityPerTick: maxLiquidityPerTick,
      feeGrowthGlobal0X128: feeGrowthGlobal0X128,
      feeGrowthGlobal1X128: feeGrowthGlobal1X128,
      rewardGrowthGlobalX128: rewardGrowthGlobalX128,
      gauge: gauge,
      tickSpacing: tickSpacing,
      amount: 0
    });
  }

  /// @inheritdoc ICLPoolActions
  function mint(
    address recipient,
    int24 tickLower,
    int24 tickUpper,
    uint128 amount,
    bytes calldata data
  ) external override returns (uint256 amount0, uint256 amount1) {
    _lock();
    CL.ModifyPositionInput memory input = _modifyPositionInput(recipient, tickLower, tickUpper);
    input.amount = amount;
    (uint128 liquidityAfter, uint256 amount0Out, uint256 amount1Out) =
      CL.modifyPositionForMint(positions, ticks, tickBitmap, observations, slot0, input);
    liquidity = liquidityAfter;
    CL.settleMint(input, amount0Out, amount1Out, token0, token1, data);
    _unlock();
    return (amount0Out, amount1Out);
  }

  /// @inheritdoc ICLPoolActions
  function collect(
    address recipient,
    int24 tickLower,
    int24 tickUpper,
    uint128 amount0Requested,
    uint128 amount1Requested
  ) external override returns (uint128 amount0, uint128 amount1) {
    _lock();
    (amount0, amount1) = _collect({
      recipient: recipient,
      tickLower: tickLower,
      tickUpper: tickUpper,
      amount0Requested: amount0Requested,
      amount1Requested: amount1Requested,
      owner: msg.sender
    });
    _unlock();
  }

  /// @inheritdoc ICLPoolActions
  function collect(
    address recipient,
    int24 tickLower,
    int24 tickUpper,
    uint128 amount0Requested,
    uint128 amount1Requested,
    address owner
  ) external override returns (uint128 amount0, uint128 amount1) {
    _lock();
    _onlyNftManager();
    (amount0, amount1) = _collect({
      recipient: recipient,
      tickLower: tickLower,
      tickUpper: tickUpper,
      amount0Requested: amount0Requested,
      amount1Requested: amount1Requested,
      owner: owner
    });
    _unlock();
  }

  function _collect(
    address recipient,
    int24 tickLower,
    int24 tickUpper,
    uint128 amount0Requested,
    uint128 amount1Requested,
    address owner
  ) private returns (uint128 amount0, uint128 amount1) {
    return CL.collect(
      positions, recipient, tickLower, tickUpper, amount0Requested, amount1Requested, owner, token0, token1
    );
  }

  /// @inheritdoc ICLPoolActions
  function burn(
    int24 tickLower,
    int24 tickUpper,
    uint128 amount
  ) external override returns (uint256 amount0, uint256 amount1) {
    _lock();
    (amount0, amount1) = _burn({tickLower: tickLower, tickUpper: tickUpper, amount: amount, owner: msg.sender});
    _unlock();
  }

  /// @inheritdoc ICLPoolActions
  function burn(
    int24 tickLower,
    int24 tickUpper,
    uint128 amount,
    address owner
  ) external override returns (uint256 amount0, uint256 amount1) {
    _lock();
    _onlyNftManager();
    (amount0, amount1) = _burn({tickLower: tickLower, tickUpper: tickUpper, amount: amount, owner: owner});
    _unlock();
  }

  function _burn(
    int24 tickLower,
    int24 tickUpper,
    uint128 amount,
    address owner
  ) private returns (uint256 amount0, uint256 amount1) {
    CL.ModifyPositionInput memory input = _modifyPositionInput(owner, tickLower, tickUpper);
    input.amount = amount;
    (uint128 liquidityAfter, uint256 amount0Out, uint256 amount1Out) =
      CL.burn(positions, ticks, tickBitmap, observations, slot0, input);
    liquidity = liquidityAfter;
    return (amount0Out, amount1Out);
  }

  /// @inheritdoc ICLPoolActions
  function stake(int128 stakedLiquidityDelta, int24 tickLower, int24 tickUpper) external override {
    _lock();
    _onlyGauge();
    int24 tick = slot0.tick;
    // Increase staked liquidity in the current tick
    if (tick >= tickLower && tick < tickUpper) {
      _settleToBlock();
      stakedLiquidity = LiquidityMath.addDelta(stakedLiquidity, stakedLiquidityDelta);
    }

    CL.stakePositions(
      positions,
      ticks,
      nft,
      tickLower,
      tickUpper,
      tick,
      stakedLiquidityDelta,
      feeGrowthGlobal0X128,
      feeGrowthGlobal1X128
    );
    _unlock();
  }

  struct SwapCache {
    // liquidity at the beginning of the swap
    uint128 liquidityStart;
    // staked liquidity at the beginning of the swap
    uint128 stakedLiquidityStart;
    // the timestamp of the current block
    uint32 blockTimestamp;
    // the current value of the tick accumulator, computed only if we cross an initialized tick
    int56 tickCumulative;
    // the current value of seconds per liquidity accumulator, computed only if we cross an initialized tick
    uint160 secondsPerLiquidityCumulativeX128;
    // whether we've computed and cached the above two accumulators
    bool computedLatestObservation;
    // global swap hook used to call beforeSwap/afterSwap methods.
    address swapHook;
  }

  // the top level state of the swap, the results of which are recorded in storage at the end
  struct SwapState {
    // the amount remaining to be swapped in/out of the input/output asset
    int256 amountSpecifiedRemaining;
    // the amount already swapped out/in of the output/input asset
    int256 amountCalculated;
    // current sqrt(price)
    uint160 sqrtPriceX96;
    // the tick associated with the current price
    int24 tick;
    // the fee associated with the pool
    uint24 fee;
    // wether we've updated the fees in the current swap
    bool hasUpdatedFees;
    // the global fee growth of the input token
    uint256 feeGrowthGlobalX128;
    // amount of input token paid as gauge fee
    uint128 gaugeFee;
    // the current liquidity in range
    uint128 liquidity;
    // the current staked liquidity in range
    uint128 stakedLiquidity;
  }

  struct StepComputations {
    // the price at the beginning of the step
    uint160 sqrtPriceStartX96;
    // the next tick to swap to from the current tick in the swap direction
    int24 tickNext;
    // whether tickNext is initialized or not
    bool initialized;
    // sqrt(price) for the next tick (1/0)
    uint160 sqrtPriceNextX96;
    // how much is being swapped in in this step
    uint256 amountIn;
    // how much is being swapped out
    uint256 amountOut;
    // how much fee is being paid in
    uint256 feeAmount;
  }

  /// @inheritdoc ICLPoolActions
  function swap(
    address recipient,
    bool zeroForOne,
    int256 amountSpecified,
    uint160 sqrtPriceLimitX96,
    bytes calldata data
  ) external override returns (int256 amount0, int256 amount1) {
    _require(amountSpecified != 0, 'AS');

    Slot0 memory slot0Start = slot0;

    _require(slot0Start.unlocked, 'LOK');
    _require(
      zeroForOne
        ? sqrtPriceLimitX96 < slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO
        : sqrtPriceLimitX96 > slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO,
      'SPL'
    );

    slot0.unlocked = false;

    SwapCache memory cache = SwapCache({
      liquidityStart: liquidity,
      stakedLiquidityStart: stakedLiquidity,
      blockTimestamp: uint32(block.timestamp),
      secondsPerLiquidityCumulativeX128: 0,
      tickCumulative: 0,
      computedLatestObservation: false,
      swapHook: ICLFactory(factory).getPoolSwapHook(address(this))
    });

    bool exactInput = amountSpecified > 0;

    SwapState memory state = SwapState({
      amountSpecifiedRemaining: amountSpecified,
      amountCalculated: 0,
      sqrtPriceX96: slot0Start.sqrtPriceX96,
      tick: slot0Start.tick,
      fee: 0, // set below
      hasUpdatedFees: false,
      feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128,
      gaugeFee: 0,
      liquidity: cache.liquidityStart,
      stakedLiquidity: cache.stakedLiquidityStart
    });

    state.fee = cache.swapHook
      .beforeSwap(
        ISwapHook.SwapParams({
          caller: msg.sender,
          recipient: recipient,
          zeroForOne: zeroForOne,
          amountSpecified: amountSpecified,
          sqrtPriceLimitX96: sqrtPriceLimitX96,
          data: data,
          sqrtPriceX96: slot0Start.sqrtPriceX96,
          tick: slot0Start.tick
        }),
        factory,
        tickSpacing
      );

    // continue swapping as long as we haven't used the entire input/output and haven't reached the price limit
    while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
      StepComputations memory step;

      step.sqrtPriceStartX96 = state.sqrtPriceX96;

      (step.tickNext, step.initialized) =
        tickBitmap.nextInitializedTickWithinOneWord(state.tick, tickSpacing, zeroForOne);

      // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
      if (step.tickNext < TickMath.MIN_TICK) {
        step.tickNext = TickMath.MIN_TICK;
      } else if (step.tickNext > TickMath.MAX_TICK) {
        step.tickNext = TickMath.MAX_TICK;
      }

      // get the price for the next tick
      step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

      // compute values to swap to the target tick, price limit, or point where input/output amount is exhausted
      (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
        state.sqrtPriceX96,
        (zeroForOne ? step.sqrtPriceNextX96 < sqrtPriceLimitX96 : step.sqrtPriceNextX96 > sqrtPriceLimitX96)
          ? sqrtPriceLimitX96
          : step.sqrtPriceNextX96,
        state.liquidity,
        state.amountSpecifiedRemaining,
        state.fee
      );

      if (exactInput) {
        state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount).toInt256();
        state.amountCalculated = state.amountCalculated.sub(step.amountOut.toInt256());
      } else {
        state.amountSpecifiedRemaining += step.amountOut.toInt256();
        state.amountCalculated = state.amountCalculated.add((step.amountIn + step.feeAmount).toInt256());
      }

      // update global fee tracker and gauge fee
      if (state.liquidity > 0) {
        (uint256 _feeGrowthGlobalX128, uint256 _stakedFeeAmount) =
          calculateFees(step.feeAmount, state.liquidity, state.stakedLiquidity);

        state.feeGrowthGlobalX128 += _feeGrowthGlobalX128;
        state.gaugeFee += uint128(_stakedFeeAmount);
      }

      // shift tick if we reached the next price
      if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
        // if the tick is initialized, run the tick transition
        if (step.initialized) {
          // check for the placeholder value, which we replace with the actual value the first time the swap
          // crosses an initialized tick
          if (!cache.computedLatestObservation) {
            (cache.tickCumulative, cache.secondsPerLiquidityCumulativeX128) = observations.observeSingle(
              cache.blockTimestamp,
              0,
              slot0Start.tick,
              slot0Start.observationIndex,
              cache.liquidityStart,
              slot0Start.observationCardinality
            );
            cache.computedLatestObservation = true;
          }
          if (!state.hasUpdatedFees) {
            _settleToBlock();
            state.hasUpdatedFees = true;
          }
          Tick.LiquidityNets memory nets = ticks.cross(
            step.tickNext,
            (zeroForOne ? state.feeGrowthGlobalX128 : feeGrowthGlobal0X128),
            (zeroForOne ? feeGrowthGlobal1X128 : state.feeGrowthGlobalX128),
            cache.secondsPerLiquidityCumulativeX128,
            cache.tickCumulative,
            cache.blockTimestamp,
            rewardGrowthGlobalX128
          );
          // if we're moving leftward, we interpret liquidityNet & stakedLiquidityNet as the opposite sign
          // safe because liquidityNet & stakedLiquidityNet cannot be type(int128).min
          if (zeroForOne) {
            nets.liquidityNet = -nets.liquidityNet;
            nets.stakedLiquidityNet = -nets.stakedLiquidityNet;
          }

          state.liquidity = LiquidityMath.addDelta(state.liquidity, nets.liquidityNet);
          state.stakedLiquidity = LiquidityMath.addDelta(state.stakedLiquidity, nets.stakedLiquidityNet);
        }

        state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
      } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
        // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
        state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
      }
    }

    /// @dev This function is able to mutate `gaugeFees` storage variable.
    cache.swapHook
      .afterSwap(
        ISwapHook.SwapParams({
          caller: msg.sender,
          recipient: recipient,
          zeroForOne: zeroForOne,
          amountSpecified: amountSpecified,
          sqrtPriceLimitX96: sqrtPriceLimitX96,
          data: data,
          sqrtPriceX96: state.sqrtPriceX96,
          tick: state.tick
        }),
        state,
        cache,
        gaugeFees
      );

    // update tick and write an oracle entry if the tick change
    if (state.tick != slot0Start.tick) {
      (uint16 observationIndex, uint16 observationCardinality) = observations.write(
        slot0Start.observationIndex,
        cache.blockTimestamp,
        slot0Start.tick,
        cache.liquidityStart,
        slot0Start.observationCardinality,
        slot0Start.observationCardinalityNext
      );
      (slot0.sqrtPriceX96, slot0.tick, slot0.observationIndex, slot0.observationCardinality) =
      (state.sqrtPriceX96, state.tick, observationIndex, observationCardinality);
    } else {
      // otherwise just update the price
      slot0.sqrtPriceX96 = state.sqrtPriceX96;
    }

    // update liquidity and stakedLiquidity if it changed
    if (cache.liquidityStart != state.liquidity) liquidity = state.liquidity;
    if (cache.stakedLiquidityStart != state.stakedLiquidity) stakedLiquidity = state.stakedLiquidity;

    // update fee growth global and, if necessary, gauge fees
    // overflow is acceptable, protocol has to withdraw before it hits type(uint128).max fees
    if (zeroForOne) {
      feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
      if (state.gaugeFee > 0) gaugeFees.token0 += state.gaugeFee;
    } else {
      feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
      if (state.gaugeFee > 0) gaugeFees.token1 += state.gaugeFee;
    }

    (amount0, amount1) = zeroForOne == exactInput
      ? (amountSpecified - state.amountSpecifiedRemaining, state.amountCalculated)
      : (state.amountCalculated, amountSpecified - state.amountSpecifiedRemaining);

    // do the transfers and collect payment
    if (zeroForOne) {
      if (amount1 < 0) TransferHelper.safeTransfer(token1, recipient, uint256(-amount1));

      uint256 balance0Before = balance0();
      ICLSwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
      _require(balance0Before.add(uint256(amount0)) <= balance0(), 'IIA');
    } else {
      if (amount0 < 0) TransferHelper.safeTransfer(token0, recipient, uint256(-amount0));

      uint256 balance1Before = balance1();
      ICLSwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
      _require(balance1Before.add(uint256(amount1)) <= balance1(), 'IIA');
    }

    emit Swap(msg.sender, recipient, amount0, amount1, state.sqrtPriceX96, state.liquidity, state.tick);
    slot0.unlocked = true;
  }

  /// @inheritdoc ICLPoolActions
  function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external override {
    _lock();

    /// @dev The internal call credits part of the paid fee to gauge's token0/1.
    ///      And thus changes the original sequence of fee updates from:
    ///       1) getUnstakedFee() -> feeGrowthGlobal0X128 += x  -> gaugeFees.token0 += y
    ///       2) getUnstakedFee() -> feeGrowthGlobal1X128 += x' -> gaugeFees.token1 += y'
    ///      to:
    ///       1) getUnstakedFee() -> gaugeFees.token0 += y
    ///       2) getUnstakedFee() -> gaugeFees.token1 += y'
    ///       3) feeGrowthGlobal0X128 += x
    ///       4) feeGrowthGlobal1X128 += x'
    (uint256 feeGrowthDelta0, uint256 feeGrowthDelta1) = CL.flash(
      gaugeFees,
      CL.FlashInput({
        token0: token0,
        token1: token1,
        factory: factory,
        tickSpacing: tickSpacing,
        liquidity: liquidity,
        stakedLiquidity: stakedLiquidity,
        recipient: recipient,
        amount0: amount0,
        amount1: amount1
      }),
      data
    );
    if (feeGrowthDelta0 > 0) feeGrowthGlobal0X128 += feeGrowthDelta0;
    if (feeGrowthDelta1 > 0) feeGrowthGlobal1X128 += feeGrowthDelta1;
    _unlock();
  }

  /// @inheritdoc ICLPoolState
  function getRewardGrowthInside(
    int24 tickLower,
    int24 tickUpper,
    uint256 _rewardGrowthGlobalX128
  ) external view override returns (uint256 rewardGrowthInside) {
    return CL.getRewardGrowthInside(
      ticks, tickLower, tickUpper, slot0.tick, _rewardGrowthGlobalX128, rewardGrowthGlobalX128
    );
  }

  /// @dev Seconds elapsed converted into X128 seconds per unit of staked liquidity.
  function _secondsPerStakedLiquidityDelta(uint256 _elapsed, uint128 _stakedLiquidity) internal pure returns (uint160) {
    return uint160((_elapsed << 128) / _stakedLiquidity);
  }

  /// @dev Credits realized emissions to the accumulator when staked liquidity is in range, otherwise banks
  ///      them into rollover, then advances the settlement timestamp. Both settlement paths terminate here.
  function _updateRewardsGrowthGlobal(uint256 _rewardsToDistribute, uint48 _now, uint48 _lastUpdated) internal {
    uint128 _stakedLiquidity = stakedLiquidity;
    if (_stakedLiquidity > 0) {
      rewardGrowthGlobalX128 += FullMath.mulDiv(_rewardsToDistribute, FixedPoint128.Q128, _stakedLiquidity);
      secondsPerStakedLiquidityCumulativeX128 += _secondsPerStakedLiquidityDelta(_now - _lastUpdated, _stakedLiquidity);
    } else {
      rollover += _rewardsToDistribute;
    }
    lastUpdated = _now;
  }

  /// @dev Realizes rewards up to the current block by pulling the emissions accrued since the last
  /// settlement through the gauge. Calls {_updateRewardsGrowthGlobal} to update the rewards to
  /// distribute and lastUpdated. The LeafVoter's settlement is permissionless and returns 0 for
  /// unregistered gauges, so the gauge pull reverts in exactly one case: the gauge's factory relays
  /// the settle to the gauge tape inside a gas-capped call, and the caller funded the settle but
  /// not that capped subcall.
  function _settleToBlock() internal {
    uint48 _timestamp = uint48(block.timestamp);
    uint48 _lastUpdated = lastUpdated;
    if (_timestamp == _lastUpdated) return;

    address _gauge = gauge;
    if (_gauge == address(0)) return;

    uint256 _rewardsToDistribute = ICLGauge(_gauge).settleGauge();
    _updateRewardsGrowthGlobal(_rewardsToDistribute, _timestamp, _lastUpdated);
  }

  /// @inheritdoc ICLPoolActions
  function settleToBlock() external override returns (uint256 _rollover) {
    _lock();
    _onlyGauge();
    _settleToBlock();
    _rollover = rollover;
    delete rollover;
    _unlock();
  }

  /// @notice Calculates the fees owed to staked liquidity, then calculates fee levied on unstaked liquidity
  /// @param feeAmount Total fees
  /// @param _liquidity Current liquidity in active tick
  /// @param _stakedLiquidity Current staked liquidity in active tick
  /// @return unstakedFeeAmount Fee amount for unstaked LPs after accounting for staked liquidity contribution and unstaked fee
  /// @return stakedFeeAmount Fee amount for staked LPs consisting of staked liquidity contribution and unstaked fee
  function splitFees(
    uint256 feeAmount,
    uint128 _liquidity,
    uint128 _stakedLiquidity
  ) internal view returns (uint256 unstakedFeeAmount, uint256 stakedFeeAmount) {
    stakedFeeAmount = FullMath.mulDivRoundingUp(feeAmount, _stakedLiquidity, _liquidity);
    (unstakedFeeAmount, stakedFeeAmount) = applyUnstakedFees(feeAmount - stakedFeeAmount, stakedFeeAmount);
  }

  /// @notice Calculates fee for levied on unstaked liquidity only
  /// @param _unstakedFeeAmount Fee amount for unstaked LPs net of staked liquidity contribution
  /// @param _stakedFeeAmount Fee amount for staked LPs consisting of staked liquidity contribution
  /// @return unstakedFeeAmount Fee amount for unstaked LPs after accounting for staked liquidity contribution and unstaked fee
  /// @return stakedFeeAmount Fee amount for staked LPs consisting of staked liquidity contribution and unstaked fee
  function applyUnstakedFees(
    uint256 _unstakedFeeAmount,
    uint256 _stakedFeeAmount
  ) internal view returns (uint256 unstakedFeeAmount, uint256 stakedFeeAmount) {
    uint256 _stakedFee = FullMath.mulDivRoundingUp(_unstakedFeeAmount, unstakedFee(), 1_000_000);
    unstakedFeeAmount = _unstakedFeeAmount - _stakedFee;
    stakedFeeAmount = _stakedFeeAmount + _stakedFee;
  }

  // calculates the fee growths for unstaked liquidity and returns it with the staked fee amount
  function calculateFees(
    uint256 feeAmount,
    uint128 _liquidity,
    uint128 _stakedLiquidity
  ) internal view returns (uint256 feeGrowthGlobalX128, uint256 stakedFeeAmount) {
    // if there is only staked liquidity
    if (_liquidity == _stakedLiquidity) {
      stakedFeeAmount = feeAmount;
    }
    // if there is only unstaked liquidity
    else if (_stakedLiquidity == 0) {
      (uint256 unstakedFeeAmount, uint256 _stakedFeeAmount) = applyUnstakedFees(feeAmount, 0);
      feeGrowthGlobalX128 = FullMath.mulDiv(unstakedFeeAmount, FixedPoint128.Q128, _liquidity);
      stakedFeeAmount = _stakedFeeAmount;
    }
    // if there are staked and unstaked liquidities
    else {
      (uint256 unstakedFeeAmount, uint256 _stakedFeeAmount) = splitFees(feeAmount, _liquidity, _stakedLiquidity);
      feeGrowthGlobalX128 = FullMath.mulDiv(unstakedFeeAmount, FixedPoint128.Q128, _liquidity - _stakedLiquidity);
      stakedFeeAmount = _stakedFeeAmount;
    }
  }

  /// @inheritdoc ICLPoolOwnerActions
  function collectFees(address recipient) external override returns (uint128 amount0, uint128 amount1) {
    _lock();
    _onlyGauge();
    (amount0, amount1) = CL.collectFees(gaugeFees, recipient, token0, token1);
    _unlock();
  }

  /// @inheritdoc ICLPoolActions
  function setGaugeAndPositionManager(address _gauge, address _nft) external override {
    _lock();
    CL.validateGaugeFactory(factoryRegistry, factory);
    require(gauge == address(0));
    gauge = _gauge;
    nft = _nft;
    // Pull any emissions the voter accrued before the gauge was connected. No liquidity can be
    // staked yet, so the accrual banks into rollover instead of crediting future stakers, and the
    // gauge's settlement cursor is initialized in the same call.
    uint256 _rewardsToDistribute = ICLGauge(_gauge).settleGauge();
    _updateRewardsGrowthGlobal(_rewardsToDistribute, uint48(block.timestamp), lastUpdated);
    _unlock();
  }
}
