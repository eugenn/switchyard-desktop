use std::path::Path;
use switchyard_desktop_core::RouteSettings;

#[test]
fn legacy_setup_exports_preserve_configuration() {
    let directory = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/legacy-setups");
    let roles: Vec<switchyard_desktop_core::RoutingRole> =
        serde_json::from_str(&std::fs::read_to_string(directory.join("roles.json")).unwrap())
            .unwrap();
    assert_eq!(roles, switchyard_desktop_core::built_in_roles());
    let mut count = 0;
    for entry in std::fs::read_dir(&directory).unwrap() {
        let file = entry.unwrap().path();
        if file.extension().and_then(|extension| extension.to_str()) != Some("json")
            || file.file_name().unwrap() == "roles.json"
        {
            continue;
        }
        let text = std::fs::read_to_string(&file).unwrap();
        let settings = RouteSettings::import_setup(&text)
            .unwrap_or_else(|error| panic!("{}: {error}", file.display()));
        let preview = settings.preview().unwrap();
        let before: toml::Value =
            toml::from_str(&std::fs::read_to_string(file.with_extension("toml")).unwrap()).unwrap();
        let after: toml::Value = toml::from_str(&preview.switchyard).unwrap();
        let before_route = before["routes"]["main"].as_table().unwrap();
        let after_route = after["routes"]["main"].as_table().unwrap();
        for field in ["id", "type", "context_window", "vision"] {
            assert_eq!(
                before_route.get(field),
                after_route.get(field),
                "{} route {field}",
                file.display()
            );
        }
        if settings.jev_classifier.is_some() {
            assert_eq!(before_route, after_route, "{} Jev policy", file.display());
            assert_eq!(
                before.get("decision_clients"),
                after.get("decision_clients")
            );
            assert_eq!(
                before.get("decision_targets"),
                after.get("decision_targets")
            );
        }
        if file
            .file_stem()
            .unwrap()
            .to_string_lossy()
            .ends_with("-native")
        {
            assert_eq!(
                before_route,
                after_route,
                "{} complete native policy",
                file.display()
            );
        }
        for (key, target) in before["targets"].as_table().unwrap() {
            if key == "judge" {
                continue;
            }
            for field in ["id", "system_prompt", "reasoning_effort"] {
                assert_eq!(
                    target.get(field),
                    after["targets"][key].get(field),
                    "{} target {key}.{field}",
                    file.display()
                );
            }
        }
        if settings.jev_classifier.is_none() {
            assert!(
                preview
                    .codex
                    .contains(r#"model_reasoning_summary = "none""#)
            );
        }
        let encoded = serde_json::to_string(&settings).unwrap();
        assert_eq!(RouteSettings::import_setup(&encoded).unwrap(), settings);
        count += 1;
    }
    assert_eq!(count, 29);
}
