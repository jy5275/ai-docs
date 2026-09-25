# Ubuntu SONiC on Superdistro — Half-Year Pilot Plan

## Context

Company strategy calls for onboarding Ubuntu SONiC artifacts into
Superdistro. The `202605_resolute_rock` branch already migrates several
containers (docker-database, docker-eventd, and others) from Dockerfiles to
chiselled rocks with pebble.
The remaining gap: those rocks consume SONiC-built debs via local
`dpkg -x`, which is invisible to Superdistro's Fetch Service, breaks the
SBOM/dependency graph, and cannot build on Superdistro's build farm where
dependencies must come from the Ubuntu archive or Superdistro stores.

## Goal

Exploration, not production: prove that a representative SONiC-owned leaf
package can be onboarded as a Superdistro **bin** and consumed by a rock, and
feed platform gaps back to the Superdistro team. Expected effort: <= 5
person-weeks.

## Scope

**In:** libswsscommon bin onboarding (pilot vehicle), one rock consumption
experiment, gap report, runbook.

**Out:** other debs/wheels, installer images, full docker-database rock,
production/LTS commitment.

## Work Plan

1. **Setup (wk 1-2):** register package in sandbox plane; confirm tooling
   (bincraft vs. sourcecraft) with the Superdistro onboarding team.
2. **Onboard (wk 3-8):** fork upstream `src/sonic-swss-common` at the pinned
   commit into the origin; write `bincraft.yaml` (autotools plugin, build
   deps from archive: libnl-3-dev/libhiredis-dev/swig, amd64+arm64,
   base ubuntu@26.04); iterate buildsets on the edge channel until a bin
   lands in the store.
3. **Map deb to bin (overlapping wk 3-8):** map the 1-source/6-debs split
   (libswsscommon, python3-swsscommon, sonic-db-cli, -dev, dbgsym) into a
   bin layout compliant with the filesystem hierarchy policy; decide the
   track naming (`1.0.0-26.04`) given SONiC's ad-hoc versioning.
4. **Consume (wk 9-11):** in a rock-branch experiment, replace the
   `dpkg -x debs/libswsscommon...` line in docker-database's rockcraft.yaml
   with a slice of the new bin; validate locally with Fetch Service enabled.
   The other 12 debs stay local as a documented gap.
5. **Report (wk 10-12):** write the gap report (expected items: maintainer
   script counterparts, dev/dbgsym policy, dual-recipe placement, python
   extension module pattern) and review with the Superdistro team.

## Success Criteria

- At least one bin buildset succeeds in the store sandbox.
- The rock builds consuming a bin slice locally.
- Gap report delivered and acknowledged by the Superdistro team.
- A go/no-go recommendation for a wider rollout.