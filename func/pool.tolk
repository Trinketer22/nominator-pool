import "@stdlib/tvm-dicts"
import "@stdlib/gas-payments"
import "@stdlib/lisp-lists"
// The validator has his own wallet in the masterchain, on which he holds his own coins for operating.
// From this wallet he sends commands to this nominator pool (mostly `new_stake`, `update_validator_set` and `recover_stake`).
// Register/vote_for complaints and register/vote_for config proposals are sent from validator's wallet.
//
// Pool contract must be in masterchain.
// Nominators' wallets must be in the basechain.
// The validator in most cases have two pools (for even and odd validation rounds).

@pure
fun `op::new_stake`(): int
    asm "0x4e73744b PUSHINT"; // https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/smartcont/elector-code.fc#L621
@pure
fun `op::new_stake_error`(): int
    asm "0xee6f454c PUSHINT"; // return_stake https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/smartcont/elector-code.fc#L169
@pure
fun `op::new_stake_ok`(): int
    asm "0xf374484c PUSHINT"; // send_confirmation https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/smartcont/elector-code.fc#L173

@pure
fun `op::recover_stake`(): int
    asm "0x47657424 PUSHINT"; // https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/smartcont/elector-code.fc#L625
@pure
fun `op::recover_stake_error`(): int
    asm "0xfffffffe PUSHINT"; // https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/smartcont/elector-code.fc#L407
@pure
fun `op::recover_stake_ok`(): int
    asm "0xf96f7324 PUSHINT"; // https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/smartcont/elector-code.fc#L426

@pure
fun ADDR_SIZE(): int
    asm "256 PUSHINT";

@pure
fun SEND_MODE_PAY_FEE_SEPARATELY(): int
    asm "1 PUSHINT"; // means that the sender wants to pay transfer fees separately
@pure
fun SEND_MODE_REMAINING_AMOUNT(): int
    asm "64 PUSHINT"; // is used for messages that carry all the remaining value of the inbound message in addition to the value initially indicated in the new message
@pure
fun ONE_TON(): int
    asm "1000000000 PUSHINT";
@pure
fun MIN_TONS_FOR_STORAGE(): int
    asm "10000000000 PUSHINT"; // 10 TON
@pure
fun DEPOSIT_PROCESSING_FEE(): int
    asm "1000000000 PUSHINT"; // 1 TON
@pure
fun MIN_STAKE_TO_SEND(): int
    asm "500000000000 PUSHINT"; // 500 TON
@pure
fun VOTES_LIFETIME(): int
    asm "2592000 PUSHINT"; // 30 days

@pure
fun binaryLogCeil(x: int): int
    asm "UBITSIZE";

// hex parse same with bridge https://github.com/ton-blockchain/bridge-func/blob/d03dbdbe9236e01efe7f5d344831bf770ac4c613/func/text_utils.fc
fun loadHexSymbol(mutate self: slice): int {
    var n: int = self.loadUint(8);
    n = n - 48;
    assert(n >= 0) throw 329;
    if (n < 10) {
        return (n);
    }
    n = n - 7;
    assert(n >= 0) throw 329;
    if (n < 16) {
        return (n);
    }
    n = n - 32;
    assert((n >= 0) & (n < 16)) throw 329;
    return n;
}

fun loadTextHexNumber(mutate self: slice, byteLength: int): int {
    var currentSliceLength: int = self.getRemainingBitsCount() / 8;
    var result: int = 0;
    var counter: int = 0;
    repeat (2 * byteLength) {
        result = result * 16 + self.loadHexSymbol();
        counter = counter + 1;
        if (counter == currentSliceLength) {
            if (self.getRemainingRefsCount() == 1) {
                var Cont: cell = self.loadRef();
                self = Cont.beginParse();
                currentSliceLength = self.getRemainingBitsCount() / 8;
                counter = 0;
            }
        }
    }
    return result;
}

@inline_ref
fun makeAddress(wc: int, addr: int): slice {
    return beginCell()
           .storeUint(4, 3).storeInt(wc, 8).storeUint(addr, ADDR_SIZE()).endCell().beginParse();
}

// https://github.com/ton-blockchain/ton/blob/ae5c0720143e231c32c3d2034cfe4e533a16d969/crypto/block/block.tlb#L584
@inline_ref
fun isElectorAddress(wc: int, addr: int): bool {
  return (wc == -1) && (getBlockchainConfigParam(1)!.beginParse().preloadUint(ADDR_SIZE()) == addr);
}

@inline_ref
fun electorAddress(): slice {
    var elector: int = getBlockchainConfigParam(1)!.beginParse().preloadUint(ADDR_SIZE());
    return makeAddress(-1, elector);
}

