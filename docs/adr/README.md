# Architecture Decision Records

This directory holds the load-bearing architectural decisions for the
Rockingham Homelab. Each ADR captures **one** decision: what was chosen,
what was rejected, and why — so a future maintainer (or future-me) can
pick up the thread without re-deriving the reasoning from chat logs and
commit messages.

## Format

Each ADR is a single Markdown file named `NNNN-short-kebab-title.md`,
where `NNNN` is a zero-padded sequence number. Numbers are never reused
and never reordered.

Every ADR has these sections, in order:

- **Status** — `Proposed`, `Accepted`, `Superseded by NNNN`, or
  `Deprecated`. The status that matters for this repository is
  `Accepted` (the decision is in force) or `Superseded by NNNN` (the
  decision was replaced; the file is kept as history).
- **Context** — what was true when the decision was made: the problem,
  the constraints, the forces in tension. Should read self-contained.
- **Decision** — the choice, stated in the active voice ("we use
  Cilium…"). Concrete enough that a reader knows what code or config
  follows from it.
- **Consequences** — what follows from the decision, both positive and
  negative. Includes operational obligations, ongoing costs, and
  things that get harder.
- **Alternatives Considered** — the options that were rejected and the
  reason for rejection. Not "we picked X because X is great" but "we
  rejected Y because Z" for each Y. This is the part that survives
  longest: anyone who later asks "why didn't you use Y?" should find
  their answer here.

## Lifecycle

ADRs are immutable once `Accepted`. To revise a decision, write a new
ADR that supersedes the old one and update the old one's `Status` to
`Superseded by NNNN`. Do not edit the body of an accepted ADR except
for typos.

If a decision turns out to have been wrong, that is itself worth
recording: the new ADR's `Context` section should explain what changed
or what was learned.

## When to write an ADR

Write one when a decision is:

- Load-bearing (other choices fan out from it).
- Non-obvious (a future reader would reasonably ask "why?").
- Reversible only at meaningful cost.

Do not write one for choices that are local, easily reversed, or
captured well enough by the code itself.
