//! The maker's quote API.
//!
//! Never retried here: a quote is single-use, and an accept that timed out
//! may have opened a swap.

use serde::Serialize;

use super::deployment::{CLIENT_TIMEOUT, QUICK_TIMEOUT};
use super::models::{
    is_fixed_hex, Address, Hex, MakerInfo, ReverseQuote, SwapAcceptance, SwapAccepted, SwapQuote,
    Word,
};
use super::transport::{get_json, post_json, HttpTransport, Service, SwapHttpError};
use super::{ErrorCode, PrivateUsdError};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct QuoteRequest {
    units: u32,
    payout: Address,
    payout_note: Word,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ReverseQuoteRequest {
    units: u32,
    user: Address,
    refund_note: Word,
}

pub(crate) struct MakerClient<'a, T: HttpTransport> {
    transport: &'a T,
    base_url: String,
}

impl<'a, T: HttpTransport> MakerClient<'a, T> {
    pub(crate) fn new(transport: &'a T, base_url: &str) -> Self {
        Self {
            transport,
            base_url: base_url.trim_end_matches('/').to_owned(),
        }
    }

    fn url(&self, path: &str) -> String {
        format!("{}{path}", self.base_url)
    }

    /// `GET /v1/info`; the caller checks it against the pins.
    pub(crate) async fn info(&self) -> Result<MakerInfo, SwapHttpError> {
        get_json(self.transport, Service::Maker, self.url("/v1/info"), |_| {
            Ok(())
        })
        .await
    }

    /// `POST /v1/quote`: `units` of the token paid to `payout` (the swap's
    /// auth address) into the Railgun note `payout_note` commits to.
    pub(crate) async fn quote(
        &self,
        units: u32,
        payout: [u8; 20],
        payout_note: [u8; 32],
    ) -> Result<SwapQuote, SwapHttpError> {
        let body = QuoteRequest {
            units,
            payout: Hex(payout),
            payout_note: Hex(payout_note),
        };
        post_json(
            self.transport,
            Service::Maker,
            self.url("/v1/quote"),
            &body,
            QUICK_TIMEOUT,
            &[],
            SwapQuote::check_well_formed,
        )
        .await
    }

    /// `POST /v1/quote/{quoteId}/accept`.
    pub(crate) async fn accept(
        &self,
        quote_id: &str,
        acceptance: &SwapAcceptance,
    ) -> Result<SwapAccepted, SwapHttpError> {
        self.accept_at("/v1/quote", quote_id, acceptance).await
    }

    /// `POST /v1/reverse/quote`: `units` of the user's private dollars,
    /// refunded into the note `refund_note` commits to.
    pub(crate) async fn quote_reverse(
        &self,
        units: u32,
        user: [u8; 20],
        refund_note: [u8; 32],
    ) -> Result<ReverseQuote, SwapHttpError> {
        let body = ReverseQuoteRequest {
            units,
            user: Hex(user),
            refund_note: Hex(refund_note),
        };
        post_json(
            self.transport,
            Service::Maker,
            self.url("/v1/reverse/quote"),
            &body,
            QUICK_TIMEOUT,
            &[],
            ReverseQuote::check_well_formed,
        )
        .await
    }

    /// `POST /v1/reverse/quote/{quoteId}/accept`.
    pub(crate) async fn accept_reverse(
        &self,
        quote_id: &str,
        acceptance: &SwapAcceptance,
    ) -> Result<SwapAccepted, SwapHttpError> {
        self.accept_at("/v1/reverse/quote", quote_id, acceptance)
            .await
    }

    async fn accept_at(
        &self,
        prefix: &str,
        quote_id: &str,
        acceptance: &SwapAcceptance,
    ) -> Result<SwapAccepted, SwapHttpError> {
        // The id becomes a path segment: only a well-formed one goes out.
        if !is_fixed_hex(quote_id, 32) {
            return Err(SwapHttpError::Invalid(PrivateUsdError::new(
                ErrorCode::Mismatch,
                "malformed quote id",
            )));
        }
        post_json(
            self.transport,
            Service::Maker,
            self.url(&format!("{prefix}/{quote_id}/accept")),
            acceptance,
            CLIENT_TIMEOUT,
            &[],
            |_: &SwapAccepted| Ok(()),
        )
        .await
    }
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
    use crate::wallet::routed_http::RoutedHttp;

    fn hex(bytes: usize, value: u8) -> String {
        format!("0x{}", format!("{value:02x}").repeat(bytes))
    }

    fn acceptance() -> SwapAcceptance {
        SwapAcceptance {
            user_share: Hex([1; 64]),
            user_proof: Hex([2; 64]),
            viewing_keys: Redacted(Hex([3; 64])),
            token_request: None,
        }
    }

