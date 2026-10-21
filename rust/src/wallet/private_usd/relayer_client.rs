//! The relayer, which sends the transactions of a user with no Ethereum
//! account.
//!
//! Every request for a swap carries the swap's terms, and its ticket in the
//! `ZecSwap-Ticket` header where the record keeps one. Never retried here: a
//! request that timed out may have sent its transaction. The fee caps are the
//! engine's to apply before it signs.
//!
//! The relayer also broadcasts the wallet's private Railgun sends and
//! withdrawals for a fee note, and its deposits: its terms for sends are held
//! to the deployment's pins, and each post's answer says whether the send is
//! dropped or posted again as the same bytes.

use serde::Serialize;
use zecswap_core::Terms;

use super::deployment::{require_within_fee_cap, Deployment, CLIENT_TIMEOUT, TICKET_HEADER};
use super::deposits::{RescueRequest as DepositRescueRequest, ShieldRequest};
use super::models::{
    Amount, Hex, RailgunSendsTerms, RailgunTransactRequest, RelayerTerms, ReverseFundingRequest,
    Sent, Signature, SwapAuthorization, SwapNote, SwapPayout, SwapRescue, Ticket, WireTerms, Word,
};
use super::transport::{
    get_json, post_json, HttpTransport, Refusal, Service, SwapErrorCode, SwapHttpError,
};

/// The longest wait a relayer's `Retry-After` holds a post for: the hour it
/// holds the notes of a send that reverted. A longer one, which it never
/// asks, would hold a post on a bad answer.
const MAX_RETRY_AFTER_SECONDS: u64 = 60 * 60;

/// How long `refusal` asked to wait, at most [`MAX_RETRY_AFTER_SECONDS`].
pub(crate) fn retry_after(refusal: &Refusal) -> Option<u64> {
    refusal
        .retry_after_secs
        .map(|seconds| seconds.min(MAX_RETRY_AFTER_SECONDS))
}

/// What the relayer did with a Railgun transaction it was asked to send.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum RailgunBroadcast {
    /// Submitted in this transaction, not mined yet: the same bytes posted
    /// again name it.
    Sent([u8; 32]),
    /// Refused (any 4xx but 409): nothing from this proof went, nor will.
    Refused { status: u16 },
    /// `409 alreadySpent`: a note it spends is spent, by these transactions
    /// of the relayer's where it named any. The chain settles it.
    Spent(Vec<[u8; 32]>),
    /// Not known yet, or never answered: the same bytes go again later, no
    /// sooner than `retry_after_secs` (at most an hour) where it asked.
    Retry { retry_after_secs: Option<u64> },
}

/// The relayer as the broadcaster of private sends and withdrawals, held to
/// the deployment's pins.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct SendsBroadcaster {
    pub chain_id: u64,
    pub railgun_proxy: [u8; 20],
    /// The relayer's own `0zk` address, which the fee note pays.
    pub railgun_address: &'static str,
    pub fee_token: [u8; 20],
    /// The least fee a send pays, in the fee token's base units.
    pub min_fee: Amount,
    /// Positive decimal: fee-token base units per 10^18 wei of gas.
    pub fee_per_unit_gas: Option<String>,
    /// Unix seconds the rate is held until; only with a rate.
    pub fee_expires_at: Option<u64>,
    pub max_gas_limit: u64,
    /// Positive decimal wei.
    pub max_gas_price_wei: String,
    pub max_calldata_bytes: u32,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AuthorizationRequest<'a> {
    swap_id: &'a Word,
    terms: &'a WireTerms,
    deadline: u64,
    signature: &'a Signature,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PayoutRequest<'a> {
    swap_id: &'a Word,
    terms: &'a WireTerms,
    note: &'a SwapNote,
    fee: Amount,
    signature: &'a Signature,
}

