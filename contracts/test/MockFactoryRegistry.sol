// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity =0.7.6;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {IFactoryRegistry} from 'contracts/core/interfaces/IFactoryRegistry.sol';
import {ICLGaugeFactory} from 'contracts/gauge/interfaces/ICLGaugeFactory.sol';
import {EnumerableSet} from 'contracts/libraries/EnumerableSet.sol';

contract MockFactoryRegistry is Ownable, IFactoryRegistry {
  using EnumerableSet for EnumerableSet.AddressSet;

  EnumerableSet.AddressSet private _targetFactories;

  mapping(address => address) private _targetFactoryToGaugeFactory;

  mapping(address => address) public targetToFactory;

  mapping(address => address) public override targetToGauge;

  mapping(address => address) public gaugeToFactory;

  function registerFactories(address gaugeFactory, address targetFactory) public override {
    require(!_targetFactories.contains(targetFactory));
    _targetFactories.add(targetFactory);
    _targetFactoryToGaugeFactory[targetFactory] = gaugeFactory;
  }

  function isTargetFactoryApproved(address targetFactory) external view override returns (bool) {
    return _targetFactories.contains(targetFactory);
  }

  function registerTarget(address target) external override {
    require(_targetFactories.contains(msg.sender), 'TargetFactoryNotRegistered');
    require(target != address(0), 'ZeroAddress');
    require(targetToFactory[target] == address(0), 'TargetAlreadyRecorded');
    targetToFactory[target] = msg.sender;
  }

  function registerGauge(address target, address gauge) external {
    require(targetToGauge[target] == address(0), 'TargetAlreadyLinked');
    targetToGauge[target] = gauge;
    gaugeToFactory[gauge] = _targetFactoryToGaugeFactory[targetToFactory[target]];
  }

  function emissionCap(address gauge) external view override returns (uint128) {
    address gaugeFactory = gaugeToFactory[gauge];
    if (gaugeFactory == address(0)) return 0;
    return ICLGaugeFactory(gaugeFactory).emissionCap(gauge);
  }

  function targetFactoryToGaugeFactory(address targetFactory) public view override returns (address) {
    return _targetFactoryToGaugeFactory[targetFactory];
  }
}
