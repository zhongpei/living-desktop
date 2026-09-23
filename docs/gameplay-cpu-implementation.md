# Classic Combat CPU implementation

This document maps `gameplay-cpu.md` to executable code. The design document is
kept verbatim; this file is the implementation and evidence ledger.

## Fixed references

| Project | Commit | Use in Living Desktop |
|---|---|---|
| FightingICE | `188fca0c13151b559ec3a4ca60b90a9b7efb6cc3` | CommandCenter queue and checkpoint simulator boundary; author-approved GPL v3 use recorded in `NOTICE.md` |
| MctsAi23i | `b05afc13f6b0815ff154d19ca7e76c99c172799b` | Compatibility parameters only: 14-frame look-ahead, 23 iterations, depth 2, expansion after 10 visits, UCB C=3, 60-frame rollout; upstream has no discoverable license |
| Surfacer | `04058c560e8804a15697e6592fda3f4bfa5057cc` | MIT surface/trajectory graph and deterministic shortest-path adaptation |
| F.LF | `21341737e4154d06d9784e9a629c9dd4db9148d6` | GPL v3 `keypress`/`keyseq`/buffer/`fetch` controller boundary |
| RHEA | `226a98727dbbeb492d9df3a8d3edd113172b3b58` | Evaluated as a future policy, not selected for the first CPU |
| OpenBOR | `787b6770409935137579715febf80cf7a529b748` | BSD-style chase, avoid, aggression and hazard-aware behavior vocabulary |
| IKEMEN GO | `76dd472f1c3876d64f52232e514bfaef9ada6aad` | MIT `aiLevel`/`AiInput` separation and state legality cross-check |

The repository is licensed under GNU GPL v3. Compatible third-party notices
and the special FightingICE authorization record are in `NOTICE.md`.

## Implemented architecture

`MyPetCombatCPU` is a separate module between `MyPetCombat` and `MyPetEngine`.
`ClassicCombatCPU` owns only decision state. It never starts a move or mutates
HP/position. Its only output is `FighterInputFrame`, which passes through
`ControlRouter`, `CombatInputBuffer`, `CommandMatcher`, and `CombatWorld` exactly
like mapped keyboard input.

Implemented design items:

- delayed perception and difficulty-specific decision/search budgets;
- deterministic target utility with vulnerability, distance, reachability,
  path cost, and engagement crowd penalty;
- dynamic surface graph with walk/jump/drop edges, per-profile mobility,
  stable shortest paths, and revision fingerprint caching;
- left/right near/far engagement reservations;
- 60 Hz threat reflex and 4-8 frame tactical cadence;
- legal move utility using reach, expected multi-hit/projectile damage,
  startup/recovery exposure, terrain risk, throw range, and repetition cost;
- Top-K bounded depth-2 UCT using real `CombatWorldCheckpoint` rollouts;
- FightingICE-style command queue, followed by the normal command matcher;
- deterministic RNG, perception history, graph, reservation, queued physical
  inputs, and last decision in checkpoint/replay;
- manual keyboard mapping remains independent: physical key -> logical control
  -> `FighterInputFrame` -> authored character command.
- `ClassicGameplayCPU` is the upper activity arbiter. Formal rounds commit to
  combat; free play scores explore/window/rest/observe, keeps 60-180 frame
  commitments, records surface visits, and emits semantic platform intent only;
- family/sequence-aware `ActionHistory`, lifetime move-use counts and a bounded
  novelty reserve prevent legal but lower-damage moves from starving forever;
- one shared energy reserve controls projectile, special, super, power-up,
  defensive burst and window intent; full gauge prioritizes super before power-up;
- deterministic team requests use mapped `assist`/`tag` controls, while the
  bench assist move still enters through the normal input buffer and matcher;
- neutral collateral escalation is checkpointed and incidentals receive the
  same autonomous input path only after joining; runtime registration carries
  the content loader's `realCombatReady` verdict, so presentation-only pets are
  not selected as opponents and withdraw after collateral damage;
- window candidates pass an explicit minimum-viability gate before spectacle
  ranking. Foreground windows, recent user activity and the 60-point reserve
  cannot be overridden by personality weights;
- `WindowInteractionPolicy` now runs inside `CombatRuntime` before an intent is
  published to a platform adapter. Allowed pull/overlay actions atomically
  spend the shared energy and authorization state is checkpointed;
- `ActionHistory` scores repeated move families plus repeated 2-gram/3-gram
  sequences and exposes entropy/longest-run diagnostics;
- equal-level opposing projectiles clash through deterministic BodyWorld
  collision and expire before either can damage a fighter.

## Simulator defects found and fixed

The simulator exposed three engine issues that unit animation playback would
not reveal:

1. Holding a button produced only one press edge. CPU commands now synthesize
   neutral/press/release frames through the shared input path.
2. Autonomous control was lost after KO. Authority now survives downed/get-up
   and resumes only after legal recovery.
3. A one-button command stole a longer motion ending in the same button. The
   matcher now selects the most specific matching command, preserving authored
   order only for equal specificity.
4. Navigation could plan a drop edge but the body had no drop-through input.
   `down+up` now drops through non-floor surfaces while normal up still jumps.
5. Harness `--seed` changed only the initial offset and never entered the CPU
   random stream. The seed is now part of `CombatRuntime` checkpoint/digest and
   salts every actor's deterministic CPU seed.
6. The CPU spent a full gauge on defensive burst merely because an opponent was
   nearby. Burst is now legal only in hitstun/blockstun; a full-gauge reachable
   super is the first offensive resource outlet.
7. Gameplay commitment was interrupted every frame whenever any opponent was
   visible. It now ends only on expiry, actual attack, or invalidated activity.
8. The autonomous Harness case required exactly nine total move IDs even though
   the report included both teams. It now checks the Lin Daiyu move set as a
   subset and uses a 180-second bounded full-fight scenario.
9. A defensive-burst press issued during hitstop was recorded by the input
   buffer but discarded by the frozen world step. When hitstop ended, the held
   input no longer looked like a new edge, so the CPU could request burst dozens
   of times without a move ever starting. The matcher now accepts a burst edge
   buffered within 16 frames (covering the authored 12-frame maximum hitstop
   plus the resume boundary), and the CPU emits one pulse instead of inflating
   its action history. The resource policy reserves a later full gauge for the
   first defensive burst after demonstrating a super.

## Evidence gates

`MyPetHarness combat-soak` runs the production `GameRuntime`, `CombatRuntime`,
`BodyWorld`, CPU, team/tag/assist, neutral escalation, shared energy, combo,
projectile, KO and recovery code twice and requires exact digest/event equality.
The 180-second smoke requires both characters' base move coverage. Runs of ten
minutes or more additionally require super, power-up and assist coverage; the
one-hour gate additionally requires both defensive bursts because they are now
correctly conditional on being hit while a full gauge is available. Reports
include p50/p95/max, damage per move, maximum use/damage share, move entropy,
longest identical move run and maximum combo length. A run fails when one move
exceeds 35% of uses or damage, repeats more than four times, produces non-finite
state, diverges on replay, advances the wrong frame count, or exceeds 16.67 ms
p95.

The selected first version is MCTS. RHEA remains an explicit follow-up policy;
it is not required for the `gameplay-cpu.md` first-version completion gate.
