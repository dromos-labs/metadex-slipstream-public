import type { BigNumberish } from 'ethers'
import { ZeroAddress } from 'ethers'
import type { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/types'
import type {
  CLFactory,
  CLGauge,
  CLGaugeFactory,
  CoreTestERC20,
  CustomUnstakedFeeModule,
  MockFactoryRegistry,
  MockTimeCLPool,
  MockVoter,
  MockVotingEscrow,
  MockVotingRewardsFactory,
  TestCLCallee,
  TestCLRouter,
} from '../../../types/ethers-contracts/index.js'
import type { EthersHelpers } from '../../shared/network'
import { encodePriceSqrt } from './utilities'

interface FactoryFixture {
  factory: CLFactory
  mockFactoryRegistry: MockFactoryRegistry
}
interface TokensFixture {
  token0: CoreTestERC20
  token1: CoreTestERC20
  token2: CoreTestERC20
}

async function tokensFixture(ethers: EthersHelpers): Promise<TokensFixture> {
  const tokenFactory = await ethers.getContractFactory('CoreTestERC20')
  const tokenA = (await tokenFactory.deploy(2n ** 255n)) as unknown as CoreTestERC20
  const tokenB = (await tokenFactory.deploy(2n ** 255n)) as unknown as CoreTestERC20
  const tokenC = (await tokenFactory.deploy(2n ** 255n)) as unknown as CoreTestERC20

  const addrs = await Promise.all([tokenA.getAddress(), tokenB.getAddress(), tokenC.getAddress()])
  const sorted = [
    { contract: tokenA, address: addrs[0] },
    { contract: tokenB, address: addrs[1] },
    { contract: tokenC, address: addrs[2] },
  ].sort((a, b) => (a.address.toLowerCase() < b.address.toLowerCase() ? -1 : 1))

  return {
    token0: sorted[0].contract,
    token1: sorted[1].contract,
    token2: sorted[2].contract,
  }
}

type TokensAndFactoryFixture = FactoryFixture & TokensFixture

export interface PoolFixture extends TokensAndFactoryFixture {
  swapTargetCallee: TestCLCallee
  swapTargetRouter: TestCLRouter
  createPool(
    fee: number,
    tickSpacing: number,
    firstToken?: CoreTestERC20,
    secondToken?: CoreTestERC20,
    sqrtPriceX96?: BigNumberish
  ): Promise<MockTimeCLPool>
}
// Monday, October 5, 2020 9:00:00 AM GMT-05:00
export const TEST_POOL_START_TIME = 1601906400

export async function poolFixture(ethers: EthersHelpers, wallet: HardhatEthersSigner): Promise<PoolFixture> {
  const { token0, token1, token2 } = await tokensFixture(ethers)

  const MockTimeCLPoolDeployerFactory = await ethers.getContractFactory('CLFactory')
  const MockTimeCLPoolFactory = await ethers.getContractFactory('MockTimeCLPool')
  const MockVoterFactory = await ethers.getContractFactory('MockVoter')
  const GaugeImplementationFactory = await ethers.getContractFactory('CLGauge')
  const GaugeFactoryFactory = await ethers.getContractFactory('CLGaugeFactory')
  const MockFactoryRegistryFactory = await ethers.getContractFactory('MockFactoryRegistry')
  const MockVotingRewardsFactoryFactory = await ethers.getContractFactory('MockVotingRewardsFactory')
  const MockVotingEscrowFactory = await ethers.getContractFactory('MockVotingEscrow')
  const CustomUnstakedFeeModuleFactory = await ethers.getContractFactory('CustomUnstakedFeeModule')

  // voter & gauge factory set up
  const mockVotingEscrow = (await MockVotingEscrowFactory.deploy(wallet.address)) as unknown as MockVotingEscrow
  const mockFactoryRegistry = (await MockFactoryRegistryFactory.deploy()) as unknown as MockFactoryRegistry
  const mockVoter = (await MockVoterFactory.deploy(
    await token2.getAddress(),
    await mockFactoryRegistry.getAddress(),
    await mockVotingEscrow.getAddress()
  )) as unknown as MockVoter
  const mockVotingRewardsFactory =
    (await MockVotingRewardsFactoryFactory.deploy()) as unknown as MockVotingRewardsFactory
  const gaugeFactory = (await GaugeFactoryFactory.deploy(
    await mockVoter.getAddress(),
    await mockVoter.getAddress(), // gauge manager, played by the mock voter in tests
    await mockVotingRewardsFactory.getAddress(),
    '0x0000000000000000000000000000000000000001',
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
  const gaugeImplementation = GaugeImplementationFactory.attach(
    await gaugeFactory.implementation()
  ) as unknown as CLGauge
  await gaugeFactory.setPenaltyConfig(0, 0)

  const mockTimePool = (await MockTimeCLPoolFactory.deploy()) as unknown as MockTimeCLPool
  const mockTimePoolDeployer = (await MockTimeCLPoolDeployerFactory.deploy(
    wallet.address,
    wallet.address,
    wallet.address,
    await mockVoter.getAddress(),
    await mockTimePool.getAddress(),
    await mockFactoryRegistry.getAddress(),
    ZeroAddress, // defaultSwapHook
    wallet.address,
    wallet.address // clPoolTapeManager
  )) as unknown as CLFactory
  const customUnstakedFeeModule = (await CustomUnstakedFeeModuleFactory.deploy(
    await mockTimePoolDeployer.getAddress()
  )) as unknown as CustomUnstakedFeeModule
  await mockTimePoolDeployer.setUnstakedFeeModule(await customUnstakedFeeModule.getAddress())
  // link pool factory <=> gauge factory combination
  await mockFactoryRegistry.registerFactories(await gaugeFactory.getAddress(), await mockTimePoolDeployer.getAddress())

  const calleeContractFactory = await ethers.getContractFactory('TestCLCallee')
  const routerContractFactory = await ethers.getContractFactory('TestCLRouter')

  const swapTargetCallee = (await calleeContractFactory.deploy()) as unknown as TestCLCallee
  const swapTargetRouter = (await routerContractFactory.deploy()) as unknown as TestCLRouter

  return {
    token0,
    token1,
    token2,
    factory: mockTimePoolDeployer,
    swapTargetCallee,
    swapTargetRouter,
    mockFactoryRegistry,
    createPool: async (
      fee,
      tickSpacing,
      firstToken = token0,
      secondToken = token1,
      sqrtPriceX96 = encodePriceSqrt(1, 1)
    ) => {
      // add tick spacing if not already added, backwards compatible with CL tests
      const tickSpacingFee = await mockTimePoolDeployer.tickSpacingToFee(tickSpacing)
      if (tickSpacingFee === 0n) await mockTimePoolDeployer['enableTickSpacing(int24,uint24)'](tickSpacing, fee)
      const tx = await mockTimePoolDeployer['createPool(address,address,int24,uint160)'](
        await firstToken.getAddress(),
        await secondToken.getAddress(),
        tickSpacing,
        sqrtPriceX96
      )
      const receipt = await tx.wait()
      if (!receipt) throw new Error('createPool: no receipt')
      const poolCreatedTopic = mockTimePoolDeployer.interface.getEvent('PoolCreated').topicHash
      const poolCreatedLog = receipt.logs.find((log) => log.topics[0] === poolCreatedTopic)
      if (!poolCreatedLog) throw new Error('PoolCreated event not found in createPool receipt')
      const poolAddress = mockTimePoolDeployer.interface.parseLog(poolCreatedLog)!.args.pool as string
      const pool = MockTimeCLPoolFactory.attach(poolAddress) as unknown as MockTimeCLPool
      await pool.advanceTime(TEST_POOL_START_TIME)
      await customUnstakedFeeModule.setCustomFee(poolAddress, 420)
      return pool
    },
  }
}