// https://github.com/ton-blockchain/ton/blob/ae5c0720143e231c32c3d2034cfe4e533a16d969/crypto/block/block.tlb#L721
@inline_ref
fun maxRecommendedPunishmentForValidatorMisbehaviour(stake: int): int {
    var cp: cell? = getBlockchainConfigParam(40);
    if (cp == null) {
        return 101000000000; // 101 TON - https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/lite-client/lite-client.cpp#L3678
    }

    var cs: slice = cp.beginParse();

    var (prefix: int,
     defaultFlatFine: int, defaultProportionalFine: int,
     severityFlatMult: int, severityProportionalMult: int,
     unpunishableInterval: int,
     longInterval: int, longFlatMult: int, longProportionalMult: int) =
        (cs.loadUint(8),
         cs.loadCoins(), cs.loadUint(32),
         cs.loadUint(16), cs.loadUint(16),
         cs.loadUint(16),
         cs.loadUint(16), cs.loadUint(16), cs.loadUint(16)
        );

     // https://github.com/ton-blockchain/ton/blob/master/lite-client/lite-client.cpp#L3721
     var fine: int = defaultFlatFine;
     var finePart: int = defaultProportionalFine;

     fine *= severityFlatMult; fine >>= 8;
     finePart *= severityProportionalMult; finePart >>= 8;

     fine *= longFlatMult; fine >>= 8;
     finePart *= longProportionalMult; finePart >>= 8;

     return min(stake, fine + mulDivFloor(stake, finePart, 1 << 32)); // https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/smartcont/elector-code.fc#L529
}

// https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/block/block.tlb#L632
// https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/smartcont/elector-code.fc#L118
@inline_ref
fun getValidatorConfig(): int {
    var cs: slice = getBlockchainConfigParam(15)!.beginParse();
    var (validatorsElectedFor: int, electionsStartBefore: int, electionsEndBefore: int, stakeHeldFor: int) = (cs.loadUint(32), cs.loadUint(32), cs.loadUint(32), cs.preloadUint(32));
    return stakeHeldFor;
}

// https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/block/block.tlb#L712
@inline_ref
fun getCurrentValidatorSet(): (int, int, cell) {
    var vset: cell = getBlockchainConfigParam(34)!; // current validator set
    var cs: slice = vset.beginParse();
    // https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/block/block.tlb#L579
    // https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/smartcont/config-code.fc#L49
    assert(cs.loadUint(8) == 0x12) throw 9;  // validators_ext#12 only
    var utimeSince: int = cs.loadUint(32); // actual start unixtime of current validation round
    var utimeUntil: int = cs.loadUint(32); // supposed end unixtime of current validation round (utime_until = utime_since + validators_elected_for); unfreeze_at = utime_until + stake_held_for
    return (utimeSince, utimeUntil, vset);
}

// check the validity of the new_stake message
// https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/smartcont/elector-code.fc#L208
@inline_ref
fun checkNewStakeMsg(cs: slice): int {
    var validatorPubkey = cs.loadUint(256);
    var stakeAt = cs.loadUint(32);
    var maxFactor = cs.loadUint(32);
    var adnlAddr = cs.loadUint(256);
    var signature = cs.loadRef().beginParse().preloadBits(512);
    cs.assertEndOfSlice();
    return stakeAt; // supposed start of next validation round (utime_since)
}

@inline_ref
fun packNominator(amount: int, pendingDepositAmount: int): builder {
    return beginCell().storeCoins(amount).storeCoins(pendingDepositAmount);
}

@inline_ref
fun unpackNominator(ds: slice): (int, int) {
    return (
        ds.loadCoins(), // amount
        ds.loadCoins()  // pending_deposit_amount
    );
}

@inline_ref
fun packConfig(validatorAddress: int, validatorRewardShare: int, maxNominatorsCount: int, minValidatorStake: int, minNominatorStake: int): cell {
    return beginCell()
        .storeUint(validatorAddress, ADDR_SIZE())
        .storeUint(validatorRewardShare, 16)
        .storeUint(maxNominatorsCount, 16)
        .storeCoins(minValidatorStake)
        .storeCoins(minNominatorStake)
        .endCell();
}

@inline_ref
fun unpackConfig(ds: slice): (int, int, int, int, int) {
    return (
        ds.loadUint(ADDR_SIZE()), // validator_address
        ds.loadUint(16), // validator_reward_share
        ds.loadUint(16), // max_nominators_count
        ds.loadCoins(), // min_validator_stake
        ds.loadCoins() // min_nominator_stake
    );
}

