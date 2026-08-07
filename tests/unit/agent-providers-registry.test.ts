import { describe, expect, it } from "vitest";

import { anthropicSdkBaseUrl, createDefaultRegistry } from "@/lib/agent-engine/edge/llm/providers";

describe("createDefaultRegistry", () => {
  it("adapta a URL documental da MiniMax ao baseURL esperado pelo AI SDK", () => {
    expect(anthropicSdkBaseUrl("https://api.minimax.io/anthropic")).toBe(
      "https://api.minimax.io/anthropic/v1",
    );
    expect(anthropicSdkBaseUrl("https://api.minimax.io/anthropic/v1/")).toBe(
      "https://api.minimax.io/anthropic/v1",
    );
  });

  it("registra os três providers do lançamento multimodal", () => {
    const reg = createDefaultRegistry();
    expect(Object.keys(reg).sort()).toEqual(["anthropic", "google", "openai"]);
  });
  it("cada factory produz um LanguageModel (não lança ao instanciar)", () => {
    const reg = createDefaultRegistry();
    expect(() => reg.anthropic!("k", "claude-sonnet-4-6")).not.toThrow();
    expect(() => reg.openai!("k", "gpt-5")).not.toThrow();
    expect(() => reg.google!("k", "gemini-2.5-pro")).not.toThrow();
  });
});
