---
name: agent:do
description: Execute a desktop automation task using the agent executor
argument-hint: "<natural language goal, e.g. 'open Notepad and type Hello World'>"
allowed-tools:
  - Bash
  - Read
  - Write
  - AskUserQuestion
---

<objective>
Execute a desktop automation task. Generates a DAG execution plan, then runs it through the FSM-based executor.

The executor handles: SENSE (perception) → PLAN (DAG decomposition) → ACT (mouse/keyboard) → VERIFY (multi-modal) → RECOVER (retry with alternatives) → DONE or ESCALATE.
</objective>

<execution_context>
Scripts are at $HOME/.claude/scripts/
Current task history: $HOME/.claude/projects/C--Users-DBA126-AppData-Roaming-npm/memory/task-history.md
</execution_context>

<process>
1. Parse the user's goal from ARGUMENTS
2. Generate a DAG (task steps) using the planner prompt format:
   - Each step: step_id, description, depends_on, action {type, target, expected_outcome, alternatives}
   - See planner.ps1 for full schema
3. Ask user to confirm the DAG before execution (use AskUserQuestion)
4. Save DAG to a temp JSON file
5. Run executor:
   ```powershell
   powershell -File "$HOME/.claude/scripts/executor.ps1" -execDagPath "<dag.json>" -execOutputDir "$HOME/Desktop/agent_output"
   ```
6. Report results: steps completed, any failures, checkpoint location
7. If ESCALATE: show failure report and suggest recovery options
</process>