/// A share revealed in its window, with the payout that follows it. The
/// secret is `z`: never logged.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RevealRequest<'a> {
    swap_id: &'a Word,
    terms: &'a WireTerms,
    secret: Word,
    payout: PayoutRequest<'a>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RescueRequest<'a> {
    swap_id: &'a Word,
    terms: &'a WireTerms,
    note: &'a SwapNote,
    fee: Amount,
    nonce: u64,
    deadline: u64,
    signature: &'a Signature,
}

pub(crate) struct RelayerClient<'a, T: HttpTransport> {
    transport: &'a T,
    base_url: String,
}

impl<'a, T: HttpTransport> RelayerClient<'a, T> {
    pub(crate) fn new(transport: &'a T, base_url: &str) -> Self {
        Self {
            transport,
            base_url: base_url.trim_end_matches('/').to_owned(),
        }
    }

    /// `GET /v1/terms`; the caller checks it against the pins and the cap.
    pub(crate) async fn terms(&self) -> Result<RelayerTerms, SwapHttpError> {
        get_json(
            self.transport,
            Service::Relayer,
            format!("{}/v1/terms", self.base_url),
            |terms: &RelayerTerms| {
                if terms.fee.is_swap_amount(false) {
                    Ok(())
                } else {
                    Err("the relayer's fee is out of range".into())
                }
            },
        )
        .await
    }

    /// The relayer's terms for private sends, held to `pins`: `None` when it
    /// sends none, or none the pins allow (another chain, proxy, `0zk` or fee
    /// token, no positive gas price, or a rate without its expiry). A least
    /// fee above the cap is `RelayerFee`: no send could pay it.
    pub(crate) async fn railgun_sends(
        &self,
        pins: &Deployment,
    ) -> super::Result<Option<SendsBroadcaster>> {
        let terms = self.terms().await?;
        let Some(sends) = terms.railgun_sends.as_ref() else {
            return Ok(None);
        };
        let Some(broadcaster) = pinned_sends(&terms, sends, pins) else {
            log::warn!("private usd: the relayer's terms for sends aren't the pinned ones");
            return Ok(None);
        };
        require_within_fee_cap(broadcaster.min_fee.0)?;
        Ok(Some(broadcaster))
    }

    /// `POST /v1/railgun/transact`: a proved Railgun transaction, sent as it
    /// is. A 409 `alreadySpent` is spent, any other 4xx refused, and anything
    /// else, a lost answer included, unknown.
    pub(crate) async fn railgun_transact(
        &self,
        request: &RailgunTransactRequest,
    ) -> RailgunBroadcast {
        const CONFLICT: u16 = 409;
        match self
            .send("/v1/railgun/transact", request, None, |_: &Sent| Ok(()))
            .await
        {
            Ok(sent) => match sent.transactions.first() {
                Some(transaction) => RailgunBroadcast::Sent(transaction.0),
                // The relayer named no transaction.
                None => RailgunBroadcast::Retry {
                    retry_after_secs: None,
                },
            },
            Err(SwapHttpError::Refused(refusal)) => {
                if refusal.status == CONFLICT && refusal.code == Some(SwapErrorCode::AlreadySpent) {
                    RailgunBroadcast::Spent(refusal.transactions)
                } else if (400..500).contains(&refusal.status) && refusal.status != CONFLICT {
                    RailgunBroadcast::Refused {
                        status: refusal.status,
                    }
                } else {
                    RailgunBroadcast::Retry {
                        retry_after_secs: retry_after(&refusal),
                    }
                }
            }
            Err(_) => RailgunBroadcast::Retry {
                retry_after_secs: None,
            },
        }
    }

    /// `POST /v1/reverse/fund`: the proved Relay Adapt transaction. An empty
    /// answer means a matching escrow already exists.
    pub(crate) async fn fund_reverse(
        &self,
        request: &ReverseFundingRequest,
        ticket: Option<&Ticket>,
    ) -> Result<Sent, SwapHttpError> {
        self.send("/v1/reverse/fund", request, ticket, |sent: &Sent| {
            if sent.transactions.len() <= 1 {
                Ok(())
            } else {
                Err("funding returned several transactions".into())
            }
        })
        .await
    }

