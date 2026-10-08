import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { renderToString } from "solid-js/web";
import { describe, expect, it, vi } from "vitest";

import { SetupGate } from "./setup_gate";
import { setupPromptFor } from "./settings_copy";
import type { ChatReadiness } from "../provider_readiness";
import type { AiProvider } from "../types";
import { MESSAGE_KEYS } from "~/i18n";

vi.mock("../chat_store", () => ({
  chatState: { config: { saving: false, error: null, provider: "remote" } },
  switchProviderAndSave: vi.fn(),
}));

vi.mock("~/plugins/builtin/core_auth/auth_service", () => ({
  authState: { loading: false, authenticated: false, error: null },
  getAuthService: () => undefined,
}));

vi.mock("~/stores/files", () => ({ openSettings: vi.fn() }));

describe("SetupGate", () => {
  it("setup gate renders from readiness", () => {
    const providers: AiProvider[] = ["remote", "gemini", "openai"];
    const readinessStates: ChatReadiness[] = [
      "ready",
      "invalid_endpoint",
      "missing_key",
      "missing_model",
      "needs_login",
      "needs_permission",
    ];

    for (const provider of providers) {
      for (const readiness of readinessStates) {
        const html = renderToString(() => (
          <SetupGate provider={provider} readiness={readiness}>
            <span data-child-marker="ready" />
          </SetupGate>
        ));
        if (readiness === "ready") {
          expect(html, `${provider}/${readiness}`).toContain('data-child-marker="ready"');
          expect(html, `${provider}/${readiness}`).not.toContain("data-setup-prompt");
        } else {
          const promptKey = setupPromptFor(provider);
          expect(html, `${provider}/${readiness}`).toContain(`data-setup-prompt="${promptKey}"`);
          expect(html, `${provider}/${readiness}`).not.toContain("data-child-marker");
          expect(MESSAGE_KEYS).toContain(promptKey);
        }
      }
    }

    const panelSource = readFileSync(
      fileURLToPath(new URL("../chat_panel.tsx", import.meta.url)),
      "utf8",
    );
    expect(panelSource).toContain("<SetupGate");
    expect(panelSource).toContain("chatReadiness(");
    for (const predicate of [
      "isApiKeyMissing",
      "isModelMissing",
      "needsRemoteLogin",
      "needsRemotePermission",
    ]) {
      expect(panelSource).not.toContain(predicate);
    }

    const gateSource = readFileSync(
      fileURLToPath(new URL("setup_gate.tsx", import.meta.url)),
      "utf8",
    );
    expect(gateSource).toContain('switchProviderAndSave("remote")');
  });
});
