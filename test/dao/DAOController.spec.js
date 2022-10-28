import { expect } from "chai";
const { expectRevert } = require("@openzeppelin/test-helpers");

const ERC20Mock = artifacts.require("./ERC20Mock.sol");
const DAOReputation = artifacts.require("./DAOReputation.sol");
const DAOController = artifacts.require("./DAOController.sol");
const DAOAvatar = artifacts.require("./DAOAvatar.sol");
const DXDVotingMachine = artifacts.require("./DXDVotingMachine.sol");
import * as helpers from "../helpers";

contract("WalletScheme", function (accounts) {
  let standardTokenMock;
  // let org;

  let reputation, controller, avatar, defaultParamsHash, repHolders;

  const schemeAddress = accounts[0]; // I need to make calls from scheme

  beforeEach(async function () {
    repHolders = [
      { address: accounts[0], amount: 20000 },
      { address: accounts[1], amount: 10000 },
      { address: accounts[2], amount: 70000 },
    ];

    reputation = await DAOReputation.new();
    await reputation.initialize("DXDaoReputation", "DXRep");

    controller = await DAOController.new();

    avatar = await DAOAvatar.new();
    await avatar.initialize(controller.address);

    for (let i = 0; i < repHolders.length; i++) {
      await reputation.mint(repHolders[i].address, repHolders[i].amount);
    }
    await reputation.transferOwnership(controller.address);

    standardTokenMock = await ERC20Mock.new("", "", 1000, accounts[1]);

    const votingMachine = await DXDVotingMachine.new(
      standardTokenMock.address,
      avatar.address
    );

    defaultParamsHash = await helpers.setDefaultParameters(votingMachine);

    await controller.initialize(
      schemeAddress,
      reputation.address,
      defaultParamsHash
    );
  });

  it("Should initialize schemesWithManageSchemesPermission and set correct default scheme params", async function () {
    const schemesWithManageSchemesPermission =
      await controller.getSchemesCountWithManageSchemesPermissions();
    const defaultSchemeParamsHash = await controller.getSchemeParameters(
      schemeAddress
    );
    const canManageSchemes = await controller.getSchemeCanManageSchemes(
      schemeAddress
    );

    expect(schemesWithManageSchemesPermission.toNumber()).to.equal(1);
    expect(defaultSchemeParamsHash).to.equal(defaultParamsHash);
    expect(canManageSchemes).to.eq(true);
  });

  // eslint-disable-next-line max-len
  it("registerScheme should subtract from schemesWithManageSchemesPermission counter if _canManageSchemes is set to false in a registered scheme", async function () {
    // change scheme with _canManageSchemes=false
    const registerCall = controller.registerScheme(
      schemeAddress,
      defaultParamsHash,
      false,
      false
    );

    await expectRevert(
      registerCall,
      "DAOController: Cannot disable canManageSchemes property from the last scheme with manage schemes permissions"
    );
  });

  // eslint-disable-next-line max-len
  it("registerScheme should not allow subtracting from schemesWithManageSchemesPermission if there is only 1 scheme with manage schemes permissions", async function () {
    // register new scheme with  manage schemes permissions
    await controller.registerScheme(
      accounts[10],
      defaultParamsHash,
      true,
      true
    );
    const schemesWithManageSchemesPermission =
      await controller.getSchemesCountWithManageSchemesPermissions();
    expect(schemesWithManageSchemesPermission.toNumber()).to.equal(2);

    // change manage schemes permissions to first scheme
    await controller.registerScheme(
      schemeAddress,
      defaultParamsHash,
      false,
      false
    );

    const schemesWithManageSchemesPermissionAfterChange =
      await controller.getSchemesCountWithManageSchemesPermissions();
    expect(schemesWithManageSchemesPermissionAfterChange.toNumber()).to.equal(
      1
    );
  });
});
