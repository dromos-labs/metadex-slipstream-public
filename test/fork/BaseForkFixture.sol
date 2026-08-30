pragma solidity ^0.7.6;
pragma abicoder v2;

import '../BaseFixture.sol';
import 'forge-std/StdJson.sol';

abstract contract BaseForkFixture is BaseFixture {
  using stdJson for string;

  string public addresses;
  IERC20 public op;
  uint256 public blockNumber = 109_241_151;

  function setUp() public virtual override {
    vm.createSelectFork({urlOrAlias: 'optimism', blockNumber: blockNumber});

    string memory root = vm.projectRoot();
    string memory path = string(abi.encodePacked(root, '/test/fork/addresses.json'));
    addresses = vm.readFile(path);

    // set up contracts after fork
    BaseFixture.setUp();

    nftCallee = new NFTManagerCallee(address(weth), address(op), address(nft));

    deal({token: address(op), to: users.alice, give: TOKEN_1 * 100});
    deal({token: address(weth), to: users.alice, give: TOKEN_1 * 100});

    vm.startPrank(users.alice);
    op.approve(address(nftCallee), type(uint256).max);
    weth.approve(address(nftCallee), type(uint256).max);
    vm.stopPrank();
  }

  function deployDependencies() public virtual override {
    factoryRegistry = IFactoryRegistry(vm.parseJsonAddress(addresses, '.FactoryRegistry'));
    // The live Velodrome registry predates the metadex API the factory and pool invoke
    // (BaseFixture passes the registry to the factory constructor). Mock those reads and
    // writes until the metadex FactoryRegistry is deployed on Optimism and addresses.json
    // is updated.
    vm.mockCall(address(factoryRegistry), abi.encodeWithSelector(IFactoryRegistry.registerTarget.selector), '');
    vm.mockCall(address(factoryRegistry), abi.encodeWithSelector(IFactoryRegistry.registerFactories.selector), '');
    vm.mockCall(
      address(factoryRegistry), abi.encodeWithSelector(IFactoryRegistry.targetToGauge.selector), abi.encode(address(0))
    );
    weth = IERC20(vm.parseJsonAddress(addresses, '.WETH'));
    op = IERC20(vm.parseJsonAddress(addresses, '.OP'));
    voter = IVoter(vm.parseJsonAddress(addresses, '.Voter'));
    rewardToken = ERC20(vm.parseJsonAddress(addresses, '.Velo'));
    votingRewardsFactory = IVotingRewardsFactory(vm.parseJsonAddress(addresses, '.VotingRewardsFactory'));
    escrow = IVotingEscrow(vm.parseJsonAddress(addresses, '.VotingEscrow'));
    minter = IMinter(vm.parseJsonAddress(addresses, '.Minter'));
  }
}
