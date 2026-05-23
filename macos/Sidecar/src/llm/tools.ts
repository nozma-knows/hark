/**
 * The Bash tool definition the Messages API expects, in the canonical
 * `anthropic-version: 2023-06-01` shape. Shared between MessagesClient
 * and any future client that talks the same protocol so we don't
 * fork the schema by accident.
 *
 * The SDK client doesn't import this — the Agent SDK has its own
 * tool registry under the hood and is configured via `allowedTools:
 * ["Bash"]` instead of a JSON schema.
 */

export interface BashToolInput {
  command: string;
}

export const BASH_TOOL = {
  name: "bash",
  description:
    "Run a single bash command on macOS. Prefer `open`, `osascript`, `shortcuts run`, `screencapture`, `pbcopy` — see the system prompt for examples. Do not chain commands with `&&` unless you have to; one tool call per logical action is easier to debug.",
  input_schema: {
    type: "object" as const,
    properties: {
      command: {
        type: "string",
        description: "The bash command to execute.",
      },
    },
    required: ["command"],
  },
} as const;
