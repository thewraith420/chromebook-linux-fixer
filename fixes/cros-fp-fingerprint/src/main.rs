// SPDX-License-Identifier: GPL-3.0-or-later
//! fprintd-shim — speak fprintd's D-Bus language on behalf of a Chromebook
//! fingerprint MCU.
//!
//! GNOME does not decide whether to offer fingerprint unlock by consulting
//! PAM. GDM and the lock screen ask fprintd, over D-Bus, whether a device
//! exists and has enrolled fingers; only then is a prompt shown and
//! pam_fprintd consulted. That is why swapping in a different PAM module
//! achieves nothing on GNOME, and why libfprint is not actually required:
//! what is required is *something* owning net.reactivated.Fprint that answers
//! correctly.
//!
//! libfprint would be the conventional home for this, but it assumes the host
//! matches prints against images it can see. This sensor matches on-device and
//! never surrenders an image, which is why the community's libfprint driver
//! stalled as an empty skeleton. Implementing the D-Bus contract directly
//! sidesteps that mismatch entirely.
//!
//! Hardware access is rust-fp's driver, unchanged. This is only translation.

mod templates;

use futures::future::join_all;
use log::{error, info, warn};
use rust_fp::drivers::get_drivers;
use rust_fp::fingerprint_driver::{
    EnrollStepOutput, MatchOutput, OpenedFingerprintDriver,
};
use std::error::Error;
use std::sync::Arc;
use zbus::object_server::SignalContext;
use zbus::{connection::Builder, fdo, interface};

use async_std::sync::Mutex;

const MANAGER_PATH: &str = "/net/reactivated/Fprint/Manager";
/// How many touches to allow before falling back to a password.
const MAX_VERIFY_ATTEMPTS: u32 = 5;

const DEVICE_PATH: &str = "/net/reactivated/Fprint/Device/0";

/// fprintd reports enrolment progress in stages. The MCU reports a percentage,
/// so the two are reconciled by mapping percentage onto this many stages.
const ENROLL_STAGES: i32 = 5;

type Driver = Arc<Mutex<Box<dyn OpenedFingerprintDriver>>>;

// ---------------------------------------------------------------- Manager

struct Manager;

#[interface(name = "net.reactivated.Fprint.Manager")]
impl Manager {
    async fn get_devices(&self) -> fdo::Result<Vec<zbus::zvariant::ObjectPath<'_>>> {
        Ok(vec![zbus::zvariant::ObjectPath::try_from(DEVICE_PATH)
            .map_err(|e| fdo::Error::Failed(format!("{e:?}")))?])
    }

    async fn get_default_device(&self) -> fdo::Result<zbus::zvariant::ObjectPath<'_>> {
        zbus::zvariant::ObjectPath::try_from(DEVICE_PATH)
            .map_err(|e| fdo::Error::Failed(format!("{e:?}")))
    }
}

// ----------------------------------------------------------------- Device

struct Device {
    driver: Driver,
    /// Who called Claim. fprintd is per-user, and the template store is too.
    claimed: Option<String>,
    /// The in-flight verify or enrol, if any.
    ///
    /// The driver blocks waiting for a finger that may never arrive, holding
    /// the driver lock the whole time. Without a handle to cancel, a stopped
    /// verify would keep the sensor busy and every later attempt would fail
    /// with Busy/Unavailable - which is exactly what happened before this.
    running: Option<async_std::task::JoinHandle<()>>,
}

impl Device {
    /// Templates in the order the MCU will be given them, plus their labels.
    fn templates_for(user: &str) -> (Vec<String>, Vec<Vec<u8>>) {
        match templates::load(user) {
            Ok(map) => {
                let mut labels: Vec<String> = map.keys().cloned().collect();
                labels.sort();
                let data = labels.iter().map(|l| map[l].clone()).collect();
                (labels, data)
            }
            Err(e) => {
                error!("could not read templates for {user}: {e}");
                (vec![], vec![])
            }
        }
    }

    /// Stop whatever the sensor is doing before asking it to do something else.
    async fn cancel_running(&mut self) {
        if let Some(handle) = self.running.take() {
            handle.cancel().await;
        }
    }

