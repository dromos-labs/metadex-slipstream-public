import { network } from 'hardhat'
import type { EthersHelpers, NetHelpers } from '../shared/network'
import { AbiCoder, Contract, keccak256, concat, zeroPadValue } from 'ethers'

import { expect } from './shared/expect'

// Minimal mock pool that implements tickSpacing() and tickBitmap(int16)
// by reading from storage slot 0 (tickSpacing) and mapping at slot 1 (tickBitmap).
// We deploy this "proxy storage" contract and then use hardhat_setStorageAt to set values.
//
// Bytecode encodes the following logic:
//   calldataload(0) >> 224 = selector (top 4 bytes of calldata)
//   0xd0c93a7c = tickSpacing()  -> SLOAD(0), return as int24
//   0x5339c296 = tickBitmap(int16) -> compute mapping slot = keccak256(pad(arg) | pad(1)), SLOAD, return
//
// We use a pre-compiled hex blob generated from the logic above.
// The bytecode below is hand-crafted EVM for this purpose.

// Create a mock CLPool-like contract address with configurable tickBitmap and tickSpacing.
async function deployMockPool(
  provider: any,
  tickSpacingValue: number,
  bitmapEntries: Record<number, bigint>
): Promise<string> {
  // We'll use hardhat_setCode to install our mock at a deterministic address.
  // The mock contract bytecode implements:
  //   tickSpacing() -> returns value from slot 0
  //   tickBitmap(int16) -> returns value from keccak256(pad32(arg) ++ pad32(1)) slot
  //
  // Yul pseudo-code:
  //   let selector := shr(224, calldataload(0))
  //   if eq(selector, 0xd0c93a7c) {  // tickSpacing()
  //     mstore(0, sload(0))
  //     return(12, 20)  // int24 is 3 bytes but returns as 32 bytes ABI-encoded
  //   }
  //   if eq(selector, 0x5339c296) {  // tickBitmap(int16)
  //     let arg := calldataload(4)   // int16 argument (ABI-encoded as 32 bytes)
  //     mstore(0x00, arg)
  //     mstore(0x20, 1)
  //     let slot := keccak256(0x00, 0x40)
  //     mstore(0, sload(slot))
  //     return(0, 32)
  //   }
  //   revert(0, 0)
  //
  // Compiled manually:
  //   PUSH4 d0c93a7c   // tickSpacing selector
  //   PUSH1 e0
  //   PUSH1 00
  //   CALLDATALOAD
  //   SHR
  //   EQ
  //   PUSH1 <tickSpacingLabel>
  //   JUMPI
  //   PUSH4 5339c296   // tickBitmap selector
  //   PUSH1 e0
  //   PUSH1 00
  //   CALLDATALOAD
  //   SHR
  //   EQ
  //   PUSH1 <tickBitmapLabel>
  //   JUMPI
  //   PUSH1 00 PUSH1 00 REVERT
  //
  //   <tickSpacingLabel>: JUMPDEST PUSH1 00 SLOAD PUSH1 00 MSTORE PUSH1 20 PUSH1 00 RETURN
  //   <tickBitmapLabel>: JUMPDEST PUSH1 04 CALLDATALOAD PUSH1 00 MSTORE PUSH1 01 PUSH1 20 MSTORE PUSH1 40 PUSH1 00 SHA3 SLOAD PUSH1 00 MSTORE PUSH1 20 PUSH1 00 RETURN

  // Let's compute the jump offsets:
  // Instruction stream:
  // 00: PUSH4 d0c93a7c    (5 bytes: 63 d0 c9 3a 7c)
  // 05: PUSH1 e0          (2 bytes: 60 e0)
  // 07: PUSH1 00          (2 bytes: 60 00)
  // 09: CALLDATALOAD      (1 byte:  35)
  // 10: SHR               (1 byte:  1c)
  // 11: EQ                (1 byte:  14)
  // 12: PUSH1 <tsLabel>   (2 bytes: 60 ??)
  // 14: JUMPI             (1 byte:  57)
  //
  // 15: PUSH4 5339c296    (5 bytes: 63 53 39 c2 96)
  // 20: PUSH1 e0          (2 bytes: 60 e0)
  // 22: PUSH1 00          (2 bytes: 60 00)
  // 24: CALLDATALOAD      (1 byte:  35)
  // 25: SHR               (1 byte:  1c)
  // 26: EQ                (1 byte:  14)
  // 27: PUSH1 <tbLabel>   (2 bytes: 60 ??)
  // 29: JUMPI             (1 byte:  57)
  //
  // 30: PUSH1 00          (2 bytes: 60 00)
  // 32: PUSH1 00          (2 bytes: 60 00)
  // 34: REVERT            (1 byte:  fd)
  //
  // tsLabel = 35:
  // 35: JUMPDEST          (1 byte:  5b)
  // 36: PUSH1 00          (2 bytes: 60 00)
  // 38: SLOAD             (1 byte:  54)
  // 39: PUSH1 00          (2 bytes: 60 00)
  // 41: MSTORE            (1 byte:  52)
  // 42: PUSH1 20          (2 bytes: 60 20)
  // 44: PUSH1 00          (2 bytes: 60 00)
  // 46: RETURN            (1 byte:  f3)
  //
  // tbLabel = 47:
  // 47: JUMPDEST          (1 byte:  5b)
  // 48: PUSH1 04          (2 bytes: 60 04)
  // 50: CALLDATALOAD      (1 byte:  35)
  // 51: PUSH1 00          (2 bytes: 60 00)
  // 53: MSTORE            (1 byte:  52)
  // 54: PUSH1 01          (2 bytes: 60 01)
  // 56: PUSH1 20          (2 bytes: 60 20)
  // 58: MSTORE            (1 byte:  52)
  // 59: PUSH1 40          (2 bytes: 60 40)
  // 61: PUSH1 00          (2 bytes: 60 00)
  // 63: SHA3              (1 byte:  20)
  // 64: SLOAD             (1 byte:  54)
  // 65: PUSH1 00          (2 bytes: 60 00)
  // 67: MSTORE            (1 byte:  52)
  // 68: PUSH1 20          (2 bytes: 60 20)
  // 70: PUSH1 00          (2 bytes: 60 00)
  // 72: RETURN            (1 byte:  f3)

  // Corrected instruction layout:
  // 00: PUSH1 00           (2 bytes)
  // 02: CALLDATALOAD       (1 byte)
  // 03: PUSH1 e0           (2 bytes)
  // 05: SHR                (1 byte)  → [selector]
  // 06: PUSH4 d0c93a7c     (5 bytes) → [selector, 0xd0c93a7c]
  // 11: EQ                 (1 byte)
  // 12: PUSH1 tsLabel(35)  (2 bytes)
  // 14: JUMPI              (1 byte)
  // 15: PUSH1 00           (2 bytes)
  // 17: CALLDATALOAD       (1 byte)
  // 18: PUSH1 e0           (2 bytes)
  // 20: SHR                (1 byte)
  // 21: PUSH4 5339c296     (5 bytes)
  // 26: EQ                 (1 byte)
  // 27: PUSH1 tbLabel(47)  (2 bytes)
  // 29: JUMPI              (1 byte)
  // 30: PUSH1 00           (2 bytes)
  // 32: PUSH1 00           (2 bytes)
  // 34: REVERT             (1 byte)
  // tsLabel=35: JUMPDEST  PUSH1 00  SLOAD  PUSH1 00  MSTORE  PUSH1 20  PUSH1 00  RETURN
  // tbLabel=47: JUMPDEST  PUSH1 04  CALLDATALOAD  PUSH1 00  MSTORE  PUSH1 01  PUSH1 20  MSTORE  PUSH1 40  PUSH1 00  SHA3  SLOAD  PUSH1 00  MSTORE  PUSH1 20  PUSH1 00  RETURN

  const tsLabel = 35
  const tbLabel = 47

  const runtimeBytecode =
    '6000' + // PUSH1 0x00
    '35' + // CALLDATALOAD
    '60e0' + // PUSH1 0xe0
    '1c' + // SHR
    '63d0c93a7c' + // PUSH4 d0c93a7c (tickSpacing selector)
    '14' + // EQ
    '60' +
    tsLabel.toString(16).padStart(2, '0') + // PUSH1 tsLabel=35=0x23
    '57' + // JUMPI
    '6000' + // PUSH1 0x00
    '35' + // CALLDATALOAD
    '60e0' + // PUSH1 0xe0
    '1c' + // SHR
    '635339c296' + // PUSH4 5339c296 (tickBitmap selector)
    '14' + // EQ
    '60' +
    tbLabel.toString(16).padStart(2, '0') + // PUSH1 tbLabel=47=0x2f
    '57' + // JUMPI
    '6000' + // PUSH1 0x00
    '6000' + // PUSH1 0x00
    'fd' + // REVERT
    '5b' + // JUMPDEST (tsLabel=35)
    '6000' + // PUSH1 0x00
    '54' + // SLOAD
    '6000' + // PUSH1 0x00
    '52' + // MSTORE
    '6020' + // PUSH1 0x20
    '6000' + // PUSH1 0x00
    'f3' + // RETURN
    '5b' + // JUMPDEST (tbLabel=47)
    '6004' + // PUSH1 0x04
    '35' + // CALLDATALOAD
    '6000' + // PUSH1 0x00
    '52' + // MSTORE
    '6001' + // PUSH1 0x01
    '6020' + // PUSH1 0x20
    '52' + // MSTORE
    '6040' + // PUSH1 0x40
    '6000' + // PUSH1 0x00
    '20' + // SHA3 (keccak256)
    '54' + // SLOAD
    '6000' + // PUSH1 0x00
    '52' + // MSTORE
    '6020' + // PUSH1 0x20
    '6000' + // PUSH1 0x00
    'f3' // RETURN

  // Use a deterministic address based on tickSpacing value
  const mockAddr = `0x${'1234' + tickSpacingValue.toString(16).padStart(36, '0')}`

  await provider.send('hardhat_setCode', [mockAddr, '0x' + runtimeBytecode])

  // Set tickSpacing in slot 0
  await provider.send('hardhat_setStorageAt', [
    mockAddr,
    '0x0000000000000000000000000000000000000000000000000000000000000000',
    '0x' + BigInt(tickSpacingValue).toString(16).padStart(64, '0'),
  ])

  // Set tickBitmap entries in their mapping slots
  const abiCoder = AbiCoder.defaultAbiCoder()
  for (const [key, value] of Object.entries(bitmapEntries)) {
    // Mapping slot = keccak256(abi.encode(key, 1))
    const encodedKey = abiCoder.encode(['int16', 'uint256'], [key, 1])
    const slot = keccak256(encodedKey)
    await provider.send('hardhat_setStorageAt', [mockAddr, slot, '0x' + value.toString(16).padStart(64, '0')])
  }

  return mockAddr
}

