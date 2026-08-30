// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity =0.7.6;
pragma abicoder v2;

import {ERC721Holder} from '@openzeppelin/contracts/token/ERC721/ERC721Holder.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/SafeCast.sol';

import {FullMath} from 'contracts/core/libraries/FullMath.sol';
import {EnumerableSet} from 'contracts/libraries/EnumerableSet.sol';

import {ICLGauge} from 'contracts/gauge/interfaces/ICLGauge.sol';
import {ICLGaugeFactory} from 'contracts/gauge/interfaces/ICLGaugeFactory.sol';
import {ICLPool} from 'contracts/gauge/interfaces/ICLPool.sol';
import {IGauge} from 'contracts/gauge/interfaces/IGauge.sol';
import {ILeafVoter} from 'contracts/gauge/interfaces/ILeafVoter.sol';
import {INonfungiblePositionManager} from 'contracts/gauge/interfaces/INonfungiblePositionManager.sol';

import {Gauge} from 'contracts/gauge/Gauge.sol';

contract CLGauge is Gauge, ICLGauge, ERC721Holder {
  using EnumerableSet for EnumerableSet.UintSet;
  using SafeCast for uint256;
  using SafeCast for int256;

  uint256 internal constant Q128 = 0x100000000000000000000000000000000;

  /// @inheritdoc ICLGauge
  INonfungiblePositionManager public immutable override nft;

  /// @inheritdoc ICLGauge
  ICLPool public override pool;

  /// @inheritdoc ICLGauge
  address public override token0;
  /// @inheritdoc ICLGauge
  address public override token1;
  /// @inheritdoc ICLGauge
  int24 public override tickSpacing;

  /// @inheritdoc ICLGauge
  mapping(uint256 => uint256) public override rewardGrowthInside;
  /// @inheritdoc ICLGauge
  mapping(uint256 => uint256) public override depositBlock;
  /// @inheritdoc ICLGauge
  mapping(address => uint256) public override deferredEmissions;

  /// @dev The set of all staked nfts for a given address
  mapping(address => EnumerableSet.UintSet) internal _stakes;
  /// @dev Staked position owner (tokenId => owner); written on deposit, cleared on withdrawal.
  ///      Gates approve() to staked positions and ensures only the staked owner can approve operators.
  mapping(uint256 => address) internal _stakeOwner;
  /// @dev Per-tokenId withdrawal approval (tokenId => operator)
  mapping(uint256 => address) internal _tokenApprovals;
  /// @dev Blanket withdrawal authorization (owner => operator => approved)
  mapping(address => mapping(address => bool)) internal _approvedForAll;

  constructor(address _voter, address _nft, address _gaugeFactory) Gauge(_voter, _gaugeFactory) {
    nft = INonfungiblePositionManager(_nft);
  }

  /// @inheritdoc ICLGauge
  function initialize(
    address _pool,
    address _votingRewardsManager,
    address _token0,
    address _token1,
    int24 _tickSpacing,
    bool _isPool
  ) external override {
    require(msg.sender == gaugeFactory, 'NA');
    require(address(pool) == address(0), 'AI');
    pool = ICLPool(_pool);
    votingRewardsManager = _votingRewardsManager;
    token0 = _token0;
    token1 = _token1;
    tickSpacing = _tickSpacing;
    isPool = _isPool;
  }

  /// @inheritdoc ICLGauge
  function settleGauge() external override returns (uint256 _delta) {
    require(msg.sender == address(pool), 'NA');
    uint256 _cumulativeRewardShare = ILeafVoter(voter).settleGauge(address(this));
    uint256 _lastCumulativeRewardShare = lastCumulativeRewardShare;

    // @dev A deregistered gauge reports a cumulative share of 0; guard against any
    //      regression so the cursor delta can never underflow
    if (_cumulativeRewardShare <= _lastCumulativeRewardShare) return 0;

    _delta = _cumulativeRewardShare - _lastCumulativeRewardShare;
    lastCumulativeRewardShare = _cumulativeRewardShare;

    emit GaugeSettled(_cumulativeRewardShare, _delta);
  }

  /// @inheritdoc ICLGauge
  function forfeitRollover() external override nonReentrant {
    uint256 _rollover = pool.settleToBlock();
    if (_rollover > 0) {
      ILeafVoter(voter).forfeitEmissions(_rollover.toUint128());
    }
  }

  /// @inheritdoc IGauge
  function claimEmissions(address _account, address _recipient) external override(Gauge, IGauge) nonReentrant {
    require(msg.sender == _account || approvedForClaim[_account][msg.sender], 'NA');

    _claimPositions(_account, _stakes[_account].values(), _recipient);
  }

  /// @inheritdoc ICLGauge
  function claimEmissions(
    address _account,
    address _recipient,
    uint256[] calldata _tokenIds
  ) external override nonReentrant {
    require(msg.sender == _account || approvedForClaim[_account][msg.sender], 'NA');

    uint256 _length = _tokenIds.length;
    for (uint256 i = 0; i < _length; i++) {
      require(_stakes[_account].contains(_tokenIds[i]), 'NA');
    }

    _claimPositions(_account, _tokenIds, _recipient);
  }

  /// @inheritdoc IGauge
  function collectFees() external override nonReentrant returns (uint256, uint256) {
    address _votingRewardsManager = votingRewardsManager;
    require(msg.sender == _votingRewardsManager, 'NVRM');
    if (!isPool) return (0, 0);
    if (!_isActivated()) return (0, 0);
    if (ICLGaugeFactory(gaugeFactory).emissionCap(address(this)) == 0) return (0, 0);

    (uint128 _claimed0, uint128 _claimed1) = pool.collectFees(_votingRewardsManager);

    if (_claimed0 > 0 || _claimed1 > 0) {
      emit ClaimFees(msg.sender, _claimed0, _claimed1);
    }

    return (_claimed0, _claimed1);
  }

  /// @inheritdoc IGauge
  function pendingFees() external view override returns (uint256, uint256) {
    if (!isPool) return (0, 0);
    if (!_isActivated()) return (0, 0);
    if (ICLGaugeFactory(gaugeFactory).emissionCap(address(this)) == 0) return (0, 0);

    (uint128 _fees0, uint128 _fees1) = pool.gaugeFees();
    return (_fees0 > 1 ? _fees0 - 1 : 0, _fees1 > 1 ? _fees1 - 1 : 0);
  }

  /// @inheritdoc IGauge
  function approve(address operator, uint256 tokenId) external override {
    // Only staked positions can be approved. _stakeOwner[tokenId] is address(0) for unstaked positions.
    require(msg.sender == _stakeOwner[tokenId], 'NA');
    _tokenApprovals[tokenId] = operator;
    emit Approval(msg.sender, operator, tokenId);
  }

  /// @inheritdoc ICLGauge
  function getApproved(uint256 tokenId) external view override returns (address) {
    return _tokenApprovals[tokenId];
  }

  /// @inheritdoc IGauge
  function earned(address _account) external view override(Gauge, IGauge) returns (uint256) {
    return earned(_account, _stakes[_account].values());
  }

  /// @inheritdoc ICLGauge
  function earned(address _account, uint256[] memory _tokenIds) public view override returns (uint256) {
    uint256 _rewardGrowthGlobalX128 = pool.rewardGrowthGlobalX128();
    uint256 _stakedLiquidity = pool.stakedLiquidity();

    // @dev Simulate pool rewardGrowthGlobalX128 advance in memory with the emissions
    //      accrued in the LeafVoter since the gauge's last settlement
    if (_stakedLiquidity > 0) {
      uint256 _cumulativeRewardShare = ILeafVoter(voter).projectedCumulativeRewardShare(address(this));
      uint256 _lastCumulativeRewardShare = lastCumulativeRewardShare;

      // @dev Ignore a regressed projection (e.g. a deregistered gauge reporting 0), matching settleGauge
      if (_cumulativeRewardShare > _lastCumulativeRewardShare) {
        _rewardGrowthGlobalX128 += FullMath.mulDiv(
          _cumulativeRewardShare - _lastCumulativeRewardShare, Q128, _stakedLiquidity
        );
      }
    }

    // @dev Load the gauge's referral and penalty config
    (address _referral, uint256 _referralShare) = ICLGaugeFactory(gaugeFactory).referralConfig(address(this));
    ICLGaugeFactory.PenaltyConfig memory _penaltyConfig =
      ICLGaugeFactory(gaugeFactory).effectivePenaltyConfig(address(this));

    uint256 _total;
    uint256 _tokenId;
    for (uint256 i = 0; i < _tokenIds.length; i++) {
      _tokenId = _tokenIds[i];
      require(_stakes[_account].contains(_tokenId), 'NA');

      // @dev Compute the position's accrued emissions
      (uint256 _reward,) = _earned(_tokenId, _rewardGrowthGlobalX128);

      // @dev Apply the early unstake penalty and referral fee
      if (_reward > 0) {
        _reward -= _applyPenalty(depositBlock[_tokenId], _reward, _penaltyConfig);
        _reward -= _applyReferral(_reward, _referral, _referralShare);
      }
      _total += _reward;
    }
    return _total + deferredEmissions[_account];
  }

  /// @inheritdoc IGauge
  function isApprovedForAll(address owner, address operator) external view override returns (bool) {
    return _approvedForAll[owner][operator];
  }

  /// @inheritdoc ICLGauge
  function stakedValues(address depositor) external view override returns (uint256[] memory staked) {
    return _stakes[depositor].values();
  }

  /// @inheritdoc ICLGauge
  function stakedByIndex(address depositor, uint256 index) external view override returns (uint256) {
    return _stakes[depositor].at(index);
  }

  /// @inheritdoc ICLGauge
  function stakedContains(address depositor, uint256 tokenId) external view override returns (bool) {
    return _stakes[depositor].contains(tokenId);
  }

  /// @inheritdoc ICLGauge
  function stakedLength(address depositor) external view override returns (uint256) {
    return _stakes[depositor].length();
  }

  /// @dev Stakes `tokenId` held by msg.sender and credits the stake to `owner`. msg.sender must own the
  ///      NFT and have approved this gauge for it; the collected pool fees are sent to `owner`.
  function _deposit(uint256 tokenId, address owner) internal override {
    require(nft.ownerOf(tokenId) == msg.sender, 'NA');
    (,, address _token0, address _token1, int24 _tickSpacing, int24 tickLower, int24 tickUpper,,,,,) =
      nft.positions(tokenId);
    require(token0 == _token0 && token1 == _token1 && tickSpacing == _tickSpacing, 'PM');

    // trigger update on staked position so NFT will be in sync with the pool
    nft.collect(
      INonfungiblePositionManager.CollectParams({
        tokenId: tokenId, recipient: owner, amount0Max: type(uint128).max, amount1Max: type(uint128).max
      })
    );

    nft.safeTransferFrom(msg.sender, address(this), tokenId);
    _stakes[owner].add(tokenId);
    _stakeOwner[tokenId] = owner;

    (,,,,,,, uint128 liquidityToStake,,,,) = nft.positions(tokenId);
    pool.stake((uint256(liquidityToStake).toInt256()).toInt128(), tickLower, tickUpper);

    uint256 rewardGrowth = pool.getRewardGrowthInside(tickLower, tickUpper, 0);
    rewardGrowthInside[tokenId] = rewardGrowth;
    depositBlock[tokenId] = block.number;

    emit Deposit(msg.sender, owner, tokenId, liquidityToStake);
  }

  /// @dev Shared withdrawal effects. Assumes authorization has been validated by the caller. Clears the
  ///      per-token approval and stake owner, calls the emission claim hook, removes the position, and transfers
  ///      the NFT to msg.sender. The claim hook defers emissions when minting reverts.
  function _withdraw(uint256 tokenId, address account, address recipient) internal override {
    require(_stakeOwner[tokenId] == account, 'NA');

    // Clear per-tokenId approval and stake owner unconditionally.
    delete _tokenApprovals[tokenId];
    delete _stakeOwner[tokenId];

    // trigger update on staked position so NFT will be in sync with the pool
    nft.collect(
      INonfungiblePositionManager.CollectParams({
        tokenId: tokenId, recipient: recipient, amount0Max: type(uint128).max, amount1Max: type(uint128).max
      })
    );

    (,,,,, int24 tickLower, int24 tickUpper, uint128 liquidityToStake,,,,) = nft.positions(tokenId);

    _claimOrDeferPositionEmissions(account, tokenId, recipient);

    pool.stake(-(uint256(liquidityToStake).toInt256()).toInt128(), tickLower, tickUpper);

    _stakes[account].remove(tokenId);
    delete depositBlock[tokenId];
    nft.safeTransferFrom(address(this), msg.sender, tokenId);

    emit Withdraw(msg.sender, account, tokenId, liquidityToStake);
  }

  /**
   * @notice Claim the LP's accrued emissions across the given positions
   * @dev Assumes `_tokenIds` are staked by `_account`. Also claims the account's deferred LP emissions.
   * @param _account The address of the LP staker
   * @param _tokenIds The staked positions to claim
   * @param _recipient The recipient of the claimed emissions
   */
  function _claimPositions(address _account, uint256[] memory _tokenIds, address _recipient) internal {
    require(_recipient != address(0), 'ZA');
    require(_tokenIds.length > 0 || deferredEmissions[_account] > 0, 'NS');

    // @dev Settle the pool's reward growth to the current timestamp. Emissions accrued while
    //      no staked liquidity was in range are returned and forfeited back to the LeafVoter
    uint256 _totalForfeitedAmount = pool.settleToBlock();

    uint256 _totalLpAmount;
    uint256 _totalReferralAmount;
    // @dev Load the gauge's referral and penalty config
    (address _referral, uint256 _referralShare) = ICLGaugeFactory(gaugeFactory).referralConfig(address(this));
    ICLGaugeFactory.PenaltyConfig memory _penaltyConfig =
      ICLGaugeFactory(gaugeFactory).effectivePenaltyConfig(address(this));

    for (uint256 i = 0; i < _tokenIds.length; i++) {
      // @dev Compute per-position emissions and reset state
      (uint256 _reward, uint256 _referralAmount, uint256 _penaltyAmount) =
        _computePositionEmissions(_account, _tokenIds[i], _referral, _referralShare, _penaltyConfig);

      _totalForfeitedAmount += _penaltyAmount;

      if (_referralAmount > 0) {
        _totalReferralAmount += _referralAmount;
        emit ReferralEmissionsDeferred(_account, _tokenIds[i], _referral, _referralAmount);
      }
      if (_reward > 0) {
        _totalLpAmount += _reward;
        emit EmissionsClaimed(_account, _tokenIds[i], _recipient, _reward);
      }
    }

    uint256 _deferredLpAmount = deferredEmissions[_account];
    if (_deferredLpAmount > 0) {
      delete deferredEmissions[_account];
      _totalLpAmount += _deferredLpAmount;
      emit DeferredEmissionsClaimed(_account, _recipient, _deferredLpAmount);
    }
    if (_totalReferralAmount > 0) {
      deferredReferralEmissions[_referral] += _totalReferralAmount;
    }

    if (_totalForfeitedAmount > 0) {
      ILeafVoter(voter).forfeitEmissions(_totalForfeitedAmount.toUint128());
    }

    if (_totalLpAmount > 0) {
      (address[] memory _recipients, uint128[] memory _amounts) = _buildMintArrays(_recipient, _totalLpAmount);
      ILeafVoter(voter).mintEmissions(_recipients, _amounts);
    }
  }

  /**
   * @notice Claims a withdrawing position's emissions or stores them for a later claim
   * @dev Defers emissions when emission minting reverts
   * @param _account The address of the LP staker
   * @param _tokenId The position being withdrawn
   * @param _recipient The recipient of successfully claimed emissions
   */
  function _claimOrDeferPositionEmissions(address _account, uint256 _tokenId, address _recipient) internal {
    uint256 _totalForfeitedAmount = pool.settleToBlock();
    (address _referral, uint256 _referralShare) = ICLGaugeFactory(gaugeFactory).referralConfig(address(this));
    ICLGaugeFactory.PenaltyConfig memory _penaltyConfig =
      ICLGaugeFactory(gaugeFactory).effectivePenaltyConfig(address(this));
    (uint256 _reward, uint256 _referralAmount, uint256 _penaltyAmount) =
      _computePositionEmissions(_account, _tokenId, _referral, _referralShare, _penaltyConfig);

    _totalForfeitedAmount += _penaltyAmount;
    if (_referralAmount > 0) {
      deferredReferralEmissions[_referral] += _referralAmount;
      emit ReferralEmissionsDeferred(_account, _tokenId, _referral, _referralAmount);
    }
    if (_totalForfeitedAmount > 0) {
      ILeafVoter(voter).forfeitEmissions(_totalForfeitedAmount.toUint128());
    }

    if (_reward == 0) return;

    (address[] memory _recipients, uint128[] memory _amounts) = _buildMintArrays(_recipient, _reward);
    try ILeafVoter(voter).mintEmissions(_recipients, _amounts) {
      emit EmissionsClaimed(_account, _tokenId, _recipient, _reward);
    } catch {
      deferredEmissions[_account] += _reward;
      emit EmissionsDeferred(_account, _tokenId, _reward);
    }
  }

  function _setApprovalForAll(address operator, bool approved) internal override {
    _approvedForAll[msg.sender][operator] = approved;
  }

  /**
   * @notice Computes the position's claimable emissions and advances its reward growth checkpoint
   * @dev Assumes the pool's reward growth has been advanced to the current timestamp
   * @dev Applies the early unstake penalty before the referral split
   * @param _account The address of the LP staker
   * @param _tokenId The staked position
   * @param _referral The referral reward recipient
   * @param _referralShare The referral share in PIPS
   * @param _penaltyConfig The effective penalty config for this gauge
   * @return The rewards after penalty and referral fee
   * @return The referral amount
   * @return The penalty amount
   */
  function _computePositionEmissions(
    address _account,
    uint256 _tokenId,
    address _referral,
    uint256 _referralShare,
    ICLGaugeFactory.PenaltyConfig memory _penaltyConfig
  ) internal returns (uint256, uint256, uint256) {
    // @dev Compute accrued emissions and capture current rewardGrowthInside
    (uint256 _reward, uint256 _rewardGrowthInsideX128) = _earned(_tokenId, 0);

    // @dev Advance the position's growth snapshot
    rewardGrowthInside[_tokenId] = _rewardGrowthInsideX128;

    if (_reward > 0) {
      // @dev Apply early unstake penalty
      uint256 _penaltyAmount = _applyPenalty(depositBlock[_tokenId], _reward, _penaltyConfig);
      if (_penaltyAmount > 0) {
        _reward -= _penaltyAmount;
        emit EarlyWithdrawPenalty(_account, _tokenId, _penaltyAmount);
      }

      // @dev Apply referral split
      uint256 _referralAmount = _applyReferral(_reward, _referral, _referralShare);
      if (_referralAmount > 0) {
        _reward -= _referralAmount;
      }

      return (_reward, _referralAmount, _penaltyAmount);
    } else {
      return (0, 0, 0);
    }
  }

  /**
   * @notice Calculates the accrued emissions for a given staked position
   * @dev If `_rewardGrowthGlobalX128` is 0, the pool's stored `rewardGrowthGlobalX128` is used
   * @param _tokenId The staked position
   * @param _rewardGrowthGlobalX128 The pool's reward growth global, or 0 to use the stored value
   * @return The claimable amount
   * @return The position's current rewardGrowthInside
   */
  function _earned(uint256 _tokenId, uint256 _rewardGrowthGlobalX128) internal view returns (uint256, uint256) {
    (,,,,, int24 _tickLower, int24 _tickUpper, uint128 _liquidity,,,,) = nft.positions(_tokenId);
    uint256 _rewardGrowthInsideX128 = pool.getRewardGrowthInside(_tickLower, _tickUpper, _rewardGrowthGlobalX128);

    // @dev Compute the position's accrued emissions
    uint256 _reward = FullMath.mulDiv(_rewardGrowthInsideX128 - rewardGrowthInside[_tokenId], _liquidity, Q128);

    return (_reward, _rewardGrowthInsideX128);
  }

  /// @dev Reverts unless the caller holds per-token or blanket withdrawal approval for `account`'s position.
  ///      Either path suffices independently. Runs only on the withdrawFrom path.
  function _authorizeWithdrawalFrom(uint256 tokenId, address account) internal view override {
    require(_tokenApprovals[tokenId] == msg.sender || _approvedForAll[account][msg.sender], 'NW');
  }
}