    fn require_claim(&self) -> fdo::Result<String> {
        self.claimed
            .clone()
            .ok_or_else(|| fdo::Error::AccessDenied("device is not claimed".into()))
    }
}

#[interface(name = "net.reactivated.Fprint.Device")]
impl Device {
    // -- properties ------------------------------------------------------

    #[zbus(property, name = "name")]
    fn name(&self) -> String {
        "ChromeOS Fingerprint (cros_fp)".into()
    }

    #[zbus(property, name = "num-enroll-stages")]
    fn num_enroll_stages(&self) -> i32 {
        ENROLL_STAGES
    }

    #[zbus(property, name = "scan-type")]
    fn scan_type(&self) -> String {
        // The sensor is touched, not swiped.
        "press".into()
    }

    #[zbus(property, name = "finger-present")]
    fn finger_present(&self) -> bool {
        false
    }

    #[zbus(property, name = "finger-needed")]
    fn finger_needed(&self) -> bool {
        false
    }

    // -- claim / release -------------------------------------------------

    async fn claim(
        &mut self,
        #[zbus(header)] header: zbus::message::Header<'_>,
        #[zbus(connection)] conn: &zbus::Connection,
        username: String,
    ) -> fdo::Result<()> {
        // Establish who is actually calling, from the bus rather than from
        // anything they told us. Without this, any local user could claim the
        // device as another user and verify against that user's templates -
        // which, for something that gates login, is the whole ballgame. Real
        // fprintd gates this with polkit; this is the same rule its default
        // policy expresses: yourself always, anyone else only as root.
        let caller_uid = match header.sender() {
            Some(sender) => zbus::fdo::DBusProxy::new(conn)
                .await
                .map_err(|e| fdo::Error::Failed(format!("{e}")))?
                .get_connection_unix_user(sender.clone().into())
                .await
                .map_err(|e| fdo::Error::Failed(format!("{e}")))?,
            None => return Err(fdo::Error::AccessDenied("no sender on message".into())),
        };

        // An empty username means "the calling user", per fprintd.
        let user = if username.is_empty() {
            templates::user_of(caller_uid)
                .map_err(|e| fdo::Error::Failed(format!("{e}")))?
        } else {
            username
        };

        let target_uid = templates::uid_of(&user)
            .map_err(|_| fdo::Error::InvalidArgs(format!("no such user: {user}")))?;
        if caller_uid != 0 && caller_uid != target_uid {
            warn!("uid {caller_uid} tried to claim the device as {user} (uid {target_uid})");
            return Err(fdo::Error::AccessDenied(
                "you may only use your own fingerprints".into(),
            ));
        }
        info!("Claim by {user}");
        self.claimed = Some(user);
        Ok(())
    }

    async fn release(&mut self) -> fdo::Result<()> {
        info!("Release");
        self.claimed = None;
        Ok(())
    }

    // -- enrolled finger management --------------------------------------

    async fn list_enrolled_fingers(&self, username: String) -> fdo::Result<Vec<String>> {
        let user = if username.is_empty() {
            self.claimed.clone().unwrap_or_default()
        } else {
            username
        };
        let (labels, _) = Self::templates_for(&user);
        info!("ListEnrolledFingers({user}) -> {labels:?}");
        Ok(labels)
    }

    async fn delete_enrolled_fingers(&mut self, username: String) -> fdo::Result<()> {
        let user = if username.is_empty() {
            self.require_claim()?
        } else {
            username
        };
        templates::save(&user, &Default::default())
            .map_err(|e| fdo::Error::Failed(format!("{e}")))?;
        info!("deleted all templates for {user}");
        Ok(())
    }

    async fn delete_enrolled_fingers2(&mut self) -> fdo::Result<()> {
        let user = self.require_claim()?;
        templates::save(&user, &Default::default())
            .map_err(|e| fdo::Error::Failed(format!("{e}")))?;
        Ok(())
    }

