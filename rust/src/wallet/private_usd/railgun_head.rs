//! Railgun's head as its indexer lists it: the newest commitment, nullifier
//! and unshield. It moves only when Railgun has new events, and asking for it
//! is the same request for every wallet, so a wallet's refreshes follow
//! Railgun's history rather than a timer set by what the wallet expects.

use std::time::Duration;

use serde::Deserialize;

use super::{deployment::Deployment, ErrorCode, PrivateUsdError, Result};
use crate::wallet::routed_http::{RoutedHttp, RoutedRequest};

const TIMEOUT: Duration = Duration::from_secs(20);
const MAX_BODY: usize = 16 * 1024;
/// Longer than any event id the indexer gives.
const MAX_ID_LEN: usize = 256;

/// The one request: the same bytes for every wallet, every time.
pub(crate) const HEAD_QUERY: &str = concat!(
    r#"{"query":"query Head { "#,
    r#"commitments(orderBy: [blockNumber_DESC, treePosition_DESC], limit: 1) { id } "#,
    r#"nullifiers(orderBy: [blockNumber_DESC, nullifier_DESC], limit: 1) { id } "#,
    r#"unshields(orderBy: [blockNumber_DESC, eventLogIndex_DESC], limit: 1) { id } }"}"#,
);

/// Railgun's head on `deployment`'s indexer: the newest event of each list,
/// as one string that changes whenever any of them does.
pub(crate) async fn railgun_head(http: &RoutedHttp, deployment: &Deployment) -> Result<String> {
    let request = RoutedRequest::post(
        deployment.railgun_indexer_url,
        HEAD_QUERY.as_bytes().to_vec(),
        TIMEOUT,
        MAX_BODY,
    )
    .header("content-type", "application/json");
    let response = http.send(request).await.map_err(|error| {
        let code = if error.route_blocked {
            ErrorCode::RouteBlocked
        } else {
            ErrorCode::Other
        };
        PrivateUsdError::new(code, format!("Railgun's indexer unreachable: {error}"))
    })?;
    if !response.is_success() {
        return Err(PrivateUsdError::new(
            ErrorCode::Other,
            format!("Railgun's indexer answered HTTP {}", response.status),
        ));
    }
    head_of(&response.body)
}

#[derive(Deserialize)]
struct Answer {
    data: Option<Lists>,
}

#[derive(Deserialize)]
struct Lists {
    commitments: Vec<Event>,
    nullifiers: Vec<Event>,
    unshields: Vec<Event>,
}

#[derive(Deserialize)]
struct Event {
    id: String,
}

/// The head an answer to [`HEAD_QUERY`] gives. A list the indexer has no
/// event in yet counts as empty.
pub(crate) fn head_of(body: &[u8]) -> Result<String> {
    let unreadable =
        || PrivateUsdError::new(ErrorCode::Other, "unreadable answer from Railgun's indexer");
    let lists = serde_json::from_slice::<Answer>(body)
        .map_err(|_| unreadable())?
        .data
        .ok_or_else(unreadable)?;
    let newest = |events: &[Event]| -> Result<String> {
        match events {
            [] => Ok(String::new()),
            [event] if readable_id(&event.id) => Ok(event.id.clone()),
            _ => Err(unreadable()),
        }
    };
    Ok([
        newest(&lists.commitments)?,
        newest(&lists.nullifiers)?,
        newest(&lists.unshields)?,
    ]
    .join("/"))
}

fn readable_id(id: &str) -> bool {
    id.len() <= MAX_ID_LEN && id.bytes().all(|byte| byte.is_ascii_graphic())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wallet::private_usd::{deployment::deployment, PrivateUsdNetwork};

    #[test]
    fn the_request_is_fixed_json_with_nothing_of_a_wallet() {
        let query: serde_json::Value = serde_json::from_str(HEAD_QUERY).unwrap();
        let text = query["query"].as_str().unwrap();
        assert!(text.starts_with("query Head {"));
        assert_eq!(query.as_object().unwrap().len(), 1, "no variables");
        for list in ["commitments", "nullifiers", "unshields"] {
            assert!(text.contains(&format!("{list}(orderBy: [blockNumber_DESC")));
        }
        assert_eq!(text.matches("limit: 1").count(), 3);
    }

    #[test]
    fn every_network_asks_its_pinned_indexer_over_https() {
        for network in [PrivateUsdNetwork::Mainnet, PrivateUsdNetwork::Testnet] {
            let url = url::Url::parse(deployment(network).railgun_indexer_url).unwrap();
            assert_eq!(url.scheme(), "https");
            assert!(url.username().is_empty() && url.password().is_none());
        }
    }

    #[test]
    fn the_head_names_the_newest_event_of_each_list() {
        let body = br#"{"data":{"commitments":[{"id":"0xaa-1"}],"nullifiers":[{"id":"0xbb-2"}],"unshields":[{"id":"0xcc-3"}]}}"#;
        assert_eq!(head_of(body).unwrap(), "0xaa-1/0xbb-2/0xcc-3");
        let empty = br#"{"data":{"commitments":[],"nullifiers":[],"unshields":[]}}"#;
        assert_eq!(head_of(empty).unwrap(), "//");
    }

    #[test]
    fn any_other_answer_is_unreadable() {
        for body in [
            &br#"{"errors":[{"message":"bad query"}]}"#[..],
            br#"{"data":null}"#,
            br#"{"data":{"commitments":[]}}"#,
            br#"{"data":{"commitments":[{"id":"a"},{"id":"b"}],"nullifiers":[],"unshields":[]}}"#,
            br#"{"data":{"commitments":[{"id":"a b"}],"nullifiers":[],"unshields":[]}}"#,
            br#"{"data":{"commitments":[{"id":7}],"nullifiers":[],"unshields":[]}}"#,
            b"not json",
        ] {
            assert!(head_of(body).is_err(), "{}", String::from_utf8_lossy(body));
        }
        let long = format!(
            r#"{{"data":{{"commitments":[{{"id":"{}"}}],"nullifiers":[],"unshields":[]}}}}"#,
            "a".repeat(MAX_ID_LEN + 1)
        );
        assert!(head_of(long.as_bytes()).is_err());
    }
}
