// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity =0.7.6;
pragma abicoder v2;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';

import {ICLGauge} from 'contracts/gauge/interfaces/ICLGauge.sol';
import {ICLPool} from 'contracts/gauge/interfaces/ICLPool.sol';
import {ILeafVoter} from 'contracts/gauge/interfaces/ILeafVoter.sol';
import {ICLGaugeTape} from 'contracts/gauge/interfaces/tape/ICLGaugeTape.sol';

/**
 * @title CLGaugeTape
 * @notice Records each CL gauge's settled reward cumulatives in two fixed rings of observations and
 *         serves the reads an emissions APR needs.
 * @dev Written through an allowlisted gauge factory, which relays its gauges' settle reports inside a
 *      gas-capped fail-open call. Ring sizes and cadence are constants: no knobs, no growth. Rings fill
 *      lazily and recycle forever, so a gauge costs at most 81 slots and a dead gauge costs nothing.
 */
contract CLGaugeTape is Ownable, ICLGaugeTape {
  /*////////////////////////////////////////////////////////////
                            STORAGE
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc ICLGaugeTape
  uint256 public constant override HOURLY_RING_SIZE = 48;
  /// @inheritdoc ICLGaugeTape
  uint256 public constant override DAILY_RING_SIZE = 32;
  /// @inheritdoc ICLGaugeTape
  uint32 public constant override HOURLY_CADENCE = 1 hours;
  /// @inheritdoc ICLGaugeTape
  uint256 public constant override HOURLY_SPAN = HOURLY_RING_SIZE * HOURLY_CADENCE;

  /// @inheritdoc ICLGaugeTape
  mapping(address => bool) public override isAllowedFactory;
  /// @notice A gauge's running credited sum, ring heads and gates
  mapping(address => Meta) public override meta;
  /// @notice The hourly ring of each gauge, throttled to one write per `HOURLY_CADENCE`
  mapping(address => Observation[48]) public override hourlyRing;
  /// @notice The daily ring of each gauge, written on each day-boundary change
  mapping(address => Observation[32]) public override dailyRing;

  /*////////////////////////////////////////////////////////////
                          CONSTRUCTOR
  ////////////////////////////////////////////////////////////*/

  /// @notice Deploys the tape with its owner and the gauge factories allowed to record from the start
  /// @param _initialOwner The owner configuring the factory allowlist
  /// @param _allowedFactories The gauge factories allowed as `record` callers from deployment, so no owner
  ///        action is needed before the first gauge settles
  constructor(address _initialOwner, address[] memory _allowedFactories) {
    require(_initialOwner != address(0), 'ZA');
    transferOwnership(_initialOwner);
    for (uint256 _i; _i < _allowedFactories.length; ++_i) {
      isAllowedFactory[_allowedFactories[_i]] = true;
      emit AllowedFactorySet(_allowedFactories[_i], true);
    }
  }

  /*////////////////////////////////////////////////////////////
                    EXTERNAL WRITE FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc ICLGaugeTape
  function setAllowedFactory(address _factory, bool _allowed) external override onlyOwner {
    isAllowedFactory[_factory] = _allowed;
    emit AllowedFactorySet(_factory, _allowed);
  }

  /// @inheritdoc ICLGaugeTape
  function record(address _gauge, GaugeTapeData calldata _data) external override {
    require(isAllowedFactory[msg.sender], 'NA');

    Meta memory _meta = meta[_gauge];
    uint32 _blockTimestamp = uint32(block.timestamp);
    bool _dirty;

    // The credited sum advances on every nonzero delta, gated or not, so throttled settles are
    // folded into the next observation instead of being dropped
    if (_data.creditedDelta > 0) {
      _meta.credited = _saturatingAdd(_meta.credited, _data.creditedDelta);
      _dirty = true;
    }

    // Both gates are evaluated independently from the meta slot alone. Both pass on the first
    // write since the stored timestamp and day are zero and any live chain is past its first
    // hour and day
    bool _writeHourly = _blockTimestamp - _meta.lastHourlyTimestamp >= HOURLY_CADENCE;
    uint16 _day = uint16(block.timestamp / 1 days);
    bool _writeDaily = _day > _meta.lastDailyDay;

    if (_writeHourly || _writeDaily) {
      Observation memory _observation = Observation({
        cumulativeEffective: _saturate(_data.cumulative),
        cumulativeCredited: _meta.credited,
        blockTimestamp: _blockTimestamp
      });

      if (_writeHourly) {
        hourlyRing[_gauge][_meta.hourlyHead] = _observation;
        emit ObservationRecorded(_gauge, Ring.Hourly, _meta.hourlyHead, _blockTimestamp);
        _meta.lastHourlyTimestamp = _blockTimestamp;
        _meta.hourlyHead = uint8((uint256(_meta.hourlyHead) + 1) % HOURLY_RING_SIZE);
        if (_meta.hourlyCount < HOURLY_RING_SIZE) _meta.hourlyCount++;
      }
      if (_writeDaily) {
        dailyRing[_gauge][_meta.dailyHead] = _observation;
        emit ObservationRecorded(_gauge, Ring.Daily, _meta.dailyHead, _blockTimestamp);
        _meta.lastDailyDay = _day;
        _meta.dailyHead = uint8((uint256(_meta.dailyHead) + 1) % DAILY_RING_SIZE);
        if (_meta.dailyCount < DAILY_RING_SIZE) _meta.dailyCount++;
      }
      _dirty = true;
    }

    // One SSTORE for the packed slot, skipped entirely when nothing moved
    if (_dirty) meta[_gauge] = _meta;
  }

  /*////////////////////////////////////////////////////////////
                    EXTERNAL VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc ICLGaugeTape
  function observe(
    address _gauge,
    uint48[] calldata _secondsAgo
  ) external view override returns (Observation[] memory _observations) {
    Meta memory _meta = meta[_gauge];
    uint256 _length = _secondsAgo.length;
    _observations = new Observation[](_length);
    for (uint256 _i; _i < _length; ++_i) {
      _observations[_i] = _observeSingle(_gauge, _meta, _secondsAgo[_i]);
    }
  }

  /// @inheritdoc ICLGaugeTape
  function dailyObservations(address _gauge) external view override returns (Observation[] memory _observations) {
    Meta memory _meta = meta[_gauge];
    uint256 _count = _meta.dailyCount;
    uint256 _oldest = _oldestIndex(_meta.dailyHead, _count, DAILY_RING_SIZE);
    _observations = new Observation[](_count);
    // The ring is resolved once so the loop hashes the gauge key a single time
    Observation[32] storage _ring = dailyRing[_gauge];
    for (uint256 _i; _i < _count; ++_i) {
      _observations[_i] = _ring[(_oldest + _i) % DAILY_RING_SIZE];
    }
  }

  /*////////////////////////////////////////////////////////////
                   OBSERVE INTERNAL FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /**
   * @notice Resolves one lookback into the live near edge or a stored far edge
   * @param _gauge The gauge to read
   * @param _meta The gauge's meta, already loaded
   * @param _secondsAgo The lookback from now, zero for the live edge
   * @return _observation The observation serving the lookback
   */
  function _observeSingle(
    address _gauge,
    Meta memory _meta,
    uint48 _secondsAgo
  ) internal view returns (Observation memory _observation) {
    if (_secondsAgo == 0) return _live(_gauge, _meta);

    // A lookback past the chain's genesis clamps to the oldest observation through the search
    uint32 _target = _secondsAgo >= block.timestamp ? 0 : uint32(block.timestamp - _secondsAgo);

    if (_secondsAgo <= HOURLY_SPAN) {
      return _binarySearch(_gauge, Ring.Hourly, _meta.hourlyHead, _meta.hourlyCount, HOURLY_RING_SIZE, _target);
    }
    return _binarySearch(_gauge, Ring.Daily, _meta.dailyHead, _meta.dailyCount, DAILY_RING_SIZE, _target);
  }

  /**
   * @notice Projects the gauge's cumulatives to the current timestamp without writing state
   * @dev Effective is the voter projection floored at the gauge's cursor, so a deregistered gauge
   *      projecting zero holds its last settled level instead of underflowing. Credited is the running
   *      sum plus the projected delta only when the pool has staked liquidity, mirroring the branch the
   *      pool takes at the next settle. An address without code returns a zeroed observation, matching
   *      the far-edge reads of an unknown gauge.
   * @param _gauge The gauge to project
   * @param _meta The gauge's meta, already loaded
   * @return _observation The live observation
   */
  function _live(address _gauge, Meta memory _meta) internal view returns (Observation memory _observation) {
    uint256 _codeLength;
    // solhint-disable-next-line no-inline-assembly
    assembly {
      _codeLength := extcodesize(_gauge)
    }
    if (_codeLength == 0) return _observation;

    ICLGauge _clGauge = ICLGauge(_gauge);
    uint256 _effective = _clGauge.lastCumulativeRewardShare();
    uint256 _projected = ILeafVoter(_clGauge.voter()).projectedCumulativeRewardShare(_gauge);
    uint256 _credited = _meta.credited;

    if (_projected > _effective) {
      if (_clGauge.pool().stakedLiquidity() > 0) _credited += _projected - _effective;
      _effective = _projected;
    }

    return Observation({
      cumulativeEffective: _saturate(_effective),
      cumulativeCredited: _saturate(_credited),
      blockTimestamp: uint32(block.timestamp)
    });
  }

  /**
   * @notice Binary searches a ring for the newest observation at or before the target
   * @dev Logical order runs from the oldest written slot upwards with nondecreasing timestamps. A
   *      target at or before the oldest observation returns the oldest one; an empty ring returns a
   *      zeroed observation.
   * @param _gauge The gauge whose ring is searched
   * @param _ring The ring to search
   * @param _head The ring's next write slot
   * @param _count The ring's written slots
   * @param _size The ring's size in slots
   * @param _target The timestamp to search for
   * @return _observation The observation found
   */
  function _binarySearch(
    address _gauge,
    Ring _ring,
    uint8 _head,
    uint8 _count,
    uint256 _size,
    uint32 _target
  ) internal view returns (Observation memory _observation) {
    if (_count == 0) return _observation;

    uint256 _oldest = _oldestIndex(_head, _count, _size);
    // Cached in memory so the slot is read once whether it is returned or only compared
    Observation memory _oldestObservation = _slot(_gauge, _ring, _oldest);
    if (_oldestObservation.blockTimestamp >= _target) return _oldestObservation;

    // Invariant: the observation at logical index `_left` is at or before the target
    uint256 _left = 0;
    uint256 _right = uint256(_count) - 1;
    while (_left < _right) {
      uint256 _mid = (_left + _right + 1) / 2;
      if (_slot(_gauge, _ring, (_oldest + _mid) % _size).blockTimestamp <= _target) _left = _mid;
      else _right = _mid - 1;
    }
    return _slot(_gauge, _ring, (_oldest + _left) % _size);
  }

  /**
   * @notice Resolves a ring slot to its storage
   * @param _gauge The gauge whose ring is read
   * @param _ring The ring to read
   * @param _index The slot to read
   * @return _observation The stored observation
   */
  function _slot(address _gauge, Ring _ring, uint256 _index) internal view returns (Observation storage _observation) {
    _observation = _ring == Ring.Hourly ? hourlyRing[_gauge][_index] : dailyRing[_gauge][_index];
  }

  /**
   * @notice The slot holding a ring's oldest observation
   * @dev Before the first lap the ring fills from slot zero; once full the head points at the slot
   *      written longest ago
   * @param _head The ring's next write slot
   * @param _count The ring's written slots
   * @param _size The ring's size in slots
   * @return _oldest The oldest slot
   */
  function _oldestIndex(uint8 _head, uint256 _count, uint256 _size) internal pure returns (uint256 _oldest) {
    _oldest = _count < _size ? 0 : _head;
  }

  /*////////////////////////////////////////////////////////////
                       INTERNAL FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /**
   * @notice Downcasts a value to the observation width, saturating at its maximum
   * @dev Casts never revert since the tape sits behind the pool's swap path
   * @param _value The value to downcast
   * @return _saturated The value, or the width's maximum when it does not fit
   */
  function _saturate(uint256 _value) internal pure returns (uint112 _saturated) {
    _saturated = _value > type(uint112).max ? type(uint112).max : uint112(_value);
  }

  /**
   * @notice Adds a delta into the observation width, saturating at its maximum
   * @param _base The running value
   * @param _delta The delta to add
   * @return _sum The sum, or the width's maximum when it does not fit
   */
  function _saturatingAdd(uint112 _base, uint256 _delta) internal pure returns (uint112 _sum) {
    uint256 _headroom = type(uint112).max - _base;
    _sum = _delta >= _headroom ? type(uint112).max : uint112(uint256(_base) + _delta);
  }
}
