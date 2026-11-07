use std::collections::BTreeSet;

use serde::Deserialize;

use crate::{
    Algorithm, JevConfiguration, ModelTarget, Result, RoleGroup, RouteSettings, RoutingRole,
    built_in_roles,
};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacySetup {
    profile: LegacyProfile,
    #[serde(default)]
    discovered_models: Vec<LegacyModel>,
    #[serde(default)]
    binary_path_override: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacyModel {
    id: String,
    #[serde(default)]
    display_name: Option<String>,
    #[serde(default)]
    supports_images: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacyProfile {
    algorithm: Algorithm,
    provider: String,
    tiers: Vec<LegacyTier>,
    #[serde(default)]
    roles: Vec<RoutingRole>,
    #[serde(default)]
    additional_targets: Vec<LegacyTier>,
    #[serde(default, rename = "judgeModelID")]
    judge_model_id: Option<String>,
    #[serde(default, rename = "classifierTargetID")]
    classifier_target_id: Option<String>,
    #[serde(default, rename = "defaultTargetID")]
    default_target_id: Option<String>,
    #[serde(default)]
    native_route_options: String,
    #[serde(default)]
    judge_native_options: String,
    #[serde(default)]
    reviewer_system_prompt: String,
    #[serde(default)]
    classify_trigger: Option<String>,
    #[serde(default)]
    allows_long_context: Option<bool>,
    #[serde(default)]
    jev_classifier: Option<JevConfiguration>,
    #[serde(default, rename = "imageCapableModelIDs")]
    image_capable_model_ids: BTreeSet<String>,
    #[serde(default)]
    model_context_windows: std::collections::BTreeMap<String, u64>,
    #[serde(default)]
    advertises_reasoning_summaries: Option<bool>,
    #[serde(default)]
    host: Option<String>,
    #[serde(default)]
    port: Option<u16>,
    #[serde(default, rename = "routeID")]
    route_id: Option<String>,
    #[serde(default, rename = "upstreamBaseURL")]
    upstream_base_url: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacyTier {
    id: String,
    name: String,
    #[serde(default)]
    summary: String,
    #[serde(default, rename = "modelID")]
    model_id: String,
    #[serde(default)]
    target_key: Option<String>,
    #[serde(default, rename = "roleID")]
    role_id: Option<String>,
    #[serde(default)]
    native_options: String,
}

fn key(name: &str) -> String {
    let mut key = name
        .to_lowercase()
        .split(|character: char| !character.is_ascii_alphanumeric())
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join("_");
    if key.starts_with(|character: char| character.is_ascii_digit()) {
        key.insert(0, 't');
    }
    key.truncate(24);
    key
}

impl RouteSettings {
    pub fn import_setup(text: &str) -> Result<Self> {
        if text.len() > 2 * 1024 * 1024 {
            return Err("Setup import exceeds 2 MiB.".into());
        }
        if let Ok(settings) = serde_json::from_str::<Self>(text) {
            settings.validate()?;
            return Ok(settings);
        }
        let setup: LegacySetup = serde_json::from_str(text).map_err(|_| "Expected an exported cross-platform setup or legacy saved-routing-setup.json. No files were changed.".to_string())?;
        let profile = setup.profile;
        let discovered_models = setup
            .discovered_models
            .into_iter()
            .map(|model| crate::AvailableModel {
                context_window: profile.model_context_windows.get(&model.id).copied(),
                display_name: model.display_name.unwrap_or_else(|| model.id.clone()),
                id: model.id,
                supports_images: model.supports_images,
                efforts: vec![],
            })
            .collect();
        if profile.provider != "codex"
            || profile
                .host
                .as_deref()
                .is_some_and(|host| !["127.0.0.1", "localhost", "::1"].contains(&host))
            || profile.port.is_some_and(|port| port != 4100)
            || profile
                .route_id
                .as_deref()
                .is_some_and(|id| id != "switchyard-desktop")
            || profile
                .upstream_base_url
                .as_deref()
                .is_some_and(|url| url != "http://127.0.0.1:4101/v1")
        {
            return Err("This setup uses a nonstandard provider, listener, route ID or upstream. Import refused rather than silently changing it.".into());
        }

        let mut roles = if profile.roles.is_empty() {
            built_in_roles()
        } else {
            profile.roles
        };
        let role_groups = roles
            .iter()
            .flat_map(|role| role.group_ids.iter().cloned())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .map(|id| RoleGroup {
                name: format!("Imported group {id}"),
                id,
                project_path: String::new(),
                routing_profile: None,
            })
            .collect();
        let classifier_role_id = roles
            .iter()
            .find(|role| role.kind == "classifier")
            .map(|role| role.id.clone())
            .unwrap_or_else(|| built_in_roles()[0].id.clone());
        if !roles.iter().any(|role| role.kind == "classifier") {
            roles.push(built_in_roles().remove(0));
        }
        let mut explicit_keys = BTreeSet::new();
        for target in profile
            .tiers
            .iter()
            .chain(profile.additional_targets.iter())
        {
            if let Some(key) = &target.target_key {
                if ["any", "judge"].contains(&key.as_str()) || !explicit_keys.insert(key) {
                    return Err("Imported native target keys are duplicated or reserved; refusing to rename policy references.".into());
                }
            }
        }
        let mut used = BTreeSet::from(["any".to_string(), "judge".to_string()]);
        let mut identity = std::collections::BTreeMap::new();
        let fixed = matches!(
            profile.algorithm,
            Algorithm::Auto
                | Algorithm::StageRouter
                | Algorithm::Capability
                | Algorithm::Escalation
                | Algorithm::Composite
                | Algorithm::PlanExecute
                | Algorithm::Vgr
        );
        let mut convert = |tier: LegacyTier, index: usize, main: bool| -> ModelTarget {
            let seed = tier.target_key.unwrap_or_else(|| {
                if fixed && main {
                    if index == 0 {
                        "efficient".into()
                    } else {
                        "capable".into()
                    }
                } else {
                    key(&tier.name)
                }
            });
            let seed = if seed.is_empty() {
                if main {
                    format!("tier{}", index + 1)
                } else {
                    format!("extra{}", index + 1)
                }
            } else {
                seed
            };
            let mut name = seed.clone();
            let mut suffix = 2;
            while !used.insert(name.clone()) {
                name = format!("{seed}{suffix}");
                suffix += 1;
            }
            identity.insert(tier.id.clone(), name.clone());
            let role_id = if let Some(id) = tier.role_id {
                Some(id)
            } else if !tier.summary.trim().is_empty() {
                roles.push(RoutingRole {
                    id: tier.id.clone(),
                    kind: "target".into(),
                    name: tier.name,
                    text: tier.summary,
                    system_prompt: None,
                    effort: None,
                    tags: vec![],
                    group_ids: vec![],
                    is_built_in: false,
                });
                Some(tier.id)
            } else {
                None
            };
            ModelTarget {
                key: name,
                model: tier.model_id,
                role_id,
                native_options: tier.native_options,
            }
        };
        let mut targets = profile
            .tiers
            .into_iter()
            .enumerate()
            .map(|(index, tier)| convert(tier, index, true))
            .collect::<Vec<_>>();
        let mut additional_targets = profile
            .additional_targets
            .into_iter()
            .enumerate()
            .map(|(index, tier)| convert(tier, index, false))
            .collect::<Vec<_>>();
        let judge_model = profile.judge_model_id.unwrap_or_default();
        let mut judge_target = if judge_model.is_empty() {
            profile
                .classifier_target_id
                .as_ref()
                .and_then(|id| identity.get(id))
                .cloned()
        } else {
            None
        };
        if profile.algorithm == Algorithm::Advisor && targets.len() == 2 {
            let advisor = targets.pop().unwrap();
            if judge_model.is_empty() {
                judge_target = Some(advisor.key.clone());
            }
            additional_targets.push(advisor);
        }
        let assigned = targets
            .iter()
            .chain(additional_targets.iter())
            .collect::<Vec<_>>();
        let vision = !assigned.is_empty()
            && assigned
                .iter()
                .all(|target| profile.image_capable_model_ids.contains(&target.model));
        let windows = assigned
            .iter()
            .map(|target| profile.model_context_windows.get(&target.model).copied())
            .collect::<Option<Vec<_>>>();
        let context_window = windows.and_then(|windows| windows.into_iter().min());
        let settings = Self {
            algorithm: profile.algorithm,
            discovered_models,
            codex_executable: setup.binary_path_override,
            jev_classifier: profile.jev_classifier,
            checkpoint: if profile.algorithm == Algorithm::PrefillRouter {
                "/path/to/router.pt".into()
            } else {
                String::new()
            },
            efficient_model: targets
                .first()
                .map(|target| target.model.clone())
                .unwrap_or_default(),
            capable_model: targets
                .get(1)
                .map(|target| target.model.clone())
                .unwrap_or_default(),
            targets,
            additional_targets,
            roles,
            role_groups,
            classifier_role_id,
            judge_model,
            judge_target,
            judge_options: profile.judge_native_options,
            native_route_options: profile.native_route_options,
            reviewer_system_prompt: profile.reviewer_system_prompt,
            classify_trigger: profile.classify_trigger.unwrap_or_else(|| {
                if profile.algorithm == Algorithm::Composite {
                    "user_turn".into()
                } else {
                    "every_request".into()
                }
            }),
            default_target: profile
                .default_target_id
                .as_ref()
                .and_then(|id| identity.get(id))
                .cloned()
                .unwrap_or_default(),
            allows_long_context: profile.allows_long_context.unwrap_or(true),
            context_window,
            vision,
            reasoning_summaries: profile.advertises_reasoning_summaries.unwrap_or(true),
            ..Default::default()
        };
        settings.validate()?;
        Ok(settings)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_custom_setup_preserves_target_keys_and_policy() {
        let settings = RouteSettings::import_setup(r#"{"profile":{"provider":"codex","algorithm":"llm_classifier","tiers":[
            {"id":"a","name":"Fast","summary":"Small fixes","modelID":"small","targetKey":"quick"},
            {"id":"b","name":"Deep","summary":"Deep investigation","modelID":"large","targetKey":"deep"}],
            "classifierTargetID":"a","defaultTargetID":"b","classifyTrigger":"user_turn"}}"#).unwrap();
        let preview = settings.preview().unwrap();
        let document: toml::Value = toml::from_str(&preview.switchyard).unwrap();
        assert_eq!(
            document["routes"]["main"]["default_target"].as_str(),
            Some("deep")
        );
        assert_eq!(
            document["routes"]["main"]["models"]["judge"][0].as_str(),
            Some("quick")
        );
        assert!(
            document["routes"]["main"]["prompt"]
                .as_str()
                .unwrap()
                .contains("Deep investigation")
        );
    }

    #[test]
    fn import_rejects_unsupported_integrations_instead_of_silently_dropping_them() {
        for extra in [
            r#", "port":4000"#,
            r#", "jevClassifier":{"modelID":"jev-latest","cutoff":0.6,"instructions":""}"#,
        ] {
            let text = format!(
                r#"{{"profile":{{"algorithm":"noop","provider":"codex","tiers":[]{extra}}}}}"#
            );
            assert!(RouteSettings::import_setup(&text).is_err());
        }
    }
}
