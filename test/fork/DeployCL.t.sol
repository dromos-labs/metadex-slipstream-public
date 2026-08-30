pragma solidity ^0.7.6;
pragma abicoder v2;

import 'forge-std/StdJson.sol';
import 'forge-std/Test.sol';

import {CLFactory} from 'contracts/core/CLFactory.sol';
import {CLPool} from 'contracts/core/CLPool.sol';
import {CustomUnstakedFeeModule} from 'contracts/core/fees/CustomUnstakedFeeModule.sol';
import {CLGauge} from 'contracts/gauge/CLGauge.sol';
import {CLGaugeFactory} from 'contracts/gauge/CLGaugeFactory.sol';
import {ICLGaugeFactory} from 'contracts/gauge/interfaces/ICLGaugeFactory.sol';
import {NonfungiblePositionManager} from 'contracts/periphery/NonfungiblePositionManager.sol';
import {NonfungibleTokenPositionDescriptor} from 'contracts/periphery/NonfungibleTokenPositionDescriptor.sol';
import {IV3FactoryRegistry} from 'contracts/periphery/interfaces/IV3FactoryRegistry.sol';
import {Metaquoter} from 'contracts/periphery/lens/Metaquoter.sol';
import {MixedRouteQuoterV2} from 'contracts/periphery/lens/MixedRouteQuoterV2.sol';
import {DeployCL} from 'script/DeployCL.s.sol';

