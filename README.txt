CoA Analytics 2.17.0
====================

CoA Analytics analyzes specializations and roles on the CoA server. The addon
brings together battleground nameplates, an enriched scoreboard, the historical
battleground ranking, and the PvE rankings for dungeons and raids.

Architecture 2.7
----------------

- Core, BG ranking, nameplates, PvE tracking, PvE interfaces, the dungeon
  widget, the main interface and the scoreboard are loaded as separate modules.
- Each file stays well under the 200-active-local limit of the Lua 5.1 client
  so new features can still be added.
- An internal API and event bus keep direct dependencies to a minimum.
- The persistent table stays strictly CoAAnalyticsDB: no data and no schema
  version is reset by this architecture change.
- Search uses OnTabPressed, compatible with Ascension 3.3.5, and every panel is
  hidden while being built to avoid overlaps.

Battleground ranking
--------------------

- The data and ranking from CoA BG Intelligence are preserved.
- Two views: anonymous specializations and individual players.
- Two categories: Damage and Healing.
- Specializations close to the best result share the points.
- A collective coefficient reduces the influence of unbalanced battlegrounds.
- The score is normalized by weighted attendance: a specialization that shows
  up often becomes more reliable, not artificially stronger.
- Five virtual battlegrounds at the mean stabilize small samples.
- Legacy Top 1 finishes, samples and battleground weights are preserved.
- In three-point capture-the-flag battlegrounds, an unlabeled countdown is
  placed under the objectives and refreshed once per second.
- The timer recognizes CoA variants by their /3 objective, works with both
  Blizzard and ElvUI frames, and stays hidden without a reliable limit.

Individual battleground ranking
-------------------------------

- Separate rankings for DPS, healers, tanks and supports.
- DPS can be filtered as All, Melee or Ranged.
- Each player is compared only against players in the same role in that match.
- Three placement battlegrounds are required before an official rank; players
  tracked once or twice stay visible but unranked.
- Metrics are compared to the role average with a continuous, strictly
  increasing curve: two large results no longer share the same ceiling and the
  best result stays distinguishable.
- Damage and healing are cautiously adjusted to the median level of the role in
  that battleground, without erasing the impact of the spec or the player.
- Measurable interrupts, dispels and spell steals enrich tank and support
  scores without keeping per-event detail.
- Healers are scored 95% on healing and 5% on survival.
- A score of 100 represents the role average and is smoothed with 10 virtual
  battlegrounds.
- The ranking uses a conservative bound: an uncertainty margin is subtracted
  from the smoothed score. It is large with a single battleground and shrinks
  with each weighted appearance, so a new player cannot artificially overtake
  an already-confirmed performance.
- Consistency reports the percentage of battlegrounds within 90% of the best
  player in the same role.
- The collective stomp coefficient reduces the battleground's influence
  identically for every player.
- Mid-match arrivals and departures are measured: statistics are corrected to
  time played and their historical weight follows the attendance rate.
- Under 25% attendance, zero damage for a DPS, or zero healing for a healer
  produces no individual sample.
- A result is only accepted after the battleground has been observed active and
  then finished, so a stale winner from the previous match is ignored during a
  loading screen.
- The rank uses an icon; the name is colored by class.
- Specializations are grouped under one icon with a detailed tooltip.
- The last time you met each player is shown in the table.
- Every header explains its value on hover.
- Name search offers up to eight players in autocomplete.
- This ranking starts with version 2.2.0 because the older history only held
  anonymous per-specialization data.
- Version 2.7.0 keeps an exact copy of the old samples in each entry, converts
  their mean onto the new curve without changing their order, corrects the
  detectable double counters, and then applies the full new algorithm to every
  subsequent battleground.

PvE ranking
-----------

- Three categories: Damage, Healing and Tanks.
- Three views: All, Dungeons and Raids.
- A completed dungeon constitutes one complete sample.
- A defeated raid boss constitutes an independent sample.
- Dungeon DPS: boss weighting adapted to combat time, a robust reference
  against the other DPS, and a correction for participation time.
- A boss or trash phase that is too short, too marginal, or observed on a
  single DPS is ignored so a stray event cannot invert the ratings.
