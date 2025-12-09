
_Last updated: 2025-12-03_

## 1. Purpose

This FRD defines **WHAT** the hh_probe system must do.  
It does **not** prescribe implementation details (see SDD for that).

Every requirement:

- Is testable.
- Maps to Pester coverage.
- Must be reflected in the MCP Memory Graph as accepted state.
- Must not contradict the Vision or SDD.

---

## 2. Definitions

- **Pipeline** — the sequence orchestrated by `hh.ps1`.
- **Canonical Vacancy** — typed, normalized representation of a vacancy.
- **Projection Row** — flattened object for rendering/reporting.
- **EC (Editor's Choice)** — LLM-selected best match.
- **Lucky** — LLM-selected wildcard pick.
- **Worst** — LLM-selected bad fit. When flags are absent, system MUST select Worst deterministically as the lowest-score row; if external LLM is disabled/missing, the "why" field MUST remain empty.
- **MCP Memory Graph** — persistent architectural ledger.
- **LiteDB** — canonical cache backend.
- **BASE_SET** — top-ranked vacancies selected for full processing.
- **Compact CV Payload** — reusable, minimal CV representation for LLM operations.

---

## 3. Sections Overview

1. Vacancy discovery (HH API ingestion).
2. Caching.
3. Scoring.
4. Skills analytics.
5. LLM integration.
6. Pipeline processing.
7. Rendering / reports.
8. Notifications.
9. Resume management.
10. CLI / configuration.
11. MCP Memory Graph integration.
12. Code hygiene.
13. Wrapper pattern retirement & typed-only pipeline.
14. Safety & guardrails.

---

## 4. Vacancy Discovery

### FR-1.1 Hybrid Search Strategy (High)

**Requirement:**
The system MUST use a parallel hybrid vacancy discovery strategy:

1.  **Stream HH (Sequential Tiers):**
    - **Stage A (Web Recommendations):** Scrape "AI recommendations" from `hh.ru/search/vacancy?resume={id}` (requires cookie) – URLs only.
    - **Stage B (Similar):** Fetch vacancies similar to the user's resume (`/resumes/{id}/similar_vacancies`).
    - **Stage C (General):** Fetch vacancies via general search (`/vacancies`) using configured filters and query.
    - **Deduplication:** Within HH stream, deduplicate by numeric HH vacancy ID (parsed from URLs where needed); retain aggregated tier origins.

2.  **Stream Getmatch (Parallel):**
    - Fetch vacancies from Getmatch.ru with independent rate limiting.
    - No deduplication against HH at fetch level.

3.  **Orchestration:** Run HH and Getmatch streams in parallel, merge by appending Getmatch results to HH results.

**Acceptance criteria:**
- Pester tests confirm that "Web Recommendations" vacancies appear before "Similar" and "General" in HH stream.
- Deduplication ensures no vacancy appears twice within HH set.
- `meta.search_stage` is correctly populated ("web_recommendation", "similar", "general", "getmatch").
- `CanonicalVacancy.SearchTiers` aggregates all contributing HH tiers for deduped items.
- When Getmatch integration is enabled, canonical dataset includes vacancies with `Source = "getmatch"`.

### FR-1.1a Unified Resume Selection & Reuse (High)

**Requirement:**
When CLI `ResumeId` is not provided and `-WhatIfSearch` is not used, the system MUST auto-detect the active/published resume ID and reuse the SAME ID across:

- Stage A (Web Recommendations) — scrape `hh.ru/search/vacancy?resume={id}` (cookie required).
- Stage B (Similar) — `/resumes/{id}/similar_vacancies`.
- Resume views & invites fetching.
- CV bump gating/publish.
- CV key skills extraction for General search when `search.use_cv_keywords=true`.


The effective Resume ID MUST be a single source-of-truth for the run and be reflected in pipeline stats/logs.

**Acceptance criteria:**
- Tests assert `Get-HHWebRecommendations`, `Get-HHSimilarVacancies`, views/invites, and CV bump receive the same effective `ResumeId` when CLI parameter is absent.
- General search query includes key skills extracted from the same resume when `use_cv_keywords=true`.
- Pipeline logs show one resolved Resume ID and reuse across stages.

### FR-1.1b HH Vacancy Identity & Detail Contract (High)

**Requirement:**
For all HH vacancies, the system MUST treat the HH numeric vacancy ID as the single source of truth:

1. **Identity from Web Recommendations (scrape):**
   - Stage A (Web Recommendations) MUST return a list of vacancy URLs from `hh.ru/search/vacancy?resume={id}`.
   - Each URL MUST be normalized to a numeric vacancy ID by parsing the `/vacancy/{id}` path segment.
   - Scraped fields from the listing page (snippets, short descriptions, etc.) MUST NOT be used for canonical enrichment.

2. **Identity from API tiers:**
   - Stage B (Similar) and Stage C (General) receive vacancies from the official HH API search endpoints and MUST take the `id` and `url` fields as-is.
   - For HH-sourced vacancies, `CanonicalVacancy.Id` and `CanonicalVacancy.Url` MUST always correspond to this HH numeric ID and HH vacancy URL.

3. **Candidate Set Assembly (HH-only):**
   - The HH stream (Web Recs + Similar + General) MUST first assemble a **candidate set** of lightweight items:
     - `Source = "hh"`,
     - `Id` (numeric vacancy id),
     - `Url`,
     - `SearchStage` (`web_recommendation`, `similar`, `general`),
     - `SearchTiers[]` (aggregated tiers, deduped by ID).
   - Deduplication within HH MUST be done strictly by numeric vacancy ID.
   - After deduplication, each HH vacancy MUST have exactly one candidate record with aggregated `SearchTiers`.

4. **Detail Enrichment from Vacancy API:**
   - All HH canonical data (title, description, key skills, salary, area, employer) MUST be loaded from `GET /vacancies/{id}` on `api.hh.ru`.
   - `CanonicalVacancy` MUST NOT depend on fields scraped from search/listing pages.
   - Employer info used in CanonicalVacancy (name, area, employer id) MUST originate from the vacancy detail response, not from ad-hoc scraping.

5. **Employer Rating / Extra Fields:**
   - Employer rating and similar non-API fields MAY be obtained by scraping employer pages, but:
     - The employer id MUST come from `GET /vacancies/{id}`.
     - No additional calls to vacancy pages are allowed for canonical enrichment once `GET /vacancies/{id}` is available.

**Acceptance criteria:**
- For a sample run, all `CanonicalVacancy` objects with `Source = "hh"` have:
  - `Id` equal to the numeric ID in `https://hh.ru/vacancy/{id}`.
  - `Url` equal to the canonical vacancy URL.
  - `SearchTiers[]` aggregated only by numeric ID, no duplicates.
- Pester tests verify:
  - Web Recommendations scraping produces only URLs which are normalized to numeric IDs.
  - Deduplication uses numeric ID as the key and aggregates tiers correctly.
  - CanonicalVacancy title, description, key skills, salary, employer, and area match the fields from a recorded `GET /vacancies/{id}` response.
- No test or production code constructs CanonicalVacancy from scraped listing HTML; all HH canonical enrichment goes through `GET /vacancies/{id}` plus optional employer rating lookup.

---

### FR-1.2 Strict Active CV Policy (High)

**Requirement:**
The system MUST enforce two mutually exclusive search modes:

1.  **Strict Mode (Default):**
    - The Active HH CV (or `cv_hh.json`) is the **exclusive** source of search skills.
    - Manual `search.keyword_text` from config MUST be ignored.
    - If CV retrieval fails or is disabled, the search query falls back to a safety default but does NOT use manual keywords.
    - A warning MUST be logged if manual keywords were configured but ignored.

2.  **WhatIf Mode (`-WhatIfSearch`):**
    - Manual `search.keyword_text` (provided via CLI/TG bot interface) is used for search.
    - The Active HH CV is **not** used for search keyword generation.
    - CV may still be used for bump/views/invites if needed.

**Additional Requirement:**
When `search.use_cv_keywords=true` in Strict Mode, the General search (Tier C) MUST construct query text from `cv_skill_set` (Compact CV Payload) rather than config keywords.

**Acceptance criteria:**
- **Strict Mode:** Tests confirm `search.keyword_text` is ignored and only CV skills are used.
- **WhatIf Mode:** Tests confirm manual keywords are used exclusively.
- No mixing of CV skills and manual keywords in any mode.
- Logs show clear mode identification and warnings for ignored keywords.
- When `use_cv_keywords=true`, General search query contains skills from CV skill set.

### FR-1.3 Vacancy Details With Rate Limiting (High)

**Requirement:**  
For each vacancy, the system MUST call `GET /vacancies/{id}` via `hh.http` with:

- requests-per-minute throttling,
- max concurrent requests,
- micro-delay between detail fetches.

**Acceptance criteria:**
- Tests confirm timestamps obey RPM settings.
- No 429 errors appear in real-run logs under normal load.

### FR-1.4 Resume Views & Invites (Medium)

**Requirement:**  
Under digest/report modes, the system MUST fetch:

- `/resumes/mine`,
- invite / negotiation counters,
- resume viewers.

**Acceptance criteria:**
- Tests assert that these functions are called under digest/report modes.
- Digest output includes correct counts for views and invites.

### FR-1.5 GetMatch Integration (High)

**Requirement:**
1. System **MUST** support Getmatch.ru as a parallel vacancy source.
2. Getmatch fetch:
   - MAY use scraping / HTTP GET, not necessarily an official API.
   - MUST respect its own pacing / backoff configuration.
3. Getmatch vacancies are merged after internal HH dedup.
4. Getmatch vacancies are **not** deduplicated against HH at fetch level.
5. Each Getmatch vacancy MUST carry `Source = "getmatch"` in canonical schema.

**Acceptance criteria:**
- When Getmatch integration is enabled:
  - Canonical dataset includes vacancies with `Source = "getmatch"`.
  - HH and Getmatch entries may coexist for similar jobs, but are clearly tagged.
- When Getmatch is disabled:
  - No canonical rows have `Source = "getmatch"`.

### FR-1.6 Source-Aware Detail Fetch Policy (High)

**Requirement:**
Detail enrichment MUST be source-aware:

1. For vacancies where `Meta.Source = 'hh'`, the system MUST call `GET /vacancies/{id}` on api.hh.ru for detail enrichment.
2. For vacancies where `Meta.Source != 'hh'`, the system MUST NOT call HH vacancy detail endpoints.
3. Non-HH sources MUST either:
   - Skip detail enrichment entirely, OR
   - Use a source-specific enrichment function (e.g., Getmatch detail fetch) when implemented.

**Acceptance criteria:**
- No API calls to `api.hh.ru/vacancies/{id}` are made for Getmatch-origin rows.
- No 404s or retries caused by Getmatch IDs appearing in HH detail fetch logs.
- Pester tests confirm that only HH-source items trigger HH detail enrichment.
- BASE_SET processing time decreases for mixed-source datasets.

---

## 5. Caching (LiteDB-first)

### FR-2.1 LiteDB as Primary Cache (High)

**Requirement:**  
All cached objects MUST be retrieved/stored via `hh.cache` with LiteDB as primary backend.  
File caches may be used only where explicitly designed as fallback.

**Acceptance criteria:**
- No direct file-cache writes outside designated LLM text fallback paths.
- Cache TTL tests pass and demonstrate correct hit/miss behavior.

### FR-2.2 TTL Enforcement (Medium)

**Requirement:**  
Cached entries MUST expire according to TTL configuration.

**Acceptance criteria:**
- TTL=0 → immediate miss.
- TTL>0 → hit within TTL window.
- Expired entries are treated as misses in logic and can be purged.

### FR-2.3 Cache Pruning (Medium)

**Requirement:**  
System MUST support pruning of expired/old entries via `Remove-HHCacheOlderThanDays` or equivalent, with logging.

**Acceptance criteria:**
- Tests show removal of items beyond configured age.
- Manual/real runs show reduced DB/file size after prune.

---

## 6. Scoring (Heuristic Gating)

### FR-3.1 Heuristic Gating Strategy (High)

**Requirement:**
The system MUST implement a deterministic **Heuristic Gating** layer to filter vacancies before expensive LLM processing.

1. **Fast & Cheap:**
   - Scoring MUST rely solely on in-memory data that is already available in the pipeline (Vacancy, CV, Config, Exchange Rates).
   - Scoring MUST NOT trigger any new HTTP requests, file IO, or database queries.

2. **Gating Role:**
   - The heuristic score decides which vacancies enter the `BASE_SET`.
   - The heuristic score is used to pre-rank all ingested vacancies (HH + Getmatch) and to discard clearly low-fit items early.

3. **Final Ranking Separation:**
   - The remote LLM score (`ranking.remote`) is the primary sort key for the final report.
   - The heuristic score is used only for:
     - Pre-selection of `BASE_SET`, and
     - Tie-breaking within equal or near-equal LLM scores.

**Acceptance criteria:**
- Scoring a vacancy takes < 10ms in typical runs (measured in tests with synthetic data).
- `BASE_SET` is populated by the top N items sorted by heuristic score (after hard filters).
- Low-quality vacancies (mismatched stack, clearly low salary) are strictly excluded from `BASE_SET` even if they were ingested initially.

### FR-3.2 Scoring Components (High)

**Requirement:**
The heuristic score (0.0 to 1.0) MUST be a weighted sum of the following components:

1. **Skills Match:**
   - Measures overlap between normalized CV skills and vacancy requirements.
   - Skill tokens MUST be normalized (case-insensitive, punctuation-stripped, consistent mapping for aliases like `Node.js` → `nodejs`, `C#` → `csharp`).
   - Both CV coverage (`|I| / |CV|`) and vacancy coverage (`|I| / |Vacancy|`) MUST contribute to the component score.

2. **Salary Match (Currency-Aware):**
   - All amounts MUST be normalized to a `base_currency` (e.g., RUB) using cached exchange rates.
   - Exchange rates MUST be obtained once per run and reused via cache (see caching section); scoring MUST NOT fetch rates directly.
   - Missing salaries MUST be interpreted with **source-aware nuance**:
     - For `Source = "getmatch"` → treat as high-trust hidden salary (neutral-to-positive contribution).
     - For `Source = "hh"` AND senior roles (e.g., `experience.id = "moreThan6"`) → treat as common practice (neutral-to-positive).
     - For `Source = "hh"` AND non-senior roles with no salary → treat as mildly negative/uncertain.
   - Explicit lowball offers (normalized max below the user's minimum expectation) MUST receive a 0.0 salary component.

3. **Experience / Seniority Match:**
   - For HH vacancies, `experience.id` MUST be mapped to CV total experience and/or seniority bucket.
   - Exact bucket match MUST yield a high component score.
   - Adjacent bucket match MUST yield a partial component score.
   - Strong mismatch (e.g., CV seniority far above or below vacancy) MUST significantly reduce the component score.
   - For `Source = "getmatch"`, experience/seniority MAY default to a neutral/high value if upstream filters already enforce seniority.

4. **Recency:**
   - Recency MUST be modeled as an exponential decay based on publication date.
   - A standard form such as `exp(-DaysSincePublish / tau)` (where `tau` is configured in `scoring.recency`) MUST be used.
   - If publication date is missing (e.g., evergreen Getmatch postings), a neutral recency score MUST be applied (e.g., 0.5).

**Acceptance criteria:**
- A salary of `3000 USD` and its RUB-equivalent vacancy are scored identically in tests (within a small numeric tolerance).
- A senior HH vacancy with no salary scores higher (salary component) than a junior HH vacancy with no salary, all else equal.
- Skills matching is robust to case and punctuation, and treats `React.js` and `REACT` as a match in tests.
- Experience component tests demonstrate clear differences between exact match, adjacent bucket, and strong mismatch cases.

### FR-3.3 Hard Filtering (High)

**Requirement:**
The system MUST support "Hard Filters" that discard vacancies *before* heuristic scoring is applied.

Hard filters MUST include at least:

1. **Employer Blacklist:**
   - Vacancies from employers specified in a blacklist configuration MUST be dropped entirely.
   - Blacklisted employers MUST NOT appear in the final report, even if LLM scores would otherwise consider them a good match.

2. **Location / Remote Preference:**
   - When the user/config indicates a strict remote-only preference, office-only roles MUST be discarded.
   - Hybrid roles MAY be kept or dropped based on a clearly documented rule in the SDD, but the rule MUST be deterministic.

3. **Other Deal-Breakers (configurable):**
   - The system MUST allow additional hard filters to be configured (e.g., excluded industries, minimum salary floors) without requiring architectural changes.

**Acceptance criteria:**
- Pester tests confirm that:
  - Blacklisted employers never appear in `hh_canonical.json`, `hh_report.json`, `hh.csv`, or the HTML report.
  - Remote-only preference drops office-only vacancies before they reach `BASE_SET`.
  - Adding a new hard filter in config changes the candidate set without code changes (within the supported filter types).

---

## 7. Skills Analytics

### FR-4.1 Skills Extraction (High)

**Requirement:**  
System MUST extract skills from:

- HH `key_skills`,
- vacancy description,
- CV / configured skills corpus.

**Acceptance criteria:**
- Skills scoring reflects matched skills.
- Tests confirm extraction from representative text samples.

### FR-4.2 SkillsInfo Completeness (High)

**Requirement:**  
`CanonicalVacancy.SkillsInfo` MUST include:

- `Score`,
- `MatchedVacancy[]`,
- `Present[]`,
- `Recommended[]`.

**Acceptance criteria:**
- Arrays are **never null** (may be empty).
- HTML skills UI uses ✔ for Present and ↗ for Recommended as designed.

---

## 8. LLM Integration

### FR-5.1 Three-Tier LLM Strategy (High)

**Requirement:**  
The system MUST implement a three-tier LLM processing strategy when `-LLM` is active:

1.  **Tier 1 (Local Summary):** Runs for **all items in BASE_SET** using local LLM (e.g., Ollama).
    - Logical operation: `summary.local`
    - Provides fast summaries and relevance scoring.

2.  **Tier 2 (Remote Rescoring):** Runs for **all items in BASE_SET** using remote LLM.
    - Logical operation: `ranking.remote`
    - Uses CanonicalVacancy subset + **Compact CV Payload** (see FR-9.2) for refined scoring.

3.  **Tier 3 (Remote Summary):** Runs for **final top N** (configured via `llm.tiered.top_n_remote`, default 10) using remote LLM.
    - Logical operation: `summary.remote`
    - Generates narrative summaries using CV context.

**Acceptance criteria:**
- Logs show that:
  - Local LLM operations count ≈ BASE_SET size.
  - Remote rescoring operations count ≈ BASE_SET size.
  - Remote summary operations count ≈ final top N.
- No LLM calls are made for vacancies outside BASE_SET.
- ALL vacancies within report limit have `summary_source: "local"` initially.
- Top N vacancies get `summary_source: "remote"` and `summary_model` from config.
- CSV export shows correct source/model for each vacancy.

### FR-5.2 Pick "Why" Texts — No Fallback (High)

**Requirement:**
- EC/Lucky/Worst "why" texts MUST be produced only by external LLM calls.
- When LLM is disabled or the response lacks a "why", the "why" field MUST remain empty.
- No pipeline/util rendering fallback strings may be injected for pick "why".

**Acceptance criteria:**
- HTML/JSON reports show empty "why" when LLM is off or returns no text.
- Pester tests confirm no synthetic "why" strings are added when flags are set.

### FR-5.3 Configurable Prompts for Pick "Why" (High)

**Requirement:**
- System prompts for EC/Lucky/Worst "why" MUST be configurable via `config/hh.config.jsonc` under `llm.prompts`:
  - `llm.prompts.ec_why.system_en|system_ru`
  - `llm.prompts.lucky_why.system_en|system_ru`
  - `llm.prompts.worst_why.system_en|system_ru`
- Implementation MUST prefer `system_en` when present, else `system_ru`, else use minimal hardcoded prompt.

**Acceptance criteria:**
- Changing config prompt values alters generated "why" texts without code changes.
- Tests and logs show prompt selection path (en→ru→fallback).

### FR-5.4 Lucky Pick Semantics (High)

**Requirement:**
- "I feel lucky" pick exists only when a random.org selection occurred in the run.
- If no random.org selection occurred, there MUST be no Lucky pick and no "why".

**Acceptance criteria:**
- Reports omit the Lucky card/pill when no selection happened.
- Pester tests confirm absence of Lucky elements when the flag is not set.

### FR-5.5 Culture Risk Prompt Configuration (Medium)

**Requirement:**
Culture risk prompts MUST be configurable via `config/hh.config.jsonc` under `llm.prompts.culture_risk`:

- Keys: `system_en`, `system_ru`, and `system` (fallback).
- Output format: JSON with `{"risk":0..1}`.
- Consumed by `LLM-MeasureCultureRisk` and used by `Get-CulturePenaltyLLM` when LLM is enabled.

**Acceptance criteria:**
- Tests confirm prompt selection path (en→ru→fallback) and presence of keys in config.
- Scoring integrates LLM culture risk when enabled; otherwise defaults to heuristic-only.

### FR-5.6 Logical Operations → Model Mapping (Medium)

**Requirement:**
- All LLM calls MUST reference logical operations (e.g., `summary.local`, `ranking.remote`, `summary.remote`, `picks.why.ec`), not raw model IDs.
- A single mapping from logical operation → provider/model MUST live in `config/hh.config.jsonc` under `llm.operations`.
- No concrete model IDs (e.g., `gpt-5.1`, `qwen3-235b`) are allowed in code.

**Acceptance criteria:**
- Changing model for `ranking.remote` in config changes behavior without code changes.
- Grep shows no hard-coded Hydra/OpenAI/Qwen model IDs in `.psm1` modules.

### FR-5.7 LLM Usage Metrics (Low/Medium)

**Requirement:**
For each logical LLM operation, the system SHOULD track:
- Number of calls,
- Estimated tokens in/out (when available),
- Estimated cost in base currency.
- Metrics SHOULD be logged per run and attached to MCP memory for post-hoc analysis.

**Acceptance criteria:**
- Pipeline logs include LLM call counts per operation.
- When available, token/cost estimates appear in run summary.
- MCP memory contains LLM usage observations.

### FR-5.8 Summary Prompt Configuration (High)

**Requirement:**
Prompts for summary generation MUST be configurable via `config/hh.config.jsonc` under `llm.prompts.summary.*` for:
- `summary.local`
- `summary.remote`

The following keys MUST be supported:
- `llm.prompts.summary.local.system_en`
- `llm.prompts.summary.local.system_ru`
- `llm.prompts.summary.remote.system_en`
- `llm.prompts.summary.remote.system_ru`

**Language Selection Rule:**
The system MUST select prompt language based on character distribution:
1. If the target vacancy text (title + description) is predominantly Cyrillic (>60%), use Russian prompt.
2. If predominantly Latin (>60%), use English prompt.
3. If mixed (40–60% each), default to English.
4. If selected language prompt is missing, fall back to the other language.
5. If both missing, use minimal hardcoded fallback.

**Acceptance criteria:**
- Changing prompts in config changes summary style without code changes.
- Language selection follows deterministic logic:
  - Calculate Cyrillic vs Latin character ratio across vacancy title and description.
  - Pick prompt language accordingly (EN/RU).
- Tests confirm:
  - Cyrillic-heavy postings (>60%) → Russian prompt used.
  - Latin-heavy postings (>60%) → English prompt used.
  - Mixed postings (40–60%) → defaults to English.
- Logs record detected language, character ratios, and chosen prompt key.
- No model-specific text or hard-coded prompts appear in `.psm1` modules.

---

## 9. Pipeline Processing

### FR-6.1 Canonical Vacancy Construction (High)

**Requirement:**  
Every vacancy MUST be converted into a typed CanonicalVacancy with:

- employer info,
- salary info,
- skills info,
- meta scores,
- meta summary,
- badges and flags.

**Acceptance criteria:**
- No raw HH structures leak beyond this layer.
- Tests confirm all mandatory fields are populated (no unexpected nulls).

### FR-6.2 Picks Selection (High)

**Requirement:**  
The system MUST select:

- 1 Editor's Choice (requires successful external LLM selection),
- 1 Lucky (requires successful random.org selection),
- 1 Worst (determined by LLM OR fallback to lowest score; "why" only from LLM)

(if enough vacancies qualify).

**Acceptance criteria:**
- JSON root objects contain `picks.ec`, `picks.lucky`, `picks.worst` (when available).
- HTML presents badges for these picks.
- EC only appears when external LLM successfully selects it.
- Lucky only appears when random.org selection occurred.
- Worst appears with lowest score when LLM unavailable; "why" empty without LLM.

### FR-6.3 Score-First Optimization (High)

**Requirement:**
1. System MUST apply baseline heuristic scoring to **all ingested vacancies** (HH + Getmatch).
2. System MUST compute `BASE_SIZE` as:
   - `BASE_SIZE = report.max_display_rows × ranking.candidate_multiplier`
   - Values come from `config/hh.config.jsonc`.
3. System MUST select top `BASE_SIZE` as `BASE_SET`.
4. Only `BASE_SET` proceeds to:
   - Full canonical construction,
   - Three-tier LLM processing,
   - Picks selection.

**Acceptance criteria:**
- LLM calls are bounded by `BASE_SET` count, not total ingested vacancies.
- Performance/logs show significantly fewer LLM calls vs "process everything".
- Final report still respects `report.max_display_rows` while picks can originate from BASE_SET.

### FR-6.4 Remote LLM Rescoring With CV Context (High)

**Requirement:**
1. For each vacancy in BASE_SET, the system MUST send to remote LLM:
   - A CanonicalVacancy subset (ID, title, employer, location, salary, skills, summary, scores).
   - A **Compact CV Payload** (see FR-9.2).
2. Remote LLM rescoring operation is identified logically as `ranking.remote`.
3. `summary_source` and `summary_model` MUST be included in CanonicalVacancy.Meta.

**Acceptance criteria:**
- Input JSON to remote LLM contains exactly:
  - CanonicalVacancy subset,
  - Compact CV payload as specified in FR-9.2,
  - Context metadata.
- No personal data (contact info, photos) in prompts.
- No raw HH resume dump is sent in prompts.
- Remote LLM only runs on BASE_SET when `-LLM` is active and remote LLM is available.
- Summary and score origins are recorded in metadata.
- Logs/diagnostics show that rescoring decisions consider both vacancy and CV context.

### FR-6.5 Summary Language Autodetection (Medium)

**Requirement:**
The system MUST implement a shared utility function for language autodetection that:
- Counts Cyrillic vs Latin characters in text.
- Applies threshold: >60% Cyrillic → Russian, >60% Latin → English.
- Defaults to English for mixed text (40–60% each).
- This detection applies to:
  - Tier 1 local summaries,
  - Tier 3 remote summaries,
  - Future cover letter / CV tuning modules.

**Acceptance criteria:**
- Detection logic implemented in a single shared utility function (`Detect-Language`).
- Tests verify correct classification for synthetic cases:
  - Pure Cyrillic text → Russian.
  - Pure Latin text → English.
  - Mixed text → English (default).
- Logs include selected language + ratio values.
- Prompts chosen must match FR-5.8 language selection rules.

---

## 10. Rendering & Reports

### FR-7.1 Projection Alignment (High)

**Requirement:**  
`hh.report` MUST map CanonicalVacancy → ProjectionRow correctly, preserving:

- scores,
- skills arrays,
- summary,
- badges,
- picks.

**Acceptance criteria:**
- Projection tests verify that each field originates from canonical structures.
- No projection field is silently dropped or renamed without tests.

### FR-7.2 HTML Report (High)

**Requirement:**  
System MUST render a valid HTML report via Handlebars.Net using the canonical template.

**Acceptance criteria:**
- HTML smoke test confirms report structure (cards, headers, drill-down).
- Opening the report in a browser shows expected sections and data.
- Mobile layout (<700px) shows horizontally scrollable cards.
- Table displays inline salary, consolidated company info, and single skills accordion.

### FR-7.3 JSON Report (Medium)

**Requirement:**  
System MUST emit a JSON report matching projection schema (not legacy).

**Acceptance criteria:**
- JSON validates against current projection schema.
- Tests verify key fields and sample values.

### FR-7.4 CSV Search Tier Origins (Medium)

**Requirement:**
CSV export MUST include a `search_tiers` column representing tier origins:

- Values are comma-separated from aggregated tiers.
- Fallback to `search_stage` when no list is available.
- No extra formatting beyond plain labels.

**Acceptance criteria:**
- Pester tests confirm presence of `search_tiers` column.
- Values match expected tiers for synthetic deduped cases.
- Single-tier rows fall back to the primary `search_stage`.
- Aggregation includes recommendation tier (tier3) when triggered.

### FR-7.5 Canonical CSV Artifact (High)

**Requirement:**  
Pipeline MUST emit a single canonical CSV artifact named `hh.csv`, produced from typed `CanonicalVacancy` rows via `hh.report` projections.

**Acceptance criteria:**
- Only `hh.csv` is written to `data/outputs/` (no competing `hh_report.csv`).
- Column order matches historical `hh.csv` plus documented extensions (`search_tiers`, summary metadata, picks flags).
- Tests assert `hh.csv` schema, ensure the file is derived from typed data, and fail if legacy PSCustomObject wrappers reappear.

---

## 11. Notifications

### FR-8.1 Telegram Digest (Medium)

**Requirement:**  
With `-Digest`, system MUST produce a Telegram message including:

- views/invites summary,
- skill-summary (skills>0),
- EC/Lucky/Worst indicators,
- top vacancies with brief information.

**Acceptance criteria:**
- Dry-run tests assert correct message assembly.
- Real runs send messages when configured.

---

## 12. Resume Management

### FR-9.1 CV Bump Logic (Medium)

**Requirement:**  
System MUST support automated resume bump (publish) with controls:

- weekdays only,
- at most once every 4 hours.

**Acceptance criteria:**
- `Should-BumpCV` unit tests verify gating logic.
- Real runs show `publish` calls only when allowed.

### FR-9.2 Compact CV Payload (High)

**Requirement:**
The system MUST be able to construct a reusable, compact CV payload object from the active HH resume snapshot, to be used across:
- Remote LLM rescoring (`ranking.remote`),
- Remote summaries (`summary.remote`),
- Future cover letter / CV tuning workflows.

The compact CV payload MUST include at minimum:
- `cv_title`: resume headline / desired role.
- `cv_skill_set`: normalized skills array.
- `cv_total_experience_months` or years.
- `cv_primary_roles`: primary professional roles IDs/names.
- `cv_recent_experience`: a compact list for the last N positions (employer, position, industry, summary).
- `cv_certifications_core`: shortlist of core certifications.

The compact CV payload MUST **exclude**:
- Contact info (phone, email, Telegram),
- Full work history older than the configured recent window,
- Full free-text CV description,
- Personal data (photo, birth date, etc.),
- Long certificates dump.

**Acceptance criteria:**
- The payload is constructed once per run and reused across all LLM operations.
- No personal/contact data appears in any LLM prompt.
- Changing `cv_recent_experience` window in config alters payload size.
- Tests verify payload structure matches specification.

---

## 13. CLI / Configuration

### FR-10.1 Single Entry Point (High)

**Requirement:**  
There MUST be exactly one entry point: `hh.ps1` (or alias `hhr.ps1`), and all flows go through it.

**Acceptance criteria:**
- No other runner scripts are introduced.
- Tests import and use `hh.ps1` where integration is needed.

### FR-10.2 Single Config Source (High)

**Requirement:**  
The only config file is `config/hh.config.jsonc`; environment variables override secrets only.

**Acceptance criteria:**
- Config tests confirm precedence rules.
- No other config loaders present in code.

### FR-10.3 No New Config Formats (High)

**Requirement:**  
System MUST NOT introduce any new config formats or files.

**Acceptance criteria:**
- Repo stays with a single config JSONC file and docs.

---

## 14. MCP Memory Graph Integration

### FR-11.1 Change Logging (High)

**Requirement:**  
Every non-trivial change MUST append a short observation into the MCP Memory Graph under a relevant entity.

**Acceptance criteria:**
- For each change/PR, there is a corresponding observation with date + summary + reference to FRD item(s).

### FR-11.2 Phase Markers (High)

**Requirement:**  
Each development phase MUST be tracked with:

- `status=pending`,
- followed by `status=accepted` or `status=failed`.

**Acceptance criteria:**
- Migration/phase entity shows full lifecycle of each phase.

---

## 15. Code Hygiene

### FR-12.1 Legacy Code Relocation (Medium)

**Requirement:**  
Unused/legacy modules/scripts/templates MUST be moved to `.tmp/<mirrored-path>/`, not deleted.

**Acceptance criteria:**
- `.tmp/` directory mirrors structure of moved elements.
- No broken references in code or tests.

---

## 16. Wrapper Pattern Retirement & Typed-Only Pipeline

### FR-16.1 Typed-Only Pipeline Architecture (High)

**Requirement:**
The system MUST use typed `CanonicalVacancy` objects directly throughout the pipeline without PSCustomObject wrapper layers.

**Acceptance criteria:**
- `Build-CanonicalRows` returns typed `CanonicalVacancy` objects directly
- Renderers (`Render-CSVReport`, `Render-HtmlReport`) consume typed objects directly
- JSON serialization uses Newtonsoft.Json for typed object serialization
- No dual-layer data synchronization issues between wrapper and inner objects

### FR-16.2 Newtonsoft.Json Serialization (High)

**Requirement:**
Canonical JSON output MUST use Newtonsoft.Json.dll for proper typed object serialization with fallback to PowerShell's `ConvertTo-Json`.

**Acceptance criteria:**
- `hh_canonical.json` uses Newtonsoft.Json serialization when DLL available
- Proper handling of null values, reference loops, and formatting
- Fallback to `ConvertTo-Json` maintains compatibility if Newtonsoft.Json unavailable

### FR-16.3 Direct Property Access (Medium)

**Requirement:**
All renderers and consumers MUST access typed `CanonicalVacancy` properties directly without wrapper property chains.

**Acceptance criteria:**
- Renderers use `$r.Meta.Summary.text` instead of complex wrapper fallback chains
- CSV export uses `$r.SearchTiers` directly for search tier aggregation
- No wrapper unwrapping logic in renderers or projection layers

### FR-16.4 Obsolete Code Retirement (Medium)

**Requirement:**
Legacy wrapper conversion code MUST be moved to `.tmp/` directory with proper documentation.

**Acceptance criteria:**
- `Convert-CanonicalVacancyToPSObject` (588 lines) archived to `.tmp/modules/hh.util.psm1.wrapper-pattern/`
- Obsolete summary helpers retired to `.tmp/`
- No references to retired wrapper functions in active code

---

## 17. Safety & Guardrails

### FR-13.1 No Architecture Drift (High)

**Requirement:**  
Agents MUST NOT create new:

- entrypoints,
- config formats,
- architectural layers,
- backends.

**Acceptance criteria:**
- Code history shows modifications only within established modules and layers.

### FR-13.2 Test Coverage Before Acceptance (High)

**Requirement:**  
Every FRD item must be backed by:

- Pester tests, or
- Explicit manual acceptance log in MCP memory (for external integrations) before being marked accepted.

**Acceptance criteria:**
- For each FR entry, there exists a test or an MCP log explaining why it's accepted.

### FR-13.3 Live Integration Smoke Tests (Medium)

**Requirement:**  
The system MUST support optional “live” integration tests against real external services (HH.ru, LLM providers, Telegram, Getmatch, random.org) using real user credentials.

**Purpose:**  
To detect API contract drift, authentication errors, and rate-limit issues before production runs.

**Constraints:**
- Live tests MUST be disabled by default.
- Live tests MUST require explicit opt-in via:
  - `Invoke-Pester -Tag Live` **and/or**
  - Environment variable `HH_LIVE_TESTS=1`.
- All credentials MUST come **only** from environment variables:
  - `HH_API_TOKEN`
  - `HH_COOKIE`
  - `HYDRA_API_KEY`
  - `TELEGRAM_BOT_TOKEN`
  - `RANDOM_ORG_KEY`
  - etc.
- Live tests MUST:
  - Perform a *minimal* number of requests (smoke tests only).
  - Respect HH and Getmatch rate limits.
  - Use **read-only** API calls where possible.
  - Use the real `hh.http` rate-limited transport.
- Live tests MUST NOT run in default CI.

**Acceptance criteria:**
- At least one Pester suite marked with `Tag Live` for:
  - HH vacancy/resume API connectivity,
  - Remote LLM provider availability,
  - Telegram (optional),
  - Getmatch (optional),
  - Random.org API checks.
- CI executes only mocked tests unless explicitly enabled.
- Logs MUST NOT reveal cookies, tokens, or personal data.
