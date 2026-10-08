import {
  DEFAULT_OPENAI_BASE_URL,
  DEFAULT_PROVIDER,
  assertNever,
  endpointPolicyFor,
  normalizeApiKey,
} from "./config";
import { setupPromptFor } from "./components/settings_copy";
import type { AiConfig, AiProvider } from "./types";
import type { MessageKey } from "~/i18n";

type ChatReadiness =
  | "ready"
  | "invalid_endpoint"
  | "missing_key"
  | "missing_model"
  | "needs_login"
  | "needs_permission";

function isApiKeyMissing(config: Partial<AiConfig>): boolean {
  const provider = config.provider ?? DEFAULT_PROVIDER;
  if (provider === "gemini") return normalizeApiKey(config.apiKey) === null;
  if (provider !== "openai") return false;

  const key = normalizeApiKey(config.openaiApiKey);
  return (
    endpointPolicyFor(config.openaiBaseUrl ?? DEFAULT_OPENAI_BASE_URL, key !== null).requirement ===
      "required" && key === null
  );
}

function isModelMissing(config: Partial<AiConfig>): boolean {
  return config.provider === "openai" && (config.openaiModel?.trim() ?? "").length === 0;
}

function needsRemoteLogin(provider: AiProvider, authenticated: boolean): boolean {
  return provider === "remote" && !authenticated;
}

function needsRemotePermission(
  provider: AiProvider,
  authenticated: boolean,
  isPluginAuthorized: boolean,
): boolean {
  return provider === "remote" && authenticated && !isPluginAuthorized;
}

function chatReadiness(
  config: Partial<AiConfig>,
  authenticated: boolean,
  isPluginAuthorized: boolean,
): ChatReadiness {
  const provider = config.provider ?? DEFAULT_PROVIDER;
  switch (provider) {
    case "openai": {
      const key = normalizeApiKey(config.openaiApiKey);
      const policy = endpointPolicyFor(
        config.openaiBaseUrl ?? DEFAULT_OPENAI_BASE_URL,
        key !== null,
      );
      if (!policy.accepted) return "invalid_endpoint";
      if (isApiKeyMissing(config)) return "missing_key";
      if (isModelMissing(config)) return "missing_model";
      return "ready";
    }
    case "gemini":
      return isApiKeyMissing(config) ? "missing_key" : "ready";
    case "remote":
      if (needsRemoteLogin(provider, authenticated)) return "needs_login";
      if (needsRemotePermission(provider, authenticated, isPluginAuthorized)) {
        return "needs_permission";
      }
      return "ready";
    default:
      return assertNever(provider);
  }
}

function panelStateFor(
  provider: AiProvider,
  readiness: ChatReadiness,
): { promptKey: MessageKey | null; inputEnabled: boolean } {
  switch (readiness) {
    case "ready":
      return { promptKey: null, inputEnabled: true };
    case "invalid_endpoint":
    case "missing_key":
    case "missing_model":
    case "needs_login":
    case "needs_permission":
      return { promptKey: setupPromptFor(provider), inputEnabled: false };
    default:
      return assertNever(readiness);
  }
}

export {
  chatReadiness,
  isApiKeyMissing,
  isModelMissing,
  needsRemoteLogin,
  needsRemotePermission,
  panelStateFor,
};
export type { ChatReadiness };
