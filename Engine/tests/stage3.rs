//! Crop, rotation, curves and denoise through the C ABI on a real file.
//! Set X3F_FIXTURE to an X3F file.
use serde_json::{json, Value};
use std::{
    ffi::{c_char, CStr, CString},
    ptr,
};
use x3fuse_engine::*;

fn cs(text: &str) -> CString {
    CString::new(text).unwrap()
}

fn message(error: *mut c_char) -> String {
    if error.is_null() {
        return String::new();
    }
    let text = unsafe { CStr::from_ptr(error) }
        .to_string_lossy()
        .into_owned();
    unsafe { x3f_string_free(error) };
    text
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
    assert_eq!(status, X3F_OK, "{}", message(error));
    let text = unsafe { CStr::from_ptr(out) }.to_str().unwrap().to_owned();
    unsafe { x3f_string_free(out) };
    text
}

fn normalize_status(recipe: &str) -> i32 {
    let (mut out, mut error) = (ptr::null_mut(), ptr::null_mut());
    let status =
        unsafe { x3f_recipe_normalize(ptr::null(), cs(recipe).as_ptr(), &mut out, &mut error) };
    message(error);
    unsafe { x3f_string_free(out) };
    status
}

/// RGB rows of a rendered frame.
struct Image {
    width: usize,
    height: usize,
    rgb: Vec<[u8; 3]>,
}

impl Image {
    fn at(&self, x: usize, y: usize) -> [u8; 3] {
        self.rgb[y * self.width + x]
    }
    fn mean(&self) -> f64 {
        let sum: u64 = self.rgb.iter().flatten().map(|&v| u64::from(v)).sum();
        sum as f64 / (self.rgb.len() * 3) as f64
    }
}

fn render(session: *mut X3fSession, recipe: &str, max_edge: u32) -> Result<Image, i32> {
    let mut frame = unsafe { std::mem::zeroed::<X3fFrame>() };
    let mut error = ptr::null_mut();
    let status = unsafe {
        x3f_session_render(
            session,
            cs(recipe).as_ptr(),
            max_edge,
            ptr::null(),
            &mut frame,
            &mut error,
        )
    };
    if status != X3F_OK {
        message(error);
        return Err(status);
    }
    let bytes = unsafe { std::slice::from_raw_parts(frame.bytes, frame.len) };
    let image = Image {
        width: frame.width as usize,
        height: frame.height as usize,
        rgb: bytes
            .as_chunks::<4>()
            .0
            .iter()
            .map(|p| [p[0], p[1], p[2]])
            .collect(),
    };
    unsafe { x3f_frame_free(&mut frame) };
    Ok(image)
}

/// Mean absolute difference between `image` and `reference` read through
/// `map` (image pixel to reference pixel), away from the edges.
fn difference(
    image: &Image,
    reference: &Image,
    map: impl Fn(usize, usize) -> (usize, usize),
) -> f64 {
    let margin = 12;
    let (mut sum, mut count) = (0., 0.);
    for y in margin..image.height - margin {
        for x in margin..image.width - margin {
            let (rx, ry) = map(x, y);
            let (a, b) = (image.at(x, y), reference.at(rx, ry));
            sum += (0..3).map(|c| f64::from(a[c].abs_diff(b[c]))).sum::<f64>();
            count += 3.;
        }
    }
    sum / count
}

