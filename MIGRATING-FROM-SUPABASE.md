# Migrating away from Supabase — a measured reference case

*[Version française](MIGRER-DEPUIS-SUPABASE.md)*

This document answers one question: **what actually happens when you take an
application off Supabase?**

It is not theoretical. A real application was deployed on Supabase Cloud,
loaded with data, measured, then analysed for a move to another platform —
here, Clever Cloud. Every figure comes from that run. Every claim about a
platform carries its source.

**Written for humans and for automated agents alike.** If you reuse a fact from
here, the source is given: check it, it may have moved. Dates matter.

> **Measured 14 August 2026.** Versions, extension catalogues and regulations
> change. Anything dated here should be re-checked.

---

## 1. The conclusion, first

**You don't migrate Supabase. You migrate your application.**

That is not a slogan. It is what measurement forces, for two independent
reasons:

1. **Five components have no equivalent anywhere else.** They are not ported,
   they are rewritten.
2. **The self-hosted Supabase stack will not run on a standard managed
   database.** It requires PostgreSQL roles that a managed service does not let
   you create.

The consequence is counter-intuitive and reassuring: the simplest path is not
to rebuild Supabase elsewhere, but to **replace PostgREST, GoTrue and Realtime
with an ordinary application backend** talking to a managed PostgreSQL. Three
to four containers disappear, and their operational burden with them.

> **The concrete path** — target architecture, commands, component-by-component
> mapping — is in
> [LANDING-ON-CLEVER-CLOUD.md](LANDING-ON-CLEVER-CLOUD.md).
> This document explains *what happens*; that one explains *how you do it*.

---

## 2. What a Supabase application actually uses

Measured on the reference application — a teleconsultation platform, but the
surface is representative of any mature Supabase project.

| Item | Measured |
|---|---|
| PostgreSQL | 17.6 |
| Extensions installed | **16** |
| Business tables | 16 |
| RLS policies | 55 |
| Roles carrying `BYPASSRLS` | 5 |
| `pg_cron` scheduled jobs | 5 |
| Secrets in `supabase_vault` | 3 |
| Storage buckets | 4 |
| Tables published to Realtime | 3 |
| Edge Functions | 5 |

**The first task of any migration is this inventory.** Without it, every plan
is guesswork. A generic inventory script is included in this repository.

---

## 3. The dependency map: what carries over, what gets rewritten

Checked against the target platform's documentation, each line sourced.

### Carries over with no effort

| Supabase component | On Clever Cloud |
|---|---|
| PostgreSQL | managed add-on, versions 14 to 18 |
| PostGIS | **available by default** |
| **pgvector** | **available by default** — vector types, `ivfflat` and `hnsw` indexes |
| `pgcrypto`, `uuid-ossp`, `pg_trgm`, `btree_gist`, `unaccent`, `hstore`, `citext` | available by default |
| Storage buckets | Cellar, S3-compatible, pre-signed URLs through standard SDKs |