    async fn delete_enrolled_finger(&mut self, finger_name: String) -> fdo::Result<()> {
        let user = self.require_claim()?;
        let mut map = templates::load(&user).map_err(|e| fdo::Error::Failed(format!("{e}")))?;
        map.remove(&finger_name);
        templates::save(&user, &map).map_err(|e| fdo::Error::Failed(format!("{e}")))?;
        Ok(())
    }

    // -- verify ----------------------------------------------------------

    async fn verify_start(
        &mut self,
        #[zbus(signal_context)] ctxt: SignalContext<'_>,
        finger_name: String,
    ) -> fdo::Result<()> {
        let user = self.require_claim()?;
        let driver = self.driver.clone();
        let ctxt = ctxt.to_owned();
        info!("VerifyStart({finger_name}) for {user}");

        self.cancel_running().await;

        // Return immediately and report through VerifyStatus, as fprintd does.
        // Callers block on the signal, not on this method.
        let handle = async_std::task::spawn(async move {
            let (labels, data) = Self::templates_for(&user);
            if data.is_empty() {
                let _ = Device::verify_status(&ctxt, "verify-no-match", true).await;
                return;
            }

            // Tell the caller which finger we are waiting for. This is what
            // produces the visible "Place your finger on the fingerprint
            // reader" prompt: pam_fprintd builds that message when it receives
            // VerifyFingerSelected, combining the finger name with the device's
            // scan-type. Without it the sensor is armed but nothing on screen
            // says so, and an admin dialog looks like it simply hung.
            let _ = Device::verify_finger_selected(&ctxt, &finger_name).await;

            // A real finger on a real sensor does not match every time: skin is
            // dry, the angle is off, the touch is brief. Reporting a single
            // no-match as final drops the user straight to a password prompt,
            // which on a tablet means the on-screen keyboard - the very thing
            // fingerprint unlock exists to avoid.
            //
            // fprintd's protocol already distinguishes these: done=false keeps
            // the prompt live for another touch, done=true ends the attempt. So
            // report the first few failures as retryable and only give up after
            // MAX_VERIFY_ATTEMPTS.
            for attempt in 1..=MAX_VERIFY_ATTEMPTS {
                let result = {
                    let mut d = driver.lock().await;
                    // Stringify the error here: match_templates yields a
                    // Box<dyn Error>, which is not Send, and holding it across
                    // the signal await below would make this task non-Send.
                    d.match_templates(&data).await.map_err(|e| format!("{e:?}"))
                };

                match result {
                    Ok(MatchOutput::Match(m)) => {
                        info!("matched template #{} ({:?})", m.index, labels.get(m.index));
                        // The MCU refines a template on a successful match;
                        // keeping it is what makes recognition improve with use.
                        if let Some(updated) = m.updated_template {
                            if let Some(label) = labels.get(m.index) {
                                if let Ok(mut map) = templates::load(&user) {
                                    map.insert(label.clone(), updated);
                                    if let Err(e) = templates::save(&user, &map) {
                                        warn!("could not save updated template: {e}");
                                    }
                                }
                            }
                        }
                        let _ = Device::verify_status(&ctxt, "verify-match", true).await;
                        return;
                    }
                    Ok(MatchOutput::NoMatch(reason)) => {
                        info!("no match on attempt {attempt}/{MAX_VERIFY_ATTEMPTS} ({reason:?})");
                    }
                    Err(e) => {
                        error!("match failed on attempt {attempt}: {e:?}");
                    }
                }

                if attempt < MAX_VERIFY_ATTEMPTS {
                    // done=false: "that did not work, try again", and the
                    // caller keeps the prompt up rather than falling back.
                    let _ = Device::verify_status(&ctxt, "verify-retry-scan", false).await;
                } else {
                    info!("giving up after {MAX_VERIFY_ATTEMPTS} attempts");
                    let _ = Device::verify_status(&ctxt, "verify-no-match", true).await;
                }
            }
        });
        self.running = Some(handle);
        Ok(())
    }

    async fn verify_stop(&mut self) -> fdo::Result<()> {
        info!("VerifyStop");
        self.cancel_running().await;
        Ok(())
    }

