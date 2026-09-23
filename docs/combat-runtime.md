# Transitional Body and Combat Runtime (v1)

> **Transitional implementation note.** This document describes the v1 implementation
> introduced before the final module split. The authoritative target architecture is
> [Unified 2D Combat-Capable Runtime](unified-2d-combat-runtime.md). In particular, generic
> body physics still lives in `MyPetCombat`, `PetModel` and `CombatWorld` temporarily share
> position responsibility, the combat simulator is still a separate runner, and rendering
> has not yet reached the final immutable `RenderSnapshot` interface.

Living Desktop v1 introduces a deterministic combat/body path alongside the existing desktop
body as a migration step. Fighting is a capability of the world, not a second game mode, but
the single-authority body design is not complete until the target architecture above lands.

## Runtime boundaries

```text
Goal / Story / Relationships                 20 Hz semantic cadence
              |
              v
       semantic/body requests
              |
              v
+-----------------------------------------------+
| MyPetCombat                                   |
| fixed 60 Hz                                   |
| input buffer / command matcher                |
| movement / gravity / surfaces / push boxes    |
| hit boxes / hurt boxes / guard / hitstop      |
| hitstun / knockback / KO / recovery           |
+----------------------+------------------------+
                       |
                       v
             immutable BodyPose snapshots
                       |
              +--------+---------+
              |                  |
              v                  v
       Render backend       Headless simulator
```

The existing 50 ms GameKernel clock remains the compatibility cadence for goals, story
beats, claims and relationships. A 50 ms semantic tick contains three 60 Hz body frames.
Keyboard, mouse and combat contacts are processed at body-frame latency rather than waiting
for a story decision.

## Control sources

The body never has separate "AI physics" and "player physics".

- manual control writes `FighterInputFrame`;
- `UtilityCombatPolicy` writes the same `FighterInputFrame`;
- command synthesis used by tests/policies feeds the same command matcher;
- authored story actions stay semantic commands, because reading, talking and handing over
  a prop are not fighting motions;
- mouse drag is an explicit high-priority body authority and restores the previous
  manual/autonomous authority after the tossed actor lands.

The first manual mapping is arrows for direction/jump/crouch, Z/X/C and A/S/D for the six
fighting buttons and Escape to leave control. The control utility
window becomes key only after the user explicitly chooses "接管控制"; normal desktop play
does not require a global event tap or Input Monitoring permission.

## Physics and collision

All coordinates use the existing flipped desktop world (origin at the main screen top-left,
Y positive downward). Screen floors and real window top/bottom edges are projected as
`CombatSurface` values.

Collision is purpose-specific:

- environment surfaces: support, landing and falling;
- push radius: character occupancy;
- hurt boxes: vulnerable character geometry;
- hit boxes: attack geometry;
- story slots/sensors: interaction reach, not damage.

Hit boxes and hurt boxes are character-local AABBs mirrored around the character axis when
facing changes. A contact is first detected from an immutable frame snapshot and only then
resolved, so same-frame trades do not depend on actor dictionary iteration order. Each
move keeps a per-target hit set to prevent one active box from damaging the same target on
every active frame.

The current native desktop body keeps the established ~1600 pt/s² gravity. At 60 Hz this is
`1600 / 60² = 0.4444 pt/frame²`, matching the scale used by MUGEN-style engines closely.

## Move timeline

Animation frame count is not game-frame count. A move owns a 60 Hz timeline:

```text
startup -> active -> recovery
             |
             +-- hitbox enabled
```

`combat.json` is optional. A role without it remains fully usable for ordinary stories
and desktop interaction, but has no authored damaging moves.

Format version 1 contains a full `CombatProfile`: HP, movement constants, hurt boxes,
moves, downed recovery duration, get-up duration, revived HP fraction and temporary
invulnerability. A move references an existing petpack action through `visualAction`;
missing presentation content must not create a hidden damaging move.

This runtime provides MUGEN-style mechanics. It does **not** claim v1 compatibility with
MUGEN CNS/AIR/SFF file formats or arbitrary existing MUGEN character packages.

## HP, knock-out and recovery

HP reaching zero never destroys an actor.

```text
active
  -> knockedOut (keep physical knockback/fall)
  -> downed (stable ground required)
  -> gettingUp
  -> active
```

Default profile values are 8 seconds downed, 0.6 seconds getting up, 30% HP restored and
2 seconds of recovery invulnerability. They are content parameters rather than engine
constants.

A downed actor may still be dragged or tossed. Recovery waits for a safe grounded state;
dragging therefore does not erase HP, reset the recovery state or revive an actor in mid-air.

## Story compatibility

StoryDirector, RelationshipGraph, slots, props, window interaction, entry/exit and semantic
actions remain authoritative at their existing layer. The migration rule is:

- narrative decides **why/what**;
- body/combat decides **whether/how the physical action occurs**;
- renderer only displays committed snapshots.

Legacy story movement currently uses `PetModel` as a compatibility façade. Its integration
has been moved to the same fixed 60 Hz frame grid. Whenever fighting, hitstun, knock-out,
manual control or autonomous combat owns an actor, `CombatWorld` becomes the live position
authority and projects its body state back into the façade. The synchronization seam is
intentional migration debt: v1 still has two body implementations, and the target design
moves their generic physics into one `MyPet2D.BodyWorld`.

## Simulation and replay

`CombatDataSimulation` uses the same v1 `CombatWorld` implementation used by the macOS
combat coordinator, but it remains a separate runner from `GameRuntime` in this transitional
version. `VirtualDesktop` supplies virtual screens/windows instead of AppKit/CGWindowList.
Snapshots contain the combat frame, bodies, profiles, input buffers and current inputs, so
restore/replay does not fake movement by waiting a number of story ticks.

Existing `HarnessScenario` files remain valid. They can opt into the combat track with
`combatActors` and `combatInputs`; an empty combat track preserves existing story-only
behavior.

## Rendering boundary

The v1 presentation path no longer depends directly on a concrete actor window. It writes
through the intermediate seams:

- `ActorRenderBackend`;
- `ActorRenderSurface`.

The v1 backend is `CoreAnimationRenderBackend`, implemented with native AppKit transparent
panels and CALayer composition. This keeps the current desktop-window behavior and avoids a
third-party game-engine dependency.

The target design replaces these surface-level seams with immutable `RenderSnapshot` values
and a stable `RenderBackend`. Metal remains a measured follow-up, not part of this v1 PR.

During combat, body coordinates are marked `authoritativePlacement`; presentation must not
apply a second actor-spacing pass. Purely visual transitions such as opacity remain renderer
concerns, while displacement must be represented in world/body state.

## Upstream references

The 60 Hz frame model, input buffer/command matcher, AABB hit geometry and combat data
boundaries were implemented with reference to the MIT-licensed Fighters Paradise and
IKEMEN GO engines. Exact attribution and inspected revisions are recorded in `NOTICE.md`.
