// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IFactoryRegistry} from 'contracts/core/interfaces/IFactoryRegistry.sol';
import {ILeafVoter} from 'contracts/gauge/interfaces/ILeafVoter.sol';

/// @title The interface for the CL Factory
/// @notice The CL Factory facilitates creation of CL pools and control over the protocol fees
interface ICLFactory {
  /// @notice Emitted when the owner of the factory is changed
  /// @param oldOwner The owner before the owner was changed
  /// @param newOwner The owner after the owner was changed
  event OwnerChanged(address indexed oldOwner, address indexed newOwner);

  /// @notice Emitted when the swapFeeManager of the factory is changed
  /// @param oldFeeManager The swapFeeManager before the swapFeeManager was changed
  /// @param newFeeManager The swapFeeManager after the swapFeeManager was changed
  event SwapFeeManagerChanged(address indexed oldFeeManager, address indexed newFeeManager);

  /// @notice Emitted when the unstakedFeeManager of the factory is changed
  /// @param oldFeeManager The unstakedFeeManager before the unstakedFeeManager was changed
  /// @param newFeeManager The unstakedFeeManager after the unstakedFeeManager was changed
  event UnstakedFeeManagerChanged(address indexed oldFeeManager, address indexed newFeeManager);

  /// @notice Emitted when the default swap hook of the factory is changed
  /// @param swapHook The default swap hook after it was changed
  event DefaultSwapHookChanged(address indexed swapHook);

  /// @notice Emitted when the swap hook of a specific pool is changed
  /// @param pool The pool whose swap hook was changed
  /// @param swapHook The pool swap hook after it was changed
  event PoolSwapHookChanged(address indexed pool, address indexed swapHook);

  /// @notice Emitted when the unstakedFeeModule of the factory is changed
  /// @param oldFeeModule The unstakedFeeModule before the unstakedFeeModule was changed
  /// @param newFeeModule The unstakedFeeModule after the unstakedFeeModule was changed
  event UnstakedFeeModuleChanged(address indexed oldFeeModule, address indexed newFeeModule);

  /// @notice Emitted when the defaultUnstakedFee of the factory is changed
  /// @param oldUnstakedFee The defaultUnstakedFee before the defaultUnstakedFee was changed
  /// @param newUnstakedFee The defaultUnstakedFee after the unstakedFeeModule was changed
  event DefaultUnstakedFeeChanged(uint24 indexed oldUnstakedFee, uint24 indexed newUnstakedFee);

  /// @notice Emitted when the discountRegistryManager of the factory is changed
  /// @param discountRegistryManager The discountRegistryManager after the discountRegistryManager was changed
  event DiscountRegistryManagerChanged(address indexed discountRegistryManager);

  /// @notice Emitted when the discountRegistry of the factory is changed
  /// @param discountRegistry The discountRegistry after the discountRegistry was changed
  event DiscountRegistryChanged(address indexed discountRegistry);

  /// @notice Emitted when the clPoolTape module of the factory is set or cleared
  /// @param clPoolTape The clPoolTape address after the change. The zero address disables tape registration
  event ClPoolTapeChanged(address indexed clPoolTape);

  /// @notice Emitted when the clPoolTapeManager of the factory is changed
  /// @param clPoolTapeManager The clPoolTapeManager after the change
  event ClPoolTapeManagerChanged(address indexed clPoolTapeManager);

  /// @notice Emitted when the voter of the factory is set
  /// @param voter The voter after it was set
  event VoterSet(address indexed voter);

  /// @notice Emitted when a pool is created
  /// @param token0 The first token of the pool by address sort order
  /// @param token1 The second token of the pool by address sort order
  /// @param tickSpacing The minimum number of ticks between initialized ticks
  /// @param pool The address of the created pool
  event PoolCreated(address indexed token0, address indexed token1, int24 indexed tickSpacing, address pool);

  /// @notice Emitted when a new tick spacing is enabled for pool creation via the factory
  /// @param tickSpacing The minimum number of ticks between initialized ticks for pools
  /// @param fee The default fee for a pool created with a given tickSpacing
  event TickSpacingEnabled(int24 indexed tickSpacing, uint24 indexed fee);

  /// @notice The LeafVoter contract, used to check gauge activation for unstaked fees
  /// @dev May be the zero address until set via setVoter, as the voter can be deployed
  ///      after the factory. Unstaked fees are zero until it is set
  /// @return The address of the LeafVoter contract
  function voter() external view returns (ILeafVoter);

  /// @notice The address of the pool implementation contract used to deploy proxies / clones
  /// @return The address of the pool implementation contract
  function poolImplementation() external view returns (address);

  /// @notice Factory registry that records pools as gauge targets
  /// @dev Set at construction. Every created pool is registered as a target;
  ///      pool creation reverts until this factory is an approved target factory
  ///      in the registry
  /// @return The address of the factory registry
  function factoryRegistry() external view returns (IFactoryRegistry);

