// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity =0.7.6;
pragma abicoder v2;

import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/proxy/Clones.sol';

import './interfaces/ICLGauge.sol';
import './interfaces/ICLGaugeFactory.sol';
import './interfaces/ICLPool.sol';
import './interfaces/ILeafVoter.sol';
import './interfaces/IVotingRewardsFactory.sol';
import './interfaces/IVotingRewardsManager.sol';

import {CLGauge} from './CLGauge.sol';

contract CLGaugeFactory is ICLGaugeFactory, AccessControl {
  struct RoleAddresses {
    address capAdmin;
    address referralAdmin;
    address penaltyAdmin;
    address capOperator;
  }

  struct CapConfig {
    uint128 defaultCap;
    uint128 operatorMinCap;
    uint128 operatorMaxCap;
    uint256 maxMinStakeBlocks;
  }

  /// @inheritdoc ICLGaugeFactory
  string public constant override GAUGE_TYPE = 'cl';
  /// @inheritdoc ICLGaugeFactory
  bytes32 public constant override CAP_ADMIN_ROLE = keccak256('CAP_ADMIN_ROLE');
  /// @inheritdoc ICLGaugeFactory
  bytes32 public constant override REFERRAL_ADMIN_ROLE = keccak256('REFERRAL_ADMIN_ROLE');
  /// @inheritdoc ICLGaugeFactory
  bytes32 public constant override PENALTY_ADMIN_ROLE = keccak256('PENALTY_ADMIN_ROLE');
  /// @inheritdoc ICLGaugeFactory
  bytes32 public constant override CAP_OPERATOR_ROLE = keccak256('CAP_OPERATOR_ROLE');
  /// @inheritdoc ICLGaugeFactory
  uint128 public constant override DEFAULT_CAP_INDICATOR = type(uint128).max;
  /// @inheritdoc ICLGaugeFactory
  uint256 public constant override MAX_PIPS = 1_000_000;
  /// @inheritdoc ICLGaugeFactory
  uint256 public constant override DEFAULT_MAX_SHARE_CAP = 50_000;
  /// @inheritdoc ICLGaugeFactory
  uint256 public constant override DEFAULT_MIN_STAKE_BLOCKS = 5;
  /// @inheritdoc ICLGaugeFactory
  uint256 public constant override DEFAULT_PENALTY_RATE = 1_000_000;

  uint8 internal constant PARAMS_REFERRAL = 0x01;

  /// @inheritdoc ICLGaugeFactory
  address public immutable override leafVoter;
  /// @inheritdoc ICLGaugeFactory
  address public immutable override gaugeManager;
  /// @inheritdoc ICLGaugeFactory
  address public immutable override votingRewardsFactory;
  /// @inheritdoc ICLGaugeFactory
  address public immutable override implementation;
  /// @inheritdoc ICLGaugeFactory
  address public immutable override nft;
  /// @inheritdoc ICLGaugeFactory
  uint256 public immutable override maxMinStakeBlocks;

  /// @inheritdoc ICLGaugeFactory
  uint128 public override defaultCap;
  /// @inheritdoc ICLGaugeFactory
  uint128 public override operatorMinCap;
  /// @inheritdoc ICLGaugeFactory
  uint128 public override operatorMaxCap;
  /// @inheritdoc ICLGaugeFactory
  uint256 public override maxShareCap;

  /// @inheritdoc ICLGaugeFactory
  mapping(address => bool) public override isGauge;

  mapping(address => uint128) internal _emissionCaps;
  /// @inheritdoc ICLGaugeFactory
  mapping(address => ReferralConfig) public override referralConfig;
  PenaltyConfig internal _factoryPenaltyConfig;
  mapping(address => uint256) internal _gaugeMinStakeBlocks;

  constructor(
    address _leafVoter,
    address _gaugeManager,
    address _votingRewardsFactory,
    address _nft,
    RoleAddresses memory _roles,
    CapConfig memory _capConfig
  ) {
    require(_leafVoter != address(0), 'ZA');
    require(_gaugeManager != address(0), 'ZA');
    require(_votingRewardsFactory != address(0), 'ZA');
    require(_nft != address(0), 'ZA');
    require(_roles.capAdmin != address(0), 'ZA');
    require(_roles.referralAdmin != address(0), 'ZA');
    require(_roles.penaltyAdmin != address(0), 'ZA');
    require(_roles.capOperator != address(0), 'ZA');
    require(_capConfig.defaultCap != 0, 'ZC');
    require(_capConfig.operatorMinCap != 0 && _capConfig.operatorMinCap <= _capConfig.operatorMaxCap, 'CR');
    require(_capConfig.maxMinStakeBlocks >= DEFAULT_MIN_STAKE_BLOCKS, 'MS');

    leafVoter = _leafVoter;
    gaugeManager = _gaugeManager;
    votingRewardsFactory = _votingRewardsFactory;
    nft = _nft;
    implementation = address(new CLGauge({_voter: _leafVoter, _nft: _nft, _gaugeFactory: address(this)}));
    maxMinStakeBlocks = _capConfig.maxMinStakeBlocks;

    defaultCap = _capConfig.defaultCap;
    operatorMinCap = _capConfig.operatorMinCap;
    operatorMaxCap = _capConfig.operatorMaxCap;
    maxShareCap = DEFAULT_MAX_SHARE_CAP;
    _factoryPenaltyConfig = PenaltyConfig({minStakeBlocks: DEFAULT_MIN_STAKE_BLOCKS, penaltyRate: DEFAULT_PENALTY_RATE});

    _setRoleAdmin(CAP_ADMIN_ROLE, CAP_ADMIN_ROLE);
    _setRoleAdmin(REFERRAL_ADMIN_ROLE, REFERRAL_ADMIN_ROLE);
    _setRoleAdmin(PENALTY_ADMIN_ROLE, PENALTY_ADMIN_ROLE);
    _setRoleAdmin(CAP_OPERATOR_ROLE, CAP_ADMIN_ROLE);
    _setupRole(CAP_ADMIN_ROLE, _roles.capAdmin);
    _setupRole(REFERRAL_ADMIN_ROLE, _roles.referralAdmin);
    _setupRole(PENALTY_ADMIN_ROLE, _roles.penaltyAdmin);
    _setupRole(CAP_OPERATOR_ROLE, _roles.capOperator);
  }

  /// @inheritdoc ICLGaugeFactory
  function computeGaugeAddress(address _pool) external view override returns (address) {
    return Clones.predictDeterministicAddress({master: implementation, salt: _salt(_pool), deployer: address(this)});
  }

  /// @inheritdoc ICLGaugeFactory
  function createGauge(
    address _target,
    bytes calldata _factoryData
  ) external override returns (address gauge, address rewards) {
    require(msg.sender == gaugeManager, 'NA');

    address token0 = ICLPool(_target).token0();
    address token1 = ICLPool(_target).token1();
    int24 tickSpacing = ICLPool(_target).tickSpacing();

    // the pool's pair tokens are the fee reward tokens, derived here rather
    // than trusted from the caller
    address[] memory rewardTokens = new address[](2);
    rewardTokens[0] = token0;
    rewardTokens[1] = token1;

    // deploy the gauge and record all factory state before any state-changing
    // external interaction (checks-effects-interactions)
    gauge = Clones.cloneDeterministic({master: implementation, salt: _salt(_target)});
    isGauge[gauge] = true;
    _emissionCaps[gauge] = DEFAULT_CAP_INDICATOR;
    _applyReferralParams({_gauge: gauge, _params: _factoryData});

    rewards = IVotingRewardsFactory(votingRewardsFactory).createRewards({_gauge: gauge, _rewards: rewardTokens});

    _initializeGauge({
      _gauge: gauge,
      _pool: _target,
      _votingRewardsManager: rewards,
      _token0: token0,
      _token1: token1,
      _tickSpacing: tickSpacing,
      _isPool: true
    });
    ICLPool(_target).setGaugeAndPositionManager({_gauge: gauge, _nft: nft});

    emit GaugeCreated({_gauge: gauge, _pool: _target, _isPool: true});
  }

  /// @inheritdoc ICLGaugeFactory
  function emissionCap(address _gauge) external view override returns (uint128) {
    uint128 cap = _emissionCaps[_gauge];
    return cap == DEFAULT_CAP_INDICATOR ? defaultCap : cap;
  }

  /// @inheritdoc ICLGaugeFactory
  function setDefaultCap(uint128 _cap) external override {
    require(hasRole(CAP_ADMIN_ROLE, msg.sender), 'NA');
    require(_cap != 0, 'ZC');
    defaultCap = _cap;
    emit DefaultCapSet({_cap: _cap});
  }

  /// @inheritdoc ICLGaugeFactory
  function setEmissionCap(address _gauge, uint128 _cap) external override {
    require(isGauge[_gauge], 'IG');

    address emergencyCouncil = ILeafVoter(leafVoter).emergencyCouncil();
    if (msg.sender == emergencyCouncil) {
      require(_cap == 0, 'NA');
      ILeafVoter(leafVoter).settleGauge(_gauge);
      _flushGaugeFees(_gauge);
      delete _emissionCaps[_gauge];
      emit EmissionCapSet({_gauge: _gauge, _cap: 0, _caller: msg.sender});
      return;
    }

    if (hasRole(CAP_ADMIN_ROLE, msg.sender)) {
      ILeafVoter(leafVoter).settleGauge(_gauge);
      if (_cap == 0) _flushGaugeFees(_gauge);
      _emissionCaps[_gauge] = _cap;
      emit EmissionCapSet({_gauge: _gauge, _cap: _cap, _caller: msg.sender});
      return;
    }

    if (hasRole(CAP_OPERATOR_ROLE, msg.sender)) {
      require(_emissionCaps[_gauge] != 0, 'NA');
      if (_cap != DEFAULT_CAP_INDICATOR) {
        require(_cap >= operatorMinCap && _cap <= operatorMaxCap, 'CR');
      }
      ILeafVoter(leafVoter).settleGauge(_gauge);
      _emissionCaps[_gauge] = _cap;
      emit EmissionCapSet({_gauge: _gauge, _cap: _cap, _caller: msg.sender});
      return;
    }

    revert('NA');
  }

  /// @inheritdoc ICLGaugeFactory
  function setOperatorCapRange(uint128 _minCap, uint128 _maxCap) external override {
    require(hasRole(CAP_ADMIN_ROLE, msg.sender), 'NA');
    require(_minCap != 0 && _minCap <= _maxCap, 'CR');
    operatorMinCap = _minCap;
    operatorMaxCap = _maxCap;
    emit OperatorCapRangeSet({_minCap: _minCap, _maxCap: _maxCap});
  }

  /// @inheritdoc ICLGaugeFactory
  function setMaxShareCap(uint256 _cap) external override {
    require(hasRole(REFERRAL_ADMIN_ROLE, msg.sender), 'NA');
    require(_cap <= MAX_PIPS, 'MSC');
    maxShareCap = _cap;
    emit MaxShareCapSet({_cap: _cap});
  }

  /// @inheritdoc ICLGaugeFactory
  function setReferralConfig(address _gauge, address _referral, uint256 _share) external override {
    require(hasRole(REFERRAL_ADMIN_ROLE, msg.sender), 'NA');
    require(isGauge[_gauge], 'IG');
    _setReferralConfig({_gauge: _gauge, _referral: _referral, _share: _share});
  }

  /// @inheritdoc ICLGaugeFactory
  function penaltyConfig() external view override returns (PenaltyConfig memory) {
    return _factoryPenaltyConfig;
  }

  /// @inheritdoc ICLGaugeFactory
  function effectivePenaltyConfig(address _gauge) external view override returns (PenaltyConfig memory) {
    return PenaltyConfig({minStakeBlocks: minStakeBlocks(_gauge), penaltyRate: _factoryPenaltyConfig.penaltyRate});
  }

  /// @inheritdoc ICLGaugeFactory
  function minStakeBlocks(address _gauge) public view override returns (uint256) {
    uint256 overrideMinStakeBlocks = _gaugeMinStakeBlocks[_gauge];
    return overrideMinStakeBlocks == 0 ? _factoryPenaltyConfig.minStakeBlocks : overrideMinStakeBlocks;
  }

  /// @inheritdoc ICLGaugeFactory
  function setPenaltyConfig(uint256 _minStakeBlocks, uint256 _penaltyRate) external override {
    require(hasRole(PENALTY_ADMIN_ROLE, msg.sender), 'NA');
    require(_penaltyRate <= MAX_PIPS, 'MR');
    require(_minStakeBlocks <= maxMinStakeBlocks, 'MS');
    _factoryPenaltyConfig = PenaltyConfig({minStakeBlocks: _minStakeBlocks, penaltyRate: _penaltyRate});
    emit PenaltyConfigSet({_minStakeBlocks: _minStakeBlocks, _penaltyRate: _penaltyRate});
  }

  /// @inheritdoc ICLGaugeFactory
  function setMinStakeBlocks(address _gauge, uint256 _minStakeBlocks) external override {
    require(hasRole(PENALTY_ADMIN_ROLE, msg.sender), 'NA');
    require(isGauge[_gauge], 'IG');
    require(_minStakeBlocks <= maxMinStakeBlocks, 'MS');
    _gaugeMinStakeBlocks[_gauge] = _minStakeBlocks;
    emit MinStakeBlocksSet({_gauge: _gauge, _minStakeBlocks: _minStakeBlocks});
  }

  /// @dev The pool address alone keys the salt, so distinct targets can never
  ///      collide regardless of the target factory's uniqueness semantics. A
  ///      repeat deployment over the same pool reverts on the CREATE2 collision.
  function _salt(address _pool) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(_pool));
  }

  function _initializeGauge(
    address _gauge,
    address _pool,
    address _votingRewardsManager,
    address _token0,
    address _token1,
    int24 _tickSpacing,
    bool _isPool
  ) internal {
    ICLGauge(_gauge)
      .initialize({
      _pool: _pool,
      _votingRewardsManager: _votingRewardsManager,
      _token0: _token0,
      _token1: _token1,
      _tickSpacing: _tickSpacing,
      _isPool: _isPool
    });
  }

  function _flushGaugeFees(address _gauge) internal {
    IVotingRewardsManager(ICLGauge(_gauge).votingRewardsManager()).flushFees();
  }

  function _applyReferralParams(address _gauge, bytes calldata _params) internal {
    if (_params.length == 0 || uint8(_params[0]) != PARAMS_REFERRAL) return;

    (address referral, uint256 share) = _decodeReferral(_params);
    _setReferralConfig({_gauge: _gauge, _referral: referral, _share: share});
  }

  function _setReferralConfig(address _gauge, address _referral, uint256 _share) internal {
    require(_share <= maxShareCap, 'SC');
    require(_share == 0 || _referral != address(0), 'IR');
    referralConfig[_gauge] = ReferralConfig({referral: _referral, share: _share});
    emit ReferralConfigSet({_gauge: _gauge, _referral: _referral, _share: _share});
  }

  function _decodeReferral(bytes calldata _params) internal pure returns (address referral, uint256 share) {
    return abi.decode(_params[1:], (address, uint256));
  }
}
