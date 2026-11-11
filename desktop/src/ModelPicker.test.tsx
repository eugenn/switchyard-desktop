// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import { useState } from "react";
import { afterEach, expect, it } from "vitest";
import { setProviderModels } from "./modelCatalog";
import { ModelPicker } from "./ModelPicker";

function Field({ provider }: { provider: "openai" | "anthropic" }) {
  const [value, setValue] = useState("");
  return <ModelPicker provider={provider} label="Model" value={value} onChange={setValue} />;
}

afterEach(() => { cleanup(); setProviderModels("openai", []); setProviderModels("anthropic", []); });

it("groups every account model by provider and names each model once", () => {
  setProviderModels("openai", [{ id: "gpt-test-sol", name: "GPT-Test Sol" }]);
  setProviderModels("anthropic", [{ id: "claude-test-large", name: "Large" }]);
  render(<Field provider="openai" />);
  const input = screen.getByRole("combobox", { name: "Model" });
  expect(screen.queryByRole("listbox")).toBeNull();
  fireEvent.click(input);
  const groups = screen.getAllByRole("group");
  expect(groups.map((group) => group.getAttribute("aria-label"))).toEqual(["OpenAI", "Anthropic"]);
  // A display name that only restyles the ID is not repeated beside it.
  expect(within(groups[0]).getByRole("option").textContent).toBe("gpt-test-sol");
  expect(within(groups[1]).getByRole("option").textContent).toBe("Largeclaude-test-large");
  // Another provider's model is listed but cannot be put into this field.
  fireEvent.mouseDown(within(groups[1]).getByRole("option"));
  expect(input).toHaveProperty("value", "");
  fireEvent.mouseDown(within(groups[0]).getByRole("option"));
  expect(input).toHaveProperty("value", "gpt-test-sol");
  expect(screen.queryByRole("listbox")).toBeNull();
});

it("filters while typing, picks with the keyboard and still accepts unlisted IDs", () => {
  setProviderModels("anthropic", [{ id: "claude-test-large", name: "Large" }, { id: "claude-test-small", name: "Small" }]);
  render(<Field provider="anthropic" />);
  const input = screen.getByRole("combobox", { name: "Model" });
  fireEvent.change(input, { target: { value: "sma" } });
  expect(screen.getAllByRole("option").map((option) => option.textContent)).toEqual(["Smallclaude-test-small"]);
  fireEvent.keyDown(input, { key: "ArrowDown" });
  fireEvent.keyDown(input, { key: "Enter" });
  expect(input).toHaveProperty("value", "claude-test-small");
  fireEvent.click(input);
  expect(screen.getAllByRole("option")).toHaveLength(2);
  fireEvent.change(input, { target: { value: "claude-unlisted" } });
  expect(screen.queryByRole("listbox")).toBeNull();
  expect(input).toHaveProperty("value", "claude-unlisted");
});
