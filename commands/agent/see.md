---
name: agent:see
description: Take a screenshot and analyze the desktop using the perception pipeline
argument-hint: "[what to look for, e.g. 'Notepad window' or 'error dialog']"
allowed-tools:
  - Bash
  - Read
---

<objective>
Run the perception pipeline to see what's on screen. Captures screenshot, runs UIA + OCR, and returns annotated PNG + JSON analysis.

Use to understand the current desktop state before planning actions.
</objective>

<execution_context>
Scripts are at $HOME/.claude/scripts/
</execution_context>

<process>
1. Run perception with skip-vision for speed:
   ```powershell
   powershell -File "$HOME/.claude/scripts/perception.ps1" -OutputDir "$HOME/Desktop" -SkipVision
   ```
2. Read the perception JSON output to get element list
3. If user asked for something specific (ARGUMENTS), filter elements matching the description
4. Present findings: total elements, key interactive elements, their coordinates
5. Reference the annotated PNG for visual confirmation
</process>
