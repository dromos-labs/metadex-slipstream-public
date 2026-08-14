// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import './CLPool.sol';
import './indexation/CLFactoryIndexation.sol';
import './interfaces/ICLFactory.sol';
import './interfaces/IFactoryRegistry.sol';
import './interfaces/IVoter.sol';
import './interfaces/fees/IFeeModule.sol';
import './interfaces/tape/IBasePoolTape.sol';
import '@nomad-xyz/excessively-safe-call/src/ExcessivelySafeCall.sol';
import '@openzeppelin/contracts/proxy/Clones.sol';

/// @title Canonical CL factory
/// @notice Deploys CL pools and manages ownership and control over pool protocol fees
contract CLFactory is CLFactoryIndexation, ICLFactory {
  using ExcessivelySafeCall for address;

  // TODO: Revisit this value
  uint16 internal constant DEFAULT_POOL_TAPE_CARDINALITY = 100;

  /// @inheritdoc ICLFactory
  IVoter public immutable override voter;
  /// @inheritdoc ICLFactory
  address public immutable override poolImplementation;
  /// @inheritdoc ICLFactory
  IFactoryRegistry public immutable override factoryRegistry;

  /// @inheritdoc ICLFactory
  address public override owner;
  /// @inheritdoc ICLFactory
  address public override swapFeeManager;
  /// @inheritdoc ICLFactory
  address public override swapFeeModule;
  /// @inheritdoc ICLFactory
  address public override unstakedFeeManager;
  /// @inheritdoc ICLFactory
  address public override unstakedFeeModule;
  /// @inheritdoc ICLFactory
  address public override swapHookManager;
  /// @inheritdoc ICLFactory
  address public override defaultSwapHook;
  /// @inheritdoc ICLFactory
  mapping(address => address) public override poolSwapHook;
  /// @inheritdoc ICLFactory
  uint24 public override defaultUnstakedFee;
  /// @inheritdoc ICLFactory
  address public override discountRegistryManager;
  /// @inheritdoc ICLFactory
  address public override discountRegistry;
  /// @inheritdoc ICLFactory
  address public override clPoolTape;
  /// @inheritdoc ICLFactory
  address public override clPoolTapeManager;

  /// @inheritdoc ICLFactory
  mapping(int24 => uint24) public override tickSpacingToFee;
  /// @dev Used in VotingEscrow to determine if a contract is a valid pool
  mapping(address => bool) private _isPool;
  /// @inheritdoc ICLFactory
  address[] public override allPools;

  int24[] private _tickSpacings;
  mapping(address => mapping(address => mapping(int24 => address))) internal _getPool;

  constructor(
    address _owner,
    address _swapFeeManager,
    address _unstakedFeeManager,
    address _voter,
    address _poolImplementation,
    address _swapHookManager,
    address _defaultSwapHook,
    address _discountRegistryManager,
    address _clPoolTapeManager
  ) {
    require(_owner != address(0), 'OwnerIsZero');
    require(_swapFeeManager != address(0), 'SwapFeeManagerIsZero');
    require(_unstakedFeeManager != address(0), 'UnstakedFeeManagerIsZero');
    require(_poolImplementation != address(0), 'PoolImplementationIsZero');
    require(_swapHookManager != address(0), 'SwapHookManagerIsZero');
    require(_discountRegistryManager != address(0), 'DiscountRegistryManagerIsZero');
    require(_clPoolTapeManager != address(0), 'ClPoolTapeManagerIsZero');
    owner = _owner;
    swapFeeManager = _swapFeeManager;
    unstakedFeeManager = _unstakedFeeManager;
    voter = IVoter(_voter);
    factoryRegistry = IVoter(_voter).factoryRegistry();
    poolImplementation = _poolImplementation;
    swapHookManager = _swapHookManager;
    defaultSwapHook = _defaultSwapHook;
    discountRegistryManager = _discountRegistryManager;
    clPoolTapeManager = _clPoolTapeManager;
    defaultUnstakedFee = 100_000;
    emit OwnerChanged(address(0), _owner);
    emit SwapFeeManagerChanged(address(0), _swapFeeManager);
    emit UnstakedFeeManagerChanged(address(0), _unstakedFeeManager);
    emit DefaultUnstakedFeeChanged(0, 100_000);
    emit SwapHookManagerChanged(_swapHookManager);
    emit DefaultSwapHookChanged(_defaultSwapHook);
    emit DiscountRegistryManagerChanged(_discountRegistryManager);
    emit ClPoolTapeManagerChanged(_clPoolTapeManager);

    enableTickSpacing(1, 100);
    enableTickSpacing(50, 500);
    enableTickSpacing(100, 500);
    enableTickSpacing(200, 3000);
    enableTickSpacing(2000, 10_000);
  }

  /// @inheritdoc ICLFactory
  function createPool(address tokenA, address tokenB, uint24 tickSpacing) external override returns (address) {
    return createPool({
      tokenA: tokenA,
      tokenB: tokenB,
      tickSpacing: int24(tickSpacing),
      sqrtPriceX96: 79_228_162_514_264_337_593_543_950_336 // encodePriceSqrt(1, 1)
    });
  }

  /// @inheritdoc ICLFactory
  function createPool(
    address tokenA,
    address tokenB,
    int24 tickSpacing,
    uint160 sqrtPriceX96
  ) public override returns (address pool) {
    require(tokenA != tokenB);
    (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    require(token0 != address(0));
    require(tickSpacingToFee[tickSpacing] != 0);
    require(_getPool[token0][token1][tickSpacing] == address(0));
    pool =
      Clones.cloneDeterministic({master: poolImplementation, salt: keccak256(abi.encode(token0, token1, tickSpacing))});
    CLPool(pool)
      .initialize({
      _factory: address(this),
      _token0: token0,
      _token1: token1,
      _tickSpacing: tickSpacing,
      _factoryRegistry: address(factoryRegistry),
      _sqrtPriceX96: sqrtPriceX96
    });
    allPools.push(pool);
    _isPool[pool] = true;
    _getPool[token0][token1][tickSpacing] = pool;
    // populate mapping in the reverse direction, deliberate choice to avoid the cost of comparing addresses
    _getPool[token1][token0][tickSpacing] = pool;

    /// @dev This function is invoked only after the pool is deployed
    ///      and only after all validations are passed.
    _createPoolHook({_tokenA: tokenA, _tokenB: tokenB, _pool: pool});

    address cachedClPoolTape = clPoolTape;
    if (cachedClPoolTape != address(0)) {
      cachedClPoolTape.excessivelySafeCall(
        gasleft(),
        0,
        abi.encodeWithSelector(
          IBasePoolTape.increaseObservationCardinalityNext.selector, pool, DEFAULT_POOL_TAPE_CARDINALITY
        )
      );
    }

    emit PoolCreated(token0, token1, tickSpacing, pool);
  }

  /// @inheritdoc ICLFactory
  function setOwner(address _owner) external override {
    address cachedOwner = owner;
    require(msg.sender == cachedOwner);
    require(_owner != address(0));
    emit OwnerChanged(cachedOwner, _owner);
    owner = _owner;
  }

  /// @inheritdoc ICLFactory
  function setSwapFeeManager(address _swapFeeManager) external override {
    address cachedSwapFeeManager = swapFeeManager;
    require(msg.sender == cachedSwapFeeManager);
    require(_swapFeeManager != address(0));
    swapFeeManager = _swapFeeManager;
    emit SwapFeeManagerChanged(cachedSwapFeeManager, _swapFeeManager);
  }

  /// @inheritdoc ICLFactory
  function setUnstakedFeeManager(address _unstakedFeeManager) external override {
    address cachedUnstakedFeeManager = unstakedFeeManager;
    require(msg.sender == cachedUnstakedFeeManager);
    require(_unstakedFeeManager != address(0));
    unstakedFeeManager = _unstakedFeeManager;
    emit UnstakedFeeManagerChanged(cachedUnstakedFeeManager, _unstakedFeeManager);
  }

  /// @inheritdoc ICLFactory
  function setSwapHookManager(address _swapHookManager) external override {
    require(msg.sender == swapHookManager, 'NotSwapHookManager');
    require(_swapHookManager != address(0), 'SwapHookManagerIsZero');

    swapHookManager = _swapHookManager;
    emit SwapHookManagerChanged(_swapHookManager);
  }

  /// @inheritdoc ICLFactory
  function setDiscountRegistryManager(address _discountRegistryManager) external override {
    require(msg.sender == discountRegistryManager, 'NotDiscountRegistryManager');
    require(_discountRegistryManager != address(0), 'DiscountRegistryManagerIsZero');

    discountRegistryManager = _discountRegistryManager;
    emit DiscountRegistryManagerChanged(_discountRegistryManager);
  }

  /// @inheritdoc ICLFactory
  function setSwapFeeModule(address _swapFeeModule) external override {
    require(msg.sender == swapFeeManager);
    require(_swapFeeModule != address(0));
    address oldFeeModule = swapFeeModule;
    swapFeeModule = _swapFeeModule;
    emit SwapFeeModuleChanged(oldFeeModule, _swapFeeModule);
  }

  /// @inheritdoc ICLFactory
  function setUnstakedFeeModule(address _unstakedFeeModule) external override {
    require(msg.sender == unstakedFeeManager);
    require(_unstakedFeeModule != address(0));
    address oldFeeModule = unstakedFeeModule;
    unstakedFeeModule = _unstakedFeeModule;
    emit UnstakedFeeModuleChanged(oldFeeModule, _unstakedFeeModule);
  }

  /// @inheritdoc ICLFactory
  function setDefaultUnstakedFee(uint24 _defaultUnstakedFee) external override {
    require(msg.sender == unstakedFeeManager);
    require(_defaultUnstakedFee <= 500_000);
    uint24 oldUnstakedFee = defaultUnstakedFee;
    defaultUnstakedFee = _defaultUnstakedFee;
    emit DefaultUnstakedFeeChanged(oldUnstakedFee, _defaultUnstakedFee);
  }

  /// @inheritdoc ICLFactory
  function setDefaultSwapHook(address _swapHook) external override {
    require(msg.sender == swapHookManager, 'NotSwapHookManager');
    defaultSwapHook = _swapHook;

    emit DefaultSwapHookChanged(_swapHook);
  }

  /// @inheritdoc ICLFactory
  function getPoolSwapHook(address _pool) external view override returns (address) {
    address poolHook = poolSwapHook[_pool];
    return poolHook == address(0) ? defaultSwapHook : poolHook;
  }

  /// @inheritdoc ICLFactory
  function setPoolSwapHook(address[] calldata _pools, address[] calldata _swapHooks) external override {
    require(msg.sender == swapHookManager, 'NotSwapHookManager');
    uint256 poolsLength = _pools.length;
    require(poolsLength == _swapHooks.length, 'LMM');

    address pool;
    address hook;
    for (uint256 i = 0; i < poolsLength; i++) {
      pool = _pools[i];
      hook = _swapHooks[i];
      poolSwapHook[pool] = hook;
      emit PoolSwapHookChanged(pool, hook);
    }
  }

  /// @inheritdoc ICLFactory
  function setDiscountRegistry(address _discountRegistry) external override {
    require(msg.sender == discountRegistryManager, 'NotDiscountRegistryManager');
    require(_discountRegistry != address(0), 'DiscountRegistryIsZero');

    discountRegistry = _discountRegistry;

    emit DiscountRegistryChanged(_discountRegistry);
  }

  /// @inheritdoc ICLFactory
  function setClPoolTapeManager(address _clPoolTapeManager) external override {
    require(msg.sender == clPoolTapeManager, 'NotClPoolTapeManager');
    require(_clPoolTapeManager != address(0), 'ClPoolTapeManagerIsZero');
    clPoolTapeManager = _clPoolTapeManager;
    emit ClPoolTapeManagerChanged(_clPoolTapeManager);
  }

  /// @inheritdoc ICLFactory
  function setClPoolTape(address _clPoolTape) external override {
    require(msg.sender == clPoolTapeManager, 'NotClPoolTapeManager');
    clPoolTape = _clPoolTape;
    emit ClPoolTapeChanged(_clPoolTape);
  }

  /// @inheritdoc ICLFactory
  function getSwapFee(address pool) external view override returns (uint24) {
    if (swapFeeModule != address(0)) {
      (bool success, bytes memory data) =
        swapFeeModule.excessivelySafeStaticCall(200_000, 32, abi.encodeWithSelector(IFeeModule.getFee.selector, pool));
      if (success) {
        uint24 fee = abi.decode(data, (uint24));
        if (fee <= 100_000) {
          return fee;
        }
      }
    }
    return tickSpacingToFee[CLPool(pool).tickSpacing()];
  }

  /// @inheritdoc ICLFactory
  function getUnstakedFee(address pool) external view override returns (uint24) {
    address gauge = voter.gauges(pool);
    if (!voter.isAlive(gauge) || gauge == address(0)) {
      return 0;
    }
    if (unstakedFeeModule != address(0)) {
      (bool success, bytes memory data) = unstakedFeeModule.excessivelySafeStaticCall(
        200_000, 32, abi.encodeWithSelector(IFeeModule.getFee.selector, pool)
      );
      if (success) {
        uint24 fee = abi.decode(data, (uint24));
        if (fee <= 1_000_000) {
          return fee;
        }
      }
    }
    return defaultUnstakedFee;
  }

  /// @inheritdoc ICLFactory
  function enableTickSpacing(int24 tickSpacing, uint24 fee) public override {
    require(msg.sender == owner);
    require(fee > 0 && fee <= 100_000);
    // tick spacing is capped at 16384 to prevent the situation where tickSpacing is so large that
    // TickBitmap#nextInitializedTickWithinOneWord overflows int24 container from a valid tick
    // 16384 ticks represents a >5x price change with ticks of 1 bips
    require(tickSpacing > 0 && tickSpacing < 16_384);
    require(tickSpacingToFee[tickSpacing] == 0);

    tickSpacingToFee[tickSpacing] = fee;
    _tickSpacings.push(tickSpacing);
    emit TickSpacingEnabled(tickSpacing, fee);
  }

  function getPool(address tokenA, address tokenB, int24 tickSpacing) external view override returns (address) {
    return _getPool[tokenA][tokenB][tickSpacing];
  }

  function getPool(address tokenA, address tokenB, uint24 tickSpacing) external view override returns (address) {
    return _getPool[tokenA][tokenB][int24(tickSpacing)];
  }

  /// @inheritdoc ICLFactory
  function tickSpacings() external view override returns (int24[] memory) {
    return _tickSpacings;
  }

  /// @inheritdoc ICLFactory
  function allPoolsLength() external view override returns (uint256) {
    return allPools.length;
  }

  /// @inheritdoc ICLFactory
  function isPool(address pool) external view override returns (bool) {
    return _isPool[pool];
  }
}