  /// @notice Returns the current owner of the factory
  /// @dev Can be changed by the current owner via setOwner
  /// @return The address of the factory owner
  function owner() external view returns (address);

  /// @notice Returns the current swapFeeManager of the factory
  /// @dev Can be changed by the current swap fee manager via setSwapFeeManager
  /// @return The address of the factory swapFeeManager
  function swapFeeManager() external view returns (address);

  /// @notice Returns the current unstakedFeeManager of the factory
  /// @dev Can be changed by the current unstaked fee manager via setUnstakedFeeManager
  /// @return The address of the factory unstakedFeeManager
  function unstakedFeeManager() external view returns (address);

  /// @notice Returns the factory-wide default swap hook used when a pool has no hook set
  /// @dev Can be changed by the current swap fee manager via setDefaultSwapHook
  /// @return The address of the factory defaultSwapHook
  function defaultSwapHook() external view returns (address);

  /// @notice Returns the swap hook override set for a specific pool.
  /// @param pool The pool to query
  /// @return The pool swap hook override, or address(0) if unset
  function poolSwapHook(address pool) external view returns (address);

  /// @notice Resolves the swap hook address for a pool. If the pool doesn't have a swap hook specified,
  ///         then the default hook address is returned.
  /// @param pool The pool to resolve the swap hook for
  /// @return The swap hook address for the pool
  function getPoolSwapHook(address pool) external view returns (address);

  /// @notice Returns the current unstakedFeeModule of the factory
  /// @dev Can be changed by the current unstaked fee manager via setUnstakedFeeModule
  /// @return The address of the factory unstakedFeeModule
  function unstakedFeeModule() external view returns (address);

  /// @notice Returns the current defaultUnstakedFee of the factory
  /// @dev Can be changed by the current unstaked fee manager via setDefaultUnstakedFee
  /// @return The default Unstaked Fee of the factory
  function defaultUnstakedFee() external view returns (uint24);

  /// @notice The current manager of {discountRegistry} of the factory
  /// @return The address of the discount registry manager
  function discountRegistryManager() external view returns (address);

  /// @notice Discount registry for swap fee discounts
  /// @return The address of the discount registry
  function discountRegistry() external view returns (address);

  /// @notice The clPoolTape module new pools are registered with. The zero address means registration is disabled
  /// @return The address of the clPoolTape module
  function clPoolTape() external view returns (address);

  /// @notice The current clPoolTapeManager of the factory
  /// @dev Can be changed by the current clPoolTapeManager via setClPoolTapeManager
  /// @return The address of the clPoolTapeManager
  function clPoolTapeManager() external view returns (address);

  /// @notice Returns a default fee for a tick spacing.
  /// @dev Use getFee for the most up to date fee for a given pool.
  /// A tick spacing can never be removed, so this value should be hard coded or cached in the calling context
  /// @param tickSpacing The enabled tick spacing. Returns 0 if not enabled
  /// @return fee The default fee for the given tick spacing
  function tickSpacingToFee(int24 tickSpacing) external view returns (uint24 fee);

  /// @notice Returns a list of enabled tick spacings. Used to iterate through pools created by the factory
  /// @dev Tick spacings cannot be removed. Tick spacings are not ordered
  /// @return List of enabled tick spacings
  function tickSpacings() external view returns (int24[] memory);

  /// @notice Returns the pool address for a given pair of tokens and a tick spacing, or address 0 if it does not exist
  /// @dev tokenA and tokenB may be passed in either token0/token1 or token1/token0 order
  /// @param tokenA The contract address of either token0 or token1
  /// @param tokenB The contract address of the other token
  /// @param tickSpacing The tick spacing of the pool in uint24
  /// @return pool The pool address
  function getPool(address tokenA, address tokenB, uint24 tickSpacing) external view returns (address pool);

