import type { Contract } from 'ethers'
import type { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/types'
import type {
  CLFactory,
  MockTimeNonfungiblePositionManager,
  MockTimeSwapRouter,
  NonfungibleTokenPositionDescriptor,
  TestERC20,
} from '../../../types/ethers-contracts/index.js'
import type { EthersHelpers } from '../../shared/network'
import { v3RouterFixture } from './externalFixtures'

export default async function completeFixture(
  ethers: EthersHelpers,
  wallet: HardhatEthersSigner
): Promise<{
  weth9: Contract
  factory: CLFactory
  router: MockTimeSwapRouter
  nft: MockTimeNonfungiblePositionManager
  nftDescriptor: NonfungibleTokenPositionDescriptor
  tokens: [TestERC20, TestERC20, TestERC20]
}> {
  const { factory, weth9, router, nft, tokens, nftDescriptor } = await v3RouterFixture(ethers, wallet)

  return {
    weth9,
    factory,
    router,
    tokens,
    nft,
    nftDescriptor,
  }
}
