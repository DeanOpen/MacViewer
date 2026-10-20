# Audit: multi-display support and remote interaction

- **Repository:** https://github.com/DeanOpen/MacViewer
- **Audit date:** 2026-10-20
- **Baseline:** `main` @ `9fa48d0` (tag `v0.3.23`, macOS + LinuxViewer)
- **Test baseline at v0.3.21:** 275 tests / 18 suites; **after the fixes below:** 343 tests / 27 suites, 0 failures
- **Method:** three read-only audit streams (macOS host sharing, macOS viewer/control, session/transport/MCP/security), independent hardware-free probes that compile the real encoder/decoder, measurements on an M1 Pro Mac (built-in Retina 3456×2234 + 1920×1080 display arranged above-left), and code review against the recovered protocol comments/tests already in the repo.

This document is a condensed, public-safe summary of the findings and their status. Detailed protocol notes and the full evidence logs are intentionally kept local, matching the repository's `/docs/*` policy.

## Status legend

| Status | Meaning |
| --- | --- |
| ✅ #10 | Fixed by the multi-display PR (merged) |
| ✅ #11 | Fixed by the remote-interaction PR (merged) |
| 🟡 #12 | Implemented in the session-UI PR (open) |
| ⬜ | Confirmed but not fixed yet; a proposed solution is given |
| 🔬 | Needs a real Windows UltraViewer peer or specific hardware to confirm the last step |

Severity: **P0** breaks a core workflow, **P1** major quality/usability, **P2** edge case or noticeable annoyance, **P3** minor.

---

## A. Multi-display: sharing this Mac

