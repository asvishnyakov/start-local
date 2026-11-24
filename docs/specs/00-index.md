# Design Specs Index

> Internal design proposals: the "why/how" (problem, options, chosen approach, trade-offs) that precedes an implementation plan.
>
> **Living** while being drafted, overwritten in place. **Historical / append-only** once a plan is drawn against a spec or code exists: from then on, never rewrite it. Corrections and outcomes go in a dated *Amendments* / *Outcome* section, original intact, and the current tree is authoritative for what was built.

## Files (newest first)

| Date | Spec | Topic | Status | Research |
|------|------|-------|--------|----------|
| 2026-11-24 | [shared-services](2026-11-24-shared-services-design.md) | One services stack (DB, Elasticsearch, Kibana, Redis) shared by several platform stacks over a shared Docker network; each platform at one `https://<name>.dev.internal:<port>` URL for every caller (RND-167); decisions S1–S19 | Planned: [plan](../plans/2026-11-24-shared-services.md) (historical; amended 2026-11-24) | none (gate waived 2026-11-24; facts in its §13) |
| 2026-10-15 | [redesign-choices](2026-10-15-redesign-choices.md) | Verbatim record of the 15 choice prompts (52 questions) behind the redesign, plus a review of the decision log and spec against them: 3 contradictions, 3 unflagged divergences | Review (historical) | [fact check](../research/2026-10-15-redesign-fact-check.md) |
| 2026-10-15 | [env-first-redesign](2026-10-15-env-first-redesign-design.md) | Redesign of start-local around one `.env`: release-pinned installer, `COMPOSE_FILE` as the stack definition, Docker-or-source platform and modules, HTTPS by default, migration of existing folders | Implemented: [plan](../plans/2026-11-10-env-first-redesign.md) (historical) | [fact check](../research/2026-10-15-redesign-fact-check.md), [review follow-up](../research/2026-10-18-redesign-review-follow-up.md) |
| 2026-10-15 | [redesign-decisions](2026-10-15-redesign-decisions.md) | The decision log behind env-first-redesign, with IDs (A1, B2…) that the spec cites; read it for the rationale of a single choice | Living | [fact check](../research/2026-10-15-redesign-fact-check.md), [review follow-up](../research/2026-10-18-redesign-review-follow-up.md) |

## Conventions & Writing Style

- Naming `YYYY-MM-DD-<kebab>.md` (authored date).
- Tone: problem statement → options → chosen approach → trade-offs. Specs hold the design, plans hold the steps.
- Cite decisions by ID from a spec's decision log and evidence by section from its research note, rather than restating them.

## Notes & Caveats

- **env-first-redesign** lists the facts still to verify while implementing in its §15.
- **shared-services** lists its open facts in §15; each is a stop-and-report step for its plan. Its S7 departs from the env-first fixed container ports (SPEC §6) for the reason given there.
- A spec marked "no plan yet" has been proposed but not executed.
- **redesign-choices** reviews the decision log and the spec as they stood on 2026-10-15. Its *Outcome* (§2.7) records which findings were applied.
