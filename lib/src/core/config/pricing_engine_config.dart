import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/zec_price_change_provider.dart';

/// The server the portfolio chart asks for ZEC/USD price history. The Home
/// price does not use it: that stays on CoinGecko.
const kVizorPricingEngineBaseUrlEnvKey = 'VIZOR_PRICING_ENGINE_BASE_URL';
const kVizorPricingEngineDefaultBaseUrl =
    'https://zapp-pricing-engine.majorworker.workers.dev';
const kVizorPricingEngineBaseUrl = String.fromEnvironment(
  kVizorPricingEngineBaseUrlEnvKey,
  defaultValue: kVizorPricingEngineDefaultBaseUrl,
);

/// The server [raw] names, or `null` unless it is an `https` URL with a host
/// and no credentials, query or fragment, since the request builder adds its
/// own path and query. A path prefix is kept, for a path-routing proxy.
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

/// Null when the define names no server [parsePricingEngineBaseUri] accepts.
final portfolioPricingEngineBaseUriProvider = Provider<Uri?>(
  (ref) => parsePricingEngineBaseUri(kVizorPricingEngineBaseUrl),
);

/// Whether the chart can be valued at market prices: where Home shows a price,
/// and with a usable pricing server.
final portfolioChartPricesAvailableProvider = Provider<bool>((ref) {
  return ref.watch(zecMarketDataAvailableProvider) &&
      ref.watch(portfolioPricingEngineBaseUriProvider) != null;
});
