# Spatial audio research — Sunshine → Moonlight → Steam Deck → AirPods Pro

> **What this doc is:** the research record behind the host-side HRTF/binaural
> audio pipeline — the PipeWire filter-chains tracked at
> [`host/etc/pipewire/pipewire.conf.d/`](../host/etc/pipewire/pipewire.conf.d/)
> and installed by [rehydrate stage 70](../rehydrate/host/70-audio/install.sh).
> The body below is a snapshot of two independent deep-research passes
> (2026-05-21) plus the v1–v6 iteration log; it's kept intact because the dead
> ends explain the design. Where it disagrees with **Current live state**
> below, the live-state note wins.

## Current live state (2026-06-10)

The filter-chain confs create three sinks:

| Sink | Priority | What it is |
|---|---|---|
| `Surround_HeSuVi` | 3000 (system default) | 8-channel HeSuVi IR convolver (`oal+++.wav` set). Its header comment still says "priority 200" — stale; the operative `priority.session` is 3000. |
| `BinauralBus` | 2000 | 2-channel bus both chains feed; Sunshine's capture point (`audio_sink = BinauralBus`) |
| `Surround_HRTF` | 50 | **Despite the name: the v5 pure 7.1→stereo ITU BS.775 downmix — no HRTF.** The HRTF stages were removed in v5 (coloration/distance problems, see iteration log); the sink name was kept so games that had already auto-routed there keep working. |

[`gamescope-headless.sh`](../host/usr/local/bin/gamescope-headless.sh) exports
`PULSE_SINK=Surround_HRTF`, and every game launched inside the gamescope
session inherits it — so **the plain ITU downmix is what games actually hit
today**, overriding the HeSuVi convolver that would otherwise win as system
default. Removing that one `export` line flips the session to HeSuVi;
per-game `PULSE_SINK=<sink> %command%` launch options override either way.
Sunshine captures `BinauralBus` in all cases, so switching chains never
touches the stream path. Client side stays as researched below: Moonlight set
to STEREO, in-game audio set to 5.1/7.1. (The MIT KEMAR `.sofa` file is no
longer referenced by any live conf — it's a v1–v4 artifact; rehydrate still
fetches it only so the iteration log below stays reproducible.)

