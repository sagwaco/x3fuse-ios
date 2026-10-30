//! C ABI checks. Set X3F_FIXTURE to an X3F file to run the RAW tests.
use std::{
    ffi::{c_char, CStr, CString},
    path::PathBuf,
    ptr,
    sync::atomic::AtomicBool,
};
use x3fuse_engine::*;

fn take_error(error: *mut c_char) -> String {
    assert!(!error.is_null(), "a failure must return an owned error");
    let message = unsafe { CStr::from_ptr(error) }
        .to_string_lossy()
        .into_owned();
    unsafe { x3f_string_free(error) };
    message
}

#[test]
fn null_arguments_return_invalid_with_an_owned_error() {
    unsafe {
        let mut error = ptr::null_mut();
        let mut session = ptr::null_mut();
        assert_eq!(
            x3f_session_open(ptr::null(), ptr::null(), &mut session, &mut error),
            X3F_ERR_INVALID
        );
        assert!(session.is_null());
        assert!(take_error(error).contains("path"));

        let path = CString::new("/nonexistent").unwrap();
        let mut error = ptr::null_mut();
        assert_eq!(
            x3f_session_open(path.as_ptr(), ptr::null(), ptr::null_mut(), &mut error),
            X3F_ERR_INVALID
        );
        take_error(error);

        let mut error = ptr::null_mut();
        let mut json = ptr::null_mut();
        assert_eq!(
            x3f_session_info(ptr::null_mut(), &mut json, &mut error),
            X3F_ERR_INVALID
        );
        assert!(json.is_null());
        take_error(error);

        let recipe = CString::new("{}").unwrap();
        let mut frame = std::mem::zeroed::<X3fFrame>();
        let mut error = ptr::null_mut();
        assert_eq!(
            x3f_session_render(
                ptr::null_mut(),
                recipe.as_ptr(),
                512,
                ptr::null(),
                &mut frame,
                &mut error
            ),
            X3F_ERR_INVALID
        );
        take_error(error);
        // A NULL error pointer is allowed.
        assert_eq!(
            x3f_session_export_jpeg(
                ptr::null_mut(),
                recipe.as_ptr(),
                ptr::null(),
                90,
                false,
                ptr::null(),
                ptr::null_mut()
            ),
            X3F_ERR_INVALID
        );

        x3f_frame_free(&mut frame);
        x3f_frame_free(ptr::null_mut());
        x3f_session_free(ptr::null_mut());
        x3f_cancel_free(ptr::null_mut());
        x3f_cancel_set(ptr::null());
        x3f_string_free(ptr::null_mut());
    }
}