@inline_ref
fun saveData(state: int, nominatorsCount: int, stakeAmountSent: int, validatorAmount: int, config: cell, nominators: cell?, withdrawRequests: cell?, stakeAt: int, savedValidatorSetHash: int, validatorSetChangesCount: int, validatorSetChangeTime: int, stakeHeldFor: int, configProposalVotings: cell?) {
    setContractData(beginCell()
        .storeUint(state, 8)
        .storeUint(nominatorsCount, 16)
        .storeCoins(stakeAmountSent)
        .storeCoins(validatorAmount)
        .storeRef(config)
        .storeDict(nominators)
        .storeDict(withdrawRequests)
        .storeUint(stakeAt, 32)
        .storeUint(savedValidatorSetHash, 256)
        .storeUint(validatorSetChangesCount, 8)
        .storeUint(validatorSetChangeTime, 32)
        .storeUint(stakeHeldFor, 32)
        .storeDict(configProposalVotings)
        .endCell());
}

@inline_ref
fun loadData(): (int, int, int, int, (int, int, int, int, int), cell?, cell?, int, int, int, int, int, cell?) {
    var ds: slice = getContractData().beginParse();
    return (
        ds.loadUint(8), // state
        ds.loadUint(16), // nominators_count
        ds.loadCoins(), // stake_amount_sent
        ds.loadCoins(), // validator_amount
        unpackConfig(ds.loadRef().beginParse()), // config
        ds.loadDict(), // nominators
        ds.loadDict(), // withdraw_requests
        ds.loadUint(32), // stake_at
        ds.loadUint(256), // saved_validator_set_hash
        ds.loadUint(8), // validator_set_changes_count
        ds.loadUint(32), // validator_set_change_time
        ds.loadUint(32), // stake_held_for
        ds.loadDict() // config_proposal_votings
    );
}

@inline_ref
fun sendMsg(toAddress: slice, amount: int, payload: cell?, flags: int, sendMode: int) {
    var hasPayload: bool = payload != null;

    var msg: builder = beginCell()
        .storeUint(flags, 6)
        .storeSlice(toAddress)
        .storeCoins(amount)
        .storeUint(hasPayload ? 1 : 0, 1 + 4 + 4 + 64 + 32 + 1 + 1);

    if (hasPayload) {
        msg = msg.storeRef(payload!);
    }

    sendRawMessage(msg.endCell(), sendMode);
}

@inline_ref
fun sendExcesses(senderAddress: slice) {
    sendMsg(senderAddress, 0, null, NON_BOUNCEABLE, SEND_MODE_REMAINING_AMOUNT() + SEND_MODE_IGNORE_ERRORS); // non-bouneable, remaining inbound message amount, fee deducted from amount, ignore errors
}

@inline_ref
fun withdrawNominator(address: int, nominators: cell?, withdrawRequests: cell?, balance: int, nominatorsCount: int): (cell?, cell?, int, int) {
    var (nominator: slice?, found: bool) = nominators!.uDictGet(ADDR_SIZE(), address);
    assert(found) throw 60;
    var (amount: int, pendingDepositAmount: int) = unpackNominator(nominator!);
    var withdrawAmount: int = amount + pendingDepositAmount;

    if (withdrawAmount > balance - MIN_TONS_FOR_STORAGE()) {
        return (nominators, withdrawRequests, balance, nominatorsCount);
    }

    nominators.uDictDelete(ADDR_SIZE(), address);
    withdrawRequests.uDictDelete(ADDR_SIZE(), address);
    nominatorsCount -= 1;
    balance -= withdrawAmount;

    if (withdrawAmount >= ONE_TON()) {
        sendMsg(makeAddress(0, address), withdrawAmount, null, NON_BOUNCEABLE, 0); // non-bouneable, fee deducted from amount, revert on errors
    }
    return (nominators, withdrawRequests, balance, nominatorsCount);
}

@inline_ref
fun processWithdrawRequests(nominators: cell?, withdrawRequests: cell?, balance: int, nominatorsCount: int, limit: int): (cell?, cell?, int, int) {
    var count: int = 0;
    var address: int = -1;
    var needBreak: bool = false;
    do {
        var (foundAddress: int?, cs: slice?, f: bool) = withdrawRequests.uDictGetNext(ADDR_SIZE(), address);
        if (f) {
            address = foundAddress!;
            var (processed, requestsAfter, newBalance: int, newCount: int) = withdrawNominator(address!, nominators, withdrawRequests, balance, nominatorsCount);
            nominators = processed;
            withdrawRequests = requestsAfter;
            nominatorsCount  = newCount;
            needBreak = (newBalance == balance);
            balance = newBalance;
            count += 1;
            if (count >= limit) {
                needBreak = true;
            }
        }
    } while (f && (needBreak == false));

    return (nominators, withdrawRequests, nominatorsCount, balance);
}

