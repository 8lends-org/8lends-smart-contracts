// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.23;

struct Authorization {
    address authorizer;
    address authorized;
    bool isAuthorized;
    uint256 nonce;
    uint256 deadline;
}
struct Signature {
    uint8 v;
    bytes32 r;
    bytes32 s;
}
struct MarketParams {
    address loanToken;
    address collateralToken;
    address irm;
    uint256 lltv;
}

interface ILending8Bridge {

    function supplyCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalf,
        bytes calldata data
    ) external;

    function withdrawCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalf,
        address receiver
    ) external;

    function setAuthorizationWithSig(Authorization memory authorization, Signature calldata signature) external;
}