- Damage is corrected against the median level of the group's DPS with a
  cautious, bounded curve: level is smoothed without erasing build, gear or
  actual performance.
- Raid DPS: performance on the defeated boss.
- Healing: stability, recovery, coverage, availability, mana and prevention.
  Overheal weighs only 2%.
- In raids, contribution is adjusted to the number and profile of healers.
- Tanks: threat control, enemy pickup, stability, mitigation, external help,
  damage spikes and survival.
- A score of 100 represents the average of a comparable context.
- Ten virtual samples stabilize small data volumes.
- Confidence: Provisional (<5), Medium (5-19), Reliable (20+).
- Progress bars use the same role colors as the BG ranking with stronger
  contrast.

Real-time PvE performance
-------------------------

- A separate tab tracks every character in the current dungeon in real time.
- Progress bars take the red, orange, yellow or green color of the rating and
  use stronger contrast.
- The last dungeon stays viewable after leaving the instance.
- The data is replaced only at the start of the next dungeon.
- Each character receives a rating out of 10 adapted to their role.
- 7/10 represents the expected performance for that role and that group.
- A compact, movable widget can show each player's name and rating inside a
  dungeon. It reuses the existing snapshot, with no second collection pass.
- Names temporarily unavailable at load are rescanned and also recovered from
  the combat log instead of remaining "Unknown".
- The widget hides itself automatically outside dungeons.
- DPS: robust comparison against the other DPS, with adaptive boss weighting,
  participation time and the same level correction as the history.
- The displayed DPS/HPS stays raw; only the comparative rating is adjusted.
- Healers: stability, effective healing, recovery, availability, mana,
  absorbs and utility.
- In a dungeon with a single healer, the rating no longer depends on a second,
  nonexistent healer. It combines health stability, coverage, recovery speed,
  mana management, prevention/utility and time alive.
- Responsiveness measures the exit from danger at 65% health first. The full
  return to 80% is still diagnosed separately so HoTs are respected.
- Without a critical failure or an avoidable death, a gradual recovery can no
  longer on its own cause a heavy responsiveness penalty.
- The dungeon's real pressure determines confidence and historical weight,
  without artificially capping the displayed execution rating.
- Group health is sampled every 0.5 seconds during combat to measure dips below
  75%, 50% and 25%, as well as recoveries.
- Tanks: threat control, mitigation, help received and survival.
- Supports: contribution per minute, participation, time alive and detectable
  utility, compared against an equivalent historical context.

Clutch healing
--------------

Any heal or absorb that lands on a group member who was at or below 35% health
is recorded as a clutch heal, and one at or below 20% health worth at least 10%
of the target's health pool is recorded as a likely life save. Credit scales on
two axes: how close to death the target was, and how much of their health pool
the heal actually returned. A trivial tick on someone at 34% is worth almost
nothing; a large heal on someone at 8% is worth full credit.

This exists so off-healing is not invisible. A damage dealer who drops a heal to
save the tank or the healer is doing something their damage number cannot
express, and now receives up to 4 points of score for it. Supports and healers
can receive up to 6. Self-heals are tracked and shown, but never rewarded:
surviving your own mistake is not the same as saving somebody else.

Healer damage contribution
--------------------------

A healer who also contributes damage is rewarded, worth up to 6 points, scaled
by their damage rate against the robust mean of the actual damage dealers in the
same fight. The bonus is gated: it only opens once stability, coverage and
responsiveness are collectively above par, and it closes completely if anybody
died a death that healer could have prevented. Damage can therefore never be
traded against healing.

Tank mitigation and self-sustain
--------------------------------

Mitigation is measured from what the combat log actually proves, so no spell
list is needed and it works on a custom client whose defensive abilities the
addon cannot know:

- The resisted, blocked and absorbed portions of every hit the tank took.
- Attacks avoided outright through dodge, parry, block, miss or immunity.
- Self-healing and self-absorbs applied while actively tanking.
- Whether that mitigation is concentrated in the dangerous windows. Once a tank
  has taken more than 15% of their health pool inside two seconds they are
  flagged as under pressure, and mitigation during those windows is accounted
  separately. A tank who holds cooldowns for the spikes scores above one who
  bleeds them on trash.

Self-casts during a pressure window are counted and displayed, but never
scored: the client exposes no reliable way to tell a defensive cooldown from
any other self-cast, so the scored signal is the measured outcome above.

