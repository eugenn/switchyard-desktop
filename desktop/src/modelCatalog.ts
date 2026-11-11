import { useSyncExternalStore } from "react";

/** Models the signed-in accounts offer, kept per provider so pickers can group them. */
export type ModelProvider = "openai" | "anthropic";
export interface CatalogModel { id: string; name: string }
export const modelProviders: { id: ModelProvider; title: string; account: string; usedBy: string }[] = [
  { id: "openai", title: "OpenAI", account: "Codex account", usedBy: "Codex route only" },
  { id: "anthropic", title: "Anthropic", account: "Anthropic API key", usedBy: "Claude Code route only" },
];

let catalog: Record<ModelProvider, CatalogModel[]> = { openai: [], anthropic: [] };
const listeners = new Set<() => void>();

export function setProviderModels(provider: ModelProvider, models: CatalogModel[]) {
  const known = catalog[provider];
  if (known.length === models.length && known.every((model, index) => model.id === models[index].id && model.name === models[index].name)) return;
  catalog = { ...catalog, [provider]: models };
  listeners.forEach((listener) => listener());
}

export function useModelCatalog() {
  return useSyncExternalStore((listener) => { listeners.add(listener); return () => { listeners.delete(listener); }; }, () => catalog);
}
