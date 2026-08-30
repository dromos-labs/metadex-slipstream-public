pragma solidity =0.7.6;
pragma abicoder v2;

import {ICLFactoryIndexation, UnitCLFactoryIndexation} from '../CLFactoryIndexation.t.sol';

contract UnitCLFactoryIndexationPoolsIndexPaginated is UnitCLFactoryIndexation {
  function test_WhenEndIsLtOrEqStart(uint256 _start, uint256 _end) external {
    _start = bound(_start, 0, type(uint256).max);
    _end = bound(_end, 0, _start);

    // it reverts with end <= start
    vm.expectRevert('end <= start');
    clFactoryIndexation.poolsIndexPaginated(_start, _end);
  }

  modifier whenEndIsGtStart() {
    _;
  }

  function test_WhenEndIsGtArrayLength(uint256 _start, uint256 _end) external whenEndIsGtStart {
    _start = bound(_start, 0, type(uint256).max - 1);
    _end = bound(_end, _start + 1, type(uint256).max);

    uint256 _length = _end - 1;
    _setPoolsIndexLength(_length);
    assertEq(clFactoryIndexation.poolsIndexLength(), _length);

    // it reverts with INVALID
    vm.expectRevert();
    clFactoryIndexation.poolsIndexPaginated(_start, _end);
  }

  function test_WhenEndIsLeqArrayLength(uint256 _start, uint256 _end, uint256 _length) external whenEndIsGtStart {
    _start = bound(_start, 0, LENGTH_CEIL - 1);
    _end = bound(_end, _start + 1, LENGTH_CEIL);

    _length = bound(_length, _end, LENGTH_CEIL > _end ? LENGTH_CEIL : _end);
    _poolsIndex_push({_numberOfElements: _length});

    ICLFactoryIndexation.PoolData[] memory _paginatedPoolData = clFactoryIndexation.poolsIndexPaginated(_start, _end);
    uint256 _len = _end - _start;

    // it returns elements from poolsIndex array from start (inclusive) to end (exclusive)
    assertEq(_paginatedPoolData.length, _len);
    for (uint256 _i = 0; _i < _len; ++_i) {
      ICLFactoryIndexation.PoolData memory _poolData = _paginatedPoolData[_i];

      (address _pool, uint48 _t) = clFactoryIndexation.poolsIndex(_i + _start);

      assertEq(_poolData.pool, _pool);
      assertEq(uint256(_poolData.creationTimestamp), uint256(_t));
    }
  }
}
