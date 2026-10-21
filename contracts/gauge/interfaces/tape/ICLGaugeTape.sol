// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6;
pragma abicoder v2;

/// @title ICLGaugeTape
/// @notice Records each CL gauge's settled reward cumulatives in two fixed rings of observations and serves
///         the reads an emissions APR needs: the live near edge, the far-edge search and the daily series.
interface ICLGaugeTape {
  /*////////////////////////////////////////////////////////////
                              ENUMS
  ////////////////////////////////////////////////////////////*/

  /// @notice The two observation rings a gauge writes into.
  /// @dev `Hourly` is throttled to one write per hour and serves the 24h window. `Daily` writes on a
  ///      day-boundary change and serves the 7D and 30D windows.
  enum Ring {
    Hourly,
    Daily
  }

  /*////////////////////////////////////////////////////////////
                             STRUCTS
  ////////////////////////////////////////////////////////////*/

  /// @notice A committed reading of a gauge's reward cumulatives.
  /// @param cumulativeEffective The voter's cumulative reward share at the settle, net of cap, saturating
  ///        downcast by the tape.
  /// @param cumulativeCredited The running sum of the settle deltas credited to staked LPs, saturating.
  ///        The sum only advances through records that reach the tape. It starts at zero on the tape's
  ///        first record for the gauge, so a gauge that settled before the tape was wired, or that moved
  ///        from another tape, carries a standing gap below `cumulativeEffective`. The same gap opens
  ///        whenever the fail-open relay drops a settle on a wired gauge: an unset tape, a factory the
  ///        tape rejects, or a capped subcall that runs out of gas. Each dropped settle still advances
  ///        the gauge's cumulative, so `cumulativeEffective` resyncs on the next record while the
  ///        credited deltas it skipped are lost for good. Deltas between two observations are exact only
  ///        when every settle between them was recorded; a window that spans a dropped settle overstates
  ///        the forfeit by the credited deltas it missed, so comparison windows must begin at or after
  ///        the first record once recording resumes. The derived forfeited level,
  ///        `cumulativeEffective - cumulativeCredited`, is only meaningful as a delta between two such
  ///        observations, never as an absolute figure.
  /// @param blockTimestamp The time the reading was taken.
  struct Observation {
    uint112 cumulativeEffective;
    uint112 cumulativeCredited;
    uint32 blockTimestamp;
  }

  /// @notice A gauge's running credited sum, ring heads and write gates, one slot.
  /// @dev `lastHourlyTimestamp` duplicates the newest hourly observation's timestamp on purpose:
  ///      the skip path decides both gates from this single slot without touching the rings.
  /// @param credited The running sum of staker-credited settle deltas, advanced on every nonzero delta.
  /// @param lastHourlyTimestamp The hourly ring gate: the timestamp of the last hourly write.
  /// @param lastDailyDay The daily ring gate: the day number (days since epoch) of the last daily write.
  /// @param hourlyHead The next hourly slot to write.
  /// @param hourlyCount Written hourly observations, bounds the search.
  /// @param dailyHead The next daily slot to write.
  /// @param dailyCount Written daily observations, bounds the search.
  struct Meta {
    uint112 credited;
    uint32 lastHourlyTimestamp;
    uint16 lastDailyDay;
    uint8 hourlyHead;
    uint8 hourlyCount;
    uint8 dailyHead;
    uint8 dailyCount;
  }

  /// @notice The gauge's report of one settle, relayed through its factory.
  /// @param cumulative The voter's cumulative reward share the gauge settled to.
  /// @param creditedDelta The settle delta credited to staked LPs: the full cursor delta when the pool
  ///        had staked liquidity, zero otherwise. Zero on a refresh.
  struct GaugeTapeData {
    uint256 cumulative;
    uint256 creditedDelta;
  }

  /*////////////////////////////////////////////////////////////
                              EVENTS
  ////////////////////////////////////////////////////////////*/

  /// @notice Emitted when a factory is allowed or disallowed as a `record` caller.
  /// @param _factory The gauge factory the permission applies to.
  /// @param _allowed True when the factory may record.
  event AllowedFactorySet(address indexed _factory, bool _allowed);

  /// @notice Emitted when an observation is written into a ring, refreshes included.
  /// @dev The stored values are not emitted, matching the pool tape's `ObservationRecorded`: the
  ///      ring and slot point at them in storage.
  /// @param _gauge The gauge the observation belongs to.
  /// @param _ring The ring written.
  /// @param _index The slot the observation was written to.
  /// @param _blockTimestamp The stored timestamp.
  event ObservationRecorded(address indexed _gauge, Ring _ring, uint8 _index, uint32 _blockTimestamp);

