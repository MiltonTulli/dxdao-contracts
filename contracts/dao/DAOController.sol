// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.17;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";
import "./DAOAvatar.sol";
import "./DAOReputation.sol";

/// @title DAO Controller
/// @dev A controller controls and connect the organizations schemes, reputation and avatar.
/// The schemes execute proposals through the controller to the avatar.
/// Each scheme has it own parameters and operation permissions.
contract DAOController is Initializable {
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;
    // using EnumerableSetUpgradeable for EnumerableSetUpgradeable.Bytes32Set;

    EnumerableSetUpgradeable.Bytes32Set private activeProposals;
    EnumerableSetUpgradeable.Bytes32Set private inactiveProposals;
    mapping(bytes32 => address) public schemeOfProposal;

    struct ProposalAndScheme {
        bytes32 proposalId;
        address scheme;
    }

    DAOReputation public reputationToken;

    struct Scheme {
        bytes32 paramsHash; // a hash voting parameters of the scheme
        bool isRegistered;
        bool canManageSchemes;
        bool canMakeAvatarCalls;
        bool canChangeReputation;
    }

    mapping(address => Scheme) public schemes;
    uint256 public schemesWithManageSchemesPermission;

    event RegisterScheme(address indexed _sender, address indexed _scheme);
    event UnregisterScheme(address indexed _sender, address indexed _scheme);

    /// @notice Sender is not a registered scheme
    error DAOController__SenderNotRegistered();

    /// @notice Sender cannot manage schemes
    error DAOController__SenderCannotManageSchemes();

    /// @notice Sender cannot perform avatar calls
    error DAOController__SenderCannotPerformAvatarCalls();

    /// @notice Sender cannot change reputation
    error DAOController__SenderCannotChangeReputation();

    /// @notice Cannot disable canManageSchemes property from the last scheme with manage schemes permissions
    error DAOController__CannotDisableLastSchemeWithManageSchemesPermission();

    /// @notice Cannot unregister last scheme with manage schemes permission
    error DAOController__CannotUnregisterLastSchemeWithManageSchemesPermission();

    /// @notice arg _proposalId is being used by other scheme
    error DAOController__IdUsedByOtherScheme();

    /// Sender is not the scheme that originally started the proposal
    error DAOController__SenderIsNotTheProposer();

    /// Sender is not a registered scheme or proposal is not active
    error DAOController__SenderIsNotRegisteredOrProposalIsInactive();

    function initialize(address _scheme, address _reputationToken, bytes32 _paramsHash) public initializer {
        schemes[_scheme] = Scheme({
            paramsHash: _paramsHash,
            isRegistered: true,
            canManageSchemes: true,
            canMakeAvatarCalls: true,
            canChangeReputation: true
        });
        schemesWithManageSchemesPermission = 1;
        reputationToken = DAOReputation(_reputationToken);
    }

    modifier onlyRegisteredScheme() {
        if (!schemes[msg.sender].isRegistered) {
            revert DAOController__SenderNotRegistered();
        }
        _;
    }

    modifier onlyRegisteringSchemes() {
        if (!schemes[msg.sender].canManageSchemes) {
            revert DAOController__SenderCannotManageSchemes();
        }
        _;
    }

    modifier onlyAvatarCallScheme() {
        if (!schemes[msg.sender].canMakeAvatarCalls) {
            revert DAOController__SenderCannotPerformAvatarCalls();
        }
        _;
    }

    modifier onlyChangingReputation() {
        if (!schemes[msg.sender].canChangeReputation) {
            revert DAOController__SenderCannotChangeReputation();
        }
        _;
    }

    /// @dev register a scheme
    /// @param _scheme the address of the scheme
    /// @param _paramsHash a hashed configuration of the usage of the scheme
    /// @param _canManageSchemes whether the scheme is able to manage schemes
    /// @param _canMakeAvatarCalls whether the scheme is able to make avatar calls
    /// @param _canChangeReputation whether the scheme is able to change reputation
    /// @return bool success of the operation
    function registerScheme(
        address _scheme,
        bytes32 _paramsHash,
        bool _canManageSchemes,
        bool _canMakeAvatarCalls,
        bool _canChangeReputation
    ) external onlyRegisteredScheme onlyRegisteringSchemes returns (bool) {
        Scheme memory scheme = schemes[_scheme];

        // Add or change the scheme:
        if ((!scheme.isRegistered || !scheme.canManageSchemes) && _canManageSchemes) {
            schemesWithManageSchemesPermission = schemesWithManageSchemesPermission + 1;
        } else if (scheme.canManageSchemes && !_canManageSchemes) {
            if (schemesWithManageSchemesPermission <= 1) {
                revert DAOController__CannotDisableLastSchemeWithManageSchemesPermission();
            }
            schemesWithManageSchemesPermission = schemesWithManageSchemesPermission - 1;
        }

        schemes[_scheme] = Scheme({
            paramsHash: _paramsHash,
            isRegistered: true,
            canManageSchemes: _canManageSchemes,
            canMakeAvatarCalls: _canMakeAvatarCalls,
            canChangeReputation: _canChangeReputation
        });

        emit RegisterScheme(msg.sender, _scheme);

        return true;
    }

    /// @dev unregister a scheme
    /// @param _scheme the address of the scheme
    /// @return bool success of the operation
    function unregisterScheme(address _scheme) external onlyRegisteredScheme onlyRegisteringSchemes returns (bool) {
        Scheme memory scheme = schemes[_scheme];

        //check if the scheme is registered
        if (_isSchemeRegistered(_scheme) == false) {
            return false;
        }

        if (scheme.canManageSchemes) {
            if (schemesWithManageSchemesPermission <= 1) {
                revert DAOController__CannotUnregisterLastSchemeWithManageSchemesPermission();
            }
            schemesWithManageSchemesPermission = schemesWithManageSchemesPermission - 1;
        }

        emit UnregisterScheme(msg.sender, _scheme);

        delete schemes[_scheme];
        return true;
    }

    /// @dev perform a generic call to an arbitrary contract
    /// @param _contract  the contract's address to call
    /// @param _data ABI-encoded contract call to call `_contract` address.
    /// @param _avatar the controller's avatar address
    /// @param _value value (ETH) to transfer with the transaction
    /// @return bool success
    /// @return bytes the return value of the called _contract's function.
    function avatarCall(
        address _contract,
        bytes calldata _data,
        DAOAvatar _avatar,
        uint256 _value
    ) external onlyRegisteredScheme onlyAvatarCallScheme returns (bool, bytes memory) {
        return _avatar.executeCall(_contract, _data, _value);
    }

    /// @dev Burns dao reputation
    /// @param _amount  the amount of reputation to burn
    /// @param _account  the account to burn reputation from
    function burnReputation(uint256 _amount, address _account) external onlyChangingReputation returns (bool) {
        return reputationToken.burn(_account, _amount);
    }

    /// @dev Mints dao reputation
    /// @param _amount  the amount of reputation to mint
    /// @param _account  the account to mint reputation from
    function mintReputation(uint256 _amount, address _account) external onlyChangingReputation returns (bool) {
        return reputationToken.mint(_account, _amount);
    }

    /// @dev Transfer ownership of dao reputation
    /// @param _newOwner  the new owner of the reputation token
    function transferReputationOwnership(
        address _newOwner
    ) external onlyRegisteringSchemes onlyAvatarCallScheme onlyChangingReputation {
        reputationToken.transferOwnership(_newOwner);
    }

    function isSchemeRegistered(address _scheme) external view returns (bool) {
        return _isSchemeRegistered(_scheme);
    }

    function getSchemeParameters(address _scheme) external view returns (bytes32) {
        return schemes[_scheme].paramsHash;
    }

    function getSchemeCanManageSchemes(address _scheme) external view returns (bool) {
        return schemes[_scheme].canManageSchemes;
    }

    function getSchemeCanMakeAvatarCalls(address _scheme) external view returns (bool) {
        return schemes[_scheme].canMakeAvatarCalls;
    }

    function getSchemeCanChangeReputation(address _scheme) external view returns (bool) {
        return schemes[_scheme].canChangeReputation;
    }

    function getSchemesCountWithManageSchemesPermissions() external view returns (uint256) {
        return schemesWithManageSchemesPermission;
    }

    function _isSchemeRegistered(address _scheme) private view returns (bool) {
        return (schemes[_scheme].isRegistered);
    }

    function getDaoReputation() external view returns (DAOReputation) {
        return reputationToken;
    }
}
