import { z } from "zod";
import { runBash } from "../runBash.ts";
import { defaultAliasStore, type Alias, type AliasStore } from "./aliasStore.ts";
import type { ExecutionResult, Tool } from "./types.ts";

/**
 * Run a user-defined voice command alias by its phrase. Aliases let
 * power users bind a spoken phrase to a sequence of shell commands
 * via the Settings UI; they're stored on disk in
 * `~/Library/Application Support/Hark/aliases.json`.
 *
 * The full list of available aliases is rendered into the system
 * prompt so the LLM knows which phrases are valid. Matching is
 * case-insensitive against the alias phrase. If the model passes
 * a phrase that doesn't exist, the tool returns a clear error and
 * the model can recover by calling a different tool.
 */

const InputShape = {
  phrase: z.string().min(1, "phrase is required"),
};
const Input = z.object(InputShape);
type Input = z.infer<typeof Input>;

export function makeRunAlias(store: AliasStore = defaultAliasStore): Tool<Input> {
  return {
    name: "runAlias",
    description:
      "Run a user-defined alias by its trigger phrase. Aliases are listed in the system prompt under 'Available aliases'. Pass the phrase the user used (case is normalised for you). If no alias matches the phrase, the tool returns a 'phrase_not_found' error.",
    inputSchema: {
      type: "object",
      properties: {
        phrase: {
          type: "string",
          description:
            "The alias phrase as the user said it. Case is normalised.",
        },
      },
      required: ["phrase"],
    },
    zodShape: InputShape,

    parseInput(raw) {
      return Input.parse(raw);
    },

    async execute({ phrase }): Promise<ExecutionResult> {
      const needle = phrase.toLowerCase().trim();
      const alias = store.current().find((a) => a.phrase === needle);
      if (!alias) {
        return {
          summary: `No alias matches "${phrase}"`,
          succeeded: false,
          error: "phrase_not_found",
          bashCommands: [],
        };
      }
      return runAliasCommands(alias);
    },
  };
}

async function runAliasCommands(alias: Alias): Promise<ExecutionResult> {
  const ran: string[] = [];
  for (const command of alias.commands) {
    const result = await runBash(command);
    ran.push(result.command);
    if (result.exitCode !== 0) {
      return {
        summary: `Ran alias "${alias.phrase}" — step failed`,
        succeeded: false,
        error: result.stderr.trim() || `exit ${result.exitCode}`,
        bashCommands: ran,
      };
    }
  }
  return {
    summary:
      ran.length === 1
        ? `Ran "${alias.phrase}"`
        : `Ran "${alias.phrase}" (${ran.length} steps)`,
    succeeded: true,
    bashCommands: ran,
  };
}

export const runAlias = makeRunAlias();