    /// `POST /v1/claim`: reveals `secret` (`z`, big-endian) and pays out.
    /// Send only in the claim's window with the margin, judged on one
    /// consistent read just before. `400 rejected` sent nothing; a `503`
    /// asks for the same post again later.
    pub(crate) async fn claim(
        &self,
        secret: &[u8; 32],
        payout: &SwapPayout,
        terms: &Terms,
        ticket: Option<&Ticket>,
    ) -> Result<Sent, SwapHttpError> {
        self.reveal("/v1/claim", secret, payout, terms, ticket)
            .await
    }

    pub(crate) async fn payout(
        &self,
        payout: &SwapPayout,
        terms: &Terms,
        ticket: Option<&Ticket>,
    ) -> Result<Sent, SwapHttpError> {
        self.payout_at("/v1/payout", payout, terms, ticket).await
    }

    pub(crate) async fn ready(
        &self,
        authorization: &SwapAuthorization,
        terms: &Terms,
        ticket: Option<&Ticket>,
    ) -> Result<Sent, SwapHttpError> {
        self.authorization("/v1/reverse/ready", authorization, terms, ticket)
            .await
    }

    /// `POST /v1/reverse/refund`: reveals `secret` once no `ready` of ours
    /// can land, or from `t1`. The relayer answers `503` while a `ready` it
    /// sent may still land.
    pub(crate) async fn refund(
        &self,
        secret: &[u8; 32],
        payout: &SwapPayout,
        terms: &Terms,
        ticket: Option<&Ticket>,
    ) -> Result<Sent, SwapHttpError> {
        self.reveal("/v1/reverse/refund", secret, payout, terms, ticket)
            .await
    }

    pub(crate) async fn refund_payout(
        &self,
        payout: &SwapPayout,
        terms: &Terms,
        ticket: Option<&Ticket>,
    ) -> Result<Sent, SwapHttpError> {
        self.payout_at("/v1/reverse/refund-payout", payout, terms, ticket)
            .await
    }

    pub(crate) async fn rescue(
        &self,
        rescue: &SwapRescue,
        terms: &Terms,
        ticket: Option<&Ticket>,
    ) -> Result<Sent, SwapHttpError> {
        let terms = WireTerms::from(terms);
        let body = RescueRequest {
            swap_id: &rescue.swap_id,
            terms: &terms,
            note: &rescue.note,
            fee: rescue.fee,
            nonce: rescue.nonce,
            deadline: rescue.deadline,
            signature: &rescue.signature,
        };
        self.send("/v1/reverse/rescue", &body, ticket, |_: &Sent| Ok(()))
            .await
    }

    /// `POST /v1/deposits/shield`: a kept deposit, as it was signed.
    pub(crate) async fn deposit_shield(
        &self,
        request: &ShieldRequest,
    ) -> Result<Sent, SwapHttpError> {
        self.send("/v1/deposits/shield", request, None, |_: &Sent| Ok(()))
            .await
    }

    /// `POST /v1/deposits/rescue`: a kept deposit rescue, as it was signed.
    pub(crate) async fn deposit_rescue(
        &self,
        request: &DepositRescueRequest,
    ) -> Result<Sent, SwapHttpError> {
        self.send("/v1/deposits/rescue", request, None, |_: &Sent| Ok(()))
            .await
    }

    async fn authorization(
        &self,
        path: &str,
        authorization: &SwapAuthorization,
        terms: &Terms,
        ticket: Option<&Ticket>,
    ) -> Result<Sent, SwapHttpError> {
        let terms = WireTerms::from(terms);
        let body = AuthorizationRequest {
            swap_id: &authorization.swap_id,
            terms: &terms,
            deadline: authorization.deadline,
            signature: &authorization.signature,
        };
        self.send(path, &body, ticket, |_: &Sent| Ok(())).await
    }

