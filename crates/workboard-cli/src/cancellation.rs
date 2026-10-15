//! Cooperative cancellation for plugin hosts.
//!
//! Catching SIGINT/SIGTERM keeps the host alive long enough to unwind its child
//! process guard, kill the provider's process group and reap its direct child.
//! Check the flag before starting a provider and before applying returned core
//! requests. A cancellation does not prove an external side effect was undone:
//! retain a pending/prepared journal record rather than automatically retrying.
//!
//! SIGKILL cannot be caught. This module makes no cleanup guarantee for SIGKILL,
//! power loss, or descendants that deliberately escape their process group.
//!
//! ctrlc's `termination` feature handles SIGINT, SIGTERM and SIGHUP on a dedicated
//! thread: https://docs.rs/ctrlc/3.5.1/ctrlc/#handling-sigterm-and-sighup
use std::sync::{
    atomic::{AtomicBool, Ordering},
    OnceLock,
};

static CANCELLED: AtomicBool = AtomicBool::new(false);
static INSTALLED: OnceLock<Result<(), String>> = OnceLock::new();

/// Install once, before any optional provider process is launched.
/// Fail closed rather than replacing a signal handler owned by another component.
pub fn install() -> Result<(), String> {
    INSTALLED
        .get_or_init(|| {
            ctrlc::try_set_handler(|| CANCELLED.store(true, Ordering::SeqCst)).map_err(|error| {
                format!("PLUGIN_CANCELLATION_UNAVAILABLE: Could not install termination signal handlers: {error}")
            })
        })
        .clone()
}

/// The flag is monotonic: a cancelled host must never start another provider.
pub fn is_cancelled() -> bool {
    CANCELLED.load(Ordering::SeqCst)
}

/// Returning an error permits normal scope cleanup, including child wait/reap.
pub fn check() -> Result<(), String> {
    if is_cancelled() {
        Err("PLUGIN_CANCELLED: Execution was cancelled. Check the external service before retrying because its result may be uncertain.".into())
    } else {
        Ok(())
    }
}