    // -- enrol -----------------------------------------------------------

    async fn enroll_start(
        &mut self,
        #[zbus(signal_context)] ctxt: SignalContext<'_>,
        finger_name: String,
    ) -> fdo::Result<()> {
        let user = self.require_claim()?;
        let driver = self.driver.clone();
        let ctxt = ctxt.to_owned();
        info!("EnrollStart({finger_name}) for {user}");

        self.cancel_running().await;

        let handle = async_std::task::spawn(async move {
            loop {
                let step = {
                    let mut d = driver.lock().await;
                    d.start_or_continue_enroll().await
                };
                match step {
                    Ok(EnrollStepOutput::InProgress(pct)) => {
                        info!("enroll progress {pct}%");
                        let _ = Device::enroll_status(&ctxt, "enroll-stage-passed", false).await;
                    }
                    Ok(EnrollStepOutput::Complete(template)) => {
                        let mut map = templates::load(&user).unwrap_or_default();
                        map.insert(finger_name.clone(), template);
                        match templates::save(&user, &map) {
                            Ok(()) => {
                                info!("enrolled {finger_name} for {user}");
                                let _ =
                                    Device::enroll_status(&ctxt, "enroll-completed", true).await;
                            }
                            Err(e) => {
                                error!("could not save template: {e}");
                                let _ = Device::enroll_status(&ctxt, "enroll-failed", true).await;
                            }
                        }
                        return;
                    }
                    Err(e) => {
                        // A poor capture is normal - ask for the finger again
                        // rather than failing the whole enrolment.
                        warn!("enroll step failed: {e:?}");
                        let _ = Device::enroll_status(&ctxt, "enroll-retry-scan", false).await;
                    }
                }
            }
        });
        self.running = Some(handle);
        Ok(())
    }

    async fn enroll_stop(&mut self) -> fdo::Result<()> {
        info!("EnrollStop");
        self.cancel_running().await;
        Ok(())
    }

    // -- signals ---------------------------------------------------------

    #[zbus(signal)]
    async fn verify_finger_selected(
        ctxt: &SignalContext<'_>,
        finger_name: &str,
    ) -> zbus::Result<()>;

    #[zbus(signal)]
    async fn verify_status(ctxt: &SignalContext<'_>, result: &str, done: bool)
        -> zbus::Result<()>;

    #[zbus(signal)]
    async fn enroll_status(ctxt: &SignalContext<'_>, result: &str, done: bool)
        -> zbus::Result<()>;
}

// ------------------------------------------------------------------- main

async fn open_driver() -> Result<Box<dyn OpenedFingerprintDriver>, Box<dyn Error>> {
    let drivers = get_drivers();
    let compatible = join_all(drivers.iter().map(|d| Box::pin((d.is_compatible)()))).await;
    let mut chosen = None;
    for (index, result) in compatible.into_iter().enumerate() {
        match result {
            Ok(true) if chosen.is_none() => chosen = Some(index),
            Ok(true) => return Err("more than one compatible driver".into()),
            Ok(false) => {}
            Err(e) => warn!("driver {} check failed: {e}", drivers[index].name),
        }
    }
    let index = chosen.ok_or("no compatible fingerprint driver on this machine")?;
    info!("Using driver: {}", drivers[index].name);
    Ok((drivers[index].open_and_init)().await?)
}

#[async_std::main]
async fn main() -> Result<(), Box<dyn Error>> {
    simple_logger::SimpleLogger::new()
        .with_level(log::LevelFilter::Info)
        .init()?;

    let driver: Driver = Arc::new(Mutex::new(open_driver().await?));

    let _conn = Builder::system()?
        .name("net.reactivated.Fprint")?
        .serve_at(MANAGER_PATH, Manager)?
        .serve_at(
            DEVICE_PATH,
            Device {
                driver,
                claimed: None,
                running: None,
            },
        )?
        .build()
        .await?;

    info!("owning net.reactivated.Fprint - GNOME will ask us about fingerprints now");
    std::future::pending::<()>().await;
    Ok(())
}
