# Private USD on Android: reference

Reference material for `docs/private-usd-android-plan.md`, numbered as the plan points to it:

- §5 protocol and state machines
- §6 the Railgun host
- §7 pinned config
- §8 veylor integration
- §9 UI and copy
- §12 the source map

Open a section only when a milestone's **Inputs** names it. Line numbers into veylor are at `main` `4a859bee0`, and into zapp at `release/4.7.0`; confirm one before relying on it. The plan's §1 decisions win over anything here.

## 5. Protocol reference

The Kotlin driver in `of/` is the source of truth. Where `zc/` (the Rust reference client) differs, this section says so. `za/docs/android-reverse-swap.md` is partly stale: it says reverse is testnet-only and names the stores `_v2`/`_v1`. The code supports mainnet too, and uses `_v3` stores (`ua/AtomicSwapDeployment.kt:44-49`, `ua/AtomicSwapStoreImpl.kt:98`, `ua/ReverseSwapStoreImpl.kt:36`). The public docs are `zs/docs/{reverse-flow.md, railgun-sends.md, tokens.md, deployment.md}`.

### 5.1 Overview

**The joint key.** ZEC moves through an Ironwood "joint" address whose spend-authorizing scalar `ask` is split.

- The maker holds the share `e`. The user holds `z`, derived from the seed per swap index (§3.3). The public shares are `E = [e]·SpendAuthG` and `Z = [z]·SpendAuthG` (`zcore/share.rs:36-38`).
- No `SpendingKey` `sk` exists for the joint account. `ak = ±(E+Z)`, negated to an even `y`. The joint FVK is `FullViewingKey::from_bytes(ak ‖ nk ‖ rivk)` (`zcore/joint.rs:66-84`), where `nk‖rivk` are the user's per-swap viewing keys. They are sent to the maker on accept, so both parties can view the deposit.
- The joint UFVK is Orchard-only, and the joint UA has one Orchard receiver (`joint.rs:91-110`).
- `spend_key` computes `±(e+z)` and checks `[ask]·G == ak` (`joint.rs:113-121`). The signer randomizes the key by each spend's `alpha`, matches it to `rk`, signs the PCZT's shielded sighash with raw RedPallas, and applies the signature with `Signer::apply_orchard_spend_auth_signature(SpendAuthSignature::from_parts(pool, index, sig))`, which checks it against `rk` (`zcore/signer.rs:3-5, 38-52, 57-93`).
- **It is an Ironwood spend.** Under NU6.3, Orchard-pool bundles must set `enableCrossAddress = 0`; only Ironwood allows cross-address transfers (`zo/src/lib.rs:205-211`). So the deposit into the joint address and the sweep or refund out of it both happen in the Ironwood bundle. Ironwood has no receiver or FVK of its own: the Orchard receiver and FVK serve both pools. NU6.3 activates at 3,428,143 on mainnet and 4,134,000 on testnet (branch id `0x37a5_165b`).
- The circuit does not care where `ak` comes from. It witnesses `ak_P` and constrains `rk = ak_P + [alpha]·SpendAuthG` and `ivk = CommitIvk(ak, nk)` (`zo/src/circuit.rs:671-676, 795-807, 813-820`). The extractor verifies the proof and every signature (`wl/.../pczt/src/roles/tx_extractor/mod.rs:125-137`).
- **This was proven on veylor's stack.** `zecswap-core` (d69e3fb) was built against `zakura-orchard =2.0.0`, `zakura-pczt =0.1.0-rc5` (patched to `wl@391d0b02`), `zakura-address`, `zakura-protocol`, `zakura-pasta-curves =2.0.0` and `zcash_note_encryption 0.4.2`. All 16 library tests and all 8 `tests/sweep.rs` tests pass. That covers a real Ironwood note to the joint address, a Builder PCZT, a Halo 2 `PostNu6_3` proof, a combined-key signature, full extractor verification, and the full and compact signer views.

**The Ethereum side.** An Ethereum contract (`ZecSwap.sol`) pays out USDC against whichever half is revealed.

- The USDC is shielded into the user's own Railgun `0zk` wallet as a pre-agreed note (the "payout note").
- The user has no Ethereum account and no gas. A relayer sends every Ethereum transaction on the user's EIP-712 signatures, made with the per-swap auth key.
- `Terms` is 11 words: `maker, token, amount (u128), makerKey (x, y), userKey (x, y), user, t0 (u64), t1 (u64), payoutNote (bytes32)`. The contract stores only the terms hash, and every call passes the terms.
- `getSwap` returns `termsHash, stage (0 None / 1 Open / 2 Ready / 3 Claimed / 4 Refunded), paidOut, secret`. When the maker refunds a forward swap, or claims a reverse one, it reveals `e` in `secret`.
- **Windows, not locks.** Veylor settles on zecSwap's windows contract: at every moment one side at most may reveal its share, by the clock (`t0`, `t1` and the contract's `LATE_WINDOW`) and the swap's stage (§5.4). A reveal mined outside its window reverts with the share public. The lock contract zapp follows (claim and refund locks, `LOCK_DURATION`, six-word swap records) is retired here, and the steps below that once took a lock now judge a window (zecSwap's `docs/local/windows/audit3/PORT-SPEC.md`).
- A `WrongStage` right after a deadline usually means a lagging node, so retry it.

**Directions.**

- **Forward (ZEC → USD):** the maker escrows USDC, the user deposits ZEC, and the user claims the USDC by revealing `z`.
- **Reverse (USD → ZEC):** the roles are swapped on chain. The user funds the escrow with USDC, and the maker deposits ZEC. After the user's `Ready` signature, the maker claims the USDC by revealing `e`, and the user sweeps the ZEC home with `±(e+z)`. The escrow id is `reverseSwapId = keccak256(abi.encode(userAuthAddress, makerShare, true))`, never a forward id.

**Spam tokens.** Every accept needs one Privacy Pass token (RFC 9577 challenge, RFC 9578 blind RSA): one token per swap, and three walk-aways per device per day. The issuer signs only devices whose Android Keystore attestation verifies (§5.9).

### 5.2 Wire format and maker endpoints

**Encoding** (`zapi/lib.rs`, `of/SwapWire.kt`, `of/SwapTypes.kt`). JSON is camelCase.

| Field kind | Encoding |
|---|---|
| Addresses | `0x` hex. zapp writes them lowercase. |
| Ids, note commitments | `0x` + 64 hex, lowercase |
| Shares, proofs, `viewingKeys` | `0x` + 128 hex (64 bytes) |
| Signatures | `0x` + 130 hex (65 bytes `r‖s‖v`, `v ∈ {27,28}`, low `s`; `zcore/auth.rs:152-163`) |
| Token amounts (`amount`, `fee`, `networkCost`) | **decimal strings** of base units (u128) |
| `chainId`, `depositZat`, `expiresAt`, `t0`, `t1`, `deadline` | JSON numbers |
| `units` in a quote request | a `u32` number (`of/SwapClients.kt:202-209`; above `u32` is `AMOUNT_UNQUOTABLE`) |

- **Unknown fields.** Decode responses with unknown fields ignored (`of/SwapClients.kt:439-443`). Requests use the exact fields, because the server sets `deny_unknown_fields`.
- **Errors.** Every non-2xx body is `{code, error}` (`zapi/service.rs:6-27`). The codes are:
  - `invalidRequest`, `rejected`, `unknownQuote`, `unknownSwap`
  - `unavailable`, `watchtowerUnavailable`, `internal`
  - `notFound`, `methodNotAllowed`
  - `tokenRequired`, `alreadySpent`

  Branch on `code` and the HTTP status, never on `error` text. A `409 alreadySpent` may add `transactions: [hash]`.
- **Ticket.** The accept returns `ticket`, which goes in the `ZecSwap-Ticket` header on every relayer POST for that swap. It is never logged. zapp keeps it only if it starts with `"<swapId>."` and is printable ASCII (`of/SwapWire.kt:198-199`).
- **Timeouts and retries.**
  - Reads (`GET /v1/info`, `GET /v1/terms`, `GET /v1/swaps/{id}`) and the quote POSTs use 20 s (`of/SwapClients.kt:304-308, 370-374, 438`).
  - Accept and relayer POSTs get the client's 180 s.
  - The client never retries at the HTTP level: a quote is single-use, and an accept or relayer request that timed out may have landed (`ProviderModule.kt:557-558`).
  - `zc/api.rs:374-394` resends while the answer is `503` with `Retry-After ≤ 30 s`, up to 90 s in total. That is safe because the gateway answers before the service sees the request. veylor may add it.
- **Refused versus unknown.** A 4xx (`AtomicSwapHttpException.Refused`) sent nothing. A transport failure (`Unreachable`) or a 5xx may have sent something (`zc/api.rs:35-37`).

**Maker endpoints** (`of/SwapClients.kt:135-210`):

| Call | Body | 200 answer |
|---|---|---|
| `GET /v1/info` | — | `{apiVersion:1, maker, chainId, contract, token, zcashNetwork:"mainnet"\|"testnet", reverseEnabled, tokenReturnKey?, contractKind?, minWindow?, lateWindow?}`. Windows the info names must be the pinned ones, and a kind must be `windows` (`WrongDeployment`); all three are optional because mainnet's lock-contract services name none. |
| `POST /v1/quote` | `{units, payout: authAddress, payoutNote}` | `{quoteId, maker, makerShare, makerProof, chainId, contract, token, amount, depositZat, expiresAt, networkCost?}` |
| `POST /v1/quote/{quoteId}/accept` | `{userShare, userProof, viewingKeys, tokenRequest?}`, plus `Authorization: PrivateToken token=…` on a paid retry | `{swapId, t0, t1, ticket, lateWindow?}`; a `lateWindow` other than the pinned one is another contract's (`NothingSent(MISMATCH)`, nothing paid) |
| `GET /v1/swaps/{swapId}` | — | `{swapId, tokenReturn?}` (read only to collect the token) |
| `POST /v1/reverse/quote` | `{units, user: authAddress, refundNote}` | `{terms: <Quote>, user, refundNote, fundingDeadline, readyDeadline, refundAfter}` |
| `POST /v1/reverse/quote/{quoteId}/accept` | as forward | `{swapId, t0, t1, ticket, lateWindow?}`; another `lateWindow` cancels the conversion, nothing paid |
| `GET /v1/reverse/swaps/{swapId}` | — | `{swapId, phase, depositTxid?, readyDeadline, refundAfter, tokenReturn?}` (advisory only) |

- **`/v1/info` checks** (`of/SwapChecks.kt:9-28`): it must equal the pin in `apiVersion`, `maker`, `chainId`, `contract`, `token` and `zcashNetwork`, and a `contractKind`, `minWindow` or `lateWindow` it names must be the pinned contract's, as in the relayer's terms (§5.3; else `WrongDeployment`). Reverse also needs `reverseEnabled`. A `tokenReturnKey` that differs from the pinned return key is refused (`TOKENS_REFUSED`). Check once per driver.
- **Quote well-formedness** (`of/SwapWire.kt:247-253`, `of/ReverseSwapModels.kt:228-234`):
  - `quoteId` is 32 bytes and `makerProof` 64 bytes
  - `amount` is in 1..2^120
  - `depositZat` is in 1..2.1e15
  - `expiresAt > 0`
  - for reverse: `0 < fundingDeadline < readyDeadline < refundAfter` and `refundAfter − fundingDeadline ≤ 24 h`

### 5.3 Relayer endpoints

**Relayer endpoints** (`of/SwapClients.kt:213-288`, `zapi/relayer.rs`). Every POST carries `terms` (`zapi/lib.rs:110-125`): `{maker, token, amount, makerKey, userKey, user, t0, t1, payoutNote}`. Each answers `{transactions: [txHash]}`.

| Path | Body |
|---|---|
| `GET /v1/terms` | answer: `{relayer, chainId, contract, minWindow?, lateWindow?, contractKind?, fee, feeExpiresAt?, reverseFunding?, railgunSends?}`. `reverseFunding` is `{relayAdapt, token, maker, maxGasLimit, maxGasPriceWei, maxCalldataBytes, fee}`. Windows the terms name must be the pinned ones, and a kind must be `windows` (`WrongDeployment`); all three are optional because mainnet's lock-contract services name none. |
| `/v1/claim` | `{swapId, terms, secret: z (32 B big-endian), payout: <Payout>}` → 2 transactions (claim, then payout) |
| `/v1/claim/hold` | the body of `/v1/claim` → `{held: true}`; a claimed swap is answered as `/v1/claim` answers it |
| `/v1/payout` | `{swapId, terms, note: {npk, encryptedBundle:[3×bytes32], shieldKey}, fee, signature}` |
| `/v1/reverse/fund` | `{swapId, chainId, to: relayAdapt, data, value:"0"}` → 0 or 1 transaction. An empty list means a matching escrow already exists. |
| `/v1/reverse/ready` | `{swapId, terms, deadline, signature}` |
| `/v1/reverse/refund` | `{swapId, terms, secret: z, payout}` |
| `/v1/reverse/refund-payout` | `<Payout>` |
| `/v1/reverse/rescue` | `{swapId, terms, note, fee, nonce, deadline, signature}` |

- **`/v1/claim/hold`** (relayer claims, plan D9) keeps the claim and sends it, with its payout at the fee accepted when held, as soon as the claim's window opens: once the ready is 2 blocks deep before `t0`, from `t0`, or from `t1 + LATE_WINDOW` if the maker did not refund. It deletes the claim once the swap is claimed or refunded. Holding the same claim again changes nothing, and a new valid payout replaces the held one. A refusal holds nothing (`400 rejected`: a refunded swap, a bad payout, or a fee it does not honour); a relayer without the endpoint answers `404`.
- **The windows contract's relayer** has no `/v1/lock-claim` or `/v1/reverse/lock-refund`. A `400 rejected` is final and sent nothing (a claim between `t1` and `t1 + LATE_WINDOW`, or under the margin before `t1`; a `ready` after the relayer sent a refund). A `503` with `Retry-After` asks for the same post again: the relayer holds a claim on a ready not yet 2 blocks deep before `t0`, and a reverse refund while a `ready` it sent may still land.

### 5.4 Contract reads (Ethereum JSON-RPC, `of/AtomicSwapChain.kt`)

- **RPC.** Use the keyed URL if set, else publicnode (`ui/common/privateusd/PrivateUsdTokens.kt:59-65`). zapp does not fall back from the keyed URL to publicnode here.
- **Every confirmed read** first checks `eth_chainId == deployment.chainId` (`:198-202`). It reads `eth_getBlockByNumber("latest")` for `{number, timestamp}`. Calls then use the block tag `head − confirmations + 1`, with the escrow confirmations (mainnet 3, testnet 2; `:204-209`).
- **`getSwap(bytes32)`** (selector `0x3da0e66e`, `zl/android.md` §6). On the windows contract the answer must be exactly 4 words (128 bytes), or `WRONG_DEPLOYMENT` (the lock contract's six-word records, which also carried `claimLockUntil` and `refundLockUntil`, are refused):
  - `termsHash`
  - `stage` (0 None → no swap; 1 Open, 2 Ready, 3 Claimed, 4 Refunded)
  - `paidOut`
  - `secret`

  A `termsHash` that differs from `keccak256(abi.encode(terms))` is `MISMATCH` (`of/AtomicSwapModels.kt:51-54`). The terms are 11 words: `maker, token, amount, makerKey.x, makerKey.y, userKey.x, userKey.y, user, t0, t1, payoutNote` (`of/SwapTerms.kt:34-44`).
- **Contract identity.** Before any swap read is trusted, the pinned contract must answer `MIN_WINDOW()` and `LATE_WINDOW()` with the pinned windows and revert `LOCK_DURATION()`, which only the lock contract answers (`WRONG_DEPLOYMENT`). Checked once.
- **`swap(id)`, `confirmedSwap(id)` and `read_swap(id)`.** `swap(id)` reads `latest`, unconfirmed. It is used only for index skipping and "did it ever open". `confirmedSwap(id, terms)` reads the confirmed block and is the only read that authorizes a deposit or completion (`of/AtomicSwapSeams.kt:122-134`). A reveal is decided on `read_swap(id, terms)`, one consistent read: the newest block's number, time and hash, then `getSwap` pinned to that hash (read again while the node does not know it; never `latest` twice, as load-balanced nodes answer a block apart). `swap_at(id, terms, n)` reads block `n`, for a ready's depth.
- **Other reads:**
  - `MIN_WINDOW()` and `LATE_WINDOW()`: read once, since they are immutable.
  - `makerKeyUsed(bytes32)`, called with `keccak(abi.encode(authAddress, share))`.
  - `reverseFunding(bytes32)` → `(refundNote bytes32, fundingBlock uint)`.
  - `vaultOf(bytes32)`, then ERC20 `balanceOf(vault)`.
  - `rescueNonces(bytes32)`.
  - On the Railgun proxy, `tokenBlocklist(address)`: `0` means it accepts, and **any revert means paused, so closed** (`:44-51`).
- **Selectors** (Keccak-256, computed 2026-10-13, the windows' on 2026-10-20; `getSwap`, `LOCK_DURATION` and `hashTerms` match `zl/android.md` §6). Each argument is one 32-byte word; addresses are left-padded.

  | Call | Selector | Answer |
  |---|---|---|
  | `getSwap(bytes32)` | `0x3da0e66e` | 4 words |
  | `MIN_WINDOW()` | `0x52b65c4b` | uint256 |
  | `LATE_WINDOW()` | `0x4d9fef3e` | uint256 |
  | `LOCK_DURATION()` | `0x485d3834` | must revert: only the lock contract answers it |
  | `makerKeyUsed(bytes32)` | `0xdc1c5a08` | bool word |
  | `reverseFunding(bytes32)` | `0x4aee90e2` | `(bytes32 refundNote, uint64 block)`; `refundNote == 0` means none |
  | `vaultOf(bytes32)` | `0x0177928f` | address word |
  | `rescueNonces(bytes32)` | `0xeb106361` | uint64 word |
  | `tokenBlocklist(address)` on the Railgun proxy | `0x815b534f` | `0` = accepts; any revert = closed |
  | ERC-20 `balanceOf(address)` | `0x70a08231` | uint256 |
  | `hashTerms((address,address,uint128,uint256[2],uint256[2],address,uint64,uint64,bytes32))` | `0x2f25f5c9` | test only: checks your terms encoding against the chain |
  | event `PaidOut(bytes32,address,uint256)` topic0 | `0xf4292e0ae547c949263a88899ebcdac1a5493bef4f206b7592b5a7de68f4c0de` | |

- **Payout event.** `PaidOut(bytes32 indexed id, address relayer, uint256 fee)`, with topics `[keccak(sig), id]` and data `relayer, fee` (`:65-99`).
  - Walk backwards from the confirmed head in 5,000-block windows, to `head − (now − acceptedAt)/12 − 5000`.
  - Skip `removed` logs and check the address and topics.
- **`caughtUp`.** Poll `confirmedSwap` every 2 s, 30 times (`zc/` uses 60 s), until a predicate holds; otherwise `CHAIN_LAGGING` (`of/AtomicSwapDriver.kt:494-504, 517-518`).
- **`freshHead`.** Refuse a reveal decision, or a `ready` signature, when the head's timestamp trails the device clock by more than 180 s (`CHAIN_LAGGING`).
- **The windows contract's rules** (zecSwap's `docs/local/windows/prototype/src/ZecSwap.sol`). At every moment one side at most may reveal:
  - Forward: the maker may refund (call the swap off) an `Open` swap until `t0`, unless it made it ready; the user may claim once it is `Ready`, or from `t0`, until `t1`; from `t1` only the maker may refund, for `LATE_WINDOW`; from `t1 + LATE_WINDOW` the user may claim again.
  - Reverse: the maker may claim a `Ready` escrow until `t1`; the user may refund an `Open` escrow, and a `Ready` one from `t1`. `ready` lands only before `t0`.
  - `openReverse` refuses an escrow that leaves less than `MIN_WINDOW` before `t0`, or between `t0` and `t1`.
- **When Veylor reveals** (`swap::claim_window`, `swap::may_sign_ready`, `swap::may_refund`; held to the vectors of zecSwap's port oracle, `rust/src/wallet/private_usd/tests/windows_vectors.json`). Each is judged on one consistent read of a fresh head, and again immediately before the post. A window has opened once the block's time is at or past its start; how much is left counts from the later of the block's time and the device clock (either can only make a reveal go earlier, and the margin covers a device clock behind).
  - Forward claim: on a `Ready` swap 2 blocks deep before `t0` (`swap_at(head − 2)` still `Ready`; the relayer answers `503` meanwhile), or from `t0` on an `Open` or `Ready` one, while `max(head, device) + 300 s < t1`. Under that margin, and from `t1` until `t1 + LATE_WINDOW`, the swap unwinds (`UNWINDING`): its ZEC comes back after the maker's refund. From `t1 + LATE_WINDOW` the claim goes for good.
  - A claim handed to the relayer (relayer claims, §5.6 step 7) is the relayer's to send as the window opens. Veylor posts it itself only once the window was open on the same read taken a minute back too: the head five blocks lower (12 s slots) and both clocks 60 s earlier (`WindowView::before_relayer_wait`), with the ready's depth read below that head. Until then the step waits as the window stood a minute ago (`CONFIRMING`, or `UNWINDING` in the minute after `t1 + LATE_WINDOW`).
  - Reverse `ready`: only on an `Open` escrow with the maker's deposit confirmed, no refund of ours ever posted, and its deadline (`head + 120 s`) before `t0`.
  - Reverse refund: a `Ready` escrow from `t1`; an `Open` one once the chain is past every `ready` deadline signed, or at `t0`.
  - Never `eth_call` or `eth_estimateGas` a claim or refund: the simulation would show the node the share. Reveals go through the relayer, which on mainnet sends them through Flashbots Protect.

### 5.5 EIP-712 (`zcore/auth.rs`)

- **Domain.** `EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)`, with `name = "ZecSwap"`, `version = "1"` and the deployment's chain and contract.
- **Digest.** `keccak(0x1901 ‖ domainSeparator ‖ keccak(typeHash ‖ fields))`. Each field is a 32-byte word, right-aligned for integers and addresses.
- **Types** (all signed by the per-swap auth key):

| Type | Used by |
|---|---|
| `Payout(bytes32 id,address relayer,uint128 fee)` | forward `/v1/claim` and `/v1/payout` |
| `OpenReverse(address maker,address user,address token,uint128 amount,bytes32 makerKey,bytes32 userKey,uint64 t0,uint64 t1,bytes32 refundNote,uint64 deadline)`, where `makerKey`/`userKey` are `keccak` of the 64-byte shares | reverse funding (`openReverse` calldata) |
| `Ready(bytes32 id,uint64 deadline)` | `/v1/reverse/ready` |
| `RefundPayout(bytes32 id,address relayer,uint128 fee)` | `/v1/reverse/refund` and `/v1/reverse/refund-payout` |
| `Rescue(bytes32 id,bytes32 note,address relayer,uint128 fee,uint64 nonce,uint64 deadline)` | `/v1/reverse/rescue` |

The lock contract's `LockClaim` and `LockRefund` are gone with it.

- **Deadline.** Every `ready` or rescue deadline is `chainHead.timestamp + 120` (`SIGNATURE_TTL_SECONDS`); a `ready`'s must fall before `t0`.
- **Ids are not in `zecswap-core`.** `swap_id` and `reverse_swap_id` live in `zecswap-chain` (`zs/crates/zecswap-chain/src/evm.rs:293-308`), which veylor does not depend on (D3). Write them in `terms.rs` with `sha3::Keccak256`:
  - `swap_id(maker, Z) = keccak(pad32(maker) ‖ Z.to_affine_bytes())` (96 bytes)
  - `reverse_swap_id(user, E) = keccak(pad32(user) ‖ E.to_affine_bytes() ‖ word(1))` (128 bytes)
  - the `makerKeyUsed` key = `swap_id(authAddress, Z)`, the same 96-byte preimage with the auth address as owner (`of/AtomicSwapChain.kt:59-63`, `SwapId.of(owner, share)`)
- **Signing.** `UserSwapKeys.auth.sign(&digest) -> [u8; 65]` (`r‖s‖v`, low `s`, `v ∈ {27,28}`). The digests are `zecswap_core::Domain { chain_id, contract }.{payout, open_reverse, ready, refund_payout, rescue}` (`zcore/auth.rs`), with the windows contract as `contract`.

**Known-answer vectors.** Output of `cargo run -p zecswap-client --example vectors` at `zs` `d69e3fb` (run 2026-10-13). Pin them in `rust/src/wallet/private_usd/tests/vectors.json`; do not regenerate. Inputs: `seed` = 64 × `0x07`, `NetworkType::Test`, account 0, index 0; maker share = `derive_maker_share(root = 32 × 0x09, nonce 0)`; maker `0x09eD1F966745Be18C711C346242c0974DAd7c3e5`; domain chain `11155111`, contract `0x1111…1111` (20 × `0x11`); relayer `0x2222…2222`; token `0x3333…3333`; payee `0x4444…4444`; `deadline` 1790000000; `fee` 20000.

```text
userShare    0x0b42629d5b3f787aba7ccde87574c13f6db6b8fccb7c5cfeb3f4e4081c756461311662156525fcaa692aeef5d2362c2a9ab2083cd6d968c618aec72617aa925a
userSecret   0x01bfb1d4b12d5365d9bc7aa9e7e7f641bdb7cce5c647b29c7077f344111ba6ac
viewingKeys  0x97afa7272114ce3634144ee0883379f1a01695bbb56f64f99181ddf44369d125c3e134a0b68e43ce055281af3bf7e30850857d77995986765a72dde442b8802f
authAddress  0x757de38c2d9880e44ab59827d1622403fbf88ff5
swapId       0x297f1ca9d44ff7136dbddb0720ecadc040229e22c03ad0f9e4c648212bfc7b66
makerShare   0x187d300ebb59a5c9e7c9e61debd0b535a8a5cbbad4a5c46ac2a0597a06c13ee4329a369cf900745cdca87863f3f00de64d16e088bb1f5da341a2977547f9080a
joint UA (Test)    utest1exuj2qh9gcll0zjygvk7c48e5ra40wwtvdgd2u0ygwn2g3kanp47utpgh25m4pqwcjqsqy55zyr7qncw0ct0gpeccytje6tgeyaheah7
joint UFVK (Test)  uviewtest130mkztp6gdvnvn0k3y3h820wjn9unqj2lzkt400lgw4velrg6dsy8m4lp3jn22hyupdk4e5z4dch99rrxcme7s2cm8r7805t64r7d7tma2xg0pn93vpu4luedpcrrj4k9jz6kx374g0738x70vu8l0ueh6nzu33aned77x7rwqyd3cxqndnpvyg4ffr8c
joint UA (Main)    u1fqg38q80j2cmvmxlgy49v6fygqdnj88tsmgrxzga6lawz0yz8rsew26sc5er5lf3d0sn79gyyan0kleskq5qkw8ufpk3j2sc3geywz6m
  (JointAccount::derive(E, Z, viewing); identical on the Zakura build, checked 2026-10-13; spend_key(e, z) succeeds)
Railgun wallet 0 of the seed itself (Keys::from_seed(64 × 0x07, 0)), note from keys.note_entropy
  0zk        0zk1qyt5x0c632363rrmd8psxws6n9tscm8gps277gzc0w3s5cg4mdpe9rv7j6fe3z53luahk4ksjwagt68fl2vguye054rxjyqzvhs9usq4rwrk09al6n0677pdrgn
  npk        0x11eb0b931cc092fe6876f395a4f8d29cf5c97c43903605253386e008ab4881e3
  bundle     0xe9f4508256863b2559259a39333a65685dfd7a7c86fa101e959517e06aa798c6, 0x63835c785858b4cf0519698cc24ee8d84fb3f943d073895b3e2521517419ee97, 0x82981c9149e1977d0ca708cd313450306e87b35a41dc832ec419686055b02e9a
  shieldKey  0x02356776cb176876b31960b8ccbf0c0850a76e9a2ef49caa6631bca732d064b2
  payoutNote 0x14d061e0bf2b24d75b75adb91c04cc6b82be6b407b5901dbdb86bbbabe7a9acd
Railgun wallet 0 of railgunSeed = 64 × 0x08, same note entropy
  0zk        0zk1qyrs4qyrd08p6uep0fc2y8njktgcpezts3rpaq6q0ln948ecjkw8prv7j6fe3z53llz8ursderja0juwv5pgnv8x5klmmwkv8q38h9n704h4d4qjyw7n5qk68nx
  npk        0x1f80223263733ae7cb3047ae61b64ee8179674dbbd708cac8a7a8b15a222ba35
  bundle     0xe9f4508256863b2559259a39333a65684a26d33e9ac0081841cc96ed3d26c2b2, 0xc47d927ba9163144d7c83e28031820134fb3f943d073895b3e2521517419ee97, 0x7d9d444c12bec55e6b3892ca92fd50c9ba2d7d0783f95545a2f15923f8474c0f
  shieldKey  0x02356776cb176876b31960b8ccbf0c0850a76e9a2ef49caa6631bca732d064b2
  payoutNote 0x5af6901ba7cb01f49785a29c4a2e57e31af3e53382ce3dd2e35678897515ffc1
EIP-712, domain (11155111, 0x1111…1111), signed by authAddress
  LockClaim(swapId, 1790000000)   digest 0xa24b846b1046f910dfb19e121beece3b85f942a20729f60f3b46847d4e2c0b93
                                  sig    0xc2a0a598fc3027f949c2a3f3fadb3e988a74effa69e09efc86d3db0e89904dfc69a81a0cc62da15628ed8084bb31d05723dfc2da4308dfbeb0ef4e134b7497551b
  Payout(swapId, 0x2222…, 20000)  digest 0xd824c10786687b122733cee8301283897ef90ad1fd4024e99a6d641ed0fe53c1
                                  sig    0x883118048774977816784fb0f34f256a8344caaf134201e0acd9f0b5c1f8e6a3685df4aa58f4d1725f49fbaa106cc594ef0ffe4b8569550860a00ce5291bae5b1c
reverseSwapId(authAddress, makerShare) 0x0a5ff70eda9eff985515f84e23bcff13da416fa9ed0500e251e248c8f5ff5436
  ReverseOpen{maker 0x09eD…, user authAddress, token 0x3333…, amount 50000000, E, Z, t0 1790003600, t1 1790007200, refundNote = payoutNote of the 0x07 wallet, deadline 1790000000}
  OpenReverse   sig 0x10a82e61f8b598a82b826c7135c139df3dd9967323eb9d932a39bdbc79161fbf4cf02891f0cf6490c2b28ece250698c272688873eabef70caa633ae3307f144a1c
  Ready         sig 0xaa8ef1a956aaba632406f534bd2d746f4146d6be7bb38c6734afb37e223003b35928dc3f2bc76b884fb7d29eff5a95934a5c920ddd077198f6ba32bd2d70821f1c
  LockRefund    sig 0xd4dedeb359b5db83dee3ed53375a43e5debb2972e4ed38e25db90c2e7953b1a63f442f88f83424a5834b953c503ddcbcd305deb7dd7bd9614c0558e4e23bfa081c
  RefundPayout  sig 0xc3f9c0eeddff6919aa2f5a3d39ddc388d49e110eccf8b83ba3a75249f4358a4b259ff1882196c7cd5166c5ece50166a0af668a0cb2538a8445ef0983629a92241c
  with refundNote = payoutNote of the 0x08 wallet instead:
  OpenReverse   sig 0x546a50d199fc62080dd679e061f87b0eca23231ab5efeefce3f83a2e6479726f4434cc9c3dbf3cc286cc63dcb0062444b1f8f2f0d937ad1b5d11b4d0fd39d3041c
  Rescue(reverseSwapId, note 0x5af6…ffc1, 0x2222…, 20000, nonce 0, deadline 1790000000)
                sig 0x78eec500e909c43573c99fe613e6eb6910df95497ce24614e1203694d222c7595bbb8ef704271ca6fd8f037a03deefc9aa8e4a1a6a779de03b52e93fcff7c35a1b
Terms hashes (amount 150000000, t0 1790003600, t1 1790007200, makerKey E, userKey Z)
  user 0x4444…, payoutNote 0                       0x909f60119225ae64356011c63945694ed0dc6aaaa8cd6002a897df9ab76efc66
  user authAddress, payoutNote 0x5af6…ffc1         0xb7ca9333e9e443218d19c3b8aa345fa67a671ac24060877de1498efb01c99a29
  reverse: ReverseOpen.terms() (maker authAddress, user 0x09eD…, makerKey Z, userKey E, amount 50000000, payoutNote 0)
                                                   0xa295e46f6db15997af4a950b5e6deed6ae5d3161b6571b2f445a34bc6570cead
```

- The signatures are deterministic (RFC 6979), so compare them byte for byte. Share proofs are randomized: test a round trip (`SwapContext::prove_user` then `verify_user`), not a value.
- The `LockClaim` and `LockRefund` lines are the lock contract's, kept as zecSwap printed them; nothing signs either type now.
- zapp pins the same values in `of/../commonTest/.../ZecSwapVectors.kt` (64 lines).
- Deposit notes have vectors of their own, inline in `deposits.rs`'s tests (`deposit_notes_are_the_ones_the_android_wallet_builds`): the seed above's testnet deposit address 0 shielding for an authorization valid before 1790000000, and its vault's first rescue (nonce 0), both into the Railgun wallet of a seed of 64 × `0x08`. zecSwap's `crates/zecswap-jni/tests/deposits.rs` and the Android module's `AtomicSwapTest.depositNotes` pin the same words, so every client that signs for a deposit address builds the note libzecswap would.

### 5.6 Forward (ZEC → USD) state machine

**Record** (`of/AtomicSwapModels.kt:76-107`; stored flat by `AtomicSwapRecordSerializer` `:209-292`):

| Field | Type | Notes |
|---|---|---|
| `index` | Int | swap index |
| `quote` | `SwapQuote` | as received |
| `swapId` | hex | `keccak(abi.encode(maker, Z.x, Z.y))` |
| `zcashHeight` | Long | Zcash tip read before accepting; the joint account's birthday |
| `acceptedAt` | Long | device unix seconds |
| `receives` | Usdc6 | expected net; replaced by the event's net at the end |
| `relayerFee`, `feeExpiresAt?` | Usdc6, Long | from `GET /v1/terms` at quote time |
| `maxTotalZat?` | Long | `depositZat + depositFee` the user approved |
| `deposit` | `NotStarted` \| `Started` \| `Kept(ZcashTransaction)` | stored as `depositAttempted: Bool` + `deposit?` |
| `sweep?` | `ZcashTransaction` | `{txId (display hex), raw (hex), expiryHeight}` |
| `payout?` | `SwapPayout` | `{swapId, note, fee, signature}`, signed and kept |
| `relayerClaims` | Bool | the user's choice at accept (Settings, on by default): the claim goes to the relayer once the deposit is out |
| `claimHold?` | `posted` \| `held` \| `declined` | the claim handed to the relayer: kept as `posted` before it is posted; `held` once the relayer holds it; `declined` after a `404` or a refusal |
| `t0?`, `t1?`, `ticket?` | | from the accept answer |
| `end?` | `{outcome, at}` | `Paid` \| `Refunded(sweepTxId, MAKER_CANCELLED\|NOT_CLAIMED_IN_TIME)` \| `NothingSent(QUOTE_EXPIRED\|MAKER_REFUSED\|MAKER_UNAVAILABLE\|NEVER_OPENED\|MISMATCH\|DEPOSIT_WINDOW_MISSED\|MAKER_CANCELLED)` |
| `payoutTx?` | hash | from the `PaidOut` event |

**Steps.** Each `advance` reads the chain first, so it can be rerun at any point.

1. **Quote** (`of/AtomicSwapDriver.kt:40-54`):
   1. Refuse if a forward record is unfinished. The repository also refuses while a reverse swap is under way.
   2. Check `/v1/info` once.
   3. `index = SwapIndices.take()`, which persists `nextIndex+1` **before** returning and skips used indices (§3.3). The index is spent from here, whatever happens next.
   4. `POST /v1/quote {units, payout: authAddress(index), payoutNote: commitment(index)}`.
   5. Require `quote.{chainId, contract, token, maker}` to equal the pin.
   6. `GET /v1/terms`, then `checkedFee`: the relayer is the pinned one and not the maker, on the pinned chain and contract (`of/SwapChecks.kt:31-39`).
   7. `receives = (amount − fee)·(1 − 25/10000)` (`:278-286`).
   8. The UI adds `maxTotalZat = depositZat + feeOfDepositProposal`, and only offers quotes whose deposit fits one transaction (`ua/AtomicSwapZcashInfo.kt`, `ui/screen/privateusd/convert/PrivateUsdZecQuotes.kt:72`).
2. **Accept** (`:57-105`):
   1. Refuse if unfinished, if `fee ≥ amount` (`RELAYER_FEE`), or if `now ≥ expiresAt − 15 s` (`QUOTE_EXPIRED`).
   2. `keys.accept` verifies the maker's share proof and builds `{userShare, userProof, viewingKeys}` (native `accept`, `zs/crates/zecswap-jni/src/ops.rs:164-188`).
   3. **Save the record** with `t0`/`t1` null, `zcashHeight = Zcash tip`, `acceptedAt` and the relayer-claims choice, *before* the share leaves the device.
   4. `POST accept`, with the token loop (§5.9). Then:

   | Outcome | Result |
   |---|---|
   | `4xx` | `NothingSent`; the code maps to `MAKER_REFUSED`, `QUOTE_EXPIRED` or `MAKER_UNAVAILABLE` (`:245-270`). `unknownSwap`/`internal` stay open. |
   | Turned away at the token gate | zapp: `NothingSent(MAKER_UNAVAILABLE)`, then rethrow. veylor: return `TokensNeeded`, issue once, and retry the same acceptance (§5.9); if issuance fails, abandon → `NothingSent(MAKER_UNAVAILABLE)`. Until M4 there is no issuance: Rust returns `TokensNeeded` with no retry, and Dart abandons at once (progress D-33). |
   | Timeout, transport failure or 5xx | throw. The record stays "maybe opened". |
   | 200 | save `t0`, `t1`, `ticket`. If `answer.swapId ≠ record.swapId`: `NothingSent(MISMATCH)`. |
3. **No `t0`/`t1` yet, or not confirmed on chain** (`notOnChain`, `:157-171`): `Waiting(OPENING)` until `quote.expiresAt + 300 s`. If the deposit is still `NotStarted` at that point:
   - `swap(id)` (latest) is empty → `NothingSent(NEVER_OPENED)`
   - otherwise, if the accept was never answered → `NothingSent(MAKER_UNAVAILABLE)`

   zapp does not recover lost `t0`/`t1` from the `Opened` event, although `zl/android.md` §2.1 suggests it.
4. **Confirmed `getSwap`** against the expected terms:
   - The terms are `maker`, `token = pin`, `amount = quote.amount`, `makerKey = quote.makerShare`, `userKey = Z(index)`, `user = authAddress(index)`, `t0`, `t1`, `payoutNote = commitment(index)` (`:300-318`).
   - A `MISMATCH` with the deposit `NotStarted` is `NothingSent(MISMATCH)`; otherwise rethrow.
5. **`OPEN`**, `ensurePaid` (`of/AtomicSwapDeposits.kt:17-44, 96-104`). The deposit address is `depositAccount(index, makerShare from the verified terms).address`, never from the API alone.
   - **Unpayable cause** (no new payment):

   | Condition | Cause |
   |---|---|
   | `t1 − t0` outside `max(MIN_WINDOW, 600 s)` to 2 h, or `t0 > now + 2 h` | `MISMATCH` |
   | `t0 < now + minSecondsToT0` (15 min mainnet, 9 min testnet; default 25 min) | `DEPOSIT_WINDOW_MISSED` |

   A maker that calls the swap off refunds it (`Refunded`, §5.8): zapp's `refundLockUntil ≠ 0 → MAKER_CANCELLED` has no windows counterpart. The `t1 − t0` bound leaves a silent maker's swap a claim from `t0` of at least twice the margin, and caps how long a deposit waits for the maker's refund.

   - **`withFound`.** If the deposit is `Started` with no tx, search the wallet's sent, non-expired transactions for a recipient equal to the deposit address. A hit becomes `Kept`.
   - **`keepSending`** (`of/ZcashTransactions.kt:53-74`):
     1. A kept tx that is `Expired` is dropped.
     2. If there is none and the deposit is payable: `prepareDeposit` proposes `depositZat` to the address and requires exactly 1 transaction and a total ≤ `maxTotalZat` (`DEPOSIT_UNPAYABLE`).
     3. **Save `Started`**, then create (sign and store, no broadcast), then **save `Kept(tx)`**.
     4. If not `Mined`, broadcast the kept bytes. This happens only while the swap is `Open`.
   - **veylor (as built, progress D-35).** Building a new deposit first waits for the main wallet's scan to reach the live lightwalletd tip (`wait = ZcashSyncing`); status reads and resends do not. A deposit that would spend Sapling notes is refused (`DEPOSIT_UNPAYABLE`): Rust cannot fetch the Sapling parameters. Send flow `private-usd-deposit:{account}:{index}`.
   - **Status** (`ua/SwapZcashTransactions.kt:98-138`):

   | Status | Meaning |
   |---|---|
   | `Mined(tip − h + 1)` | mined |
   | `Expired` | absent and the wallet has *fully scanned* past `expiryHeight` |
   | `Unmined` | in history but not mined |
   | `Unknown` | not in history and not provably expired |

   veylor's `swap_tx_status` (M2) counts `Mined` depth from the fully scanned height, and calls a transaction `Expired` only once the fully scanned height is above its expiry height; an expiry of 0 never expires (progress doc D-9).

   - Unpayable and no deposit → `NothingSent(cause)`.
   - `chain.now ≥ t0` → claim (the maker went quiet).
   - Otherwise `Waiting(CONFIRMING, t0, t1)`.
6. **`READY`** → claim. **`CLAIMED`** and not `paidOut` → payout. Then `finishPaid`. A claim the relayer held and sent ends the same way.
7. **Claim** (zapp's `AtomicSwapClaim.claim`, `:330-345`, with the lock replaced by the claim's window, §5.4):
   0. **Hand-over** (relayer claims, on a `Ready` swap at its confirmation depth with the deposit kept and out: reached from step 6, never from step 5, since the maker may cancel an open swap and its cancel reveals `e` beside the `z` handed over; D-151). Once per swap: sign the payout as in step 8 and keep it, keep `claimHold = posted`, then post `/v1/claim/hold` with the ticket. Held, or answered as a claim, → `held`. A `4xx` holds nothing: on `400 rejected`, re-read the terms, and if the fee rose within the cap, sign again at it, keep it and post once more; otherwise, and on a `404`, → `declined`, and the swap claims as without relayer claims. No answer (transport, `5xx`) leaves `posted`, and the next step posts the kept payout again, the same bytes. A failure never holds up the rest of the step.
   1. The window on one consistent read (`claim_window`): before `t0` and not `Ready` 2 blocks deep → `Waiting(CONFIRMING)`; under the margin before `t1`, or from `t1` until `t1 + LATE_WINDOW` → `Waiting(UNWINDING)`; otherwise open. A claim handed over (`posted` or `held`) waits until the window has been open a minute (§5.4).
   2. Build or reuse the payout (step 8).
   3. Require Railgun open (`RAILGUN_CLOSED`), asked only once the window is open.
   4. Derive `z`.
   5. Immediately before sending, judge the window again on a fresh consistent read, and keep `claim_posted` on the record.
   6. `POST /v1/claim {secret: z, payout}`. A `503` (the relayer's own depth wait) posts the same claim again later.
   7. `caughtUp(stage == Claimed)`. If not `paidOut`: `POST /v1/payout` and `caughtUp(Claimed && paidOut)`.

   **Never send `z` on a relayer answer or an old observation.**
8. **Relayer fee and payout** (`:384-419, 361-375`):
   - The fee is the offer's `relayerFee` while `now < feeExpiresAt`, else the current `GET /v1/terms` fee.
   - Require `fee < amount`.
   - Reuse the saved `payout` if its fee matches. Otherwise sign `Payout(id, pinnedRelayer, fee)` and **save it before sending**.
   - On `400 rejected`: re-read the terms. If the fee went up, sign again at the new fee and send once more. Otherwise rethrow.
   - **Fee cap (D11).** zapp has none; `zc/user.rs:339-343` takes a caller `max_fee`. veylor refuses a fee above 2 USDC here and at quote time. At claim time that is the `RELAYER_FEE` problem: the swap waits for the fee to come down, and if it never does before `t1`, the maker refunds and the ZEC is swept home.
9. **`finishPaid`** (`:227-239`): require a confirmed `PaidOut` event (`CHAIN_LAGGING` until one appears). Check the event's relayer and fee against the pin. `end = Paid`, with `payoutTx` and `receives` recomputed from the event's fee.
10. **`REFUNDED`**: §5.8.
11. **Token return.** On every advance after the deposit started, `GET /v1/swaps/{id}` collects the token if one is awaited (§5.9). Until M4, none is awaited and nothing is read (progress D-33).
12. **Abandon** (user action, `:126-131`): allowed only while the deposit is `NotStarted` and `swap(id)` is empty → `NothingSent(NEVER_OPENED)`. As built, an unanswered record (no `t0`, such as one turned away at the token gate) ends `NothingSent(MAKER_UNAVAILABLE)` instead (progress D-33); otherwise `TooLate`. A record of another deployment is `WrongDeployment`: never ended or driven.

The invariants for this machine are §3.5 items 1–8 and 16.

### 5.7 Reverse (USD → ZEC) state machine

**Roles are swapped on chain.** The escrow's `Terms.maker` is the **user's** auth address, `Terms.user` is the ZEC maker, `makerKey = Z(user)`, `userKey = E(maker)`, `t0 = readyDeadline`, `t1 = refundAfter`, and `payoutNote = 0` (`of/SwapTerms.kt:48-61`). The id is `keccak(abi.encode(authAddress, E.x, E.y, true))` (`of/SwapTypes.kt:72-80`). The refund note is kept apart, in `reverseFunding(id)`.

**Record** (`of/ReverseSwapModels.kt:120-147`):

- `index`, the whole `deployment` (pinned with the record), `quote` (`ReverseQuote`), `swapId`, `userShare`, `acceptance` (the wire `SwapAcceptance`, re-sent on retry) and `birthday`
- `account?` (the joint account's UUID), `phase`, `cost?` (`{debit, railgunFee, broadcasterFee, feeExpiresAt?}`)
- `funding?` (`{txId?, cost, request: {swapId, chainId, to, data, value:"0"}}`), `ready?` and `cancelRequested`
- `refundPosted` (kept before a refund goes), `payout?`, `rescue?`, `receive?` (`{txId, raw, expiryHeight, receivedZat, feeZat}`), `receiveEstimate?` (`{availableZat, feeZat}`) and `receiveConfirmations`
- `acceptedAt?`, `makerAccepted` and `ticket?`

**Phases:** `QUOTED → ACCEPTING → AWAITING_FUNDING → SENDING_USDC → CONFIRMING_ESCROW → RECEIVING_ZEC → AWAITING_READY → SETTLING → RECEIVING → COMPLETE`. The refund branch is `REFUND_WAIT → REFUNDING → REFUND_PAYOUT → REFUNDED`. `CANCELLED` ends a conversion with nothing paid. `FINISHED = {COMPLETE, REFUNDED, CANCELLED}`.

**Steps** (`of/ReverseSwapDriver.kt`):

1. **Quote** (`:46-91`; a preview that commits nothing):
   1. Nothing under way either way.
   2. `/v1/info` with `reverseEnabled`.
   3. `GET /v1/terms` with `checkedFee(requested)`: the refund payout must leave something.
   4. `index = take()`.
   5. `POST /v1/reverse/quote {units, user: authAddress, refundNote: commitment(index)}`.
   6. Verify: the deployment, `user` and `refundNote` are ours and the note is non-zero; `terms.amount == requested`; and the maker proof, by building the acceptance now.
   7. Require `readyDeadline > chainNow + 25 min` and `refundAfter ≤ chainNow + 24 h` (`:228-236`), and that the quote leaves the contract's `MIN_WINDOW` from `fundingDeadline` to `readyDeadline` and from `readyDeadline` to `refundAfter`, or `openReverse` would revert the funding.
   8. `birthday = Zcash tip`; `cost = funding.cost(amount)`, using the page's `reverseCost` (§6).
   9. Save as `QUOTED`. A quoted draft is never written to history.
2. **Go ahead** (first foreground authorization, `:94-103`): under the lock, require the quote to hold (`now < expiresAt` and `now < fundingDeadline`). Then save `ACCEPTING` with `acceptedAt`.
3. **Accepted** (`:198-207`, `ReverseSwapOpening.accept`, `:389-419`), once:
   1. `POST /v1/reverse/quote/{id}/accept` with the saved acceptance and the token loop.
   2. Require `swapId`, `t0 == readyDeadline` and `t1 == refundAfter`.
   3. Save `makerAccepted = true` and the `ticket`.
   4. A refusal that will not change ends the conversion as `CANCELLED`. The codes `unavailable` and `watchtowerUnavailable` → `MAKER_BUSY`; `unknownQuote` → `QUOTE_EXPIRED`; `tokenRequired` → `TOKENS_REFUSED`; `rejected`, `invalidRequest`, `unknownSwap`, `notFound` and `methodNotAllowed` → `MISMATCH`, as do the token blocks. `internal` is tried again (`:575-612`).
   5. **Import the joint account** at `birthday` and save `account`, then `AWAITING_FUNDING`. This happens **before funding**, per `zs/docs/reverse-flow.md` step 3.
4. **Fund** (first authorization, continued; foreground; `:122-144`, `ua/ReverseSwapFundingImpl.kt`):
   1. Require: no escrow yet, `now < fundingDeadline`, and `readyDeadline > now + 25 min`.
   2. Read `GET /v1/terms`. Require `reverseFunding` with a `fee`, and require `relayAdapt`, `token` and `maker` to equal the pin (`of/ReverseFundingTerms.kt:63-86`). Refuse a `fee` above 2 USDC (X6).
   3. Pick the fee: the reviewed `broadcasterFee` while `now + 120 s < feeExpiresAt`, else the current one.
   4. Sign `OpenReverse` (this needs the Railgun seed, for the refund note commitment).
   5. Encode three calls (`of/ReverseFundingCalls.kt`):
      - `token.approve(contract, amount)`
      - `contract.openReverse((quote.terms.maker, quote.user, token, amount, makerShare.x, makerShare.y, userShare.x, userShare.y, readyDeadline, refundAfter, refundNote, fundingDeadline), sig)`, with the selector string `openReverse((address,address,address,uint128,uint256[2],uint256[2],uint64,uint64,bytes32,uint64),bytes)`. This is the `ReverseOpen` order. The contract stores the swapped-role `Terms`.
      - `token.transfer(relayer, fee)`
   6. The page's `prepareReverse {amount, railgun: proxy, token, calls, relayAdapt, fee}` proves one Relay Adapt V2 transaction. It runs in public-wallet mode (`requireSuccess = true`) and shields the remaining dust back.
   7. Require `to == relayAdapt`, `value == 0` and calldata ≤ `maxCalldataBytes` (64 KiB at most).
   8. If the proved `cost` differs from the reviewed one: save the new cost and throw `FUNDING_COST_CHANGED`. Nothing is paid, and the user reviews again.
   9. **Save `funding` and `SENDING_USDC`**, then `POST /v1/reverse/fund`. Save the returned hash and move to `CONFIRMING_ESCROW`.
   10. On `400 rejected` with no hash: drop `funding` and go back to `AWAITING_FUNDING`. If the fee went up, show the new cost (`FUNDING_COST_CHANGED`; `of/ReverseFundingSubmission.kt`).
   11. **Never prove a second unshield because a response was lost.** Resend the same bytes only while the node does not know the hash, `now < fundingDeadline` and the user has not cancelled (`:452-474`).
5. **`advance()`**, once per loop tick (`:105-119`, `ReverseSwapStages`, `:322-362`). First, a confirmed escrow read via `verifier.state`. It checks the record's ids against its keys, the `refundNote` and `fundingBlock` against the read, and requires `block − fundingBlock + 1 ≥ escrowConfirmations` (else `CHAIN_LAGGING`; `of/ReverseSwapVerifier.kt:16-36`). Then the first matching case applies:

   | Case | Action |
   |---|---|
   | no escrow | the funding tx `REVERTED`, or `now > fundingDeadline + 600 s` → `CANCELLED`. A known tx → `CONFIRMING_ESCROW`. A cancel requested, or `now ≥ fundingDeadline` with no funding → `CANCELLED`. |
   | `CLAIMED` | the maker revealed `e`. Save `RECEIVING` and **sweep home**. |
   | refund due (§5.8) | the refund path |
   | `READY` | `SETTLING` |
   | `ready` saved | resend it while `now ≤ ready.deadline` and no refund was posted, never re-signed. Lapsed → `REFUND_WAIT`. |
   | otherwise | look at the deposit (below) |
6. **Deposit detection** (`ReverseSwapReceiving`, `:498-531`). Sync the joint account to the tip. `estimate` sums **received**, not-sent transactions with ≥ `zcashConfirmations` (2), and sets `fee = 5000 × max(2, notes + 1)` (`ua/JointAccounts.kt:92-107`).
   - If `available < depositZat`, there is no estimate yet. `available ≥ depositZat` but `available ≤ fee` → `MISMATCH`.
   - The phase is `SETTLING` if the escrow is not `Open`. It is `REFUND_WAIT` if a refund was posted or `now + 120 ≥ readyDeadline`. Otherwise it is `AWAITING_READY` with an estimate, or `RECEIVING_ZEC` without one.
   - **The maker's status API is never evidence.**
7. **Ready** (second foreground authorization; `:147-157`, `ReverseSwapApprovals.authorizeReady`, `:291-310`):
   1. Require the whole deposit spendable (`DEPOSIT_UNCONFIRMED`), and, on one consistent read of a fresh head (`CHAIN_LAGGING` on a head minutes behind), the escrow `Open`, no refund ever posted, and `head + 120 < readyDeadline` (`may_sign_ready`; `TOO_LATE` otherwise).
   2. Sign `Ready(id, head+120)`.
   3. **Save** `ready` (its deadline is the one a refund waits out), `SETTLING` and `receiveEstimate` (the reviewed sweep fee), then `POST /v1/reverse/ready`. The relayer refuses a `ready` after it sent a refund for the escrow (`400`).
   4. A restart never signs `ready`.
8. **Sweep home** (`receive`, `:534-558`): `keepSending` with `prepareReceive`. The sweep is signed with `e + z` and capped at the reviewed `receiveEstimate.feeZat`. It is kept before it is first sent. `confirmations ≥ zcashConfirmations` → `COMPLETE`, then forget the joint account.
9. **Cancel** (user, `:159-182`): allowed until the escrow is claimed or a receive is built (`isSettled`). It saves `cancelRequested`. The phase becomes `REFUND_WAIT` unless a refund is already under way, and an advance follows at once. With no escrow it ends `CANCELLED`. With an escrow it starts a refund.

**veylor as built (M6 part 1, progress D-70 to D-78).** `rust/src/wallet/private_usd/reverse.rs`; the calldata is `funding_calls.rs`.

- **Pricing is split around the page.** Step 1.8's cost is set by `set_cost` after the page's `reverseCost`: the quote returns the request (amount, Railgun proxy, the relayer's funding fee), and `set_cost` re-reads the fee and requires `debit = amount + fee + railgun_fee`. Going ahead and the funding request need a priced record.
- **Step 4 runs in two calls around the page.** `funding_request` (steps 4.1–4.5; the page's open address must be the account's) holds the request in memory for its lock session; `submit_funding` (4.7–4.11) takes it once and refuses after a cancel, a lock or a restart (`Cancelled`) or a changed record (`TooLate`). The proof must go to the pinned Relay Adapt with no value and cost exactly what the calls pay. After a `400 rejected` at a higher fee, the dropped funding's cost is cleared for the page to price again.
- **Posts follow their save** under the per-account driver lock, which spans the post: a cancel waits for a funding's post rather than interleaving with it. The funding's answer is merged into the record as it is then.
- **The token gate** (step 3): the user's accept returns `TokensNeeded` and leaves the record unanswered; the loop resuming an interrupted accept ends it `CANCELLED` (no tokens client before M4).
- **The sweep home** pays at most the reviewed `receiveEstimate.feeZat`; `estimate` is the joint account's confirmed receipts and `5000 × max(2, notes + 1)`.

### 5.8 Refunds, offline behaviour and user-visible states

**Forward refund** (`of/AtomicSwapDeposits.kt:47-93`). It runs when `getSwap.stage == Refunded`; the maker revealed `e` in `secret`.

1. Find the deposit (`withFound`):
   - `Mined` → sweep
   - `Unmined` or `Unknown` → `Waiting(DEPOSIT_UNSETTLED)`
   - `Expired` or no deposit → `NothingSent(MAKER_CANCELLED)`
2. Sweep:
   1. `prepareSweep`: import the joint UFVK at `zcashHeight` (idempotent, found by UFVK).
   2. Sync. Return null until **every** note is spendable, meaning balance > 0 and pending = 0.
   3. Reuse an earlier non-expired sent transaction from the joint account, if any. As built, veylor looks for it **before** step 2's balance check (`joint::find_sent`, to any address), since an unmined earlier sweep leaves nothing spendable (progress D-34). The sweep pays the account's current receive address; send flow `private-usd-sweep:{account}:{index}`.
   4. Else build: `SweepIntent(homeUA, balance − feeLimit, feeLimit)`, with `feeLimit = min(320,000, balance − 1)` and at least 10,000.
   5. Propose the whole balance with no change. The fee starts at 10,000 and grows to the proposal's fee until it is stable at one transaction, up to 64 tries (`ua/JointAccounts.kt:154-208`).
3. Keep the sweep and send it until it has `zcashConfirmations`.
4. End `Refunded(sweepTxId, cause)` and delete the joint account. The cause is `MAKER_CANCELLED` if the refund mined before `t1` (the maker called the swap off), else `NOT_CLAIMED_IN_TIME` (the refund from `t1`, after the swap unwound).

**Reverse refund** (`of/ReverseSwapRefunds.kt`, with the lock replaced by the windows, §5.4). It is due when cancelled, when the escrow is `Refunded`, when it is `Ready` with `now ≥ refundAfter`, or when it is `Open` with `now ≥ readyDeadline`.

1. `Refunded` and `paidOut` → `REFUNDED`. `Refunded` without a payout → sign or reuse `RefundPayout(id, relayer, feeNow)`, save it, then `POST /v1/reverse/refund-payout` (`REFUND_PAYOUT`). The fee must be ≤ 2 USDC (D11).
2. `Ready` and `now < t1` → `REFUND_WAIT`.
3. On one consistent read (`may_refund`): a `Ready` escrow from `t1`, an `Open` one once the chain is past every `ready` deadline signed (or at `t0`); else `REFUND_WAIT`. After a cancel with a signed `ready` that may still land, that is a wait of up to 2 minutes.
4. Save the payout first. Judge again on a fresh read immediately before sending, keep `refund_posted` (no `ready` is signed or sent after it), then `POST /v1/reverse/refund {secret: z, payout}`. A `503` (a `ready` the relayer sent may still land) posts the same refund again later.
5. Revealing `z` lets the maker take back its ZEC with `e + z`. The USDC goes to the refund note, less the relayer fee.
6. **Rescue** (user action on a `REFUNDED` record): only if `paidOut` and the vault balance exceeds the relayer fee. Read `rescueNonces(id)`, require the fee ≤ 2 USDC (X6), sign `Rescue(id, note, relayer, fee, nonce, now+120)`, then `POST /v1/reverse/rescue`. The record stays finished, and `REFUNDED` records are kept beyond the 100-record history limit (`ua/ReverseSwapStoreImpl.kt:61-69`).

**When the app is offline past a deadline.** No case loses funds.

| Direction and state | Outcome |
|---|---|
| Forward, before the deposit | Past `t0 − minSecondsToT0` the deposit is never paid: `NothingSent(DEPOSIT_WINDOW_MISSED)`. |
| Forward, deposit paid, user absent past `t1 − 300 s` | The swap unwinds: from `t1` the maker may refund, revealing `e`, for `LATE_WINDOW`. The user sweeps the ZEC home whenever they next open and unlock Veylor (`Refunded(NOT_CLAIMED_IN_TIME)`, less Zcash fees). The USDC is lost only as an opportunity. A maker that never refunds leaves the claim to the user from `t1 + LATE_WINDOW`, for good. |
| Forward, `Open` from `t0` | The user may claim; the maker can no longer call the swap off. |
| Reverse, unready escrow | Never the maker's to claim. The USDC stays escrowed until the phone returns and refunds. |
| Reverse, `Ready` | The maker claims until `t1`. A user who returns late still sweeps with the revealed `e`. If the maker never claims, the user refunds from `t1`. |

The real hazard is a reveal that lands outside its window: it reverts with the share public, and the other side takes both legs. That is why the 300 s margin, the 12-block ready depth, the one consistent read and the fresh read immediately before the post exist.

**User-visible states.**

- **Forward stages** (`ua/AtomicSwapStage.kt`): `OPENING`, `DEPOSITING`, `CONFIRMING`, `CLAIMING`, `REFUNDING`. Veylor adds the `UNWINDING` wait (§5.4).
- **Forward outcomes:** `Paid`, `Refunded(cause)`, `NothingSent(cause)`.
- **Reverse:** one label per phase (`ua/ReverseSwapStage.kt`). The user's approvals are `FUNDING` in `AWAITING_FUNDING` and `SETTLEMENT` in `AWAITING_READY`. Cancel is shown while `!cancelRequested && !isSettled` and not in `REFUNDING`/`REFUND_PAYOUT`.
- **Problems** (`ua/SwapLoop.kt:61-95`): `RELAYER_UNREACHABLE`, `RELAYER_REFUSED`, `RELAYER_FEE`, `ETHEREUM_UNREACHABLE`, `RAILGUN_CLOSED`, `ZCASH_WALLET`, `DEPOSIT_UNPAYABLE`, `ZCASH_REJECTED`, `MISMATCH`, `TOKENS_UNREACHABLE`, `UNEXPECTED`. zapp's `CLAIM_TURN` went with the locks.
  - A problem is shown only after 1 min of consecutive failures.
  - `ZcashWait.{SYNCING, CONFIRMATIONS}` is never a problem.
  - The block → hold mapping is at `ua/SwapLoop.kt:424-486`.

### 5.9 Privacy Pass tokens and attestation

**Spec:** `zs/docs/tokens.md`. **Client:** `of/SwapTokens.kt`. **Crypto:** `zs/crates/zecswap-tokens` (RFC 9578 type `0x0002`, `blind-rsa-signatures 0.18`, no Zcash dependencies, but it does not resolve beside veylor's Zakura stack: M0.1 result). The JNI wrapper `zs/crates/zecswap-jni/src/tokens.rs` shows the four calls: `read_www_authenticate`, `Pending::new` → `(pending, blinded 256 B)`, `Pending::finalize(key, blind_sig)` → a 354-byte token, and `Token::authorization()`.

**Spending a token at accept** (`of/SwapClients.kt:325-349`):

1. POST without a token.
2. While the answer is `401` with `WWW-Authenticate: PrivateToken challenge=…, token-key=…`, and for at most 3 paid tries:
   1. `tokens.pay(swapId, header)`.
   2. Resend with `Authorization: PrivateToken token="…"` and the body's `tokenRequest`, a fresh blinded request under the **return key** for the same challenge.
   3. `settle(payment, status)`.

**Inside `pay`** (`of/SwapTokens.kt:212-236, 303-319`):

1. Refuse a challenge whose issuer name or token key differs from the pin, or whose day (the last 8 bytes of the 32-byte redemption context, big-endian, as UTC days) is not today ± 10 min (`TOKENS_REFUSED`).
2. Drop held tokens and returns from earlier days.
3. Spend an issuer token for this challenge first. Fetch a batch if none is held and the day is not marked exhausted. Spend a **returned** token only once the issuer is exhausted for the day.
4. Record a `PendingReturn(swapId, challenge, pending)` before spending.

**`settle`** (`:243-256`):

- A `2xx` drops the token.
- A `401` drops the token and the pending return.
- Anything else, or no answer, leaves the token spendable.

**Collecting the return** (`:265-283`): on every advance after paying in, `GET /v1/swaps/{id}` or `/v1/reverse/swaps/{id}`, but only while a return is awaited. A `tokenReturn` that finalizes under the return key becomes a held token. Per `tokens.md`, wait hours before spending a returned token.

**Issuance** (`SwapTokenIssuance`, `:373-450`), over a **fresh client that is closed after each fetch**:

1. `GET {issuer}/v1/token-key` → `{issuer, tokenKey, tokensPerDay}`. It must equal the pin.
2. Make `n = clamp(tokensPerDay, 1, 100)` blinded requests.
3. `GET /v1/challenge` → `{challenge}`, 32 bytes base64url, good once for 5 min.
4. `POST /v1/tokens {attestation: {challenge, chain, signature}, blinded}` → `{blindSignatures}`.
5. Handle the answer:

   | Answer | Action |
   |---|---|
   | fewer signatures than requested | mark today exhausted |
   | `429` | exhausted |
   | `403` with `code: rejected` | `TOKENS_DEVICE_REFUSED`; retried once with a new challenge, because an expired challenge is also refused |
   | anything else | `TOKENS_UNAVAILABLE` |
6. Unblind and check each signature.
7. **Prefetch** (`:286-300`) on the quote screen and after every conversion ends. It moves the last challenge to today and fetches if none is held.

**State** (`SwapTokenState`): `{challenge?, held[{challenge, tokenKey, token}], exhaustedDay?, returns[{swapId, challenge, pending}], refusedBy?}`. `pending` is the blinding secret, so keep the store at least as protected as the swap records.

**Attestation** (`ua/AtomicSwapAttestation.kt`, `tokens.md` §Attestation):

- **The key.** EC P-256 (`secp256r1`), `PURPOSE_SIGN`, `DIGEST_SHA256`, with the attestation challenge `SHA-256("zecswap-issuer-v1" ‖ issuerName)`. It uses StrongBox where `generate` succeeds, else the TEE (veylor's minSdk 30 always tries StrongBox). It needs no user authentication (zapp fetches in the background; keep the same key spec in veylor).
- **Alias and lifetime.** One alias (zapp: `atomicswap_issuer_attestation`). The key is regenerated **only** when a certificate in its chain has expired. Making a new key after a refusal would hand out a fresh allowance.
- **The request.** `chain` is the `KeyStore.getCertificateChain` list, leaf first, each DER, base64url without padding. `signature` is `SHA256withECDSA` over `"zecswap-issuer-v1" ‖ challenge(32 B) ‖ SHA-256(blinded₁‖…‖blindedₙ)`.
- **What the issuer checks:** the chain up to Google's root, each certificate's validity, Google's status list, at least TEE level, a locked bootloader with verified boot, and the configured package and signing digest (`tokens.md` "What the issuer checks"). An emulator or a debug build signed with another key gets `403`.
- **veylor needs one alias per issuer**, for example `vizor_privateusd_attest_<issuerName>`. veylor runs mainnet and testnet in one app (D2), while zapp ships one network per build. A key attested for the testnet issuer counts for nothing at the mainnet issuer. Never delete it (X4).

**Route (D10).** Issuer requests go through `routed_http`, like every other engine request: over Tor when Tor is on, direct otherwise. zapp requires Tor here (`TOKENS_NEED_TOR`, `ua/AtomicSwapTokens.kt:40-50`). Its reason is unlinkability: the issuer sees the install's attestation key on every fetch, the maker sees the spend, and a fetch and a spend from the same address can be matched (`tokens.md`: "Fetch ahead, spend later … Send both over Tor or Oblivious HTTP"). veylor accepts that link when Tor is off, and discloses it on the review screens (`tor_off_disclosure`).

**veylor issuance (X11).** Rust cannot reach the Keystore, so issuance takes two FRB phases around a Kotlin call:

1. `private_usd_tokens_issuance_begin`. Rust runs issuance steps 1–3 (token key, blinded requests, challenge). It keeps the pending blinding secrets in memory under a `session_id`, and returns `message = "zecswap-issuer-v1" ‖ challenge ‖ SHA-256(blinded₁‖…‖blindedₙ)` and the issuer name. It returns `None` when nothing is needed: a token is already held for the current challenge, or today is marked exhausted.
2. Kotlin `sign(issuerName, message)` returns `{chain, signature}`.
3. `private_usd_tokens_issuance_finish(session_id, chain, signature)`. Rust runs steps 4–6. On the first `403 rejected` it fetches a new attestation challenge and returns `SignAgain` with the new message for the same blinded batch; Dart repeats step 2 once (§8.2, M4 pitfalls).

At accept, the engine spends only tokens it already holds (the M5 seam is `engine::TokenSource`; until M4, `NoTokens` holds none, progress D-33). If the maker answers `401` with a pinned challenge and no token for it is held, the engine stores the challenge and returns `TokensNeeded`. Nothing was opened, because a `401` sends nothing. Dart then runs issuance once and calls accept again with the same saved acceptance. If issuance fails, Dart calls abandon, which ends the record as `NothingSent(MAKER_UNAVAILABLE)`, as zapp does for a turn-away at the token gate. Keep zapp's limit of 3 paid tries per accept.

**As built (M4, progress D-154).** `rust/src/wallet/private_usd/tokens.rs` is the state file and the rules above, with these differences from the port:

- Each pending return records its direction, so the prefetch pass knows which status (`/v1/swaps/{id}` or `/v1/reverse/swaps/{id}`) to read for it.
- The store keeps `makerAsks`, set from the maker's `/v1/info` (the pinned return key) by `issuance_begin` and by a `401`; `ApiTokenStatus.maker_asks` shows it, and the review screens disclose the fetch-spend link while it holds and Tor is off.
- The maker's challenge being deterministic (`(issuer, "maker", day)`), a batch is fetched ahead for it as soon as `makerAsks` holds, from install; a `401` that asks for another challenge drops the batch fetched ahead for the day and is paid for the asked one.
- `begin` asks for `clamp(tokensPerDay, 1, 100)` blinded requests; `finish` holds a short batch and marks today spent.
- One `tokens::accept_paying` runs both accepts: an unpaid post, then at most 3 paid ones, each settled by its answer (a success that does not read still took the token; a request that never went out left it). The forward acceptance is built per post; the reverse one is kept without `tokenRequest`, which goes on the paid post alone.
- A reverse resume the maker turns away with no token held returns `TokensNeeded` as the advance's problem (`ErrorCode::TokensNeeded`, shown as "The market maker asks for a token…"), and the Dart engine runs the issuance once per record; only three tokens refused on a resume cancel the conversion.
- Returns are collected on every forward advance once the deposit is kept and once more as the record ends paid, on every reverse advance once a funding is kept, and for every pending return during a prefetch pass.
- `Keystore` is a Dart-raised code (`ApiPrivateUsdErrorCode::Keystore`, never from Rust) for the attestation channel's failures; `unavailable` from the channel (iOS, or no attested key) maps to "Conversions need an Android phone…".

### 5.10 The foreground loop (zapp's timing, without the worker)

D9 drops zapp's `AtomicSwapWorker`, its scheduler, its wake alarms and its notifier. These are zapp's loop rules that veylor keeps, in `PrivateUsdEngineLoop` (`ua/SwapLoop.kt:160-345`):

- The loop runs while any software account has a record under way, and only while unlocked and in the foreground (D9, D14). It calls `forward_advance`/`reverse_advance`, then naps. A `nudge` (`retryNow`: "Try now", accept, fund, ready, cancel or rescue) cuts the nap short.
- A failed step is retried every 15 s. A crashed loop restarts after 30 s.
- **Forward naps:** `OPENING` 5 s; `CONFIRMING` 20 s; `DEPOSIT_UNSETTLED`, `REFUNDING` and veylor's `UNWINDING` 30 s (`ua/AtomicSwapRepository.kt:269-276`). **Reverse naps:** 15 s (`ua/ReverseSwapRepository.kt:184-186`).
- A problem (§5.8) shows only after 1 minute of consecutive failures. `ZcashWait.{SYNCING, CONFIRMATIONS}` is never a problem. The mapping from a failed step to a held problem is at `ua/SwapLoop.kt:424-486`.
- **Starts:** app foreground and unlock; the progress screen opening; and in a `finally` after accept, fund, ready, cancel and rescue (`ua/AtomicSwapRepository.kt:137-144`, `ua/ReverseSwapRepository.kt:122-129`).
- **On a finished forward swap:** prefetch tokens.
- **Zcash status reads:** zapp runs `syncToTip` for up to 1 minute per read, because nothing else syncs in its background (`ua/SwapZcashTransactions.kt:103-104`). In veylor, the main DB is kept current by `syncProvider`. Before a deposit decision, check that the main wallet's scan has reached the tip, else return `ZcashWait.SYNCING`. Sync `joint.db` with `sync_joint_db` on each advance that needs it.
- **What must happen while the app is open**, for a conversion to *succeed* rather than only stay safe:
  - the forward deposit, before `t0 − minSecondsToT0`
  - the forward claim, before `t1 − 300 s`; after it the swap unwinds through the maker's refund (or the claim waits for `t1 + LATE_WINDOW`)
  - the reverse `ready`, before `readyDeadline − 120 s`
  - every refund and sweep

  The progress copy says so (§9.6, `F` rows).

**veylor engine (Rust side, `engine.rs`).**

```rust
// As built (M5 part 1, progress D-31).
pub(crate) fn lock_account(account: &str) -> Result<DriverGuard>;   // a tokio::sync::Mutex per account; try_lock_owned → Busy. Held across I/O; never OPERATIONS.
pub(crate) struct Offer { network, quote: SwapQuote, relayer_fee, fee_expires_at, receives, deposit_fee_zat: Option<u64> }   // + max_total_zat()
pub(crate) fn session() -> u64;                                      // a quote takes it first; clear_sessions bumps it
pub(crate) fn put_offer(account, index, offer, now, session);        // kept until quote.expires_at, pruned per account; dropped if the session moved on
pub(crate) fn offer(account, index, network, now) -> Option<Offer>;  // None once expired: accept → QuoteExpired
pub(crate) fn remove_offer(account, index); pub(crate) fn remove_account_offers(account);
pub(crate) fn clear_sessions();                                      // offers, reverse fundings, maker /v1/info checks; from private_usd_clear_sessions (on lock)
pub(crate) struct FundingSession { network, record, fee, fee_expires_at, relay_adapt, max_calldata_bytes }   // M6: a reverse funding handed to the page
pub(crate) fn put_funding(account, index, funding, session); pub(crate) fn take_funding(account, index, network) -> Option<FundingSession>;
pub(crate) struct OpHandle;      // begin(op_id) registers (Busy if in use); dropped on return. .cancelled() between steps; .cancel_flag() reaches routed HTTP and joint scans; .set_activity(a) before a slow step
pub(crate) fn cancel_op(op_id: u32);                                 // also remembers up to 64 ids cancelled before their call registered
pub(crate) fn op_activity(op_id: u32) -> Option<Activity>;          // Depositing | Claiming | PayingOut | Sweeping | Funding | Readying | Refunding
pub(crate) trait Clock { fn now(&self) -> u64; async fn sleep(&self, d: Duration); }   // SystemClock; tests fake it
pub(crate) trait TokenSource { fn accept_authorization(&self) -> Option<String>; fn token_required(&self, challenge: Option<&str>); }   // NoTokens until M4
pub(crate) fn problem(code: ErrorCode) -> ErrorCode;                 // folds a failed step's code into the §5.8 problem set
pub(crate) fn delete_account(store_dir, network, account) -> Result<()>;   // driver lock (Busy), joint accounts, then swaps.db rows
```

**veylor engine (Dart side).** `PrivateUsdEngine` in `services/private_usd_engine.dart`, owned by the keepAlive `privateUsdEngineProvider`; skeleton in §9.2.

- One serial queue per account. Every FRB call that touches a record (accept, advance, fund, ready, cancel, rescue, abandon) goes through it, so Rust's `Busy` is a rare race, not a normal path.
- `run()` loop: while `allowed()`, for each account from `private_usd_accounts_with_unfinished`, for each unfinished index: read the mnemonic (`getMnemonicBytesForAccount(uuid)`), call `…_advance(op_id)`, zero the bytes in `finally`, publish the result to `privateUsdConversionProvider` and `privateUsdUnfinishedProvider`, then nap the minimum `next_poll_ms` (or 15 s after a failure). `nudge()` cuts the nap.
- `allowed()` = `foreground && !requiresUnlock && !quiesced && !disposed`.
- `pause()` (lock, hide, quiesce): bump the epoch, `private_usd_cancel(currentOpId)`, stop the nap timer. On lock also `private_usd_clear_sessions()`, close the Railgun page (M3) and clear the problem timers.
- Problem timing (§5.8): track `failingSince` per `(account, direction, index)`; show `problem` only when `now − failingSince ≥ 60 s`; clear on any success. `ZcashSyncing` is a wait, never a problem.
- After a forward record ends: `private_usd_tokens_issuance_*` prefetch (M4 service).
- As built (M5, progress D-51): the loop idles with no timer while nothing is under way, and accept, a progress screen opening, unlock and the foreground start it. It naps the shortest `next_poll_ms` of a pass (at least 1 s), 15 s after a failed step or `Busy`, 30 s when listing failed. Only advances and accept drop a result that lands after a pause; a quote or a call-off that finished in Rust is still shown. The lifecycle and lock listeners live in `privateUsdEngineProvider`; `PrivateUsdEngineHost` only keeps it alive.
- As built (M6, progress D-81): each pass reads both directions per account and advances reverse records under way only (never a `quoted` draft); reverse records live in a second snapshot (`privateUsdReverseConversionsProvider`), and the unfinished set is the union. The funding runs outside the queue, bound to the engine's epoch (`PrivateUsdEngineTicket`), and its submit is asked again right before the FRB call; a cancel `drop`s it. The loop never sends a rescue.

### 5.11 End-to-end walk (who does what; crash, kill and lock at each step)

"Kill" means the process dies; "lock" includes the 15-minute background auto-lock. "Resume" is the engine's next advance after unlock and foreground. Rust saves are one SQLite transaction each.

**Forward (ZEC → USD), happy path.**

| # | Step | Component | Crash/kill here | Lock/background here |
|---|---|---|---|---|
| F1 | Tap the strip → `/private-usd`; tap Convert. If an unfinished record exists, open its progress route instead. | `MobilePrivateUsdScreen`, `privateUsdUnfinishedProvider` | nothing saved | redirect to `/unlock` |
| F2 | Type ZEC; after 700 ms the quote search calls `private_usd_forward_quote` 1–4 times. | `privateUsdConvertProvider`, `PrivateUsdZecQuoteSearch` → Rust `forward.rs` | indices already taken stay spent; the offer cache is gone; quote again | `clear_sessions` drops the offers; the screen re-quotes after unlock (new index) |
| F3 | Review → "Convert" → `private_usd_forward_accept`: Rust saves the record (t0 = None), then POSTs accept. | review screen → Rust | before the save: nothing; after it: the record is "maybe opened"; resume → `OPENING` until `expiresAt + 300 s` → `NEVER_OPENED`/`MAKER_UNAVAILABLE`, or it continues | the FRB call finishes in Rust; Dart drops the result (epoch) and the engine resumes the record after unlock |
| F3a | `TokensNeeded` → token issuance (Kotlin sign) → accept again, same index. Issuance fails → `forward_abandon` → `NothingSent(MAKER_UNAVAILABLE)`. | `privateUsdConvertProvider`, M4 service | the record stays unanswered; resume shows the opening step with "Call it off" after 90 s | as F3 |
| F4 | `pushReplacement` to `/private-usd/conversion/forward/:index`; the engine nudges. | router, `PrivateUsdEngine` | — | — |
| F5 | Advance: confirmed `getSwap`; verify terms; derive the joint UA from the on-chain shares. | Rust `forward.rs` | read-only | cancelled between reads |
| F6 | Deposit: main wallet scanned to the live tip? else `ZcashSyncing`. Save `Started` → propose (RAII discard) → create (stored in the main DB) → save `Kept{txid, raw, expiry}` → broadcast. | Rust (`propose_swap_deposit`, `create_stored_proposal_transactions`, `broadcast_raw`) | after `Started` and before `Kept`: resume runs `findDeposit` (the stored tx, which the main sync is also rebroadcasting); never a second deposit | cancel is honoured only before `Started` or after `Kept` |
| F7 | `Waiting(CONFIRMING)` until the maker marks `Ready` (or `t0` passes). Naps 20 s. | Rust + engine | nothing at risk | paused; absent past `t1` → the maker may refund → F-R1 |
| F8 | Claim: the window on one consistent read, payout signed and saved, the window again on a fresh read, `claim_posted` kept, reveal `z`, payout. Too late before `t1`: `UNWINDING` until the maker's refund (F-R1), or a claim from `t1 + LATE_WINDOW`. | Rust | resume re-reads the chain; a saved payout is reused; `z` goes again only inside its window | cancel between steps |
| F9 | `finishPaid` on a confirmed `PaidOut` → `end = Paid`. Engine prefetches tokens; the balance polls at 30 s (arriving). | Rust; `privateUsdBalanceProvider` | idempotent | — |

**Forward refund.**

| # | Step | Component | Crash/kill | Lock |
|---|---|---|---|---|
| F-R1 | `getSwap.stage == Refunded`: find the deposit (`Mined` → sweep; unmined → `DEPOSIT_UNSETTLED`; expired/none → `NothingSent(MAKER_CANCELLED)`). | Rust | read-only | paused |
| F-R2 | Import the joint UFVK at `zcashHeight` (idempotent), `sync_joint_db`, wait for all notes spendable. | Rust `joint.rs` | idempotent | cancel flag reaches the claim sync |
| F-R3 | Build the sweep (fee loop), sign with `±(e+z)`, prove, broadcast, store; save `sweep`. | Rust | before the save: the joint DB holds the tx (or nothing); resume reuses "an earlier non-expired sent transaction" (§5.8 step 2.3) | as F6 |
| F-R4 | `zcashConfirmations` reached → `Refunded(cause)`, delete the joint account. | Rust | idempotent | — |

**Reverse (USD → ZEC).**

| # | Step | Component | Crash/kill | Lock/background |
|---|---|---|---|---|
| R1 | Convert screen, `?to=zec`. Requires the page READY and the balance known. | convert screen, `RailgunEngine` | — | page closed on lock |
| R2 | Type dollars; 700 ms → `private_usd_reverse_quote` (saves QUOTED, index spent) → page `reverseCost` → `…_set_cost`. | convert provider → Rust → page → Rust | QUOTED survives; it is not "under way" | the quote stays; cost re-asked after unlock |
| R3 | Review → "Convert": `…_go_ahead` (ACCEPTING) → `…_accept` (TokensNeeded loop; imports the joint account; AWAITING_FUNDING). | review screen, engine queue | resume runs `accepted` again (idempotent) | resume after unlock |
| R4 | Spend guard `startConversion`. `…_funding_request` (signs OpenReverse). | Dart guard → Rust | nothing saved | — |
| R5 | Page `prepareReverse` (≤ 10 min; `proof` events; keep-awake). | `RailgunEngine` | proof lost; nothing paid; "Pay {debit}" proves again | lock closes the page → `closed`; background → the result is dropped unless still foreground, unlocked and same epoch |
| R6 | `…_submit_funding`: cost changed → saved, `FundingCostChanged`, AWAITING_FUNDING ("Pay {debit}"); else save `funding` + SENDING_USDC, then POST. | Rust | after the save: resume resends the same bytes only while the node does not know the hash and `now < fundingDeadline` | as F3 |
| R7 | Advance (15 s naps): escrow confirmed → RECEIVING_ZEC; the maker deposits ZEC; `sync_joint_db`; 2 confirmations → AWAITING_READY (banner "needs attention"). | engine → Rust | read-only | paused |
| R8 | "Authorize settlement" → `…_authorize_ready`: on a fresh head, with its deadline before `t0` and no refund posted, sign, save `ready`, SETTLING, then POST. | progress screen → Rust | resume resends the saved `ready` until its deadline, never after a refund was posted; never re-signs | — |
| R9 | The maker claims (reveals `e`) → RECEIVING: sweep home capped at the reviewed fee, kept before first send → COMPLETE, delete the joint account. | Rust | as F-R3 | as F6 |

**Reverse cancel, refund and rescue.**

| # | Step | Component | Crash/kill | Lock |
|---|---|---|---|---|
| RC1 | Cancel (confirmation sheet) → `…_cancel`: saves `cancelRequested`, REFUND_WAIT; no escrow → CANCELLED. A funding proof in flight is dropped at R6. | progress screen → Rust | the flag is saved first | — |
| RC2 | Refund due → its window on one consistent read (a `ready` that may still land waits it out) → payout saved → the window again on a fresh read → `refund_posted` kept → reveal `z` → REFUND_PAYOUT → REFUNDED. | Rust | each signature saved before sending; resume re-reads the chain | cancel between steps |
| RC3 | Refunds screen: `…_can_rescue` per REFUNDED row every 15 s; "Recover refund" (sheet) → `…_rescue`. | refunds provider → Rust | rescue is idempotent by `rescueNonces` | the screen's poller stops; nothing at risk |

## 6. Railgun host reference

Port zapp's `railgun-lib` (X1). Read on 2026-10-13 from `rl/` at `60bcf0b30`.

### 6.1 Files, bundle and build

**Files.**

- **Kotlin.** About 1.1k lines, in `rl/src/main/java/xyz/justzappit/railgun/`:
  - `RailgunWebViewHost.kt`: 305 lines
  - `RailgunChannel.kt`: 67 lines
  - `RailgunProtocol.kt`: 298 lines
  - `RailgunWallet.kt`: 197 lines
  - `RailgunModels.kt`: 250 lines
  - `RailgunReverseFunding.kt`: 55 lines
  - `RailgunException.kt`: 37 lines
  - `Bech32m.kt`
- **JS source.** `rl/web/src/{index,wallet,transact,reverse,reverse-amounts,reverse-envelope,broadcaster-fee,artifacts,errors,shims}.js` and `index.html`.
- **Tests.**
  - Kotlin: `rl/src/test/.../{RailgunBoundaryTest,RailgunChannelTest,RailgunProtocolTest,RailgunSessionTest}.kt`
  - JS: `rl/web/dev/*.test.mjs` (`node --test`)
  - Desktop smoke check: `rl/web/dev/check.mjs` (puppeteer, headless Chrome)

**The committed bundle.** It is in `rl/src/main/assets/railgun/`, about 11.7 MB in the APK before compression:

| File | Size (bytes) |
|---|---:|
| `railgun.js` | 9,767,606 (ESM, minified) |
| `poseidon_hash_wasm_bg.wasm` | 1,936,566 |
| `curve25519_scalarmult_wasm_bg.wasm` | 29,793 |
| `index.html` | 617 |
| `railgun.js.LEGAL.txt` | 4,586 |

**How it is built** (`rl/web/build.mjs`):

- Command: `npm ci --ignore-scripts && npm run build`.
- esbuild 0.28.2 with `format: esm`, `target: chrome100` and `minify`.
- `src/shims.js` is injected (Buffer, process, `queueMicrotask` nextTick).
- `crypto` → `crypto-browserify` and `stream` → `stream-browserify`.
- The Node `http/https/url/zlib` modules are stubbed, and `web3` is stubbed (`rl/web/stubs/web3`).
- The wasm-bindgen web builds are copied beside the bundle.
- `npm overrides` pin patched `axios 1.20.0`, `bn.js`, `underscore` and `ws`.

**Versions and licenses** (`rl/web/package.json`; checked in `rl/web/node_modules`):

| Package | Version | License |
|---|---|---|
| `@railgun-community/wallet` | 11.1.0 | MIT |
| `@railgun-community/engine` | 9.8.0 | MIT |
| `@railgun-community/shared-models` | 8.2.0 | MIT |
| `ethers` | 6.14.3 | MIT |
| `level-js` | 6.1.0 | MIT |
| `@railgun-community/poseidon-hash-wasm` | 1.0.3 | MIT |
| `@railgun-community/curve25519-scalarmult-wasm` | 0.1.5 | MIT |
| **`snarkjs`** | **0.7.6** | **GPL-3.0** (the prover, imported by `wallet.js:19`) |
| **`ffjavascript`** | **0.3.1** | **GPL-3.0** |
| **`@railgun-community/circomlibjs`** | **0.0.8** | **GPL-3.0** (an engine dependency) |
| `@railgun-community/ffjavascript` | 0.1.0 | GPL-3.0 |
| the zapp glue (`package.json`) | — | `AGPL-3.0-only` |

The bundle contains GPL-3.0 code. It ships as a separately licensed asset, with its notices beside it and its source in the repo (D3, X12). The swap path never needs the bundle: the payout note is built in Rust.

### 6.2 Wire protocol

JSON strings go over one `WebMessagePort`. The page side is `rl/web/src/index.js:1-58` and the host side is `RailgunProtocol.kt:162-282`.

- **Handshake.**
  1. After `onPageFinished(PAGE_URL)`, the host creates a message channel and posts `WebMessage("vizor-railgun-init", [pagePort])` (`"zapp-railgun-init"` before the iOS MI1 rebuild) to origin `https://railgun.appassets.androidplatform.net` (`RailgunWebViewHost.kt:137-153`).
  2. The page takes only the first port handed over, and only when `event.source === null` and `data === INIT` (`index.js:53-58`).
  3. The page answers `{event:"ready", data:null}`.
  4. The host waits for it for 30 s (`LOAD_TIMEOUT`, `:262`).
- **Envelopes.**
  - Request: `{id: Long, method: String, params: Object}`.
  - Reply: `{id, result}`.
  - Failure: `{id, error: {code: "BAD_REQUEST" | "RPC_FAILED" | "FAILED", message}}`. `BAD_REQUEST` maps to `RailgunException.Protocol`, `RPC_FAILED` (a sync that failed while the Ethereum RPC did not answer or turned requests away, which the page tells from the connection by asking the RPC and a screening node as the sync fails; `rpc-probe.js`, D-153) to `RpcFailed`; anything else maps to `Failed` (`rl/web/src/errors.js`, `RailgunProtocol.kt:251-264`).
  - Event: `{event, data}`.
- **Amounts.** Token amounts are decimal strings (`DecimalSerializer`, `:285-297`).
- **Unreadable messages.** A reply that cannot be decoded still fails its call (`:197-206`). Unknown events are dropped.
- **Methods.** Host timeouts are from `RailgunProtocol.kt:30-58`; handlers from `index.js:8-17`.

| Method | Timeout | Params | Result | JS |
|---|---|---|---|---|
| `start` | 2 min | `{network: "mainnet"\|"sepolia", rpcUrls: [String], poiNodeUrls: [String], debug: Bool}` | `{fees: {unshield: Int bps}}` (the JS also returns `shield`) | `wallet.js:53-88` |
| `openWallet` | 1 min | `{encryptionKey: hex32, mnemonic: String}` | `{address: "0zk…"}` | `wallet.js:91, 96-112` |
| `refresh` | **2 h** | `{}` | `{balances: {"<bucket>": [{token: 0xAddr, amount: dec}]}, received: [{txid, timestamp, token, amount: dec, bucket, sender}] \| null, screening: "ok" \| "failed"}` | `wallet.js` `refresh`, `received.js` |
| `broadcasterFee` | 2 min | `{to: 0zk\|0x, token, amount, broadcaster: B}` | `{fee: dec}` | `transact.js:38-56` |
| `transfer` | 10 min | `{to: 0zk, token, amount, fee, broadcaster: B}` | `{chainId, to, data, value:"0", spends:[{tree, nullifiers:[hex]}], proofMs}` | `transact.js:59-76` |
| `unshield` | 10 min | `{to: 0x, token, amount, fee, broadcaster: B}` | same as `transfer` | `transact.js:79-95` |
| `reverseCost` | 30 s | `{amount, railgun: proxy, fee}` | `{debit, railgunFee}` | `reverse.js:14-20` |
| `prepareReverse` | 10 min | `{amount, railgun, token, calls:[{to,data}]×3, relayAdapt, fee}` | `{to: relayAdapt, data, value, cost:{debit, railgunFee}}` | `reverse.js:22-50` |
| `deleteWallet` | 1 min | `{network: "mainnet"\|"sepolia", mnemonic: String}` | `null` | `wallet.js` (iOS MI1, VI-2): on a fresh page, with only the database open (no network); removes the wallet's record and its decrypted notes. A page that deleted refuses `start`, and one that started refuses `deleteWallet`. |
| `openNewWallet` (debug only) | — | `{encryptionKey, mnemonic, creationBlock}` | `{address}` | `wallet.js:94` |

- **The broadcaster object `B`.** It is `{chainId, railgunProxy, railgunAddress, token, minFee, feePerUnitGas?, maxGasPrice}` (`RailgunProtocol.kt:128-150`).
- **Host checks on a proved send.** `prove()` requires all of the following, or it throws `Protocol` (`RailgunWallet.kt:144-151`):
  - `chainId == broadcaster.chainId`
  - `to == railgunProxy`
  - `value == 0`
  - every spend has nullifiers

  `prepareReverse` requires `to == relayAdapt` and `value == 0` (`:162-171`).
- **Events.**
  - `scan {tree: "utxo"|"txid", status: Started|Updated|Complete|Incomplete, progress: 0..1}`
  - `proof {progress: 0..1, status}`: the prover counts to 100 (`transact.js:133-134`)
  - `log` (debug only)

  The host emits them on a `SharedFlow` (buffer 256, drop oldest) (`RailgunWebViewHost.kt:51-56`).

**The veylor channel contract** (X7). The typed models stay in Dart, so a Swift host can reuse them. Arguments are a `Map`; JSON travels as `String`, never as nested maps, so Kotlin never parses params or results.

`MethodChannel com.zcash.wallet/railgun` (handler `RailgunHostHandler`):

| Method | Args | Result | Notes |
|---|---|---|---|
| `load` | `{proxyPort: int, debug: bool}` | `null` once the page says `ready` | Closes any previous page. Sets the proxy override, waits for its callback (at most 10 s, else `timeout`), then `loadUrl`. `debug` enables content debugging and `log` events (pass `kDebugMode`); Kotlin ANDs it with `BuildConfig.DEBUG`, so a release build never debugs the page. |
| `call` | `{method: String, paramsJson: String}` | `resultJson: String` | `method` must be one of the §6.2 table names except the debug-only `openNewWallet`, which is not exposed (`bad_args`); Kotlin picks the timeout from it. With no open page: `closed`. |
| `close` | — | `null` | Idempotent. Clears the proxy override, also when no page is open (as built, only when this host set one, so a close with nothing to clear does not load the WebView package). |
| `wipe` | — | `null` | `close`, then `WebStorage.getInstance().deleteOrigin(PAGE_ORIGIN)`. |
| `isOpen` | — | `bool` | |

Errors are `PlatformException(code, message)`, mapped from `RailgunException`:

| `code` | From | Dart action |
|---|---|---|
| `closed` | `Disconnected` (page closed, renderer gone, replaced) | reopen lazily on the next use |
| `timeout` | `Timeout` (the page is closed) | as `closed`; a first-sync `refresh` timeout restarts from zero (§6.3) |
| `unavailable` | `Unavailable` (no WebView package, no `PROXY_OVERRIDE`) | show unavailable; do not retry in a loop |
| `protocol` | `Protocol` (`BAD_REQUEST`, unreadable reply) | a bug: log the method only, never params |
| `failed` | `Failed` (engine, chain or POI error) | retry per caller. The message is the engine's own text and can quote a keyed RPC URL (ethers puts request URLs in its errors): never log it, and redact the keyed URL before showing it |
| `rpc_failed` | `RpcFailed` (`RPC_FAILED`: a sync failed while the RPC did not answer, or answered 403 or 429, and a screening node still answered) | as `failed`; the balance says the RPC is not answering and offers another one (`PrivateUsdBalanceState.rpcFailed`, "Change RPC", or "Use the default" with the user's own set) |
| `bad_args` | handler-level argument check | a bug |

A call whose coroutine is cancelled is answered `closed`, so every call gets exactly one answer.

`EventChannel com.zcash.wallet/railgun/events`: each event is the page's raw JSON `{event, data}` as a `String`, forwarded unparsed. Dart decodes `scan` and `proof`; `log` is forwarded only when `debug`. The page also emits `log` without `debug` (a failed screening refresh, `wallet.js:123`), so Kotlin drops page `log` events from a page loaded without `debug`.

- **Threading.** MethodChannel handlers run on the main thread. Launch each `call` in a `CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)` owned by the process singleton, and reply with `result.success`/`result.error` exactly once (a second reply crashes). EventChannel `success` must be called on the main thread: collect the host's `SharedFlow` with `Dispatchers.Main`.
- **Method timeouts are enforced in Kotlin** (the table above). A timeout closes the page.

`MethodChannel com.zcash.wallet/private_usd_attestation` (handler `PrivateUsdAttestationHandler`, M4):

| Method | Args | Result | Errors |
|---|---|---|---|
| `sign` | `{issuerName: String, message: Uint8List}` | `{chain: List<String>, signature: String}`, base64url without padding, leaf first | `KEYSTORE` (any `GeneralSecurityException`/`ProviderException`), `bad_args` |

**What to port and what to reuse.**

- **Reuse** `rl/web/` (source, lockfile and build) and the bundle, rebuilt per E5 and X2. Keep `rl/web/dev/check.mjs` as the desktop smoke test.
- **Port to Kotlin** (`android/app/src/main/kotlin/com/keplr/vizor/railgun/`): `RailgunWebViewHost`, `RailgunChannel` and `RailgunException` with the edits in §8.7 (they are **not** verbatim-portable: Host and Channel use `kotlinx.serialization.json.JsonElement`, which veylor does not have). From `RailgunProtocol`, port only `INIT`, the envelope (`request`, `decode`; `:162-282`) with `org.json`, and the method timeouts (`RailgunMethod`, `:30-58`) as a plain enum. Port `RailgunEndpoints.hosts` (`RailgunModels.kt:28-58`) without its `BuildConfig` keyed-URL fields. `Bech32m`, the typed models, `RailgunWallet` and `RailgunReverseFunding` are not ported to Kotlin.
- **Port to Dart** (`lib/src/features/private_usd/`): the typed models (`RailgunModels`, `RailgunWallet`, `RailgunSession`, `RailgunReverseFunding`); `RailgunEngine` (`ui/common/repository/RailgunEngine.kt`, 127 lines); `RailgunWalletRepository` (196); `PrivateUsdBalanceRepository` (483) and its cache (89).
- **WebView ownership.** Channel handlers are per Activity, but the host must survive Activity recreation. Hold `RailgunWebViewHost` in a process-level singleton built with `applicationContext`, as zapp does (`rl/.../RailgunWallet.kt:25`, an unattached WebView). The per-Activity handler only binds the channel. Close the page in `onDestroy` only when `isFinishing`. As built (M3): the singleton is `RailgunHostHandler.Pages`, which also holds the coroutine scope and the current page. A page therefore outlives its Flutter engine when Android destroys the Activity without finishing it, so the Dart engine wrapper calls `close` once when it starts.

### 6.3 Lifecycle and the engine wrapper

- **Start.** `RailgunWallet.open(network, key32, mnemonic)` (`RailgunWallet.kt:36-66`) loads a fresh page (closing any previous one), then calls `start`, then `openWallet`. The page is closed if any step fails.
- **What `start` does** (`wallet.js:70-88`):
  1. `startRailgunEngine("zapp" /* "vizor" after X2 */, new LevelJS("railgun-<network>"), debug, artifactStore, false, false, poiNodeUrls)`
  2. `setSnarkJSGroth16`
  3. the scan callbacks
  4. `loadProvider({chainId, providers: rpcUrls.map(priority i+1, weight 2)}, network, 15_000 ms polling)`
- **Idempotence.** `start` is idempotent per page and refuses a second network.
- **One wallet per page.** `openWallet` loads by `RailgunWallet.generateID(mnemonic, 0)`, or creates the wallet with **no creation block**. A second, different wallet on the same page is refused (`wallet.js:99-101`), so an account switch needs a page reload.
- **What `refresh` does:**
  1. `refreshBalances` for the notes scan, retried until a scan actually starts: 20 attempts × 3 s, and `Incomplete` throws (`:136-150`)
  2. `refreshReceivePOIsForWallet` and `generatePOIsForWallet`, best effort (`:118-124`)
  3. `getTokenBalancesByBucket` (`:153-161`)
  4. As built: `getWalletTransactionHistory` for the private sends the wallet received (`received.js`: `TransferReceiveERC20s` only, so no shield, deposit, payout or change). The SDK builds it from the notes the scan already decrypted, so it sends no request. `sender` is set only where the sender showed its 0zk address, and `timestamp` is null where the engine has no block time. A history it cannot read gives `null`, and the balances stand.
- **Serialized spends.** `broadcasterFee`, `transfer`, `unshield` and `prepareReverse` run one at a time (`transact.js:24-31`).
- **First sync.** The first sync reads all of Railgun's history (using the `rail-squid.squids.live` quick sync). Its notes phase alone took about 40 minutes on a Galaxy A35 over Wi-Fi, about 60 % of the sync, before the txid batches; the milestone table is at `ui/common/privateusd/PrivateUsdBalanceRepository.kt:436-448, 480-483`. Nothing is kept until it completes, and a timeout restarts it (`RailgunProtocol.kt:39-42`).
- **The engine wrapper** (`ui/common/repository/RailgunEngine.kt`):
  - One use at a time, under a mutex (`:44-56`).
  - The page closes after 10 min idle (`IDLE_CLOSE`, `:113`).
  - The 0zk address is checked against the native one (`:84-95`).
  - `reset()` cancels work, wipes the page origin's storage and forgets the state (`:62-70`).
  - `forget()` runs on a wallet change (`ui/common/repository/RailgunWalletRepository.kt:119-120`).
  - Phases: `UNAVAILABLE, IDLE, STARTING, SYNCING, PROVING, READY, FAILED` (`:86`).

**veylor rules for the engine wrapper** (details in §8.4):

- **Lock:** close the page. It holds the wallet's keys in memory.
- **Background:** stop polling. The idle close takes the page down after 10 minutes. A key-using step never runs in the background (D9).
- **Account switch:** close the page and reopen it lazily for the new active account. Only one wallet is allowed per page.
- **Route change:** close and reopen the page, so Chromium drops pooled connections (§6.8).
- **Account delete:** call `deleteWallet` for that account's wallet id (D15, E5), delete `vizor_railgun_encryption_key_{uuid}` and the balance cache, and close the page if it is open. As built (iOS progress VI-17): `RailgunEngine.deleteWallet` closes any open page, then deletes on a fresh page behind an offline bridge, as one use of the drained engine.
- **Full reset:** call `wipe()`.
- Both deletions are drained by `privateUsdLifecycle` (§8.4).
- **The forward path never needs the page.** The payout note is built in Rust (§3.3). Reverse funding, the balance and sends need it.

### 6.4 Host security

**Security of the host** (`RailgunWebViewHost.kt`):

- **WebView settings** (`:83-95`):
  - JavaScript and DOM storage on
  - `allowFileAccess` and `allowContentAccess` off
  - no `addJavascriptInterface`
  - content debugging only when `debug`
- **Asset loading.** Assets are served by `WebViewAssetLoader` at `https://railgun.appassets.androidplatform.net/assets/railgun/`. The path handler is restricted to the `railgun/` asset dir (`:178-183, 249-256, 278-283`).
- **Request filter.** `shouldInterceptRequest` sends each request one of three ways (`:185-195, 292-304`):
  - own asset
  - allowed (https, default port, host in `RailgunEndpoints.hosts`, or the `blob:`/`data:` schemes)
  - 403
- **Navigation.** All navigation is overridden (`:197-200`).
- **Failure paths.**
  - A failed own-asset load closes the page early (`:229-237`).
  - `onRenderProcessGone` closes the page (`:221-227`).
  - `WebView` construction failure (package missing or updating) becomes `RailgunException.Unavailable` (`:267-273`).
- **The allowlist.** It lives in `rl/.../RailgunModels.kt:28-58`, and the same hosts are repeated in the CSP (`rl/web/src/index.html:5`):
  - `ethereum-rpc.publicnode.com`, `ethereum-sepolia-rpc.publicnode.com`
  - `eth-mainnet.g.alchemy.com`, `eth-sepolia.g.alchemy.com`
  - `mainnet.infura.io`, `sepolia.infura.io`
  - `ppoi.fdi.network` (`POI_NODE_URL = https://ppoi.fdi.network/`)
  - `rail-squid.squids.live`
  - `ipfs-lb.com`
  - `railgun-artifacts.pepeman931.workers.dev`: veylor's mirror of the proving artifacts, the fallback for `ipfs-lb.com` (§6.5; not in zapp)
- **The CSP:** `default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; worker-src blob:; connect-src 'self' <hosts>; base-uri 'none'; form-action 'none'`.
- **WebRTC.** `shims.js:11-14` deletes `RTCPeerConnection`, `webkitRTCPeerConnection` and `RTCDataChannel`, because STUN would bypass both filters.

### 6.5 Storage, artifacts and threading

- **Engine data.** It is in IndexedDB via level-js, in database `railgun-mainnet` or `railgun-sepolia`, under the page origin. It is wiped only by `WebStorage.deleteOrigin(PAGE_ORIGIN)` (`RailgunWebViewHost.kt:77-81, 97-98`).
- **Proving artifacts.** They are downloaded lazily, per circuit variant used. They are brotli files from `https://ipfs-lb.com/ipfs/QmUsmnK4PFc7zDp2cmC4wBZxYLjNyRgWfs5GNcJJ2uLcpU/{circuits/<v>/zkey.br, prover/snarkjs/<v>.wasm.br, circuits/<v>/vkey.json}`. The POI artifacts are under `QmZrP9zaZw2LwErT2yA6VpMWm65UdToQiKj4DtStVsUJHr/POI_{3x3,13x13}/`.
  - Source: `@railgun-community/wallet/dist/services/artifacts/artifact-util.js:9-11, 55-91`.
  - Everything except the vkey is hash-checked against `artifact-v2-hashes.json` (93 variants).
  - **The mirror (veylor, not in zapp; progress D-114).** The SDK hard-codes `ipfs-lb.com`, with no setting and no fallback. Veylor's build (`android/railgun-web/artifact-mirror-plugin.mjs`) sends the downloader's one request through `src/artifact-mirror.js`, which asks `ipfs-lb.com` first and, when that fails (an HTTP error, a network error, or nothing from it for 10 s), asks `https://railgun-artifacts.pepeman931.workers.dev` for the same path. The mirror holds all 279 files (93 variants, three each). The SDK's hash check runs on whatever arrives; a file that fails it is not fetched again from the mirror.
  - They are cached in a separate IndexedDB, `railgun-artifacts` (`rl/web/src/artifacts.js`).
- **Artifact sizes.** Measured by HEAD on 2026-10-13:
  - `01x02/zkey.br`: 3.53 MB
  - `01x02.wasm.br`: 0.89 MB
  - `POI_3x3/zkey.br`: 7.78 MB
  - Larger variants are bigger. **Unverified:** the total for a typical send (U14).
- **Threading.**
  - The WebView lives on the main thread.
  - Port messages are decoded on a `HandlerThread("railgun-page")` (`:59`).
  - Calls suspend on a `CompletableDeferred` with a per-method timeout. A timeout **closes the page** (`RailgunChannel.kt:33-47`, `RailgunWebViewHost.kt:124-133`).
  - snarkjs uses blob Web Workers (`worker-src blob:`).
- **Memory and proof time. Unverified (U14).** Neither is measured in the repo. `transfer`, `unshield` and `prepareReverse` return `proofMs` for logging only.

### 6.6 Balance

**Buckets → display.** Source: `PrivateUsdBalanceRepository.kt:52-125`. Only known tokens count (`PrivateUsdTokens.kt:68-93`): USDC on mainnet; tUSD, USDC and WETH on Sepolia, where WETH is not a dollar.

- `Spendable` → `available`
- `ShieldPending` → `arriving`
- `ShieldBlocked` → `blocked`
- `ProofSubmitted`, `MissingInternalPOI`, `MissingExternalPOI` → `processing`
- `Spent` → ignored
- **headline = `spendable = available + processing`**
- `total` = available + arriving + blocked + processing

Dollar amounts are `amount / 10^decimals` with decimals 6, taken from the table and never from the chain. 1 USDC is treated as $1.

**State and refresh.**

- **State** (`:127-139`): `balances?`, `updatedAt?`, `isRefreshing`, `refreshFailed`, `firstSyncPercent?`.
- **Polling** (`keptFresh`, `:232-246`). A loop every 30 s calls `refresh(maxAge)`:
  - `maxAge = 30 s` while arriving, meaning a pending shield, or a forward payout marked Paid within 2 h whose balance predates it plus 30 s (`isArriving`, `:339-354`)
  - else `maxAge = 5 min`
- **Timeouts.** A refresh times out after 5 min, or 2 h while nothing has been shown yet (`:307-313`).
- **Back-off.** Failures back off 30 s × 2^n, up to 32× (`Retries`, `:317-336`). An explicit `refresh()` ignores the back-off.
- **Shared syncs.** Syncs started by sends, conversions or debugging also update the state, and settle pending sends (`:184-193`).
- **Home only refreshes once Private USD is in use** (`observeIfUsed`, `isInUse` `:248-255`): a non-zero cached balance, any swap history, or any send log. Otherwise the home never starts the WebView or the first sync.
- **Cache.** One encrypted entry, `private_usd_balances_v1` (`PrivateUsdBalanceCache.kt:27-88`), holds `{address, updatedAt ms, buckets}`. It is tied to the 0zk address, shown at once on load, and its failures are ignored.
- **First-sync progress** (`FirstSyncProgress`, `:362-450`). Notes milestones map to 0–60 % with time-based creep between them. Each txid batch then leaves 85 % of the rest, capped at 99 %. It shows on the Private USD screen (`private_usd_first_load_progress`), not on the home.

**What zapp's home shows.**

- **Placement.** The balance card's secondary line reads `<fiat or ZEC> · Private USD $X [+$Y]` (diff of `ui/screen/tabs/view/WalletBalanceCard.kt`, `PrivateUsdAmount`). When there is no fiat line, Private USD gets a line of its own.
- **Amounts.**
  - `$X` is the headline spendable.
  - `+$Y` (accent color) is `arriving`.
  - The amount turns the danger color when `blocked > 0`, with the content description "Needs attention: …".
- **Before a balance is known**, the amount shows "Loading…" while refreshing, else "—" (`ui/screen/privateusd/PrivateUsdText.kt:89-128`).
- **Hidden balances.** The amounts are scrambled like the rest.
- **Tapping** opens Private USD.
- **Conversion banner.** A banner above the card shows an in-flight conversion, `ToUsd` (forward) or `ToZec` (reverse); only one runs at a time (`ObservePrivateUsdConversionUseCase.kt`, the `WalletHomeView.kt` diff).
- **When it is absent.** The whole widget is null when there is no deployment, no Railgun network, or `is_private_usd_available` is false (`ObservePrivateUsdAvailableUseCase.kt:17-30`).
- **What it does not show.** zapp shows **no ZEC equivalent** of the Private USD balance. Its currency is the user's fiat: local per-ZEC price (Zcash SDK exchange rate) ÷ ZEC USD price (NEAR 1-Click asset list), falling back to USD (`ObserveLocalCurrencyUseCase.kt:24-44`).

**Data sources for veylor's home.** Show both USD and ZEC amounts.

| Number | Source | Notes |
|---|---|---|
| Shielded ZEC balance | the existing `syncProvider` balances (Rust `get_balance`) | unchanged |
| ZEC → USD price | `zecHomeUsdUnitPriceProvider` (`lib/src/providers/zec_price_change_provider.dart:359-361`) | CoinGecko `/simple/price?ids=zcash&vs_currencies=usd` (`:113-160`) through `NetworkHttpClient`, which is Tor-aware. It refreshes every 3 min, with a 1 h cached display value (`:14-22`). It is gated by `swapFeatureEnabledProvider` (`:251`), which is mainnet-only; the gate becomes `swapFeatureEnabled || privateUsdAvailable` (X3). Use `zecLiveUsdUnitPriceProvider` (`:366-368`) for anything that computes an amount to spend. |
| Private USD (USD) | the Railgun `refresh` buckets → `spendable` | Show `arriving` and `blocked` as zapp does. veylor shows USD only and has no local-fiat selector, so `LocalCurrency` is not needed. |
| Private USD in ZEC | `spendable / zecUsdPrice` | **Indicative only.** zapp has none, and it is not a conversion quote. Never use a maker quote for display: each `/v1/quote` takes a swap index (`ui/screen/privateusd/convert/PrivateUsdZecQuotes.kt` header). |
| Total in USD (optional) | `shieldedZec × zecUsdPrice + spendable` | Label it as an estimate. Hide it when the price is null (`fiatTextForZatoshi`, `:378-388`). |

### 6.7 Sends and withdrawals (relayer route)

- **The route.** The deployment's relayer sends plain Railgun `transact` calls for a fee note: `zs/docs/railgun-sends.md`.
  1. `GET {relayer}/v1/terms` → `railgunSends {railgunAddress, railgunProxy, token, fee (floor, base units), feePerUnitGas?, feeExpiresAt?, maxGasLimit, maxGasPriceWei, maxCalldataBytes}`
  2. **Pin** the relayer's 0zk, the proxy, the chain and the fee token (`ui/common/privateusd/PrivateUsdRelayer.kt:23-73`, `RailgunSendsPin`)
  3. Get the fee from the page's `broadcasterFee`: the SDK gas estimate × `feePerUnitGas`, or the `fee` floor if that is more. Mainnet's floor is 0.5 USDC (`mainnet-beta.json` `relayerTerms`).
  4. Prove with `transfer` (to a 0zk) or `unshield` (to a 0x address)
  5. `POST {relayer}/v1/railgun/transact {chainId, to, data, value:"0"}` with exactly these four fields, at most 132 KiB
- **Answers** (`of/RailgunSendsClient.kt:43-94`):
  - `200` with `{transactions}`: Sent
  - `409 alreadySpent`: Spent; settle from the chain
  - any other 4xx: Refused; free the notes
  - `503` with `Retry-After`, `500` or a transport failure: Retry with the **same bytes**, waiting no more than 1 h
- **Persistence.** zapp persists the proved bytes before posting, in `PrivateUsdSendLog` (`private_usd_sends_v2`, max 100). It reconciles them on every balance sync (`PrivateUsdSender.kt:269-437`; veylor runs this in Rust, `private_usd_send_settle_all`, §8.2).
- **One outgoing payment at a time.** `PrivateUsdSpendGuard` allows one outgoing payment per wallet, conversions included, across restarts (`PrivateUsdSpendGuard.kt:32-96`).
- **Fees.** Railgun's unshield fee is 25 bps (`RailgunFees`, from the engine; `of/AtomicSwapDriver.kt:297` `RAILGUN_FEE`).
- **Screening caveat.** On Sepolia, Railgun's indexer breaks its verification-hash chain at transaction 4188, which held relayed-send outputs in `MissingExternalPOI` (`railgun-sends.md` "Screening"). The page reads Sepolia's list through our worker `railgun-sepolia-list`, which repairs the chain, so the wallet proves its own sends again (progress D-138).
- **Fee cap (D11).** Refuse a `broadcasterFee` result above 2 USDC (in the fee token's base units) with `send_error_fee_cap`, before proving.
- **veylor storage.** The send log is the `railgun_sends` table in `swaps.db` (§3.4). Persist the proved bytes before posting. Reconcile them on every balance sync. As built (M7 part 1, progress D-90 to D-94): `rust/src/wallet/private_usd/sends.rs` keeps the page's proof (`keep`), posts only kept bytes (`Sends::transact`) and settles from the chain (`Sends::settle_all`); `relayer_client.rs` maps the answers (a `Retry-After` above an hour waits an hour) and pins the terms; `evm_rpc.rs` reads `nullifiers(uint256,bytes32)` through the `SendChain` seam. The Dart half (M7 part 2, progress D-96 to D-98): `services/private_usd_sender.dart` prices, proves, keeps (only while the tap's engine epoch holds) and posts once; `privateUsdSenderProvider` settles on every Railgun sync, on unlock and on an account switch; `services/private_usd_spend_guard.dart` reads the send log across restarts.

### 6.8 Tor bridge (D4, D13)

**Why a bridge.** The WebView cannot use veylor's Tor. veylor's Tor is arti, in process, through `zcash_client_backend`'s `tor` feature, and there is no SOCKS listener in `rust/src/`. The zakura `tor::Client` keeps its `arti_client::TorClient` private (`wl/librustzcash/zcash_client_backend/src/tor.rs:104-106`). Its only stream-opening code is the private `HttpTcpConnector` (`tor/grpc.rs:90-145`) and `one_http_request` (`tor/http.rs:317-338`). Hence the patch.

**The patch (E4, owner's fork, D13).** Add this to `wl/.../zcash_client_backend/src/tor.rs` (~15 lines):

```rust
// wl/librustzcash/zcash_client_backend/src/tor.rs — next to the other re-exports (`pub use arti_client::DormantMode;` at :16)
pub use arti_client::DataStream;

// inside `impl Client` (after `isolated_client`, ~:206)
/// Opens a raw TCP stream to `host:port` through this client's circuits.
/// The name is resolved by the exit, so nothing leaks to local DNS.
pub async fn connect_stream(&self, host: &str, port: u16) -> Result<DataStream, Error> {
    self.ensure_bootstrapped().await?;
    tokio::time::timeout(self.timeouts.connect, self.inner.connect((host, port)))
        .await
        .map_err(|_| Error::Http(http::HttpError::Timeout(http::TimeoutPhase::Connect)))?
        .map_err(Error::from)
}
```

Every name used exists at `391d0b0`: `Timeouts.connect` (`tor.rs:28-40`), `ensure_bootstrapped` (private, same impl), `Error::Http`/`From<arti_client::Error>` (`tor.rs:282`), `HttpError::Timeout(TimeoutPhase::Connect)` (`tor/http.rs:39-46, 442`), and `tokio` is already a dependency under the `tor` feature. `DataStream` implements tokio `AsyncRead`/`AsyncWrite` because the backend enables arti-client's `tokio` feature (`wl/Cargo.toml:184`), so veylor needs no direct `arti-client` dependency for it, only for naming the type (`zcash_client_backend::tor::DataStream` after the patch).

**What exists to build on.**

- `rust/src/tor_update_relay.rs` is a loopback HTTP relay (`TcpListener::bind(127.0.0.1:0)`, `:43-70`). It serves one random-token path and fetches upstream with `tor.http_get`. It is the precedent for a loopback listener with start, stop and a `JoinSet` of connections. It is **not** a CONNECT or SOCKS tunnel: it terminates HTTP and serves only the desktop updater (`rust/src/api/network_privacy.rs:100-108`).
- `tor-socksproto 0.35.0` is in `rust/Cargo.lock` (`:7300`) with its default `proxy-handshake` feature, which gives `SocksProxyHandshake`, a server-side SOCKS4/4a/5 state machine. `arti-client 0.35.0` (`DataStream`, with tokio `AsyncRead`/`AsyncWrite` under its `tokio` feature) is in the lock too. Both are transitive. Neither needs to become direct (M3 task 4); as built, the bridge does not use `SocksProxyHandshake` at all (D-17).

**WebView behaviour** (from androidx source and Chromium docs; verified on a Galaxy A35 with WebView 155 in M0.3):

- `ProxyController.getInstance().setProxyOverride(ProxyConfig, executor, listener)` is gated by `WebViewFeature.PROXY_OVERRIDE`.
- `ProxyConfig.Builder.addProxyRule("[scheme://]host[:port]")` accepts `HTTP`, `HTTPS` or `SOCKS` (default port 1080). Loopback bypasses the proxy implicitly unless `removeImplicitRules()` is called. That does not matter here, because the page fetches only public hosts.
- Chromium maps `socks://` to SOCKS5 and resolves names on the proxy side, so there is no DNS leak. It supports **no SOCKS5 authentication** (Chromium `net/docs/proxy.md`). Use a destination allowlist instead.
- The override is process-wide, for all WebViews. veylor has no other WebView: `url_launcher` is only used with `LaunchMode.externalApplication`.
- zapp pins `ANDROIDX_WEBKIT_VERSION=1.17.1` (`za/gradle.properties:297`).

**Design.** The page is **always proxied**, so the route policy lives in one place.

1. **Rust `rust/src/railgun_bridge.rs`** (as built in M3, from the M0 spike):
   - `start()` resolves the route once, with `tor_client_for_route(true, || false)`, waiting out a bootstrap (up to 3 minutes). `Some(tor)` keeps that isolated client for the whole page session, `None` means direct, and `Err` means no bridge at all (fail closed). Only then does it bind `127.0.0.1:0`.
   - It speaks SOCKS5 with no auth through its own RFC 1928 parser, not `SocksProxyHandshake` (D-17): the bridge needs only a no-auth `CONNECT` to a domain name.
   - Accept only `CONNECT host:443` with a domain name (ATYP 3), where `host` is in `deployment::RAILGUN_PAGE_HOSTS` (§6.4). Refuse everything else: other commands, IP addresses, other ports, and clients that offer only authentication.
   - For each connection, `try_tor_client_for_route(false)` must still match the route the bridge started on:
     - a Tor bridge while Tor is usable → `tor.connect_stream(host, 443)` on the session's isolated client
     - a direct bridge while the route is direct → `tokio::net::TcpStream::connect` under a `DirectRouteLease` (with a tokio `AsyncRead`/`AsyncWrite` impl beside the hyper one), so `begin_tor_enable` aborts it, mid-connect too
     - anything else (a route change, Tor failed) → refuse. Fail closed; the caller restarts the bridge.
   - Then `copy_bidirectional`. Nothing per connection is logged.
   - FRB, in `rust/src/api/network_privacy.rs`: `start_railgun_bridge() -> Result<u16, String>` (idempotent: it returns the running bridge's port) and `stop_railgun_bridge()` (idempotent). Dart: `startRailgunBridge()` → `Future<int>`, `stopRailgunBridge()` → `Future<void>`.
   - The offline kind (iOS progress VI-17): `start_offline_railgun_bridge()` (Dart `startOfflineRailgunBridge()`) starts a bridge that refuses every `CONNECT`, the page's hosts included. It needs no route, so it never waits for Tor; the page an account deletion loads to call `deleteWallet` reaches nothing, yet must load behind its proxy. A bridge keeps its kind: asking for the other stops it first, and `stop_railgun_bridge()` stops either.
2. **Kotlin.** Before loading the page, call `setProxyOverride(ProxyConfig.Builder().addProxyRule("socks://127.0.0.1:$port").build(), …)`, and wait for its listener callback before `loadUrl`. Call `clearProxyOverride` on close and wipe, and whenever the page closes itself (timeout, renderer gone). If `!WebViewFeature.isFeatureSupported(PROXY_OVERRIDE)`, refuse to start the page (`RailgunException.Unavailable`).
3. **Dart.** On every route change (`ref.listen(networkPrivacyProvider…)`), close and reopen the page, so Chromium drops pooled connections. M0.3 showed that Chromium does **not** tear down pooled sockets by itself (U19), so this close and reopen is required.

**Residual risk.** A no-auth loopback proxy is reachable by other apps on the device while the page is open. The destination allowlist limits that to Railgun hosts on port 443, through veylor's route. Android gives ordinary apps no per-UID loopback filter (`ConnectivityManager.getConnectionOwnerUid` is VPN-only).

**Risk rating:** MEDIUM overall. Rust tunnelling is LOW once `connect_stream` exists. The WebView side is MEDIUM until it runs on a device: `PROXY_OVERRIDE` support, SOCKS5 behaviour, keep-alive on a route change, and IndexedDB and `blob:` workers under a proxy. **Unverified:** whether targetSdk 36's cleartext policy affects the WebView's SOCKS hop to `127.0.0.1`. The tunnelled bytes are TLS, so it probably does not. There is no `network_security_config` today.

M0.3 passed all five exit criteria except the transfer proof (plan §4 M0). D4's fallback stays documented in case a later device or WebView version breaks the bridge.

## 7. Config reference

### 7.1 Per-network pins

Source: `ui/common/atomicswap/AtomicSwapMainnet.kt:18-79` and `AtomicSwapTestnet.kt:18-81`, cross-checked with `zs/deployments/mainnet-beta.json`, `sepolia-terms-hash.json`, `sepolia-tokens.json` and `zs/docs/deployment.md`. All values match. The deployment is picked by Zcash network (`ui/common/atomicswap/AtomicSwapDeployment.kt:41-50`): Mainnet → mainnet, Testnet → testnet, anything else → none.

| | Mainnet (beta, deployed 2026-10-12) | Testnet |
|---|---|---|
| Maker URL | `https://zecswap-mainnet.pepeman931.workers.dev/maker` | `https://zecswap-testnet.pepeman931.workers.dev/maker` |
| Relayer URL | `…mainnet…/relayer` | `…testnet…/relayer` |
| Issuer URL / name | `…mainnet…/issuer` / `zecswap-mainnet-issuer` | `…testnet…/issuer` / `zecswap-testnet-issuer` |
| Ethereum chain id | 1 | 11155111 (Sepolia) |
| ZecSwap windows contract (bridging) | `0xeB3A00bcB6c9fF626fE57a5dBbDCf01730e7898f` (block 26250774, `MIN_WINDOW` 3600 s, `LATE_WINDOW` 86400 s; live since 21:21 UTC on 2026-10-22, in place of the lock contract) | `0x459b0a69e0f736666b66a3ffe0fc17c11f05980d` (block 11958709, `MIN_WINDOW` 1800 s, `LATE_WINDOW` 3600 s) |
| Retired lock contracts (their used indices are skipped) | `0x4708D7d36992b7e33Ad97a1ab0A31c3ac6C4fe6D` (block 26178667, `LOCK_DURATION` 1800 s; empty since the switch) | `0xD75Efc6a157CC0A95f66962DA86DDf35d9F2617c` (block 11860526, `LOCK_DURATION` 600 s) |
| The maker's deadlines (its policy, not pinned) | ZEC → USD: `t0` 1.5 h after the open, `t1` an hour after `t0`. USD → ZEC, from the maker's quote: funding within 15 min, `t0` (the ready deadline) 2 h after it, `t1` 3 h after it. Claims, refunds and the maker's reveals go through Flashbots Protect, held claims included. The contract's USDC is the maker's inventory (`balanceOf(maker, USDC)`), moved from the lock contract at the switch | `t0` 45 min after the open, `t1` an hour after `t0`; an unpaid swap is called off 5 min before `t0` |
| Swap token | USDC `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` (`of/SwapDeployment.kt:60`) | test USD `0x64c4a5cb09fe0b706d4cf24dc0a45fff275d727c` (`ZecSwap Test USD`, version `2`, 6 decimals, EIP-3009; Sepolia block 11,944,315; the hosted maker and relayer moved to it at 23:42 UTC on 2026-10-18, for swaps too; the retired one, `0x5764D0044bef5AA839E0dDafE2073421101B9Ed8`, no longer swaps); Circle test USDC is `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` (`PrivateUsdTokens.kt:36-42`) |
| Maker address (only maker accepted) | `0x4370eEaa6bEcf1dAeF21Deeb0379Eb7f6CaEf7eF` | `0x2bac02b5032e9092493814c705f156b49e288922` |
| Relayer address (payouts signed for) | `0xcBcb5f57C79C88a0E4BB450289dE2088958A017F` | `0xd9633572041886fa7584a2e12f36c8c7f1126412` |
| Deposits (M9) | Deposits contract `0xebc7508e20bd4467491ee7e7589d5c7d4c5e8cb6` (block 26,224,004, live since 03:48 UTC on 2026-10-19); the relayer's deposits account `0x6ae40b34c32d3feaa0eef53d7e4724160b7a2135` (not the payouts relayer), sending through Flashbots Protect one at a time; token: USDC above; Multicall3 `0xcA11bde05977b3631167028862bE2a173976CA11` (`deployments/mainnet-deposits.json` on zecSwap's `feature/deposits`) | Deposits contract `0x58324e9a866c9690aca08169d3c67630e84c9019` (block 11,944,316); the relayer's deposits account `0xedc4c88a3f6ae8130a2c18babbabd8100cc1a446` (not the payouts relayer); token: the test USD above; Multicall3 `0xcA11bde05977b3631167028862bE2a173976CA11` (`deployments/sepolia-deposits.json`) |
| Relayer 0zk (send fee note, pinned) | `0zk1qy860uut20m8gd6fnhzvr0zqeyhs0ya5247x7h2eyedxsazx43w5nrv7j6fe3z53l78hn78kmslky2206lm75mclrv7dawd756m2suy7l4zud2m4yhg6kcsn7ed` | `0zk1qy25r4x4qjhtlfe0k9z22jy9psfm83j4k4fgvqs3pmv4he4ytefm8rv7j6fe3z53lltumh8amd66g2axaej92dmjk6mvnuveqtmmwccdm593pft827p4xpwljug` |
| Railgun proxy / Relay Adapt | `0xFA7093CDD9EE6932B4eb2c9e1cde7CE00B1FA4b9` / `0xAc9f360Ae85469B27aEDdEaFC579Ef2d052aD405` | `0xeCFCf3b4eC647c4Ca6D49108b311b7a7C9543fea` / `0x7e3d929EbD5bDC84d02Bd3205c777578f33A214D` (`of/SwapDeployment.kt:40-57`) |
| Issuer `tokenKey` (base64url SPKI, RSA-PSS SHA-384) | full value below (`AtomicSwapMainnet.kt:29-34` = `mainnet-beta.json` `issuer.tokenKey`) | full value below (`AtomicSwapTestnet.kt:30-35` = `sepolia-tokens.json` `tokens.issuerTokenKey`) |
| Maker `tokenReturnKey` | full value below (`AtomicSwapMainnet.kt:35-40` = `issuer.returnKey`) | full value below (`AtomicSwapTestnet.kt:36-41` = `tokens.makerReturnKey`) |
| Zcash confirmations (maker counts a deposit) | 2 | 2 |
| Open / escrow / payout confirmations (Ethereum) | 3 (the default, `of/SwapDeployment.kt:79`) | 2 |
| Min `t0` (`ZcashDepositTerms.minSecondsToT0`) | 15 min | 9 min |
| Default min `t0` / max `t0` | 25 min (`of/SwapTypes.kt:30`) / 2 h (`of/AtomicSwapDeposits.kt:126`) | same |
| Screening time shown | 1 h | 1 min |
| Explorer / Railscan | `https://etherscan.io/tx/`, `https://railscan.io/ethereum/tx/` | `https://sepolia.etherscan.io/tx/`, `https://railscan.io/sepolia/tx/` |
| Keyless RPC (allowlisted) | `https://ethereum-rpc.publicnode.com` | `https://ethereum-sepolia-rpc.publicnode.com` |
| Keyed RPC (build secret, tried first) | `VIZOR_ETHEREUM_RPC_URL_MAINNET` (zapp: `ETHEREUM_RPC_URL_MAINNET`; D3) | `VIZOR_ETHEREUM_RPC_URL_SEPOLIA` |
| POI node | `https://ppoi.fdi.network/` | same |
| Proving artifacts (allowlisted; §6.5) | `https://ipfs-lb.com`, the SDK's gateway; when it fails, veylor's mirror `https://railgun-artifacts.pepeman931.workers.dev` (not in zapp; progress D-114) | same |
| Beta limits (server side) | `maxSwapUsdc` 50, `maxAwaitingDeposit` 20, `spreadBps` 100; relayer fee floor 500000 (0.5 USDC) | `maxAwaitingDeposit` 20 |

**Token keys** (copied 2026-10-13 from zapp and cross-checked equal to the zecSwap records; one line each, no whitespace):

```text
mainnet issuer tokenKey
MIIBUjA9BgkqhkiG9w0BAQowMKANMAsGCWCGSAFlAwQCAqEaMBgGCSqGSIb3DQEBCDALBglghkgBZQMEAgKiAwIBMAOCAQ8AMIIBCgKCAQEAuA8Rq3Fo644QG48Kmxsyg1UFAKd-kfsS9t7BgPVwJqXHIEmlH4gS1UaxDBdu7awf0n9lv7yYozNTE5PysBh01LBhGbcIMWyTSNXkF2l1Mi0AOVVhVJZr-KTyr0u6ZFI2EGRVxT1BF2B4QgzQgJ64xqj-tzX_ctpwYQiE1Gf74zG4Yd0mdEbDjTYhgzoaR0lV5uHHSnVN2fmnlskAkZl6mfrJKfcfivp-UQ8qgBEs-7ke67lMhMyC3BxoDG7qoY0B4eIQRQ_-fu3eYT1RifuO5LgvMYkzRe58X63emOvYls19En0Vbkeq2Y73kMRA2AOYMp5gD3DyF4t5LM535p4-GQIDAQAB
mainnet maker tokenReturnKey
MIIBUjA9BgkqhkiG9w0BAQowMKANMAsGCWCGSAFlAwQCAqEaMBgGCSqGSIb3DQEBCDALBglghkgBZQMEAgKiAwIBMAOCAQ8AMIIBCgKCAQEArte6ewR0iOfbhxrByZ1vj_MMkKiQLQ-2R3OdCyHeKr_G4FrsCHvLhJ0uuu5r-papDogiMb_btM5-nPaOWzC1olxbmEUypJWgz-yCXD3K4wp_jgeqlP7EnlJE3IT5iTwv_S1hK5yV4Fka5mRoyhvZlhvDW3eCWoMix15Fp-TD3AGm7GttqzW4QyLXV_mQcnqlWPwuCacmTYch93eMZ7CaTHHRMmsfqR7_kZdskZh_JM55_lw_puDvvdRtu4vYItvo5wMI5mkwmSEwi6UahZDx_OI8IAF2JpeqRIKwbhT6FVGwahDeu6PRTww71C0i13EOwC3GQ85pxDRIAzF01W14wQIDAQAB
testnet issuer tokenKey
MIIBUjA9BgkqhkiG9w0BAQowMKANMAsGCWCGSAFlAwQCAqEaMBgGCSqGSIb3DQEBCDALBglghkgBZQMEAgKiAwIBMAOCAQ8AMIIBCgKCAQEAqAp6ClskrSdfUjiFvS2H9eTxKKNxrtVPM-n0n8WCgCj508sXiyQj21W9Dpjki-JYLbYS7xkHaTCuplU7-Kg6EFK_xwFB-BmQZcW9qk1GTYcZAqJ5YmfttMFHMDsdroUq5v6RnQxLRINIh5UIiFgn_516Wp2CcizaU-lwuwP4f8hp-0cLvynQ119pUTIfwgaYhrRaxngHFu0JnQF6l4AK4rhtIt6g7AG_bSSV06cYowKuOVEncE45CaUDOUJbP18MfRSP42HPnWZ0-h6n3_uBYvxHYsKp7KQ5_Hr-QpOafUoXhFANv4mfpk3MUQxo2m7vZZAMaFa9ELsIIiaLkACGhQIDAQAB
testnet maker tokenReturnKey
MIIBUjA9BgkqhkiG9w0BAQowMKANMAsGCWCGSAFlAwQCAqEaMBgGCSqGSIb3DQEBCDALBglghkgBZQMEAgKiAwIBMAOCAQ8AMIIBCgKCAQEA5boFzxSM2UDd-NfwWUnT_lVo23Td6wOH5twYjLo2wLDEWmGKSNBgdZy3t3JC2JkzD8j9rVRdehpll_i3GRKmUq0wr6xkHHuHxswr3TehMUqUrztg-nxDS4U2f0V0yYno3I5YPo2SByOz_-jHNWM6Mlx-TZsWzALQTb3NmRXdynqecz3-8hqd_OPhUJtH7M3pK9ikkUbSzV1ofXkyM6FnaNAGkHZ1kAMEF2pGe69tOJJqGq6wpTuZMtzaaxu9t1C4xoR7R7pbdkjPM_Wxd15LoXa1N26V-PToIeD06VmwX51VjrO_2VHWFat4Rtu7eLPeiEX-5kKsyvCY7EhpkNK1DQIDAQAB
```

**Issuer registration (E3).** Mainnet's issuer config today holds only zapp:

- `android.package` = `xyz.justzappit.zapp`
- `uploadKeySha256` = `800c61a4…dfd4`
- `playAppSigningSha256` = `b7807587…3d83` (`mainnet-beta.json` `issuer.android`)

### 7.2 Driver constants (both networks)

- `SIGNATURE_TTL_SECONDS` = 120 (`of/SwapTypes.kt:33`): a `ready` or rescue holds this long
- `REVEAL_MARGIN_SECONDS`, the `CLAIM_MARGIN`, = 300 (`:36`, and `zs/crates/zecswap-client/src/user.rs:24`): a claim goes only while `max(head, device) + 300 s < t1`
- `READY_DEPTH_BLOCKS` = 2: before `t0` a claim goes on a ready only this deep, the port oracle's rule (12 until relayer claims). Veylor reads the swap at `head − 2`.
- `RELAYER_CLAIM_WAIT_SECONDS` = 60 and `RELAYER_CLAIM_WAIT_BLOCKS` = 5: a claim handed to the relayer is the relayer's for this long after its window opens (in blocks for a ready before `t0`); then Veylor, if open, posts it itself (§5.4)
- `MAX_T0_TO_T1_SECONDS` = 2 h: the most a forward swap's `t1` may follow its `t0`; the least is `max(MIN_WINDOW, 600 s)`
- `MAX_HEAD_LAG_SECONDS` = 180 (`freshHead`)
- `ACCEPT_MARGIN_SECONDS` = 15 (`of/AtomicSwapDriver.kt:294`)
- `RAILGUN_FEE` = 25 bps (`:297`)
- quick HTTP timeout 20 s (`of/SwapClients.kt:438`); relayer ticket header `ZecSwap-Ticket` (`:436`)
- the issuer clock skew allowed is 600 s (`of/SwapTokens.kt:344`)

- **Fee cap (D11, X6), not in zapp:** `MAX_RELAYER_FEE = 2_000_000` base units (2 USDC) on both networks. It applies to the forward payout fee, the refund payout fee, the reverse funding fee, the rescue fee and the Railgun send network fee. zapp checks only that the relayer is the pinned one (not the maker), on the pinned chain and contract, and that `fee < amount` (`of/SwapChecks.kt:31-52`). zecSwap's reverse client takes a caller-supplied `max_fee` (`zc/reverse.rs:41, 284`).
- **Mainnet beta limits are enforced by the server.** The UI maps the maker's refusal (`convert_error_amount_refused`, `convert_error_maker_cant_fill`). Do not hard-code `maxSwapUsdc`.

### 7.3 Build defines and secrets

Every knob is a Dart define, read once with `String.fromEnvironment`/`bool.fromEnvironment`. Gradle needs none of them: the Kotlin host gets `rpcUrls` and the proxy port from Dart, and its allowlist is a fixed host list. That avoids a second knob that could disagree, in line with the deep-link rule in AGENTS.md.

| Define | Default | Use |
|---|---|---|
| `VIZOR_PRIVATE_USD_ENABLED` | `false` | Master switch until launch. Release builds turn it on only after M8 sign-off. |
| `VIZOR_ETHEREUM_RPC_URL_MAINNET` | `''` | Keyed RPC (E6). **Secret.** Tried first; publicnode is the fallback for the page. |
| `VIZOR_ETHEREUM_RPC_URL_SEPOLIA` | `''` | As above, for Sepolia. **Secret.** |
| `VIZOR_PRIVATE_USD_FLAG_URL` | `''` | Kill-switch JSON URL (D16, E7). Empty means no fetch, so the feature is available. |
| `VIZOR_SUPPORT_URL` | `''` | Optional support link (D17). |

**The keyed RPC URLs.**

- They are the only secrets. The issuer keys, addresses and URLs are public pins.
- **Their host must be `eth-{mainnet,sepolia}.g.alchemy.com` or `{mainnet,sepolia}.infura.io`.** The page allowlist and CSP admit only those (§6.4); any other provider needs a bundle rebuild and a Kotlin and Rust allowlist change.
- Read them with `String.fromEnvironment` in one place (`private_usd_feature_config.dart`) and treat `''` as unset.
- Pass them with `--dart-define-from-file=<gitignored json>`, so they stay out of shell history and CI logs.
- Dart passes the URL to Rust on each engine call that reads the chain, and to the page's `start.rpcUrls` (keyed first, then publicnode). Rust's engine uses the keyed URL if it is set, else publicnode. Like zapp (`PrivateUsdTokens.kt:59-65`), it does not fall back from a keyed URL to publicnode.
- **Never put the URL in a swap record or a log.** Changing the key must not strand a reverse swap.
- A define sits in plain text in the release binary, like zapp's `BuildConfig`. It is "secret" only from the repo. Use a dedicated, rate-capped key. **Unverified:** whether Alchemy origin allowlisting helps. WebView requests carry `Origin: https://railgun.appassets.androidplatform.net`; Rust requests carry none.

**Bridging off (mainnet).** No define: the pins decide. `private_usd_deployment` returns `bridgeAvailable: false` where no windows contract is pinned (mainnet for now). The app then hides Bridge and the ways to a new bridge, and sends `/private-usd/convert…` to `/private-usd`; Rust refuses quotes and conversions (`Unavailable`). The balance, deposits, sends and withdrawals are unaffected, and a conversion's progress stays reachable.

**Kill-switch semantics (D16).**

- Fetch `{"private_usd_available": bool}` with Dart's `NetworkHttpClient`, which is Tor-aware and fails closed. Use the retries and foreground policy in `lib/src/core/config/swap_feature_config.dart:136-205` (`_kSwapOverrideRetryDelays` `:136`, `swapOverrideProcessWorkPolicyProvider` `:146`). `NetworkHttpClient` has no `get`; call `request('GET', uri, timeout: …)` (`lib/src/core/network/network_http_client.dart`), which returns `NetworkHttpResponse{statusCode, bodyBytes, headers}`.
- Cache the last answer in `SharedPreferences` (`vizor_private_usd_available_v1`).
- Only an explicit `false` disables the feature. A missing key, a parse error or a fetch failure keeps the last known value, defaulting to `true`.
- `false` hides the strip and the entry points. It does **not** stop the engine: the banner and `/private-usd/conversion/...` stay reachable for an unfinished swap, and the loop keeps driving it to completion or refund.

## 8. veylor integration reference

### 8.1 Joint-account and deposit operations (Rust)

Each row is a step zapp performs, and the veylor seam that performs it. "New" means new code in M2. As built (2026-10-13), the joint operations live in `vr/wallet/private_usd/joint.rs` and the proposal halves in `vr/wallet/sync/send.rs`; the plan's M2 tasks give the final signatures, and the progress doc's D-8 to D-14 how they differ from this map.

#### 8.1.1 Operation map

| zapp step | zapp code | veylor seam | Reuse as is? |
|---|---|---|---|
| Joint UFVK and UA | `AtomicSwap.depositAccount(index, makerShare)` → `[UA, UFVK]` (`zs/crates/zecswap-jni/src/ops.rs:190-197`) | `zecswap_core::JointAccount::derive(E, Z, viewing).{unified_address, ufvk}` through path B | new thin wrapper |
| Import, Spending, no derivation, exact birthday, idempotent by UFVK | `ua/JointAccounts.kt:57-75` | `vr/wallet/keys.rs:512` `register_gift_card_observer` shape (`ensure_db_migrated_once` `keys.rs:254`, `open_wallet_db_for_mutation`, `get_account_for_ufvk`), but the observer imports `ViewOnly` with key source `None`; the joint account uses `import_account_ufvk("Private USD joint", ufvk, make_birthday(network, Some(h)), Spending{derivation: None}, Some("vizor-private-usd-joint"))` and, when `get_account_for_ufvk` finds one, requires it to be `Spending` | **new** `register_joint_account(db, network, ufvk, birthday)`; reuse `make_birthday` (`keys.rs:297`, exact and unrounded) |
| Scan until the deposit is visible | `SwapZcashTransactions.synced()` (SDK `syncToTip`, 2 min) | `vr/api/sync.rs:403` `run_payment_link_claim_sync(claim_id, joint_db, lwd, network, allow_resubmit=true)` (a sync FRB wrapper that builds its own runtime; from async engine code call `vr/wallet/sync_engine/mod.rs:2808` directly): an isolated compact-block scan with its own cancel, which **also rebroadcasts the joint DB's pending sweep** (`vr/wallet/sync_engine/mod.rs:2808, 2983-2996`) | yes, as `sync_joint_db(joint_db, lwd, network, cancel)`. `payment_link_resubmit_exclusions` (`vr/wallet/sync/payment_link.rs:223`) is harmless on a joint DB: it excludes only a local send that a deeply mined transaction conflicts with (U7). A DB born above the tip is not scanned yet (U6) |
| Received ≥ N confirmations, and spendable | `JointAccounts.estimate` / `settled` | none | **new** `joint_receipts(joint_db, network, joint_uuid, confirmations)`: received notes and mined heights in the joint DB, with depth counted from the fully scanned height, plus `get_wallet_summary` spendable versus pending under the sweep policy |
| Propose the whole balance, no change | `proposeSweep` fee loop | `build_send_max_proposal` (`vr/wallet/sync/send.rs:4592`) uses `MaxSpendMode::MaxSpendable` (`:4639`) and does not store the proposal | **new** `propose_joint_sweep(joint_db, network, joint_uuid, flow_id, home_ua, max_fee)`: `propose_send_max_transfer(…, &[Orchard, Ironwood], …, MaxSpendMode::Everything, ConfirmationsPolicy(2,2,false))`, as zecSwap's own wallet does (`zs/crates/zecswap-chain/src/zcash/wallet.rs:305-320`). Require one step and `fee ≤ max_fee`. Then reuse the lock-and-store block of `propose_send_with_request` (`send.rs:853-970`), refactored to take a built proposal (`lock_and_store_proposal`). It returns `SwapProposal { proposal_id, needs_sapling_params, fee_zatoshi, amount_zatoshi }`; the sweep's `SweepIntent` takes the amount. |
| PCZT | `createPcztFromProposal` | `create_pczt_from_proposal(joint_db, lwd, network, id, flow)` (`pczt.rs:502`), keyed by db path and checked against the proposal's lock (`:532`) | yes, after §8.1.3: the proposal carries `StoredOvkPolicy::Discard` (D12) |
| Sign with `±(e+z)` | `AtomicSwap.signRefund` / `ReverseAtomicSwap.signReceive`, which run `sign_pczt_bytes(pczt, [key], intent)` | `zecswap_core::sign_pczt` on the **unredacted base** PCZT. It needs the note values and randomness to verify the `SweepIntent` (`zcore/sweep.rs:68-100`), and it ignores proprietary fields such as veylor's lock owner. Then `extract_required_compact_sigs_from_signed_pczt(base, signed)` (`pczt.rs:2367`). | yes, plus glue |
| Prove | `addProofsToPczt` | `add_proofs_to_pczt(base, None, None)` (`pczt.rs:895`; Ironwood proving key, no Sapling) | yes |
| Combine, extract, broadcast, store | `createTransactionFromPczt` (**the SDK stores, then the app sends**) | `store_and_broadcast_pczts_with_compact_signatures_for_proposal(joint_db, lwd, network, id, flow, &[proofs], &[sigs], None, None)` (`pczt.rs:1645`): extract → broadcast → store, and it releases or retains the lock | yes. It is bound only to a `PROPOSAL_STORE` id and a send-flow id, which any propose call creates, and `hardware_authority` is a no-op without transparent inputs (`vr/wallet/sync/hardware_authority.rs:139, 193-195`). Its errors and logs say "Keystone"; cosmetic. |
| Keep the bytes and resend until mined | `keepSending` and the record's `sweep` | `sweep_joint` returns `{txid, raw, expiry_height}`: the bytes the joint DB stored, or, if storing failed, a re-extraction with the same txid. Retries: the claim sync's resubmit, or `broadcast_raw` (`send.rs`, over `broadcast_raw_transaction_isolated`) | small new API |
| Status: Mined, Unmined, Expired, Unknown | `ua/SwapZcashTransactions.kt:98-141` | none | **new** `swap_tx_status(db, network, txid, expiry)`. `Mined` counts its depth from the fully scanned height; `Expired` needs the fully scanned height above the expiry height (zecSwap's `is_expired`); an expiry of 0 never expires. Shared by the main and joint DBs. |
| Delete when mined | `deleteAccount` | `vr/wallet/keys.rs:1033` `delete_account(joint_db, …)`, as `delete_joint_account` | yes |

#### 8.1.2 The deposit (forward step 7), main account → joint UA

- **Proposal.** `propose_send(main_db, network, account, flow, jointUA, depositZat, None)` (`send.rs:790`) proposes one payment.
  - After NU6.3 the first pass is V6. A payment to an Orchard receiver is never downgraded to V5 (`send.rs:4321-4330`).
  - The Orchard-only joint UA should therefore produce an Ironwood output, as on zapp's SDK. Verified offline in veylor in M0.2 (U2); M2's regtest test confirms it end to end.
  - An active Ironwood migration restricts inputs to Ironwood (`send.rs:4218-4227`). That is fine.
  - `ProposalResult` does not expose the step count. Add a one-step check, so the deposit is never several transactions.
- **Recording the txid before broadcast.** `execute_proposal` creates and stores, then broadcasts, in one call (`send.rs:1516-1680`; the broadcast is `broadcast_created_transactions` at `:1677`). The txid is known only after it returns. To match zapp's `prepareDeposit().create()` then `submit`:
  1. Split `execute_stored_proposal` into a create half that returns `{txid, raw, expiryHeight}` and stores the transaction in the main DB. As built: `propose_swap_deposit` (one step, total ≤ the cap) and `create_stored_proposal_transactions`, which returns `Vec<CreatedTransaction>`. If storing succeeds but reading the bytes back fails, it says so; the engine then finds the deposit with `find_deposit`.
  2. The swap engine persists `Kept(tx)`.
  3. It then broadcasts the raw bytes itself (`broadcast_raw`).

  The main wallet sync's `resubmit_pending_transactions` also rebroadcasts it until it is mined or expires. The record must say `deposit = Started` before the create.
- **Never paying twice.** That relies on `findDeposit`: on resume with `Started` and no transaction, search the main DB's non-expired sent transactions for an output to the joint UA (`sent_notes.to_address`; U3, verified offline in M0.2 and by the M2 unit test). As built: `find_deposit(main_db, network, account_uuid, joint_ua)`, which fails closed when a matching deposit has no stored bytes. It also relies on `keepSending` rebuilding only after a proven expiry.
- **Seed.** The deposit needs the active account's seed, so it runs in the foreground only (D9).

#### 8.1.3 Discard OVK for joint sweeps (D12)

**Before M2.**

- `SendPurpose::{Ordinary, PaymentLinkClaim}` (`rust/src/wallet/sync/send.rs:125-144`) maps to `StoredOvkPolicy::{Sender, Discard}`. That is stored on `StoredProposal.ovk_policy` (`rust/src/wallet/sync/mod.rs:584-604`) by `propose_send_with_request` (`send.rs:957`).
- The software execute path honours it (`send.rs:1600`, `stored.ovk_policy.to_ovk_policy()`).
- The PCZT path refuses any `Discard` proposal: `reject_discard_ovk_proposal` (`pczt.rs:101-112`, called at `:519` and, for TEX, `:638`), whose message says Gift Card claims cannot be PCZT-signed. It then passes a literal `OvkPolicy::Sender` to `zcb_create_pczt` (`:586-594`). `create_tex_pczts_from_proposal` (`:623`, OVK at `:696, :832`) also hard-codes `Sender`. It is unaffected, since joint sweeps never produce TEX.
- The test `gift_card_claim_proposal_is_rejected_before_pczt_and_releases_lock` (`pczt.rs:4067`) asserts the refusal.
- Zakura supports `Discard` in PCZT creation: `build_proposed_transaction` maps it to `(None, None)` OVKs (`wl/.../data_api/wallet.rs:1903-1916`), and `create_pczt_from_proposal` forwards `ovk_policy` (`:2626-2680`).

**Change.**

1. Add `SendPurpose::JointSweep`. Its `ovk_policy()` is `StoredOvkPolicy::Discard`, and its `confirmations_policy()` is the §8.1 `ConfirmationsPolicy(2, 2, false)`. Store the **purpose** on `StoredProposal` (new field `purpose: SendPurpose`) next to `ovk_policy`.
2. In `create_pczt_from_proposal`, replace the OVK-based refusal with a purpose-based one: refuse only `SendPurpose::PaymentLinkClaim`, keeping its message. Pass `stored.ovk_policy.to_ovk_policy()` instead of the literal `OvkPolicy::Sender` at `:591`.
3. `propose_joint_sweep` (new, §8.1) creates its proposal with `SendPurpose::JointSweep`. The forward deposit (main account → joint UA) stays `Ordinary`/`Sender`, because the user's own OVK should still recover their outgoing deposit.
4. **Tests.**
   - Keep the PaymentLinkClaim refusal test, keyed on purpose.
   - Add a unit test that a `JointSweep` proposal's PCZT has outputs whose `out_ciphertext` does not decrypt under the joint FVK's OVK (`try_output_recovery_with_ovk` fails).
   - Extend the Ironwood regtest (§10) to assert the same on chain, as `gift_card_claims_at_two_confirmations_and_discards_the_card_ovk` does (`rust/tests/ironwood_regtest_gift_card_claim.rs:27-40`).
5. **Unverified (U8).** `store_and_broadcast_pczts_with_compact_signatures_for_proposal` (`pczt.rs:1645`) stores through `extract_and_store_transaction_from_pczt`, falling back to `decrypt_and_store_transaction` (call at `:2056`; `:1741` is only its `use`). `extract_and_broadcast_pczt` (`:2399`) has a second fallback at `:2478`. With `Discard` the fallback cannot recover sent-output metadata. That is harmless for a joint DB that is deleted after the sweep, but check that the primary path still records the sweep as sent. By reading (M2), it rebuilds sent outputs from the PCZT's own fields and never uses an OVK; M2.7b asserts the sent row.

**As built (M2, 2026-10-13).**

- `SendPurpose::JointSweep` maps to `StoredOvkPolicy::Discard` and `joint_sweep_confirmations_policy()`, `ConfirmationsPolicy(2, 2, false)` (`JOINT_SWEEP_CONFIRMATIONS`, `vr/wallet/mod.rs`). `StoredProposal.purpose` sits next to `ovk_policy`.
- `create_pczt_from_proposal` refuses only `PaymentLinkClaim` (`reject_payment_link_claim_proposal`, message unchanged) and passes `stored.ovk_policy.to_ovk_policy()`.
- `create_tex_pczts_from_proposal` still builds both PCZTs with the sender's OVK, so it keeps refusing every `Discard` proposal: the Gift Card message for claims, a generic one otherwise (D-11).
- Tests: `gift_card_claim_proposal_is_rejected_before_pczt_and_releases_lock` (`pczt.rs`) is keyed on purpose. `a_joint_sweep_pczt_discards_the_joint_ovk` (`vr/wallet/private_usd/tests/joint.rs`) shows a sweep's one output does not recover under the joint OVKs, while an ordinary send's payment from the same account does. librustzcash encrypts change without an OVK even under `Sender`.

#### 8.1.4 Traps

- **Global write lock.** `with_wallet_db_write_lock` is process-global, not per path (`vr/wallet/db.rs:220-245`). Joint-DB scans and writes therefore serialize with main-wallet writes, as Gift Card claims already do.
- **Birthday at the tip.** zecSwap imports at tip + 1, because librustzcash panics on an empty scan range next to a deleted account's ranges (`zs/…/zcash/wallet.rs:451-470`, librustzcash#2301). veylor's claim-sync normalizes ranges (`sync_engine/mod.rs:2865-2868`). Verified for a joint account born above the tip by the M2.7b regtest run, 2026-10-13 (U6). As built, `sync_joint_db` does not scan a `joint.db` whose accounts are all born above the tip: the claim scan's completion checks need a stored tip block (D-10). The tip it compares must be fresh, not the 15 s transaction tip cache, or the block that reaches the birthday is skipped (D-50).

### 8.2 FRB API conventions

- **Registration.** Add `pub mod private_usd;` to `rust/src/api/mod.rs`. `flutter_rust_bridge.yaml` has `rust_input: crate::api,zcash_voting::wire` and `dart_output: lib/src/rust`, so the new file is picked up automatically and generates `lib/src/rust/api/private_usd.dart`. Regenerate with `scripts/generate-rust-bridge.sh` (FRB `=2.11.1`, `rust/Cargo.toml:13`; Dart `flutter_rust_bridge: 2.11.1`). Logic lives in `rust/src/wallet/private_usd/{mod,keys,railgun_keys,evm_rpc,maker_client,relayer_client,tokens,forward,reverse,joint,store}.rs`; `api/` stays thin.
- **Signatures.** Only primitives, `String`, `Vec<u8>` and flat structs (AGENTS.md "Rust API Design Constraint").
  - Per-account calls take `db_path: String, network: String, account_uuid: String`. Key-using calls take `mnemonic_bytes: Vec<u8>`, wrapped at once in `zeroize::Zeroizing` (`api/gift_card_tracking.rs:6-23`; `api/sync.rs:1656-1663`).
  - Calls that sync or broadcast also take `lightwalletd_url: String`, from `rpcEndpointFailoverProvider.current.normalizedLightwalletdUrl`.
  - Re-export wallet structs with `pub use` (`api/gift_card_tracking.rs:3`).
  - Use `#[flutter_rust_bridge::frb(sync)]` only for cheap pure calls (address validation, cancel flags), as in `api/network_privacy.rs:42-99`.
  - **"async" in the table below means a Dart `Future`**, not necessarily a Rust `async fn`. Follow the file you are next to: most of `api/sync.rs` is plain `pub fn` that FRB runs on a worker thread and that builds its own runtime (`:429`); `api/network_privacy.rs` uses `pub async fn` on FRB's tokio runtime. Use plain `pub fn` + `catch` + an inner runtime for the private USD calls, and `pub async fn` only for the bridge start/stop (it spawns a long-lived tokio task).
  - **No data-carrying enums** (no `freezed` in `pubspec.yaml` dependencies; FRB would emit `@freezed` sealed classes). A result such as `Accepted | TokensNeeded | NothingSent(cause)` is a struct `{ kind: ApiAcceptKind, cause: Option<ApiNothingSentCause>, … }` with fieldless enums.
  - **Integer widths.** `u64` becomes Dart `BigInt` (`lib/src/rust/api/sync.dart:202`); `u32`/`i32` become `int`. Use `u32` for indices, counts and `next_poll_ms`, `i64` for unix seconds, and decimal `String` for token amounts. `Option<T>` → `T?`.
- **Errors.** Copy `ApiWalletError` (`api/sync.rs:63-122`): `pub struct ApiPrivateUsdError { code: ApiPrivateUsdErrorCode, message: String }`, with `#[frb(dart_code = "@override String toString() => message;")]`. The codes mirror §5.8's problems plus the pre-send errors: `RelayerUnreachable`, `RelayerRefused`, `RelayerFee`, `EthereumUnreachable`, `RailgunClosed`, `ZcashWallet`, `DepositUnpayable`, `ZcashRejected`, `Mismatch`, `TokensUnreachable`, `TokensRefused`, `TokensDeviceRefused`, `NoTokensToday`, `TokensNeeded`, `Keystore`, `ChainLagging`, `QuoteExpired`, `MakerUnavailable`, `MakerBusy`, `AmountRefused`, `FundingCostChanged`, `DepositUnconfirmed`, `TooLate`, `Busy`, `StoreUnreadable`, `Unavailable`, `RouteBlocked` and `Other`, plus `Cancelled` since M5 (a call stopped by `private_usd_cancel`; never a failure, progress D-32) and `WrongDeployment` (a record, service or node of another deployment, the lock contract's included; never followed). The lock contract's `ClaimTurn` is gone (progress D-137). Dart never branches on message text; `privateUsdErrorMessage(code)` maps them to copy (§9.6). Wrap panics with the `catch` helper (`api/secret.rs:7-21`).
- **Concurrency.** A module-level `OPERATIONS: Mutex<()>` per DB, like `wallet::gift_card_tracking::OPERATIONS` (defined at `rust/src/wallet/gift_card_tracking.rs:8`, taken at `api/gift_card_tracking.rs:14-16`), plus an id-keyed cancel registry like `cancel_payment_link_claim_sync` (`api/sync.rs:545`; registry shape at `:19-20, 414-449`). From M5 also a per-account async driver lock held across network I/O (§5.10 "veylor engine"); `OPERATIONS` never is.
- **Streams.** The swap engine needs none: Dart drives `forward_advance(...) -> ApiForwardAdvance { record, wait?, next_poll_ms, problem? }` from a foreground loop, and polls the sync `private_usd_activity(op_id)` for the in-flight step label. Use `StreamSink<T>` (`crate::frb_generated::StreamSink`; examples at `api/sync.rs:305-346` and `api/ledger.rs:512-545`) only if joint-sync progress is shown. Railgun `scan` and `proof` events come from the Kotlin `EventChannel`, not FRB.
- **Dart conventions.** Riverpod 3 (`flutter_riverpod: ^3.3.1`).
  - Feature providers go in `lib/src/features/private_usd/providers/`. Global lifecycle fences go in `lib/src/providers/` only if `account_provider.dart` imports them (as `public_details_loads_provider.dart` does).
  - Use `NotifierProvider<X, S>(X.new)` and `FutureProvider.family<…, String>` keyed by account UUID, and check `ref.mounted` after awaits.
  - The service-with-registry pattern is `giftCardTrackingServiceProvider` (`gift_card_tracking_provider.dart:76-131`).
  - Persist small per-account state in `AppSecureStore` (`zcash_swap_activities_v1:<uuid>` style) only for the balance cache. Swap records go in the Rust SQLite store (§3.4).

**API surface** (`rust/src/api/private_usd.rs`; flat structs; `ApiPrivateUsdError` on failure). Common parameters:

- `ctx` = `db_path: String, network: String, account_uuid: String, store_dir: String`
- `secret` = `mnemonic_bytes: Vec<u8>`
- `lwd` = `lightwalletd_url: String`
- `rpc` = `eth_rpc_url: String` (the keyed URL, or empty)

| Call | Kind | Milestone | Notes |
|---|---|---|---|
| `private_usd_deployment(network) -> Option<ApiDeployment>` | sync | M1 | All §7.1 pins Dart and Kotlin need (allowlist hosts, proxy, explorer prefixes, confirmations, fee cap). Dart never duplicates config. |
| `private_usd_is_valid_railgun_address(address) -> bool` | sync | M1 | bech32m decode with the `bech32` crate: hrp `0zk`, 73 bytes, version byte 1 (`zecswap-railgun` has only `encode`, and it is `pub(crate)`; zapp's check is `rl/.../RailgunModels.kt:84-89`) |
| `private_usd_cancel(op_id)` | sync | M5 | id-keyed cancel registry |
| `private_usd_account_eligible(ctx) -> bool` | async | M1 | software, has derivation |
| `private_usd_railgun_mnemonic(ctx, secret) -> String` | async | M1 | §3.3 |
| `private_usd_railgun_address(ctx, secret) -> String` | async | M1 | for the address check |
| `start_railgun_bridge() -> Result<u16, String>`, `stop_railgun_bridge()` | `pub async fn` | M3 | §6.8 |
| `private_usd_tokens_issuance_begin`, `…_finish`, `…_status` | async | M4 | §5.9 |
| `private_usd_forward_quote(ctx, secret, lwd, rpc, units) -> ApiForwardQuote` | async | M5 | takes an index; includes the deposit-fee estimate and `max_total_zat` |
| `private_usd_forward_accept(ctx, secret, lwd, rpc, index, max_total_zat) -> ApiAcceptResult` | async | M5 | flat struct: `kind` ∈ `Accepted`, `TokensNeeded`, `NothingSent`, plus `cause: Option<…>` |
| `private_usd_forward_advance(ctx, secret, lwd, rpc, op_id, index) -> ApiForwardAdvance` | async | M5 | `{record, wait?, next_poll_ms, problem?}` |
| `private_usd_forward_abandon(network, account_uuid, store_dir, rpc, index)` | async | M5 | §5.6 step 12; no `db_path` (as built, D-32) |
| `private_usd_forward_records(ctx) -> Vec<ApiForwardRecord>` | async | M5 | history and activity |
| `private_usd_unfinished_count(store_dir, account_uuid) -> u32`, `…_accounts_with_unfinished(store_dir)`, `…_delete_account(store_dir, network, account_uuid)`, `private_usd_activity(op_id)` (sync) | async | M5 | the deletion and reset warning; the D14 loop; cleanup; the in-flight step label |
| `private_usd_reverse_quote`, `…_set_cost`, `…_go_ahead`, `…_accept`, `…_funding_request`, `…_submit_funding`, `…_advance`, `…_authorize_ready`, `…_cancel`, `…_can_rescue`, `…_rescue`, `…_records` | async | M6 | §5.7, §5.8 |
| `private_usd_railgun_sends_terms(network)`, `private_usd_relayer_transact(...)`, `private_usd_send_log_{put,list}`, `private_usd_send_settle_all(...)` | async | M7 | §6.7; as built, D-90 |

**Exact M1–M4 signatures.** The M5–M7 block follows below.

```rust
// rust/src/api/private_usd.rs
use flutter_rust_bridge::frb;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApiPrivateUsdErrorCode { /* the list above */ }

#[frb(dart_code = "
  @override
  String toString() => message;
")]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApiPrivateUsdError { pub code: ApiPrivateUsdErrorCode, pub message: String }

pub struct ApiDeployment {
    pub network: String,              // "mainnet" | "testnet"
    pub railgun_network: String,      // "mainnet" | "sepolia" (page `start.network`)
    pub chain_id: i64,
    pub token: String,                // 0x… lowercase
    pub token_decimals: u32,          // 6
    pub keyless_rpc_url: String,      // publicnode
    pub poi_node_url: String,
    pub railgun_proxy: String,
    pub relay_adapt: String,
    pub relayer_railgun_address: String,
    pub allowed_hosts: Vec<String>,   // §6.4, for display and Dart-side checks of the keyed RPC host
    pub explorer_tx_prefix: String,
    pub railscan_tx_prefix: String,
    pub zcash_confirmations: u32,
    pub escrow_confirmations: u32,
    pub screening_seconds: u32,
    pub max_relayer_fee: String,      // "2000000"
    pub usd_tokens: Vec<ApiUsdToken>, // M3 (D-19): the balance's dollar tokens, swap token first
}
pub struct ApiUsdToken { pub address: String /* 0x lowercase */, pub symbol: String /* "USDC" | "tUSD" */ }

#[frb(sync)] pub fn private_usd_deployment(network: String) -> Option<ApiDeployment>;   // "main" | "test"
#[frb(sync)] pub fn private_usd_is_valid_railgun_address(address: String) -> bool;

/// Software account with ZIP-32 derivation metadata. No secret needed.
pub fn private_usd_account_eligible(db_path: String, network: String, account_uuid: String) -> Result<bool, ApiPrivateUsdError>;
/// Checks the seed fingerprint first (§3.3); `Mismatch` on a wrong seed, `Unavailable` without derivation.
pub fn private_usd_railgun_mnemonic(db_path: String, network: String, account_uuid: String, mnemonic_bytes: Vec<u8>) -> Result<String, ApiPrivateUsdError>;
pub fn private_usd_railgun_address(db_path: String, network: String, account_uuid: String, mnemonic_bytes: Vec<u8>) -> Result<String, ApiPrivateUsdError>;

// M3, in rust/src/api/network_privacy.rs next to the updater relay (as built)
pub async fn start_railgun_bridge() -> Result<u16, String>;  // idempotent: returns the running port; allowlist = deployment::RAILGUN_PAGE_HOSTS
pub async fn stop_railgun_bridge();                          // idempotent

// M4 (as built, D-154). `tokens_path` = `<support>/private_usd_tokens_<network>.json`, from Dart `getPrivateUsdTokenStorePath(network)`;
// `private_usd_forward_accept`, `…_forward_advance`, `…_reverse_accept` and `…_reverse_advance` take it too, after `eth_rpc_url`.
pub struct ApiIssuanceBegin { pub session_id: u64, pub issuer_name: String, pub message: Vec<u8> }
/// `maker_asks`: the maker's `/v1/info` last showed the pinned return key (the review's Tor-off disclosure).
pub struct ApiTokenStatus { pub held: u32, pub exhausted_today: bool, pub awaiting_returns: u32, pub device_refused: bool, pub maker_asks: bool }
/// Reads the maker's `/v1/info` first: no return key, nothing is asked of the issuer (`None`); another key, `TokensRefused`.
/// Then collects the tokens handed back for swaps still awaiting one, and fetches ahead unless a token is held or today is spent.
pub fn private_usd_tokens_issuance_begin(tokens_path: String, network: String) -> Result<Option<ApiIssuanceBegin>, ApiPrivateUsdError>;
/// `chain` and `signature` are passed through exactly as Kotlin returns them (base64url, no padding).
pub enum ApiIssuanceKind { Issued, Exhausted, SignAgain }
/// `SignAgain`: the issuer answered 403 once; `next` is the message of a fresh attestation challenge over the same blinded batch.
/// A second 403 is `Err(TokensDeviceRefused)` and records `refusedBy`.
pub struct ApiIssuanceFinish { pub kind: ApiIssuanceKind, pub next: Option<Vec<u8>>, pub status: ApiTokenStatus }
pub fn private_usd_tokens_issuance_finish(tokens_path: String, network: String, session_id: u64, chain: Vec<String>, signature: String) -> Result<ApiIssuanceFinish, ApiPrivateUsdError>;
pub fn private_usd_tokens_status(tokens_path: String, network: String) -> Result<ApiTokenStatus, ApiPrivateUsdError>;
#[frb(sync)] pub fn private_usd_clear_sessions();   // called on lock. As built it lands in M5: drops the forward offers and maker checks; M4 adds its issuance sessions
```

- Dart reads `db_path` and `network` the way the Gift Card provider does (`ref.read(rpcEndpointFailoverProvider).current.networkName`, `gift_card_tracking_provider.dart:82`; the wallet DB path from `getWalletDbPath()`), and `lightwalletd_url` from `rpcEndpointFailoverProvider.current.normalizedLightwalletdUrl` (the provider is `lib/src/providers/rpc_endpoint_failover_provider.dart:716`; the getter is `lib/src/core/config/rpc_endpoint_config.dart:25`, used at `gift_card_tracking_provider.dart:184`).
- **Three copies of the host allowlist** (§6.4): Rust `deployment::RAILGUN_PAGE_HOSTS` (the 10 hosts, both networks; the bridge uses it), Kotlin `RailgunEndpoints.hosts`, and the CSP in the bundle's `index.html`. The ported `RailgunBoundaryTest` pins Kotlin against the CSP. The Rust unit test `railgun_bridge::tests::the_page_hosts_match_the_kotlin_filter_and_the_page_csp` (M3) pins all three: it reads the string literals of `RailgunEndpoints.kt`'s `setOf(…)` and the `connect-src` of both `android/app/src/main/assets/railgun/index.html` and `android/railgun-web/src/index.html`, so keep the Kotlin hosts literal. Dart refuses a keyed RPC URL whose host is not in `ApiDeployment.allowed_hosts`.

**Exact M5–M7 signatures** (same conventions as M1–M4; every call is `catch` + inner runtime unless marked `sync`). `ctx` expands to `db_path: String, network: String, account_uuid: String, store_dir: String`; `secret` to `mnemonic_bytes: Vec<u8>`; `lwd` to `lightwalletd_url: String`; `rpc` to `eth_rpc_url: String`; `op_id: u32` is allocated by Dart per call (`private_usd_cancel(op_id)` sets its flag). The shorthand is for this doc only; write the parameters out in code. Zatoshi are `u64` (Dart `BigInt`, as `estimate_fee` already is), token amounts decimal `String`, unix seconds `i64` (Dart `int`).

```rust
// ---- shared (M5) ----
// As built (progress D-32): no ApiDirection yet (no call takes one); `Cancelled` joins ApiPrivateUsdErrorCode;
// private_usd_clear_sessions (above) lands here.
pub enum ApiActivity { Depositing, Claiming, PayingOut, Sweeping, Funding, Readying, Refunding }   // zapp AtomicSwapActivity + reverse (M6)
#[frb(sync)] pub fn private_usd_cancel(op_id: u32);
/// The step `op_id` is in right now (zapp's `onActivity`); Dart polls it every 500 ms while an advance is in flight.
#[frb(sync)] pub fn private_usd_activity(op_id: u32) -> Option<ApiActivity>;
/// Unfinished = forward `end == None`, or reverse phase ∉ {QUOTED} ∪ FINISHED. QUOTED drafts do not count.
/// Neither this nor the next call creates swaps.db (0 / empty for a wallet that never converted).
pub fn private_usd_unfinished_count(store_dir: String, account_uuid: String) -> Result<u32, ApiPrivateUsdError>;
/// Every account with an unfinished record (D14 loop input).
pub fn private_usd_accounts_with_unfinished(store_dir: String) -> Result<Vec<String>, ApiPrivateUsdError>;
pub fn private_usd_delete_account(store_dir: String, network: String, account_uuid: String) -> Result<(), ApiPrivateUsdError>; // its joint accounts in store_dir/joint.db, then its swaps.db rows (§8.4); Busy while one of its steps runs

// ---- forward (M5) ----
pub struct ApiForwardQuote {
    pub index: u32, pub expires_at: i64,
    pub amount: String, pub network_cost: Option<String>, pub relayer_fee: String, pub receives: String,
    pub deposit_zat: u64, pub deposit_fee_zat: Option<u64>,   // None = not payable in one transaction now
    pub max_total_zat: Option<u64>,                           // deposit_zat + deposit_fee_zat
    pub fee_expires_at: Option<i64>,
}
/// Takes an index (spent from here, §3.3). Caches the offer in memory under (account, index) until `expires_at`
/// (the forward quote is not persisted; zapp keeps `AtomicSwapOffer` in memory too). `units` = USDC base units (u32, §5.2).
pub fn private_usd_forward_quote(ctx, secret, lwd, rpc, units: u32) -> Result<ApiForwardQuote, ApiPrivateUsdError>;

pub enum ApiAcceptKind { Accepted, TokensNeeded, NothingSent }
pub enum ApiNothingSentCause { QuoteExpired, MakerRefused, MakerUnavailable, NeverOpened, Mismatch, DepositWindowMissed, MakerCancelled }
pub struct ApiAcceptResult { pub kind: ApiAcceptKind, pub cause: Option<ApiNothingSentCause>, pub index: u32 }
/// First call: consumes the cached offer (missing → `QuoteExpired`), saves the record, POSTs accept.
/// Repeat call for the same index (after `TokensNeeded`, or after a thrown timeout/5xx): finds the saved,
/// unanswered record and re-POSTs with `record.quote` (never takes a new index). An `Err` after the save
/// means "maybe opened": Dart must then open the progress route, not the error.
pub fn private_usd_forward_accept(ctx, secret, lwd, rpc, index: u32, max_total_zat: u64) -> Result<ApiAcceptResult, ApiPrivateUsdError>;

pub enum ApiForwardWait { Opening, Confirming, DepositUnsettled, Refunding, ZcashSyncing, Unwinding }   // Unwinding: too late to claim before t1; the maker's refund brings the ZEC back
pub enum ApiForwardOutcome { Paid, Refunded, NothingSent }
pub enum ApiRefundCause { MakerCancelled, NotClaimedInTime }
pub enum ApiForwardPhase { Opening, Depositing, Confirming, Claiming, Refunding, Paid, Refunded, NothingSent }   // as built: the store's phase
pub struct ApiForwardRecord {          // flat view of zapp's record (§5.6); the JSON stays in Rust
    pub index: u32, pub swap_id: String, pub phase: ApiForwardPhase, pub accepted_at: i64, pub quote_expires_at: i64,
    pub deposit_zat: u64, pub max_total_zat: Option<u64>, pub amount: String, pub receives: String, pub relayer_fee: String,
    pub t0: Option<i64>, pub t1: Option<i64>,
    pub late_claim_at: Option<i64>,    // t1 + LATE_WINDOW: the claim goes for good if the maker never refunded; None before the maker answered
    pub deposit_txid: Option<String>,  // internal byte order hex, = TransactionInfo.txidHex (M5 pitfalls); records keep zapp's display hex
    pub deposit_confirmations: Option<u32>,   // as built: only while under way with a deposit kept (0 until mined)
    pub sweep_txid: Option<String>, pub payout_tx: Option<String>,
    pub outcome: Option<ApiForwardOutcome>, pub refund_cause: Option<ApiRefundCause>, pub nothing_sent_cause: Option<ApiNothingSentCause>,
    pub ended_at: Option<i64>,
}
pub struct ApiForwardAdvance {
    pub record: ApiForwardRecord,
    pub wait: Option<ApiForwardWait>,
    pub next_poll_ms: u32,                       // §5.10 naps
    pub problem: Option<ApiPrivateUsdErrorCode>, // the step's failure, folded into the §5.8 problem set; Dart shows it only after 1 min
}
/// One look at the chain, then at most one key-using step (deposit, claim, payout, sweep). Reloads the record
/// from swaps.db; never trusts a Dart copy. Holds the per-account driver lock for its whole duration (`Busy` if taken).
pub fn private_usd_forward_advance(ctx, secret, lwd, rpc, op_id: u32, index: u32) -> Result<ApiForwardAdvance, ApiPrivateUsdError>;
pub fn private_usd_forward_abandon(network: String, account_uuid: String, store_dir: String, eth_rpc_url: String, index: u32) -> Result<ApiForwardRecord, ApiPrivateUsdError>; // §5.6 step 12; `TooLate` if it opened
pub fn private_usd_forward_records(ctx) -> Result<Vec<ApiForwardRecord>, ApiPrivateUsdError>;   // active first, then history newest first

// ---- reverse (M6) ----
// As built (M6 part 1, progress D-79): the calls that need no key take no db_path; `reverse_quote`
// returns the page's `reverseCost` params; `private_usd_reverse_cost_request` is new.
pub enum ApiReversePhase { Quoted, Accepting, AwaitingFunding, SendingUsdc, ConfirmingEscrow, ReceivingZec, AwaitingReady,
                           Settling, Receiving, Complete, RefundWait, Refunding, RefundPayout, Refunded, Cancelled }
pub struct ApiReverseCost { pub debit: String, pub railgun_fee: String, pub broadcaster_fee: String, pub fee_expires_at: Option<i64> }
pub struct ApiReverseRecord {
    pub index: u32, pub swap_id: String, pub phase: ApiReversePhase, pub amount: String, pub network_cost: Option<String>,
    pub deposit_zat: u64, pub quote_expires_at: i64, pub funding_deadline: i64, pub ready_deadline: i64, pub refund_after: i64,
    pub cost: Option<ApiReverseCost>, pub funded: bool, pub funding_tx: Option<String>,
    pub cancel_requested: bool, pub settled: bool, pub cancellable: bool, pub awaiting_user: bool,
    pub receive_estimate_zat: Option<u64>, pub receive_fee_zat: Option<u64>,   // the reviewed sweep: after its fee, and the fee (its cap)
    pub receive_txid: Option<String>, pub received_zat: Option<u64>, pub receive_confirmations: u32,   // receive_txid: internal byte order
    pub accepted_at: Option<i64>, pub updated_at: i64,
}
pub struct ApiReverseAdvance { pub record: ApiReverseRecord, pub next_poll_ms: u32, pub problem: Option<ApiPrivateUsdErrorCode>, pub needs_you: bool }
pub struct ApiReverseCostRequest { pub index: u32, pub amount: String, pub railgun_proxy: String, pub fee: String, pub fee_expires_at: Option<i64> }
pub struct ApiReverseQuote { pub record: ApiReverseRecord, pub cost_request: ApiReverseCostRequest }
/// §5.7 step 1. Saves QUOTED with `cost = None` (replacing any earlier QUOTED draft); `units` whole cents (else `AmountRefused`).
/// `TooLate` if readyDeadline is too near.
pub fn private_usd_reverse_quote(ctx, secret, lwd, rpc, units: u32) -> Result<ApiReverseQuote, ApiPrivateUsdError>;
/// The page's `reverseCost` params now (no key).
pub fn private_usd_reverse_cost_request(network: String, account_uuid: String, store_dir: String, index: u32) -> Result<ApiReverseCostRequest, ApiPrivateUsdError>;
/// After the page's `reverseCost`. Refuses unless QUOTED, or AWAITING_FUNDING with no funding; re-reads the relayer's fee and
/// requires `debit = amount + fee + railgun_fee` (`FundingCostChanged` when the fee moved).
pub fn private_usd_reverse_set_cost(network: String, account_uuid: String, store_dir: String, index: u32, debit: String, railgun_fee: String) -> Result<ApiReverseRecord, ApiPrivateUsdError>;
pub fn private_usd_reverse_go_ahead(network: String, account_uuid: String, store_dir: String, eth_rpc_url: String, index: u32) -> Result<ApiReverseRecord, ApiPrivateUsdError>;
/// Idempotent (zapp `accepted`): POST accept if `!makerAccepted`, then import the joint account. May return `TokensNeeded`.
pub fn private_usd_reverse_accept(ctx, secret, lwd, rpc, index: u32) -> Result<ApiAcceptResult, ApiPrivateUsdError>;
pub struct ApiFundingRequest {          // the page's `prepareReverse` params, ready to JSON-encode
    pub amount: String, pub railgun_proxy: String, pub token: String,
    pub calls_to: Vec<String>, pub calls_data: Vec<String>,   // 3 calls, same order
    pub relay_adapt: String, pub fee: String,
    pub already_funded: bool,           // record.funding != None: skip the page, call advance
}
/// §5.7 step 4.1–4.5: checks (the page's open wallet must be the account's: `railgun_address`), picks the fee (≤ 2 USDC, X6),
/// signs OpenReverse, encodes the calls; holds the request in memory for `submit_funding`.
pub fn private_usd_reverse_funding_request(db_path: String, network: String, account_uuid: String, store_dir: String, mnemonic_bytes: Vec<u8>,
                                           eth_rpc_url: String, index: u32, railgun_address: String) -> Result<ApiFundingRequest, ApiPrivateUsdError>;
/// §5.7 step 4.7–4.11: checks the page result, `FundingCostChanged` (saves the new cost) or saves `funding` + SENDING_USDC, then POSTs.
/// `Cancelled` after a cancel or a lock (the request is gone), `TooLate` when the record changed.
pub fn private_usd_reverse_submit_funding(network: String, account_uuid: String, store_dir: String, eth_rpc_url: String, index: u32,
                                          to: String, data: String, value: String, debit: String, railgun_fee: String) -> Result<ApiReverseRecord, ApiPrivateUsdError>;
pub fn private_usd_reverse_advance(ctx, secret, lwd, rpc, op_id: u32, index: u32) -> Result<ApiReverseAdvance, ApiPrivateUsdError>;
pub fn private_usd_reverse_authorize_ready(ctx, secret, lwd, rpc, index: u32) -> Result<ApiReverseRecord, ApiPrivateUsdError>; // `DepositUnconfirmed`, `TooLate`
pub fn private_usd_reverse_cancel(ctx, secret, lwd, rpc, index: u32) -> Result<ApiReverseRecord, ApiPrivateUsdError>;
pub fn private_usd_reverse_can_rescue(network: String, account_uuid: String, store_dir: String, eth_rpc_url: String, index: u32) -> Result<bool, ApiPrivateUsdError>;
pub fn private_usd_reverse_rescue(db_path: String, network: String, account_uuid: String, store_dir: String, mnemonic_bytes: Vec<u8>,
                                  eth_rpc_url: String, index: u32) -> Result<ApiReverseRecord, ApiPrivateUsdError>;
pub fn private_usd_reverse_records(account_uuid: String, store_dir: String) -> Result<Vec<ApiReverseRecord>, ApiPrivateUsdError>;  // active (incl. QUOTED) first, then history

// ---- sends (M7) ----  As built (progress D-90): no send_log_update or send_log_remove; the proof never returns to Dart.
pub struct ApiRailgunSendsTerms {       // §6.7 step 1, already checked against the pins
    pub chain_id: i64, pub railgun_address: String, pub railgun_proxy: String, pub token: String,
    pub fee_floor: String,                                   // never above max_relayer_fee (else RelayerFee)
    pub fee_per_unit_gas: Option<String>, pub fee_expires_at: Option<i64>,   // both or neither
    pub max_gas_limit: String, pub max_gas_price_wei: String, pub max_calldata_bytes: u32,
}
pub fn private_usd_railgun_sends_terms(network: String) -> Result<ApiRailgunSendsTerms, ApiPrivateUsdError>; // `Unavailable` when absent or not the pinned terms
pub struct ApiProvedSend {               // input of the put
    pub send_id: String, pub token: String, pub amount: String,
    pub fee: String,                     // the broadcasterFee the proof pays, ≤ max_relayer_fee
    pub to: String,                      // 0zk (lowercase) or 0x
    pub proof_json: String,              // the page's transfer/unshield result, unchanged
}
pub enum ApiSendState { Unconfirmed, Confirmed }
pub struct ApiSendRecord {
    pub send_id: String, pub token: String, pub amount: String, pub fee: String, pub to: String, pub withdraw: bool, pub sent_at: i64,
    pub state: ApiSendState, pub tx_hash: Option<String>, pub posted_at: Option<i64>, pub spent_at: Option<i64>, pub retry_at: Option<i64>,
}
/// Keeps a proved send before it is posted (zapp `PrivateUsdSendLog.prove`): checks the proof against the pins
/// (chain, proxy, value 0, nullifiers), the fee cap, and the guard (Busy while another send of the account is
/// unconfirmed or a conversion is under way). The same send kept again returns it; another proof under its id is Mismatch.
pub fn private_usd_send_log_put(store_dir: String, network: String, account_uuid: String, send: ApiProvedSend) -> Result<ApiSendRecord, ApiPrivateUsdError>;
pub fn private_usd_send_log_list(store_dir: String, account_uuid: String) -> Result<Vec<ApiSendRecord>, ApiPrivateUsdError>; // newest first
pub enum ApiTransactKind { Sent, Spent, Refused, Retry }
pub struct ApiTransactResult { pub kind: ApiTransactKind, pub transactions: Vec<String>, pub retry_after_secs: Option<u32> }
/// Posts the stored request bytes for `send_id` (never bytes from Dart) and updates the log row. `Other` when none is kept.
pub fn private_usd_relayer_transact(store_dir: String, network: String, account_uuid: String, send_id: String) -> Result<ApiTransactResult, ApiPrivateUsdError>;
/// `PrivateUsdSender.settleAll` (`up/PrivateUsdSender.kt:294-421`) in Rust: for each `unconfirmed` row, read the receipt
/// (1 confirmation) or the nullifiers (`nullifiers(uint256,bytes32)` = `0xf19ea903` on the proxy), mark confirmed,
/// remove a reverted one, or post the same bytes again once `retry_at` has passed. Returns the rows after the pass.
pub fn private_usd_send_settle_all(store_dir: String, network: String, eth_rpc_url: String, account_uuid: String) -> Result<Vec<ApiSendRecord>, ApiPrivateUsdError>;
```

### 8.3 Home (mobile)

**Where the balance hero lives.** It is all in one file, `lib/src/features/home/screens/mobile/mobile_home_screen.dart`:

- **`MobileHomeScreen.build`** (`:77-137`): top nav, then `_HomeContent`. It watches `privacyModeProvider` (`:83`) and wraps everything in `SwapActivityStatusAutoRefresh`.
- **`_HomeContentState.build`** (`:1027-1327`):
  - It computes `shieldedBalance` (`:1039-1046`).
  - It reads `zecHomeUsdUnitPriceProvider` (`:1051`) and formats fiat with `_mobileHomeFiatTextForZatoshi` (`:1706-1728`).
  - It masks the fiat line with `fixedPrivacyMask()` when hiding balances (`:1056-1059`).
  - It builds the `ListView`, in this order:
    1. the `_BalanceCard` (`:1156-1188`)
    2. the Send / Receive / Pay row (`:1190-1268`)
    3. `_MobileSetupCarousel` (`:1269`)
    4. `_MobileVotingEntry` (`:1270`)
    5. the migration banner (`:1271-1293`)
    6. recent activity (`:1296-1324`)
- **`_BalanceCard`** (`:1733-1925`): a 200 px `colors.background.homeCard` card with the label "Shielded balance", the privacy eye, the fiat line plus the 24 h change, and the serif ZEC amount. Its bottom slot is `_AnimatedMobileTransparentBalanceStrip` (`:1911`, class `:1993`; static strip `_MobileTransparentBalanceStrip` `:2141`). The strip shows "Transparent: X ZEC" with an action button, and masks with `hideAmountIfPrivacyMode` (`lib/src/core/privacy/privacy_mask.dart:19`).
- **The entry-card pattern.** `_MobileHomeEntryCard` (`:1578-1704`) takes `icon`, `title`, `subtitle`, an `emphasized` style, `semanticsLabel` and `onTap`. `_MobileVotingEntry` (`:1383-1513`) shows how such a card refreshes on route return and foreground, using `AppLifecycleListener`, the router listener and `ref.listen(appSecurityProvider…requiresUnlock)`.
- **Hide balances.** `privacyModeProvider` (`lib/src/providers/privacy_mode_provider.dart`) is a plain `bool` notifier seeded from bootstrap. Use `fixedPrivacyMask()` for whole amounts and `hideAmountIfPrivacyMode(text, privacyModeEnabled:)` for labelled amounts.

**The Private USD surface.** It follows zapp's placement and veylor's existing strip.

- **A second strip under the card.** Add a `_MobilePrivateUsdStrip` in `_BalanceCard`'s `Column`, after the transparent strip. It is a single tappable row:
  - `Private USD $X` and `≈ Y ZEC`, plus `+$Z arriving` in the accent colour
  - the danger colour when `blocked > 0`
  - "Loading…" or "—" before the first balance
  - a chevron that opens `/private-usd`

  Pass it in through new optional `_BalanceCard` fields, so the existing card and its widget tests do not change when the feature is off.
- **ZEC equivalent.** It is `spendable / zecHomeUsdUnitPriceProvider`, labelled "≈" and hidden when the price is null (§6.6). Use `zecLiveUsdUnitPriceProvider` (`lib/src/providers/zec_price_change_provider.dart:366`) only for amounts to spend.
- **The price gate.** `ZecHomeMarketDataNotifier.build` returns empty unless `swapFeatureEnabledProvider` is true (`zec_price_change_provider.dart:251`). That provider is mainnet-only (`swap_feature_config.dart:28-30`), so the testnet build gets no price. Change the gate to `swapFeatureEnabled || privateUsdAvailable`.
- **The entry point** is the strip itself, which pushes the Private USD screen holding "Convert", "Send" and "Withdraw". The action row stays Send / Receive / Pay. The in-flight conversion banner (zapp's `ToUsd`/`ToZec`) is a `_MobileHomeEntryCard(emphasized: true)` placed after the action row.
- **When to hide it:** whenever `privateUsdAvailableProvider` is false (below). Before first use the strip still shows "—" and starts no WebView (§9.4 S1). The banner stays while an unfinished swap exists, even when unavailable (D16).
- **New providers.** All go under `lib/src/features/private_usd/providers/`: `privateUsdAvailableProvider`, `privateUsdBalanceProvider(accountUuid)` (the §6.6 state), and `privateUsdConversionBannerProvider(accountUuid)`.
- **Tokens to use.** `colors.background.homeCard`, `colors.text.homeCard`, `colors.text.positiveStrong` / `colors.text.destructive`, `AppSpacing.*`, `AppRadii.large`, `_mobileHomeLabelMStyle`, and `AppIcon` with `AppIcons.*`. A Private USD icon must be added as a design asset (lossless WebP for raster, per AGENTS.md).

**Figma-compare and Widgetbook.**

- **Fixture builder.** Mobile home fixtures are built by `_buildMobileHomeUseCase` (`lib/widgetbook/screen_use_cases.dart:3310`), with public builders such as `buildMobileHomeDefaultUseCase` (`:1652`) registered in `lib/widgetbook/widgetbook_app.dart:520`. Figma scenarios are `FigmaCompareScenario(id:, description:, builder:, desktop: false, mobile: true)` entries in `lib/figma_compare/figma_compare_scenarios.dart` (for example `mobile-home-default`, `:2154-2160`).
- **What the implementer adds:**
  1. A `privateUsd…` override parameter on `_buildMobileHomeUseCase`, so tests can inject a fake balance provider.
  2. Use cases: `buildMobileHomePrivateUsdUseCase`, plus `…Loading`, `…Arriving`, `…Blocked` and `…Hidden`.
  3. The capture scenarios in §9.7.
  4. Widgetbook entries under the home folder and a new `private_usd` folder (§9.7).

  All of them must use deterministic fakes, with no WebView, Rust or network.

**Availability.** `privateUsdAvailableProvider` (`lib/src/features/private_usd/providers/private_usd_available_provider.dart`) is true when all of these hold:

- `VIZOR_PRIVATE_USD_ENABLED` is set
- `kAppFormFactor == AppFormFactor.mobile` (const, so desktop tree-shakes the rest) **and** `defaultTargetPlatform == TargetPlatform.android`. Only Android has the Kotlin host; a mobile-form-factor iOS build would otherwise hit `MissingPluginException`. This is an OS-behaviour check, which AGENTS.md allows; use `defaultTargetPlatform` so widget tests can override it.
- `private_usd_deployment(network) != null` (mainnet or testnet; never regtest)
- the kill switch is not `false` (§7.3)
- the active account is a software account with a ZIP-32 index (`!isKeystoneAccount && !isLedgerAccount`, `account_provider.dart:2788-2792`, and `zip32AccountIndex != null`)

`privateUsdTorBlockedProvider` is true only under D4's fallback (M0.3 no-go) while Tor is enabled. It then disables Convert, Send and Withdraw and shows `tor_unavailable`, but leaves `/private-usd` and the progress routes reachable.

### 8.4 Account lifecycle hooks

**Lock.**

- **The lock paths.** All of them call `appSecurityProvider.notifier.lock()`, which clears the session password (`lib/src/providers/app_security_provider.dart:365-370`), then `accountProvider.notifier.clearSensitiveStateForLock()` (`account_provider.dart:2134`) and `syncProvider.notifier.clearSensitiveStateForLock()` (`sync_provider.dart:2411`). The call sites are:
  - the mobile 15-minute auto-lock, `BackgroundAutoLockHost._lockIfPending` (`lib/src/core/security/background_auto_lock_host.dart:81-98`; it calls `lock()` at `:94`, then `accountProvider.clearSensitiveStateForLock()`, `router.go('/unlock')` and an unawaited `syncProvider.clearSensitiveStateForLock()`)
  - desktop sign-out (`core/layout/app_main_sidebar.dart:419-438`)
  - a failed `restoreAfterUnlock` (`account_provider.dart:2205-2210`)
  - `lost_password_screen.dart:171` and `forgot_passcode_sheet.dart:240`
- **Do not add another call site.** Copy the Gift Card observer pattern (`features/payment_links/providers/gift_card_tracking_provider.dart:76-131`): `ref.listen(appSecurityProvider, (p, n) { if (n.requiresUnlock) engine.pause(); })`, with an `allowed()` predicate of `foreground && !requiresUnlock`.
- **On pause:**
  1. Cancel the Rust swap step (a cancel flag, as `cancel_payment_link_claim_sync` does).
  2. Call `railgunHost.close()`, which drops the page and its in-memory keys.
  3. Clear any Dart-held Railgun mnemonic and the derived public-key caches.
- **Unlock.** The mobile unlock calls `accountNotifier.restoreAfterUnlock()` and then `syncNotifier.refreshAfterUnlock()` (`features/onboarding/mobile/mobile_unlock_screen.dart:235-236`). The engine resumes from its `requiresUnlock` listener; nothing needs to change there.

**Background.** Pause the engine loop (cancel the Rust step, start nothing new, stop balance polling) on `AppLifecycleListener.onHide`/`onPause`, as Gift Card tracking does (`gift_card_tracking_provider.dart:111-123`; its lock listen is `:101-105`). Leave the Railgun page open; the idle timer or the lock closes it (§3.5 item 14). Gate loops with `canRunAppProcessWork(isInForeground:)` (`lib/src/core/layout/app_process_work_policy.dart:10`), which is foreground-only on mobile (D9).

**Account switch.**

- **What switching does.** `switchAccount` → `_switchAccount` (`account_provider.dart:1354-1414`; public wrapper `:1350`) runs under `linuxKeyringCoordinatorProvider.runMutation` (serialized on every platform). It writes the new active UUID and updates state. It drains nothing.
- **The hook.** `ref.listen(accountProvider.select((s) => s.value?.activeAccountUuid), …)`, as `SwapNotifier` does (`swap_state_provider.dart:109-134`).
  - On a change: close the Railgun page (one wallet per page, §6), reset the balance state to the new account's cache, and reopen lazily.
- **The swap loop does not pause on a switch (D14).** `getMnemonicBytesForAccount(uuid)` works for **any** account while unlocked (`account_provider.dart:2815-2820`), so the loop keeps advancing unfinished swaps of non-active accounts, and a switch cannot push a claim past `t0`/`t1`. The Railgun page, the balance and new conversions follow the active account (D6).

**Deletion of one account.**

- **Where.** `removeAccount` → `_removeAccount` (`account_provider.dart:1638-1681`; public wrapper `:1596`) drains each lifecycle in turn: `ledgerOperationLifecycle`, `publicDetailsLoads`, `giftCardTrackingLifecycle`, `paymentLinkClaimLifecycleRegistry`, `votingShareTrackingRegistry`. It resumes them in `finally`. `_removeAccountWithShareTrackingStopped` (`:1683-1843`) then deletes the Rust account (`rust_wallet.deleteAccount`) and the sidecars: mnemonic, swap activity (`:1758-1763`), Gift Card drafts and voting state.
- **Add, in this order:**
  1. **Refuse while unfinished.** Refuse with a typed exception, as `PaymentLinkInFlightClaimsException` does (count `:1691-1693`, throw `:1694-1699`), if the account has an unfinished conversion or a held reverse escrow, unless the user confirmed. Funds may sit in a joint account or escrow that only this seed and index can recover (§3.4). As built (M5, progress D-53): `removeAccount(uuid, confirmedPrivateUsdUnfinishedCount:)` throws `PrivateUsdUnfinishedConversionsException(count)` when more are under way than the user confirmed; it counts **after** the drain, like the Gift Card recheck, so a conversion that started meanwhile is counted, and an unreadable store never blocks. The count shows in the mobile removal sheet (`MobileAccountRemovalSheet` in `mobile_accounts_screen.dart`) and the forgot-passcode sheet; the desktop `accounts_screen.dart` and `settings_uninstall_screen.dart` are desktop-only and Private USD is mobile-only, so they have none.
  2. **Drain.** Add a `privateUsdLifecycleProvider` drained with the others. Model it on `PublicDetailsLoads` (`lib/src/providers/public_details_loads_provider.dart`: `run` / `cancel` / `quiesceAndDrain` / `resume`, register before the first async step) or on `GiftCardTrackingLifecycle` (`features/payment_links/providers/gift_card_tracking_lifecycle_provider.dart`, which fences even before the service is instantiated). Railgun sends hold the same lease until their proved bytes are persisted (§6.7).
     - **Exact place.** `_removeAccount` reads the five lifecycles at `account_provider.dart:1650-1654`, then drains in order `ledgerLifecycle`, `publicLoads`, `_storage.invalidatePendingSecretOperations()`, `giftTracking`, `claimLifecycle`, `shareTracking(accountUuid:)`, and resumes them all in `finally`. Read `privateUsdLifecycleProvider` with the others, `await privateUsd.quiesceAndDrain()` right after `claimLifecycle`, and `privateUsd.resume()` in `finally`. `_resetWallet` has the same order but resumes conditionally (`resetCompleted || restoreAfterFailure`); resume Private USD under the same condition as `claimLifecycle`.
     - `quiesceAndDrain` = stop starting steps, `private_usd_cancel` the in-flight op, await it (bounded, 30 s), close the Railgun page. `resume` = restart the loop if `allowed()`.
     - As built (M5): `PrivateUsdLifecycle` also answers `unfinishedCount(accountUuids)` and runs `deleteAccountConversions(uuid)` (asking again up to three times on `Busy`), over the `PrivateUsdSwapBackend` it is given; builds without the define give none, so desktop never looks.
  3. **Clean up after the Rust delete succeeds** (best-effort, logged, like the other sidecars):
     - `private_usd_delete_account(store_dir, network, uuid)`: its rows in `swaps.db` (§3.4) and its live joint accounts in `joint.db` (through `rust/src/wallet/keys.rs:1033` `delete_account`)
     - delete its Railgun engine key `vizor_railgun_encryption_key_{uuid}`
     - delete its balance cache
     - close the page if this account is open
  4. **Railgun storage.** All accounts share one WebView origin and one IndexedDB per network (`railgun-<network>`). Call the page's `deleteWallet` for this account's wallet id (D15, E5). Until E5 lands, deleting the per-account encryption key alone leaves an unreadable blob (U15). As built (iOS progress VI-17): for an account with a Railgun engine key, `PrivateUsdLifecycle.prepareRailgunWalletDeletion` derives the wallet's mnemonic just before the Rust delete, and `deleteRailgunWallet` deletes the wallet through a fresh page as the deletion's last step, behind an offline bridge (§6.8), best effort and bounded at 2 minutes. A failure leaves the unreadable blob until a reset.
- **Last account.** Removing the last account is a full reset (AGENTS.md), so it goes through the reset path below.

**Full reset.**

- **Where.** `resetWallet` → `_resetWallet` (`account_provider.dart:1873-1912`; public wrapper `:1865`) does the same drains. `_resetWalletWithShareTrackingStopped` (`:1914-2132`) deletes the DB, then, only if `dbDeleted`: the claim wallets, `deleteGiftCardTrackingDirectories()` (`lib/src/core/storage/wallet_paths.dart:171-182`), the companions, the voting caches and `_storage.deleteAll()`. `runWithSyncPausedForWalletReset` wraps all of it (`lib/src/providers/wallet_mutation_guard.dart:167-194`; it sets `resumeAfterMutation: false` and `quiesceVotingWork: true`).
- **Add:**
  - the same unfinished-swap refusal (unlocked only, as the Gift Card refusal at `:1923-1940` is)
  - the `privateUsdLifecycle` drain
  - `deletePrivateUsdDirectories()`: a sibling of `deleteGiftCardTrackingDirectories` that removes every `private_usd_*` directory (`swaps.db` and `joint.db`)
  - `railgunHost.wipe()`, which is `WebStorage.deleteOrigin` plus closing the page
  - `deleteAll()` already removes the secure-storage keys
  - delete the device-wide token store files (X4). Never delete the Keystore attestation key.

**Mutation guard.** `runWithSyncPausedForAccountMutation` (`wallet_mutation_guard.dart:17-45`, body `_runWithSyncPausedForAccountMutation` `:47-165`) pauses foreground sync, Ironwood migration work and optionally voting around imports and deletes. It does **not** pause sends, proposals, claim syncs or the Private USD engine. Joint-DB scans and writes take the process-global `with_wallet_db_write_lock` (§8.1), so they serialize with main-DB writes. The engine still must not start a step while a mutation holds `linuxKeyringCoordinatorProvider.runMutation`. The lifecycle drain covers this.

### 8.5 Network routing

**The route policy (Rust, process-wide).**

- **State.** `rust/src/network_privacy.rs` holds it:
  - `TOR_DESIRED`, `TOR_STATUS` and the `TorClient` slot (`:40-58`)
  - `enable_tor`/`bootstrap_tor` (`:355-448`), via `TorClient::create_with_timeouts(dir, perms, timeouts)` with a 3-minute deadline. The data directory is Dart's `getTorDataDirectoryPath()` (`lib/src/core/storage/wallet_paths.dart:59`).
  - `disable_tor` (`:532`) and `begin_tor_enable` (`:100`), which bumps `DIRECT_ROUTE_EPOCH` and aborts direct I/O
  - `set_tor_dormant` (`:315`), called on app hide and show
- **Getting a client for a request.** Use `tor_client_for_route(isolated, cancelled) -> Result<Option<TorClient>, String>` (`:638`). It returns `Ok(None)` for direct, `Ok(Some(client))` for Tor, and `Err` while Tor is failed or unavailable. It waits out a bootstrap. It **never falls back to clearnet**.
- **Direct I/O.** It must hold a `DirectRouteLease` (`:166-216`), wrapped as `DirectRouteIo<T>` (`:218-301`; implements hyper's `rt::Read`/`Write` and `Connection`), so a switch to Tor aborts it.

**The HTTP opener for the swap engine.**

- **What exists.** There is no generic Rust HTTP opener. App HTTP is split:
  - Dart `NetworkHttpClient` (`lib/src/core/network/network_http_client.dart`) goes direct in Dart, or calls Rust `tor_http_get`/`tor_http_post` when Tor is selected (`rust/src/api/network_privacy.rs:136-204`; isolated circuit per request, cancellable via `tor_http_begin_request`/`tor_http_cancel_request`).
  - In Rust there are two routed HTTP executors. The closer one is the Enhance PIR transport (`rust/src/wallet/sync_engine/enhancement/transport/mod.rs:100-312`; see the recommendation). The other is voting's `VizorRoute` (`rust/src/wallet/voting/route.rs:27-176`):
    1. `tor_client_for_route(true, …)` under the request timeout
    2. `Some(tor)`: `tor.http_get/http_post(uri, headers, body, collect, retry_limit = 0, |_| None)`
    3. `None`: a hyper client over `DirectRouteConnector` (`:235-282`, `HttpConnector` + `DirectRouteLease`)

    It also classifies pre- versus post-dispatch failures (`classify_tor_error`, `:202-230`).
- **Recommendation.** Factor a crate-level `rust/src/wallet/routed_http.rs` from the Enhance PIR transport (`rust/src/wallet/sync_engine/enhancement/transport/mod.rs`, which the list above omits: it is a second routed executor, over HTTPS, with direct TLS through `hyper-rustls`). It exposes:
  - `RoutedHttp::new().send(RoutedRequest{method, url, headers, body: Option<Vec<u8>>, timeout, max_body}, cancelled) -> Result<RoutedResponse{status, headers, body}, RoutedError{phase: BeforeDispatch|AfterDispatch|ResponseRead, message}>` (built in M1; the direct client is pooled per `RoutedHttp` instance)
  - Tor via `tor_client_for_route(true, cancelled)`. **No retries** (§5.2: quotes are single-use, and accepts and relayer posts may have landed).
  - As built: a Tor failure before librustzcash's header callback runs is `BeforeDispatch`; a direct failure is `BeforeDispatch` only for a connect error (the pooled hyper client fuses connecting with sending, so a direct timeout counts as `AfterDispatch`).

  `RoutedError::phase` is exactly the "refused versus unknown" split the driver needs (§5.2). Build it from the Enhance PIR transport (M1 task 10). Then move the PIR transport and voting's `VizorRoute` onto it (M1 task 10b), so veylor keeps one routed executor. For reference, `VizorRoute` implements `zcash_voting`'s `RouteHttp` (`fn execute<'a>(&'a self, request: RouteRequest<'a>, on_dispatch: &'a (dyn Fn() + Send + Sync)) -> RouteFuture<'a>`); its body shows the request fields to mirror: `url`, `method`, `headers`, `body`, `timeout`, `max_response_bytes`.
- **Direct TLS.** As the PIR transport does (`enhancement/transport/mod.rs:107-130`): `HttpsConnectorBuilder::new().with_webpki_roots().https_only().enable_http1().wrap_connector(DirectRouteConnector::new())`, and install the ring `CryptoProvider` once with a `std::sync::Once` (a routed request can be the process's first TLS use, and unit tests never run `init_app`).
- **Body limits.** Enforce `max_body` while reading (`http_body_util::Limited`); relayer and maker answers are small (cap 1 MiB), `eth_getLogs` pages larger (cap 8 MiB).
- **JSON.** `serde_json` is already a dependency (`Cargo.toml:84`). POST bodies use `Content-Type: application/json`, and relayer POSTs add `ZecSwap-Ticket`.
- **Fail-closed behaviour comes for free.** While Tor is bootstrapping the request waits (bounded by the timeout). Failed means a `BeforeDispatch` error. A route switch mid-request aborts direct sockets.

**Ethereum JSON-RPC.**

- **Nothing exists.** veylor has no EVM RPC client: no `eth_*`, alloy or ethers in `rust/src` or `lib/src`. The only EVM code is Dart EIP-55 checksumming (`lib/src/core/crypto/keccak256.dart`).
- **Write `rust/src/wallet/private_usd/evm_rpc.rs`** (about 250 lines) over `routed_request`, with JSON-RPC 2.0 `{jsonrpc, id, method, params}` and one request per call (no batching, since publicnode limits it):
  - `eth_chainId` → must equal the pin (§5.4)
  - `eth_getBlockByNumber("latest", false)` → `{number, timestamp}`
  - `eth_call({to, data}, blockTag)`, for `getSwap(bytes32)` `0x3da0e66e` (at a block number, or pinned to the newest block's hash for a reveal), `MIN_WINDOW()`, `LATE_WINDOW()`, `LOCK_DURATION()` (which must revert), `makerKeyUsed(bytes32)`, `reverseFunding(bytes32)`, `vaultOf(bytes32)`, ERC-20 `balanceOf`, `rescueNonces(bytes32)`, and the proxy `tokenBlocklist(address)` (revert = closed)
  - `eth_getLogs({address, topics:[PaidOut sig, id], fromBlock, toBlock})` in 5,000-block windows
  - `eth_getTransactionReceipt(hash)` for the reverse funding `REVERTED` check
- **ABI.** Fixed 32-byte words; there are no dynamic types in these calls. Encode by hand and decode by slicing (`getSwap` must be exactly 192 bytes). Use `zecswap-core`'s terms hashing and `sha3::Keccak256`.
- **URL.** The keyed URL (a define passed from Dart, §7) first, else publicnode. Never persist it.

**Route changes at runtime.**

- **The toggle.** `NetworkPrivacyNotifier.setTorEnabled` (`lib/src/providers/network_privacy_provider.dart:688-877`) orders it so the saved route is never laxer than the enforced one:
  - **Enable:** a native-updater preflight (`nativeUpdates.setTorEnabled(true)`), then write the preference, then `runtime.beginEnable()`, then drain the Dart direct requests, then `configure(true)`.
  - **Disable:** `nativeUpdates.prepareForTorDisable()`, then `configure(false)`, then write the preference, then `directRequests.allow()`.
  - The state is exposed as `NetworkPrivacyState{torEnabled, status}`.
- **The precedent.** `NetworkPrivacyNativeUpdateCoordinator` (`:214-336`) is the existing "native network stack outside embedded Tor" hook. The Railgun page is one more such stack: on every route change, close and reopen it (§6.8).

### 8.6 Android native

**`MainActivity.kt`** (`android/app/src/main/kotlin/com/keplr/vizor/MainActivity.kt`) is a `FlutterFragmentActivity`.

- **Registration.** All channels are registered in `configureFlutterEngine` (`:97-242`), as `MethodChannel(binaryMessenger, NAME).setMethodCallHandler { call, result -> handler.handle(call, result) }`, and for streams `EventChannel(...).setStreamHandler(handler)` (`LedgerMobileHandler.EVENT_CHANNEL`).
- **Naming.** Channel names use the `com.zcash.wallet/…` prefix (`MainActivity.kt:447-451`; `BiometricUnlockHandler.kt:227`; `LedgerMobileHandler.kt:821-822`). Hence X7's names: `com.zcash.wallet/railgun`, `com.zcash.wallet/railgun/events` and `com.zcash.wallet/private_usd_attestation`.
- **Handler classes.** Each has `fun handle(call, result)` and `companion object { const val CHANNEL }`. `DeviceOwnerAuthHandler.kt` and `BiometricUnlockHandler.kt` (Keystore-bound key) are the closest templates for the attestation handler.
- **Dart wrappers** for channels live in `lib/src/services/*.dart` (for example `biometric_unlock.dart`, `device_owner_auth.dart`) or in `features/<f>/services/` (`ledger_mobile_ble_service.dart`). Put `railgun_host_channel.dart` and `private_usd_attestation.dart` in `lib/src/features/private_usd/services/`.

**`android/app/build.gradle.kts`.**

- **SDK levels.** minSdk 30, targetSdk 36, compileSdk 36 (`:112, 141-142`). Java and Kotlin target 17. Kotlin plugin 2.2.20, AGP 8.11.1 (`android/settings.gradle.kts:22-23`).
- **Dependencies** (`:189-203`): Play review (non-degoogled), Ledger DMK, flowredux and `androidx.biometric`; tests use junit, robolectric and mockito.
- **Add:**
  - `androidx.webkit:webkit:1.17.1`
  - an explicit `org.jetbrains.kotlinx:kotlinx-coroutines-android`. Coroutines are already used (`LedgerMobileHandler`) but arrive only transitively.
  - Use **`org.json`** for the thin host envelope instead of adding the kotlinx-serialization plugin. The typed models stay in Dart (§6).
- **Dart-define decoding.** `dartDefines` (`:15-40`) decodes `-Pdart-defines` for `VIZOR_DEGOOGLED` and `VIZOR_DEEPLINK_BASE_URL`. The keyed RPC URLs do **not** need Gradle (§7: Dart passes `rpcUrls` to Kotlin and to Rust). Keep them Dart-only, as `VIZOR_ETHEREUM_RPC_URL_{MAINNET,SEPOLIA}` via `--dart-define-from-file`.
- **Shrinking.** There is no ProGuard file and no explicit `isMinifyEnabled`. Flutter's Gradle plugin applies its default R8 shrinking to release. **Unverified** whether it is on for this build (U13). The host uses no reflection (no JS interface; `org.json` is platform code), so no keep rules are expected. Verify a release build loads the page.

**`AndroidManifest.xml`.**

- **Permissions:** only `INTERNET`, biometric, camera and Bluetooth. Nothing more is needed for v1 (no foreground service, no notifications, no exact alarms, per D9).
- **Backup.** `allowBackup="false"`. `data_extraction_rules.xml` excluded only `file/tor` from cloud backup and device transfer. M3.3 added an exclusion for the WebView data directory (`domain="root" path="app_webview"`; the path was confirmed on the device in M0, U12), so the encrypted Railgun IndexedDB and its scan cache are not carried to a new device. Without the secure-storage key the data is useless anyway.

**Worker and JNI.** Absent (D9). The only native Rust entry is FRB through cargokit (`rust_builder/cargokit`); the crate is built as `cdylib`/`staticlib`/`rlib` (`rust/Cargo.toml:7`).

**More Android facts** (verified at `4a859bee0`):

- `MainActivity.onDestroy` already exists (`:329-332`, closes the Ledger handler). Add the Railgun handler's unbind there, and close the page only `if (isFinishing)`. Done in M3 (`railgunHostHandler.dispose(isFinishing)`).
- There was no `android/app/src/main/assets/` directory; the M3 bundle copy created it.
- There is no `network_security_config` and no `usesCleartextTraffic`; leave them unset: M0.3 showed that the loopback SOCKS hop needs none.
- Kotlin unit tests have JUnit 4, Robolectric 4.16.1, Mockito and `kotlinx-coroutines-test:1.10.2` (`build.gradle.kts:198-201`), but had **no `kotlin-test`**, which zapp's Railgun tests import (`kotlin.test.*`). M3.3 added `testImplementation("org.jetbrains.kotlin:kotlin-test-junit:2.2.20")` (the Kotlin plugin version, `android/settings.gradle.kts:23`).
- **`org.json` in local unit tests is a stub** that throws "Method … not mocked" on the plain JVM. Run envelope tests with `@RunWith(RobolectricTestRunner::class)`, or add `testImplementation("org.json:json:20240303")`.
- Device-to-device transfer copies everything except `files/tor` (`data_extraction_rules.xml`), including `zcash_wallet.db`. The new `private_usd_*` directories hold no keys, so they need no exclusion; the WebView directory does (U12).

### 8.7 Copy manifest

Run from the veylor repo root. **Never open** `railgun.js` (9.8 MB, minified), the `.wasm` files or `package-lock.json` (329 KB); copy them blind. Every zapp file starts with two SPDX lines (`AGPL-3.0-only`, "The Zapp Contributors"); veylor source files carry no header, so delete them once E2 relicenses the code (until then, nothing here merges).

```sh
ZA=~/dev/zapp/zapp-android; REV=release/4.7.0
K=android/app/src/main/kotlin/com/keplr/vizor/railgun
KT=android/app/src/test/kotlin/com/keplr/vizor/railgun
RLK=railgun-lib/src/main/java/xyz/justzappit/railgun
RLT=railgun-lib/src/test/java/xyz/justzappit/railgun

# 1. JS source, lockfile, build script, stubs, dev tests (node_modules is not tracked)
mkdir -p android/railgun-web
git -C "$ZA" archive "$REV" railgun-lib/web | tar -x --strip-components=2 -C android/railgun-web

# 2. Built bundle (railgun.js, two .wasm, index.html, railgun.js.LEGAL.txt)
mkdir -p android/app/src/main/assets/railgun
git -C "$ZA" archive "$REV" railgun-lib/src/main/assets/railgun | tar -x --strip-components=5 -C android/app/src/main/assets/railgun

# 3. Kotlin host sources (then apply the edits below)
mkdir -p "$K" "$KT"
for f in RailgunWebViewHost RailgunChannel RailgunException RailgunProtocol; do
  git -C "$ZA" show "$REV:$RLK/$f.kt" > "$K/$f.kt"; done
git -C "$ZA" show "$REV:$RLK/RailgunModels.kt" > "$K/RailgunEndpoints.kt"   # trimmed to the hosts object below
for f in RailgunChannelTest RailgunProtocolTest RailgunBoundaryTest; do
  git -C "$ZA" show "$REV:$RLT/$f.kt" > "$KT/$f.kt"; done

# 4. Package rename and header removal on every copied Kotlin file
sed -i '' -e 's/^package xyz\.justzappit\.railgun$/package com.keplr.vizor.railgun/' -e '/^\/\/ SPDX-/d' "$K"/*.kt "$KT"/*.kt

# 5. Keep node_modules out of git
printf '\n# Railgun bundle build\n/android/railgun-web/node_modules/\n' >> .gitignore
```

| Source (`za/`) | Destination | Mode | Edits |
|---|---|---|---|
| `railgun-lib/web/**` (≈380 KB without the lockfile) | `android/railgun-web/` | copy | `build.mjs:8`: `path.resolve('../src/main/assets/railgun')` → `path.resolve('../app/src/main/assets/railgun')`. The build `rm -rf`s that directory, so keep the GPL-3.0 text as `android/railgun-web/COPYING` and add a `copyFile('COPYING', path.join(out, 'COPYING'))` beside `:60`. `dev/check.mjs:16, 18` get the same move: `ASSETS` → `../app/src/main/assets/railgun`, `LOCAL_PROPERTIES` → `../local.properties` (D-15). With E5: `src/wallet.js:25` `WALLET_SOURCE`, `src/index.js:7` `INIT`, and the `deleteWallet` handler. `package.json` `license` → per E2. |
| `railgun-lib/src/main/assets/railgun/*` (11.7 MB) | `android/app/src/main/assets/railgun/` | copy blind | none, besides the GPL-3.0 text added as `COPYING`, as a rebuild would (D-15); it is rebuilt by `npm ci --ignore-scripts && npm run build` in `android/railgun-web` after E5 |
| `$RLK/RailgunException.kt` (37 lines) | `$K/` | copy | package, header |
| `$RLK/RailgunChannel.kt` (67) | `$K/` | copy with edits | `JsonElement` → `String` (raw JSON) for `call` params and result; `onEvent: (RailgunEvent) -> Unit` → `(RailgunProtocol.Message.Event) -> Unit`, the event's name and raw JSON, so the host can drop `log` events (D-16); drop the `kotlinx.serialization` import |
| `$RLK/RailgunWebViewHost.kt` (305) | `$K/` | copy with edits | `JsonElement` → `String`; `MutableSharedFlow<RailgunEvent>` → `MutableSharedFlow<String>`; the console `RailgunEvent.Log(…)` (`:243`) → a `{"event":"log","data":…}` string built with `JSONObject`, emitted only when `debug`; in `Page.load()` set the proxy override and wait for its callback before `loadUrl`, and clear it in `close` (§6.8). Keep `RailgunRequests` (`:278-305`) as is. As built (D-16): `debug` is a `load` parameter, not a constructor one, and page `log` events are dropped unless `debug`. |
| `$RLK/RailgunProtocol.kt` (298) | `$K/` | rewrite down to ~90 lines | keep `INIT` (`:163`; `"zapp-railgun-init"` until the E5 rebuild, it must equal `index.js:7`), `RailgunMethod` as a plain enum of wire name + timeout (`:30-58`), and `request`/`decode` (`:162-282`) over `org.json`: `Message.{Ready, Event(name: String, raw: String), Reply(id, resultJson: String), Failure(id, RailgunException)}`. Drop every serializer, `DecimalSerializer` and `Address`. |
| `$RLK/RailgunModels.kt` (250) | `$K/RailgunEndpoints.kt` | trim | keep only `object RailgunEndpoints` (`:28-58`) minus `SEPOLIA_KEYED_RPC_URL`/`MAINNET_KEYED_RPC_URL` (they read zapp's `BuildConfig`); keep `hosts`. As built: `internal`, the hosts written as literals inside `setOf(…)` (a Rust test reads them, §8.2), and the unused `SEPOLIA_RPC_URL`/`MAINNET_RPC_URL` and `POI_NODE_URL` dropped (Rust's deployment pins the POI node) |
| `$RLK/{RailgunWallet,RailgunReverseFunding,Bech32m}.kt` | — | do not copy | their logic moves to Dart (models, session) and Rust (address check) |
| `$RLT/RailgunChannelTest.kt` (117) | `$KT/` | copy with edits | JSON types → strings; needs `kotlin-test` (§8.6) and `kotlinx-coroutines-test` |
| `$RLT/RailgunProtocolTest.kt` (144) | `$KT/` | copy with edits | delete the two `RailgunAddress` checksum tests; `File("web/src/index.js")` → `File("../railgun-web/src/index.js")` (unit tests run in `android/app`); Robolectric runner for `org.json` |
| `$RLT/RailgunBoundaryTest.kt` (69) | `$KT/` | copy with edits | `web/src/index.html` → `../railgun-web/src/index.html`; `src/main/assets/railgun/index.html` is unchanged; drop `RailgunNetwork` references |
| `$RLT/RailgunSessionTest.kt` (162) | Dart tests | translate | its cases test the typed models, which live in Dart |
| `ua/AtomicSwapAttestation.kt` (157) | `android/app/src/main/kotlin/com/keplr/vizor/PrivateUsdAttestationHandler.kt` | translate (M4) | key code in M4; drop `KeyAttestation`/`AtomicSwapBlockedException` (zapp `offramp-lib` types) |
| `of/*.kt`, `ua/*.kt` driver and store code | `rust/src/wallet/private_usd/*.rs` | translate | never copy; read only the file a task names |
| `ui/common/repository/{RailgunEngine,RailgunWalletRepository}.kt`, `ui/common/privateusd/{PrivateUsdBalanceRepository,PrivateUsdBalanceCache}.kt` | `lib/src/features/private_usd/services/` | translate to Dart | drop Koin, `Flow` → Riverpod notifiers/streams, zapp logging → `debugPrint` guarded by `kDebugMode` |
| `evm-lib/.../hd/{Bip32,Bip85}.kt` | — | do not port | Rust implementation in §3.3 |

**`org.json` traps for the envelope.** `obj.get("result").toString()` drops the quotes of a string result and prints `null` oddly; produce the raw JSON with `when (val r = obj.opt("result")) { is String -> JSONObject.quote(r); JSONObject.NULL, null -> "null"; else -> r.toString() }`. Read `id` with `optLong`, and treat a missing `id` on a non-event as unreadable (zapp fails the call, `RailgunProtocol.kt:197-206`).

**M5–M8 sources** (all "translate": port by reading only the ranges named; nothing here is copied). Read with `git -C ~/dev/zapp/zapp-android show release/4.7.0:<path> | sed -n 'A,Bp'`. Prefixes as in the path table; `oft/` = `za/offramp-lib/src/commonTest/kotlin/xyz/justzappit/offramp/atomicswap/`, `ut/` = `za/ui-lib/src/test/java/co/electriccoin/zcash/ui/`.

| Source (lines total) | Read only | Destination | Milestone |
|---|---|---|---|
| `of/AtomicSwapDriver.kt` (519) | quote 40-54, accept 57-105, advance 108-123, abandon 126-131, step/notOnChain/onChain/open 139-224, finishPaid 227-239, refusal map 241-276, fees 278-297, terms 300-318, `AtomicSwapClaim` 321-460, ending 463-491, `caughtUp`/`freshHead` 494-519 | `forward.rs` | M5 |
| `of/AtomicSwapDeposits.kt` (131) | whole | `forward.rs` | M5 |
| `of/ZcashTransactions.kt` (74) | `keepSending` 53-74 (types 12-51) | `forward.rs`, `reverse.rs` | M5 |
| `of/AtomicSwapSeams.kt` (168) | whole: the seam traits to mirror (`AtomicSwapKeys` 26-71, `AtomicSwapZcash` 79-111, `AtomicSwapStore` 112-120, `AtomicSwapChainReader` 122-162) | `forward.rs` traits | M5 |
| `of/AtomicSwapModels.kt` (293) | record 76-107, deposit/end/outcome/causes 110-191, offer 194-206; serializer 209-293 only if M1 skipped it | `models.rs` | M1/M5 |
| `ua/SwapLoop.kt` (488) | problems 61-95, `run` 211-244, `step` 274-312, `failing` 317-325, constants 331-344, block → hold 424-486 | `private_usd_engine.dart`, `ApiPrivateUsdErrorCode` mapping | M5 |
| `ua/AtomicSwapRepository.kt` (287) | accept 128-145, naps 269-276 | engine | M5 |
| `ua/JointAccounts.kt` (234) | estimate 92-107, build 143-165, proposal + fee loop 167-208 | `joint.rs` (M2), sweep glue | M5 |
| `ua/AtomicSwapZcashInfo.kt` (47) | `depositFee` 12-25 | `deposit_fee` | M5 |
| `pu/convert/PrivateUsdZecQuotes.kt` (83) | whole | `private_usd_zec_quote_search.dart` | M5 |
| `pu/PrivateUsdConversions.kt` (89) | whole (debounce, `showConversionUnderWay` 37-51, zatoshi 74-82) | convert provider | M5 |
| `pu/convert/PrivateUsdConvertVM.kt` (319) | state 128-214, quoting 216-255, confirm 257-297, back 299-314 | convert provider | M5 |
| `pu/progress/PrivateUsdProgressVM.kt` (169) / `PrivateUsdProgressSteps.kt` (300) | VM 82-158; steps only for §9.5 rows you cannot place | conversion provider, status mapper | M5 |
| `pu/PrivateUsdActivityMapper.kt` (269), `pu/PrivateUsdConversionBanner.kt` (124) | rows table in S2 suffices; open only to settle an ambiguity | activity, banner | M5 |
| `of/ReverseSwapDriver.kt` (621) | quote 46-91, goAhead 94-103, advance 105-119, fund 122-144, ready 147-157, cancel 159-182, rescue/locked 185-195, accepted 198-207, deadlines 209-246, approvals 271-311, stages 314-363, outbox 366-374, opening 377-475, receiving 483-559, code map 575-612 | `reverse.rs` | M6 |
| `of/ReverseSwapRefunds.kt` (164), `of/ReverseSwapVerifier.kt` (81), `of/ReverseFundingSubmission.kt` (70), `of/ReverseFundingCalls.kt` (49) | whole | `reverse.rs`, `funding_calls.rs` | M6 |
| `of/ReverseFundingTerms.kt` (93), `of/ReverseSwapSeams.kt` (131) | 41-86; seams whole | `reverse.rs` | M6 |
| `of/ReverseSwapModels.kt` (237) | phases 29-45, cost/funding/receive 49-118, record 120-213, `FINISHED` 236 | `models.rs` | M1/M6 |
| `ua/ReverseSwapRepository.kt` (193), `ua/ReverseSwapFundingImpl.kt` (118) | 95-129; funding impl whole | `private_usd_reverse_funding.dart` | M6 |
| `pu/reverse/PrivateUsdReverseVM.kt` (382), `PrivateUsdReverseMapper.kt` (200), `PrivateUsdReverseRefundRequest.kt` (73) | VM 145-348; mapper 74-200; refund request whole | convert and conversion providers | M6 |
| `pu/refunds/PrivateUsdRefundsVM.kt` (234) | 65-206 | refunds provider | M6 |
| `up/PrivateUsdSender.kt` (486) | types 41-111, `RelayedPrivateUsdSender` 115-207, settlement 269-437 | `private_usd_sender.dart`; settlement → Rust `sends.rs` | M7 |
| `up/PrivateUsdSpendGuard.kt` (96), `up/PrivateUsdSendChain.kt` (60) | whole | `private_usd_spend_guard.dart`; `evm_rpc.rs` | M7 |
| `up/PrivateUsdSendLog.kt` (206) | records 26-118, log ops 146-200 | `sends.rs` | M7 |
| `up/PrivateUsdRelayer.kt` (80), `of/RailgunSendsClient.kt` (95) | pin 23-73; answers 21-86 | `relayer_client.rs` | M7 |
| `pu/send/PrivateUsdSendVM.kt` (410), `PrivateUsdSendForm.kt` (231) | VM 115-361; form whole | send provider | M7 |

**Tests to translate** (★ = must port; the rest are optional). Line numbers are the test functions.

| File (lines) | ★ cases | Destination |
|---|---|---|
| `oft/AtomicSwapDriverTest.kt` (447) | 21 happy path, 55 offer after fees, 114 quote about to run out, 214 maybe-opened accept waits then gives up, 242/255/266/284/298 deposit never paid twice, 398 terms off by one, 428 silent maker claimed after `t0` | `forward.rs` tests |
| `oft/AtomicSwapClaimTest.kt` (469) | 19-131 refund branches, 161-214 reveal margin, 225-271 fee rise and re-sign, 311 claim revealed before interruption, 385/397 accept code map | `forward.rs` tests |
| `oft/AtomicSwapSettlementTest.kt` (193) | 17-82 reveal margin, 124 orphaned payout | `forward.rs` tests |
| `oft/ReverseSwapDriverTest.kt` (399) | 47 happy path, 145 partial deposits, 183 interrupted funding reuses tx, 200 duplicate callbacks, 215 restart never authorizes ready, 338 cancellation reveal margin, 359 after-ready refund, 382 pending ready not resent after cancel | `reverse.rs` tests |
| `oft/ReverseSwapRefundTest.kt` (431) | 99 refund payout failure + rescue, 171 funding never seen sent again, 202 refund secret with lagging node, 220 receive resumes same bytes, 305 earlier refund rescuable with a newer preview | `reverse.rs` tests |
| `oft/ReverseSwapRevealTest.kt` (61), `oft/ReverseFundingTest.kt` (217) | all; 24 late response keeps cancel, 43 retain proof across restart, 64 timeout then lands, 95 never resubmitted after deadline | `reverse.rs` tests |
| `oft/AtomicSwapDriverFixtures.kt` (416), `oft/ReverseSwapDriverFixtures.kt` (467) | do not port as files. Read the fakes you need: forward `FakeChain` 159-229, `FakeKeys` 230-272, `FakeZcash` 274-335, `FakeStore` 337-350, constants 352-413; reverse knobs 26-98, overrides 137-357 | `rust/src/wallet/private_usd/tests/fakes.rs` (fake `ChainReader`, `HttpTransport` routing by path, Zcash ops, in-memory store) |
| `oft/SwapClientsTest.kt` (510) | 228, 355, 382 (Railgun sends answers) | `relayer_client.rs` tests (M7) |
| `ut/common/atomicswap/SwapLoopTest.kt` (457) | 58 retry says why once, 77 asks once, 155 nudge cuts nap, 186 cancellation is not failure, 281 reverse asks approval once | `test/features/private_usd/private_usd_engine_test.dart` |
| `ut/common/atomicswap/JointAccountsTest.kt` (230), `SweepProposalTest.kt` (78) | 97, 112; all three sweep cases | `joint.rs` tests |
| `ut/common/privateusd/PrivateUsdSpendGuardTest.kt` (139), `PrivateUsdSendLogTest.kt` (147), `RelayedPrivateUsdSenderTest.kt` (412) | all; 52, 98; 63, 92, 104, 132, 180, 274 | Dart guard and sender tests; Rust `sends.rs` tests for the log and settlement |
| `ut/screen/privateusd/convert/PrivateUsdZecQuotesTest.kt` (158), `PrivateUsdConvertVMTest.kt` (467), `reverse/PrivateUsdReverseVMTest.kt` (458), `send/PrivateUsdSendFormTest.kt` (146), `send/PrivateUsdSendVMTest.kt` (399) | quotes all; VM tests: only the button-enable, back and expiry cases | `test/features/private_usd/…` (providers untagged; widgets `@Tags(['mobile'])`) |

## 9. UI reference

Read from zapp at `60bcf0b30` and veylor at `4a859bee0`. **No Figma exists for this feature in veylor.** Nothing in `lib/`, `test/`, `lib/figma_compare/`, `lib/widgetbook/` or `FIGMA-AI-FIX.md` mentions Private USD or Railgun. Build it from veylor's existing tokens and widgets. The Widgetbook fixtures and capture scenarios (§9.7) are for self-review and regression.

### 9.1 Rules that differ from zapp

1. **Send and Withdraw are two buttons, two routes, one screen.** `60bcf0b30` deleted zapp's send/withdraw toggle. The mode is fixed by the button that opened the screen (`pu/send/PrivateUsdSendState.kt:48`; `pu/PrivateUsdView.kt:307-323`).
2. **Every quote spends a swap index, in both directions.** The forward amount step may make up to 4 maker quotes per typed amount: one $1 price probe, plus up to 3 refinements (`pu/convert/PrivateUsdZecQuotes.kt:35-47, 75-80`). The reverse step makes one per amount. The 700 ms typing debounce (`pu/PrivateUsdConversions.kt:27`) is therefore load-bearing (X10).
3. **The forward amount is total ZEC, network fee included** (`pu/convert/PrivateUsdConvertState.kt:17`; `str:305`). The quote search finds the largest quote whose `depositZat + feeZat` fits. The reverse amount is in dollars, with 2 decimals (`common/privateusd/PrivateUsdAmounts.kt:36, 49`).
4. **No app-lock prompt before spends (D18).** zapp prompts before convert, fund, ready, cancel, rescue and send (`pu/PrivateUsdAuthentication.kt:11-20`). veylor adds confirmation sheets for cancel, request refund and rescue instead.
5. **The banner survives the kill switch (D16).** zapp hides it when unavailable (`ObservePrivateUsdSummaryUseCase` returns `null`). veylor keeps the banner and the progress route for an unfinished swap.
6. **No notifications, no notification-permission prompt (D9).** zapp prompts before review (`pu/convert/PrivateUsdConvertView.kt:31-35`, `pu/reverse/PrivateUsdReverseView.kt:39-43`). Every "Zapp keeps going in the background" line becomes "keep Veylor open" copy (`F` rows in §9.6).
7. **USD only.** Drop the local-currency toggle, the `≈ local` lines and their strings. Show `≈ Y ZEC` where zapp shows the local amount (X3).
8. **Follow veylor's patterns in these places:**

| Topic | zapp | veylor (follow this) |
|---|---|---|
| Steps | one route with in-screen phases (amount ⇄ review; form → review → sending → done) | separate `CupertinoPage` routes per step, with state in a Riverpod notifier, as send (`/send`, `/send/amount`, `/send/review`, `/send/status`, `lib/src/core/navigation/mobile_routes.dart:189-280`) and swap/pay (`/swap/review`, `/pay/review`) do |
| Back | to the Pay tab | pop the stack. As built (M5, progress D-54): accept pops the review with the conversion's route, and the convert screen replaces itself with progress (`pushReplacement`), so back from progress lands on `/private-usd`. |
| Quote expiry | "Quote refreshes in", then "Get a new quote" | "Quote expires in m:ss" divider, "Quote expired", and a "Refresh quote" primary (`features/pay/widgets/mobile/mobile_pay_review_content.dart:155-206` `_QuoteExpiryDivider`, labels in `MobilePayReviewActions` `:229-260`). The divider has no timer: the caller passes `expiresInText` (computed in `features/swap/screens/mobile/mobile_swap_review_screen.dart:124`); the convert provider's 1 s tick supplies it. Stale notice text as in `mobile_swap_review_content.dart:113-117`. As built (M5): "Refresh quote" asks again on the review itself (same size first) and the review keeps the new quote; the countdown runs to 20 s before expiry, when the quote stops being offered. |
| Errors | a danger caption in the scaffold | an inline warning notice with icon and destructive text (the private `_MobileReviewNotice`, `mobile_swap_review_content.dart:257-287`; lift it to `core/widgets/mobile/`) |
| Progress | a `ZappStepList` | `MobileSwapStatusContent` (`features/swap/widgets/mobile/mobile_swap_status_content.dart:35`) with progress and details tabs, fed a `SwapActivityStatusPresentation` whose `steps` use `SwapStatusStepData{title, state, completeTitle, activeTitle, pendingTitle, description}` (`features/swap/models/swap_status_presentation.dart:3-47`) and whose badge is a `SwapStatusBadgeKind` (`liveQuote`, `completed`, `refunded`, `warning`, `failed`). The details tab carries the Etherscan and Railscan links through `SwapStatusDetailRowData.linkUri` (`:49-61`). |
| Send in flight / done | an in-screen proving bar | `MobileTransactionProgressScreen` (`core/widgets/mobile/mobile_transaction_progress_screen.dart:30`; phases `inProgress`, `pending`, `succeeded`, `failed`, `:12`). Put the proof percentage in `body` ("Proving your transaction · 42%"). `pending` = `Unconfirmed`. |
| Info "i" | `ZappInfoSheet` | a `MobileTopNav.back(trailing: info button)` (`core/layout/mobile/mobile_top_nav.dart:78`) opening `showAppMobileSheet` (`core/layout/mobile/app_mobile_sheet.dart:41`) with `MobileBottomSafeArea(bottomPadding:)` (`mobile_bottom_safe_area.dart:21`). The body pattern is `showMobileTxFeeInfoSheet` (`core/widgets/mobile/mobile_tx_fee_info_sheet.dart:11`). |
| Spend auth | app-lock prompt | none (D18). Confirmation sheets for cancel, request refund and rescue. |
| Currency | local fiat | USD only, plus `≈ ZEC` |
| Notifications | yes | none in v1 |

### 9.2 Routes, screens, providers and reuse

**Module.** Build a new feature, `lib/src/features/private_usd/`, with `models/`, `providers/`, `services/`, `screens/mobile/` and `widgets/mobile/`. Do not extend `SwapNotifier`: veylor's swap UI is tied to NEAR models. `MobileSwapComposerTicket` and `MobilePayAmountStep` take a `SwapState`, and `MobileSwapReviewContent` takes a `SwapQuote`. Reuse only the presentational pieces. Keep Private USD out of the Swap screen, whose Home button (a tab until 2026-10-19) disappears whenever NEAR is disabled.

**Routes.** All routes are mobile-tree `CupertinoPage`s over the shell, next to `/pay` in `lib/src/core/navigation/mobile_routes.dart` (`/pay` at `:339`). Route arguments go through `state.extra`, with a `redirect` back when the extra has the wrong type (`:289-297`). Titles are sentence case.

**Reuse.**

| Need | Reuse | Notes |
|---|---|---|
| Amount entry | `DecimalAmountInputFormatter` (`core/widgets/decimal_amount_input_formatter.dart:6`), `MobileNumericKeyboardToolbar` (`core/widgets/mobile/mobile_numeric_keyboard_toolbar.dart:10`), and the serif amount styles | Build `MobilePrivateUsdAmountStep`, modelled on `MobilePayAmountStep`'s layout (actions pinned above the keyboard), not on its `SwapState`. |
| Review | `MobileSwapReviewHeader` (`swap/widgets/mobile/mobile_swap_review_header.dart:47`) with `MobileSwapReviewHeaderRow` (`:10`), using the existing `SwapAsset.zec` / `SwapAsset.usdc` consts (`swap/domain/swap_asset.dart:39,49`); `ReviewWrapCard`, `ReviewInfoRow`, `MobileReviewInfoRow`, `ReviewButtonsStack` (`core/widgets/…`) | Rows: receive, relayer fee (refused above 2 USDC, D11), Railgun 0.25 %, deposit + Zcash fee, `t0` deadline. |
| Submitting or proving | `MobileTransactionProgressScreen` (`core/widgets/mobile/mobile_transaction_progress_screen.dart:30`; "caller owns execution, copy, navigation") | Use it for "Proving…" (`proof` events) and "Sending…". |
| Swap progress or receipt | `MobileSwapStatusContent` (`swap/widgets/mobile/mobile_swap_status_content.dart:35`) fed with a `SwapActivityStatusPresentation` (`swap/models/swap_activity_status_mapper.dart:67`; steps `SwapStatusStepData`) | Write a `privateUsdStatusPresentation(record)` mapper from the Rust phase or stage. This keeps the timeline UI single-sourced. |
| Sheets | `showAppMobileSheet` (`core/layout/mobile/app_mobile_sheet.dart:41`), with bodies wrapped in `MobileBottomSafeArea(bottomPadding:)` | Use for refunds, fee info and "needs you" prompts. |
| Recipient input (send/withdraw) | the `address_scan` widgets (`features/address_scan/widgets/{address_qr_scan_modal,mobile_address_scan_card}.dart`), and the EVM EIP-55 check in `features/address_book/models/address_format_validator.dart` (`_isEvmAddress`, `:125`, **private**; the public `addressFormatCheck` `:52` returns address-book copy) using `core/crypto/keccak256.dart` | Add a public `isValidEvmAddress(String)` wrapper (M7 pitfalls). `0zk` needs a new bech32m validator: the sync FRB call `private_usd_is_valid_railgun_address` (M1, §8.2). |
| History | add `privateUsdActivityRowItemsProvider(uuid)` and merge it where `swapItems` are merged: inline in `mobile_home_screen.dart:1076-1134` and `features/activity/screens/mobile/mobile_activity_screen.dart:270-300` (there is no shared merged provider) | Drop main-DB rows whose `txidHex` is a record's deposit or sweep txid (internal byte order, M5 pitfalls). `matchSwapActivityLegAbsorption` (`features/activity/swap_activity_row_mapper.dart:447`) is NEAR-intent-keyed; write a small txid-set filter instead. |

**Routes, screens and providers.** Screens go in `lib/src/features/private_usd/screens/mobile/`, widgets in `widgets/mobile/`, and providers in `providers/`.

| zapp | Route | Screen widget (file) | Provider(s) read | Form |
|---|---|---|---|---|
| 1, 2 | home (no route) | `_MobilePrivateUsdStrip` and the banner via `_MobileHomeEntryCard(emphasized:)` in `features/home/screens/mobile/mobile_home_screen.dart` (§8.3) | `privateUsdAvailableProvider`, `privateUsdBalanceProvider(uuid)`, `privateUsdConversionBannerProvider(uuid)`, `zecHomeUsdUnitPriceProvider`, `privacyModeProvider` | inline |
| 3 | `/private-usd` | `MobilePrivateUsdScreen` (`mobile_private_usd_screen.dart`) | `privateUsdBalanceProvider(uuid)`, `privateUsdConversionBannerProvider(uuid)`, `privateUsdActivityProvider(uuid)`, `privateUsdSpendStatusProvider(uuid)`, `privateUsdReceiveAddressProvider(uuid)` | full screen |
| 4, 5 amount | `/private-usd/convert` (`?to=zec` for reverse; the toggle replaces the query in place) | `MobilePrivateUsdConvertScreen` (`mobile_private_usd_convert_screen.dart`), layout modelled on `MobilePayAmountStep` with `MobileNumericKeyboardToolbar` and `DecimalAmountInputFormatter` (reuse table above) | `privateUsdConvertProvider` (a `Notifier`: direction, amount, quote, step, error; debounce; expiry tick), `syncProvider` (shielded spendable, sync %), `privateUsdBalanceProvider(uuid)` | full screen |
| 4, 5 review | `/private-usd/convert/review` (redirect to `/private-usd/convert` without a ready quote, as `/swap/keystone-sign` does at `mobile_routes.dart:289-297`) | `MobilePrivateUsdConvertReviewScreen`, using `MobileSwapReviewHeader` with a new `SwapAsset`-like `privateUsd` row (the USDC icon plus a private badge asset), `ReviewWrapCard`, `ReviewInfoRow`/`MobileReviewInfoRow`, `ReviewButtonsStack` | `privateUsdConvertProvider`, `networkPrivacyProvider` (Tor-off disclosure) | full screen |
| 6, 7 | `/private-usd/conversion/:direction/:index` (`forward`/`reverse`) | `MobilePrivateUsdConversionScreen`, with `MobileSwapStatusContent` and a `privateUsdStatusPresentation(record)` mapper (reuse table above) implementing §9.5 | `privateUsdConversionProvider((uuid, direction, index))`, driven by the foreground engine loop (§8.2 `forward_advance`/`reverse_advance`) | full screen |
| 8 | `/private-usd/refunds` | `MobilePrivateUsdRefundsScreen` with `MobileListRow` rows | `privateUsdRefundsProvider(uuid)` (15 s re-check loop while visible) | full screen |
| 9 form | `/private-usd/send`, `/private-usd/withdraw` | `MobilePrivateUsdSendScreen(mode:)`. The address field reuses `MobileTextField` (`core/widgets/mobile_text_field.dart`) with paste, and optionally the `address_scan` QR modal (reuse table above). 0zk validation is a sync FRB call; 0x validation reuses `_isEvmAddress` (`features/address_book/models/address_format_validator.dart:125`) plus a zero-address check. | `privateUsdSendProvider(mode)`, `privateUsdBalanceProvider(uuid)`, `privateUsdSpendStatusProvider(uuid)` | full screen |
| 9 review | `/private-usd/send/review`, `/private-usd/withdraw/review` | `MobilePrivateUsdSendReviewScreen` | `privateUsdSendProvider(mode)` | full screen |
| 9 sending/done | `/private-usd/send/status` (`extra`: mode) | `MobilePrivateUsdSendStatusScreen` wrapping `MobileTransactionProgressScreen` | `privateUsdSendProvider(mode)`, proof events from `railgun_host_channel.dart` | full screen |
| 10 | none | `showPrivateUsdInfoSheet(context, info)` | none | sheet |
| new | none | `showPrivateUsdBlockedInfoSheet` ("Screening refused" help), `showPrivateUsdCancelConfirmSheet`, `showPrivateUsdRescueConfirmSheet` | none | sheet |

**Guards** (in `appRedirect`, `lib/app.dart:650-731`, beside the swap guard; the shared redirect today sends `/swap`, `/pay` and `/activity/swap` home when swap is disabled, `:677-680, 729`):

- Add `isPrivateUsd = _isRouteOrChild(location, '/private-usd')` beside the swap guard.
- Redirect `/private-usd*` to `/home` when `!privateUsdAvailable`. That covers hardware accounts, accounts with no ZIP-32 index, no deployment, and the kill switch off.
- **Except** `/private-usd/conversion/:d/:i` while that record is unfinished for the active account. This keeps D16's "in-flight swaps keep being driven" visible. The redirect is synchronous (`ref.read`), so read `privateUsdUnfinishedProvider` (a `Notifier<Set<PrivateUsdRecordKey>>` the engine updates), never a `FutureProvider`.
- Make the router re-run the guard: add `ref.listen(privateUsdAvailableProvider, …)` and `ref.listen(privateUsdUnfinishedProvider, …)` → `refresh.requestRefresh()` in `_routerProvider` (`lib/app.dart:541-553`), as the swap flag does.
- The locked case needs nothing new: `requiresUnlock` already sends every route to `/unlock` (`:722`), and unlock lands on `/home` (`:723`).
- Under the Tor fallback (D4, only if the spike fails), `/private-usd` stays reachable:
  - It shows the `tor_unavailable` notice.
  - The balance stays at its last cached value.
  - Send, Withdraw and Convert are disabled.
  - Conversion progress stays reachable. The engine's Rust HTTP follows Tor, so forward steps continue (the forward path never needs the page, §3.3). Steps that need the Railgun page (the reverse funding proof, the balance) wait with that notice.

**As built (M5, progress D-54).** The progress route redirects a `reverse` path to `/private-usd` until M6; `/private-usd/convert` ignores `?to=zec` and shows no direction toggle until then. The guard's exception reads `privateUsdUnfinishedProvider` with the active account, and `_routerProvider` refreshes on it.

**As built (M7, progress D-99).** The four send routes are as in the table below, plus `/private-usd/withdraw` beside `/private-usd/send`; each step pushes the next and pops with a result. The status screen is `MobileTransactionProgressScreen` with "Done" and "View on Etherscan". Send and Withdraw sit under the total on `/private-usd` with the spending note, and send rows show in its activity only.

**One conversion at a time and the spend guard.**

- "Convert" opens the in-flight conversion when one exists, from `/private-usd`, from the strip and from `/private-usd/convert` on open. That matches `showConversionUnderWay`, including after a crash between accept and the progress route.
- Send and Withdraw are disabled unless the guard is `AVAILABLE`.

**Lifecycle UX.**

- **Locked:** the engine pauses (§8.4). Unlock lands on `/home`; the banner reopens progress, which shows "Picking up where it left off." until the first advance after the resume returns.
- **Account switch:** the screens follow the active account. A non-active account's swap keeps advancing (D14), but v1 shows no UI for it except the account-deletion refusal (§8.4).

**Route table** (append to the list `buildMobileRoutes` returns, after the shell, `lib/src/core/navigation/mobile_routes.dart:74`; plain top-level `GoRoute`s, no `parentNavigatorKey`, the same shape as `/swap/keystone-sign` `:288-298`):

```dart
GoRoute(path: '/private-usd', pageBuilder: (c, s) => CupertinoPage(key: s.pageKey, child: const MobilePrivateUsdScreen())),
GoRoute(path: '/private-usd/convert',                    // ?to=zec selects reverse
    pageBuilder: (c, s) => CupertinoPage(key: s.pageKey, child: MobilePrivateUsdConvertScreen(
        direction: s.uri.queryParameters['to'] == 'zec' ? PrivateUsdDirection.reverse : PrivateUsdDirection.forward))),
GoRoute(path: '/private-usd/convert/review',
    redirect: (c, s) => s.extra is PrivateUsdReviewArgs ? null : '/private-usd/convert',
    pageBuilder: (c, s) => CupertinoPage(key: s.pageKey, child: MobilePrivateUsdConvertReviewScreen(args: s.extra! as PrivateUsdReviewArgs))),
GoRoute(path: '/private-usd/conversion/:direction/:index',
    redirect: (c, s) => PrivateUsdRoutePath.tryParse(s.pathParameters) == null ? '/private-usd' : null,   // direction ∈ {forward, reverse}, index ≥ 0
    pageBuilder: (c, s) => CupertinoPage(key: s.pageKey, child: MobilePrivateUsdConversionScreen(path: PrivateUsdRoutePath.parse(s.pathParameters)))),
    // the screen pairs the path with the active account into a PrivateUsdRecordKey
GoRoute(path: '/private-usd/refunds', pageBuilder: …MobilePrivateUsdRefundsScreen()),
GoRoute(path: '/private-usd/send', pageBuilder: …MobilePrivateUsdSendScreen(mode: PrivateUsdSendMode.private)),
GoRoute(path: '/private-usd/withdraw', pageBuilder: …MobilePrivateUsdSendScreen(mode: PrivateUsdSendMode.withdraw)),
GoRoute(path: '/private-usd/send/review', …MobilePrivateUsdSendReviewScreen(mode: private)),
GoRoute(path: '/private-usd/withdraw/review', …MobilePrivateUsdSendReviewScreen(mode: withdraw)),
GoRoute(path: '/private-usd/send/status', redirect: (c, s) => s.extra is PrivateUsdSendMode ? null : '/private-usd', …MobilePrivateUsdSendStatusScreen(mode: s.extra! as PrivateUsdSendMode)),
```

The progress route carries its key in the path (not `extra`), so a cold start, the banner and a deep link can all open it. Never put amounts or quotes in the URL.

**Dart feature tree** (`lib/src/features/private_usd/`; signature level, milestone in brackets):

```text
private_usd_copy.dart                       [M3+] abstract final class PrivateUsdCopy: const strings and builders (§9.6); privateUsdErrorMessage(ApiPrivateUsdErrorCode) with the M5 error tables
models/
  railgun_models.dart                       [M3] typed page requests/results (§6.2)
  private_usd_record_key.dart               [M5] class PrivateUsdRecordKey {String accountUuid; PrivateUsdDirection direction; int index} (==, hashCode); class PrivateUsdRoutePath {direction; index; static tryParse(Map<String,String>)}
  private_usd_status_presentation.dart      [M5/M6] SwapActivityStatusPresentation privateUsdStatusPresentation(ApiForwardRecord|ApiReverseRecord, {wait, activity, problem, resuming, balanceArriving}) (§9.5)
services/
  railgun_host_channel.dart, railgun_engine.dart, railgun_engine_key_store.dart       [M3]
  private_usd_balance_repository.dart, private_usd_balance_cache.dart                 [M3]
  private_usd_attestation.dart, private_usd_tokens_service.dart                       [M4]
  (no paths wrapper)                        the services call wallet_paths.dart directly: getPrivateUsdDirPath, getExistingPrivateUsdDirPath (never creates a directory or assigns a wallet DB name), deletePrivateUsdDirectories and deletePrivateUsdTokenStores
  private_usd_swap_backend.dart             [M5] PrivateUsdSwapBackend: the FRB calls with this wallet's context; key-using calls take a PrivateUsdSecretReader (read the seed last, zero it once Rust copied it) (D-51)
  private_usd_account_data.dart             [M3] deletePrivateUsdAccountData(storage, uuid): the engine key and the balance cache
  private_usd_engine.dart                   [M5] class PrivateUsdEngine {   // as built (D-51)
                                                ValueNotifier<Map<PrivateUsdRecordKey, PrivateUsdConversionStatus>> conversions;
                                                void start({bool resuming}); void nudge(); Future<void> pause(PrivateUsdPauseReason);   // lock | background
                                                Future<T> runFor<T>(String accountUuid, Future<T> Function(int opId, PrivateUsdSecretReader secret) step, {bool dropLateResult}); // serial per account, epoch-checked
                                                quote(account, units:); accept(account, index:, maxTotalZat:); abandon(account, index:); loadRecords(account);
                                                Future<void> quiesceAndDrain(); void resumeAfterMutation(); forgetAccount(uuid); forgetAll(); dispose(); }
  private_usd_zec_quote_search.dart         [M5] class PrivateUsdZecQuoteSearch { Future<ZecQuote> quote(BigInt totalZat, {BigInt? requestedUnits}); } // PrivateUsdZecQuotes.kt:35-80
  private_usd_reverse_funding.dart          [M6] as built (D-81): PrivateUsdReverseFunding { price(account, costRequest); Future<PrivateUsdFundingResult> fund(PrivateUsdRecordKey key); drop(key); states } over PrivateUsdReversePage (RailgunReversePage) // R2, R4–R6 in §5.11
  private_usd_spend_guard.dart              [M6 minimal, M7] enum PrivateUsdSpendStatus {checking, available, sending, converting, unreadable}; startConversion() (M6, in memory per account, D-82); send() and the send log (M7)
  private_usd_sender.dart                   [M7] Future<PrivateUsdSendOutcome> send(PrivateUsdSendRequest, PrivateUsdSendCost); Future<void> settleAll()
providers/
  private_usd_available_provider.dart       [M3] Provider<bool> privateUsdAvailableProvider (+ privateUsdAvailableFor, the deployment providers); no privateUsdTorBlockedProvider: D4 passed (D-22)
  private_usd_balance_provider.dart         [M3] NotifierProvider.autoDispose.family<…, PrivateUsdBalanceState, String /*uuid*/>, plus privateUsdBalanceKeepFreshProvider((accountUuid, ifUsed)) that polls while watched (D-21)
  railgun_engine_provider.dart              [M3] railgunEngineProvider (kept alive; registers with privateUsdLifecycleProvider; closes on lock, account switch, route change), railgunEngineStateProvider, RustRailgunWalletSource
  private_usd_receive_address_provider.dart [M3] FutureProvider.autoDispose.family<String, String> (Rust-derived; unlocked only)
  private_usd_engine_provider.dart          [M5] Provider<PrivateUsdEngine> (keepAlive; registers with privateUsdLifecycleProvider)
  private_usd_unfinished_provider.dart      [M5] NotifierProvider<…, Set<PrivateUsdRecordKey>> (sync; the router reads it; notifies only when the set changes), plus privateUsdConversionsProvider (the engine's snapshot, Map<PrivateUsdRecordKey, PrivateUsdConversionStatus>) and the deletion/reset counts privateUsdUnfinishedCountProvider(uuid), privateUsdUnfinishedTotalProvider
  private_usd_conversion_provider.dart      [M5] NotifierProvider.family<…, PrivateUsdConversionState, PrivateUsdRecordKey>
                                                 // {record, wait, activity, problem (after 60 s), resuming, busy}; actions: retryNow, callOff, pay, authorizeReady, cancel
  private_usd_conversion_banner_provider.dart [M5] Provider.family<PrivateUsdBannerState?, String>; as built it sits in private_usd_conversion_provider.dart, from the engine's snapshot (D-54)
  private_usd_convert_provider.dart         [M5/M6] NotifierProvider.autoDispose<…, PrivateUsdConvertState>
                                                 // {direction, amountText, quote, quoting, error, expiresIn, step: amount|review|confirming}; onAmountChanged (700 ms), onMax, refreshQuote, confirm
  private_usd_keep_awake_provider.dart      [M5] Provider<bool> (OR-ed into SyncKeepAwakeNativeHost)
  private_usd_activity_provider.dart        [M5] as built: privateUsdActivityRecordsProvider(uuid) (the account's forward records from the engine's snapshot, read once) and privateUsdActivityTxids; the rows come from widgets/mobile/private_usd_activity_rows.dart (D-54)
  private_usd_refunds_provider.dart         [M6] NotifierProvider.autoDispose.family<…, PrivateUsdRefundsState, String> (15 s, ≤ 4 checks, 30 s each)
  private_usd_reverse_convert_provider.dart [M6] as built (D-86): the reverse amount, quote (priced by the page) and review; "Convert" = go ahead → accept → fund
  private_usd_reverse_conversion_provider.dart [M6] as built: one reverse conversion's progress; pay, authorizeReady, cancel (the sheet is the screen's)
  private_usd_send_provider.dart            [M7] NotifierProvider.autoDispose.family<…, PrivateUsdSendState, PrivateUsdSendMode>
  private_usd_spend_status_provider.dart    [M7] StreamProvider.family<PrivateUsdSpendStatus, String>
screens/mobile/  mobile_private_usd_{,convert_,convert_review_,conversion_,refunds_,send_,send_review_,send_status_}screen.dart
widgets/mobile/  private_usd_home_strip.dart, private_usd_banner.dart, private_usd_activity_rows.dart, private_usd_info_sheets.dart, private_usd_confirm_sheets.dart (M6). As built: both directions' amount and review views are in private_usd_convert_views.dart over the shared panels in private_usd_convert_widgets.dart and private_usd_flow_widgets.dart, the progress bodies in private_usd_progress_views.dart (screens/ keeps the screens), and models/private_usd_reverse_{amount,presentation}.dart hold the 2-decimal amounts, Max, the "Authorize settlement" window and the progress presentation. The banner reuses MobileHomeEntryCard (lib/src/core/widgets/mobile/, extracted from home)
lib/src/providers/private_usd_lifecycle_provider.dart   [M3] register / quiesceAndDrain / resume (GiftCardTrackingLifecycle shape, several owners) + wipeRailgunPage for a reset; M5 registers the swap engine (run / cancel)
lib/src/features/private_usd/widgets/mobile/private_usd_engine_host.dart [M5] ConsumerWidget; watches privateUsdEngineProvider when privateUsdEngineEnabledProvider (define, mobile, Android, a deployment; not the kill switch or the active account). As built (D-51) the AppLifecycleListener and the lock listener live in privateUsdEngineProvider (Gift Card's shape)
```

The home strip and banner widgets are passed into `_BalanceCard` and the home `ListView` from `mobile_home_screen.dart` (§8.3); they are separate files so `mobile_home_screen.dart` grows only by the wiring.

### 9.3 Screen inventory and navigation (zapp, for reference)

| # | Surface | zapp source | Kind |
|---|---|---|---|
| 1 | Home balance-card amount `Private USD $X +$Y` | `ui/screen/tabs/view/WalletBalanceCard.kt:434-530` (`SecondaryBalanceLine`, `PrivateUsdAmount`); state `pu/widget/PrivateUsdWidgetState.kt`, VM `pu/widget/PrivateUsdWidgetVM.kt` | inline, tap → 3 |
| 2 | Home in-flight conversion banner | `WalletHomeView.kt:137-146`; `pu/PrivateUsdConversionBanner.kt:35-98` | card, tap → 6 or 7 |
| 2b | Home speed-dial "Private USD" | `ui/screen/tabs/view/PayActionSpeedDial.kt:61-67` → `onConvertClick` | opens 4, or the in-flight 6/7 |
| 2c | Balance breakdown sheet card | `ui/screen/balances/breakdown/BalanceBreakdownView.kt:107-110, 162+` | card, tap → 3 |
| 3 | Private USD screen (balance, buckets, Send, Withdraw, receive address, activity, Refunds, Convert) | `pu/PrivateUsdView.kt`, `pu/PrivateUsdState.kt`, `pu/PrivateUsdVM.kt` | full screen |
| 4 | Convert, ZEC → USD: amount, then review in place | `pu/convert/PrivateUsdConvert{Screen,View,AmountView,State,Terms,VM}.kt`, `PrivateUsdZecQuotes.kt` | full screen, 2 phases |
| 5 | Convert, USD → ZEC: amount, review, then progress in place | `pu/reverse/PrivateUsdReverse{Screen,View,State,Terms,Mapper,Progress,RefundRequest,VM}.kt` | same route as 4 with the other direction; 3 phases |
| 6 | Forward progress and result | `pu/progress/PrivateUsdProgress{Screen,View,State,Steps,VM}.kt` | full screen |
| 7 | Reverse progress and result | rendered by 5 once the record is past `QUOTED` (`PrivateUsdReverseView.kt:44-46`) | full screen |
| 8 | Refunds (reverse `REFUNDED` records, rescue) | `pu/refunds/PrivateUsdRefunds{Screen,View,State,VM}.kt` | full screen |
| 9 | Send privately / Withdraw: form, review, proving, done | `pu/send/PrivateUsdSend{Screen,View,Form,State,VM}.kt` | full screen, 4 phases |
| 10 | "How this works" info sheet on every screen | `pu/PrivateUsdScaffold.kt:129-170` (`ZappInfoSheet`), content `pu/PrivateUsdInfo.kt` | bottom sheet |
| 11 | App-lock prompt | `PinVerifyOverlay` on 4, 5, 8, 9 | overlay; **drop in veylor** |
| 12 | Notifications | `common/atomicswap/AtomicSwapNotifier.kt` | **not v1** |

There is **no separate onboarding**. First use is the first balance load, shown inline as "Loading your private balance…" with a percentage (`str:42-43`, `pu/PrivateUsdText.kt:98-102`) on 3, 4 and 5. Railgun screening (POI) is shown as the "Arriving" bucket and the "Screening" progress step, not as its own screen. **Unavailable** means the surfaces are absent: the widget is `null` (no deployment, no Railgun network, or the kill switch is off).

```
Home ─┬─ balance strip (1) ─────────────► Private USD (3)
      ├─ banner (2) ──────────────────────► Forward progress (6) | Reverse progress (7)
      └─ speed dial (2b) ─► in-flight? ──► 6 | 7   else ► Convert (4)

Private USD (3) ─┬─ Convert ─► in-flight? ─► 6 | 7   else ► Convert (4)
                 ├─ Send ────────────────► Send privately (9, mode PRIVATE)
                 ├─ Withdraw ────────────► Withdraw (9, mode WITHDRAW)
                 ├─ Refunds ─────────────► Refunds (8)
                 ├─ activity row: conversion under way ─► 6 | 7
                 ├─ activity row: finished, tx known ───► Etherscan (external)
                 └─ activity row: reverse refunded ─────► Refunds (8)

Convert (4) ⇄ direction toggle ⇄ Convert USD→ZEC (5)   (in place; disabled once confirming)
Convert (4): amount ─Review─► review ─Convert─► replace with 6
Convert (5): amount ─Review─► review ─Convert─► progress (7, same route) ─Refunds─► 8
Progress (6): Paid ─"View private USD"─► replaceAll 3 ; Refunded/Nothing sent ─"Try again"─► replace 4
Progress (7): over ─"New conversion"─► amount step of 5
Send (9): form ─Review─► review ─Send/Withdraw─► proving ─► done ─Done─► back to 3
Any screen opened while a conversion is under way, or after a crash mid-accept, is replaced by 6 or 7
(`pu/PrivateUsdConversions.kt:37-51`, `PrivateUsdConvertVM.kt:117-120`, `PrivateUsdProgressVM.kt:138-145`).
```

Back from 3, 4, 5, 6 and 7 returns to the tab shell on the Pay tab (`ui/common/usecase/NavigateBackToPayUseCase.kt:9-16`). In veylor, back pops the stack instead (§9.1).

### 9.4 Per-screen spec

Rules are zapp's unless marked **veylor**. Data references point to §6.6 (balance), §5.6–§5.8 (swap state) and §6.7 (sends).

#### S1. Home strip, banner and entry (zapp 1, 2, 2b)

- **Shows** (`pu/widget/PrivateUsdWidgetVM.kt:50-65`, `WalletBalanceCard.kt:466-530`):
  - `Private USD` then the headline `spendable` (§6.6), or "Loading…" while refreshing and "—" before any balance (`pu/PrivateUsdText.kt:91-93`).
  - `+$Y` in the accent colour while `arriving > 0`; its read-aloud text is "$Y arriving".
  - The amount turns the danger colour while `blocked > 0`; read aloud as "Needs attention: $X".
  - Masked with the rest of the balances when hidden.
  - **veylor:** add `≈ Y ZEC` (indicative, §6.6), hidden when the price is null or balances are hidden.
- **Banner** (`pu/PrivateUsdConversionBanner.kt:44-67`): only one conversion runs at a time, either way.
  - Title: "Conversion needs attention" when there is a problem (§5.8), or when the reverse phase is `AWAITING_READY`. Otherwise "Converting to private USD" (forward) or "Converting to ZEC" (reverse).
  - Detail: the forward stage label with the confirmation count (`pu/PrivateUsdText.kt:65-76`, for example "Waiting for confirmations · 1 of 2"), or the reverse step label (`pu/reverse/PrivateUsdReverseProgress.kt:158-160`).
  - **veylor:** also flag `AWAITING_FUNDING` as attention. In foreground-only v1 it means the fees changed or a funding post was refused, and only the user can continue.
- **When present:** zapp shows the strip whenever the feature is available, even before first use (it shows "—" and starts no WebView until opened; §6.6 `observeIfUsed`). **veylor:** keep that: the strip is the only entry point. Hide it for hardware accounts, accounts without a ZIP-32 index, networks without a deployment, and when the kill switch is off. Keep the banner while an unfinished swap exists (§9.1).
- **Tap:** strip → Private USD screen. Banner → that conversion's progress. **veylor:** no speed dial; the action row stays Send / Receive / Pay (§8.3).

#### S2. Private USD screen (zapp 3)

- **Header:** title "Private USD", subtitle "0zkUSDC held on Ethereum" (`str:25`), and an info button.
- **Total** (`pu/PrivateUsdView.kt:89-156`): headline `spendable`, greyed while unknown. The status line says "Updated {time}", or "Updating…", or the first-load line with its percentage. A refresh button; an explicit refresh ignores back-off (§6.6). A refresh error shows below in the danger colour: "Couldn't update the balance. Showing the last known amounts." with a balance, or "Couldn't load the balance. Try again in a moment." without one (`pu/PrivateUsdVM.kt:164-169`). **veylor:** add the `≈ ZEC` line here; drop the currency toggle. **As built (iOS progress VI-19, owner 2026-10-17):** the sync is Home's neon sync line over the whole screen (`privateUsdSyncLine`): a first sync's percentage (`SYNC n%`, or `TOR …`) climbs over the content, a refresh of a wallet that synced before stays `SYNCED` behind blocks backed solid, and a failure reads `SYNC FAILED` (`TOR OFFLINE`). The status line keeps the first-load line without its percentage and "Updated {time}", and the errors stay; screen readers hear the old status text from the line's live region.
- **Banner:** the in-flight conversion, as on home.
- **Buckets** (`pu/PrivateUsdVM.kt:171-203`): "Available" always; "Processing", "Arriving" and "Screening refused" only when non-zero, each with an explanation. "Screening refused" is in the danger colour.
- **Empty state:** shown when the total is 0 and nothing is converting: "No private dollars yet" with a short body (`:114`).
- **Assets:** listed only when more than one dollar token is held (Sepolia only, `:205-225`).
- **Send / Withdraw** (`:116-123`, `PrivateUsdView.kt:301-334`): enabled when a sender exists, the spend guard is `AVAILABLE`, and some dollar token has `available > 0`.
- **Receive address:** the 0zk address with a copy button, labelled "Receive from a Railgun wallet" since M9 (it was "Your receive address"): the way private USD comes in from another Railgun wallet, with no fee. It is not sensitive. Public USDC comes in through the deposit address of the Receive USDC sheet (M9).
- **Spending note** (`pu/PrivateUsdSpendingText.kt`), from the spend guard (§6.7):

  | Status | Note |
  |---|---|
  | `CHECKING` | "Checking pending payments…" |
  | `SENDING` | "A previous payment is still pending…" |
  | `CONVERTING` | "A conversion is in progress…" |
  | `UNREADABLE` | the store error |

- **Activity** (`pu/PrivateUsdActivityMapper.kt:41-208`), newest first; nothing that moved no money becomes a row:

  | Record | Title | Detail | Amount | Tap |
  |---|---|---|---|---|
  | Forward under way | "Converting ZEC" | stage detail, or the date | `+$receives`, neutral | open progress |
  | Forward `Paid` | "Converted ZEC" | date · ZEC paid | `+$receives`, positive | payout tx on Etherscan |
  | Forward `Refunded` | "Conversion called off" | date · "your ZEC came back" | none | none |
  | Forward `NothingSent` | no row | | | |
  | Reverse under way | "Converting to ZEC" | step label, or the date | `−$debit`, neutral | open progress |
  | Reverse `COMPLETE` | "Converted to ZEC" | date · ZEC received | `−$debit`, out | funding tx on Etherscan |
  | Reverse `REFUNDED` | "Conversion called off" | date · "your dollars came back" | none | open Refunds |
  | Reverse `CANCELLED` or `QUOTED` | no row | | | |
  | Send or withdraw, confirmed | "Sent privately" or "Withdrew" | date · "to 0zk1qy86…l4zu" (8 + 4 characters) | `−$amount` | tx on Etherscan |
  | Send not in a block yet | same | date · "not in a block yet" | same | tx if known |
  | Send still proving | same | date · "sending…" | same | none |
  | Private send received (as built) | "Received privately" | date · "from 0zk1qy86…l4zu" where the sender showed it, else "sender hidden"; "available once screened" until spendable | `+$amount`, positive once screened | tx on Etherscan |

  The empty state reads "Your conversions, sends and withdrawals will show here." A "Refunds" button sits beside the "Activity" heading (`PrivateUsdView.kt:193-214`).
- **Primary button:** "Convert". It opens the conversion under way if there is one, else the convert screen. It is enabled when a conversion exists or `canStartConversion` (§6.7: `AVAILABLE` or `CONVERTING`).
- **Info sheet** "About private USD" (`PrivateUsdVM.kt:227-245`): five steps (convert, receive, send, withdraw, refunds) and notes (screening time, privacy).
- **On open:** `refresh(maxAge 30 s)` and `findMissingPayouts()` (`:90-93`).

#### S3. Convert, ZEC → USD (zapp 4)

The **amount** phase (`pu/convert/PrivateUsdConvertVM.kt`, `PrivateUsdConvertTerms.kt`):

- **Fields.**
  - "ZEC": the total to spend, with the note "Includes the Zcash network fee".
  - "Available": the shielded spendable balance, with a use-it-all action.
  - A direction toggle.
  - "Private USD": the estimate, read-only, with the note "Estimated amount", plus the private USD available and a refresh button.
- **Validation.**
  - Up to 8 decimals, and `1 ≤ zatoshi ≤ 2.1e15` (`pu/PrivateUsdConversions.kt:73-82`).
  - Larger than spendable → "Not enough ZEC. You have {X} available." This is checked before any quote.
  - A zero still being typed is not flagged.
  - A quote that does not pay out (`fee ≥ amount`) → "This amount doesn't cover the relayer's fee. Try a larger amount."
  - No quote fits → "No quote fits this amount. Try a different amount or tap Available for the maximum."
  - Maker refusals map through `pu/PrivateUsdFailure.kt:26-163` (the error table in §9.6).
  - **veylor:** a relayer fee above the 2 USDC cap (D11) → its own message (§9.6, `N` rows).
- **Quoting.** It starts 700 ms after typing stops, and only when the amount is valid and not more than spendable.
  - While a quote loads, the button reads "Getting quote…", disabled and loading.
  - A quote that arrives already expired → "The quote had run out by the time it arrived. Check that your phone's clock is right…" (`PrivateUsdConvertTerms.kt:86-90`).
  - A quote stops being offered 20 s before its `expiresAt` (`QUOTE_EXPIRY_MARGIN_SECONDS`, `pu/PrivateUsdConversions.kt:24`).
  - On the amount phase an expired quote is replaced automatically (`PrivateUsdConvertVM.kt:225-232`).
- **Max.** Disabled while the balance is unknown or while the wallet is catching up. The catching-up line reads "Your wallet is still syncing (n%)…" (`PrivateUsdConvertTerms.kt:110-129`). Max fills the whole spendable amount, then the quote rewrites the field to the total that quote pays for (`withQuote(fillsAmount)`).
- **Quote ledger:**

  | Row | Value |
  |---|---|
  | "You pay" | total ZEC |
  | "Network fee" | ZEC |
  | "You receive about" | $ |
  | "Conversion fees" | "{$relayer} relayer · 0.25% Railgun" |
  | "Market maker's network cost" | $; only if the quote has one |

  It ends with the notice "Quote refreshes in m:ss".
- **"Review"** is enabled when the quote pays out, it has not expired, spendable is known and sufficient, and `canStartConversion` holds.

The **review** phase (same screen):

- **Header** (`pu/PrivateUsdReviewHeader.kt`): the source says "Review conversion"; Veylor uses "Review" so the mobile navigation title fits. Then `{ZEC}`, "for about", `{$}`. The ledger repeats the fees, with "Quote holds for m:ss".
- **"Convert":** authenticate, then `accept`, then replace with progress. The failure message defaults to "The conversion couldn't start. Nothing was sent…". If the swap was recorded anyway, the progress screen shows instead (`:286-297`).
- **Expiry:** once the quote expires, the button becomes "Get a new quote" and the message reads "This quote ran out. Get a new one to continue." A new quote that lands while the review is up is dropped (`withQuote`).
- **Info sheet** "Before you convert", with five notes (`PrivateUsdConvertTerms.kt:203-215`).

**Back:** blocked while confirming. From review, back returns to the amount phase. From the amount phase it leaves the screen (`PrivateUsdConvertVM.kt:299-314`). The direction toggle is disabled while confirming, and switching resets the amount.

#### S4. Convert, USD → ZEC (zapp 5)

- **Amount** (`pu/reverse/PrivateUsdReverseVM.kt`, `PrivateUsdReverseTerms.kt`):
  - Private USD is entered in dollars, 2 decimals (`holds`). An amount with more decimals, or zero → invalid, and no quote.
  - "ZEC" shows the estimate, `receivedZat()`: the sweep's own figure, else the reviewed estimate, else `depositZat − 10,000` (`:180-183`).
  - Quoting is debounced 700 ms. It saves a `QUOTED` draft (§5.7 step 1).
  - An expired quote is re-asked once for the same amount. A failed amount is marked `stale` and not re-asked until it changes (`:250-260`).
  - Max = `available − unshieldFee(balance) − fundingFee`, rounded down (`:240-248`). It is enabled only while typing and `available > 0`.
  - Short: when `cost.debit` (or the typed amount before a quote) exceeds the available balance and nothing is funded yet → "Not enough Private USD for this amount and its fees." (`PrivateUsdReverseTerms.kt:69-99`).
  - A "View refunds" button shows when any earlier `REFUNDED` record exists and nothing is under way (`PrivateUsdReverseVM.kt:202-211`).
- **Review** (`PrivateUsdReverseMapper.kt:74-88`):
  - Header: `{$debit}` for about `{ZEC}`.
  - Rows: "Escrow value", "Railgun unshield fee", "Broadcast fee", "Total paid", "Market maker's network cost" (optional), and "Estimated ZEC after sweep fee".
  - **veylor:** add a "Keep Veylor open" note, the settlement deadline (`readyDeadline`) and the Tor-off disclosure (§9.6).
- **"Convert"** is one authorized step: accept, import the joint account, then fund (`:353-357`). Its default failure is "The conversion couldn't start…". After it, the screen renders progress (S6).
- **Cost changed.** `FUNDING_COST_CHANGED` → "The fees changed, so nothing was paid. The new total shows above: convert again to pay it, or cancel." The record stays in `AWAITING_FUNDING`, whose primary button is "Convert" again (`PrivateUsdReverseMapper.kt:149-153`). **veylor:** show the new cost rows on the progress screen in `AWAITING_FUNDING`, and label the button "Pay {debit}".
- **Back** (`:296-317`): from review of a preview → back to the amount. During a look-up (the max calculation) → cancels it. During an authorized step → blocked. Otherwise → leave.

#### S5. Forward progress (zapp 6)

- **State** (`pu/progress/PrivateUsdProgressVM.kt:82-116`, `PrivateUsdProgressSteps.kt`):
  - amounts line: "{total ZEC} for about {$}"
  - the step list
  - a note
  - a problem card, "Taking longer than usual", with "Try now" (`retryNow`)
  - the result header
  - "Call it off": only while opening has taken more than 90 s and there is no problem (`:89-109`). `abandon` succeeds only before any deposit and with no escrow (§5.6 step 12); otherwise → "The swap opened on Ethereum meanwhile, so it can't be called off. It carries on."
  - the background note (**veylor:** keep-open note)
  - the primary button: none while under way; "View private USD" after `Paid` (replaceAll → S2); "Try again" after `Refunded` or `NothingSent` (replace → S3)
- **Ticks** every 15 s. On open it resumes the loop. If there is no forward record at all, it moves to the reverse conversion or to Convert (`:137-145`).
- **Back** goes home (blocked while call-off is busy).

#### S6. Reverse progress (zapp 7)

- **State** (`pu/reverse/PrivateUsdReverseProgress.kt:28-61`, `PrivateUsdReverseMapper.kt:90-200`):
  - amounts: "{$} for about {ZEC} after fees", without "about" once the sweep exists. Hidden for refunded and cancelled.
  - steps and notes (§9.5)
  - a problem card (no retry button)
  - the call-off button: "Cancel conversion" before any funding in `ACCEPTING`/`AWAITING_FUNDING`, else "Request private refund" (as built, the copy table's "Request refund", progress D-84). It is shown only while the status is `cancellable` (`!cancelRequested && !isSettled && phase ∉ {REFUNDING, REFUND_PAYOUT}`).
  - while refunded: "View refunds"
- **Primary button.**
  - `AWAITING_FUNDING` → "Convert"
  - `AWAITING_READY` → "Authorize settlement"
  - over → "New conversion"
  - otherwise none
- **Cancel** (`PrivateUsdReverseRefundRequest.kt`): it runs independently of an authorized funding proof, and cancels that job afterwards. A settled record → "This conversion has already settled and can no longer be refunded…". A failure → "Couldn't call it off. Try again in a moment.". **veylor:** put a confirmation sheet before cancel, because there is no app-lock prompt (D18).
- **Ready.** Its failure → "The market maker's ZEC isn't confirmed yet. Try again in a few minutes." (`DEPOSIT_UNCONFIRMED`) or the generic `reverse_error`. Too late → "It's too late for this step, so the conversion ends by itself. Anything you paid comes back."

#### S7. Refunds (zapp 8)

- **Content** (`pu/refunds/PrivateUsdRefundsVM.kt:63-234`, `PrivateUsdRefundsView.kt`):
  - The list is every reverse record in `REFUNDED`, newest first. Each row shows the date, the original amount ("Original conversion amount") and a status.
  - Each row is re-checked with `canRescue` every 15 s, at most 4 at a time, with a 30 s timeout per check.
  - Row status:

    | Condition | Status |
    |---|---|
    | busy | "Recovering your refund…" |
    | check failed | "Couldn't check this refund. Refresh to try again." (danger) |
    | not checked yet | "Checking refunds…" |
    | recoverable | "This refund can be recovered." and a "Recover refund" button |
    | otherwise | "No recovery available right now. Your refund may still be going through Railgun screening." |

  - Only one recovery runs at a time, and back is blocked while it runs. A recovery failure → "Couldn't recover this refund. Try again."
  - The page empty state is "No refunded conversions yet."; there is an explanatory paragraph at the top and a refresh button.
- **Rescue** is §5.8 step 6. A record stays `REFUNDED`.

#### S8. Send privately and Withdraw (zapp 9)

- **Phases** (`pu/send/PrivateUsdSendVM.kt`, `PrivateUsdSendForm.kt`): `FORM → REVIEW → SENDING → DONE`.
- **Form.**
  - **Asset chooser:** only if more than one dollar token has a balance (testnet). The first token is pinned so a refresh cannot swap it.
  - **Amount:** in dollars, at most the token's decimals (6 for USDC/tUSD) → "Use at most 6 decimal places.". Above available → "More than you have available.". If the fee is paid in the same token and the amount leaves less than the network-fee reserve (the last quoted fee, else the minimum) → "Leave {fee} for the network fee." (`:96-118`). "Use it all" fills `available − reserve`.
  - **Recipient, PRIVATE:** parsed as a Railgun 0zk address, else "That isn't a Railgun 0zk address.".
  - **Recipient, WITHDRAW:** `^0x[0-9a-fA-F]{40}$`; a mixed-case address must match its EIP-55 checksum; the zero address → "That's the zero address: anything sent there is lost for good."; else "That isn't an Ethereum address." (`:120-139, 222-229`).
  - An empty field shows no error. Editing clears any cost and error.
- **"Review"** is enabled once a valid request exists. It fetches the cost (`sender.cost`). Unavailable → "Private sends are unavailable right now. Nothing was sent. Try again later."; other failures → "Nothing was sent. Try again in a moment." If the quoted fee no longer fits, it returns to the form (`priced`).
- **Review rows:** "Asset", "Amount", "Railgun fee (0.25%)" (withdraw only; non-zero), "Network fee", "They receive", and "To" (the full address).
  - The withdraw notice reads "Anyone on Ethereum can see this amount and address."
  - If the balance drops below the amount → "Your available balance is now less than this amount."
  - The primary button is "Send" or "Withdraw", enabled when `canSend`, the cost is known and the guard is `AVAILABLE`.
  - **veylor:** refuse a network fee above 2 USDC (D11) with its own message.
- **Sending:** "Proving your transaction" with a body and the proof progress (0–1), from the page's `proof` events. The button reads "Sending" (disabled, loading). Back is blocked.
- **Outcomes** (`:276-302`):

  | Outcome | Result |
  |---|---|
  | `Busy` | back to review with "A previous payment is still pending…" |
  | `NotSent` | back to where it was, with "Nothing was sent…" |
  | `Repriced` | re-review with "The network fee went up to {fee}. Nothing was sent." |
  | `Sent` or `Unconfirmed` | Done |

  Anything signed never returns to review.
- **Done:** "Sent" or "Withdrawn", "{amount} went to {0zk1…}". If unconfirmed: "It isn't in a block yet. Check your activity before sending again." Buttons: "View on Etherscan", "View on Railscan", and "Done" (back).
- **Back:** during the cost look-up it cancels and leaves; review → form; sending → blocked; form or done → leave.
- **Info sheets.** Send: three steps. Withdraw: "Withdrawing makes it public", two steps and three notes, including the privacy advice and the Railgun fee bps (`:363-403`).

### 9.5 Progress UI ↔ state machine

**Forward** (§5.6; zapp's stage is `common/atomicswap/AtomicSwapStage.kt:22-31`; the steps come from `pu/progress/PrivateUsdProgressSteps.kt`). The list is `Opening → Sending ZEC → Confirmations → Claiming → Arriving → Screening`, plus a separate single-step refund list.

| Engine state (§5.6/§5.8) | Active step (label · detail) | Note | User action |
|---|---|---|---|
| Record saved, accept outstanding, or `Waiting(OPENING)` | "Opening the swap on Ethereum" · "About a minute" | after 90 s: "The market maker hasn't opened the swap yet. Nothing has been sent." | "Call it off" (only then) |
| Deposit `Started`/`Kept`, being built or sent (activity `DEPOSITING`) | "Sending your ZEC" · "A few seconds" | none | none (**veylor: keep the app open**; the deposit needs the seed) |
| `Waiting(CONFIRMING)` | "Waiting for confirmations" · "n of 2 · about x min" (75 s per block) | `confirmations ≥ 2`, no payout yet, `t0 > now`: "The market maker hasn't confirmed your deposit yet. If it still hasn't by {t0}, Veylor claims your dollars itself." | none (**veylor: stay open past `t0`**) |
| `ZcashWait.SYNCING` (any step) | detail "Waiting for your Zcash wallet to sync" | none | none |
| Claim or payout under way (any other activity) | "Claiming your dollars" · "About a minute" | none | none |
| `Waiting(UNWINDING)`, no claim running | two steps: "Waiting for the market maker's refund", then "Bringing your ZEC back" | "The swap couldn't be completed in time, so it unwinds: your ZEC comes back after the market maker's refund. If the market maker hasn't refunded by {lateClaimAt}, Veylor claims your dollars instead." | none (**veylor: keep open**; the sweep or the late claim needs the seed) |
| `end = Paid`, balance not yet synced 30 s after it | all four complete; "Arriving in your private balance" · "About a minute" | none | "View private USD" |
| `Paid`, arrived but still `arriving` | "Screening" · "about 1 h" (mainnet; 1 min testnet) | none | "View private USD" |
| `Paid`, screened | all complete | none | "View private USD" |
| `Refunded`, waiting (`Waiting(REFUNDING)`) or activity `SWEEPING` | single step "Bringing your ZEC back" | "The swap was called off. Veylor is bringing your ZEC back to your wallet." | none (**veylor: keep open**; the sweep needs the seed) |
| `Waiting(DEPOSIT_UNSETTLED)` | the confirmations step | "The market maker called the swap off while your ZEC payment was still unconfirmed. If it goes through, Veylor brings your ZEC back." | none |
| Resuming after a restart | the current step | "Picking up where it left off." | none |
| Any problem after 1 min of failures (§5.8) | the current step | problem card "Taking longer than usual" + message | "Try now" |
| `end = Refunded(cause)` | no steps | result "Your ZEC came back" + body by cause | "Try again" (none while bridging is off) |
| `end = NothingSent(cause)` | no steps | result "Nothing was sent" + body by cause | "Try again" (none while bridging is off) |

**Reverse** (§5.7; `pu/reverse/PrivateUsdReverseProgress.kt:114-191`, phase labels `common/atomicswap/ReverseSwapStage.kt:14-31`). The list is `Prepare → Fund → Deposit → Approve → Settle → Receive`. Refund phases show one step labelled with the phase.

| Phase | Step (active) | Banner / activity detail | Note | User action | Cancel button |
|---|---|---|---|---|---|
| `QUOTED` | none (review) | no row | none | "Convert" | none |
| `ACCEPTING` | "Preparing your receiving account" | same | none | none | "Cancel conversion" |
| `AWAITING_FUNDING` | "Sending private USD to escrow" | same | the cost-changed error when relevant | **"Convert"** (pay; **veylor: "Pay {debit}"**, attention) | "Cancel conversion" (no funding) / "Request private refund" |
| `SENDING_USDC` | same | same | none | none | "Request private refund" |
| `CONFIRMING_ESCROW` | same | same | none | none | same |
| `RECEIVING_ZEC` | "Waiting for confirmed ZEC" | same | none | none | same |
| `AWAITING_READY` | "Authorize settlement" · "Your approval is needed to continue." | banner turns "Conversion needs attention" | "The full ZEC deposit is confirmed. Authorize settlement…" | **"Authorize settlement"** (before `readyDeadline − 120 s`) | same |
| `SETTLING` | "Settling your conversion" | same | "Settlement is authorized. A refund can only proceed after {refundAfter} if settlement has not completed." | none | same (until claimed) |
| `RECEIVING` | "Moving ZEC to your shielded wallet" · "Zcash confirmations: n" | same | none | none (**veylor: keep open**) | none (settled) |
| `COMPLETE` | all complete | "Converted to ZEC" | result "ZEC received" / "{ZEC} arrived after fees." | "New conversion" | none |
| `REFUND_WAIT` | one step: "Waiting until a refund can proceed. Veylor retries while it's open." | same | the cancel-requested note, if any | none | none (`cancelRequested`) |
| `REFUNDING` | "Securing your private refund" | same | same | none | none |
| `REFUND_PAYOUT` | "Returning your private USD to Railgun" | same | none | none | none |
| `REFUNDED` | none | "Conversion called off" · "your dollars came back" | result "Refund sent" / "Private refund paid. Railgun screening may delay availability." | "New conversion"; "View refunds" → rescue if eligible | none |
| `CANCELLED` | none | no row | result "Conversion cancelled" / "Conversion cancelled; no escrow payment remains" | "New conversion" | none |

The cancel-requested note: "Refund requested…" before `ready`, or "…after {refundAfter}…" after it. While bridging is off, an ended conversion offers no "New conversion".

**What needs the user.** In zapp, only the funding payment (`AWAITING_FUNDING`), the settlement approval (`AWAITING_READY`), cancel and rescue. In veylor, **every key-using step also needs the app open and unlocked** (D9): the forward deposit, claim and sweep, and the reverse fund, ready, refund and sweep. So the progress screens and the banner must say so (§9.6 `F` rows). Keep the screen awake while a progress screen is visible and a key step is pending (X8), by OR-ing `privateUsdKeepAwakeProvider` into the watch in `SyncKeepAwakeNativeHost.build` (`lib/src/core/widgets/mobile/sync_keep_awake_native_host.dart:62-70`), never by calling `NativeScreenAwakeBridge` directly (M5 pitfalls; the opt-in sync keep-awake is `syncKeepAwakeActiveProvider`, `lib/src/providers/sync_keep_awake_provider.dart:168`). As built (iOS progress VI-18): it also holds through a Railgun first sync while the wallet is unlocked (`privateUsdFirstSyncKeepAwakeProvider`; the balance notifier registers each first sync in `privateUsdFirstSyncsProvider`).

**Home for in-flight swaps:** the banner (S1), the activity row with the stage detail (S2), and nothing else. There are no notifications in v1.

### 9.6 Copy

The tables give every user-facing string the veylor screens need, rewritten in sentence case with zapp's branding removed. The key is zapp's, to keep provenance. `{x}` is a placeholder.

Flags:

- **B**: branding changed ("Zapp" becomes "Veylor", or the sentence is rephrased)
- **F**: foreground-only change
- **T**: Tor or token-route change (D10, D4)
- **C**: local-currency text removed
- **N**: new for veylor
- **S**: sentence case fixed
- unflagged: verbatim

**Dropped (do not port):**

- the notifications block (`str:204-217`) and `convert_notifications_off` (`:113`)
- `private_usd_info_note_currency` (`:53`), `private_usd_info_switch_currency` (`:56`) and `private_usd_switch_currency` (`:317`), all C
- `convert_error_tor_off` (`:105`): veylor issues tokens directly when Tor is off (D10)
- `private_usd_token_weth` (`:36`): not a dollar
- `private_usd_home_separator` (`:17`): veylor lays out its own strip
- `convert_quote_countdown` (`:90`): use veylor's `m:ss` formatter

**Naming rule.** "Private USD" is the feature's name: capitalize it at the start of a sentence and as a screen title, and write "private USD" mid-sentence (zapp mixes both). "Railgun", "Ethereum", "Etherscan", "Railscan", "ZEC", "USDC" and "Zcash" keep their canonical case (AGENTS.md "UI Copy Conventions").

**Shared**

| Key | Text | Flag |
|---|---|---|
| `private_usd_title` | Private USD | |
| `private_usd_about_minutes` / `_hours` | about {n} min / about {n} h | |
| `private_usd_info_content_description` | How this works | |
| `private_usd_worth` | ≈ {zec} | C (now the ZEC equivalent) |
| `private_usd_home_loading` | Loading… | |
| `private_usd_home_unknown` | — | |
| `private_usd_refresh` | Refresh | |
| `private_usd_updating` | Updating… | |
| `private_usd_updated` | Updated {time} | |
| `convert_review` | Review | |
| `convert_result_done` | Done | |
| `private_usd_use_available` | Use it all (accessibility label) | S |
| N `support_sentence` | Contact support. (A link to `VIZOR_SUPPORT_URL` when that define is set.) | N (D17) |

**Home**

| Key | Text | Flag |
|---|---|---|
| `private_usd_home_arriving` | +{$} arriving | |
| `private_usd_home_arriving_description` | {$} arriving | |
| `private_usd_home_blocked` | {$} needs attention | |
| `private_usd_home_blocked_description` | Needs attention: {$} | |
| `private_usd_home_content_description` | Open private USD | |
| `private_usd_banner_title` | Converting to private USD | |
| `private_usd_converting_zec` | Converting to ZEC | |
| `private_usd_banner_attention_title` | Conversion needs attention | |
| `private_usd_banner_view` | View | |
| N `home_zec_equivalent` | ≈ {zec} ZEC | N |
| N `banner_keep_open` | Keep Veylor open to finish | N, F (banner detail suffix while a key step is pending) |

**Private USD screen**

| Key | Text | Flag |
|---|---|---|
| `private_usd_subtitle` | 0zkUSDC held on Ethereum | |
| `private_usd_breakdown_note` | Held separately and privately, on Ethereum through Railgun. | |
| `private_usd_row_available` | Available | |
| `private_usd_row_processing` | Processing | |
| `private_usd_row_processing_info` | A send is being confirmed. These funds are available again once it settles. | |
| `private_usd_row_arriving` | Arriving | |
| `private_usd_row_arriving_info` | Railgun screens new funds before they can be spent. This takes {about}. | |
| `private_usd_row_blocked` | Screening refused | |
| `private_usd_row_blocked_info` | Railgun's screening refused these funds, so they can't be spent or sent. They can only go back to where they came from, the conversion contract. {support sentence} | B (D17) |
| `private_usd_assets_title` | Assets | |
| `private_usd_token_usdc` / `_test_usd` | USD Coin / Test dollar | |
| `private_usd_action_convert` / `_send` / `_withdraw` | Convert / Send / Withdraw | |
| `private_usd_first_load` | Loading your private balance. The first time reads Railgun's history and can take a while. Keep Veylor open. | F |
| `private_usd_first_load_progress` | Loading your private balance: {n}%. The first time reads Railgun's history and can take a while. Keep Veylor open. | F |
| `private_usd_refresh_failed` | Couldn't update the balance. Showing the last known amounts. | |
| `private_usd_load_failed` | Couldn't load the balance. Try again in a moment. | |
| `private_usd_empty_title` | No private dollars yet | |
| `private_usd_empty_body` | Convert ZEC into dollars nobody else can see: not your balance, and not who you pay. | |
| N `empty_body_receive` | Receive dollars nobody else can see: not your balance, and not who you pay. (bridging off) | N |
| `private_usd_receive_address` | Receive from a Railgun wallet (M9; was "Your receive address") | |
| `private_usd_copy_address` | Copy your private USD address | |
| `private_usd_checking_payments` | Checking pending payments… | |
| `private_usd_payment_pending` | A previous payment is still pending. You can send or convert again once it's confirmed. | |
| `private_usd_conversion_pending` | A conversion is in progress. Sending will be available when it finishes. | |
| `private_usd_info_title` | About private USD | |
| `private_usd_info_step_convert` | Convert: exchange ZEC and private USD. | S (em dash → colon, all five) |
| `private_usd_info_receive` | Receive: public USDC from an exchange or any wallet goes to your deposit address (Receive), and Veylor makes it private for a small fee. Private USD from another Railgun wallet goes to your Railgun address on this screen, with no fee. (M9) | B |
| `private_usd_info_send` | Send: transfer private USD to another Railgun address. The recipient receives it privately. | |
| `private_usd_info_withdraw` | Withdraw: move private USD to a public Ethereum address. The destination and amount are visible on Ethereum. | |
| `private_usd_info_refunds` | Refunds: recover a refund that couldn't enter your private balance. | |
| `private_usd_info_step_screen` | Railgun screens new funds for {about} before they can be spent. | |
| `private_usd_info_note_private` | Nobody else can see your balance, or who you pay. | |
| N `info_note_keep_open` | Conversions, sends and refunds run only while Veylor is open and unlocked. | N, F |
| N `tor_unavailable` | Private USD is unavailable while Tor is on. Turn off Tor in Settings to use it. Conversions already under way continue. | N, T (only if the D4 spike fails) |

**Activity**

| Key | Text |
|---|---|
| `private_usd_activity_title` | Activity |
| `private_usd_activity_empty` | Your conversions, sends and withdrawals will show here. |
| `private_usd_activity_converting` / `_converted` | Converting ZEC / Converted ZEC |
| `private_usd_activity_converted_zec` | Converted to ZEC |
| `private_usd_activity_refunded` | Conversion called off |
| `private_usd_activity_refunded_detail` / `_refunded_zec_detail` | your ZEC came back / your dollars came back |
| `private_usd_activity_sent` / `_withdrew` | Sent privately / Withdrew |
| `private_usd_activity_detail` | {a} · {b} |
| `private_usd_activity_to` | to {address} |
| N `private_usd_activity_received` | Received privately (a private send another wallet made to this one; on `/private-usd` only, as sends) |
| N `private_usd_activity_from` / `_sender_hidden` | from {address} / sender hidden |
| N `private_usd_activity_received_screening` | available once screened |
| `private_usd_activity_in` / `_out` | +{$} / −{$} |
| `private_usd_activity_sending` / `_unconfirmed` | sending… / not in a block yet |
| `private_usd_activity_open_conversion` / `_open_transaction` | Open conversion / View transaction |
| `refunds_view` | View refunds |

**Convert (both directions): amount and quote**

| Key | Text | Flag |
|---|---|---|
| `convert_title` | Convert | |
| `convert_asset_zec` | ZEC | |
| `convert_swap_direction` | Swap conversion direction | |
| `convert_zec_includes_fee` | Includes the Zcash network fee | |
| `convert_estimated_amount` | Estimated amount | |
| `convert_you_pay` / `convert_network_fee` / `convert_you_receive` | You pay / Network fee / You receive about | |
| `convert_fees` | Conversion fees | |
| `convert_fees_value` | {$} relayer · {bps}% Railgun | |
| `convert_maker_cost` | Market maker's network cost | |
| `convert_quote_expires` | Quote expires in {m:ss} | S (veylor wording, `features/pay/widgets/mobile/mobile_pay_review_content.dart:186`) |
| `convert_quote_holds` | Quote holds for {m:ss} | |
| N `quote_expired` | Quote expired | N (veylor's, `mobile_pay_review_content.dart:176`) |
| `convert_quote_loading` | Getting quote… | |
| `convert_new_quote` | Refresh quote | S (veylor's label, `mobile_pay_review_content.dart:255`) |
| `convert_quote_ran_out` | This quote expired. Refresh it to continue. | S |
| `convert_quote_clock_ahead` | The quote had expired by the time it arrived. Check that your phone's clock is right, then try again. | |
| `convert_insufficient` | Not enough ZEC. You have {zec} available. | |
| `convert_zec_syncing` | Your wallet is still syncing. The rest of your ZEC is available once it catches up. | |
| `convert_zec_syncing_progress` | Your wallet is still syncing ({n}%). The rest of your ZEC is available once it catches up. | |
| `convert_zec_no_quote` | No quote fits this amount. Try a different amount, or use it all for the maximum. | S |
| `reverse_insufficient` | Not enough private USD for this amount and its fees. | S |
| `reverse_error_max` | Couldn't work out the most you can convert. Try again in a moment. | |

**Convert: errors before anything is sent** (`pu/PrivateUsdFailure.kt:26-163`)

| Key | Text | Flag |
|---|---|---|
| `convert_error_maker` | The market maker can't be reached right now. Try again in a moment. | |
| `convert_error_maker_cant_fill` | The market maker can't convert this much right now. Try a smaller amount, or try again later. | |
| `convert_error_maker_busy` | The market maker is busy with other conversions. Try again in a few minutes. | |
| `convert_error_amount_refused` | The market maker won't convert this amount. It may be over the limit for one conversion, or too small to cover the swap's network cost. | |
| `convert_error_below_fee` | This amount doesn't cover the relayer's fee. Try a larger amount. | |
| N `convert_error_fee_cap` | The relayer's fee is above the 2 USDC limit right now, so nothing was sent. Try again later. | N (D11) |
| `convert_error_no_tokens_today` | This phone has used today's conversions. More are available after midnight UTC. | |
| `convert_error_tokens_unavailable` | Couldn't get this conversion's token, so nothing was sent. Try again in a moment. | B, T |
| `convert_error_device_refused` | This phone can't get conversion tokens. The token service turns away emulators, phones with an unlocked bootloader or a modified system, and app builds it doesn't recognize. | B |
| `convert_error_keystore` | Veylor couldn't use this phone's secure key storage to get a conversion token, so nothing was sent. Try again in a moment. | B |
| `convert_error_relayer` | The relayer that completes conversions can't be reached right now. Try again in a moment. | |
| `convert_error_relayer_refused` | The relayer that completes conversions turned this down. Try again in a moment. | |
| `convert_error_ethereum` | Veylor can't reach Ethereum right now. Try again in a moment. | B |
| `convert_error_wallet` | Veylor couldn't complete this step with your Zcash wallet. Try again in a moment. | |
| `convert_error_unpayable` | Your wallet can't pay this in one transaction right now. Try a smaller amount. | |
| `convert_error_store` | Veylor can't read its saved conversions. {support sentence} | B (D17) |
| `convert_error_generic` | Couldn't get a quote. Try again in a moment. | |
| `convert_start_failed` | The conversion couldn't start. Nothing was sent. Try again in a moment. | |
| `reverse_error_funding_unavailable` | Conversion to ZEC is unavailable right now. Try again later. | S |
| `reverse_error_cost_changed` | The fees changed, so nothing was paid. Review the new total, then pay it or cancel. | (layout changed) |
| N `route_blocked` | Tor is starting or unavailable, so nothing was sent. Try again once it's connected. | N, T (`ApiPrivateUsdErrorCode::RouteBlocked`, §8.2) |

**Convert: review and info**

| Key | Text | Flag |
|---|---|---|
| `convert_review_title` | Review | |
| `convert_review_arrow` | for about | |
| `convert_info_title` | How converting works | |
| `convert_info_step_quote` | Enter the ZEC you want to convert, including the network fee. The market maker quotes how much private USD you receive. The quote holds for a few minutes. | |
| `convert_info_step_deposit` | Your ZEC goes to a deposit address that you and the market maker control together. | |
| `convert_info_step_claim` | Once the deposit is confirmed, Veylor claims the dollars into your private balance. | B |
| `convert_info_note_either` | Either the dollars reach your private balance, or your ZEC comes back to you. | |
| `convert_info_note_time` | Takes {about}. Keep Veylor open and unlocked until it's done. If you leave, it pauses; if it can't finish in time, it's called off and your ZEC comes back, less a network fee. | B, F |
| `convert_review_info_title` | Before you convert | |
| `convert_review_info_pay` | You pay the ZEC deposit, which includes the market maker's network cost, plus the Zcash network fee. | |
| `convert_review_info_receive` | You receive the dollars left after the relayer's fee and Railgun's {bps}% fee for shielding them. | |
| `convert_review_info_quote` | The quote holds for a few minutes. If it expires, refresh it: nothing is sent until you convert. | S |
| N `tor_off_disclosure` | Tor is off, so the token service sees this phone's attestation together with your IP address. | N, T (D10; show on both reviews only when Tor is off; add "Turn on Tor in Settings to hide it." only if the D4 bridge ships) |
| `reverse_title` | Private USD to ZEC | S (was "→") |
| `reverse_intro` | Approve sending private USD first. After your wallet confirms the full ZEC deposit itself, approve settlement to receive shielded ZEC. | S |
| `reverse_refund_note` | Before you approve settlement, you can cancel. After that, a refund waits for the contract deadline. A refund pays the relayer's fee and Railgun's shielding fee. Closing Veylor never approves settlement. | B |
| N `reverse_keep_open` | Keep Veylor open after you pay. Once the ZEC is confirmed, you approve settlement here by {time}. If you don't, your private USD is refunded, less fees. | N, F |
| `reverse_escrow` / `reverse_railgun_fee` / `reverse_broadcaster_fee` / `reverse_total` | Escrow value / Railgun unshield fee / Broadcast fee / Total paid | |
| `reverse_receive_estimate` | Estimated ZEC after sweep fee | |

**Convert: progress (forward)**

| Key | Text | Flag |
|---|---|---|
| `convert_progress_title` | Converting | |
| `convert_progress_amounts` | {zec} for about {$} | |
| `convert_step_open` / `_deposit` / `_confirm` / `_claim` | Opening the swap on Ethereum / Sending your ZEC / Waiting for confirmations / Claiming your dollars | |
| `convert_step_confirm_count` | {n} of {m} | |
| `convert_step_arrive` / `_screen` / `_refund` | Arriving in your private balance / Screening / Bringing your ZEC back | |
| `convert_eta_seconds` / `_minute` | A few seconds / About a minute | |
| `convert_wait_syncing` | Waiting for your Zcash wallet to sync | |
| `convert_maker_silent` | The market maker hasn't confirmed your deposit yet. If it still hasn't by {time}, Veylor claims your dollars itself. Keep Veylor open until then. | B, F |
| `convert_opening_slow` | The market maker hasn't opened the swap yet. Nothing has been sent. | |
| `convert_call_off` | Call it off | |
| `convert_call_off_failed` | Couldn't call it off. Try again in a moment. | |
| `convert_call_off_too_late` | The swap opened on Ethereum meanwhile, so it can't be called off. It carries on. | |
| `convert_unsettled` | The market maker called the swap off while your ZEC payment was still unconfirmed. If it goes through, Veylor brings your ZEC back. | B |
| `convert_resuming` | Picking up where it left off. | |
| `convert_refunding` | The swap was called off. Veylor is bringing your ZEC back to your wallet. | B |
| `convert_step_unwind` | Waiting for the market maker's refund | N |
| `convert_unwinding` / `_until` | The swap couldn't be completed in time, so it unwinds: your ZEC comes back after the market maker's refund. / {that} If the market maker hasn't refunded by {time}, Veylor claims your dollars instead. | N |
| `convert_background_note` | Keep Veylor open until this finishes. If you leave, it pauses and picks up when you're back. | B, F |
| `convert_progress_info_title` | What's happening | |
| `convert_progress_info_open` | The market maker opens the swap on Ethereum and puts the dollars in it. | B |
| `convert_progress_info_deposit` | Veylor sends your ZEC to the deposit address you and the market maker share. | B |
| `convert_progress_info_confirm` | The market maker waits for {n} Zcash confirmation(s). (plural) | |
| `convert_progress_info_claim` | Veylor claims the dollars into your private balance. A relayer pays the Ethereum fees. | B |
| `convert_progress_info_screen` | Railgun screens them for {about} before they can be spent. | |
| `convert_progress_info_refund` | If the swap can't finish in time, it's called off and your ZEC comes back, less a small network fee. | |

**Convert: problems** (shown after 1 min of failures; title `convert_problem_title`, "Taking longer than usual"; retry `convert_problem_retry`, "Try now")

| Key | Text | Flag |
|---|---|---|
| `convert_problem_relayer` | Veylor can't reach the relayer that sends your claim. It keeps trying while it's open. | B, F |
| `reverse_problem_relayer` | Veylor can't reach the relayer that moves your dollars. It keeps trying while it's open. | B, F |
| `convert_problem_relayer_refused` | The relayer keeps turning down this conversion's transaction. Veylor keeps trying while it's open. | B, F |
| `convert_problem_relayer_fee` | The relayer's fee is more than this conversion pays out, or above the 2 USDC limit, so Veylor waits for it to come down. | B, N |
| `convert_problem_ethereum` | Veylor can't reach Ethereum right now. It keeps trying while it's open. | B, F |
| `convert_problem_railgun` | Railgun isn't accepting deposits right now, so Veylor holds off claiming. If it doesn't reopen in time, the swap is called off and your ZEC comes back. | B |
| `convert_problem_wallet` | Veylor couldn't complete this step with your Zcash wallet. It will keep trying while open and unlocked. | B |
| `convert_problem_unpayable` | Your wallet can't pay the deposit right now, for example because the network fee went up. Veylor keeps trying. If it still can't pay in time, the swap ends and nothing is sent. | B |
| `convert_problem_tokens` | Veylor can't get this conversion's token right now. It keeps trying while it's open. | B, T, F |
| `convert_problem_rejected` | The Zcash network turned down a transaction of this conversion. Veylor keeps sending it until it goes through or expires. | B |
| `convert_problem_mismatch` | What's on the chain doesn't match this conversion, so Veylor only brings your funds back. | B |
| `convert_problem_unexpected` | Something went wrong. Veylor keeps trying while it's open. | B, F |

**Convert: results (forward)**

| Key | Text | Flag |
|---|---|---|
| `convert_result_paid_title` | Dollars on their way | |
| `convert_result_paid_body` | {$} is in your private balance. Railgun screens new funds for {about} before they can be spent. | |
| `convert_result_screened_body` | {$} is in your private balance, ready to use. | |
| `convert_result_refunded_title` | Your ZEC came back | |
| `convert_result_refunded_maker` | The market maker called the swap off, so your ZEC came back to your wallet, less a small network fee. | |
| `convert_result_refunded_late` | The swap couldn't be completed in time, so it was called off and your ZEC came back, less a small network fee. | |
| `convert_result_nothing_title` | Nothing was sent | |
| `convert_result_quote_expired` | The quote expired before the market maker took it. Your ZEC never left your wallet. | |
| `convert_result_maker_refused` | The market maker turned the conversion down. Your ZEC never left your wallet. | |
| `convert_result_maker_unavailable` | The market maker isn't taking conversions right now. Your ZEC never left your wallet. | |
| `convert_result_never_opened` | The swap never opened on Ethereum. Your ZEC never left your wallet. | |
| `convert_result_mismatch` | The swap on Ethereum didn't match its quote, so Veylor didn't send your ZEC. | B |
| `convert_result_window_missed` | The swap opened too late to finish safely, so Veylor didn't send your ZEC. | B |
| `convert_result_maker_cancelled` | The market maker called the swap off before your ZEC was sent. Your ZEC never left your wallet. | |
| `convert_result_view_balance` | View private USD | |
| `convert_result_try_again` | Try again | |

**Reverse: progress, results and actions**

| Key | Text | Flag |
|---|---|---|
| `reverse_accepting` | Preparing your receiving account | |
| `reverse_review` | Review and approve your payment | S |
| `reverse_step_fund` | Sending private USD to escrow | |
| `reverse_sending` | Sending private USD | S |
| `reverse_confirming` | Confirming escrow | |
| `reverse_receiving` | Waiting for confirmed ZEC | |
| `reverse_ready` | Authorize settlement | |
| `reverse_step_approval_detail` | Your approval is needed to continue. | |
| `reverse_ready_explanation` | The full ZEC deposit is confirmed. Authorize settlement to release your private USD and move ZEC to your shielded wallet. | S |
| `reverse_step_settle` / `reverse_settling` | Settling your conversion / Waiting for settlement | |
| `reverse_sweeping` | Moving ZEC to your shielded wallet | |
| `reverse_sweep_confirmations` | Zcash confirmations: {n} | |
| `reverse_refund_wait` | Waiting until a refund can proceed. Veylor retries while it's open. | B, F |
| `reverse_refunding` | Securing your private refund | |
| `reverse_payout` | Returning your private USD to Railgun | S |
| `reverse_complete` | ZEC received in your shielded wallet | |
| `reverse_refunded` | Private refund paid. Railgun screening may delay availability. | |
| `reverse_cancelled` | Conversion cancelled. No escrow payment remains. | S |
| `reverse_progress_amounts` / `_estimate` | {$} for {zec} after fees / {$} for about {zec} after fees | |
| `reverse_progress_received` | {zec} arrived after fees. | |
| `reverse_result_received` / `_refunded` / `_cancelled` | ZEC received / Refund sent / Conversion cancelled | |
| `reverse_new` | New conversion | |
| `reverse_cancel` | Cancel conversion | |
| `reverse_request_refund` | Request refund | S |
| N `reverse_cancel_confirm_title` / `_body` | Cancel this conversion? / Your private USD comes back, less the relayer's and Railgun's fees. This can't be undone. | N (confirm sheet, D18) |
| `reverse_refund_requested` | Refund requested. Veylor continues when your refund is available, while it's open. | B, F |
| `reverse_refund_requested_after_ready` | Refund requested. If settlement doesn't finish, Veylor can start returning your funds after {time}. Settlement may still finish before then. | B |
| `reverse_settlement_refund_limit` | Settlement is authorized. A refund can only proceed after {time} if settlement hasn't completed. | |
| `reverse_refund_unavailable` | This conversion has already settled and can no longer be refunded. Veylor will finish moving your ZEC to your wallet. | B |
| `reverse_error` | Unable to complete this step. Your saved conversion resumes after Veylor checks both chains. A payment is never repeated because a request timed out. | B |
| `reverse_error_unconfirmed` | The market maker's ZEC isn't confirmed yet. Try again in a few minutes. | |
| `reverse_error_too_late` | It's too late for this step, so the conversion ends by itself. Anything you paid comes back. | |
| `reverse_error_rescue` | Couldn't recover the refund. Try again in a moment. | |
| `reverse_rescue` | Recover refund | |

**Refunds**

| Key | Text |
|---|---|
| `refunds_title` | Refunds |
| `refunds_subtitle` | Refunds from earlier conversions |
| `refunds_info` | If a refund couldn't enter your private balance, recover it here. Railgun screening may delay availability. |
| `refunds_original_amount` | Original conversion amount |
| `refunds_empty` | No refunded conversions yet. |
| `refunds_checking` | Checking refunds… |
| `refunds_available` | This refund can be recovered. |
| `refunds_no_recovery` | No recovery available right now. Your refund may still be going through Railgun screening. |
| `refunds_recover` | Recover refund |
| `refunds_recovering` | Recovering your refund… |
| `refunds_check_failed` | Couldn't check this refund. Refresh to try again. |
| `refunds_recover_failed` | Couldn't recover this refund. Try again. |
| N `refunds_recover_confirm_title` / `_body` | Recover this refund? / The relayer's fee of {fee} comes out of the refund. |

**Send and withdraw**

| Key | Text | Flag |
|---|---|---|
| `private_usd_send_title` / `private_usd_withdraw_title` | Send privately / Withdraw | |
| `private_usd_send_asset` / `_amount` | Asset / Amount | |
| `private_usd_send_to_private` / `_to_withdraw` | To a Railgun address / To an Ethereum address | |
| `private_usd_send_hint_private` / `_hint_withdraw` | 0zk1… / 0x… | |
| `private_usd_send_invalid_0zk` | That isn't a Railgun 0zk address. | |
| `private_usd_send_invalid_0x` | That isn't an Ethereum address. | |
| `private_usd_send_zero_address` | That's the zero address: anything sent there is lost for good. | |
| `private_usd_send_too_much` | More than you have available. | |
| `private_usd_send_leave_network_fee` | Leave {fee} for the network fee. | |
| `private_usd_send_too_precise` | Use at most {n} decimal place(s). (plural) | |
| `private_usd_send_balance_dropped` | Your available balance is now less than this amount. | |
| `private_usd_send_withdraw_public` | Anyone on Ethereum can see this amount and address. | |
| `private_usd_send_review_title_private` / `_withdraw` | Review send / Review withdrawal | |
| `private_usd_send_review_railgun_fee` | Railgun fee ({bps}%) | |
| `private_usd_send_review_receives` / `_to` | They receive / To | |
| N `send_error_fee_cap` | The network fee is above the 2 USDC limit right now, so nothing was sent. Try again later. | N (D11) |
| `private_usd_send_proving` | Proving your transaction | |
| `private_usd_send_proving_detail` | Your phone builds a zero-knowledge proof so nobody can see what you send. This takes a few seconds. Keep Veylor open. | F |
| `private_usd_send_sending` | Sending | |
| `private_usd_send_done_title_private` / `_withdraw` | Sent / Withdrawn | |
| `private_usd_send_done_body` | {amount} went to {address}. | |
| `private_usd_send_view_tx` / `_view_railscan` | View on Etherscan / View on Railscan | |
| `private_usd_send_not_sent` | Nothing was sent. Try again in a moment. | |
| `private_usd_send_unavailable` | Private sends are unavailable right now. Nothing was sent. Try again later. | |
| `private_usd_send_fee_rose` | The network fee went up to {fee}. Nothing was sent. | |
| `private_usd_send_unconfirmed` | It isn't in a block yet. Check your activity before sending again. | |
| `private_usd_send_info_title` | Sending privately | |
| `private_usd_send_info_step_address` | Enter the amount and the recipient's Railgun address, which starts with 0zk. | |
| `private_usd_send_info_step_proof` | Your phone builds a zero-knowledge proof. This takes a few seconds. | |
| `private_usd_send_info_step_private` | The dollars move inside Railgun: nobody else sees the amount, or who sent and received it. | |
| `private_usd_withdraw_info_title` | Withdrawing makes it public | |
| `private_usd_withdraw_info_step_address` | Enter the amount and an Ethereum address, which starts with 0x. | |
| `private_usd_withdraw_info_step_proof` | Your phone builds a proof, and the dollars leave Railgun for that address. | |
| `private_usd_withdraw_info_note_public` | Once withdrawn, the amount and the address are visible to anyone on Ethereum. | |
| `private_usd_withdraw_info_note_private` | To stay private, don't withdraw the exact amount you just converted, wait a while first, and use a fresh address each time. | |
| `private_usd_withdraw_info_note_fee` | Railgun keeps {bps}% of what you withdraw. | |

**Accounts and reset** (new for veylor; §8.4 refusal)

| Key | Text | Flag |
|---|---|---|
| N `delete_unfinished_title` | Conversion in progress | N |
| N `delete_unfinished_body` | This account has {n} unfinished private USD conversion(s). Only this account can recover their funds, so deleting it now can lose them. Keep Veylor open until they finish or are refunded. | N, F (plural) |
| N `reset_unfinished_body` | Your wallet has {n} unfinished private USD conversion(s). Only this wallet can recover their funds, so resetting now can lose them. | N (plural) |
| N `delete_anyway` | Delete anyway | N |
| N `reset_anyway` | Reset anyway | N |
| N `accounts_pending_conversions` | {n} conversion(s) in progress | N (plural; beside the swap pending count) |

**Where the copy lives.** veylor keeps UI strings inline in widgets (for example `mobile_swap_review_content.dart:116`); there is no ARB. Put them in `lib/src/features/private_usd/private_usd_copy.dart` as `const` strings and builder functions, so tests and Widgetbook assert on one source (AGENTS.md: "When editing existing copy, also update widgetbook fixtures and tests"). Map `ApiPrivateUsdErrorCode` (§8.2) to these strings in one `privateUsdErrorMessage(code)` function, mirroring `pu/PrivateUsdFailure.kt`.

### 9.7 Widgetbook fixtures and capture scenarios

All of them use deterministic fakes: provider overrides with fixed balances, records and times. There is no WebView, Rust, network or clock (AGENTS.md "Figma Visual Verification"). Register them in `lib/widgetbook/` (home use cases through `_buildMobileHomeUseCase`, `lib/widgetbook/screen_use_cases.dart:3310`; a new `private_usd` folder in `widgetbook_app.dart`). Add `FigmaCompareScenario(desktop: false, mobile: true)` entries in `lib/figma_compare/figma_compare_scenarios.dart`. Capture both themes:

```bash
scripts/figma-compare.sh widget --form-factor mobile --scenario <id> --theme dark
```

As built in M3 (D-28): the six `mobile-home-private-usd*` strip scenarios without the two banners, and `mobile-private-usd-{default,empty,first-load,refresh-failed,blocked}`. The fixtures live in `lib/widgetbook/private_usd_use_cases.dart`; the home ones pass `privateUsdBalance` (and `privacyModeEnabled`) to `_buildMobileHomeUseCase`. The banners arrive with M5, `payment-pending` with M7, and `tor-unavailable` is moot (D-22). The default screen has no activity rows until M5 and M7.

As built in M7 (D-101): the nine send rows below and `mobile-private-usd-payment-pending`, in `lib/widgetbook/private_usd_send_use_cases.dart` (the payment-pending screen in `private_usd_use_cases.dart`); `mobile-private-usd-send-done` shows Etherscan only. `mobile-private-usd-default` now has Send, Withdraw and a send row.

As built in M6 (D-87): the twelve reverse and refunds rows below plus `mobile-private-usd-reverse-proving` (the payment's proof at 42 %), in `lib/widgetbook/private_usd_reverse_use_cases.dart`; `mobile-home-private-usd-attention` passes `privateUsdReverseConversions` to `_buildMobileHomeUseCase`. The forward convert fixture shows the direction toggle.

As built for the windows contract (D-137): `mobile-private-usd-{bridge-off,other-deployment}`, `mobile-private-usd-progress-{unwinding,other-deployment}` and `mobile-private-usd-reverse-other-deployment`. The preview forward record carries a late claim time an hour after `t1`.

As built in M5 (D-56): the forward rows, `mobile-home-private-usd-converting` (through `_buildMobileHomeUseCase`'s `privateUsdConversions`), `mobile-private-usd-convert{,-quoting,-insufficient,-syncing}`, `mobile-private-usd-review{,-expired,-tor-off}` and `mobile-private-usd-progress{,-opening-slow,-problem,-paid,-refunding,-refunded,-nothing-sent}`; `mobile-private-usd-default` now has a converted and a called-off row and the Convert button. `mobile-home-private-usd-attention` is a reverse banner and arrives with M6.

| Scenario id | State |
|---|---|
| `mobile-home-private-usd` | strip with balance, `≈ ZEC` |
| `mobile-home-private-usd-unknown` | "—" (not yet used) |
| `mobile-home-private-usd-loading` | "Loading…" |
| `mobile-home-private-usd-arriving` | `+$Y` accent |
| `mobile-home-private-usd-blocked` | danger colour |
| `mobile-home-private-usd-hidden` | privacy mode |
| `mobile-home-private-usd-converting` | forward banner, "Waiting for confirmations · 1 of 2" |
| `mobile-home-private-usd-attention` | reverse `AWAITING_READY` banner |
| `mobile-private-usd-default` | buckets (available, arriving, processing), activity rows, receive address |
| `mobile-private-usd-empty` | empty state |
| `mobile-private-usd-first-load` | first load at 42% |
| `mobile-private-usd-refresh-failed` | last known balance plus error |
| `mobile-private-usd-blocked` | "Screening refused" row |
| `mobile-private-usd-payment-pending` | spending note, Send/Withdraw disabled |
| `mobile-private-usd-bridge-off` | no Bridge, the empty card points to Receive (mainnet for now) |
| `mobile-private-usd-tor-unavailable` | fallback notice |
| `mobile-private-usd-convert` | ZEC→USD amount with a quote ledger and countdown |
| `mobile-private-usd-convert-quoting` | "Getting quote…" |
| `mobile-private-usd-convert-insufficient` | "Not enough ZEC…" |
| `mobile-private-usd-convert-syncing` | catch-up line, max disabled |
| `mobile-private-usd-convert-reverse` | USD→ZEC amount |
| `mobile-private-usd-review` | forward review |
| `mobile-private-usd-review-expired` | "Quote expired", "Refresh quote" |
| `mobile-private-usd-review-tor-off` | disclosure visible |
| `mobile-private-usd-review-reverse` | reverse review rows, keep-open note, deadline |
| `mobile-private-usd-progress` | forward confirming |
| `mobile-private-usd-progress-opening-slow` | "Call it off" |
| `mobile-private-usd-progress-problem` | problem card |
| `mobile-private-usd-progress-paid` | arriving/screening |
| `mobile-private-usd-progress-refunding` | refund step |
| `mobile-private-usd-progress-unwinding` | the maker's refund, then the ZEC home; the late claim time |
| `mobile-private-usd-progress-refunded` | result |
| `mobile-private-usd-progress-nothing-sent` | result |
| `mobile-private-usd-reverse-funding` | `AWAITING_FUNDING` with cost changed |
| `mobile-private-usd-reverse-ready` | "Authorize settlement" |
| `mobile-private-usd-reverse-settling` | refundAfter note |
| `mobile-private-usd-reverse-receiving` | sweep confirmations |
| `mobile-private-usd-reverse-complete` | result |
| `mobile-private-usd-reverse-refund-wait` | cancel requested |
| `mobile-private-usd-reverse-refunded` | "View refunds" |
| `mobile-private-usd-refunds` | rows: checking, recoverable, none, check failed |
| `mobile-private-usd-refunds-empty` | empty |
| `mobile-private-usd-send` | form, valid |
| `mobile-private-usd-send-invalid` | invalid 0zk |
| `mobile-private-usd-withdraw-zero` | zero address |
| `mobile-private-usd-send-leave-fee` | leave fee |
| `mobile-private-usd-send-review` | private review |
| `mobile-private-usd-withdraw-review` | public notice |
| `mobile-private-usd-send-proving` | 42% |
| `mobile-private-usd-send-done` | Etherscan / Railscan |
| `mobile-private-usd-send-unconfirmed` | pending |

Widget tests for these screens are mobile-tagged (`@Tags(['mobile'])`) and compare against token constants (§10). Fixtures must not reference `assets/**/desktop/` artwork. The private badge and any Private USD icon go in shared asset paths, as lossless WebP if raster.

## 12. Source map

| What | Where |
|---|---|
| Reference app | `~/dev/zapp/zapp-android`, branch `release/4.7.0`. PR #79 `feature/private-usd-ui` was merged as `e5f6fc621` (base `a3a3f88b1`). Full feature diff: `git diff a3a3f88b1 HEAD`. Post-merge follow-ups: `5441d95f0` (keyed RPC before publicnode), `f400d24c6` (Infura hosts for the Railgun page), `60bcf0b30` (send/withdraw toggle removed). |
| Protocol, services, crypto | `~/dev/zapp/zecSwap-mainnet-beta`, branch `feature/mainnet-beta` (`d69e3fb`). The newest branch, holding the mainnet beta records (`deployments/mainnet-beta.json`, `sepolia-terms-hash.json`, `sepolia-tokens.json`). zapp-android pins zecSwap `9b52dfc`. |
| Internal handoffs (gitignored) | `~/dev/zapp/zecSwap/docs/local/{android.md, plan.md, private-usd.md, PR8-REVIEW.md}`. `android.md` §2, §6 and §6b give the client flow step by step, including the contract selectors and custom errors. |
| Public protocol docs | `zs/docs/{reverse-flow.md, railgun-sends.md, tokens.md, deployment.md}` and `za/docs/android-reverse-swap.md` (partly stale, §5) |
| Known-answer vectors | `cargo run -p zecswap-client --example vectors` (in zecSwap) |

**Per component.**

| Component | zapp-android / zecSwap source | veylor target |
|---|---|---|
| Swap driver, forward | `of/AtomicSwapDriver.kt`, `AtomicSwapDeposits.kt`, `AtomicSwapClaim` (in the driver), `AtomicSwapModels.kt`, `SwapChecks.kt`, `SwapTerms.kt`, `SwapWire.kt`, `SwapTypes.kt`, `ZcashTransactions.kt`; Rust reference `zc/user.rs` | `rust/src/wallet/private_usd/forward.rs`, `models.rs`, `terms.rs` |
| Swap driver, reverse | `of/ReverseSwapDriver.kt`, `ReverseSwapModels.kt`, `ReverseSwapVerifier.kt`, `ReverseSwapRefunds.kt`, `ReverseFundingTerms.kt`, `ReverseFundingCalls.kt`, `ReverseFundingSubmission.kt`; `ua/ReverseSwapFundingImpl.kt`; Rust reference `zc/reverse.rs` | `reverse.rs` |
| HTTP clients | `of/SwapClients.kt`, `RailgunSendsClient.kt`; `zapi/{lib,service,relayer}.rs`; `zc/api.rs` | `maker_client.rs`, `relayer_client.rs` |
| Chain reads | `of/AtomicSwapChain.kt`, `AtomicSwapSeams.kt`; `zs/contracts/src/ZecSwap.sol` | `evm_rpc.rs` |
| Index allocation | `of/SwapIndices.kt` | `indices.rs` |
| Tokens | `of/SwapTokens.kt`; `ua/AtomicSwapTokens.kt`, `ua/AtomicSwapAttestation.kt`; `zs/crates/zecswap-tokens`; `zs/crates/zecswap-jni/src/tokens.rs` (the four calls) | `tokens.rs`; `PrivateUsdAttestationHandler.kt` |
| Joint account and sweep (behaviour) | `ua/JointAccounts.kt`, `ua/AtomicSwapZcashImpl.kt`, `ua/SwapZcashTransactions.kt`; zecSwap's own wallet `zs/crates/zecswap-chain/src/zcash/wallet.rs` | `joint.rs`, `send.rs`, `pczt.rs` |
| Native primitives glue | `zs/crates/zecswap-jni/src/ops.rs:160-265` | `keys.rs` |
| Loop timing and problems | `ua/SwapLoop.kt`, `ua/AtomicSwapRepository.kt`, `ua/ReverseSwapRepository.kt`, `ua/AtomicSwapStage.kt`, `ua/ReverseSwapStage.kt` | `private_usd_engine_loop.dart`, `private_usd_status_presentation.dart` |
| Persistence shapes | `ua/AtomicSwapStoreImpl.kt`, `ua/ReverseSwapStoreImpl.kt`, `of/AtomicSwapModels.kt:209-292` (serializer); `SwapRecordStorageTest` | `store.rs` |
| Pinned config | `ua/AtomicSwapMainnet.kt:18-79`, `ua/AtomicSwapTestnet.kt:18-81`, `of/SwapDeployment.kt`, `ua/AtomicSwapDeployment.kt:41-50`, `ui/common/privateusd/PrivateUsdTokens.kt` | `deployment.rs` |
| Railgun keys | `ui/common/provider/RailgunMnemonicProvider.kt`, `RailgunKeyProvider.kt`; `za/evm-lib/.../hd/{Bip32,Bip85,EvmKeyDerivation}.kt`; `zs/crates/zecswap-railgun` | `railgun_keys.rs` |
| Railgun host | `rl/src/main/java/xyz/justzappit/railgun/` (`RailgunWebViewHost.kt` 305 lines, `RailgunChannel.kt` 67, `RailgunProtocol.kt` 298, `RailgunWallet.kt` 197, `RailgunModels.kt` 250, `RailgunReverseFunding.kt` 55, `RailgunException.kt` 37, `Bech32m.kt`); `rl/web/` | `android/app/src/main/kotlin/com/keplr/vizor/railgun/`; `android/railgun-web/`; Dart models |
| Engine wrapper and balance | `ui/common/repository/{RailgunEngine,RailgunWalletRepository}.kt`; `ui/common/privateusd/{PrivateUsdBalanceRepository,PrivateUsdBalanceCache}.kt` | `lib/src/features/private_usd/services/` |
| Sends | `ui/common/privateusd/{PrivateUsdSender,PrivateUsdSendLog,PrivateUsdSpendGuard,PrivateUsdRelayer}.kt` | `private_usd_sender.dart`, `relayer_client.rs` |
| UI | `pu/{.,convert,progress,refunds,reverse,send,widget}/`; `ui/screen/tabs/view/{WalletBalanceCard,WalletHomeView}.kt` | `lib/src/features/private_usd/screens/mobile/`, `widgets/mobile/`, `mobile_home_screen.dart` |
| Copy | `za/ui-lib/src/main/res/ui/private_usd/values/strings.xml` (341 lines) | `lib/src/features/private_usd/private_usd_copy.dart` (§9.6) |

**The 17-line Zakura diff for `zecswap-core` (E1).** The exact manifest and source diff that built and passed all 24 tests on 2026-10-13 (a scratch copy of `zs/crates/zecswap-core` at `d69e3fb`). Use them for the M0.1 local checkout and hand them to the owner for E1.

`[dependencies]` and `[dev-dependencies]` (replace the workspace-inherited ones; keep `edition = "2024"`):

```toml
[dependencies]
blake2b_simd = "1"
ff = "0.14"
group = "0.14"
k256 = { version = "0.13", default-features = false, features = ["ecdsa", "std"] }
orchard = { package = "zakura-orchard", version = "=2.0.0", default-features = false, features = ["std"] }
pasta_curves = { package = "zakura-pasta-curves", version = "=2.0.0" }
pczt = { package = "zakura-pczt", version = "=0.1.0-rc5", default-features = false, features = ["std", "orchard", "signer"] }
rand = { version = "0.10", default-features = false, features = ["sys_rng"] }
sha3 = "0.10"
zcash_address = { package = "zakura-address", version = "=2.0.0" }
zcash_note_encryption = "0.4.2"
zcash_protocol = { package = "zakura-protocol", version = "=2.0.0" }
zeroize = { version = "1", features = ["zeroize_derive"] }

[dev-dependencies]
incrementalmerkletree = "0.8"
orchard = { package = "zakura-orchard", version = "=2.0.0", features = ["circuit"] }
pczt = { package = "zakura-pczt", version = "=0.1.0-rc5", features = ["io-finalizer", "prover", "spend-finalizer", "tx-extractor", "zcp-builder"] }
rand_chacha = "0.10"
shardtree = "0.7"
zcash_primitives = { package = "zakura-primitives", version = "=2.0.0" }
zcash_protocol = { package = "zakura-protocol", version = "=2.0.0", features = ["local-consensus"] }
```

Source diff (`src/`; the test-file changes are the three no-RNG calls below, `enc_ciphertext.0` → `enc_ciphertext`, the import line, and deleting `sweep_destination_takes_either_revision_but_refuses_metadata`):

```diff
--- a/src/joint.rs
+++ b/src/joint.rs
-use zcash_address::unified::{self, Encoding, Revision, Uitem};
+use zcash_address::unified::{self, Encoding};
@@ pub fn ufvk
-        unified::Ufvk::try_from_items(
-            Revision::R0,
-            vec![Uitem::Data(unified::Fvk::Orchard(self.fvk.to_bytes()))],
-        )
+        unified::Ufvk::try_from_items(vec![unified::Fvk::Orchard(self.fvk.to_bytes())])
@@ pub fn unified_address
-        unified::Address::try_from_items(Revision::R0, vec![Uitem::Data(receiver)])
+        unified::Address::try_from_items(vec![receiver])
--- a/src/sweep.rs
+++ b/src/sweep.rs
@@ pub fn recipient
-        let (actual_network, _, address) = unified::Address::decode(address)
+        let (actual_network, address) = unified::Address::decode(address)
             .map_err(|_| policy("sweep destination must be a unified address"))?;
-        // Metadata such as an expiry would have to be honoured, so it is refused, not ignored.
-        if !address.metadata_items().is_empty() {
-            return Err(policy("sweep destination must not carry address metadata"));
-        }
@@ fn recover
-    orchard::pczt::Action: zcash_note_encryption::ShieldedOutput<D>,
+    orchard::pczt::Action: zcash_note_encryption::ShieldedOutput<D, { zcash_note_encryption::ENC_CIPHERTEXT_SIZE }>,
```

The joint UA and UFVK this build produces equal upstream's (§5.5).

- **`zakura-address` has no `Revision`/`Uitem`.** `try_from_items(items)` takes one argument, and `decode` returns `(net, addr)`. That changes 2 sites in `joint.rs` and 1 in `sweep.rs`, and drops the ZIP 316 r1 metadata check (there is no r1 to check).
- **`zcash_note_encryption 0.4`'s `ShieldedOutput<D, ENC_CIPHERTEXT_SIZE>`** needs a const-generic bound (`sweep.rs:207`).
- **The test API diffs are trivial:** `finalize_io()`, `create_ironwood_proof(&pk)` and `extract()` take no RNG.
- **veylor's matching seams:**
  - `FullViewingKey::from_bytes(&[u8;96])` is public (`zo/src/keys.rs:440`). It checks only that `ak` is a non-identity point with even `y`, that `nk` and `rivk` are canonical, and that `ivk ≠ 0` (`keys.rs:206-220, 440-455`).
  - `redpallas::SigningKey: TryFrom<[u8;32]>` and `randomize` are public (`zo/src/primitives/redpallas.rs:41, 53`).
  - zakura-pczt has `SpendAuthSignature::from_parts`, `apply_orchard_spend_auth_signature` (routing to Orchard or Ironwood), `apply_ironwood_signature` and `extract_orchard_spend_auth_signatures` (`wl/librustzcash/pczt/src/roles/signer/mod.rs:48-67, 91, 405-422, 478-487`). veylor's Keystone and Ledger paths already use them (`rust/src/wallet/sync/pczt.rs:2158`; `rust/src/wallet/ledger/mod.rs:1109`; Ironwood external signatures in tests at `pczt.rs:3651`).
  - Import as `AccountPurpose::Spending { derivation: None }`, never `ViewOnly`: a view-only account "will not track spend information" (`wl/librustzcash/zcash_client_backend/src/data_api.rs:618-624`). The Orchard viewing key trial-decrypts Ironwood outputs (`wl/.../zcash_client_backend/src/scanning.rs:220-262`).
