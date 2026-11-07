use serde::Serialize;
use switchyard_desktop_core::{
    ClaudeIntegration, ClaudeSettings, ClaudeStatus, ConfigurationPreview, DesktopSession,
    LoginStatus, PreparedClaudePlugin, RouteSettings, RuntimeLayout, RuntimeStatus, SessionStatus,
    UserDataLocations,
};
use tauri::{Manager, State};
use tokio::sync::Mutex;

struct DesktopState {
    locations: UserDataLocations,
    runtime: RuntimeLayout,
    session: Mutex<DesktopSession>,
    claude: Mutex<ClaudeIntegration>,
}

#[tauri::command]
async fn claude_settings(state: State<'_, DesktopState>) -> Result<ClaudeSettings, String> {
    state.claude.lock().await.settings()
}

#[tauri::command]
async fn claude_status(
    settings: ClaudeSettings,
    state: State<'_, DesktopState>,
) -> Result<ClaudeStatus, String> {
    state.claude.lock().await.status(&settings).await
}

#[tauri::command]
async fn claude_login(
    settings: ClaudeSettings,
    state: State<'_, DesktopState>,
) -> Result<ClaudeStatus, String> {
    state.claude.lock().await.begin_login(&settings)
}

#[tauri::command]
async fn claude_cancel_login(state: State<'_, DesktopState>) -> Result<ClaudeStatus, String> {
    Ok(state.claude.lock().await.cancel_login())
}

#[tauri::command]
async fn prepare_claude(
    settings: ClaudeSettings,
    state: State<'_, DesktopState>,
) -> Result<PreparedClaudePlugin, String> {
    state.claude.lock().await.prepare(&settings).await
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Bootstrap {
    settings: RouteSettings,
    runtime: RuntimeStatus,
    session: SessionStatus,
    login: LoginStatus,
}

#[tauri::command]
async fn bootstrap(state: State<'_, DesktopState>) -> Result<Bootstrap, String> {
    let mut session = state.session.lock().await;
    Ok(Bootstrap {
        settings: state.locations.read_settings()?,
        runtime: state.runtime.status(),
        login: session.login_status()?,
        session: session.status(),
    })
}

#[tauri::command]
fn preview_configuration(settings: RouteSettings) -> Result<ConfigurationPreview, String> {
    settings.preview()
}

#[tauri::command]
fn save_settings(settings: RouteSettings, state: State<'_, DesktopState>) -> Result<(), String> {
    state.locations.save_settings(&settings)
}

#[tauri::command]
fn save_role_library(
    roles: Vec<switchyard_desktop_core::RoutingRole>,
    groups: Vec<switchyard_desktop_core::RoleGroup>,
    state: State<'_, DesktopState>,
) -> Result<(), String> {
    state.locations.save_role_library(roles, groups)
}

#[tauri::command]
async fn start_routing(
    settings: RouteSettings,
    state: State<'_, DesktopState>,
) -> Result<SessionStatus, String> {
    state.session.lock().await.start(&settings).await
}

#[tauri::command]
async fn stop_routing(state: State<'_, DesktopState>) -> Result<SessionStatus, String> {
    Ok(state.session.lock().await.stop())
}

#[tauri::command]
async fn session_status(state: State<'_, DesktopState>) -> Result<SessionStatus, String> {
    Ok(state.session.lock().await.status())
}

#[tauri::command]
async fn typesafe_key_status(state: State<'_, DesktopState>) -> Result<bool, String> {
    state.session.lock().await.has_typesafe_key()
}

#[tauri::command]
async fn save_typesafe_key(key: String, state: State<'_, DesktopState>) -> Result<(), String> {
    state.session.lock().await.set_typesafe_key(&key)
}

#[tauri::command]
async fn begin_login(state: State<'_, DesktopState>) -> Result<LoginStatus, String> {
    state.session.lock().await.begin_login()
}

#[tauri::command]
async fn login_status(state: State<'_, DesktopState>) -> Result<LoginStatus, String> {
    state.session.lock().await.login_status()
}

#[tauri::command]
async fn cancel_login(state: State<'_, DesktopState>) -> Result<LoginStatus, String> {
    Ok(state.session.lock().await.cancel_login())
}

#[tauri::command]
async fn read_stats(state: State<'_, DesktopState>) -> Result<serde_json::Value, String> {
    state.session.lock().await.stats().await
}

#[tauri::command]
async fn model_prices(
    refresh: Option<bool>,
    state: State<'_, DesktopState>,
) -> Result<switchyard_desktop_core::ModelPrices, String> {
    let reader = switchyard_desktop_core::ModelPriceReader::new(
        state.runtime.clone(),
        state.locations.clone(),
    );
    if refresh.unwrap_or(false) {
        reader.refresh_prices().await
    } else {
        reader.local_prices()
    }
}

#[tauri::command]
fn rollout_session_ids(session_ids: Vec<String>, state: State<'_, DesktopState>) -> Vec<String> {
    state.locations.rollout_session_ids(&session_ids)
}

#[tauri::command]
fn routing_history(state: State<'_, DesktopState>) -> Result<Vec<serde_json::Value>, String> {
    state.locations.routing_history()
}

#[tauri::command]
fn import_setup(text: String) -> Result<RouteSettings, String> {
    RouteSettings::import_setup(&text)
}

#[tauri::command]
async fn discover_models(
    executable: String,
    state: State<'_, DesktopState>,
) -> Result<Vec<switchyard_desktop_core::AvailableModel>, String> {
    switchyard_desktop_core::discover_models(&state.locations, &executable).await
}

fn main() {
    tauri::Builder::default()
        .setup(|app| {
            let locations = UserDataLocations::current().map_err(std::io::Error::other)?;
            #[cfg(debug_assertions)]
            let runtime_root = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("runtime");
            #[cfg(not(debug_assertions))]
            let runtime_root = app.path().resource_dir()?.join("runtime");
            let runtime = RuntimeLayout::bundled(runtime_root);
            let session = DesktopSession::new(locations.clone(), runtime.clone())
                .map_err(std::io::Error::other)?;
            let claude = ClaudeIntegration::new(locations.clone(), runtime.clone());
            app.manage(DesktopState {
                locations,
                runtime,
                session: Mutex::new(session),
                claude: Mutex::new(claude),
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            bootstrap,
            claude_settings,
            claude_status,
            claude_login,
            claude_cancel_login,
            prepare_claude,
            preview_configuration,
            save_settings,
            save_role_library,
            start_routing,
            stop_routing,
            session_status,
            read_stats,
            routing_history,
            model_prices,
            rollout_session_ids,
            import_setup,
            discover_models,
            typesafe_key_status,
            save_typesafe_key,
            begin_login,
            login_status,
            cancel_login
        ])
        .build(tauri::generate_context!())
        .expect("Could not initialize Switchyard desktop")
        .run(|app, event| {
            if matches!(event, tauri::RunEvent::Exit) {
                let state = app.state::<DesktopState>();
                tauri::async_runtime::block_on(async {
                    state.claude.lock().await.cancel_login();
                    state.session.lock().await.stop();
                });
            }
        });
}