| ID | Sev | Finding | Solution / status |
| --- | --- | --- | --- |
| F1 | P0 | Host frame rate was hard-capped: a fixed 250 ms sleep after every viewer ACK limited a session to ~2–2.8 fps, worse with more displays. | ACK-driven pacing (0.04 s after a sent frame, 0.25 s for identical frames); one frame in flight remains the backpressure. ✅ #11 |
| F2 | P1 | Retina density was never detected: `CGDisplayPixelsWide/High` report the mode's *point* size (1728×1117 for a 3456×2234 panel), so backing scale was always 1. | Read `NSScreen.backingScaleFactor` (display-mode and CoreGraphics fallbacks); pure helper + tests. ✅ #11 |
| F3 | P1 | Shared canvas was forced into 16:9 boxes: three 1080p displays became 1280×720 each; a portrait display became 607×1080. | Shape-agnostic pixel budget: 2,073,600 px for one display, 8,294,400 px for several; `scale = min(1, sqrt(budget/area))`, never upscale. ✅ #10 |
| F4 | P1 | Unplugging a display, display sleep or a transient capture failure ended the Windows session. | Transient capture errors retry with backoff; screen-recording loss and a disconnected selected display still end sharing as documented. Power assertion while streaming is still open. ✅ #11 (partial) / ⬜ power assertion |
| F5 | P1 | A mid-session display-layout change re-sent initialization with a reset frame number, but the decoder requires `previous + 1`. | Re-init for a layout change keeps the sequence; a fresh approval or viewer re-login resets it. ✅ #11 |
| F6 | P2 | A static screen was re-captured ~3–4 times per second forever (CPU/GPU/battery cost while merely viewing). | Proposed: continuous `SCStream` or an adaptive idle poll (0.5–1 s) after unchanged frames. ⬜ |
| F7 | P2 | Per-display ScreenCaptureKit captures run serially (measured 84 ms serial vs 65 ms parallel for two displays). | Proposed: `withThrowingTaskGroup` over displays with a Sendable image box; no protocol change. ⬜ |
| F8 | P2 | Composite + scalar RGB555 conversion runs on the MainActor (measured 9 ms for this Mac's two-display canvas, 17.8 ms for 4K). | Proposed: move capture/composite to a dedicated actor; keep only display enumeration on MainActor. ⬜ |
| F9 | P2 | macOS 12–13 fallback frames (`CGDisplayCreateImage`) contain no cursor, and the host never sends cursor commands. | Proposed: draw `NSCursor.current` at the cursor location into each surface before compositing, or drop 12–13. 🔬 |
| F10 | P3 | Rotated displays: the old backing-scale formula used unrotated pixel sizes. | Fixed by F2 (using `backingScaleFactor`); screen-capture orientation on a rotated display still needs hardware validation. ✅ #11 / 🔬 |

## B. Multi-display: viewing and controlling another computer

| ID | Sev | Finding | Solution / status |
| --- | --- | --- | --- |
| V1 | P1 | Viewer rejected large Windows desktops (8192 px / 16.7 Mpx): 3×4K, 2×5K and 2×4K + laptop could not connect. | Limits raised to 16,384 px / 32,000,000 px; actionable error text; boundary tests. ✅ #11 |
| V2 | P1 | A monitor-crop failure was silent: the whole desktop was shown while the menu/MCP still claimed "Monitor N". | `monitorNotice` banner + MCP `session_status`; display/input stay consistent. ✅ #11 |
| V3 | P2 | Monitor-string parsing was all-or-nothing; a trailing NUL or one bad record removed the whole monitor menu. | Trailing NUL run tolerated; strict otherwise. A malformed-but-present list still has no per-record recovery — proposed: skip bad records with a status. ✅ #11 (partial) |
| V4 | P2 | Initialization parts 9/10 (desktop origin) were treated as required whenever monitor info was present, killing the session. | Decoded independently and optional; one effective origin derived from monitor edges. ✅ #11 |
| V5 | P2 | Monitor selection was lost on refresh/reconnect and never remembered. | Kept across metadata-less re-inits; persisted per partner ID. ✅ #11 |
| V6 | P2 | Monitor menu labels did not identify the physical display. | Rows now include the virtual desktop offset, e.g. `· (-1920, 0)`. ✅ #11 |
| V7 | P2 | Footer still printed the whole-desktop size while a single monitor was shown. | Proposed: show `displayedSize` and the active monitor label. ⬜ |
| V8 | P3 | Monitor switching was buried two menus deep, with no shortcuts or refresh action. | First-class toolbar monitor menu, All/Next/Previous (⌃⌥⌘0, ⌃⌥⌘], ⌃⌥⌘[), direct ⌃⌥⌘1…9. Refresh-screen command still proposed. 🟡 #12 / ⬜ refresh |
| V9 | P3 | Monitor selection is local-only; the host keeps sending the full canvas (protocol limitation). | Keep local crop as fallback; capture a native Windows viewer switching monitors before adding any "capture this monitor" request. 🔬 |
| V10 | P3 | Capture menu said "Save full screen" while saving one monitor; recording canvas did not follow a monitor switch. | Proposed: wording/filename includes the monitor; restart or re-fit the recording canvas on switch. ⬜ |
| V11 | P3 | 16-bit coordinate packing wraps on virtual desktops wider/taller than 32,767 px (click lParam and remote cursor). | Proposed: warn when the virtual desktop exceeds the Int16 range; test the packed round-trip at ±32,768. ⬜ |

## C. Pointer/input mapping (both directions)

| ID | Sev | Finding | Solution / status |
| --- | --- | --- | --- |
| C1 | P1 | Host injection fell back to the Mac's own cursor when no remote position had arrived, so the first Windows click after a display change could land anywhere. | Injection point now comes only from the last accepted remote pointer; otherwise the event is dropped. ✅ #11 |
| C2 | P1 | Viewer assumed transmitted canvas pixels equal virtual-desktop units; a scaled canvas made crops fail and clicks reach only part of the desktop. | Origin is now derived from monitors; full canvas-scale inference still needs a Windows peer trace. ✅ #11 (origin) / 🔬 |
| C3 | P2 | Stateless gap clamping teleported the pointer by 100–500 pt per canvas pixel when crossing the black gap between displays. | Preferred-region clamping keeps the pointer on the source display until it re-enters another one; property-tested. ✅ #11 |
| C4 | P2 | "Actual size" could not be panned while Control was on; every wheel event went to the remote computer. | Plain wheel pans locally at Actual size; Option+wheel controls the remote; Fit mode unchanged. ✅ #11 / 🟡 #12 |
| C5 | P2 | Retina backing scale (same root cause as F2). | Fixed by F2. ✅ #11 |
| C6 | P3 | `mapPoint` uses the pixel's top-left corner and clamps to `width-1`, leaving a ~1–2 pt dead strip at the right/bottom edge. | Proposed: map the pixel centre `(px + 0.5)` and clamp to `maxX - 0.001`; update the coordinate tests. ⬜ |
| C7 | P2 | Wheel events carried a stale/zero position (no move before scroll), so Windows scrolled the wrong window/monitor. | Send the exact pointer position before the wheel; encoder test pins the packed lParam. ✅ #11 |
| C8 | P3 | Silent crop failure plus a stale MCP screenshot scale after changing monitors. | Notice instead of silence (V2); MCP scale keyed per client. ✅ #11 |

## D. Remote interaction — Mac controlling Windows

| ID | Sev | Finding | Solution / status |
| --- | --- | --- | --- |
| I1 | P1 | Double-click was sent as two single clicks; Windows never received `WM_LBUTTONDBLCLK` (0x203/0x206/0x209). | Dedicated double-click input event, mouse-up suppression, monitor offset + virtual origin, wire double-click after moving; MCP `count:2` uses it. ✅ #11 |
| I2 | P2 | The activation click after switching apps was swallowed. | `acceptsFirstMouse` while Control is on. ✅ #11 |
| I3 | P2 | Keyboard focus was not acquired on connect/Actual-size, and chat stole it on open. | Transition-only focus claim; chat composer focuses only on click. ✅ #11 |
| I4 | P2 | Horizontal trackpad/mouse scroll was computed then discarded. | Horizontal wheel message 0x20E with signed 120-unit/fractional accumulation; vertical bytes unchanged. ✅ #11 / 🔬 host support |
| I5 | P2 | At Actual size the surrounding ScrollView could not be scrolled. | Same as C4. ✅ #11 |
| I6 | P2 | Held keys/buttons were not released when a sheet/panel became key. | Release on session-window `didResignKey`. ✅ #11 |
| I7 | P2 | Right Shift/Ctrl/Alt and AltGr collapsed to the left side. | Side-specific modifier events from `flagsChanged` keyCode. ✅ #11 / 🔬 peer |
| I8 | P2 | Old UltraViewer hosts silently dropped all keyboard input while the UI claimed control was on. | `keyboardSupported` notice in the session UI. ✅ #11 |
| I9 | P2 | Two cursors: local pointer plus a lagging remote overlay. | Added a remembered show/hide remote-cursor option (toolbar, View menu, ⌃⌥⌘P). Hiding the *local* pointer while controlling is still proposed. 🟡 #12 / ⬜ |
| I10 | P2 | MCP `screenshotScale` was shared by all agents, mis-scaling concurrent clicks. | Per-client scale, reset on monitor change. ✅ #11 |
| I11 | P3 | Caps Lock never toggled the remote Caps state (Mac keycode 0x39 has no mapping). | Proposed: emit VK_CAPITAL on the caps-flag transition; verify against a peer. ⬜ 🔬 |
| I12 | P3 | MCP `press_keys` names were wrong/no-ops (`plus`, uppercase, `capslock`, `!`, F13). | Uppercase implies Shift, shifted symbols/plus/F13–F20 parsed; `capslock` still needs I11. ✅ #11 (partial) |
| I13 | P3 | `type_text`/IME dropped non-BMP characters but reported success. | `type_text` now reports sent/skipped UTF-16 units; viewer IME remains silent (protocol limitation). ✅ #11 (partial) |
| I14 | P3 | Option/dead-key composition never reached the text system. | Proposed product rule: send composed printable text for Option characters without Cmd/Ctrl; keep Alt for shortcuts. ⬜ 🔬 |
| I15 | P3 | MCP `scroll` without coordinates scrolled at virtual (0,0). | Anchors at the remote cursor or the displayed image centre. ✅ #11 |
| I16 | P3 | Paste could use a stale clipboard (0.5 s polling). | Proposed: flush the local clipboard before forwarding the paste chord. ⬜ |
| I17 | P3 | Input can queue behind frame decode on the relay actor (~5–50 ms). | Proposed: measure and move decoding off the send path or prioritise input writes. ⬜ |
| I18 | P3 | An agent changing monitors could surprise the human and release their held input. | Proposed: mark agent-initiated switches in the session notice/status. ⬜ |

## E. Remote interaction — Windows controlling this Mac

| ID | Sev | Finding | Solution / status |
| --- | --- | --- | --- |
| H1 | P1 | Any dropped host event was fatal: a ~1 s MainActor stall with mouse input ended the shared session (`bufferingOldest(128)` + `slowConsumer`). | Buffer 256, pointer-move coalescing, realtime drops non-fatal, one release hint per dropped-input burst. ✅ #11 |
| H2 | P1 | Right-side modifiers collapsed to the left when Windows used the scan-less legacy VK branch. | Side-specific reconciliation over the generic left guess. ✅ #11 / 🔬 |
| H3 | P2 | Caps Lock was posted as a flagsChanged down+up pair, potentially toggling twice. | One flagsChanged key-down per physical press with the new alphaShift state. ✅ #11 / 🔬 hardware |
| H4 | P2 | One malformed input payload disabled Control and blamed Accessibility. | Only `accessibilityRequired` revokes control; malformed/geometry/event-creation errors are dropped. ✅ #11 |
| H5 | P2 | The host never sends cursor feedback; macOS 12/13 frames have no pointer. | Proposed: CursorMessage 3/4/5 or draw the cursor into the frame. 🔬 |
| H6 | P2 | Accessibility loss mid-session left the UI claiming control and skipped releases. | Permission refresh ~1 s while streaming; revoke Control with the real reason. ✅ #11 |
| H7 | P2 | Non-BMP text (emoji, rare CJK) can never be typed from Windows (surrogates dropped both ends). | Proposed: buffer a pending high surrogate and send both UTF-16 units in one Unicode event. 🔬 |
| H8 | P3 | Viewer Actions 22/40/53 (Ctrl-Alt-Del/restart/lock screen) are silently ignored. | Proposed: at least show a status for unsupported actions; implement lock screen via a documented safe route. ⬜ |
| H9 | P3 | Special keys not in the VK map are dropped (NumLock, Pause, PrintScreen, F21–F24, keypad separator, media). | Proposed: map the useful ones; document the rest. ⬜ |
| H10 | P3 | Mouse edge cases: no horizontal-wheel injection yet, first click without a prior move is dropped (safe), triple-click clickState 1, high-resolution wheels quantised to 120. | 0x20E is decoded and consumed; injection waits for the axis convention from a Windows viewer. ✅ #11 (decode) / ⬜ 🔬 |
| H11 | P3 | VK_PACKET text uses keycode 0 (ANSI A) and can overwrite physical-A state/autorepeat. | Proposed: use a dedicated unused keycode or do not record packet text in held-key state. ⬜ |
| H12 | P3 | Chat window keeps every session model/observation forever; failed file saves cannot be retried; no chat/file-offer rate limit. | Proposed: release peers on deactivate, add retry for failed saves, rate-limit incoming offers. ⬜ |
| H13 | P3 | Input is dropped silently while display geometry is nil; a second viewer on the same route/different hash hangs to timeout. | One-shot "control paused while the display changes" status; proposed cmd27 reply for the second viewer. ✅ #11 (status) / ⬜ |
| H14 | P3 | Windows Ctrl maps to Mac Control and Win to Command, so Ctrl+C/V/Z/S do not behave like Windows. | Proposed optional "map Ctrl↔Cmd" preference (translate Ctrl to Command when no other Command is held). ⬜ 🔬 |

## F. Session, transport, MCP and security boundaries

| ID | Sev | Finding | Solution / status |
| --- | --- | --- | --- |
| S1 | P1 | Host always sends one full frame and ignores the viewer's quality preset (commands 31/32/23), so 4K/multi-display feedback is bandwidth-bound. | Proposed: honour the quality preset by reducing the capture scale, plus ACK-timing-based downscale; needs a Windows peer to confirm command semantics. ⬜ 🔬 |
| S2 | P1 | Same root cause as H1 (duplicate). | ✅ #11 |
| S3 | P2 | No liveness watchdog/write timeout: a frozen peer looked connected forever; heartbeat pings were diagnostics-only. | 30 s silence → one refresh + status; 30 s more → explicit timeout; activity resets. ✅ #11 / 🔬 idle peer |
| S4 | P2 | A fixed 20 s ACK deadline armed before sending a multi-MB frame cut slow-but-progressing uplinks. | `20 s + frameBytes / 256 KiB/s`, capped at 180 s. ✅ #11 |
| S5 | P2 | MCP tools crossed permission boundaries: reading chat/clipboard needed no permission, writing clipboard did not need Control, Stop only blocked input tools. | One tool-permission matrix; Stop refuses everything except `session_status`; gate checked before and after approval. ✅ #11 |
| S6 | P2 | The MCP approval queue could resolve the wrong client, leak prompts for disconnected agents, and permanently deny a client for the run. | Waiters bound to pending-approval id; exact resolution; cancel on disconnect; denial can be re-asked. ✅ #11 |
| S7 | P2 | Input dispatch is serialized behind frame encode/decode (~10–50 ms added during heavy screen updates). | Proposed: hoist frame encode/decode off the session actor; measure with diagnostics. ⬜ |
| S8 | P2 | A screen refresh turned Control off and never restored it. | Refresh-suspension state machine; Control returns only when the re-init still allows input; real revocations stay off. ✅ #11 |
| S9 | P3 | MCP scroll without x/y (same as I15). | ✅ #11 |
| S10 | P3 | Chat typing indicator can stick or be sent repeatedly while typing quickly. | Proposed: transition-based state machine, clear on deactivate. ⬜ |
| S11 | P3 | MCP tools reported success even when input was silently dropped (control off/queue overflow). | Partially addressed by the permission gate; a send-success result is still proposed. ✅ #11 (partial) |
| S12 | P3 | A failed clipboard send stopped retrying that text until the pasteboard changed. | Restore bookkeeping on failure so the next poll retries. ✅ #11 |

## G. Requested UX additions (session UI)

| Item | Status |
| --- | --- |
| First-class monitor switcher for multi-monitor remotes (toolbar menu, All/Next/Previous, ⌃⌥⌘0/]/[, direct ⌃⌥⌘1…9 while the remote screen has focus, per-partner persistence) | 🟡 #12 |
| Fit-to-window ↔ Actual-size mode visible in the toolbar and View menu (⌃⌥⌘F), persisted across sessions, unknown stored values fall back to Fit | 🟡 #12 |
| Show/hide remote cursor option in the toolbar and View menu (⌃⌥⌘P), default on, persisted, used by command 28 on connect | 🟡 #12 |

## H. Verification

- **Tests:** 275/18 at `v0.3.21` → **343/27 passing, 0 failures** after the fixes (serial 1.01 s, parallel 0.92 s; one env-gated benchmark skipped).
- **Builds:** macOS 12 `minos 12.0`; experimental macOS 11 `minos 11.0`; release app bundle packaging/signing OK.
- **CI (GitHub, macos-26 + Xcode):** PR #10, #11 and #12 each passed **Test & build**, **Build for macOS 11 (experimental)** and **LinuxViewer (Rust)**; #10 and #11 are merged.
- **Hardware-free probes:** encoder↔host round-trip for 109 key positions (108 identity; keypad `=` is the only inherent ambiguity), modifier sides, buttons/wheel/double-click, input queue semantics, layout numbers (3×1080p → 5760×1080; this Mac → 1920×2197), MonitorCycle/shortcut tables, MCP gate matrix, watchdog, host drop/deadline policies.
- **Measured on M1 Pro:** ScreenCaptureKit capture 46 ms/display (84 ms serial, 65 ms parallel for two); composite+RGB555 9 ms (2 displays) / 17.8 ms (4K); zstd L1 ~32 ms for a 16.6 MB 4K frame; input cannot be reordered; host injection can add ~20–100 ms under heavy updates.

## I. Proposed follow-up priorities

1. **Partial frame updates** (delta rectangles/scroll/image cache) and honouring the viewer quality preset — the only way to raise fps without proportional bandwidth. Needs a Windows peer.
2. **Move encode/decode off the session actor / MainActor** to reduce control latency during heavy screen updates.
3. **Host cursor feedback** (CursorMessage 3/4/5 or frame cursor), especially macOS 12–13.
4. **Power assertion while streaming** and pause (not end) on display sleep; duplicate-viewer rejection.
5. **Non-BMP text**, Caps Lock Mac→Windows, Windows Actions/special keys, horizontal-wheel injection, Ctrl↔Cmd option, dead-key composition, local-pointer hiding, clipboard paste flush, chat-window cleanup, C6 edge accuracy.
6. **Windows peer validation** for: double-click/wheel messages, modifier sides, VK_PACKET surrogates, quality commands, idle heartbeat replies, monitor rect coordinate space.

## J. Limitations of this audit

- No Windows UltraViewer peer and no 4K/rotated display were available; wire-behaviour items are labelled accordingly.
- The AppKit event layer and the Accessibility/event-tap injector are not covered by unit tests; they were verified by code review, pure predicates and probes, and need a manual UI/hardware pass.
- Packaging, signing and notarisation are verified locally/CI only; no distribution credentials were used here.
- Detailed protocol evidence is kept local because `/docs/*` is gitignored by this repository.

---

## Tóm tắt tiếng Việt

Báo cáo này tổng hợp **toàn bộ phát hiện** của hai đợt audit (đa màn hình và tương tác remote), kèm giải pháp và trạng thái:

- **Đã sửa và đã merge:** PR **#10** (đa màn hình: ngân sách điểm ảnh, Retina, monitor rects, input đa màn hình) và PR **#11** (tương tác: nháy đúp, focus, cuộn ngang/Actual size, host chịu input burst, modifier/Caps Lock, MCP permission matrix, watchdog, deadline…).
- **Đang mở:** PR **#12** (nút chuyển màn hình cấp 1, chế độ Vừa khung ghi nhớ, tuỳ chọn ẩn/hiện con trỏ remote).
- **Còn mở, đã có đề xuất:** delta-rectangle frames + tôn trọng quality preset; đưa encode/decode khỏi actor/MainActor; host cursor feedback; quyền Trợ năng/power assertion; emoji/non-BMP; Caps Lock Mac→Windows; Actions 22/40/53; phím đặc biệt; horizontal wheel injection; Ctrl↔Cmd; dead-key Option; ẩn con trỏ local; clipboard paste flush; dọn chat window; cảnh báo Int16; làm mới màn hình.
- **Kiểm chứng:** 343 test / 27 suite pass (baseline 275/18), build macOS 12 + macOS 11, CI xanh cả 3 job ở cả ba PR; probe vòng lặp encoder↔host và các policy đều đạt.
- **Cần Windows UltraViewer thật:** phản ứng với double-click/WM_MOUSEHWHEEL, modifier side, VK_PACKET surrogate, quality command, heartbeat khi màn hình tĩnh, không gian toạ độ monitor.
