//! Advanced film controls through the C ABI.
//! Set X3F_FIXTURE and X3F_MONO_FIXTURE to real color and Monochrome X3F files.
use serde_json::{json, Value};
use std::{
    ffi::{c_char, CStr, CString},
    ptr,
};
use x3fuse_engine::*;

const EDGE: u32 = 1024;

fn cs(text: &str) -> CString {
    CString::new(text).unwrap()
}

/// Takes an engine string and frees it.
unsafe fn take(text: *mut c_char) -> String {
    if text.is_null() {
        return String::new();
    }
    let owned = CStr::from_ptr(text).to_string_lossy().into_owned();
    x3f_string_free(text);
    owned
}

fn json(text: &str) -> Value {
    serde_json::from_str(text).unwrap()
}

fn patch(recipe: &str, patch: Value) -> String {
    let (mut out, mut error) = (ptr::null_mut(), ptr::null_mut());
    let status = unsafe {
        x3f_recipe_patch(
            cs(recipe).as_ptr(),
            cs(&patch.to_string()).as_ptr(),
            &mut out,
            &mut error,
        )
    };
    let error = unsafe { take(error) };
    assert_eq!(status, X3F_OK, "{patch}: {error}");
    unsafe { take(out) }
}

fn normalize(recipe: &str) -> Result<String, i32> {
    let (mut out, mut error) = (ptr::null_mut(), ptr::null_mut());
    let status =
        unsafe { x3f_recipe_normalize(ptr::null(), cs(recipe).as_ptr(), &mut out, &mut error) };
    unsafe { take(error) };
    let out = unsafe { take(out) };
    if status == X3F_OK {
        Ok(out)
    } else {
        Err(status)
    }
}

fn open(path: &str) -> *mut X3fSession {
    let (mut session, mut error) = (ptr::null_mut(), ptr::null_mut());
    let status =
        unsafe { x3f_session_open(cs(path).as_ptr(), ptr::null(), &mut session, &mut error) };
    let error = unsafe { take(error) };
    assert_eq!(status, X3F_OK, "{error}");
    session
}

fn default_recipe(session: *mut X3fSession) -> String {
    let mut info = ptr::null_mut();
    assert_eq!(
        unsafe { x3f_session_info(session, &mut info, ptr::null_mut()) },
        X3F_OK
    );
    json(&unsafe { take(info) })["defaultRecipe"].to_string()
}

/// RGB bytes of a preview.
fn render(session: *mut X3fSession, recipe: &str) -> Vec<u8> {
    let mut frame = unsafe { std::mem::zeroed::<X3fFrame>() };
    let mut error = ptr::null_mut();
    let status = unsafe {
        x3f_session_render(
            session,
            cs(recipe).as_ptr(),
            EDGE,
            ptr::null(),
            &mut frame,
            &mut error,
        )
    };
    let error = unsafe { take(error) };
    assert_eq!(status, X3F_OK, "{error}");
    let bytes = unsafe { std::slice::from_raw_parts(frame.bytes, frame.len) };
    let rgb = bytes
        .as_chunks::<4>()
        .0
        .iter()
        .flat_map(|p| [p[0], p[1], p[2]])
        .collect();
    unsafe { x3f_frame_free(&mut frame) };
    rgb
}

/// Mean absolute difference per channel.
fn difference(a: &[u8], b: &[u8]) -> f64 {
    assert_eq!(a.len(), b.len());
    let sum: u64 = a
        .iter()
        .zip(b)
        .map(|(x, y)| u64::from(x.abs_diff(*y)))
        .sum();
    sum as f64 / a.len() as f64
}

fn catalog() -> Value {
    let mut out = ptr::null_mut();
    assert_eq!(
        unsafe { x3f_film_catalog(&mut out, ptr::null_mut()) },
        X3F_OK
    );
    json(&unsafe { take(out) })
}

fn film_patch(recipe: &str, change: Value) -> String {
    patch(recipe, json!({"film": change}))
}