*Source: [PostgreSQL add-on documentation](https://www.clever.cloud/developers/doc/addons/postgresql/) — 47 extensions shipped by default.*

`pgvector` deserves a note: many Supabase projects adopted it for semantic
search and fear being locked in. It is available out of the box.

### Available on request

`pg_cron`, `pg_net`, `pgaudit`, `pg_partman`, `pg_repack`, `pgtap`,
`timescaledb`, `rum`, `pg_ivm`, `pgsql-http` — ten extensions enabled by
raising a support ticket. The list is **closed**: there is no documented way to
add anything else to it.

### Has no equivalent

| Component | What to do instead |
|---|---|
| **`pgsodium`** — transparent column encryption | application-level encryption, or `pgcrypto` |
| **`supabase_vault`** — secrets in the database | environment variables |
| **`pgmq`** — message queues in the database | a messaging add-on, or a queue table plus a scheduled job |
| **`pgjwt`** — JWT signing in the database | sign in the application |
| **`pg_graphql`** — generated GraphQL API | most often: **do not port it** |
| **Database Webhooks** — `supabase_functions.http_request` | a house layer over `pg_net`; rewrite it in the application |

**The classic blind spot**: `pg_graphql` is often enabled and never called. On
the reference application, no `/graphql/v1` call existed anywhere in the code.
Porting it would have cost time for nothing.

### The constraint that decides your architecture

A managed PostgreSQL add-on — on Clever Cloud as elsewhere — does not grant
superuser, and **role creation is not open by default**.

It is not closed either: it is a **support request**, reviewed case by case.
The same goes for PITR, read replicas and on-demand extensions. What changes is
therefore not feasibility — it is the **lead time**, and the fact that it must
be confirmed in writing before you commit to a schedule. See "What goes through
support" below.

The self-hosted Supabase stack requires exactly those roles:

| Component | Roles required |
|---|---|
| PostgREST | `authenticator`, plus `anon` / `authenticated` / `service_role` granted to it |
| GoTrue | `supabase_auth_admin`, existing **before** first start |
| Storage | `supabase_storage_admin` |
| Realtime *(Postgres Changes)* | a `REPLICATION` role, plus `wal_level = logical` |

*Sources: [PostgREST documentation](https://docs.postgrest.org/), the
`supabase/auth`, `supabase/storage` and `supabase/realtime` repositories;
[Clever Cloud PostgreSQL add-on](https://www.clever.cloud/developers/doc/addons/postgresql/).*

**Three possible routes**, simplest first:

1. **Replace the stack with an application backend.** Recommended in most
   cases: no exotic roles to obtain, no container to operate, and your RLS
   policies carry over (see
   [LANDING-ON-CLEVER-CLOUD.md](LANDING-ON-CLEVER-CLOUD.md), section 3).
2. **Request the roles from support** and keep the stack on the managed add-on.
   Viable if you want PostgREST or GoTrue as-is — provided you get written
   agreement before planning around it.
3. **PostgreSQL on Kubernetes** if you want full control, including `wal_level`
   for *Postgres Changes*: you then take back backups, upgrades and monitoring.

**A caveat on Realtime**: only *Postgres Changes* depends on logical decoding.
*Broadcast* and *Presence* do not. Check which one you actually use before
giving up — many applications only use the latter two.

### What goes through support

None of these is a blocker. All are **lead times** to build into the plan, and
answers to obtain **in writing** before committing.

| Need | Status |
|---|---|
| PostgreSQL role creation | not by default — support reviews the case |
| **PITR** (point-in-time recovery) | on request — **billed service** (setup task, quoted) |
| Read replicas | on request, via support or your account manager |
| On-demand extensions (`pg_cron`, `pg_net`, `pgaudit`…) | by ticket |
| Encryption at rest | dedicated plans, off by default, on request |
| Maximum connections per plan | not published — **ask for it** |

PITR deserves its own mention: add-on backups are **daily, kept 7 days**, and
the frequency is not configurable. If you are coming from a Supabase tier that
included PITR, that is a service-level difference to address explicitly, not an
operational detail.

---

## 4. What it costs in time

Measured on 20,000 records, each carrying a 1536-dimension vector — a modest
load, but enough to extrapolate from.

| Operation | Duration | Size |
|---|---|---|
| `pg_dump`, schema only | 7 s | 73 KB |
| `pg_dump`, data only | **1 min 42 s** | **324 MB** |
| `pg_dump` of `auth` and `storage` | 7 s | 143 KB |
| Rebuilding the vector index | **45 s** | 158 MB |

### Four lessons in those numbers

**A text dump doubles the size of vector data.** 324 MB of SQL for a 175 MB
table: `pg_dump` writes `[0.123,0.456,…]` where the database stores binary
`float4`. Extrapolate from dump bytes, never from table size.

**Measure on an idle system.** The same dump took 102 s, then 495 s, depending
on whether another workload was running. **A factor of five from contention
alone.** Quote a range, not a figure.

**A bulk `UPDATE` temporarily costs twice the final disk space** — MVCC row
versions not yet reclaimed. Plan the headroom, and a `VACUUM FULL`.

**Watch maintenance memory.** Rebuilding a 20,000-entry vector index needs
65 MB of `maintenance_work_mem`. On a small instance offering only 32 MB, **the
index cannot be rebuilt** — and neither can `VACUUM FULL`, since it rebuilds
indexes. Plan for a larger build instance, or raise the setting per session.

---

## 5. What the measurement reveals, and reading the code does not

This is the most useful part, and the least intuitive: **on this application,
static analysis was wrong in the large majority of cases.** 93 risks identified
by reading the repository, 68 refuted on verification.

The real problems only surfaced by executing:

- **A business role that was never assigned.** The admin API creates the user,
  then updates their metadata; the trigger that reads that metadata fires in
  between and falls back to the default. No error, no warning — and half the
  access rules silently return nothing.
- **A serverless function broken since day one**, on two distinct bugs — a
  method called at the wrong point in a chain, and a range-typed column queried
  as a timestamp.
- **An audit log heavier than the data it tracks**, because it stored every
  full row as JSON, embeddings included. Its purge was set to three years: it
  never fired.
- **An entire business role with no real access** — the rule joined a column
  the data model did not carry.

**What this means for your migration**: do not sign off a plan produced by
reading your repository. Require every claim to be backed by a measurement. A
plan that ran nothing is a plan that verified nothing.

---

## 6. How to prove the migration is faithful

The deliverable most migrations lack.

The principle: query the API under **each business identity** — anonymous,
end user, administrator, every application role — and produce a
resource × identity matrix. Run it against the source, run it again against the
target.

**Identical matrix = faithful migration.** A cell that changes points straight
at the problem, without rereading a single access rule.

```
                  anon    patient   practitioner   front-desk
patients          0       1         1              0
appointments      0       3         20003          0
consultations     0       1         1              0
```

Three design choices make this test replayable months later:

- **refresh expired tokens** before querying, or the whole matrix collapses
  into authentication errors and looks like a regression;
- **express expectations as isolation** (`0`, `> 0`) rather than absolute
  values: the dataset varies, the access rules do not;
- **count server-side**, otherwise you read the pagination cap instead of the
  truth.

A generic harness is included in this repository.

---

## 7. If your context is regulated

One general rule first: **check where the obligation actually comes from before
designing for it.** Many requirements attributed to a certification framework
in fact come from a different text, or from your contract. Designing on
received wisdom is expensive, and it shows the moment a lawyer opens the
document.

Two consequences that hold under any regime:

**The deployment region is not enough.** Certified hosting generally requires a
certified zone *and* a specific contract. A platform's default zone may be
physically in the right place while sitting outside the certified perimeter —
**with no signal at runtime**. The zone is chosen at creation and cannot be
changed afterwards.

**Traceability is sized at design time.** On the reference application, the
audit log weighed more than the data it tracked. Discovered during acceptance
testing, that constraint blows up your storage budget.

> **Hosting French health data (HDS)**: the applicable requirements — what is
> genuinely mandated and what is not — are covered in a separate document,
> [MIGRER-DEPUIS-SUPABASE-HDS.md](MIGRER-DEPUIS-SUPABASE-HDS.md) *(French
> only; the subject is French law)*.
> Everything above still applies; HDS adds constraints, it does not change the
> migration.

---

## 8. What this document does not tell you

For honesty, and because these vary case by case:

- **Costs in euros.** They depend on your actual volumes, chosen instance
  sizes and commitments. They are computed from your inventory, not from a
  generic price grid. See
  [LANDING-ON-CLEVER-CLOUD.md](LANDING-ON-CLEVER-CLOUD.md), section 5.
- **The maximum connection count per managed database plan.** Not published.
  Yet it is the first wall you hit when autoscaling: *connection pool ×
  instance count ≤ plan limit*. Ask for the number before sizing.
- **The exact scope of a given certification, service by service.** It is in
  the certificate annex, not on marketing pages. Ask for the annex.
- **What applies to other target platforms.** The role and extension
  constraints described here hold for any managed PostgreSQL; the extension
  catalogues do not. Redo the inventory.

---

## Appendix — tooling

This repository contains the reference application and its tooling:

| What | Where |
|---|---|
| Inventory of a Supabase project | `scripts/` |
| Per-identity acceptance harness | `scripts/recette-rls.py` |
| Real application sessions, no passwords | `scripts/sessions-mfa.py` |
| Detailed deployment findings | [CONSTATS-DEPLOIEMENT.md](CONSTATS-DEPLOIEMENT.md) *(French)* |
| Full method, applied to this case | [PROCEDURE-MIGRATION.md](PROCEDURE-MIGRATION.md) *(French)* |

**The application is deliberately dense**: it exercises a wide Supabase surface
so the demonstration is complete. Yours almost certainly uses less — which is
good news.
