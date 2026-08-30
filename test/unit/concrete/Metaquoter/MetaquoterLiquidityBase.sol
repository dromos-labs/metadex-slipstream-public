// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {Test} from 'forge-std/Test.sol';

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Babylonian} from '@uniswap/lib/contracts/libraries/Babylonian.sol';

import {TickMath} from 'contracts/core/libraries/TickMath.sol';

import {IV2Pool} from 'contracts/periphery/interfaces/IV2Pool.sol';
import {IV3FactoryRegistry} from 'contracts/periphery/interfaces/IV3FactoryRegistry.sol';

import {Metaquoter} from 'contracts/periphery/lens/Metaquoter.sol';

abstract contract UnitMetaquoterLiquidityBase is Test {
  uint256 internal constant _MINIMUM_LIQUIDITY = 1000;
  uint256 internal constant _MINIMUM_K = 1e10;
  bytes32 internal constant _CL_POOL_TYPE = 'CL';
  bytes32 internal constant _V2_STABLE_POOL_TYPE = 'V2_STABLE';
  bytes32 internal constant _V2_VOLATILE_POOL_TYPE = 'V2_VOLATILE';

  Metaquoter internal _quoter;

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  /// @notice Bootstraps a fuzzed registry, factory and pool, all distinct, and deploys the quoter against the registry.
  function _bootstrap(address _registry, address _factory, address _pool) internal {
    _sanitize(_registry);
    _quoter = new Metaquoter(_registry);

    _sanitize(_factory);
    _sanitize(_pool);
    vm.assume(_factory != _registry && _factory != address(_quoter));
    vm.assume(_pool != _registry && _pool != _factory && _pool != address(_quoter));
  }

  /// @notice Mocks a fully validated V2 pool with the given type.
  function _mockValidPool(address _registry, address _factory, address _pool, bytes32 _poolType) internal {
    _mockAndExpect(
      _registry, abi.encodeWithSelector(IV3FactoryRegistry.targetToFactory.selector, _pool), abi.encode(_factory)
    );
    _mockAndExpect(
      _registry, abi.encodeWithSelector(IV3FactoryRegistry.isTargetFactoryApproved.selector, _factory), abi.encode(true)
    );
    _mockAndExpect(_pool, abi.encodeWithSelector(IV2Pool.POOL_TYPE.selector), abi.encode(_poolType));
  }

  /// @notice Mocks the pool metadata with 18-decimal scales and the given reserves in token0/token1 order.
  function _mockMetadata(address _pool, uint256 _reserve0, uint256 _reserve1) internal {
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(IV2Pool.metadata.selector),
      abi.encode(uint256(1e18), uint256(1e18), _reserve0, _reserve1, address(0), address(0))
    );
  }

  /// @notice Mocks the live balances the pool holds of each metadata token.
  /// @dev Plain `vm.mockCall`, not `_mockAndExpect`: the add path only reads these once it credits donations.
  function _mockPoolBalances(
    address _pool,
    address _token0,
    address _token1,
    uint256 _balance0,
    uint256 _balance1
  ) internal {
    vm.mockCall(_token0, abi.encodeWithSelector(IERC20.balanceOf.selector, _pool), abi.encode(_balance0));
    vm.mockCall(_token1, abi.encodeWithSelector(IERC20.balanceOf.selector, _pool), abi.encode(_balance1));
  }

  /// @notice Mocks pool metadata returning the given reserves and tokens, with 18-decimal scales.
  function _mockMetadataTokens(
    address _pool,
    uint256 _reserve0,
    uint256 _reserve1,
    address _token0,
    address _token1
  ) internal {
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(IV2Pool.metadata.selector),
      abi.encode(uint256(1e18), uint256(1e18), _reserve0, _reserve1, _token0, _token1)
    );
  }

  /// @notice Mocks pool metadata returning the given decimal scales, reserves and tokens.
  /// @dev Companion to `_mockMetadataTokens` for pairs whose tokens do not both use 18 decimals.
  function _mockMetadataScaled(
    address _pool,
    uint256 _decimals0,
    uint256 _decimals1,
    uint256 _reserve0,
    uint256 _reserve1,
    address _token0,
    address _token1
  ) internal {
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(IV2Pool.metadata.selector),
      abi.encode(_decimals0, _decimals1, _reserve0, _reserve1, _token0, _token1)
    );
  }

  /// @notice The square-root price halfway through `_tick`, strictly between its ratio and the next tick's.
  /// @dev The ordinary state after a swap lands inside a tick rather than on its boundary: `slot0` reports `_tick`
  ///      while the price has already moved past that tick's ratio.
  function _sqrtPriceInsideTick(int24 _tick) internal pure returns (uint160 _sqrtPriceX96) {
    uint160 _tickRatio = TickMath.getSqrtRatioAtTick(_tick);
    _sqrtPriceX96 = _tickRatio + (TickMath.getSqrtRatioAtTick(_tick + 1) - _tickRatio) / 2;
  }

  /// @notice Mocks a call and expects it to be made.
  function _mockAndExpect(address _target, bytes memory _calldata, bytes memory _returned) internal {
    vm.mockCall(_target, _calldata, _returned);
    vm.expectCall(_target, _calldata);
  }

  /// @notice Excludes addresses that would collide with the suite's actors or cheatcode targets.
  function _sanitize(address _addr) internal view {
    assumeNotForgeAddress(_addr);
    vm.assume(_addr != address(0));
    vm.assume(_addr != address(this));
  }

  /// @notice Excludes token addresses that would collide with the suite's actors or with each other.
  function _sanitizeTokens(
    address _registry,
    address _factory,
    address _pool,
    address _token0,
    address _token1
  ) internal view {
    _sanitize(_token0);
    _sanitize(_token1);
    vm.assume(_token0 != _token1);
    vm.assume(_token0 != _pool && _token0 != _registry && _token0 != _factory);
    vm.assume(_token1 != _pool && _token1 != _registry && _token1 != _factory);
  }
}
