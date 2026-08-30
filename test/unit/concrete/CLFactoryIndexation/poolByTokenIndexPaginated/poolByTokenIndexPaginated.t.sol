pragma solidity =0.7.6;
pragma abicoder v2;

import {UnitCLFactoryIndexation} from '../CLFactoryIndexation.t.sol';

contract UnitCLFactoryIndexationPoolByTokenIndexPaginated is UnitCLFactoryIndexation {
  function test_WhenEndIsLtOrEqStart(uint256 _start, uint256 _end) external {
    _start = bound(_start, 0, type(uint256).max);
    _end = bound(_end, 0, _start);

    // it reverts with end <= start
    vm.expectRevert('end <= start');
    clFactoryIndexation.poolByTokenIndexPaginated(address(0), _start, _end);
  }

  modifier whenEndIsGtStart() {
    _;
  }

  function test_WhenEndIsGtArrayLength(address _token, uint256 _start, uint256 _end) external whenEndIsGtStart {
    _start = bound(_start, 0, type(uint256).max - 1);
    _end = bound(_end, _start + 1, type(uint256).max);

    uint256 _length = _end - 1;

    _setPoolByTokenIndexLength(_token, _length);
    assertEq(clFactoryIndexation.poolByTokenIndexLength(_token), _length);

    // it reverts with INVALID
    vm.expectRevert();
    clFactoryIndexation.poolByTokenIndexPaginated(_token, _start, _end);
  }

  function test_WhenEndIsLeqArrayLength(
    address _token,
    uint256 _start,
    uint256 _end,
    uint256 _length
  ) external whenEndIsGtStart {
    _start = bound(_start, 0, LENGTH_CEIL - 1);
    _end = bound(_end, _start + 1, LENGTH_CEIL);

    _length = bound(_length, _end, LENGTH_CEIL > _end ? LENGTH_CEIL : _end);
    _poolByTokenIndex_push({_token: _token, _numberOfPools: _length});

    address[] memory _paginatedPools = clFactoryIndexation.poolByTokenIndexPaginated(_token, _start, _end);
    uint256 _len = _end - _start;

    // it returns elements from poolByTokenIndex array from start (inclusive) to end (exclusive)
    assertEq(_paginatedPools.length, _len);
    for (uint256 _i = 0; _i < _len; ++_i) {
      assertEq(_paginatedPools[_i], clFactoryIndexation.poolByTokenIndex(_token, _i + _start));
    }
  }
}
