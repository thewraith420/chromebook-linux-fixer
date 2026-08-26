// SPDX-License-Identifier: GPL-3.0-or-later
//! Per-user template storage.
//!
//! rust-fp's own get_templates()/set_templates() resolve the path through
//! home_dir(), which is correct for its CLI - that runs as the user. This
//! daemon runs as root, so home_dir() would be /root and every user would
//! share one empty store. fprintd's API is explicitly per-username, so the
//! home directory is resolved from the username instead.
//!
//! The on-disk format is deliberately identical (MessagePack of
//! HashMap<String, Vec<u8>>), so templates enrolled with the rust-fp CLI are
//! visible here and vice versa.

use rust_fp_common::template::Templates;
use std::io::{Error, ErrorKind};
use std::path::PathBuf;

/// Look up a user's home directory in /etc/passwd.
///
/// Deliberately not getpwnam: this avoids pulling in a libc binding for one
/// field, and /etc/passwd is the same source nsswitch consults for local users.
pub fn home_of(username: &str) -> std::io::Result<PathBuf> {
    let passwd = std::fs::read_to_string("/etc/passwd")?;
    for line in passwd.lines() {
        let mut fields = line.split(':');
        if fields.next() == Some(username) {
            // name:passwd:uid:gid:gecos:home:shell
            if let Some(home) = fields.nth(4) {
                return Ok(PathBuf::from(home));
            }
        }
    }
    Err(Error::new(
        ErrorKind::NotFound,
        format!("no such user: {username}"),
    ))
}

pub fn template_path(username: &str) -> std::io::Result<PathBuf> {
    Ok(home_of(username)?.join(".var").join("cros-fp-templates"))
}

pub fn load(username: &str) -> std::io::Result<Templates> {
    let path = template_path(username)?;
    match std::fs::read(&path) {
        Ok(bytes) => rmp_serde::from_slice::<Templates>(&bytes)
            .map_err(|e| Error::new(ErrorKind::InvalidData, format!("{e:?}"))),
        Err(e) if e.kind() == ErrorKind::NotFound => Ok(Templates::default()),
        Err(e) => Err(e),
    }
}

pub fn save(username: &str, templates: &Templates) -> std::io::Result<()> {
    let path = template_path(username)?;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let bytes = rmp_serde::encode::to_vec(templates)
        .map_err(|e| Error::new(ErrorKind::InvalidData, format!("{e:?}")))?;
    std::fs::write(&path, bytes)?;
    // The template is credential material. rust-fp's CLI leaves it 0644;
    // there is no reason for other local users to read it.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(())
}

/// Look up a username's uid in /etc/passwd.
pub fn uid_of(username: &str) -> std::io::Result<u32> {
    let passwd = std::fs::read_to_string("/etc/passwd")?;
    for line in passwd.lines() {
        let mut fields = line.split(':');
        if fields.next() == Some(username) {
            if let Some(uid) = fields.nth(1) {
                return uid.parse().map_err(|_| {
                    Error::new(ErrorKind::InvalidData, format!("bad uid for {username}"))
                });
            }
        }
    }
    Err(Error::new(
        ErrorKind::NotFound,
        format!("no such user: {username}"),
    ))
}

/// Reverse: uid to username, for resolving "the calling user".
pub fn user_of(uid: u32) -> std::io::Result<String> {
    let passwd = std::fs::read_to_string("/etc/passwd")?;
    for line in passwd.lines() {
        let fields: Vec<&str> = line.split(':').collect();
        if fields.len() > 2 && fields[2].parse::<u32>() == Ok(uid) {
            return Ok(fields[0].to_string());
        }
    }
    Err(Error::new(
        ErrorKind::NotFound,
        format!("no user with uid {uid}"),
    ))
}
