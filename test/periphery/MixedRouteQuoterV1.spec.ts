import { config as dotenvConfig } from 'dotenv'
dotenvConfig()

import { Contract, MaxUint256 } from 'ethers'
import { network } from 'hardhat'
import type { EthersHelpers, NetHelpers } from '../shared/network'
import type { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/types'
import completeFixture from './shared/completeFixture'
import { FeeAmount, TICK_SPACINGS, V2_PLACEHOLDER_STABLE, V2_PLACEHOLDER_VOLATILE } from './shared/constants'
import { encodePriceSqrt } from './shared/encodePriceSqrt'
import { expandTo18Decimals } from './shared/expandTo18Decimals'
import { expect } from './shared/expect'
import { encodePath } from './shared/path'
import {
  createPair,
  createPool,
  createPoolWithMultiplePositions,
  createPoolWithZeroTickInitialized,
} from './shared/quoter'
import snapshotGasCost from './shared/snapshotGasCost'

import { abi as POOL_V2_ABI } from './shared/abis/V2Pool.json'
import { abi as FACTORY_V2_ABI } from './shared/abis/V2Factory.json'
import jsonConstants from '../../script/constants/Optimism.json'

const factoryV2Address = jsonConstants.factoryV2

describe('MixedRouteQuoterV1', function () {
  this.timeout(120000)

  let ethers: EthersHelpers
  let networkHelpers: NetHelpers

  let wallet: HardhatEthersSigner
  let trader: HardhatEthersSigner

  let nft: Contract
  let factoryV2: Contract
  let tokens: [Contract, Contract, Contract]
  let quoter: Contract

  let pair01Address: string
  let pair02Address: string
  let pair12Address: string
  let pair01AddressStable: string
  let pair02AddressStable: string
  let pair12AddressStable: string

  before('create fixture loader', async () => {
    const conn = await network.create({
      override: {
        forking: {
          url: `${process.env.OPTIMISM_RPC_URL}`,
          blockNumber: 114000000,
        },
      },
    })
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

    const factoryV2 = new ethers.Contract(factoryV2Address, FACTORY_V2_ABI, wallet)
    const quoterFactory = await ethers.getContractFactory('MixedRouteQuoterV1')
    const quoter = (await quoterFactory.deploy(
      await factory.getAddress(),
      factoryV2Address,
      await weth9.getAddress()
    )) as unknown as Contract

    return {
      tokens,
      nft,
      factoryV2,
      quoter,
    }
  }

  // helper for getting weth and token balances
  beforeEach('load fixture', async () => {
    ;({ tokens, nft, factoryV2, quoter } = await networkHelpers.loadFixture(swapRouterFixture))
  })

  const addLiquidityV2 = async (
    pairAddress: string,
    token0: Contract,
    token1: Contract,
    amount0: string,
    amount1: string
  ) => {
    const pair = new Contract(pairAddress, POOL_V2_ABI, wallet)
    expect(await pair.token0.staticCall()).to.equal(await token0.getAddress())
    expect(await pair.token1.staticCall()).to.equal(await token1.getAddress())
    // seed the pairs with liquidity

    const [reserve0Before, reserve1Before] = await pair.getReserves.staticCall()

    const token0BalanceBefore = await token0.balanceOf(pairAddress)
    const token1BalanceBefore = await token1.balanceOf(pairAddress)

    await token0.transfer(pairAddress, ethers.parseEther(amount0))
    await token1.transfer(pairAddress, ethers.parseEther(amount1))

    expect(await token0.balanceOf(pairAddress)).to.equal(token0BalanceBefore + ethers.parseEther(amount0))
    expect(await token1.balanceOf(pairAddress)).to.equal(token1BalanceBefore + ethers.parseEther(amount1))

    await pair.mint(wallet.address) // update the reserves

    const [reserve0, reserve1] = await pair.getReserves.staticCall()
    expect(reserve0).to.equal(reserve0Before + ethers.parseEther(amount0))
    expect(reserve1).to.equal(reserve1Before + ethers.parseEther(amount1))
  }

  describe('quotes', () => {
    beforeEach(async () => {
      const token0Addr = await tokens[0].getAddress()
      const token1Addr = await tokens[1].getAddress()
      const token2Addr = await tokens[2].getAddress()

      await createPool(nft, wallet, token0Addr, token1Addr)
      await createPool(nft, wallet, token1Addr, token2Addr)
      await createPoolWithMultiplePositions(nft, wallet, token0Addr, token2Addr)
      /// @dev Create V2 Pairs
      pair01Address = await createPair(factoryV2, token0Addr, token1Addr, false)
      pair12Address = await createPair(factoryV2, token1Addr, token2Addr, false)
      pair02Address = await createPair(factoryV2, token0Addr, token2Addr, false)
      pair01AddressStable = await createPair(factoryV2, token0Addr, token1Addr, true)
      pair12AddressStable = await createPair(factoryV2, token1Addr, token2Addr, true)
      pair02AddressStable = await createPair(factoryV2, token0Addr, token2Addr, true)

      await addLiquidityV2(pair01Address, tokens[0], tokens[1], '1000000', '1000000')
      await addLiquidityV2(pair12Address, tokens[1], tokens[2], '1000000', '1000000')
      await addLiquidityV2(pair02Address, tokens[0], tokens[2], '1000000', '1000000')
      await addLiquidityV2(pair01AddressStable, tokens[0], tokens[1], '1000000', '1000000')
      await addLiquidityV2(pair12AddressStable, tokens[1], tokens[2], '1000000', '1000000')
      await addLiquidityV2(pair02AddressStable, tokens[0], tokens[2], '1000000', '1000000')
    })

    /// @dev Test running the old suite on the new function but with protocolFlags only being V3[]
    describe('#quoteExactInput V3 only', () => {
      it('0 -> 2 cross 2 tick', async () => {
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountOut, v3SqrtPriceX96AfterList, v3InitializedTicksCrossedList, v3SwapGasEstimate } = await quoter[
          'quoteExactInput(bytes,uint256)'
        ].staticCall(encodePath([token0Addr, token2Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]), 10000)

        expect(v3SqrtPriceX96AfterList.length).to.eq(1)
        expect(v3SqrtPriceX96AfterList[0]).to.eq('78461846509168490764501028180')
        expect(v3InitializedTicksCrossedList[0]).to.eq(2)
        expect(amountOut).to.eq(9871)
        await snapshotGasCost(v3SwapGasEstimate)
      })

      it('0 -> 2 cross 2 tick where after is initialized', async () => {
        // The swap amount is set such that the active tick after the swap is -120.
        // -120 is an initialized tick for this pool. We check that we don't count it.
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountOut, v3SqrtPriceX96AfterList, v3InitializedTicksCrossedList, v3SwapGasEstimate } = await quoter[
          'quoteExactInput(bytes,uint256)'
        ].staticCall(encodePath([token0Addr, token2Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]), 6200)

        await snapshotGasCost(v3SwapGasEstimate)
        expect(v3SqrtPriceX96AfterList.length).to.eq(1)
        expect(v3SqrtPriceX96AfterList[0]).to.eq('78757224507315167622282810783')
        expect(v3InitializedTicksCrossedList.length).to.eq(1)
        expect(v3InitializedTicksCrossedList[0]).to.eq(1)
        expect(amountOut).to.eq(6143)
      })

      it('0 -> 2 cross 1 tick', async () => {
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountOut, v3SqrtPriceX96AfterList, v3InitializedTicksCrossedList, v3SwapGasEstimate } = await quoter[
          'quoteExactInput(bytes,uint256)'
        ].staticCall(encodePath([token0Addr, token2Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]), 4000)

        await snapshotGasCost(v3SwapGasEstimate)
        expect(v3InitializedTicksCrossedList[0]).to.eq(1)
        expect(v3SqrtPriceX96AfterList.length).to.eq(1)
        expect(v3SqrtPriceX96AfterList[0]).to.eq('78926452400586371254602774705')
        expect(amountOut).to.eq(3971)
      })

      it('0 -> 2 cross 0 tick, starting tick not initialized', async () => {
        // Tick before 0, tick after -1.
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountOut, v3SqrtPriceX96AfterList, v3InitializedTicksCrossedList, v3SwapGasEstimate } = await quoter[
          'quoteExactInput(bytes,uint256)'
        ].staticCall(encodePath([token0Addr, token2Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]), 10)

        await snapshotGasCost(v3SwapGasEstimate)
        expect(v3InitializedTicksCrossedList[0]).to.eq(0)
        expect(v3SqrtPriceX96AfterList.length).to.eq(1)
        expect(v3SqrtPriceX96AfterList[0]).to.eq('79227483487511329217250071027')
        expect(amountOut).to.eq(8)
      })

      it('0 -> 2 cross 0 tick, starting tick initialized', async () => {
        // Tick before 0, tick after -1. Tick 0 initialized.
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        await createPoolWithZeroTickInitialized(nft, wallet, token0Addr, token2Addr)

        const { amountOut, v3SqrtPriceX96AfterList, v3InitializedTicksCrossedList, v3SwapGasEstimate } = await quoter[
          'quoteExactInput(bytes,uint256)'
        ].staticCall(encodePath([token0Addr, token2Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]), 10)

        await snapshotGasCost(v3SwapGasEstimate)
        expect(v3InitializedTicksCrossedList[0]).to.eq(1)
        expect(v3SqrtPriceX96AfterList.length).to.eq(1)
        expect(v3SqrtPriceX96AfterList[0]).to.eq('79227817515327498931091950511')
        expect(amountOut).to.eq(8)
      })

      it('2 -> 0 cross 2', async () => {
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountOut, v3SqrtPriceX96AfterList, v3InitializedTicksCrossedList, v3SwapGasEstimate } = await quoter[
          'quoteExactInput(bytes,uint256)'
        ].staticCall(encodePath([token2Addr, token0Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]), 10000)

        await snapshotGasCost(v3SwapGasEstimate)
        expect(v3InitializedTicksCrossedList[0]).to.eq(2)
        expect(v3SqrtPriceX96AfterList.length).to.eq(1)
        expect(v3SqrtPriceX96AfterList[0]).to.eq('80001962924147897865541384515')
        expect(v3InitializedTicksCrossedList.length).to.eq(1)
        expect(amountOut).to.eq(9871)
      })

      it('2 -> 0 cross 2 where tick after is initialized', async () => {
        // The swap amount is set such that the active tick after the swap is 120.
        // 120 is an initialized tick for this pool. We check we don't count it.
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountOut, v3SqrtPriceX96AfterList, v3InitializedTicksCrossedList, v3SwapGasEstimate } = await quoter[
          'quoteExactInput(bytes,uint256)'
        ].staticCall(encodePath([token2Addr, token0Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]), 6250)

        await snapshotGasCost(v3SwapGasEstimate)
        expect(v3InitializedTicksCrossedList[0]).to.eq(2)
        expect(v3SqrtPriceX96AfterList.length).to.eq(1)
        expect(v3SqrtPriceX96AfterList[0]).to.eq('79705728824507063507279123685')
        expect(v3InitializedTicksCrossedList.length).to.eq(1)
        expect(amountOut).to.eq(6190)
      })

      it('2 -> 0 cross 0 tick, starting tick initialized', async () => {
        // Tick 0 initialized. Tick after = 1
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        await createPoolWithZeroTickInitialized(nft, wallet, token0Addr, token2Addr)

        const { amountOut, v3SqrtPriceX96AfterList, v3InitializedTicksCrossedList, v3SwapGasEstimate } = await quoter[
          'quoteExactInput(bytes,uint256)'
        ].staticCall(encodePath([token2Addr, token0Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]), 200)

        await snapshotGasCost(v3SwapGasEstimate)
        expect(v3InitializedTicksCrossedList[0]).to.eq(0)
        expect(v3SqrtPriceX96AfterList.length).to.eq(1)
        expect(v3SqrtPriceX96AfterList[0]).to.eq('79235729830182478001034429156')
        expect(v3InitializedTicksCrossedList.length).to.eq(1)
        expect(amountOut).to.eq(198)
      })

      it('2 -> 0 cross 0 tick, starting tick not initialized', async () => {
        // Tick 0 initialized. Tick after = 1
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountOut, v3SqrtPriceX96AfterList, v3InitializedTicksCrossedList, v3SwapGasEstimate } = await quoter[
          'quoteExactInput(bytes,uint256)'
        ].staticCall(encodePath([token2Addr, token0Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]), 103)

        await snapshotGasCost(v3SwapGasEstimate)
        expect(v3InitializedTicksCrossedList[0]).to.eq(0)
        expect(v3SqrtPriceX96AfterList.length).to.eq(1)
        expect(v3SqrtPriceX96AfterList[0]).to.eq('79235858216754624215638319723')
        expect(v3InitializedTicksCrossedList.length).to.eq(1)
        expect(amountOut).to.eq(101)
      })

      it('2 -> 1', async () => {
        const token1Addr = await tokens[1].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountOut, v3SqrtPriceX96AfterList, v3InitializedTicksCrossedList, v3SwapGasEstimate } = await quoter[
          'quoteExactInput(bytes,uint256)'
        ].staticCall(encodePath([token2Addr, token1Addr], [TICK_SPACINGS[FeeAmount.MEDIUM]]), 10000)

        await snapshotGasCost(v3SwapGasEstimate)
        expect(v3SqrtPriceX96AfterList.length).to.eq(1)
        expect(v3SqrtPriceX96AfterList[0]).to.eq('80018067294531553039351583520')
        expect(v3InitializedTicksCrossedList[0]).to.eq(0)
        expect(amountOut).to.eq(9871)
      })

      it('0 -> 2 -> 1', async () => {
        const token0Addr = await tokens[0].getAddress()
        const token1Addr = await tokens[1].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountOut, v3SqrtPriceX96AfterList, v3InitializedTicksCrossedList, v3SwapGasEstimate } = await quoter[
          'quoteExactInput(bytes,uint256)'
        ].staticCall(
          encodePath(
            [token0Addr, token2Addr, token1Addr],
            [TICK_SPACINGS[FeeAmount.MEDIUM], TICK_SPACINGS[FeeAmount.MEDIUM]]
          ),
          10000
        )

        await snapshotGasCost(v3SwapGasEstimate)
        expect(v3SqrtPriceX96AfterList.length).to.eq(2)
        expect(v3SqrtPriceX96AfterList[0]).to.eq('78461846509168490764501028180')
        expect(v3SqrtPriceX96AfterList[1]).to.eq('80007846861567212939802016351')
        expect(v3InitializedTicksCrossedList[0]).to.eq(2)
        expect(v3InitializedTicksCrossedList[1]).to.eq(0)
        expect(amountOut).to.eq(9745)
      })
    })

    /// @dev Test running the old suite on the new function but with protocolFlags only being V2[]
    describe('#quoteExactInput V2 only', () => {
      it('0 -> 2 volatile', async () => {
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountOut, v3SwapGasEstimate } = await quoter['quoteExactInput(bytes,uint256)'].staticCall(
          encodePath([token0Addr, token2Addr], [V2_PLACEHOLDER_VOLATILE]),
          10000
        )

        expect(amountOut).to.eq(9969)
      })

      it('0 -> 1 -> 2 volatile', async () => {
        const token0Addr = await tokens[0].getAddress()
        const token1Addr = await tokens[1].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountOut, v3SwapGasEstimate } = await quoter['quoteExactInput(bytes,uint256)'].staticCall(
          encodePath([token0Addr, token1Addr, token2Addr], [V2_PLACEHOLDER_VOLATILE, V2_PLACEHOLDER_VOLATILE]),
          10000
        )

        expect(amountOut).to.eq(9939)
      })

      it('0 -> 2 stable', async () => {
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountOut, v3SwapGasEstimate } = await quoter['quoteExactInput(bytes,uint256)'].staticCall(
          encodePath([token0Addr, token2Addr], [V2_PLACEHOLDER_STABLE]),
          10000
        )

        expect(amountOut).to.eq(9994)
      })

      it('0 -> 1 -> 2 stable', async () => {
        const token0Addr = await tokens[0].getAddress()
        const token1Addr = await tokens[1].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const { amountOut, v3SwapGasEstimate } = await quoter['quoteExactInput(bytes,uint256)'].staticCall(
          encodePath([token0Addr, token1Addr, token2Addr], [V2_PLACEHOLDER_STABLE, V2_PLACEHOLDER_STABLE]),
          10000
        )

        expect(amountOut).to.eq(9989)
      })
    })

    /// @dev Test copied over from QuoterV2.spec.ts
    describe('#quoteExactInputSingle V3', () => {
      it('0 -> 2', async () => {
        const token0Addr = await tokens[0].getAddress()
        const token2Addr = await tokens[2].getAddress()
        const {
          amountOut: quote,
          sqrtPriceX96After,
          initializedTicksCrossed,
          gasEstimate,
        } = await quoter.quoteExactInputSingleV3.staticCall({
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
        } = await quoter.quoteExactInputSingleV3.staticCall({
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

    /// @dev Test the new function for fetching a single V2 pair quote on chain (exactIn)
    describe('#quoteExactInputSingleV2', () => {
      it('0 -> 2 volatile', async () => {
        const amountIn = 10000
        const tokenIn = await tokens[0].getAddress()
        const tokenOut = await tokens[2].getAddress()
        const stable = false
        const quote = await quoter.quoteExactInputSingleV2.staticCall({ tokenIn, tokenOut, stable, amountIn })

        expect(quote).to.eq(9969)
      })

      it('2 -> 0 volatile', async () => {
        const amountIn = 10000
        const tokenIn = await tokens[2].getAddress()
        const tokenOut = await tokens[0].getAddress()
        const stable = false
        const quote = await quoter.quoteExactInputSingleV2.staticCall({ tokenIn, tokenOut, stable, amountIn })

        expect(quote).to.eq(9969)
      })

      it('0 -> 2 stable', async () => {
        const amountIn = 10000
        const tokenIn = await tokens[0].getAddress()
        const tokenOut = await tokens[2].getAddress()
        const stable = true
        const quote = await quoter.quoteExactInputSingleV2.staticCall({ tokenIn, tokenOut, stable, amountIn })

        expect(quote).to.eq(9994)
      })

      it('2 -> 0 stable', async () => {
        const amountIn = 10000
        const tokenIn = await tokens[2].getAddress()
        const tokenOut = await tokens[0].getAddress()
        const stable = true
        const quote = await quoter.quoteExactInputSingleV2.staticCall({ tokenIn, tokenOut, stable, amountIn })

        expect(quote).to.eq(9994)
      })

      describe('+ with imbalanced pairs', () => {
        before(async () => {
          await addLiquidityV2(pair12Address, tokens[1], tokens[2], '1000000', '1000')
        })

        it('1 -> 2 volatile', async () => {
          const amountIn = 2_000_000
          const tokenIn = await tokens[1].getAddress()
          const tokenOut = await tokens[2].getAddress()
          const stable = false
          const quote = await quoter.quoteExactInputSingleV2.staticCall({ tokenIn, tokenOut, stable, amountIn })

          expect(quote).to.eq(1993999)
        })

        it('1 -> 2 stable', async () => {
          const amountIn = 2_000_000
          const tokenIn = await tokens[1].getAddress()
          const tokenOut = await tokens[2].getAddress()
          const stable = true
          const quote = await quoter.quoteExactInputSingleV2.staticCall({ tokenIn, tokenOut, stable, amountIn })

          expect(quote).to.eq(1998999)
        })
      })
    })
  })
})