  /// @notice Returns the pool address for a given pair of tokens and a tick spacing, or address 0 if it does not exist
  /// @dev tokenA and tokenB may be passed in either token0/token1 or token1/token0 order
  /// @param tokenA The contract address of either token0 or token1
  /// @param tokenB The contract address of the other token
  /// @param tickSpacing The tick spacing of the pool
  /// @return pool The pool address
  function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address pool);

  /// @notice Return address of pool created by this factory given its `index`
  /// @param index Index of the pool
  /// @return The pool address in the given index
  function allPools(uint256 index) external view returns (address);

  /// @notice Returns the number of pools created from this factory
  /// @return Number of pools created from this factory
  function allPoolsLength() external view returns (uint256);

  /// @notice Used in VotingEscrow to determine if a contract is a valid pool of the factory
  /// @param pool The address of the pool to check
  /// @return Whether the pool is a valid pool of the factory
  function isPool(address pool) external view returns (bool);

  /// @notice Get unstaked fee for a given pool. Accounts for default and dynamic fees
  /// @dev Unstaked fee is denominated in pips. i.e. 1e-6
  /// @param pool The pool to get the unstaked fee for
  /// @return The unstaked fee for the given pool
  function getUnstakedFee(address pool) external view returns (uint24);

  /// @notice Creates a pool for the given two tokens and tick spacing
  /// @param tokenA One of the two tokens in the desired pool
  /// @param tokenB The other of the two tokens in the desired pool
  /// @param tickSpacing The desired tick spacing for the pool
  /// @dev Use encodeSqrtPrice(1,1) as price
  /// @dev Used to programmatically create pools in case one does not exist
  /// @dev Invalid tickSpacing will revert the transaction
  /// @return pool The address of the newly created pool
  function createPool(address tokenA, address tokenB, uint24 tickSpacing) external returns (address pool);

  /// @notice Creates a pool for the given two tokens and tick spacing
  /// @param tokenA One of the two tokens in the desired pool
  /// @param tokenB The other of the two tokens in the desired pool
  /// @param tickSpacing The desired tick spacing for the pool
  /// @param sqrtPriceX96 The initial sqrt price of the pool, as a Q64.96
  /// @dev tokenA and tokenB may be passed in either order: token0/token1 or token1/token0. The call will
  /// revert if the pool already exists, the tick spacing is invalid, or the token arguments are invalid
  /// @return pool The address of the newly created pool
  function createPool(
    address tokenA,
    address tokenB,
    int24 tickSpacing,
    uint160 sqrtPriceX96
  ) external returns (address pool);

  /// @notice Updates the owner of the factory
  /// @dev Must be called by the current owner
  /// @param _owner The new owner of the factory
  function setOwner(address _owner) external;

  /// @notice Sets the voter of the factory
  /// @dev Must be called by the current owner. Callable only while the voter is unset,
  ///      so once set the voter is immutable. Used when the factory is deployed before the voter
  /// @param _voter The voter of the factory
  function setVoter(address _voter) external;

  /// @notice Updates the swapFeeManager of the factory
  /// @dev Must be called by the current swap fee manager
  /// @param _swapFeeManager The new swapFeeManager of the factory
  function setSwapFeeManager(address _swapFeeManager) external;

  /// @notice Updates the unstakedFeeManager of the factory
  /// @dev Must be called by the current unstaked fee manager
  /// @param _unstakedFeeManager The new unstakedFeeManager of the factory
  function setUnstakedFeeManager(address _unstakedFeeManager) external;

  /// @notice Updates the discountRegistryManager of the factory
  /// @dev Must be called by the current discount registry manager
  /// @param _discountRegistryManager The new discountRegistryManager of the factory
  function setDiscountRegistryManager(address _discountRegistryManager) external;

  /// @notice Updates the unstakedFeeModule of the factory
  /// @dev Must be called by the current unstaked fee manager
  /// @param _unstakedFeeModule The new unstakedFeeModule of the factory
  function setUnstakedFeeModule(address _unstakedFeeModule) external;

  /// @notice Updates the defaultUnstakedFee of the factory
  /// @dev Must be called by the current unstaked fee manager
  /// @param _defaultUnstakedFee The new defaultUnstakedFee of the factory
  function setDefaultUnstakedFee(uint24 _defaultUnstakedFee) external;

  /// @notice Updates the factory-wide default swap hook
  /// @dev Must be called by the current swap fee manager
  /// @param _swapHook The new default swap hook of the factory
  function setDefaultSwapHook(address _swapHook) external;

  /// @notice Sets the swap hook override for a batch of pools
  /// @dev Must be called by the current swap fee manager. Reverts with 'LMM' if the array lengths differ.
  ///      For each pool, passing address(0) clears its override back to the default.
  /// @param _pools The pools to set swap hooks for
  /// @param _swapHooks The new swapHook for each corresponding pool
  function setPoolSwapHook(address[] calldata _pools, address[] calldata _swapHooks) external;

  /// @notice Updates the discountRegistry of the factory
  /// @dev Must be called by the current discount registry manager
  /// @param _discountRegistry The new discountRegistry of the factory
  function setDiscountRegistry(address _discountRegistry) external;

  /// @notice Updates the clPoolTapeManager of the factory
  /// @dev Must be called by the current clPoolTapeManager
  /// @param _clPoolTapeManager The new clPoolTapeManager of the factory
  function setClPoolTapeManager(address _clPoolTapeManager) external;

  /// @notice Sets or clears the clPoolTape module new pools are registered with
  /// @dev Must be called by the clPoolTapeManager. The zero address disables tape registration
  /// @param _clPoolTape The new clPoolTape module address
  function setClPoolTape(address _clPoolTape) external;

  /// @notice Enables a certain tickSpacing
  /// @dev Tick spacings may never be removed once enabled
  /// @param tickSpacing The spacing between ticks to be enforced in the pool
  /// @param fee The default fee associated with a given tick spacing
  function enableTickSpacing(int24 tickSpacing, uint24 fee) external;
}
