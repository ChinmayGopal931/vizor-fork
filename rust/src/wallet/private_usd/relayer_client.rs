//! The relayer, which sends the transactions of a user with no Ethereum
//! account (plan reference §5.3; zapp `of/SwapClients.kt`).
//!
//! Every request for a swap carries the swap's terms, and its ticket in the
//! `ZecSwap-Ticket` header where the record keeps one. Never retried here: a
//! request that timed out may have sent its transaction. The fee caps (D11,
//! X6) are the engine's to apply before it signs.

use serde::Serialize;
use zecswap_core::Terms;

use super::deployment::{CLIENT_TIMEOUT, TICKET_HEADER};
use super::models::{
    Amount, Hex, RelayerTerms, ReverseFundingRequest, Sent, Signature, SwapAuthorization, SwapNote,
    SwapPayout, SwapRescue, Ticket, WireTerms, Word,
};
use super::transport::{get_json, post_json, HttpTransport, Service, SwapHttpError};

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

/// A share revealed under a held lock, with the payout that follows it. The
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

    pub(crate) async fn lock_claim(
        &self,
        authorization: &SwapAuthorization,
        terms: &Terms,
        ticket: Option<&Ticket>,
    ) -> Result<Sent, SwapHttpError> {
        self.authorization("/v1/lock-claim", authorization, terms, ticket)
            .await
    }

    /// `POST /v1/claim`: reveals `secret` (`z`, big-endian) and pays out.
    /// Send only under a fresh, held claim lock (plan §3.5 item 5).
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

    pub(crate) async fn lock_refund(
        &self,
        authorization: &SwapAuthorization,
        terms: &Terms,
        ticket: Option<&Ticket>,
    ) -> Result<Sent, SwapHttpError> {
        self.authorization("/v1/reverse/lock-refund", authorization, terms, ticket)
            .await
    }

    /// `POST /v1/reverse/refund`: reveals `secret` under a held refund lock.
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::network_privacy::test_route_policy::lock_route_policy;
    use crate::wallet::private_usd::models::Redacted;
    use crate::wallet::private_usd::transport::{
        test_support::{Reply, TestServer},
        RoutedTransport, SwapErrorCode,
    };

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
    /// the transactions they name, and a 5xx may have sent.
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
        let transport = RoutedTransport::new();
        let relayer = RelayerClient::new(&transport, &format!("{}/relayer", server.url));
        let ticket: Ticket = Redacted(format!("0x{}.{}", "5c".repeat(32), "3f".repeat(32)));
        let authorization = SwapAuthorization {
            swap_id: Hex([0x5c; 32]),
            deadline: 1_790_001_000,
            signature: Hex([9; 65]),
        };

        let answer = relayer
            .lock_claim(&authorization, &terms(), Some(&ticket))
            .await
            .unwrap();
        assert_eq!(answer.transactions.len(), 2);

        let spent = relayer
            .lock_claim(&authorization, &terms(), None)
            .await
            .unwrap_err();
        let SwapHttpError::Refused(refusal) = &spent else {
            panic!("{spent:?}");
        };
        assert_eq!(refusal.code, Some(SwapErrorCode::AlreadySpent));
        assert_eq!(refusal.transactions, vec![[0xef; 32]]);
        assert!(!spent.may_have_sent());

        let gateway = relayer
            .ready(&authorization, &terms(), None)
            .await
            .unwrap_err();
        assert!(gateway.may_have_sent(), "{gateway:?}");

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
        assert_eq!(received[0].path, "/relayer/v1/lock-claim");
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
}
