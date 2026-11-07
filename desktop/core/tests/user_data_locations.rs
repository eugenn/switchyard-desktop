use switchyard_desktop_core::UserDataLocations;

#[test]
fn integration_test_defaults_are_sandboxed_even_when_the_library_is_not_cfg_test() {
    let locations = UserDataLocations::current().unwrap();
    assert!(locations.root().starts_with(std::env::temp_dir()));
    assert_eq!(locations.codex_home(), locations.root().join("codex"));
    assert_eq!(locations.claude_home(), locations.root().join("claude"));
    assert_eq!(locations.user_home(), locations.root().join("home"));
    assert!(
        locations
            .root()
            .to_string_lossy()
            .contains(&format!("SwitchyardDesktopTests-{}", std::process::id()))
    );
}
