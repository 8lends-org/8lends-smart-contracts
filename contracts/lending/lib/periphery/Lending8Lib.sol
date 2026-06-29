// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {ILending8, Id} from "../../interfaces/ILending8.sol";
import {Lending8StorageLib} from "./Lending8StorageLib.sol";

/// @title Lending8Lib
/// @author 8lends

/// @notice Helper library to access Lending8 storage variables.
/// @dev Warning: Supply and borrow getters may return outdated values that do not include accrued interest.
library Lending8Lib {
    function supplyShares(ILending8 lending8, Id id, address user) internal view returns (uint256) {
        bytes32[] memory slot = _array(Lending8StorageLib.positionSupplySharesSlot(id, user));
        return uint256(lending8.extSloads(slot)[0]);
    }

    function borrowShares(ILending8 lending8, Id id, address user) internal view returns (uint256) {
        bytes32[] memory slot = _array(Lending8StorageLib.positionBorrowSharesAndCollateralSlot(id, user));
        return uint128(uint256(lending8.extSloads(slot)[0]));
    }

    function collateral(ILending8 lending8, Id id, address user) internal view returns (uint256) {
        bytes32[] memory slot = _array(Lending8StorageLib.positionBorrowSharesAndCollateralSlot(id, user));
        return uint256(lending8.extSloads(slot)[0] >> 128);
    }

    function totalSupplyAssets(ILending8 lending8, Id id) internal view returns (uint256) {
        bytes32[] memory slot = _array(Lending8StorageLib.marketTotalSupplyAssetsAndSharesSlot(id));
        return uint128(uint256(lending8.extSloads(slot)[0]));
    }

    function totalSupplyShares(ILending8 lending8, Id id) internal view returns (uint256) {
        bytes32[] memory slot = _array(Lending8StorageLib.marketTotalSupplyAssetsAndSharesSlot(id));
        return uint256(lending8.extSloads(slot)[0] >> 128);
    }

    function totalBorrowAssets(ILending8 lending8, Id id) internal view returns (uint256) {
        bytes32[] memory slot = _array(Lending8StorageLib.marketTotalBorrowAssetsAndSharesSlot(id));
        return uint128(uint256(lending8.extSloads(slot)[0]));
    }

    function totalBorrowShares(ILending8 lending8, Id id) internal view returns (uint256) {
        bytes32[] memory slot = _array(Lending8StorageLib.marketTotalBorrowAssetsAndSharesSlot(id));
        return uint256(lending8.extSloads(slot)[0] >> 128);
    }

    function lastUpdate(ILending8 lending8, Id id) internal view returns (uint256) {
        bytes32[] memory slot = _array(Lending8StorageLib.marketLastUpdateAndFeeSlot(id));
        return uint128(uint256(lending8.extSloads(slot)[0]));
    }

    function fee(ILending8 lending8, Id id) internal view returns (uint256) {
        bytes32[] memory slot = _array(Lending8StorageLib.marketLastUpdateAndFeeSlot(id));
        return uint256(lending8.extSloads(slot)[0] >> 128);
    }

    function _array(bytes32 x) private pure returns (bytes32[] memory) {
        bytes32[] memory res = new bytes32[](1);
        res[0] = x;
        return res;
    }
}
