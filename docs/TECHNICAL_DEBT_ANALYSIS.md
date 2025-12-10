# Technical Debt Analysis & Strategic Roadmap
_Date: 2025-05-20_
_Version: 1.0_

## Executive Summary

This document analyzes the current state of the `hh_probe` repository, focusing on technical debt that hinders stability and future feature development (specifically batch LLM processing and parallel fetch).

The analysis is guided by the user's key priorities:
1.  **Stability First:** Eliminate silent failures that hide bugs.
2.  **Modularization:** Break down the monolithic `hh.pipeline.psm1` to enable safe growth.
3.  **Intentional Modernization:** Openness to new tools (dependencies) if planned and beneficial, avoiding "drift."

## 1. Critical Technical Debt (High Impact / High Priority)

### 1.1 Silent Failure Suppression
**Issue:** The codebase contains ~50 generic `try { ... } catch {}` blocks, particularly in `hh.pipeline.psm1` and `hh.fetch.psm1`, which suppress all exceptions without logging.
**Impact:**
*   **Hidden Bugs:** Logic errors (e.g., null reference exceptions) fail silently, leading to corrupted data or partial runs that look successful.
*   **Debugging Nightmare:** When a feature fails, there is no trace in the logs.
**Solution:**
*   Adopt a "Fail Fast" or "Log & Continue" strategy.
*   Replace empty catches with `Write-Log -Level Warning "Operation X failed: $_"` at minimum.
*   Let critical errors bubble up to the main orchestrator.
**Cost:** Medium (Audit ~80 blocks).
**Benefit:** High (Immediate visibility into system health).

### 1.2 `hh.pipeline.psm1` Monolith
**Issue:** `hh.pipeline.psm1` (~800 lines) violates the Single Responsibility Principle. It handles:
*   Orchestration (Fetch -> Score -> LLM -> Render).
*   Business Logic (Picks selection, Enrichment, Scoring integration).
*   Data Transformation (Canonical object building).
**Impact:**
*   **Fragility:** Changes to one logic flow (e.g., Picks) risk breaking others (e.g., Rendering).
*   **Testing Difficulty:** Integration tests are complex because the pipeline does "everything."
*   **Concurrency Blocker:** Difficult to parallelize fetch or LLM calls when state is tightly coupled in one script scope.
**Solution:** Refactor into focused modules:
*   `hh.pipeline.orchestrator.psm1` (The coordinator).
*   `hh.pipeline.enrichment.psm1` (Detail fetching & canonical building).
*   `hh.pipeline.picks.psm1` (EC/Lucky/Worst logic).
**Cost:** High (Major refactoring).
**Benefit:** High (Enables safe addition of Batch LLM & Parallel Fetch).

### 1.3 `hh.fetch.psm1` Complexity
**Issue:** `hh.fetch.psm1` mixes low-level HTTP logic, HTML scraping (Getmatch), and API orchestration.
**Impact:** Hard to maintain Getmatch scraping without risking HH API logic stability.
**Solution:** Split source-specific logic:
*   `hh.fetch.hh.psm1` (Official API).
*   `hh.fetch.getmatch.psm1` (Scraping logic).
*   `hh.fetch.common.psm1` (Shared types).
**Cost:** Medium.
**Benefit:** Medium (Isolates fragile scraping code).

## 2. Repository Hygiene (Medium Impact)

### 2.1 Binary Dependencies in Git
**Issue:** `bin/*.dll` (Newtonsoft.Json, LiteDB, Handlebars) are checked into source control.
**Impact:**
*   **Bloat:** Git repo size increases with updates.
*   **Security:** Harder to track/update vulnerable versions.
*   **Drift:** No clear record of *where* these DLLs came from or their exact versions.
**Solution:** Introduce a `bootstrap.ps1` script (or `tools/setup.ps1`) that downloads specific versions from NuGet/Maven Central to `bin/` on first run (if missing).
**Cost:** Low.
**Benefit:** Medium (Cleanliness, reproducability).

### 2.2 Test Coverage Gaps
**Issue:** Tests are heavily mocked integration tests. While good, they rely on the implementation details of the monolith.
**Impact:** Refactoring the pipeline will break many tests, requiring significant rewrite of the test suite.
**Solution:** Write *pure unit tests* for the new smaller modules (e.g., `hh.pipeline.picks`) *before* or *during* extraction.
**Cost:** Medium.
**Benefit:** High (Confidence during refactoring).

## 3. Cost-Benefit Analysis Matrix

| Item | Effort (Cost) | Value (Benefit) | Priority | Recommendation |
| :--- | :--- | :--- | :--- | :--- |
| **Fix Silent Catches** | Medium | **Very High** | **1** | **Immediate Action.** Prerequisite for any other work. |
| **Split Pipeline Monolith** | High | **Very High** | **2** | **Core Strategic Goal.** Essential for future features. |
| **Dependency Bootstrap** | Low | Medium | **3** | **Quick Win.** Implement alongside Phase 1 or 2. |
| **Split Fetch Module** | Medium | Medium | **4** | Defer until Pipeline refactor is stable. |
| **Getmatch Hardening** | Medium | Low | **5** | Defer (User requested). |

## 4. Proposed Roadmap

### Phase 1: Stabilization (The "No Silent Failures" Run)
**Goal:** Ensure we can see what's breaking before we move it.
1.  **Audit `try/catch`:** Iterate through `hh.pipeline.psm1` and `hh.fetch.psm1`.
2.  **Implement Logging:** Replace empty catches with `Write-Log -Level Warning`.
3.  **Verify:** Run the pipeline and fix the *actual* bugs that appear in the logs.

### Phase 2: The Great decoupling (Refactoring)
**Goal:** Break `hh.pipeline.psm1` into 3-4 distinct, testable modules.
1.  **Extract `hh.pipeline.enrichment`:** Move `Build-CanonicalRowTyped`, `Get-VacancyDetail` (if orchestration), and enrichment logic.
2.  **Extract `hh.pipeline.picks`:** Move `Apply-Picks`, `Invoke-EditorsChoice` etc.
3.  **Slim down `hh.pipeline`:** It becomes purely an orchestrator that calls these sub-modules.
4.  **Update Tests:** Ensure `Picks.Selection.Tests.ps1` targets the new module directly.

### Phase 3: Modernization
**Goal:** Clean up the repo and prep for CI.
1.  **Dependency Script:** Create `tools/install-deps.ps1` to fetch DLLs.
2.  **Gitignore:** Update `.gitignore` to exclude `bin/*.dll` (but keep them for now until transition is verified).

## 5. Next Steps for "Deep Planning"
To proceed, I recommend authorizing **Phase 1 (Stabilization)** immediately. This will reveal the true state of the system ("hidden bugs") and make Phase 2 (Refactoring) much safer.
