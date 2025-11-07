//SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

// ====================================
//              IMPORTS          
// ====================================

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./interfaces/IUSDC.sol";
import "./interfaces/IMarketplace.sol";

// ====================================
//              CONTRACT          
// ====================================

/**
 * Smart contract with the main logic of Lancer Protocol
 * It also allows the owner to withdraw the Ether in the contract
 * @author 0xDarioSanchez
 */
contract ProtocolContract {
    using SafeERC20 for IERC20;

    // ====================================
    //          STATE VARIABLES          
    // ====================================

    address public owner;
    address public factory;
    IERC20 private usdc;

    uint256 private contractBalance;            // Balance of USDC in the contract that is able to be withdrawn by the owner, so is not the total balance of the contract!
    uint64 public disputeCount = 1;                 // Counter for dispute IDs
    uint8 public numberOfVotes = 5;             // Number of votes required to resolve a dispute

    uint8 constant USDC_DECIMALS = 6;          // Decimals of USDC token
    uint256 public disputePrice = 50 * 10**USDC_DECIMALS; // Price to open a dispute, 50 USDC

    struct Judge {
        address judgeAddress;       // Address of the corresponding judge
        uint256 balance;            // Balance of USDC that the judge can withdraw
        int8 reputation;            // Reputation of the judge, it can be negative
    }

    struct Dispute {
        uint32 disputeId;           // ID to connect the dispute with the corresponding deal
        address contractAddress;    // Address of the contract from where the dispute was opened
        address requester;          // The one who opens the dispute. It will always be the payer
        address beneficiary;        // The one who is disputed against.
        string requesterProofs;     // Proofs provided by the requester
        string beneficiaryProofs;   // Proofs provided by the beneficiary
        address[] ableToVote;       // List of judges that can vote in the dispute
        address[] voters;           // List of judges that already voted in the dispute
        bool[] votes;               // List of votes corresponding to the judges in the voters array, it seems redundant but it is to easily assign tokens and reputation
        uint8 votesFor;             // Votes in favor of the requester
        uint8 votesAgainst;         // Votes against the requester
        bool waitingForJudges;      // True if waiting for the judges to be assigned
        bool isOpen;                // True if the dispute is open to vote, False if it is closed
        bool resolved;              // True if the dispute has been resolved
    }

    mapping(address => Judge) public judges;
    mapping(uint64 => Dispute) public disputes;


    // ====================================
    //             MODIFIERS          
    // ====================================

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the Owner");
        _;
    }

    // ====================================
    //              EVENTS          
    // ====================================

    event JudgeRegistered(address indexed judge);
    event DisputeCreated(uint256 indexed disputeId, address indexed requester, address indexed contractAddress);
    event DisputeResolved(uint256 indexed disputeId, address winner);

    // ====================================
    //           CUSTOM ERRORs          
    // ====================================

    // ====================================
    //           CONSTRUCTOR          
    // ====================================

    constructor(address _owner, address _usdc) {
        owner = _owner;
        usdc = IERC20(_usdc);
    }

    // ====================================
    //         EXTERNAL FUNCTIONS          
    // ====================================

    /// Set the Factory contract address, can only be called once and only by the owner
    /// @param _factory is the address of the Factory contract
    function setFactoryAddress(address _factory) external onlyOwner {
        require(factory == address(0), "Factory already set");
        require(_factory != address(0), "Invalid address");
        factory = _factory;
    }

    /// Function to register as a judge
    /// Anyone can register as a judge, starting with 0 reputation
    function registerAsJudge() external {
        require(judges[msg.sender].judgeAddress == address(0), "Already registered");
        judges[msg.sender] = Judge(msg.sender, 0, 0);

        emit JudgeRegistered(msg.sender);
    }


    /// Function called by a MarketplaceInstance contract to create a dispute
    /// @param _requester address of the requester (the one who opens the dispute, it will always be the `payer`)
    /// @param _proofs striing to indicate a link to the proofs provided by the requester, it can be updated later
    function createDispute(address _requester, string calldata _proofs) external {
        Dispute storage dispute = disputes[disputeCount];

        dispute.requester = _requester;
        dispute.requesterProofs = _proofs;
        dispute.contractAddress = msg.sender;
        dispute.waitingForJudges = true;

        emit DisputeCreated(disputeCount, _requester, msg.sender);

        disputeCount++;
    }


    function updateDisputeForPayer(uint64 _disputeId, address _requester, string calldata _proof) external {
        Dispute storage dispute = disputes[_disputeId];
        require(dispute.requester == _requester, "Not the requester");
        require(bytes(_proof).length > 0, "Proof cannot be empty");
        require(!dispute.resolved, "Dispute resolved");

        dispute.requesterProofs = _proof;
    }


    function updateDisputeForBeneficiary(uint64 _disputeId, address _beneficiary, string calldata _proof) external {
        Dispute storage dispute = disputes[_disputeId];
        require(dispute.beneficiary == _beneficiary, "Not the beneficiary");
        require(bytes(_proof).length > 0, "Proof cannot be empty");
        require(!dispute.resolved, "Dispute resolved");

        dispute.beneficiaryProofs = _proof;
    }


    function registerToVote(uint64 _disputeId) external {
        Dispute storage dispute = disputes[_disputeId];
        require(judges[msg.sender].judgeAddress != address(0), "Not a judge");

        // If a judge vote as the minority, they lose 1 reputation point
        // In the future, I want to add function to rest for example 3 points if the judge doesn't vote
        require(judges[msg.sender].reputation >= -3, "Not enough reputation");

        require(dispute.waitingForJudges, "Judges already assigned");

        // Check if the judge is already registered to vote
        for (uint256 i = 0; i < dispute.ableToVote.length; i++) {
            require(dispute.ableToVote[i] != msg.sender, "Judge already registered");
        }

        dispute.ableToVote.push(msg.sender);

        // If the required number of judges is reached, the dispute is open for voting
        if (dispute.ableToVote.length == numberOfVotes) {
            dispute.waitingForJudges = false;
            dispute.isOpen = true;
        }
    }

    /// Function to vote in a dispute, only judges assigned to the dispute can vote
    /// @param _disputeId Indicate the corresponding dispute
    /// @param _support boolean that indicates if the judge supports the requester (true) or the beneficiary (false)
    function vote(uint64 _disputeId, bool _support) external {
        Dispute storage dispute = disputes[_disputeId];
        require(_checkIfAbleToVote(disputes[_disputeId], msg.sender), "Judge not allowed to vote");
        require(!dispute.resolved, "Dispute already resolved");
        require(dispute.isOpen, "Dispute not open");

        // Check if the judge has already voted
        for (uint256 i = 0; i < dispute.voters.length; i++) {
            require(dispute.voters[i] != msg.sender, "Judge already voted");
        }
        dispute.voters.push(msg.sender);
        dispute.votes.push(_support);

        if (_support) {
            dispute.votesFor++;
        } else {
            dispute.votesAgainst++;
        }

        // At the moment I'm assuming all disputes will be resolved with the same number of votes
        if (dispute.voters.length == numberOfVotes) {
            dispute.isOpen = false;
            dispute.resolved = true;

            //For saving gas
            uint8 positiveVotes = dispute.votesFor;
            uint8 negativeVotes = dispute.votesAgainst;

            uint256 prize = disputePrice / numberOfVotes;

            // If the requester wins
            if (positiveVotes > negativeVotes) {
                for (uint256 i = 0; i < dispute.voters.length; i++) {
                    if (dispute.votes[i]) {
                        judges[dispute.voters[i]].reputation++;
                        judges[dispute.voters[i]].balance += prize;
                    } else {
                        judges[dispute.voters[i]].reputation--;
                    }
                }
                contractBalance += prize * negativeVotes;

                //IMarketplaceInstance(dispute.contractAddress).applyDisputeResult(_disputeId, true);

                emit DisputeResolved(_disputeId, dispute.requester);
            }
            // If the beneficiaty wins
            else {
                for (uint256 i = 0; i < dispute.voters.length; i++) {
                    if (!dispute.votes[i]) {
                        judges[dispute.voters[i]].reputation++;
                        judges[dispute.voters[i]].balance += prize;
                    } else {
                        judges[dispute.voters[i]].reputation--;
                    }
                }
                contractBalance += prize * positiveVotes;

                //IMarketplaceInstance(dispute.contractAddress).applyDisputeResult(_disputeId, false);

                emit DisputeResolved(_disputeId, dispute.beneficiary);
            }
        }
    }


    /// To update the number of votes required to resolve a dispute, in the future I want to manage different levels of disputes, allowing to pay more to have more judges voting
    /// @param _newNumber new number of votes required
    function updateNumberOfVotes(uint8 _newNumber) external onlyOwner {
        require(_newNumber > 0, "Must be greater than 0");
        numberOfVotes = _newNumber;
    }


    function executeDisputeResult(uint64 _disputeId) external view returns (bool) {

        Dispute memory dispute = disputes[_disputeId];
        require(dispute.resolved, "Dispute not resolved yet");

        if (dispute.votesFor > dispute.votesAgainst) {
            // Requester wins
            return true;
        } else {
            // Beneficiary wins
            return false;
        }
    }

    /// Function that allows a judge to withdraw their balance of USDC tokens
    function judgeWithdraw() external {
        Judge storage judge = judges[msg.sender];

        address judgeAddress = judge.judgeAddress;

        require(judgeAddress != address(0), "Not a judge");
        require(judge.balance > 0, "No balance to withdraw");

        uint256 amount = judge.balance;
        judge.balance = 0;

        usdc.safeTransfer(judgeAddress, amount);
    }

    // Function that allows the owner to withdraw all the disponible USDC tokens in the contract
    // The tokens assigned to reward judges cannot be withdrawn by the owner or anyone else except the judges
    function withdraw() external onlyOwner {
        uint256 balance = usdc.balanceOf(address(this));
        uint256 amountToWithdraw = balance - contractBalance;
        require(amountToWithdraw > 0, "No USDC to withdraw");

        usdc.safeTransfer(owner, amountToWithdraw);
        contractBalance = 0;
    }

    // ====================================
    //        PURE & VIEW FUNCTIONS          
    // ====================================

    function checkIfDisputeIsResolved(uint64 _disputeId) external view returns (bool) {
        return disputes[_disputeId].resolved;
    }

    function _checkIfAbleToVote(Dispute memory dispute, address judge) internal pure returns (bool) {
        for (uint256 i = 0; i < dispute.ableToVote.length; i++) {
            if (dispute.ableToVote[i] == judge) {
                return true;
            }
        }
        return false;
    }

    // ====================================
    //              OTHERS          
    // ====================================

    //Function that allows the contract to receive ETH
    receive() external payable { }

}