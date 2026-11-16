import '../../core/config/network_config.dart';

/// The project's public mainnet donation address, documented in README.md:
/// an Orchard receiver, which takes Ironwood payments since NU7.
const kVizorDonationAddress =
    'u18sgfmlyjukysawn8svyk5ka0e3faplel07a6g2zafe0rpymtt63cykn02erkrjyt8nerv2sd2lgswnlusd29wdexzfyuly44k5kg2kfw';

bool donationFeatureEnabledForNetwork(String networkName) =>
    networkName.trim() == ZcashNetwork.mainnet.name;