Tank score weighting is threat 38%, damage-taken resilience 30%, mitigation
quality 20%, survival 12%.

Run pace
--------

A dungeon is cleared in wall-clock time, not in combat time, so the gaps between
pulls are measured alongside the pulls themselves. The real-time panel reports
the pull count, the share of the run actually spent in combat, and total
downtime. A group with ordinary throughput and no downtime finishes ahead of a
group with excellent throughput that drinks after every pack, and until now
nothing in the addon could see that difference.

Downtime only counts once a gap exceeds five seconds, so the normal seconds
between packs are not mistaken for idling.

Interrupt coverage
------------------

Enemy casts are tracked from SPELL_CAST_START to their resolution, so interrupts
are expressed as coverage rather than as a raw count: how many enemy casts were
stopped out of how many were attempted. Interrupts and dispels are now also
counted separately per player instead of being pooled into one utility tally.

Not every enemy cast is interruptible, so treat the percentage as a comparable
signal between runs of the same dungeon rather than as an absolute grade.

Avoidable damage
----------------

When one spell hits the same non-tank three or more times inside a single pull,
everything past the second hit is recorded as likely avoidable damage. A
mechanic can legitimately catch someone once; being hit by the same thing five
times is the clearest evidence a 3.3.5 client can give that the player was not
moving. This needs no per-spell database, which matters on a custom client whose
abilities the addon cannot know in advance.

The per-player tooltip reports the number of repeat hits, the damage they cost,
and what share of that character's total damage taken they represent. The
tracker resets at the end of each pull and caps the number of distinct spells it
follows per player, so it cannot grow without bound.

Pet and guardian attribution
----------------------------

Damage from pets and guardians is attributed by reading the combat log's own
object flags, so the addon never needs to know which of the 21 classes or 70
specs summoned what. Ownership learned from any SPELL_SUMMON is also keyed by
pet name, which recovers a guardian that was recast with a fresh GUID after a
summon event was missed.

Anything the flags prove is a group pet but that still cannot be traced to an
owner is recorded rather than silently dropped. "/coaa pve pets" lists those
sources by name and damage, so the specs actually affected come from your own
log instead of guesswork.

Level scaling
-------------

Level correction now uses the level-scaling table that Details ships, which is
generated by the Ascension launcher and is the authoritative answer for how this
server scales damage between levels. The addon's own curve was only ever a
cautious guess made without access to those numbers, and it was clamped to a
range far narrower than reality: on a level 60 character the real modifiers run
from roughly 1388% at level 20 down to 40% at level 80, while the old curve
never moved further than 0.65x to 1.55x.

Normalization matches Details exactly, into the local player's level frame, so
both addons agree on what a level difference is worth.

The Details table is only used where Details itself would use it, so a context
the server does not scale is left alone. If Details is missing, disabled, or
returns no modifier, the built-in curve still applies and the tooltip says which
source produced the number. "/coaa pve status" reports the same thing, including
a sample modifier, so it can be confirmed at a glance.

Hybrid grading
--------------

Specs that fill two roles are graded on a curve against both, because judging
them purely as supports buried their real contribution.

Which curve applies is decided by group composition, since that is what sets
the expectation:

- With a dedicated healer in the group, the hybrid is the secondary and is
  expected to deal damage. Healing counts, but credit is capped at 60% of a
  dedicated healer, because a hybrid cannot replace one.
- With no healer at all, the hybrid is the healer. Its damage is expected to
  be far lower and is never penalised for that. Healing is measured against the
  healing the fight actually demanded rather than against a healer who is not
  there.

In damage mode a hybrid is also expected to clearly out-damage the actual
healers; landing near healer-level damage scales the score down. That penalty
fades out as the hybrid's own healing rises, so a spec doing two thirds of a
real healer's work is never punished for it.

Doing a full damage dealer's output while still healing meaningfully earns a
synergy bonus. Genuine outliers are scaled, never disqualified.

Wipe prevention
---------------

A life-saving heal counts as wipe prevention when it lands on the tank or the
healer, when the group was already collapsing, or when a non-healer covers most
of the party inside one window. All three mean the next death likely cascades,
and all three are weighted far above an ordinary save.

