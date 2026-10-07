# NinjaOne Device Mover

**Puts every managed endpoint in the right Organization and Location automatically, from the IP address it is actually sitting on.**

Ship **one installer**. Every agent lands in a single holding organization. This script reads each device's IP address, looks it up in your site map, and moves the device to the Organization and Location that subnet belongs to — then keeps it there on a schedule.

It is an external API client. It only ever reads, plus one write — `PATCH /device/{id}` — and it installs nothing on your endpoints.

> This is also what makes per-location cache servers work: a cache server only serves devices in its own Location, so devices have to be in the right Location first.

| | |
|---|---|
| **Time to set up** | ~30 minutes |
| **Default mode** | Dry run — nothing moves until you say so |
| **Scope** | Managed agents. ITAM / unmanaged records are never touched. |
| **Where it runs** | One always-on device, reconciling the whole fleet |

---

## Contents

- [Before you start](#before-you-start)
- [Setup](#setup)
  - [1. Create API credentials](#1-create-api-credentials)
  - [2. Store the credentials in custom fields](#2-store-the-credentials-in-custom-fields)
  - [3. Add the script as an automation](#3-add-the-script-as-an-automation)
  - [4. Find out which subnets you actually have](#4-find-out-which-subnets-you-actually-have-optional)
  - [5. Write the site map](#5-write-the-site-map)
  - [6. Hand the map to the automation](#6-hand-the-map-to-the-automation)
  - [7. Point the schedule at exactly one device](#7-point-the-schedule-at-exactly-one-device)
  - [8. Dry run, review, then go live](#8-dry-run-review-then-go-live)
- [Site map reference](#site-map-reference)
- [Matching modes](#matching-modes)
- [Read before you run it live](#read-before-you-run-it-live)
- [Safety rails](#safety-rails)
- [What it writes](#what-it-writes)
- [If something looks wrong](#if-something-looks-wrong)
- [Running it outside NinjaOne](#running-it-outside-ninjaone)
- [Command-line reference](#command-line-reference)
- [About this tool](#about-this-tool)

### Files in this folder

| File | What it is |
|---|---|
| `Move-NinjaDevices.ps1` | The mover. |
| `ninja-location-map-SAMPLE.csv` | A filled-in example site map. |
| `ninja-location-map.csv` | Your site map. Not included: copy the sample to this name and edit it. |

---

## Before you start

| | |
|---|---|
| **Permission you need** | Enough rights in NinjaOne to create an API client app, create organization custom fields, and add an automation to the script library. |
| **Where it runs** | One always-on Windows device with a NinjaOne agent. It reconciles the entire fleet from that single device. |
| **What you have to author** | One CSV — the site map. Everything else is configuration in the console. |
| **What you should know** | Which IP subnet belongs to which site. If you don't, [step 4](#4-find-out-which-subnets-you-actually-have-optional) finds out for you. |

---

## Setup

### 1. Create API credentials

Go to **Administration → Apps → API → Client app IDs → Add client app**, and set:

| Setting | Value |
|---|---|
| Application platform | **API Services (machine-to-machine)** |
| Scopes | **Monitoring** and **Management**. Leave **Control** off. |
| Allowed grant types | **Client credentials** only — **untick Authorization code**, which is on by default. Once it is unticked, Redirect URIs stops being required. |

> [!IMPORTANT]
> **Copy the client secret on the screen where it is created.** NinjaOne displays it once and never shows it again. If you lose it, delete the client app and make a new one.

---

### 2. Store the credentials in custom fields

The script reads its credentials from three **organization-scoped** custom fields, so nothing sensitive is ever pasted into the script body or a scheduled task's command line.

This is two separate actions in two different places. **Create** the fields first, then **populate** them — creating a field does not give it a value.

**Create** at **Administration → Organizations → Organization custom fields → Add custom field**. That is the **Organizations** section, not Devices — these are organization fields and will not appear on the device custom fields page.

| Field name | Type | Value |
|---|---|---|
| `ninjaoneInstance` | Text | Your console host, e.g. `ca.ninjarmm.com`. With or without `https://` — both work. |
| `ninjaoneClientId` | **Secure** | Client ID from step 1 |
| `ninjaoneClientSecret` | **Secure** | Client secret from step 1 |

**Secure** is its own field type in the dropdown — not Text. It masks the value in the console and stores it encrypted. On all three fields set **Script permission: Read/Write** and **API permission: None**. That combination is the point: a script running on an agent can read the secret, but the public API can never read it back out.

**Populate** the values at **[Organization] → Custom → Default fields**. Set them on the organization that **owns the device you will run the automation from**.

> [!WARNING]
> If the values are set on the wrong organization, the run fails with a missing-credentials error even though the fields exist — the lookup is organization-scoped and simply comes back empty. This is the single most common setup mistake.

---

### 3. Add the script as an automation

Go to **Library → Automation → Add → Script**, paste in `Move-NinjaDevices.ps1`, and set:

| Setting | Value |
|---|---|
| Language | PowerShell |
| Operating System | Windows |
| Architecture | All |
| Run as | System |

Credentials come from the custom fields in step 2, so you do not add them here. Everything else — the site map and the execute switch — is set on the **Script Variables** tab in [step 6](#6-hand-the-map-to-the-automation).

---

### 4. Find out which subnets you actually have *(optional)*

Skip this if you already know which IP range belongs to which site.

Otherwise run the script once with `-Discover`. It reports the live networks, how many devices sit on each, and where those devices currently live, then writes `discovered-subnets.csv` as a starter map with the subnets already filled in — so you only have to add the destination columns.

```
==== Subnets in use (7 networks, 37 devices, 2 with no usable IPv4) ====

Subnet          Devices SampleIP       CurrentOrgs
------          ------- --------       -----------
10.10.1.0/24         22 10.10.1.42     101 (Endpoint Environment)
10.10.2.0/24          7 10.10.2.21     101 (Endpoint Environment)
10.20.0.0/24          2 10.20.0.11     102 (Endpoint Environment East)
```

> [!NOTE]
> **Run this from your own workstation, not as an automation.** `-Discover` has no Script Variable, so there is no checkbox for it in the console. The script is a plain API client — it runs anywhere with Windows PowerShell and internet access.

```powershell
.\Move-NinjaDevices.ps1 -Discover `
  -NinjaUrl https://ca.ninjarmm.com `
  -ClientId <client id> -ClientSecret <client secret>
```

Same for `-SelfTest`, which runs 36 built-in assertions on the subnet-matching logic with no credentials and no API calls. Worth running once if you want to see the matching rules proved before you trust them with your fleet.

```powershell
.\Move-NinjaDevices.ps1 -SelfTest
```

---

### 5. Write the site map

A plain CSV. This is the **only** input you have to author:

```csv
Subnet,OrgID,LocationID,Org,Location
10.10.1.0/24,101,5001,Endpoint Environment,Bluffton
10.10.2.0/24,101,5002,Endpoint Environment,Brewster
10.10.3.0/24,101,5003,Endpoint Environment,Burlington
10.10.3.200-250,101,5015,Endpoint Environment,Burlington - Server VLAN
10.10.9.77,101,5016,Endpoint Environment,Main Office - Cache Host
10.20.1.0/24,102,5012,Endpoint Environment East,Newport
0.0.0.0/0,101,5099,Endpoint Environment,Unassigned Holding
```

**OrgID** is in the console URL when you open an organization — `#/customerDashboard/101/overview`. **LocationID** comes from `GET /v2/organization/{id}/locations`. `Org` and `Location` are labels for the reports only; the two ID columns are what actually get written.

> [!TIP]
> Getting an ID wrong is not dangerous. The map is **validated against your live instance before anything moves** — a bad row aborts the run with the exact problem, e.g. *"LocationID 99999 is not in org 101 'Endpoint Environment'"*.

See [Site map reference](#site-map-reference) for every subnet format and how precedence works.

---

### 6. Hand the map to the automation

The agent has no copy of your CSV, so you have to tell the automation where to find it. On the script's **Script Variables** tab, add **one** of these three:

| Variable | Type | Use it when |
|---|---|---|
| `mapUrl` | String | **Recommended.** An HTTPS URL to the CSV. Keep the file in source control or on an internal web server and every run picks up the current version — no script edit, no file to copy onto the agent. |
| `mapInline` | Multi-line | You would rather paste the CSV contents straight into the variable. Fine for a small, stable map; you edit the automation to change a site. |
| `mapPath` | String | The CSV already sits on that specific agent's disk. |

While you are on that tab, add the rest of the settings you want. All Script Variables are optional and matched case-insensitively.

| Variable | Type | What it does |
|---|---|---|
| `execute` | Checkbox | **Unticked = dry run.** Tick it to actually move devices. Add this one now and leave it unticked. |
| `matchOn` | Drop-Down | `LocalIP` (default) / `Gateway` / `PublicIP` / `Auto`. See [Matching modes](#matching-modes). |
| `orgId` | Integer | Restrict the run to one source organization. Useful for a staged rollout. |
| `excludeTags` | String | Comma-separated tags to never move, e.g. `Pinned,Roaming`. |
| `excludeNames` | String | Comma-separated name wildcards, e.g. `EPSON*,*-KIOSK`. |
| `skipOffline` | Checkbox | Ignore offline devices — their last known IP may be stale. |
| `staleDays` | Integer | Ignore devices not seen in N days. `0` = off. |
| `maxMoves` | Integer | Safety cap per run. Default `250`. `0` = unlimited. |
| `ninjaUrl` | Drop-Down | Only if you are not using the `ninjaoneInstance` custom field. |
| `clientId` / `clientSecret` | String | Only if you are not using the custom fields from step 2. |

---

### 7. Point the schedule at exactly one device

Create the schedule under **Automation → Scheduled Script**, targeting **one always-on device** — a utility server, or a group that resolves to exactly one machine.

> [!CAUTION]
> **Do not target a group of servers.** This is a fleet-wide API client, not a per-endpoint script. Every run reconciles the entire fleet from wherever it executes. Point it at "all Windows servers" and every one of them reconciles the whole fleet at once — fighting each other over the same `PATCH` calls and burning the `maxMoves` cap once per server.

| Setting | Value |
|---|---|
| Target | One always-on device, or a group containing exactly one |
| Schedule | Hourly, or daily off-hours. It is idempotent, so frequency only costs API calls. |
| `execute` | **Leave unticked for the first few runs.** |

---

### 8. Dry run, review, then go live

Run it once. Dry run is the default, and the mode is stated on the first line of the summary. Everything below is written to the script output, so you can read it straight from the device's activity feed.

```
==== NinjaOne Device Mover ====
Mode            : DRY RUN
In scope        : 37
Already correct : 1
Would move (DRY RUN) : 3
Unmatched       : 2
Skipped         : 0
Failed          : 0

Device          MatchKey     Rule          FromOrg FromLoc ToOrg ToLoc ToLabel
------          --------     ----          ------- ------- ----- ----- -------
BLUF-WKS-0142   10.10.1.39   10.10.1.0/24      101    5099   101  5001 .. / Bluffton
BREW-WKS-0071   10.10.2.16   10.10.2.0/24      101    5099   101  5002 .. / Brewster
NEWP-SRV-01     10.20.1.8    10.20.1.0/24      101    5099   102  5012 .. / Newport
```

**Read the Unmatched count before anything else.** Those devices had no matching rule and were not touched — that is where a missing site shows up. Add the subnet to the map and dry-run again.

When the plan reads right, tick `execute` and run it again. Start with one organization via `orgId` if you would rather widen gradually, then remove it for the whole fleet.

---

## Site map reference

CSV with columns `Subnet,OrgID,LocationID,Org,Location`. The `Subnet` cell accepts any of these:

| Subnet format | Matches |
|---|---|
| `10.10.1.0/24` | the whole /24 |
| `10.10.1.50` | just that host (= /32) |
| `10.10.1.*` | same as a /24 |
| `10.10.*.*` | same as a /16 |
| `10.10.1.20-10.10.1.40` | explicit range |
| `10.10.1.20-40` | same, last octet only |
| `0.0.0.0/0` | catch-all |

**The most specific rule wins, whatever order the rows are in.** A single IP beats a /24, which beats a /16, which beats the catch-all.

So you can carve a handful of servers out of a site range without reordering the file, and a catch-all row safely acts as an "unassigned holding" bucket.

Loopback, `169.254.x` APIPA and IPv6 addresses are ignored, so a dual-stack device still matches on its real IPv4.

---

## Matching modes

Set with the `matchOn` variable (or `-MatchOn`). `LocalIP` is the default and the normal case.

| Mode | Reads | Cost | Use when |
|---|---|---|---|
| `LocalIP` | The device's own IPv4, from the bulk device record | Free | Each site owns distinct internal subnets. This is the usual case. |
| `Gateway` | Active default gateway | **1 extra API call per device** | Sites share internal subnet ranges but differ by gateway. On a large fleet, shard with `orgId` or space the schedule out. |
| `PublicIP` | Public egress IP | Free | Each site egresses on a distinct public IP. |
| `Auto` | `LocalIP`, falling back to `PublicIP` | Free | Mixed estate. |

---

## Read before you run it live

> [!WARNING]
> **Dry run is the default.** Nothing is written unless you tick `execute` or pass `-Execute`. Every run states its mode on the first line of the summary.
>
> **Roaming laptops follow their IP.** A laptop that spends a week at another plant gets moved to that plant. That is intended behavior — use `excludeTags` or `excludeNames` to pin anything that should never be re-homed.
>
> **A moved device inherits the destination organization's policy mapping.** The script does not send a policy — `nodeRoleId`, `rolePolicyId` and `policyId` are left untouched — so the device picks up whatever the destination org maps that role to. Check the destination org's policy assignments match your intent before going live.

---

## Safety rails

| | |
|---|---|
| **Dry run default** | `execute` is the only thing that writes. |
| **Map validated** | A bad Org or Location aborts before any device is touched. |
| **Move cap** | `maxMoves` (default 250) stops a bad row early. |
| **Pinning** | `excludeTags`, `excludeNames`. |
| **Stale guards** | `skipOffline`, `staleDays`. |
| **Idempotent** | Correct devices are skipped, so no churn. |
| **Managed only** | ITAM records are never touched. |

---

## What it writes

Written to `-Dir`, which defaults to the script folder.

| File | Contents |
|---|---|
| `mover-moved.csv` | Moved, or would move. |
| `mover-unmatched.csv` | No rule matched. **Check this.** |
| `mover-skipped.csv` | Pinned or filtered, with reason. |
| `mover-failed.csv` | Errored, with the API message. |
| `discovered-subnets.csv` | From `-Discover` only. |

On a NinjaOne run these land on **that agent's** disk. The summary and the plan are in the script output, so a dry run is fully readable from the activity feed without going to the files.

Exit codes: `0` clean · `1` fatal (config, auth or map) · `2` finished with failures.

---

## If something looks wrong

| What you see | What it means |
|---|---|
| Missing-credentials error, but the custom fields exist | The values are set on the wrong organization. They have to be on the org that owns the device the automation runs from. See [step 2](#2-store-the-credentials-in-custom-fields). |
| Run aborts on the map | An `OrgID` or `LocationID` in the CSV doesn't exist, or the location doesn't belong to that org. The message names the exact row. Nothing was written. |
| High **Unmatched** count | Real subnets missing from the map. Open `mover-unmatched.csv`, or re-run `-Discover`, and add the rows. |
| Devices with no usable IPv4 | Phones and some tablets have no IPv4 in the record. They land in `mover-unmatched.csv` and are never moved. |
| Run stops at exactly 250 moves | The `maxMoves` cap did its job. If the plan is right, raise it or run again. |
| Device count looks far too large | Expected. `/devices-detailed` returns ITAM records too. The script pages through all of it and filters to managed agents afterwards. |
| Nothing was excluded despite `-ExcludeNames` | Only affects command-line runs — see [the `-File` note below](#running-it-outside-ninjaone). |

---

## Running it outside NinjaOne

It also runs as a plain scheduled task on any always-on Windows box, which does not consume a scripting entitlement. `Ninja-Property-Get` does not exist there, so credentials come from machine environment variables instead:

```powershell
[Environment]::SetEnvironmentVariable('NINJA_URL','https://ca.ninjarmm.com','Machine')
[Environment]::SetEnvironmentVariable('NINJA_CLIENT_ID','<client id>','Machine')
[Environment]::SetEnvironmentVariable('NINJA_CLIENT_SECRET','<client secret>','Machine')
```

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\NinjaMover\Move-NinjaDevices.ps1 -Dir C:\NinjaMover -MapPath C:\NinjaMover\ninja-location-map.csv -Execute
```

In Task Scheduler, set it to run whether the user is logged on or not, on whatever interval fits.

> [!WARNING]
> **Multi-value options need `-Command`, not `-File`.** Windows does not parse PowerShell syntax after `-File`, so `-ExcludeNames "WIN-*","*KIOSK*"` arrives as one literal string and silently excludes *nothing* — while the run still looks completely clean. Pass a single pattern, or invoke through `-Command`:
>
> ```
> powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& 'C:\NinjaMover\Move-NinjaDevices.ps1' -Dir C:\NinjaMover -ExcludeNames 'WIN-*','*KIOSK*' -Execute"
> ```
>
> This does not affect Script Variables — `excludeNames` is parsed by the script itself, so a comma-separated list there works as written. Either way, confirm `mover-skipped.csv` lists what you expected to pin.

---

## Command-line reference

Credential precedence, first hit wins: **command line → Script Variables → custom fields → environment variables.**

| Parameter | Default | What it does |
|---|---|---|
| `-Execute` | off | Actually move devices. Omit for a dry run. |
| `-SelfTest` | — | Run the built-in matching assertions and exit. No credentials needed. |
| `-Discover` | — | Report live subnets and write `discovered-subnets.csv`. |
| `-DiscoverPrefix` | `24` | Prefix length to group discovered subnets by (8–32). |
| `-MapPath` / `-MapUrl` / `-MapInline` | — | The site map. Pick one. |
| `-MatchOn` | `LocalIP` | `LocalIP` / `Gateway` / `PublicIP` / `Auto`. |
| `-OrgId` | all | Restrict to one source organization. |
| `-ExcludeTags` | — | Tags to never move. |
| `-ExcludeNames` | — | Device-name wildcards to never move. |
| `-SkipOffline` | off | Ignore offline devices. |
| `-StaleDays` | `0` | Ignore devices not seen in N days. `0` = off. |
| `-MaxMoves` | `250` | Safety cap per run. `0` = unlimited. |
| `-SkipMapValidation` | off | Skip the pre-flight Org/Location check. Not recommended. |
| `-Dir` | script folder | Where the output CSVs go. |
| `-NinjaUrl` / `-ClientId` / `-ClientSecret` | — | Connection, if not coming from fields or environment. |
| `-CfInstance` / `-CfClientId` / `-CfClientSecret` | `ninjaoneInstance` / `ninjaoneClientId` / `ninjaoneClientSecret` | Override the custom field names. |

Common runs:

```powershell
# Prove the matching logic works, offline, before you trust it with anything
.\Move-NinjaDevices.ps1 -SelfTest

# See which subnets your fleet is actually on, with device counts
.\Move-NinjaDevices.ps1 -Discover

# Dry run against one org
.\Move-NinjaDevices.ps1 -MapPath .\ninja-location-map.csv -OrgId 101

# Go live for that org, then widen to the whole fleet
.\Move-NinjaDevices.ps1 -MapPath .\ninja-location-map.csv -OrgId 101 -Execute
.\Move-NinjaDevices.ps1 -MapPath .\ninja-location-map.csv -Execute
```

---

## About this tool

Built to cover a gap while native subnet-based Organization and Location assignment is in development. It is an external API client using only read calls and `PATCH /device/{id}`. **It is not an official NinjaOne product and is not supported by NinjaOne Support** — report problems to your NinjaOne contact.

**Verified.** Moving a managed agent between organizations is confirmed working against a live instance: a Windows workstation moved org 1 → org 2 and back, the change held server-side, and `nodeRoleId`, `rolePolicyId` and `policyId` were identical before and after.
