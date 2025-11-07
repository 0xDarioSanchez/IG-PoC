//SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.19;

import "./DeployHelpers.s.sol";
import "../contracts/Protocol.sol";
import { Marketplace } from "../contracts/Marketplace.sol";
import "../contracts/mocks/MockUSDC.sol";
import "forge-std/Script.sol";
import "forge-std/console.sol";

/**
 * @notice Main deployment script for all contracts
 * @dev Run this when you want to deploy multiple contracts at once
 */
contract DeployScript is ScaffoldETHDeploy {
    function run() external {
        // ==========================================
        //            Load keys from .env
        // ==========================================
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        uint256 payerKey = vm.envUint("PAYER_KEY");
        uint256 beneficiaryKey = vm.envUint("BENEFICIARY_KEY");
        uint256[5] memory judgeKeys = [
            vm.envUint("JUDGE1_KEY"),
            vm.envUint("JUDGE2_KEY"),
            vm.envUint("JUDGE3_KEY"),
            vm.envUint("JUDGE4_KEY"),
            vm.envUint("JUDGE5_KEY")
        ];

        // ==========================================
        //     Derive addresses from private keys
        // ==========================================
        address deployer = vm.addr(deployerKey);
        address payer = vm.addr(payerKey);
        address beneficiary = vm.addr(beneficiaryKey);
        address[5] memory judges;
        for (uint i; i < 5; i++) {
            judges[i] = vm.addr(judgeKeys[i]);
        }

        // ==========================================
        //           Deploy core contracts
        // ==========================================
        vm.startBroadcast(deployerKey);

        MockUSDC usdc = new MockUSDC();
        ProtocolContract protocol = new ProtocolContract(deployer, address(usdc));
        Marketplace marketplace = new Marketplace(
            address(deployer),
            uint8(3),            
            address(usdc),
            address(protocol)
        );

        vm.stopBroadcast();

        // ==========================================
        //             Payer registers
        // ==========================================
        vm.startBroadcast(payerKey);
        marketplace.registerUser(true, false, false);
        usdc.mint(payer, 1000 * 1e6); // fund payer
        vm.stopBroadcast();

        // ==========================================
        //   Beneficiary registers and creates deal
        // ==========================================
        vm.startBroadcast(beneficiaryKey);
        marketplace.registerUser(false, true, false);
        marketplace.createDeal(payer, 700 * 10**6, 2 weeks);
        vm.stopBroadcast();

        // ==========================================
        //         Judges register as judges
        // ==========================================
        for (uint i; i < judges.length; i++) {
            vm.startBroadcast(judgeKeys[i]);
            protocol.registerAsJudge();
            vm.stopBroadcast();
        }

        // ==========================================
        //       Payer accepts deal
        // ==========================================
        vm.startBroadcast(payerKey);
        usdc.approve(address(marketplace), type(uint256).max);
        marketplace.acceptDeal(1);
        vm.stopBroadcast();

        // ==========================================
        //          Payer requests a dispute
        // ==========================================
        vm.startBroadcast(payerKey);
        marketplace.requestDispute(1, "The work was not delivered");
        vm.stopBroadcast();

        // ==========================================
        //           Judges register to vote        
        // ==========================================
        for (uint i; i < judges.length; i++) {
            vm.startBroadcast(judgeKeys[i]);
            protocol.registerToVote(1);
            vm.stopBroadcast();
        }

        // ==========================================
        //               Judges vote
        // ==========================================
        for (uint i; i < judges.length; i++) {
            vm.startBroadcast(judgeKeys[i]);
            if (i < 4) {                    // 3 judges vote for beneficiary, 2 for requester
                protocol.vote(1, false);    // Vote for beneficiary
            } else {
                protocol.vote(1, true);     // Vote for requester
            }
            vm.stopBroadcast();
        }

        // ==========================================
        //        Check if dispute is resolved
        // ==========================================
        bool isResolved = protocol.checkIfDisputeIsResolved(1);

        // ==========================================
        //       Execute dispute result
        // ==========================================

        vm.startBroadcast(beneficiaryKey);
        marketplace.applyDisputeResult(1, 1);
        vm.stopBroadcast();

        // ==========================================
        //           Judges withdraw fees
        // ==========================================
        vm.startBroadcast(judgeKeys[0]);
        protocol.judgeWithdraw();
        vm.stopBroadcast();
        vm.startBroadcast(judgeKeys[1]);
        protocol.judgeWithdraw();
        vm.stopBroadcast();
        vm.startBroadcast(judgeKeys[2]);
        protocol.judgeWithdraw();
        vm.stopBroadcast();
        vm.startBroadcast(judgeKeys[3]);
        protocol.judgeWithdraw();
        vm.stopBroadcast();

        // ==========================================
        //       Beneficiary withdraws funds
        // ==========================================
        vm.startBroadcast(beneficiaryKey);
        marketplace.withdraw();
        vm.stopBroadcast();


        // ==========================================
        //         Check final balances
        // ==========================================
        console.log("Marketplace address:", address(marketplace));
        
        console.log("Dispute resolved:", isResolved);

        console.log("Payer USDC balance:", usdc.balanceOf(payer) / 1e6, "Initially 1000, paid 700 for deal and 50 for dispute");
        console.log("Beneficiary USDC balance:", usdc.balanceOf(beneficiary) / 1e6);
        console.log("Marketplace USDC balance:", usdc.balanceOf(address(marketplace)) / 1e6);
        console.log("Protocol USDC balance:", usdc.balanceOf(address(protocol)) / 1e6);
        console.log("Judge 1 USDC balance:", usdc.balanceOf(judges[0]) / 1e6);
        console.log("Judge 2 USDC balance:", usdc.balanceOf(judges[1]) / 1e6);
        console.log("Judge 3 USDC balance:", usdc.balanceOf(judges[2]) / 1e6);
        console.log("Judge 4 USDC balance:", usdc.balanceOf(judges[3]) / 1e6);
        console.log("Judge 5 USDC balance:", usdc.balanceOf(judges[4]) / 1e6);
    }
}