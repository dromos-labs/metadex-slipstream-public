// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.7.6;
pragma abicoder v2;

import 'forge-std/Script.sol';
import 'forge-std/StdJson.sol';

import {CLFactory} from 'contracts/core/CLFactory.sol';
import {CLPool} from 'contracts/core/CLPool.sol';
import {CustomSwapFeeModule} from 'contracts/core/fees/CustomSwapFeeModule.sol';
import {CustomUnstakedFeeModule} from 'contracts/core/fees/CustomUnstakedFeeModule.sol';
import {CLGauge} from 'contracts/gauge/CLGauge.sol';
import {CLGaugeFactory} from 'contracts/gauge/CLGaugeFactory.sol';
import {LpMigrator} from 'contracts/periphery/LpMigrator.sol';
import {NonfungiblePositionManager} from 'contracts/periphery/NonfungiblePositionManager.sol';
import {NonfungibleTokenPositionDescriptor} from 'contracts/periphery/NonfungibleTokenPositionDescriptor.sol';
import {SwapRouter} from 'contracts/periphery/SwapRouter.sol';
import {MixedRouteQuoterV1} from 'contracts/periphery/lens/MixedRouteQuoterV1.sol';
import {MixedRouteQuoterV2} from 'contracts/periphery/lens/MixedRouteQuoterV2.sol';
import {MixedRouteQuoterV3} from 'contracts/periphery/lens/MixedRouteQuoterV3.sol';
import {QuoterV2} from 'contracts/periphery/lens/QuoterV2.sol';

