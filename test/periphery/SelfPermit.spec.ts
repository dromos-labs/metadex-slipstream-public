import { expect } from 'chai'
import { Contract, MaxUint256 } from 'ethers'
import { network } from 'hardhat'
import type { EthersHelpers, NetHelpers } from '../shared/network'
import type { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/types'

import { getPermitSignature } from './shared/permit'

describe('SelfPermit', () => {
  let ethers: EthersHelpers
  let networkHelpers: NetHelpers

  let wallet: HardhatEthersSigner
  let other: HardhatEthersSigner

  let token: Contract
  let tokenAddr: string
  let selfPermitTest: Contract
  let selfPermitTestAddr: string

  before(async () => {
    const conn = await network.create()
    ethers = conn.ethers
    networkHelpers = conn.networkHelpers
    ;[wallet, other] = await ethers.getSigners()
  })

  const deployFixture = async () => {
    const tokenFactory = await ethers.getContractFactory('TestERC20PermitAllowed')
    const token = (await tokenFactory.deploy(0)) as unknown as Contract

    const selfPermitTestFactory = await ethers.getContractFactory('SelfPermitTest')
    const selfPermitTest = (await selfPermitTestFactory.deploy()) as unknown as Contract

    return { token, selfPermitTest }
  }

  beforeEach('load fixture', async () => {
    ;({ token, selfPermitTest } = await networkHelpers.loadFixture(deployFixture))
    tokenAddr = await token.getAddress()
    selfPermitTestAddr = await selfPermitTest.getAddress()
  })

  it('#permit', async () => {
    const value = 123

    const { v, r, s } = await getPermitSignature(wallet, token, other.address, value)

    expect(await token.allowance(wallet.address, other.address)).to.eq(0)
    await token['permit(address,address,uint256,uint256,uint8,bytes32,bytes32)'](
      wallet.address,
      other.address,
      value,
      MaxUint256,
      v,
      r,
      s
    )
    expect(await token.allowance(wallet.address, other.address)).to.eq(value)
  })

  describe('#selfPermit', () => {
    const value = 456

    it('works', async () => {
      const { v, r, s } = await getPermitSignature(wallet, token, selfPermitTestAddr, value)

      expect(await token.allowance(wallet.address, selfPermitTestAddr)).to.eq(0)
      await selfPermitTest.selfPermit(tokenAddr, value, MaxUint256, v, r, s)
      expect(await token.allowance(wallet.address, selfPermitTestAddr)).to.eq(value)
    })

    it('fails if permit is submitted externally', async () => {
      const { v, r, s } = await getPermitSignature(wallet, token, selfPermitTestAddr, value)

      expect(await token.allowance(wallet.address, selfPermitTestAddr)).to.eq(0)
      await token['permit(address,address,uint256,uint256,uint8,bytes32,bytes32)'](
        wallet.address,
        selfPermitTestAddr,
        value,
        MaxUint256,
        v,
        r,
        s
      )
      expect(await token.allowance(wallet.address, selfPermitTestAddr)).to.eq(value)

      await expect(selfPermitTest.selfPermit(tokenAddr, value, MaxUint256, v, r, s)).to.be.revertedWith(
        'ERC20Permit: invalid signature'
      )
    })
  })

  describe('#selfPermitIfNecessary', () => {
    const value = 789

    it('works', async () => {
      const { v, r, s } = await getPermitSignature(wallet, token, selfPermitTestAddr, value)

      expect(await token.allowance(wallet.address, selfPermitTestAddr)).to.eq(0)
      await selfPermitTest.selfPermitIfNecessary(tokenAddr, value, MaxUint256, v, r, s)
      expect(await token.allowance(wallet.address, selfPermitTestAddr)).to.eq(value)
    })

    it('does not fail if permit is submitted externally', async () => {
      const { v, r, s } = await getPermitSignature(wallet, token, selfPermitTestAddr, value)

      expect(await token.allowance(wallet.address, selfPermitTestAddr)).to.eq(0)
      await token['permit(address,address,uint256,uint256,uint8,bytes32,bytes32)'](
        wallet.address,
        selfPermitTestAddr,
        value,
        MaxUint256,
        v,
        r,
        s
      )
      expect(await token.allowance(wallet.address, selfPermitTestAddr)).to.eq(value)

      await selfPermitTest.selfPermitIfNecessary(tokenAddr, value, MaxUint256, v, r, s)
    })
  })

  describe('#selfPermitAllowed', () => {
    it('works', async () => {
      const { v, r, s } = await getPermitSignature(wallet, token, selfPermitTestAddr, MaxUint256)

      expect(await token.allowance(wallet.address, selfPermitTestAddr)).to.eq(0)
      await expect(selfPermitTest.selfPermitAllowed(tokenAddr, 0, MaxUint256, v, r, s))
        .to.emit(token, 'Approval')
        .withArgs(wallet.address, selfPermitTestAddr, MaxUint256)
      expect(await token.allowance(wallet.address, selfPermitTestAddr)).to.eq(MaxUint256)
    })

    it('fails if permit is submitted externally', async () => {
      const { v, r, s } = await getPermitSignature(wallet, token, selfPermitTestAddr, MaxUint256)

      expect(await token.allowance(wallet.address, selfPermitTestAddr)).to.eq(0)
      await token['permit(address,address,uint256,uint256,bool,uint8,bytes32,bytes32)'](
        wallet.address,
        selfPermitTestAddr,
        0,
        MaxUint256,
        true,
        v,
        r,
        s
      )
      expect(await token.allowance(wallet.address, selfPermitTestAddr)).to.eq(MaxUint256)

      await expect(selfPermitTest.selfPermitAllowed(tokenAddr, 0, MaxUint256, v, r, s)).to.be.revertedWith(
        'TestERC20PermitAllowed::permit: wrong nonce'
      )
    })
  })

  describe('#selfPermitAllowedIfNecessary', () => {
    it('works', async () => {
      const { v, r, s } = await getPermitSignature(wallet, token, selfPermitTestAddr, MaxUint256)

      expect(await token.allowance(wallet.address, selfPermitTestAddr)).to.eq(0)
      await expect(selfPermitTest.selfPermitAllowedIfNecessary(tokenAddr, 0, MaxUint256, v, r, s))
        .to.emit(token, 'Approval')
        .withArgs(wallet.address, selfPermitTestAddr, MaxUint256)
      expect(await token.allowance(wallet.address, selfPermitTestAddr)).to.eq(MaxUint256)
    })

    it('skips if already max approved', async () => {
      const { v, r, s } = await getPermitSignature(wallet, token, selfPermitTestAddr, MaxUint256)

      expect(await token.allowance(wallet.address, selfPermitTestAddr)).to.eq(0)
      await token.approve(selfPermitTestAddr, MaxUint256)
      await expect(selfPermitTest.selfPermitAllowedIfNecessary(tokenAddr, 0, MaxUint256, v, r, s)).to.not.emit(
        token,
        'Approval'
      )
      expect(await token.allowance(wallet.address, selfPermitTestAddr)).to.eq(MaxUint256)
    })

    it('does not fail if permit is submitted externally', async () => {
      const { v, r, s } = await getPermitSignature(wallet, token, selfPermitTestAddr, MaxUint256)

      expect(await token.allowance(wallet.address, selfPermitTestAddr)).to.eq(0)
      await token['permit(address,address,uint256,uint256,bool,uint8,bytes32,bytes32)'](
        wallet.address,
        selfPermitTestAddr,
        0,
        MaxUint256,
        true,
        v,
        r,
        s
      )
      expect(await token.allowance(wallet.address, selfPermitTestAddr)).to.eq(MaxUint256)

      await selfPermitTest.selfPermitAllowedIfNecessary(tokenAddr, 0, MaxUint256, v, r, s)
    })
  })
})
