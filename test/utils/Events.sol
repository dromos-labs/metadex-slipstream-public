pragma solidity ^0.7.6;
pragma abicoder v2;

import {IDiscountRegistry} from 'contracts/core/interfaces/fees/IDiscountRegistry.sol';
import {ICLPoolTape} from 'contracts/core/interfaces/tape/ICLPoolTape.sol';

/// @notice Events for all contracts
abstract contract Events {
  ///
  /// Pool Factory Events
  ///
  event SwapFeeManagerChanged(address indexed oldFeeManager, address indexed newFeeManager);
  event SwapFeeModuleChanged(address indexed oldFeeModule, address indexed newFeeModule);
  event UnstakedFeeManagerChanged(address indexed oldFeeManager, address indexed newFeeManager);
  event UnstakedFeeModuleChanged(address indexed oldFeeModule, address indexed newFeeModule);
  event DefaultUnstakedFeeChanged(uint24 indexed oldUnstakedFee, uint24 indexed newUnstakedFee);
  event DiscountRegistryManagerChanged(address indexed discountRegistryManager);
  event DiscountRegistryChanged(address indexed discountRegistry);
  event ClPoolTapeChanged(address indexed clPoolTape);
  event ClPoolTapeManagerChanged(address indexed clPoolTapeManager);
  event OwnerChanged(address indexed oldOwner, address indexed newOwner);
  event VoterSet(address indexed voter);
  event PoolCreated(address indexed token0, address indexed token1, int24 indexed tickSpacing, address pool);
  event TickSpacingEnabled(int24 indexed tickSpacing, uint24 indexed fee);
  event DefaultSwapHookChanged(address indexed swapHook);
  event PoolSwapHookChanged(address indexed pool, address indexed swapHook);

  ///
  /// Custom Fee Module Events
  ///

  event CustomFeeSet(address indexed pool, uint24 indexed fee);
  event FeeCapSet(address indexed pool, uint256 indexed feeCap);
  event DiscountedRegistered(address indexed discountReceiver, uint24 indexed discount);
  event DiscountedDeregistered(address indexed discountOver);
  event SecondsAgoSet(uint32 indexed secondsAgo);
  event ScalingFactorSet(address indexed pool, uint256 indexed scalingFactor);
  event DefaultScalingFactorSet(uint256 indexed defaultScalingFactor);
  event DefaultFeeCapSet(uint256 indexed defaultFeeCap);
  event DynamicFeeReset(address indexed pool);
  event InitialFeeSet(address indexed pool, uint24 indexed initialFee);
  event InitialFeeDisabled(address indexed pool);

  ///
  /// ERC20 Events
  ///
  event Transfer(address indexed from, address indexed to, uint256 value);

  ///
  /// CLGauge Events
  ///
  event Deposit(address indexed _caller, address indexed _user, uint256 indexed _tokenId, uint128 _liquidityToStake);
  event Withdraw(address indexed _caller, address indexed _user, uint256 indexed _tokenId, uint128 _liquidityToStake);
  event EmissionsClaimed(
    address indexed _account, uint256 indexed _tokenId, address indexed _recipient, uint256 _rewardAmount
  );
  event EmissionsDeferred(address indexed _account, uint256 indexed _tokenId, uint256 _rewardAmount);
  event ReferralEmissionsDeferred(
    address indexed _account, uint256 indexed _tokenId, address indexed _referral, uint256 _amount
  );
  event DeferredEmissionsClaimed(address indexed _account, address indexed _recipient, uint256 _amount);
  event ReferralEmissionsClaimed(address indexed _referral, address indexed _recipient, uint256 _amount);
  event EarlyWithdrawPenalty(address indexed _from, uint256 indexed _tokenId, uint256 _penalty);
  event GaugeSettled(uint256 _cumulativeRewardShare, uint256 _delta);

  ///
  /// Operator Approval Events
  ///
  event ClaimApproval(address indexed _account, address indexed _operator, bool _approved);
  event Approval(address indexed _owner, address indexed _operator, uint256 indexed _tokenId);
  event ApprovalForAll(address indexed _owner, address indexed _operator, bool _approved);

  ///
  /// CLPool Events
  ///
  event Flash(
    address indexed sender, address indexed recipient, uint256 amount0, uint256 amount1, uint256 paid0, uint256 paid1
  );

  ///
  /// NonfungiblePositionManager Events
  ///
  event IncreaseLiquidity(
    uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1, int24 tickLower, int24 tickUpper
  );
}
