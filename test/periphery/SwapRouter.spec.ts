import { MaxUint256, ZeroAddress } from 'ethers'
import { network } from 'hardhat'
import type { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/signers'
import type {
  IWETH9,
  MockTimeNonfungiblePositionManager,
  MockTimeSwapRouter,
  TestERC20,
} from '../../types/ethers-contracts'
import completeFixture from './shared/completeFixture'
import { FeeAmount, TICK_SPACINGS } from './shared/constants'
import { encodePriceSqrt } from './shared/encodePriceSqrt'
import { expandTo18Decimals } from './shared/expandTo18Decimals'
import { expect } from './shared/expect'
import { encodePath } from './shared/path'
import { getMaxTick, getMinTick } from './shared/ticks'
import { computePoolAddress } from './shared/computePoolAddress'

describe('SwapRouter', function () {
  this.timeout(40000)
  let wallet: HardhatEthersSigner
  let trader: HardhatEthersSigner

  let ethers: any
  let networkHelpers: any

  let factory: any
  let weth9: IWETH9
  let router: MockTimeSwapRouter
  let nft: MockTimeNonfungiblePositionManager
  let tokens: [TestERC20, TestERC20, TestERC20]
  let getBalances: (who: string) => Promise<{
    weth9: bigint
    token0: bigint
    token1: bigint
    token2: bigint
  }>

  before('create fixture loader', async () => {
    const conn = await network.create()
    ethers = conn.ethers
    networkHelpers = conn.networkHelpers
    ;[wallet, trader] = await ethers.getSigners()
  })

  async function swapRouterFixture() {
    const { weth9, factory, router, tokens, nft } = await completeFixture(ethers, wallet)

    // approve & fund wallets
    for (const token of tokens) {
      await token.approve(await router.getAddress(), MaxUint256)
      await token.approve(await nft.getAddress(), MaxUint256)
      await token.connect(trader).approve(await router.getAddress(), MaxUint256)
      await token.transfer(trader.address, expandTo18Decimals(1_000_000))
    }

    return {
      weth9,
      factory,
      router,
      tokens,
      nft,
    }
  }

  // helper for getting weth and token balances
  beforeEach('load fixture', async () => {
    ;({ router, weth9, factory, tokens, nft } = await networkHelpers.loadFixture(swapRouterFixture))

    getBalances = async (who: string) => {
      const balances = await Promise.all([
        weth9.balanceOf(who),
        tokens[0].balanceOf(who),
        tokens[1].balanceOf(who),
        tokens[2].balanceOf(who),
      ])
      return {
        weth9: balances[0],
        token0: balances[1],
        token1: balances[2],
        token2: balances[3],
      }
    }
  })

  // ensure the swap router never ends up with a balance
  afterEach('load fixture', async () => {
    const routerAddress = await router.getAddress()
    const balances = await getBalances(routerAddress)
    expect(Object.values(balances).every((b) => b === 0n)).to.be.eq(true)
    const balance = await ethers.provider.getBalance(routerAddress)
    expect(balance === 0n).to.be.eq(true)
  })

  describe('swaps', () => {
    const liquidity = 1000000
    async function createPool(tokenAddressA: string, tokenAddressB: string) {
      if (tokenAddressA.toLowerCase() > tokenAddressB.toLowerCase())
        [tokenAddressA, tokenAddressB] = [tokenAddressB, tokenAddressA]

      await nft.createPoolFromFactory(
        tokenAddressA,
        tokenAddressB,
        TICK_SPACINGS[FeeAmount.MEDIUM],
        encodePriceSqrt(1, 1)
      )

      const liquidityParams = {
        token0: tokenAddressA,
        token1: tokenAddressB,
        tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
        tickLower: getMinTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
        tickUpper: getMaxTick(TICK_SPACINGS[FeeAmount.MEDIUM]),
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

    async function createPoolWETH9(tokenAddress: string) {
      await weth9.deposit({ value: liquidity })
      await weth9.approve(await nft.getAddress(), MaxUint256)
      return createPool(await weth9.getAddress(), tokenAddress)
    }

    beforeEach('create 0-1 and 1-2 pools', async () => {
      await createPool(await tokens[0].getAddress(), await tokens[1].getAddress())
      await createPool(await tokens[1].getAddress(), await tokens[2].getAddress())
    })

    describe('#exactInput', () => {
      async function exactInput(tokenList: string[], amountIn: number = 3, amountOutMinimum: number = 1) {
        const weth9Address = await weth9.getAddress()
        const inputIsWETH = weth9Address === tokenList[0]
        const outputIsWETH9 = tokenList[tokenList.length - 1] === weth9Address

        const value = inputIsWETH ? amountIn : 0

        const params = {
          path: encodePath(tokenList, new Array(tokenList.length - 1).fill(TICK_SPACINGS[FeeAmount.MEDIUM])),
          recipient: outputIsWETH9 ? ZeroAddress : trader.address,
          deadline: 1,
          amountIn,
          amountOutMinimum,
        }

        const data = [router.interface.encodeFunctionData('exactInput', [params])]
        if (outputIsWETH9)
          data.push(router.interface.encodeFunctionData('unwrapWETH9', [amountOutMinimum, trader.address]))

        // ensure that the swap fails if the limit is any tighter
        params.amountOutMinimum += 1
        await expect(router.connect(trader).exactInput(params, { value })).to.be.revertedWith('Too little received')
        params.amountOutMinimum -= 1

        // optimized for the gas test
        return data.length === 1
          ? router.connect(trader).exactInput(params, { value })
          : router.connect(trader).multicall(data, { value })
      }

      describe('single-pool', () => {
        it('0 -> 1', async () => {
          const token0Address = await tokens[0].getAddress()
          const token1Address = await tokens[1].getAddress()
          const pool = await factory['getPool(address,address,int24)'](
            token0Address,
            token1Address,
            TICK_SPACINGS[FeeAmount.MEDIUM]
          )

          // get balances before
          const poolBefore = await getBalances(pool)
          const traderBefore = await getBalances(trader.address)

          await exactInput([token0Address, token1Address])

          // get balances after
          const poolAfter = await getBalances(pool)
          const traderAfter = await getBalances(trader.address)

          expect(traderAfter.token0).to.be.eq(traderBefore.token0 - 3n)
          expect(traderAfter.token1).to.be.eq(traderBefore.token1 + 1n)
          expect(poolAfter.token0).to.be.eq(poolBefore.token0 + 3n)
          expect(poolAfter.token1).to.be.eq(poolBefore.token1 - 1n)
        })

        it('1 -> 0', async () => {
          const token0Address = await tokens[0].getAddress()
          const token1Address = await tokens[1].getAddress()
          const pool = await factory['getPool(address,address,int24)'](
            token1Address,
            token0Address,
            TICK_SPACINGS[FeeAmount.MEDIUM]
          )

          // get balances before
          const poolBefore = await getBalances(pool)
          const traderBefore = await getBalances(trader.address)

          await exactInput([token1Address, token0Address])

          // get balances after
          const poolAfter = await getBalances(pool)
          const traderAfter = await getBalances(trader.address)

          expect(traderAfter.token0).to.be.eq(traderBefore.token0 + 1n)
          expect(traderAfter.token1).to.be.eq(traderBefore.token1 - 3n)
          expect(poolAfter.token0).to.be.eq(poolBefore.token0 - 1n)
          expect(poolAfter.token1).to.be.eq(poolBefore.token1 + 3n)
        })
      })

      describe('multi-pool', () => {
        it('0 -> 1 -> 2', async () => {
          const traderBefore = await getBalances(trader.address)

          await exactInput(await Promise.all(tokens.map((t) => t.getAddress())), 5, 1)

          const traderAfter = await getBalances(trader.address)

          expect(traderAfter.token0).to.be.eq(traderBefore.token0 - 5n)
          expect(traderAfter.token2).to.be.eq(traderBefore.token2 + 1n)
        })

        it('2 -> 1 -> 0', async () => {
          const traderBefore = await getBalances(trader.address)

          await exactInput((await Promise.all(tokens.map((t) => t.getAddress()))).reverse(), 5, 1)

          const traderAfter = await getBalances(trader.address)

          expect(traderAfter.token2).to.be.eq(traderBefore.token2 - 5n)
          expect(traderAfter.token0).to.be.eq(traderBefore.token0 + 1n)
        })

        it('events', async () => {
          const token0Address = await tokens[0].getAddress()
          const token1Address = await tokens[1].getAddress()
          const token2Address = await tokens[2].getAddress()
          const factoryAddress = await factory.getAddress()
          const routerAddress = await router.getAddress()
          await expect(exactInput([token0Address, token1Address, token2Address], 5, 1))
            .to.emit(tokens[0], 'Transfer')
            .withArgs(
              trader.address,
              await computePoolAddress(
                factoryAddress,
                [token0Address, token1Address],
                TICK_SPACINGS[FeeAmount.MEDIUM],
                factory
              ),
              5
            )
            .to.emit(tokens[1], 'Transfer')
            .withArgs(
              await computePoolAddress(
                factoryAddress,
                [token0Address, token1Address],
                TICK_SPACINGS[FeeAmount.MEDIUM],
                factory
              ),
              routerAddress,
              3
            )
            .to.emit(tokens[1], 'Transfer')
            .withArgs(
              routerAddress,
              await computePoolAddress(
                factoryAddress,
                [token1Address, token2Address],
                TICK_SPACINGS[FeeAmount.MEDIUM],
                factory
              ),
              3
            )
            .to.emit(tokens[2], 'Transfer')
            .withArgs(
              await computePoolAddress(
                factoryAddress,
                [token1Address, token2Address],
                TICK_SPACINGS[FeeAmount.MEDIUM],
                factory
              ),
              trader.address,
              1
            )
        })
      })

      describe('ETH input', () => {
        describe('WETH9', () => {
          beforeEach(async () => {
            await createPoolWETH9(await tokens[0].getAddress())
          })

          it('WETH9 -> 0', async () => {
            const weth9Address = await weth9.getAddress()
            const token0Address = await tokens[0].getAddress()
            const pool = await factory['getPool(address,address,int24)'](
              weth9Address,
              token0Address,
              TICK_SPACINGS[FeeAmount.MEDIUM]
            )

            // get balances before
            const poolBefore = await getBalances(pool)
            const traderBefore = await getBalances(trader.address)

            await expect(exactInput([weth9Address, token0Address]))
              .to.emit(weth9, 'Deposit')
              .withArgs(await router.getAddress(), 3)

            // get balances after
            const poolAfter = await getBalances(pool)
            const traderAfter = await getBalances(trader.address)

            expect(traderAfter.token0).to.be.eq(traderBefore.token0 + 1n)
            expect(poolAfter.weth9).to.be.eq(poolBefore.weth9 + 3n)
            expect(poolAfter.token0).to.be.eq(poolBefore.token0 - 1n)
          })

          it('WETH9 -> 0 -> 1', async () => {
            const weth9Address = await weth9.getAddress()
            const token0Address = await tokens[0].getAddress()
            const token1Address = await tokens[1].getAddress()
            const traderBefore = await getBalances(trader.address)

            await expect(exactInput([weth9Address, token0Address, token1Address], 5))
              .to.emit(weth9, 'Deposit')
              .withArgs(await router.getAddress(), 5)

            const traderAfter = await getBalances(trader.address)

            expect(traderAfter.token1).to.be.eq(traderBefore.token1 + 1n)
          })
        })
      })

      describe('ETH output', () => {
        describe('WETH9', () => {
          beforeEach(async () => {
            await createPoolWETH9(await tokens[0].getAddress())
            await createPoolWETH9(await tokens[1].getAddress())
          })

          it('0 -> WETH9', async () => {
            const weth9Address = await weth9.getAddress()
            const token0Address = await tokens[0].getAddress()
            const pool = await factory['getPool(address,address,int24)'](
              token0Address,
              weth9Address,
              TICK_SPACINGS[FeeAmount.MEDIUM]
            )

            // get balances before
            const poolBefore = await getBalances(pool)
            const traderBefore = await getBalances(trader.address)

            await expect(exactInput([token0Address, weth9Address]))
              .to.emit(weth9, 'Withdrawal')
              .withArgs(await router.getAddress(), 1)

            // get balances after
            const poolAfter = await getBalances(pool)
            const traderAfter = await getBalances(trader.address)

            expect(traderAfter.token0).to.be.eq(traderBefore.token0 - 3n)
            expect(poolAfter.weth9).to.be.eq(poolBefore.weth9 - 1n)
            expect(poolAfter.token0).to.be.eq(poolBefore.token0 + 3n)
          })

          it('0 -> 1 -> WETH9', async () => {
            const weth9Address = await weth9.getAddress()
            const token0Address = await tokens[0].getAddress()
            const token1Address = await tokens[1].getAddress()
            // get balances before
            const traderBefore = await getBalances(trader.address)

            await expect(exactInput([token0Address, token1Address, weth9Address], 5))
              .to.emit(weth9, 'Withdrawal')
              .withArgs(await router.getAddress(), 1)

            // get balances after
            const traderAfter = await getBalances(trader.address)

            expect(traderAfter.token0).to.be.eq(traderBefore.token0 - 5n)
          })
        })
      })
    })

    describe('#exactInputSingle', () => {
      async function exactInputSingle(
        tokenIn: string,
        tokenOut: string,
        amountIn: number = 3,
        amountOutMinimum: number = 1,
        sqrtPriceLimitX96?: bigint
      ) {
        const weth9Address = await weth9.getAddress()
        const inputIsWETH = weth9Address === tokenIn
        const outputIsWETH9 = tokenOut === weth9Address

        const value = inputIsWETH ? amountIn : 0

        const params = {
          tokenIn,
          tokenOut,
          tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
          sqrtPriceLimitX96:
            sqrtPriceLimitX96 ??
            (tokenIn.toLowerCase() < tokenOut.toLowerCase()
              ? 4295128740n
              : 1461446703485210103287273052203988822378723970341n),
          recipient: outputIsWETH9 ? ZeroAddress : trader.address,
          deadline: 1,
          amountIn,
          amountOutMinimum,
        }

        const data = [router.interface.encodeFunctionData('exactInputSingle', [params])]
        if (outputIsWETH9)
          data.push(router.interface.encodeFunctionData('unwrapWETH9', [amountOutMinimum, trader.address]))

        // ensure that the swap fails if the limit is any tighter
        params.amountOutMinimum += 1
        await expect(router.connect(trader).exactInputSingle(params, { value })).to.be.revertedWith(
          'Too little received'
        )
        params.amountOutMinimum -= 1

        // optimized for the gas test
        return data.length === 1
          ? router.connect(trader).exactInputSingle(params, { value })
          : router.connect(trader).multicall(data, { value })
      }

      it('0 -> 1', async () => {
        const token0Address = await tokens[0].getAddress()
        const token1Address = await tokens[1].getAddress()
        const pool = await factory['getPool(address,address,int24)'](
          token0Address,
          token1Address,
          TICK_SPACINGS[FeeAmount.MEDIUM]
        )

        // get balances before
        const poolBefore = await getBalances(pool)
        const traderBefore = await getBalances(trader.address)

        await exactInputSingle(token0Address, token1Address)

        // get balances after
        const poolAfter = await getBalances(pool)
        const traderAfter = await getBalances(trader.address)

        expect(traderAfter.token0).to.be.eq(traderBefore.token0 - 3n)
        expect(traderAfter.token1).to.be.eq(traderBefore.token1 + 1n)
        expect(poolAfter.token0).to.be.eq(poolBefore.token0 + 3n)
        expect(poolAfter.token1).to.be.eq(poolBefore.token1 - 1n)
      })

      it('1 -> 0', async () => {
        const token0Address = await tokens[0].getAddress()
        const token1Address = await tokens[1].getAddress()
        const pool = await factory['getPool(address,address,int24)'](
          token1Address,
          token0Address,
          TICK_SPACINGS[FeeAmount.MEDIUM]
        )

        // get balances before
        const poolBefore = await getBalances(pool)
        const traderBefore = await getBalances(trader.address)

        await exactInputSingle(token1Address, token0Address)

        // get balances after
        const poolAfter = await getBalances(pool)
        const traderAfter = await getBalances(trader.address)

        expect(traderAfter.token0).to.be.eq(traderBefore.token0 + 1n)
        expect(traderAfter.token1).to.be.eq(traderBefore.token1 - 3n)
        expect(poolAfter.token0).to.be.eq(poolBefore.token0 - 1n)
        expect(poolAfter.token1).to.be.eq(poolBefore.token1 + 3n)
      })

      describe('ETH input', () => {
        describe('WETH9', () => {
          beforeEach(async () => {
            await createPoolWETH9(await tokens[0].getAddress())
          })

          it('WETH9 -> 0', async () => {
            const weth9Address = await weth9.getAddress()
            const token0Address = await tokens[0].getAddress()
            const pool = await factory['getPool(address,address,int24)'](
              weth9Address,
              token0Address,
              TICK_SPACINGS[FeeAmount.MEDIUM]
            )

            // get balances before
            const poolBefore = await getBalances(pool)
            const traderBefore = await getBalances(trader.address)

            await expect(exactInputSingle(weth9Address, token0Address))
              .to.emit(weth9, 'Deposit')
              .withArgs(await router.getAddress(), 3)

            // get balances after
            const poolAfter = await getBalances(pool)
            const traderAfter = await getBalances(trader.address)

            expect(traderAfter.token0).to.be.eq(traderBefore.token0 + 1n)
            expect(poolAfter.weth9).to.be.eq(poolBefore.weth9 + 3n)
            expect(poolAfter.token0).to.be.eq(poolBefore.token0 - 1n)
          })
        })
      })

      describe('ETH output', () => {
        describe('WETH9', () => {
          beforeEach(async () => {
            await createPoolWETH9(await tokens[0].getAddress())
            await createPoolWETH9(await tokens[1].getAddress())
          })

          it('0 -> WETH9', async () => {
            const weth9Address = await weth9.getAddress()
            const token0Address = await tokens[0].getAddress()
            const pool = await factory['getPool(address,address,int24)'](
              token0Address,
              weth9Address,
              TICK_SPACINGS[FeeAmount.MEDIUM]
            )

            // get balances before
            const poolBefore = await getBalances(pool)
            const traderBefore = await getBalances(trader.address)

            await expect(exactInputSingle(token0Address, weth9Address))
              .to.emit(weth9, 'Withdrawal')
              .withArgs(await router.getAddress(), 1)

            // get balances after
            const poolAfter = await getBalances(pool)
            const traderAfter = await getBalances(trader.address)

            expect(traderAfter.token0).to.be.eq(traderBefore.token0 - 3n)
            expect(poolAfter.weth9).to.be.eq(poolBefore.weth9 - 1n)
            expect(poolAfter.token0).to.be.eq(poolBefore.token0 + 3n)
          })
        })
      })
    })

    describe('#exactOutput', () => {
      async function exactOutput(tokenList: string[], amountOut: number = 1, amountInMaximum: number = 3) {
        const weth9Address = await weth9.getAddress()
        const inputIsWETH9 = tokenList[0] === weth9Address
        const outputIsWETH9 = tokenList[tokenList.length - 1] === weth9Address

        const value = inputIsWETH9 ? amountInMaximum : 0

        const params = {
          path: encodePath(
            tokenList.slice().reverse(),
            new Array(tokenList.length - 1).fill(TICK_SPACINGS[FeeAmount.MEDIUM])
          ),
          recipient: outputIsWETH9 ? ZeroAddress : trader.address,
          deadline: 1,
          amountOut,
          amountInMaximum,
        }

        const data = [router.interface.encodeFunctionData('exactOutput', [params])]
        if (inputIsWETH9) data.push(router.interface.encodeFunctionData('unwrapWETH9', [0, trader.address]))
        if (outputIsWETH9) data.push(router.interface.encodeFunctionData('unwrapWETH9', [amountOut, trader.address]))

        // ensure that the swap fails if the limit is any tighter
        params.amountInMaximum -= 1
        await expect(router.connect(trader).exactOutput(params, { value })).to.be.revertedWith('Too much requested')
        params.amountInMaximum += 1

        return router.connect(trader).multicall(data, { value })
      }

      describe('single-pool', () => {
        it('0 -> 1', async () => {
          const token0Address = await tokens[0].getAddress()
          const token1Address = await tokens[1].getAddress()
          const pool = await factory['getPool(address,address,int24)'](
            token0Address,
            token1Address,
            TICK_SPACINGS[FeeAmount.MEDIUM]
          )

          // get balances before
          const poolBefore = await getBalances(pool)
          const traderBefore = await getBalances(trader.address)

          await exactOutput([token0Address, token1Address])

          // get balances after
          const poolAfter = await getBalances(pool)
          const traderAfter = await getBalances(trader.address)

          expect(traderAfter.token0).to.be.eq(traderBefore.token0 - 3n)
          expect(traderAfter.token1).to.be.eq(traderBefore.token1 + 1n)
          expect(poolAfter.token0).to.be.eq(poolBefore.token0 + 3n)
          expect(poolAfter.token1).to.be.eq(poolBefore.token1 - 1n)
        })

        it('1 -> 0', async () => {
          const token0Address = await tokens[0].getAddress()
          const token1Address = await tokens[1].getAddress()
          const pool = await factory['getPool(address,address,int24)'](
            token1Address,
            token0Address,
            TICK_SPACINGS[FeeAmount.MEDIUM]
          )

          // get balances before
          const poolBefore = await getBalances(pool)
          const traderBefore = await getBalances(trader.address)

          await exactOutput([token1Address, token0Address])

          // get balances after
          const poolAfter = await getBalances(pool)
          const traderAfter = await getBalances(trader.address)

          expect(traderAfter.token0).to.be.eq(traderBefore.token0 + 1n)
          expect(traderAfter.token1).to.be.eq(traderBefore.token1 - 3n)
          expect(poolAfter.token0).to.be.eq(poolBefore.token0 - 1n)
          expect(poolAfter.token1).to.be.eq(poolBefore.token1 + 3n)
        })
      })

      describe('multi-pool', () => {
        it('0 -> 1 -> 2', async () => {
          const traderBefore = await getBalances(trader.address)

          await exactOutput(await Promise.all(tokens.map((t) => t.getAddress())), 1, 5)

          const traderAfter = await getBalances(trader.address)

          expect(traderAfter.token0).to.be.eq(traderBefore.token0 - 5n)
          expect(traderAfter.token2).to.be.eq(traderBefore.token2 + 1n)
        })

        it('2 -> 1 -> 0', async () => {
          const traderBefore = await getBalances(trader.address)

          await exactOutput((await Promise.all(tokens.map((t) => t.getAddress()))).reverse(), 1, 5)

          const traderAfter = await getBalances(trader.address)

          expect(traderAfter.token2).to.be.eq(traderBefore.token2 - 5n)
          expect(traderAfter.token0).to.be.eq(traderBefore.token0 + 1n)
        })

        it('events', async () => {
          const token0Address = await tokens[0].getAddress()
          const token1Address = await tokens[1].getAddress()
          const token2Address = await tokens[2].getAddress()
          const factoryAddress = await factory.getAddress()
          await expect(exactOutput([token0Address, token1Address, token2Address], 1, 5))
            .to.emit(tokens[2], 'Transfer')
            .withArgs(
              await computePoolAddress(
                factoryAddress,
                [token2Address, token1Address],
                TICK_SPACINGS[FeeAmount.MEDIUM],
                factory
              ),
              trader.address,
              1
            )
            .to.emit(tokens[1], 'Transfer')
            .withArgs(
              await computePoolAddress(
                factoryAddress,
                [token1Address, token0Address],
                TICK_SPACINGS[FeeAmount.MEDIUM],
                factory
              ),
              await computePoolAddress(
                factoryAddress,
                [token2Address, token1Address],
                TICK_SPACINGS[FeeAmount.MEDIUM],
                factory
              ),
              3
            )
            .to.emit(tokens[0], 'Transfer')
            .withArgs(
              trader.address,
              await computePoolAddress(
                factoryAddress,
                [token1Address, token0Address],
                TICK_SPACINGS[FeeAmount.MEDIUM],
                factory
              ),
              5
            )
        })
      })

      describe('ETH input', () => {
        describe('WETH9', () => {
          beforeEach(async () => {
            await createPoolWETH9(await tokens[0].getAddress())
          })

          it('WETH9 -> 0', async () => {
            const weth9Address = await weth9.getAddress()
            const token0Address = await tokens[0].getAddress()
            const pool = await factory['getPool(address,address,int24)'](
              weth9Address,
              token0Address,
              TICK_SPACINGS[FeeAmount.MEDIUM]
            )

            // get balances before
            const poolBefore = await getBalances(pool)
            const traderBefore = await getBalances(trader.address)

            await expect(exactOutput([weth9Address, token0Address]))
              .to.emit(weth9, 'Deposit')
              .withArgs(await router.getAddress(), 3)

            // get balances after
            const poolAfter = await getBalances(pool)
            const traderAfter = await getBalances(trader.address)

            expect(traderAfter.token0).to.be.eq(traderBefore.token0 + 1n)
            expect(poolAfter.weth9).to.be.eq(poolBefore.weth9 + 3n)
            expect(poolAfter.token0).to.be.eq(poolBefore.token0 - 1n)
          })

          it('WETH9 -> 0 -> 1', async () => {
            const weth9Address = await weth9.getAddress()
            const token0Address = await tokens[0].getAddress()
            const token1Address = await tokens[1].getAddress()
            const traderBefore = await getBalances(trader.address)

            await expect(exactOutput([weth9Address, token0Address, token1Address], 1, 5))
              .to.emit(weth9, 'Deposit')
              .withArgs(await router.getAddress(), 5)

            const traderAfter = await getBalances(trader.address)

            expect(traderAfter.token1).to.be.eq(traderBefore.token1 + 1n)
          })
        })
      })

      describe('ETH output', () => {
        describe('WETH9', () => {
          beforeEach(async () => {
            await createPoolWETH9(await tokens[0].getAddress())
            await createPoolWETH9(await tokens[1].getAddress())
          })

          it('0 -> WETH9', async () => {
            const weth9Address = await weth9.getAddress()
            const token0Address = await tokens[0].getAddress()
            const pool = await factory['getPool(address,address,int24)'](
              token0Address,
              weth9Address,
              TICK_SPACINGS[FeeAmount.MEDIUM]
            )

            // get balances before
            const poolBefore = await getBalances(pool)
            const traderBefore = await getBalances(trader.address)

            await expect(exactOutput([token0Address, weth9Address]))
              .to.emit(weth9, 'Withdrawal')
              .withArgs(await router.getAddress(), 1)

            // get balances after
            const poolAfter = await getBalances(pool)
            const traderAfter = await getBalances(trader.address)

            expect(traderAfter.token0).to.be.eq(traderBefore.token0 - 3n)
            expect(poolAfter.weth9).to.be.eq(poolBefore.weth9 - 1n)
            expect(poolAfter.token0).to.be.eq(poolBefore.token0 + 3n)
          })

          it('0 -> 1 -> WETH9', async () => {
            const weth9Address = await weth9.getAddress()
            const token0Address = await tokens[0].getAddress()
            const token1Address = await tokens[1].getAddress()
            // get balances before
            const traderBefore = await getBalances(trader.address)

            await expect(exactOutput([token0Address, token1Address, weth9Address], 1, 5))
              .to.emit(weth9, 'Withdrawal')
              .withArgs(await router.getAddress(), 1)

            // get balances after
            const traderAfter = await getBalances(trader.address)

            expect(traderAfter.token0).to.be.eq(traderBefore.token0 - 5n)
          })
        })
      })
    })

    describe('#exactOutputSingle', () => {
      async function exactOutputSingle(
        tokenIn: string,
        tokenOut: string,
        amountOut: number = 1,
        amountInMaximum: number = 3,
        sqrtPriceLimitX96?: bigint
      ) {
        const weth9Address = await weth9.getAddress()
        const inputIsWETH9 = tokenIn === weth9Address
        const outputIsWETH9 = tokenOut === weth9Address

        const value = inputIsWETH9 ? amountInMaximum : 0

        const params = {
          tokenIn,
          tokenOut,
          tickSpacing: TICK_SPACINGS[FeeAmount.MEDIUM],
          recipient: outputIsWETH9 ? ZeroAddress : trader.address,
          deadline: 1,
          amountOut,
          amountInMaximum,
          sqrtPriceLimitX96:
            sqrtPriceLimitX96 ??
            (tokenIn.toLowerCase() < tokenOut.toLowerCase()
              ? 4295128740n
              : 1461446703485210103287273052203988822378723970341n),
        }

        const data = [router.interface.encodeFunctionData('exactOutputSingle', [params])]
        if (inputIsWETH9) data.push(router.interface.encodeFunctionData('refundETH'))
        if (outputIsWETH9) data.push(router.interface.encodeFunctionData('unwrapWETH9', [amountOut, trader.address]))

        // ensure that the swap fails if the limit is any tighter
        params.amountInMaximum -= 1
        await expect(router.connect(trader).exactOutputSingle(params, { value })).to.be.revertedWith(
          'Too much requested'
        )
        params.amountInMaximum += 1

        return router.connect(trader).multicall(data, { value })
      }

      it('0 -> 1', async () => {
        const token0Address = await tokens[0].getAddress()
        const token1Address = await tokens[1].getAddress()
        const pool = await factory['getPool(address,address,int24)'](
          token0Address,
          token1Address,
          TICK_SPACINGS[FeeAmount.MEDIUM]
        )

        // get balances before
        const poolBefore = await getBalances(pool)
        const traderBefore = await getBalances(trader.address)

        await exactOutputSingle(token0Address, token1Address)

        // get balances after
        const poolAfter = await getBalances(pool)
        const traderAfter = await getBalances(trader.address)

        expect(traderAfter.token0).to.be.eq(traderBefore.token0 - 3n)
        expect(traderAfter.token1).to.be.eq(traderBefore.token1 + 1n)
        expect(poolAfter.token0).to.be.eq(poolBefore.token0 + 3n)
        expect(poolAfter.token1).to.be.eq(poolBefore.token1 - 1n)
      })

      it('1 -> 0', async () => {
        const token0Address = await tokens[0].getAddress()
        const token1Address = await tokens[1].getAddress()
        const pool = await factory['getPool(address,address,int24)'](
          token1Address,
          token0Address,
          TICK_SPACINGS[FeeAmount.MEDIUM]
        )

        // get balances before
        const poolBefore = await getBalances(pool)
        const traderBefore = await getBalances(trader.address)

        await exactOutputSingle(token1Address, token0Address)

        // get balances after
        const poolAfter = await getBalances(pool)
        const traderAfter = await getBalances(trader.address)

        expect(traderAfter.token0).to.be.eq(traderBefore.token0 + 1n)
        expect(traderAfter.token1).to.be.eq(traderBefore.token1 - 3n)
        expect(poolAfter.token0).to.be.eq(poolBefore.token0 - 1n)
        expect(poolAfter.token1).to.be.eq(poolBefore.token1 + 3n)
      })

      describe('ETH input', () => {
        describe('WETH9', () => {
          beforeEach(async () => {
            await createPoolWETH9(await tokens[0].getAddress())
          })

          it('WETH9 -> 0', async () => {
            const weth9Address = await weth9.getAddress()
            const token0Address = await tokens[0].getAddress()
            const pool = await factory['getPool(address,address,int24)'](
              weth9Address,
              token0Address,
              TICK_SPACINGS[FeeAmount.MEDIUM]
            )

            // get balances before
            const poolBefore = await getBalances(pool)
            const traderBefore = await getBalances(trader.address)

            await expect(exactOutputSingle(weth9Address, token0Address))
              .to.emit(weth9, 'Deposit')
              .withArgs(await router.getAddress(), 3)

            // get balances after
            const poolAfter = await getBalances(pool)
            const traderAfter = await getBalances(trader.address)

            expect(traderAfter.token0).to.be.eq(traderBefore.token0 + 1n)
            expect(poolAfter.weth9).to.be.eq(poolBefore.weth9 + 3n)
            expect(poolAfter.token0).to.be.eq(poolBefore.token0 - 1n)
          })
        })
      })

      describe('ETH output', () => {
        describe('WETH9', () => {
          beforeEach(async () => {
            await createPoolWETH9(await tokens[0].getAddress())
            await createPoolWETH9(await tokens[1].getAddress())
          })

          it('0 -> WETH9', async () => {
            const weth9Address = await weth9.getAddress()
            const token0Address = await tokens[0].getAddress()
            const pool = await factory['getPool(address,address,int24)'](
              token0Address,
              weth9Address,
              TICK_SPACINGS[FeeAmount.MEDIUM]
            )

            // get balances before
            const poolBefore = await getBalances(pool)
            const traderBefore = await getBalances(trader.address)

            await expect(exactOutputSingle(token0Address, weth9Address))
              .to.emit(weth9, 'Withdrawal')
              .withArgs(await router.getAddress(), 1)

            // get balances after
            const poolAfter = await getBalances(pool)
            const traderAfter = await getBalances(trader.address)

            expect(traderAfter.token0).to.be.eq(traderBefore.token0 - 3n)
            expect(poolAfter.weth9).to.be.eq(poolBefore.weth9 - 1n)
            expect(poolAfter.token0).to.be.eq(poolBefore.token0 + 3n)
          })
        })
      })
    })

    describe('*WithFee', () => {
      const feeRecipient = '0xfEE0000000000000000000000000000000000000'

      it('#sweepTokenWithFee', async () => {
        const token0Address = await tokens[0].getAddress()
        const token1Address = await tokens[1].getAddress()
        const amountOutMinimum = 100
        const params = {
          path: encodePath([token0Address, token1Address], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
          recipient: await router.getAddress(),
          deadline: 1,
          amountIn: 102,
          amountOutMinimum,
        }

        const data = [
          router.interface.encodeFunctionData('exactInput', [params]),
          router.interface.encodeFunctionData('sweepTokenWithFee', [
            token1Address,
            amountOutMinimum,
            trader.address,
            100,
            feeRecipient,
          ]),
        ]

        await router.connect(trader).multicall(data)

        const balance = await tokens[1].balanceOf(feeRecipient)
        expect(balance === 1n).to.be.eq(true)
      })

      it('#unwrapWETH9WithFee', async () => {
        const token0Address = await tokens[0].getAddress()
        const weth9Address = await weth9.getAddress()
        const startBalance = await ethers.provider.getBalance(feeRecipient)
        await createPoolWETH9(token0Address)

        const amountOutMinimum = 100
        const params = {
          path: encodePath([token0Address, weth9Address], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
          recipient: await router.getAddress(),
          deadline: 1,
          amountIn: 102,
          amountOutMinimum,
        }

        const data = [
          router.interface.encodeFunctionData('exactInput', [params]),
          router.interface.encodeFunctionData('unwrapWETH9WithFee', [
            amountOutMinimum,
            trader.address,
            100,
            feeRecipient,
          ]),
        ]

        await router.connect(trader).multicall(data)
        const endBalance = await ethers.provider.getBalance(feeRecipient)
        expect(endBalance - startBalance === 1n).to.be.eq(true)
      })
    })
  })
})