@inline_ref
fun calculateTotalNominatorsAmount(nominators: cell?): int {
    var total: int = 0;
    var address: int = -1;
    do {
        var (foundAddress: int?, cs: slice?, f: bool) = nominators.uDictGetNext(ADDR_SIZE(), address);
        if (f) {
            address = foundAddress!;
            var (amount: int, pendingDepositAmount: int) = unpackNominator(cs!);
            total += (amount + pendingDepositAmount);
        }
    } while (f);
    return total;
}

@inline_ref
fun distributeShare(reward: int, nominators: cell?): cell? {
    var totalAmount: int = 0;
    var address: int = -1;
    do {
        var (foundAddress: int? , cs: slice?, f: bool) = nominators.uDictGetNext(ADDR_SIZE(), address);
        if (f) {
            address = foundAddress!;
            var (amount: int, pendingDepositAmount: int) = unpackNominator(cs!);
            totalAmount += amount;
        }
    } while (f);

    var newNominators: cell? = createEmptyDict();
    address = -1;
    do {
        var (foundAddress: int? , cs: slice?, f: bool) = nominators.uDictGetNext(ADDR_SIZE(), address);
        if (f) {
            address = foundAddress!;
            var (amount: int, pendingDepositAmount: int) = unpackNominator(cs!);
            if (totalAmount > 0) {
                amount += mulDivFloor(reward, amount, totalAmount);
                if (amount < 0) {
                    amount = 0;
                }
            }
            amount += pendingDepositAmount;
            newNominators.uDictSetBuilder(ADDR_SIZE(), address!, packNominator(amount, 0));
        }
    } while (f);

    return newNominators;
}

