// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.17;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UD60x18, toUD60x18, fromUD60x18} from "@prb/math/src/UD60x18.sol";
import {SD59x18} from "@prb/math/src/SD59x18.sol";
import "./AccountSnapshot.sol";
import "./VotingPower.sol";

/**
 * @title DXDInfluence
 * @dev Keeps track of the time commitment of accounts that have staked. The more DXD is staked and
 * the more time the DXD tokens are staked, the more influence the user will have on the DAO. The influence
 * formula is:
 *      influence = sum(stake.a.tc + stake.b.tc^k) over all stakes for a given account
 *                = a * sum(stake.tc) + b * sum(stake.tc^k)
 *      where:
 *          a: linearMultiplier      --> configurable by governance (signed 59.18-decimal fixed-point number).
 *          b: exponentialMultiplier --> configurable by governance (signed 59.18-decimal fixed-point number).
 *          k: exponent          --> constant set at initialization (unsigned 59.18-decimal fixed-point number).
 *          tc: time commitment  --> defined by the user at each stake.
 *          stake: tokens locked --> defined by the user at each stake.
 *
 * In order to allow the governor to change the parameters of the formula, sum(stake.tc) and sum(stake.tc^k)
 * are stored for each snapshot and the influence balance is calculated on the fly when queried. Notice that
 * changes in the formula are retroactive in the sense that all snapshots balances will be updated when queried
 * if `a` and `b` change. We call stake.tc the `linear term` of the formula and stake.tc^k the `exponential term`.
 *
 * DXDInfluence notifies the Voting Power contract of any stake changes.
 */
