# Kessel LLM Evaluation Harness

## Overview

This directory contains a benchmarking harness that evaluates how different large language models (LLMs) solve real-world implementation tasks on the Kessel JavaScript parser. The harness sends standardized prompts to various models (via OpenRouter), captures their responses through terminal automation, and collects structured results for comparison.

## Tasks

The evaluation suite consists of three realistic implementation challenges:

- **Task 1: Octal & Binary Number Parsing** — Implement `scan_octal_number` and `scan_binary_number` functions in the lexer to parse JavaScript numeric literals like `0o755` and `0b1010`. Tests the model's ability to understand number format specifications and handle edge cases gracefully.

- **Task 2: Default Values in Arrow Function Destructuring** — Add support for default parameter values in destructured arrow functions (e.g., `const f = ({ x = 10 }) => x`). Requires understanding of pattern matching, assignment expressions, and AST transformation logic.

- **Task 3: Unicode Identifier Support** — Extend identifier recognition in the lexer to support Unicode characters (e.g., `café`, `日本語`, `π`). Tests knowledge of Unicode standards, performance considerations, and maintaining backward compatibility with the ASCII fast path.

## Models Evaluated

Models are grouped by provider:

**NVIDIA**
- `llama-3.3-nemotron-super-49b-v1.5`

**OpenAI**
- `gpt-5-nano`
- `gpt-oss-120b`

**OpenRouter**
- `elephant-alpha`

**Qwen (Alibaba)**
- `qwen3-next-80b-a3b-instruct`
- `qwen3.5-9b`

## Usage

### Run a single model on a single task

```bash
./eval_single.sh <model> <task_num> <output_dir>
```

Example:
```bash
./eval_single.sh "openai/gpt-5-nano" 1 ./results
```

### Run a model on all tasks

```bash
./eval_model.sh <model> <output_dir>
```

Example:
```bash
./eval_model.sh "nvidia/llama-3.3-nemotron-super-49b-v1.5" ./results
```

## Results Structure

- **`results/`** — Final collected results from all models across all tasks. Files are named `<model_slug>__task<N>.md`.

- **`results_task1/`, `results_task2/`, `results_task3/`** — Task-specific result directories (alternative organization).

Each result file contains:
- Model and task metadata
- Timestamp of evaluation
- Terminal screenshot/transcript of the model's response

## Infrastructure

- **Harness Framework**: Uses `agent-tui` to automate interaction with models via the OpenRouter API
- **Session Management**: Maintains terminal sessions and monitors for completion (3+ seconds of stable output)
- **Timeout Handling**: 120–180 second timeouts per evaluation to prevent hanging on slow responses
- **Error Detection**: Monitors for API errors (401, 403, 429, 500) and rate limiting
