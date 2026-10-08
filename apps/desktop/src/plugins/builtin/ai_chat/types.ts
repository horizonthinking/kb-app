import type { AI_PROVIDERS } from "./config";

type ChatMode = "ask" | "agent" | "inline";
type FinishReason = string;
type ChatSessionStatus = "idle" | "streaming" | "awaiting-approval" | "applying" | "error";
type AiProvider = (typeof AI_PROVIDERS)[number];

interface AiConfig {
  apiKey: string | null;
  openaiApiKey: string | null;
  openaiBaseUrl?: string | null;
  openaiModel?: string | null;
  model: string;
  provider?: AiProvider;
  serverUrl?: string | null;
  // Internal guardrails; not exposed in settings UI.
  roundLimit?: number;
  proxyToolTimeoutMs?: number;
}

interface AiSettingsDraft {
  provider: AiProvider;
  apiKey: string;
  openaiApiKey: string;
  openaiBaseUrl: string;
  openaiModel: string;
  serverUrl: string;
}

interface ChatFileAttachmentDraft {
  path: string;
  name: string;
  folder: string;
}

interface EmbeddedFileContext {
  path: string;
  content: string;
  checksum: string;
  sizeBytes: number;
}

interface EditorContext {
  activeFile: string | null;
  selectedText: string | null;
  embeddedFiles?: EmbeddedFileContext[];
  openTabs?: string[];
  cursorLine?: number | null;
}

interface ChatFileMessageAttachment {
  kind: "file";
  path: string;
  name: string;
  sizeBytes: number;
}

interface ChatSelectionMessageAttachment {
  kind: "selection";
  activeFile: string | null;
  sizeBytes: number;
}

type ChatMessageAttachment = ChatFileMessageAttachment | ChatSelectionMessageAttachment;

interface SendMessageOptions {
  includeSelectedText?: boolean;
}

interface StreamChunkPayload {
  sessionId: string;
  delta: string;
}

interface ToolCallStartPayload {
  sessionId: string;
  callId: string;
  toolName: string;
  toolId?: string;
  arguments: Record<string, unknown>;
}

interface ToolCallEndPayload {
  sessionId: string;
  callId: string;
  toolName: string;
  toolId?: string;
  output: string;
  isError: boolean;
}

interface PendingApprovalPayload {
  sessionId: string;
  callId: string;
  toolName: string;
  toolId?: string;
  mutation: Record<string, unknown>;
  previewText?: string;
}

interface DonePayload {
  sessionId: string;
  finishReason: FinishReason;
  usage?: TokenUsage;
}

interface ErrorPayload {
  sessionId: string;
  message: string;
}

interface TokenUsage {
  inputTokens: number;
  outputTokens: number;
  totalTokens: number;
  cachedInputTokens: number;
}

interface ToolDescriptor {
  name: string;
  toolId?: string;
  description: string;
  parameters: Record<string, unknown>;
  category: string;
  access?: "readOnly" | "proposesMutation";
  source?: "native" | "proxy";
}

interface ChatTextMessage {
  id: string;
  kind: "text";
  role: "user" | "assistant" | "system";
  content: string;
  attachments?: ChatMessageAttachment[];
  streaming?: boolean;
}

interface ChatToolMessage {
  id: string;
  kind: "tool";
  callId: string;
  toolName: string;
  toolId?: string;
  arguments: Record<string, unknown>;
  expanded: boolean;
  success?: boolean;
  output?: string;
  error?: string;
}

interface ChatApprovalMessage {
  id: string;
  kind: "approval";
  callId: string;
  toolName: string;
  toolId?: string;
  mutation: Record<string, unknown>;
  previewText?: string;
  expanded: boolean;
  status: "pending" | "approved" | "rejected" | "applied" | "conflict" | "error";
  error?: string;
}

type ChatMessage = ChatTextMessage | ChatToolMessage | ChatApprovalMessage;

interface ChatSessionState {
  id: string;
  mode: ChatMode;
  draft: string;
  fileAttachments: ChatFileAttachmentDraft[];
  messages: ChatMessage[];
  inflightAssistantId: string | null;
  autoApprove: boolean;
  status: ChatSessionStatus;
  error: string | null;
  finishReason: FinishReason | null;
}

interface ChatConfigState {
  apiKey: string;
  openaiApiKey: string;
  openaiBaseUrl: string;
  openaiModel: string;
  provider: AiProvider;
  serverUrl: string;
  model: string;
  settingsDraft: AiSettingsDraft;
  modelSuggestions: string[];
  modelsLoading: boolean;
  modelsError: string | null;
  rawConfig: Record<string, unknown>;
  loading: boolean;
  saving: boolean;
  error: string | null;
  toolsLoading: boolean;
  toolsError: string | null;
  availableTools: ToolDescriptor[];
}

interface ChatStoreState {
  selectedMode: ChatMode;
  activeSessionId: string | null;
  sessions: Record<string, ChatSessionState>;
  isCreatingSession: boolean;
  isSendingMessage: boolean;
  config: ChatConfigState;
}

interface NewSessionPayload {
  sessionId: string;
}

interface ChatSnapshotSource {
  snapshot(): EditorContext;
}

export type {
  AiConfig,
  AiProvider,
  AiSettingsDraft,
  ChatApprovalMessage,
  ChatConfigState,
  ChatFileAttachmentDraft,
  ChatFileMessageAttachment,
  ChatMessage,
  ChatMessageAttachment,
  ChatMode,
  ChatSessionState,
  ChatSnapshotSource,
  ChatStoreState,
  ChatTextMessage,
  ChatToolMessage,
  DonePayload,
  EmbeddedFileContext,
  EditorContext,
  ErrorPayload,
  FinishReason,
  ChatSessionStatus,
  NewSessionPayload,
  PendingApprovalPayload,
  SendMessageOptions,
  ToolDescriptor,
  StreamChunkPayload,
  TokenUsage,
  ToolCallEndPayload,
  ToolCallStartPayload,
};