contract DeployCLForkTest is Test {
  using stdJson for string;

  DeployCL public deployCL;

  string public constantsFilename = vm.envString('CONSTANTS_FILENAME');
  address public deployerAddress = 0x4994DacdB9C57A811aFfbF878D92E00EF2E5C4C2;
  string public jsonConstants;
  string public patchedConstantsPath;

  // fail-loud sentinel used in constants files for contracts not yet deployed
  address public constant PLACEHOLDER = 0x000000000000000000000000000000000000dEaD;

  // loaded variables
  address public team;
  address public weth;
  address public voter;
  address public gaugeManager;
  address public votingRewardsFactory;
  address public factoryRegistry;
  address public targetFactoryRegistry;
  address public poolFactoryOwner;
  address public feeManager;
  address public factoryV2;
  address public gaugeStakeManager;
  uint256 public minStakeBlocks;
  uint256 public penaltyRate;
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
  MixedRouteQuoterV2 public mixedQuoterV2;
  Metaquoter public metaquoter;

  function setUp() public {
    vm.createSelectFork({urlOrAlias: 'optimism', blockNumber: 109_241_151});

    string memory root = vm.projectRoot();
    string memory path = concat(root, '/script/constants/');
    path = concat(path, constantsFilename);
    jsonConstants = vm.readFile(path);

    team = abi.decode(vm.parseJson(jsonConstants, '.team'), (address));
    weth = abi.decode(vm.parseJson(jsonConstants, '.WETH'), (address));
    voter = abi.decode(vm.parseJson(jsonConstants, '.Voter'), (address));
    gaugeManager = abi.decode(vm.parseJson(jsonConstants, '.GaugeManager'), (address));
    votingRewardsFactory = abi.decode(vm.parseJson(jsonConstants, '.VotingRewardsFactory'), (address));
    factoryRegistry = abi.decode(vm.parseJson(jsonConstants, '.FactoryRegistry'), (address));
    targetFactoryRegistry = abi.decode(vm.parseJson(jsonConstants, '.TargetFactoryRegistry'), (address));
    factoryV2 = abi.decode(vm.parseJson(jsonConstants, '.factoryV2'), (address));
    poolFactoryOwner = abi.decode(vm.parseJson(jsonConstants, '.poolFactoryOwner'), (address));
    feeManager = abi.decode(vm.parseJson(jsonConstants, '.feeManager'), (address));
    gaugeStakeManager = abi.decode(vm.parseJson(jsonConstants, '.gaugeStakeManager'), (address));
    minStakeBlocks = abi.decode(vm.parseJson(jsonConstants, '.minStakeBlocks'), (uint256));
    penaltyRate = abi.decode(vm.parseJson(jsonConstants, '.penaltyRate'), (uint256));
    nftName = abi.decode(vm.parseJson(jsonConstants, '.nftName'), (string));
    nftSymbol = abi.decode(vm.parseJson(jsonConstants, '.nftSymbol'), (string));

    // The committed constants file may carry fail-loud placeholders for the metadex
    // contracts that are not deployed yet, and DeployCL refuses to broadcast those.
    // Run the script against a patched copy wired with distinct dummy addresses.
    if (gaugeManager == PLACEHOLDER || votingRewardsFactory == PLACEHOLDER || targetFactoryRegistry == PLACEHOLDER) {
      gaugeManager = makeAddr('gaugeManager');
      votingRewardsFactory = makeAddr('votingRewardsFactory');
      targetFactoryRegistry = makeAddr('targetFactoryRegistry');
      patchedConstantsPath = concat(root, '/script/constants/output/DeployCLForkTest-constants.json');
      vm.copyFile(path, patchedConstantsPath);
      vm.writeJson(quote(vm.toString(gaugeManager)), patchedConstantsPath, '.GaugeManager');
      vm.writeJson(quote(vm.toString(votingRewardsFactory)), patchedConstantsPath, '.VotingRewardsFactory');
      vm.writeJson(quote(vm.toString(targetFactoryRegistry)), patchedConstantsPath, '.TargetFactoryRegistry');
      vm.setEnv('CONSTANTS_FILENAME', 'output/DeployCLForkTest-constants.json');
      // the script probes this address for IV3FactoryRegistry conformance before broadcasting; the dummy carries no
      // code, so answer the probe here. The matching expectCall lives in the test body: an expectation declared here
      // would be validated at the end of setUp, before the script ever runs.
      vm.mockCall(
        targetFactoryRegistry,
        abi.encodeWithSelector(IV3FactoryRegistry.isTargetFactoryApproved.selector, address(0)),
        abi.encode(false)
      );
    }

    // DeployCL reads CONSTANTS_FILENAME at construction; restore the env var afterwards
    deployCL = new DeployCL();
    vm.setEnv('CONSTANTS_FILENAME', constantsFilename);

    deal(address(deployerAddress), 10 ether);
  }

  function test_deployCL() public {
    // pairs with the mock in setUp: pin that the script probes the mocked registry before broadcasting
    if (bytes(patchedConstantsPath).length != 0) {
      vm.expectCall(
        targetFactoryRegistry, abi.encodeWithSelector(IV3FactoryRegistry.isTargetFactoryApproved.selector, address(0))
      );
    }
    deployCL.run();
    if (bytes(patchedConstantsPath).length != 0) vm.removeFile(patchedConstantsPath);

    // preload variables for convenience
    poolImplementation = deployCL.poolImplementation();
    poolFactory = deployCL.poolFactory();
    nftDescriptor = deployCL.nftDescriptor();
    nft = deployCL.nft();
    gaugeImplementation = deployCL.gaugeImplementation();
    gaugeFactory = deployCL.gaugeFactory();
    unstakedFeeModule = deployCL.unstakedFeeModule();
    mixedQuoterV2 = deployCL.mixedQuoterV2();
    metaquoter = deployCL.metaquoter();

    assertTrue(address(poolImplementation) != address(0));
    assertTrue(address(poolFactory) != address(0));
    assertEq(address(poolFactory.voter()), voter);
    assertEq(address(poolFactory.poolImplementation()), address(poolImplementation));
    assertEq(address(poolFactory.factoryRegistry()), factoryRegistry);
    assertEq(address(poolFactory.owner()), poolFactoryOwner);
    assertEq(address(poolFactory.swapFeeManager()), feeManager);
    assertEq(address(poolFactory.unstakedFeeModule()), address(unstakedFeeModule));
    assertEq(address(poolFactory.unstakedFeeManager()), feeManager);
    assertEqUint(poolFactory.defaultUnstakedFee(), 100_000);
    assertEqUint(poolFactory.tickSpacingToFee(1), 100);
    assertEqUint(poolFactory.tickSpacingToFee(50), 500);
    assertEqUint(poolFactory.tickSpacingToFee(100), 500);
    assertEqUint(poolFactory.tickSpacingToFee(200), 3000);
    assertEqUint(poolFactory.tickSpacingToFee(2000), 10_000);

    assertTrue(address(nftDescriptor) != address(0));
    assertEq(nftDescriptor.WETH9(), weth);
    assertEq(nftDescriptor.nativeCurrencyLabelBytes(), bytes32('ETH'));

    assertTrue(address(nft) != address(0));
    assertEq(nft.factory(), address(poolFactory));
    assertEq(nft.WETH9(), weth);
    assertEq(nft.owner(), team);
    assertEq(nft.name(), nftName);
    assertEq(nft.symbol(), nftSymbol);

    assertTrue(address(gaugeImplementation) != address(0));
    assertTrue(address(gaugeFactory) != address(0));
    assertEq(gaugeFactory.leafVoter(), voter);
    assertEq(gaugeFactory.gaugeManager(), gaugeManager);
    assertEq(gaugeFactory.votingRewardsFactory(), votingRewardsFactory);
    assertEq(gaugeFactory.implementation(), address(gaugeImplementation));
    assertEq(gaugeFactory.nft(), address(nft));
    assertTrue(gaugeFactory.hasRole(gaugeFactory.PENALTY_ADMIN_ROLE(), gaugeStakeManager));
    ICLGaugeFactory.PenaltyConfig memory config = gaugeFactory.penaltyConfig();
    assertEq(config.minStakeBlocks, minStakeBlocks);
    assertEq(config.penaltyRate, penaltyRate);
    assertTrue(gaugeStakeManager != address(deployCL.deployerAddress()));

    assertTrue(address(unstakedFeeModule) != address(0));
    assertEq(unstakedFeeModule.MAX_FEE(), 500_000); // 50%, using pip denomination
    assertEq(address(unstakedFeeModule.factory()), address(poolFactory));

    // Check MixedRouteQuoterV2
    assertTrue(address(mixedQuoterV2) != address(0));
    assertEq(address(mixedQuoterV2.factory()), address(poolFactory));
    assertEq(address(mixedQuoterV2.factoryV2()), factoryV2);
    assertEq(mixedQuoterV2.WETH9(), weth);

    // Check Metaquoter
    assertTrue(address(metaquoter) != address(0));
    assertEq(address(metaquoter.factoryRegistry()), targetFactoryRegistry);
  }

  function concat(string memory a, string memory b) internal pure returns (string memory) {
    return string(abi.encodePacked(a, b));
  }

  function quote(string memory a) internal pure returns (string memory) {
    return string(abi.encodePacked('"', a, '"'));
  }
}