Scoring breakdowns
------------------

Hovering a character's row in the real-time dungeon panel shows the full
breakdown behind their rating: every component, its measured value, and the
bonuses applied. Damage dealers see phase weighting, output ratios,
participation, time alive and their utility and clutch bonuses. Healers see
stability, coverage, responsiveness, availability, mana, prevention, recovery
timings and their damage contribution with its gate. Tanks see threat uptime,
losses, pickup timing, and the complete mitigation panel. Clutch healing is
shown for every role that recorded any.

PvE collection
--------------

Collection starts automatically in dungeon- and raid-type instances. The combat
log is processed in real time and only aggregated statistics are kept. Threat is
sampled roughly three times per second, and only during combat, to limit the
impact on the game.

Damage attribution follows the Details! convention: the absorbed portion of a
hit is credited to the attacker, so a shielded target no longer deflates the
attacker's output. Guardians and temporary pets (totems, ghouls, mirror images,
elementals, treants) are learned from SPELL_SUMMON and their mapping to an owner
survives roster refreshes, so their damage is credited to the summoner. The
DAMAGE_SPLIT event is also parsed.

Official encounter-end events validate raid bosses. Completion events validate
dungeons. If the client does not produce the completion event, leaving shortly
after a defeated boss can validate the dungeon with an inferred completion
status.

Battleground nameplates and scoreboard
--------------------------------------

- Role and specialization icons above or inline with the nameplate.
- Melee and ranged DPS roles are differentiated.
- Compatible with Blizzard and ElvUI nameplates.
- BG scoreboard: specialization icon, role, level, class color, top damage and
  top healing.

Settings
--------

- General settings and nameplate settings are separated.
- The dungeon performance widget can be enabled, hidden and repositioned.
- A widget button shares the overall rating, then one line per player, into the
  party or raid channel.
- PvE collection continues as long as the group is fighting, even if the user is
  dead. The last boss is consolidated before the dungeon is recorded.
- Instant deaths are distinguished from deaths preceded by a long critical
  period.
- The healer rating focuses on stability, responsiveness, availability and mana
  management. Overheal weighs only 2%.
- When the user is the sole healer, deaths and damage outside their range, out
  of combat, or during the run back after a wipe no longer lower their rating.
  A death is still shown in the raw report.
- DPS use a robust reference, adaptive boss weighting and the participation time
  specific to each phase. Idle players and replaced former members no longer
  skew the group reference.
- Replacements stay visible individually, but group size uses the maximum number
  of players present simultaneously.
- A diagnostic can be enabled for the current or the next dungeon. Tracking then
  stays active and keeps the last 10 dungeons without duplicates.
- An entry with no combat no longer consumes the diagnostic and can no longer
  replace a valid report. Export picks the most recently completed dungeon and
  keeps the diagnostic armed until the first real fight.
- The diagnostic reports the number, duration and origin of boss and trash
  segments to make atypical Ascension clients easier to analyze.
- The "Export reports" button automatically reloads the interface and writes the
  history to WTF\Account\<account>\SavedVariables\CoAAnalytics.lua.

Migration from CoA BG Intelligence
----------------------------------

The main folder becomes CoAAnalytics and the database becomes CoAAnalyticsDB. A
small migration bridge loads the old CoABGIntelligenceDB once and copies all
settings and BG rankings. It does not recalculate, reset or delete any
historical data.

Commands
--------

/coaa settings       opens the interface
/coaa ranking        opens the BG ranking
/coaa players        opens the individual BG ranking
/coaa pve            opens the PvE ranking
/coaa performance    opens the current or previous dungeon performance
/coaa pve status     shows the state of PvE collection
/coaa pve complete   manually validates the active dungeon (fallback)
/coaa pve log on     enables continuous dungeon diagnostic tracking
/coaa pve log off    cancels the diagnostic
/coaa pve log status shows the status and the file path
/coaa pve log clear  clears the stored diagnostics
/coaa status         shows the state of BG nameplates
/coaa debug          toggles BG debug
/coaa retry          restarts specialization detection
/coaa log            opens the BG detection log
/coaa log clear      clears that log

The French aliases (classement, joueurs) and the historical /coabgi command are
still accepted for compatibility.
