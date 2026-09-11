function shortModelLabel(modelId: string): string {
  if (!modelId) return "—";
  if (modelId.includes("gemini-3.1-flash-lite")) return "Gemini 3.1 Flash Lite";
  if (modelId.includes("gemini-3.1-flash")) return "Gemini 3.1 Flash";
  if (modelId.includes("flash")) return "Gemini Flash";
  if (modelId.includes("pro")) return "Gemini Pro";
  return modelId;
}

export { shortModelLabel };
