// BountyFactory — deploys BountyEscrow contracts and tracks all bounties

import "@stdlib/ownable";
import "./BountyEscrow.tact";

// ─── Messages ────────────────────────────────────────────────────────────────

message CreateBounty {
    title: String;
    description: String;
    bountyType: String;
    winnerCount: Int;
    winnerSelection: String;
    verification: String;
    verificationRule: String;
}

// ─── Contract ────────────────────────────────────────────────────────────────

contract BountyFactory with Ownable {

    owner: Address;
    platformFeeBps: Int;
    platformAddress: Address;
    bountyCount: Int;
    bounties: map<Int, Address>;

    init(platformFeeBps: Int, platformAddress: Address) {
        self.owner = sender();
        self.platformFeeBps = platformFeeBps;
        self.platformAddress = platformAddress;
        self.bountyCount = 0;
        self.bounties = emptyMap();
    }

    receive(msg: CreateBounty) {
        // Validate minimum payout: pool must cover $0.01 per winner
        let poolAmount = context().value;
        let perWinner = poolAmount / msg.winnerCount;

        // Minimum per-winner: 1000000 nanotons (~0.001 TON, well above $0.01)
        require(perWinner >= 1000000, "Per-winner payout too low");
        require(msg.winnerCount >= 1, "Must have at least 1 winner");
        require(msg.winnerSelection == "draw" || msg.winnerSelection == "manual", "Invalid selection");
        require(msg.verification == "manual" || msg.verification == "auto", "Invalid verification");

        // Deploy new BountyEscrow contract
        let escrow = initOf BountyEscrow(
            sender(),
            msg.title,
            msg.description,
            msg.bountyType,
            poolAmount,
            msg.winnerCount,
            msg.winnerSelection,
            msg.verification,
            msg.verificationRule,
            self.platformFeeBps,
            self.platformAddress,
            now()
        );

        // Send the pool amount to the escrow contract
        send(SendParameters {
            to: contractAddress(escrow),
            value: poolAmount,
            mode: SendPayGasSeparately,
        });

        // Track the bounty
        self.bounties.set(self.bountyCount, contractAddress(escrow));
        self.bountyCount = self.bountyCount + 1;
    }

    // ─── Admin ────────────────────────────────────────────────────────────────
    
    receive(msg: SetPlatformFee) {
        require(self.owner == sender(), "Only owner");
        self.platformFeeBps = msg.newFee;
    }

    // ─── Getters ──────────────────────────────────────────────────────────────────

    get fun bountyCount(): Int { return self.bountyCount; }
    get fun platformFeeBps(): Int { return self.platformFeeBps; }
    get fun platformAddress(): Address { return self.platformAddress; }

    get fun bountyAddress(index: Int): Address {
        return self.bounties.get(index)!!;
    }
}
