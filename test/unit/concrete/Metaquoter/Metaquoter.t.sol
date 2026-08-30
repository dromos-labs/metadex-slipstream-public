// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.7.6;
pragma abicoder v2;

import {UnitMetaquoterBase} from 'test/unit/concrete/Metaquoter/MetaquoterBase.sol';

import {ICLPoolActions} from 'contracts/core/interfaces/pool/ICLPoolActions.sol';
import {ICLPoolConstants} from 'contracts/core/interfaces/pool/ICLPoolConstants.sol';
import {ICLPoolState} from 'contracts/core/interfaces/pool/ICLPoolState.sol';

import {IPoolFactoryV3} from 'contracts/periphery/interfaces/IPoolFactoryV3.sol';
import {IV2Pool} from 'contracts/periphery/interfaces/IV2Pool.sol';
import {IV3FactoryRegistry} from 'contracts/periphery/interfaces/IV3FactoryRegistry.sol';

contract UnitMetaquoter is UnitMetaquoterBase {
  /*////////////////////////////////////////////////////////////
                      QUOTE EXACT OUTPUT
  ////////////////////////////////////////////////////////////*/

  function test_QuoteExactOutputWhenThePathIsEmpty(address _registry, uint256 _amountOut) external {
    _bootstrapRegistry(_registry);

    // it reverts with EP
    vm.expectRevert(bytes('EP'));
    _quoter.quoteExactOutput(new address[](0), _tokenLow, _amountOut);
  }

  modifier givenThePathIsNotEmpty() {
    _;
  }

  function test_QuoteExactOutputWhenAPoolFactoryIsNotApproved(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountOut
  ) external givenThePathIsNotEmpty {
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
    _quoter.quoteExactOutput(_route(_pool), _tokenLow, _amountOut);
  }

  modifier givenThePoolFactoryIsApproved() {
    _;
  }

  function test_QuoteExactOutputWhenThePoolIsNotARegisteredTarget(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountOut
  ) external givenThePathIsNotEmpty givenThePoolFactoryIsApproved {
    _bootstrap(_registry, _factory, _pool);

    _mockAndExpect(
      _registry, abi.encodeWithSelector(IV3FactoryRegistry.targetToFactory.selector, _pool), abi.encode(address(0))
    );

    // it reverts with IP
    vm.expectRevert(bytes('IP'));
    _quoter.quoteExactOutput(_route(_pool), _tokenLow, _amountOut);
  }

  modifier givenThePoolIsARegisteredTarget() {
    _;
  }

  function test_QuoteExactOutputWhenTokenInIsNotATokenOfItsHopPool(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountOut
  ) external givenThePathIsNotEmpty givenThePoolFactoryIsApproved givenThePoolIsARegisteredTarget {
    _bootstrap(_registry, _factory, _pool);
    _mockPool(_registry, _factory, _pool, _CL_POOL_TYPE, _tokenLow, _tokenHigh);

    // it reverts with TI
    vm.expectRevert(bytes('TI'));
    _quoter.quoteExactOutput(_route(_pool), _tokenMid, _amountOut);
  }

  modifier givenTokenInIsATokenOfItsHopPool() {
    _;
  }

  function test_QuoteExactOutputWhenTheRouteIsASingleCLPool(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountOut
  )
    external
    givenThePathIsNotEmpty
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenTokenInIsATokenOfItsHopPool
  {
    _bootstrap(_registry, _factory, _pool);
    _amountOut = bound(_amountOut, 1, uint256(type(int256).max));

    // pinned so the assertion checks a concrete decoded quote, not a value tied to the mock
    uint256 _expectedAmountIn = 2e18;
    uint160 _expectedSqrtPrice = uint160(3e18);

    _mockPool(_registry, _factory, _pool, _CL_POOL_TYPE, _tokenLow, _tokenHigh);
    // it sizes the hop input from the exact output
    // (the swap mock only matches the negated exact-output amount)
    vm.mockCallRevert(
      _pool,
      abi.encodeWithSelector(
        ICLPoolActions.swap.selector,
        address(_quoter),
        true,
        -int256(_amountOut),
        _MIN_PRICE_LIMIT,
        abi.encode(_pool, false, _amountOut)
      ),
      abi.encode(_expectedAmountIn, _expectedSqrtPrice, int24(0))
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(uint160(0), int24(0), uint16(0), uint16(0), uint16(0), false)
    );
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(int24(1)));
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolState.tickBitmap.selector, int16(0)), abi.encode(uint256(0)));

    (uint256 _amountIn, uint160[] memory _sqrtPriceX96AfterList, uint32[] memory _initializedTicksCrossedList) =
      _quoter.quoteExactOutput(_route(_pool), _tokenLow, _amountOut);

    assertEq(_amountIn, _expectedAmountIn);
    // it populates the lists at the pool index
    assertEq(_sqrtPriceX96AfterList.length, 1);
    assertEq(_initializedTicksCrossedList.length, 1);
    assertEq(uint256(_sqrtPriceX96AfterList[0]), _expectedSqrtPrice);
    assertEq(uint256(_initializedTicksCrossedList[0]), 0);
  }

  function test_QuoteExactOutputWhenTheRouteHasMultipleCLHops(
    address _registry,
    address _factory,
    address _pool,
    address _pool2,
    uint256 _amountOut
  )
    external
    givenThePathIsNotEmpty
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenTokenInIsATokenOfItsHopPool
  {
    _bootstrap(_registry, _factory, _pool);
    _sanitize(_pool2);
    vm.assume(_pool2 != _registry && _pool2 != _factory && _pool2 != _pool && _pool2 != address(_quoter));
    _amountOut = bound(_amountOut, 1, uint256(type(int256).max));

    // pinned so each backward-sized hop is concrete: the last pool's input (4e18) must feed the first pool's target
    uint256 _hopAmountIn = 4e18;
    uint256 _expectedAmountIn = 9e18;
    uint160 _expectedSqrtPrice = uint160(5e18);
    uint160 _expectedSqrtPrice2 = uint160(6e18);

    // Forward route tokenLow -> tokenMid -> tokenHigh; the last pool is quoted first with the exact output and its
    // input becomes the previous pool's output target.
    _mockPool(_registry, _factory, _pool, _CL_POOL_TYPE, _tokenLow, _tokenMid);
    _mockPool(_registry, _factory, _pool2, _CL_POOL_TYPE, _tokenMid, _tokenHigh);
    // it sizes each hop input backward from the exact output
    // (each swap mock only matches its hop's negated amount: the exact output, then the last hop's input)
    vm.mockCallRevert(
      _pool2,
      abi.encodeWithSelector(
        ICLPoolActions.swap.selector,
        address(_quoter),
        true,
        -int256(_amountOut),
        _MIN_PRICE_LIMIT,
        abi.encode(_pool2, false, _amountOut)
      ),
      abi.encode(_hopAmountIn, _expectedSqrtPrice2, int24(0))
    );
    _mockAndExpect(
      _pool2,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(uint160(0), int24(0), uint16(0), uint16(0), uint16(0), false)
    );
    _mockAndExpect(_pool2, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(int24(1)));
    _mockAndExpect(_pool2, abi.encodeWithSelector(ICLPoolState.tickBitmap.selector, int16(0)), abi.encode(uint256(0)));
    vm.mockCallRevert(
      _pool,
      abi.encodeWithSelector(
        ICLPoolActions.swap.selector,
        address(_quoter),
        true,
        -int256(_hopAmountIn),
        _MIN_PRICE_LIMIT,
        abi.encode(_pool, false, _hopAmountIn)
      ),
      abi.encode(_expectedAmountIn, _expectedSqrtPrice, int24(0))
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(uint160(0), int24(0), uint16(0), uint16(0), uint16(0), false)
    );
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(int24(1)));
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolState.tickBitmap.selector, int16(0)), abi.encode(uint256(0)));

    address[] memory _pools = new address[](2);
    _pools[0] = _pool;
    _pools[1] = _pool2;
    (uint256 _amountIn, uint160[] memory _sqrtPriceX96AfterList, uint32[] memory _initializedTicksCrossedList) =
      _quoter.quoteExactOutput(_pools, _tokenLow, _amountOut);

    // it populates the lists at each index
    assertEq(uint256(_sqrtPriceX96AfterList[0]), _expectedSqrtPrice);
    assertEq(uint256(_sqrtPriceX96AfterList[1]), _expectedSqrtPrice2);
    assertEq(uint256(_initializedTicksCrossedList[0]), 0);
    assertEq(uint256(_initializedTicksCrossedList[1]), 0);
    // it returns the first hop input as amountIn
    assertEq(_amountIn, _expectedAmountIn);
  }

  function test_QuoteExactOutputWhenTheRouteIsASingleV2Pool(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountOut
  )
    external
    givenThePathIsNotEmpty
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenTokenInIsATokenOfItsHopPool
  {
    _bootstrap(_registry, _factory, _pool);

    // pinned so the assertion checks a concrete quote, not a value tied to the mock
    uint256 _expectedAmountIn = 2e18;

    _mockPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE, _tokenLow, _tokenHigh);
    // the pool getter is addressed by the output token, so the hop's counterpart token is what it is asked about
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(IV2Pool.getAmountInWithTotalFee.selector, _amountOut, _tokenHigh),
      abi.encode(_expectedAmountIn)
    );

    (uint256 _amountIn, uint160[] memory _sqrtPriceX96AfterList, uint32[] memory _initializedTicksCrossedList) =
      _quoter.quoteExactOutput(_route(_pool), _tokenLow, _amountOut);

    // it returns the getAmountInWithTotalFee quote
    assertEq(_amountIn, _expectedAmountIn);
    // it leaves the lists zeroed at the pool index
    assertEq(_sqrtPriceX96AfterList.length, 1);
    assertEq(_initializedTicksCrossedList.length, 1);
    assertEq(uint256(_sqrtPriceX96AfterList[0]), 0);
    assertEq(uint256(_initializedTicksCrossedList[0]), 0);
  }

  function test_QuoteExactOutputWhenTheRouteMixesCLAndV2Hops(
    address _registry,
    address _factory,
    address _pool,
    address _pool2,
    uint256 _amountOut
  )
    external
    givenThePathIsNotEmpty
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenTokenInIsATokenOfItsHopPool
  {
    _bootstrap(_registry, _factory, _pool);
    _sanitize(_pool2);
    vm.assume(_pool2 != _registry && _pool2 != _factory && _pool2 != _pool && _pool2 != address(_quoter));
    _amountOut = bound(_amountOut, 1, uint256(type(int256).max));

    // pinned so each backward-sized hop is concrete: the V2 hop's input (4e18) must become the CL hop's output target
    uint256 _hopAmountIn = 4e18;
    uint256 _expectedAmountIn = 9e18;
    uint160 _expectedSqrtPrice = uint160(5e18);

    // Forward route tokenLow -> tokenMid -> tokenHigh: a CL hop then a V2 hop. The V2 pool is quoted first with the
    // exact output and its input becomes the CL pool's output target.
    _mockPool(_registry, _factory, _pool, _CL_POOL_TYPE, _tokenLow, _tokenMid);
    // the V2 pool never receives CL calls, so it is mocked without slot0, tickSpacing or tickBitmap
    _mockPool(_registry, _factory, _pool2, _V2_STABLE_POOL_TYPE, _tokenMid, _tokenHigh);
    // it sizes each hop input backward through both pool kinds
    // (the V2 mock only matches the exact output, and the CL swap mock only matches the V2 hop's negated input)
    _mockAndExpect(
      _pool2,
      abi.encodeWithSelector(IV2Pool.getAmountInWithTotalFee.selector, _amountOut, _tokenHigh),
      abi.encode(_hopAmountIn)
    );
    vm.mockCallRevert(
      _pool,
      abi.encodeWithSelector(
        ICLPoolActions.swap.selector,
        address(_quoter),
        true,
        -int256(_hopAmountIn),
        _MIN_PRICE_LIMIT,
        abi.encode(_pool, false, _hopAmountIn)
      ),
      abi.encode(_expectedAmountIn, _expectedSqrtPrice, int24(0))
    );
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(uint160(0), int24(0), uint16(0), uint16(0), uint16(0), false)
    );
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector), abi.encode(int24(1)));
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolState.tickBitmap.selector, int16(0)), abi.encode(uint256(0)));

    address[] memory _pools = new address[](2);
    _pools[0] = _pool;
    _pools[1] = _pool2;
    (uint256 _amountIn, uint160[] memory _sqrtPriceX96AfterList, uint32[] memory _initializedTicksCrossedList) =
      _quoter.quoteExactOutput(_pools, _tokenLow, _amountOut);

    // it populates only the CL entries
    assertEq(uint256(_sqrtPriceX96AfterList[0]), _expectedSqrtPrice);
    assertEq(uint256(_initializedTicksCrossedList[0]), 0);
    assertEq(uint256(_sqrtPriceX96AfterList[1]), 0);
    assertEq(uint256(_initializedTicksCrossedList[1]), 0);
    // it returns the first hop input as amountIn
    assertEq(_amountIn, _expectedAmountIn);
  }

  function test_QuoteExactOutputWhenAPoolReportsAnUnknownPoolType(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountOut
  )
    external
    givenThePathIsNotEmpty
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenTokenInIsATokenOfItsHopPool
  {
    _bootstrap(_registry, _factory, _pool);
    // mocked without _mockPool: the type check short-circuits, so the reads it expects never happen
    vm.mockCall(
      _registry, abi.encodeWithSelector(IV3FactoryRegistry.targetToFactory.selector, _pool), abi.encode(_factory)
    );
    vm.mockCall(
      _registry, abi.encodeWithSelector(IV3FactoryRegistry.isTargetFactoryApproved.selector, _factory), abi.encode(true)
    );
    vm.mockCall(_pool, abi.encodeWithSelector(ICLPoolConstants.POOL_TYPE.selector), abi.encode(bytes32('UNKNOWN')));

    // it does not read the factory pause flag
    // an unsupported label must fail on its own type, not on a getter its factory may not implement
    vm.expectCall(_factory, abi.encodeWithSelector(IPoolFactoryV3.isPaused.selector), 0);

    // it does not read the pool tokens
    vm.expectCall(_pool, abi.encodeWithSelector(ICLPoolConstants.token0.selector), 0);

    // it reverts with PT
    vm.expectRevert(bytes('PT'));
    _quoter.quoteExactOutput(_route(_pool), _tokenLow, _amountOut);
  }

  function test_QuoteExactOutputWhenAV2HopQuotesZeroInput(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountOut
  )
    external
    givenThePathIsNotEmpty
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenTokenInIsATokenOfItsHopPool
  {
    _bootstrap(_registry, _factory, _pool);

    // a hop that prices its output at zero input cannot execute, and it would also leave every hop upstream of it
    // with nothing to size against
    _mockPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE, _tokenLow, _tokenHigh);
    _mockAndExpect(
      _pool, abi.encodeWithSelector(IV2Pool.getAmountInWithTotalFee.selector, _amountOut, _tokenHigh), abi.encode(0)
    );

    // it reverts with II
    vm.expectRevert(bytes('II'));
    _quoter.quoteExactOutput(_route(_pool), _tokenLow, _amountOut);
  }

  /*////////////////////////////////////////////////////////////
                  QUOTE EXACT INPUT SINGLE V2
  ////////////////////////////////////////////////////////////*/

  function test_QuoteExactInputSingleV2WhenThePoolFactoryIsNotApproved(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountIn
  ) external {
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
    _quoter.quoteExactInputSingleV2(_pool, _tokenLow, _amountIn);
  }

  function test_QuoteExactInputSingleV2WhenThePoolIsNotARegisteredTarget(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountIn
  ) external givenThePoolFactoryIsApproved {
    _bootstrap(_registry, _factory, _pool);

    _mockAndExpect(
      _registry, abi.encodeWithSelector(IV3FactoryRegistry.targetToFactory.selector, _pool), abi.encode(address(0))
    );

    // it reverts with IP
    vm.expectRevert(bytes('IP'));
    _quoter.quoteExactInputSingleV2(_pool, _tokenLow, _amountIn);
  }

  function test_QuoteExactInputSingleV2WhenThePoolTypeIsNotAV2Type(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountIn
  ) external givenThePoolFactoryIsApproved givenThePoolIsARegisteredTarget {
    _bootstrap(_registry, _factory, _pool);
    _mockPool(_registry, _factory, _pool, _CL_POOL_TYPE, _tokenLow, _tokenHigh);

    // it reverts with PT
    vm.expectRevert(bytes('PT'));
    _quoter.quoteExactInputSingleV2(_pool, _tokenLow, _amountIn);
  }

  modifier givenThePoolTypeIsAV2Type() {
    _;
  }

  function test_QuoteExactInputSingleV2WhenThePoolFactoryIsPaused(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountIn
  ) external givenThePoolFactoryIsApproved givenThePoolIsARegisteredTarget givenThePoolTypeIsAV2Type {
    _bootstrap(_registry, _factory, _pool);
    _mockAndExpect(
      _registry, abi.encodeWithSelector(IV3FactoryRegistry.targetToFactory.selector, _pool), abi.encode(_factory)
    );
    _mockAndExpect(
      _registry, abi.encodeWithSelector(IV3FactoryRegistry.isTargetFactoryApproved.selector, _factory), abi.encode(true)
    );
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.POOL_TYPE.selector), abi.encode(_V2_STABLE_POOL_TYPE));
    _mockAndExpect(_factory, abi.encodeWithSelector(IPoolFactoryV3.isPaused.selector), abi.encode(true));

    // it reverts with PS
    vm.expectRevert(bytes('PS'));
    _quoter.quoteExactInputSingleV2(_pool, _tokenLow, _amountIn);
  }

  function test_QuoteExactInputSingleV2WhenTokenInIsNotAPoolToken(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountIn
  ) external givenThePoolFactoryIsApproved givenThePoolIsARegisteredTarget givenThePoolTypeIsAV2Type {
    _bootstrap(_registry, _factory, _pool);
    _mockPool(_registry, _factory, _pool, _V2_STABLE_POOL_TYPE, _tokenLow, _tokenHigh);

    // it reverts with TI
    vm.expectRevert(bytes('TI'));
    _quoter.quoteExactInputSingleV2(_pool, _tokenMid, _amountIn);
  }

  modifier givenTokenInIsAPoolToken() {
    _;
  }

  function test_QuoteExactInputSingleV2WhenThePoolIsV2Stable(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountIn
  )
    external
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenThePoolTypeIsAV2Type
    givenTokenInIsAPoolToken
  {
    _bootstrap(_registry, _factory, _pool);

    // pinned so the assertion checks a concrete quote, not a value tied to the mock
    uint256 _expectedAmountOut = 2e18;

    _mockPool(_registry, _factory, _pool, _V2_STABLE_POOL_TYPE, _tokenLow, _tokenHigh);
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(IV2Pool.getAmountOutWithTotalFee.selector, _amountIn, _tokenLow),
      abi.encode(_expectedAmountOut)
    );

    // it returns the getAmountOutWithTotalFee quote
    assertEq(_quoter.quoteExactInputSingleV2(_pool, _tokenLow, _amountIn), _expectedAmountOut);
  }

  function test_QuoteExactInputSingleV2WhenThePoolIsV2Volatile(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountIn
  )
    external
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenThePoolTypeIsAV2Type
    givenTokenInIsAPoolToken
  {
    _bootstrap(_registry, _factory, _pool);

    // pinned so the assertion checks a concrete quote, not a value tied to the mock
    uint256 _expectedAmountOut = 2e18;

    _mockPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE, _tokenLow, _tokenHigh);
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(IV2Pool.getAmountOutWithTotalFee.selector, _amountIn, _tokenHigh),
      abi.encode(_expectedAmountOut)
    );

    // it returns the getAmountOutWithTotalFee quote
    assertEq(_quoter.quoteExactInputSingleV2(_pool, _tokenHigh, _amountIn), _expectedAmountOut);
  }

  function test_QuoteExactInputSingleV2WhenThePoolQuotesZeroOutput(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountIn
  )
    external
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenThePoolTypeIsAV2Type
    givenTokenInIsAPoolToken
  {
    _bootstrap(_registry, _factory, _pool);

    // dust rounds the pool's own quote down to zero, and Pool.swap reverts InsufficientOutputAmount on a swap that
    // moves nothing: quoting zero would describe a trade that cannot execute
    _mockPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE, _tokenLow, _tokenHigh);
    _mockAndExpect(
      _pool, abi.encodeWithSelector(IV2Pool.getAmountOutWithTotalFee.selector, _amountIn, _tokenLow), abi.encode(0)
    );

    // it reverts with IO
    vm.expectRevert(bytes('IO'));
    _quoter.quoteExactInputSingleV2(_pool, _tokenLow, _amountIn);
  }

  /*////////////////////////////////////////////////////////////
                  QUOTE EXACT OUTPUT SINGLE V2
  ////////////////////////////////////////////////////////////*/

  function test_QuoteExactOutputSingleV2WhenThePoolFactoryIsNotApproved(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountOut
  ) external {
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
    _quoter.quoteExactOutputSingleV2(_pool, _tokenLow, _amountOut);
  }

  function test_QuoteExactOutputSingleV2WhenThePoolIsNotARegisteredTarget(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountOut
  ) external givenThePoolFactoryIsApproved {
    _bootstrap(_registry, _factory, _pool);

    _mockAndExpect(
      _registry, abi.encodeWithSelector(IV3FactoryRegistry.targetToFactory.selector, _pool), abi.encode(address(0))
    );

    // it reverts with IP
    vm.expectRevert(bytes('IP'));
    _quoter.quoteExactOutputSingleV2(_pool, _tokenLow, _amountOut);
  }

  function test_QuoteExactOutputSingleV2WhenThePoolTypeIsNotAV2Type(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountOut
  ) external givenThePoolFactoryIsApproved givenThePoolIsARegisteredTarget {
    _bootstrap(_registry, _factory, _pool);
    _mockPool(_registry, _factory, _pool, _CL_POOL_TYPE, _tokenLow, _tokenHigh);

    // it reverts with PT
    vm.expectRevert(bytes('PT'));
    _quoter.quoteExactOutputSingleV2(_pool, _tokenLow, _amountOut);
  }

  function test_QuoteExactOutputSingleV2WhenThePoolFactoryIsPaused(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountOut
  ) external givenThePoolFactoryIsApproved givenThePoolIsARegisteredTarget givenThePoolTypeIsAV2Type {
    _bootstrap(_registry, _factory, _pool);
    _mockAndExpect(
      _registry, abi.encodeWithSelector(IV3FactoryRegistry.targetToFactory.selector, _pool), abi.encode(_factory)
    );
    _mockAndExpect(
      _registry, abi.encodeWithSelector(IV3FactoryRegistry.isTargetFactoryApproved.selector, _factory), abi.encode(true)
    );
    _mockAndExpect(_pool, abi.encodeWithSelector(ICLPoolConstants.POOL_TYPE.selector), abi.encode(_V2_STABLE_POOL_TYPE));
    _mockAndExpect(_factory, abi.encodeWithSelector(IPoolFactoryV3.isPaused.selector), abi.encode(true));

    // it reverts with PS
    vm.expectRevert(bytes('PS'));
    _quoter.quoteExactOutputSingleV2(_pool, _tokenLow, _amountOut);
  }

  function test_QuoteExactOutputSingleV2WhenTokenInIsNotAPoolToken(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountOut
  ) external givenThePoolFactoryIsApproved givenThePoolIsARegisteredTarget givenThePoolTypeIsAV2Type {
    _bootstrap(_registry, _factory, _pool);
    _mockPool(_registry, _factory, _pool, _V2_STABLE_POOL_TYPE, _tokenLow, _tokenHigh);

    // it reverts with TI
    vm.expectRevert(bytes('TI'));
    _quoter.quoteExactOutputSingleV2(_pool, _tokenMid, _amountOut);
  }

  function test_QuoteExactOutputSingleV2WhenThePoolIsV2Stable(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountOut
  )
    external
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenThePoolTypeIsAV2Type
    givenTokenInIsAPoolToken
  {
    _bootstrap(_registry, _factory, _pool);

    // pinned so the assertion checks a concrete quote, not a value tied to the mock
    uint256 _expectedAmountIn = 2e18;

    _mockPool(_registry, _factory, _pool, _V2_STABLE_POOL_TYPE, _tokenLow, _tokenHigh);
    // the API is tokenIn-addressed but the pool getter is addressed by the output token
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(IV2Pool.getAmountInWithTotalFee.selector, _amountOut, _tokenHigh),
      abi.encode(_expectedAmountIn)
    );

    // it returns the getAmountInWithTotalFee quote
    assertEq(_quoter.quoteExactOutputSingleV2(_pool, _tokenLow, _amountOut), _expectedAmountIn);
  }

  function test_QuoteExactOutputSingleV2WhenThePoolIsV2Volatile(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountOut
  )
    external
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenThePoolTypeIsAV2Type
    givenTokenInIsAPoolToken
  {
    _bootstrap(_registry, _factory, _pool);

    // pinned so the assertion checks a concrete quote, not a value tied to the mock
    uint256 _expectedAmountIn = 2e18;

    _mockPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE, _tokenLow, _tokenHigh);
    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(IV2Pool.getAmountInWithTotalFee.selector, _amountOut, _tokenLow),
      abi.encode(_expectedAmountIn)
    );

    // it returns the getAmountInWithTotalFee quote
    assertEq(_quoter.quoteExactOutputSingleV2(_pool, _tokenHigh, _amountOut), _expectedAmountIn);
  }

  function test_QuoteExactOutputSingleV2WhenThePoolQuotesZeroInput(
    address _registry,
    address _factory,
    address _pool,
    uint256 _amountOut
  )
    external
    givenThePoolFactoryIsApproved
    givenThePoolIsARegisteredTarget
    givenThePoolTypeIsAV2Type
    givenTokenInIsAPoolToken
  {
    _bootstrap(_registry, _factory, _pool);

    // dust rounds the pool's own quote down to zero, and a swap that pays nothing cannot execute: quoting zero would
    // describe a trade the pool rejects
    _mockPool(_registry, _factory, _pool, _V2_VOLATILE_POOL_TYPE, _tokenLow, _tokenHigh);
    _mockAndExpect(
      _pool, abi.encodeWithSelector(IV2Pool.getAmountInWithTotalFee.selector, _amountOut, _tokenHigh), abi.encode(0)
    );

    // it reverts with II
    vm.expectRevert(bytes('II'));
    _quoter.quoteExactOutputSingleV2(_pool, _tokenLow, _amountOut);
  }

  /*////////////////////////////////////////////////////////////
                    UNISWAP V3 SWAP CALLBACK
  ////////////////////////////////////////////////////////////*/

  function test_UniswapV3SwapCallbackWhenBothDeltasAreNonPositive(
    address _registry,
    int256 _amount0Delta,
    int256 _amount1Delta
  ) external {
    _bootstrapRegistry(_registry);
    _amount0Delta = bound(_amount0Delta, type(int256).min, 0);
    _amount1Delta = bound(_amount1Delta, type(int256).min, 0);

    // it reverts with ZL
    vm.expectRevert(bytes('ZL'));
    _quoter.uniswapV3SwapCallback(_amount0Delta, _amount1Delta, '');
  }

  modifier givenAPositiveDelta() {
    _;
  }

  function test_UniswapV3SwapCallbackWhenTheCallerIsNotTheEncodedPool(
    address _registry,
    address _factory,
    address _pool,
    int256 _amount0Delta
  ) external givenAPositiveDelta {
    _bootstrap(_registry, _factory, _pool);
    _amount0Delta = bound(_amount0Delta, 1, type(int256).max);

    // it reverts with MS
    vm.expectRevert(bytes('MS'));
    _quoter.uniswapV3SwapCallback(_amount0Delta, 0, abi.encode(_pool, true, uint256(0)));
  }

  modifier givenTheCallerIsTheEncodedPool() {
    _;
  }

  modifier givenAnExactInputSimulation() {
    _;
  }

  function test_UniswapV3SwapCallbackWhenTheInputTokenIsToken0(
    address _registry,
    address _factory,
    address _pool,
    int256 _amount0Delta,
    int256 _amount1Delta,
    uint160 _sqrtPriceX96,
    int24 _tick
  ) external givenAPositiveDelta givenTheCallerIsTheEncodedPool givenAnExactInputSimulation {
    // amount, the negated amount1Delta.
    _bootstrap(_registry, _factory, _pool);
    _amount0Delta = bound(_amount0Delta, 1, type(int256).max);
    _amount1Delta = bound(_amount1Delta, type(int256).min + 1, 0);

    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(_sqrtPriceX96, _tick, uint16(0), uint16(0), uint16(0), false)
    );

    // it reverts with the received amount and the pool price and tick
    vm.expectRevert(abi.encode(uint256(-_amount1Delta), _sqrtPriceX96, _tick));
    vm.prank(_pool);
    _quoter.uniswapV3SwapCallback(_amount0Delta, _amount1Delta, abi.encode(_pool, true, uint256(0)));
  }

  function test_UniswapV3SwapCallbackWhenTheInputTokenIsToken1(
    address _registry,
    address _factory,
    address _pool,
    int256 _amount0Delta,
    int256 _amount1Delta,
    uint160 _sqrtPriceX96,
    int24 _tick
  ) external givenAPositiveDelta givenTheCallerIsTheEncodedPool givenAnExactInputSimulation {
    // Paying token1 for token0 is an exact input: the payload carries the received amount, the negated amount0Delta.
    // Direction now comes solely from which delta is positive, independently of the exactness flag.
    _bootstrap(_registry, _factory, _pool);
    _amount0Delta = bound(_amount0Delta, type(int256).min + 1, 0);
    _amount1Delta = bound(_amount1Delta, 1, type(int256).max);

    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(_sqrtPriceX96, _tick, uint16(0), uint16(0), uint16(0), false)
    );

    // it reverts with the received amount and the pool price and tick
    vm.expectRevert(abi.encode(uint256(-_amount0Delta), _sqrtPriceX96, _tick));
    vm.prank(_pool);
    _quoter.uniswapV3SwapCallback(_amount0Delta, _amount1Delta, abi.encode(_pool, true, uint256(0)));
  }

  modifier givenAnExactOutputSimulation() {
    _;
  }

  function test_UniswapV3SwapCallbackWhenNoOutputIsExpected(
    address _registry,
    address _factory,
    address _pool,
    int256 _amount0Delta,
    int256 _amount1Delta,
    uint160 _sqrtPriceX96,
    int24 _tick
  ) external givenAPositiveDelta givenTheCallerIsTheEncodedPool givenAnExactOutputSimulation {
    // Paying token0 with tokenIn = token1 > tokenOut is an exact output: with no expected output the payload carries
    // the payable amount, amount0Delta.
    _bootstrap(_registry, _factory, _pool);
    _amount0Delta = bound(_amount0Delta, 1, type(int256).max);
    _amount1Delta = bound(_amount1Delta, type(int256).min + 1, 0);

    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(_sqrtPriceX96, _tick, uint16(0), uint16(0), uint16(0), false)
    );

    // it reverts with the payable amount and the pool price and tick
    vm.expectRevert(abi.encode(uint256(_amount0Delta), _sqrtPriceX96, _tick));
    vm.prank(_pool);
    _quoter.uniswapV3SwapCallback(_amount0Delta, _amount1Delta, abi.encode(_pool, false, uint256(0)));
  }

  modifier givenAnOutputIsExpected() {
    _;
  }

  function test_UniswapV3SwapCallbackWhenTheReceivedAmountDiffersFromTheExpectedOutput(
    address _registry,
    address _factory,
    address _pool,
    int256 _amount0Delta,
    int256 _amount1Delta,
    uint160 _sqrtPriceX96,
    int24 _tick,
    uint256 _amountOutExpected
  ) external givenAPositiveDelta givenTheCallerIsTheEncodedPool givenAnExactOutputSimulation givenAnOutputIsExpected {
    _bootstrap(_registry, _factory, _pool);
    _amount0Delta = bound(_amount0Delta, 1, type(int256).max);
    _amount1Delta = bound(_amount1Delta, type(int256).min + 1, 0);
    _amountOutExpected = bound(_amountOutExpected, 1, type(uint256).max);
    vm.assume(_amountOutExpected != uint256(-_amount1Delta));

    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(_sqrtPriceX96, _tick, uint16(0), uint16(0), uint16(0), false)
    );

    // it reverts with OC
    vm.expectRevert(bytes('OC'));
    vm.prank(_pool);
    _quoter.uniswapV3SwapCallback(_amount0Delta, _amount1Delta, abi.encode(_pool, false, _amountOutExpected));
  }

  function test_UniswapV3SwapCallbackWhenTheReceivedAmountMatchesTheExpectedOutput(
    address _registry,
    address _factory,
    address _pool,
    int256 _amount0Delta,
    int256 _amount1Delta,
    uint160 _sqrtPriceX96,
    int24 _tick
  ) external givenAPositiveDelta givenTheCallerIsTheEncodedPool givenAnExactOutputSimulation givenAnOutputIsExpected {
    _bootstrap(_registry, _factory, _pool);
    _amount0Delta = bound(_amount0Delta, 1, type(int256).max);
    _amount1Delta = bound(_amount1Delta, type(int256).min + 1, -1);

    _mockAndExpect(
      _pool,
      abi.encodeWithSelector(ICLPoolState.slot0.selector),
      abi.encode(_sqrtPriceX96, _tick, uint16(0), uint16(0), uint16(0), false)
    );

    // it reverts with the payable amount and the pool price and tick
    vm.expectRevert(abi.encode(uint256(_amount0Delta), _sqrtPriceX96, _tick));
    vm.prank(_pool);
    _quoter.uniswapV3SwapCallback(_amount0Delta, _amount1Delta, abi.encode(_pool, false, uint256(-_amount1Delta)));
  }
}
