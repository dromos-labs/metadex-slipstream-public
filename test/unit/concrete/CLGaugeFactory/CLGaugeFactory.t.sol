// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity ^0.7.6;
pragma abicoder v2;

import {Test} from 'forge-std/Test.sol';

import {CLGauge} from 'contracts/gauge/CLGauge.sol';
import {CLGaugeFactory} from 'contracts/gauge/CLGaugeFactory.sol';
import {ICLGaugeFactory} from 'contracts/gauge/interfaces/ICLGaugeFactory.sol';
import {IVotingRewardsManager} from 'contracts/gauge/interfaces/IVotingRewardsManager.sol';

contract UnitCLGaugeFactory is Test {
  event GaugeCreated(address indexed _gauge, address indexed _pool, bool _isPool);
  event EmissionCapSet(address indexed _gauge, uint128 _cap, address indexed _caller);
  event FeeFlushFailed(address indexed _gauge);
  event DefaultCapSet(uint128 _cap);
  event OperatorCapRangeSet(uint128 _minCap, uint128 _maxCap);
  event MaxShareCapSet(uint256 _cap);
  event ReferralConfigSet(address indexed _gauge, address indexed _referral, uint256 _share);
  event PenaltyConfigSet(uint256 _minStakeBlocks, uint256 _penaltyRate);
  event MinStakeBlocksSet(address indexed _gauge, uint256 _minStakeBlocks);

  address internal _capAdmin = makeAddr('capAdmin');
  address internal _referralAdmin = makeAddr('referralAdmin');
  address internal _penaltyAdmin = makeAddr('penaltyAdmin');
  address internal _capOperator = makeAddr('capOperator');
  address internal _emergencyCouncil = makeAddr('emergencyCouncil');
  address internal _gaugeManager = makeAddr('gaugeManager');
  address internal _nft = makeAddr('nft');
  address internal _token0 = makeAddr('token0');
  address internal _token1 = makeAddr('token1');
  int24 internal _tickSpacing = 100;

  MockCLGaugeFactoryLeafVoter internal _leafVoter;
  MockCLGaugeFactoryPool internal _pool;
  MockCLGaugeFactoryVotingRewardsFactory internal _votingRewardsFactory;
  MockCLGaugeFactoryVotingRewardsManager internal _votingRewardsManager;
  CLGauge internal _implementation;
  CLGaugeFactory internal _gaugeFactory;

  uint128 internal _defaultCap = 1e18;
  uint128 internal _operatorMinCap = 1e16;
  uint128 internal _operatorMaxCap = 1e20;
  uint256 internal _maxMinStakeBlocks = 100;

  function setUp() public virtual {
    _leafVoter = new MockCLGaugeFactoryLeafVoter(_emergencyCouncil);
    _pool = new MockCLGaugeFactoryPool(_token0, _token1, _tickSpacing);
    _votingRewardsManager = new MockCLGaugeFactoryVotingRewardsManager();
    _votingRewardsFactory = new MockCLGaugeFactoryVotingRewardsFactory(address(_votingRewardsManager));
    _gaugeFactory = _deployGaugeFactory();
    _implementation = CLGauge(_gaugeFactory.implementation());
  }

  function test_ConstructorWhenLeafVoterIsTheZeroAddress() external {
    // it should revert with ZA
    vm.expectRevert(bytes('ZA'));
    _deployGaugeFactory(address(0), _gaugeManager, address(_votingRewardsFactory), _nft, _roles(), _capConfig());
  }

  function test_ConstructorWhenGaugeManagerIsTheZeroAddress() external {
    // it should revert with ZA
    vm.expectRevert(bytes('ZA'));
    _deployGaugeFactory(address(_leafVoter), address(0), address(_votingRewardsFactory), _nft, _roles(), _capConfig());
  }

  function test_ConstructorWhenVotingRewardsFactoryIsTheZeroAddress() external {
    // it should revert with ZA
    vm.expectRevert(bytes('ZA'));
    _deployGaugeFactory(address(_leafVoter), _gaugeManager, address(0), _nft, _roles(), _capConfig());
  }

  function test_ConstructorWhenNftIsTheZeroAddress() external {
    // it should revert with ZA
    vm.expectRevert(bytes('ZA'));
    _deployGaugeFactory(
      address(_leafVoter), _gaugeManager, address(_votingRewardsFactory), address(0), _roles(), _capConfig()
    );
  }

  function test_ConstructorWhenCapAdminIsTheZeroAddress() external {
    CLGaugeFactory.RoleAddresses memory roles = _roles();
    roles.capAdmin = address(0);

    // it should revert with ZA
    vm.expectRevert(bytes('ZA'));
    _deployGaugeFactory(address(_leafVoter), _gaugeManager, address(_votingRewardsFactory), _nft, roles, _capConfig());
  }

  function test_ConstructorWhenReferralAdminIsTheZeroAddress() external {
    CLGaugeFactory.RoleAddresses memory roles = _roles();
    roles.referralAdmin = address(0);

    // it should revert with ZA
    vm.expectRevert(bytes('ZA'));
    _deployGaugeFactory(address(_leafVoter), _gaugeManager, address(_votingRewardsFactory), _nft, roles, _capConfig());
  }

  function test_ConstructorWhenPenaltyAdminIsTheZeroAddress() external {
    CLGaugeFactory.RoleAddresses memory roles = _roles();
    roles.penaltyAdmin = address(0);

    // it should revert with ZA
    vm.expectRevert(bytes('ZA'));
    _deployGaugeFactory(address(_leafVoter), _gaugeManager, address(_votingRewardsFactory), _nft, roles, _capConfig());
  }

  function test_ConstructorWhenCapOperatorIsTheZeroAddress() external {
    CLGaugeFactory.RoleAddresses memory roles = _roles();
    roles.capOperator = address(0);

    // it should revert with ZA
    vm.expectRevert(bytes('ZA'));
    _deployGaugeFactory(address(_leafVoter), _gaugeManager, address(_votingRewardsFactory), _nft, roles, _capConfig());
  }

  function test_ConstructorWhenDefaultCapIsZero() external {
    CLGaugeFactory.CapConfig memory capConfig = _capConfig();
    capConfig.defaultCap = 0;

    // it should revert with ZC
    vm.expectRevert(bytes('ZC'));
    _deployGaugeFactory(address(_leafVoter), _gaugeManager, address(_votingRewardsFactory), _nft, _roles(), capConfig);
  }

  function test_ConstructorWhenOperatorMinCapIsZero() external {
    CLGaugeFactory.CapConfig memory capConfig = _capConfig();
    capConfig.operatorMinCap = 0;

    // it should revert with CR
    vm.expectRevert(bytes('CR'));
    _deployGaugeFactory(address(_leafVoter), _gaugeManager, address(_votingRewardsFactory), _nft, _roles(), capConfig);
  }

  function test_ConstructorWhenOperatorMinCapExceedsOperatorMaxCap(uint128 _minCap, uint128 _maxCap) external {
    _maxCap = uint128(bound(uint256(_maxCap), 0, uint256(type(uint128).max) - 1));
    _minCap = uint128(bound(uint256(_minCap), uint256(_maxCap) + 1, type(uint128).max));
    CLGaugeFactory.CapConfig memory capConfig = _capConfig();
    capConfig.operatorMinCap = _minCap;
    capConfig.operatorMaxCap = _maxCap;
    // it should revert with CR
    vm.expectRevert(bytes('CR'));
    _deployGaugeFactory(address(_leafVoter), _gaugeManager, address(_votingRewardsFactory), _nft, _roles(), capConfig);
  }

  function test_ConstructorWhenMaxMinStakeBlocksIsLessThanTheDefault(uint256 _invalidMaxMinStakeBlocks) external {
    _invalidMaxMinStakeBlocks = bound(_invalidMaxMinStakeBlocks, 0, _gaugeFactory.DEFAULT_MIN_STAKE_BLOCKS() - 1);
    CLGaugeFactory.CapConfig memory capConfig = _capConfig();
    capConfig.maxMinStakeBlocks = _invalidMaxMinStakeBlocks;
    // it should revert with MS
    vm.expectRevert(bytes('MS'));
    _deployGaugeFactory(address(_leafVoter), _gaugeManager, address(_votingRewardsFactory), _nft, _roles(), capConfig);
  }

  function test_ConstructorWhenConstructorArgumentsAreValid(
    uint128 _validDefaultCap,
    uint128 _validOperatorMinCap,
    uint128 _validOperatorMaxCap,
    uint256 _validMaxMinStakeBlocks
  ) external {
    _validDefaultCap = uint128(bound(uint256(_validDefaultCap), 1, type(uint128).max));
    _validOperatorMinCap = uint128(bound(uint256(_validOperatorMinCap), 1, type(uint128).max));
    _validOperatorMaxCap = uint128(bound(uint256(_validOperatorMaxCap), _validOperatorMinCap, type(uint128).max));
    _validMaxMinStakeBlocks =
      bound(_validMaxMinStakeBlocks, _gaugeFactory.DEFAULT_MIN_STAKE_BLOCKS(), type(uint256).max);

    CLGaugeFactory.CapConfig memory capConfig = CLGaugeFactory.CapConfig({
      defaultCap: _validDefaultCap,
      operatorMinCap: _validOperatorMinCap,
      operatorMaxCap: _validOperatorMaxCap,
      maxMinStakeBlocks: _validMaxMinStakeBlocks
    });

    CLGaugeFactory gaugeFactory = _deployGaugeFactory(
      address(_leafVoter), _gaugeManager, address(_votingRewardsFactory), _nft, _roles(), capConfig
    );

    // it should set immutable views
    assertEq(gaugeFactory.GAUGE_TYPE(), 'cl');
    assertEq(gaugeFactory.leafVoter(), address(_leafVoter));
    assertEq(gaugeFactory.gaugeManager(), _gaugeManager);
    assertEq(gaugeFactory.votingRewardsFactory(), address(_votingRewardsFactory));
    assertEq(gaugeFactory.nft(), _nft);
    CLGauge implementation = CLGauge(gaugeFactory.implementation());
    assertEq(address(implementation.voter()), address(_leafVoter));
    assertEq(address(implementation.nft()), _nft);
    assertEq(address(implementation.gaugeFactory()), address(gaugeFactory));
    assertEq(gaugeFactory.maxMinStakeBlocks(), _validMaxMinStakeBlocks);

    // it should set cap views
    assertEq(gaugeFactory.MAX_PIPS(), 1_000_000);
    assertEq(uint256(gaugeFactory.defaultCap()), uint256(_validDefaultCap));
    assertEq(uint256(gaugeFactory.operatorMinCap()), uint256(_validOperatorMinCap));
    assertEq(uint256(gaugeFactory.operatorMaxCap()), uint256(_validOperatorMaxCap));

    // it should set referral and penalty defaults
    assertEq(gaugeFactory.DEFAULT_MAX_SHARE_CAP(), 50_000);
    assertEq(gaugeFactory.maxShareCap(), gaugeFactory.DEFAULT_MAX_SHARE_CAP());
    ICLGaugeFactory.PenaltyConfig memory config = gaugeFactory.penaltyConfig();
    assertEq(config.minStakeBlocks, gaugeFactory.DEFAULT_MIN_STAKE_BLOCKS());
    assertEq(config.penaltyRate, gaugeFactory.DEFAULT_PENALTY_RATE());

    // it should grant initial roles
    assertTrue(gaugeFactory.hasRole(gaugeFactory.CAP_ADMIN_ROLE(), _capAdmin));
    assertTrue(gaugeFactory.hasRole(gaugeFactory.REFERRAL_ADMIN_ROLE(), _referralAdmin));
    assertTrue(gaugeFactory.hasRole(gaugeFactory.PENALTY_ADMIN_ROLE(), _penaltyAdmin));
    assertTrue(gaugeFactory.hasRole(gaugeFactory.CAP_OPERATOR_ROLE(), _capOperator));

    // it should set role admin relationships
    assertEq(gaugeFactory.getRoleAdmin(gaugeFactory.CAP_ADMIN_ROLE()), gaugeFactory.CAP_ADMIN_ROLE());
    assertEq(gaugeFactory.getRoleAdmin(gaugeFactory.REFERRAL_ADMIN_ROLE()), gaugeFactory.REFERRAL_ADMIN_ROLE());
    assertEq(gaugeFactory.getRoleAdmin(gaugeFactory.PENALTY_ADMIN_ROLE()), gaugeFactory.PENALTY_ADMIN_ROLE());
    assertEq(gaugeFactory.getRoleAdmin(gaugeFactory.CAP_OPERATOR_ROLE()), gaugeFactory.CAP_ADMIN_ROLE());
  }

  function test_ComputeGaugeAddressWhenThePoolVaries(address _poolInput) external {
    // it should match the independent clone address
    assertEq(_gaugeFactory.computeGaugeAddress(_poolInput), _independentCloneAddress(_poolInput));
  }

  function test_CreateGaugeWhenTheCallerIsNotTheGaugeManager(address _caller) external {
    vm.assume(_caller != address(0));
    vm.assume(_caller != _gaugeManager);

    // it should revert with NA
    vm.prank(_caller);
    vm.expectRevert(bytes('NA'));
    _gaugeFactory.createGauge(address(_pool), '');
  }

  modifier whenTheCallerIsTheGaugeManager() {
    _;
  }

  function test_CreateGaugeWhenFactoryDataIsEmpty() external whenTheCallerIsTheGaugeManager {
    address predicted = _gaugeFactory.computeGaugeAddress(address(_pool));

    vm.prank(_gaugeManager);
    vm.expectEmit(address(_gaugeFactory));
    emit GaugeCreated(predicted, address(_pool), true);
    (address gaugeAddress, address rewards) = _gaugeFactory.createGauge(address(_pool), '');
    CLGauge gauge = CLGauge(gaugeAddress);

    // it should deploy the predicted gauge
    assertEq(address(gauge), predicted);

    // it should deploy the voting rewards manager for the predicted gauge
    assertEq(rewards, address(_votingRewardsManager));
    assertEq(_votingRewardsFactory.createRewardsCalls(), 1);
    assertEq(_votingRewardsFactory.lastGauge(), predicted);
    assertEq(_votingRewardsFactory.lastRewardToken(0), _token0);
    assertEq(_votingRewardsFactory.lastRewardToken(1), _token1);

    // it should initialize gauge fields
    assertEq(address(gauge.pool()), address(_pool));
    assertEq(address(gauge.gaugeFactory()), address(_gaugeFactory));
    assertEq(address(gauge.voter()), address(_leafVoter));
    assertEq(address(gauge.nft()), _nft);
    assertEq(gauge.token0(), _token0);
    assertEq(gauge.token1(), _token1);
    assertEq(gauge.tickSpacing(), _tickSpacing);
    assertEq(gauge.votingRewardsManager(), rewards);
    assertTrue(gauge.isPool());

    // it should link the gauge and nft on the pool
    assertEq(_pool.gauge(), address(gauge));
    assertEq(_pool.nft(), _nft);
    assertEq(_pool.setGaugeAndPositionManagerCalls(), 1);

    // it should mark the gauge
    assertTrue(_gaugeFactory.isGauge(address(gauge)));

    // it should initialize the emission cap to the current default cap
    assertEq(uint256(_gaugeFactory.emissionCap(address(gauge))), uint256(_defaultCap));

    // it should leave referral config empty
    _assertReferralConfig(address(gauge), address(0), 0);

    // it should emit GaugeCreated
  }

  function test_CreateGaugeWhenTheGaugeAlreadyExists() external whenTheCallerIsTheGaugeManager {
    _createGauge('');

    // it should revert on the CREATE2 collision
    vm.prank(_gaugeManager);
    vm.expectRevert(bytes('ERC1167: create2 failed'));
    _gaugeFactory.createGauge(address(_pool), '');
  }

  function test_CreateGaugeWhenFactoryDataIsUnknown() external whenTheCallerIsTheGaugeManager {
    CLGauge gauge = _createGauge(hex'02');

    // it should deploy a gauge
    assertTrue(_gaugeFactory.isGauge(address(gauge)));

    // it should leave referral config empty
    _assertReferralConfig(address(gauge), address(0), 0);
  }

  function test_CreateGaugeWhenFactoryDataIsATruncatedReferralPayload(uint256 _factoryDataLength)
    external
    whenTheCallerIsTheGaugeManager
  {
    _factoryDataLength = bound(_factoryDataLength, 1, 64);
    bytes memory factoryData = new bytes(_factoryDataLength);
    factoryData[0] = bytes1(uint8(0x01));

    // it should revert with IR
    vm.prank(_gaugeManager);
    vm.expectRevert(bytes('IR'));
    _gaugeFactory.createGauge(address(_pool), factoryData);
  }

  function test_CreateGaugeWhenFactoryDataIsAnOversizedReferralPayload(uint256 _factoryDataLength)
    external
    whenTheCallerIsTheGaugeManager
  {
    _factoryDataLength = bound(_factoryDataLength, 66, 256);
    bytes memory factoryData = new bytes(_factoryDataLength);
    factoryData[0] = bytes1(uint8(0x01));

    // it should revert with IR
    vm.prank(_gaugeManager);
    vm.expectRevert(bytes('IR'));
    _gaugeFactory.createGauge(address(_pool), factoryData);
  }

  function test_CreateGaugeWhenReferralShareExceedsMaxShareCap(uint256 _share) external whenTheCallerIsTheGaugeManager {
    _share = bound(_share, _gaugeFactory.maxShareCap() + 1, type(uint256).max);
    bytes memory factoryData = abi.encodePacked(bytes1(0x01), abi.encode(makeAddr('referral'), _share));

    // it should revert with SC
    vm.prank(_gaugeManager);
    vm.expectRevert(bytes('SC'));
    _gaugeFactory.createGauge(address(_pool), factoryData);
  }

  function test_CreateGaugeWhenReferralShareIsNonzeroAndReferralIsTheZeroAddress(uint256 _share)
    external
    whenTheCallerIsTheGaugeManager
  {
    _share = bound(_share, 1, _gaugeFactory.maxShareCap());
    bytes memory factoryData = abi.encodePacked(bytes1(0x01), abi.encode(address(0), _share));

    // it should revert with IR
    vm.prank(_gaugeManager);
    vm.expectRevert(bytes('IR'));
    _gaugeFactory.createGauge(address(_pool), factoryData);
  }

  function test_CreateGaugeWhenFactoryDataIsReferral(
    address _referral,
    uint256 _share
  ) external whenTheCallerIsTheGaugeManager {
    vm.assume(_referral != address(0));
    _share = bound(_share, 1, _gaugeFactory.maxShareCap());
    address predicted = _gaugeFactory.computeGaugeAddress(address(_pool));
    bytes memory factoryData = abi.encodePacked(bytes1(0x01), abi.encode(_referral, _share));

    vm.expectEmit(address(_gaugeFactory));
    emit ReferralConfigSet(predicted, _referral, _share);
    CLGauge gauge = _createGauge(factoryData);

    // it should deploy a gauge
    assertEq(address(gauge), predicted);

    // it should set referral config
    _assertReferralConfig(address(gauge), _referral, _share);

    // it should emit ReferralConfigSet
  }

  function test_SetDefaultCapWhenTheCallerDoesNotHaveTheCapAdminRole(address _caller, uint128 _cap) external {
    vm.assume(_caller != address(0));
    vm.assume(_caller != _capAdmin);
    _cap = uint128(bound(uint256(_cap), 1, type(uint128).max));

    // it should revert with NA
    vm.prank(_caller);
    vm.expectRevert(bytes('NA'));
    _gaugeFactory.setDefaultCap(_cap);
  }

  modifier whenTheCallerHasTheCapAdminRole() {
    _;
  }

  function test_SetDefaultCapWhenTheCapIsZero() external whenTheCallerHasTheCapAdminRole {
    // it should revert with ZC
    vm.prank(_capAdmin);
    vm.expectRevert(bytes('ZC'));
    _gaugeFactory.setDefaultCap(0);
  }

  function test_SetDefaultCapWhenTheCapIsNonzero(uint128 _cap) external whenTheCallerHasTheCapAdminRole {
    _cap = uint128(bound(uint256(_cap), 1, type(uint128).max));
    vm.assume(_cap != _defaultCap);
    CLGauge gauge = _createGauge('');

    vm.prank(_capAdmin);
    vm.expectEmit(address(_gaugeFactory));
    emit DefaultCapSet(_cap);
    _gaugeFactory.setDefaultCap(_cap);

    // it should update defaultCap
    assertEq(uint256(_gaugeFactory.defaultCap()), uint256(_cap));

    // it should preserve the existing gauge cap
    assertEq(uint256(_gaugeFactory.emissionCap(address(gauge))), uint256(_defaultCap));

    // it should emit DefaultCapSet
  }

  function test_SetOperatorCapRangeWhenTheCallerDoesNotHaveTheCapAdminRole(address _caller) external {
    vm.assume(_caller != address(0));
    vm.assume(_caller != _capAdmin);

    // it should revert with NA
    vm.prank(_caller);
    vm.expectRevert(bytes('NA'));
    _gaugeFactory.setOperatorCapRange(1, 2);
  }

  function test_SetOperatorCapRangeWhenMinCapIsZero(uint128 _maxCap) external whenTheCallerHasTheCapAdminRole {
    _maxCap = uint128(bound(uint256(_maxCap), 0, type(uint128).max));

    // it should revert with CR
    vm.prank(_capAdmin);
    vm.expectRevert(bytes('CR'));
    _gaugeFactory.setOperatorCapRange(0, _maxCap);
  }

  function test_SetOperatorCapRangeWhenMinCapExceedsMaxCap(
    uint128 _minCap,
    uint128 _maxCap
  ) external whenTheCallerHasTheCapAdminRole {
    _maxCap = uint128(bound(uint256(_maxCap), 0, uint256(type(uint128).max) - 1));
    _minCap = uint128(bound(uint256(_minCap), uint256(_maxCap) + 1, type(uint128).max));

    // it should revert with CR
    vm.prank(_capAdmin);
    vm.expectRevert(bytes('CR'));
    _gaugeFactory.setOperatorCapRange(_minCap, _maxCap);
  }

  function test_SetOperatorCapRangeWhenTheRangeIsValid(
    uint128 _minCap,
    uint128 _maxCap
  ) external whenTheCallerHasTheCapAdminRole {
    _minCap = uint128(bound(uint256(_minCap), 1, type(uint128).max));
    _maxCap = uint128(bound(uint256(_maxCap), _minCap, type(uint128).max));

    vm.prank(_capAdmin);
    vm.expectEmit(address(_gaugeFactory));
    emit OperatorCapRangeSet(_minCap, _maxCap);
    _gaugeFactory.setOperatorCapRange(_minCap, _maxCap);

    // it should update operator cap range
    assertEq(uint256(_gaugeFactory.operatorMinCap()), uint256(_minCap));
    assertEq(uint256(_gaugeFactory.operatorMaxCap()), uint256(_maxCap));

    // it should emit OperatorCapRangeSet
  }

  function test_SetEmissionCapWhenTheGaugeIsInvalid(address _gauge, uint128 _cap) external {
    vm.assume(!_gaugeFactory.isGauge(_gauge));

    // it should revert with IG
    vm.expectRevert(bytes('IG'));
    _gaugeFactory.setEmissionCap(_gauge, _cap);
  }

  modifier whenTheGaugeIsValid() {
    _;
  }

  modifier whenTheCapIsZeroForCapAdmin() {
    _;
  }

  function test_SetEmissionCapWhenFeeFlushingReverts()
    external
    whenTheGaugeIsValid
    whenTheCallerHasTheCapAdminRole
    whenTheCapIsZeroForCapAdmin
  {
    CLGauge gauge = _createGauge('');
    bytes memory revertData = _expectFlushFeesRevert(address(gauge));

    vm.prank(_capAdmin);
    // it should revert with FeeCollectionFailed
    vm.expectRevert(revertData);
    _gaugeFactory.setEmissionCap(address(gauge), 0);
  }

  function test_SetEmissionCapWhenFeeFlushingSucceeds()
    external
    whenTheGaugeIsValid
    whenTheCallerHasTheCapAdminRole
    whenTheCapIsZeroForCapAdmin
  {
    CLGauge gauge = _createGauge('');
    uint128 priorCap = _gaugeFactory.emissionCap(address(gauge));
    assertGt(uint256(priorCap), 0);

    vm.prank(_capAdmin);
    vm.expectEmit(address(_gaugeFactory));
    emit EmissionCapSet(address(gauge), 0, _capAdmin);
    _gaugeFactory.setEmissionCap(address(gauge), 0);

    // it should settle the gauge
    assertEq(_leafVoter.settleGaugeCalls(address(gauge)), 1);

    // it should flush fees while the prior effective cap is nonzero
    assertEq(uint256(_votingRewardsManager.emissionCapDuringFlush()), uint256(priorCap));
    assertEq(_votingRewardsManager.flushFeesCalls(), 1);

    // it should write the zero cap
    assertEq(uint256(_gaugeFactory.emissionCap(address(gauge))), 0);

    // it should emit EmissionCapSet
  }

  function test_SetEmissionCapWhenTheCapIsTheMaximumValueForCapAdmin()
    external
    whenTheGaugeIsValid
    whenTheCallerHasTheCapAdminRole
  {
    CLGauge gauge = _createGauge('');
    uint128 maximumCap = type(uint128).max;

    vm.prank(_capAdmin);
    vm.expectEmit(address(_gaugeFactory));
    emit EmissionCapSet(address(gauge), maximumCap, _capAdmin);
    _gaugeFactory.setEmissionCap(address(gauge), maximumCap);

    // it should settle the gauge
    assertEq(_leafVoter.settleGaugeCalls(address(gauge)), 1);

    // it should write the maximum cap
    assertEq(uint256(_gaugeFactory.emissionCap(address(gauge))), uint256(maximumCap));

    // it should emit EmissionCapSet
  }

  function test_SetEmissionCapWhenTheCapIsNonzeroForCapAdmin(uint128 _cap)
    external
    whenTheGaugeIsValid
    whenTheCallerHasTheCapAdminRole
  {
    _cap = uint128(bound(uint256(_cap), 1, uint256(type(uint128).max) - 1));
    CLGauge gauge = _createGauge('');

    vm.prank(_capAdmin);
    vm.expectEmit(address(_gaugeFactory));
    emit EmissionCapSet(address(gauge), _cap, _capAdmin);
    _gaugeFactory.setEmissionCap(address(gauge), _cap);

    // it should settle the gauge
    assertEq(_leafVoter.settleGaugeCalls(address(gauge)), 1);

    // it should write the cap
    assertEq(uint256(_gaugeFactory.emissionCap(address(gauge))), uint256(_cap));

    // it should emit EmissionCapSet
  }

  modifier whenTheCallerHasTheCapOperatorRole() {
    _;
  }

  function test_SetEmissionCapWhenTheCurrentCapIsZero()
    external
    whenTheGaugeIsValid
    whenTheCallerHasTheCapOperatorRole
  {
    CLGauge gauge = _createGauge('');
    vm.prank(_capAdmin);
    _gaugeFactory.setEmissionCap(address(gauge), 0);

    // it should revert with NA
    vm.prank(_capOperator);
    vm.expectRevert(bytes('NA'));
    _gaugeFactory.setEmissionCap(address(gauge), _operatorMinCap);
  }

  modifier whenTheCurrentCapIsNonzero() {
    _;
  }

  function test_SetEmissionCapWhenTheNewCapIsBelowTheOperatorRange(uint128 _cap)
    external
    whenTheGaugeIsValid
    whenTheCallerHasTheCapOperatorRole
    whenTheCurrentCapIsNonzero
  {
    _cap = uint128(bound(uint256(_cap), 0, _operatorMinCap - 1));
    CLGauge gauge = _createGauge('');

    // it should revert with CR
    vm.prank(_capOperator);
    vm.expectRevert(bytes('CR'));
    _gaugeFactory.setEmissionCap(address(gauge), _cap);
  }

  function test_SetEmissionCapWhenTheNewCapIsAboveTheOperatorRange(uint128 _cap)
    external
    whenTheGaugeIsValid
    whenTheCallerHasTheCapOperatorRole
    whenTheCurrentCapIsNonzero
  {
    _cap = uint128(bound(uint256(_cap), uint256(_operatorMaxCap) + 1, type(uint128).max));
    CLGauge gauge = _createGauge('');

    // it should revert with CR
    vm.prank(_capOperator);
    vm.expectRevert(bytes('CR'));
    _gaugeFactory.setEmissionCap(address(gauge), _cap);
  }

  function test_SetEmissionCapWhenTheNewCapIsInTheOperatorRange(uint128 _cap)
    external
    whenTheGaugeIsValid
    whenTheCallerHasTheCapOperatorRole
    whenTheCurrentCapIsNonzero
  {
    _cap = uint128(bound(uint256(_cap), _operatorMinCap, _operatorMaxCap));
    CLGauge gauge = _createGauge('');

    vm.prank(_capOperator);
    vm.expectEmit(address(_gaugeFactory));
    emit EmissionCapSet(address(gauge), _cap, _capOperator);
    _gaugeFactory.setEmissionCap(address(gauge), _cap);

    // it should settle the gauge
    assertEq(_leafVoter.settleGaugeCalls(address(gauge)), 1);

    // it should write the cap
    assertEq(uint256(_gaugeFactory.emissionCap(address(gauge))), uint256(_cap));

    // it should emit EmissionCapSet
  }

  modifier whenTheCallerIsTheEmergencyCouncil() {
    _;
  }

  function test_SetEmissionCapWhenTheCapIsNonzeroForEmergencyCouncil(uint128 _cap)
    external
    whenTheGaugeIsValid
    whenTheCallerIsTheEmergencyCouncil
  {
    _cap = uint128(bound(uint256(_cap), 1, type(uint128).max));
    CLGauge gauge = _createGauge('');

    // it should revert with NA
    vm.prank(_emergencyCouncil);
    vm.expectRevert(bytes('NA'));
    _gaugeFactory.setEmissionCap(address(gauge), _cap);
  }

  modifier whenTheCapIsZeroForEmergencyCouncil() {
    _;
  }

  function test_SetEmissionCapWhenFeeFlushingReverts_()
    external
    whenTheGaugeIsValid
    whenTheCallerIsTheEmergencyCouncil
    whenTheCapIsZeroForEmergencyCouncil
  {
    CLGauge gauge = _createGauge('');
    bytes memory revertData = _expectFlushFeesRevert(address(gauge));

    vm.prank(_emergencyCouncil);
    // it should revert with FeeCollectionFailed
    vm.expectRevert(revertData);
    _gaugeFactory.setEmissionCap(address(gauge), 0);
  }

  function test_SetEmissionCapWhenFeeFlushingSucceeds_()
    external
    whenTheGaugeIsValid
    whenTheCallerIsTheEmergencyCouncil
    whenTheCapIsZeroForEmergencyCouncil
  {
    CLGauge gauge = _createGauge('');
    uint128 priorCap = _gaugeFactory.emissionCap(address(gauge));
    assertGt(uint256(priorCap), 0);

    vm.prank(_emergencyCouncil);
    vm.expectEmit(address(_gaugeFactory));
    emit EmissionCapSet(address(gauge), 0, _emergencyCouncil);
    _gaugeFactory.setEmissionCap(address(gauge), 0);

    // it should settle the gauge
    assertEq(_leafVoter.settleGaugeCalls(address(gauge)), 1);

    // it should flush fees while the prior effective cap is nonzero
    assertEq(uint256(_votingRewardsManager.emissionCapDuringFlush()), uint256(priorCap));
    assertEq(_votingRewardsManager.flushFeesCalls(), 1);

    // it should write the zero cap
    assertEq(uint256(_gaugeFactory.emissionCap(address(gauge))), 0);

    // it should emit EmissionCapSet
  }

  function test_SetEmissionCapWhenTheCallerIsNotAuthorized(address _caller, uint128 _cap) external whenTheGaugeIsValid {
    vm.assume(_caller != address(0));
    vm.assume(_caller != _capAdmin);
    vm.assume(_caller != _capOperator);
    vm.assume(_caller != _emergencyCouncil);
    CLGauge gauge = _createGauge('');

    // it should revert with NA
    vm.prank(_caller);
    vm.expectRevert(bytes('NA'));
    _gaugeFactory.setEmissionCap(address(gauge), _cap);
  }

  function test_SetEmissionCapRolesWhenTheCallerHasAllRoles() external {
    _grantFactoryRole(_gaugeFactory.CAP_ADMIN_ROLE(), _emergencyCouncil);
    _grantFactoryRole(_gaugeFactory.CAP_OPERATOR_ROLE(), _emergencyCouncil);
    address gauge = address(_createGauge(''));
    uint128 otherCap = _operatorMaxCap + 1;

    vm.startPrank(_emergencyCouncil);

    // it should allow setting the emission cap to zero
    _gaugeFactory.setEmissionCap(gauge, 0);
    assertEq(uint256(_gaugeFactory.emissionCap(gauge)), 0);

    // it should allow setting the emission cap within the operator range
    _gaugeFactory.setEmissionCap(gauge, _operatorMinCap);
    assertEq(uint256(_gaugeFactory.emissionCap(gauge)), uint256(_operatorMinCap));

    // it should allow setting the emission cap to another nonzero value
    _gaugeFactory.setEmissionCap(gauge, otherCap);
    assertEq(uint256(_gaugeFactory.emissionCap(gauge)), uint256(otherCap));

    vm.stopPrank();
  }

  modifier whenTheCallerHasTheEmergencyCouncilRole() {
    _;
  }

  function test_SetEmissionCapRolesWhenTheCallerHasTheCapAdminRole() external whenTheCallerHasTheEmergencyCouncilRole {
    _grantFactoryRole(_gaugeFactory.CAP_ADMIN_ROLE(), _emergencyCouncil);
    address gauge = address(_createGauge(''));
    uint128 otherCap = _operatorMaxCap + 1;

    vm.startPrank(_emergencyCouncil);

    // it should allow setting the emission cap to zero
    _gaugeFactory.setEmissionCap(gauge, 0);
    assertEq(uint256(_gaugeFactory.emissionCap(gauge)), 0);

    // it should allow setting the emission cap within the operator range
    _gaugeFactory.setEmissionCap(gauge, _operatorMinCap);
    assertEq(uint256(_gaugeFactory.emissionCap(gauge)), uint256(_operatorMinCap));

    // it should allow setting the emission cap to another nonzero value
    _gaugeFactory.setEmissionCap(gauge, otherCap);
    assertEq(uint256(_gaugeFactory.emissionCap(gauge)), uint256(otherCap));

    vm.stopPrank();
  }

  function test_SetEmissionCapRolesWhenTheCallerHasTheCapOperatorRole()
    external
    whenTheCallerHasTheEmergencyCouncilRole
  {
    _grantFactoryRole(_gaugeFactory.CAP_OPERATOR_ROLE(), _emergencyCouncil);
    address gauge = address(_createGauge(''));
    uint128 otherCap = _operatorMaxCap + 1;

    vm.startPrank(_emergencyCouncil);

    // it should allow setting the emission cap to zero
    _gaugeFactory.setEmissionCap(gauge, 0);
    assertEq(uint256(_gaugeFactory.emissionCap(gauge)), 0);

    vm.stopPrank();
    /// @dev Restores a nonzero cap because cap operators cannot update a zero-capped gauge.
    vm.prank(_capAdmin);
    _gaugeFactory.setEmissionCap(gauge, _operatorMinCap);
    assertEq(uint256(_gaugeFactory.emissionCap(gauge)), uint256(_operatorMinCap));
    vm.startPrank(_emergencyCouncil);

    // it should allow setting the emission cap within the operator range
    _gaugeFactory.setEmissionCap(gauge, _operatorMaxCap);
    assertEq(uint256(_gaugeFactory.emissionCap(gauge)), uint256(_operatorMaxCap));

    // it should not allow setting the emission cap to another nonzero value
    vm.expectRevert(bytes('CR'));
    _gaugeFactory.setEmissionCap(gauge, otherCap);

    vm.stopPrank();
  }

  function test_SetEmissionCapRolesWhenTheCallerHasNoOtherRole() external whenTheCallerHasTheEmergencyCouncilRole {
    address gauge = address(_createGauge(''));
    uint128 otherCap = _operatorMaxCap + 1;

    vm.startPrank(_emergencyCouncil);

    // it should allow setting the emission cap to zero
    _gaugeFactory.setEmissionCap(gauge, 0);
    assertEq(uint256(_gaugeFactory.emissionCap(gauge)), 0);

    // it should not allow setting the emission cap within the operator range
    vm.expectRevert(bytes('NA'));
    _gaugeFactory.setEmissionCap(gauge, _operatorMinCap);

    // it should not allow setting the emission cap to another nonzero value
    vm.expectRevert(bytes('NA'));
    _gaugeFactory.setEmissionCap(gauge, otherCap);

    vm.stopPrank();
  }

  modifier whenTheCallerHasTheCapAdminRole_() {
    _;
  }

  function test_SetEmissionCapRolesWhenTheCallerHasTheCapOperatorRole_() external whenTheCallerHasTheCapAdminRole_ {
    _grantFactoryRole(_gaugeFactory.CAP_OPERATOR_ROLE(), _capAdmin);
    address gauge = address(_createGauge(''));
    uint128 otherCap = _operatorMaxCap + 1;

    vm.startPrank(_capAdmin);

    // it should allow setting the emission cap to zero
    _gaugeFactory.setEmissionCap(gauge, 0);
    assertEq(uint256(_gaugeFactory.emissionCap(gauge)), 0);

    // it should allow setting the emission cap within the operator range
    _gaugeFactory.setEmissionCap(gauge, _operatorMinCap);
    assertEq(uint256(_gaugeFactory.emissionCap(gauge)), uint256(_operatorMinCap));

    // it should allow setting the emission cap to another nonzero value
    _gaugeFactory.setEmissionCap(gauge, otherCap);
    assertEq(uint256(_gaugeFactory.emissionCap(gauge)), uint256(otherCap));

    vm.stopPrank();
  }

  function test_SetEmissionCapRolesWhenTheCallerHasNoOtherRole_() external whenTheCallerHasTheCapAdminRole_ {
    address gauge = address(_createGauge(''));
    uint128 otherCap = _operatorMaxCap + 1;

    vm.startPrank(_capAdmin);

    // it should allow setting the emission cap to zero
    _gaugeFactory.setEmissionCap(gauge, 0);
    assertEq(uint256(_gaugeFactory.emissionCap(gauge)), 0);

    // it should allow setting the emission cap within the operator range
    _gaugeFactory.setEmissionCap(gauge, _operatorMinCap);
    assertEq(uint256(_gaugeFactory.emissionCap(gauge)), uint256(_operatorMinCap));

    // it should allow setting the emission cap to another nonzero value
    _gaugeFactory.setEmissionCap(gauge, otherCap);
    assertEq(uint256(_gaugeFactory.emissionCap(gauge)), uint256(otherCap));

    vm.stopPrank();
  }

  function test_SetEmissionCapRolesWhenTheCallerHasOnlyTheCapOperatorRole() external {
    address gauge = address(_createGauge(''));
    uint128 otherCap = _operatorMaxCap + 1;

    vm.startPrank(_capOperator);

    // it should not allow setting the emission cap to zero
    vm.expectRevert(bytes('CR'));
    _gaugeFactory.setEmissionCap(gauge, 0);

    // it should allow setting the emission cap within the operator range
    _gaugeFactory.setEmissionCap(gauge, _operatorMinCap);
    assertEq(uint256(_gaugeFactory.emissionCap(gauge)), uint256(_operatorMinCap));

    // it should not allow setting the emission cap to another nonzero value
    vm.expectRevert(bytes('CR'));
    _gaugeFactory.setEmissionCap(gauge, otherCap);

    vm.stopPrank();
  }

  function test_ClearEmissionCapWhenTheGaugeIsInvalid(address _gauge) external {
    vm.assume(!_gaugeFactory.isGauge(_gauge));

    // it should revert with IG
    vm.expectRevert(bytes('IG'));
    _gaugeFactory.clearEmissionCap(_gauge);
  }

  function test_ClearEmissionCapWhenTheCallerIsNotTheEmergencyCouncil(address _caller) external whenTheGaugeIsValid {
    vm.assume(_caller != address(0));
    vm.assume(_caller != _emergencyCouncil);
    CLGauge gauge = _createGauge('');

    vm.prank(_caller);
    // it should revert with NA
    vm.expectRevert(bytes('NA'));
    _gaugeFactory.clearEmissionCap(address(gauge));
  }

  function test_ClearEmissionCapWhenFeeFlushingReverts()
    external
    whenTheGaugeIsValid
    whenTheCallerIsTheEmergencyCouncil
  {
    CLGauge gauge = _createGauge('');

    // it should attempt to flush fees
    _expectFlushFeesRevert(address(gauge));

    vm.prank(_emergencyCouncil);

    // it should emit FeeFlushFailed
    vm.expectEmit(address(_gaugeFactory));
    emit FeeFlushFailed(address(gauge));

    // it should emit EmissionCapSet
    vm.expectEmit(address(_gaugeFactory));
    emit EmissionCapSet(address(gauge), 0, _emergencyCouncil);
    _gaugeFactory.clearEmissionCap(address(gauge));

    // it should settle the gauge
    assertEq(_leafVoter.settleGaugeCalls(address(gauge)), 1);

    // it should write the zero cap
    assertEq(uint256(_gaugeFactory.emissionCap(address(gauge))), 0);
  }

  function test_ClearEmissionCapWhenFeeFlushingSucceeds()
    external
    whenTheGaugeIsValid
    whenTheCallerIsTheEmergencyCouncil
  {
    CLGauge gauge = _createGauge('');
    uint128 priorCap = _gaugeFactory.emissionCap(address(gauge));
    assertGt(uint256(priorCap), 0);

    vm.prank(_emergencyCouncil);
    vm.expectEmit(address(_gaugeFactory));
    emit EmissionCapSet(address(gauge), 0, _emergencyCouncil);
    _gaugeFactory.clearEmissionCap(address(gauge));

    // it should settle the gauge
    assertEq(_leafVoter.settleGaugeCalls(address(gauge)), 1);

    // it should flush fees while the prior effective cap is nonzero
    assertEq(uint256(_votingRewardsManager.emissionCapDuringFlush()), uint256(priorCap));
    assertEq(_votingRewardsManager.flushFeesCalls(), 1);

    // it should write the zero cap
    assertEq(uint256(_gaugeFactory.emissionCap(address(gauge))), 0);

    // it should emit EmissionCapSet
  }

  function test_SetMaxShareCapWhenTheCallerDoesNotHaveTheReferralAdminRole(address _caller, uint256 _cap) external {
    vm.assume(_caller != address(0));
    vm.assume(_caller != _referralAdmin);
    _cap = bound(_cap, 0, _gaugeFactory.MAX_PIPS());

    // it should revert with NA
    vm.prank(_caller);
    vm.expectRevert(bytes('NA'));
    _gaugeFactory.setMaxShareCap(_cap);
  }

  modifier whenTheCallerHasTheReferralAdminRole() {
    _;
  }

  function test_SetMaxShareCapWhenTheCapExceedsMaxPips(uint256 _cap) external whenTheCallerHasTheReferralAdminRole {
    _cap = bound(_cap, _gaugeFactory.MAX_PIPS() + 1, type(uint256).max);

    // it should revert with MSC
    vm.prank(_referralAdmin);
    vm.expectRevert(bytes('MSC'));
    _gaugeFactory.setMaxShareCap(_cap);
  }

  function test_SetMaxShareCapWhenTheCapIsValid(uint256 _cap) external whenTheCallerHasTheReferralAdminRole {
    _cap = bound(_cap, 0, _gaugeFactory.MAX_PIPS());

    vm.prank(_referralAdmin);
    vm.expectEmit(address(_gaugeFactory));
    emit MaxShareCapSet(_cap);
    _gaugeFactory.setMaxShareCap(_cap);

    // it should update maxShareCap
    assertEq(_gaugeFactory.maxShareCap(), _cap);

    // it should emit MaxShareCapSet
  }

  function test_SetReferralConfigWhenTheCallerDoesNotHaveTheReferralAdminRole(address _caller) external {
    vm.assume(_caller != address(0));
    vm.assume(_caller != _referralAdmin);
    CLGauge gauge = _createGauge('');

    // it should revert with NA
    vm.prank(_caller);
    vm.expectRevert(bytes('NA'));
    _gaugeFactory.setReferralConfig(address(gauge), makeAddr('referral'), 1);
  }

  function test_SetReferralConfigWhenTheGaugeIsInvalid(address _gauge) external whenTheCallerHasTheReferralAdminRole {
    vm.assume(!_gaugeFactory.isGauge(_gauge));

    // it should revert with IG
    vm.prank(_referralAdmin);
    vm.expectRevert(bytes('IG'));
    _gaugeFactory.setReferralConfig(_gauge, makeAddr('referral'), 1);
  }

  function test_SetReferralConfigWhenTheShareExceedsMaxShareCap(uint256 _share)
    external
    whenTheCallerHasTheReferralAdminRole
  {
    _share = bound(_share, _gaugeFactory.maxShareCap() + 1, type(uint256).max);
    CLGauge gauge = _createGauge('');

    // it should revert with SC
    vm.prank(_referralAdmin);
    vm.expectRevert(bytes('SC'));
    _gaugeFactory.setReferralConfig(address(gauge), makeAddr('referral'), _share);
  }

  function test_SetReferralConfigWhenShareIsNonzeroAndReferralIsTheZeroAddress(uint256 _share)
    external
    whenTheCallerHasTheReferralAdminRole
  {
    _share = bound(_share, 1, _gaugeFactory.maxShareCap());
    CLGauge gauge = _createGauge('');

    // it should revert with IR
    vm.prank(_referralAdmin);
    vm.expectRevert(bytes('IR'));
    _gaugeFactory.setReferralConfig(address(gauge), address(0), _share);
  }

  function test_SetReferralConfigWhenTheConfigIsValid(
    address _referral,
    uint256 _share
  ) external whenTheCallerHasTheReferralAdminRole {
    vm.assume(_referral != address(0));
    _share = bound(_share, 1, _gaugeFactory.maxShareCap());
    CLGauge gauge = _createGauge('');

    vm.prank(_referralAdmin);
    vm.expectEmit(address(_gaugeFactory));
    emit ReferralConfigSet(address(gauge), _referral, _share);
    _gaugeFactory.setReferralConfig(address(gauge), _referral, _share);

    // it should update referral config
    _assertReferralConfig(address(gauge), _referral, _share);

    // it should emit ReferralConfigSet
  }

  function test_SetReferralConfigWhenClearingTheConfig() external whenTheCallerHasTheReferralAdminRole {
    CLGauge gauge = _createGauge('');
    address referral = makeAddr('referral');
    vm.prank(_referralAdmin);
    _gaugeFactory.setReferralConfig(address(gauge), referral, 100);

    vm.prank(_referralAdmin);
    vm.expectEmit(address(_gaugeFactory));
    emit ReferralConfigSet(address(gauge), address(0), 0);
    _gaugeFactory.setReferralConfig(address(gauge), address(0), 0);

    // it should clear referral config
    _assertReferralConfig(address(gauge), address(0), 0);

    // it should emit ReferralConfigSet
  }

  function test_SetPenaltyConfigWhenTheCallerDoesNotHaveThePenaltyAdminRole(address _caller) external {
    vm.assume(_caller != address(0));
    vm.assume(_caller != _penaltyAdmin);

    // it should revert with NA
    vm.prank(_caller);
    vm.expectRevert(bytes('NA'));
    _gaugeFactory.setPenaltyConfig(10, 500_000);
  }

  modifier whenTheCallerHasThePenaltyAdminRole() {
    _;
  }

  function test_SetPenaltyConfigWhenPenaltyRateExceedsMaxPips(uint256 _penaltyRate)
    external
    whenTheCallerHasThePenaltyAdminRole
  {
    _penaltyRate = bound(_penaltyRate, _gaugeFactory.MAX_PIPS() + 1, type(uint256).max);

    // it should revert with MR
    vm.prank(_penaltyAdmin);
    vm.expectRevert(bytes('MR'));
    _gaugeFactory.setPenaltyConfig(10, _penaltyRate);
  }

  function test_SetPenaltyConfigWhenMinStakeBlocksExceedsMaxMinStakeBlocks(uint256 _minStakeBlocks)
    external
    whenTheCallerHasThePenaltyAdminRole
  {
    _minStakeBlocks = bound(_minStakeBlocks, _maxMinStakeBlocks + 1, type(uint256).max);
    uint256 maxPips = _gaugeFactory.MAX_PIPS();

    // it should revert with MS
    vm.prank(_penaltyAdmin);
    vm.expectRevert(bytes('MS'));
    _gaugeFactory.setPenaltyConfig(_minStakeBlocks, maxPips);
  }

  function test_SetPenaltyConfigWhenTheConfigIsValid(
    uint256 _minStakeBlocks,
    uint256 _penaltyRate
  ) external whenTheCallerHasThePenaltyAdminRole {
    _minStakeBlocks = bound(_minStakeBlocks, 0, _maxMinStakeBlocks);
    _penaltyRate = bound(_penaltyRate, 0, _gaugeFactory.MAX_PIPS());

    vm.prank(_penaltyAdmin);
    vm.expectEmit(address(_gaugeFactory));
    emit PenaltyConfigSet(_minStakeBlocks, _penaltyRate);
    _gaugeFactory.setPenaltyConfig(_minStakeBlocks, _penaltyRate);

    // it should update penaltyConfig
    ICLGaugeFactory.PenaltyConfig memory config = _gaugeFactory.penaltyConfig();
    assertEq(config.minStakeBlocks, _minStakeBlocks);
    assertEq(config.penaltyRate, _penaltyRate);

    // it should emit PenaltyConfigSet
  }

  function test_SetMinStakeBlocksWhenTheCallerDoesNotHaveThePenaltyAdminRole(address _caller) external {
    vm.assume(_caller != address(0));
    vm.assume(_caller != _penaltyAdmin);
    CLGauge gauge = _createGauge('');

    // it should revert with NA
    vm.prank(_caller);
    vm.expectRevert(bytes('NA'));
    _gaugeFactory.setMinStakeBlocks(address(gauge), 1);
  }

  function test_SetMinStakeBlocksWhenTheGaugeIsInvalid(address _gauge) external whenTheCallerHasThePenaltyAdminRole {
    vm.assume(!_gaugeFactory.isGauge(_gauge));

    // it should revert with IG
    vm.prank(_penaltyAdmin);
    vm.expectRevert(bytes('IG'));
    _gaugeFactory.setMinStakeBlocks(_gauge, 1);
  }

  function test_SetMinStakeBlocksWhenMinStakeBlocksExceedsMaxMinStakeBlocks(uint256 _minStakeBlocks)
    external
    whenTheCallerHasThePenaltyAdminRole
  {
    _minStakeBlocks = bound(_minStakeBlocks, _maxMinStakeBlocks + 1, type(uint256).max);
    CLGauge gauge = _createGauge('');

    // it should revert with MS
    vm.prank(_penaltyAdmin);
    vm.expectRevert(bytes('MS'));
    _gaugeFactory.setMinStakeBlocks(address(gauge), _minStakeBlocks);
  }

  function test_SetMinStakeBlocksWhenTheOverrideIsNonzero(uint256 _minStakeBlocks)
    external
    whenTheCallerHasThePenaltyAdminRole
  {
    _minStakeBlocks = bound(_minStakeBlocks, 1, _maxMinStakeBlocks);
    CLGauge gauge = _createGauge('');

    vm.prank(_penaltyAdmin);
    vm.expectEmit(address(_gaugeFactory));
    emit MinStakeBlocksSet(address(gauge), _minStakeBlocks);
    _gaugeFactory.setMinStakeBlocks(address(gauge), _minStakeBlocks);

    // it should update minStakeBlocks
    assertEq(_gaugeFactory.minStakeBlocks(address(gauge)), _minStakeBlocks);

    // it should emit MinStakeBlocksSet
  }

  function test_SetMinStakeBlocksWhenClearingTheOverride() external whenTheCallerHasThePenaltyAdminRole {
    CLGauge gauge = _createGauge('');
    vm.prank(_penaltyAdmin);
    _gaugeFactory.setMinStakeBlocks(address(gauge), 20);

    vm.prank(_penaltyAdmin);
    vm.expectEmit(address(_gaugeFactory));
    emit MinStakeBlocksSet(address(gauge), 0);
    _gaugeFactory.setMinStakeBlocks(address(gauge), 0);

    // it should set minStakeBlocks to the factory default
    assertEq(_gaugeFactory.minStakeBlocks(address(gauge)), _gaugeFactory.DEFAULT_MIN_STAKE_BLOCKS());

    // it should emit MinStakeBlocksSet
  }

  function _deployGaugeFactory() internal returns (CLGaugeFactory) {
    return _deployGaugeFactory(
      address(_leafVoter), _gaugeManager, address(_votingRewardsFactory), _nft, _roles(), _capConfig()
    );
  }

  function _deployGaugeFactory(
    address _leafVoterInput,
    address _gaugeManagerInput,
    address _votingRewardsFactoryInput,
    address _nftInput,
    CLGaugeFactory.RoleAddresses memory _rolesInput,
    CLGaugeFactory.CapConfig memory _capConfigInput
  ) internal returns (CLGaugeFactory) {
    return new CLGaugeFactory({
      _leafVoter: _leafVoterInput,
      _gaugeManager: _gaugeManagerInput,
      _votingRewardsFactory: _votingRewardsFactoryInput,
      _nft: _nftInput,
      _roles: _rolesInput,
      _capConfig: _capConfigInput
    });
  }

  function _roles() internal view returns (CLGaugeFactory.RoleAddresses memory) {
    return CLGaugeFactory.RoleAddresses({
      capAdmin: _capAdmin, referralAdmin: _referralAdmin, penaltyAdmin: _penaltyAdmin, capOperator: _capOperator
    });
  }

  function _capConfig() internal view returns (CLGaugeFactory.CapConfig memory) {
    return CLGaugeFactory.CapConfig({
      defaultCap: _defaultCap,
      operatorMinCap: _operatorMinCap,
      operatorMaxCap: _operatorMaxCap,
      maxMinStakeBlocks: _maxMinStakeBlocks
    });
  }

  function _createGauge(bytes memory _factoryData) internal returns (CLGauge gauge) {
    vm.prank(_gaugeManager);
    (address gaugeAddress,) = _gaugeFactory.createGauge(address(_pool), _factoryData);
    _votingRewardsManager.setGauge(address(_gaugeFactory), gaugeAddress);
    gauge = CLGauge(gaugeAddress);
  }

  function _grantFactoryRole(bytes32 _role, address _account) internal {
    vm.prank(_capAdmin);
    _gaugeFactory.grantRole(_role, _account);
  }

  function _assertReferralConfig(address _gauge, address _expectedReferral, uint256 _expectedShare) internal view {
    (address referral, uint256 share) = _gaugeFactory.referralConfig(_gauge);
    assertEq(referral, _expectedReferral);
    assertEq(share, _expectedShare);
  }

  function _expectFlushFeesRevert(address _gauge) internal returns (bytes memory revertData) {
    revertData = abi.encodeWithSelector(bytes4(keccak256('FeeCollectionFailed(address)')), _gauge);
    bytes memory callData = abi.encodeWithSelector(IVotingRewardsManager.flushFees.selector);
    vm.mockCallRevert(address(_votingRewardsManager), callData, revertData);
    vm.expectCall(address(_votingRewardsManager), callData);
  }

  function _salt(address _poolInput) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked(_poolInput));
  }

  function _independentCloneAddress(address _poolInput) internal view returns (address predicted) {
    bytes20 targetBytes = bytes20(address(_implementation));
    bytes32 codeHash = keccak256(
      abi.encodePacked(hex'3d602d80600a3d3981f3363d3d373d3d3d363d73', targetBytes, hex'5af43d82803e903d91602b57fd5bf3')
    );
    bytes32 digest = keccak256(abi.encodePacked(bytes1(0xff), address(_gaugeFactory), _salt(_poolInput), codeHash));
    predicted = address(uint160(uint256(digest)));
  }
}

