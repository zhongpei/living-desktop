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
  same autonomous input path only after joining.

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

## Evidence gates

`MyPetHarness combat-soak` runs the production `GameRuntime`, `CombatRuntime`,
`BodyWorld`, CPU, team/tag/assist, neutral escalation, shared energy, combo,
projectile, KO and recovery code twice and requires exact digest/event equality.
The 90-second smoke requires both characters' base move coverage. Runs of ten
minutes or more additionally require super, power-up, burst and assist coverage
for both characters. Every run also requires finite state, exact frame count,
and simulation p95 below 16.67 ms.

The selected first version is MCTS. RHEA remains an explicit follow-up policy;
it is not required for the `gameplay-cpu.md` first-version completion gate.
