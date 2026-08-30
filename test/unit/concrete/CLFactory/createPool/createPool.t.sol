// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.7.6;
pragma abicoder v2;

import {CLFactoryTest} from '../CLFactory.t.sol';

import {ICLFactoryIndexation} from 'contracts/core/interfaces/indexation/ICLFactoryIndexation.sol';
import {ICLPoolActions} from 'contracts/core/interfaces/pool/ICLPoolActions.sol';
import {StdStorage, stdStorage} from 'forge-std/Test.sol';

contract UnitCLFactoryCreatePool is CLFactoryTest {
  using stdStorage for StdStorage;

  function test_RevertWhen_TokenAEqualsTokenB(address _token) external {
    // it should revert
    vm.expectRevert();
    poolFactory.createPool(_token, _token, 0);
  }

  modifier whenTokenADiffersFromTokenB(address _tokenA, address _tokenB) {
    vm.assume(_tokenA != _tokenB);
    _;
  }

  function test_RevertWhen_TheLowerTokenIsTheZeroAddress(address _token)
    external
    whenTokenADiffersFromTokenB(address(0), _token)
  {
    // it should revert
    vm.expectRevert();
    poolFactory.createPool(address(0), _token, 0);
  }

  modifier whenTheLowerTokenIsNotTheZeroAddress(address _tokenA, address _tokenB) {
    (address _token0,) = _sortTokens(_tokenA, _tokenB);
    vm.assume(_token0 != address(0));
    _;
  }

  function test_RevertWhen_TickSpacingDoesntCorrespondToAFee(
    address _tokenA,
    address _tokenB,
    uint24 _tickSpacing
  ) external whenTokenADiffersFromTokenB(_tokenA, _tokenB) whenTheLowerTokenIsNotTheZeroAddress(_tokenA, _tokenB) {
    if (poolFactory.tickSpacingToFee(int24(_tickSpacing)) != 0) {
      _tickSpacing++;
      assertEq(uint256(poolFactory.tickSpacingToFee(int24(_tickSpacing))), 0);
    }

    // it should revert
    vm.expectRevert();
    poolFactory.createPool(_tokenA, _tokenB, _tickSpacing);
  }

  modifier whenTickSpacingCorrespondsToAValidFee() {
    _;
  }

  function test_RevertWhen_ThePoolAlreadyExistsForThePair(
    address _tokenA,
    address _tokenB
  )
    external
    whenTokenADiffersFromTokenB(_tokenA, _tokenB)
    whenTheLowerTokenIsNotTheZeroAddress(_tokenA, _tokenB)
    whenTickSpacingCorrespondsToAValidFee
  {
    (address _token0, address _token1) = _sortTokens(_tokenA, _tokenB);

    _setGetPool(_token0, _token1, TICK_SPACING_60, address(1));
    assertEq(poolFactory.getPool(_token0, _token1, TICK_SPACING_60), address(1));

    // it should revert
    vm.expectRevert();
    poolFactory.createPool(_tokenA, _tokenB, uint24(TICK_SPACING_60));
  }

  modifier whenThePairHasNoPoolYet() {
    _;
  }

  function test_WhenThePairHasNoPoolYet(
    address _tokenA,
    address _tokenB,
    uint48 _timestamp
  )
    external
    whenTokenADiffersFromTokenB(_tokenA, _tokenB)
    whenTheLowerTokenIsNotTheZeroAddress(_tokenA, _tokenB)
    whenTickSpacingCorrespondsToAValidFee
    whenThePairHasNoPoolYet
  {
    address _toBePool = computeAddress(address(poolFactory), _tokenA, _tokenB, TICK_SPACING_60);

    (address _token0, address _token1) = _sortTokens(_tokenA, _tokenB);

    // it should call pool.initialize
    _mockAndExpectInitialize(_toBePool, _token0, _token1, TICK_SPACING_60);

    // it should register the pool as a target on the factory registry
    _mockAndExpectRegisterTarget(_toBePool);

    // it should emit PoolCreated
    vm.expectEmit();
    emit PoolCreated(_token0, _token1, TICK_SPACING_60, _toBePool);

    vm.warp(_timestamp);
    address _pool = poolFactory.createPool(_tokenA, _tokenB, uint24(TICK_SPACING_60));

    // it should deploy a clone at the predicted deterministic address
    assertEq(_pool, _toBePool);

    // it should store the pool in the _getPool mapping in both directions
    assertEq(poolFactory.getPool(_token0, _token1, TICK_SPACING_60), _pool);
    assertEq(poolFactory.getPool(_token1, _token0, TICK_SPACING_60), _pool);

    // it should append the pool to allPools
    assertEq(poolFactory.allPools(0), _pool);

    // it should mark the pool as a valid pool in _isPools mapping
    assertTrue(poolFactory.isPool(_pool));

    // it should push pool keyed by tokenA to poolByTokenIndex
    assertEq(_pool, ICLFactoryIndexation(address(poolFactory)).poolByTokenIndex(_tokenA, 0));

    // it should push pool keyed by tokenB to poolByTokenIndex
    assertEq(_pool, ICLFactoryIndexation(address(poolFactory)).poolByTokenIndex(_tokenB, 0));

    // it should push pool and timestamp to poolsIndex
    (address _pool0, uint48 _t0) = ICLFactoryIndexation(address(poolFactory)).poolsIndex(0);
    assertEq(_pool0, _pool);
    assertEq(uint256(_t0), uint256(_timestamp));

    address[] memory _tokens = ICLFactoryIndexation(address(poolFactory)).tokenIndexPaginated(0, 2);

    // it should add tokenA to tokenIndex
    assertEq(_tokenA, _tokens[0]);

    // it should add tokenB to tokenIndex
    assertEq(_tokenB, _tokens[1]);
  }

  function test_RevertWhen_TheRegistryRegisterTargetCallReverts(
    address _tokenA,
    address _tokenB
  )
    external
    whenTokenADiffersFromTokenB(_tokenA, _tokenB)
    whenTheLowerTokenIsNotTheZeroAddress(_tokenA, _tokenB)
    whenTickSpacingCorrespondsToAValidFee
    whenThePairHasNoPoolYet
  {
    address _toBePool = computeAddress(address(poolFactory), _tokenA, _tokenB, TICK_SPACING_60);
    (address _token0, address _token1) = _sortTokens(_tokenA, _tokenB);

    _mockAndExpectInitialize(_toBePool, _token0, _token1, TICK_SPACING_60);

    vm.mockCallRevert(
      address(factoryRegistry),
      abi.encodeWithSignature('registerTarget(address)', _toBePool),
      abi.encodePacked('TargetFactoryNotRegistered')
    );

    // it should revert
    vm.expectRevert(bytes('TargetFactoryNotRegistered'));
    poolFactory.createPool(_tokenA, _tokenB, uint24(TICK_SPACING_60));
  }

  /*////////////////////////////////////////////////////////////
                              INTERNAL HELPERS
  ////////////////////////////////////////////////////////////*/

  function _setGetPool(address _token0, address _token1, int24 _tickSpacing, address _pool) internal {
    // Resolve the `_getPool` slot via the public getter so this stays correct if the factory storage layout shifts.
    // The int24 tick spacing is sign-extended to bytes32 to match how Solidity hashes an int24 mapping key.
    stdstore.target(address(poolFactory)).sig('getPool(address,address,int24)').with_key(_token0).with_key(_token1)
      .with_key(bytes32(int256(_tickSpacing))).checked_write(_pool);
  }

  function _sortTokens(address _tokenA, address _tokenB) internal pure returns (address _token0, address _token1) {
    (_token0, _token1) = _tokenA < _tokenB ? (_tokenA, _tokenB) : (_tokenB, _tokenA);
  }

  function _mockAndExpectInitialize(address _pool, address _token0, address _token1, int24 _tickSpacing) internal {
    bytes memory _data = abi.encodeWithSelector(
      ICLPoolActions.initialize.selector,
      address(poolFactory),
      _token0,
      _token1,
      _tickSpacing,
      factoryRegistry,
      79_228_162_514_264_337_593_543_950_336
    );

    vm.mockCall(_pool, _data, '');
    vm.etch(_pool, ''); // avoid CREATE2 collision
    vm.expectCall(_pool, _data);
  }

  function _mockAndExpectRegisterTarget(address _pool) internal {
    bytes memory _registration = abi.encodeWithSignature('registerTarget(address)', _pool);
    vm.mockCall(address(factoryRegistry), _registration, '');
    vm.expectCall(address(factoryRegistry), _registration);
  }
}
