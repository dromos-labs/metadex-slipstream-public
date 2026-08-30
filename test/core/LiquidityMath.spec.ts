import { expect } from './shared/expect'
import { Contract } from 'ethers'
import { network } from 'hardhat'
import type { EthersHelpers, NetHelpers } from '../shared/network'
import snapshotGasCost from './shared/snapshotGasCost'

describe('LiquidityMath', () => {
  let ethers: EthersHelpers
  let networkHelpers: NetHelpers

  let liquidityMath: Contract

  before(async () => {
    const conn = await network.create()
    ethers = conn.ethers
    networkHelpers = conn.networkHelpers
  })

  const fixture = async () => {
    const factory = await ethers.getContractFactory('LiquidityMathTest')
    return (await factory.deploy()) as unknown as Contract
  }

  beforeEach('deploy LiquidityMathTest', async () => {
    liquidityMath = await networkHelpers.loadFixture(fixture)
  })

  describe('#addDelta', () => {
    it('1 + 0', async () => {
      expect(await liquidityMath.addDelta(1, 0)).to.eq(1)
    })
    it('1 + -1', async () => {
      expect(await liquidityMath.addDelta(1, -1)).to.eq(0)
    })
    it('1 + 1', async () => {
      expect(await liquidityMath.addDelta(1, 1)).to.eq(2)
    })
    it('2**128-15 + 15 overflows', async () => {
      await expect(liquidityMath.addDelta(2n ** 128n - 15n, 15)).to.be.revertedWith('LA')
    })
    it('0 + -1 underflows', async () => {
      await expect(liquidityMath.addDelta(0, -1)).to.be.revertedWith('LS')
    })
    it('3 + -4 underflows', async () => {
      await expect(liquidityMath.addDelta(3, -4)).to.be.revertedWith('LS')
    })
    it('gas add', async () => {
      await snapshotGasCost(liquidityMath.getGasCostOfAddDelta(15, 4))
    })
    it('gas sub', async () => {
      await snapshotGasCost(liquidityMath.getGasCostOfAddDelta(15, -4))
    })
  })
})