    async fn payout_at(
        &self,
        path: &str,
        payout: &SwapPayout,
        terms: &Terms,
        ticket: Option<&Ticket>,
    ) -> Result<Sent, SwapHttpError> {
        let terms = WireTerms::from(terms);
        let body = payout_request(payout, &terms);
        self.send(path, &body, ticket, |_: &Sent| Ok(())).await
    }

    async fn reveal(
        &self,
        path: &str,
        secret: &[u8; 32],
        payout: &SwapPayout,
        terms: &Terms,
        ticket: Option<&Ticket>,
    ) -> Result<Sent, SwapHttpError> {
        let terms = WireTerms::from(terms);
        let body = RevealRequest {
            swap_id: &payout.swap_id,
            terms: &terms,
            secret: Hex(*secret),
            payout: payout_request(payout, &terms),
        };
        self.send(path, &body, ticket, |_: &Sent| Ok(())).await
    }

    async fn send<B: Serialize>(
        &self,
        path: &str,
        body: &B,
        ticket: Option<&Ticket>,
        check: impl FnOnce(&Sent) -> Result<(), String>,
    ) -> Result<Sent, SwapHttpError> {
        let headers: Vec<(&str, &str)> = ticket
            .map(|ticket| (TICKET_HEADER, ticket.0.as_str()))
            .into_iter()
            .collect();
        post_json(
            self.transport,
            Service::Relayer,
            format!("{}{path}", self.base_url),
            body,
            CLIENT_TIMEOUT,
            &headers,
            check,
        )
        .await
    }
}

fn payout_request<'a>(payout: &'a SwapPayout, terms: &'a WireTerms) -> PayoutRequest<'a> {
    PayoutRequest {
        swap_id: &payout.swap_id,
        terms,
        note: &payout.note,
        fee: payout.fee,
        signature: &payout.signature,
    }
}

/// `sends` as the pins allow them. Without the pin, a gateway that rewrote
/// the terms and kept the post could take the fee note and send the
/// transaction itself.
fn pinned_sends(
    terms: &RelayerTerms,
    sends: &RailgunSendsTerms,
    pins: &Deployment,
) -> Option<SendsBroadcaster> {
    let address = sends.railgun_address.to_ascii_lowercase();
    let is_pinned = terms.chain_id == pins.chain_id
        && sends.railgun_proxy.0 == pins.railgun_proxy
        && super::railgun_keys::is_valid_railgun_address(&address)
        && address == pins.relayer_railgun_address
        && sends.token.0 == pins.token;
    let max_gas_price_wei = positive_decimal(&sends.max_gas_price_wei)?;
    let fee_per_unit_gas = match sends.fee_per_unit_gas.as_deref() {
        // A rate comes with the time it's held until, or it does not read.
        Some(rate) => Some((positive_decimal(rate)?, sends.fee_expires_at?)),
        None => None,
    };
    if !is_pinned || !sends.fee.is_swap_amount(false) {
        return None;
    }
    Some(SendsBroadcaster {
        chain_id: pins.chain_id,
        railgun_proxy: pins.railgun_proxy,
        railgun_address: pins.relayer_railgun_address,
        fee_token: pins.token,
        min_fee: sends.fee,
        fee_per_unit_gas: fee_per_unit_gas.as_ref().map(|(rate, _)| rate.clone()),
        fee_expires_at: fee_per_unit_gas.map(|(_, expires_at)| expires_at),
        max_gas_limit: sends.max_gas_limit,
        max_gas_price_wei,
        max_calldata_bytes: sends.max_calldata_bytes,
    })
}

