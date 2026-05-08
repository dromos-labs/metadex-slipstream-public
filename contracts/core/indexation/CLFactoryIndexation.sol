// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import {ICLFactoryIndexation} from '../interfaces/indexation/ICLFactoryIndexation.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/EnumerableSet.sol';

/**
 * @title CLFactoryIndexation
 * @notice Exposes on-chain indexes for CL pools. The indexes are append-only and
 *         must be updated atomically on each pool creation by the child
 *         CL factory contract through the use of {_createPoolHook}.
 * @dev Exposed indexes are:
 *      1) POOL-BY-TOKEN index: maps a token address to the array of pools in which the token appears.
 *      2) POOLS index: provides a record of all pools created by the child factory, along with their creation timestamps.
 *      3) TOKEN index: contains all unique tokens that have ever appeared in any pool created by the child factory.
 */
abstract contract CLFactoryIndexation is ICLFactoryIndexation {
  using EnumerableSet for EnumerableSet.AddressSet;

  /*////////////////////////////////////////////////////////////
                              STORAGE
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc ICLFactoryIndexation
  /// @dev {token => pools}
  mapping(address => address[]) public override poolByTokenIndex;

  /// @inheritdoc ICLFactoryIndexation
  PoolData[] public override poolsIndex;

  /// @dev TOKEN index stores tokens used in pools created by the child factory.
  EnumerableSet.AddressSet private tokenIndex;

  /*////////////////////////////////////////////////////////////
                              ERRORS
  ////////////////////////////////////////////////////////////*/

  /// @dev Thrown when end argument to the pagination function
  ///      is less than or equal to the start argument.
  ///      When end < start: we revert instead of substituting
  ///      `end` with the actual length.
  ///      When end == start: we revert instead of returning an empty array.
  string private constant ERR_END_LEQ_START = 'end <= start';

  /*////////////////////////////////////////////////////////////
                              LENGTH FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc ICLFactoryIndexation
  function poolByTokenIndexLength(address _token) external view override returns (uint256 _length) {
    _length = poolByTokenIndex[_token].length;
  }

  /// @inheritdoc ICLFactoryIndexation
  function poolsIndexLength() external view override returns (uint256 _length) {
    _length = poolsIndex.length;
  }

  /// @inheritdoc ICLFactoryIndexation
  function tokenIndexLength() external view override returns (uint256 _length) {
    _length = tokenIndex.length();
  }

  /*////////////////////////////////////////////////////////////
                              PAGINATION FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc ICLFactoryIndexation
  function poolByTokenIndexPaginated(
    address _token,
    uint256 _start,
    uint256 _end
  ) external view override returns (address[] memory _poolByTokenIndexPaginated) {
    if (_end <= _start) revert(ERR_END_LEQ_START);

    uint256 _len = _end - _start;
    _poolByTokenIndexPaginated = new address[](_len);

    address[] storage pools = poolByTokenIndex[_token];

    for (uint256 _i = 0; _i < _len; ++_i) {
      _poolByTokenIndexPaginated[_i] = pools[_i + _start];
    }
  }

  /// @inheritdoc ICLFactoryIndexation
  function poolsIndexPaginated(
    uint256 _start,
    uint256 _end
  ) external view override returns (PoolData[] memory _poolsIndexPaginated) {
    if (_end <= _start) revert(ERR_END_LEQ_START);

    uint256 _len = _end - _start;
    _poolsIndexPaginated = new PoolData[](_len);

    for (uint256 _i = 0; _i < _len; ++_i) {
      _poolsIndexPaginated[_i] = poolsIndex[_i + _start];
    }
  }

  /// @inheritdoc ICLFactoryIndexation
  function tokenIndexPaginated(
    uint256 _start,
    uint256 _end
  ) external view override returns (address[] memory _tokenIndexPaginated) {
    if (_end <= _start) revert(ERR_END_LEQ_START);

    uint256 _len = _end - _start;
    _tokenIndexPaginated = new address[](_len);

    for (uint256 _i = 0; _i < _len; ++_i) {
      _tokenIndexPaginated[_i] = tokenIndex.at(_start + _i);
    }
  }

  /*////////////////////////////////////////////////////////////
                              INTERNAL FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /**
   * @notice This method populates all indexes with parameters used to create the pool by the child factory.
   * @param _tokenA One of the tokens used to create `_pool`.
   * @param _tokenB One of the tokens used to create `_pool`.
   * @param _pool An address of a newly created pool.
   */
  function _createPoolHook(address _tokenA, address _tokenB, address _pool) internal {
    /// @dev 1) Populates POOL-BY-TOKEN index for both tokens with newly created pool.
    poolByTokenIndex[_tokenA].push(_pool);
    poolByTokenIndex[_tokenB].push(_pool);

    /// @dev 2) Populates POOLS index with newly created pool.
    poolsIndex.push(PoolData({pool: _pool, creationTimestamp: uint48(block.timestamp)}));

    /// @dev 3) Populates TOKEN index with tokens, used to create a new pool.
    ///      {add} is no-op for duplicate elements.
    tokenIndex.add(_tokenA);
    tokenIndex.add(_tokenB);
  }
}