#[test]
fn crop_rotation_curves_and_denoise() {
    let Some(path) = std::env::var_os("X3F_FIXTURE") else {
        eprintln!("skipped: X3F_FIXTURE unset");
        return;
    };
    eprintln!("fixture: {}", path.to_string_lossy());
    unsafe {
        let mut session = ptr::null_mut();
        let mut error = ptr::null_mut();
        let c_path = cs(path.to_str().unwrap());
        assert_eq!(
            x3f_session_open(c_path.as_ptr(), ptr::null(), &mut session, &mut error),
            X3F_OK,
            "{}",
            message(error)
        );
        let mut raw_info = ptr::null_mut();
        assert_eq!(
            x3f_session_info(session, &mut raw_info, ptr::null_mut()),
            X3F_OK
        );
        let info: Value = serde_json::from_str(CStr::from_ptr(raw_info).to_str().unwrap()).unwrap();
        x3f_string_free(raw_info);
        let (w, h) = (
            info["width"].as_f64().unwrap() as f32,
            info["height"].as_f64().unwrap() as f32,
        );
        let default = info["defaultRecipe"].to_string();
        // Full frame, no straighten, no film: a stable reference.
        let full_recipe = patch(
            &default,
            json!({"crop": null, "straighten": 0, "rotation": 0}),
        );
        let full = render(session, &full_recipe, 1024).unwrap();
        let factor = 1024. / w.max(h);
        assert_eq!(
            (full.width, full.height),
            ((w * factor).round() as usize, (h * factor).round() as usize)
        );

        // Crop: size and pixel mapping. At max edge 512 a half-size crop has
        // the scale of the full frame at 1024.
        let crop = json!({"x": 0.25, "y": 0.25, "width": 0.5, "height": 0.5});
        let cropped = render(session, &patch(&full_recipe, json!({ "crop": crop })), 512).unwrap();
        let (cw, ch) = ((w * 0.5).round(), (h * 0.5).round());
        let f = 512. / cw.max(ch);
        assert_eq!(
            (cropped.width, cropped.height),
            ((cw * f).round() as usize, (ch * f).round() as usize)
        );
        let (ox, oy) = (
            (0.25 * full.width as f32).round() as usize,
            (0.25 * full.height as f32).round() as usize,
        );
        let right = difference(&cropped, &full, |x, y| (x + ox, y + oy));
        let wrong = difference(&cropped, &full, |x, y| (x + ox + 24, y + oy));
        eprintln!("crop mapping: {right:.2} (shifted {wrong:.2})");
        // The crop origin falls up to half a pixel off the reference grid,
        // so fine detail differs a little. A wrong mapping differs far more.
        assert!(
            right < 6. && wrong > 4. * right,
            "crop mapping {right} vs {wrong}"
        );

        // Quarter turns are clockwise and applied after the crop.
        let (fw, fh) = (full.width, full.height);
        for rotation in 1..=3 {
            let turned = render(
                session,
                &patch(&full_recipe, json!({ "rotation": rotation })),
                1024,
            )
            .unwrap();
            let expected = if rotation % 2 == 1 {
                (fh, fw)
            } else {
                (fw, fh)
            };
            assert_eq!(
                (turned.width, turned.height),
                expected,
                "rotation {rotation}"
            );
            // Output (u, v) to crop (a, b): r1 (v, 1-u), r2 (1-u, 1-v), r3 (1-v, u).
            let map = |r: u32| {
                move |x: usize, y: usize| match r {
                    1 => (y, fh - 1 - x),
                    2 => (fw - 1 - x, fh - 1 - y),
                    _ => (fw - 1 - y, x),
                }
            };
            let right = difference(&turned, &full, map(rotation));
            let wrong = difference(&turned, &full, map(4 - rotation));
            eprintln!("rotation {rotation}: {right:.2} (opposite {wrong:.2})");
            assert!(right < 1.5, "rotation {rotation} mapping {right}");
            if rotation != 2 {
                assert!(wrong > 4. * right.max(0.5), "rotation {rotation} direction");
            }
        }

        // A crop rotates with the image: crop size first, then the turn.
        let turned_crop = render(
            session,
            &patch(&full_recipe, json!({"crop": crop, "rotation": 1})),
            512,
        )
        .unwrap();
        assert_eq!(
            (turned_crop.width, turned_crop.height),
            (cropped.height, cropped.width)
        );

        // Curves darken and keep every other field.
        let curve = json!({"master": [{"x": 0, "y": 0}, {"x": 0.5, "y": 0.25}, {"x": 1, "y": 1}]});
        let curved_recipe = patch(&full_recipe, json!({ "curves": curve }));
        let (mut before, mut after): (Value, Value) = (
            serde_json::from_str(&full_recipe).unwrap(),
            serde_json::from_str(&curved_recipe).unwrap(),
        );
        assert_eq!(after["curves"]["master"][1], json!({"x": 0.5, "y": 0.25}));
        assert_eq!(after["curves"]["red"], before["curves"]["red"]);
        before.as_object_mut().unwrap().remove("curves");
        after.as_object_mut().unwrap().remove("curves");
        assert_eq!(before, after, "a curve patch keeps other fields");
        let curved = render(session, &curved_recipe, 1024).unwrap();
        eprintln!("curve mean {:.1} vs {:.1}", curved.mean(), full.mean());
        assert!(curved.mean() < full.mean() - 3.);
        for bad in [
            json!({"master": [{"x": 0, "y": 0}]}),
            json!({"master": [{"x": 0.1, "y": 0}, {"x": 1, "y": 1}]}),
            json!({"master": [{"x": 0, "y": 0}, {"x": 0.5, "y": 0.5}, {"x": 0.5, "y": 0.6}, {"x": 1, "y": 1}]}),
            json!({"master": [{"x": 0, "y": 0}, {"x": 1, "y": 1.5}]}),
        ] {
            let mut recipe: Value = serde_json::from_str(&full_recipe).unwrap();
            recipe["curves"]["master"] = bad["master"].clone();
            assert_eq!(
                normalize_status(&recipe.to_string()),
                X3F_ERR_INVALID,
                "{bad}"
            );
        }
        for bad in [
            json!({"crop": {"x": 0.5, "y": 0, "width": 0.6, "height": 1}}),
            json!({"crop": {"x": 0, "y": 0, "width": 0, "height": 1}}),
            json!({"rotation": 4}),
            json!({"denoise": 11}),
            json!({"denoiseOptions": {"strength": 5}}),
            json!({"denoiseOptions": {"nlm": {"lumaPatch": 4}}}),
            json!({"denoiseOptions": {"algorithm": "median"}}),
        ] {
            let mut recipe: Value = serde_json::from_str(&full_recipe).unwrap();
            for (key, value) in bad.as_object().unwrap() {
                recipe[key] = value.clone();
            }
            assert_eq!(
                normalize_status(&recipe.to_string()),
                X3F_ERR_INVALID,
                "{bad}"
            );
        }

        // Denoise prepares the RAW again; a cancelled preparation recovers.
        let base = render(session, &full_recipe, 512).unwrap();
        let off = patch(&full_recipe, json!({"denoise": 0}));
        let start = std::time::Instant::now();
        let plain = render(session, &off, 512).unwrap();
        eprintln!("denoise 0 re-prepare and render: {:?}", start.elapsed());
        let changed = difference(&plain, &base, |x, y| (x, y));
        eprintln!("denoise 0 vs 10: {changed:.3}");
        assert!(changed > 0.05, "denoise change must change pixels");
        let start = std::time::Instant::now();
        let again = render(session, &off, 512).unwrap();
        eprintln!("same denoise render (no prepare): {:?}", start.elapsed());
        assert_eq!(again.rgb, plain.rgb);

        let luma = patch(&full_recipe, json!({"denoiseOptions": {"luminance": true}}));
        let cancel = x3f_cancel_new();
        x3f_cancel_set(cancel);
        let mut frame = std::mem::zeroed::<X3fFrame>();
        let mut error = ptr::null_mut();
        assert_eq!(
            x3f_session_render(
                session,
                cs(&luma).as_ptr(),
                512,
                cancel,
                &mut frame,
                &mut error
            ),
            X3F_ERR_CANCELLED
        );
        message(error);
        x3f_cancel_free(cancel);
        // Cancel in the middle of a preparation from another thread.
        let cancel = x3f_cancel_new() as usize;
        let canceller = std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(150));
            x3f_cancel_set(cancel as *const X3fCancel);
        });
        let mut error = ptr::null_mut();
        let status = x3f_session_render(
            session,
            cs(&luma).as_ptr(),
            512,
            cancel as *const X3fCancel,
            &mut frame,
            &mut error,
        );
        canceller.join().unwrap();
        message(error);
        x3f_frame_free(&mut frame);
        x3f_cancel_free(cancel as *mut X3fCancel);
        eprintln!("timed cancel during prepare: status {status}");
        assert!(status == X3F_ERR_CANCELLED || status == X3F_OK);
        let with_luma = render(session, &luma, 512).unwrap();
        assert!(difference(&with_luma, &base, |x, y| (x, y)) > 0.0);
        // Back to the first settings gives the first pixels again.
        let restored = render(session, &full_recipe, 512).unwrap();
        assert_eq!(restored.rgb, base.rgb, "re-preparation is deterministic");

        x3f_session_free(session);
    }
}