describe('PoolTicksCounter', () => {
  let ethers: EthersHelpers
  let networkHelpers: NetHelpers

  const TICK_SPACINGS = [200, 60, 10]

  before(async () => {
    const conn = await network.create()
    ethers = conn.ethers
    networkHelpers = conn.networkHelpers
  })

  TICK_SPACINGS.forEach((TICK_SPACING) => {
    let PoolTicksCounter: Contract
    let poolAddr: string

    // Bit index to tick
    const bitIdxToTick = (idx: number, page = 0) => {
      return idx * TICK_SPACING + page * 256 * TICK_SPACING
    }

    const setPool = async (bitmapEntries: Record<number, bigint>) => {
      poolAddr = await deployMockPool(ethers.provider, TICK_SPACING, bitmapEntries)
    }

    before(async () => {
      const poolTicksHelperFactory = await ethers.getContractFactory('PoolTicksCounterTest')
      PoolTicksCounter = (await poolTicksHelperFactory.deploy()) as unknown as Contract
    })

    describe(`[Tick Spacing: ${TICK_SPACING}]: tick after is bigger`, async () => {
      it('same tick initialized', async () => {
        await setPool({ 0: 0b1100n })
        const result = await PoolTicksCounter.countInitializedTicksCrossed(poolAddr, bitIdxToTick(2), bitIdxToTick(2))
        expect(result).to.be.eq(1)
      })

      it('same tick not-initialized', async () => {
        await setPool({ 0: 0b1100n })
        const result = await PoolTicksCounter.countInitializedTicksCrossed(poolAddr, bitIdxToTick(1), bitIdxToTick(1))
        expect(result).to.be.eq(0)
      })

      it('same page', async () => {
        await setPool({ 0: 0b1100n })
        const result = await PoolTicksCounter.countInitializedTicksCrossed(poolAddr, bitIdxToTick(0), bitIdxToTick(255))
        expect(result).to.be.eq(2)
      })

      it('multiple pages', async () => {
        await setPool({ 0: 0b1100n, 1: 0b1101n })
        const result = await PoolTicksCounter.countInitializedTicksCrossed(
          poolAddr,
          bitIdxToTick(0),
          bitIdxToTick(255, 1)
        )
        expect(result).to.be.eq(5)
      })

      it('counts all ticks in a page except ending tick', async () => {
        await setPool({ 0: 2n ** 256n - 1n, 1: 0x0n })
        const result = await PoolTicksCounter.countInitializedTicksCrossed(
          poolAddr,
          bitIdxToTick(0),
          bitIdxToTick(255, 1)
        )
        expect(result).to.be.eq(255)
      })

      it('counts ticks to left of start and right of end on same page', async () => {
        await setPool({ 0: 0b1111000100001111n })
        const result = await PoolTicksCounter.countInitializedTicksCrossed(poolAddr, bitIdxToTick(8), bitIdxToTick(255))
        expect(result).to.be.eq(4)
      })

      it('counts ticks to left of start and right of end across on multiple pages', async () => {
        await setPool({ 0: 0b1111000100001111n, 1: 0b1111000100001111n })
        const result = await PoolTicksCounter.countInitializedTicksCrossed(
          poolAddr,
          bitIdxToTick(8),
          bitIdxToTick(8, 1)
        )
        expect(result).to.be.eq(9)
      })

      it('counts ticks when before and after are initialized on same page', async () => {
        await setPool({ 0: 0b11111100n })
        const startingTickInit = await PoolTicksCounter.countInitializedTicksCrossed(
          poolAddr,
          bitIdxToTick(2),
          bitIdxToTick(255)
        )
        expect(startingTickInit).to.be.eq(5)
        const endingTickInit = await PoolTicksCounter.countInitializedTicksCrossed(
          poolAddr,
          bitIdxToTick(0),
          bitIdxToTick(3)
        )
        expect(endingTickInit).to.be.eq(2)
        const bothInit = await PoolTicksCounter.countInitializedTicksCrossed(poolAddr, bitIdxToTick(2), bitIdxToTick(5))
        expect(bothInit).to.be.eq(3)
      })

      it('counts ticks when before and after are initialized on multiple page', async () => {
        await setPool({ 0: 0b11111100n, 1: 0b11111100n })
        const startingTickInit = await PoolTicksCounter.countInitializedTicksCrossed(
          poolAddr,
          bitIdxToTick(2),
          bitIdxToTick(255)
        )
        expect(startingTickInit).to.be.eq(5)
        const endingTickInit = await PoolTicksCounter.countInitializedTicksCrossed(
          poolAddr,
          bitIdxToTick(0),
          bitIdxToTick(3, 1)
        )
        expect(endingTickInit).to.be.eq(8)
        const bothInit = await PoolTicksCounter.countInitializedTicksCrossed(
          poolAddr,
          bitIdxToTick(2),
          bitIdxToTick(5, 1)
        )
        expect(bothInit).to.be.eq(9)
      })

      it('counts ticks with lots of pages', async () => {
        await setPool({ 0: 0b11111100n, 1: 0b11111111n, 2: 0x0n, 3: 0x0n, 4: 0b11111100n })
        const bothInit = await PoolTicksCounter.countInitializedTicksCrossed(
          poolAddr,
          bitIdxToTick(4),
          bitIdxToTick(5, 4)
        )
        expect(bothInit).to.be.eq(15)
      })
    })

    describe(`[Tick Spacing: ${TICK_SPACING}]: tick after is smaller`, async () => {
      it('same page', async () => {
        await setPool({ 0: 0b1100n })
        const result = await PoolTicksCounter.countInitializedTicksCrossed(poolAddr, bitIdxToTick(255), bitIdxToTick(0))
        expect(result).to.be.eq(2)
      })

      it('multiple pages', async () => {
        await setPool({ 0: 0b1100n, [-1]: 0b1100n })
        const result = await PoolTicksCounter.countInitializedTicksCrossed(
          poolAddr,
          bitIdxToTick(255),
          bitIdxToTick(0, -1)
        )
        expect(result).to.be.eq(4)
      })

      it('counts all ticks in a page', async () => {
        await setPool({ 0: 2n ** 256n - 1n, [-1]: 0x0n })
        const result = await PoolTicksCounter.countInitializedTicksCrossed(
          poolAddr,
          bitIdxToTick(255),
          bitIdxToTick(0, -1)
        )
        expect(result).to.be.eq(256)
      })

      it('counts ticks to right of start and left of end on same page', async () => {
        await setPool({ 0: 0b1111000100001111n })
        const result = await PoolTicksCounter.countInitializedTicksCrossed(poolAddr, bitIdxToTick(15), bitIdxToTick(2))
        expect(result).to.be.eq(6)
      })

      it('counts ticks to right of start and left of end on multiple pages', async () => {
        await setPool({ 0: 0b1111000100001111n, [-1]: 0b1111000100001111n })
        const result = await PoolTicksCounter.countInitializedTicksCrossed(
          poolAddr,
          bitIdxToTick(8),
          bitIdxToTick(8, -1)
        )
        expect(result).to.be.eq(9)
      })

      it('counts ticks when before and after are initialized on same page', async () => {
        await setPool({ 0: 0b11111100n })
        const startingTickInit = await PoolTicksCounter.countInitializedTicksCrossed(
          poolAddr,
          bitIdxToTick(3),
          bitIdxToTick(0)
        )
        expect(startingTickInit).to.be.eq(2)
        const endingTickInit = await PoolTicksCounter.countInitializedTicksCrossed(
          poolAddr,
          bitIdxToTick(255),
          bitIdxToTick(2)
        )
        expect(endingTickInit).to.be.eq(5)
        const bothInit = await PoolTicksCounter.countInitializedTicksCrossed(poolAddr, bitIdxToTick(5), bitIdxToTick(2))
        expect(bothInit).to.be.eq(3)
      })

      it('counts ticks when before and after are initialized on multiple page', async () => {
        await setPool({ 0: 0b11111100n, [-1]: 0b11111100n })
        const startingTickInit = await PoolTicksCounter.countInitializedTicksCrossed(
          poolAddr,
          bitIdxToTick(2),
          bitIdxToTick(3, -1)
        )
        expect(startingTickInit).to.be.eq(5)
        const endingTickInit = await PoolTicksCounter.countInitializedTicksCrossed(
          poolAddr,
          bitIdxToTick(5),
          bitIdxToTick(255, -1)
        )
        expect(endingTickInit).to.be.eq(4)
        const bothInit = await PoolTicksCounter.countInitializedTicksCrossed(
          poolAddr,
          bitIdxToTick(2),
          bitIdxToTick(5, -1)
        )
        expect(bothInit).to.be.eq(3)
      })

      it('counts ticks with lots of pages', async () => {
        await setPool({ 0: 0b11111100n, [-1]: 0xffn, [-2]: 0x0n, [-3]: 0x0n, [-4]: 0b11111100n })
        const bothInit = await PoolTicksCounter.countInitializedTicksCrossed(
          poolAddr,
          bitIdxToTick(3),
          bitIdxToTick(6, -4)
        )
        expect(bothInit).to.be.eq(11)
      })
    })
  })
})
