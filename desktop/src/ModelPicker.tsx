import { useId, useState } from "react";
import { modelProviders, useModelCatalog, type CatalogModel, type ModelProvider } from "./modelCatalog";

/** A display name that only restyles the ID ("GPT-6.1 Sol" for gpt-6.1-sol) adds nothing next to it. */
const repeatsId = (model: CatalogModel) => model.name.trim().toLowerCase().replace(/\s+/g, "-") === model.id.toLowerCase();

/**
 * Free-text model ID field that suggests every model the signed-in accounts
 * offer, grouped by provider. Only `provider`'s models can serve this field;
 * the other groups are listed for reference and cannot be picked.
 */
export function ModelPicker({ value, onChange, provider, label, invalid, placeholder }: {
  value: string; onChange: (value: string) => void; provider: ModelProvider; label: string; invalid?: boolean; placeholder?: string;
}) {
  const catalog = useModelCatalog();
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(-1);
  const menu = useId();
  const query = value.trim().toLowerCase();
  // A field that already holds a listed model shows the whole list, so another one can be chosen.
  const filtering = !!query && !modelProviders.some((item) => catalog[item.id].some((model) => model.id === value));
  const groups = [...modelProviders].sort((a, b) => Number(b.id === provider) - Number(a.id === provider))
    .map((item) => ({ ...item, models: catalog[item.id].filter((model) => !filtering || model.id.toLowerCase().includes(query) || model.name.toLowerCase().includes(query)) }))
    .filter((group) => group.models.length > 0);
  const choices = groups.filter((group) => group.id === provider).flatMap((group) => group.models);
  const shown = open && groups.length > 0;
  function pick(model: CatalogModel) { onChange(model.id); setOpen(false); setActive(-1); }

  return <div className="model-picker">
    <input role="combobox" aria-label={label} aria-invalid={invalid} aria-expanded={shown} aria-controls={menu} aria-autocomplete="list"
      aria-activedescendant={shown && active >= 0 ? `${menu}-${choices[active]?.id}` : undefined}
      autoComplete="off" spellCheck={false} placeholder={placeholder} value={value}
      onChange={(event) => { onChange(event.target.value); setOpen(true); setActive(-1); }}
      onClick={() => setOpen(true)} onBlur={() => { setOpen(false); setActive(-1); }}
      onKeyDown={(event) => {
        if (event.key === "ArrowDown" || event.key === "ArrowUp") {
          event.preventDefault();
          if (!shown) { setOpen(true); return; }
          if (choices.length) setActive((current) => (current + (event.key === "ArrowDown" ? 1 : choices.length - (current < 0 ? 0 : 1))) % choices.length);
        } else if (event.key === "Enter" && shown && choices[active]) { event.preventDefault(); pick(choices[active]); }
        else if (event.key === "Escape" && shown) { event.stopPropagation(); setOpen(false); setActive(-1); }
      }} />
    {shown && <div id={menu} className="model-menu" role="listbox" aria-label={`${label} suggestions`}>
      {groups.map((group) => {
        const usable = group.id === provider;
        return <div key={group.id} role="group" aria-label={group.title} className={`model-group${usable ? "" : " elsewhere"}`}>
          <div className="model-group-title"><strong>{group.title}</strong><span>{group.account}{!usable && ` · ${group.usedBy}`}</span></div>
          {group.models.map((model) => <div key={model.id} id={`${menu}-${model.id}`} role="option" aria-selected={model.id === value} aria-disabled={!usable}
            className={`model-option${usable && choices[active]?.id === model.id ? " active" : ""}`}
            onMouseDown={(event) => { event.preventDefault(); if (usable) pick(model); }}>
            {repeatsId(model) ? <code>{model.id}</code> : <><span>{model.name}</span><code>{model.id}</code></>}
          </div>)}
        </div>;
      })}
    </div>}
  </div>;
}
