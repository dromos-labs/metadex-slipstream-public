import { MaxUint256, ZeroAddress } from 'ethers'
import { network } from 'hardhat'
import type { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/signers'
import type { ICLPool, IWETH9, MockTimeSwapRouter, TestERC20 } from '../../types/ethers-contracts'
import completeFixture from './shared/completeFixture'
import { FeeAmount, TICK_SPACINGS } from './shared/constants'
import { encodePriceSqrt } from './shared/encodePriceSqrt'
import { expandTo18Decimals } from './shared/expandTo18Decimals'
import { expect } from './shared/expect'
import { encodePath } from './shared/path'
import snapshotGasCost from './shared/snapshotGasCost'
import { getMaxTick, getMinTick } from './shared/ticks'

describe('SwapRouter gas tests', function () {
  this.timeout(40000)
  let wallet: HardhatEthersSigner
  let trader: HardhatEthersSigner

  let ethers: any
  let networkHelpers: any

  let weth9: IWETH9
  let router: MockTimeSwapRouter
  let tokens: [TestERC20, TestERC20, TestERC20]
  let pools: [ICLPool, ICLPool, ICLPool]

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

    const liquidity = 1000000
    async function createPool(tokenAddressA: string, tokenAddressB: string) {
      if (tokenAddressA.toLowerCase() > tokenAddressB.toLowerCase())
        [tokenAddressA, tokenAddressB] = [tokenAddressB, tokenAddressA]

      await nft.createPoolFromFactory(
        tokenAddressA,
        tokenAddressB,
        TICK_SPACINGS[FeeAmount.MEDIUM],
        encodePriceSqrt(100005, 100000) // we don't want to cross any ticks
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
      await weth9.deposit({ value: liquidity * 2 })
      await weth9.approve(await nft.getAddress(), MaxUint256)
      return createPool(await weth9.getAddress(), tokenAddress)
    }

    const weth9Address = await weth9.getAddress()
    const token0Address = await tokens[0].getAddress()
    const token1Address = await tokens[1].getAddress()
    const token2Address = await tokens[2].getAddress()

    // create pools
    await createPool(token0Address, token1Address)
    await createPool(token1Address, token2Address)
    await createPoolWETH9(token0Address)

    const poolAddresses = await Promise.all([
      factory['getPool(address,address,int24)'](token0Address, token1Address, TICK_SPACINGS[FeeAmount.MEDIUM]),
      factory['getPool(address,address,int24)'](token1Address, token2Address, TICK_SPACINGS[FeeAmount.MEDIUM]),
      factory['getPool(address,address,int24)'](weth9Address, token0Address, TICK_SPACINGS[FeeAmount.MEDIUM]),
    ])

    const pools = (await Promise.all(
      poolAddresses.map((poolAddress) =>
        ethers.getContractAt('contracts/core/interfaces/ICLPool.sol:ICLPool', poolAddress, wallet)
      )
    )) as [ICLPool, ICLPool, ICLPool]

    return {
      weth9,
      router,
      tokens,
      pools,
    }
  }

  beforeEach('load fixture', async () => {
    ;({ router, weth9, tokens, pools } = await networkHelpers.loadFixture(swapRouterFixture))
  })

  async function exactInput(tokens: string[], amountIn: number = 2, amountOutMinimum: number = 1) {
    const weth9Address = await weth9.getAddress()
    const inputIsWETH = weth9Address === tokens[0]
    const outputIsWETH9 = tokens[tokens.length - 1] === weth9Address

    const value = inputIsWETH ? amountIn : 0

    const params = {
      path: encodePath(tokens, new Array(tokens.length - 1).fill(TICK_SPACINGS[FeeAmount.MEDIUM])),
      recipient: outputIsWETH9 ? ZeroAddress : trader.address,
      deadline: 1,
      amountIn,
      amountOutMinimum: outputIsWETH9 ? 0 : amountOutMinimum, // save on calldata,
    }

    const data = [router.interface.encodeFunctionData('exactInput', [params])]
    if (outputIsWETH9) data.push(router.interface.encodeFunctionData('unwrapWETH9', [amountOutMinimum, trader.address]))

    // optimized for the gas test
    return data.length === 1
      ? router.connect(trader).exactInput(params, { value })
      : router.connect(trader).multicall(data, { value })
  }

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
      sqrtPriceLimitX96: sqrtPriceLimitX96 ?? 0,
      recipient: outputIsWETH9 ? ZeroAddress : trader.address,
      deadline: 1,
      amountIn,
      amountOutMinimum: outputIsWETH9 ? 0 : amountOutMinimum, // save on calldata
    }

    const data = [router.interface.encodeFunctionData('exactInputSingle', [params])]
    if (outputIsWETH9) data.push(router.interface.encodeFunctionData('unwrapWETH9', [amountOutMinimum, trader.address]))

    // optimized for the gas test
    return data.length === 1
      ? router.connect(trader).exactInputSingle(params, { value })
      : router.connect(trader).multicall(data, { value })
  }

  async function exactOutput(tokenList: string[]) {
    const amountInMaximum = 10 // we don't care
    const amountOut = 1

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
    if (inputIsWETH9) data.push(router.interface.encodeFunctionData('refundETH'))
    if (outputIsWETH9) data.push(router.interface.encodeFunctionData('unwrapWETH9', [amountOut, trader.address]))

    return router.connect(trader).multicall(data, { value })
  }

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
      sqrtPriceLimitX96: sqrtPriceLimitX96 ?? 0,
    }

    const data = [router.interface.encodeFunctionData('exactOutputSingle', [params])]
    if (inputIsWETH9) data.push(router.interface.encodeFunctionData('unwrapWETH9', [0, trader.address]))
    if (outputIsWETH9) data.push(router.interface.encodeFunctionData('unwrapWETH9', [amountOut, trader.address]))

    return router.connect(trader).multicall(data, { value })
  }

  // TODO should really throw this in the fixture
  beforeEach('intialize feeGrowthGlobals', async () => {
    const token0Address = await tokens[0].getAddress()
    const token1Address = await tokens[1].getAddress()
    const token2Address = await tokens[2].getAddress()
    const weth9Address = await weth9.getAddress()
    await exactInput([token0Address, token1Address], 1, 0)
    await exactInput([token1Address, token0Address], 1, 0)
    await exactInput([token1Address, token2Address], 1, 0)
    await exactInput([token2Address, token1Address], 1, 0)
    await exactInput([token0Address, weth9Address], 1, 0)
    await exactInput([weth9Address, token0Address], 1, 0)
  })

  beforeEach('ensure feeGrowthGlobals are >0', async () => {
    const slots = await Promise.all(
      pools.map((pool) =>
        Promise.all([
          pool.feeGrowthGlobal0X128().then((f) => f.toString()),
          pool.feeGrowthGlobal1X128().then((f) => f.toString()),
        ])
      )
    )

    expect(slots).to.deep.eq([
      ['340290874192793283295456993856614', '340290874192793283295456993856614'],
      ['340290874192793283295456993856614', '340290874192793283295456993856614'],
      ['340290874192793283295456993856614', '340290874192793283295456993856614'],
    ])
  })

  beforeEach('ensure ticks are 0 before', async () => {
    const slots = await Promise.all(pools.map((pool) => pool.slot0().then(({ tick }) => tick)))
    expect(slots).to.deep.eq([0, 0, 0])
  })

  afterEach('ensure ticks are 0 after', async () => {
    const slots = await Promise.all(pools.map((pool) => pool.slot0().then(({ tick }) => tick)))
    expect(slots).to.deep.eq([0, 0, 0])
  })

  describe('#exactInput', () => {
    it('0 -> 1', async () => {
      const token0Address = await tokens[0].getAddress()
      const token1Address = await tokens[1].getAddress()
      await snapshotGasCost(exactInput([token0Address, token1Address]))
    })

    it('0 -> 1 minimal', async () => {
      const calleeFactory = await ethers.getContractFactory('TestCLCallee')
      const callee = await calleeFactory.deploy()

      await tokens[0].connect(trader).approve(await callee.getAddress(), MaxUint256)
      await snapshotGasCost(
        callee.connect(trader).swapExact0For1(await pools[0].getAddress(), 2, trader.address, '4295128740')
      )
    })

    it('0 -> 1 -> 2', async () => {
      await snapshotGasCost(exactInput(await Promise.all(tokens.map((t) => t.getAddress())), 3))
    })

    it('WETH9 -> 0', async () => {
      const weth9Address = await weth9.getAddress()
      const token0Address = await tokens[0].getAddress()
      await snapshotGasCost(
        exactInput([weth9Address, token0Address], weth9Address.toLowerCase() < token0Address.toLowerCase() ? 2 : 3)
      )
    })

    it('0 -> WETH9', async () => {
      const weth9Address = await weth9.getAddress()
      const token0Address = await tokens[0].getAddress()
      await snapshotGasCost(
        exactInput([token0Address, weth9Address], token0Address.toLowerCase() < weth9Address.toLowerCase() ? 2 : 3)
      )
    })

    it('2 trades (via router)', async () => {
      const weth9Address = await weth9.getAddress()
      const token0Address = await tokens[0].getAddress()
      const token1Address = await tokens[1].getAddress()
      await weth9.connect(trader).deposit({ value: 3 })
      await weth9.connect(trader).approve(await router.getAddress(), MaxUint256)
      const swap0 = {
        path: encodePath([weth9Address, token0Address], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
        recipient: ZeroAddress,
        deadline: 1,
        amountIn: 3,
        amountOutMinimum: 0, // save on calldata
      }

      const swap1 = {
        path: encodePath([token1Address, token0Address], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
        recipient: ZeroAddress,
        deadline: 1,
        amountIn: 3,
        amountOutMinimum: 0, // save on calldata
      }

      const data = [
        router.interface.encodeFunctionData('exactInput', [swap0]),
        router.interface.encodeFunctionData('exactInput', [swap1]),
        router.interface.encodeFunctionData('sweepToken', [token0Address, 2, trader.address]),
      ]

      await snapshotGasCost(router.connect(trader).multicall(data))
    })

    it('3 trades (directly to sender)', async () => {
      const weth9Address = await weth9.getAddress()
      const token0Address = await tokens[0].getAddress()
      const token1Address = await tokens[1].getAddress()
      const token2Address = await tokens[2].getAddress()
      await weth9.connect(trader).deposit({ value: 3 })
      await weth9.connect(trader).approve(await router.getAddress(), MaxUint256)
      const swap0 = {
        path: encodePath([weth9Address, token0Address], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
        recipient: trader.address,
        deadline: 1,
        amountIn: 3,
        amountOutMinimum: 1,
      }

      const swap1 = {
        path: encodePath([token0Address, token1Address], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
        recipient: trader.address,
        deadline: 1,
        amountIn: 3,
        amountOutMinimum: 1,
      }

      const swap2 = {
        path: encodePath([token1Address, token2Address], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
        recipient: trader.address,
        deadline: 1,
        amountIn: 3,
        amountOutMinimum: 1,
      }

      const data = [
        router.interface.encodeFunctionData('exactInput', [swap0]),
        router.interface.encodeFunctionData('exactInput', [swap1]),
        router.interface.encodeFunctionData('exactInput', [swap2]),
      ]

      await snapshotGasCost(router.connect(trader).multicall(data))
    })
  })

  it('3 trades (directly to sender)', async () => {
    const weth9Address = await weth9.getAddress()
    const token0Address = await tokens[0].getAddress()
    const token1Address = await tokens[1].getAddress()
    await weth9.connect(trader).deposit({ value: 3 })
    await weth9.connect(trader).approve(await router.getAddress(), MaxUint256)
    const swap0 = {
      path: encodePath([weth9Address, token0Address], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
      recipient: trader.address,
      deadline: 1,
      amountIn: 3,
      amountOutMinimum: 1,
    }

    const swap1 = {
      path: encodePath([token1Address, token0Address], [TICK_SPACINGS[FeeAmount.MEDIUM]]),
      recipient: trader.address,
      deadline: 1,
      amountIn: 3,
      amountOutMinimum: 1,
    }

    const data = [
      router.interface.encodeFunctionData('exactInput', [swap0]),
      router.interface.encodeFunctionData('exactInput', [swap1]),
    ]

    await snapshotGasCost(router.connect(trader).multicall(data))
  })

  describe('#exactInputSingle', () => {
    it('0 -> 1', async () => {
      const token0Address = await tokens[0].getAddress()
      const token1Address = await tokens[1].getAddress()
      await snapshotGasCost(exactInputSingle(token0Address, token1Address))
    })

    it('WETH9 -> 0', async () => {
      const weth9Address = await weth9.getAddress()
      const token0Address = await tokens[0].getAddress()
      await snapshotGasCost(
        exactInputSingle(weth9Address, token0Address, weth9Address.toLowerCase() < token0Address.toLowerCase() ? 2 : 3)
      )
    })

    it('0 -> WETH9', async () => {
      const weth9Address = await weth9.getAddress()
      const token0Address = await tokens[0].getAddress()
      await snapshotGasCost(
        exactInputSingle(token0Address, weth9Address, token0Address.toLowerCase() < weth9Address.toLowerCase() ? 2 : 3)
      )
    })
  })

  describe('#exactOutput', () => {
    it('0 -> 1', async () => {
      const token0Address = await tokens[0].getAddress()
      const token1Address = await tokens[1].getAddress()
      await snapshotGasCost(exactOutput([token0Address, token1Address]))
    })

    it('0 -> 1 -> 2', async () => {
      await snapshotGasCost(exactOutput(await Promise.all(tokens.map((t) => t.getAddress()))))
    })

    it('WETH9 -> 0', async () => {
      const weth9Address = await weth9.getAddress()
      const token0Address = await tokens[0].getAddress()
      await snapshotGasCost(exactOutput([weth9Address, token0Address]))
    })

    it('0 -> WETH9', async () => {
      const weth9Address = await weth9.getAddress()
      const token0Address = await tokens[0].getAddress()
      await snapshotGasCost(exactOutput([token0Address, weth9Address]))
    })
  })

  describe('#exactOutputSingle', () => {
    it('0 -> 1', async () => {
      const token0Address = await tokens[0].getAddress()
      const token1Address = await tokens[1].getAddress()
      await snapshotGasCost(exactOutputSingle(token0Address, token1Address))
    })

    it('WETH9 -> 0', async () => {
      const weth9Address = await weth9.getAddress()
      const token0Address = await tokens[0].getAddress()
      await snapshotGasCost(exactOutputSingle(weth9Address, token0Address))
    })

    it('0 -> WETH9', async () => {
      const weth9Address = await weth9.getAddress()
      const token0Address = await tokens[0].getAddress()
      await snapshotGasCost(exactOutputSingle(token0Address, weth9Address))
    })
  })
})
