import { Contract } from 'ethers'
import { network } from 'hardhat'
import type { EthersHelpers, NetHelpers } from '../shared/network'
import type { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/types'
import completeFixture from './shared/completeFixture'
import { FeeAmount, MaxUint128, TICK_SPACINGS } from './shared/constants'
import { encodePriceSqrt } from './shared/encodePriceSqrt'
import snapshotGasCost from './shared/snapshotGasCost'

import { expect } from './shared/expect'
import { getMaxTick, getMinTick } from './shared/ticks'
import { computePoolAddress } from './shared/computePoolAddress'

describe('PairFlash test', () => {
  let ethers: EthersHelpers
  let networkHelpers: NetHelpers

  let wallet: HardhatEthersSigner

  let flash: Contract
  let nft: Contract
  let token0: Contract
  let token1: Contract
  let factory: Contract
  let quoter: Contract

  before(async () => {
    const conn = await network.create()
    ethers = conn.ethers
    networkHelpers = conn.networkHelpers
    ;[wallet] = await ethers.getSigners()
  })

  async function createPool(tokenAddressA: string, tokenAddressB: string, tickSpacing: number, price: bigint) {
    if (tokenAddressA.toLowerCase() > tokenAddressB.toLowerCase())
      [tokenAddressA, tokenAddressB] = [tokenAddressB, tokenAddressA]

    await nft.createPoolFromFactory(tokenAddressA, tokenAddressB, tickSpacing, price)

    const liquidityParams = {
      token0: tokenAddressA,
      token1: tokenAddressB,
      tickSpacing: tickSpacing,
      tickLower: getMinTick(tickSpacing),
      tickUpper: getMaxTick(tickSpacing),
      recipient: wallet.address,
      amount0Desired: 1000000,
      amount1Desired: 1000000,
      amount0Min: 0,
      amount1Min: 0,
      deadline: 1,
      sqrtPriceX96: 0,
    }

    return nft.mint(liquidityParams)
  }

  const flashFixture = async () => {
    const { router, tokens, factory, weth9, nft } = await completeFixture(ethers, wallet)
    const token0 = tokens[0]
    const token1 = tokens[1]

    const flashContractFactory = await ethers.getContractFactory('PairFlash')
    const flash = (await flashContractFactory.deploy(
      await router.getAddress(),
      await factory.getAddress(),
      await weth9.getAddress()
    )) as unknown as Contract

    const quoterFactory = await ethers.getContractFactory('Quoter')
    const quoter = (await quoterFactory.deploy(
      await factory.getAddress(),
      await weth9.getAddress()
    )) as unknown as Contract

    return {
      token0,
      token1,
      flash,
      factory,
      weth9,
      nft,
      quoter,
      router,
    }
  }

  beforeEach('load fixture', async () => {
    ;({ factory, token0, token1, flash, nft, quoter } = await networkHelpers.loadFixture(flashFixture))

    await token0.approve(await nft.getAddress(), MaxUint128)
    await token1.approve(await nft.getAddress(), MaxUint128)
    await createPool(
      await token0.getAddress(),
      await token1.getAddress(),
      TICK_SPACINGS[FeeAmount.LOW],
      encodePriceSqrt(5, 10)
    )
    await createPool(
      await token0.getAddress(),
      await token1.getAddress(),
      TICK_SPACINGS[FeeAmount.MEDIUM],
      encodePriceSqrt(1, 1)
    )
    await createPool(
      await token0.getAddress(),
      await token1.getAddress(),
      TICK_SPACINGS[FeeAmount.HIGH],
      encodePriceSqrt(20, 10)
    )
  })

  describe('flash', () => {
    it('test correct transfer events', async () => {
      //choose amountIn to test
      const amount0In = 1000
      const amount1In = 1000

      const fee0 = Math.ceil((amount0In * FeeAmount.MEDIUM) / 1000000)
      const fee1 = Math.ceil((amount1In * FeeAmount.MEDIUM) / 1000000)

      const token0Addr = await token0.getAddress()
      const token1Addr = await token1.getAddress()
      const flashAddr = await flash.getAddress()
      const factoryAddr = await factory.getAddress()

      const flashParams = {
        token0: token0Addr,
        token1: token1Addr,
        tickSpacing1: TICK_SPACINGS[FeeAmount.MEDIUM],
        amount0: amount0In,
        amount1: amount1In,
        tickSpacing2: TICK_SPACINGS[FeeAmount.LOW],
        tickSpacing3: TICK_SPACINGS[FeeAmount.HIGH],
      }
      // pool1 is the borrow pool
      const pool1 = await computePoolAddress(
        factoryAddr,
        [token0Addr, token1Addr],
        TICK_SPACINGS[FeeAmount.MEDIUM],
        factory
      )
      const pool2 = await computePoolAddress(
        factoryAddr,
        [token0Addr, token1Addr],
        TICK_SPACINGS[FeeAmount.LOW],
        factory
      )
      const pool3 = await computePoolAddress(
        factoryAddr,
        [token0Addr, token1Addr],
        TICK_SPACINGS[FeeAmount.HIGH],
        factory
      )

      const expectedAmountOut0 = await quoter.quoteExactInputSingle.staticCall(
        token1Addr,
        token0Addr,
        TICK_SPACINGS[FeeAmount.LOW],
        amount1In,
        encodePriceSqrt(20, 10)
      )
      const expectedAmountOut1 = await quoter.quoteExactInputSingle.staticCall(
        token0Addr,
        token1Addr,
        TICK_SPACINGS[FeeAmount.HIGH],
        amount0In,
        encodePriceSqrt(5, 10)
      )

      await expect(flash.initFlash(flashParams))
        .to.emit(token0, 'Transfer')
        .withArgs(pool1, flashAddr, amount0In)
        .to.emit(token1, 'Transfer')
        .withArgs(pool1, flashAddr, amount1In)
        .to.emit(token0, 'Transfer')
        .withArgs(pool2, flashAddr, expectedAmountOut0)
        .to.emit(token1, 'Transfer')
        .withArgs(pool3, flashAddr, expectedAmountOut1)
        .to.emit(token0, 'Transfer')
        .withArgs(flashAddr, wallet.address, Number(expectedAmountOut0) - amount0In - fee0)
        .to.emit(token1, 'Transfer')
        .withArgs(flashAddr, wallet.address, Number(expectedAmountOut1) - amount1In - fee1)
    })

    it('gas', async () => {
      const amount0In = 1000
      const amount1In = 1000

      const flashParams = {
        token0: await token0.getAddress(),
        token1: await token1.getAddress(),
        tickSpacing1: TICK_SPACINGS[FeeAmount.MEDIUM],
        amount0: amount0In,
        amount1: amount1In,
        tickSpacing2: TICK_SPACINGS[FeeAmount.LOW],
        tickSpacing3: TICK_SPACINGS[FeeAmount.HIGH],
      }
      await snapshotGasCost(flash.initFlash(flashParams))
    })
  })
})
