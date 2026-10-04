<div align="center">

# kanade-manifests

**Community showcase of [kanade](https://github.com/kanadehq/kanade) job / schedule / view / group manifests — copy, tune, register.**

</div>

Every YAML file here is a real, working manifest for
[`kanade`](https://github.com/kanadehq/kanade) — the AD-independent
Windows fleet manager built on NATS/JetStream. Clone this repo (or
`curl` a single file), register it, done:

```powershell
git clone --depth=1 https://github.com/kanadehq/kanade-manifests.git
cd kanade-manifests

kanade job create      configs/jobs/check-disk-space.yaml
kanade schedule create configs/schedules/check-disk-space.yaml
kanade exec check-disk-space --pcs <pc-id>
```

The command-signing manifests are the exception — they carry
placeholders and must go through
[`scripts/rotate-command-keys.ps1`](scripts/rotate-command-keys.ps1)
first; see [Command signing (rollout)](#command-signing-rollout). The NATS
credential manifests work the same way, through
[`scripts/provision-nats-user.ps1`](scripts/provision-nats-user.ps1); see
[NATS role credentials, before the switch](#nats-role-credentials-before-the-switch).

None of this is infrastructure kanade itself depends on — that lives
in [`configs/jobs/installers/`](https://github.com/kanadehq/kanade/tree/main/configs/jobs/installers)
in the main repo. Everything below is operator-authored example
content: health checks, inventory probes, patch/update jobs,
troubleshooting one-shots, security feeds + dashboards, and fleet
targeting groups. Read a file before you register it — several are
opt-in or disruptive by design (see each entry's notes below).

## Layout

```
configs/
├── jobs/        — kanade Job manifests (script body + what it does)
├── schedules/    — cron/interval wiring for a job (when + who + rollout)
├── views/        — SQL-backed Analytics dashboards over job output
└── groups/       — fleet-targeting group definitions (query / members)
scripts/          — operator helper scripts (placeholder fill-in for signing and NATS credential manifests)
```

A job and its schedule share an `id` (e.g. `check-disk-space.yaml` in
both `jobs/` and `schedules/`) — register the job first, then the
schedule that drives it. Not every job has a schedule (some are
ad-hoc-only, like the `troubleshoot` fixes); not every schedule needs
a view (only the two security feeds do).

See [kanadehq/kanade's SPEC §2.4](https://github.com/kanadehq/kanade/blob/main/docs/SPEC.md)
for the full manifest schema, and the main repo's
[README "Authoring jobs"](https://github.com/kanadehq/kanade#authoring-jobs)
for a minimal from-scratch example.

## Health checks & compliance

`check:` jobs — status surfaces on the Client App's Health tab and
the operator SPA's Compliance page. Most pair with a `troubleshoot`
remediation job below via `check.troubleshoot:`.

| Manifest | Schedule | Description |
|---|---|---|
| [`check-av-signature`](configs/jobs/check-av-signature.yaml) | [✓](configs/schedules/check-av-signature.yaml) | Windows Defender antivirus signature age |
| [`check-bitlocker`](configs/jobs/check-bitlocker.yaml) | [✓](configs/schedules/check-bitlocker.yaml) | BitLocker protection status per volume |
| [`check-cert-expiry`](configs/jobs/check-cert-expiry.yaml) | [✓](configs/schedules/check-cert-expiry.yaml) | Soonest-expiring machine certificate (LocalMachine\My) |
| [`check-defender-rtp`](configs/jobs/check-defender-rtp.yaml) | [✓](configs/schedules/check-defender-rtp.yaml) | Defender real-time / tamper protection state (wired to `fix-defender-rtp`) |
| [`check-disk-space`](configs/jobs/check-disk-space.yaml) | [✓](configs/schedules/check-disk-space.yaml) | Free space on the system drive |
| [`check-firewall`](configs/jobs/check-firewall.yaml) | [✓](configs/schedules/check-firewall.yaml) | Windows Firewall enabled on all profiles |
| [`check-nats-user`](configs/jobs/check-nats-user.yaml) | [✓](configs/schedules/check-nats-user.yaml) | NATS role credential present on the machine (presence only, never the value) |
| [`check-pending-reboot`](configs/jobs/check-pending-reboot.yaml) | [✓](configs/schedules/check-pending-reboot.yaml) | Waiting on a reboot (CBS / Windows Update / file-rename) |
| [`check-windows-patches`](configs/jobs/check-windows-patches.yaml) | [✓](configs/schedules/check-windows-patches.yaml) | Pending security updates per PC |
| [`edge-extensions`](configs/jobs/edge-extensions.yaml) | [✓](configs/schedules/edge-extensions.yaml) | Edge installed-extension compliance + inventory, all local users |

## Inventory

Fleet-wide facts, projected into the SPA's Inventory page.

| Manifest | Schedule | Description |
|---|---|---|
| [`inventory-hw`](configs/jobs/inventory-hw.yaml) | [✓](configs/schedules/inventory-hw.yaml) | Hardware snapshot via `Get-CimInstance` |
| [`inventory-sw`](configs/jobs/inventory-sw.yaml) | [✓](configs/schedules/inventory-sw.yaml) | Installed software via Uninstall registry hives + AppX |
| [`inventory-driver`](configs/jobs/inventory-driver.yaml) | [✓](configs/schedules/inventory-driver.yaml) | Device-driver versions/dates via `Win32_PnPSignedDriver` |
| [`inventory-bitlocker-key`](configs/jobs/inventory-bitlocker-key.yaml) | [✓](configs/schedules/inventory-bitlocker-key.yaml) | BitLocker recovery-password escrow per volume |
| [`winget-upgrades`](configs/jobs/winget-upgrades.yaml) | [✓](configs/schedules/winget-upgrades.yaml) | Pending winget upgrades per PC (feeds the KEV "update available?" status) |
| — | [`offline-inventory`](configs/schedules/offline-inventory.yaml) | `runs_on: agent` inventory tick for hosts that go offline before a broker-side schedule fires |

## Security feeds & dashboards

`feed:` jobs pull an external catalog into the `feeds` table; the
matching `views/` manifest cross-references it against fleet
inventory on the SPA's Analytics / Security tabs. Feeds are
`tier: controller` — register on trusted infrastructure only, never
fanned out fleet-wide.

| Manifest | Schedule | View | Description |
|---|---|---|---|
| [`feed-kev`](configs/jobs/feed-kev.yaml) | [✓](configs/schedules/feed-kev.yaml) | [`kev-exposure`](configs/views/kev-exposure.yaml) | CISA Known Exploited Vulnerabilities catalog |
| [`feed-eol`](configs/jobs/feed-eol.yaml) | [✓](configs/schedules/feed-eol.yaml) | [`eol-exposure`](configs/views/eol-exposure.yaml) | endoflife.date release-cycle EOL dates |
| — | — | [`dashboards-fleet`](configs/views/dashboards-fleet.yaml) | Fleet analytics: reliability / access / agent health (charts `obs_event`, not a specific job) |

## Patching & updates

| Manifest | Schedule | Description |
|---|---|---|
| [`windows-update-scan`](configs/jobs/windows-update-scan.yaml) | — | Scan for pending Windows Updates, read-only, no install |
| [`winget-upgrade-all`](configs/jobs/winget-upgrade-all.yaml) | — | Upgrade every winget-managed app to latest |
| [`chrome-update`](configs/jobs/chrome-update.yaml) | — | Update Google Chrome to latest stable via winget |
| [`urgent-patch`](configs/jobs/urgent-patch.yaml) | — | Emergency hotfix install; refuses on an agent that's lost broker contact |

## App installs

Ad-hoc, user-invokable winget wrappers.

| Manifest | Description |
|---|---|
| [`install-7zip`](configs/jobs/install-7zip.yaml) | 7-Zip archiver |
| [`install-slack`](configs/jobs/install-slack.yaml) | Slack desktop app |
| [`install-vscode`](configs/jobs/install-vscode.yaml) | Visual Studio Code |

## Troubleshooting & remediation

One-shot fixes, several wired as a `check:`'s `troubleshoot:` target
(so they show up as the Client App Health tab's "修復する" button).

| Manifest | Description |
|---|---|
| [`fix-defender-rtp`](configs/jobs/fix-defender-rtp.yaml) | Re-enable Defender real-time protection — remediation for `check-defender-rtp` |
| [`fix-teams-cache`](configs/jobs/fix-teams-cache.yaml) | Clear the Microsoft Teams cache for the current user |
| [`flush-dns`](configs/jobs/flush-dns.yaml) | Flush the DNS resolver cache |
| [`restart-print-spooler`](configs/jobs/restart-print-spooler.yaml) | Restart the Windows Print Spooler service |
| [`reset-network-stack`](configs/jobs/example-unlock/reset-network-stack.yaml) | Reset TCP/IP + Winsock — **helpdesk-only, disruptive**; see `example-unlock/` for the `unlock:` gating pattern |

## Observability & diagnostics

On-demand collection and event-log wiring, not periodic checks.

| Manifest | Schedule | Description |
|---|---|---|
| [`collect-broker-health`](configs/jobs/collect-broker-health.yaml) | — | ~3 min NATS/JetStream health capture for fleet-scaling analysis |
| [`collect-diagnostics`](configs/jobs/collect-diagnostics.yaml) | — | Windows diagnostic bundle: event logs, processes, network, agent logs |
| [`collect-winlog-logons-all`](configs/jobs/collect-winlog-logons-all.yaml) | — | All Security logon/logoff events → ObsEvent timeline |
| [`collect-wlan-events`](configs/jobs/collect-wlan-events.yaml) | — | Full Wi-Fi connect/disconnect/assoc/auth history → ObsEvent timeline |
| [`enable-session-audit`](configs/jobs/enable-session-audit.yaml) | [✓](configs/schedules/enable-session-audit.yaml) | Enable the "Other Logon/Logoff Events" audit subcategory, once per PC |
| [`restart-kanade-agent`](configs/jobs/restart-kanade-agent.yaml) | — | Restart the `KanadeAgent` service via a detached one-shot task |

## Setup, onboarding & samples

Reference patterns more than day-1-useful jobs — read the comments,
these are meant to be copied and adapted.

| Manifest | Schedule | Description |
|---|---|---|
| [`kitting-setup`](configs/jobs/kitting-setup.yaml) | [`kitting-once`](configs/schedules/kitting-once.yaml) | First-boot setup pipeline sketch (`per_pc: once`), no real side effects |
| [`show-toast`](configs/jobs/show-toast.yaml) | [`morning-greeting`](configs/schedules/morning-greeting.yaml) | Good-morning toast to the logged-in user |
| [`example-power-plan`](configs/jobs/example-power-plan.yaml) | — | Switch the active power plan to High performance, opt-in setting pattern |
| [`example-show-when/`](configs/jobs/example-show-when/) | — | `detect-myapp-version` + `update-myapp` pair demonstrating `show_when:` (only offer the update job when the detector says it's needed) |

## Command signing (rollout)

**These manifests carry `REPLACE-...` placeholders (public keys, key ids,
the backend fingerprint) that must be filled in through
[`scripts/rotate-command-keys.ps1`](scripts/rotate-command-keys.ps1) before
you apply them — never apply the files as-is. Applying
`enable-command-signing` with a wrong keyring makes hosts refuse every
command, including the one that would fix it. Roll out in order:
distribute the keyring, confirm coverage (the `command-signing-ready` group
and `command_keys` from `GET /api/agents`), and enforce last. The agent reads
its enforcement flag at startup, so enforcement begins at each machine's next
agent restart, not when the job runs.**

The keyring array is replaced, not merged: every revision must list every
key the fleet should trust. The rotate script fills the placeholders into
temporary copies, so no fleet-specific value is committed here.

| Manifest | Schedule | Description |
|---|---|---|
| [`provision-command-keys`](configs/jobs/provision-command-keys.yaml) | [✓](configs/schedules/provision-command-keys.yaml) | Distribute the command-signing public keyring (backend + break-glass) to every agent, once per version |
| [`enable-command-signing`](configs/jobs/enable-command-signing.yaml) | [✓](configs/schedules/enable-command-signing.yaml) | Turn signature enforcement on, one ready machine at a time — **ships `enabled: false`** |
| [`command-signing-ready`](configs/groups/command-signing-ready.yaml) | — | Group of machines that reported a successful verification and hold the current backend key — the only safe targets for enforcement |
| [`rotate-command-keys.ps1`](scripts/rotate-command-keys.ps1) | — | Fills the placeholders into temp copies and applies them in order; dry-run by default |

## NATS role credentials, before the switch

**These manifests carry `REPLACE-...` placeholders and must go through
[`scripts/provision-nats-user.ps1`](scripts/provision-nats-user.ps1); never
apply them as-is. They put the agent role's NATS user and password on every
Windows agent and let you confirm coverage. They do not touch the broker:
switching it from the shared token to per-role users happens elsewhere, and
only after the steps below.**

A machine that is offline when the credential is distributed keeps the old one
and is locked out at the switch, so distribution is a schedule
(`per_pc: once_per_version`) that catches machines up as they return.

Order of operations:

1. **Distribute.** Run the script (dry run by default, `-Apply` to apply). The
   password is read from a hidden prompt (asked twice), a SecureString, or
   `KANADE_NATS_AGENT_PASSWORD`, never from a plain argument by default. The
   existing token is left alone.
2. **Confirm coverage.** `check-nats-user` reports `{"present": true|false}`
   per machine, as SYSTEM. Run the not-ready query (below) until it returns
   nothing; offline machines appear there until they come back and report.
3. **Switch the broker**, elsewhere.

The `nats-user-ready` group lists machines whose check is `ok`, but a group
cannot list machines with no result, which are the dangerous ones. The useful
list is the machines that are **not** ready:

```sql
SELECT hw.pc_id
FROM inventory_facts hw
LEFT JOIN inventory_facts c
       ON c.pc_id = hw.pc_id AND c.job_id = 'check-nats-user'
WHERE hw.job_id = 'inventory-hw'
  AND COALESCE(json_extract(c.facts_json, '$.status'), 'unknown') <> 'ok'
ORDER BY hw.pc_id
```

Group membership can lag by its `refresh` interval and long results can be
truncated, so run the query itself and read the count. Machines with no
`inventory-hw` row are not in the base list either.

Warnings:

- **The password travels inside a job.** It sits in the jobs bucket and in
  retained commands for up to seven days, readable by anything holding the
  current broker credential. That is acceptable only because this is the
  credential every agent already holds. Base64 in the rendered copy is an
  encoding, not secrecy.
- **Backend and break-glass credentials are never distributed this way.**
  They are written on their own hosts by the deployment scripts.
- **Linux and macOS agents** get the pair from their setup scripts; these jobs
  are Windows-only, and those machines are not in the not-ready list.
- **Changing the credential means bumping the job version**, or machines that
  already applied the old one never receive it, and the check keeps reporting
  them ready. The script refuses the committed version and any version at or below the one it last applied from the same machine; on a machine with no such record, `-Apply` needs `-ConfirmVersionBumped`, meaning you checked the registered job's version.
- **Presence is not correctness.** A mistyped password passes the check and
  is locked out at the switch. Keep the switch revertible and watch which
  machines disappear afterwards.

| Manifest | Schedule | Description |
|---|---|---|
| [`provision-nats-user`](configs/jobs/provision-nats-user.yaml) | [✓](configs/schedules/provision-nats-user.yaml) | Write `NatsUser` / `NatsPassword` under the agent's registry key (SYSTEM + Administrators only), once per version |
| [`check-nats-user`](configs/jobs/check-nats-user.yaml) | [✓](configs/schedules/check-nats-user.yaml) | Read-only presence check as SYSTEM; reports no length, hash or prefix |
| [`nats-user-ready`](configs/groups/nats-user-ready.yaml) | — | Group of machines whose latest check is `ok`; header carries the not-ready query |
| [`provision-nats-user.ps1`](scripts/provision-nats-user.ps1) | — | Fills the placeholders into private temp copies and applies them in order; dry-run by default |

## Fleet targeting (groups)

`query:`/`members:` group definitions a schedule's `target:` or an
`exec --groups` can reference.

| Manifest | Description |
|---|---|
| [`clients`](configs/groups/clients.yaml) | Windows client SKUs, excludes Windows Server |
| [`servers`](configs/groups/servers.yaml) | Windows Server SKUs |
| [`hostname-prefix`](configs/groups/hostname-prefix.yaml) | Hosts named `SRV-*` by naming convention |
| [`pilot-ring`](configs/groups/pilot-ring.yaml) | Manually curated early-adopter pilot machines |
| [`win-24h2-clients`](configs/groups/win-24h2-clients.yaml) | Clients still on 24H2 (build 26100), staging for a 25H2 rollout |
| [`nats-user-ready`](configs/groups/nats-user-ready.yaml) | Machines whose `check-nats-user` result is `ok`; see the NATS section for the not-ready query |

## Contributing

Adding a manifest? Keep the category tables above in sync, and lead
the file with a comment block explaining what it does and any
opt-in/disruptive caveats — every existing file follows that
convention. PRs welcome.

## License

[MIT](LICENSE)
