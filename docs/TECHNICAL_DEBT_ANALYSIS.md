# Technical Debt Analysis & Strategic Roadmap
_Date: 2025-05-20_
_Version: 2.0 (Integrated Roadmap)_

## Executive Summary

This document analyzes the current state of the `hh_probe` repository, focusing on technical debt that hinders stability and future feature development (specifically batch LLM processing and parallel fetch).

The analysis is guided by the user's key priorities:
1.  **Stability First:** Eliminate silent failures that hide bugs.
2.  **Modularization:** Break down the monolithic `hh.pipeline.psm1` to enable safe growth.
3.  **Intentional Modernization:** Openness to new tools (dependencies) if planned and beneficial, avoiding "drift."

## 1. Integrated Strategic Roadmap (Safe Sequence)

This section outlines the optimal sequence for integrating Technical Debt fixes with requested Feature streams (Getmatch Parallel, Batch LLM, External LLM). The sequence is prioritized by **Safety** (minimizing regression risk).

### Phase 1: Baseline Health (The "Safety Net")
**Goal:** Establish a trusted baseline before changing ANY logic.
*   **1.1 Fix Red Tests:** Investigate and fix currently failing tests. We cannot refactor code if the tests are already broken (broken windows theory).
*   **1.2 Create E2E Smoke Test (Testpack):** Create a "black box" end-to-end test that runs the full pipeline with mocked inputs and asserts a valid HTML report is generated. This is our insurance policy against catastrophic breakage during refactoring.

### Phase 2: Stabilization (Visibility)
**Goal:** Stop flying blind.
*   **2.1 Audit & Fix Silent Failures:** Replace ~50 empty `catch {}` blocks in `hh.pipeline` and `hh.fetch` with `Write-Log -Level Warning`.
    *   *Rationale:* Adding parallel fetch (high complexity) to a system that swallows errors (low visibility) is dangerous. We need to see failures when we turn on parallelism.

### Phase 3: Low-Risk Wins (Infrastructure)
**Goal:** Deploy easy wins that don't destabilize the core pipeline.
*   **3.1 Switch to External Cheap LLM (Tier 1):** Modify `hh.llm.local` (or add `hh.llm.external`) to support cheap external APIs for summarization.
    *   *Rationale:* This enables low-RAM VPS deployment immediately without waiting for the heavy refactoring. It is an isolated change.
*   **3.2 Dependency Management:** Introduce `tools/setup.ps1` to handle DLL dependencies cleanly (optional but good hygiene).

### Phase 4: Structural Preparation (The Great Decoupling)
**Goal:** Prepare the code for Concurrency and Batching.
*   **4.1 Split `hh.pipeline.psm1`:** Refactor the monolith into:
    *   `hh.pipeline.orchestrator.psm1` (Flow control)
    *   `hh.pipeline.enrichment.psm1` (Data building)
    *   `hh.pipeline.picks.psm1` (EC/Lucky logic)
    *   *Rationale:* You cannot safely add "Batch Processing" state management or "Parallel Fetch" threads to an 800-line script that mixes concerns. We need clear boundaries.

### Phase 5: High-Risk Features (Advanced)
**Goal:** Enable the "Heavy" features.
*   **5.1 Parallel Getmatch & HH Tiered Fetch:** Now that the orchestrator is clean, we can implement a proper `Invoke-ParallelFetch` strategy.
*   **5.2 LLM Batch Processing:** Now that logic is separated, we can implement a `Batch-LLMRequests` layer that aggregates prompts from the enrichment phase and sends them in bulk, then maps results back.

---

## 2. Critical Technical Debt Analysis

### 2.1 Silent Failure Suppression
**Issue:** The codebase contains ~50 generic `try { ... } catch {}` blocks.
**Impact:** Hidden bugs, debugging nightmares, valid-looking but corrupted runs.
**Recommendation:** Phase 2 priority.

### 2.2 `hh.pipeline.psm1` Monolith
**Issue:** ~800 lines violating Single Responsibility Principle.
**Impact:** Fragility, concurrency blocker, hard to test.
**Recommendation:** Phase 4 priority.

### 2.3 `hh.fetch.psm1` Complexity
**Issue:** Mixes HTTP, Scraping, and API logic.
**Impact:** Hard to maintain Getmatch scraping.
**Recommendation:** Address during Phase 5 (Parallel Fetch implementation).

## 3. Cost-Benefit Analysis Matrix

| Item | Effort | Value | Phase |
| :--- | :--- | :--- | :--- |
| **Fix Red Tests** | Low | **Critical** | **1** |
| **E2E Testpack** | Medium | **High** | **1** |
| **Fix Silent Catches** | Medium | **Very High** | **2** |
| **External LLM Switch** | Low | Medium | **3** |
| **Split Pipeline Monolith** | High | **Very High** | **4** |
| **Parallel Fetch / Batch LLM** | High | High | **5** |

## 4. Next Steps for "Deep Planning"
To proceed, I recommend authorizing **Phase 1 (Baseline Health)** immediately.
1.  Run tests.
2.  Fix failures.
3.  Implement `tests/E2E.Smoke.Tests.ps1`.
