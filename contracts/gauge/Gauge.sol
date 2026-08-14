// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity =0.7.6;
pragma abicoder v2;

import {ReentrancyGuard} from '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/SafeCast.sol';

import {ICLGaugeFactory} from 'contracts/gauge/interfaces/ICLGaugeFactory.sol';
import {IGauge} from 'contracts/gauge/interfaces/IGauge.sol';

/**
 * @title Gauge
 * @notice Abstract gauge holding functionality common to all gauge types.
 */
abstract contract Gauge is IGauge, ReentrancyGuard {
  using SafeCast for uint256;

  /// @inheritdoc IGauge
  uint256 public constant override MAX_PIPS = 1_000_000;

  /// @inheritdoc IGauge
  ICLGaugeFactory public immutable override gaugeFactory;

  /// @inheritdoc IGauge
  mapping(address => mapping(address => bool)) public override approvedForClaim;

  constructor(address _gaugeFactory) {
    gaugeFactory = ICLGaugeFactory(_gaugeFactory);
  }

  /// @inheritdoc IGauge
  function deposit(uint256 lp) external override nonReentrant {
    _deposit(lp, msg.sender);
  }

  /// @inheritdoc IGauge
  function depositFor(uint256 lp, address owner) external override nonReentrant {
    require(owner != address(0), 'ZA');
    _deposit(lp, owner);
  }

  /// @inheritdoc IGauge
  function withdraw(uint256 lp) external override nonReentrant {
    _withdraw(lp, msg.sender, msg.sender);
  }

  /// @inheritdoc IGauge
  function withdrawFrom(uint256 lp, address account) external override nonReentrant {
    require(account != address(0), 'ZA');
    _authorizeWithdrawalFrom(lp, account);
    address claimRecipient = approvedForClaim[account][msg.sender] ? msg.sender : account;
    _withdraw(lp, account, claimRecipient);
  }

  /// @inheritdoc IGauge
  function claimEmissions(address _account, address _recipient) external virtual override;

  /// @inheritdoc IGauge
  function approveForClaim(address operator, bool approved) external override {
    require(operator != address(0), 'ZA');
    approvedForClaim[msg.sender][operator] = approved;
    emit ClaimApproval(msg.sender, operator, approved);
  }

  /// @inheritdoc IGauge
  function setApprovalForAll(address operator, bool approved) external override {
    require(operator != address(0), 'ZA');
    _setApprovalForAll(operator, approved);
    emit ApprovalForAll(msg.sender, operator, approved);
  }

  /// @inheritdoc IGauge
  function earned(address _account) external view virtual override returns (uint256);

  /**
   * @notice Calculates the early withdraw penalty for a reward
   * @dev Assumes the penalty rate is smaller than or equal to `MAX_PIPS`
   * @param _depositBlock The LP's most recent deposit block
   * @param _reward The reward amount before penalty
   * @param _config The penalty config to apply
   * @return The penalty amount
   */
  function _applyPenalty(
    uint256 _depositBlock,
    uint256 _reward,
    ICLGaugeFactory.PenaltyConfig memory _config
  ) internal view returns (uint256) {
    return _config.penaltyRate > 0 && _config.minStakeBlocks > 0
      && block.number < _depositBlock + _config.minStakeBlocks
      ? _reward * _config.penaltyRate / MAX_PIPS
      : 0;
  }

  /**
   * @notice Calculates the referral fee for a reward
   * @dev Assumes the referral share is smaller than or equal to `MAX_PIPS`
   * @param _reward The reward amount before referral split
   * @param _referral The referral reward recipient
   * @param _referralShare The referral share in PIPS
   * @return The referral amount
   */
  function _applyReferral(uint256 _reward, address _referral, uint256 _referralShare) internal pure returns (uint256) {
    if (_referralShare == 0 || _referral == address(0)) return 0;

    return _reward * _referralShare / MAX_PIPS;
  }

  /**
   * @notice Builds the recipient and amount arrays for an emissions mint
   * @param _recipient The LP reward recipient
   * @param _lpAmount The total LP reward amount
   * @param _referral The referral reward recipient
   * @param _referralAmount The total referral reward amount
   * @return _recipients The mint recipients
   * @return _amounts The mint amounts
   */
  function _buildMintArrays(
    address _recipient,
    uint256 _lpAmount,
    address _referral,
    uint256 _referralAmount
  ) internal pure returns (address[] memory _recipients, uint128[] memory _amounts) {
    uint256 _length = _lpAmount > 0 ? 1 : 0;
    if (_referralAmount > 0) _length++;

    _recipients = new address[](_length);
    _amounts = new uint128[](_length);

    uint256 _index;
    if (_lpAmount > 0) {
      _recipients[_index] = _recipient;
      _amounts[_index] = _lpAmount.toUint128();
      _index++;
    }

    if (_referralAmount > 0) {
      _recipients[_index] = _referral;
      _amounts[_index] = _referralAmount.toUint128();
    }
  }

  function _authorizeWithdrawalFrom(uint256 lp, address account) internal virtual;

  function _deposit(uint256 lp, address owner) internal virtual;

  function _withdraw(uint256 lp, address account, address claimRecipient) internal virtual;

  function _setApprovalForAll(address operator, bool approved) internal virtual;
}