    /// Refusals carry the status, the code and what the service attached; a
    /// dropped connection is no answer, and a success that does not read is
    /// unreadable.
    #[tokio::test]
    async fn classifies_the_makers_answers() {
        let _policy = lock_route_policy();
        let quote = format!(
            r#"{{"quoteId":"{}","maker":"0x2bac02b5032e9092493814c705f156b49e288922","makerShare":"{}","makerProof":"{}","chainId":11155111,"contract":"0x459b0a69e0f736666b66a3ffe0fc17c11f05980d","token":"0x64c4a5cb09fe0b706d4cf24dc0a45fff275d727c","amount":"1000000","depositZat":202021,"expiresAt":1790000300,"later":true}}"#,
            hex(32, 0x22),
            hex(64, 0x0a),
            hex(64, 0x06)
        );
        let accepted = format!(
            r#"{{"swapId":"{}","t0":1790002700,"t1":1790006300,"ticket":"{}.{}","lateWindow":3600}}"#,
            hex(32, 0x5c),
            hex(32, 0x5c),
            "3f".repeat(32)
        );
        let server = TestServer::start(vec![
            Reply::json(200, &quote),
            Reply::json(200, &accepted),
            Reply::Http {
                status: 401,
                headers: vec![(
                    "www-authenticate",
                    r#"PrivateToken challenge="abc", token-key="def""#.into(),
                )],
                body: r#"{"code":"tokenRequired","error":"spend a token"}"#.into(),
            },
            Reply::Http {
                status: 503,
                headers: vec![("retry-after", "7".into())],
                body: r#"{"code":"unavailable","error":"busy"}"#.into(),
            },
            Reply::json(409, r#"{"code":"somethingNew","error":"later"}"#),
            Reply::json(400, "not json"),
            Reply::json(200, r#"{"swapId":"0x12"}"#),
            Reply::Hangup,
        ]);
        let transport = RoutedHttp::new();
        let maker = MakerClient::new(&transport, &format!("{}/maker/", server.url));
        let quote_id = hex(32, 0x22);

        let quote = maker.quote(1_000_000, [4; 20], [5; 32]).await.unwrap();
        assert_eq!(quote.amount.0, 1_000_000);

        // An accept names the deadlines, the ticket and the contract's late
        // window.
        let opened = maker.accept(&quote_id, &acceptance()).await.unwrap();
        assert_eq!((opened.t0, opened.t1), (1_790_002_700, 1_790_006_300));
        assert_eq!(opened.late_window, Some(3_600));
        assert!(opened.ticket_for(&Hex([0x5c; 32])).is_some());

        let token_required = maker.accept(&quote_id, &acceptance()).await.unwrap_err();
        let SwapHttpError::Refused(refusal) = &token_required else {
            panic!("{token_required:?}");
        };
        assert_eq!(refusal.status, 401);
        assert_eq!(refusal.code, Some(SwapErrorCode::TokenRequired));

        let busy = maker.accept(&quote_id, &acceptance()).await.unwrap_err();
        let SwapHttpError::Refused(refusal) = &busy else {
            panic!("{busy:?}");
        };
        assert_eq!(
            (refusal.status, refusal.code),
            (503, Some(SwapErrorCode::Unavailable))
        );
        assert_eq!(refusal.retry_after_secs, Some(7));

        let unknown = maker.accept(&quote_id, &acceptance()).await.unwrap_err();
        assert_eq!(unknown.code(), None);
        assert!(matches!(&unknown, SwapHttpError::Refused(refusal) if refusal.reason == "later"));

        let not_json = maker.accept(&quote_id, &acceptance()).await.unwrap_err();
        assert!(
            matches!(&not_json, SwapHttpError::Refused(refusal) if refusal.reason == "not json")
        );

        let unreadable = maker.accept(&quote_id, &acceptance()).await.unwrap_err();
        assert!(
            matches!(unreadable, SwapHttpError::Unreadable { .. }),
            "{unreadable:?}"
        );

        let hangup = maker.accept(&quote_id, &acceptance()).await.unwrap_err();
        assert!(
            matches!(hangup, SwapHttpError::Unreachable { .. }),
            "{hangup:?}"
        );

        let received = server.received();
        assert_eq!(received[0].path, "/maker/v1/quote");
        let body: serde_json::Value = serde_json::from_slice(&received[0].body).unwrap();
        assert_eq!(body["units"], 1_000_000);
        assert_eq!(body["payout"], format!("0x{}", "04".repeat(20)));
        assert_eq!(
            received[1].path,
            format!("/maker/v1/quote/{quote_id}/accept")
        );
        assert_eq!(received[1].header("content-type"), Some("application/json"));
        assert_eq!(received[1].header("authorization"), None);

        // Nothing listens: no answer.
        let port = std::net::TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let closed = MakerClient::new(&transport, &format!("http://127.0.0.1:{port}"));
        let unsent = closed.info().await.unwrap_err();
        assert!(
            matches!(unsent, SwapHttpError::Unreachable { .. }),
            "{unsent:?}"
        );
    }
}