fun onInternalMessage(msgValue: int, inMsgFull: cell, inMsgBody: slice) {
    var balance: int = getMyOriginalBalance();

    var cs: slice = inMsgFull.beginParse();
    var flags: int = cs.loadUint(4);

    var senderAddress: slice = cs.loadAddress();
    var (senderWc: int, senderAddr: int) = parseStandardAddress(senderAddress);

    if (flags & 1) { // bounced messages
        if (inMsgBody.getRemainingBitsCount() >= 64) {
            inMsgBody.skipBits(32); // skip 0xFFFFFFFF bounced prefix
            var op: int = inMsgBody.loadUint(32);
            if ((op == `op::new_stake`()) & (isElectorAddress(senderWc, senderAddr))) {
                // `new_stake` from nominator-pool should always be handled without throws by elector
                // because nominator-pool do `check_new_stake_msg` and `msg_value` checks before sending `new_stake`.
                // If the stake is not accepted elector will send `new_stake_error` response message.
                // Nevertheless we do process theoretically possible bounced `new_stake`.

                var (state: int, nominatorsCount: int, stakeAmountSent: int, validatorAmount: int, (validatorAddress: int, validatorRewardShare: int, maxNominatorsCount: int, minValidatorStake: int, minNominatorStake: int), nominators: cell?, withdrawRequests: cell?, stakeAt: int, savedValidatorSetHash: int, validatorSetChangesCount: int, validatorSetChangeTime: int, stakeHeldFor: int, configProposalVotings: cell?) = loadData();
                if (state == 1) {
                    state = 0;
                }
                saveData(
                    state,
                    nominatorsCount,
                    stakeAmountSent,
                    validatorAmount,
                    packConfig(validatorAddress, validatorRewardShare, maxNominatorsCount, minValidatorStake, minNominatorStake),
                    nominators,
                    withdrawRequests,
                    stakeAt,
                    savedValidatorSetHash,
                    validatorSetChangesCount,
                    validatorSetChangeTime,
                    stakeHeldFor,
                    configProposalVotings
                );
            }
        }
        return; // ignore other bounces messages
    }

    var op: int = inMsgBody.loadUint(32);

   var (state: int, nominatorsCount: int, stakeAmountSent: int, validatorAmount: int, (validatorAddress: int, validatorRewardShare: int, maxNominatorsCount: int, minValidatorStake: int, minNominatorStake: int), nominators: cell?, withdrawRequests: cell?, stakeAt: int, savedValidatorSetHash: int, validatorSetChangesCount: int, validatorSetChangeTime: int, stakeHeldFor: int, configProposalVotings: cell?) = loadData();

    if (op == 0) {
        // We use simple text comments for nominator operations so nominators can do it from any wallet app.
        // In other cases, they will need to put a stake on a browser extension, or use scripts, which can be inconvenient.

        // Throw on any unexpected request so that the stake is bounced back to the nominator in case of a typo.

        var action: int = inMsgBody.loadUint(8);
        var isVote: bool = (action == 121) || (action == 110); // "y" or "n"
        assert((action == 100) || (action == 119) || isVote) throw 64; // "d" or "w" or "y" or "n"

        if (! isVote) {
            inMsgBody.assertEndOfSlice();
            assert(senderWc == 0) throw 61; // nominators only in basechain
            assert(senderAddr != validatorAddress) throw 62;
        }

        if (action == 100) { // "d" - deposit nominator (any time, will take effect in the next round)
            var (nominator: slice?, found: bool) = nominators.uDictGet(ADDR_SIZE(), senderAddr);

            if (! found) {
                nominatorsCount += 1;
            }
            assert(nominatorsCount <= maxNominatorsCount) throw 65;

            msgValue -= DEPOSIT_PROCESSING_FEE();
            assert(msgValue > 0) throw 66;

            var (amount: int, pendingDepositAmount: int) = found ? unpackNominator(nominator!) : (0, 0);
            if (state == 0) {
                amount += msgValue;
            } else {
                pendingDepositAmount += msgValue;
            }
            assert(amount + pendingDepositAmount >= minNominatorStake) throw 67;
            assert(getCellDepth(nominators) < max(5, binaryLogCeil(nominatorsCount) * 2)) throw 68; // prevent dict depth ddos
            nominators.uDictSetBuilder(ADDR_SIZE(), senderAddr, packNominator(amount, pendingDepositAmount));
        }

        if (action == 119) { // "w" - withdraw request (any time)
            if (state == 0) {
                var (nmProcessed: cell?, withdrawProcessed: cell? , newBalance: int, newNmCount: int ) = withdrawNominator(senderAddr, nominators, withdrawRequests, balance, nominatorsCount);
                nominatorsCount = newNmCount;
                if (newBalance - msgValue >= MIN_TONS_FOR_STORAGE()) {
                    sendExcesses(senderAddress);
                }
                nominators = nmProcessed;
                withdrawRequests = withdrawProcessed;
            } else {
                var (nominator: slice?, found: bool) = nominators.uDictGet(ADDR_SIZE(), senderAddr);
                assert(found) throw 69;
                withdrawRequests.uDictSetBuilder(ADDR_SIZE(), senderAddr, beginCell());
                sendExcesses(senderAddress);
            }
        }

        if (isVote) {
            var authorized: bool = (senderWc == -1) && (senderAddr == validatorAddress);

            if (! authorized) {
                assert(senderWc == 0) throw 121;
                var (nominator: slice?, authorized: bool ) = nominators.uDictGet(ADDR_SIZE(), senderAddr);
                assert(authorized) throw 122;
                var (amount: int, pendingDepositAmount: int) = unpackNominator(nominator!);
                assert(amount > 0) throw 123;
            }

            var proposalHash: int = inMsgBody.loadTextHexNumber(32);
            inMsgBody.assertEndOfSlice();
            var support: bool = action == 121;

            var (votesSlice: slice?, found: bool) = configProposalVotings.uDictGet(256, proposalHash);

            if (! found) {
                // require higher fee to prevent dictionary spam
                var fee: int = ONE_TON();
                var power: int = getCellDepth(configProposalVotings);
                repeat (power) {
                    fee = mulDivFloor(fee, 15, 10);
               }
               assert(msgValue >= fee) throw 123;
            }

            var (votesDict: cell?, votesCreateTime: int) = found ? (votesSlice!.loadDict(), votesSlice!.loadUint(32)) : (createEmptyDict(), now());

            var (_, voteFound: bool) = votesDict.uDictGet(256, senderAddr);
            assert(!(voteFound)) throw 124;
            votesDict.uDictSetBuilder(256, senderAddr, beginCell().storeBool(support).storeUint(now(), 32));

            var newVotes: builder = beginCell().storeDict(votesDict).storeUint(votesCreateTime, 32);
            configProposalVotings.uDictSetBuilder(256, proposalHash, newVotes);

            if (found) {
                sendExcesses(senderAddress);
            }
        }

    } else {

        var queryId: int = inMsgBody.loadUint(64);

        if (isElectorAddress(senderWc, senderAddr)) { // response from elector

            acceptExternalMessage();

            if (op == `op::recover_stake_ok`()) {
                state = 0;

                var reward: int = msgValue - stakeAmountSent;
                var nominatorsReward: int = 0;

                if (reward <= 0) {
                    validatorAmount += reward;
                    if (validatorAmount < 0) {
                        // even this should never happen
                        nominatorsReward = validatorAmount;
                        validatorAmount = 0;
                    }
                } else {
                    var validatorReward: int = (reward * validatorRewardShare) / 10000;
                    if (validatorReward > reward) { // Theoretical invalid case if validator_reward_share > 10000
                        validatorReward = reward;
                    }
                    validatorAmount += validatorReward;
                    nominatorsReward = reward - validatorReward;
                }

                nominators = distributeShare(nominatorsReward, nominators); // call even if there was no reward to process deposit requests
                stakeAmountSent = 0;
            }

            if (state == 1) {
                if (op == `op::new_stake_error`()) { // error when new_stake; stake returned
                    state = 0;
                }

                if (op == `op::new_stake_ok`()) {
                    state = 2;
                }
            }

            // else just accept coins from elector

        } else {

            // throw on any unexpected request so that the coins is bounced back to the sender in case of a typo
            assert(((op >= 1) & (op <= 7)) | (op == `op::recover_stake`()) | (op == `op::new_stake`())) throw 70;

            if (op == 1) {
                // just accept coins
            }

            if (op == 2) { // process withdraw requests (at any time while the balance is enough)
                var limit: int = inMsgBody.loadUint(8);

                var (newNm: cell? , newWr: cell?, newCount: int, newBalance: int) = processWithdrawRequests(nominators, withdrawRequests, balance, nominatorsCount, limit);

                nominators       = newNm;
                withdrawRequests = newWr;
                nominatorsCount  = newCount;

                if (newBalance - msgValue >= MIN_TONS_FOR_STORAGE()) {
                    sendExcesses(senderAddress);
                }
            }

            if (op == 3) { // emergency process withdraw request  (at any time if the balance is enough)
                var requestAddress: int = inMsgBody.loadUint(ADDR_SIZE());
                var (withdrawRequest: slice?, found: bool) = withdrawRequests.uDictGet(ADDR_SIZE(), requestAddress);
                assert(found) throw 71;
                var (nominators: cell? , withdrawRequests: cell? , newBalance: int, newNmCount: int) = withdrawNominator(requestAddress, nominators, withdrawRequests, balance, nominatorsCount);
                nominatorsCount = newNmCount;

                if (newBalance - msgValue >= MIN_TONS_FOR_STORAGE()) {
                    sendExcesses(senderAddress);
                }
            }

            if (op == 6) { // update current valudator set hash (anyone can invoke)
                assert(validatorSetChangesCount < 3) throw 113;
                var (utimeSince: int, utimeUntil: int, vset: cell) = getCurrentValidatorSet();
                var currentHash: int = cellHash(vset);
                if (savedValidatorSetHash != currentHash) {
                    savedValidatorSetHash = currentHash;
                    validatorSetChangesCount += 1;
                    validatorSetChangeTime = now();
                }
                sendExcesses(senderAddress);
            }

            if (op == 7) { // clean up outdating votings
                var t: int = now();
                var proposalHash: int = -1;
                do {
                    var (foundProp: int? , votesSlice: slice?, found: bool) = configProposalVotings.uDictGetNext(256, proposalHash);
                    if (found) {
                        proposalHash = foundProp!;
                        var (votesDict: cell?, votesCreateTime: int) = (votesSlice!.loadDict(), votesSlice!.loadUint(32));
                        if (t - votesCreateTime > VOTES_LIFETIME()) {
                            configProposalVotings.uDictDelete(256, proposalHash);
                        }
                    }
                } while (found);

                sendExcesses(senderAddress);
            }

            if (op == `op::recover_stake`()) { // send recover_stake to elector (anyone can send)

                // We need to take all credits from the elector at once,
                // because if we do not take all at once, then it will be processed as a fine by pool.
                // In the elector, credits (`credit_to`) are accrued in three places:
                // 1) return of surplus stake in elections (`try_elect`)
                // 2) reward for complaint when punish (`punish`) - before unfreezing
                // 3) unfreeze round (`unfreeze_without_bonuses`/`unfreeze_with_bonuses`)
                // We need to be guaranteed to wait for unfreezing round and only then send `recover_stake`.
                // So we are waiting for the change of 3 validator sets.

                // ADDITIONAL NOTE:
                // In a special case (if the network was down), the config theoretically can refuse the elector to save a new round after election - https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/smartcont/config-code.fc#L494
                // and the elector will start a new election - https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/smartcont/elector-code.fc#L364
                // in this case, our pool will have to skip the round, but it will be able to recover stake later

                assert(validatorSetChangesCount >= 2) throw 111;
                assert((validatorSetChangesCount > 2) || (now() - validatorSetChangeTime > stakeHeldFor + 60)) throw 112;
                // https://github.com/ton-blockchain/ton/blob/b38d227a469666d83ac535ad2eea80cb49d911b8/crypto/smartcont/elector-code.fc#L887

                var payload: cell = beginCell().storeUint(`op::recover_stake`(), 32).storeUint(queryId, 64).endCell();
                sendMsg(electorAddress(), 0, payload, BOUNCEABLE, SEND_MODE_REMAINING_AMOUNT()); // bounceable,  carry all the remaining value of the inbound message, fee deducted from amount, revert on errors
            }

            // message from validator

            if (op == 4) { // deposit validator (any time)
                assert((senderWc == -1) & (senderAddr == validatorAddress)) throw 73;
                msgValue -= DEPOSIT_PROCESSING_FEE();
                assert(msgValue > 0) throw 74;
                validatorAmount += msgValue;
            }

            if (op == 5) { // withdraw validator (after recover_stake and before new_stake)
                assert(state == 0) throw 74; // no withdraw request because validator software can wait right time
                assert((senderWc == -1) & (senderAddr == validatorAddress)) throw 75;
                var requestAmount: int = inMsgBody.loadCoins();
                assert(requestAmount > 0) throw 78;

                var totalNominatorsAmount: int = calculateTotalNominatorsAmount(nominators);
                // the validator can withdraw everything that does not belong to the nominators
                assert(requestAmount <= balance - MIN_TONS_FOR_STORAGE() - totalNominatorsAmount) throw 76;
                validatorAmount -= requestAmount;
                if (validatorAmount < 0) {
                    validatorAmount = 0;
                }
                sendMsg(makeAddress(-1, validatorAddress), requestAmount, null, NON_BOUNCEABLE, 0); // non-bouneable, fee deducted from amount, revert on errors
                var newBalance: int = balance - requestAmount;
                if (newBalance - msgValue >= MIN_TONS_FOR_STORAGE()) {
                    sendExcesses(senderAddress);
                }
            }

            if (op == `op::new_stake`()) {
                assert((senderWc == -1) & (senderAddr == validatorAddress)) throw 78;

                assert(state == 0) throw 79;

                assert(queryId) throw 80; // query_id must be greater then 0 to receive confirmation message from elector

                assert(msgValue >= ONE_TON()) throw 86; // must be greater then new_stake sending to elector fee

                var value: int = inMsgBody.loadCoins();

                var msg: slice = inMsgBody;

                stakeAt = checkNewStakeMsg(inMsgBody);

                stakeAmountSent = value - ONE_TON();

                assert(value >= MIN_STAKE_TO_SEND()) throw 81;

                assert(value <= balance - MIN_TONS_FOR_STORAGE()) throw 82;

                assert(validatorAmount >= minValidatorStake) throw 83;

                assert(validatorAmount >= maxRecommendedPunishmentForValidatorMisbehaviour(stakeAmountSent)) throw 84;

                assert((withdrawRequests == null)) throw 85; // no withdraw requests

                state = 1;
                var (utimeSince: int, utimeUntil: int, vset: cell) = getCurrentValidatorSet();
                savedValidatorSetHash = cellHash(vset); // current validator set, we will be in next validator set
                validatorSetChangesCount = 0;
                validatorSetChangeTime = utimeSince;
                stakeHeldFor = getValidatorConfig(); // save `stake_held_for` in case the config changes in the process

                sendMsg(electorAddress(), value, beginCell().storeUint(op, 32).storeUint(queryId, 64).storeSlice(msg).endCell(), BOUNCEABLE, SEND_MODE_PAY_FEE_SEPARATELY()); // pay fee separately, rever on errors
            }
        }
    }

    saveData(
        state,
        nominatorsCount,
        stakeAmountSent,
        validatorAmount,
        packConfig(validatorAddress, validatorRewardShare, maxNominatorsCount, minValidatorStake, minNominatorStake),
        nominators,
        withdrawRequests,
        stakeAt,
        savedValidatorSetHash,
        validatorSetChangesCount,
        validatorSetChangeTime,
        stakeHeldFor,
        configProposalVotings
    );
}

