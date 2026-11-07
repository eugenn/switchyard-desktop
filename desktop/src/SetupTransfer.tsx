import { useRef, useState } from "react";
import { api, native, type RouteSettings } from "./api";

export function SetupTransfer({ settings, disabled, onImport }: { settings: RouteSettings; disabled: boolean; onImport: (settings: RouteSettings) => void }) {
  const [text, setText] = useState("");
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const [working, setWorking] = useState(false);
  const operation = useRef(false);
  async function importSetup() {
    if (operation.current) return;
    operation.current = true; setWorking(true); setError(""); setMessage("");
    try {
      const imported = await api.importSetup(text);
      onImport(imported);
      setMessage("Imported as an unsaved draft. Review configuration, then Save settings. Existing files and accounts are unchanged.");
    } catch (reason) { setError(String(reason)); }
    finally { operation.current = false; setWorking(false); }
  }
  function exportSetup() {
    const url = URL.createObjectURL(new Blob([JSON.stringify(settings, null, 2)], { type: "application/json" }));
    const link = document.createElement("a");
    link.href = url; link.download = "switchyard-routing-setup.json"; link.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    setMessage("Exported routing settings and role prompts. Credentials and request history are never included. Treat custom prompts as private content.");
  }
  return <section className="panel transfer-panel"><details><summary>Import / export routing setup</summary><p>Paste an exported setup or the contents of a legacy saved-routing-setup.json. Import is explicit and creates a draft only. No account, token, Codex file or running service is imported.</p>
    <fieldset disabled={disabled || working}><legend className="sr-only">Setup transfer</legend>
      <label>Setup JSON<textarea value={text} onChange={(event) => setText(event.target.value)} spellCheck={false} /></label>
      <div className="role-toolbar"><button className="button secondary" disabled={!native || !text.trim()} onClick={() => void importSetup()}>{working ? "Checking setup..." : "Import as draft"}</button><button className="button secondary" onClick={exportSetup}>Export setup</button></div>
    </fieldset>{message && <p role="status">{message}</p>}{error && <p className="editor-warning" role="alert">{error}</p>}</details></section>;
}
