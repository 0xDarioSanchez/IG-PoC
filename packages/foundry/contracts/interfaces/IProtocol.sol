//SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;


interface IProtocol {
    function createDispute(uint64 dealId, address requester, string calldata reason) external;
    function updateDisputeForPayer(uint256 disputeId, address requester, string calldata proof) external;
    function updateDisputeForBeneficiary(uint256 disputeId, address beneficiary, string calldata proof) external;
    function executeDisputeResult(uint64 _disputeId) external view returns (bool);
    function vote(uint256 disputeId, bool support) external;
}