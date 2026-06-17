// BountyEscrow — holds funds for a single bounty, manages submissions & payouts

import "@stdlib/ownable";

// ─── Messages ────────────────────────────────────────────────────────────────

message SubmitProof {
    proofUrl: String; // link to screenshot / proof
}

message ApproveSubmission {
    submissionId: Int;
}

message RejectSubmission {
    submissionId: Int;
}

message SelectWinners {
    count: Int;
    winnerIds: map<Int, Address>;
}

message CancelBounty {}

message WithdrawExcess {}

// ─── Structs ─────────────────────────────────────────────────────────────────

struct Submission {
    id: Int;
    submitter: Address;
    proofUrl: String;
    submittedAt: Int;
    approved: Bool;
}

// ─── Contract ────────────────────────────────────────────────────────────────

contract BountyEscrow with Ownable {

    owner: Address;

    // Identity
    title: String;
    description: String;
    bountyType: String; // "task" | "quiz" | "creative"

    // Economics
    poolAmount: Int;       // total TON in nanotons
    winnerCount: Int;
    perWinnerAmount: Int; // poolAmount / winnerCount
    platformFeeBps: Int;  // platform fee in basis points (100 = 1%)
    platformAddress: Address;

    // Selection & verification
    winnerSelection: String; // "draw" | "manual"
    verification: String;    // "manual" | "auto"
    verificationRule: String;

    // Timing
    createdAt: Int;
    durationSeconds: Int;   // always 86400 (24h)
    reviewWindowSeconds: Int; // 86400 (24h after bounty ends for manual review)
    endsAt: Int;
    reviewEndsAt: Int;

    // State
    status: String; // "active" | "review" | "completed" | "cancelled"
    submissions: map<Int, Submission>;
    submissionCount: Int;
    nextSubmissionId: Int;
    winners: map<Int, Address>; // index -> winner address
    winnerCountFinal: Int;
    payoutDone: Bool;

    init(
        owner: Address,
        title: String,
        description: String,
        bountyType: String,
        poolAmount: Int,
        winnerCount: Int,
        winnerSelection: String,
        verification: String,
        verificationRule: String,
        platformFeeBps: Int,
        platformAddress: Address,
        createdAt: Int
    ) {
        self.owner = owner;
        self.title = title;
        self.description = description;
        self.bountyType = bountyType;
        self.poolAmount = poolAmount;
        self.winnerCount = winnerCount;
        self.perWinnerAmount = poolAmount / winnerCount;
        self.winnerSelection = winnerSelection;
        self.verification = verification;
        self.verificationRule = verificationRule;
        self.platformFeeBps = platformFeeBps;
        self.platformAddress = platformAddress;
        self.createdAt = createdAt;
        self.durationSeconds = 86400; // 24 hours — fixed
        self.reviewWindowSeconds = 86400; // 24 hours for review
        self.endsAt = createdAt + 86400;
        self.reviewEndsAt = self.endsAt + 86400;
        self.status = "active";
        self.submissions = emptyMap();
        self.submissionCount = 0;
        self.nextSubmissionId = 0;
        self.winners = emptyMap();
        self.winnerCountFinal = 0;
        self.payoutDone = false;
    }

    // ─── Receive TON ──────────────────────────────────────────────────────────

    receive() {
        // Accept incoming TON for escrow funding
    }

    // ─── Submit proof ────────────────────────────────────────────────────────

    receive(msg: SubmitProof) {
        require(self.status == "active", "Bounty not active");
        require(now() <= self.endsAt, "Bounty ended");

        let sub = Submission {
            id: self.nextSubmissionId,
            submitter: sender(),
            proofUrl: msg.proofUrl,
            submittedAt: now(),
            approved: false,
        };

        self.submissions.set(self.nextSubmissionId, sub);
        self.nextSubmissionId = self.nextSubmissionId + 1;
        self.submissionCount = self.submissionCount + 1;
    }

    // ─── Approve / reject submissions (manual verification) ──────────────────

    receive(msg: ApproveSubmission) {
        require(self.owner == sender(), "Only owner");
        require(self.status == "active" || self.status == "review", "Not in review period");

        let optSub = self.submissions.get(msg.submissionId);
        require(optSub != null, "Submission not found");

        let sub = optSub!!;
        sub.approved = true;
        self.submissions.set(msg.submissionId, sub);
    }

    receive(msg: RejectSubmission) {
        require(self.owner == sender(), "Only owner");
        require(self.status == "active" || self.status == "review", "Not in review period");

        let optSub = self.submissions.get(msg.submissionId);
        require(optSub != null, "Submission not found");

        let sub = optSub!!;
        sub.approved = false;
        self.submissions.set(msg.submissionId, sub);
    }

    // ─── Select winners (manual mode) ─────────────────────────────────────────

    receive(msg: SelectWinners) {
        require(self.owner == sender(), "Only owner");
        require(self.winnerSelection == "manual", "Not manual selection");
        require(self.status == "review", "Not in review");

        // Count selected winners
        let count: Int = 0;
        let remainingPool: Int = self.poolAmount;

        // Distribute payouts to selected winners
        let platformFee = self.perWinnerAmount * self.platformFeeBps / 10000;
        let payoutPerWinner = self.perWinnerAmount - platformFee;

        // Send platform fee
        send(SendParameters {
            to: self.platformAddress,
            value: platformFee * msg.count,
            mode: SendPayGasSeparately + SendIgnoreErrors,
        });

        // Send payouts to each winner
        let idx: Int = 0;
        repeat (msg.count) {
            let winnerAddr = msg.winnerIds.get(idx)!!;
            self.winners.set(idx, winnerAddr);

            send(SendParameters {
                to: winnerAddr,
                value: payoutPerWinner,
                mode: SendPayGasSeparately + SendIgnoreErrors,
            });

            idx = idx + 1;
        }

        self.winnerCountFinal = msg.count;
        self.payoutDone = true;
        self.status = "completed";
    }

    // ─── Cancel bounty ───────────────────────────────────────────────────────

    receive(msg: CancelBounty) {
        require(self.owner == sender(), "Only owner");
        require(self.status == "active", "Can only cancel active bounty");

        // Refund full pool to owner
        send(SendParameters {
            to: self.owner,
            value: self.poolAmount,
            mode: SendPayGasSeparately + SendIgnoreErrors,
        });

        self.status = "cancelled";
    }

    // ─── Auto-complete: draw winners after review window ──────────────────────

    receive("auto_complete") {
        // Only trigger after review window
        require(now() > self.reviewEndsAt, "Review window not over");
        require(self.status == "active" || self.status == "review", "Not active/review");
        require(!self.payoutDone, "Already paid out");

        // Collect approved submissions
        let approvedIds: map<Int, Int> = emptyMap(); // submissionId -> 1
        let approvedCount: Int = 0;

        let i: Int = 0;
        repeat (self.submissionCount) {
            let optSub = self.submissions.get(i);
            if (optSub != null) {
                let sub = optSub!!;
                if (sub.approved) {
                    approvedIds.set(approvedCount, sub.id);
                    approvedCount = approvedCount + 1;
                }
            }
            i = i + 1;
        }

        // If no approved submissions, refund owner
        if (approvedCount == 0) {
            send(SendParameters {
                to: self.owner,
                value: self.poolAmount,
                mode: SendPayGasSeparately + SendIgnoreErrors,
            });
            self.status = "cancelled";
            return;
        }

        // For draw mode: randomly select winners from approved submissions
        let actualWinners: Int = min(self.winnerCount, approvedCount);
        let platformFee = self.perWinnerAmount * self.platformFeeBps / 10000;
        let payoutPerWinner = self.perWinnerAmount - platformFee;

        // Send platform fee
        send(SendParameters {
            to: self.platformAddress,
            value: platformFee * actualWinners,
            mode: SendPayGasSeparately + SendIgnoreErrors,
        });

        // Random draw using on-chain randomness (built-in Tact random)
        let selected: map<Int, Bool> = emptyMap();
        let winnerIdx: Int = 0;

        while (winnerIdx < actualWinners) {
            let randIdx = random(0, approvedCount);
            let subId = approvedIds.get(randIdx)!!;
            let sub = self.submissions.get(subId)!!;
            if (selected.get(randIdx) == null) {
                selected.set(randIdx, true);
                self.winners.set(winnerIdx, sub.submitter);
                send(SendParameters {
                    to: sub.submitter,
                    value: payoutPerWinner,
                    mode: SendPayGasSeparately + SendIgnoreErrors,
                });
                winnerIdx = winnerIdx + 1;
            }
        }

        self.winnerCountFinal = winnerIdx;
        self.payoutDone = true;
        self.status = "completed";
    }

    // ─── Withdraw excess (unused pool after payout) ──────────────────────────

    receive(msg: WithdrawExcess) {
        require(self.payoutDone, "Payout not done");
        require(self.owner == sender(), "Only owner");

        let usedPool = self.perWinnerAmount * self.winnerCountFinal;
        let excess = self.poolAmount - usedPool;

        if (excess > 0) {
            send(SendParameters {
                to: self.owner,
                value: excess,
                mode: SendPayGasSeparately + SendIgnoreErrors,
            });
        }
    }

    // ─── Getters ─────────────────────────────────────────────────────────────

    get fun title(): String { return self.title; }
    get fun description(): String { return self.description; }
    get fun bountyType(): String { return self.bountyType; }
    get fun poolAmount(): Int { return self.poolAmount; }
    get fun winnerCount(): Int { return self.winnerCount; }
    get fun perWinnerAmount(): Int { return self.perWinnerAmount; }
    get fun winnerSelection(): String { return self.winnerSelection; }
    get fun verification(): String { return self.verification; }
    get fun status(): String { return self.status; }
    get fun endsAt(): Int { return self.endsAt; }
    get fun reviewEndsAt(): Int { return self.reviewEndsAt; }
    get fun submissionCount(): Int { return self.submissionCount; }
    get fun payoutDone(): Bool { return self.payoutDone; }
    get fun winnerCountFinal(): Int { return self.winnerCountFinal; }
}
