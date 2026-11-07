use switchyard_desktop_core::{Algorithm, RouteSettings};

fn main() {
    let directory = std::path::PathBuf::from(
        std::env::args_os()
            .nth(1)
            .expect("Pass an explicit output directory"),
    );
    std::fs::create_dir_all(&directory).unwrap();
    for algorithm in Algorithm::ALL {
        let settings = RouteSettings {
            algorithm,
            efficient_model: "test-small".into(),
            capable_model: "test-large".into(),
            judge_model: "test-judge".into(),
            efficient_role_id: Some("0D000000-0000-0000-0000-000000000001".into()),
            capable_role_id: Some("0D000000-0000-0000-0000-000000000002".into()),
            checkpoint: "/nonexistent/router.pt".into(),
            classify_trigger: if algorithm == Algorithm::Composite {
                "user_turn".into()
            } else {
                "every_request".into()
            },
            ..Default::default()
        };
        let name = serde_json::to_value(algorithm)
            .unwrap()
            .as_str()
            .unwrap()
            .to_owned();
        let preview = settings.preview().unwrap();
        std::fs::write(directory.join(format!("{name}.toml")), preview.switchyard).unwrap();
    }
}
