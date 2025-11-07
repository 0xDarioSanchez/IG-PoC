//SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

// ====================================
//              IMPORTS          
// ====================================

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/IUSDC.sol";
import "./interfaces/IProtocol.sol";

// ====================================
//              CONTRACT          
// ====================================

/**
 * Instance of contracts deployed by Lancer Protocol
 * It allows the Owner to withdraw the USDC earned throught lending
 * @author 0xDarioSanchez
 */
contract Marketplace is ReentrancyGuard{
    using SafeERC20 for IERC20;
    // ====================================
    //          STATE VARIABLES          
    // ====================================

    address public immutable owner;             //Owner of the contract, the one who deployed it
    IERC20 public usdc;                        //Interface for USDC token
    IProtocol public protocol;          //Interface for Protocol contract
        
    uint64 public dealIdCounter = 1;            //Incremental ID for deals
    uint8 constant USDC_DECIMALS = 6;          // Decimals of USDC token
    uint8 public feePercent;                  //Fee percentage charged on each deal, in USDC

    //Struct for storing user information
    //The reason to have 3 booleans is to allow users to be in different roles while using the same address
    struct User {
        address userAddress;
        uint256 balance;        //Balance in USDC disponible to withdraw
        int8 reputationAsUser;  //Reputation calculated from deals as payer or beneficiary
        int8 reputationAsJudge; //Reputation calculated from voting process as judge
        bool isPayer;           //Determines if the user can act as a payer (e.g. freelancer or seller)
        bool isBeneficiary;     //Determines if the user can act as a beneficiary (e.g. company or buyer)
        bool isJudge;           //Determines if the user can act as a judge
        uint64[] deals;         // deals where the user is involved
    }

    //Struct to store deal information
    //`amount` indicates the total
    struct Deal {
        uint64 dealId;          //ID to identify the deal
        address payer;          //The one who pays, it can be a company or a buyer
        address beneficiary;    //The one who receives the payment, it can be a freelancer or a seller
        uint256 amount;         //Amount in USDC
        uint256 startedAt;      //Timestamp when the deal was accepted
        uint64 duration;        //Duration in days for the deal
        bool accepted;          //True if the deal is open, false if it is closed
        bool disputed;          //True if there is an open dispute for this deal
    }

    struct Dispute {
        uint64 dealId;              //ID to connect the dispute with the corresponding deal
        address requester;          //The one who opens the dispute. It will always be the payer
        string requesterProofs;     //Proofs provided by the requester
        string beneficiaryProofs;   //Proofs provided by the beneficiary
        bool[] votes;               //Array of votes, true for requester, false for beneficiary
        bool waitingForJudges;      //True if waiting for the judges to be assigned
        bool isOpen;                //True if the dispute is open to vote, False if it is closed
    }   

    mapping(address => User) public users;      //Mapping to store users information
    mapping(uint256 => Deal) public deals;      //Mapping to store deals information
    mapping(uint64 => Dispute) public disputes; //Mapping to store disputes information

    // ====================================
    //             MODIFIERS          
    // ====================================

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the Owner");
        _;
    }

    modifier onlyUser() {
        require(users[msg.sender].userAddress == msg.sender, "Not the user");
        _;
    }

    modifier onlyBeneficiary(uint64 dealId) {
        require(msg.sender == deals[dealId].beneficiary, "Only receiver can perform this action");
        _;
    }

    modifier onlyPayer(uint64 dealId) {
        require(msg.sender == deals[dealId].payer, "Only payer can perform this action");
        _;
    }

    modifier dealExists(uint64 dealId) {
        require(deals[dealId].amount > 0, "Deal does not exist");
        _;
    }

    modifier disputeExists(uint64 disputeId) {
        require(disputes[disputeId].dealId > 0, "Dispute does not exist");
        _;
    }

    // ====================================
    //              EVENTS          
    // ====================================

    event UserRegistered(address indexed user, bool isPayer, bool isBeneficiary, bool isJudge);
    event DealCreated(uint64 indexed dealId, address indexed payer, address indexed beneficiary, uint256 amount);
    event DealAccepted(uint64 indexed dealId);
    event DealRejected(uint64 indexed dealId);
    event DisputeRequested(uint256 indexed disputeId, address indexed requester);
    event UserWithdrew(address indexed user, uint256 amount);
    event PaymentDeposited(address indexed user, uint256 amount);
    event DealAmountUpdated(uint64 indexed dealId, uint256 newAmount);
    event DealFinalized(uint64 indexed dealId);
    event DealDurationUpdated(uint64 indexed dealId, uint16 newDuration);
    event DisputeCreated(uint64 indexed dealId, address indexed requester);
    event DisputeResolved(uint64 indexed disputeId, address indexed winner);
    event NewFeePercent(uint8 newFeePercent);

    // ====================================
    //           CUSTOM ERRORs          
    // ====================================

    // ====================================
    //           CONSTRUCTOR          
    // ====================================

    constructor(
        address _owner, 
        uint8 _feePercent, 
        address _token,
        address _protocolAddress 
    ) {
        owner = _owner;
        feePercent = _feePercent;
        usdc = IERC20(_token);
        protocol = IProtocol(_protocolAddress);
    }


    // ====================================
    //        ONLY-OWNER FUNCTIONS          
    // ====================================


    // Function to update the fee percentage
    // Only callable by the owner
    function setFeePercent(uint8 _newFeePercent) external onlyOwner {
        feePercent = _newFeePercent;
        emit NewFeePercent(_newFeePercent);
    }

    // ====================================
    //         EXTERNAL FUNCTIONS          
    // ====================================

    function registerUser(bool _isPayer, bool _isBeneficiary, bool _isJudge) external {

        // Check if the user is already registered
        require(users[msg.sender].userAddress == address(0), "User already registered");
        // User must have at least one role
        require(_isPayer || _isBeneficiary || _isJudge, "At least one role must be true");

        // Register the user
        users[msg.sender] = User({
            userAddress: msg.sender,
            balance: 0,
            reputationAsUser: 0,
            reputationAsJudge: 0,
            isPayer: _isPayer,
            isBeneficiary: _isBeneficiary,
            isJudge: _isJudge,
            deals: new uint64[](0)
        });

        emit UserRegistered(msg.sender, _isPayer, _isBeneficiary, _isJudge);
    }

    function addRole(bool _isPayer, bool _isBeneficiary, bool _isJudge) external onlyUser {
        require(_isPayer || _isBeneficiary || _isJudge, "At least one role must be true");

        // Set the roles
        if(_isPayer){
            users[msg.sender].isPayer = true;
        }
        if(_isBeneficiary){
            users[msg.sender].isBeneficiary = true;
        }
        if(_isJudge){
            users[msg.sender].isJudge = true;
        }

        emit UserRegistered(msg.sender, _isPayer, _isBeneficiary, _isJudge);
    }


    //Allow users registered as beneficiaries to create deals
    //It must be accepted by the payer to be effective
    //Only `amount` can be updated after creation, but not if already accepted
    function createDeal(address _payer, uint256 _amount, uint64 _duration) external {
        require(_amount > 0, "Amount must be greater than zero");
        require(_payer != address(0), "Invalid payer address");
        require(users[msg.sender].isBeneficiary, "User not registered as beneficiary");
        require(users[_payer].isPayer, "Target not registered as payer");

        deals[dealIdCounter] = Deal({
            dealId: dealIdCounter,
            payer: _payer,
            beneficiary: msg.sender,
            amount: _amount,
            duration: _duration,
            startedAt: 0,
            accepted: false,
            disputed: false
        });

        emit DealCreated(dealIdCounter, _payer, msg.sender, _amount);

        dealIdCounter += 1;
    }


    function updateDealAmount(uint64 _dealId, uint256 _newAmount) external dealExists(_dealId) {
        Deal storage deal = deals[_dealId];

        require(msg.sender == deal.payer, "Only payer can update the deal");
        require(!deal.accepted, "Deal already accepted");
        require(_newAmount > 0, "Amount must be greater than zero");

        deal.amount = _newAmount;

        emit DealAmountUpdated(_dealId, _newAmount);
    }

    //Function to update the duration of a deal, only if not accepted yet
    //Duration is in days
    function updateDealDuration(uint64 _dealId, uint16 _newDuration) external dealExists(_dealId) {
        Deal storage deal = deals[_dealId];

        require(msg.sender == deal.payer, "Only payer can update the deal");
        require(!deal.accepted, "Deal already accepted");
        require(_newDuration > 0, "Duration must be greater than zero");

        deal.duration = _newDuration;

        emit DealDurationUpdated(_dealId, _newDuration);
    }


    //Function to accept a deal, transferring the funds to the contract
    //`Payer` transfer tokens to the contract but its balance is not updated until, that only happens if `Payer` request for a dispute and win it
    function acceptDeal(uint64 _dealId) public dealExists(_dealId) {
        Deal storage deal = deals[_dealId];
        require(msg.sender == deals[_dealId].payer, "Only payer can perform this action");
        require(!deal.accepted, "Deal already accepted");

        deal.accepted = true;
        deal.startedAt = block.timestamp;

        usdc.safeTransferFrom(msg.sender, address(this), deal.amount);

        emit DealAccepted(_dealId);
    }


    //If `Payer` does not agree with the deal, it can reject it
    //The deal is deleted for storage optimization
    //Ideally it should be a gasless transaction, payed by the contract itself
    function rejectDeal(uint64 _dealId) external dealExists(_dealId) {
        Deal memory deal = deals[_dealId];

        require(msg.sender == deal.payer, "Only payer can reject the deal");
        require(!deal.accepted, "Deal already accepted");

        delete deals[_dealId];

        emit DealRejected(_dealId);
    } 


    //Function to finalize a deal once `Payer` is satisfied with the conditions
    //`Beneficiary` balance is updated to allow its withdrawal
    //The corresponding fee is kept in the contract to be withdrawn by the owner
    //The deal is deleted
    function finishDeal(uint64 _dealId) external onlyPayer(_dealId) dealExists(_dealId) {
        Deal memory deal = deals[_dealId];

        require(deal.accepted, "Deal not accepted");
        require(!deal.disputed, "Deal is disputed");

        //Calculate fee
        uint256 fee = (deal.amount * feePercent) / 100;

        //Update beneficiary balance
        users[deal.beneficiary].balance += (deal.amount - fee);

        delete deals[_dealId];

        emit DealFinalized(_dealId);
    }


    //Function to request the payment of a deal after its duration has passed
    //Only can be executed by the `Beneficiary` if 1 week have passed since the deal duration ended
    //`Beneficiary` balance is updated to allow its withdrawal
    //The corresponding fee is kept in the contract to be withdrawn by the owner
    //The deal is deleted
    function requestDealPayment(uint64 _dealId) external onlyBeneficiary(_dealId) dealExists(_dealId) {
        Deal memory deal = deals[_dealId];

        require(deal.accepted, "Deal not accepted");
        require(!deal.disputed, "Deal is disputed");
        require(block.timestamp >= deal.startedAt + (deal.duration * 1 days) + 1 weeks, "Deal duration not sufficient");

        //Calculate fee
        uint256 fee = (deal.amount * feePercent) / 100;

        //Update beneficiary balance
        users[deal.beneficiary].balance += (deal.amount - fee) * 10**USDC_DECIMALS;

        delete deals[_dealId];

        emit DealFinalized(_dealId);
    }


    // Request a dispute, transfer dispute fee to Voting contract
    function requestDispute(uint64 _dealId, string calldata _proof) external dealExists(_dealId) onlyPayer(_dealId) {
        // Intentionally hard-coded 50 USDC fee for dispute
        // In the future I want to create different levels of disputes, e.g. pay more for disputes with more judges
        usdc.safeTransferFrom(msg.sender, address(protocol), 50 * 10**USDC_DECIMALS); 
        
        Deal storage deal = deals[_dealId];
        require(deal.accepted, "Deal not accepted");
        require(!deal.disputed, "Deal already disputed");

        deal.disputed = true;

        // Call Protocol contract
        protocol.createDispute(_dealId, msg.sender, _proof);

        emit DisputeCreated(_dealId, msg.sender);
    }    


    function addDisputeEvidenceForPayer(uint64 _disputeId, string calldata _proof) external disputeExists(_disputeId) {
        Dispute memory dispute = disputes[_disputeId];
        require(msg.sender == dispute.requester, "Only requester can add evidence");
        require(bytes(_proof).length > 0, "Proof cannot be empty");

        // Call Protocol contract
        protocol.updateDisputeForPayer(_disputeId, msg.sender, _proof);
    }


    function addDisputeEvidenceForBeneficiary(uint64 _disputeId, string calldata _proof) external disputeExists(_disputeId) {
        Dispute memory dispute = disputes[_disputeId];
        Deal memory deal = deals[dispute.dealId];
        require(msg.sender == deal.beneficiary, "Only beneficiary can add evidence");
        require(bytes(_proof).length > 0, "Proof cannot be empty");

        dispute.beneficiaryProofs = string(abi.encodePacked(dispute.beneficiaryProofs, " | ", _proof));

        // Call Protocol contract
        protocol.updateDisputeForBeneficiary(_disputeId, msg.sender, _proof);
    }

    // Called by Payer or Beneficiary, only executable after the dispute is resolved
    // Protocol contract calls `onDisputeResult` in this contract to apply the result
    // If Payer wins, its balance is updated with the deal amount minus fee
    // If Beneficiary wins, its balance is updated with the deal amount minus fee
    // The deal and the dispute are deleted
    function applyDisputeResult(uint64 _disputeId, uint64 _dealId) external {
        Dispute memory dispute = disputes[_disputeId];
        Deal memory deal = deals[_dealId];
        require(msg.sender == dispute.requester || msg.sender == deal.beneficiary,
            "Only involved parties can execute this");

        bool winner = protocol.executeDisputeResult(_disputeId);

        uint256 fee = (deal.amount * feePercent) / 100; // Marketplace fee
        uint256 payout = deal.amount - fee;             // Amount to winner

        address winnerAddress;

        if (winner) {
            winnerAddress = deal.payer;
        } else {
            winnerAddress = deal.beneficiary;
        }

        users[winnerAddress].balance += payout;

        // Marketplace keeps the fee (deal.amount - payout)

        delete deals[dispute.dealId];
        delete disputes[_disputeId];

        emit DisputeResolved(_disputeId, winner ? deal.payer : deal.beneficiary);
    }


    // Allows users to withdraw their USDC balance
    function withdraw() external onlyUser nonReentrant {
        uint256 balance = users[msg.sender].balance;
        require(balance > 0, "Insufficient balance");

        // Reset balance before transfer
        users[msg.sender].balance = 0;

        usdc.safeTransfer(msg.sender, balance);

        emit UserWithdrew(msg.sender, balance);
    }


    // ====================================
    //         INTERNAL FUNCTIONS          
    // ====================================

    // ====================================
    //          PRIVATE FUNCTIONS          
    // ====================================

    // Deposit funds to deal
    function deposit(uint256 _amount) private {
        require(usdc.transferFrom(msg.sender, address(this), _amount), "Transfer failed");

        users[msg.sender].balance += _amount;

        emit PaymentDeposited(msg.sender, _amount);
    }

    // ====================================
    //        PURE & VIEW FUNCTIONS          
    // ====================================

}