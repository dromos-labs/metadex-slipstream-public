// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma abicoder v2;

import {IAccessControl} from './IAccessControl.sol';

interface ILeafVoter is IAccessControl {
  /**
   * @notice Aggregated voting power of a gauge at a point in time.
   * @param bias Decaying voting power at `ts`.
   * @param slope Per-second decay of `bias`.
   * @param ts Timestamp the point was resolved at.
   * @param permanentStakeBalance Non-decaying voting power from permanent stakes.
   */
  struct Point {
    int128 bias;
    int128 slope;
    uint48 ts;
    uint128 permanentStakeBalance;
  }

  /**
   * @notice Permissionless settle entrypoint for a registered gauge.
   *         Settles the chain index to `block.timestamp`, settles `_gauge`, and
   *         returns the gauge's cumulative reward share. The return value is
   *         monotonically increasing; a call against an unregistered gauge
   *         returns 0 without settling, so the function never reverts for any
   *         input address.
   * @param _gauge The gauge to settle.
   * @return _cumulativeRewardShare The gauge's settled cumulative reward share.
   */
  function settleGauge(address _gauge) external returns (uint256 _cumulativeRewardShare);

  /**
   * @notice Read-only twin of `settleGauge`. Projects the gauge's cumulative
   *         reward share at the current timestamp without writing state.
   *         `projectedCumulativeRewardShare(_gauge)` equals the value a
   *         `settleGauge(_gauge)` in this block would return.
   * @param _gauge The gauge to project.
   * @return _cumulativeRewardShare The gauge's projected cumulative reward share.
   */
  function projectedCumulativeRewardShare(address _gauge) external view returns (uint256 _cumulativeRewardShare);

  /**
   * @notice Mints `ReceiptToken` to the registered `EmissionsHandler` and calls it back per recipient.
   * @dev Reverts with `GaugeNotRegistered` for an unregistered caller and `CeilingExceeded` when the claim exceeds the
   * gauge's claimable headroom, `ceiling - claimed - surplus`. The claim is added to the gauge's `claimed` before the
   * mint, so all state effects complete before the handler callback fires. Callbacks MUST NOT rely on further
   * `LeafVoter` state changes. Emits `EmissionsMinted`.
   * @param _recipients Recipients for the per-leg delivery (LP, referral).
   * @param _amounts Per-leg amounts of `ReceiptToken`.
   */
  function mintEmissions(address[] calldata _recipients, uint128[] calldata _amounts) external;

  /**
   * @notice Gauge-only entrypoint for forfeiting surplus emissions the gauge
   *         cannot distribute, covering the Idle Gauge and Early Exit cases.
   *         Clamps `_amount` to the gauge's claimable headroom
   *         (`ceiling - claimed - surplus`), flushes the clamped amount into
   *         the gauge's `surplus` and the chain-level `surplusAccrued`, and
   *         emits `EmissionsForfeited` with the accrued amount. Reverts with
   *         `GaugeNotRegistered` when the caller is not a registered gauge.
   * @param _amount The surplus the calling gauge is forfeiting.
   */
  function forfeitEmissions(uint128 _amount) external;

  /**
   * @notice Whether a gauge is activated for direct allocation routing.
   * @param _gauge Gauge address to query.
   * @return Whether the gauge is activated.
   */
  function isActivated(address _gauge) external view returns (bool);

  /**
   * @notice Canonical per-gauge settlement state.
   * @param _gauge Gauge address to query.
   * @return _ceiling Cumulative effective share credited to the gauge.
   * @return _claimed Cumulative emissions minted to recipients by the claim flow.
   * @return _lastSettlement Timestamp of the gauge's last settlement.
   * @return _isRegistered Whether the gauge was produced by an approved factory.
   * @return _isActivated Whether the gauge is activated for direct allocation routing.
   * @return _surplus Cumulative surplus attributed to the gauge.
   * @return _lastIndex Snapshot of the chain index at the gauge's last settlement.
   * @return _lastTimeIndex Snapshot of the chain time index at the gauge's last settlement.
   * @return _point Decaying weight of the gauge.
   */
  function gaugeStates(address _gauge)
    external
    view
    returns (
      uint128 _ceiling,
      uint128 _claimed,
      uint48 _lastSettlement,
      bool _isRegistered,
      bool _isActivated,
      uint128 _surplus,
      uint256 _lastIndex,
      uint256 _lastTimeIndex,
      Point memory _point
    );
}
