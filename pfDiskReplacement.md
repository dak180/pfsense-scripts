## High-Level Overview

`pfDiskReplacement.sh` automates the replacement of a failed or preemptively retired disk in a **ZFS-mirrored pfSense system**, while preserving **bootability, pool integrity, and uptime**.

pfSense is an appliance-oriented operating system. While it supports ZFS, it does not provide a built-in, low-downtime workflow for replacing a single disk in a ZFS mirror. The official guidance typically recommends **reinstalling pfSense and restoring from a configuration backup**, a process that is reliable but requires **full system downtime**.

This script exists to address a different operational goal: **replace a disk in place, without taking the firewall offline**.

---

## What the Script Does

At a high level, the script:

- Enumerates and validates available disks
- Uses a known-good disk as a **partition and boot template**
- Clones the GPT layout onto a new, blank disk
- Recreates boot infrastructure, including:
  - BIOS bootcode (where applicable)
  - EFI System Partitions (ESP)
- Ensures the new disk is **independently bootable**
- Replaces the old disk in the ZFS mirror using stable identifiers
- Preserves labels and `gptid` mappings so ZFS sees consistent devices
- Cleans up safely on success or failure

All destructive actions are confined to the **new disk** until ZFS replacement occurs.

---

## Downtime as the Primary Differentiator

The key difference between this script and the official pfSense recovery workflow is **downtime**.

### Official pfSense Recommendation

Reinstalling pfSense and restoring a configuration backup:

- Requires taking the firewall offline
- Involves reinstalling the OS from media
- Reboots into a fresh system
- Reconstructs storage and boot state
- Typically results in **tens of minutes to hours of outage**

This approach prioritizes **supportability and predictability**, and it is the correct default when:

- Multiple disks are compromised
- System state is unknown
- Simplicity outweighs continuity

---

### This Script's Approach

This script is designed so that:

- pfSense **continues running** during disk preparation
- The replacement disk is fully initialized and bootable *before* ZFS
  involvement
- ZFS resilvering happens live, in the background
- No reboot is required

From a network perspective, the replacement is often **invisible**.

Downtime is reduced to:

- **None**, or
- A minor performance impact during resilvering


### Additional Benefits on Hot-Swap Capable Hardware

On systems that support true drive hot swap, the advantages of this approach are further amplified.

(Actual hot-swap behavior depends on controller, backplane, and firmware support; the script does not attempt to emulate or force hot-swap capability.)

Because the script prepares and replaces the disk while pfSense remains running, a failed or aging drive can often be:

- Replaced with new media without powering down
- Detached from the ZFS mirror immediately
- Physically removed while the system is online

In these environments, disk replacement can be performed with:

- No service interruption
- No reboot
- No maintenance window

This is particularly valuable for rack-mounted appliances and servers where power cycles are disruptive, remote, or operationally expensive.


---

## Why This Matters

### For MSPs

For managed environments, downtime often means:

- SLA violations
- Emergency maintenance windows
- Customer escalation

Using a reinstall-based workflow for a single disk failure can turn a routine hardware task into a service incident.

This script allows disk replacement to be:

- Planned maintenance
- Performed during business hours
- Completed without customer-visible disruption

---

### For Home Labs

For home lab operators:

- Reinstalling pfSense disrupts connectivity and hosted services
- Rebuilding ZFS pools manually can be error prone
- Experimentation carries higher risk

This script enables:

- Incremental hardware maintenance
- Preemptive disk replacement
- Learning ZFS operations without tearing down the system

---

## Design Philosophy

The script deliberately favors:

- **Continuity over reconstruction**
- **Exact reproduction** of boot environments where possible
- **Explicit validation** before destructive steps
- **pfSense-specific correctness**, not generic portability

It does not attempt to replace the official recommendation. Instead, it fills the gap between "do nothing" and "reinstall everything."

---

## Summary

In short:

- The official pfSense recommendation optimizes for certainty, at the cost of
  downtime.
- This script optimizes for **uptime**, assuming one healthy mirror member
  remains.
- Both approaches are valid; they serve different operational priorities.

For environments where continuity matters and the system is otherwise healthy, this script provides a controlled, repeatable way to replace disks **without taking the firewall offline**.
