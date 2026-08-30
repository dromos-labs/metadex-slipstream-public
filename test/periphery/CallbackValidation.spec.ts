import { Contract, MaxUint256, ZeroAddress } from 'ethers'
import { network } from 'hardhat'
import type { EthersHelpers, NetHelpers } from '../shared/network'
import type { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/types'
import { expect } from './shared/expect'
import { FeeAmount } from './shared/constants'

describe('CallbackValidation', () => {
  let ethers: EthersHelpers
  let networkHelpers: NetHelpers

  let nonpairAddr: HardhatEthersSigner

  let callbackValidation: Contract
  let tokens: [Contract, Contract]
  let factory: Contract

  before(async () => {
    const conn = await network.create()
    ethers = conn.ethers
    networkHelpers = conn.networkHelpers
    ;[nonpairAddr] = await ethers.getSigners()
  })

  const callbackValidationFixture = async () => {
    const [wallet] = await ethers.getSigners()

    // Deploy factory without NFT manager (avoid code-too-large)
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

    const tokens: [Contract, Contract] = [
      (await tokenFactory.deploy(MaxUint256 / 2n)) as unknown as Contract,
      (await tokenFactory.deploy(MaxUint256 / 2n)) as unknown as Contract,
    ]
    const callbackValidationFactory = await ethers.getContractFactory('TestCallbackValidation')
    const callbackValidation = (await callbackValidationFactory.deploy()) as unknown as Contract

    return {
      tokens,
      callbackValidation,
      factory,
    }
  }

  beforeEach('load fixture', async () => {
    ;({ callbackValidation, tokens, factory } = await networkHelpers.loadFixture(callbackValidationFixture))
  })

  it('reverts when called from an address other than the associated CLPool', async () => {
    await expect(
      callbackValidation
        .connect(nonpairAddr)
        .verifyCallback(
          await factory.getAddress(),
          await tokens[0].getAddress(),
          await tokens[1].getAddress(),
          FeeAmount.MEDIUM
        )
    ).to.be.revert(ethers)
  })
})
