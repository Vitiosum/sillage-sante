# Landing on Clever Cloud

*[Version française](ATTERRIR-SUR-CLEVER-CLOUD.md)*

You have read [MIGRATING-FROM-SUPABASE.md](MIGRATING-FROM-SUPABASE.md) and you
know what carries over and what gets rewritten. **This document is the concrete
path**: what you create, in what order, with which commands.

> Verified 14 August 2026 against official documentation. Catalogues change:
> check before you commit to a number.

---

## 1. The recommended target architecture

The one that fits most Supabase projects:

```
                    ┌──────────────────────────────┐
   browser ───────► │  your application            │
                    │  (Node, Go, PHP, Python…)    │
                    │  = replaces PostgREST,       │
                    │    GoTrue and Realtime       │
                    └──────┬────────────────┬──────┘
                           │                │
                  ┌────────▼──────┐  ┌──────▼────────┐
                  │ PostgreSQL    │  │ Cellar        │
                  │ add-on        │  │ (S3)          │
                  └───────────────┘  └───────────────┘
                           ▲
                  ┌────────┴──────┐
                  │ cron          │  = replaces pg_cron + pg_net
                  │ clevercloud/  │
                  └───────────────┘
```

**Two managed services and one application.** No container to operate, no
exotic PostgreSQL roles to recreate, no secrets living in the database.

If you must keep the Supabase stack as-is — because you depend on *Postgres
Changes*, or because rewriting the backend is not an option right now — the
target becomes **Kubernetes** with a PostgreSQL you administer yourself. That
is a different job: you take back backups, version upgrades and database
monitoring.

---

## 2. Provisioning, in order

```bash
clever login
```

**Create the application.** The type determines the detected runtime:

```bash
clever create --type node my-app --alias my-app --region par
```

> **Regulated context**: the zone is chosen here and **cannot be changed
> afterwards**. See
> [MIGRER-DEPUIS-SUPABASE-HDS.md](MIGRER-DEPUIS-SUPABASE-HDS.md) *(French)*.

**Add the database and object storage.** The `--link` option attaches them
directly and **automatically exposes their environment variables** to the
application:

```bash
clever addon create postgresql-addon my-app-pg --link my-app
```

```bash
clever addon create cellar-addon my-app-cellar --link my-app
```

Without `--plan`, the cheapest plan is selected. For production, pick a
**dedicated** plan: encryption at rest is only available there, is not enabled
by default, and is turned on by support request.

**Look at the variables that were actually injected** — do not guess their
names:

```bash
clever env --alias my-app
```

For Cellar there are exactly three: `CELLAR_ADDON_HOST`,
`CELLAR_ADDON_KEY_ID`, `CELLAR_ADDON_KEY_SECRET`. **`HOST` is a bare hostname,
with no scheme** — prefix `https://` yourself in your S3 client.

**Add your own variables** from a dotenv file:

```bash
clever env import --alias my-app < .env.production
```

---

## 3. The mapping, one component at a time

### Your PostgreSQL extensions

47 extensions ship by default and are enabled with `CREATE EXTENSION` without
asking anyone — including **PostGIS and pgvector**.

Ten more are available by support ticket, including **`pg_cron` and `pg_net`**.

Five do not exist and must be rewritten: `pgsodium`, `supabase_vault`, `pgmq`,
`pgjwt`, `pg_graphql`. The full mapping table is in
[MIGRATING-FROM-SUPABASE.md](MIGRATING-FROM-SUPABASE.md).

### Your RLS policies

**They carry over unchanged** — this is standard PostgreSQL. What does not
carry over are the **roles** they rely on: a managed add-on does not let you
create `anon`, `authenticated` or `service_role`.

Two options:

- **keep RLS**, anchored to the owner role, with the application setting the
  user context on every request;
- **move authorisation up into the application**, with the database no longer
  acting as a backstop.

The first keeps defence in depth. The second is simpler to reason about.
Choose — but **choose deliberately**: this is the most structural security
decision of the whole migration.

### Your Vault secrets

They become environment variables. `clever env import` sets them, the platform
injects them, and they leave the database — a net gain: no more secrets being
decrypted on the query path.

### Your `pg_cron` jobs

A `clevercloud/cron.json` file at the repository root:

```json
[
  "0 * * * * $ROOT/clevercloud/task.sh appointment-reminder",
  "*/5 * * * * $ROOT/clevercloud/task.sh process-queues"
]
```

**The trap to know about**: cron jobs run on **every instance**. With three
instances, the task fires three times. Clustering is not supported —
deduplication is on you:

```bash
# At the top of clevercloud/task.sh
if [[ "${INSTANCE_NUMBER:-0}" != "0" ]]; then
  exit 0
fi
```

In the database, the job ran once. Here, it runs as many times as you have
instances. A reminder sent three times is noticed; a purge run three times,
much less so.

Two further differences: `@reboot` does not exist, and paths must be absolute —
hence `$ROOT`.

### Your `pg_net` calls in triggers

They become HTTP calls from your application. More verbose, and considerably
more testable: the logic leaves the database, where it was invisible to
debugging.

### Your Storage buckets

