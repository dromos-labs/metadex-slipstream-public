// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {CLFactory} from 'contracts/core/CLFactory.sol';
import {IFactoryRegistry} from 'contracts/core/interfaces/IFactoryRegistry.sol';
import {IVoter} from 'contracts/core/interfaces/IVoter.sol';
import {IVotingEscrow} from 'contracts/core/interfaces/IVotingEscrow.sol';
import {CLGaugeFactory} from 'contracts/gauge/CLGaugeFactory.sol';
import {ILeafVoter} from 'contracts/gauge/interfaces/ILeafVoter.sol';
import {MockFactoryRegistry} from 'contracts/test/MockFactoryRegistry.sol';

contract MockVoter is IVoter {
  // mock addresses used for testing gauge creation, a copy is stored in Constants.sol
  address public forwarder = address(11);

  // Rewards are released over 7 days
  uint256 internal constant DURATION = 7 days;

  /// @dev pool => gauge
  mapping(address => address) public override gauges;
  /// @dev gauge => isAlive
  mapping(address => bool) public override isAlive;
  /// @dev gauge => isActivated (LeafVoter-compatible)
  mapping(address => bool) public isActivated;
  mapping(address => address) public override gaugeToFees;
  mapping(address => address) public override gaugeToBribes;
  mapping(bytes32 => mapping(address => bool)) public hasRole;

  IERC20 public immutable rewardToken;
  IFactoryRegistry public immutable override factoryRegistry;
  IVotingEscrow public immutable override ve;
  address public immutable override emergencyCouncil;
  mapping(address => uint256) public settleGaugeCalls;
  /// @dev gauge => cumulative reward share returned by settleGauge (LeafVoter-compatible)
  mapping(address => uint256) public cumulativeRewardShare;

  constructor(address _rewardToken, address _factoryRegistry, address _ve) {
    rewardToken = IERC20(_rewardToken);
    factoryRegistry = IFactoryRegistry(_factoryRegistry);
    ve = IVotingEscrow(_ve);
    emergencyCouncil = msg.sender;
    hasRole[keccak256('EMERGENCY_COUNCIL_ROLE')][msg.sender] = true;
  }

  function claimFees(address[] memory, address[][] memory, uint256) external override {}

  function distribute(address[] memory) external pure override {
    revert('Not implemented');
  }

  function createGauge(address _poolFactory, address _pool) external override returns (address) {
    require(factoryRegistry.isTargetFactoryApproved(_poolFactory));
    address gaugeFactory = factoryRegistry.targetFactoryToGaugeFactory(_poolFactory);

    /// @dev mimic flow in real gauge manager; the gauge factory deploys the
    ///      voting rewards manager alongside the gauge
    (address gauge, address votingRewardsManager) = CLGaugeFactory(gaugeFactory).createGauge(_pool, '');
    require(CLFactory(_poolFactory).isPool(_pool));
    isAlive[gauge] = true;
    isActivated[gauge] = true;
    gauges[_pool] = gauge;
    MockFactoryRegistry(address(factoryRegistry)).registerGauge(_pool, gauge);
    gaugeToFees[gauge] = votingRewardsManager;
    gaugeToBribes[gauge] = votingRewardsManager;
    return gauge;
  }

  function distribute(address) external pure override {
    revert('Not implemented');
  }

  function settleGauge(address gauge) external returns (uint256) {
    settleGaugeCalls[gauge]++;
    return cumulativeRewardShare[gauge];
  }

  function projectedCumulativeRewardShare(address gauge) external view returns (uint256) {
    return cumulativeRewardShare[gauge];
  }

  function setCumulativeRewardShare(address gauge, uint256 share) external {
    cumulativeRewardShare[gauge] = share;
  }

  function gaugeStates(address gauge)
    external
    view
    returns (uint128, uint128, uint48, bool, bool, uint128, uint256, uint256, ILeafVoter.Point memory)
  {
    return (0, 0, 0, isActivated[gauge], isActivated[gauge], 0, 0, 0, ILeafVoter.Point(0, 0, 0, 0));
  }

  function killGauge(address gauge) external override {
    isAlive[gauge] = false;
    isActivated[gauge] = false;
  }

  function vote(uint256 _tokenId, address[] calldata _poolVote, uint256[] calldata _weights) external override {}
}
