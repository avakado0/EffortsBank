// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice EffortsBank: mutual effort + accountability contract
/// Membership is ERC721 NFT (max 10 members), subscription & penalties per NFT
/// Efforts/Proposals are fully tied to members

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";

contract EffortsBank is ERC721Enumerable, Ownable, ReentrancyGuard {
    constructor() ERC721("EffortsBank Membership", "EBM") Ownable(msg.sender) {}


    // ---- CONFIG ----
    uint256 public constant MAX_MEMBERS = 10;
    uint256 public constant SUBSCRIPTION_FEE = 0.05 ether;
    uint256 public constant SUBSCRIPTION_PERIOD = 3 days;
    uint256 public constant MIN_PROPOSAL_AMOUNT = 0.01 ether;
    uint256 public constant PENALTY_PER_DAY = 0.01 ether;
    uint256 public constant CONFIRM_WINDOW = 3 days;

    uint256 public maxPenaltyDays = 30;
    uint256 public treasuryBalance;
    uint256 private nextTokenId = 1;

    // ---- MEMBERSHIP ----
    struct Subscription {
        uint256 paidThrough;
        uint256 pendingPenalty;
        bool blocked;
    }
    mapping(uint256 => Subscription) public subscriptions;

    modifier onlyMember() {
        require(balanceOf(msg.sender) == 1, "not a member");
        _;
    }

    function _getMemberTokenId(address member) internal view returns (uint256) {
        require(balanceOf(member) == 1, "member must own exactly 1 NFT");
        return tokenOfOwnerByIndex(member, 0);
    }

    function mintMembership(address to) external onlyOwner {
        require(totalSupply() < MAX_MEMBERS, "max members reached");
        require(balanceOf(to) == 0, "already a member");

        _safeMint(to, nextTokenId);
        nextTokenId++;
    }

    function isActive(address member) public view returns (bool) {
        if (balanceOf(member) != 1) return false;
        uint256 tokenId = _getMemberTokenId(member);
        Subscription storage s = subscriptions[tokenId];
        if (s.paidThrough < block.timestamp) return false;
        if (s.pendingPenalty > 0) return false;
        return !s.blocked;
    }

    // ---- SUBSCRIPTION / PENALTY ----
    function paySubscriptionFee(uint256 periods) external payable onlyMember {
        require(periods >= 1, "must cover at least one period");
        uint256 required = SUBSCRIPTION_FEE * periods;
        require(msg.value == required, "pay exact subscription multiples");

        uint256 tokenId = _getMemberTokenId(msg.sender);
        Subscription storage s = subscriptions[tokenId];

        if (s.paidThrough < block.timestamp) {
            s.paidThrough = block.timestamp + (SUBSCRIPTION_PERIOD * periods);
        } else {
            s.paidThrough += (SUBSCRIPTION_PERIOD * periods);
        }

        treasuryBalance += msg.value;
        emit SubscriptionPaid(msg.sender, periods, s.paidThrough, msg.value);
        emit TreasuryToppedUp(msg.sender, msg.value);
    }

    function _updatePenalty(uint256 tokenId) internal {
        Subscription storage s = subscriptions[tokenId];
        if (s.paidThrough >= block.timestamp) return;

        uint256 secondsLate = block.timestamp - s.paidThrough;
        uint256 daysLate = secondsLate / 1 days;
        if (daysLate == 0) return;

        uint256 capped = daysLate > maxPenaltyDays ? maxPenaltyDays : daysLate;
        uint256 newPenalty = capped * PENALTY_PER_DAY;

        if (newPenalty != s.pendingPenalty) {
            s.pendingPenalty = newPenalty;
            s.blocked = s.pendingPenalty > 0;
            emit PenaltyAccrued(msg.sender, s.pendingPenalty);
        }
    }

    function payPendingPenalty() external payable onlyMember {
        uint256 tokenId = _getMemberTokenId(msg.sender);
        Subscription storage s = subscriptions[tokenId];
        require(s.pendingPenalty > 0, "no pending penalty");
        require(msg.value == s.pendingPenalty, "pay exact penalty");

        treasuryBalance += msg.value;
        s.pendingPenalty = 0;
        s.blocked = false;
        emit PenaltyPaid(msg.sender, msg.value);
        emit TreasuryToppedUp(msg.sender, msg.value);
    }

    // ---- EFFORTS / PROPOSALS ----
    struct Effort {
        uint256 id;
        uint256 proposerTokenId;
        uint256 proposedTokenId;
        uint256 amount;
        uint256 proposedDurationDays;
        bool awaitingNewDuration;
        uint256 requestedNewDurationDays;
        bool committed;
        uint256 commitmentAcceptedDate;
        bool achievementCompleted;
        uint256 completedAt;
        bool concluded;
        uint256 createdAt;
    }
    uint256 public nextEffortId;
    mapping(uint256 => Effort) public efforts;

    modifier onlyActiveMember() {
        require(isActive(msg.sender), "member not active");
        _;
    }

    function submitProposal(address proposed, uint256 proposedDurationDays) external payable onlyMember onlyActiveMember {
        require(msg.sender != proposed, "cannot propose for yourself");
        require(balanceOf(proposed) == 1, "proposed must be a member");
        require(msg.value >= MIN_PROPOSAL_AMOUNT, "min deposit 0.01 ETH");

        uint256 proposerId = _getMemberTokenId(msg.sender);
        uint256 proposedId = _getMemberTokenId(proposed);

        Effort storage e = efforts[nextEffortId];
        e.id = nextEffortId;
        e.proposerTokenId = proposerId;
        e.proposedTokenId = proposedId;
        e.amount = msg.value;
        e.proposedDurationDays = proposedDurationDays;
        e.awaitingNewDuration = false;
        e.requestedNewDurationDays = 0;
        e.committed = false;
        e.commitmentAcceptedDate = 0;
        e.achievementCompleted = false;
        e.completedAt = 0;
        e.concluded = false;
        e.createdAt = block.timestamp;

        emit ProposalSubmitted(nextEffortId, msg.sender, proposed, msg.value, proposedDurationDays);
        nextEffortId++;
    }

    function requestDurationUpdate(uint256 effortId, uint256 newDurationDays) external onlyMember {
        Effort storage e = efforts[effortId];
        require(e.id == effortId, "invalid effort");
        require(!e.concluded, "already concluded");
        uint256 callerTokenId = _getMemberTokenId(msg.sender);
        require(callerTokenId == e.proposedTokenId, "only proposed may request");

        e.awaitingNewDuration = true;
        e.requestedNewDurationDays = newDurationDays;
        emit DurationUpdateRequested(effortId, newDurationDays);
    }

    function approveDurationUpdate(uint256 effortId) external onlyMember {
        Effort storage e = efforts[effortId];
        require(e.id == effortId, "invalid effort");
        require(!e.concluded, "already concluded");
        uint256 callerTokenId = _getMemberTokenId(msg.sender);
        require(callerTokenId == e.proposerTokenId, "only proposer may approve");
        require(e.awaitingNewDuration, "no pending request");

        e.proposedDurationDays = e.requestedNewDurationDays;
        e.awaitingNewDuration = false;
        e.requestedNewDurationDays = 0;
        emit DurationUpdateApproved(effortId, e.proposedDurationDays);
    }

    function commitToEffort(uint256 effortId) external onlyMember onlyActiveMember {
        Effort storage e = efforts[effortId];
        require(e.id == effortId, "invalid effort");
        require(!e.committed, "already committed");
        uint256 callerTokenId = _getMemberTokenId(msg.sender);
        require(callerTokenId == e.proposedTokenId, "only proposed can commit");

        _updatePenalty(callerTokenId);
        require(isActive(msg.sender), "pending subscription/penalty");

        e.committed = true;
        e.commitmentAcceptedDate = block.timestamp;
        emit CommitmentAccepted(effortId, msg.sender, block.timestamp);
    }

    function markEffortCompleted(uint256 effortId) external onlyMember {
        Effort storage e = efforts[effortId];
        require(e.id == effortId, "invalid effort");
        require(e.committed, "not committed");
        uint256 callerTokenId = _getMemberTokenId(msg.sender);
        require(callerTokenId == e.proposedTokenId, "only proposed can mark completion");
        require(!e.achievementCompleted, "already marked");

        e.achievementCompleted = true;
        e.completedAt = block.timestamp;
        emit CompletedMarked(effortId, block.timestamp);
    }

    function approveEffortCompletion(uint256 effortId) external nonReentrant onlyMember {
        Effort storage e = efforts[effortId];
        require(e.id == effortId, "invalid effort");
        require(e.committed, "not committed");
        require(e.achievementCompleted, "proposed hasn't marked completion");
        require(!e.concluded, "already concluded");

        uint256 callerTokenId = _getMemberTokenId(msg.sender);
        require(callerTokenId == e.proposerTokenId, "only proposer can approve");

        uint256 proposerDeposit = e.amount;
        e.amount = 0;
        e.concluded = true;

        uint256 matchable = proposerDeposit;
        uint256 matched = (treasuryBalance >= matchable) ? matchable : treasuryBalance;
        if (matched > 0) treasuryBalance -= matched;

        uint256 payoutTotal = proposerDeposit + matched;
        (bool ok, ) = payable(ownerOf(e.proposedTokenId)).call{value: payoutTotal}("");
        require(ok, "transfer failed");

        emit CompletionApproved(effortId, proposerDeposit, matched);
    }

    function autoFailIfNoApproval(uint256 effortId) external nonReentrant onlyMember {
        Effort storage e = efforts[effortId];
        require(e.id == effortId, "invalid effort");
        require(e.achievementCompleted, "not marked completed");
        require(!e.concluded, "already concluded");

        uint256 deadlineForApproval = e.completedAt + CONFIRM_WINDOW;
        require(block.timestamp > deadlineForApproval, "confirmation window still open");

        uint256 depositToReturn = e.amount;
        e.amount = 0;
        e.concluded = true;

        if (depositToReturn > 0) {
            (bool ok, ) = payable(ownerOf(e.proposerTokenId)).call{value: depositToReturn}("");
            require(ok, "refund failed");
        }

        emit ProposalFailed(effortId);
    }

    function failIfNotCompletedByDeadline(uint256 effortId) external nonReentrant onlyMember {
        Effort storage e = efforts[effortId];
        require(e.id == effortId, "invalid effort");
        require(e.committed, "not committed");
        require(!e.concluded, "already concluded");

        uint256 deadline = e.commitmentAcceptedDate + (e.proposedDurationDays * 1 days);
        require(block.timestamp > deadline, "deadline not reached");

        if (!e.achievementCompleted) {
            uint256 depositToReturn = e.amount;
            e.amount = 0;
            e.concluded = true;
            if (depositToReturn > 0) {
                (bool ok, ) = payable(ownerOf(e.proposerTokenId)).call{value: depositToReturn}("");
                require(ok, "refund failed");
            }
            emit ProposalFailed(effortId);
        } else {
            revert("marked completed - handle via approve or autoFail");
        }
    }

    // ---- TREASURY / FALLBACK ----
    function ownerTopUpTreasury() external payable onlyOwner {
        require(msg.value > 0, "zero");
        treasuryBalance += msg.value;
        emit TreasuryToppedUp(msg.sender, msg.value);
    }

    receive() external payable {
        treasuryBalance += msg.value;
        emit TreasuryToppedUp(msg.sender, msg.value);
    }

    // ---- EVENTS ----
    event SubscriptionPaid(address indexed member, uint256 periods, uint256 paidThrough, uint256 value);
    event PenaltyAccrued(address indexed member, uint256 penalty);
    event PenaltyPaid(address indexed member, uint256 value);
    event TreasuryToppedUp(address indexed from, uint256 value);
    event ProposalSubmitted(uint256 indexed id, address indexed proposer, address indexed proposed, uint256 amount, uint256 durationDays);
    event DurationUpdateRequested(uint256 indexed id, uint256 newDurationDays);
    event DurationUpdateApproved(uint256 indexed id, uint256 newDurationDays);
    event CommitmentAccepted(uint256 indexed id, address indexed proposed, uint256 timestamp);
    event CompletedMarked(uint256 indexed id, uint256 timestamp);
    event CompletionApproved(uint256 indexed id, uint256 rewardPaid, uint256 matchedFromTreasury);
    event ProposalFailed(uint256 indexed id);
}