Cellar, S3-compatible. Your pre-signed URLs work with standard SDKs
(`getSignedUrl` in Node, `generate_presigned_url` in Python).

**What Cellar does not do**: per-row policies. Object access control moves up
into your application. And **one key grants access to every bucket** of the
add-on — to isolate them, create a second add-on and set a bucket policy.

**Never store on local disk**: instances are disposable, and it is wiped on
every redeployment.

### Your Edge Functions

Routes in your application, or a dedicated application. The Deno runtime is not
native; if your functions are TypeScript without Deno-specific dependencies,
they port to Node with few changes.

---

## 4. Three numbers to know before sizing

**`pool × instances ≤ the add-on's max connections`.** This is the first wall
you hit when autoscaling. A pool of 10 across 3 instances saturates a 25-
connection plan. That number is not published per plan: **ask support** before
setting `--max-instances`.

**Size for the peak, not the steady state.** Builds, restores, index rebuilds.
On the reference application, rebuilding a 20,000-entry vector index needs
65 MB of `maintenance_work_mem` — a small instance offering only 32 MB **cannot
rebuild its own index**.

Hence the dedicated build instance:

```bash
clever scale --alias my-app --min-instances 1 --max-instances 3 --build-flavor M
```

**Backups are daily, kept 7 days.** Frequency and retention are not
configurable. If your RPO is shorter, plan your own dumps.

---

## 5. What it costs

**You will not find prices in this document.** Rates change, and a figure
frozen into a guide goes stale without warning — which casts doubt on
everything else. The sources are authoritative:

- **Clever Cloud** — [clever.cloud/pricing](https://www.clever.cloud/pricing/),
  with an **estimator** that prices a full configuration, region by region.
- **Supabase** — [supabase.com/pricing](https://supabase.com/pricing).

### The two models do not compare plan to plan

This is the trap in every cost comparison between the two.

| | Supabase | Clever Cloud |
|---|---|---|
| Structure | monthly subscription per organisation, **plus** included quotas, **plus** overages | consumption, **billed by the second** |
| Compute | billed separately, per project | resource by resource, for time actually used |
| Ceiling control | quotas and overages | configurable **maximum spend limit** |

A quota-based subscription does not compare to metered consumption. **The only
honest comparison starts from your inventory** — section 2 of
[MIGRATING-FROM-SUPABASE.md](MIGRATING-FROM-SUPABASE.md) — and prices both
sides against *your* real usage.

### What to count, on both sides

Feed the estimator one line per item:

- **the application**: instance size × instance count × time;
- **the database**: the chosen plan — and a **dedicated** plan if you need
  encryption at rest;
- **object storage**: volume stored and egress traffic;
- **anything you add**: messaging, cache, identity.

And on the other side, what **disappears** from your Supabase bill: function
invocation quotas, bandwidth, storage, and per-project compute.

### Three levers specific to per-second billing

**The minimum instance size is the floor you pay around the clock.** In
vertical autoscaling, `--min-flavor` defines what runs continuously, not what
runs at peak. Setting it high out of caution costs you 24/7.

**The build instance is paid at build time.** `--build-flavor` lets you compile
on a large instance without carrying that size the rest of the time. This is
the lever that solves "my application cannot rebuild its own index" without
oversizing runtime.

**`--max-instances` caps the bill** as much as the load. The spending ceiling
is a setting, not something you endure.

One pleasant corollary: **a staging environment only costs while it runs.**
Shut down, it bills nothing.

### Saying it plainly

Migrating is not automatically cheaper. You take back in-house what used to be
managed — an application backend replaces PostgREST, GoTrue and Realtime, and
that backend has to be written and maintained.

The gain is elsewhere: control over the ceiling, billing by actual time, data
location, and getting out of a dependency on five components that exist nowhere
else.

**Price it before deciding, and re-date the pricing before presenting it.**

---

## 6. Deploying

```bash
clever deploy --alias my-app
```

Deployment happens by `git push` to the platform remote. There is **no manifest
file** in the style of `fly.toml`: configuration lives in `CC_*` environment
variables, your language's native files, and `clevercloud/`.

For a Docker application: `Dockerfile` at the root, `CMD` required, and the
listening port declared through `CC_DOCKER_EXPOSED_HTTP_PORT`. Docker Compose
is not supported — one application is one container.

```bash
clever logs --alias my-app
```

---

## 7. Proving the migration is faithful

Do not close a migration on "it seems to work".

Query your API under **each business identity**, against the source **before**
the switch, then against the target **after**. Compare the two matrices.
Identical means faithful; a cell that changes points straight at the problem.

The method and a generic harness are in
[MIGRATING-FROM-SUPABASE.md](MIGRATING-FROM-SUPABASE.md), section 6.

It is the one deliverable that turns "we think it works" into "we verified it".
In a regulated context, it is also a document worth keeping.

---

## What a product page will not tell you

- The **connection count per plan** is not published. Ask for it.
- **Encryption at rest** is neither on by default nor available everywhere.
- **`pg_cron` and `pg_net` go through a support ticket** — budget the delay.
- **Postgres Changes will not work** on a managed add-on. If you genuinely
  depend on it, the answer is Kubernetes.

Better to know now than halfway through a cutover.
