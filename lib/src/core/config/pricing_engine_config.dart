/// The pricing engine that serves the Home portfolio chart's price history.
///
/// `VIZOR_PRICING_ENGINE_BASE_URL` is the server's origin. The default is the
/// zapp pricing engine the owner chose for the chart. The Home price does not
/// use it: that stays on CoinGecko (`VIZOR_COINGECKO_PRICE_BASE_URL`).
///
/// A value that is empty, not `https`, or not a plain origin leaves the chart
/// without market prices: [parsePricingEngineBaseUri] returns `null`, the
/// Settings card offers no price switch, and nothing is ever requested.
library;

const kVizorPricingEngineBaseUrlEnvKey = 'VIZOR_PRICING_ENGINE_BASE_URL';
const kVizorPricingEngineDefaultBaseUrl =
    'https://zapp-pricing-engine.majorworker.workers.dev';
const kVizorPricingEngineBaseUrl = String.fromEnvironment(
  kVizorPricingEngineBaseUrlEnvKey,
  defaultValue: kVizorPricingEngineDefaultBaseUrl,
);

/// The server [raw] names, or `null` when it cannot be used.
///
/// Only an `https` URL with a host is usable, and one that carries no
/// credentials, query or fragment: the request builder adds the path and the
/// query itself, so anything else would be silently dropped or, worse, send
/// something this config did not mean to. A path prefix is kept, for a
/// deployment behind a path-routing proxy.
Uri? parsePricingEngineBaseUri(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  return uri;
}