  /*////////////////////////////////////////////////////////////
                      EXTERNAL WRITE FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Records a gauge's settle report, writing each ring whose gate has passed.
  /// @dev Called by an allowlisted gauge factory relaying its gauge's report. The credited delta is
  ///      added to the running sum before any gate, so deltas arriving between throttled writes are
  ///      never dropped. Both gates are evaluated independently, so one call can write either ring,
  ///      both or neither. A report whose values equal the last stored ones writes a refresh: same
  ///      values, new timestamp. Reverts with `NA` when the caller is not allowlisted.
  /// @param _gauge The gauge the report belongs to.
  /// @param _data The gauge's settle report.
  function record(address _gauge, GaugeTapeData calldata _data) external;

  /// @notice Allows or disallows a gauge factory as a `record` caller.
  /// @dev Only callable by the owner. Disallowing a factory that still points at this tape does not stop
  ///      its gauges from relaying: each settle keeps paying for a record call that reverts inside its
  ///      gas budget. To stop recording, the factory's tape manager clears the pointer with
  ///      `setClGaugeTape(address(0), gasLimit)`.
  /// @param _factory The gauge factory to configure.
  /// @param _allowed True to allow, false to disallow.
  function setAllowedFactory(address _factory, bool _allowed) external;

  /*////////////////////////////////////////////////////////////
                      EXTERNAL VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Returns an observation for each requested past timestamp (`block.timestamp - secondsAgo`).
  /// @dev A zero lookback returns the live near edge: the voter's projected cumulative, floored at the
  ///      gauge's cursor, and the running credited sum plus the projected delta when the pool has staked
  ///      liquidity. An address without code is not a gauge and returns a zeroed observation, so a batch
  ///      over a mixed gauge list never reverts on the live edge; a contract that is not a CL gauge still
  ///      reverts. Any other lookback returns a stored observation without interpolation: the newest
  ///      one at or before its target. Lookbacks up to `HOURLY_SPAN` read the hourly ring, longer ones
  ///      the daily ring. A target older than the oldest stored observation returns the
  ///      oldest one, so the window shrinks instead of failing. An empty serving ring returns a zeroed
  ///      observation.
  /// @param _gauge The gauge to read.
  /// @param _secondsAgo The lookbacks to read, each from now.
  /// @return _observations One observation per lookback, in the same order as `_secondsAgo`.
  function observe(
    address _gauge,
    uint48[] calldata _secondsAgo
  ) external view returns (Observation[] memory _observations);

  /// @notice The daily observations of a gauge, oldest first.
  /// @dev At most `DAILY_RING_SIZE` entries: the ring recycles, each new day overwrites the oldest
  ///      slot, so the series never grows past one lap.
  /// @param _gauge The gauge to read.
  /// @return _observations The stored daily observations in write order.
  function dailyObservations(address _gauge) external view returns (Observation[] memory _observations);

  /// @notice True when the factory may call `record`.
  /// @param _factory The factory to read.
  /// @return _allowed The factory's allowlist state.
  function isAllowedFactory(address _factory) external view returns (bool _allowed);

  /// @notice A gauge's running credited sum, ring heads and gates.
  /// @param _gauge The gauge to read.
  /// @return _credited The running sum of staker-credited settle deltas.
  /// @return _lastHourlyTimestamp The hourly ring gate.
  /// @return _lastDailyDay The daily ring gate, days since epoch.
  /// @return _hourlyHead The next hourly slot to write.
  /// @return _hourlyCount Written hourly observations.
  /// @return _dailyHead The next daily slot to write.
  /// @return _dailyCount Written daily observations.
  function meta(address _gauge)
    external
    view
    returns (
      uint112 _credited,
      uint32 _lastHourlyTimestamp,
      uint16 _lastDailyDay,
      uint8 _hourlyHead,
      uint8 _hourlyCount,
      uint8 _dailyHead,
      uint8 _dailyCount
    );

  /// @notice A stored hourly ring observation.
  /// @param _gauge The gauge to read.
  /// @param _index The slot to read, in `[0, hourlyCount)`.
  /// @return _cumulativeEffective The stored effective cumulative.
  /// @return _cumulativeCredited The stored credited cumulative.
  /// @return _blockTimestamp The stored timestamp.
  function hourlyRing(
    address _gauge,
    uint256 _index
  ) external view returns (uint112 _cumulativeEffective, uint112 _cumulativeCredited, uint32 _blockTimestamp);

  /// @notice A stored daily ring observation.
  /// @param _gauge The gauge to read.
  /// @param _index The slot to read, in `[0, dailyCount)`.
  /// @return _cumulativeEffective The stored effective cumulative.
  /// @return _cumulativeCredited The stored credited cumulative.
  /// @return _blockTimestamp The stored timestamp.
  function dailyRing(
    address _gauge,
    uint256 _index
  ) external view returns (uint112 _cumulativeEffective, uint112 _cumulativeCredited, uint32 _blockTimestamp);

  /// @notice The hourly ring size in slots. The hourly ring spans `HOURLY_SPAN` of gated writes.
  /// @return _size The hourly ring size.
  function HOURLY_RING_SIZE() external view returns (uint256 _size);

  /// @notice The daily ring size in slots.
  /// @return _size The daily ring size.
  function DAILY_RING_SIZE() external view returns (uint256 _size);

  /// @notice The hourly ring cadence: the minimum seconds between hourly writes.
  /// @return _cadence The hourly cadence in seconds.
  function HOURLY_CADENCE() external view returns (uint32 _cadence);

  /// @notice The hourly ring's span in seconds, `HOURLY_RING_SIZE * HOURLY_CADENCE`: the longest lookback
  ///         `observe` serves from the hourly ring, longer ones read the daily ring.
  /// @return _span The hourly span in seconds.
  function HOURLY_SPAN() external view returns (uint256 _span);
}
