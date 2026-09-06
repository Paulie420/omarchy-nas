#!/usr/bin/env bash
# lib/nas-common.sh — shared by omarchy-nas-status and omarchy-nas-mountctl.
# Sourced, never executed. Both scripts MUST derive paths through here: if
# status and mountctl disagreed on a target, a nested share would mount at one
# path and be checked at another and read as permanently unmounted.

NAS_HOST="${NAS_HOST:-10.0.0.118}"
NAS_EXPORT_BASE="${NAS_EXPORT_BASE:-/mnt/SpeakerOffice}"
NAS_MOUNT_ROOT="${NAS_MOUNT_ROOT:-/mnt}"

# One optional slash for nested exports (Backup4TB/ISOs). No "..", no absolute
# paths, no whitespace, no shell metacharacters. Anchored at both ends.
# The regex requires each segment to start with alphanumeric, which rejects
# ".", "..", and leading-dash names (like "-rf") in a single expression.
nas_valid_name() {
  [[ $# -eq 1 ]] || return 1
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)?$ ]] || return 1
  return 0
}

# Flatten the one legal slash so two exports cannot collide on basename.
nas_target() { printf '%s/%s\n' "$NAS_MOUNT_ROOT" "${1//\//-}"; }
nas_source() { printf '%s:%s/%s\n' "$NAS_HOST" "$NAS_EXPORT_BASE" "$1"; }