contract MockCLGaugeFactoryLeafVoter {
  mapping(address => uint256) public settleGaugeCalls;
  mapping(bytes32 => mapping(address => bool)) public hasRole;

  constructor(address _emergencyCouncil) {
    hasRole[keccak256('EMERGENCY_COUNCIL_ROLE')][_emergencyCouncil] = true;
  }

  function settleGauge(address _gauge) external returns (uint256) {
    settleGaugeCalls[_gauge]++;
    return 0;
  }
}

contract MockCLGaugeFactoryPool {
  address public token0;
  address public token1;
  int24 public tickSpacing;
  address public gauge;
  address public nft;
  uint256 public setGaugeAndPositionManagerCalls;

  constructor(address _token0, address _token1, int24 _tickSpacing) {
    token0 = _token0;
    token1 = _token1;
    tickSpacing = _tickSpacing;
  }

  function setGaugeAndPositionManager(address _gauge, address _nft) external {
    gauge = _gauge;
    nft = _nft;
    setGaugeAndPositionManagerCalls++;
  }
}

contract MockCLGaugeFactoryVotingRewardsManager {
  uint256 public flushFeesCalls;
  uint128 public emissionCapDuringFlush;
  address internal _gaugeFactory;
  address internal _gauge;

  function setGauge(address gaugeFactory, address gauge) external {
    _gaugeFactory = gaugeFactory;
    _gauge = gauge;
  }

  function flushFees() external {
    emissionCapDuringFlush = ICLGaugeFactory(_gaugeFactory).emissionCap(_gauge);
    flushFeesCalls++;
  }
}

contract MockCLGaugeFactoryVotingRewardsFactory {
  address public votingRewardsManager;
  uint256 public createRewardsCalls;
  address public lastGauge;
  address[] internal _lastRewards;

  constructor(address _votingRewardsManager) {
    votingRewardsManager = _votingRewardsManager;
  }

  function createRewards(address _gauge, address[] memory _rewards) external returns (address) {
    createRewardsCalls++;
    lastGauge = _gauge;
    _lastRewards = _rewards;
    return votingRewardsManager;
  }

  function lastRewardToken(uint256 _index) external view returns (address) {
    return _lastRewards[_index];
  }
}
