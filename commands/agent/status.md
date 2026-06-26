---
name: agent:status
description: Show recent agent task execution history
argument-hint: "[optional: number of recent tasks, default 5]"
allowed-tools:
  - Bash
  - Read
---

<objective>
Display recent agent task execution history from cross-session memory. Shows task goals, completion status, and timing.

Each task execution automatically records to task-history.md for cross-session recall.
</objective>

<execution_context>
Task history: $HOME/.claude/projects/C--Users-DBA126-AppData-Roaming-npm/memory/task-history.md
Output dirs are typically at $HOME/Desktop/agent_output or $HOME/Desktop/agent_test/
</execution_context>

<process>
1. Read the task history file
2. Parse the markdown table to extract recent entries
3. Display summary: total tasks, success rate, recent failures
4. For any recent ESCALATE tasks, check if checkpoint.json exists for resuming
5. Present as a clean table with task IDs truncated for readability
</process>
