// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.7.6;
pragma abicoder v2;

import 'forge-std/Script.sol';
import 'forge-std/StdJson.sol';

import {CLFactory} from 'contracts/core/CLFactory.sol';
import {CLPool} from 'contracts/core/CLPool.sol';
import {CustomUnstakedFeeModule} from 'contracts/core/fees/CustomUnstakedFeeModule.sol';
import {CLGauge} from 'contracts/gauge/CLGauge.sol';
import {CLGaugeFactory} from 'contracts/gauge/CLGaugeFactory.sol';
import {LpMigrator} from 'contracts/periphery/LpMigrator.sol';
import {NonfungiblePositionManager} from 'contracts/periphery/NonfungiblePositionManager.sol';
import {NonfungibleTokenPositionDescriptor} from 'contracts/periphery/NonfungibleTokenPositionDescriptor.sol';
import {SwapRouter} from 'contracts/periphery/SwapRouter.sol';
import {IV3FactoryRegistry} from 'contracts/periphery/interfaces/IV3FactoryRegistry.sol';
import {Metaquoter} from 'contracts/periphery/lens/Metaquoter.sol';
import {MixedRouteQuoterV1} from 'contracts/periphery/lens/MixedRouteQuoterV1.sol';
import {MixedRouteQuoterV2} from 'contracts/periphery/lens/MixedRouteQuoterV2.sol';
import {MixedRouteQuoterV3} from 'contracts/periphery/lens/MixedRouteQuoterV3.sol';
import {QuoterV2} from 'contracts/periphery/lens/QuoterV2.sol';

