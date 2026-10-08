import type { AiConfig, AiProvider } from "./types";

const AI_CHAT_SETTINGS_PLUGIN_ID = "ai-chat";
const AI_CHAT_SECURE_KEYS = ["apiKey", "openaiApiKey"] as const;
const AI_PROVIDERS = ["remote", "gemini", "openai"] as const;
const DEFAULT_MODEL = "gemini-3.1-flash-lite";
const DEFAULT_PROVIDER = "remote" as const;
const DEFAULT_OPENAI_BASE_URL = "https://api.openai.com/v1";
const DEFAULT_SERVER_URL =
  import.meta.env.VITE_KUKU_API_URL?.trim() ||
  (import.meta.env.PROD ? "https://api.kuku.mom" : "http://localhost:8080");
// Internal guardrails: these are intentionally kept out of the settings UI.
const DEFAULT_ROUND_LIMIT = 12;
const DEFAULT_PROXY_TIMEOUT_MS = 15_000;

function createDefaultAiConfig(): AiConfig {
  return {
    provider: DEFAULT_PROVIDER,
    apiKey: null,
    openaiApiKey: null,
    openaiBaseUrl: DEFAULT_OPENAI_BASE_URL,
    openaiModel: null,
    model: DEFAULT_MODEL,
    serverUrl: DEFAULT_SERVER_URL,
    roundLimit: DEFAULT_ROUND_LIMIT,
    proxyToolTimeoutMs: DEFAULT_PROXY_TIMEOUT_MS,
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function normalizeApiKey(value: string | null | undefined): string | null {
  const trimmed = value?.trim() ?? "";
  return trimmed.length > 0 ? trimmed : null;
}

function normalizedNullableString(value: unknown): string | null {
  return typeof value === "string" ? normalizeApiKey(value) : null;
}

function modelForProvider(provider: AiProvider, raw: Partial<AiConfig>): string {
  switch (provider) {
    case "openai":
      return normalizedNullableString(raw.openaiModel) ?? "";
    case "gemini":
    case "remote":
      return DEFAULT_MODEL;
    default:
      return assertNever(provider);
  }
}

interface EndpointPolicy {
  requirement: "required" | "optional";
  accepted: boolean;
}

function requirementForHostname(hostname: string): EndpointPolicy["requirement"] {
  const normalized = hostname
    .replace(/^\[/, "")
    .replace(/\]$/, "")
    .replace(/\.$/, "")
    .toLowerCase();
  if (
    normalized === "localhost" ||
    normalized.endsWith(".local") ||
    normalized.endsWith(".ts.net") ||
    normalized === "::1"
  ) {
    return "optional";
  }

  const octets = normalized.split(".").map(Number);
  if (
    octets.length === 4 &&
    octets.every((octet) => Number.isInteger(octet) && octet >= 0 && octet <= 255)
  ) {
    if (
      octets[0] === 10 ||
      octets[0] === 127 ||
      (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) ||
      (octets[0] === 192 && octets[1] === 168)
    ) {
      return "optional";
    }
  }
  return "required";
}

function endpointPolicyFor(baseUrl: string, keyPresent: boolean): EndpointPolicy {
  let url: URL;
  try {
    url = new URL(baseUrl.trim());
  } catch {
    return { requirement: "required", accepted: false };
  }

  const requirement = requirementForHostname(url.hostname);
  const validScheme = url.protocol === "http:" || url.protocol === "https:";
  const hasForbiddenParts =
    url.username.length > 0 ||
    url.password.length > 0 ||
    url.search.length > 0 ||
    url.hash.length > 0;
  const accepted =
    validScheme &&
    !hasForbiddenParts &&
    url.hostname.length > 0 &&
    (url.protocol === "https:" || (!keyPresent && requirement === "optional"));
  return { requirement, accepted };
}

function keyRequirementFor(baseUrl: string): EndpointPolicy["requirement"] {
  return endpointPolicyFor(baseUrl, false).requirement;
}

function normalizeAiConfig(raw: unknown): AiConfig {
  const defaults = createDefaultAiConfig();
  if (!isRecord(raw)) return defaults;

  const provider: AiProvider = AI_PROVIDERS.includes(raw.provider as AiProvider)
    ? (raw.provider as AiProvider)
    : DEFAULT_PROVIDER;
  const openaiModel = normalizedNullableString(raw.openaiModel);
  const model = modelForProvider(provider, { openaiModel });

  return {
    provider,
    apiKey: typeof raw.apiKey === "string" ? normalizeApiKey(raw.apiKey) : null,
    openaiApiKey: typeof raw.openaiApiKey === "string" ? normalizeApiKey(raw.openaiApiKey) : null,
    openaiBaseUrl:
      typeof raw.openaiBaseUrl === "string" && raw.openaiBaseUrl.trim().length > 0
        ? raw.openaiBaseUrl.trim()
        : DEFAULT_OPENAI_BASE_URL,
    openaiModel,
    model,
    serverUrl:
      typeof raw.serverUrl === "string" && raw.serverUrl.trim().length > 0
        ? raw.serverUrl
        : defaults.serverUrl,
    roundLimit:
      typeof raw.roundLimit === "number" && Number.isFinite(raw.roundLimit) && raw.roundLimit > 0
        ? raw.roundLimit
        : defaults.roundLimit,
    proxyToolTimeoutMs:
      typeof raw.proxyToolTimeoutMs === "number" &&
      Number.isFinite(raw.proxyToolTimeoutMs) &&
      raw.proxyToolTimeoutMs > 0
        ? raw.proxyToolTimeoutMs
        : defaults.proxyToolTimeoutMs,
  };
}

function assertNever(value: never): never {
  throw new Error(`Unhandled AI provider: ${String(value)}`);
}

export {
  AI_CHAT_SETTINGS_PLUGIN_ID,
  AI_CHAT_SECURE_KEYS,
  AI_PROVIDERS,
  DEFAULT_MODEL,
  DEFAULT_OPENAI_BASE_URL,
  DEFAULT_PROVIDER,
  DEFAULT_PROXY_TIMEOUT_MS,
  DEFAULT_ROUND_LIMIT,
  DEFAULT_SERVER_URL,
  assertNever,
  createDefaultAiConfig,
  endpointPolicyFor,
  keyRequirementFor,
  modelForProvider,
  normalizeApiKey,
  normalizeAiConfig,
};
export type { EndpointPolicy };
