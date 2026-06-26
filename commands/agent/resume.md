---
name: agent:resume
description: Resume a failed or interrupted task from its checkpoint
argument-hint: "<output directory containing checkpoint.json>"
allowed-tools:
  - Bash
  - Read
  - AskUserQuestion
---

<objective>
Resume a previously failed or interrupted agent task from its checkpoint.

The executor automatically saves checkpoint.json after each step, enabling resume from the exact point of failure without re-executing completed steps.
</objective>

<execution_context>
Scripts are at $HOME/.claude/scripts/
Checkpoint format: checkpoint.json contains current_step_index, retry_count, strategy_index, and step_states
</execution_context>

<process>
1. Verify checkpoint.json exists in the specified output directory
2. Read checkpoint to show: which step failed, how many retries, which strategy was last used
3. Ask user: resume from checkpoint or start fresh?
4. To resume:
   - The checkpoint state is auto-loaded by executor.ps1 when checkpoint.json exists in the output dir
   - Or use the MCP resume_task tool if available
   ```powershell
   powershell -File "$HOME/.claude/scripts/executor.ps1" -execOutputDir "<dir>"
   ```
5. Report result of resumed execution
</process>
