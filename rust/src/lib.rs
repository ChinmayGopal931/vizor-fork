// The PIR transport's nested async types exceed the default layout query depth.
#![recursion_limit = "256"]

pub mod api;
pub mod ffi;
mod frb_generated;
mod log_redaction;
pub mod migration_preparation;
pub mod network_privacy;
// Anon's archive for Windows's Railgun page host, over a C ABI; Windows's
// HTTP stacks have no SOCKS5 client. Tests run it everywhere.
#[cfg(any(target_os = "windows", test))]
pub mod railgun_archive;
mod railgun_bridge;
mod tor_update_relay;
pub mod wallet;