// Get methods

get get_pool_data() {
    return loadData();
}

get has_withdraw_requests(): bool {
    var (state: int, nominatorsCount: int, stakeAmountSent: int, validatorAmount: int, (validatorAddress: int, validatorRewardShare: int, maxNominatorsCount: int, minValidatorStake: int, minNominatorStake: int), nominators: cell?, withdrawRequests: cell?, stakeAt: int, savedValidatorSetHash: int, validatorSetChangesCount: int, validatorSetChangeTime: int, stakeHeldFor: int, configProposalVotings: cell?) = loadData();
    return (withdrawRequests != null);
}

get get_nominator_data(nominatorAddress: int): (int, int, bool) {
    var (state: int, nominatorsCount: int, stakeAmountSent: int, validatorAmount: int, (validatorAddress: int, validatorRewardShare: int, maxNominatorsCount: int, minValidatorStake: int, minNominatorStake: int), nominators: cell?, withdrawRequests: cell?, stakeAt: int, savedValidatorSetHash: int, validatorSetChangesCount: int, validatorSetChangeTime: int, stakeHeldFor: int, configProposalVotings: cell?) = loadData();

    var (nominator: slice?, found: bool) = nominators.uDictGet(ADDR_SIZE(), nominatorAddress);
    assert(found) throw 86;
    var (amount: int, pendingDepositAmount: int) = unpackNominator(nominator!);
    var (withdrawRequest: slice?, withdrawFound: bool) = withdrawRequests.uDictGet(ADDR_SIZE(), nominatorAddress);

    return (amount, pendingDepositAmount, withdrawFound);
}

