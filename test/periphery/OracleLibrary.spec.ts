import { expect } from 'chai'
import { Contract, type BigNumberish } from 'ethers'
import { network } from 'hardhat'
import type { EthersHelpers, NetHelpers } from '../shared/network'
import { expandTo18Decimals } from './shared/expandTo18Decimals'
import snapshotGasCost from './shared/snapshotGasCost'

describe('OracleLibrary', () => {
  let ethers: EthersHelpers
  let networkHelpers: NetHelpers
  let tokens: Contract[]
  let oracle: Contract

  before(async () => {
    const conn = await network.create()
    ethers = conn.ethers
    networkHelpers = conn.networkHelpers
  })

  const OracleLibraryTestFixture = async () => {
    const tokenFactory = await ethers.getContractFactory('TestERC20')
    const tokens: [Contract, Contract, Contract] = [
      (await tokenFactory.deploy((2n ** 256n - 1n) / 2n)) as unknown as Contract,
      (await tokenFactory.deploy((2n ** 256n - 1n) / 2n)) as unknown as Contract,
      (await tokenFactory.deploy((2n ** 256n - 1n) / 2n)) as unknown as Contract,
    ]

    const addrs = await Promise.all(tokens.map((t) => t.getAddress()))
    const sorted = tokens
      .map((t, i) => ({ t, addr: addrs[i] }))
      .sort((a, b) => (a.addr.toLowerCase() < b.addr.toLowerCase() ? -1 : 1))
    tokens[0] = sorted[0].t
    tokens[1] = sorted[1].t
    tokens[2] = sorted[2].t

    const oracleFactory = await ethers.getContractFactory('OracleLibraryTest')
    const oracle = (await oracleFactory.deploy()) as unknown as Contract

    return {
      tokens: tokens as Contract[],
      oracle,
    }
  }

  beforeEach('deploy fixture', async () => {
    const fixtures = await networkHelpers.loadFixture(OracleLibraryTestFixture)
    tokens = fixtures['tokens']
    oracle = fixtures['oracle']
  })

  describe('#consult', () => {
    let mockObservableFactory: any

    before('create mockObservableFactory', async () => {
      mockObservableFactory = await ethers.getContractFactory('MockObservable')
    })

    it('reverts when period is 0', async () => {
      await expect(oracle.consult(await oracle.getAddress(), 0)).to.be.revertedWith('BP')
    })

    it('correct output when tick is 0', async () => {
      const period = 3
      const secondsPerLiqCumulatives: [BigNumberish, BigNumberish] = [10, 20]
      const mockObservable = await observableWith({
        period,
        tickCumulatives: [12, 12],
        secondsPerLiqCumulatives,
      })
      const { arithmeticMeanTick, harmonicMeanLiquidity } = await oracle.consult(
        await mockObservable.getAddress(),
        period
      )

      expect(arithmeticMeanTick).to.equal(0)
      expect(harmonicMeanLiquidity).to.equal(calculateHarmonicAvgLiq(period, secondsPerLiqCumulatives))
    })

    it('correct rounding for .5 negative tick', async () => {
      const period = 4

      const secondsPerLiqCumulatives: [BigNumberish, BigNumberish] = [10, 15]
      const mockObservable = await observableWith({
        period,
        tickCumulatives: [-10, -12],
        secondsPerLiqCumulatives,
      })

      const { arithmeticMeanTick, harmonicMeanLiquidity } = await oracle.consult(
        await mockObservable.getAddress(),
        period
      )

      // Always round to negative infinity
      // In this case, we need to subtract one because integer division rounds to 0
      expect(arithmeticMeanTick).to.equal(-1)
      expect(harmonicMeanLiquidity).to.equal(calculateHarmonicAvgLiq(period, secondsPerLiqCumulatives))
    })

    it('correct output for liquidity overflow', async () => {
      const period = 1

      const secondsPerLiqCumulatives: [BigNumberish, BigNumberish] = [10, 11]
      const mockObservable = await observableWith({
        period,
        tickCumulatives: [12, 12],
        secondsPerLiqCumulatives,
      })

      const { arithmeticMeanTick, harmonicMeanLiquidity } = await oracle.consult(
        await mockObservable.getAddress(),
        period
      )

      expect(arithmeticMeanTick).to.equal(0)
      // Make sure liquidity doesn't overflow uint128
      expect(harmonicMeanLiquidity).to.equal(2n ** 128n - 1n)
    })

    function calculateHarmonicAvgLiq(period: number, secondsPerLiqCumulatives: [BigNumberish, BigNumberish]) {
      const [secondsPerLiq0, secondsPerLiq1] = secondsPerLiqCumulatives.map(BigInt)
      const delta = secondsPerLiq1 - secondsPerLiq0

      const maxUint160 = 2n ** 160n - 1n
      return (maxUint160 * BigInt(period)) / (delta << 32n)
    }

    function observableWith({
      period,
      tickCumulatives,
      secondsPerLiqCumulatives,
    }: {
      period: number
      tickCumulatives: [BigNumberish, BigNumberish]
      secondsPerLiqCumulatives: [BigNumberish, BigNumberish]
    }) {
      return mockObservableFactory.deploy(
        [period, 0],
        tickCumulatives.map(BigInt),
        secondsPerLiqCumulatives.map(BigInt)
      )
    }
  })

  describe('#getQuoteAtTick', () => {
    // sanity check
    it('token0: returns correct value when tick = 0', async () => {
      const quoteAmount = await oracle.getQuoteAtTick(
        0,
        expandTo18Decimals(1),
        await tokens[0].getAddress(),
        await tokens[1].getAddress()
      )

      expect(quoteAmount).to.equal(expandTo18Decimals(1))
    })

    // sanity check
    it('token1: returns correct value when tick = 0', async () => {
      const quoteAmount = await oracle.getQuoteAtTick(
        0,
        expandTo18Decimals(1),
        await tokens[1].getAddress(),
        await tokens[0].getAddress()
      )

      expect(quoteAmount).to.equal(expandTo18Decimals(1))
    })

    it('token0: returns correct value when at min tick | 0 < sqrtRatioX96 <= type(uint128).max', async () => {
      const quoteAmount = await oracle.getQuoteAtTick(
        -887272,
        2n ** 128n - 1n,
        await tokens[0].getAddress(),
        await tokens[1].getAddress()
      )
      expect(quoteAmount).to.equal(1n)
    })

    it('token1: returns correct value when at min tick | 0 < sqrtRatioX96 <= type(uint128).max', async () => {
      const quoteAmount = await oracle.getQuoteAtTick(
        -887272,
        2n ** 128n - 1n,
        await tokens[1].getAddress(),
        await tokens[0].getAddress()
      )
      expect(quoteAmount).to.equal(115783384738768196242144082653949453838306988932806144552194799290216044976282n)
    })

    it('token0: returns correct value when at max tick | sqrtRatioX96 > type(uint128).max', async () => {
      const quoteAmount = await oracle.getQuoteAtTick(
        887272,
        2n ** 128n - 1n,
        await tokens[0].getAddress(),
        await tokens[1].getAddress()
      )
      expect(quoteAmount).to.equal(115783384785599357996676985412062652720342362943929506828539444553934033845703n)
    })

    it('token1: returns correct value when at max tick | sqrtRatioX96 > type(uint128).max', async () => {
      const quoteAmount = await oracle.getQuoteAtTick(
        887272,
        2n ** 128n - 1n,
        await tokens[1].getAddress(),
        await tokens[0].getAddress()
      )
      expect(quoteAmount).to.equal(1n)
    })

    it('gas test', async () => {
      await snapshotGasCost(
        oracle.getGasCostOfGetQuoteAtTick(
          10,
          expandTo18Decimals(1),
          await tokens[0].getAddress(),
          await tokens[1].getAddress()
        )
      )
    })
  })

  describe('#getOldestObservationSecondsAgo', () => {
    let mockObservationsFactory: any

    // some empty tick values as this function does not use them
    const emptySPL = [0, 0, 0, 0]
    const emptyTickCumulatives = [0, 0, 0, 0]
    const emptyTick = 0
    const emptyLiquidity = 0

    // helper function to run each test case identically
    const runOldestObservationsTest = async (
      blockTimestamps: number[],
      initializeds: boolean[],
      observationCardinality: number,
      observationIndex: number
    ) => {
      const mockObservations = await mockObservationsFactory.deploy(
        blockTimestamps,
        emptyTickCumulatives,
        emptySPL,
        initializeds,
        emptyTick,
        observationCardinality,
        observationIndex,
        false,
        emptyLiquidity
      )

      var result = await oracle.getOldestObservationSecondsAgo(await mockObservations.getAddress())

      //calculate seconds ago
      var secondsAgo
      if (initializeds[(observationIndex + 1) % observationCardinality]) {
        secondsAgo =
          Number(result['currentTimestamp']) - blockTimestamps[(observationIndex + 1) % observationCardinality]
      } else {
        secondsAgo = Number(result['currentTimestamp']) - blockTimestamps[0]
      }

      if (secondsAgo < 0) {
        secondsAgo += 2 ** 32
      }

      expect(result['secondsAgo']).to.equal(secondsAgo)
    }

    before('create mockObservationsFactory', async () => {
      mockObservationsFactory = await ethers.getContractFactory('MockObservations')
    })

    it('fetches the oldest timestamp from the slot after observationIndex', async () => {
      const blockTimestamps = [2, 3, 1, 0]
      const initializeds = [true, true, true, false]
      const observationCardinality = 3
      const observationIndex = 1

      await runOldestObservationsTest(blockTimestamps, initializeds, observationCardinality, observationIndex)
    })

    it('loops to fetches the oldest timestamp from index 0', async () => {
      const blockTimestamps = [1, 2, 3, 0]
      const initializeds = [true, true, true, false]
      const observationCardinality = 3
      const observationIndex = 2

      await runOldestObservationsTest(blockTimestamps, initializeds, observationCardinality, observationIndex)
    })

    it('fetches from index 0 if the next index is uninitialized', async () => {
      const blockTimestamps = [1, 2, 0, 0]
      const initializeds = [true, true, false, false]
      const observationCardinality = 4
      const observationIndex = 1

      await runOldestObservationsTest(blockTimestamps, initializeds, observationCardinality, observationIndex)
    })

    it('reverts if the pool is not initialized', async () => {
      const blockTimestamps = [0, 0, 0, 0]
      const initializeds = [false, false, false, false]
      const observationCardinality = 0
      const observationIndex = 0
      const mockObservations = await mockObservationsFactory.deploy(
        blockTimestamps,
        emptyTickCumulatives,
        emptySPL,
        initializeds,
        emptyTick,
        observationCardinality,
        observationIndex,
        false,
        emptyLiquidity
      )

      await expect(oracle.getOldestObservationSecondsAgo(await mockObservations.getAddress())).to.be.revertedWith('NI')
    })

    it('fetches the correct timestamp when the timestamps overflow', async () => {
      const maxUint32 = 2 ** 32 - 1
      const blockTimestamps = [maxUint32, 3, maxUint32 - 2, 0]
      const initializeds = [true, true, true, false]
      const observationCardinality = 3
      const observationIndex = 1

      await runOldestObservationsTest(blockTimestamps, initializeds, observationCardinality, observationIndex)
    })
  })

  describe('#getBlockStartingTickAndLiquidity', () => {
    let mockObservationsFactory: any
    let mockObservations: Contract
    let blockTimestamps: number[]
    let tickCumulatives: number[]
    let liquidityValues: bigint[]
    let initializeds: boolean[]
    let slot0Tick: number
    let observationCardinality: number
    let observationIndex: number
    let lastObservationCurrentTimestamp: boolean
    let liquidity: number

    before('create mockObservationsFactory', async () => {
      mockObservationsFactory = await ethers.getContractFactory('MockObservations')
    })

    const deployMockObservationsContract = async () => {
      mockObservations = (await mockObservationsFactory.deploy(
        blockTimestamps,
        tickCumulatives,
        liquidityValues,
        initializeds,
        slot0Tick,
        observationCardinality,
        observationIndex,
        lastObservationCurrentTimestamp,
        liquidity
      )) as unknown as Contract
    }

    it('reverts if the pool is not initialized', async () => {
      blockTimestamps = [0, 0, 0, 0]
      tickCumulatives = [0, 0, 0, 0]
      liquidityValues = [0n, 0n, 0n, 0n]
      initializeds = [false, false, false, false]
      slot0Tick = 0
      observationCardinality = 0
      observationIndex = 0
      lastObservationCurrentTimestamp = false
      liquidity = 0

      await deployMockObservationsContract()

      await expect(oracle.getBlockStartingTickAndLiquidity(await mockObservations.getAddress())).to.be.revertedWith(
        'NEO'
      )
    })

    it('returns the tick and liquidity in storage if the latest observation was in a previous block', async () => {
      blockTimestamps = [1, 3, 4, 0]
      // 0
      // 8: 0 + (4*(3-1))
      // 13: 8 + (5*(4-3))
      tickCumulatives = [0, 8, 13, 0]
      // 0
      // (1): 0 + ((3-1)*2**128)/5000
      // (1) + ((4-3)*2**128)/7000
      liquidityValues = [0n, 136112946768375385385349842972707284n, 184724713471366594451546215462959885n, 0n]
      initializeds = [true, true, true, false]
      observationCardinality = 3
      observationIndex = 2
      slot0Tick = 6
      lastObservationCurrentTimestamp = false
      liquidity = 10000

      await deployMockObservationsContract()

      var result = await oracle.getBlockStartingTickAndLiquidity(await mockObservations.getAddress())
      expect(result[0]).to.equal(slot0Tick)
      expect(result[1]).to.equal(liquidity)
    })

    it('reverts if it needs 2 observations and doesnt have them', async () => {
      blockTimestamps = [1, 0, 0, 0]
      tickCumulatives = [8, 0, 0, 0]
      liquidityValues = [136112946768375385385349842972707284n, 0n, 0n, 0n]
      initializeds = [true, false, false, false]
      observationCardinality = 1
      observationIndex = 0
      slot0Tick = 4
      lastObservationCurrentTimestamp = true
      liquidity = 10000

      await deployMockObservationsContract()

      await expect(oracle.getBlockStartingTickAndLiquidity(await mockObservations.getAddress())).to.be.revertedWith(
        'NEO'
      )
    })

    it('reverts if the prior observation needed is not initialized', async () => {
      blockTimestamps = [1, 0, 0, 0]
      observationCardinality = 2
      observationIndex = 0
      liquidityValues = [136112946768375385385349842972707284n, 0n, 0n, 0n]
      initializeds = [true, false, false, false]
      tickCumulatives = [8, 0, 0, 0]
      slot0Tick = 4
      lastObservationCurrentTimestamp = true
      liquidity = 10000

      await deployMockObservationsContract()

      await expect(oracle.getBlockStartingTickAndLiquidity(await mockObservations.getAddress())).to.be.revertedWith(
        'ONI'
      )
    })

    it('calculates the prior tick and liquidity from the prior observations', async () => {
      blockTimestamps = [9, 5, 8, 0]
      observationCardinality = 3
      observationIndex = 0
      initializeds = [true, true, true, false]
      // 99: 95 + (4*1)
      // 80: 72 + (4*2)
      // 95: 80 + (5*3)
      tickCumulatives = [99, 80, 95, 0]
      // prev: 784724713471366594451546215462959885
      // (3): (2) + (1*2**128)/13212
      // (1): prev + (2*2**128)/12345
      // (2): (1) + (3*2**128)/10238
      liquidityValues = [
        965320616647837491242414421221086683n,
        839853488995212437053956034406948254n,
        939565063595995342933046073701273770n,
        0n,
      ]
      slot0Tick = 3
      lastObservationCurrentTimestamp = true
      liquidity = 10000

      await deployMockObservationsContract()

      var result = await oracle.getBlockStartingTickAndLiquidity(await mockObservations.getAddress())

      var actualStartingTick = (tickCumulatives[0] - tickCumulatives[2]) / (blockTimestamps[0] - blockTimestamps[2])
      expect(result[0]).to.equal(actualStartingTick)

      var actualStartingLiquidity = 13212 // see comments above
      expect(result[1]).to.equal(actualStartingLiquidity)
    })
  })

  describe('#getWeightedArithmeticMeanTick', () => {
    it('single observation returns average tick', async () => {
      const observation = { tick: 10, weight: 10 }

      const oracleTick = await oracle.getWeightedArithmeticMeanTick([observation])

      expect(oracleTick).to.equal(10)
    })

    it('multiple observations with same weight result in average across tiers', async () => {
      const observation1 = { tick: 10, weight: 10 }
      const observation2 = { tick: 20, weight: 10 }

      const oracleTick = await oracle.getWeightedArithmeticMeanTick([observation1, observation2])

      expect(oracleTick).to.equal(15)
    })

    it('multiple observations with different weights are weighted correctly', async () => {
      const observation2 = { tick: 20, weight: 15 }
      const observation1 = { tick: 10, weight: 10 }

      const oracleTick = await oracle.getWeightedArithmeticMeanTick([observation1, observation2])

      expect(oracleTick).to.equal(16)
    })

    it('correct rounding for .5 negative tick', async () => {
      const observation1 = { tick: -10, weight: 10 }
      const observation2 = { tick: -11, weight: 10 }

      const oracleTick = await oracle.getWeightedArithmeticMeanTick([observation1, observation2])

      expect(oracleTick).to.equal(-11)
    })
  })
  describe('#getChainedPrice', () => {
    let ticks: number[]

    it('fails with discrepant length', async () => {
      const tokenAddresses = [await tokens[0].getAddress(), await tokens[2].getAddress()]
      ticks = [5, 5]

      expect(oracle.getChainedPrice(tokenAddresses, ticks)).to.be.revertedWith('DL')
    })
    it('add two positive ticks, sorted order', async () => {
      const tokenAddresses = [await tokens[0].getAddress(), await tokens[1].getAddress(), await tokens[2].getAddress()]
      ticks = [5, 5]
      const oracleTick = await oracle.getChainedPrice(tokenAddresses, ticks)

      expect(oracleTick).to.equal(10)
    })
    it('add one positive and one negative tick, sorted order', async () => {
      const tokenAddresses = [await tokens[0].getAddress(), await tokens[1].getAddress(), await tokens[2].getAddress()]
      ticks = [5, -5]
      const oracleTick = await oracle.getChainedPrice(tokenAddresses, ticks)

      expect(oracleTick).to.equal(0)
    })
    it('add one negative and one positive tick, sorted order', async () => {
      const tokenAddresses = [await tokens[0].getAddress(), await tokens[1].getAddress(), await tokens[2].getAddress()]
      ticks = [-5, 5]
      const oracleTick = await oracle.getChainedPrice(tokenAddresses, ticks)

      expect(oracleTick).to.equal(0)
    })
    it('add two negative ticks, sorted order', async () => {
      const tokenAddresses = [await tokens[0].getAddress(), await tokens[1].getAddress(), await tokens[2].getAddress()]
      ticks = [-5, -5]
      const oracleTick = await oracle.getChainedPrice(tokenAddresses, ticks)

      expect(oracleTick).to.equal(-10)
    })

    it('add two positive ticks, token0/token1 + token1/token0', async () => {
      const tokenAddresses = [await tokens[0].getAddress(), await tokens[2].getAddress(), await tokens[1].getAddress()]
      ticks = [5, 5]
      const oracleTick = await oracle.getChainedPrice(tokenAddresses, ticks)

      expect(oracleTick).to.equal(0)
    })
    it('add one positive tick and one negative tick, token0/token1 + token1/token0', async () => {
      const tokenAddresses = [await tokens[0].getAddress(), await tokens[2].getAddress(), await tokens[1].getAddress()]
      ticks = [5, -5]
      const oracleTick = await oracle.getChainedPrice(tokenAddresses, ticks)

      expect(oracleTick).to.equal(10)
    })
    it('add one negative tick and one positive tick, token0/token1 + token1/token0', async () => {
      const tokenAddresses = [await tokens[0].getAddress(), await tokens[2].getAddress(), await tokens[1].getAddress()]
      ticks = [-5, 5]
      const oracleTick = await oracle.getChainedPrice(tokenAddresses, ticks)

      expect(oracleTick).to.equal(-10)
    })
    it('add two negative ticks, token0/token1 + token1/token0', async () => {
      const tokenAddresses = [await tokens[0].getAddress(), await tokens[2].getAddress(), await tokens[1].getAddress()]
      ticks = [-5, -5]
      const oracleTick = await oracle.getChainedPrice(tokenAddresses, ticks)

      expect(oracleTick).to.equal(0)
    })

    it('add two positive ticks, token1/token0 + token0/token1', async () => {
      const tokenAddresses = [await tokens[1].getAddress(), await tokens[0].getAddress(), await tokens[2].getAddress()]
      ticks = [5, 5]
      const oracleTick = await oracle.getChainedPrice(tokenAddresses, ticks)

      expect(oracleTick).to.equal(0)
    })
    it('add one positive tick and one negative tick, token1/token0 + token0/token1', async () => {
      const tokenAddresses = [await tokens[1].getAddress(), await tokens[0].getAddress(), await tokens[2].getAddress()]
      ticks = [5, -5]
      const oracleTick = await oracle.getChainedPrice(tokenAddresses, ticks)

      expect(oracleTick).to.equal(-10)
    })
    it('add one negative tick and one positive tick, token1/token0 + token0/token1', async () => {
      const tokenAddresses = [await tokens[1].getAddress(), await tokens[0].getAddress(), await tokens[2].getAddress()]
      ticks = [-5, 5]
      const oracleTick = await oracle.getChainedPrice(tokenAddresses, ticks)

      expect(oracleTick).to.equal(10)
    })
    it('add two negative ticks, token1/token0 + token0/token1', async () => {
      const tokenAddresses = [await tokens[1].getAddress(), await tokens[0].getAddress(), await tokens[2].getAddress()]
      ticks = [-5, -5]
      const oracleTick = await oracle.getChainedPrice(tokenAddresses, ticks)

      expect(oracleTick).to.equal(0)
    })

    it('add two positive ticks, token0/token1 + token1/token0', async () => {
      const tokenAddresses = [await tokens[1].getAddress(), await tokens[2].getAddress(), await tokens[0].getAddress()]
      ticks = [5, 5]
      const oracleTick = await oracle.getChainedPrice(tokenAddresses, ticks)

      expect(oracleTick).to.equal(0)
    })
    it('add one positive tick and one negative tick, token0/token1 + token1/token0', async () => {
      const tokenAddresses = [await tokens[1].getAddress(), await tokens[2].getAddress(), await tokens[0].getAddress()]
      ticks = [5, -5]
      const oracleTick = await oracle.getChainedPrice(tokenAddresses, ticks)

      expect(oracleTick).to.equal(10)
    })
    it('add one negative tick and one positive tick, token0/token1 + token1/token0', async () => {
      const tokenAddresses = [await tokens[1].getAddress(), await tokens[2].getAddress(), await tokens[0].getAddress()]
      ticks = [-5, 5]
      const oracleTick = await oracle.getChainedPrice(tokenAddresses, ticks)

      expect(oracleTick).to.equal(-10)
    })
    it('add two negative ticks, token0/token1 + token1/token0', async () => {
      const tokenAddresses = [await tokens[1].getAddress(), await tokens[2].getAddress(), await tokens[0].getAddress()]
      ticks = [-5, -5]
      const oracleTick = await oracle.getChainedPrice(tokenAddresses, ticks)

      expect(oracleTick).to.equal(0)
    })

    it('add two positive ticks, token1/token0 + token0/token1', async () => {
      const tokenAddresses = [await tokens[2].getAddress(), await tokens[0].getAddress(), await tokens[1].getAddress()]
      ticks = [5, 5]
      const oracleTick = await oracle.getChainedPrice(tokenAddresses, ticks)

      expect(oracleTick).to.equal(0)
    })
    it('add one positive tick and one negative tick, token1/token0 + token0/token1', async () => {
      const tokenAddresses = [await tokens[2].getAddress(), await tokens[0].getAddress(), await tokens[1].getAddress()]
      ticks = [5, -5]
      const oracleTick = await oracle.getChainedPrice(tokenAddresses, ticks)

      expect(oracleTick).to.equal(-10)
    })
    it('add one negative tick and one positive tick, token1/token0 + token0/token1', async () => {
      const tokenAddresses = [await tokens[2].getAddress(), await tokens[0].getAddress(), await tokens[1].getAddress()]
      ticks = [-5, 5]
      const oracleTick = await oracle.getChainedPrice(tokenAddresses, ticks)

      expect(oracleTick).to.equal(10)
    })
    it('add two negative ticks, token1/token0 + token0/token1', async () => {
      const tokenAddresses = [await tokens[2].getAddress(), await tokens[0].getAddress(), await tokens[1].getAddress()]
      ticks = [-5, -5]
      const oracleTick = await oracle.getChainedPrice(tokenAddresses, ticks)

      expect(oracleTick).to.equal(0)
    })

    it('add two positive ticks, token1/token0 + token1/token0', async () => {
      const tokenAddresses = [await tokens[2].getAddress(), await tokens[1].getAddress(), await tokens[0].getAddress()]
      ticks = [5, 5]
      const oracleTick = await oracle.getChainedPrice(tokenAddresses, ticks)

      expect(oracleTick).to.equal(-10)
    })
    it('add one positive tick and one negative tick, token1/token0 + token1/token0', async () => {
      const tokenAddresses = [await tokens[2].getAddress(), await tokens[1].getAddress(), await tokens[0].getAddress()]
      ticks = [5, -5]
      const oracleTick = await oracle.getChainedPrice(tokenAddresses, ticks)

      expect(oracleTick).to.equal(0)
    })
    it('add one negative tick and one positive tick, token1/token0 + token1/token0', async () => {
      const tokenAddresses = [await tokens[2].getAddress(), await tokens[1].getAddress(), await tokens[0].getAddress()]
      ticks = [-5, 5]
      const oracleTick = await oracle.getChainedPrice(tokenAddresses, ticks)

      expect(oracleTick).to.equal(0)
    })
    it('add two negative ticks, token1/token0 + token1/token0', async () => {
      const tokenAddresses = [await tokens[2].getAddress(), await tokens[1].getAddress(), await tokens[0].getAddress()]
      ticks = [-5, -5]
      const oracleTick = await oracle.getChainedPrice(tokenAddresses, ticks)

      expect(oracleTick).to.equal(10)
    })
  })
})
