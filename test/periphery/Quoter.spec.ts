import { Contract, MaxUint256 } from 'ethers'
import { network } from 'hardhat'
import type { EthersHelpers, NetHelpers } from '../shared/network'
import type { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/types'
import completeFixture from './shared/completeFixture'
import { FeeAmount, MaxUint128, TICK_SPACINGS } from './shared/constants'
import { encodePriceSqrt } from './shared/encodePriceSqrt'
import { expandTo18Decimals } from './shared/expandTo18Decimals'
import { expect } from './shared/expect'
import { encodePath } from './shared/path'
import { createPool } from './shared/quoter'

describe('Quoter', () => {
  let ethers: EthersHelpers
  let networkHelpers: NetHelpers

  let wallet: HardhatEthersSigner
  let trader: HardhatEthersSigner

  let nft: Contract
  let tokens: [Contract, Contract, Contract]
  let quoter: Contract

  before(async () => {
    const conn = await network.create()
    ethers = conn.ethers
    networkHelpers = conn.networkHelpers
    ;[wallet, trader] = await ethers.getSigners()
  })

  const swapRouterFixture = async () => {
    const { weth9, factory, router, tokens, nft } = await completeFixture(ethers, wallet)

    // approve & fund wallets
    for (const token of tokens) {
      await token.approve(await router.getAddress(), MaxUint256)
      await token.approve(await nft.getAddress(), MaxUint256)
      await token.connect(trader).approve(await router.getAddress(), MaxUint256)
      await token.transfer(trader.address, expandTo18Decimals(1_000_000))
    }

    const quoterFactory = await ethers.getContractFactory('Quoter')
    const quoter = (await quoterFactory.deploy(
      await factory.getAddress(),
      await weth9.getAddress()
    )) as unknown as Contract

    return {
      tokens,
      nft,
      quoter,
    }
  }

  // helper for getting weth and token balances
  beforeEach('load fixture', async () => {
    ;({ tokens, nft, quoter } = await networkHelpers.loadFixture(swapRouterFixture))
  })

  describe('quotes', () => {
    beforeEach(async () => {
      await createPool(nft, wallet, await tokens[0].getAddress(), await tokens[1].getAddress())
      await createPool(nft, wallet, await tokens[1].getAddress(), await tokens[2].getAddress())
    })

    describe('#quoteExactInput', () => {
      it('0 -> 1', async () => {
        const quote = await quoter.quoteExactInput.staticCall(
          encodePath([await tokens[0].getAddress(), await tokens[1].getAddress()], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
          3
        )

        expect(quote).to.eq(1)
      })

      it('1 -> 0', async () => {
        const quote = await quoter.quoteExactInput.staticCall(
          encodePath([await tokens[1].getAddress(), await tokens[0].getAddress()], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
          3
        )

        expect(quote).to.eq(1)
      })

      it('0 -> 1 -> 2', async () => {
        const addrs = await Promise.all(tokens.map((t) => t.getAddress()))
        const quote = await quoter.quoteExactInput.staticCall(
          encodePath(addrs, [TICK_SPACINGS[FeeAmount.MEDIUM], TICK_SPACINGS[FeeAmount.MEDIUM]]),
          5
        )

        expect(quote).to.eq(1)
      })

      it('2 -> 1 -> 0', async () => {
        const addrs = await Promise.all(tokens.map((t) => t.getAddress()))
        const quote = await quoter.quoteExactInput.staticCall(
          encodePath(addrs.reverse(), [TICK_SPACINGS[FeeAmount.MEDIUM], TICK_SPACINGS[FeeAmount.MEDIUM]]),
          5
        )

        expect(quote).to.eq(1)
      })
    })

    describe('#quoteExactInputSingle', () => {
      it('0 -> 1', async () => {
        const quote = await quoter.quoteExactInputSingle.staticCall(
          await tokens[0].getAddress(),
          await tokens[1].getAddress(),
          TICK_SPACINGS[FeeAmount.MEDIUM],
          MaxUint128,
          // -2%
          encodePriceSqrt(100, 102)
        )

        expect(quote).to.eq(9852)
      })

      it('1 -> 0', async () => {
        const quote = await quoter.quoteExactInputSingle.staticCall(
          await tokens[1].getAddress(),
          await tokens[0].getAddress(),
          TICK_SPACINGS[FeeAmount.MEDIUM],
          MaxUint128,
          // +2%
          encodePriceSqrt(102, 100)
        )

        expect(quote).to.eq(9852)
      })
    })

    describe('#quoteExactOutput', () => {
      it('0 -> 1', async () => {
        const quote = await quoter.quoteExactOutput.staticCall(
          encodePath([await tokens[1].getAddress(), await tokens[0].getAddress()], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
          1
        )

        expect(quote).to.eq(3)
      })

      it('1 -> 0', async () => {
        const quote = await quoter.quoteExactOutput.staticCall(
          encodePath([await tokens[0].getAddress(), await tokens[1].getAddress()], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
          1
        )

        expect(quote).to.eq(3)
      })

      it('0 -> 1 -> 2', async () => {
        const addrs = await Promise.all(tokens.map((t) => t.getAddress()))
        const quote = await quoter.quoteExactOutput.staticCall(
          encodePath(addrs.reverse(), [TICK_SPACINGS[FeeAmount.MEDIUM], TICK_SPACINGS[FeeAmount.MEDIUM]]),
          1
        )

        expect(quote).to.eq(5)
      })

      it('2 -> 1 -> 0', async () => {
        const addrs = await Promise.all(tokens.map((t) => t.getAddress()))
        const quote = await quoter.quoteExactOutput.staticCall(
          encodePath(addrs, [TICK_SPACINGS[FeeAmount.MEDIUM], TICK_SPACINGS[FeeAmount.MEDIUM]]),
          1
        )

        expect(quote).to.eq(5)
      })
    })

    describe('#quoteExactOutputSingle', () => {
      it('0 -> 1', async () => {
        const quote = await quoter.quoteExactOutputSingle.staticCall(
          await tokens[0].getAddress(),
          await tokens[1].getAddress(),
          TICK_SPACINGS[FeeAmount.MEDIUM],
          MaxUint128,
          encodePriceSqrt(100, 102)
        )

        expect(quote).to.eq(9981)
      })

      it('1 -> 0', async () => {
        const quote = await quoter.quoteExactOutputSingle.staticCall(
          await tokens[1].getAddress(),
          await tokens[0].getAddress(),
          TICK_SPACINGS[FeeAmount.MEDIUM],
          MaxUint128,
          encodePriceSqrt(102, 100)
        )

        expect(quote).to.eq(9981)
      })
    })
  })
})
