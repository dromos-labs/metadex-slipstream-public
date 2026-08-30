import Decimal from 'decimal.js'
import type { BigNumberish } from 'ethers'

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