contract DeployCL is Script {
  using stdJson for string;

  address public constant deployerAddress = 0x4994DacdB9C57A811aFfbF878D92E00EF2E5C4C2;
  // Fail-loud sentinel used in constants files for contracts not yet deployed
  address public constant PLACEHOLDER = 0x000000000000000000000000000000000000dEaD;
  string public constantsFilename = vm.envString('CONSTANTS_FILENAME');
  string public outputFilename = vm.envString('OUTPUT_FILENAME');
  string public jsonConstants;

  // loaded variables
  address public team;
  address public weth;
  address public voter;
  address public gaugeManager;
  address public votingRewardsFactory;
  address public factoryRegistry;
  // Metadex "target factory" registry the Metaquoter authenticates pools against through
  // `isTargetFactoryApproved` and `targetToFactory`.
  address public targetFactoryRegistry;
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

  // deployed contracts
  CLPool public poolImplementation;
  CLFactory public poolFactory;
  NonfungibleTokenPositionDescriptor public nftDescriptor;
  NonfungiblePositionManager public nft;
  CLGauge public gaugeImplementation;
  CLGaugeFactory public gaugeFactory;
  CustomUnstakedFeeModule public unstakedFeeModule;
  MixedRouteQuoterV1 public mixedQuoter;
  MixedRouteQuoterV2 public mixedQuoterV2;
  MixedRouteQuoterV3 public mixedQuoterV3;
  Metaquoter public metaquoter;
  QuoterV2 public quoter;
  SwapRouter public swapRouter;
  LpMigrator public lpMigrator;

  function run() public {
    string memory root = vm.projectRoot();
    string memory basePath = concat(root, '/script/constants/');
    string memory path = concat(basePath, constantsFilename);
    jsonConstants = vm.readFile(path);

    team = abi.decode(vm.parseJson(jsonConstants, '.team'), (address));
    weth = abi.decode(vm.parseJson(jsonConstants, '.WETH'), (address));
    voter = abi.decode(vm.parseJson(jsonConstants, '.Voter'), (address));
    gaugeManager = abi.decode(vm.parseJson(jsonConstants, '.GaugeManager'), (address));
    votingRewardsFactory = abi.decode(vm.parseJson(jsonConstants, '.VotingRewardsFactory'), (address));
    factoryRegistry = abi.decode(vm.parseJson(jsonConstants, '.FactoryRegistry'), (address));
    targetFactoryRegistry = abi.decode(vm.parseJson(jsonConstants, '.TargetFactoryRegistry'), (address));
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

    require(address(voter) != address(0)); // sanity check for constants file fillled out correctly
    // reject placeholder wiring addresses before broadcasting
    _requireWired(gaugeManager, 'GaugeManager not set');
    _requireWired(votingRewardsFactory, 'VotingRewardsFactory not set');
    // the registry is deployed by the metadex unit; the factory stores it as an immutable and
    // every createPool registers the pool as a target, so it must be a real address at deploy time
    _requireWired(factoryRegistry, 'FactoryRegistry not set');
    // TODO: set `.TargetFactoryRegistry` to the deployed metadex registry (pending PR #407) before broadcasting; the
    // Metaquoter stores it as an immutable and reverts every quote if it lacks `isTargetFactoryApproved`.
    _requireWired(targetFactoryRegistry, 'TargetFactoryRegistry not set');
    // probe the registry ABI before broadcasting: a mis-wired address would deploy a quoter that reverts on
    // every quote
    IV3FactoryRegistry(targetFactoryRegistry).isTargetFactoryApproved(address(0));

    vm.startBroadcast(deployerAddress);
    // deploy pool + factory
    poolImplementation = new CLPool();
    poolFactory = new CLFactory({
      _owner: deployerAddress,
      _swapFeeManager: deployerAddress,
      _unstakedFeeManager: deployerAddress,
      _voter: voter,
      _poolImplementation: address(poolImplementation),
      _factoryRegistry: factoryRegistry,
      // TODO: Set default hook address
      _defaultSwapHook: address(0),
      _discountRegistryManager: deployerAddress,
      _clPoolTapeManager: deployerAddress
    });

    // deploy nft contracts
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

    // deploy gauges
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

    // configure gauge factory stake parameters
    gaugeFactory.setPenaltyConfig(minStakeBlocks, penaltyRate);
    gaugeFactory.grantRole(gaugeFactory.CAP_ADMIN_ROLE(), gaugeStakeManager);
    gaugeFactory.grantRole(gaugeFactory.REFERRAL_ADMIN_ROLE(), gaugeStakeManager);
    gaugeFactory.grantRole(gaugeFactory.PENALTY_ADMIN_ROLE(), gaugeStakeManager);
    gaugeFactory.renounceRole(gaugeFactory.CAP_ADMIN_ROLE(), deployerAddress);
    gaugeFactory.renounceRole(gaugeFactory.REFERRAL_ADMIN_ROLE(), deployerAddress);
    gaugeFactory.renounceRole(gaugeFactory.PENALTY_ADMIN_ROLE(), deployerAddress);

    // deploy fee modules
    unstakedFeeModule = new CustomUnstakedFeeModule({_factory: address(poolFactory)});
    poolFactory.setUnstakedFeeModule({_unstakedFeeModule: address(unstakedFeeModule)});

    // transfer permissions
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
    metaquoter = new Metaquoter({_factoryRegistry: targetFactoryRegistry});
    lpMigrator = new LpMigrator();
    vm.stopBroadcast();

    // write to file
    path = concat(basePath, 'output/DeployCL-');
    path = concat(path, outputFilename);
    vm.writeJson(vm.serializeAddress('', 'PoolImplementation', address(poolImplementation)), path);
    vm.writeJson(vm.serializeAddress('', 'PoolFactory', address(poolFactory)), path);
    vm.writeJson(vm.serializeAddress('', 'NonfungibleTokenPositionDescriptor', address(nftDescriptor)), path);
    vm.writeJson(vm.serializeAddress('', 'NonfungiblePositionManager', address(nft)), path);
    vm.writeJson(vm.serializeAddress('', 'GaugeImplementation', address(gaugeImplementation)), path);
    vm.writeJson(vm.serializeAddress('', 'GaugeFactory', address(gaugeFactory)), path);
    vm.writeJson(vm.serializeAddress('', 'UnstakedFeeModule', address(unstakedFeeModule)), path);
    vm.writeJson(vm.serializeAddress('', 'MixedQuoter', address(mixedQuoter)), path);
    vm.writeJson(vm.serializeAddress('', 'MixedQuoterV2', address(mixedQuoterV2)), path);
    vm.writeJson(vm.serializeAddress('', 'MixedQuoterV3', address(mixedQuoterV3)), path);
    vm.writeJson(vm.serializeAddress('', 'Metaquoter', address(metaquoter)), path);
    vm.writeJson(vm.serializeAddress('', 'Quoter', address(quoter)), path);
    vm.writeJson(vm.serializeAddress('', 'SwapRouter', address(swapRouter)), path);
    vm.writeJson(vm.serializeAddress('', 'LpMigrator', address(lpMigrator)), path);
  }

  function concat(string memory a, string memory b) internal pure returns (string memory) {
    return string(abi.encodePacked(a, b));
  }

  /// @dev Rejects the zero address and the fail-loud PLACEHOLDER sentinel for wiring parameters
  function _requireWired(address _addr, string memory _label) internal pure {
    require(_addr != address(0) && _addr != PLACEHOLDER, _label);
  }
}
