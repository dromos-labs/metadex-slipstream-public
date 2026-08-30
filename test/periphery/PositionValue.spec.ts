import { Contract, MaxUint256 } from 'ethers'
import { network } from 'hardhat'
import type { EthersHelpers, NetHelpers } from '../shared/network'
import type { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/types'
import { FeeAmount, MaxUint128, TICK_SPACINGS } from './shared/constants'
import { getMaxTick, getMinTick } from './shared/ticks'
import { encodePriceSqrt } from './shared/encodePriceSqrt'
import { expandTo18Decimals } from './shared/expandTo18Decimals'
import { encodePath } from './shared/path'
import { computePoolAddress } from './shared/computePoolAddress'
import completeFixture from './shared/completeFixture'
import snapshotGasCost from './shared/snapshotGasCost'

import { expect } from './shared/expect'

describe('PositionValue', async () => {
  let ethers: EthersHelpers
  let networkHelpers: NetHelpers

  let wallet: HardhatEthersSigner

  let pool: Contract
  let tokens: [Contract, Contract, Contract]
  let positionValue: Contract
  let nft: Contract
  let router: Contract
  let factory: Contract

  let amountDesired: bigint

  before(async () => {
    const conn = await network.create()
    ethers = conn.ethers
    networkHelpers = conn.networkHelpers
    ;[wallet] = await ethers.getSigners()
  })

  const positionValueCompleteFixture = async () => {
    const { nft, router, tokens, factory } = await completeFixture(ethers, wallet)
    const positionValueFactory = await ethers.getContractFactory('PositionValueTest')
    const positionValue = (await positionValueFactory.deploy()) as unknown as Contract

    for (const token of tokens) {
      await token.approve(await nft.getAddress(), MaxUint256)
      await token.connect(wallet).approve(await nft.getAddress(), MaxUint256)
      await token.transfer(wallet.address, expandTo18Decimals(1_000_000))
    }

    return {
      positionValue,
      tokens,
      nft,
      router,
      factory,
    }
  }

  beforeEach(async () => {
    ;({ positionValue, tokens, nft, router, factory } = await networkHelpers.loadFixture(positionValueCompleteFixture))
    const token0Addr = await tokens[0].getAddress()
    const token1Addr = await tokens[1].getAddress()
    const factoryAddr = await factory.getAddress()

    await nft.createPoolFromFactory(token0Addr, token1Addr, TICK_SPACINGS[FeeAmount.MEDIUM], encodePriceSqrt(1, 1))

    const poolAddress = await computePoolAddress(
      factoryAddr,
      [token0Addr, token1Addr],
      TICK_SPACINGS[FeeAmount.MEDIUM],
      factory
    )
    pool = await ethers.getContractAt('contracts/core/interfaces/ICLPool.sol:ICLPool', poolAddress, wallet)
  })

  describe('#total', () => {
    let tokenId: number
    let sqrtRatioX96: bigint

    beforeEach(async () => {
      amountDesired = expandTo18Decimals(100_000)
      const token0Addr = await tokens[0].getAddress()
      const token1Addr = await tokens[1].getAddress()
      const nftAddr = await nft.getAddress()
      const routerAddr = await router.getAddress()

      await nft.mint({
        token0: token0Addr,
        token1: token1Addr,
        tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
        recipient: wallet.address,
        amount0Desired: amountDesired,
        amount1Desired: amountDesired,
        amount0Min: 0,
        amount1Min: 0,
        deadline: 10,
        sqrtPriceX96: 0,
      })

      const swapAmount = expandTo18Decimals(1_000)
      await tokens[0].approve(routerAddr, swapAmount)
      await tokens[1].approve(routerAddr, swapAmount)

      // accumulate token0 fees
      await router.exactInput({
        recipient: wallet.address,
        deadline: 1,
        path: encodePath([token0Addr, token1Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
        amountIn: swapAmount,
        amountOutMinimum: 0,
      })

      // accumulate token1 fees
      await router.exactInput({
        recipient: wallet.address,
        deadline: 1,
        path: encodePath([token1Addr, token0Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
        amountIn: swapAmount,
        amountOutMinimum: 0,
      })

      sqrtRatioX96 = (await pool.slot0()).sqrtPriceX96
    })

    it('returns the correct amount', async () => {
      const nftAddr = await nft.getAddress()
      const pvAddr = await positionValue.getAddress()
      const principal = await positionValue.principal(nftAddr, 1, sqrtRatioX96)
      const fees = await positionValue.fees(nftAddr, 1)
      const total = await positionValue.total(nftAddr, 1, sqrtRatioX96)

      expect(total[0]).to.equal(principal[0] + fees[0])
      expect(total[1]).to.equal(principal[1] + fees[1])
    })

    it('gas', async () => {
      await snapshotGasCost(positionValue.totalGas(await nft.getAddress(), 1, sqrtRatioX96))
    })
  })

  describe('#principal', () => {
    let sqrtRatioX96: bigint

    beforeEach(async () => {
      amountDesired = expandTo18Decimals(100_000)
      sqrtRatioX96 = (await pool.slot0()).sqrtPriceX96
    })

    it('returns the correct values when price is in the middle of the range', async () => {
      const token0Addr = await tokens[0].getAddress()
      const token1Addr = await tokens[1].getAddress()
      await nft.mint({
        token0: token0Addr,
        token1: token1Addr,
        tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
        recipient: wallet.address,
        amount0Desired: amountDesired,
        amount1Desired: amountDesired,
        amount0Min: 0,
        amount1Min: 0,
        deadline: 10,
        sqrtPriceX96: 0,
      })

      const principal = await positionValue.principal(await nft.getAddress(), 1, sqrtRatioX96)
      expect(principal.amount0).to.equal('99999999999999999999999')
      expect(principal.amount1).to.equal('99999999999999999999999')
    })

    it('returns the correct values when range is below current price', async () => {
      const token0Addr = await tokens[0].getAddress()
      const token1Addr = await tokens[1].getAddress()
      await nft.mint({
        token0: token0Addr,
        token1: token1Addr,
        tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickUpper: -60,
        tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
        recipient: wallet.address,
        amount0Desired: amountDesired,
        amount1Desired: amountDesired,
        amount0Min: 0,
        amount1Min: 0,
        deadline: 10,
        sqrtPriceX96: 0,
      })

      const principal = await positionValue.principal(await nft.getAddress(), 1, sqrtRatioX96)
      expect(principal.amount0).to.equal('0')
      expect(principal.amount1).to.equal('99999999999999999999999')
    })

    it('returns the correct values when range is below current price', async () => {
      const token0Addr = await tokens[0].getAddress()
      const token1Addr = await tokens[1].getAddress()
      await nft.mint({
        token0: token0Addr,
        token1: token1Addr,
        tickLower: 60,
        tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
        recipient: wallet.address,
        amount0Desired: amountDesired,
        amount1Desired: amountDesired,
        amount0Min: 0,
        amount1Min: 0,
        deadline: 10,
        sqrtPriceX96: 0,
      })

      const principal = await positionValue.principal(await nft.getAddress(), 1, sqrtRatioX96)
      expect(principal.amount0).to.equal('99999999999999999999999')
      expect(principal.amount1).to.equal('0')
    })

    it('returns the correct values when range is skewed above price', async () => {
      const token0Addr = await tokens[0].getAddress()
      const token1Addr = await tokens[1].getAddress()
      await nft.mint({
        token0: token0Addr,
        token1: token1Addr,
        tickLower: -6_000,
        tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
        recipient: wallet.address,
        amount0Desired: amountDesired,
        amount1Desired: amountDesired,
        amount0Min: 0,
        amount1Min: 0,
        deadline: 10,
        sqrtPriceX96: 0,
      })

      const principal = await positionValue.principal(await nft.getAddress(), 1, sqrtRatioX96)
      expect(principal.amount0).to.equal('99999999999999999999999')
      expect(principal.amount1).to.equal('25917066770240321655335')
    })

    it('returns the correct values when range is skewed below price', async () => {
      const token0Addr = await tokens[0].getAddress()
      const token1Addr = await tokens[1].getAddress()
      await nft.mint({
        token0: token0Addr,
        token1: token1Addr,
        tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickUpper: 6_000,
        tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
        recipient: wallet.address,
        amount0Desired: amountDesired,
        amount1Desired: amountDesired,
        amount0Min: 0,
        amount1Min: 0,
        deadline: 10,
        sqrtPriceX96: 0,
      })

      const principal = await positionValue.principal(await nft.getAddress(), 1, sqrtRatioX96)
      expect(principal.amount0).to.equal('25917066770240321655335')
      expect(principal.amount1).to.equal('99999999999999999999999')
    })

    it('gas', async () => {
      const token0Addr = await tokens[0].getAddress()
      const token1Addr = await tokens[1].getAddress()
      await nft.mint({
        token0: token0Addr,
        token1: token1Addr,
        tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
        recipient: wallet.address,
        amount0Desired: amountDesired,
        amount1Desired: amountDesired,
        amount0Min: 0,
        amount1Min: 0,
        deadline: 10,
        sqrtPriceX96: 0,
      })

      await snapshotGasCost(positionValue.principalGas(await nft.getAddress(), 1, sqrtRatioX96))
    })
  })

  describe('#fees', () => {
    let tokenId: number

    beforeEach(async () => {
      amountDesired = expandTo18Decimals(100_000)
      tokenId = 2
      const token0Addr = await tokens[0].getAddress()
      const token1Addr = await tokens[1].getAddress()

      await nft.mint({
        token0: token0Addr,
        token1: token1Addr,
        tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
        recipient: wallet.address,
        amount0Desired: amountDesired,
        amount1Desired: amountDesired,
        amount0Min: 0,
        amount1Min: 0,
        deadline: 10,
        sqrtPriceX96: 0,
      })
    })

    describe('when price is within the position range', () => {
      beforeEach(async () => {
        const token0Addr = await tokens[0].getAddress()
        const token1Addr = await tokens[1].getAddress()
        const routerAddr = await router.getAddress()

        await nft.mint({
          token0: token0Addr,
          token1: token1Addr,
          tickLower: TICK_SPACINGS[FeeAmount.MEDIUM] * -1_000,
          tickUpper: TICK_SPACINGS[FeeAmount.MEDIUM] * 1_000,
          tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
          recipient: wallet.address,
          amount0Desired: amountDesired,
          amount1Desired: amountDesired,
          amount0Min: 0,
          amount1Min: 0,
          deadline: 10,
          sqrtPriceX96: 0,
        })

        const swapAmount = expandTo18Decimals(1_000)
        await tokens[0].approve(routerAddr, swapAmount)
        await tokens[1].approve(routerAddr, swapAmount)

        // accumulate token0 fees
        await router.exactInput({
          recipient: wallet.address,
          deadline: 1,
          path: encodePath([token0Addr, token1Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
          amountIn: swapAmount,
          amountOutMinimum: 0,
        })

        // accumulate token1 fees
        await router.exactInput({
          recipient: wallet.address,
          deadline: 1,
          path: encodePath([token1Addr, token0Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
          amountIn: swapAmount,
          amountOutMinimum: 0,
        })
      })

      it('return the correct amount of fees', async () => {
        const feesFromCollect = await nft.collect.staticCall({
          tokenId,
          recipient: wallet.address,
          amount0Max: MaxUint128,
          amount1Max: MaxUint128,
        })
        const feeAmounts = await positionValue.fees(await nft.getAddress(), tokenId)

        expect(feeAmounts[0]).to.equal(feesFromCollect[0])
        expect(feeAmounts[1]).to.equal(feesFromCollect[1])
      })

      it('returns the correct amount of fees if tokensOwed fields are greater than 0', async () => {
        await nft.increaseLiquidity({
          tokenId: tokenId,
          amount0Desired: 100,
          amount1Desired: 100,
          amount0Min: 0,
          amount1Min: 0,
          deadline: 1,
        })

        const token0Addr = await tokens[0].getAddress()
        const token1Addr = await tokens[1].getAddress()
        const routerAddr = await router.getAddress()
        const swapAmount = expandTo18Decimals(1_000)
        await tokens[0].approve(routerAddr, swapAmount)

        // accumulate more token0 fees after clearing initial amount
        await router.exactInput({
          recipient: wallet.address,
          deadline: 1,
          path: encodePath([token0Addr, token1Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
          amountIn: swapAmount,
          amountOutMinimum: 0,
        })

        const feesFromCollect = await nft.collect.staticCall({
          tokenId,
          recipient: wallet.address,
          amount0Max: MaxUint128,
          amount1Max: MaxUint128,
        })
        const feeAmounts = await positionValue.fees(await nft.getAddress(), tokenId)
        expect(feeAmounts[0]).to.equal(feesFromCollect[0])
        expect(feeAmounts[1]).to.equal(feesFromCollect[1])
      })

      it('gas', async () => {
        await snapshotGasCost(positionValue.feesGas(await nft.getAddress(), tokenId))
      })
    })

    describe('when price is below the position range', async () => {
      beforeEach(async () => {
        const token0Addr = await tokens[0].getAddress()
        const token1Addr = await tokens[1].getAddress()
        const routerAddr = await router.getAddress()

        await nft.mint({
          token0: token0Addr,
          token1: token1Addr,
          tickLower: TICK_SPACINGS[FeeAmount.MEDIUM] * -10,
          tickUpper: TICK_SPACINGS[FeeAmount.MEDIUM] * 10,
          tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
          recipient: wallet.address,
          amount0Desired: expandTo18Decimals(10_000),
          amount1Desired: expandTo18Decimals(10_000),
          amount0Min: 0,
          amount1Min: 0,
          deadline: 10,
          sqrtPriceX96: 0,
        })

        await tokens[0].approve(routerAddr, MaxUint256)
        await tokens[1].approve(routerAddr, MaxUint256)

        // accumulate token1 fees
        await router.exactInput({
          recipient: wallet.address,
          deadline: 1,
          path: encodePath([token1Addr, token0Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
          amountIn: expandTo18Decimals(1_000),
          amountOutMinimum: 0,
        })

        // accumulate token0 fees and push price below tickLower
        await router.exactInput({
          recipient: wallet.address,
          deadline: 1,
          path: encodePath([token0Addr, token1Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
          amountIn: expandTo18Decimals(50_000),
          amountOutMinimum: 0,
        })
      })

      it('returns the correct amount of fees', async () => {
        const feesFromCollect = await nft.collect.staticCall({
          tokenId,
          recipient: wallet.address,
          amount0Max: MaxUint128,
          amount1Max: MaxUint128,
        })

        const feeAmounts = await positionValue.fees(await nft.getAddress(), tokenId)
        expect(feeAmounts[0]).to.equal(feesFromCollect[0])
        expect(feeAmounts[1]).to.equal(feesFromCollect[1])
      })

      it('gas', async () => {
        await snapshotGasCost(positionValue.feesGas(await nft.getAddress(), tokenId))
      })
    })

    describe('when price is above the position range', async () => {
      beforeEach(async () => {
        const token0Addr = await tokens[0].getAddress()
        const token1Addr = await tokens[1].getAddress()
        const routerAddr = await router.getAddress()

        await nft.mint({
          token0: token0Addr,
          token1: token1Addr,
          tickLower: TICK_SPACINGS[FeeAmount.MEDIUM] * -10,
          tickUpper: TICK_SPACINGS[FeeAmount.MEDIUM] * 10,
          tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
          recipient: wallet.address,
          amount0Desired: expandTo18Decimals(10_000),
          amount1Desired: expandTo18Decimals(10_000),
          amount0Min: 0,
          amount1Min: 0,
          deadline: 10,
          sqrtPriceX96: 0,
        })

        await tokens[0].approve(routerAddr, MaxUint256)
        await tokens[1].approve(routerAddr, MaxUint256)

        // accumulate token0 fees
        await router.exactInput({
          recipient: wallet.address,
          deadline: 1,
          path: encodePath([token0Addr, token1Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
          amountIn: expandTo18Decimals(1_000),
          amountOutMinimum: 0,
        })

        // accumulate token1 fees and push price above tickUpper
        await router.exactInput({
          recipient: wallet.address,
          deadline: 1,
          path: encodePath([token1Addr, token0Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
          amountIn: expandTo18Decimals(50_000),
          amountOutMinimum: 0,
        })
      })

      it('returns the correct amount of fees', async () => {
        const feesFromCollect = await nft.collect.staticCall({
          tokenId,
          recipient: wallet.address,
          amount0Max: MaxUint128,
          amount1Max: MaxUint128,
        })
        const feeAmounts = await positionValue.fees(await nft.getAddress(), tokenId)
        expect(feeAmounts[0]).to.equal(feesFromCollect[0])
        expect(feeAmounts[1]).to.equal(feesFromCollect[1])
      })

      it('gas', async () => {
        await snapshotGasCost(positionValue.feesGas(await nft.getAddress(), tokenId))
      })
    })
  })
})
