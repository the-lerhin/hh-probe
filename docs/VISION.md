# Vision Document — hh_probe (v1.0)
_Last updated: 2025-11-18_

## 1. Product Vision

**hh_probe** is an autonomous, privacy-respecting personal job-search intelligence system.

Its purpose is to continuously:

- Discover suitable vacancies.
- Evaluate and prioritize them.
- Present actionable insight.
- Later: apply automatically with tailored AI-powered cover letters.

The system behaves like a **personal analyst + research assistant**, not a mass-apply spam bot.

It makes decisions based on:

- Data pulled from the HH.ru API.
- Cached domain intelligence (LiteDB).
- LLM-generated summaries and scoring.
- Accumulated skill trends.
- Employer metadata.
- Personal preferences and CV.

The system is built for **long-term, unattended operation** and **high transparency**.

---

## 2. Motivation

Job boards produce:

- Massive numbers of irrelevant matches.
- Repetitive manual filtering.
- Scattered employer signals (views, invites).
- Inconsistent descriptions.
- High cognitive load.

Users waste time scanning and evaluating rather than making decisions.

**hh_probe** aims to invert that model:

- Automate search.
- Automate scoring.
- Automate summarization.
- Automate context extraction.
- Eventually automate application.

The user’s role becomes **decision-maker**, not data processor.

---

## 3. Core Philosophy

### 3.1 Deterministic Pipeline, AI-Enriched

AI is used only for:

- Relevance scoring.
- Summarization.
- Risk flags / picks (Editor’s Choice, Lucky, Worst).
- Explanatory “why” text.
- Optional cover letter generation (future).

Everything else is deterministic, testable, and cached.

### 3.2 Zero Drift

- All code follows a described pipeline.
- Agents may extend or modify **only inside** the existing architecture.
- No new entrypoints, configs, services, formats, or frameworks unless explicitly authorized.

### 3.3 Predictable Output

Every run produces three core artifacts:

- `hh_canonical.json` → typed, normalized model.
- `hh_report.json` → projection (view model).
- `hh.html` → human-readable report.

This deterministic structure enables CI stability, diff-based tracking, and agent correctness.

### 3.4 Local First

The pipeline must run identically:

- Locally.
- On a personal server.
- In terminal.
- Under scheduled tasks.

No GUI, browser, or external orchestration required.

---

## 4. Long-Term Product Goals

### 4.1 Autonomous Job Research

The system becomes a 24/7 research agent:

- Runs on schedule.
- Discovers new roles.
- Logs changes.
- Examines employer behavior.
- Builds a long-range skills map.
- Tracks trends in job requirements.

### 4.2 Human-Readable Reports

Every run yields:

- KPI summary (views, invites, picks).
- Vacancy table.
- Structured drill-downs.
- Employer metadata.
- Updated cumulative skill corpus.

The system is **information-dense**, not cluttered.

### 4.3 Fully Automated Application Cycle (Future Phase)

- Choose top N positions meeting strict thresholds.
- Generate quality cover letters.
- Apply via the HH API.
- Log outcomes and replies.

### 4.4 Multi-Source Expansion (Future Phases)

- LinkedIn job search.
- Employer contact enrichment.
- Cross-platform skills analytics.
- Proactive targeting of similar employers.

---

## 5. Key System Properties

### 5.1 Reliability

Every subsystem must have Pester coverage:

- Fetching.
- Scoring.
- Caching.
- LLM pipeline.
- Rendering.
- Drill-down logic.
- Pipeline orchestration.

### 5.2 Modularity

The system’s PowerShell modules are stable, documented, and isolated:

- `hh.core`
- `hh.fetch`
- `hh.http`
- `hh.llm`
- `hh.scoring`
- `hh.skills`
- `hh.pipeline`
- `hh.render`
- `hh.notify`
- `hh.cache`
- Others as needed.

Agents modify modules, not the overall structure.

### 5.3 Cache Stability

LiteDB is authoritative.

- File cache exists only where explicitly intended.
- All caching must:
  - Be TTL-controlled.
  - Survive restarts.
  - Prevent re-computation.
  - Support bulk pruning.

### 5.4 Predictable Side Effects

Only:

- Reading HH API.
- Writing report files.
- Updating LiteDB.
- Updating the MCP Memory Graph.

Nothing else touches the system.

### 5.5 MCP Memory Graph as Architectural Ledger

The MCP Memory Graph stores:

- Decisions.
- Changes.
- Lessons.
- Dependencies.
- Test coverage.
- Design invariants.
- Phase completion markers.

It is **not** part of the repo, not a config, not code — it is the shared brain.

Agents always update memory with:

- `status=pending` → `status=accepted` / `status=failed`.

---

## 6. Target User

- Single, highly-technical user.
- Wants persistent, automated research.
- Wants stable architecture.
- Wants AI assistance with guarantees against uncontrolled drift.
- Wants structured artifacts and predictable behavior.
- Prefers autonomy and clarity over bloat.

---

## 7. Constraints

- Must run on **PowerShell 7.5.4**.
- Must remain a **single-entry-point** CLI script (`hh.ps1` / `hhr.ps1`).
- Must **not** introduce:
  - New configs.
  - New file formats.
  - New entrypoints.
  - New tech stacks/frameworks.
- Must use:
  - LiteDB for cache.
  - HH API.
  - LLM models configurable via environment.
  - Handlebars templates for HTML.

---

## 8. Non-Goals

- Building a GUI, Electron, or web app UI.
- Multi-user SaaS.
- Generic job spam tool.
- Heavy frontend SPA logic.
- Replacing PowerShell as runtime.

---

## 9. Summary Statement

> **hh_probe is a stable, deterministic job-research pipeline enriched with AI, producing structured human-readable reports and progressively automating the job search lifecycle — while strictly preserving architecture, config, entrypoints, and design invariants.**