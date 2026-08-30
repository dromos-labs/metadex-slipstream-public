import { Contract, MaxUint256, ZeroAddress } from 'ethers'
import { network } from 'hardhat'
import type { EthersHelpers, NetHelpers } from '../shared/network'
import { expect } from './shared/expect'
import { wethFixture } from './shared/externalFixtures'

import WETH9 from './contracts/WETH9.json'

describe('PeripheryImmutableState', () => {
  let ethers: EthersHelpers
  let networkHelpers: NetHelpers

  let factory: Contract
  let weth9: Contract
  let state: Contract

  before(async () => {
    const conn = await network.create()
    ethers = conn.ethers
    networkHelpers = conn.networkHelpers
  })

  const peripheryStateFixture = async () => {
    const [wallet] = await ethers.getSigners()

    // Deploy WETH9 directly without NFT manager
    const weth9Factory = new ethers.ContractFactory(WETH9.abi, WETH9.bytecode, wallet)
    const weth9 = (await weth9Factory.deploy()) as unknown as Contract

    // Deploy factory (minimal - no NFT manager needed)
    const Pool = await ethers.getContractFactory('CLPool')
    const Factory = await ethers.getContractFactory('CLFactory')
    const CustomUnstakedFeeModuleFactory = await ethers.getContractFactory('CustomUnstakedFeeModule')
    const MockVoterFactory = await ethers.getContractFactory('MockVoter')
    const MockFactoryRegistryFactory = await ethers.getContractFactory('MockFactoryRegistry')
    const MockVotingEscrowFactory = await ethers.getContractFactory('MockVotingEscrow')
    const tokenFactory = await ethers.getContractFactory('TestERC20')

    const pool = (await Pool.deploy()) as unknown as Contract
    const rewardToken = (await tokenFactory.deploy(MaxUint256 / 2n)) as unknown as Contract
    const mockVotingEscrow = await MockVotingEscrowFactory.deploy(wallet.address)
    const mockFactoryRegistry = (await MockFactoryRegistryFactory.deploy()) as unknown as Contract
    const mockVoter = (await MockVoterFactory.deploy(
      await rewardToken.getAddress(),
      await mockFactoryRegistry.getAddress(),
      await mockVotingEscrow.getAddress()
    )) as unknown as Contract

    const factory = (await Factory.deploy(
      wallet.address,
      wallet.address,
      wallet.address,
      await mockVoter.getAddress(),
      await pool.getAddress(),
      await mockFactoryRegistry.getAddress(),
      ZeroAddress, // defaultSwapHook
      wallet.address,
      wallet.address // clPoolTapeManager
    )) as unknown as Contract
    const customUnstakedFeeModule = (await CustomUnstakedFeeModuleFactory.deploy(
      await factory.getAddress()
    )) as unknown as Contract
    await factory.setUnstakedFeeModule(await customUnstakedFeeModule.getAddress())

    const stateFactory = await ethers.getContractFactory('PeripheryImmutableStateTest')
    const state = (await stateFactory.deploy(
      await factory.getAddress(),
      await weth9.getAddress()
    )) as unknown as Contract

    return {
      weth9,
      factory,
      state,
    }
  }

  beforeEach('load fixture', async () => {
    ;({ state, weth9, factory } = await networkHelpers.loadFixture(peripheryStateFixture))
  })

  describe('#WETH9', () => {
    it('points to WETH9', async () => {
      expect(await state.WETH9()).to.eq(await weth9.getAddress())
    })
  })

  describe('#factory', () => {
    it('points to v3 core factory', async () => {
      expect(await state.factory()).to.eq(await factory.getAddress())
    })
  })
})