#[test]
fn advanced_film_recipe_contract() {
    let film = catalog()["defaultFilm"].clone();
    assert_eq!(
        film["grainParams"]["rmsGranularity"],
        json!([4.5, 4.5, 4.5])
    );
    assert_eq!(film["grainParams"]["blur"].as_f64().unwrap() as f32, 0.7);
    assert_eq!(film["grainParams"]["multUsmAmount"], 1.5);
    assert_eq!(film["halationParams"]["scatterAmount"], 1.0);
    assert_eq!(film["halationParams"]["scatterSpatialScale"], 1.0);
    assert_eq!(film["halationParams"]["halationAmount"], 1.0);
    assert_eq!(film["halationParams"]["halationSpatialScale"], 1.0);
    assert_eq!(film["halationParams"]["boostEv"], 0.0);
    assert_eq!(
        film["halationParams"]["boostRange"].as_f64().unwrap() as f32,
        0.3
    );
    assert_eq!(film["halationParams"]["protectEv"], 4.0);
    let base = patch("{}", json!({"film": film, "exposure": 0.5}));
    let advanced = film_patch(
        &base,
        json!({
            "evPaper": -1.25, "gammaFilm": 1.5, "gammaPaper": 0.75,
            "tuneM": 0.25, "tuneY": -0.5,
            "grainParams": {"rmsGranularity": [12, 8, 5], "rmsBase": 8, "blur": 1.5},
            "halationParams": {"scatterAmount": 0.5, "boostEv": 5, "boostRange": 0.7}
        }),
    );
    assert_eq!(normalize(&advanced).unwrap(), advanced);
    let changed = film_patch(&advanced, json!({"grainParams": {"blur": 2}}));
    let mut expected = json(&advanced);
    expected["film"]["grainParams"]["blur"] = json!(2.0);
    assert_eq!(
        json(&changed),
        expected,
        "nested patch keeps all other values"
    );
    let auto = film_patch(&advanced, json!({"evPaper": null}));
    expected = json(&advanced);
    expected["film"]["evPaper"] = Value::Null;
    assert_eq!(json(&auto), expected, "auto exposure keeps a JSON null");

    // Missing native blocks must keep old sidecars on the legacy path.
    let mut legacy = json(&advanced);
    for key in ["grainParams", "halationParams"] {
        legacy["film"].as_object_mut().unwrap().remove(key);
    }
    let legacy = normalize(&legacy.to_string()).unwrap();
    assert!(json(&legacy)["film"]["grainParams"].is_null());
    assert!(json(&legacy)["film"]["halationParams"].is_null());
    assert_eq!(
        film_patch(
            &advanced,
            json!({"grainParams": null, "halationParams": null})
        ),
        legacy
    );
    for invalid in [
        json!({"gammaFilm": 0.49}),
        json!({"gammaPaper": 2.01}),
        json!({"evFilm": 3.01}),
        json!({"evPaper": -6.01}),
        json!({"tuneM": 1.01}),
        json!({"tuneY": -1.01}),
        json!({"grainParams": {"rmsGranularity": [101, 1, 1]}}),
        json!({"grainParams": {"rmsGranularity": [1, 1]}}),
        json!({"grainParams": {"blur": -0.01}}),
        json!({"halationParams": {"scatterAmount": 1.01}}),
        json!({"halationParams": {"halationAmount": 4.01}}),
        json!({"halationParams": {"boostEv": 20.01}}),
    ] {
        let mut recipe = json(&base);
        for (key, value) in invalid.as_object().unwrap() {
            recipe["film"][key] = value.clone();
        }
        assert_eq!(
            normalize(&recipe.to_string()),
            Err(X3F_ERR_INVALID),
            "{invalid}"
        );
    }
}

#[test]
fn advanced_film_on_a_color_file() {
    let Ok(path) = std::env::var("X3F_FIXTURE") else {
        eprintln!("skipped: X3F_FIXTURE unset");
        return;
    };
    let session = open(&path);
    let base = patch(
        &default_recipe(session),
        json!({"film": catalog()["defaultFilm"]}),
    );
    let base = film_patch(&base, json!({"grain": false, "halation": true}));
    let pixels = render(session, &base);
    assert_eq!(
        render(session, &film_patch(&base, json!({"evPaper": 0}))),
        pixels
    );
    for change in [
        json!({"evFilm": 1}),
        json!({"evPaper": -1}),
        json!({"gammaFilm": 1.5}),
        json!({"gammaPaper": 1.5}),
        json!({"tuneM": 0.7}),
        json!({"tuneY": 0.7}),
        json!({"couplers": 1}),
        json!({"halationParams": {"scatterAmount": 0}}),
        json!({"halationParams": {"scatterSpatialScale": 4}}),
        json!({"halationParams": {"halationAmount": 4}}),
        json!({"halationParams": {"halationSpatialScale": 4}}),
        json!({"halationParams": {"boostEv": 5, "boostRange": 0.7, "protectEv": 0}}),
    ] {
        let delta = difference(
            &pixels,
            &render(session, &film_patch(&base, change.clone())),
        );
        eprintln!("{change}: mean channel difference {delta:.4}");
        assert!(delta > 0.001, "{change} must affect pixels");
    }
    let boosted = film_patch(&base, json!({"halationParams": {"boostEv": 5}}));
    let boosted_pixels = render(session, &boosted);
    for change in [
        json!({"halationParams": {"boostRange": 1}}),
        json!({"halationParams": {"protectEv": 0}}),
    ] {
        let delta = difference(
            &boosted_pixels,
            &render(session, &film_patch(&boosted, change.clone())),
        );
        eprintln!("{change} with boost enabled: mean channel difference {delta:.4}");
        assert!(
            delta > 0.001,
            "{change} must affect pixels with boost enabled"
        );
    }
    let grain = film_patch(
        &base,
        json!({"grain": true, "grainParams": {
            "rmsGranularity": [20, 12, 8], "blur": 0, "multUsmAmount": 0
        }}),
    );
    let grain_pixels = render(session, &grain);
    assert!(difference(&pixels, &grain_pixels) > 0.01);
    for change in [
        json!({"grainParams": {"rmsGranularity": [0, 0, 0]}}),
        json!({"grainParams": {"blur": 3}}),
        json!({"grainParams": {"multUsmAmount": 3}}),
    ] {
        let delta = difference(
            &grain_pixels,
            &render(session, &film_patch(&grain, change.clone())),
        );
        eprintln!("{change}: mean channel difference {delta:.4}");
        assert!(delta > 0.001, "{change} must affect pixels");
    }
    let legacy_fields = json!({
        "grainAmount": 0, "grainSize": 4, "grainRoughness": 1, "grainSaturation": 0,
        "halationStrength": 0, "halationRadius": 0.006, "halationMidtones": 1,
        "scatterSizeRgb": [0, 0, 0], "scatterStrengthRgb": [0, 0, 0],
        "halationSizeRgb": [0, 0, 0], "halationStrengthRgb": [0, 0, 0]
    });
    let kept = film_patch(&grain, legacy_fields);
    assert_eq!(
        render(session, &kept),
        grain_pixels,
        "native blocks override legacy fields"
    );
    assert_eq!(
        render(
            session,
            &film_patch(&grain, json!({"grainParams": {"rmsBase": 99}}))
        ),
        grain_pixels
    );
    let legacy = film_patch(&kept, json!({"grainParams": null, "halationParams": null}));
    assert!(difference(&render(session, &legacy), &grain_pixels) > 0.01);
    let negative = film_patch(&base, json!({"negative": true}));
    let bypassed = film_patch(
        &negative,
        json!({"evPaper": 3, "gammaPaper": 2, "tuneM": 1, "tuneY": -1}),
    );
    assert_eq!(
        render(session, &negative),
        render(session, &bypassed),
        "direct scan skips print controls"
    );
    sidecar_round_trip(session, &film_patch(&kept, json!({"evPaper": null})));
    assert_eq!(
        render(session, &base),
        pixels,
        "cache restores the original controls"
    );
    unsafe { x3f_session_free(session) };
}

