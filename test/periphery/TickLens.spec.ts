import { Contract, MaxUint256 } from 'ethers'
import { network } from 'hardhat'
import type { EthersHelpers, NetHelpers } from '../shared/network'
import type { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/types'
import completeFixture from './shared/completeFixture'
import { FeeAmount, TICK_SPACINGS } from './shared/constants'
import { encodePriceSqrt } from './shared/encodePriceSqrt'
import { expect } from './shared/expect'
import { getMaxTick, getMinTick } from './shared/ticks'
import { computePoolAddress } from './shared/computePoolAddress'
import snapshotGasCost from './shared/snapshotGasCost'

describe('TickLens', () => {
  let ethers: EthersHelpers
  let networkHelpers: NetHelpers
  let wallets: HardhatEthersSigner[]

  let factory: Contract
  let nft: Contract
  let tokens: [Contract, Contract, Contract]
  let poolAddress: string
  let tickLens: Contract

  before(async () => {
    const conn = await network.create()
    ethers = conn.ethers
    networkHelpers = conn.networkHelpers
    wallets = await ethers.getSigners()
  })

  const nftFixture = async () => {
    const [wallet] = await ethers.getSigners()
    const { factory, tokens, nft } = await completeFixture(ethers, wallet)

    for (const token of tokens) {
      await token.approve(await nft.getAddress(), MaxUint256)
    }

    return {
      factory,
      nft,
      tokens,
    }
  }

  beforeEach('load fixture', async () => {
    ;({ factory, tokens, nft } = await networkHelpers.loadFixture(nftFixture))
  })

  describe('#getPopulatedTicksInWord', () => {
    const fullRangeLiquidity = 1000000
    async function createPool(tokenAddressA: string, tokenAddressB: string) {
      if (tokenAddressA.toLowerCase() > tokenAddressB.toLowerCase())
        [tokenAddressA, tokenAddressB] = [tokenAddressB, tokenAddressA]

      await nft.createPoolFromFactory(
        tokenAddressA,
        tokenAddressB,
        TICK_SPACINGS[FeeAmount.MEDIUM],
        encodePriceSqrt(1, 1)
      )

      const liquidityParams = {
        token0: tokenAddressA,
        token1: tokenAddressB,
        tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
        tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        recipient: wallets[0].address,
        amount0Desired: 1000000,
        amount1Desired: 1000000,
        amount0Min: 0,
        amount1Min: 0,
        deadline: 1,
        sqrtPriceX96: 0,
      }

      return nft.mint(liquidityParams)
    }

    async function mint(tickLower: number, tickUpper: number, amountBothDesired: bigint | number): Promise<number> {
      const mintParams = {
        token0: await tokens[0].getAddress(),
        token1: await tokens[1].getAddress(),
        tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
        tickLower,
        tickUpper,
        amount0Desired: amountBothDesired,
        amount1Desired: amountBothDesired,
        amount0Min: 0,
        amount1Min: 0,
        recipient: wallets[0].address,
        deadline: 1,
        sqrtPriceX96: 0,
      }

      const { liquidity } = await nft.mint.staticCall(mintParams)

      await nft.mint(mintParams)
      return Number(liquidity)
    }

    beforeEach(async () => {
      await createPool(await tokens[0].getAddress(), await tokens[1].getAddress())
      poolAddress = await computePoolAddress(
        await factory.getAddress(),
        [await tokens[0].getAddress(), await tokens[1].getAddress()],
        TICK_SPACINGS[FeeAmount.MEDIUM],
        factory
      )
    })

    beforeEach(async () => {
      const lensFactory = await ethers.getContractFactory('TickLensTest')
      tickLens = (await lensFactory.deploy()) as unknown as Contract
    })

    function getTickBitmapIndex(tick: bigint | number, tickSpacing: number): bigint {
      const tickBig = BigInt(tick)
      const tickSpacingBig = BigInt(tickSpacing)
      const intermediate = tickBig / tickSpacingBig
      // see https://docs.soliditylang.org/en/v0.7.6/types.html#shifts
      return intermediate < 0n ? (intermediate + 1n) / 2n ** 8n - 1n : intermediate >> 8n
    }

    async function estimateGasCostsFetchingByTick(wordCount: number) {
      // populate `wordCount` words
      for (let i = 0; i < 128 * wordCount; i++) {
        await mint(
          i * TICK_SPACINGS[FeeAmount.MEDIUM],
          (256 * wordCount - 1 - i) * TICK_SPACINGS[FeeAmount.MEDIUM],
          100
        )
      }

      // fetch all populated ticks
      const ticks = await tickLens.getPopulatedTicks(poolAddress, 0, wordCount)
      // verify that all words were fully populated
      expect(ticks.length).to.be.eq(256 * wordCount)

      await snapshotGasCost(tickLens.getGasCostOfGetPopulatedTicks(poolAddress, 0, wordCount))
    }

    it('works for min/max', async () => {
      const [min] = await tickLens.getPopulatedTicksInWord(
        poolAddress,
        getTickBitmapIndex(getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]), TICK_SPACINGS[FeeAmount.MEDIUM])
      )

      const [max] = await tickLens.getPopulatedTicksInWord(
        poolAddress,
        getTickBitmapIndex(getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]), TICK_SPACINGS[FeeAmount.MEDIUM])
      )

      expect(min.tick).to.be.eq(getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]))
      expect(min.liquidityNet).to.be.eq(fullRangeLiquidity)
      expect(min.liquidityGross).to.be.eq(fullRangeLiquidity)

      expect(max.tick).to.be.eq(getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]))
      expect(max.liquidityNet).to.be.eq(fullRangeLiquidity * -1)
      expect(min.liquidityGross).to.be.eq(fullRangeLiquidity)
    })

    it('works for min/max and -2/-1/0/1', async () => {
      const minus = -TICK_SPACINGS[FeeAmount.MEDIUM]
      const plus = -minus

      const liquidity0 = await mint(minus * 2, minus, 2)
      const liquidity1 = await mint(minus * 2, 0, 3)
      const liquidity2 = await mint(minus * 2, plus, 5)
      const liquidity3 = await mint(minus, 0, 7)
      const liquidity4 = await mint(minus, plus, 11)
      const liquidity5 = await mint(0, plus, 13)

      const [min] = await tickLens.getPopulatedTicksInWord(
        poolAddress,
        getTickBitmapIndex(getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]), TICK_SPACINGS[FeeAmount.MEDIUM])
      )

      const [negativeOne, negativeTwo] = await tickLens.getPopulatedTicksInWord(
        poolAddress,
        getTickBitmapIndex(minus, TICK_SPACINGS[FeeAmount.MEDIUM])
      )

      const [one, zero] = await tickLens.getPopulatedTicksInWord(
        poolAddress,
        getTickBitmapIndex(plus, TICK_SPACINGS[FeeAmount.MEDIUM])
      )

      const [max] = await tickLens.getPopulatedTicksInWord(
        poolAddress,
        getTickBitmapIndex(getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]), TICK_SPACINGS[FeeAmount.MEDIUM])
      )

      expect(min.tick).to.be.eq(getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]))
      expect(min.liquidityNet).to.be.eq(fullRangeLiquidity)
      expect(min.liquidityGross).to.be.eq(fullRangeLiquidity)

      expect(negativeTwo.tick).to.be.eq(minus * 2)
      expect(negativeTwo.liquidityNet).to.be.eq(liquidity0 + liquidity1 + liquidity2)
      expect(negativeTwo.liquidityGross).to.be.eq(liquidity0 + liquidity1 + liquidity2)

      expect(negativeOne.tick).to.be.eq(minus)
      expect(negativeOne.liquidityNet).to.be.eq(liquidity3 + liquidity4 - liquidity0)
      expect(negativeOne.liquidityGross).to.be.eq(liquidity3 + liquidity4 + liquidity0)

      expect(zero.tick).to.be.eq(0)
      expect(zero.liquidityNet).to.be.eq(liquidity5 - liquidity1 - liquidity3)
      expect(zero.liquidityGross).to.be.eq(liquidity5 + liquidity1 + liquidity3)

      expect(one.tick).to.be.eq(plus)
      expect(one.liquidityNet).to.be.eq(-liquidity2 - liquidity4 - liquidity5)
      expect(one.liquidityGross).to.be.eq(liquidity2 + liquidity4 + liquidity5)

      expect(max.tick).to.be.eq(getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]))
      expect(max.liquidityNet).to.be.eq(fullRangeLiquidity * -1)
      expect(max.liquidityGross).to.be.eq(fullRangeLiquidity)
    })

    it('gas for single populated tick', async () => {
      await snapshotGasCost(
        tickLens.getGasCostOfGetPopulatedTicksInWord(
          poolAddress,
          getTickBitmapIndex(getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]), TICK_SPACINGS[FeeAmount.MEDIUM])
        )
      )
    })

    it('fully populated ticks', async () => {
      // fully populate a word
      for (let i = 0; i < 128; i++) {
        await mint(i * TICK_SPACINGS[FeeAmount.MEDIUM], (255 - i) * TICK_SPACINGS[FeeAmount.MEDIUM], 100)
      }

      const ticks = await tickLens.getPopulatedTicksInWord(
        poolAddress,
        getTickBitmapIndex(0, TICK_SPACINGS[FeeAmount.MEDIUM])
      )
      expect(ticks.length).to.be.eq(256)

      await snapshotGasCost(
        tickLens.getGasCostOfGetPopulatedTicksInWord(
          poolAddress,
          getTickBitmapIndex(0, TICK_SPACINGS[FeeAmount.MEDIUM])
        )
      )
    }).timeout(300_000)
    it.skip('gas costs by tick 2 fully populated words', async () => {
      await estimateGasCostsFetchingByTick(2)
    }).timeout(300_000)
    it.skip('gas costs by tick 3 fully populated words', async () => {
      await estimateGasCostsFetchingByTick(3)
    }).timeout(300_000)
    it.skip('gas costs by tick 4 fully populated words', async () => {
      await estimateGasCostsFetchingByTick(4)
    }).timeout(300_000)
    it.skip('gas costs by tick 5 fully populated words', async () => {
      await estimateGasCostsFetchingByTick(5)
    }).timeout(300_000)
    it.skip('gas costs by tick 6 fully populated words', async () => {
      await estimateGasCostsFetchingByTick(6)
    }).timeout(300_000)
  })
})
