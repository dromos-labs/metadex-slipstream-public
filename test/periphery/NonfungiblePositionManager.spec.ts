import { type BigNumberish, MaxUint256, ZeroAddress } from 'ethers'
import { network } from 'hardhat'
import type { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/signers'
import type {
  CustomUnstakedFeeModule,
  ICLFactory,
  IWETH9,
  MockTimeNonfungiblePositionManager,
  NonfungiblePositionManagerPositionsGasTest,
  SwapRouter,
  TestERC20,
  TestPositionNFTOwner,
} from '../../types/ethers-contracts'
import completeFixture from './shared/completeFixture'
import { computePoolAddress } from './shared/computePoolAddress'
import { FeeAmount, MaxUint128, TICK_SPACINGS } from './shared/constants'
import { encodePriceSqrt } from './shared/encodePriceSqrt'
import { expandTo18Decimals } from './shared/expandTo18Decimals'
import { expect } from './shared/expect'
import { extractJSONFromURI } from './shared/extractJSONFromURI'
import getPermitNFTSignature from './shared/getPermitNFTSignature'
import { encodePath } from './shared/path'
import snapshotGasCost from './shared/snapshotGasCost'
import { getMaxTick, getMinTick } from './shared/ticks'

describe('NonfungiblePositionManager', () => {
  let wallet: HardhatEthersSigner, other: HardhatEthersSigner

  let ethers: any
  let networkHelpers: any

  let factory: ICLFactory
  let nft: MockTimeNonfungiblePositionManager
  let tokens: [TestERC20, TestERC20, TestERC20]
  let weth9: IWETH9
  let router: SwapRouter

  before('create fixture loader', async () => {
    const conn = await network.create()
    ethers = conn.ethers
    networkHelpers = conn.networkHelpers
    ;[wallet, other] = await ethers.getSigners()
  })

  async function nftFixture() {
    const { weth9, factory, tokens, nft, router } = await completeFixture(ethers, wallet)

    const nftAddress = await nft.getAddress()
    // approve & fund wallets
    for (const token of tokens) {
      await token.approve(nftAddress, MaxUint256)
      await token.connect(other).approve(nftAddress, MaxUint256)
      await token.transfer(other.address, expandTo18Decimals(1_000_000))
    }

    return {
      nft,
      factory,
      tokens,
      weth9,
      router,
    }
  }

  beforeEach('load fixture', async () => {
    ;({ nft, factory, tokens, weth9, router } = await networkHelpers.loadFixture(nftFixture))
  })

  describe('#mint', () => {
    it('fails if cannot transfer', async () => {
      const token0Address = await tokens[0].getAddress()
      const token1Address = await tokens[1].getAddress()
      const nftAddress = await nft.getAddress()
      await nft.createPoolFromFactory(
        token0Address,
        token1Address,
        TICK_SPACINGS[FeeAmount.MEDIUM],
        encodePriceSqrt(1, 1)
      )
      await tokens[0].approve(nftAddress, 0)
      await expect(
        nft.mint({
          token0: token0Address,
          token1: token1Address,
          tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
          tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
          tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
          amount0Desired: 100,
          amount1Desired: 100,
          amount0Min: 0,
          amount1Min: 0,
          recipient: wallet.address,
          deadline: 1,
          sqrtPriceX96: 0,
        })
      ).to.be.revertedWith('STF')
    })

    it('creates a token', async () => {
      const token0Address = await tokens[0].getAddress()
      const token1Address = await tokens[1].getAddress()
      await nft.createPoolFromFactory(
        token0Address,
        token1Address,
        TICK_SPACINGS[FeeAmount.MEDIUM],
        encodePriceSqrt(1, 1)
      )

      await nft.mint({
        token0: token0Address,
        token1: token1Address,
        tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
        recipient: other.address,
        amount0Desired: 15,
        amount1Desired: 15,
        amount0Min: 0,
        amount1Min: 0,
        deadline: 10,
        sqrtPriceX96: 0,
      })
      expect(await nft.balanceOf(other.address)).to.eq(1)
      expect(await nft.tokenOfOwnerByIndex(other.address, 0)).to.eq(1)
      const {
        tickSpacing,
        token0,
        token1,
        tickLower,
        tickUpper,
        liquidity,
        tokensOwed0,
        tokensOwed1,
        feeGrowthInside0LastX128,
        feeGrowthInside1LastX128,
      } = await nft.positions(1)
      expect(token0).to.eq(token0Address)
      expect(token1).to.eq(token1Address)
      expect(tickSpacing).to.eq(TICK_SPACINGS[FeeAmount.MEDIUM])
      expect(tickLower).to.eq(getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]))
      expect(tickUpper).to.eq(getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]))
      expect(liquidity).to.eq(15)
      expect(tokensOwed0).to.eq(0)
      expect(tokensOwed1).to.eq(0)
      expect(feeGrowthInside0LastX128).to.eq(0)
      expect(feeGrowthInside1LastX128).to.eq(0)
    })

    it('can use eth', async () => {
      const weth9Address = await weth9.getAddress()
      const token0Address = await tokens[0].getAddress()
      const nftAddress = await nft.getAddress()

      // sort tokens
      const [tok0Addr, tok1Addr] =
        weth9Address.toLowerCase() < token0Address.toLowerCase()
          ? [weth9Address, token0Address]
          : [token0Address, weth9Address]

      // remove any approval
      await weth9.approve(nftAddress, 0)

      const balanceBefore = await ethers.provider.getBalance(wallet.address)
      const tx = await nft.mint(
        {
          token0: tok0Addr,
          token1: tok1Addr,
          tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
          tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
          tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
          recipient: other.address,
          amount0Desired: 100,
          amount1Desired: 100,
          amount0Min: 0,
          amount1Min: 0,
          deadline: 1,
          sqrtPriceX96: encodePriceSqrt(1, 1),
        },
        {
          value: expandTo18Decimals(1),
        }
      )
      const receipt = await tx.wait()
      const balanceAfter = await ethers.provider.getBalance(wallet.address)
      expect(balanceBefore).to.eq(balanceAfter + receipt!.gasUsed * receipt!.gasPrice + 100n)
    })

    it('emits an event')

    it('gas first mint for pool', async () => {
      const token0Address = await tokens[0].getAddress()
      const token1Address = await tokens[1].getAddress()
      await nft.createPoolFromFactory(
        token0Address,
        token1Address,
        TICK_SPACINGS[FeeAmount.MEDIUM],
        encodePriceSqrt(1, 1)
      )

      await snapshotGasCost(
        nft.mint({
          token0: token0Address,
          token1: token1Address,
          tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
          tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
          tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
          recipient: wallet.address,
          amount0Desired: 100,
          amount1Desired: 100,
          amount0Min: 0,
          amount1Min: 0,
          deadline: 10,
          sqrtPriceX96: 0,
        })
      )
    })

    it('gas first mint for pool using eth with zero refund', async () => {
      const weth9Address = await weth9.getAddress()
      const token0Address = await tokens[0].getAddress()
      const [tok0Addr, tok1Addr] =
        weth9Address.toLowerCase() < token0Address.toLowerCase()
          ? [weth9Address, token0Address]
          : [token0Address, weth9Address]
      await nft.createPoolFromFactory(tok0Addr, tok1Addr, TICK_SPACINGS[FeeAmount.MEDIUM], encodePriceSqrt(1, 1))

      await snapshotGasCost(
        nft.mint(
          {
            token0: tok0Addr,
            token1: tok1Addr,
            tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
            tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
            tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
            recipient: wallet.address,
            amount0Desired: 100,
            amount1Desired: 100,
            amount0Min: 0,
            amount1Min: 0,
            deadline: 10,
            sqrtPriceX96: 0,
          },
          { value: 100 }
        )
      )
    })

    it('gas first mint for pool using eth with non-zero refund', async () => {
      const weth9Address = await weth9.getAddress()
      const token0Address = await tokens[0].getAddress()
      const [tok0Addr, tok1Addr] =
        weth9Address.toLowerCase() < token0Address.toLowerCase()
          ? [weth9Address, token0Address]
          : [token0Address, weth9Address]
      await nft.createPoolFromFactory(tok0Addr, tok1Addr, TICK_SPACINGS[FeeAmount.MEDIUM], encodePriceSqrt(1, 1))

      await snapshotGasCost(
        nft.mint(
          {
            token0: tok0Addr,
            token1: tok1Addr,
            tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
            tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
            tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
            recipient: wallet.address,
            amount0Desired: 100,
            amount1Desired: 100,
            amount0Min: 0,
            amount1Min: 0,
            deadline: 10,
            sqrtPriceX96: 0,
          },
          { value: 1000 }
        )
      )
    })

    it('gas mint on same ticks', async () => {
      const token0Address = await tokens[0].getAddress()
      const token1Address = await tokens[1].getAddress()
      await nft.createPoolFromFactory(
        token0Address,
        token1Address,
        TICK_SPACINGS[FeeAmount.MEDIUM],
        encodePriceSqrt(1, 1)
      )

      await nft.mint({
        token0: token0Address,
        token1: token1Address,
        tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
        recipient: other.address,
        amount0Desired: 100,
        amount1Desired: 100,
        amount0Min: 0,
        amount1Min: 0,
        deadline: 10,
        sqrtPriceX96: 0,
      })

      await snapshotGasCost(
        nft.mint({
          token0: token0Address,
          token1: token1Address,
          tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
          tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
          tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
          recipient: wallet.address,
          amount0Desired: 100,
          amount1Desired: 100,
          amount0Min: 0,
          amount1Min: 0,
          deadline: 10,
          sqrtPriceX96: 0,
        })
      )
    })

    it('gas mint for same pool, different ticks', async () => {
      const token0Address = await tokens[0].getAddress()
      const token1Address = await tokens[1].getAddress()
      await nft.createPoolFromFactory(
        token0Address,
        token1Address,
        TICK_SPACINGS[FeeAmount.MEDIUM],
        encodePriceSqrt(1, 1)
      )

      await nft.mint({
        token0: token0Address,
        token1: token1Address,
        tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
        recipient: other.address,
        amount0Desired: 100,
        amount1Desired: 100,
        amount0Min: 0,
        amount1Min: 0,
        deadline: 10,
        sqrtPriceX96: 0,
      })

      await snapshotGasCost(
        nft.mint({
          token0: token0Address,
          token1: token1Address,
          tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]) + TICK_SPACINGS[FeeAmount.MEDIUM],
          tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]) - TICK_SPACINGS[FeeAmount.MEDIUM],
          tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
          recipient: wallet.address,
          amount0Desired: 100,
          amount1Desired: 100,
          amount0Min: 0,
          amount1Min: 0,
          deadline: 10,
          sqrtPriceX96: 0,
        })
      )
    })
  })

  describe('#increaseLiquidity', () => {
    const tokenId = 1
    beforeEach('create a position', async () => {
      const token0Address = await tokens[0].getAddress()
      const token1Address = await tokens[1].getAddress()
      await nft.createPoolFromFactory(
        token0Address,
        token1Address,
        TICK_SPACINGS[FeeAmount.MEDIUM],
        encodePriceSqrt(1, 1)
      )

      await nft.mint({
        token0: token0Address,
        token1: token1Address,
        tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
        recipient: other.address,
        amount0Desired: 1000,
        amount1Desired: 1000,
        amount0Min: 0,
        amount1Min: 0,
        deadline: 1,
        sqrtPriceX96: 0,
      })
    })

    it('increases position liquidity', async () => {
      await nft.increaseLiquidity({
        tokenId: tokenId,
        amount0Desired: 100,
        amount1Desired: 100,
        amount0Min: 0,
        amount1Min: 0,
        deadline: 1,
      })
      const { liquidity } = await nft.positions(tokenId)
      expect(liquidity).to.eq(1100)
    })

    it('emits an event')

    it('can be paid with ETH', async () => {
      const weth9Address = await weth9.getAddress()
      const token0Address = await tokens[0].getAddress()
      const nftAddress = await nft.getAddress()
      const [tok0Addr, tok1Addr] =
        token0Address.toLowerCase() < weth9Address.toLowerCase()
          ? [token0Address, weth9Address]
          : [weth9Address, token0Address]

      const tokenId = 1

      await nft.createPoolFromFactory(tok0Addr, tok1Addr, TICK_SPACINGS[FeeAmount.MEDIUM], encodePriceSqrt(1, 1))

      const mintData = nft.interface.encodeFunctionData('mint', [
        {
          token0: tok0Addr,
          token1: tok1Addr,
          tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
          tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
          tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
          recipient: other.address,
          amount0Desired: 100,
          amount1Desired: 100,
          amount0Min: 0,
          amount1Min: 0,
          deadline: 1,
          sqrtPriceX96: 0,
        },
      ])
      const refundETHData = nft.interface.encodeFunctionData('unwrapWETH9', [0, other.address])
      await nft.multicall([mintData, refundETHData], { value: expandTo18Decimals(1) })

      const increaseLiquidityData = nft.interface.encodeFunctionData('increaseLiquidity', [
        {
          tokenId: tokenId,
          amount0Desired: 100,
          amount1Desired: 100,
          amount0Min: 0,
          amount1Min: 0,
          deadline: 1,
        },
      ])
      await nft.multicall([increaseLiquidityData, refundETHData], { value: expandTo18Decimals(1) })
    })

    it('gas', async () => {
      await snapshotGasCost(
        nft.increaseLiquidity({
          tokenId: tokenId,
          amount0Desired: 100,
          amount1Desired: 100,
          amount0Min: 0,
          amount1Min: 0,
          deadline: 1,
        })
      )
    })
  })

  describe('#decreaseLiquidity', () => {
    const tokenId = 1
    beforeEach('create a position', async () => {
      const token0Address = await tokens[0].getAddress()
      const token1Address = await tokens[1].getAddress()
      await nft.createPoolFromFactory(
        token0Address,
        token1Address,
        TICK_SPACINGS[FeeAmount.MEDIUM],
        encodePriceSqrt(1, 1)
      )

      await nft.mint({
        token0: token0Address,
        token1: token1Address,
        tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
        recipient: other.address,
        amount0Desired: 100,
        amount1Desired: 100,
        amount0Min: 0,
        amount1Min: 0,
        deadline: 1,
        sqrtPriceX96: 0,
      })
    })

    it('emits an event')

    it('fails if past deadline', async () => {
      await nft.setTime(2)
      await expect(
        nft.connect(other).decreaseLiquidity({ tokenId, liquidity: 50, amount0Min: 0, amount1Min: 0, deadline: 1 })
      ).to.revert(ethers)
    })

    it('cannot be called by other addresses', async () => {
      await expect(
        nft.decreaseLiquidity({ tokenId, liquidity: 50, amount0Min: 0, amount1Min: 0, deadline: 1 })
      ).to.revert(ethers)
    })

    it('decreases position liquidity', async () => {
      await nft.connect(other).decreaseLiquidity({ tokenId, liquidity: 25, amount0Min: 0, amount1Min: 0, deadline: 1 })
      const { liquidity } = await nft.positions(tokenId)
      expect(liquidity).to.eq(75)
    })

    it('is payable', async () => {
      await nft
        .connect(other)
        .decreaseLiquidity({ tokenId, liquidity: 25, amount0Min: 0, amount1Min: 0, deadline: 1 }, { value: 1 })
    })

    it('accounts for tokens owed', async () => {
      await nft.connect(other).decreaseLiquidity({ tokenId, liquidity: 25, amount0Min: 0, amount1Min: 0, deadline: 1 })
      const { tokensOwed0, tokensOwed1 } = await nft.positions(tokenId)
      expect(tokensOwed0).to.eq(24)
      expect(tokensOwed1).to.eq(24)
    })

    it('can decrease for all the liquidity', async () => {
      await nft.connect(other).decreaseLiquidity({ tokenId, liquidity: 100, amount0Min: 0, amount1Min: 0, deadline: 1 })
      const { liquidity } = await nft.positions(tokenId)
      expect(liquidity).to.eq(0)
    })

    it('cannot decrease for more than all the liquidity', async () => {
      await expect(
        nft.connect(other).decreaseLiquidity({ tokenId, liquidity: 101, amount0Min: 0, amount1Min: 0, deadline: 1 })
      ).to.revert(ethers)
    })

    it('cannot decrease for more than the liquidity of the nft position', async () => {
      const token0Address = await tokens[0].getAddress()
      const token1Address = await tokens[1].getAddress()
      await nft.mint({
        token0: token0Address,
        token1: token1Address,
        tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
        recipient: other.address,
        amount0Desired: 200,
        amount1Desired: 200,
        amount0Min: 0,
        amount1Min: 0,
        deadline: 1,
        sqrtPriceX96: 0,
      })
      await expect(
        nft.connect(other).decreaseLiquidity({ tokenId, liquidity: 101, amount0Min: 0, amount1Min: 0, deadline: 1 })
      ).to.revert(ethers)
    })

    it('gas partial decrease', async () => {
      await snapshotGasCost(
        nft.connect(other).decreaseLiquidity({ tokenId, liquidity: 50, amount0Min: 0, amount1Min: 0, deadline: 1 })
      )
    })

    it('gas complete decrease', async () => {
      await snapshotGasCost(
        nft.connect(other).decreaseLiquidity({ tokenId, liquidity: 100, amount0Min: 0, amount1Min: 0, deadline: 1 })
      )
    })
  })

  describe('#collect', () => {
    const tokenId = 1
    beforeEach('create a position', async () => {
      const token0Address = await tokens[0].getAddress()
      const token1Address = await tokens[1].getAddress()
      await nft.createPoolFromFactory(
        token0Address,
        token1Address,
        TICK_SPACINGS[FeeAmount.MEDIUM],
        encodePriceSqrt(1, 1)
      )

      await nft.mint({
        token0: token0Address,
        token1: token1Address,
        tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
        tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        recipient: other.address,
        amount0Desired: 100,
        amount1Desired: 100,
        amount0Min: 0,
        amount1Min: 0,
        deadline: 1,
        sqrtPriceX96: 0,
      })
    })

    it('emits an event')

    it('cannot be called by other addresses', async () => {
      await expect(
        nft.collect({
          tokenId,
          recipient: wallet.address,
          amount0Max: MaxUint128,
          amount1Max: MaxUint128,
        })
      ).to.revert(ethers)
    })

    it('cannot be called with 0 for both amounts', async () => {
      await expect(
        nft.connect(other).collect({
          tokenId,
          recipient: wallet.address,
          amount0Max: 0,
          amount1Max: 0,
        })
      ).to.revert(ethers)
    })

    it('no op if no tokens are owed', async () => {
      await expect(
        nft.connect(other).collect({
          tokenId,
          recipient: wallet.address,
          amount0Max: MaxUint128,
          amount1Max: MaxUint128,
        })
      )
        .to.not.emit(tokens[0], 'Transfer')
        .to.not.emit(tokens[1], 'Transfer')
    })

    it('transfers tokens owed from burn', async () => {
      const token0Address = await tokens[0].getAddress()
      const token1Address = await tokens[1].getAddress()
      await nft.connect(other).decreaseLiquidity({ tokenId, liquidity: 50, amount0Min: 0, amount1Min: 0, deadline: 1 })
      const poolAddress = await computePoolAddress(
        await factory.getAddress(),
        [token0Address, token1Address],
        TICK_SPACINGS[FeeAmount.MEDIUM],
        factory
      )
      await expect(
        nft.connect(other).collect({
          tokenId,
          recipient: wallet.address,
          amount0Max: MaxUint128,
          amount1Max: MaxUint128,
        })
      )
        .to.emit(tokens[0], 'Transfer')
        .withArgs(poolAddress, wallet.address, 49)
        .to.emit(tokens[1], 'Transfer')
        .withArgs(poolAddress, wallet.address, 49)
    })

    it('gas transfers both', async () => {
      await nft.connect(other).decreaseLiquidity({ tokenId, liquidity: 50, amount0Min: 0, amount1Min: 0, deadline: 1 })
      await snapshotGasCost(
        nft.connect(other).collect({
          tokenId,
          recipient: wallet.address,
          amount0Max: MaxUint128,
          amount1Max: MaxUint128,
        })
      )
    })

    it('gas transfers token0 only', async () => {
      await nft.connect(other).decreaseLiquidity({ tokenId, liquidity: 50, amount0Min: 0, amount1Min: 0, deadline: 1 })
      await snapshotGasCost(
        nft.connect(other).collect({
          tokenId,
          recipient: wallet.address,
          amount0Max: MaxUint128,
          amount1Max: 0,
        })
      )
    })

    it('gas transfers token1 only', async () => {
      await nft.connect(other).decreaseLiquidity({ tokenId, liquidity: 50, amount0Min: 0, amount1Min: 0, deadline: 1 })
      await snapshotGasCost(
        nft.connect(other).collect({
          tokenId,
          recipient: wallet.address,
          amount0Max: 0,
          amount1Max: MaxUint128,
        })
      )
    })
  })

  describe('#burn', () => {
    const tokenId = 1
    beforeEach('create a position', async () => {
      const token0Address = await tokens[0].getAddress()
      const token1Address = await tokens[1].getAddress()
      await nft.createPoolFromFactory(
        token0Address,
        token1Address,
        TICK_SPACINGS[FeeAmount.MEDIUM],
        encodePriceSqrt(1, 1)
      )

      await nft.mint({
        token0: token0Address,
        token1: token1Address,
        tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
        tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        recipient: other.address,
        amount0Desired: 100,
        amount1Desired: 100,
        amount0Min: 0,
        amount1Min: 0,
        deadline: 1,
        sqrtPriceX96: 0,
      })
    })

    it('emits an event')

    it('cannot be called by other addresses', async () => {
      await expect(nft.burn(tokenId)).to.revert(ethers)
    })

    it('cannot be called while there is still liquidity', async () => {
      await expect(nft.connect(other).burn(tokenId)).to.be.revertedWith('NC')
    })

    it('cannot be called while there is still partial liquidity', async () => {
      await nft.connect(other).decreaseLiquidity({ tokenId, liquidity: 50, amount0Min: 0, amount1Min: 0, deadline: 1 })
      await expect(nft.connect(other).burn(tokenId)).to.be.revertedWith('NC')
    })

    it('cannot be called while there is still tokens owed', async () => {
      await nft.connect(other).decreaseLiquidity({ tokenId, liquidity: 100, amount0Min: 0, amount1Min: 0, deadline: 1 })
      await expect(nft.connect(other).burn(tokenId)).to.be.revertedWith('NC')
    })

    it('deletes the token', async () => {
      await nft.connect(other).decreaseLiquidity({ tokenId, liquidity: 100, amount0Min: 0, amount1Min: 0, deadline: 1 })
      await nft.connect(other).collect({
        tokenId,
        recipient: wallet.address,
        amount0Max: MaxUint128,
        amount1Max: MaxUint128,
      })
      await nft.connect(other).burn(tokenId)
      await expect(nft.positions(tokenId)).to.be.revertedWith('ID')
    })

    it('gas', async () => {
      await nft.connect(other).decreaseLiquidity({ tokenId, liquidity: 100, amount0Min: 0, amount1Min: 0, deadline: 1 })
      await nft.connect(other).collect({
        tokenId,
        recipient: wallet.address,
        amount0Max: MaxUint128,
        amount1Max: MaxUint128,
      })
      await snapshotGasCost(nft.connect(other).burn(tokenId))
    })
  })

  describe('#transferFrom', () => {
    const tokenId = 1
    beforeEach('create a position', async () => {
      const token0Address = await tokens[0].getAddress()
      const token1Address = await tokens[1].getAddress()
      await nft.createPoolFromFactory(
        token0Address,
        token1Address,
        TICK_SPACINGS[FeeAmount.MEDIUM],
        encodePriceSqrt(1, 1)
      )

      await nft.mint({
        token0: token0Address,
        token1: token1Address,
        tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
        tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        recipient: other.address,
        amount0Desired: 100,
        amount1Desired: 100,
        amount0Min: 0,
        amount1Min: 0,
        deadline: 1,
        sqrtPriceX96: 0,
      })
    })

    it('can only be called by authorized or owner', async () => {
      await expect(nft.transferFrom(other.address, wallet.address, tokenId)).to.be.revertedWith(
        'ERC721: transfer caller is not owner nor approved'
      )
    })

    it('changes the owner', async () => {
      await nft.connect(other).transferFrom(other.address, wallet.address, tokenId)
      expect(await nft.ownerOf(tokenId)).to.eq(wallet.address)
    })

    it('removes existing approval', async () => {
      await nft.connect(other).approve(wallet.address, tokenId)
      expect(await nft.getApproved(tokenId)).to.eq(wallet.address)
      await nft.transferFrom(other.address, wallet.address, tokenId)
      expect(await nft.getApproved(tokenId)).to.eq(ZeroAddress)
    })

    it('gas', async () => {
      await snapshotGasCost(nft.connect(other).transferFrom(other.address, wallet.address, tokenId))
    })

    it('gas comes from approved', async () => {
      await nft.connect(other).approve(wallet.address, tokenId)
      await snapshotGasCost(nft.transferFrom(other.address, wallet.address, tokenId))
    })
  })

  describe('#permit', () => {
    it('emits an event')

    describe('owned by eoa', () => {
      const tokenId = 1
      beforeEach('create a position', async () => {
        const token0Address = await tokens[0].getAddress()
        const token1Address = await tokens[1].getAddress()
        await nft.createPoolFromFactory(
          token0Address,
          token1Address,
          TICK_SPACINGS[FeeAmount.MEDIUM],
          encodePriceSqrt(1, 1)
        )

        await nft.mint({
          token0: token0Address,
          token1: token1Address,
          tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
          tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
          tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
          recipient: other.address,
          amount0Desired: 100,
          amount1Desired: 100,
          amount0Min: 0,
          amount1Min: 0,
          deadline: 1,
          sqrtPriceX96: 0,
        })
      })

      it('changes the operator of the position and increments the nonce', async () => {
        const { v, r, s } = await getPermitNFTSignature(other, nft, wallet.address, tokenId, 1)
        await nft.permit(wallet.address, tokenId, 1, v, r, s)
        expect((await nft.positions(tokenId)).nonce).to.eq(1)
        expect((await nft.positions(tokenId)).operator).to.eq(wallet.address)
      })

      it('cannot be called twice with the same signature', async () => {
        const { v, r, s } = await getPermitNFTSignature(other, nft, wallet.address, tokenId, 1)
        await nft.permit(wallet.address, tokenId, 1, v, r, s)
        await expect(nft.permit(wallet.address, tokenId, 1, v, r, s)).to.revert(ethers)
      })

      it('fails with invalid signature', async () => {
        const { v, r, s } = await getPermitNFTSignature(wallet, nft, wallet.address, tokenId, 1)
        await expect(nft.permit(wallet.address, tokenId, 1, v + 3, r, s)).to.be.revertedWith('IS')
      })

      it('fails with signature not from owner', async () => {
        const { v, r, s } = await getPermitNFTSignature(wallet, nft, wallet.address, tokenId, 1)
        await expect(nft.permit(wallet.address, tokenId, 1, v, r, s)).to.be.revertedWith('UA')
      })

      it('fails with expired signature', async () => {
        await nft.setTime(2)
        const { v, r, s } = await getPermitNFTSignature(other, nft, wallet.address, tokenId, 1)
        await expect(nft.permit(wallet.address, tokenId, 1, v, r, s)).to.be.revertedWith('PE')
      })

      it('gas', async () => {
        const { v, r, s } = await getPermitNFTSignature(other, nft, wallet.address, tokenId, 1)
        await snapshotGasCost(nft.permit(wallet.address, tokenId, 1, v, r, s))
      })
    })
    describe('owned by verifying contract', () => {
      const tokenId = 1
      let testPositionNFTOwner: TestPositionNFTOwner

      beforeEach('deploy test owner and create a position', async () => {
        testPositionNFTOwner = (await (
          await ethers.getContractFactory('TestPositionNFTOwner')
        ).deploy()) as TestPositionNFTOwner

        const token0Address = await tokens[0].getAddress()
        const token1Address = await tokens[1].getAddress()
        await nft.createPoolFromFactory(
          token0Address,
          token1Address,
          TICK_SPACINGS[FeeAmount.MEDIUM],
          encodePriceSqrt(1, 1)
        )

        await nft.mint({
          token0: token0Address,
          token1: token1Address,
          tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
          tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
          tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
          recipient: await testPositionNFTOwner.getAddress(),
          amount0Desired: 100,
          amount1Desired: 100,
          amount0Min: 0,
          amount1Min: 0,
          deadline: 1,
          sqrtPriceX96: 0,
        })
      })

      it('changes the operator of the position and increments the nonce', async () => {
        const { v, r, s } = await getPermitNFTSignature(other, nft, wallet.address, tokenId, 1)
        await testPositionNFTOwner.setOwner(other.address)
        await nft.permit(wallet.address, tokenId, 1, v, r, s)
        expect((await nft.positions(tokenId)).nonce).to.eq(1)
        expect((await nft.positions(tokenId)).operator).to.eq(wallet.address)
      })

      it('fails if owner contract is owned by different address', async () => {
        const { v, r, s } = await getPermitNFTSignature(other, nft, wallet.address, tokenId, 1)
        await testPositionNFTOwner.setOwner(wallet.address)
        await expect(nft.permit(wallet.address, tokenId, 1, v, r, s)).to.be.revertedWith('UA')
      })

      it('fails with signature not from owner', async () => {
        const { v, r, s } = await getPermitNFTSignature(wallet, nft, wallet.address, tokenId, 1)
        await testPositionNFTOwner.setOwner(other.address)
        await expect(nft.permit(wallet.address, tokenId, 1, v, r, s)).to.be.revertedWith('UA')
      })

      it('fails with expired signature', async () => {
        await nft.setTime(2)
        const { v, r, s } = await getPermitNFTSignature(other, nft, wallet.address, tokenId, 1)
        await testPositionNFTOwner.setOwner(other.address)
        await expect(nft.permit(wallet.address, tokenId, 1, v, r, s)).to.be.revertedWith('PE')
      })

      it('gas', async () => {
        const { v, r, s } = await getPermitNFTSignature(other, nft, wallet.address, tokenId, 1)
        await testPositionNFTOwner.setOwner(other.address)
        await snapshotGasCost(nft.permit(wallet.address, tokenId, 1, v, r, s))
      })
    })
  })

  describe('multicall exit', () => {
    const tokenId = 1
    beforeEach('create a position', async () => {
      const token0Address = await tokens[0].getAddress()
      const token1Address = await tokens[1].getAddress()
      await nft.createPoolFromFactory(
        token0Address,
        token1Address,
        TICK_SPACINGS[FeeAmount.MEDIUM],
        encodePriceSqrt(1, 1)
      )

      await nft.mint({
        token0: token0Address,
        token1: token1Address,
        tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
        tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        recipient: other.address,
        amount0Desired: 100,
        amount1Desired: 100,
        amount0Min: 0,
        amount1Min: 0,
        deadline: 1,
        sqrtPriceX96: 0,
      })
    })

    async function exit({
      nft,
      liquidity,
      tokenId,
      amount0Min,
      amount1Min,
      recipient,
    }: {
      nft: MockTimeNonfungiblePositionManager
      tokenId: BigNumberish
      liquidity: BigNumberish
      amount0Min: BigNumberish
      amount1Min: BigNumberish
      recipient: string
    }) {
      const decreaseLiquidityData = nft.interface.encodeFunctionData('decreaseLiquidity', [
        { tokenId, liquidity, amount0Min, amount1Min, deadline: 1 },
      ])
      const collectData = nft.interface.encodeFunctionData('collect', [
        {
          tokenId,
          recipient,
          amount0Max: MaxUint128,
          amount1Max: MaxUint128,
        },
      ])
      const burnData = nft.interface.encodeFunctionData('burn', [tokenId])

      return nft.multicall([decreaseLiquidityData, collectData, burnData])
    }

    it('executes all the actions', async () => {
      const token0Address = await tokens[0].getAddress()
      const token1Address = await tokens[1].getAddress()
      const poolAddress = await computePoolAddress(
        await factory.getAddress(),
        [token0Address, token1Address],
        TICK_SPACINGS[FeeAmount.MEDIUM],
        factory
      )
      const pool = await ethers.getContractAt('contracts/core/interfaces/ICLPool.sol:ICLPool', poolAddress, wallet)
      await expect(
        exit({
          nft: nft.connect(other),
          tokenId,
          liquidity: 100,
          amount0Min: 0,
          amount1Min: 0,
          recipient: wallet.address,
        })
      )
        .to.emit(pool, 'Burn')
        .to.emit(pool, 'Collect')
    })

    it('gas', async () => {
      await snapshotGasCost(
        exit({
          nft: nft.connect(other),
          tokenId,
          liquidity: 100,
          amount0Min: 0,
          amount1Min: 0,
          recipient: wallet.address,
        })
      )
    })
  })

  describe('#tokenURI', async () => {
    const tokenId = 1
    beforeEach('create a position', async () => {
      const token0Address = await tokens[0].getAddress()
      const token1Address = await tokens[1].getAddress()
      await nft.createPoolFromFactory(
        token0Address,
        token1Address,
        TICK_SPACINGS[FeeAmount.MEDIUM],
        encodePriceSqrt(1, 1)
      )

      await nft.mint({
        token0: token0Address,
        token1: token1Address,
        tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
        tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        recipient: other.address,
        amount0Desired: 100,
        amount1Desired: 100,
        amount0Min: 0,
        amount1Min: 0,
        deadline: 1,
        sqrtPriceX96: 0,
      })
    })

    it('reverts for invalid token id', async () => {
      await expect(nft.tokenURI(tokenId + 1)).to.revert(ethers)
    })

    it('returns a data URI with correct mime type', async () => {
      expect(await nft.tokenURI(tokenId)).to.match(/data:application\/json;base64,.+/)
    })

    it('content is valid JSON and structure', async () => {
      const content = extractJSONFromURI(await nft.tokenURI(tokenId))
      expect(content).to.haveOwnProperty('name').is.a('string')
      expect(content).to.haveOwnProperty('description').is.a('string')
      expect(content).to.haveOwnProperty('image').is.a('string')
    })
  })

  describe('fees accounting', () => {
    beforeEach('create two positions', async () => {
      const token0Address = await tokens[0].getAddress()
      const token1Address = await tokens[1].getAddress()
      await nft.createPoolFromFactory(
        token0Address,
        token1Address,
        TICK_SPACINGS[FeeAmount.MEDIUM],
        encodePriceSqrt(1, 1)
      )
      // nft 1 earns 25% of fees
      await nft.mint({
        token0: token0Address,
        token1: token1Address,
        tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
        tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        amount0Desired: 100,
        amount1Desired: 100,
        amount0Min: 0,
        amount1Min: 0,
        deadline: 1,
        recipient: wallet.address,
        sqrtPriceX96: 0,
      })
      // nft 2 earns 75% of fees
      await nft.mint({
        token0: token0Address,
        token1: token1Address,
        tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
        tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),

        amount0Desired: 300,
        amount1Desired: 300,
        amount0Min: 0,
        amount1Min: 0,
        deadline: 1,
        recipient: wallet.address,
        sqrtPriceX96: 0,
      })
      const poolAddress = await computePoolAddress(
        await factory.getAddress(),
        [token0Address, token1Address],
        TICK_SPACINGS[FeeAmount.MEDIUM],
        factory
      )
      const moduleAddress = await factory.unstakedFeeModule()
      const customUnstakedFeeModule = (await ethers.getContractAt(
        'CustomUnstakedFeeModule',
        moduleAddress,
        wallet
      )) as CustomUnstakedFeeModule
      await customUnstakedFeeModule.setCustomFee(poolAddress, 420)
    })

    describe('10k of token0 fees collect', () => {
      beforeEach('swap for ~10k of fees', async () => {
        const token0Address = await tokens[0].getAddress()
        const token1Address = await tokens[1].getAddress()
        const routerAddress = await router.getAddress()
        const swapAmount = 3_333_333
        await tokens[0].approve(routerAddress, swapAmount)
        await router.exactInput({
          recipient: wallet.address,
          deadline: 1,
          path: encodePath([token0Address, token1Address], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
          amountIn: swapAmount,
          amountOutMinimum: 0,
        })
      })
      it('expected amounts', async () => {
        const { amount0: nft1Amount0, amount1: nft1Amount1 } = await nft.collect.staticCall({
          tokenId: 1,
          recipient: wallet.address,
          amount0Max: MaxUint128,
          amount1Max: MaxUint128,
        })
        const { amount0: nft2Amount0, amount1: nft2Amount1 } = await nft.collect.staticCall({
          tokenId: 2,
          recipient: wallet.address,
          amount0Max: MaxUint128,
          amount1Max: MaxUint128,
        })
        expect(nft1Amount0).to.eq(2501)
        expect(nft1Amount1).to.eq(0)
        expect(nft2Amount0).to.eq(7503)
        expect(nft2Amount1).to.eq(0)
      })

      it('actually collected', async () => {
        const token0Address = await tokens[0].getAddress()
        const token1Address = await tokens[1].getAddress()
        const poolAddress = await computePoolAddress(
          await factory.getAddress(),
          [token0Address, token1Address],
          TICK_SPACINGS[FeeAmount.MEDIUM],
          factory
        )

        await expect(
          nft.collect({
            tokenId: 1,
            recipient: wallet.address,
            amount0Max: MaxUint128,
            amount1Max: MaxUint128,
          })
        )
          .to.emit(tokens[0], 'Transfer')
          .withArgs(poolAddress, wallet.address, 2501)
          .to.not.emit(tokens[1], 'Transfer')
        await expect(
          nft.collect({
            tokenId: 2,
            recipient: wallet.address,
            amount0Max: MaxUint128,
            amount1Max: MaxUint128,
          })
        )
          .to.emit(tokens[0], 'Transfer')
          .withArgs(poolAddress, wallet.address, 7503)
          .to.not.emit(tokens[1], 'Transfer')
      })
    })
  })

  describe('#positions', async () => {
    it('gas', async () => {
      const positionsGasTestFactory = await ethers.getContractFactory('NonfungiblePositionManagerPositionsGasTest')
      const positionsGasTest = (await positionsGasTestFactory.deploy(
        await nft.getAddress()
      )) as NonfungiblePositionManagerPositionsGasTest

      const token0Address = await tokens[0].getAddress()
      const token1Address = await tokens[1].getAddress()
      await nft.createPoolFromFactory(
        token0Address,
        token1Address,
        TICK_SPACINGS[FeeAmount.MEDIUM],
        encodePriceSqrt(1, 1)
      )

      await nft.mint({
        token0: token0Address,
        token1: token1Address,
        tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
        recipient: other.address,
        amount0Desired: 15,
        amount1Desired: 15,
        amount0Min: 0,
        amount1Min: 0,
        deadline: 10,
        sqrtPriceX96: 0,
      })

      await snapshotGasCost(positionsGasTest.getGasCostOfPositions(1))
    })
  })
})
