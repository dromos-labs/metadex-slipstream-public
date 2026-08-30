// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {Test} from 'forge-std/Test.sol';

import {ICLPoolConstants} from 'contracts/core/interfaces/pool/ICLPoolConstants.sol';
import {TickMath} from 'contracts/core/libraries/TickMath.sol';

import {IPoolFactoryV3} from 'contracts/periphery/interfaces/IPoolFactoryV3.sol';
import {IV3FactoryRegistry} from 'contracts/periphery/interfaces/IV3FactoryRegistry.sol';

import {Metaquoter} from 'contracts/periphery/lens/Metaquoter.sol';

import {ClSwapProbe} from 'test/unit/concrete/Metaquoter/harnesses/ClSwapProbe.sol';

abstract contract UnitMetaquoterBase is Test {
  /// @dev Canonical POOL_TYPE labels reported by the pools.
  bytes32 internal constant _CL_POOL_TYPE = 'CL';
  bytes32 internal constant _V2_STABLE_POOL_TYPE = 'V2_STABLE';
  bytes32 internal constant _V2_VOLATILE_POOL_TYPE = 'V2_VOLATILE';

  /// @dev Probe defaults for the CL round-trip: the input the pool charges (kept distinct from any output so a
  ///      wrong-branch quote that returns the output as the input is detectable) and the post-swap price it reports.
  uint256 internal constant _INPUT_OWED = 5e18;
  uint256 internal constant _OUTPUT_SENT = 4e18;
  uint160 internal constant _SQRT_PRICE_AFTER = uint160(3e18);

  /// @dev The price limits the quoter falls back to when none is provided.
  uint160 internal _MIN_PRICE_LIMIT = TickMath.MIN_SQRT_RATIO + 1;
  uint160 internal _MAX_PRICE_LIMIT = TickMath.MAX_SQRT_RATIO - 1;

  Metaquoter internal _quoter;
  ClSwapProbe internal _probe;

  /// @dev Three ordered token addresses: `tokenLow < tokenMid < tokenHigh`.
  address internal _tokenLow = address(0x1111000000000000000000000000000000000000);
  address internal _tokenMid = address(0x2222000000000000000000000000000000000000);
  address internal _tokenHigh = address(0x3333000000000000000000000000000000000000);

  function setUp() public view {
    assertLt(uint256(uint160(_tokenLow)), uint256(uint160(_tokenMid)));
    assertLt(uint256(uint160(_tokenMid)), uint256(uint160(_tokenHigh)));
  }

  /// @notice Points the suite at a fuzzed registry and deploys the quoter against it.
  function _bootstrapRegistry(address _registry) internal {
    _sanitize(_registry);

    _quoter = new Metaquoter(_registry);
  }

  /// @notice Bootstraps a fuzzed registry, factory and pool, all distinct.
  function _bootstrap(address _registry, address _factory, address _pool) internal {
    _bootstrapRegistry(_registry);

    _sanitize(_factory);
    _sanitize(_pool);
    vm.assume(_factory != _registry && _factory != address(_quoter));
    vm.assume(_pool != _registry && _pool != _factory && _pool != address(_quoter));
  }

  /// @notice Bootstraps a real CL pool probe (approved factory, registered target) so quotes drive the actual swap
  ///         callback instead of a mocked return. The registry and factory are still fuzzed but mocked, as they are
  ///         not under test on this path.
  function _bootstrapProbe(address _registry, address _factory) internal {
    _sanitize(_registry);
    _sanitize(_factory);
    vm.assume(_registry != _factory);

    _quoter = new Metaquoter(_registry);
    _probe = new ClSwapProbe(_factory, _tokenLow, _tokenHigh);

    vm.mockCall(
      _registry,
      abi.encodeWithSelector(IV3FactoryRegistry.targetToFactory.selector, address(_probe)),
      abi.encode(_factory)
    );
    vm.mockCall(
      _registry, abi.encodeWithSelector(IV3FactoryRegistry.isTargetFactoryApproved.selector, _factory), abi.encode(true)
    );
  }

  /// @notice Mocks a fully validated pool: approved factory, registered target, and its type and tokens.
  function _mockPool(
    address _registry,
    address _factory,
    address _pool,
    bytes32 _poolType,
    address _token0,
    address _token1
  ) internal {
    _mockAndExpect(
      _registry, abi.encodeWithSelector(IV3FactoryRegistry.targetToFactory.selector, _pool), abi.encode(_factory)
    );
    _mockAndExpect(
      _registry, abi.encodeWithSelector(IV3FactoryRegistry.isTargetFactoryApproved.selector, _factory), abi.encode(true)
    );
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.POOL_TYPE.selector), abi.encode(_poolType));
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.token0.selector), abi.encode(_token0));
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.token1.selector), abi.encode(_token1));

    // resolvePool gates V2 (non-CL) pools on the factory's pause flag; default it unpaused (CL pools never read it).
    vm.mockCall(_factory, abi.encodeWithSelector(IPoolFactoryV3.isPaused.selector), abi.encode(false));
  }

  /// @notice Mocks a call and expects it to be made.
  function _mockAndExpect(address _target, bytes memory _calldata, bytes memory _returned) internal {
    vm.mockCall(_target, _calldata, _returned);
    vm.expectCall(_target, _calldata);
  }

  /// @notice Excludes addresses that would collide with the suite's actors, tokens or cheatcode targets.
  function _sanitize(address _addr) internal view {
    assumeNotForgeAddress(_addr);
    vm.assume(_addr != address(0));
    vm.assume(_addr != address(this));
    vm.assume(_addr != _tokenLow && _addr != _tokenMid && _addr != _tokenHigh);
  }

  /// @notice Builds a single-pool route.
  function _route(address _pool) internal pure returns (address[] memory _pools) {
    _pools = new address[](1);
    _pools[0] = _pool;
  }
}
