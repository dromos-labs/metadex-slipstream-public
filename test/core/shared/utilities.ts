import Decimal from 'decimal.js'
import {
  type BigNumberish,
  Contract,
  type ContractTransactionResponse,
  MaxUint256,
  solidityPackedKeccak256,
} from 'ethers'
import type { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/types'

export const MaxUint128 = 2n ** 128n - 1n

export const getMinTick = (tickSpacing: number) => Math.ceil(-887272 / tickSpacing) * tickSpacing
export const getMaxTick = (tickSpacing: number) => Math.floor(887272 / tickSpacing) * tickSpacing
export const getMaxLiquidityPerTick = (tickSpacing: number) =>
  (2n ** 128n - 1n) / BigInt((getMaxTick(tickSpacing) - getMinTick(tickSpacing)) / tickSpacing + 1)

export const MIN_SQRT_RATIO = 4295128739n
export const MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342n

export enum FeeAmount {
  LOW = 500,
  MEDIUM = 3000,
  HIGH = 10000,
}

export const TICK_SPACINGS: { [amount in FeeAmount]: number } = {
  [FeeAmount.LOW]: 10,
  [FeeAmount.MEDIUM]: 60,
  [FeeAmount.HIGH]: 200,
}

export function expandTo18Decimals(n: number): bigint {
  return BigInt(n) * 10n ** 18n
}

Decimal.set({ toExpPos: 9_999_999, toExpNeg: -9_999_999, precision: 80 })

// returns the sqrt price as a 64x96
export function encodePriceSqrt(reserve1: BigNumberish, reserve0: BigNumberish): bigint {
  return BigInt(
    new Decimal(reserve1.toString())
      .div(reserve0.toString())
      .sqrt()
      .mul(new Decimal(2).pow(96))
      .toFixed(0, Decimal.ROUND_FLOOR)
  )
}

export function getPositionKey(address: string, lowerTick: number, upperTick: number): string {
  return solidityPackedKeccak256(['address', 'int24', 'int24'], [address, lowerTick, upperTick])
}

export type SwapFunction = (
  amount: BigNumberish,
  to: HardhatEthersSigner | string,
  sqrtPriceLimitX96?: BigNumberish
) => Promise<ContractTransactionResponse>
export type SwapToPriceFunction = (
  sqrtPriceX96: BigNumberish,
  to: HardhatEthersSigner | string
) => Promise<ContractTransactionResponse>
export type FlashFunction = (
  amount0: BigNumberish,
  amount1: BigNumberish,
  to: HardhatEthersSigner | string,
  pay0?: BigNumberish,
  pay1?: BigNumberish
) => Promise<ContractTransactionResponse>
export type MintFunction = (
  recipient: string,
  tickLower: BigNumberish,
  tickUpper: BigNumberish,
  liquidity: BigNumberish
) => Promise<ContractTransactionResponse>
export interface PoolFunctions {
  swapToLowerPrice: SwapToPriceFunction
  swapToHigherPrice: SwapToPriceFunction
  swapExact0For1: SwapFunction
  swap0ForExact1: SwapFunction
  swapExact1For0: SwapFunction
  swap1ForExact0: SwapFunction
  flash: FlashFunction
  mint: MintFunction
}
export function createPoolFunctions({
  swapTarget,
  token0,
  token1,
  pool,
}: {
  swapTarget: Contract
  token0: Contract
  token1: Contract
  pool: Contract
}): PoolFunctions {
  async function swapToSqrtPrice(
    inputToken: Contract,
    targetPrice: BigNumberish,
    to: HardhatEthersSigner | string
  ): Promise<ContractTransactionResponse> {
    const method = inputToken === token0 ? swapTarget.swapToLowerSqrtPrice : swapTarget.swapToHigherSqrtPrice

    await inputToken.approve(await swapTarget.getAddress(), MaxUint256)

    const toAddress = typeof to === 'string' ? to : to.address

    return method(await pool.getAddress(), targetPrice, toAddress)
  }

  async function swap(
    inputToken: Contract,
    [amountIn, amountOut]: [BigNumberish, BigNumberish],
    to: HardhatEthersSigner | string,
    sqrtPriceLimitX96?: BigNumberish
  ): Promise<ContractTransactionResponse> {
    const exactInput = amountOut === 0

    const method =
      inputToken === token0
        ? exactInput
          ? swapTarget.swapExact0For1
          : swapTarget.swap0ForExact1
        : exactInput
        ? swapTarget.swapExact1For0
        : swapTarget.swap1ForExact0

    if (typeof sqrtPriceLimitX96 === 'undefined') {
      if (inputToken === token0) {
        sqrtPriceLimitX96 = MIN_SQRT_RATIO + 1n
      } else {
        sqrtPriceLimitX96 = MAX_SQRT_RATIO - 1n
      }
    }
    await inputToken.approve(await swapTarget.getAddress(), MaxUint256)

    const toAddress = typeof to === 'string' ? to : to.address

    return method(await pool.getAddress(), exactInput ? amountIn : amountOut, toAddress, sqrtPriceLimitX96)
  }

  const swapToLowerPrice: SwapToPriceFunction = (sqrtPriceX96, to) => {
    return swapToSqrtPrice(token0, sqrtPriceX96, to)
  }

  const swapToHigherPrice: SwapToPriceFunction = (sqrtPriceX96, to) => {
    return swapToSqrtPrice(token1, sqrtPriceX96, to)
  }

  const swapExact0For1: SwapFunction = (amount, to, sqrtPriceLimitX96) => {
    return swap(token0, [amount, 0], to, sqrtPriceLimitX96)
  }

  const swap0ForExact1: SwapFunction = (amount, to, sqrtPriceLimitX96) => {
    return swap(token0, [0, amount], to, sqrtPriceLimitX96)
  }

  const swapExact1For0: SwapFunction = (amount, to, sqrtPriceLimitX96) => {
    return swap(token1, [amount, 0], to, sqrtPriceLimitX96)
  }

  const swap1ForExact0: SwapFunction = (amount, to, sqrtPriceLimitX96) => {
    return swap(token1, [0, amount], to, sqrtPriceLimitX96)
  }

  const mint: MintFunction = async (recipient, tickLower, tickUpper, liquidity) => {
    await token0.approve(await swapTarget.getAddress(), MaxUint256)
    await token1.approve(await swapTarget.getAddress(), MaxUint256)
    return swapTarget.mint(await pool.getAddress(), recipient, tickLower, tickUpper, liquidity)
  }

  const flash: FlashFunction = async (amount0, amount1, to, pay0?: BigNumberish, pay1?: BigNumberish) => {
    const fee = await pool.fee()

    if (typeof pay0 === 'undefined') {
      pay0 = (BigInt(amount0.toString()) * BigInt(fee) + BigInt(1e6 - 1)) / BigInt(1e6) + BigInt(amount0.toString())
    }
    if (typeof pay1 === 'undefined') {
      pay1 = (BigInt(amount1.toString()) * BigInt(fee) + BigInt(1e6 - 1)) / BigInt(1e6) + BigInt(amount1.toString())
    }
    return swapTarget.flash(
      await pool.getAddress(),
      typeof to === 'string' ? to : to.address,
      amount0,
      amount1,
      pay0,
      pay1
    )
  }

  return {
    swapToLowerPrice,
    swapToHigherPrice,
    swapExact0For1,
    swap0ForExact1,
    swapExact1For0,
    swap1ForExact0,
    mint,
    flash,
  }
}

export interface MultiPoolFunctions {
  swapForExact0Multi: SwapFunction
  swapForExact1Multi: SwapFunction
}

export function createMultiPoolFunctions({
  inputToken,
  swapTarget,
  poolInput,
  poolOutput,
}: {
  inputToken: Contract
  swapTarget: Contract
  poolInput: Contract
  poolOutput: Contract
}): MultiPoolFunctions {
  async function swapForExact0Multi(
    amountOut: BigNumberish,
    to: HardhatEthersSigner | string
  ): Promise<ContractTransactionResponse> {
    const method = swapTarget.swapForExact0Multi
    await inputToken.approve(await swapTarget.getAddress(), MaxUint256)
    const toAddress = typeof to === 'string' ? to : to.address
    return method(toAddress, await poolInput.getAddress(), await poolOutput.getAddress(), amountOut)
  }

  async function swapForExact1Multi(
    amountOut: BigNumberish,
    to: HardhatEthersSigner | string
  ): Promise<ContractTransactionResponse> {
    const method = swapTarget.swapForExact1Multi
    await inputToken.approve(await swapTarget.getAddress(), MaxUint256)
    const toAddress = typeof to === 'string' ? to : to.address
    return method(toAddress, await poolInput.getAddress(), await poolOutput.getAddress(), amountOut)
  }

  return {
    swapForExact0Multi,
    swapForExact1Multi,
  }
}
