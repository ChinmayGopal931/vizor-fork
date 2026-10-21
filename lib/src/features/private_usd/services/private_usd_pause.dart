/// A Private USD step that stopped because the app paused it (a lock, the
/// background, an account change or a drain), not because anything failed.
/// Its caller retries later or says nothing; it is never shown as a failure.
abstract interface class PrivateUsdPause implements Exception {}
