// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {FixedPoint128} from 'contracts/core/libraries/FixedPoint128.sol';
import {FixedPoint96} from 'contracts/core/libraries/FixedPoint96.sol';
import {FullMath} from 'contracts/core/libraries/FullMath.sol';
import {SwapMath} from 'contracts/core/libraries/SwapMath.sol';
import {TickMath} from 'contracts/core/libraries/TickMath.sol';
import {SwapHookLib} from 'contracts/core/libraries/hook/SwapHookLib.sol';

import {ICLFactory} from 'contracts/core/interfaces/ICLFactory.sol';
import {IERC20Minimal} from 'contracts/core/interfaces/IERC20Minimal.sol';
import {ICLSwapCallback} from 'contracts/core/interfaces/callback/ICLSwapCallback.sol';
import {ISwapHook} from 'contracts/core/interfaces/hook/ISwapHook.sol';
import {ICLPoolState} from 'contracts/core/interfaces/pool/ICLPoolState.sol';

import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import {CLPoolTest} from '../CLPool.t.sol';

contract UnitCLPoolSwapBaseHelpers is CLPoolTest {
  using stdStorage for StdStorage;

  /*////////////////////////////////////////////////////////////
                          EVENTS
  ////////////////////////////////////////////////////////////*/

  /// @dev Event is declared here, due to name collision with
  ///      another struct in custom-fee tests.
  event Swap(
    address indexed sender,
    address indexed recipient,
    int256 amount0,
    int256 amount1,
    uint160 sqrtPriceX96,
    uint128 liquidity,
    int24 tick
  );

  /*////////////////////////////////////////////////////////////
                          STRUCTS
  ////////////////////////////////////////////////////////////*/

  /// @dev For children - to avoid stack too deep.
  struct Params {
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
    uint128 liquidity;
    uint128 stakedLiquidity;
    uint24 fee;
  }

  bool internal constant _ZERO_FOR_ONE = true;
  bool internal constant _ONE_FOR_ZERO = false;

  uint256 internal immutable _MIN_LIQUIDITY = FixedPoint96.Q96;
  uint256 internal constant _MAX_LIQUIDITY = type(uint128).max / 1e6;

  address internal _swapHook = makeAddr('swapHook');
  address internal _swapper = makeAddr('swapper');

  function setUp() public virtual override {
    super.setUp();

    int24 _tick = clPool.tickSpacing();

    _setSlot0SqrtPrice(address(clPool), TickMath.getSqrtRatioAtTick(_tick));
    _setSlot0Tick(address(clPool), (_tick * 2));

    /// @dev Returns address of a swap hook for all {CLPool.swap} calls.
    vm.mockCall(
      clPool.factory(),
      0,
      abi.encodeWithSelector(ICLFactory.getPoolSwapHook.selector, address(clPool)),
      abi.encode(_swapHook)
    );
  }

  /*////////////////////////////////////////////////////////////
                          MOCK HELPERS
  ////////////////////////////////////////////////////////////*/

  function _bypassBalanceOf(address _token, address _user) internal {
    uint256[] memory _balances = new uint256[](2);
    _balances[0] = 0;
    _balances[1] = type(uint128).max;
    _mockAndExpectBalanceOfCalls(_token, _user, _balances);
  }

  function _mockAndExpectBalanceOfCalls(address _token, address _user, uint256[] memory _retBalances) internal {
    bytes memory _data = abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, _user);
    bytes[] memory _mocks = new bytes[](_retBalances.length);

    for (uint256 _i = 0; _i < _retBalances.length; ++_i) {
      _mocks[_i] = abi.encode(_retBalances[_i]);
    }

    vm.mockCalls(_token, _data, _mocks);
    vm.expectCall(_token, _data);
  }

  function _mockAndExpectTransfer(address _token, address _user, uint256 _amount) internal {
    bytes memory _data = abi.encodeWithSelector(IERC20Minimal.transfer.selector, _user, _amount);

    vm.mockCall(_token, _data, abi.encode(_amount));
    vm.expectCall(_token, _data);
  }

  function _mockAndExpectSwapCallback(address _msgSender, int256 _amount0, int256 _amount1) internal {
    bytes memory _data = abi.encodeWithSelector(ICLSwapCallback.uniswapV3SwapCallback.selector, _amount0, _amount1, '');

    vm.mockCall(_msgSender, _data, '');
    vm.expectCall(_msgSender, _data);
  }

  function _mockAndExpectBeforeSwap(uint24 _fee, bytes memory _data) internal {
    vm.mockCall(_swapHook, 0, _data, abi.encode(_fee));
    vm.expectCall(_swapHook, _data);

    /// @dev It will fallback to factory's tick-spacing fee.
    if (_fee == 0) {
      _data = abi.encodeWithSelector(ICLFactory.tickSpacingToFee.selector, clPool.tickSpacing());
      vm.expectCall(clPool.factory(), 0, _data);
    }
  }

  function _mockAndExpectAfterSwap(uint24 _fee, bytes memory _data) internal {
    vm.mockCall(_swapHook, 0, _data, abi.encode(_fee));
    vm.expectCall(_swapHook, _data);
  }

  /*////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
  ////////////////////////////////////////////////////////////*/

  /// @notice Internal modifier that should be invoked by hook-using modifiers.
  function _whenHookUsesBeforeSwapOnly(Params memory _params, bool _exactInput, bool _swapDirection) internal {
    /// @dev Re-bind the currently active tick, so that we can walk rightward.
    if (_swapDirection == _ONE_FOR_ZERO) {
      int24 _tick = clPool.tickSpacing();
      _setSlot0Tick(address(clPool), -(_tick * 2));
    }

    (uint160 _slot0SqrtPriceX96, int24 _tick,,,,) = clPool.slot0();

    /// @dev Sqrt price bounding to prevent "SPL" revert.
    _params.sqrtPriceLimitX96 = uint160(
      bound(
        uint256(_params.sqrtPriceLimitX96),
        _swapDirection == _ZERO_FOR_ONE ? TickMath.MIN_SQRT_RATIO + 1 : _slot0SqrtPriceX96 + 1,
        _swapDirection == _ZERO_FOR_ONE ? _slot0SqrtPriceX96 - 1 : TickMath.MAX_SQRT_RATIO - 1
      )
    );

    _params.fee = uint24(bound(uint256(_params.fee), 0, _FEE_CEIL));

    _params.stakedLiquidity = uint128(bound(uint256(_params.stakedLiquidity), 0, _MAX_LIQUIDITY - _MIN_LIQUIDITY));
    _params.liquidity =
      uint128(bound(uint256(_params.liquidity), _params.stakedLiquidity + _MIN_LIQUIDITY, _MAX_LIQUIDITY));

    /// @dev Max amount is used to obtain normal amount to specify for a swap.
    _params.amountSpecified = int256(type(int256).max);
    if (!_exactInput) _params.amountSpecified = -(_params.amountSpecified);

    SwapStep memory _step = _computeSwapStep(_params, _swapDirection);

    _params.amountSpecified = int256(_step.amountIn + _step.feeAmount);
    if (!_exactInput) _params.amountSpecified = -int256(_step.amountOut);

    bytes memory _beforeSwapData = abi.encodeWithSelector(
      ISwapHook.beforeSwap.selector,
      ISwapHook.SwapParams({
        caller: _swapper,
        recipient: _swapper,
        zeroForOne: _swapDirection,
        amountSpecified: _params.amountSpecified,
        sqrtPriceLimitX96: _params.sqrtPriceLimitX96,
        data: '',
        sqrtPriceX96: _slot0SqrtPriceX96,
        tick: _tick
      })
    );

    _mockAndExpectBeforeSwap(_params.fee, _beforeSwapData);
  }

  struct SwapStep {
    uint160 sqrtRatioNextX96;
    uint256 amountIn;
    uint256 amountOut;
    uint256 feeAmount;
    int24 tickNext;
  }

  /// @notice Wrapper function for {SwapMath.computeSwapStep}.
  function _computeSwapStep(Params memory _params, bool _zeroForOne) internal view returns (SwapStep memory _step) {
    (uint160 _slot0SqrtPriceX96, int24 _tick,,,,) = clPool.slot0();

    (int24 _tickNext,) = nextInitializedTickWithinOneWord(clPool, _tick, clPool.tickSpacing(), _zeroForOne);

    (uint160 _sqrtRatioNextX96, uint256 _amountIn, uint256 _amountOut, uint256 _feeAmount) = SwapMath.computeSwapStep(
      _slot0SqrtPriceX96,
      /// @dev sqrt ratio at `tickNext` is recomputed to avoid stack too deep.
      (_zeroForOne
          ? TickMath.getSqrtRatioAtTick(_tickNext) < _params.sqrtPriceLimitX96
          : TickMath.getSqrtRatioAtTick(_tickNext) > _params.sqrtPriceLimitX96)
        ? _params.sqrtPriceLimitX96
        : TickMath.getSqrtRatioAtTick(_tickNext),
      _params.liquidity,
      _params.amountSpecified,
      _getBeforeSwapFee(_params)
    );

    _step = SwapStep(_sqrtRatioNextX96, _amountIn, _amountOut, _feeAmount, _tickNext);
  }

  function _getBeforeSwapFee(Params memory _params) public view returns (uint24) {
    return _params.fee == 0 ? ICLFactory(clPool.factory()).tickSpacingToFee(clPool.tickSpacing()) : _params.fee;
  }
}