get get_max_punishment(stake: int): int {
    return maxRecommendedPunishmentForValidatorMisbehaviour(stake);
}

get list_nominators(): tuple? {
    var (state: int, nominatorsCount: int, stakeAmountSent: int, validatorAmount: int, (validatorAddress: int, validatorRewardShare: int, maxNominatorsCount: int, minValidatorStake: int, minNominatorStake: int), nominators: cell?, withdrawRequests: cell?, stakeAt: int, savedValidatorSetHash: int, validatorSetChangesCount: int, validatorSetChangeTime: int, stakeHeldFor: int, configProposalVotings: cell?) = loadData();
    var list: tuple? = null;
    var address: int = -1;
    do {
        var (foundAddress: int? , nominator: slice?, found: bool) = nominators.uDictGetNext(ADDR_SIZE(), address);
        if (found) {
            address = foundAddress!;
            var (amount: int, pendingDepositAmount: int) = unpackNominator(nominator!);
            var (_, withdrawRequested: bool) = withdrawRequests.uDictGet(ADDR_SIZE(), address!);
            list = listPrepend([address, amount, pendingDepositAmount, withdrawRequested], list);
        }
    } while (found);
    return list;
}

get list_votes(): tuple? {
    var (state: int, nominatorsCount: int, stakeAmountSent: int, validatorAmount: int, (validatorAddress: int, validatorRewardShare: int, maxNominatorsCount: int, minValidatorStake: int, minNominatorStake: int), nominators: cell?, withdrawRequests: cell?, stakeAt: int, savedValidatorSetHash: int, validatorSetChangesCount: int, validatorSetChangeTime: int, stakeHeldFor: int, configProposalVotings: cell?) = loadData();
    var list: tuple? = null;
    var proposalHash: int = -1;
    do {
        var (foundProposalHash: int? , votesSlice: slice?, found: bool) = configProposalVotings.uDictGetNext(256, proposalHash);
        if (found) {
            proposalHash = foundProposalHash!;
            var (votesDict: cell?, votesCreateTime: int) = (votesSlice!.loadDict(), votesSlice!.loadUint(32));
            list = listPrepend([proposalHash, votesCreateTime], list);
        }
    } while (found);
    return list;
}

get list_voters(proposalHash: int): tuple? {
    var (state: int, nominatorsCount: int, stakeAmountSent: int, validatorAmount: int, (validatorAddress: int, validatorRewardShare: int, maxNominatorsCount: int, minValidatorStake: int, minNominatorStake: int), nominators: cell?, withdrawRequests: cell?, stakeAt: int, savedValidatorSetHash: int, validatorSetChangesCount: int, validatorSetChangeTime: int, stakeHeldFor: int, configProposalVotings: cell?) = loadData();
    var list: tuple? = null;
    var (votesSlice: slice?, found: bool) = configProposalVotings.uDictGet(256, proposalHash);
    assert(found) throw 133;
    var votesDict: cell? = votesSlice!.loadDict();

    var address: int = -1;
    do {
        var (foundAddress:int?, cs: slice?, found: bool) = votesDict.uDictGetNext(ADDR_SIZE(), address);
        if (found) {
            address = foundAddress!;
            var (support: int, voteTime: int) = (cs!.loadInt(1), cs!.loadUint(32));
            list = listPrepend([address, support, voteTime], list);
        }
    } while (found);
    return list;
}
