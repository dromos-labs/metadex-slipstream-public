export const MaxUint128 = 2n ** 128n - 1n

export const V2_PLACEHOLDER_VOLATILE = 4194304 // 1 << 22
export const V2_PLACEHOLDER_STABLE = 2097152 // 1 << 21

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
