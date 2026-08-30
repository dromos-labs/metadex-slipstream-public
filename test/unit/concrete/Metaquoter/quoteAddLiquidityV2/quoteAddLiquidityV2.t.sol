// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {UnitMetaquoterLiquidityBase} from 'test/unit/concrete/Metaquoter/MetaquoterLiquidityBase.sol';

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Babylonian} from '@uniswap/lib/contracts/libraries/Babylonian.sol';

import {FullMath} from 'contracts/core/libraries/FullMath.sol';
import {IV2Pool} from 'contracts/periphery/interfaces/IV2Pool.sol';
import {IV3FactoryRegistry} from 'contracts/periphery/interfaces/IV3FactoryRegistry.sol';

contract UnitMetaquoterQuoteAddLiquidityV2 is UnitMetaquoterLiquidityBase {
  function test_WhenThePoolIsNotARegisteredTarget(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amount0Desired,
    uint256 _amount1Desired
  ) external {
    // The registry resolves the pool to the zero factory, i.e. it is not a registered target, so `validateV2Pool`
    // reverts before any reserves or supply are read.
    _bootstrap(_registry, _factory, _pool);

    _mockAndExpect(
      _registry, abi.encodeWithSelector(IV3FactoryRegistry.targetToFactory.selector, _pool), abi.encode(address(0))
    );

    // it reverts with IP
    vm.expectRevert(bytes('IP'));
    _quoter.quoteAddLiquidityV2(_pool, _amount0Desired, _amount1Desired);
  }

  modifier givenThePoolIsARegisteredTarget() {
    _;
  }

  function test_WhenTheTargetFactoryIsNotApproved(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amount0Desired,
    uint256 _amount1Desired
  ) external givenThePoolIsARegisteredTarget {
    // The pool resolves to a factory, but the registry has not approved it, so `validateV2Pool` reverts before any
    // reserves or supply are read.
    _bootstrap(_registry, _factory, _pool);

    _mockAndExpect(
      _registry, abi.encodeWithSelector(IV3FactoryRegistry.targetToFactory.selector, _pool), abi.encode(_factory)
    );
    _mockAndExpect(
      _registry,
      abi.encodeWithSelector(IV3FactoryRegistry.isTargetFactoryApproved.selector, _factory),
      abi.encode(false)
    );

    // it reverts with AF
    vm.expectRevert(bytes('AF'));
    _quoter.quoteAddLiquidityV2(_pool, _amount0Desired, _amount1Desired);
  }

  modifier givenTheTargetFactoryIsApproved() {
    _;
  }

  function test_WhenThePoolTypeIsNotAV2Type(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amount0Desired,
    uint256 _amount1Desired
  ) external givenThePoolIsARegisteredTarget givenTheTargetFactoryIsApproved {
    _bootstrap(_registry, _factory, _pool);
    _mockValidPool(_registry, _factory, _pool, bytes32('CL'));

    // it reverts with PT
    vm.expectRevert(bytes('PT'));
    _quoter.quoteAddLiquidityV2(_pool, _amount0Desired, _amount1Desired);
  }

  modifier givenTheTotalSupplyIsZero() {
    _;
  }

  function test_WhenTheGeometricMeanUnderflowsTheMinimumLiquidity(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amount0Desired,
    uint256 _amount1Desired
  ) external givenThePoolIsARegisteredTarget givenTheTargetFactoryIsApproved givenTheTotalSupplyIsZero {
    // Product below MINIMUM_LIQUIDITY^2 (= 1e6) so sqrt(product) < MINIMUM_LIQUIDITY and the `sqrt(...) -
    // MINIMUM_LIQUIDITY` subtraction underflows after the V2 pool-type gate, mirroring the pool's arithmetic panic.
    _bootstrap(_registry, _factory, _pool);
    _amount0Desired = bound(_amount0Desired, 1, type(uint256).max);
    _amount1Desired = bound(_amount1Desired, 0, (_MINIMUM_LIQUIDITY * _MINIMUM_LIQUIDITY - 1) / _amount0Desired);

    _mockValidPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE);
    // totalSupply must be 0 to select the first-mint branch.
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(0)));
    _mockMetadata(_pool, 0, 0);

    // it reverts with SafeMath: subtraction overflow
    vm.expectRevert(bytes('SafeMath: subtraction overflow'));
    _quoter.quoteAddLiquidityV2(_pool, _amount0Desired, _amount1Desired);
  }

  modifier givenThePoolIsStable() {
    _;
  }

  function test_WhenTheDepositsAreNotEqual(
    address _registry,
    address _factory,
    address _pool,
    address _token0,
    address _token1
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenTheTotalSupplyIsZero
    givenThePoolIsStable
  {
    // Stable first mint with decimal-normalized deposits that differ (4e18 vs 9e18 at 18-decimal scales): the
    // geometric mean clears the minimum, but the pool rejects unequal deposits (DepositsNotEqual). The pool sits
    // undonated, so the credited amounts are the desired amounts.
    _bootstrap(_registry, _factory, _pool);
    _sanitizeTokens(_registry, _factory, _pool, _token0, _token1);

    _mockValidPool(_registry, _factory, _pool, _V2_STABLE_POOL_TYPE);
    // totalSupply must be 0 to select the first-mint branch.
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(0)));
    _mockMetadataTokens(_pool, 0, 0, _token0, _token1);
    _mockPoolBalances(_pool, _token0, _token1, 0, 0);

    // it reverts with DE
    vm.expectRevert(bytes('DE'));
    _quoter.quoteAddLiquidityV2(_pool, 4e18, 9e18);
  }

  function test_WhenADonationMakesTheCreditedDepositsUnequal(
    address _registry,
    address _factory,
    address _pool,
    address _token0,
    address _token1,
    uint256 _donation
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenTheTotalSupplyIsZero
    givenThePoolIsStable
  {
    // On a first mint the pool credits `balanceOf(pool) - reserve`, i.e. the live balance after the depositor's
    // transfer, so a pre-existing one-sided donation is credited alongside the deposit. The desired amounts here are
    // decimal-normalized equal, but token0 already holds a donation while token1 holds nothing, so the credited
    // amounts differ and mint() reverts DepositsNotEqual. The donation is capped so the normalizing `mul(1e18)` stays
    // within uint256.
    _bootstrap(_registry, _factory, _pool);
    _sanitizeTokens(_registry, _factory, _pool, _token0, _token1);
    _donation = bound(_donation, 1, type(uint128).max);

    _mockValidPool(_registry, _factory, _pool, _V2_STABLE_POOL_TYPE);
    // totalSupply must be 0 to select the first-mint branch.
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(0)));
    _mockMetadataTokens(_pool, 0, 0, _token0, _token1);
    _mockPoolBalances(_pool, _token0, _token1, _donation, 0);
    // Mocked but not expected: rejecting the unequal credited amounts short-circuits before the invariant floor.
    vm.mockCall(_pool, abi.encodeWithSelector(IV2Pool.MINIMUM_K.selector), abi.encode(_MINIMUM_K));

    // it reverts with DE
    vm.expectRevert(bytes('DE'));
    _quoter.quoteAddLiquidityV2(_pool, 4e18, 4e18);
  }

  function test_WhenTheStableInvariantIsBelowTheMinimum(
    address _registry,
    address _factory,
    address _pool,
    address _token0,
    address _token1
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenTheTotalSupplyIsZero
    givenThePoolIsStable
  {
    _bootstrap(_registry, _factory, _pool);
    _sanitizeTokens(_registry, _factory, _pool, _token0, _token1);

    _mockValidPool(_registry, _factory, _pool, _V2_STABLE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(0)));
    _mockMetadataTokens(_pool, 0, 0, _token0, _token1);
    _mockPoolBalances(_pool, _token0, _token1, 0, 0);
    _mockAndExpect(_pool, abi.encodeWithSelector(IV2Pool.MINIMUM_K.selector), abi.encode(_MINIMUM_K));

    // Equal 0.001-token deposits produce k = 2e6, below the stable pool's 1e10 minimum.
    vm.expectRevert(bytes('BK'));
    _quoter.quoteAddLiquidityV2(_pool, 1e15, 1e15);
  }

  function test_WhenTheDepositsAreEqual(
    address _registry,
    address _factory,
    address _pool,
    address _token0,
    address _token1
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenTheTotalSupplyIsZero
    givenThePoolIsStable
  {
    // Stable first mint with equal decimal-normalized deposits into an undonated pool clears DE; the geometric mean
    // (4e18) also clears the minimum liquidity, so the quote returns the full amounts and the seeded liquidity.
    _bootstrap(_registry, _factory, _pool);
    _sanitizeTokens(_registry, _factory, _pool, _token0, _token1);

    _mockValidPool(_registry, _factory, _pool, _V2_STABLE_POOL_TYPE);
    // totalSupply must be 0 to select the first-mint branch.
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(0)));
    _mockMetadataTokens(_pool, 0, 0, _token0, _token1);
    _mockPoolBalances(_pool, _token0, _token1, 0, 0);
    _mockAndExpect(_pool, abi.encodeWithSelector(IV2Pool.MINIMUM_K.selector), abi.encode(_MINIMUM_K));

    (uint256 _amount0, uint256 _amount1, uint256 _liquidity) = _quoter.quoteAddLiquidityV2(_pool, 4e18, 4e18);

    // it returns amount0Desired as amount0 and amount1Desired as amount1
    assertEq(_amount0, 4e18);
    assertEq(_amount1, 4e18);
    // it returns liquidity as sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY
    assertEq(_liquidity, 4e18 - _MINIMUM_LIQUIDITY);
  }

  function test_WhenAnOffsettingDesiredDepositBalancesTheCreditedDeposits(
    address _registry,
    address _factory,
    address _pool,
    address _token0,
    address _token1,
    uint256 _donation
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenTheTotalSupplyIsZero
    givenThePoolIsStable
  {
    // token0 already holds a one-sided donation, so the caller desires exactly that much less of it: the credited
    // amounts (donation + amount0Desired against amount1Desired) are decimal-normalized equal and the mint clears DE.
    // The quote itself stays derived from the desired amounts alone, so the returned amount0 is the smaller,
    // donation-free figure. The donation is bounded to leave a nonzero desired amount whose geometric mean against
    // 4e18 still clears MINIMUM_LIQUIDITY.
    _bootstrap(_registry, _factory, _pool);
    _sanitizeTokens(_registry, _factory, _pool, _token0, _token1);
    _donation = bound(_donation, 1, 4e18 - 1e15);
    uint256 _amount0Desired = 4e18 - _donation;

    _mockValidPool(_registry, _factory, _pool, _V2_STABLE_POOL_TYPE);
    // totalSupply must be 0 to select the first-mint branch.
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(0)));
    _mockMetadataTokens(_pool, 0, 0, _token0, _token1);
    _mockPoolBalances(_pool, _token0, _token1, _donation, 0);
    _mockAndExpect(_pool, abi.encodeWithSelector(IV2Pool.MINIMUM_K.selector), abi.encode(_MINIMUM_K));

    (uint256 _amount0, uint256 _amount1, uint256 _liquidity) = _quoter.quoteAddLiquidityV2(_pool, _amount0Desired, 4e18);

    // it returns amount0Desired as amount0 and amount1Desired as amount1
    assertEq(_amount0, _amount0Desired);
    assertEq(_amount1, 4e18);
    // it returns liquidity as sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY
    assertEq(_liquidity, Babylonian.sqrt(_amount0Desired * 4e18) - _MINIMUM_LIQUIDITY);
  }

  function test_WhenDonationsAreCreditedOnBothSides(
    address _registry,
    address _factory,
    address _pool,
    address _token0,
    address _token1,
    uint256 _donation
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenTheTotalSupplyIsZero
    givenThePoolIsStable
  {
    // Both sides hold the same donation at equal decimal scales, so the credited amounts stay equal and DE passes
    // however large the donation grows. The quote must ignore the donation entirely: the returned amounts are the
    // desired ones and the liquidity is their geometric mean, never the larger credited figure. The donation is
    // bounded so the invariant computed on the credited amounts (~2 * credited^4 / 1e36) stays within uint256.
    _bootstrap(_registry, _factory, _pool);
    _sanitizeTokens(_registry, _factory, _pool, _token0, _token1);
    _donation = bound(_donation, 1, 1e27);

    _mockValidPool(_registry, _factory, _pool, _V2_STABLE_POOL_TYPE);
    // totalSupply must be 0 to select the first-mint branch.
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(0)));
    _mockMetadataTokens(_pool, 0, 0, _token0, _token1);
    _mockPoolBalances(_pool, _token0, _token1, _donation, _donation);
    _mockAndExpect(_pool, abi.encodeWithSelector(IV2Pool.MINIMUM_K.selector), abi.encode(_MINIMUM_K));

    (uint256 _amount0, uint256 _amount1, uint256 _liquidity) = _quoter.quoteAddLiquidityV2(_pool, 4e18, 4e18);

    // it returns amount0Desired as amount0 and amount1Desired as amount1
    assertEq(_amount0, 4e18);
    assertEq(_amount1, 4e18);
    // it returns liquidity from the desired amounts, not the credited ones
    assertEq(_liquidity, 4e18 - _MINIMUM_LIQUIDITY);
  }

  function test_WhenTheDepositsAreEqualAtDifferingTokenDecimals(
    address _registry,
    address _factory,
    address _pool,
    address _token0,
    address _token1
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenTheTotalSupplyIsZero
    givenThePoolIsStable
  {
    // A 6-decimal/18-decimal stable pair (e.g. USDC/DAI). Both validations run on decimal-normalized amounts, so
    // 4 USDC against 4 DAI normalizes to 4e18 on both sides and clears DE, with k = 512e18 clearing the minimum.
    // The minted liquidity, by contrast, is the geometric mean of the RAW amounts: sqrt(4e6 * 4e18) = 4e12.
    _bootstrap(_registry, _factory, _pool);
    _sanitizeTokens(_registry, _factory, _pool, _token0, _token1);

    _mockValidPool(_registry, _factory, _pool, _V2_STABLE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(0)));
    _mockMetadataScaled(_pool, 1e6, 1e18, 0, 0, _token0, _token1);
    _mockPoolBalances(_pool, _token0, _token1, 0, 0);
    _mockAndExpect(_pool, abi.encodeWithSelector(IV2Pool.MINIMUM_K.selector), abi.encode(_MINIMUM_K));

    (uint256 _amount0, uint256 _amount1, uint256 _liquidity) = _quoter.quoteAddLiquidityV2(_pool, 4e6, 4e18);

    // it returns amount0Desired as amount0 and amount1Desired as amount1
    assertEq(_amount0, 4e6);
    assertEq(_amount1, 4e18);
    // it returns liquidity as sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY
    assertEq(_liquidity, 4e12 - _MINIMUM_LIQUIDITY);
  }

  function test_WhenTheRawDepositsMatchButTheNormalizedOnesDoNot(
    address _registry,
    address _factory,
    address _pool,
    address _token0,
    address _token1
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenTheTotalSupplyIsZero
    givenThePoolIsStable
  {
    // Numerically identical deposits into the same 6/18-decimal pair are worth wildly different amounts: 4e18 base
    // units of a 6-decimal token normalizes to 4e30 against the other side's 4e18. A comparison on raw amounts would
    // wave this through; the pool rejects it, so the quote must too.
    _bootstrap(_registry, _factory, _pool);
    _sanitizeTokens(_registry, _factory, _pool, _token0, _token1);

    _mockValidPool(_registry, _factory, _pool, _V2_STABLE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(0)));
    _mockMetadataScaled(_pool, 1e6, 1e18, 0, 0, _token0, _token1);
    _mockPoolBalances(_pool, _token0, _token1, 0, 0);

    // it reverts with DE
    vm.expectRevert(bytes('DE'));
    _quoter.quoteAddLiquidityV2(_pool, 4e18, 4e18);
  }

  function test_WhenTheStableInvariantEqualsTheMinimum(
    address _registry,
    address _factory,
    address _pool,
    address _token0,
    address _token1
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenTheTotalSupplyIsZero
    givenThePoolIsStable
  {
    // The pool rejects `k <= MINIMUM_K`, so equality must revert rather than squeak through. Equal 4e18 deposits give
    // k = 512e18 exactly; pinning the pool's minimum to that same value puts the quote on the boundary.
    _bootstrap(_registry, _factory, _pool);
    _sanitizeTokens(_registry, _factory, _pool, _token0, _token1);

    _mockValidPool(_registry, _factory, _pool, _V2_STABLE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(0)));
    _mockMetadataTokens(_pool, 0, 0, _token0, _token1);
    _mockPoolBalances(_pool, _token0, _token1, 0, 0);
    _mockAndExpect(_pool, abi.encodeWithSelector(IV2Pool.MINIMUM_K.selector), abi.encode(uint256(512e18)));

    // it reverts with BK
    vm.expectRevert(bytes('BK'));
    _quoter.quoteAddLiquidityV2(_pool, 4e18, 4e18);
  }

  modifier givenThePoolIsNotStable() {
    _;
  }

  function test_WhenTheFirstMintClearsTheMinimumLiquidity(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amount0Desired,
    uint256 _amount1Desired
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenTheTotalSupplyIsZero
    givenThePoolIsNotStable
  {
    // Volatile first mint: no deposit-equality constraint. Keep both factors >= 2 * MINIMUM_LIQUIDITY so the geometric
    // mean clears MINIMUM_LIQUIDITY with headroom while the product stays within uint256. totalSupply must be 0 to
    // select the first-mint branch.
    _bootstrap(_registry, _factory, _pool);
    _amount0Desired = bound(_amount0Desired, 2 * _MINIMUM_LIQUIDITY, type(uint256).max / (2 * _MINIMUM_LIQUIDITY));
    _amount1Desired = bound(_amount1Desired, 2 * _MINIMUM_LIQUIDITY, type(uint256).max / _amount0Desired);

    _mockValidPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE);
    // totalSupply must be 0 to select the first-mint branch.
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(0)));
    _mockMetadata(_pool, 0, 0);

    (uint256 _amount0, uint256 _amount1, uint256 _liquidity) =
      _quoter.quoteAddLiquidityV2(_pool, _amount0Desired, _amount1Desired);

    // it returns amount0Desired as amount0 and amount1Desired as amount1
    assertEq(_amount0, _amount0Desired);
    assertEq(_amount1, _amount1Desired);
    // it returns liquidity as sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY
    assertEq(_liquidity, Babylonian.sqrt(_amount0Desired * _amount1Desired) - _MINIMUM_LIQUIDITY);
  }

  function test_WhenTheMintedLiquidityIsBelowTheMinimum(
    address _registry,
    address _factory,
    address _pool
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenTheTotalSupplyIsZero
    givenThePoolIsNotStable
  {
    // Geometric mean in [MINIMUM_LIQUIDITY, 2 * MINIMUM_LIQUIDITY): the subtraction does not underflow but the minted
    // liquidity lands below MINIMUM_LIQUIDITY, which the pool rejects. 1500/1500 gives sqrt = 1500, liquidity = 500.
    _bootstrap(_registry, _factory, _pool);

    _mockValidPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE);
    // totalSupply must be 0 to select the first-mint branch.
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(0)));
    _mockMetadata(_pool, 0, 0);

    // it reverts with ILM
    vm.expectRevert(bytes('ILM'));
    _quoter.quoteAddLiquidityV2(_pool, 1500, 1500);
  }

  modifier givenTheTotalSupplyIsNonzero() {
    _;
  }

  function test_WhenAmount0DesiredIsZero(
    address _registry,
    address _factory,
    address _pool,
    uint256 _reserve0,
    uint256 _reserve1,
    uint256 _totalSupply,
    uint256 _amount1Desired
  ) external givenThePoolIsARegisteredTarget givenTheTargetFactoryIsApproved givenTheTotalSupplyIsNonzero {
    // The seeded branch opens with `require(amount0Desired > 0, 'IA')`, which reverts ahead of the reserve guard and
    // every piece of quote math, so the fuzzed reserves and supply never reach a comparison and are free to fuzz.
    // reserve0 is bounded nonzero only to keep the fuzz domain aligned with the other seeded tests; with 'IA' firing
    // first neither reserve is ever read, and reserve1 can even be zero.
    _bootstrap(_registry, _factory, _pool);
    _reserve0 = bound(_reserve0, 1, type(uint256).max);
    _totalSupply = bound(_totalSupply, 1, type(uint256).max);

    _mockValidPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(_totalSupply));
    _mockMetadata(_pool, _reserve0, _reserve1);

    // it reverts with IA
    vm.expectRevert(bytes('IA'));
    _quoter.quoteAddLiquidityV2(_pool, 0, _amount1Desired);
  }

  function test_WhenReserve0IsZero(
    address _registry,
    address _factory,
    address _pool,
    uint256 _reserve1,
    uint256 _totalSupply,
    uint256 _amount0Desired,
    uint256 _amount1Desired
  ) external givenThePoolIsARegisteredTarget givenTheTargetFactoryIsApproved givenTheTotalSupplyIsNonzero {
    // A nonzero totalSupply selects the seeded branch, where amount0Desired (bounded nonzero) clears the 'IA' guard and
    // `require(reserve0 > 0 && reserve1 > 0, 'IL')` then reverts on its reserve0 half, before `mul512High` or any
    // `mulDiv` runs, so amount0Desired and the rest are free to fuzz.
    _bootstrap(_registry, _factory, _pool);
    _reserve1 = bound(_reserve1, 1, type(uint256).max);
    _amount0Desired = bound(_amount0Desired, 1, type(uint256).max);
    _totalSupply = bound(_totalSupply, 1, type(uint256).max);

    _mockValidPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(_totalSupply));
    _mockMetadata(_pool, 0, _reserve1);

    // it reverts with IL
    vm.expectRevert(bytes('IL'));
    _quoter.quoteAddLiquidityV2(_pool, _amount0Desired, _amount1Desired);
  }

  function test_WhenReserve1IsZero(
    address _registry,
    address _factory,
    address _pool,
    uint256 _reserve0,
    uint256 _totalSupply,
    uint256 _amount0Desired,
    uint256 _amount1Desired
  ) external givenThePoolIsARegisteredTarget givenTheTargetFactoryIsApproved givenTheTotalSupplyIsNonzero {
    // The mirror of the reserve0 case: amount0Desired (bounded nonzero) clears the 'IA' guard and the same
    // `require(reserve0 > 0 && reserve1 > 0, 'IL')` reverts on its reserve1 half, still before `mul512High` or any
    // `mulDiv` runs, so the remaining inputs are free to fuzz.
    _bootstrap(_registry, _factory, _pool);
    _reserve0 = bound(_reserve0, 1, type(uint256).max);
    _amount0Desired = bound(_amount0Desired, 1, type(uint256).max);
    _totalSupply = bound(_totalSupply, 1, type(uint256).max);

    _mockValidPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(_totalSupply));
    _mockMetadata(_pool, _reserve0, 0);

    // it reverts with IL
    vm.expectRevert(bytes('IL'));
    _quoter.quoteAddLiquidityV2(_pool, _amount0Desired, _amount1Desired);
  }

  modifier givenBothReservesAreNonzero() {
    _;
  }

  function test_WhenTheMintedLiquidityIsZero(
    address _registry,
    address _factory,
    address _pool
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenTheTotalSupplyIsNonzero
    givenBothReservesAreNonzero
  {
    _bootstrap(_registry, _factory, _pool);

    _mockValidPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(1e18)));
    _mockMetadata(_pool, 2e18, 2e18);

    // A one-wei proportional deposit rounds the minted LP amount down to zero.
    vm.expectRevert(bytes('ILM'));
    _quoter.quoteAddLiquidityV2(_pool, 1, 1);
  }

  function test_WhenAStablePoolHasDriftedReserves(
    address _registry,
    address _factory,
    address _pool
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenTheTotalSupplyIsNonzero
    givenBothReservesAreNonzero
  {
    // A stable pool validates deposit equality on its FIRST mint only (`_mintValidation` is called inside the
    // zero-supply branch of `mint()`), so a seeded stable pool accepts whatever the reserve ratio dictates even once
    // that ratio has drifted away from decimal-normalized parity. Here a 6/18-decimal pair sits at 1.1 USDC against
    // 1 DAI, i.e. normalized 1.1e18 vs 1e18: the trim mirrors the pool and must not impose the first-mint check.
    _bootstrap(_registry, _factory, _pool);

    _mockValidPool(_registry, _factory, _pool, _V2_STABLE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(1e18)));
    _mockMetadataScaled(_pool, 1e6, 1e18, 1.1e6, 1e18, address(0), address(0));
    // MINIMUM_K and the token balances are deliberately left unmocked: reaching either would revert on the empty
    // return data, so this quote succeeding proves the seeded path runs no first-mint validation and reads no
    // balances.

    (uint256 _amount0, uint256 _amount1, uint256 _liquidity) = _quoter.quoteAddLiquidityV2(_pool, 1.1e6, 2e18);

    // it trims amount1 to the drifted reserve ratio
    assertEq(_amount0, 1.1e6);
    assertEq(_amount1, 1e18);
    // it returns liquidity as the min of the reserve-proportional shares
    assertEq(_liquidity, 1e18);
  }

  function test_WhenTheForwardQuotientDoesNotFitUint256(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amount0Desired,
    uint256 _amount1Desired
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenTheTotalSupplyIsNonzero
    givenBothReservesAreNonzero
  {
    // reserve0 = 2**100, reserve1 = 2**200, so the high word of `amount0Desired * reserve1` is `amount0Desired >> 56`:
    // every amount0Desired >= 2**156 lifts it to or above reserve0, leaving the forward quote unrepresentable in a
    // uint256. token1 therefore binds on its own and amount0Desired drops out of the result entirely, which is why it
    // is free to fuzz across the whole range above that threshold. amount1Desired is bounded below so the minted
    // liquidity clears zero and above so the pool-share multiplications stay inside uint256.
    _bootstrap(_registry, _factory, _pool);
    _amount0Desired = bound(_amount0Desired, 1 << 156, type(uint256).max);
    _amount1Desired = bound(_amount1Desired, 1 << 140, (1 << 196) - 1);

    _mockValidPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(1 << 60)));
    _mockMetadata(_pool, 1 << 100, 1 << 200);

    (uint256 _amount0, uint256 _amount1, uint256 _liquidity) =
      _quoter.quoteAddLiquidityV2(_pool, _amount0Desired, _amount1Desired);

    // it returns the full precision amount0Optimal as amount0 and amount1Desired as amount1
    uint256 _amount0Optimal = FullMath.mulDiv(_amount1Desired, 1 << 100, 1 << 200);
    assertEq(_amount0, _amount0Optimal);
    assertEq(_amount1, _amount1Desired);
    // it returns liquidity as the min of the reserve-proportional shares
    uint256 _share0 = FullMath.mulDiv(_amount0Optimal, 1 << 60, 1 << 100);
    uint256 _share1 = FullMath.mulDiv(_amount1Desired, 1 << 60, 1 << 200);
    assertEq(_liquidity, _share0 < _share1 ? _share0 : _share1);
  }

  function test_WhenTheHighWordIsOneBelowTheDenominator(
    address _registry,
    address _factory,
    address _pool,
    uint256 _k
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenTheTotalSupplyIsNonzero
    givenBothReservesAreNonzero
  {
    // amount0Desired = k << 128 against reserve1 = 2**128 makes the 512-bit product exactly k * 2**256: a high word of
    // k over a zero low word, i.e. the comparison lands on an exact boundary rather than near one. reserve0 = k + 1
    // leaves the high word one below the denominator — the largest high word whose quotient `mulDiv` can still
    // represent; the quotient itself stays below the uint256 max — so the forward quote survives and, with
    // amount1Desired at the uint256 max, token0 binds. totalSupply is 1 so the
    // near-2**256 amount1 cannot overflow the pool-share multiplication.
    _bootstrap(_registry, _factory, _pool);
    _k = bound(_k, 2, 1 << 100);

    _mockValidPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(1)));
    _mockMetadata(_pool, _k + 1, 1 << 128);

    (uint256 _amount0, uint256 _amount1, uint256 _liquidity) =
      _quoter.quoteAddLiquidityV2(_pool, _k << 128, type(uint256).max);

    // it returns amount0Desired as amount0 and the exact forward quote as amount1
    uint256 _amount1Optimal = FullMath.mulDiv(_k << 128, 1 << 128, _k + 1);
    assertEq(_amount0, _k << 128);
    assertEq(_amount1, _amount1Optimal);
    // it returns liquidity as the min of the reserve-proportional shares
    uint256 _share0 = (_k << 128) / (_k + 1);
    uint256 _share1 = _amount1Optimal / (1 << 128);
    assertEq(_liquidity, _share0 < _share1 ? _share0 : _share1);
  }

  function test_WhenTheForwardQuotientIsTheFirstUnrepresentableOne(
    address _registry,
    address _factory,
    address _pool,
    uint256 _k,
    uint256 _amount1Desired
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenTheTotalSupplyIsNonzero
    givenBothReservesAreNonzero
  {
    // The same exact k * 2**256 product, one step further: reserve0 = k makes the high word equal the denominator, the
    // first quotient `mulDiv` cannot represent (it would be exactly 2**256). The strict `<` skips the forward quote
    // altogether and token1 binds on the reverse one. A `<=` comparison would instead run the forward `mulDiv` and
    // revert on the overflowing quotient, so this case pins the boundary down to the single exact value.
    _bootstrap(_registry, _factory, _pool);
    _k = bound(_k, 2, 1 << 100);
    _amount1Desired = bound(_amount1Desired, 1 << 130, type(uint256).max);

    _mockValidPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(1)));
    _mockMetadata(_pool, _k, 1 << 128);

    (uint256 _amount0, uint256 _amount1, uint256 _liquidity) =
      _quoter.quoteAddLiquidityV2(_pool, _k << 128, _amount1Desired);

    // it returns the reverse quote as amount0 and amount1Desired as amount1
    uint256 _amount0Optimal = FullMath.mulDiv(_amount1Desired, _k, 1 << 128);
    assertEq(_amount0, _amount0Optimal);
    assertEq(_amount1, _amount1Desired);
    // it returns liquidity as the min of the reserve-proportional shares
    uint256 _share0 = _amount0Optimal / _k;
    uint256 _share1 = _amount1Desired / (1 << 128);
    assertEq(_liquidity, _share0 < _share1 ? _share0 : _share1);
  }

  function test_WhenTheForwardQuotientIsExactlyTheUint256Max(
    address _registry,
    address _factory,
    address _pool,
    uint256 _d
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenTheTotalSupplyIsNonzero
    givenBothReservesAreNonzero
  {
    // reserve1 = the uint256 max makes the product d * (2**256 - 1) = d * 2**256 - d, whose high word is d - 1: one
    // below reserve0 = d, so the forward quote runs and returns exactly 2**256 - 1, the largest value `mulDiv` can
    // ever produce. amount1Desired at that same max keeps token0 binding, and totalSupply = 1 keeps the pool-share
    // multiplication of the maximal amount1 inside uint256.
    _bootstrap(_registry, _factory, _pool);
    _d = bound(_d, 2, 1 << 100);

    _mockValidPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(1)));
    _mockMetadata(_pool, _d, type(uint256).max);

    (uint256 _amount0, uint256 _amount1, uint256 _liquidity) = _quoter.quoteAddLiquidityV2(_pool, _d, type(uint256).max);

    // it returns amount0Desired as amount0 and the uint256 max as amount1
    assertEq(_amount0, _d);
    assertEq(_amount1, type(uint256).max);
    // it returns liquidity as the min of the reserve-proportional shares
    // min(d * 1 / d, (2**256 - 1) * 1 / (2**256 - 1)) = 1
    assertEq(_liquidity, 1);
  }

  function test_WhenANonPowerOfTwoProductOverflows(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amount0Desired,
    uint256 _reserve1,
    uint256 _amount1Desired
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenTheTotalSupplyIsNonzero
    givenBothReservesAreNonzero
  {
    // Nothing here is a power of two: both factors are forced odd inside [2**160, 2**161), so the product lands in
    // [2**320, 2**322) with a nonzero low word and a high word inside [2**64, 2**66). reserve0 = 2**70 clears every
    // reachable high word, so the forward quote is always representable and, with amount1Desired at or above the
    // 2**252 ceiling of that quote, token0 always binds. The high word is recomputed here from `FullMath.mulDiv`
    // instead of the library under test, so the branch outcome is checked against an independent expectation.
    _bootstrap(_registry, _factory, _pool);
    _amount0Desired = bound(_amount0Desired, 1 << 160, (1 << 161) - 1) | 1;
    _reserve1 = bound(_reserve1, 1 << 160, (1 << 161) - 1) | 1;
    _amount1Desired = bound(_amount1Desired, 1 << 252, type(uint256).max);

    _mockValidPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(1)));
    _mockMetadata(_pool, 1 << 70, _reserve1);

    (uint256 _amount0, uint256 _amount1, uint256 _liquidity) =
      _quoter.quoteAddLiquidityV2(_pool, _amount0Desired, _amount1Desired);

    // The product overflows uint256 yet its high word stays below reserve0, so the forward quote is the one taken.
    uint256 _high = FullMath.mulDiv(_amount0Desired, _reserve1, 1 << 128) / (1 << 128);
    assertGt(_high, 0);
    assertLt(_high, 1 << 70);
    // it returns amount0Desired as amount0 and the exact forward quote as amount1
    uint256 _amount1Optimal = FullMath.mulDiv(_amount0Desired, _reserve1, 1 << 70);
    assertEq(_amount0, _amount0Desired);
    assertEq(_amount1, _amount1Optimal);
    // it returns liquidity as the min of the reserve-proportional shares
    uint256 _share0 = _amount0Desired / (1 << 70);
    uint256 _share1 = _amount1Optimal / _reserve1;
    assertEq(_liquidity, _share0 < _share1 ? _share0 : _share1);
  }

  modifier givenTheOptimalAmount1QuoteIsAtMostAmount1Desired() {
    _;
  }

  function test_WhenTheAmountsAreTrimmedToAmount1(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amount1Desired
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenTheTotalSupplyIsNonzero
    givenBothReservesAreNonzero
    givenTheOptimalAmount1QuoteIsAtMostAmount1Desired
  {
    // reserve0 = 1e18, reserve1 = 4e18, totalSupply = 2e18. amount0Desired = 1e18 gives amount1Optimal =
    // 1e18 * 4e18 / 1e18 = 4e18; any desired >= 4e18 keeps the optimal-<=-desired branch, so amount1Desired's exact
    // value does not change the result.
    // liquidity = min(1e18 * 2e18 / 1e18, 4e18 * 2e18 / 4e18) = min(2e18, 2e18) = 2e18.
    _bootstrap(_registry, _factory, _pool);
    _amount1Desired = bound(_amount1Desired, 4e18, type(uint256).max);

    _mockValidPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(2e18)));
    _mockMetadata(_pool, 1e18, 4e18);

    (uint256 _amount0, uint256 _amount1, uint256 _liquidity) = _quoter.quoteAddLiquidityV2(_pool, 1e18, _amount1Desired);

    // it returns amount0Desired as amount0 and amount1Optimal as amount1
    assertEq(_amount0, 1e18);
    assertEq(_amount1, 4e18);
    // it returns liquidity as the min of the reserve-proportional shares
    assertEq(_liquidity, 2e18);
  }

  function test_WhenTheForwardQuoteTiesAmount1Desired(
    address _registry,
    address _factory,
    address _pool
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenTheTotalSupplyIsNonzero
    givenBothReservesAreNonzero
    givenTheOptimalAmount1QuoteIsAtMostAmount1Desired
  {
    // reserve0 = 2e18, reserve1 = 1e18, amount0Desired = 3e18 + 1: the forward quote floors the odd wei away,
    // (3e18 + 1) * 1e18 / 2e18 = 1.5e18, exactly amount1Desired, so the comparison lands on the tie. The `<=` keeps
    // the forward pair and the caller's full amount0Desired; a `<` would take the reverse quote instead, whose
    // round-trip loses the floored wei (1.5e18 * 2e18 / 1e18 = 3e18) and diverges from the Metarouter's execution.
    // liquidity = min((3e18 + 1) * 2e18 / 2e18, 1.5e18 * 2e18 / 1e18) = min(3e18 + 1, 3e18) = 3e18.
    _bootstrap(_registry, _factory, _pool);

    _mockValidPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(2e18)));
    _mockMetadata(_pool, 2e18, 1e18);

    (uint256 _amount0, uint256 _amount1, uint256 _liquidity) = _quoter.quoteAddLiquidityV2(_pool, 3e18 + 1, 1.5e18);

    // it returns amount0Desired as amount0 and the tying forward quote as amount1
    assertEq(_amount0, 3e18 + 1);
    assertEq(_amount1, 1.5e18);
    // it returns liquidity as the min of the reserve-proportional shares
    assertEq(_liquidity, 3e18);
  }

  function test_WhenTheForwardProductOverflowsAndAmount1IsTrimmed(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amount1Desired,
    uint256 _totalSupply
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenTheTotalSupplyIsNonzero
    givenBothReservesAreNonzero
    givenTheOptimalAmount1QuoteIsAtMostAmount1Desired
  {
    // reserve0 = 2**160, reserve1 = 2**200 and amount0Desired = 2**200 make the forward product 2**400, far past
    // uint256, yet its high word (2**144) sits below reserve0, so the forward quote 2**240 is representable and still
    // binds. A SafeMath quote could never reach this branch: it reverted on the product before comparing anything.
    // totalSupply is capped so the 2**240 pool-share multiplication stays inside uint256, and any amount1Desired at or
    // above the optimal quote leaves the result unchanged.
    _bootstrap(_registry, _factory, _pool);
    _amount1Desired = bound(_amount1Desired, 1 << 240, type(uint256).max);
    _totalSupply = bound(_totalSupply, 1, type(uint16).max);

    _mockValidPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(_totalSupply));
    _mockMetadata(_pool, 1 << 160, 1 << 200);

    (uint256 _amount0, uint256 _amount1, uint256 _liquidity) =
      _quoter.quoteAddLiquidityV2(_pool, 1 << 200, _amount1Desired);

    // it returns amount0Desired as amount0 and the full precision amount1Optimal as amount1
    uint256 _amount1Optimal = FullMath.mulDiv(1 << 200, 1 << 200, 1 << 160);
    assertEq(_amount0, 1 << 200);
    assertEq(_amount1, _amount1Optimal);
    // it returns liquidity as the min of the reserve-proportional shares
    uint256 _share0 = FullMath.mulDiv(1 << 200, _totalSupply, 1 << 160);
    uint256 _share1 = FullMath.mulDiv(_amount1Optimal, _totalSupply, 1 << 200);
    assertEq(_liquidity, _share0 < _share1 ? _share0 : _share1);
  }

  modifier givenTheOptimalAmount1QuoteExceedsAmount1Desired() {
    _;
  }

  function test_WhenAmount1DesiredIsZero(
    address _registry,
    address _factory,
    address _pool,
    uint256 _totalSupply,
    uint256 _amount0Desired
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenTheTotalSupplyIsNonzero
    givenBothReservesAreNonzero
    givenTheOptimalAmount1QuoteExceedsAmount1Desired
  {
    // reserve0 = 1e18, reserve1 = 4e18, so the product's high word is 0 and the forward quote is taken:
    // amount1Optimal = amount0Desired * 4e18 / 1e18 = 4 * amount0Desired > 0 = amount1Desired, leaving amount0Binds
    // false. The reverse path then reverts on its own `require(amount1Desired > 0, 'IA')` regardless of amount0Desired,
    // i.e. the second 'IA' guard in the function rather than the leading one.
    _bootstrap(_registry, _factory, _pool);
    _amount0Desired = bound(_amount0Desired, 1, type(uint256).max / 4e18);
    _totalSupply = bound(_totalSupply, 1, type(uint256).max);

    _mockValidPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(_totalSupply));
    _mockMetadata(_pool, 1e18, 4e18);

    // it reverts with IA
    vm.expectRevert(bytes('IA'));
    _quoter.quoteAddLiquidityV2(_pool, _amount0Desired, 0);
  }

  function test_WhenTheTrimmedAmount0IsQuoted(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amount0Desired
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenTheTotalSupplyIsNonzero
    givenBothReservesAreNonzero
    givenTheOptimalAmount1QuoteExceedsAmount1Desired
  {
    // reserve0 = 1e18, reserve1 = 4e18, totalSupply = 2e18, amount1Desired = 2e18. amount1Optimal =
    // amount0Desired * 4e18 / 1e18 = 4 * amount0Desired; any amount0Desired > 0.5e18 makes it exceed the 2e18 desired,
    // so amount0 is trimmed instead and amount0Desired's exact value drops out. amount0Optimal = 2e18 * 1e18 / 4e18 =
    // 0.5e18.
    // liquidity = min(0.5e18 * 2e18 / 1e18, 2e18 * 2e18 / 4e18) = min(1e18, 1e18) = 1e18.
    _bootstrap(_registry, _factory, _pool);
    _amount0Desired = bound(_amount0Desired, 0.5e18 + 1, type(uint256).max / 4e18);

    _mockValidPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(2e18)));
    _mockMetadata(_pool, 1e18, 4e18);

    (uint256 _amount0, uint256 _amount1, uint256 _liquidity) = _quoter.quoteAddLiquidityV2(_pool, _amount0Desired, 2e18);

    // it returns amount0Optimal as amount0 and amount1Desired as amount1
    assertEq(_amount0, 0.5e18);
    assertEq(_amount1, 2e18);
    // it returns liquidity as the min of the reserve-proportional shares
    assertEq(_liquidity, 1e18);
  }

  function test_WhenTheForwardProductOverflowsAndAmount0IsTrimmed(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amount1Desired
  )
    external
    givenThePoolIsARegisteredTarget
    givenTheTargetFactoryIsApproved
    givenTheTotalSupplyIsNonzero
    givenBothReservesAreNonzero
    givenTheOptimalAmount1QuoteExceedsAmount1Desired
  {
    // Same overflowing 2**400 product as the trimmed-amount1 case, with the same representable 2**240 forward quote,
    // but amount1Desired is capped far below it, so token1 binds and amount0 is trimmed with the reverse quote. The
    // bounds keep the minted liquidity above zero and the pool-share multiplications inside uint256.
    _bootstrap(_registry, _factory, _pool);
    _amount1Desired = bound(_amount1Desired, 1 << 120, (1 << 176) - 1);

    _mockValidPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(1 << 80)));
    _mockMetadata(_pool, 1 << 160, 1 << 200);

    (uint256 _amount0, uint256 _amount1, uint256 _liquidity) =
      _quoter.quoteAddLiquidityV2(_pool, 1 << 200, _amount1Desired);

    // it returns the full precision amount0Optimal as amount0 and amount1Desired as amount1
    uint256 _amount0Optimal = FullMath.mulDiv(_amount1Desired, 1 << 160, 1 << 200);
    assertEq(_amount0, _amount0Optimal);
    assertEq(_amount1, _amount1Desired);
    // it returns liquidity as the min of the reserve-proportional shares
    uint256 _share0 = FullMath.mulDiv(_amount0Optimal, 1 << 80, 1 << 160);
    uint256 _share1 = FullMath.mulDiv(_amount1Desired, 1 << 80, 1 << 200);
    assertEq(_liquidity, _share0 < _share1 ? _share0 : _share1);
  }
}
