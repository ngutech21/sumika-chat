# skills.sh Search in Sumika

Status: 2026-08-21. This note examines the official skills.sh documentation,
the official `skills` CLI source, and primary Swift package sources. No product
code was changed.

## Summary

- Sumika can implement skill search with Foundation `URLSession` and `Codable`;
  no additional package is required.
- The documented skills.sh search API currently expects Vercel OIDC. Its
  documentation provides no general client credential flow for a distributed
  native macOS application.
- The official CLI instead calls the undocumented and anonymous
  `GET https://skills.sh/api/search` endpoint. This is usable for an experimental
  MVP but is not a stable documented contract.
- There is no official Swift client from skills.sh or Vercel. One small
  community SPM package exports a real skills.sh search provider, but it is an
  unreleased thin wrapper around that same legacy endpoint. `SwiftSkill` is a
  separate package for the Agent Skills file format, not a registry client.

## Official skills.sh API

The [official API reference](https://www.skills.sh/docs/api) documents JSON
endpoints under `https://skills.sh/api/v1/`:

- `GET /api/v1/skills/search?q=...&limit=...&owner=...` searches by name,
  source, or description. It uses fuzzy matching for a one-word query and
  semantic search for a multi-word query.
- `GET /api/v1/skills` returns `all-time`, `trending`, and `hot` leaderboard
  views.
- `GET /api/v1/skills/curated` returns first-party skills.
- `GET /api/v1/skills/{source}/{skill}` returns details, the file tree, and a
  content hash.
- `GET /api/v1/skills/audit/{source}/{skill}` returns available security audits.

The documented search response includes a stable `{source}/{slug}` ID plus
`name`, `source`, `installs`, `sourceType`, `installUrl`, and the skills.sh page
URL. It does not include the description text even though descriptions influence
search. The documentation recommends respecting `Cache-Control` and filtering
results marked with `isDuplicate`.

### Authentication is the main constraint

The documented API expects a short-lived Vercel OIDC token. The
[authentication section](https://www.skills.sh/docs/api#authentication) obtains
that token from a Vercel project at runtime or refreshes it in local development
through a project linked with the Vercel CLI. It does not document a general API
key or native client flow. A live request without a token returned `HTTP 401` for
v1 search on 2026-08-21.

## What the official CLI calls

The official TypeScript CLI does not use the documented v1 endpoint for
`skills find`. At the source revision for version 1.5.23, it defaults
`SEARCH_API_BASE` to `https://skills.sh`, sends an anonymous request to
`/api/search` with `q`, `limit`, and optional `owner`, and decodes only `id`,
`name`, `installs`, and `source`:
[find.ts lines 16-18 and 86-116](https://github.com/vercel-labs/skills/blob/435076e78988e1e6ec40d00b0b1d76bdbbc5419a/src/find.ts#L16-L116).

A live request to `https://skills.sh/api/search?q=swift&limit=10` returned
`HTTP 200` and ten results on 2026-08-21. The response identified itself with
the `x-search-version: legacy` header. Because `/api/search` is absent from the
v1 API reference and has no documented stability or rate-limit contract, Sumika
should access it only through a replaceable adapter with caching and graceful
offline or failure behavior.

Running `npx skills find` as a child process is a poor fit for Sumika. The search
itself is only the small HTTP request above, while a child process would require
Node and npm and would expose human-readable terminal output rather than a
stable Swift API. The official
[`find-skills` skill](https://github.com/vercel-labs/skills/blob/435076e78988e1e6ec40d00b0b1d76bdbbc5419a/skills/find-skills/SKILL.md)
documents `npx skills find` and `npx skills add` as CLI workflows, not a library
API.

## Swift libraries

### SwiftSkill: file format support, not search

A search of the
[canonical Swift Package Index package list](https://github.com/SwiftPackageIndex/PackageList/blob/main/packages.json)
for skill and Agent Skills packages found one directly relevant indexed package:
[`1amageek/swift-skills`](https://swiftpackageindex.com/1amageek/swift-skills).
Version 0.2.1 at revision `61c4bda16cb04d7e7fa54623c19297833c720bda`
provides parsing, writing, validation, local file discovery and CRUD, and provider
paths. This scope is visible in its
[README](https://github.com/1amageek/swift-skills/blob/61c4bda16cb04d7e7fa54623c19297833c720bda/README.md#overview)
and
[complete source directory](https://github.com/1amageek/swift-skills/tree/61c4bda16cb04d7e7fa54623c19297833c720bda/Sources/SwiftSkill).
The source contains no `skills.sh` integration, `URLSession`, remote registry
search, or HTTP client.

### skill-manager: a real but immature community client

Outside the Swift Package Index,
[`VolvoxLLC/skill-manager`](https://github.com/VolvoxLLC/skill-manager) is an SPM
package whose manifest exports `SkillDeckSources`
([Package.swift lines 11-27](https://github.com/VolvoxLLC/skill-manager/blob/ae2b9c4f82f4929a3cddc390dd0713c4eec008c5/Package.swift#L11-L27)).
Its
[`SkillsShSearchProvider`](https://github.com/VolvoxLLC/skill-manager/blob/ae2b9c4f82f4929a3cddc390dd0713c4eec008c5/Sources/SkillDeckSources/SkillsShSearchProvider.swift#L1-L57)
uses `URLSession` to call `GET /api/search?q=...&limit=...` and maps the four
legacy result fields into its own model.

This is a genuine community client, but it is not a strong Sumika dependency:

- It depends on the undocumented legacy endpoint.
- It supplies an empty description and marks every skills.sh result as
  `trusted: true`.
- The repository had no tags or
  [releases](https://github.com/VolvoxLLC/skill-manager/releases) at the inspected
  revision `ae2b9c4f82f4929a3cddc390dd0713c4eec008c5`, dated 2026-06-15.
- Its package declares Sentry and Amplitude dependencies even though the search
  target itself depends only on `SkillDeckCore`
  ([Package.swift lines 19-27](https://github.com/VolvoxLLC/skill-manager/blob/ae2b9c4f82f4929a3cddc390dd0713c4eec008c5/Package.swift#L19-L27)).

The precise answer is therefore: a small unofficial Swift/SPM wrapper exists,
but there is no official or versioned skills.sh client library. `SwiftSkill`
solves a different problem: the portable `SKILL.md` format.

Sumika does not need `SwiftSkill` for this search. It already owns YAML parsing,
validation, hashing, and activation in
[`SkillCatalog.swift`](../../Sources/SumikaCore/Features/Agent/Skills/SkillCatalog.swift),
which imports Foundation and uses the existing Yams dependency. Apple's
[`URLSession.data(for:delegate:)`](https://developer.apple.com/documentation/foundation/urlsession/data(for:delegate:))
is enough for the small JSON search client.

## Recommended Sumika design

The current `$` completion searches only installed project and personal skills.
This is visible in
[`ChatComposer.swift`](../../Sources/SumikaApp/Features/Composer/ChatComposer.swift#L339-L359),
while
[`SkillCatalog.swift`](../../Sources/SumikaCore/Features/Agent/Skills/SkillCatalog.swift#L13-L21)
scans the project and personal `.agents/skills` directories.

A clean extension would be:

1. Define a small vendor-neutral interface in `SumikaCore`, such as
   `SkillDiscoveryService.search(query:owner:limit:)`, plus a value-only
   `RemoteSkillDescriptor`. Keep the existing local `SkillCatalog` as the only
   owner of installed and activatable skills.
2. Implement `SkillsShSkillDiscoveryClient` as a concrete adapter outside the
   vendor-neutral Core policy. Use `URLSession`, `Codable`, URL query items, a
   bounded timeout, and strict validation of response IDs and URLs.
3. Separate local and remote semantics in the UI. An "Installed" result can
   activate `$skill` immediately. A "Discover" result opens preview and install
   actions. Never inject a remote result into the existing activation path as if
   it were a local `SkillDescriptor`.
4. Start remote search only after two characters. Debounce it, cancel obsolete
   tasks, and cache short-lived results. Local search must remain available when
   offline or rate limited.
5. Treat installation as a separate confirmed write operation. Show the source
   and content, expose audit status when available, validate every file and path,
   then write to the selected project or personal skill directory and refresh
   `SkillCatalog`. skills.sh itself warns in its
   [official security guidance](https://www.skills.sh/docs#how-are-you-securing-skills)
   that audits do not guarantee quality or safety and that users should review a
   skill before installing it.

## Deployment choices

### A. Pragmatic local MVP

Call `/api/search` through one `SkillsShSkillDiscoveryClient`. Mark it as
experimental online discovery and include:

- a short cache lifetime and explicit offline state,
- no hard dependency from local activation to remote search,
- contract tests against stored JSON fixtures,
- a kill switch and a replaceable endpoint.

This is the smallest native implementation, but it consciously depends on the
legacy contract used by the official CLI today.

### B. Documented contract through a proxy

A narrow Sumika backend on Vercel could call the documented
`/api/v1/skills/search` API with project OIDC and return Sumika's own versioned
search model. The application would no longer depend on legacy JSON, but this
introduces server availability, operations, and privacy tradeoffs that conflict
with Sumika's local-first goal.

## Recommendation

Do not add a Swift dependency. Start with option A as a replaceable experimental
discovery adapter and keep remote results distinct from installed skills. Before
calling the feature a durable supported integration, skills.sh should either
offer a documented credential-free search contract or Sumika should consciously
operate option B.
