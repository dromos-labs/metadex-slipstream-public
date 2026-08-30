import { Contract } from 'ethers'
import { network } from 'hardhat'
import type { EthersHelpers, NetHelpers } from '../shared/network'
import { expect } from './shared/expect'

import snapshotGasCost from './shared/snapshotGasCost'

describe('Multicall', async () => {
  let ethers: EthersHelpers
  let networkHelpers: NetHelpers

  let wallet: any
  let multicall: Contract

  before(async () => {
    const conn = await network.create()
    ethers = conn.ethers
    networkHelpers = conn.networkHelpers
    ;[wallet] = await ethers.getSigners()
  })

  const multicallFixture = async () => {
    const multicallTestFactory = await ethers.getContractFactory('TestMulticall')
    return (await multicallTestFactory.deploy()) as unknown as Contract
  }

  beforeEach('create multicall', async () => {
    multicall = await networkHelpers.loadFixture(multicallFixture)
  })

  it('revert messages are returned', async () => {
    await expect(
      multicall.multicall([multicall.interface.encodeFunctionData('functionThatRevertsWithError', ['abcdef'])])
    ).to.be.revertedWith('abcdef')
  })

  it('return data is properly encoded', async () => {
    const [data] = await multicall.multicall.staticCall([
      multicall.interface.encodeFunctionData('functionThatReturnsTuple', ['1', '2']),
    ])
    const {
      tuple: { a, b },
    } = multicall.interface.decodeFunctionResult('functionThatReturnsTuple', data)
    expect(b).to.eq(1)
    expect(a).to.eq(2)
  })

  describe('context is preserved', () => {
    it('msg.value', async () => {
      await multicall.multicall([multicall.interface.encodeFunctionData('pays')], { value: 3 })
      expect(await multicall.paid()).to.eq(3)
    })

    it('msg.value used twice', async () => {
      await multicall.multicall(
        [multicall.interface.encodeFunctionData('pays'), multicall.interface.encodeFunctionData('pays')],
        { value: 3 }
      )
      expect(await multicall.paid()).to.eq(6)
    })

    it('msg.sender', async () => {
      expect(await multicall.returnSender()).to.eq(wallet.address)
    })
  })

  it('gas cost of pay w/o multicall', async () => {
    await snapshotGasCost(multicall.pays({ value: 3 }))
  })

  it('gas cost of pay w/ multicall', async () => {
    await snapshotGasCost(multicall.multicall([multicall.interface.encodeFunctionData('pays')], { value: 3 }))
  })
})
