// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {UnitMetaquoterLiquidityBase} from 'test/unit/concrete/Metaquoter/MetaquoterLiquidityBase.sol';

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IV2Pool} from 'contracts/periphery/interfaces/IV2Pool.sol';
import {IV3FactoryRegistry} from 'contracts/periphery/interfaces/IV3FactoryRegistry.sol';

contract UnitMetaquoterQuoteRemoveLiquidityV2 is UnitMetaquoterLiquidityBase {
  function test_WhenThePoolIsNotARegisteredTarget(
    address _registry,
    address _factory,
    address _pool,
    uint256 _liquidity
  ) external {
    // The registry resolves the pool to the zero factory, i.e. it is not a registered target, so `validateV2Pool`
    // reverts.
    _bootstrap(_registry, _factory, _pool);

    _mockAndExpect(
      _registry, abi.encodeWithSelector(IV3FactoryRegistry.targetToFactory.selector, _pool), abi.encode(address(0))
    );

    // it reverts with IP
    vm.expectRevert(bytes('IP'));
    _quoter.quoteRemoveLiquidityV2(_pool, _liquidity);
  }

  modifier givenThePoolIsARegisteredTarget() {
    _;
  }

  function test_WhenTheTargetFactoryIsNotApproved(
    address _registry,
    address _factory,
    address _pool,
    uint256 _liquidity
  ) external givenThePoolIsARegisteredTarget {
    // The pool resolves to a factory, but the registry has not approved it, so `validateV2Pool` reverts.
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
    _quoter.quoteRemoveLiquidityV2(_pool, _liquidity);
  }

  modifier givenTheTargetFactoryIsApproved() {
    _;
  }

  function test_WhenTheTotalSupplyIsZero(
    address _registry,
    address _factory,
    address _pool,
    uint256 _liquidity
  ) external givenThePoolIsARegisteredTarget givenTheTargetFactoryIsApproved {
    // A created-but-unseeded pool has totalSupply == 0. The guard short-circuits to (0, 0) before any balances are
    // read, so nothing else needs mocking.
    _bootstrap(_registry, _factory, _pool);

    _mockValidPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(0)));

    (uint256 _amount0, uint256 _amount1) = _quoter.quoteRemoveLiquidityV2(_pool, _liquidity);

    // it returns amount0 and amount1 as zero
    assertEq(_amount0, 0);
    assertEq(_amount1, 0);
  }

  modifier givenTheTotalSupplyIsNonzero() {
    _;
  }

  function test_WhenTheLiquidityExceedsTheTotalSupply(
    address _registry,
    address _factory,
    address _pool,
    uint256 _liquidity,
    uint256 _totalSupply
  ) external givenThePoolIsARegisteredTarget givenTheTargetFactoryIsApproved givenTheTotalSupplyIsNonzero {
    // No LP balance can exceed the total supply, so such a quote describes a burn nothing can execute. With the pool
    // holding none of its own LP the bound is the plain total supply; the guard runs before any metadata or token
    // balances are read, so nothing beyond that is mocked.
    _bootstrap(_registry, _factory, _pool);
    _totalSupply = bound(_totalSupply, 1, type(uint256).max - 1);
    _liquidity = bound(_liquidity, _totalSupply + 1, type(uint256).max);

    _mockValidPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(_totalSupply));
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.balanceOf.selector, _pool), abi.encode(uint256(0)));

    // it reverts with LTS
    vm.expectRevert(bytes('LTS'));
    _quoter.quoteRemoveLiquidityV2(_pool, _liquidity);
  }

  function test_WhenTheLiquidityExceedsTheSupplyHeldOutsideThePool(
    address _registry,
    address _factory,
    address _pool,
    uint256 _liquidity,
    uint256 _held,
    uint256 _totalSupply
  ) external givenThePoolIsARegisteredTarget givenTheTargetFactoryIsApproved givenTheTotalSupplyIsNonzero {
    // burn() consumes all LP already held by the pool in addition to the quoted liquidity. Bound the quote above the
    // externally held supply while keeping it at or below totalSupply to isolate the held-LP-aware guard.
    _bootstrap(_registry, _factory, _pool);
    _totalSupply = bound(_totalSupply, 2, type(uint256).max);
    _held = bound(_held, 1, _totalSupply - 1);
    _liquidity = bound(_liquidity, _totalSupply - _held + 1, _totalSupply);

    _mockValidPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(_totalSupply));
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.balanceOf.selector, _pool), abi.encode(_held));

    // it reverts with LTS
    vm.expectRevert(bytes('LTS'));
    _quoter.quoteRemoveLiquidityV2(_pool, _liquidity);
  }

  function test_WhenAPoolBalanceExceedsItsReserve(
    address _registry,
    address _factory,
    address _pool,
    address _token0,
    address _token1,
    uint256 _liquidity,
    uint256 _reserve0,
    uint256 _reserve1,
    uint256 _totalSupply
  ) external givenThePoolIsARegisteredTarget givenTheTargetFactoryIsApproved givenTheTotalSupplyIsNonzero {
    // A donation leaves the pool's live balance above its bookkept reserve. Although burn() pays from live balances,
    // the quote uses min(balance, reserve) to exclude skimmable excess, i.e. the reserve here. balance0 is set to
    // reserve0 + totalSupply so the balance-based quote exceeds the reserve-based one by exactly `liquidity` (>= 1)
    // and floor division can never mask the difference. Bounds keep `liquidity * balance` within uint256.
    _bootstrap(_registry, _factory, _pool);
    _sanitize(_token0);
    _sanitize(_token1);
    vm.assume(_token0 != _token1);
    vm.assume(_token0 != _pool && _token0 != _registry && _token0 != _factory);
    vm.assume(_token1 != _pool && _token1 != _registry && _token1 != _factory);
    _totalSupply = bound(_totalSupply, 1, type(uint128).max);
    _liquidity = bound(_liquidity, 1, _totalSupply);
    uint256 _minimumBalance = _totalSupply / _liquidity + (_totalSupply % _liquidity == 0 ? 0 : 1);
    _reserve0 = bound(_reserve0, _minimumBalance, type(uint256).max / _liquidity - _totalSupply);
    _reserve1 = bound(_reserve1, _minimumBalance, type(uint256).max / _liquidity);
    uint256 _balance0 = _reserve0 + _totalSupply;

    _mockValidPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(_totalSupply));
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.balanceOf.selector, _pool), abi.encode(uint256(0)));
    _mockMetadataTokens(_pool, _reserve0, _reserve1, _token0, _token1);
    _mockAndExpect(_token0, abi.encodeWithSelector(IERC20.balanceOf.selector, _pool), abi.encode(_balance0));
    _mockAndExpect(_token1, abi.encodeWithSelector(IERC20.balanceOf.selector, _pool), abi.encode(_reserve1));

    (uint256 _amount0, uint256 _amount1) = _quoter.quoteRemoveLiquidityV2(_pool, _liquidity);

    // it quotes from the reserves
    assertEq(_amount0, (_liquidity * _reserve0) / _totalSupply);
    assertEq(_amount1, (_liquidity * _reserve1) / _totalSupply);
  }

  function test_WhenPoolBalancesAreBelowReserves(
    address _registry,
    address _factory,
    address _pool,
    address _token0,
    address _token1,
    uint256 _liquidity,
    uint256 _balance0,
    uint256 _balance1,
    uint256 _totalSupply
  ) external givenThePoolIsARegisteredTarget givenTheTargetFactoryIsApproved givenTheTotalSupplyIsNonzero {
    // Live balances below reserves exercise the balance side of min(balance, reserve). Span the full range while
    // keeping `liquidity * balance` (a SafeMath.mul) within uint256 and leaving room for a strictly larger reserve.
    _bootstrap(_registry, _factory, _pool);
    _sanitize(_token0);
    _sanitize(_token1);
    vm.assume(_token0 != _token1);
    vm.assume(_token0 != _pool && _token0 != _registry && _token0 != _factory);
    vm.assume(_token1 != _pool && _token1 != _registry && _token1 != _factory);
    _totalSupply = bound(_totalSupply, 1, type(uint128).max);
    _liquidity = bound(_liquidity, 1, _totalSupply);
    uint256 _balanceCap = type(uint256).max / _liquidity;
    if (_balanceCap == type(uint256).max) _balanceCap--;
    uint256 _minimumBalance = _totalSupply / _liquidity + (_totalSupply % _liquidity == 0 ? 0 : 1);
    _balance0 = bound(_balance0, _minimumBalance, _balanceCap);
    _balance1 = bound(_balance1, _minimumBalance, _balanceCap);

    _mockValidPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(_totalSupply));
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.balanceOf.selector, _pool), abi.encode(uint256(0)));
    _mockMetadataTokens(_pool, _balance0 + 1, _balance1 + 1, _token0, _token1);
    _mockAndExpect(_token0, abi.encodeWithSelector(IERC20.balanceOf.selector, _pool), abi.encode(_balance0));
    _mockAndExpect(_token1, abi.encodeWithSelector(IERC20.balanceOf.selector, _pool), abi.encode(_balance1));

    (uint256 _amount0, uint256 _amount1) = _quoter.quoteRemoveLiquidityV2(_pool, _liquidity);

    // it returns amount0 and amount1 proportional to the pool's live balances
    assertEq(_amount0, (_liquidity * _balance0) / _totalSupply);
    assertEq(_amount1, (_liquidity * _balance1) / _totalSupply);
  }

  function test_WhenOneBalanceExceedsItsReserveAndTheOtherIsBelow(
    address _registry,
    address _factory,
    address _pool,
    address _token0,
    address _token1
  ) external givenThePoolIsARegisteredTarget givenTheTargetFactoryIsApproved givenTheTotalSupplyIsNonzero {
    // The two sides are capped independently: token0 carries a donation above its reserve (capped down to the
    // reserve) while token1 sits below its reserve after an un-synced outflow (capped down to the live balance).
    // Both land on 1e18, so a cap wrongly applied across sides would show up in the quote.
    _bootstrap(_registry, _factory, _pool);
    _sanitizeTokens(_registry, _factory, _pool, _token0, _token1);

    _mockValidPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(1e18)));
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.balanceOf.selector, _pool), abi.encode(uint256(0)));
    _mockMetadataTokens(_pool, 1e18, 2e18, _token0, _token1);
    _mockAndExpect(_token0, abi.encodeWithSelector(IERC20.balanceOf.selector, _pool), abi.encode(uint256(3e18)));
    _mockAndExpect(_token1, abi.encodeWithSelector(IERC20.balanceOf.selector, _pool), abi.encode(uint256(1e18)));

    (uint256 _amount0, uint256 _amount1) = _quoter.quoteRemoveLiquidityV2(_pool, 5e17);

    // it caps each side independently
    assertEq(_amount0, 5e17);
    assertEq(_amount1, 5e17);
  }

  function test_WhenAStablePoolWouldHaveZeroResidualK(
    address _registry,
    address _factory,
    address _pool,
    address _token0,
    address _token1
  ) external givenThePoolIsARegisteredTarget givenTheTargetFactoryIsApproved givenTheTotalSupplyIsNonzero {
    // Burning all but the permanently locked LP leaves 1,000 wei per side. Both quoted outputs are positive, but a
    // stable pool rejects the burn because its residual normalized k rounds to zero.
    _bootstrap(_registry, _factory, _pool);
    _sanitize(_token0);
    _sanitize(_token1);
    vm.assume(_token0 != _token1);
    vm.assume(_token0 != _pool && _token0 != _registry && _token0 != _factory);
    vm.assume(_token1 != _pool && _token1 != _registry && _token1 != _factory);

    uint256 _totalSupply = 1e18;
    uint256 _liquidity = _totalSupply - _MINIMUM_LIQUIDITY;

    _mockValidPool(_registry, _factory, _pool, _V2_STABLE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(_totalSupply));
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.balanceOf.selector, _pool), abi.encode(uint256(0)));
    _mockMetadataTokens(_pool, 1e18, 1e18, _token0, _token1);
    _mockAndExpect(_token0, abi.encodeWithSelector(IERC20.balanceOf.selector, _pool), abi.encode(uint256(1e18)));
    _mockAndExpect(_token1, abi.encodeWithSelector(IERC20.balanceOf.selector, _pool), abi.encode(uint256(1e18)));

    // it reverts with KZ
    vm.expectRevert(bytes('KZ'));
    _quoter.quoteRemoveLiquidityV2(_pool, _liquidity);
  }

  function test_WhenAStablePoolRetainsANonzeroResidualK(
    address _registry,
    address _factory,
    address _pool,
    address _token0,
    address _token1
  ) external givenThePoolIsARegisteredTarget givenTheTargetFactoryIsApproved givenTheTotalSupplyIsNonzero {
    // The success side of the stable residual check, on a 6/18-decimal pair so the normalization actually does work:
    // burning half of a 1 USDC / 1 DAI pool leaves 0.5 on each side, normalizing to 5e17 apiece for a nonzero k.
    _bootstrap(_registry, _factory, _pool);
    _sanitizeTokens(_registry, _factory, _pool, _token0, _token1);

    _mockValidPool(_registry, _factory, _pool, _V2_STABLE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(1e18)));
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.balanceOf.selector, _pool), abi.encode(uint256(0)));
    _mockMetadataScaled(_pool, 1e6, 1e18, 1e6, 1e18, _token0, _token1);
    _mockAndExpect(_token0, abi.encodeWithSelector(IERC20.balanceOf.selector, _pool), abi.encode(uint256(1e6)));
    _mockAndExpect(_token1, abi.encodeWithSelector(IERC20.balanceOf.selector, _pool), abi.encode(uint256(1e18)));

    (uint256 _amount0, uint256 _amount1) = _quoter.quoteRemoveLiquidityV2(_pool, 5e17);

    // it returns amount0 and amount1 proportional to the pool's live balances
    assertEq(_amount0, 5e5);
    assertEq(_amount1, 5e17);
  }

  function test_WhenEitherAmountRoundsToZero(
    address _registry,
    address _factory,
    address _pool,
    address _token0,
    address _token1,
    bool _zeroAmount0
  ) external givenThePoolIsARegisteredTarget givenTheTargetFactoryIsApproved givenTheTotalSupplyIsNonzero {
    _bootstrap(_registry, _factory, _pool);
    _sanitize(_token0);
    _sanitize(_token1);
    vm.assume(_token0 != _token1);
    vm.assume(_token0 != _pool && _token0 != _registry && _token0 != _factory);
    vm.assume(_token1 != _pool && _token1 != _registry && _token1 != _factory);

    uint256 _balance0 = _zeroAmount0 ? 1 : 2e18;
    uint256 _balance1 = _zeroAmount0 ? 2e18 : 1;

    _mockValidPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(uint256(2e18)));
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.balanceOf.selector, _pool), abi.encode(uint256(0)));
    _mockMetadataTokens(_pool, _balance0, _balance1, _token0, _token1);
    _mockAndExpect(_token0, abi.encodeWithSelector(IERC20.balanceOf.selector, _pool), abi.encode(_balance0));
    _mockAndExpect(_token1, abi.encodeWithSelector(IERC20.balanceOf.selector, _pool), abi.encode(_balance1));

    // Burning one LP wei makes one side round to zero, which burn() rejects.
    vm.expectRevert(bytes('ILB'));
    _quoter.quoteRemoveLiquidityV2(_pool, 1);
  }

  function test_WhenThePoolAlreadyHoldsLiquidity(
    address _registry,
    address _factory,
    address _pool,
    address _token0,
    address _token1
  ) external givenThePoolIsARegisteredTarget givenTheTargetFactoryIsApproved givenTheTotalSupplyIsNonzero {
    // burn() burns balanceOf(address(this)) — the pool's whole LP balance — not just the amount the caller pushes in.
    // With 9e13 LP already sitting in the pool, execution burns 1e18 - 1e13 rather than the 1e18 - 1e14 requested,
    // leaving a residual of 1e13 whose k floors to zero. Quoting the residual from the requested amount alone models
    // 1e14, whose k is nonzero, so the quote would pass on a burn the pool reverts with KIsZero.
    _bootstrap(_registry, _factory, _pool);
    _sanitizeTokens(_registry, _factory, _pool, _token0, _token1);

    uint256 _totalSupply = 1e18;
    uint256 _liquidity = _totalSupply - 1e14;

    _mockValidPool(_registry, _factory, _pool, _V2_STABLE_POOL_TYPE);
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.totalSupply.selector), abi.encode(_totalSupply));
    _mockAndExpect(_pool, abi.encodeWithSelector(IERC20.balanceOf.selector, _pool), abi.encode(uint256(9e13)));
    _mockMetadataTokens(_pool, _totalSupply, _totalSupply, _token0, _token1);
    _mockAndExpect(_token0, abi.encodeWithSelector(IERC20.balanceOf.selector, _pool), abi.encode(_totalSupply));
    _mockAndExpect(_token1, abi.encodeWithSelector(IERC20.balanceOf.selector, _pool), abi.encode(_totalSupply));

    // it reverts with KZ
    vm.expectRevert(bytes('KZ'));
    _quoter.quoteRemoveLiquidityV2(_pool, _liquidity);
  }
}