#[test]
fn unsupported_and_missing_files() {
    let dir = std::env::temp_dir().join(format!("x3fuse-engine-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let jpeg = dir.join("photo.jpg");
    std::fs::write(&jpeg, b"\xFF\xD8\xFF\xE0 not a raw").unwrap();
    unsafe {
        let path = CString::new(jpeg.to_str().unwrap()).unwrap();
        let mut session = ptr::null_mut();
        let mut error = ptr::null_mut();
        assert_eq!(
            x3f_session_open(path.as_ptr(), ptr::null(), &mut session, &mut error),
            X3F_ERR_UNSUPPORTED
        );
        assert!(session.is_null());
        take_error(error);

        let path = CString::new(dir.join("missing.x3f").to_str().unwrap()).unwrap();
        let mut error = ptr::null_mut();
        assert_eq!(
            x3f_session_open(path.as_ptr(), ptr::null(), &mut session, &mut error),
            X3F_ERR_IO
        );
        take_error(error);
    }
    std::fs::remove_dir_all(dir).unwrap();
}

fn fixture() -> Option<PathBuf> {
    let Some(path) = std::env::var_os("X3F_FIXTURE") else {
        eprintln!("skipped: X3F_FIXTURE unset");
        return None;
    };
    let path = PathBuf::from(path);
    eprintln!("fixture: {}", path.display());
    assert!(path.is_file(), "X3F_FIXTURE does not exist");
    Some(path)
}

#[test]
fn cancelled_token_cancels_open() {
    let Some(path) = fixture() else { return };
    unsafe {
        let cancel = x3f_cancel_new();
        x3f_cancel_set(cancel);
        let path = CString::new(path.to_str().unwrap()).unwrap();
        let mut session = ptr::null_mut();
        let mut error = ptr::null_mut();
        assert_eq!(
            x3f_session_open(path.as_ptr(), cancel, &mut session, &mut error),
            X3F_ERR_CANCELLED
        );
        assert!(session.is_null());
        take_error(error);
        x3f_cancel_free(cancel);
    }
}

fn mean(frame: &X3fFrame) -> f64 {
    let bytes = unsafe { std::slice::from_raw_parts(frame.bytes, frame.len) };
    let sum: u64 = bytes
        .as_chunks::<4>()
        .0
        .iter()
        .map(|p| u64::from(p[0]) + u64::from(p[1]) + u64::from(p[2]))
        .sum();
    sum as f64 / (bytes.len() / 4 * 3) as f64
}

fn render(session: *mut X3fSession, recipe: &str) -> X3fFrame {
    let recipe = CString::new(recipe).unwrap();
    let mut frame = unsafe { std::mem::zeroed::<X3fFrame>() };
    let mut error = ptr::null_mut();
    let status = unsafe {
        x3f_session_render(
            session,
            recipe.as_ptr(),
            512,
            ptr::null(),
            &mut frame,
            &mut error,
        )
    };
    assert_eq!(
        status,
        X3F_OK,
        "{}",
        if error.is_null() {
            String::new()
        } else {
            take_error(error)
        }
    );
    frame
}

/// Renders a real X3F through the C ABI and compares it with the desktop
/// editor path in Rust: the same preparation and `render_prepared`.
#[test]
fn real_fixture_matches_desktop_path() {
    let Some(path) = fixture() else { return };
    unsafe {
        let c_path = CString::new(path.to_str().unwrap()).unwrap();
        let mut session = ptr::null_mut();
        let mut error = ptr::null_mut();
        assert_eq!(
            x3f_session_open(c_path.as_ptr(), ptr::null(), &mut session, &mut error),
            X3F_OK
        );

        let mut json = ptr::null_mut();
        assert_eq!(
            x3f_session_info(session, &mut json, ptr::null_mut()),
            X3F_OK
        );
        let info: serde_json::Value =
            serde_json::from_str(CStr::from_ptr(json).to_str().unwrap()).unwrap();
        x3f_string_free(json);
        assert_eq!(info["renderVersion"], 20);
        assert_eq!(info["kind"], "x3f");
        let default = &info["defaultRecipe"];
        assert_eq!(default["sharpen"], 50.0);
        assert_eq!(default["cameraProfile"], info["asShotProfile"]);
        assert!(default["film"].is_null());
        assert!(default["temperature"].is_null());

        let mut base = render(
            session,
            r#"{"version":1,"exposure":0,"temperature":null,"tint":0,"film":null}"#,
        );
        assert_eq!(base.stride, base.width * 4);
        assert_eq!(base.len, (base.stride * base.height) as usize);
        assert_eq!(base.width.max(base.height), 512);

        // Desktop path with the same recipe.
        let recipe = session_recipe(&path, "{}");
        let profiles = x3f_render::read_camera_profiles(&path, &AtomicBool::new(false)).unwrap();
        let scene = x3f_core::prepare_scene_linear(
            &path,
            &x3f_core::SceneLinearOptions {
                denoise_intensity: recipe.denoise,
                denoise_options: recipe.denoise_options,
                highlight_recovery: true,
                x3i_source: x3f_core::X3iSource::MiddleExposure,
                ..Default::default()
            },
            &AtomicBool::new(false),
            |_| (),
        )
        .unwrap();
        let prepared = x3f_render::PreparedImage::new(scene, &AtomicBool::new(false))
            .unwrap()
            .with_camera_profiles(profiles);
        let desktop = x3f_render::Renderer::new()
            .unwrap()
            .render_prepared(
                &prepared,
                &recipe,
                x3f_render::RenderOptions {
                    max_dimension: Some(512),
                    rgba8: true,
                    ..Default::default()
                },
                &AtomicBool::new(false),
            )
            .unwrap();
        assert!(
            desktop.rgba8().unwrap() == std::slice::from_raw_parts(base.bytes, base.len),
            "engine differs from the desktop path"
        );
        // Renderer::render has no camera calibration, so a color profile
        // must render differently through the engine.
        assert!(!info["cameraProfiles"].as_array().unwrap().is_empty());
        let standard = r#"{"cameraProfile":"Standard","monochrome":null}"#;
        let renderer = x3f_render::Renderer::new().unwrap();
        let uncalibrated = renderer
            .render(
                prepared.image(),
                &session_recipe(&path, standard),
                x3f_render::RenderOptions {
                    max_dimension: Some(512),
                    rgba8: true,
                    ..Default::default()
                },
                &AtomicBool::new(false),
            )
            .unwrap();
        let mut calibrated = render(session, standard);
        let same = uncalibrated.rgba8().unwrap()
            == std::slice::from_raw_parts(calibrated.bytes, calibrated.len);
        x3f_frame_free(&mut calibrated);
        assert!(!same, "engine output equals the uncalibrated renderer");
        drop(prepared);

        let brighter = {
            let mut f = render(session, r#"{"exposure":1}"#);
            let m = mean(&f);
            x3f_frame_free(&mut f);
            m
        };
        let warmer = {
            let mut f = render(
                session,
                r#"{"cameraProfile":"Standard","monochrome":null,"temperature":9000}"#,
            );
            let bytes = std::slice::from_raw_parts(f.bytes, f.len);
            let (r, b) = bytes
                .as_chunks::<4>()
                .0
                .iter()
                .fold((0u64, 0u64), |(r, b), p| {
                    (r + u64::from(p[0]), b + u64::from(p[2]))
                });
            x3f_frame_free(&mut f);
            r as f64 / b as f64
        };
        let base_mean = mean(&base);
        let base_rb = {
            let mut f = render(session, r#"{"cameraProfile":"Standard","monochrome":null}"#);
            let bytes = std::slice::from_raw_parts(f.bytes, f.len).to_vec();
            x3f_frame_free(&mut f);
            let (r, b) = bytes
                .as_chunks::<4>()
                .0
                .iter()
                .fold((0u64, 0u64), |(r, b), p| {
                    (r + u64::from(p[0]), b + u64::from(p[2]))
                });
            r as f64 / b as f64
        };
        assert!(base_mean > 5. && base_mean < 250., "base mean {base_mean}");
        assert!(
            brighter > base_mean,
            "exposure +1: {brighter} <= {base_mean}"
        );
        assert!(warmer > base_rb, "9000 K: r/b {warmer} <= {base_rb}");
        x3f_frame_free(&mut base);
        assert!(base.bytes.is_null() && base.owner.is_null());

        let mut error = ptr::null_mut();
        let bad = CString::new(r#"{"noSuchField":1}"#).unwrap();
        let mut frame = std::mem::zeroed::<X3fFrame>();
        assert_eq!(
            x3f_session_render(
                session,
                bad.as_ptr(),
                512,
                ptr::null(),
                &mut frame,
                &mut error
            ),
            X3F_ERR_INVALID
        );
        take_error(error);

        let dir = std::env::temp_dir().join(format!("x3fuse-export-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let out = dir.join("out.jpg");
        let c_out = CString::new(out.to_str().unwrap()).unwrap();
        let recipe = CString::new(r#"{"exposure":0.5}"#).unwrap();
        let cancel = x3f_cancel_new();
        x3f_cancel_set(cancel);
        let mut error = ptr::null_mut();
        assert_eq!(
            x3f_session_export_jpeg(
                session,
                recipe.as_ptr(),
                c_out.as_ptr(),
                90,
                false,
                cancel,
                &mut error
            ),
            X3F_ERR_CANCELLED
        );
        take_error(error);
        x3f_cancel_free(cancel);
        assert_eq!(
            std::fs::read_dir(&dir).unwrap().count(),
            0,
            "cancel leaves no file"
        );

        let mut error = ptr::null_mut();
        assert_eq!(
            x3f_session_export_jpeg(
                session,
                recipe.as_ptr(),
                c_out.as_ptr(),
                90,
                false,
                ptr::null(),
                &mut error
            ),
            X3F_OK
        );
        let jpeg = std::fs::read(&out).unwrap();
        assert_eq!(&jpeg[..2], b"\xFF\xD8");
        let full = (
            info["width"].as_u64().unwrap(),
            info["height"].as_u64().unwrap(),
        );
        let decoded = image_size(&jpeg);
        assert!(
            decoded.0 as u64 <= full.0
                && decoded.1 as u64 <= full.1
                && decoded.0.max(decoded.1) > 1000,
            "{decoded:?} vs {full:?}"
        );
        assert_eq!(
            std::fs::read_dir(&dir).unwrap().count(),
            1,
            "no partial file remains"
        );

        // No clobber without approval, and never the source.
        let mut error = ptr::null_mut();
        assert_eq!(
            x3f_session_export_jpeg(
                session,
                recipe.as_ptr(),
                c_out.as_ptr(),
                90,
                false,
                ptr::null(),
                &mut error
            ),
            X3F_ERR_EXISTS
        );
        take_error(error);
        assert_eq!(std::fs::read(&out).unwrap(), jpeg);
        let link = dir.join("source-link.x3f");
        std::fs::hard_link(&path, &link).unwrap();
        for target in [&path, &link] {
            let c_target = CString::new(target.to_str().unwrap()).unwrap();
            let mut error = ptr::null_mut();
            assert_eq!(
                x3f_session_export_jpeg(
                    session,
                    recipe.as_ptr(),
                    c_target.as_ptr(),
                    90,
                    true,
                    ptr::null(),
                    &mut error
                ),
                X3F_ERR_INVALID
            );
            take_error(error);
        }
        assert_eq!(sha256_hex(&path), info["sourceRevision"].as_str().unwrap());
        std::fs::remove_dir_all(dir).unwrap();

        x3f_session_free(session);
    }
}

/// Reads the size from the JPEG SOF marker.
fn image_size(jpeg: &[u8]) -> (u32, u32) {
    let mut i = 2;
    while i + 9 < jpeg.len() {
        let marker = jpeg[i + 1];
        let len = usize::from(u16::from_be_bytes([jpeg[i + 2], jpeg[i + 3]]));
        if (0xC0..=0xC2).contains(&marker) {
            let h = u16::from_be_bytes([jpeg[i + 5], jpeg[i + 6]]);
            let w = u16::from_be_bytes([jpeg[i + 7], jpeg[i + 8]]);
            return (w.into(), h.into());
        }
        i += 2 + len;
    }
    panic!("no SOF marker");
}

fn sha256_hex(path: &std::path::Path) -> String {
    use sha2::Digest;
    format!("{:x}", sha2::Sha256::digest(std::fs::read(path).unwrap()))
}

fn session_recipe(path: &std::path::Path, json: &str) -> x3f_render::EditRecipe {
    x3fuse_engine::Session::open(path, &AtomicBool::new(false))
        .unwrap()
        .recipe(json)
        .unwrap()
}
