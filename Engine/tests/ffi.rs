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
        let default_json = default.to_string();
        let p = |patch: &str| patched(&default_json, patch);

        let mut base = render(session, &default_json);
        assert_eq!(base.stride, base.width * 4);
        assert_eq!(base.len, (base.stride * base.height) as usize);
        assert_eq!(base.width.max(base.height), 512);

        // Desktop path with the same recipe.
        let recipe: x3f_render::EditRecipe = serde_json::from_str(&default_json).unwrap();
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
        let standard = &p(r#"{"cameraProfile":"Standard","monochrome":null}"#);
        let renderer = x3f_render::Renderer::new().unwrap();
        let uncalibrated = renderer
            .render(
                prepared.image(),
                &serde_json::from_str(standard).unwrap(),
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
            let mut f = render(session, &p(r#"{"exposure":1}"#));
            let m = mean(&f);
            x3f_frame_free(&mut f);
            m
        };
        let warmer = {
            let mut f = render(
                session,
                &p(r#"{"cameraProfile":"Standard","monochrome":null,"temperature":9000}"#),
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
            let mut f = render(session, standard);
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
        let base_frame_bytes = std::slice::from_raw_parts(base.bytes, base.len).to_vec();
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
        let edited_json = p(r#"{"exposure":0.5}"#);
        let recipe = CString::new(edited_json.as_str()).unwrap();
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

        stage2(
            session,
            &path,
            &info,
            &default_json,
            &edited_json,
            &base_frame_bytes,
            &dir,
        );
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

/// Takes an owned engine string, or panics with the error.
fn owned(status: i32, out: *mut c_char, error: *mut c_char) -> String {
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
    let text = unsafe { CStr::from_ptr(out) }.to_str().unwrap().to_owned();
    unsafe { x3f_string_free(out) };
    text
}

fn cs(text: &str) -> CString {
    CString::new(text).unwrap()
}

fn patched(recipe: &str, patch: &str) -> String {
    let (mut out, mut error) = (ptr::null_mut(), ptr::null_mut());
    let status = unsafe {
        x3f_recipe_patch(
            cs(recipe).as_ptr(),
            cs(patch).as_ptr(),
            &mut out,
            &mut error,
        )
    };
    owned(status, out, error)
}

/// The status of a call that must fail, after freeing its error.
fn failed(status: i32, error: *mut c_char) -> i32 {
    assert_ne!(status, X3F_OK);
    take_error(error);
    status
}

/// True when the TIFF/DNG has an OpcodeList3 (tag 51022) entry, little endian.
fn has_opcode_list3(bytes: &[u8]) -> bool {
    bytes.windows(4).any(|w| w == [0x4E, 0xC7, 0x07, 0x00])
}

/// Desktop documents, recipes, TIFF and DNG on a real file.
unsafe fn stage2(
    session: *mut X3fSession,
    path: &std::path::Path,
    info: &serde_json::Value,
    default_json: &str,
    edited_json: &str,
    base_frame: &[u8],
    dir: &std::path::Path,
) {
    let source = info["sourceRevision"].as_str().unwrap();
    let (mut out, mut error) = (ptr::null_mut(), ptr::null_mut());

    // Sparse recipes take the desktop defaults, not the camera defaults.
    let sparse = owned(
        x3f_recipe_normalize(
            ptr::null(),
            cs(r#"{"exposure":1}"#).as_ptr(),
            &mut out,
            &mut error,
        ),
        out,
        error,
    );
    let sparse: serde_json::Value = serde_json::from_str(&sparse).unwrap();
    assert!(sparse["film"].is_object() && sparse["cameraProfile"].is_null());
    assert_eq!(
        (sparse["sharpen"].as_f64(), sparse["seed"].as_u64()),
        (Some(0.), Some(0))
    );
    let merge = serde_json::json!({ "x3iSource": x3f_core::X3iSource::Merge }).to_string();
    let merge = patched(default_json, &merge);
    assert_eq!(
        failed(
            x3f_recipe_normalize(session, cs(&merge).as_ptr(), &mut out, &mut error),
            error
        ),
        X3F_ERR_UNSUPPORTED
    );
    assert!(out.is_null());

    let mut edited = true;
    assert_eq!(
        x3f_recipe_edited(
            session,
            cs(default_json).as_ptr(),
            &mut edited,
            ptr::null_mut()
        ),
        X3F_OK
    );
    assert!(!edited);
    assert_eq!(
        x3f_recipe_edited(
            session,
            cs(edited_json).as_ptr(),
            &mut edited,
            ptr::null_mut()
        ),
        X3F_OK
    );
    assert!(edited);

    // Film look from the catalog renders differently from the camera look.
    let catalog: serde_json::Value =
        serde_json::from_str(&owned(x3f_film_catalog(&mut out, &mut error), out, error)).unwrap();
    let stock = catalog["films"][0]["key"].as_str().unwrap();
    let film = owned(
        x3f_recipe_apply_look(
            cs(default_json).as_ptr(),
            cs(stock).as_ptr(),
            &mut out,
            &mut error,
        ),
        out,
        error,
    );
    let start = std::time::Instant::now();
    let mut frame = render(session, &film);
    eprintln!("film preview 512 px: {:?}", start.elapsed());
    assert!(std::slice::from_raw_parts(frame.bytes, frame.len) != base_frame);
    x3f_frame_free(&mut frame);

    // Sidecar write and read back.
    let sidecar = dir.join("photo.X3F.x3fuse.json");
    let c_sidecar = cs(sidecar.to_str().unwrap());
    let written = owned(
        x3f_sidecar_write(
            session,
            c_sidecar.as_ptr(),
            cs(edited_json).as_ptr(),
            1,
            ptr::null(),
            &mut out,
            &mut error,
        ),
        out,
        error,
    );
    let on_disk = std::fs::read_to_string(&sidecar).unwrap();
    assert_eq!(written, on_disk);
    let doc: serde_json::Value = serde_json::from_str(&on_disk).unwrap();
    let keys: Vec<_> = doc.as_object().unwrap().keys().cloned().collect();
    assert_eq!(keys.len(), 5, "{keys:?}");
    assert_eq!(
        (doc["version"].as_u64(), doc["revision"].as_u64()),
        (Some(2), Some(1))
    );
    assert_eq!(doc["sourceRevision"], source);
    let (mut recipe_out, mut edited) = (ptr::null_mut(), false);
    let read = owned(
        x3f_sidecar_read(
            session,
            c_sidecar.as_ptr(),
            &mut out,
            &mut recipe_out,
            &mut edited,
            &mut error,
        ),
        out,
        error,
    );
    assert_eq!(read, on_disk);
    assert!(edited);
    assert_eq!(
        owned(X3F_OK, recipe_out, ptr::null_mut()),
        patched(edited_json, "{}")
    );

    // Desktop save rules.
    let other = patched(edited_json, r#"{"exposure":0.25}"#);
    assert_eq!(
        failed(
            x3f_sidecar_write(
                session,
                c_sidecar.as_ptr(),
                cs(&other).as_ptr(),
                1,
                ptr::null(),
                &mut out,
                &mut error
            ),
            error
        ),
        X3F_ERR_CONFLICT
    );
    assert_eq!(
        failed(
            x3f_sidecar_write(
                session,
                c_sidecar.as_ptr(),
                cs(&other).as_ptr(),
                0,
                ptr::null(),
                &mut out,
                &mut error
            ),
            error
        ),
        X3F_ERR_INVALID
    );
    assert_eq!(
        std::fs::read_to_string(&sidecar).unwrap(),
        on_disk,
        "a refused save keeps the file"
    );
    let newer = on_disk.replace("\"revision\": 1", "\"revision\": 5");
    assert_eq!(
        failed(
            x3f_sidecar_write(
                session,
                c_sidecar.as_ptr(),
                cs(&other).as_ptr(),
                2,
                cs(&newer).as_ptr(),
                &mut out,
                &mut error
            ),
            error
        ),
        X3F_ERR_CONFLICT
    );
    let second = owned(
        x3f_sidecar_write(
            session,
            c_sidecar.as_ptr(),
            cs(&other).as_ptr(),
            2,
            ptr::null(),
            &mut out,
            &mut error,
        ),
        out,
        error,
    );
    let second: serde_json::Value = serde_json::from_str(&second).unwrap();
    assert!(second["updatedMs"].as_u64() > doc["updatedMs"].as_u64());
    assert_eq!(
        x3f_document_check_previous(cs(&on_disk).as_ptr(), cs(&newer).as_ptr(), ptr::null_mut()),
        X3F_OK
    );
    assert_eq!(
        failed(
            x3f_document_check_previous(cs(&newer).as_ptr(), cs(&on_disk).as_ptr(), &mut error),
            error
        ),
        X3F_ERR_CONFLICT
    );

    // Invalid, newer, unknown key and other source documents.
    let bad = |text: &str| {
        let (mut out, mut error) = (ptr::null_mut(), ptr::null_mut());
        let status = failed(
            x3f_document_validate(
                session,
                cs(text).as_ptr(),
                &mut out,
                ptr::null_mut(),
                ptr::null_mut(),
                &mut error,
            ),
            error,
        );
        assert!(out.is_null());
        status
    };
    assert_eq!(bad("not json"), X3F_ERR_INVALID);
    assert_eq!(
        bad(&on_disk.replace("\"version\": 2", "\"version\": 3")),
        X3F_ERR_UNSUPPORTED
    );
    assert_eq!(
        bad(&on_disk.replacen("\"revision\"", "\"extra\": 1,\n  \"revision\"", 1)),
        X3F_ERR_INVALID
    );
    assert_eq!(
        bad(&on_disk.replace(source, &"0".repeat(64))),
        X3F_ERR_CONFLICT
    );
    // A version 1 document with the old default film look is unedited.
    let legacy = serde_json::json!({
        "version": 1, "sourceRevision": source, "revision": 1, "updatedMs": 1,
        "recipe": x3f_render::EditRecipe {
            film: Some(x3f_render::FilmSettings { grain_params: None, halation_params: None, ..Default::default() }),
            crop: serde_json::from_value(info["defaultRecipe"]["crop"].clone()).unwrap(),
            seed: info["defaultRecipe"]["seed"].as_u64().unwrap() as u32,
            ..Default::default()
        }
    }).to_string();
    let (mut recipe_out, mut edited) = (ptr::null_mut(), true);
    owned(
        x3f_document_validate(
            session,
            cs(&legacy).as_ptr(),
            &mut out,
            &mut recipe_out,
            &mut edited,
            &mut error,
        ),
        out,
        error,
    );
    assert!(!edited);
    assert_eq!(
        owned(X3F_OK, recipe_out, ptr::null_mut()),
        patched(default_json, "{}")
    );

    // An unreadable existing file is kept.
    let garbage = dir.join("garbage.x3fuse.json");
    std::fs::write(&garbage, "garbage").unwrap();
    let c_garbage = cs(garbage.to_str().unwrap());
    assert_eq!(
        failed(
            x3f_sidecar_write(
                session,
                c_garbage.as_ptr(),
                cs(edited_json).as_ptr(),
                9,
                ptr::null(),
                &mut out,
                &mut error
            ),
            error
        ),
        X3F_ERR_CONFLICT
    );
    assert_eq!(std::fs::read_to_string(&garbage).unwrap(), "garbage");
    assert_eq!(
        failed(
            x3f_sidecar_read(
                session,
                c_garbage.as_ptr(),
                &mut out,
                ptr::null_mut(),
                ptr::null_mut(),
                &mut error
            ),
            error
        ),
        X3F_ERR_INVALID
    );
    std::fs::remove_file(&garbage).unwrap();
    let missing = cs(dir.join("none.x3fuse.json").to_str().unwrap());
    assert_eq!(
        x3f_sidecar_read(
            session,
            missing.as_ptr(),
            &mut out,
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut()
        ),
        X3F_OK
    );
    assert!(out.is_null());
    // Never the source, and a read-only folder fails cleanly.
    assert_eq!(
        failed(
            x3f_sidecar_write(
                session,
                cs(path.to_str().unwrap()).as_ptr(),
                cs(edited_json).as_ptr(),
                9,
                ptr::null(),
                &mut out,
                &mut error
            ),
            error
        ),
        X3F_ERR_INVALID
    );
    let locked = dir.join("locked");
    std::fs::create_dir(&locked).unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o555)).unwrap();
    let c_locked = cs(locked.join("photo.X3F.x3fuse.json").to_str().unwrap());
    assert_eq!(
        failed(
            x3f_sidecar_write(
                session,
                c_locked.as_ptr(),
                cs(edited_json).as_ptr(),
                1,
                ptr::null(),
                &mut out,
                &mut error
            ),
            error
        ),
        X3F_ERR_IO
    );
    assert_eq!(std::fs::read_dir(&locked).unwrap().count(), 0);
    std::fs::set_permissions(&locked, std::fs::Permissions::from_mode(0o755)).unwrap();

    // 16-bit TIFF.
    let tif = dir.join("photo.tif");
    let c_tif = cs(tif.to_str().unwrap());
    let start = std::time::Instant::now();
    assert_eq!(
        x3f_session_export_tiff(
            session,
            cs(edited_json).as_ptr(),
            c_tif.as_ptr(),
            1,
            false,
            false,
            ptr::null(),
            &mut error
        ),
        X3F_OK,
        "{}",
        if error.is_null() {
            String::new()
        } else {
            take_error(error)
        }
    );
    eprintln!("TIFF export: {:?}", start.elapsed());
    let tiff = std::fs::read(&tif).unwrap();
    assert!(tiff.starts_with(b"II*\0") || tiff.starts_with(b"MM\0*"));
    let pixels = info["width"].as_u64().unwrap() * info["height"].as_u64().unwrap();
    assert!(
        tiff.len() as u64 > pixels,
        "16-bit TIFF is too small: {}",
        tiff.len()
    );
    assert_eq!(
        failed(
            x3f_session_export_tiff(
                session,
                cs(edited_json).as_ptr(),
                c_tif.as_ptr(),
                0,
                false,
                false,
                ptr::null(),
                &mut error
            ),
            error
        ),
        X3F_ERR_EXISTS
    );
    assert_eq!(
        failed(
            x3f_session_export_tiff(
                session,
                cs(edited_json).as_ptr(),
                c_tif.as_ptr(),
                9,
                false,
                true,
                ptr::null(),
                &mut error
            ),
            error
        ),
        X3F_ERR_INVALID
    );
    drop(tiff);

    // Original DNG, with lens correction from the bundled opcodes.
    let opcodes = cs(concat!(env!("CARGO_MANIFEST_DIR"), "/resources/opcodes"));
    let dng = dir.join("photo.dng");
    let c_dng = cs(dng.to_str().unwrap());
    assert_eq!(
        failed(
            x3f_session_export_dng(
                session,
                c_dng.as_ptr(),
                ptr::null(),
                false,
                false,
                ptr::null(),
                ptr::null_mut(),
                &mut error
            ),
            error
        ),
        X3F_ERR_INVALID
    );
    let cancel = x3f_cancel_new();
    x3f_cancel_set(cancel);
    assert_eq!(
        failed(
            x3f_session_export_dng(
                session,
                c_dng.as_ptr(),
                opcodes.as_ptr(),
                false,
                false,
                cancel,
                ptr::null_mut(),
                &mut error
            ),
            error
        ),
        X3F_ERR_CANCELLED
    );
    x3f_cancel_free(cancel);
    assert!(!dng.exists());
    let mut warnings = ptr::null_mut();
    let start = std::time::Instant::now();
    assert_eq!(
        x3f_session_export_dng(
            session,
            c_dng.as_ptr(),
            opcodes.as_ptr(),
            false,
            false,
            ptr::null(),
            &mut warnings,
            &mut error
        ),
        X3F_OK,
        "{}",
        if error.is_null() {
            String::new()
        } else {
            take_error(error)
        }
    );
    eprintln!("DNG export: {:?}", start.elapsed());
    let warnings = owned(X3F_OK, warnings, ptr::null_mut());
    eprintln!("DNG warnings: {warnings}");
    let bytes = std::fs::read(&dng).unwrap();
    assert!(bytes.starts_with(b"II*\0"));
    let merrill = info["cameraProfiles"]
        .as_array()
        .unwrap()
        .iter()
        .all(|p| p["id"] != "FCYellow");
    assert_eq!(
        has_opcode_list3(&bytes),
        merrill,
        "Merrill DNGs carry lens correction, Quattro have none"
    );
    let recovered = dir.join("recovered.dng");
    assert_eq!(
        x3f_session_export_dng(
            session,
            cs(recovered.to_str().unwrap()).as_ptr(),
            ptr::null(),
            true,
            false,
            ptr::null(),
            ptr::null_mut(),
            ptr::null_mut()
        ),
        X3F_OK
    );
    assert!(!has_opcode_list3(&std::fs::read(&recovered).unwrap()));
    let leftovers: Vec<_> = std::fs::read_dir(dir)
        .unwrap()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_name().to_string_lossy().ends_with(".partial"))
        .collect();
    assert!(leftovers.is_empty());
}

/// The real desktop sidecar in X3F_SIDECAR_FIXTURE (next to its RAW). It is
/// only read.
#[test]
fn desktop_sidecar_fixture() {
    let Some(sidecar) = std::env::var_os("X3F_SIDECAR_FIXTURE").map(PathBuf::from) else {
        eprintln!("skipped: X3F_SIDECAR_FIXTURE unset");
        return;
    };
    eprintln!("sidecar fixture: {}", sidecar.display());
    let raw = PathBuf::from(
        sidecar
            .to_str()
            .unwrap()
            .strip_suffix(".x3fuse.json")
            .unwrap(),
    );
    let before = (std::fs::read(&sidecar).unwrap(), sha256_hex(&raw));
    let document: serde_json::Value = serde_json::from_slice(&before.0).unwrap();
    unsafe {
        let mut session = ptr::null_mut();
        let mut error = ptr::null_mut();
        assert_eq!(
            x3f_session_open(
                cs(raw.to_str().unwrap()).as_ptr(),
                ptr::null(),
                &mut session,
                &mut error
            ),
            X3F_OK
        );
        let (mut out, mut recipe_out, mut edited) = (ptr::null_mut(), ptr::null_mut(), false);
        let read = owned(
            x3f_sidecar_read(
                session,
                cs(sidecar.to_str().unwrap()).as_ptr(),
                &mut out,
                &mut recipe_out,
                &mut edited,
                &mut error,
            ),
            out,
            error,
        );
        let recipe = owned(X3F_OK, recipe_out, ptr::null_mut());
        let read: serde_json::Value = serde_json::from_str(&read).unwrap();
        assert_eq!(read["version"], 2);
        assert_eq!(read["sourceRevision"], document["sourceRevision"]);
        assert_eq!(read["revision"], document["revision"]);
        assert_eq!(read["updatedMs"], document["updatedMs"]);
        eprintln!(
            "desktop document version {} edited {edited}",
            document["version"]
        );
        if edited {
            // An edited recipe is kept exactly as parsed.
            let parsed: x3f_render::EditRecipe =
                serde_json::from_value(document["recipe"].clone()).unwrap();
            assert_eq!(
                serde_json::from_str::<x3f_render::EditRecipe>(&recipe).unwrap(),
                parsed
            );
        }
        let mut frame = render(session, &recipe);
        x3f_frame_free(&mut frame);
        x3f_session_free(session);
    }
    assert_eq!(
        (std::fs::read(&sidecar).unwrap(), sha256_hex(&raw)),
        before,
        "fixtures unchanged"
    );
}