/// @notice Shared CL deployment used by the root and leaf scripts.
abstract contract DeployBase is Script {
  using stdJson for string;

  address public constant PLACEHOLDER = 0x000000000000000000000000000000000000dEaD;

  string internal _constantsFilename;
  string internal _outputFilename;

  address public deployerAddress;
  address public team;
  address public weth;
  address public voter;
  address public gaugeManager;
  address public votingRewardsFactory;
  address public factoryRegistry;
  address public poolFactoryOwner;
  address public feeManager;
  address public factoryV2;
  address public legacyCLFactory;
  address public legacyCLFactory2;
  address public gaugeStakeManager;
  uint256 public minStakeBlocks;
  uint256 public penaltyRate;
  uint128 public defaultCap;
  uint128 public operatorMinCap;
  uint128 public operatorMaxCap;
  uint256 public maxMinStakeBlocks;
  string public nftName;
  string public nftSymbol;

  CLPool public poolImplementation;
  CLFactory public poolFactory;
  NonfungibleTokenPositionDescriptor public nftDescriptor;
  NonfungiblePositionManager public nft;
  CLGauge public gaugeImplementation;
  CLGaugeFactory public gaugeFactory;
  CustomSwapFeeModule public swapFeeModule;
  CustomUnstakedFeeModule public unstakedFeeModule;
  MixedRouteQuoterV1 public mixedQuoter;
  MixedRouteQuoterV2 public mixedQuoterV2;
  MixedRouteQuoterV3 public mixedQuoterV3;
  QuoterV2 public quoter;
  SwapRouter public swapRouter;
  LpMigrator public lpMigrator;

  function _loadConstants() internal {
    string memory path = string(abi.encodePacked(vm.projectRoot(), '/script/constants/', _constantsFilename));
    string memory jsonConstants = vm.readFile(path);

    deployerAddress = abi.decode(vm.parseJson(jsonConstants, '.deployer'), (address));
    team = abi.decode(vm.parseJson(jsonConstants, '.team'), (address));
    weth = abi.decode(vm.parseJson(jsonConstants, '.WETH'), (address));
    voter = abi.decode(vm.parseJson(jsonConstants, '.Voter'), (address));
    gaugeManager = abi.decode(vm.parseJson(jsonConstants, '.GaugeManager'), (address));
    votingRewardsFactory = abi.decode(vm.parseJson(jsonConstants, '.VotingRewardsFactory'), (address));
    factoryRegistry = abi.decode(vm.parseJson(jsonConstants, '.FactoryRegistry'), (address));
    poolFactoryOwner = abi.decode(vm.parseJson(jsonConstants, '.poolFactoryOwner'), (address));
    feeManager = abi.decode(vm.parseJson(jsonConstants, '.feeManager'), (address));
    factoryV2 = abi.decode(vm.parseJson(jsonConstants, '.factoryV2'), (address));
    legacyCLFactory = abi.decode(vm.parseJson(jsonConstants, '.legacyCLFactory'), (address));
    legacyCLFactory2 = abi.decode(vm.parseJson(jsonConstants, '.legacyCLFactory2'), (address));
    gaugeStakeManager = abi.decode(vm.parseJson(jsonConstants, '.gaugeStakeManager'), (address));
    minStakeBlocks = abi.decode(vm.parseJson(jsonConstants, '.minStakeBlocks'), (uint256));
    penaltyRate = abi.decode(vm.parseJson(jsonConstants, '.penaltyRate'), (uint256));
    uint256 parsedDefaultCap = abi.decode(vm.parseJson(jsonConstants, '.defaultCap'), (uint256));
    uint256 parsedOperatorMinCap = abi.decode(vm.parseJson(jsonConstants, '.operatorMinCap'), (uint256));
    uint256 parsedOperatorMaxCap = abi.decode(vm.parseJson(jsonConstants, '.operatorMaxCap'), (uint256));
    require(parsedDefaultCap <= type(uint128).max, 'default cap too large');
    require(parsedOperatorMinCap <= type(uint128).max, 'operator min cap too large');
    require(parsedOperatorMaxCap <= type(uint128).max, 'operator max cap too large');
    defaultCap = uint128(parsedDefaultCap);
    operatorMinCap = uint128(parsedOperatorMinCap);
    operatorMaxCap = uint128(parsedOperatorMaxCap);
    maxMinStakeBlocks = abi.decode(vm.parseJson(jsonConstants, '.maxMinStakeBlocks'), (uint256));
    nftName = abi.decode(vm.parseJson(jsonConstants, '.nftName'), (string));
    nftSymbol = abi.decode(vm.parseJson(jsonConstants, '.nftSymbol'), (string));

    require(deployerAddress != address(0) && deployerAddress != PLACEHOLDER, 'deployer not set');
    require(voter != address(0) && voter != PLACEHOLDER, 'Voter not set');
    require(gaugeManager != address(0) && gaugeManager != PLACEHOLDER, 'GaugeManager not set');
    require(votingRewardsFactory != address(0) && votingRewardsFactory != PLACEHOLDER, 'VotingRewardsFactory not set');
  }

  function _deploy() internal {
    poolImplementation = new CLPool();
    poolFactory = new CLFactory({
      _owner: deployerAddress,
      _swapFeeManager: deployerAddress,
      _unstakedFeeManager: deployerAddress,
      _voter: voter,
      _poolImplementation: address(poolImplementation),
      _swapHookManager: deployerAddress,
      _defaultSwapHook: address(0),
      _discountRegistryManager: deployerAddress,
      _clPoolTapeManager: deployerAddress
    });

    nftDescriptor =
      new NonfungibleTokenPositionDescriptor({_WETH9: address(weth), _nativeCurrencyLabelBytes: bytes32('ETH')});
    nft = new NonfungiblePositionManager({
      _owner: team,
      _factory: address(poolFactory),
      _WETH9: address(weth),
      _tokenDescriptor: address(nftDescriptor),
      name: nftName,
      symbol: nftSymbol
    });

    gaugeFactory = new CLGaugeFactory({
      _leafVoter: voter,
      _gaugeManager: gaugeManager,
      _votingRewardsFactory: votingRewardsFactory,
      _nft: address(nft),
      _roles: CLGaugeFactory.RoleAddresses({
        capAdmin: deployerAddress,
        referralAdmin: deployerAddress,
        penaltyAdmin: deployerAddress,
        capOperator: gaugeStakeManager
      }),
      _capConfig: CLGaugeFactory.CapConfig({
        defaultCap: defaultCap,
        operatorMinCap: operatorMinCap,
        operatorMaxCap: operatorMaxCap,
        maxMinStakeBlocks: maxMinStakeBlocks
      })
    });
    gaugeImplementation = CLGauge(gaugeFactory.implementation());

    gaugeFactory.setPenaltyConfig(minStakeBlocks, penaltyRate);
    gaugeFactory.grantRole(gaugeFactory.CAP_ADMIN_ROLE(), gaugeStakeManager);
    gaugeFactory.grantRole(gaugeFactory.REFERRAL_ADMIN_ROLE(), gaugeStakeManager);
    gaugeFactory.grantRole(gaugeFactory.PENALTY_ADMIN_ROLE(), gaugeStakeManager);
    gaugeFactory.renounceRole(gaugeFactory.CAP_ADMIN_ROLE(), deployerAddress);
    gaugeFactory.renounceRole(gaugeFactory.REFERRAL_ADMIN_ROLE(), deployerAddress);
    gaugeFactory.renounceRole(gaugeFactory.PENALTY_ADMIN_ROLE(), deployerAddress);

    swapFeeModule = new CustomSwapFeeModule({_factory: address(poolFactory)});
    unstakedFeeModule = new CustomUnstakedFeeModule({_factory: address(poolFactory)});
    poolFactory.setSwapFeeModule({_swapFeeModule: address(swapFeeModule)});
    poolFactory.setUnstakedFeeModule({_unstakedFeeModule: address(unstakedFeeModule)});

    poolFactory.setOwner(poolFactoryOwner);
    poolFactory.setSwapFeeManager(feeManager);
    poolFactory.setUnstakedFeeManager(feeManager);

    mixedQuoter = new MixedRouteQuoterV1({_factory: address(poolFactory), _factoryV2: factoryV2, _WETH9: weth});
    quoter = new QuoterV2({_factory: address(poolFactory), _WETH9: weth});
    swapRouter = new SwapRouter({_factory: address(poolFactory), _WETH9: weth});
    mixedQuoterV2 = new MixedRouteQuoterV2({_factory: address(poolFactory), _factoryV2: factoryV2, _WETH9: weth});
    mixedQuoterV3 = new MixedRouteQuoterV3({
      _factory: address(poolFactory),
      _legacyCLFactory: legacyCLFactory,
      _legacyCLFactory2: legacyCLFactory2,
      _factoryV2: factoryV2,
      _WETH9: weth
    });
    lpMigrator = new LpMigrator();
  }

  function _writeOutput() internal {
    string memory path = string(abi.encodePacked(vm.projectRoot(), '/script/constants/output/', _outputFilename));
    vm.writeJson(vm.serializeAddress('', 'PoolImplementation', address(poolImplementation)), path);
    vm.writeJson(vm.serializeAddress('', 'PoolFactory', address(poolFactory)), path);
    vm.writeJson(vm.serializeAddress('', 'NonfungibleTokenPositionDescriptor', address(nftDescriptor)), path);
    vm.writeJson(vm.serializeAddress('', 'NonfungiblePositionManager', address(nft)), path);
    vm.writeJson(vm.serializeAddress('', 'GaugeImplementation', address(gaugeImplementation)), path);
    vm.writeJson(vm.serializeAddress('', 'GaugeFactory', address(gaugeFactory)), path);
    vm.writeJson(vm.serializeAddress('', 'CustomSwapFeeModule', address(swapFeeModule)), path);
    vm.writeJson(vm.serializeAddress('', 'UnstakedFeeModule', address(unstakedFeeModule)), path);
    vm.writeJson(vm.serializeAddress('', 'MixedQuoter', address(mixedQuoter)), path);
    vm.writeJson(vm.serializeAddress('', 'MixedQuoterV2', address(mixedQuoterV2)), path);
    vm.writeJson(vm.serializeAddress('', 'MixedQuoterV3', address(mixedQuoterV3)), path);
    vm.writeJson(vm.serializeAddress('', 'Quoter', address(quoter)), path);
    vm.writeJson(vm.serializeAddress('', 'SwapRouter', address(swapRouter)), path);
    vm.writeJson(vm.serializeAddress('', 'LpMigrator', address(lpMigrator)), path);
  }

  function run() public {
    _loadConstants();
    vm.startBroadcast(deployerAddress);
    _deploy();
    vm.stopBroadcast();
    _writeOutput();
  }
}
