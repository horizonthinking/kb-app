import { describe, expect, it } from "vitest";

import {
  chatReadiness,
  isApiKeyMissing,
  isModelMissing,
  needsRemoteLogin,
  needsRemotePermission,
} from "./provider_readiness";
import type { AiConfig } from "./types";

function config(patch: Partial<AiConfig>): AiConfig {
  return {
    provider: "remote",
    apiKey: null,
    openaiApiKey: null,
    openaiBaseUrl: "https://api.openai.com/v1",
    openaiModel: null,
    model: "gemini-3.1-flash-lite",
    serverUrl: "http://localhost:8080",
    ...patch,
  };
}

describe("AI provider readiness", () => {
  it("gemini reports a missing key", () => {
    expect(isApiKeyMissing(config({ provider: "gemini", apiKey: null }))).toBe(true);
    expect(isApiKeyMissing(config({ provider: "gemini", apiKey: "key" }))).toBe(false);
  });

  it("openai requires a key only for key-required hosts", () => {
    expect(
      isApiKeyMissing(config({ provider: "openai", openaiBaseUrl: "https://api.openai.com/v1" })),
    ).toBe(true);
    expect(
      isApiKeyMissing(config({ provider: "openai", openaiBaseUrl: "http://127.0.0.1:11434/v1" })),
    ).toBe(false);
    expect(
      isApiKeyMissing(
        config({ provider: "openai", openaiBaseUrl: "https://openrouter.ai/api/v1" }),
      ),
    ).toBe(true);
  });

  it("openai reports a missing model", () => {
    expect(isModelMissing(config({ provider: "openai", openaiModel: "" }))).toBe(true);
    expect(isModelMissing(config({ provider: "openai", openaiModel: "gpt-5-nano" }))).toBe(false);
    expect(isModelMissing(config({ provider: "gemini", openaiModel: "" }))).toBe(false);
    expect(isModelMissing(config({ provider: "remote", openaiModel: "" }))).toBe(false);
  });

  it("remote login and permission predicates are unchanged", () => {
    expect(needsRemoteLogin("remote", false)).toBe(true);
    expect(needsRemoteLogin("remote", true)).toBe(false);
    expect(needsRemoteLogin("gemini", false)).toBe(false);
    expect(needsRemotePermission("remote", true, false)).toBe(true);
    expect(needsRemotePermission("remote", false, false)).toBe(false);
    expect(needsRemotePermission("remote", true, true)).toBe(false);
    expect(needsRemotePermission("openai", true, false)).toBe(false);
  });

  it("chatReadiness composes every provider state", () => {
    const readyOpenAi = config({
      provider: "openai",
      openaiApiKey: "key",
      openaiBaseUrl: "https://api.openai.com/v1",
      openaiModel: "gpt-5-nano",
    });
    const cases: [AiConfig, boolean, boolean, ReturnType<typeof chatReadiness>][] = [
      [readyOpenAi, false, false, "ready"],
      [{ ...readyOpenAi, openaiModel: "" }, false, false, "missing_model"],
      [{ ...readyOpenAi, openaiApiKey: null }, false, false, "missing_key"],
      [
        config({
          provider: "openai",
          openaiBaseUrl: "http://127.0.0.1:11434/v1",
          openaiModel: "qwen3.5:4b",
        }),
        false,
        false,
        "ready",
      ],
      [config({ provider: "gemini", apiKey: null }), false, false, "missing_key"],
      [config({ provider: "gemini", apiKey: "key" }), false, false, "ready"],
      [config({ provider: "remote" }), false, false, "needs_login"],
      [config({ provider: "remote" }), true, false, "needs_permission"],
      [config({ provider: "remote" }), true, true, "ready"],
    ];
    for (const endpoint of [
      "not a url",
      "http://api.openai.com/v1",
      "http://127.0.0.1:11434/v1",
      "https://user:pw@api.openai.com/v1",
      "https://api.openai.com/v1?x=1",
      "https://api.openai.com/v1#f",
    ]) {
      cases.push([{ ...readyOpenAi, openaiBaseUrl: endpoint }, false, false, "invalid_endpoint"]);
    }

    for (const [candidate, authenticated, authorized, expected] of cases) {
      expect(
        chatReadiness(candidate, authenticated, authorized),
        candidate.openaiBaseUrl ?? candidate.provider,
      ).toBe(expected);
    }
  });
});