contract DXDInfluence is OwnableUpgradeable, AccountSnapshot {
    using ArraysUpgradeable for uint256[];

    address public constant FORMULA_SNAPSHOT_SLOT = address(0x1);

    struct CumulativeStake {
        uint256 linearTerm;
        uint256 exponentialTerm;
    }

    struct FormulaMultipliers {
        SD59x18 linearMultiplier;
        SD59x18 exponentialMultiplier;
    }

    address public dxdStake;
    VotingPower public votingPower;

    /// @dev influence formula parameters.
    /// @dev formulaMultipliers[snapshotId]
    mapping(uint256 => FormulaMultipliers) public formulaMultipliers;
    UD60x18 public exponent; // Must be immutable

    /// @dev cumulativeStakesSnapshots[account][snapshotId]
    /// @dev keeps track of the influence parameters of each account at the snapshot the account's stake was modified.
    mapping(address => mapping(uint256 => CumulativeStake)) public cumulativeStakesSnapshots;

    /// @dev keeps track of the influence parameters (linear and exponential terms) at the latest snapshot.
    CumulativeStake public totalCumulativeStake;
    /// @dev _totalInfluenceSnapshots[snapshotId] keeps track of the total influence at each snapshot.
    mapping(uint256 => uint256) private _totalInfluenceSnapshots;

    constructor() {}

    function initialize(
        address _dxdStake,
        address _votingPower,
        int256 _linearMultiplier,
        int256 _exponentialMultiplier,
        uint256 _exponent
    ) external initializer {
        __Ownable_init();

        _transferOwnership(_dxdStake);
        dxdStake = _dxdStake;
        votingPower = VotingPower(_votingPower);

        uint256 currentSnapshotId = _snapshot(FORMULA_SNAPSHOT_SLOT);
        formulaMultipliers[currentSnapshotId].linearMultiplier = SD59x18.wrap(_linearMultiplier);
        formulaMultipliers[currentSnapshotId].exponentialMultiplier = SD59x18.wrap(_exponentialMultiplier);
        exponent = UD60x18.wrap(_exponent);
    }

    /**
     * @dev Changes the influence formula parameters. The owner modifying the formula parameters must make sure
     * that the parameters are safe, i.e. that the dxd influence space is bounded to positive values. Negative
     * influence values will make balanceOf(), balanceOfAt(), totalSupply() and totalSupplyAt() revert.
     * Influence should also be a monotonically non-decreasing function with respect to time. The longer a user
     * commits to stake, the greater the influence.
     * @param _linearMultiplier Factor that will multiply the linear term of the influence. 18 decimals.
     * @param _exponentialMultiplier Factor that will multiply the exponential term of the influence. 18 decimals.
     */
    function changeFormula(int256 _linearMultiplier, int256 _exponentialMultiplier) external onlyOwner {
        uint256 currentSnapshotId = _snapshot(FORMULA_SNAPSHOT_SLOT);
        FormulaMultipliers storage newFormula = formulaMultipliers[currentSnapshotId];
        newFormula.linearMultiplier = SD59x18.wrap(_linearMultiplier);
        newFormula.exponentialMultiplier = SD59x18.wrap(_exponentialMultiplier);

        // Update global stake data
        _totalInfluenceSnapshots[currentSnapshotId] = calculateInfluence(totalCumulativeStake, newFormula);
    }

    /**
     * @dev Mints influence tokens according to the amount staked and takes a snapshot. The influence value
     * is not stored, only the linear and exponential terms of the formula are updated, which are then used
     * to compute the influence on the fly in the balance getter.
     * @param _account Account that has staked the tokens.
     * @param _amount Amount of tokens to have been staked.
     * @param _timeCommitment Time that the user commits to lock the tokens.
     */
    function mint(
        address _account,
        uint256 _amount,
        uint256 _timeCommitment
    ) external onlyOwner {
        CumulativeStake storage lastCumulativeStake = cumulativeStakesSnapshots[_account][_lastSnapshotId(_account)];
        uint256 currentSnapshotId = _snapshot(_account);

        (uint256 linearTerm, uint256 exponentialTerm) = getFormulaTerms(_amount, _timeCommitment);

        // Update account's stake data
        CumulativeStake storage cumulativeStake = cumulativeStakesSnapshots[_account][currentSnapshotId];
        cumulativeStake.linearTerm = lastCumulativeStake.linearTerm + linearTerm;
        cumulativeStake.exponentialTerm = lastCumulativeStake.exponentialTerm + exponentialTerm;

        // Update global stake data
        totalCumulativeStake.exponentialTerm += exponentialTerm;
        totalCumulativeStake.linearTerm += linearTerm;
        FormulaMultipliers storage currentFormula = formulaMultipliers[_lastSnapshotId(FORMULA_SNAPSHOT_SLOT)];
        _totalInfluenceSnapshots[currentSnapshotId] = calculateInfluence(totalCumulativeStake, currentFormula);

        // Notify Voting Power contract.
        votingPower.callback();
    }

    /**
     * @dev Burns influence tokens according to the amount withdrawn and takes a snapshot. The influence value
     * is not stored, only the linear and exponential terms of the formula are updated, which are then used
     * to compute the influence on the fly in the balance getter.
     * @param _account Account that has staked the tokens.
     * @param _amount Amount of tokens to have been staked.
     * @param _timeCommitment Time that the user commits to lock the tokens.
     */
    function burn(
        address _account,
        uint256 _amount,
        uint256 _timeCommitment
    ) external onlyOwner {
        CumulativeStake storage lastCumulativeStake = cumulativeStakesSnapshots[_account][_lastSnapshotId(_account)];
        uint256 currentSnapshotId = _snapshot(_account);

        (uint256 linearTerm, uint256 exponentialTerm) = getFormulaTerms(_amount, _timeCommitment);

        // Update account's stake data
        CumulativeStake storage cumulativeStake = cumulativeStakesSnapshots[_account][currentSnapshotId];
        cumulativeStake.linearTerm = lastCumulativeStake.linearTerm - linearTerm;
        cumulativeStake.exponentialTerm = lastCumulativeStake.exponentialTerm - exponentialTerm;

        // Update global stake data
        totalCumulativeStake.exponentialTerm -= exponentialTerm;
        totalCumulativeStake.linearTerm -= linearTerm;
        FormulaMultipliers storage currentFormula = formulaMultipliers[_lastSnapshotId(FORMULA_SNAPSHOT_SLOT)];
        _totalInfluenceSnapshots[currentSnapshotId] = calculateInfluence(totalCumulativeStake, currentFormula);

        // Notify Voting Power contract.
        votingPower.callback();
    }

    /**
     * @dev Updates the time a given amount of DXD was staked for and takes a snapshot. The influence value
     * is not stored, only the linear and exponential terms of the formula are updated, which are then used
     * to compute the influence on the fly in the balance getter.
     * @param _account Account that has staked the tokens.
     * @param _amount Amount of tokens to have been staked.
     * @param _oldTimeCommitment Time that the user commits to lock the tokens.
     * @param _newTimeCommitment Time that the user commits to lock the tokens.
     */
    function updateTime(
        address _account,
        uint256 _amount,
        uint256 _oldTimeCommitment,
        uint256 _newTimeCommitment
    ) external onlyOwner {
        CumulativeStake storage lastCumulativeStake = cumulativeStakesSnapshots[_account][_lastSnapshotId(_account)];
        uint256 currentSnapshotId = _snapshot(_account);

        (uint256 oldLinearTerm, uint256 oldExponentialTerm) = getFormulaTerms(_amount, _oldTimeCommitment);
        (uint256 newLinearTerm, uint256 newExponentialTerm) = getFormulaTerms(_amount, _newTimeCommitment);

        // Update account's stake data
        CumulativeStake storage cumulativeStake = cumulativeStakesSnapshots[_account][currentSnapshotId];
        cumulativeStake.linearTerm = lastCumulativeStake.linearTerm - oldLinearTerm + newLinearTerm;
        cumulativeStake.exponentialTerm = lastCumulativeStake.exponentialTerm - oldExponentialTerm + newExponentialTerm;

        // Update global stake data
        totalCumulativeStake.exponentialTerm =
            totalCumulativeStake.exponentialTerm -
            oldExponentialTerm +
            newExponentialTerm;
        totalCumulativeStake.linearTerm = totalCumulativeStake.linearTerm - oldLinearTerm + newLinearTerm;
        FormulaMultipliers storage currentFormula = formulaMultipliers[_lastSnapshotId(FORMULA_SNAPSHOT_SLOT)];
        _totalInfluenceSnapshots[currentSnapshotId] = calculateInfluence(totalCumulativeStake, currentFormula);

        // Notify Voting Power contract.
        votingPower.callback();
    }

    /**
     * @dev Returns the linear and exponential influence term for a given amount and time commitment.
     * @param _amount DXD amount.
     * @param _timeCommitment Amount of time the DXD is staked.
     */
    function getFormulaTerms(uint256 _amount, uint256 _timeCommitment) internal view returns (uint256, uint256) {
        UD60x18 tc = toUD60x18(_timeCommitment);
        uint256 exponentialTerm = fromUD60x18(toUD60x18(_amount).mul(tc.pow(exponent)));
        uint256 linearTerm = _amount * _timeCommitment;
        return (linearTerm, exponentialTerm);
    }

    /**
     * @dev Returns the amount of influence in existence.
     */
    function totalSupply() public view returns (uint256) {
        return totalSupplyAt(getCurrentSnapshotId());
    }

    /**
     * @dev Retrieves the influence total supply at the time `snapshotId` was created.
     */
    function totalSupplyAt(uint256 snapshotId) public view returns (uint256) {
        return _totalInfluenceSnapshots[snapshotId];
    }

    /**
     * @dev Returns the amount of influence owned by `account`.
     */
    function balanceOf(address account) public view returns (uint256) {
        CumulativeStake storage cumulativeStake = cumulativeStakesSnapshots[account][_lastSnapshotId(account)];
        return calculateInfluence(cumulativeStake, formulaMultipliers[_lastSnapshotId(FORMULA_SNAPSHOT_SLOT)]);
    }

    /**
     * @dev Retrieves the influence balance of `account` at the time `snapshotId` was created.
     */
    function balanceOfAt(address account, uint256 snapshotId) public view returns (uint256) {
        uint256 lastSnapshotId = _lastRegisteredSnapshotIdAt(snapshotId, account);
        CumulativeStake storage cumulativeStake = cumulativeStakesSnapshots[account][lastSnapshotId];
        return calculateInfluence(cumulativeStake, getFormulaMultipliersAt(snapshotId));
    }

    /**
     * @dev Calculates influence for the given cumulative stake data point.
     * @param _cumulativeStake Accumulated stake information on a specific snapshot.
     * @param _formula formula params to use.
     */
    function calculateInfluence(CumulativeStake storage _cumulativeStake, FormulaMultipliers storage _formula)
        internal
        view
        returns (uint256)
    {
        SD59x18 linearTerm = SD59x18.wrap(int256(_cumulativeStake.linearTerm));
        SD59x18 linearInfluence = _formula.linearMultiplier.mul(linearTerm);

        SD59x18 exponentialTerm = SD59x18.wrap(int256(_cumulativeStake.exponentialTerm));
        SD59x18 exponentialInfluence = _formula.exponentialMultiplier.mul(exponentialTerm);

        int256 influence = SD59x18.unwrap(linearInfluence.add(exponentialInfluence));
        require(influence >= 0, "DXDInfluence: negative influence, update formula");
        return uint256(influence);
    }

    /**
     * @dev Retrieves the influence formula parameters at the time `_snapshotId` was created.
     * @param _snapshotId Id of the snapshot.
     */
    function getFormulaMultipliersAt(uint256 _snapshotId) internal view returns (FormulaMultipliers storage) {
        uint256 lastSnapshotId = _lastRegisteredSnapshotIdAt(_snapshotId, FORMULA_SNAPSHOT_SLOT);
        return formulaMultipliers[lastSnapshotId];
    }

    /**
     * @dev Returns the number of decimals used (only used for display purposes)
     */
    function decimals() external pure returns (uint8) {
        return 18;
    }
}
