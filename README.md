# Hiring Agent

> [!NOTE]
> Used for GDG KIIT's 2025 recruitment (500+ applications, shortlisting cut from 2 weeks to 3 days, every shortlist human-reviewed). Published Oct 2026; v2 with a web frontend in progress for the 2026 cycle.

<p align="center"><strong>Resume-to-Score pipeline</strong> that extracts structured data from PDFs, enriches with GitHub signals, and outputs a fair, explainable evaluation.</p>

<p align="center">
  <a href="https://www.python.org/downloads/release/python-3110/">
    <img alt="Python" src="https://img.shields.io/badge/python-3.11%2B-blue.svg">
  </a>
  <a href="https://github.com/interviewstreet/hiring-agent/blob/master/LICENSE">
    <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-yellow.svg">
  </a>
  <a href="https://github.com/psf/black">
    <img alt="Code style: Black" src="https://img.shields.io/badge/code%20style-Black-000000.svg">
  </a>
</p>

---

## Contents

- [About this fork](#about-this-fork)
- [Upstream context](#upstream-context)
- [Coverage](#coverage)
- [Overview](#overview)
- [Architecture](#architecture)
- [Installation and Setup](#installation-and-setup)
  - [Prerequisites](#prerequisites)
  - [Quick setup with pip](#quick-setup-with-pip)
  - [Ollama models](#ollama-models)
- [Configuration](#configuration)
- [How it works](#how-it-works)
- [CLI usage](#cli-usage)
- [Directory layout](#directory-layout)
- [Provider details](#provider-details)
- [Contributing](#contributing)
- [License](#license)

---

## About this fork

> **Status: under development** for GDG KIIT's 2026 recruitment cycle.

This is a fork of [interviewstreet/hiring-agent](https://github.com/interviewstreet/hiring-agent), adapted for GDG KIIT's recruitment and kept up to date with upstream. On top of the upstream pipeline, it adds:

- **Batch ranking** ([`batch_score.py`](#batch-scoring-and-ranking)): score a whole applicant sheet, such as an Airtable export, against a folder of resume PDFs and get one ranked `scores.csv` with the original columns intact.
- **Docker setup** ([`hiring-agent.sh`](#docker-setup)): an interactive setup that asks for a provider and API key (or Ollama), then runs the agent without a local Python install.

Every shortlist is reviewed by a person.

**In progress for 2026:** v2 with a web frontend.

---

## Upstream context

*This section is from the upstream HackerRank project and describes how HackerRank uses it.*

This project got a lot of attention recently, and some of the discussion surfaced misconceptions worth addressing directly.

**What this is not:**
- Not an ATS (Applicant Tracking System)
- Not used to screen HackerRank's open roles
- Not a product available to HackerRank customers

**What it actually is:**

Every year HackerRank receives 50,000–60,000 intern applications. No human can read that many resumes well. This tool was built to *rank* them — helping decide which resumes to read first. Resumes scoring below the cutoff are filtered out, but the cutoff is intentionally set very low so only candidates at the very bottom of the distribution are removed. The vast majority pass through to human review, where the real decisions are made.

Since this was built, HackerRank has also shipped [AI Interviewer (Chakra)](https://www.hackerrank.com/products/ai-interviewer/) to automate the first round of interviews — so candidates are no longer assessed on their resume alone.

**On the default model:**

The repo ships with `gemma4:latest` as the default because it runs locally on most laptops without any cloud API key. Actual intern resumes at HackerRank are evaluated using a top-tier Gemini model. The repo ships with a demo config, not the production one.

---

## Coverage

Articles and discussions about the upstream project that have shaped how it is being improved:

| Article | Key takeaway |
|---|---|
| [HackerRank open sourced its ATS. My resume scored 90/100. Oh wait 74/100. No — 88/100. Actually 83/100.](https://danunparsed.com/p/hackerrank-open-source-ats) — *Dan Kinsky* | Deep statistical analysis of score variance across 100 runs of the same resume. Isolates which categories are stable (technical skills) vs. noisy (project quality judgments). Points to LLM non-determinism as the root cause. |
| [The Score Depends on the Roll of the Dice](https://pinggy.io/blog/hackerrank_open_source_ats_inconsistent_scoring/) — *Pinggy Blog* | Reproduces the variance findings and surfaces a security issue: invisible text embedded in PDFs can inflate scores significantly. |
| [The Hiring Rubric Inside](https://byteiota.com/hackerrank-ats-open-source-the-hiring-rubric-inside/) — *ByteIota* | Breaks down the scoring weights and argues that a GitHub-centric rubric disadvantages engineers whose work is in private enterprise repos. Also notes the signal degradation risk as candidates optimize for the now-public rubric. |
| [Analyzing resume scoring consistency](https://dev.to/mgobea/hackerrank-open-sourced-its-ats-analyzing-resume-scoring-consistency-1j5d) — *Mariano Gobea Alcoba, DEV Community* | Proposes concrete fixes: standardized data formats, versioned evaluation models, ensemble scoring, and explainability layers to reduce variance and make the system more robust. |
| [AI-Powered Pipeline for Explainable Resume Scoring](https://aitoolly.com/ai-news/article/2026-06-26-interviewstreet-unveils-hiring-agent-an-ai-powered-pipeline-for-explainable-resume-scoring-and-githu) — *AIToolly* | Covers the launch and highlights the transparency argument — making scoring logic public allows scrutiny that proprietary ATS systems never face. |
| [Hacker News discussion](https://news.ycombinator.com/item?id=48713832) | 200+ comment thread covering LLM determinism, GDPR Article 22 implications, and the broader ethics of automated resume filtering. |

**Video coverage**

- [HackerRank Open-Sourced Their ATS?](https://www.youtube.com/shorts/0OP2bhYZQfc) — YouTube Short
- [HackerRank Open-Sourced ATS Tool for selecting Resume](https://www.youtube.com/shorts/UnHGC1Ywhys) — YouTube Short
- [HackerRank Custom ATS Released! Get Your Resume Score & Beat ATS Filters](https://www.youtube.com/watch?v=tQSve-xx4_8) — full walkthrough video

**Community tools built on this repo**

- [Resume Reality Check](https://resume-reality-check-seven.vercel.app/) — hosted tool that lets candidates score their own resume against the same rubric

---

## Overview

Hiring Agent parses a resume PDF to Markdown, extracts sectioned JSON using a local or hosted LLM, augments the data with GitHub profile and repository signals, then produces an objective evaluation with category scores, evidence, bonus points, and deductions. You can run fully local with Ollama or use Google Gemini.

---

## Architecture

<table>
<tr>
<td>

**Flow**

1. `pymupdf_rag.py` converts PDF pages to Markdown-like text.
2. `pdf.py` calls the LLM per section using Jinja templates under `prompts/templates`.
3. `github.py` fetches profile and repos, classifies projects, and asks the LLM to select the top 7.
4. `evaluator.py` runs a strict-scored evaluation with fairness constraints.
5. `score.py` orchestrates everything end to end and writes CSV when development mode is on.

</td>
<td>

**Key modules**

- `models.py`
  Pydantic schemas and LLM provider interfaces.

- `llm_utils.py`
  Provider initialization and response cleanup.

- `transform.py`
  Normalization from loose LLM JSON to JSON Resume style.

- `prompts/`
  All Jinja templates for extraction and scoring.

</td>
</tr>
</table>

---

## Installation and Setup

### Prerequisites

- **Python 3.11+**

  The repository pins `.python-version` to 3.11.13.

- **One LLM backend** (either of them)

  - **Ollama** for local models
    Install from the [official site](https://ollama.com/), then run `ollama serve`.
  - **Google Gemini** if you have an API key, get it from [here](https://aistudio.google.com/api-keys).

### Quick setup with pip

```bash
$ git clone https://github.com/interviewstreet/hiring-agent
$ cd hiring-agent

$ python -m venv .venv
# Linux or macOS
$ source .venv/bin/activate
# Windows
# .venv\Scripts\activate

$ pip install -r requirements.txt
```

### Docker setup

If you have [Docker](https://docs.docker.com/get-docker/), you can skip the Python setup entirely:

```bash
$ ./hiring-agent.sh setup
```

Setup builds the image, then lists the providers and models in `providers.json` (Ollama, Gemini and Anthropic out of the box) and asks for the API key the chosen provider needs. For Ollama, it can use an install on your machine, or run Ollama in its own container and pull the model for you. It also asks for an optional GitHub token, then saves everything to `.env`. Rerun it anytime to switch providers.

```bash
# Rank a sheet of applicants against a folder of resumes
$ ./hiring-agent.sh batch applicants.xlsx resumes/ --role software_engineering_intern -o scores.csv

# Score a single resume
$ ./hiring-agent.sh score resume.pdf --role software_engineering_intern

# Create a new role to score against (written to roles/ in this repo)
$ ./hiring-agent.sh score --init-role gdg_member

# Stop the bundled Ollama container when you're done
$ ./hiring-agent.sh stop
```

Paths are relative to the folder you run the script from, and `cache/` and `scores.csv` are written there. The image picks up code changes on each run, and `roles/` is shared with the container, so role edits apply immediately. `.env` is never copied into the image.

> [!NOTE]
> On macOS, choose "On this machine" for Ollama. Docker on a Mac can't use the GPU, so Ollama inside Docker runs on the CPU and is much slower. On Linux, start a host Ollama with `OLLAMA_HOST=0.0.0.0 ollama serve` so containers can reach it.

### Ollama Models

Pull the model you want to use. For example:

```bash
$ ollama pull gemma4:latest
```

If you want different results, you can pull other models such as:

```bash
# For higher system configuration
$ ollama pull gemma3:12b

# For lower system configuration
$ ollama pull gemma3:1b
```

---

## Configuration

Copy the template and set your environment variables.

```bash
$ cp .env.example .env
```

**Environment variables**

| Variable         | Values                                      | Description                                                            |
| ---------------- | ------------------------------------------- | ---------------------------------------------------------------------- |
| `DEFAULT_MODEL`  | for example `gemma4:latest` or `gemini-2.5-pro` | Model to use; must exist in `providers.json` — the provider is inferred from which provider lists it. Defaults to `default_model` in `providers.json`. |
| `GEMINI_API_KEY` | string                                      | Required when using a Gemini model.                                   |
| `GITHUB_TOKEN`   | optional                                    | Inherits from your shell environment, improves GitHub API rate limits. |

Provider mapping lives in `providers.json` — each provider declares its `base_url`, an optional API-key env var, and per-model parameters; `config.py` loads it and resolves the provider for a model. A `<PROVIDER>_BASE_URL` env var (for example `OLLAMA_BASE_URL`) overrides a provider's `base_url`. `config.py` also has a flag:

```python
# config.py
DEVELOPMENT_MODE = True  # enables caching and CSV export
```

You can leave it on during iteration. See the next section for details.

---

## How it works

<details>
<summary><b>1) PDF extraction</b></summary>

- `pymupdf_rag.py` and `pdf.py` read the PDF using PyMuPDF and convert pages to Markdown-like text.
- The `to_markdown` routine handles headings, links, tables, and basic formatting.

</details>

<details>
<summary><b>2) Section parsing with templates</b></summary>

- `prompts/templates/*.jinja` define strict instructions for each section
  Basics, Work, Education, Skills, Projects, Awards.
- `pdf.PDFHandler` calls the LLM per section and assembles a `JSONResume` object (see `models.py`).

</details>

<details>
<summary><b>3) GitHub enrichment</b></summary>

- `github.py` extracts a username from the resume profiles, fetches profile and repos, and classifies each project.
- It asks the LLM to select exactly 7 unique projects with a minimum author commit threshold, favoring meaningful contributions.

</details>

<details>
<summary><b>4) Evaluation</b></summary>

- `evaluator.py` scores the resume against the **role** selected on the command line.
- Each role lives in `roles/<role_name>/` and defines its own scoring categories and weights in `role.json`, plus its own `criteria.jinja` and `system_message.jinja` prompts (encoding fairness and scoring rules).
- The shipped `software_engineering_intern` role scores `open_source`, `self_projects`, `production`, and `technical_skills`, plus bonus and deductions, with evidence for each. Other roles can define entirely different categories.

</details>

<details>
<summary><b>5) Output and CSV export</b></summary>

- `score.py` prints a readable summary to stdout.
- When `DEVELOPMENT_MODE=True` it creates or appends a per-role `resume_evaluations_<role>.csv` with key fields (columns follow the role's categories), and caches intermediate JSON under `cache/`.

</details>

---

## CLI usage

### End to end scoring

Provide a path to a resume PDF and the role to score against. `--role` is the
name of a directory under `roles/` and is **required**.

```bash
$ python score.py ./resume/sample.pdf --role software_engineering_intern
```

What happens:

1. If development mode is on, the PDF extraction result is cached to `cache/resumecache_<basename>.json`.
2. If a GitHub profile is found in the resume, repositories are fetched and cached to `cache/githubcache_<basename>.json`.
3. The evaluator scores the resume against the selected role, prints a report and, in development mode, appends a CSV row to `resume_evaluations_<role>.csv`.

### Roles

A role bundles its rubric in `roles/<role_name>/`:

```text
roles/software_engineering_intern/
├── role.json           # categories, weights (max), bonus_max, score bounds, position_title
├── criteria.jinja      # evaluation criteria prompt (receives {{ text_content }})
└── system_message.jinja
```

`role.json` drives the scoring schema, the printed report, the CSV columns, and
the score caps — so each role can score against its own categories and weights.

To add a role, scaffold one with basic template files and then edit them:

```bash
$ python score.py --init-role backend_engineer
# edit roles/backend_engineer/{role.json,criteria.jinja,system_message.jinja}
$ python score.py ./resume/sample.pdf --role backend_engineer
```

`--init-role` creates the role directory with placeholder categories and prompts
(it only scaffolds; it does not score a resume). You can also copy an existing
role directory instead.

### Batch scoring and ranking

Score a whole applicant sheet (for example, an Airtable export of recruitment responses) against a folder of resume PDFs:

```bash
$ python batch_score.py applicants.xlsx resumes/ --role software_engineering_intern -o scores.csv
```

- The sheet can be `.xlsx` or `.csv`. Use `--sheet-name` to pick a worksheet other than the first.
- Each row is matched to a PDF in the folder (subfolders included), in this order:
  1. The attachment filename in the resume column. Airtable cells like `jane_resume.pdf (https://...)` work as-is.
  2. The applicant's email, or the part before `@`, appearing in a PDF filename.
  3. The applicant's name appearing in a PDF filename.
- Columns are detected automatically. Override them with `--resume-column`, `--email-column` and `--name-column` if detection guesses wrong.
- `--role` picks the rubric, as with `score.py`.
- `scores.csv` keeps every original column and adds `rank`, `total_score`, one `<category>_score` column per role category, bonus, deductions, strengths, areas for improvement, `matched_resume` and `scoring_status`. Rows are sorted by score, and unmatched or failed rows go at the bottom.
- In development mode, cached extractions mean a rerun only scores resumes that haven't been scored before. Pressing Ctrl+C still writes the rows scored so far.

---

## Directory layout

```text
.
├── .env.example
├── .python-version
├── config.py
├── evaluator.py
├── github.py
├── llm_utils.py
├── models.py
├── pdf.py
├── prompt.py
├── prompts/
│   ├── template_manager.py
│   └── templates/
│       ├── awards.jinja
│       ├── basics.jinja
│       ├── education.jinja
│       ├── github_project_selection.jinja
│       ├── projects.jinja
│       ├── skills.jinja
│       ├── system_message.jinja
│       └── work.jinja
├── providers.json
├── pymupdf_rag.py
├── requirements.txt
├── roles.py
├── roles/
│   └── software_engineering_intern/
│       ├── role.json
│       ├── criteria.jinja
│       └── system_message.jinja
├── score.py
└── transform.py
```

---

## Provider details

### Ollama

- Set `DEFAULT_MODEL` to any pulled model listed in `providers.json`, for example `gemma4:latest`
- Requests go through `models.OpenAICompatibleProvider` against Ollama's OpenAI-compatible endpoint (`http://localhost:11434/v1`)

### Gemini

- Set `DEFAULT_MODEL` to a Gemini model listed in `providers.json`, for example `gemini-2.0-flash`
- Provide `GEMINI_API_KEY`
- The same `models.OpenAICompatibleProvider` wrapper is used, pointed at Gemini's OpenAI-compatible endpoint

---

## Contributing

Please read the [CONTRIBUTING.md](./CONTRIBUTING.md) for detailed guidelines on filing issues, proposing changes, and submitting pull requests. Key principles include:

- Keep prompts declarative and provider-agnostic.
- Validate changes with a couple of real resumes under different providers.
- Add or adjust unit-free smoke tests that call each stage with minimal inputs.

---


## License

[MIT](https://github.com/interviewstreet/hiring-agent/blob/master/LICENSE) © HackerRank
