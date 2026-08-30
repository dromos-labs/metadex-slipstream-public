import { MaxUint256, ZeroAddress } from 'ethers'
import type { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/types'

import type {
  CLFactory,
  CLGauge,
  CLGaugeFactory,
  CustomUnstakedFeeModule,
  MockFactoryRegistry,
  MockTimeNonfungiblePositionManager,
  MockTimeSwapRouter,
  MockVoter,
  MockVotingEscrow,
  MockVotingRewardsFactory,
  NFTDescriptor,
  NFTSVG,
  NonfungibleTokenPositionDescriptor,
  TestERC20,
} from '../../../types/ethers-contracts/index.js'
import type { EthersHelpers } from '../../shared/network'
import type { Contract } from 'ethers'

import WETH9 from '../contracts/WETH9.json'

export async function wethFixture(ethers: EthersHelpers, wallet: HardhatEthersSigner): Promise<{ weth9: Contract }> {
  const weth9Factory = new ethers.ContractFactory(WETH9.abi, WETH9.bytecode, wallet)
  const weth9 = (await weth9Factory.deploy()) as unknown as Contract
  return { weth9 }
}

export async function v3CoreFactoryFixture(
  ethers: EthersHelpers,
  wallet: HardhatEthersSigner
): Promise<{
  factory: CLFactory
  nft: MockTimeNonfungiblePositionManager
  weth9: Contract
  tokens: [TestERC20, TestERC20, TestERC20]
  nftDescriptor: NonfungibleTokenPositionDescriptor
}> {
  const { weth9 } = await wethFixture(ethers, wallet)
  const tokenFactory = await ethers.getContractFactory('TestERC20')
  const rewardToken = (await tokenFactory.deploy(MaxUint256 / 2n)) as unknown as TestERC20 // do not use maxu256 to avoid overflowing

  const tokens: [TestERC20, TestERC20, TestERC20] = [
    (await tokenFactory.deploy(MaxUint256 / 2n)) as unknown as TestERC20, // do not use maxu256 to avoid overflowing
    (await tokenFactory.deploy(MaxUint256 / 2n)) as unknown as TestERC20,
    (await tokenFactory.deploy(MaxUint256 / 2n)) as unknown as TestERC20,
  ]

  const addrs = await Promise.all(tokens.map((t) => t.getAddress()))
  const sorted = tokens
    .map((t, i) => ({ t, addr: addrs[i] }))
    .sort((a, b) => (a.addr.toLowerCase() < b.addr.toLowerCase() ? -1 : 1))
  tokens[0] = sorted[0].t
  tokens[1] = sorted[1].t
  tokens[2] = sorted[2].t

  const Pool = await ethers.getContractFactory('CLPool')
  const Factory = await ethers.getContractFactory('CLFactory')
  const CustomUnstakedFeeModuleFactory = await ethers.getContractFactory('CustomUnstakedFeeModule')
  const pool = await Pool.deploy()

  const MockVoterFactory = await ethers.getContractFactory('MockVoter')
  const GaugeFactoryFactory = await ethers.getContractFactory('CLGaugeFactory')
  const MockFactoryRegistryFactory = await ethers.getContractFactory('MockFactoryRegistry')
  const MockVotingRewardsFactoryFactory = await ethers.getContractFactory('MockVotingRewardsFactory')
  const MockVotingEscrowFactory = await ethers.getContractFactory('MockVotingEscrow')

  const positionManagerFactory = await ethers.getContractFactory('MockTimeNonfungiblePositionManager')

  // voter & gauge factory set up
  const mockVotingEscrow = (await MockVotingEscrowFactory.deploy(wallet.address)) as unknown as MockVotingEscrow
  const mockFactoryRegistry = (await MockFactoryRegistryFactory.deploy()) as unknown as MockFactoryRegistry
  const mockVoter = (await MockVoterFactory.deploy(
    await rewardToken.getAddress(),
    await mockFactoryRegistry.getAddress(),
    await mockVotingEscrow.getAddress()
  )) as unknown as MockVoter

  const factory = (await Factory.deploy(
    wallet.address,
    wallet.address,
    wallet.address,
    await mockVoter.getAddress(),
    await pool.getAddress(),
    await mockFactoryRegistry.getAddress(),
    ZeroAddress, // defaultSwapHook
    wallet.address, // discountRegistryManager
    wallet.address // clPoolTapeManager
  )) as unknown as CLFactory
  const customUnstakedFeeModule = (await CustomUnstakedFeeModuleFactory.deploy(
    await factory.getAddress()
  )) as unknown as CustomUnstakedFeeModule
  await factory.setUnstakedFeeModule(await customUnstakedFeeModule.getAddress())

  const nftDescriptorLibraryFactory = await ethers.getContractFactory('NFTDescriptor')
  const nftDescriptorLibrary = (await nftDescriptorLibraryFactory.deploy()) as unknown as NFTDescriptor
  const nftSVGLibraryFactory = await ethers.getContractFactory('NFTSVG')
  const nftSVGLibrary = (await nftSVGLibraryFactory.deploy()) as unknown as NFTSVG
  const positionDescriptorFactory = await ethers.getContractFactory('NonfungibleTokenPositionDescriptor', {
    libraries: {
      NFTDescriptor: await nftDescriptorLibrary.getAddress(),
      NFTSVG: await nftSVGLibrary.getAddress(),
    },
  })
  const nftDescriptor = (await positionDescriptorFactory.deploy(
    await tokens[0].getAddress(),
    // 'ETH' as a bytes32 string
    '0x4554480000000000000000000000000000000000000000000000000000000000'
  )) as unknown as NonfungibleTokenPositionDescriptor

  const nft = (await positionManagerFactory.deploy(
    wallet.address,
    await factory.getAddress(),
    await weth9.getAddress(),
    await nftDescriptor.getAddress()
  )) as unknown as MockTimeNonfungiblePositionManager

  const mockVotingRewardsFactory =
    (await MockVotingRewardsFactoryFactory.deploy()) as unknown as MockVotingRewardsFactory
  const gaugeFactory = (await GaugeFactoryFactory.deploy(
    await mockVoter.getAddress(),
    await mockVoter.getAddress(), // gauge manager, played by the mock voter in tests
    await mockVotingRewardsFactory.getAddress(),
    await nft.getAddress(),
    {
      capAdmin: wallet.address,
      referralAdmin: wallet.address,
      penaltyAdmin: wallet.address,
      capOperator: wallet.address,
    },
    {
      defaultCap: 10n ** 18n,
      operatorMinCap: 1,
      operatorMaxCap: 10n ** 18n,
      maxMinStakeBlocks: 7 * 24 * 60 * 60,
    }
  )) as unknown as CLGaugeFactory
  await gaugeFactory.setPenaltyConfig(0, 0)

  // link pool factory <=> gauge factory combination
  await mockFactoryRegistry.registerFactories(await gaugeFactory.getAddress(), await factory.getAddress())

  // backwards compatible with v3-periphery tests
  await factory['enableTickSpacing(int24,uint24)'](10, 500)
  await factory['enableTickSpacing(int24,uint24)'](60, 3_000)
  return { factory, nft, weth9, tokens, nftDescriptor }
}

export async function v3RouterFixture(
  ethers: EthersHelpers,
  wallet: HardhatEthersSigner
): Promise<{
  weth9: Contract
  factory: CLFactory
  router: MockTimeSwapRouter
  nft: MockTimeNonfungiblePositionManager
  tokens: [TestERC20, TestERC20, TestERC20]
  nftDescriptor: NonfungibleTokenPositionDescriptor
}> {
  const { factory, nft, weth9, tokens, nftDescriptor } = await v3CoreFactoryFixture(ethers, wallet)

  const router = (await (
    await ethers.getContractFactory('MockTimeSwapRouter')
  ).deploy(await factory.getAddress(), await weth9.getAddress())) as unknown as MockTimeSwapRouter

  return { factory, weth9, router, nft, tokens, nftDescriptor }
}
