//SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

interface IMarketplace {
    function applyDisputeResult(uint64 _disputeId, bool _result) external;
}