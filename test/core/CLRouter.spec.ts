import { Contract } from 'ethers'
import { network } from 'hardhat'
import type { EthersHelpers, NetHelpers } from '../shared/network'
import type { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/types'
import { expect } from './shared/expect'

import { poolFixture } from './shared/fixtures'

import {
  FeeAmount,
  TICK_SPACINGS,
  createPoolFunctions,
  type PoolFunctions,
  createMultiPoolFunctions,
  encodePriceSqrt,
  getMinTick,
  getMaxTick,
  expandTo18Decimals,
} from './shared/utilities'

const feeAmount = FeeAmount.MEDIUM
const startingPrice = encodePriceSqrt(1, 1)
const tickSpacing = TICK_SPACINGS[feeAmount]

describe('CLPool', () => {
  let ethers: EthersHelpers
  let networkHelpers: NetHelpers

  let wallet: HardhatEthersSigner
  let other: HardhatEthersSigner

  let token0: Contract
  let token1: Contract
  let token2: Contract
  let factory: Contract
  let pool0: Contract
  let pool1: Contract

  let pool0Functions: PoolFunctions
  let pool1Functions: PoolFunctions

  let minTick: number
  let maxTick: number

  let swapTargetCallee: Contract
  let swapTargetRouter: Contract

  let createPool: Awaited<ReturnType<typeof poolFixture>>['createPool']

  before(async () => {
    const conn = await network.create()
    ethers = conn.ethers
    networkHelpers = conn.networkHelpers
    ;[wallet, other] = await ethers.getSigners()
  })

  const fixture = async () => {
    return poolFixture(ethers, wallet)
  }

  beforeEach('deploy first fixture', async () => {
    ;({ token0, token1, token2, factory, createPool, swapTargetCallee, swapTargetRouter } =
      await networkHelpers.loadFixture(fixture))

    const createPoolWrapped = async (
      amount: number,
      spacing: number,
      firstToken: Contract,
      secondToken: Contract,
      sqrtPriceX96: bigint
    ): Promise<[Contract, PoolFunctions]> => {
      const pool = await createPool(amount, spacing, firstToken, secondToken, sqrtPriceX96)
      const poolFunctions = createPoolFunctions({
        swapTarget: swapTargetCallee,
        token0: firstToken,
        token1: secondToken,
        pool,
      })
      minTick = getMinTick(spacing)
      maxTick = getMaxTick(spacing)
      return [pool, poolFunctions]
    }

    // default to the 30 bips pool
    ;[pool0, pool0Functions] = await createPoolWrapped(feeAmount, tickSpacing, token0, token1, startingPrice)
    ;[pool1, pool1Functions] = await createPoolWrapped(feeAmount, tickSpacing, token1, token2, startingPrice)
  })

  it('constructor initializes immutables', async () => {
    expect(await pool0.factory()).to.eq(await factory.getAddress())
    expect(await pool0.token0()).to.eq(await token0.getAddress())
    expect(await pool0.token1()).to.eq(await token1.getAddress())
    expect(await pool1.factory()).to.eq(await factory.getAddress())
    expect(await pool1.token0()).to.eq(await token1.getAddress())
    expect(await pool1.token1()).to.eq(await token2.getAddress())
  })

  describe('multi-swaps', () => {
    let inputToken: Contract
    let outputToken: Contract

    beforeEach('initialize both pools', async () => {
      inputToken = token0
      outputToken = token2

      await pool0Functions.mint(wallet.address, minTick, maxTick, expandTo18Decimals(1))
      await pool1Functions.mint(wallet.address, minTick, maxTick, expandTo18Decimals(1))
    })

    it('multi-swap', async () => {
      const token0OfPoolOutput = await pool1.token0()
      const ForExact0 = (await outputToken.getAddress()) === token0OfPoolOutput

      const { swapForExact0Multi, swapForExact1Multi } = createMultiPoolFunctions({
        inputToken: token0,
        swapTarget: swapTargetRouter,
        poolInput: pool0,
        poolOutput: pool1,
      })

      const method = ForExact0 ? swapForExact0Multi : swapForExact1Multi

      await expect(method(100, wallet.address))
        .to.emit(outputToken, 'Transfer')
        .withArgs(await pool1.getAddress(), wallet.address, 100)
        .to.emit(token1, 'Transfer')
        .withArgs(await pool0.getAddress(), await pool1.getAddress(), 102)
        .to.emit(inputToken, 'Transfer')
        .withArgs(wallet.address, await pool0.getAddress(), 104)
    })
  })
})
