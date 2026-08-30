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
import { createPool, createPoolWithMultiplePositions, createPoolWithZeroTickInitialized } from './shared/quoter'
import snapshotGasCost from './shared/snapshotGasCost'

describe('QuoterV2', function () {
  this.timeout(40000)

  let ethers: EthersHelpers
  let networkHelpers: NetHelpers

  let wallet: HardhatEthersSigner
  let trader: HardhatEthersSigner

  let nft: Contract
  let tokens: [Contract, Contract, Contract]
  let quoter: Contract

  before('create fixture loader', async () => {
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

    const quoterFactory = await ethers.getContractFactory('QuoterV2')
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
      const token0Addr = await tokens[0].getAddress()
      const token1Addr = await tokens[1].getAddress()
      const token2Addr = await tokens[2].getAddress()
      await createPool(nft, wallet, token0Addr, token1Addr)
      await createPool(nft, wallet, token1Addr, token2Addr)
      await createPoolWithMultiplePositions(nft, wallet, token0Addr, token2Addr)
    })

    describe('#quoteExactInput', () => {
      it('0 -> 2 cross 2 tick', async () => {
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountOut, sqrtPriceX96AfterList, initializedTicksCrossedList, gasEstimate } =
          await quoter.quoteExactInput.staticCall(
            encodePath([token0Addr, token2Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
            10000
          )

        await snapshotGasCost(gasEstimate)
        expect(sqrtPriceX96AfterList.length).to.eq(1)
        expect(sqrtPriceX96AfterList[0]).to.eq('78461846509168490764501028180')
        expect(initializedTicksCrossedList[0]).to.eq(2)
        expect(amountOut).to.eq(9871)
      })

      it('0 -> 2 cross 2 tick where after is initialized', async () => {
        // The swap amount is set such that the active tick after the swap is -120.
        // -120 is an initialized tick for this pool. We check that we don't count it.
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountOut, sqrtPriceX96AfterList, initializedTicksCrossedList, gasEstimate } =
          await quoter.quoteExactInput.staticCall(
            encodePath([token0Addr, token2Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
            6200
          )

        await snapshotGasCost(gasEstimate)
        expect(sqrtPriceX96AfterList.length).to.eq(1)
        expect(sqrtPriceX96AfterList[0]).to.eq('78757224507315167622282810783')
        expect(initializedTicksCrossedList.length).to.eq(1)
        expect(initializedTicksCrossedList[0]).to.eq(1)
        expect(amountOut).to.eq(6143)
      })

      it('0 -> 2 cross 1 tick', async () => {
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountOut, sqrtPriceX96AfterList, initializedTicksCrossedList, gasEstimate } =
          await quoter.quoteExactInput.staticCall(
            encodePath([token0Addr, token2Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
            4000
          )

        await snapshotGasCost(gasEstimate)
        expect(initializedTicksCrossedList[0]).to.eq(1)
        expect(sqrtPriceX96AfterList.length).to.eq(1)
        expect(sqrtPriceX96AfterList[0]).to.eq('78926452400586371254602774705')
        expect(amountOut).to.eq(3971)
      })

      it('0 -> 2 cross 0 tick, starting tick not initialized', async () => {
        // Tick before 0, tick after -1.
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountOut, sqrtPriceX96AfterList, initializedTicksCrossedList, gasEstimate } =
          await quoter.quoteExactInput.staticCall(
            encodePath([token0Addr, token2Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
            10
          )

        await snapshotGasCost(gasEstimate)
        expect(initializedTicksCrossedList[0]).to.eq(0)
        expect(sqrtPriceX96AfterList.length).to.eq(1)
        expect(sqrtPriceX96AfterList[0]).to.eq('79227483487511329217250071027')
        expect(amountOut).to.eq(8)
      })

      it('0 -> 2 cross 0 tick, starting tick initialized', async () => {
        // Tick before 0, tick after -1. Tick 0 initialized.
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        await createPoolWithZeroTickInitialized(nft, wallet, token0Addr, token2Addr)

        const { amountOut, sqrtPriceX96AfterList, initializedTicksCrossedList, gasEstimate } =
          await quoter.quoteExactInput.staticCall(
            encodePath([token0Addr, token2Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
            10
          )

        await snapshotGasCost(gasEstimate)
        expect(initializedTicksCrossedList[0]).to.eq(1)
        expect(sqrtPriceX96AfterList.length).to.eq(1)
        expect(sqrtPriceX96AfterList[0]).to.eq('79227817515327498931091950511')
        expect(amountOut).to.eq(8)
      })

      it('2 -> 0 cross 2', async () => {
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountOut, sqrtPriceX96AfterList, initializedTicksCrossedList, gasEstimate } =
          await quoter.quoteExactInput.staticCall(
            encodePath([token2Addr, token0Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
            10000
          )

        await snapshotGasCost(gasEstimate)
        expect(initializedTicksCrossedList[0]).to.eq(2)
        expect(sqrtPriceX96AfterList.length).to.eq(1)
        expect(sqrtPriceX96AfterList[0]).to.eq('80001962924147897865541384515')
        expect(initializedTicksCrossedList.length).to.eq(1)
        expect(amountOut).to.eq(9871)
      })

      it('2 -> 0 cross 2 where tick after is initialized', async () => {
        // The swap amount is set such that the active tick after the swap is 120.
        // 120 is an initialized tick for this pool. We check we don't count it.
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountOut, sqrtPriceX96AfterList, initializedTicksCrossedList, gasEstimate } =
          await quoter.quoteExactInput.staticCall(
            encodePath([token2Addr, token0Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
            6250
          )

        await snapshotGasCost(gasEstimate)
        expect(initializedTicksCrossedList[0]).to.eq(2)
        expect(sqrtPriceX96AfterList.length).to.eq(1)
        expect(sqrtPriceX96AfterList[0]).to.eq('79705728824507063507279123685')
        expect(initializedTicksCrossedList.length).to.eq(1)
        expect(amountOut).to.eq(6190)
      })

      it('2 -> 0 cross 0 tick, starting tick initialized', async () => {
        // Tick 0 initialized. Tick after = 1
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        await createPoolWithZeroTickInitialized(nft, wallet, token0Addr, token2Addr)

        const { amountOut, sqrtPriceX96AfterList, initializedTicksCrossedList, gasEstimate } =
          await quoter.quoteExactInput.staticCall(
            encodePath([token2Addr, token0Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
            200
          )

        await snapshotGasCost(gasEstimate)
        expect(initializedTicksCrossedList[0]).to.eq(0)
        expect(sqrtPriceX96AfterList.length).to.eq(1)
        expect(sqrtPriceX96AfterList[0]).to.eq('79235729830182478001034429156')
        expect(initializedTicksCrossedList.length).to.eq(1)
        expect(amountOut).to.eq(198)
      })

      it('2 -> 0 cross 0 tick, starting tick not initialized', async () => {
        // Tick 0 initialized. Tick after = 1
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountOut, sqrtPriceX96AfterList, initializedTicksCrossedList, gasEstimate } =
          await quoter.quoteExactInput.staticCall(
            encodePath([token2Addr, token0Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
            103
          )

        await snapshotGasCost(gasEstimate)
        expect(initializedTicksCrossedList[0]).to.eq(0)
        expect(sqrtPriceX96AfterList.length).to.eq(1)
        expect(sqrtPriceX96AfterList[0]).to.eq('79235858216754624215638319723')
        expect(initializedTicksCrossedList.length).to.eq(1)
        expect(amountOut).to.eq(101)
      })

      it('2 -> 1', async () => {
        const token1Addr = await tokens[1].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountOut, sqrtPriceX96AfterList, initializedTicksCrossedList, gasEstimate } =
          await quoter.quoteExactInput.staticCall(
            encodePath([token2Addr, token1Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
            10000
          )

        await snapshotGasCost(gasEstimate)
        expect(sqrtPriceX96AfterList.length).to.eq(1)
        expect(sqrtPriceX96AfterList[0]).to.eq('80018067294531553039351583520')
        expect(initializedTicksCrossedList[0]).to.eq(0)
        expect(amountOut).to.eq(9871)
      })

      it('0 -> 2 -> 1', async () => {
        const token0Addr = await tokens[0].getAddress()
        const token1Addr = await tokens[1].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountOut, sqrtPriceX96AfterList, initializedTicksCrossedList, gasEstimate } =
          await quoter.quoteExactInput.staticCall(
            encodePath(
              [token0Addr, token2Addr, token1Addr],
              [TICK_SPACINGS[FeeAmount.MEDIUM], TICK_SPACINGS[FeeAmount.MEDIUM]]
            ),
            10000
          )

        await snapshotGasCost(gasEstimate)
        expect(sqrtPriceX96AfterList.length).to.eq(2)
        expect(sqrtPriceX96AfterList[0]).to.eq('78461846509168490764501028180')
        expect(sqrtPriceX96AfterList[1]).to.eq('80007846861567212939802016351')
        expect(initializedTicksCrossedList[0]).to.eq(2)
        expect(initializedTicksCrossedList[1]).to.eq(0)
        expect(amountOut).to.eq(9745)
      })
    })

    describe('#quoteExactInputSingle', () => {
      it('0 -> 2', async () => {
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const {
          amountOut: quote,
          sqrtPriceX96After,
          initializedTicksCrossed,
          gasEstimate,
        } = await quoter.quoteExactInputSingle.staticCall({
          tokenIn: token0Addr,
          tokenOut: token2Addr,
          tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
          amountIn: 10000,
          // -2%
          sqrtPriceLimitX96: encodePriceSqrt(100, 102),
        })

        await snapshotGasCost(gasEstimate)
        expect(initializedTicksCrossed).to.eq(2)
        expect(quote).to.eq(9871)
        expect(sqrtPriceX96After).to.eq('78461846509168490764501028180')
      })

      it('2 -> 0', async () => {
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const {
          amountOut: quote,
          sqrtPriceX96After,
          initializedTicksCrossed,
          gasEstimate,
        } = await quoter.quoteExactInputSingle.staticCall({
          tokenIn: token2Addr,
          tokenOut: token0Addr,
          tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
          amountIn: 10000,
          // +2%
          sqrtPriceLimitX96: encodePriceSqrt(102, 100),
        })

        await snapshotGasCost(gasEstimate)
        expect(initializedTicksCrossed).to.eq(2)
        expect(quote).to.eq(9871)
        expect(sqrtPriceX96After).to.eq('80001962924147897865541384515')
      })
    })

    describe('#quoteExactOutput', () => {
      it('0 -> 2 cross 2 tick', async () => {
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountIn, sqrtPriceX96AfterList, initializedTicksCrossedList, gasEstimate } =
          await quoter.quoteExactOutput.staticCall(
            encodePath([token2Addr, token0Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
            15000
          )

        await snapshotGasCost(gasEstimate)
        expect(initializedTicksCrossedList.length).to.eq(1)
        expect(initializedTicksCrossedList[0]).to.eq(2)
        expect(amountIn).to.eq(15273)

        expect(sqrtPriceX96AfterList.length).to.eq(1)
        expect(sqrtPriceX96AfterList[0]).to.eq('78055527257643669242286029831')
      })

      it('0 -> 2 cross 2 where tick after is initialized', async () => {
        // The swap amount is set such that the active tick after the swap is -120.
        // -120 is an initialized tick for this pool. We check that we count it.
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountIn, sqrtPriceX96AfterList, initializedTicksCrossedList, gasEstimate } =
          await quoter.quoteExactOutput.staticCall(
            encodePath([token2Addr, token0Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
            6143
          )

        await snapshotGasCost(gasEstimate)
        expect(sqrtPriceX96AfterList.length).to.eq(1)
        expect(sqrtPriceX96AfterList[0]).to.eq('78757225449310403327341205211')
        expect(initializedTicksCrossedList.length).to.eq(1)
        expect(initializedTicksCrossedList[0]).to.eq(1)
        expect(amountIn).to.eq(6200)
      })

      it('0 -> 2 cross 1 tick', async () => {
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountIn, sqrtPriceX96AfterList, initializedTicksCrossedList, gasEstimate } =
          await quoter.quoteExactOutput.staticCall(
            encodePath([token2Addr, token0Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
            4000
          )

        await snapshotGasCost(gasEstimate)
        expect(initializedTicksCrossedList.length).to.eq(1)
        expect(initializedTicksCrossedList[0]).to.eq(1)
        expect(amountIn).to.eq(4029)

        expect(sqrtPriceX96AfterList.length).to.eq(1)
        expect(sqrtPriceX96AfterList[0]).to.eq('78924219757724709840818372098')
      })

      it('0 -> 2 cross 0 tick starting tick initialized', async () => {
        // Tick before 0, tick after 1. Tick 0 initialized.
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        await createPoolWithZeroTickInitialized(nft, wallet, token0Addr, token2Addr)
        const { amountIn, sqrtPriceX96AfterList, initializedTicksCrossedList, gasEstimate } =
          await quoter.quoteExactOutput.staticCall(
            encodePath([token2Addr, token0Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
            100
          )

        await snapshotGasCost(gasEstimate)
        expect(initializedTicksCrossedList.length).to.eq(1)
        expect(initializedTicksCrossedList[0]).to.eq(1)
        expect(amountIn).to.eq(102)

        expect(sqrtPriceX96AfterList.length).to.eq(1)
        expect(sqrtPriceX96AfterList[0]).to.eq('79224329176051641448521403903')
      })

      it('0 -> 2 cross 0 tick starting tick not initialized', async () => {
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountIn, sqrtPriceX96AfterList, initializedTicksCrossedList, gasEstimate } =
          await quoter.quoteExactOutput.staticCall(
            encodePath([token2Addr, token0Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
            10
          )

        await snapshotGasCost(gasEstimate)
        expect(initializedTicksCrossedList.length).to.eq(1)
        expect(initializedTicksCrossedList[0]).to.eq(0)
        expect(amountIn).to.eq(12)

        expect(sqrtPriceX96AfterList.length).to.eq(1)
        expect(sqrtPriceX96AfterList[0]).to.eq('79227408033628034983534698435')
      })

      it('2 -> 0 cross 2 ticks', async () => {
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountIn, sqrtPriceX96AfterList, initializedTicksCrossedList, gasEstimate } =
          await quoter.quoteExactOutput.staticCall(
            encodePath([token0Addr, token2Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
            15000
          )

        await snapshotGasCost(gasEstimate)
        expect(initializedTicksCrossedList.length).to.eq(1)
        expect(initializedTicksCrossedList[0]).to.eq(2)
        expect(amountIn).to.eq(15273)
        expect(sqrtPriceX96AfterList.length).to.eq(1)
        expect(sqrtPriceX96AfterList[0]).to.eq('80418414376567919517220409857')
      })

      it('2 -> 0 cross 2 where tick after is initialized', async () => {
        // The swap amount is set such that the active tick after the swap is 120.
        // 120 is an initialized tick for this pool. We check that we don't count it.
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountIn, sqrtPriceX96AfterList, initializedTicksCrossedList, gasEstimate } =
          await quoter.quoteExactOutput.staticCall(
            encodePath([token0Addr, token2Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
            6223
          )

        await snapshotGasCost(gasEstimate)
        expect(initializedTicksCrossedList[0]).to.eq(2)
        expect(sqrtPriceX96AfterList.length).to.eq(1)
        expect(sqrtPriceX96AfterList[0]).to.eq('79708304437530892332449657932')
        expect(initializedTicksCrossedList.length).to.eq(1)
        expect(amountIn).to.eq(6283)
      })

      it('2 -> 0 cross 1 tick', async () => {
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountIn, sqrtPriceX96AfterList, initializedTicksCrossedList, gasEstimate } =
          await quoter.quoteExactOutput.staticCall(
            encodePath([token0Addr, token2Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
            6000
          )

        await snapshotGasCost(gasEstimate)
        expect(initializedTicksCrossedList[0]).to.eq(1)
        expect(sqrtPriceX96AfterList.length).to.eq(1)
        expect(sqrtPriceX96AfterList[0]).to.eq('79690640184021170956740081887')
        expect(initializedTicksCrossedList.length).to.eq(1)
        expect(amountIn).to.eq(6055)
      })

      it('2 -> 1', async () => {
        const token1Addr = await tokens[1].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountIn, sqrtPriceX96AfterList, initializedTicksCrossedList, gasEstimate } =
          await quoter.quoteExactOutput.staticCall(
            encodePath([token1Addr, token2Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
            9871
          )

        await snapshotGasCost(gasEstimate)
        expect(sqrtPriceX96AfterList.length).to.eq(1)
        expect(sqrtPriceX96AfterList[0]).to.eq('80018020393569259756601362385')
        expect(initializedTicksCrossedList[0]).to.eq(0)
        expect(amountIn).to.eq(10000)
      })

      it('0 -> 2 -> 1', async () => {
        const token0Addr = await tokens[0].getAddress()
        const token1Addr = await tokens[1].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountIn, sqrtPriceX96AfterList, initializedTicksCrossedList, gasEstimate } =
          await quoter.quoteExactOutput.staticCall(
            encodePath([token0Addr, token2Addr, token1Addr].reverse(), [
              TICK_SPACINGS[FeeAmount.MEDIUM],
              TICK_SPACINGS[FeeAmount.MEDIUM],
            ]),
            9745
          )

        await snapshotGasCost(gasEstimate)
        expect(sqrtPriceX96AfterList.length).to.eq(2)
        expect(sqrtPriceX96AfterList[0]).to.eq('80007838904387594703933785072')
        expect(sqrtPriceX96AfterList[1]).to.eq('78461888503179331029803316753')
        expect(initializedTicksCrossedList[0]).to.eq(0)
        expect(initializedTicksCrossedList[1]).to.eq(2)
        expect(amountIn).to.eq(10000)
      })
    })

    describe('#quoteExactOutputSingle', () => {
      it('0 -> 1', async () => {
        const token0Addr = await tokens[0].getAddress()
        const token1Addr = await tokens[1].getAddress()
        const { amountIn, sqrtPriceX96After, initializedTicksCrossed, gasEstimate } =
          await quoter.quoteExactOutputSingle.staticCall({
            tokenIn: token0Addr,
            tokenOut: token1Addr,
            tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
            amount: MaxUint128,
            sqrtPriceLimitX96: encodePriceSqrt(100, 102),
          })

        await snapshotGasCost(gasEstimate)
        expect(amountIn).to.eq(9981)
        expect(initializedTicksCrossed).to.eq(0)
        expect(sqrtPriceX96After).to.eq('78447570448055484695608110440')
      })

      it('1 -> 0', async () => {
        const token0Addr = await tokens[0].getAddress()
        const token1Addr = await tokens[1].getAddress()
        const { amountIn, sqrtPriceX96After, initializedTicksCrossed, gasEstimate } =
          await quoter.quoteExactOutputSingle.staticCall({
            tokenIn: token1Addr,
            tokenOut: token0Addr,
            tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
            amount: MaxUint128,
            sqrtPriceLimitX96: encodePriceSqrt(102, 100),
          })

        await snapshotGasCost(gasEstimate)
        expect(amountIn).to.eq(9981)
        expect(initializedTicksCrossed).to.eq(0)
        expect(sqrtPriceX96After).to.eq('80016521857016594389520272648')
      })
    })
  })
})
