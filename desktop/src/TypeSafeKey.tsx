import { useEffect, useRef, useState } from "react";
import { api, native } from "./api";

export function TypeSafeKey({ disabled }: { disabled: boolean }) {
  const [key, setKey] = useState("");
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const operation = useRef(false);
  useEffect(() => {
    if (!native) return;
    let active = true;
    api.typesafeKeyStatus().then((saved) => { if (active) setMessage(saved ? "A TypeSafe key is saved in the system credential vault." : "No TypeSafe key saved."); }).catch((reason) => { if (active) setError(String(reason)); });
    return () => { active = false; };
  }, []);
  async function save(value: string) {
    if (operation.current) return;
    operation.current = true; setBusy(true); setError("");
    try {
      await api.saveTypesafeKey(value);
      setKey(""); setMessage(value ? "Key saved in the system credential vault." : "Key removed from the system credential vault.");
    } catch (reason) { setError(String(reason)); }
    finally { operation.current = false; setBusy(false); }
  }
  return <fieldset disabled={!native || disabled || busy} className="credential-editor"><legend>TypeSafe credential</legend>
    <p>Stored in macOS Keychain or Windows Credential Manager, not in setup files. Jev sends classification requests to api.typesafe.ai. ChatGPT credentials are not sent to TypeSafe.</p>
    <label>TypeSafe API key<input type="password" autoComplete="off" value={key} onChange={(event) => setKey(event.target.value)} /></label>
    <div className="role-toolbar"><button className="button secondary" disabled={!key.trim()} onClick={() => void save(key)}>Save API key</button><button className="text-button" onClick={() => void save("")}>Remove API key</button></div>
    {message && <p role="status">{message}</p>}{error && <p className="editor-warning" role="alert">{error}</p>}
  </fieldset>;
}
