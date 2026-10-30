//! HSL bands and color wheels through the C ABI on real files.
//! Set X3F_FIXTURE to a color X3F file, X3F_MONO_FIXTURE to an X3F file shot
//! in the camera's Monochrome mode, and X3F_SIDECAR_FIXTURE to a desktop
//! sidecar of X3F_FIXTURE (only read). Each test skips when its file is unset.
use serde_json::{json, Value};
use std::{
    ffi::{c_char, CStr, CString},
    ptr,
};
use x3fuse_engine::*;

const EDGE: u32 = 384;

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

fn edited(session: *mut X3fSession, recipe: &str) -> bool {
    let mut edited = false;
    let status =
        unsafe { x3f_recipe_edited(session, cs(recipe).as_ptr(), &mut edited, ptr::null_mut()) };
    assert_eq!(status, X3F_OK);
    edited
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

/// Mean of max minus min channel: zero for gray pixels.
fn chroma(rgb: &[u8]) -> f64 {
    let sum: u64 = rgb
        .as_chunks::<3>()
        .0
        .iter()
        .map(|p| u64::from(p.iter().max().unwrap() - p.iter().min().unwrap()))
        .sum();
    sum as f64 / (rgb.len() / 3) as f64
}

fn bands(band: Value) -> Value {
    Value::Array(vec![band; 8])
}

/// Every key except `skip` is equal in both recipes.
fn same_except(a: &str, b: &str, skip: &[&str]) {
    let (mut a, mut b) = (json(a), json(b));
    for key in skip {
        a.as_object_mut().unwrap().remove(*key);
        b.as_object_mut().unwrap().remove(*key);
    }
    assert_eq!(a, b, "only {skip:?} may change");
}

/// Invalid values, accepted boundaries, the canonical form and patches. No
/// RAW file is needed.
#[test]
fn hsl_and_wheel_recipes() {
    let base = normalize("{}").unwrap();
    // Default wheels are not written; the eight default bands are.
    assert!(json(&base).get("wheels").is_none());
    assert_eq!(
        json(&base)["hsl"],
        bands(json!({"hue": 0., "saturation": 0., "luminance": 0.}))
    );
    let with = |change: Value| {
        let mut recipe = json(&base);
        for (key, value) in change.as_object().unwrap() {
            recipe[key] = value.clone();
        }
        recipe.to_string()
    };
    let wheel = |w: Value| with(json!({"wheels": {"midtones": w}}));
    for bad in [
        with(json!({"hsl": bands(json!({"hue": 100.01}))})),
        with(json!({"hsl": bands(json!({"saturation": -101}))})),
        // Larger than f32: infinite, so not finite.
        with(json!({"hsl": bands(json!({"luminance": 1e39}))})),
        with(json!({"hsl": [{}, {}, {}, {}, {}, {}, {}]})),
        with(json!({"hsl": [{}, {}, {}, {}, {}, {}, {}, {}, {}]})),
        with(json!({"hsl": bands(json!({"value": 1}))})),
        with(json!({"hsl": null})),
        wheel(json!({"x": 1.01})),
        wheel(json!({"y": -1.01})),
        // In the square, out of the disc: |(0.7072, 0.7072)| = 1.00013.
        wheel(json!({"x": 0.7072, "y": 0.7072})),
        wheel(json!({"luminance": 100.5})),
        wheel(json!({"hue": 3.143})),
        wheel(json!({"hue": -3.143})),
        wheel(json!({"saturation": 0.5})),
        with(json!({"wheels": {"blending": -1}})),
        with(json!({"wheels": {"blending": 101}})),
        with(json!({"wheels": {"balance": -100.5}})),
        with(json!({"wheels": {"strength": 1}})),
        with(json!({"wheels": null})),
    ] {
        assert_eq!(normalize(&bad), Err(X3F_ERR_INVALID), "{bad}");
    }
    for good in [
        with(json!({"hsl": bands(json!({"hue": -100, "saturation": 100, "luminance": -100}))})),
        wheel(json!({"x": 1})),
        wheel(json!({"x": 0, "y": -1})),
        // Float slack at the rim: |(0.70717, 0.70717)| = 1.00008.
        wheel(json!({"x": 0.70717, "y": 0.70717})),
        wheel(json!({"hue": 3.1425, "luminance": -100})),
        wheel(json!({"hue": -std::f32::consts::PI})),
        with(json!({"wheels": {"blending": 0, "balance": -100}})),
        with(json!({"wheels": {"blending": 100, "balance": 100}})),
    ] {
        assert!(normalize(&good).is_ok(), "{good}");
    }

    // The canonical form is stable and keeps a nonzero remembered hue only.
    let graded = with(json!({
        "hsl": [{"hue": 12.5}, {"saturation": -40}, {"luminance": 30}, {},
                {}, {"hue": -100, "saturation": 100, "luminance": -100}, {}, {"saturation": 0.25}],
        "wheels": {
            "shadows": {"x": 0.3, "y": -0.4, "luminance": -20},
            "midtones": {"x": 0, "y": 0, "hue": 2.0944},
            "highlights": {"x": 0, "y": 0, "hue": 0, "luminance": 15},
            "blending": 70,
            "balance": -25
        }
    }));
    let canonical = normalize(&graded).unwrap();
    assert_eq!(
        normalize(&canonical).unwrap(),
        canonical,
        "normalize is idempotent"
    );
    let c = json(&canonical);
    assert_eq!(
        c["hsl"][0],
        json!({"hue": 12.5, "saturation": 0., "luminance": 0.})
    );
    assert_eq!(
        c["hsl"][5],
        json!({"hue": -100., "saturation": 100., "luminance": -100.})
    );
    assert_eq!(c["hsl"][7]["saturation"], 0.25);
    let shadows = &c["wheels"]["shadows"];
    assert_eq!(shadows["x"].as_f64().unwrap() as f32, 0.3);
    assert_eq!(shadows["y"].as_f64().unwrap() as f32, -0.4);
    assert!(shadows.get("hue").is_none());
    assert_eq!(
        c["wheels"]["midtones"]["hue"].as_f64().unwrap() as f32,
        2.0944
    );
    assert!(
        c["wheels"]["highlights"].get("hue").is_none(),
        "a zero hue is not written"
    );
    assert_eq!(
        (
            c["wheels"]["blending"].as_f64(),
            c["wheels"]["balance"].as_f64()
        ),
        (Some(70.), Some(-25.))
    );
    // Wheels back at the default are not written again.
    let reset = patch(
        &canonical,
        json!({"wheels": {
        "shadows": {"x": 0, "y": 0, "luminance": 0},
        "midtones": {"hue": 0},
        "highlights": {"luminance": 0},
        "blending": 50, "balance": 0}}),
    );
    assert!(json(&reset).get("wheels").is_none());
    same_except(&reset, &canonical, &["wheels"]);

    // A nested patch keeps every other field, also the remembered hue.
    let moved = patch(&canonical, json!({"wheels": {"shadows": {"x": -0.5}}}));
    let m = json(&moved);
    assert_eq!(m["wheels"]["shadows"]["x"], -0.5);
    assert_eq!(m["wheels"]["shadows"]["y"], c["wheels"]["shadows"]["y"]);
    assert_eq!(
        m["wheels"]["shadows"]["luminance"],
        c["wheels"]["shadows"]["luminance"]
    );
    assert_eq!(m["wheels"]["midtones"], c["wheels"]["midtones"]);
    assert_eq!(m["wheels"]["highlights"], c["wheels"]["highlights"]);
    same_except(&moved, &canonical, &["wheels"]);
    // A strength reset that omits the hue keeps it; only an explicit 0 clears it.
    let strength = patch(
        &canonical,
        json!({"wheels": {"midtones": {"x": 0, "y": 0}}}),
    );
    assert_eq!(
        json(&strength)["wheels"]["midtones"],
        c["wheels"]["midtones"]
    );
    let cleared = patch(&canonical, json!({"wheels": {"midtones": {"hue": 0}}}));
    assert!(json(&cleared)["wheels"]["midtones"].get("hue").is_none());
    // An array replaces the whole array: the patch must hold all eight bands.
    let mut hsl = c["hsl"].clone();
    hsl[3]["luminance"] = json!(-60.0);
    let banded = patch(&canonical, json!({ "hsl": hsl }));
    assert_eq!(json(&banded)["hsl"], hsl);
    same_except(&banded, &canonical, &["hsl"]);
    for bad in [
        json!({"hsl": [{"hue": 10}]}),
        json!({"hsl": {"0": {"hue": 10}}}),
    ] {
        let (mut out, mut error) = (ptr::null_mut(), ptr::null_mut());
        let status = unsafe {
            x3f_recipe_patch(
                cs(&canonical).as_ptr(),
                cs(&bad.to_string()).as_ptr(),
                &mut out,
                &mut error,
            )
        };
        unsafe { (take(out), take(error)) };
        assert_eq!(status, X3F_ERR_INVALID, "{bad}");
    }
}

#[test]
fn hsl_and_wheels_on_a_color_file() {
    let Some(path) = std::env::var("X3F_FIXTURE").ok() else {
        eprintln!("skipped: X3F_FIXTURE unset");
        return;
    };
    eprintln!("fixture: {path}");
    let session = open(&path);
    let default = default_recipe(session);
    assert!(json(&default)["monochrome"].is_null(), "a color fixture");
    let base = render(session, &default);

    let desaturated = patch(&default, json!({"hsl": bands(json!({"saturation": -100}))}));
    let gray = render(session, &desaturated);
    eprintln!("chroma {:.2} -> {:.2}", chroma(&base), chroma(&gray));
    assert!(
        chroma(&gray) < 0.5 * chroma(&base),
        "saturation -100 removes color"
    );
    // One band changes less than all bands.
    let mut one = json(&default)["hsl"].clone();
    one[0]["hue"] = json!(100);
    one[1]["hue"] = json!(100);
    let red_hue = render(session, &patch(&default, json!({ "hsl": one })));
    let all_hue = render(
        session,
        &patch(&default, json!({"hsl": bands(json!({"hue": 100}))})),
    );
    let (some, all) = (difference(&red_hue, &base), difference(&all_hue, &base));
    eprintln!("hue +100: red and orange {some:.3}, all {all:.3}");
    assert!(some > 0.05 && all > some);

    // Wheels: luminance brightens, a tint moves the channels, y is up.
    let grade = |w: Value| {
        render(
            session,
            &patch(&default, json!({"wheels": {"midtones": w}})),
        )
    };
    let mean = |rgb: &[u8], c: usize| {
        rgb.iter()
            .skip(c)
            .step_by(3)
            .map(|&v| f64::from(v))
            .sum::<f64>()
            / (rgb.len() / 3) as f64
    };
    let bright = grade(json!({"luminance": 100}));
    assert!(mean(&bright, 1) > mean(&base, 1) + 5.);
    // Blending and balance move the zone borders of an active grade only.
    let shadow = json!({"shadows": {"luminance": 100}});
    let zones = |extra: Value| {
        let mut wheels = shadow.clone();
        wheels
            .as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        render(session, &patch(&default, json!({ "wheels": wheels })))
    };
    let lifted = zones(json!({}));
    for extra in [json!({"balance": -100}), json!({"blending": 0})] {
        let change = difference(&zones(extra.clone()), &lifted);
        eprintln!("{extra} on a shadow grade: {change:.3}");
        assert!(change > 0.05, "{extra}");
    }
    let borders = patch(
        &default,
        json!({"wheels": {"balance": -100, "blending": 0}}),
    );
    assert_eq!(
        render(session, &borders),
        base,
        "borders alone change nothing"
    );
    let red = grade(json!({"x": 1}));
    let green = grade(json!({"x": -0.5, "y": 0.866})); // 120°
    let blue = grade(json!({"x": -0.5, "y": -0.866})); // 240°
    let tilt = |rgb: &[u8], c: usize| mean(rgb, c) - mean(&base, c);
    eprintln!(
        "wheel tilt red {:.1} green {:.1} blue {:.1}",
        tilt(&red, 0),
        tilt(&green, 1),
        tilt(&blue, 2)
    );
    for (rgb, c) in [(&red, 0), (&green, 1), (&blue, 2)] {
        let others = (0..3)
            .filter(|&o| o != c)
            .map(|o| tilt(rgb, o))
            .fold(f64::MIN, f64::max);
        assert!(tilt(rgb, c) > others + 2., "wheel hue {c}");
    }

    // A remembered hue at zero strength is not an edit and changes no pixel.
    let kept = patch(&default, json!({"wheels": {"shadows": {"hue": 2.0944}}}));
    assert!(!edited(session, &kept));
    assert_eq!(render(session, &kept), base);
    assert!(edited(session, &desaturated));

    // Color film keeps the HSL bands; B&W turns them and the wheels off
    // but keeps their values.
    let mut catalog = ptr::null_mut();
    assert_eq!(
        unsafe { x3f_film_catalog(&mut catalog, ptr::null_mut()) },
        X3F_OK
    );
    let catalog = json(&unsafe { take(catalog) });
    let film = patch(&default, json!({"film": catalog["defaultFilm"]}));
    assert!(!catalog["defaultFilm"].is_null());
    let graded_film = patch(&film, json!({"hsl": bands(json!({"saturation": -100}))}));
    assert!(difference(&render(session, &graded_film), &render(session, &film)) > 0.5);

    let all = json!({"hsl": bands(json!({"hue": 60, "saturation": -80, "luminance": 50})),
                     "wheels": {"shadows": {"x": 0.8, "luminance": -50}, "highlights": {"y": -0.9, "luminance": 60}}});
    let graded = patch(&default, all.clone());
    let graded_pixels = render(session, &graded);
    let mono = patch(&default, json!({"monochrome": {"filter": "neutral"}}));
    let mono_graded = patch(&graded, json!({"monochrome": {"filter": "neutral"}}));
    for key in ["hsl", "wheels"] {
        assert_eq!(json(&mono_graded)[key], json(&graded)[key], "{key} kept");
    }
    assert_eq!(
        render(session, &mono_graded),
        render(session, &mono),
        "neutral ignores HSL and wheels"
    );
    let mono_key = catalog["films"]
        .as_array()
        .unwrap()
        .iter()
        .find(|f| f["monochrome"] == true)
        .expect("a B&W stock")["key"]
        .as_str()
        .unwrap()
        .to_owned();
    let look = |recipe: &str| {
        let (mut out, mut error) = (ptr::null_mut(), ptr::null_mut());
        let status = unsafe {
            x3f_recipe_apply_look(
                cs(recipe).as_ptr(),
                cs(&mono_key).as_ptr(),
                &mut out,
                &mut error,
            )
        };
        let error = unsafe { take(error) };
        assert_eq!(status, X3F_OK, "{error}");
        unsafe { take(out) }
    };
    let (bw, bw_graded) = (look(&default), look(&graded));
    assert_eq!(json(&bw_graded)["hsl"], json(&graded)["hsl"]);
    assert_eq!(
        render(session, &bw_graded),
        render(session, &bw),
        "B&W film ignores HSL and wheels"
    );
    // Full spectrum color with equal mix rows is gray, so it is neutral too.
    // A mix with different rows keeps the grade.
    let raw = |matrix: [f32; 9]| json!({"cameraProfile": null, "rawColor": {"gains": [1, 1, 1], "matrix": matrix}});
    let gray_row = raw([0.3, 0.4, 0.3, 0.3, 0.4, 0.3, 0.3, 0.4, 0.3]);
    assert_eq!(
        render(session, &patch(&graded, gray_row.clone())),
        render(session, &patch(&default, gray_row)),
        "a monochrome raw mix ignores HSL and wheels"
    );
    let color_rows = raw([1., 0., 0., 0., 1., 0., 0., 0., 1.]);
    let change = difference(
        &render(session, &patch(&graded, color_rows.clone())),
        &render(session, &patch(&default, color_rows)),
    );
    eprintln!("grade on a color raw mix: {change:.3}");
    assert!(change > 0.5);
    // Back to color: the kept grade applies again, identically.
    let color_again = patch(&mono_graded, json!({"monochrome": null}));
    assert_eq!(color_again, graded);
    assert_eq!(render(session, &color_again), graded_pixels);
    // Back to the defaults gives the first pixels again.
    assert_eq!(
        render(session, &default),
        base,
        "restoration is deterministic"
    );

    sidecar_round_trip(session, &path, &graded);
    unsafe { x3f_session_free(session) };
}

/// A graded recipe in the desktop sidecar's document keeps the document's
/// metadata, and a written document reads back with the same recipe.
fn sidecar_round_trip(session: *mut X3fSession, raw: &str, graded: &str) {
    let Some(sidecar) = std::env::var("X3F_SIDECAR_FIXTURE").ok() else {
        eprintln!("skipped sidecar: X3F_SIDECAR_FIXTURE unset");
        return;
    };
    assert_eq!(
        sidecar.strip_suffix(".x3fuse.json"),
        Some(raw),
        "the sidecar of X3F_FIXTURE"
    );
    let before = std::fs::read(&sidecar).unwrap();
    let mut document: Value = serde_json::from_slice(&before).unwrap();
    let kept = patch(graded, json!({"wheels": {"midtones": {"hue": -1.25}}}));
    document["recipe"] = json(&kept);
    let (mut out, mut recipe, mut edited, mut error) =
        (ptr::null_mut(), ptr::null_mut(), false, ptr::null_mut());
    let status = unsafe {
        x3f_document_validate(
            session,
            cs(&document.to_string()).as_ptr(),
            &mut out,
            &mut recipe,
            &mut edited,
            &mut error,
        )
    };
    let error = unsafe { take(error) };
    assert_eq!(status, X3F_OK, "{error}");
    let (out, recipe) = unsafe { (json(&take(out)), take(recipe)) };
    assert!(edited);
    assert_eq!(recipe, kept);
    for key in ["sourceRevision", "revision", "updatedMs"] {
        assert_eq!(out[key], document[key], "{key}");
    }

    let dir = std::env::temp_dir().join(format!("x3fuse-stage4-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = cs(dir.join("photo.X3F.x3fuse.json").to_str().unwrap());
    let revision = document["revision"].as_u64().unwrap() + 1;
    let mut error = ptr::null_mut();
    let status = unsafe {
        x3f_sidecar_write(
            session,
            path.as_ptr(),
            cs(&recipe).as_ptr(),
            revision,
            ptr::null(),
            ptr::null_mut(),
            &mut error,
        )
    };
    let error = unsafe { take(error) };
    assert_eq!(status, X3F_OK, "{error}");
    let (mut out, mut read_recipe, mut error) = (ptr::null_mut(), ptr::null_mut(), ptr::null_mut());
    let status = unsafe {
        x3f_sidecar_read(
            session,
            path.as_ptr(),
            &mut out,
            &mut read_recipe,
            ptr::null_mut(),
            &mut error,
        )
    };
    let error = unsafe { take(error) };
    assert_eq!(status, X3F_OK, "{error}");
    let (out, read_recipe) = unsafe { (json(&take(out)), take(read_recipe)) };
    assert_eq!(
        read_recipe, kept,
        "hsl, wheels and the remembered hue read back"
    );
    assert_eq!(out["revision"], revision);
    assert_eq!(out["sourceRevision"], document["sourceRevision"]);
    std::fs::remove_dir_all(&dir).unwrap();
    assert_eq!(
        std::fs::read(&sidecar).unwrap(),
        before,
        "the fixture sidecar is unchanged"
    );
}

/// An as-shot Monochrome file opens neutral. HSL and wheels change nothing
/// until the recipe returns to a color profile; this test uses Standard.
#[test]
fn hsl_on_an_as_shot_monochrome_file() {
    let Some(path) = std::env::var("X3F_MONO_FIXTURE").ok() else {
        eprintln!("skipped: X3F_MONO_FIXTURE unset");
        return;
    };
    eprintln!("monochrome fixture: {path}");
    let session = open(&path);
    let default = default_recipe(session);
    let d = json(&default);
    assert_eq!(d["cameraProfile"], "Monochrome");
    assert!(d["monochrome"].is_object());
    let grade = json!({"hsl": bands(json!({"hue": 80, "saturation": 100, "luminance": -40})),
                       "wheels": {"midtones": {"x": -0.6, "y": 0.6, "luminance": 40}}});
    let base = render(session, &default);
    assert!(chroma(&base) < 1., "as shot is gray");
    assert_eq!(render(session, &patch(&default, grade.clone())), base);

    let standard = patch(
        &default,
        json!({"cameraProfile": "Standard", "monochrome": null}),
    );
    let color = render(session, &standard);
    let graded = render(session, &patch(&standard, grade));
    let change = difference(&graded, &color);
    eprintln!(
        "Standard chroma {:.2}, grade change {change:.3}",
        chroma(&color)
    );
    assert!(chroma(&color) > 1. && change > 1.);
    assert_eq!(
        render(session, &default),
        base,
        "restoration is deterministic"
    );
    unsafe { x3f_session_free(session) };
}
