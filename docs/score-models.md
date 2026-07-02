# MCAT score models — Memory, Performance, Readiness

One-page description of the three scores, the give-up rule, and the
readiness→scaled-score mapping (PRD deliverable: "One-page model descriptions
(memory/performance/readiness) including the give-up rule").

**Honesty first.** Honesty is graded and *fabricated or misleading readiness
numbers = automatic fail*. So: Memory is computed only from the engine's own FSRS
retrievability; every score is a **range, never a single blended number**; the
Performance/Readiness models are **uncalibrated and labelled provisional**; and
below the give-up line the app shows **no scores at all**.

Code: the pure math is `AnkiKit/Sources/AnkiKit/BackendReadiness.swift`
(`ScoreModel`, `ScoreRange`, `ReadinessProjection`, `ReadinessAssessment`); the
engine inputs come from `Backend.readinessEvidence(forDeck:)` and
`Backend.coverage(forTopics:inDeck:)`; the UI is
`AnkiApp/Sources/ReadinessDashboardView.swift`. Tests:
`AnkiKit/Tests/AnkiKitTests/AnkiKitTests.swift`.

---

## The give-up rule (exact line)

> **No score until ≥200 graded reviews AND ≥50% topic coverage.**

(`ScoreModel.giveUpRule`. The 50% half is `CoverageReport.scoringThreshold`; the
200 half is `ScoreModel.gradedReviewThreshold`.)

- **Graded reviews** = the sum of each studied card's review count (`card.reps`,
  surfaced by `card_stats` as `reviews`) across the deck. A manual reschedule
  does not increment `reps`, so this counts graded answers only.
- **Coverage** = share of the 50 `MCATOutline` topics that have ≥1 card, scoped
  to the deck (`Backend.coverage(forTopics:inDeck:)`).
- Both halves must clear, **and** there must be real FSRS memory data, or the
  dashboard shows the **abstain** state: what's missing (review/coverage
  progress) and the single best next thing to study — and no score numbers.

---

## 1. Memory — chance of recalling a *taught* fact now

- **Data (real):** the engine's per-card FSRS retrievability for every studied
  card (`deck:"…" -is:new`) that carries FSRS memory state, read from
  `card_stats` (43/0). The core computes it via
  `FSRS::current_retrievability_seconds(memory_state, seconds_since_last_review,
  decay)` — the same function it uses everywhere. We never synthesise a
  retrievability value.
- **Point estimate:** the mean of those retrievabilities.
- **Range (count-based):** a 95% normal-approximation confidence interval on the
  mean, `mean ± 1.96·(sd/√n)`, clamped to `0…1`. It **narrows as more cards back
  it**. With one card the spread is undefined and the interval collapses to the
  point (treated as low confidence).
- **Confidence:** from the number of contributing cards — `<25` low, `25–79`
  moderate, `≥80` high. (Memory is real data, so unlike the other two it can earn
  confidence above "low".)

## 2. Performance — chance on a *new* exam-style question (PROVISIONAL)

There is **no validated exam-question model yet** (that is the later AI /
held-out-eval phase). So Performance is a conservative, clearly-labelled estimate
discounted from Memory, with a **wide** range. On screen and in the data it
carries:

> *Provisional — not yet calibrated against held-out exam-style questions.*

- **Model (expected value over the whole exam):**

  ```
  p = coverage · (memory · transfer) + (1 − coverage) · guessBaseline
  ```

  - `memory` = the Memory estimate (recall of taught facts).
  - `transfer` = recall→application discount. Recall of a memorised fact
    overstates the chance of answering a *new* exam-style question (the PRD 7d
    paraphrase gap), so we discount. **Uncalibrated**, so the band is wide:
    `transfer ∈ {0.50 (low), 0.675 (point), 0.85 (high)}`.
  - `guessBaseline = 0.25` — the 4-option multiple-choice floor on the share of
    the exam not yet covered.
- **Range:** the Memory low/high are propagated through the wide transfer band, so
  the interval is intentionally broad.
- **Confidence:** pinned to **low** until calibrated.

## 3. Readiness — projected MCAT score (472–528), PROVISIONAL

- **Scale:** total **472–528** (span 56); each of the four sections **118–132**
  (span 14).
- **Mapping (documented, first-order, uncalibrated):** map a correctness
  probability `p` linearly onto the total scale:

  ```
  scaled(p) = round(472 + p · 56)        // clamped to 472…528
  ```

  Endpoints: `p=0 → 472`, `p=0.5 → 500`, `p=1 → 528`.
- **Driver:** Readiness maps the **provisional Performance** range (which already
  folds in Memory and coverage) onto the scale, so it inherits Performance's wide
  band:
  - `readiness.low  = scaled(performance.low)`
  - `readiness.point = scaled(performance.point)`
  - `readiness.high = scaled(performance.high)`
- **Never a single number.** It is always shown as a range with a confidence note
  and the % of the exam covered, e.g.
  `Projected 497 · likely 491–504 · confidence: low — 60% of topics studied`.
- **Confidence:** **low** until the held-out exam-style evaluation calibrates the
  model.
- **Per-section bands (118–132):** the same mapping applies per section
  (`118 + p_section · 14`). Per-section *projection* is deferred until per-section
  calibration; today the dashboard shows the per-section **coverage** context and
  the calibrated **total** range. Worked example: a section with `p_section = 0.45`
  would map to `118 + 0.45·14 ≈ 124`.

---

## Ranges & confidence — summary

| Score | Source | Point | Range method | Confidence |
|---|---|---|---|---|
| Memory | Real FSRS retrievability (`card_stats`) | mean | 95% CI on the mean (count-based, clamped 0–1) | scales with card count |
| Performance | Memory × transfer, blended with guess by coverage | mid transfer | wide transfer band × Memory CI | low (provisional) |
| Readiness | Performance mapped to 472–528 | `scaled(point)` | `scaled(low)…scaled(high)` | low (provisional) |

## The honesty read-out (shown with every scored result)

Per the mandatory honesty rule, alongside the numbers the dashboard shows: the
**evidence** behind each score, **what data is missing**, the **likely range**, a
**confidence** indicator, the **% of exam covered**, the **last-updated** time,
the **main reasons**, and the **single best next thing to study**.
Past-prediction accuracy is reported as *"not enough history yet"* until the eval
phase.

## Demonstrating both states

- **Abstain (real):** the seeded **"MCAT Content"** deck (~48% coverage, no
  reviews) correctly shows the abstain dashboard.
- **Scored (demo):** the clearly-marked **"MCAT Readiness Demo"** deck seeds real
  MCAT facts plus a *simulated study history* (stored FSRS memory state + review
  counts) so it crosses both thresholds (60% coverage, >200 reviews). Every score
  it shows is still computed by the engine from that stored state — the seeding
  simulates having studied; it does not hand-write any score.
