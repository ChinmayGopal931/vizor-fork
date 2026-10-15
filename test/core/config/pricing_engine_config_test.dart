import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/config/pricing_engine_config.dart';

void main() {
  test('the default pricing server is the zapp pricing engine over https', () {
    expect(
      kVizorPricingEngineDefaultBaseUrl,
      'https://zapp-pricing-engine.majorworker.workers.dev',
    );
    expect(kVizorPricingEngineBaseUrlEnvKey, 'VIZOR_PRICING_ENGINE_BASE_URL');
    // No define is passed under test, so the build uses the default.
    expect(kVizorPricingEngineBaseUrl, kVizorPricingEngineDefaultBaseUrl);
    expect(
      parsePricingEngineBaseUri(kVizorPricingEngineDefaultBaseUrl)?.host,
      'zapp-pricing-engine.majorworker.workers.dev',
    );
  });

  test('a server is an https origin, or there is none and prices are off', () {
    expect(
      parsePricingEngineBaseUri(
        ' https://prices.example:8443/engine/ ',
      )?.toString(),
      'https://prices.example:8443/engine/',
    );
    for (final unusable in [
      '',
      '   ',
      'http://prices.example',
      'ftp://prices.example',
      'prices.example',
      'https://',
      'https://user:secret@prices.example',
      'https://prices.example?key=1',
      'https://prices.example/#fragment',
      'not a url',
    ]) {
      expect(parsePricingEngineBaseUri(unusable), isNull, reason: unusable);
    }
  });
}
