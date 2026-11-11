use serde::Serialize;
use switchyard_desktop_core::{
    ClaudeSettings, ConfigurationPreview, DesktopSession, LoginStatus, RouteSettings,
    RuntimeLayout, RuntimeStatus, SessionStatus, UserDataLocations,
};
use tauri::{Manager, State};
use tokio::sync::Mutex;

struct DesktopState {
    locations: UserDataLocations,
    runtime: RuntimeLayout,
    session: Mutex<DesktopSession>,
}

#[tauri::command]
fn claude_settings(state: State<'_, DesktopState>) -> Result<ClaudeSettings, String> {
    ClaudeSettings::load(&state.locations)
}

#[tauri::command]
fn save_claude_settings(
    settings: ClaudeSettings,
    state: State<'_, DesktopState>,
) -> Result<(), String> {
    settings.save(&state.locations)
}

#[tauri::command]
async fn claude_launch_command(
    settings: ClaudeSettings,
    state: State<'_, DesktopState>,
) -> Result<String, String> {
    let port = state.session.lock().await.router_port();
    settings.launch_command(port)
}

#[tauri::command]
async fn anthropic_key_status(state: State<'_, DesktopState>) -> Result<bool, String> {
    state.session.lock().await.has_anthropic_key()
}

#[tauri::command]
async fn save_anthropic_key(key: String, state: State<'_, DesktopState>) -> Result<(), String> {
    state.session.lock().await.set_anthropic_key(&key)
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
            app.manage(DesktopState {
                locations,
                runtime,
                session: Mutex::new(session),
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            bootstrap,
            claude_settings,
            save_claude_settings,
            claude_launch_command,
            anthropic_key_status,
            save_anthropic_key,
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
                    state.session.lock().await.stop();
                });
            }
        });
}