**IR provenance:** the 14 `ir_*.wav` mono impulse responses the HeSuVi
convolver loads are **derived at install time** by
[rehydrate stage 70](../rehydrate/host/70-audio/install.sh) from HeSuVi's
`oal+++.wav`, which is **not redistributed in this repo** (HeSuVi licensing).
Bring your own from a [HeSuVi release](https://sourceforge.net/projects/hesuvi/)
(the 48 kHz `hrir/oal+++.wav`) — the split recipe is in §"To reproduce" below.

---

## TL;DR

**Per-channel HRTF on a 7.1 bed (what we built in v1–v4) is structurally
wrong for game audio.** Symptoms we observed map 1:1 to known failure modes
of that architecture, regardless of gain/angle tuning:

| Symptom | Root cause |
|---|---|
| Far enemies sound close | KEMAR HRIRs are anechoic, far-field only (~1.4m); distance is carried by reverb/air-absorption/near-field ILD, none of which a bare HRIR provides |
| Excessive width / wrap | Rear virtual speakers externalize strongly via HRTF, front pair doesn't — image stretches outward |
| Head in a jar / underwater | KEMAR pinna-resonance peaks (~8kHz) summed across 8 phase-different convolvers comb-filter together |
| Hollow / phasey dialog | Phantom-center artifact: dialog built from L+R virtual speakers, each with its own HRIR, doesn't add coherently at the eardrum |

This is not a bug in our chain — it's the model itself.

## What actually works (consensus from FPS / audio engineering / Steam Audio / HeSuVi communities)

1. **Per-game in-engine HRTF, system stays stereo.** The engine has real 3D
   source positions; it HRTF's each source at its exact angle, applies
   distance modeling (reverb / air absorption / near-field) *before* HRTF,
   and avoids comb-filter pile-up. Steam Audio (Valve, default in many UE/Unity
   titles), OpenAL Soft HRTF, Resonance Audio, Wwise/FMOD spatializers.

   - Witchfire (UE5): look for HRTF/Binaural/Headphones in audio settings
   - CS2: `snd_use_hrtf 1` in console
   - Valorant: Audio → HRTF on
   - OpenAL games via Proton: `alsoft.ini` with `hrtf=true stereo-mode=headphones`
     in prefix, plus `WINEDLLOVERRIDES=xaudio2_7=n,b xaudio2_8=n,b dsound=n,b`
   - **Never stack in-game HRTF with system HRTF** — phase cancellation, smeared imaging

2. **HeSuVi-style 14-channel WAV in `convolver`** for games without in-engine HRTF.
   Engineered as a coherent set for 7.1→2; doesn't comb-filter against itself
   like 8 independent SOFA convolvers do.

   Community ranking:
   1. `oal+++.wav` (OpenAL Soft) — "most natural, best 3D positioning"
   2. Sennheiser GSX 7.1 Binaural — best for FPS footsteps
   3. Dolby Atmos for Headphones — immersive, slightly bassy
   4. DTS Headphone:X — neutral tonality, good surround
   5. SBX Pro Studio — popular gaming default

   Design: keep `BinauralBus` (pure stereo) as default; add `BinauralBus_HeSuVi`
   as a second sink with convolver. Opt-in per-game via Sunshine WebUI's
   per-app `audio_sink` or `PULSE_SINK` env in Steam launch options.

3. **If sticking with the PipeWire `sofa` builtin**, swap MIT KEMAR for
   SADIE II KU100 DFC (`SADIE_KU100_DFC_256_order_fir_48000.sofa` from York)
   or Steam Audio's CIPIC default. Less coloration, better-validated. Use a
   *single* `sofa` instance with proper azimuth/elevation/radius per source,
   not 8 parallel convolvers — that's closer to object-based.

## Sunshine / Moonlight reality

- **Sunshine codec: Opus only.** No DTS/Atmos/PCM passthrough. Six modes:
  stereo (96k or 512k high), 5.1 (256k or 1536k), 7.1 (450k or 2048k), 48kHz.
- **Multichannel via Sunshine works** (auto-creates `sink-sunshine-stereo/-surround51/-surround71`)
  but Moonlight on Steam Deck has unresolved bugs: 7.1 channel-mapping wrong
  (#1148), 5.1 broken-not-planned (#1798), Deck collapses surround to L/R
  (#1481). Don't try to "send 7.1 to the Deck and binauralize there" — the
  client surround path is broken on this hardware.
- **No client-side binaural pathway exists in Moonlight.** It hands PCM to
  the OS and lets PipeWire downmix. So all HRTF must happen on the host.

## AirPods Pro on Linux — facts

- **Apple Spatial Audio cannot be triggered from Linux.** It's app-level
  CoreAudio + H2-chip IPC on Apple platforms only. Not a Bluetooth metadata
  flag we can spoof. LibrePods (reverse-engineered AirPods Linux driver):
  *"spatializing stereo sound is beyond this project's scope and will never
  be available."* Treat AirPods as a plain stereo AAC sink. Full stop.
- **Codec: AAC over A2DP** (AirPods don't do aptX/LDAC; Apple doesn't license
  Qualcomm codecs). PipeWire bluez5 + libfdk-aac handles this.
- **Latency budget**:
  - AAC over Bluetooth to AirPods on Linux: ~100–140 ms (Linux has no
    Apple-style pre-buffer sync compensation)
  - Sunshine encode + LAN + Moonlight decode: ~10–35 ms
  - **Total ~120–170 ms** — past competitive FPS threshold (~30ms gold,
    ≤80ms casual-acceptable)
  - No HRTF tuning fixes this. For competitive: wired USB-C DAC or 2.4 GHz
    wireless headset plugged into Deck → ~25–35 ms total.

## Final landed config (v6 — snapshot 2026-05-21; see "Current live state" above for today's routing)

**HeSuVi `oal+++.wav` convolver chain as system default, v5 ITU downmix kept
as an opt-in fallback.** Three sinks live in PipeWire:

| Sink | Priority | What it does |
|---|---|---|
| `Surround_HeSuVi` (8ch) | 3000 (system default) | 14 mono convolvers loaded with the HeSuVi OpenAL Soft IRs split from `oal+++.wav`. LFE bypassed direct at 0.4 gain. Convolved L/R sums feed `BinauralBus`. |
| `BinauralBus` (2ch) | 2000 | Pure stereo passthrough. The sink Sunshine captures (`audio_sink=BinauralBus`). |
| `Surround_HRTF` (8ch) | 50 | Pure 7.1→stereo ITU BS.775 downmix. Reachable for A/B comparison via `PULSE_SINK=Surround_HRTF`. |

**Per-game opt-outs** via Steam launch options:
- In-engine HRTF games (CS2, Valorant, UE+SteamAudio etc.) → `PULSE_SINK=BinauralBus %command%` to bypass HeSuVi and avoid double-processing.
- Compare HeSuVi vs pure downmix on a specific game → `PULSE_SINK=Surround_HRTF %command%`.
- Live A/B without relaunch → `pavucontrol-qt`, Playback tab, switch the stream's target sink.

**To reproduce on a clean box** (or just run
[`rehydrate/host/70-audio/install.sh`](../rehydrate/host/70-audio/install.sh),
which automates all of this):
1. Install: `pacman -S pipewire pipewire-pulse wireplumber p7zip ffmpeg`
2. Place `oal+++.wav` (48 kHz variant from HeSuVi 2.0.0.1) at `/etc/pipewire/hrtf/hesuvi/oal+++.wav` — not in this repo, see the IR provenance note above
3. Split into 14 mono WAVs (HeSuVi channel order — FL.L, FL.R, SL.L, SL.R, RL.L, RL.R, FC.L, FC.R, FR.L, FR.R, SR.L, SR.R, RR.L, RR.R):
   ```bash
   for c in 0:fl_l 1:fl_r 2:sl_l 3:sl_r 4:rl_l 5:rl_r 6:fc_l 7:fc_r \
            8:fr_l 9:fr_r 10:sr_l 11:sr_r 12:rr_l 13:rr_r; do
     ch=${c%:*}; name=${c#*:}
     ffmpeg -y -i /etc/pipewire/hrtf/hesuvi/oal+++.wav \
       -af "pan=mono|c0=c${ch}" -ar 48000 \
       /etc/pipewire/hrtf/hesuvi/ir_${name}.wav
   done
   ```
4. Drop the two filter-chain confs (tracked in this repo at
   [`host/etc/pipewire/pipewire.conf.d/`](../host/etc/pipewire/pipewire.conf.d/))
   into `/etc/pipewire/pipewire.conf.d/`
5. Restart pipewire user services + gamescope-headless

## What we tried (chronologically)

- **v1** (original) — 8 KEMAR spatializers, unity gain. Scratchy clipping,
  uneven blindspots, weak spatial.
- **v2** — added per-input mixer gains 0.25, LFE bypass via `copy`, lower
  `node.latency`. Triggered "unaligned latency" warning (LFE 0-sample vs
  spatializer 558-sample). Reverted LFE bypass.
- **v3** — 8 KEMAR spatializers with 0.25 gain (LFE re-spatialized for
  alignment). Cleaner but "artificially spatial," hollow/phasey/colored.
- **v4** — 6 spatializers + FC/LFE bypass at 0.707/0.40. "Head in a jar,
  underwater, still too wide, distance broken."
- **v5** — pure 7.1→stereo ITU BS.775 downmix, NO HRTF. Natural tonality,
  proper distance, no spatial cues. Demoted to opt-in fallback in v6.
- **v6** (current) — HeSuVi `oal+++.wav` convolver chain (OpenAL Soft IRs,
  14 mono convolvers with LFE bypass) as system default. Per-game opt-outs
  via `PULSE_SINK` env. User-validated as "good, keep it."

## Sources (top hits)

- [Sunshine audio subsystem](https://deepwiki.com/LizardByte/Sunshine/6-audio-subsystem)
- [Sunshine configuration docs](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html)
- [PipeWire filter-chain (sofa, convolver)](https://docs.pipewire.org/page_module_filter_chain.html)
- [Pipewire-DX-Utils](https://github.com/Dekomoro/Pipewire-Virtual-Surround) — most-polished PipeWire virtual surround config
- [HeSuVi HRIR community ranking](https://sourceforge.net/p/hesuvi/discussion/general/thread/ccfbeee90e/)
- [vukilis — HeSuVi on Linux](https://vukilis.com/my-hesuvi-configuration-on-linux/)
- [obito.fr — True spatial audio on Linux using HRTF](https://obito.fr/posts/2023/06/true-spatial-audio-on-linux-using-hrtf/)
- [Steam Audio docs](https://valvesoftware.github.io/steam-audio/)
- [SADIE II HRTF database (York)](https://www.york.ac.uk/sadie-project/database.html)
- [SOFA Conventions file index](https://www.sofaconventions.org/mediawiki/index.php/Files)
- [LibrePods — Linux AirPods driver](https://github.com/kavishdevar/librepods)
- [Switchblade Gaming — Best Audio Settings for Competitive FPS 2026](https://www.switchbladegaming.com/game-settings/best-audio-fps-games/)
- moonlight-qt Deck-surround issues: [#1148](https://github.com/moonlight-stream/moonlight-qt/issues/1148), [#1481](https://github.com/moonlight-stream/moonlight-qt/issues/1481), [#1798](https://github.com/moonlight-stream/moonlight-qt/issues/1798)