fn sidecar_round_trip(session: *mut X3fSession, recipe: &str) {
    let dir = std::env::temp_dir().join(format!("x3fuse-stage5-{}", std::process::id()));
    std::fs::create_dir(&dir).unwrap();
    let path = cs(dir.join("photo.X3F.x3fuse.json").to_str().unwrap());
    let mut error = ptr::null_mut();
    let status = unsafe {
        x3f_sidecar_write(
            session,
            path.as_ptr(),
            cs(recipe).as_ptr(),
            7,
            ptr::null(),
            ptr::null_mut(),
            &mut error,
        )
    };
    let error = unsafe { take(error) };
    assert_eq!(status, X3F_OK, "{error}");
    let (mut document, mut read_recipe, mut error) =
        (ptr::null_mut(), ptr::null_mut(), ptr::null_mut());
    let status = unsafe {
        x3f_sidecar_read(
            session,
            path.as_ptr(),
            &mut document,
            &mut read_recipe,
            ptr::null_mut(),
            &mut error,
        )
    };
    let error = unsafe { take(error) };
    assert_eq!(status, X3F_OK, "{error}");
    let document = json(&unsafe { take(document) });
    assert_eq!(unsafe { take(read_recipe) }, recipe);
    assert_eq!(document["revision"], 7);
    assert!(document["sourceRevision"].is_string());
    assert_eq!(document["recipe"], json(recipe));
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn print_tuning_on_a_monochrome_file() {
    let Ok(path) = std::env::var("X3F_MONO_FIXTURE") else {
        eprintln!("skipped: X3F_MONO_FIXTURE unset");
        return;
    };
    let session = open(&path);
    let default = default_recipe(session);
    assert_eq!(json(&default)["cameraProfile"], "Monochrome");
    let catalog = catalog();
    let key = catalog["films"]
        .as_array()
        .unwrap()
        .iter()
        .find(|f| f["monochrome"] == true)
        .unwrap()["key"]
        .as_str()
        .unwrap();
    let (mut out, mut error) = (ptr::null_mut(), ptr::null_mut());
    let status = unsafe {
        x3f_recipe_apply_look(
            cs(&default).as_ptr(),
            cs(key).as_ptr(),
            &mut out,
            &mut error,
        )
    };
    let error = unsafe { take(error) };
    assert_eq!(status, X3F_OK, "{error}");
    let film = film_patch(&unsafe { take(out) }, json!({"grain": false}));
    let pixels = render(session, &film);
    let tuned = film_patch(&film, json!({"tuneM": 1, "tuneY": -1}));
    assert!(
        render(session, &tuned) == pixels,
        "B&W ignores color filtration"
    );
    assert_eq!(
        json(&tuned)["film"]["tuneM"],
        1.0,
        "inactive values stay saved"
    );
    assert!(
        difference(
            &pixels,
            &render(session, &film_patch(&film, json!({"gammaFilm": 1.5})))
        ) > 0.01
    );
    unsafe { x3f_session_free(session) };
}