/// A positive decimal integer of at most 78 digits (`uint256`), without
/// leading zeros.
fn positive_decimal(text: &str) -> Option<String> {
    if text.is_empty() || text.len() > 78 || !text.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let digits = text.trim_start_matches('0');
    (!digits.is_empty()).then(|| digits.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::network_privacy::test_route_policy::lock_route_policy;
    use crate::wallet::private_usd::models::Redacted;
    use crate::wallet::private_usd::transport::{
        test_support::{Reply, TestServer},
        SwapErrorCode,
    };
    use crate::wallet::private_usd::{abi::hex0x, deployment, ErrorCode, PrivateUsdNetwork};
    use crate::wallet::routed_http::RoutedHttp;
    use serde_json::{json, Value};

    fn terms() -> Terms {
        Terms {
            maker: [9; 20],
            token: [3; 20],
            amount: 1_000_000,
            maker_share: zecswap_core::derive_maker_share(&[9; 32], 0)
                .unwrap()
                .public(),
            user_share: zecswap_core::derive_maker_share(&[8; 32], 0)
                .unwrap()
                .public(),
            user: [4; 20],
            t0: 1_790_003_600,
            t1: 1_790_007_200,
            payout_note: [6; 32],
        }
    }

    /// Requests carry the swap's terms and ticket; refusals keep the code and
    /// the transactions they name.
    #[tokio::test]
    async fn classifies_the_relayers_answers() {
        let _policy = lock_route_policy();
        let sent = format!(
            r#"{{"transactions":["0x{}","0x{}"]}}"#,
            "ab".repeat(32),
            "cd".repeat(32)
        );
        let server = TestServer::start(vec![
            Reply::json(200, &sent),
            Reply::json(
                409,
                &format!(
                    r#"{{"code":"alreadySpent","error":"spent","transactions":["0x{}","nope"]}}"#,
                    "ef".repeat(32)
                ),
            ),
            Reply::json(502, "bad gateway"),
            Reply::json(200, &sent),
        ]);
        let transport = RoutedHttp::new();
        let relayer = RelayerClient::new(&transport, &format!("{}/relayer", server.url));
        let ticket: Ticket = Redacted(format!("0x{}.{}", "5c".repeat(32), "3f".repeat(32)));
        let authorization = SwapAuthorization {
            swap_id: Hex([0x5c; 32]),
            deadline: 1_790_001_000,
            signature: Hex([9; 65]),
        };

        let answer = relayer
            .ready(&authorization, &terms(), Some(&ticket))
            .await
            .unwrap();
        assert_eq!(answer.transactions.len(), 2);

        let spent = relayer
            .ready(&authorization, &terms(), None)
            .await
            .unwrap_err();
        let SwapHttpError::Refused(refusal) = &spent else {
            panic!("{spent:?}");
        };
        assert_eq!(refusal.code, Some(SwapErrorCode::AlreadySpent));
        assert_eq!(refusal.transactions, vec![[0xef; 32]]);

        relayer
            .ready(&authorization, &terms(), None)
            .await
            .unwrap_err();

        let funding = ReverseFundingRequest {
            swap_id: Hex([0x5c; 32]),
            chain_id: 11_155_111,
            to: Hex([7; 20]),
            data: "0x12345678".into(),
            value: "0".into(),
        };
        let twice = relayer.fund_reverse(&funding, None).await.unwrap_err();
        assert!(
            matches!(twice, SwapHttpError::Unreadable { .. }),
            "{twice:?}"
        );

        let received = server.received();
        assert_eq!(received[0].path, "/relayer/v1/reverse/ready");
        assert_eq!(
            received[0].header("zecswap-ticket"),
            Some(ticket.0.as_str())
        );
        assert_eq!(received[1].header("zecswap-ticket"), None);
        let body: serde_json::Value = serde_json::from_slice(&received[0].body).unwrap();
        assert_eq!(body["swapId"], format!("0x{}", "5c".repeat(32)));
        assert_eq!(body["deadline"], 1_790_001_000);
        assert_eq!(body["terms"]["amount"], "1000000");
        assert_eq!(body["terms"]["user"], format!("0x{}", "04".repeat(20)));
        assert_eq!(received[2].path, "/relayer/v1/reverse/ready");
        assert_eq!(received[3].path, "/relayer/v1/reverse/fund");
    }

    /// A Railgun send goes out as proved, and each answer says whether to drop
    /// it or post the same bytes again, honouring `Retry-After` up to an hour.
    #[tokio::test]
    async fn railgun_send_answers_say_whether_to_drop_it_or_post_it_again() {
        let _policy = lock_route_policy();
        let hash = format!("0x{}", "ab".repeat(32));
        let held_back = |retry_after: &str| Reply::Http {
            status: 503,
            headers: vec![
                ("content-type", "application/json".into()),
                ("retry-after", retry_after.into()),
            ],
            body: r#"{"code":"unavailable","error":"a send of these notes reverted lately"}"#
                .into(),
        };
        let mut replies = vec![
            Reply::json(200, &format!(r#"{{"transactions":["{hash}"]}}"#)),
            Reply::json(200, r#"{"transactions":[]}"#),
            Reply::json(409, r#"{"code":"alreadySpent","error":"spent"}"#),
            Reply::json(
                409,
                &format!(r#"{{"code":"alreadySpent","error":"spent","transactions":["{hash}"]}}"#),
            ),
            Reply::json(409, r#"{"code":"unavailable","error":"busy"}"#),
        ];
        let refusals = [400, 404, 413, 415, 422];
        replies.extend(refusals.map(|status| Reply::json(status, "not json")));
        replies.extend([500, 503].map(|status| Reply::json(status, "not json")));
        let waits = [
            "1800",
            "86400",
            "Wed, 21 Oct 2026 07:28:00 GMT",
            "-1",
            "1.5",
            "99999999999999999999",
        ];
        replies.extend(waits.map(held_back));
        replies.push(Reply::Hangup);
        let count = replies.len();
        let server = TestServer::start(replies);
        let transport = RoutedHttp::new();
        let relayer = RelayerClient::new(&transport, &format!("{}/relayer", server.url));
        let request = RailgunTransactRequest {
            chain_id: 11_155_111,
            to: Hex([7; 20]),
            data: "0xd8ae136a".into(),
            value: "0".into(),
        };

        let mut answers = Vec::new();
        for _ in 0..count {
            answers.push(relayer.railgun_transact(&request).await);
        }
        let retry = |retry_after_secs| RailgunBroadcast::Retry { retry_after_secs };
        let mut expected = vec![
            RailgunBroadcast::Sent([0xab; 32]),
            retry(None),
            RailgunBroadcast::Spent(Vec::new()),
            RailgunBroadcast::Spent(vec![[0xab; 32]]),
            retry(None),
        ];
        expected.extend(refusals.map(|status| RailgunBroadcast::Refused { status }));
        expected.extend([retry(None), retry(None)]);
        expected.extend([
            retry(Some(1800)),
            retry(Some(MAX_RETRY_AFTER_SECONDS)),
            retry(None),
            retry(None),
            retry(None),
            retry(None),
        ]);
        expected.push(retry(None));
        assert_eq!(answers, expected);

        let received = server.received();
        assert_eq!(received.len(), count);
        let body = format!(
            r#"{{"chainId":11155111,"to":"0x{}","data":"0xd8ae136a","value":"0"}}"#,
            "07".repeat(20)
        );
        for request in received {
            assert_eq!(request.path, "/relayer/v1/railgun/transact");
            assert_eq!(request.header("zecswap-ticket"), None);
            assert_eq!(String::from_utf8(request.body).unwrap(), body);
        }
    }

    /// Only the pinned relayer's terms send, a rate needs its expiry, and the
    /// least fee is held to the 2 USDC cap.
    #[tokio::test]
    async fn railgun_sends_terms_are_held_to_the_pins_and_the_fee_cap() {
        let _policy = lock_route_policy();
        let pins = deployment::deployment(PrivateUsdNetwork::Testnet);
        let mainnet = deployment::deployment(PrivateUsdNetwork::Mainnet);
        let sends = json!({
            "railgunAddress": pins.relayer_railgun_address,
            "railgunProxy": hex0x(&pins.railgun_proxy),
            "token": hex0x(&pins.token),
            "fee": "500000",
            "feePerUnitGas": "2726271000",
            "feeExpiresAt": 1_791_504_000u64,
            "maxGasLimit": 6_000_000u64,
            "maxGasPriceWei": "0200000000000",
            "maxCalldataBytes": 131_072u32,
        });
        let terms = |chain_id: u64, sends: Option<Value>| {
            let mut terms = json!({
                "relayer": hex0x(&pins.relayer),
                "chainId": chain_id,
                "contract": hex0x(&pins.swap_contract().unwrap().address),
                "fee": "20000",
            });
            if let Some(sends) = sends {
                terms["railgunSends"] = sends;
            }
            Reply::json(200, &terms.to_string())
        };
        let edited = |edit: &dyn Fn(&mut Value)| {
            let mut edited = sends.clone();
            edit(&mut edited);
            terms(pins.chain_id, Some(edited))
        };
        let replies = vec![
            terms(pins.chain_id, Some(sends.clone())),
            terms(pins.chain_id, None),
            terms(mainnet.chain_id, Some(sends.clone())),
            edited(&|sends| sends["railgunAddress"] = json!(mainnet.relayer_railgun_address)),
            edited(&|sends| sends["railgunProxy"] = json!(hex0x(&mainnet.railgun_proxy))),
            edited(&|sends| sends["token"] = json!(hex0x(&mainnet.token))),
            edited(&|sends| {
                sends.as_object_mut().unwrap().remove("feeExpiresAt");
            }),
            edited(&|sends| sends["maxGasPriceWei"] = json!("0")),
            edited(&|sends| sends["fee"] = json!("2000001")),
            edited(&|sends| {
                sends["fee"] = json!("2000000");
                sends.as_object_mut().unwrap().remove("feePerUnitGas");
            }),
        ];
        let server = TestServer::start(replies);
        let transport = RoutedHttp::new();
        let relayer = RelayerClient::new(&transport, &format!("{}/relayer", server.url));

        let pinned = relayer.railgun_sends(pins).await.unwrap().unwrap();
        assert_eq!(
            pinned,
            SendsBroadcaster {
                chain_id: pins.chain_id,
                railgun_proxy: pins.railgun_proxy,
                railgun_address: pins.relayer_railgun_address,
                fee_token: pins.token,
                min_fee: Amount(500_000),
                fee_per_unit_gas: Some("2726271000".into()),
                fee_expires_at: Some(1_791_504_000),
                max_gas_limit: 6_000_000,
                max_gas_price_wei: "200000000000".into(),
                max_calldata_bytes: 131_072,
            }
        );
        for case in [
            "no sends",
            "another chain",
            "another 0zk",
            "another proxy",
            "another fee token",
            "a rate without its expiry",
            "no gas price",
        ] {
            assert_eq!(relayer.railgun_sends(pins).await.unwrap(), None, "{case}");
        }
        let error = relayer.railgun_sends(pins).await.unwrap_err();
        assert_eq!(error.code, ErrorCode::RelayerFee);
        let at_cap = relayer.railgun_sends(pins).await.unwrap().unwrap();
        assert_eq!(at_cap.min_fee, Amount(deployment::MAX_RELAYER_FEE));
        assert_eq!(
            (at_cap.fee_per_unit_gas, at_cap.fee_expires_at),
            (None, None),
            "an expiry without a rate holds nothing"
        );
    }
}
