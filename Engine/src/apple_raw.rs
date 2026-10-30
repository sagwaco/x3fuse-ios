//! Validated input from the Apple RAW decoder. Metadata geometry is checked by Swift.
use super::*;
use serde::Deserialize;
use std::io::{Seek, SeekFrom};
use x3f_core::{SceneLinearImage, WhiteBalanceCalibration};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Metadata {
    width: u32,
    height: u32,
    #[serde(default)]
    original_width: Option<u32>,
    #[serde(default)]
    original_height: Option<u32>,
    orientation: u16,
    source_revision: String,
    decoder_identity: String,
    baseline_exposure: f64,
    as_shot_temperature: f32,
}

pub(crate) fn valid_identity(value: &str) -> bool {
    value.starts_with("apple-raw-v1:")
        && value.len() > 13
        && value.len() <= 256
        && value.bytes().all(|c| c.is_ascii_graphic())
        && value[13..]
            .split_once(':')
            .is_some_and(|(os, decoder)| !os.trim().is_empty() && !decoder.trim().is_empty())
}

// The pixels use RGB coordinates, so the camera matrix is identity. XYZ maps to
// linear sRGB; [1,1,1] is the already applied as-shot neutral.
fn calibration() -> WhiteBalanceCalibration {
    WhiteBalanceCalibration {
        camera_to_rgb: [1., 0., 0., 0., 1., 0., 0., 0., 1.],
        xyz_to_camera: [
            3.2404542, -1.5371385, -0.4985314, -0.9692660, 1.8760108, 0.0415560, 0.0556434,
            -0.2040259, 1.0572252,
        ],
        as_shot_neutral: [1.; 3],
    }
}

/// Check the TIFF signature and the IFD0 DNGVersion without decoding RAW data.
fn check_dng(path: &Path) -> Result<()> {
    let mut file = fs::File::open(path)?;
    let mut header = [0; 8];
    file.read_exact(&mut header)?;
    let little = match &header[..4] {
        b"II\x2a\0" => true,
        b"MM\0\x2a" => false,
        _ => return Err(invalid("Apple RAW source must be a classic TIFF DNG")),
    };
    let u16_at = |b: [u8; 2]| {
        if little {
            u16::from_le_bytes(b)
        } else {
            u16::from_be_bytes(b)
        }
    };
    let u32_at = |b: [u8; 4]| {
        if little {
            u32::from_le_bytes(b)
        } else {
            u32::from_be_bytes(b)
        }
    };
    let offset = u64::from(u32_at(header[4..8].try_into().unwrap()));
    if offset < 8 || offset > file.metadata()?.len().saturating_sub(2) {
        return Err(invalid("Invalid DNG directory"));
    }
    file.seek(SeekFrom::Start(offset))?;
    let mut count = [0; 2];
    file.read_exact(&mut count)?;
    let count = u64::from(u16_at(count));
    if offset + 2 + count * 12 + 4 > file.metadata()?.len() {
        return Err(invalid("Truncated DNG directory"));
    }
    let mut found = false;
    for _ in 0..count {
        let mut entry = [0; 12];
        file.read_exact(&mut entry)?;
        if u16_at(entry[..2].try_into().unwrap()) == 50706 {
            if found
                || u16_at(entry[2..4].try_into().unwrap()) != 1
                || u32_at(entry[4..8].try_into().unwrap()) != 4
                || entry[8] != 1
                || entry[9] > 7
            {
                return Err(invalid("Unsupported DNGVersion"));
            }
            found = true;
        }
    }
    if !found {
        return Err(invalid("Source has no DNGVersion"));
    }
    Ok(())
}

/// # Safety
/// See the public header. The buffer is borrowed only for this call.
#[no_mangle]
pub unsafe extern "C" fn x3f_session_open_apple_raw(
    source_path: *const c_char,
    rgba: *const f32,
    float_count: usize,
    metadata_json: *const c_char,
    cancel: *const X3fCancel,
    out: *mut *mut X3fSession,
    error: *mut *mut c_char,
) -> i32 {
    ffi(error, || {
        if out.is_null() {
            return Err(invalid("out is NULL"));
        }
        // SAFETY: the caller provides a writable output.
        unsafe {
            *out = ptr::null_mut();
        }
        let none = AtomicBool::new(false);
        let cancel = token(cancel, &none);
        check(cancel)?;
        // SAFETY: the caller provides NUL-terminated strings or NULL.
        let path = Path::new(unsafe { text(source_path, "source_path") }?);
        let json = unsafe { text(metadata_json, "metadata_json") }?;
        if json.len() > 4096 {
            return Err(invalid("Apple RAW metadata is too large"));
        }
        let m: Metadata =
            serde_json::from_str(json).map_err(|e| invalid(format!("Apple RAW: {e}")))?;
        let pixels = (m.width as usize)
            .checked_mul(m.height as usize)
            .filter(|&n| n > 0 && n <= 24_000_000)
            .ok_or_else(|| invalid("Apple RAW dimensions exceed 24 MP"))?;
        let original = match (m.original_width, m.original_height) {
            (None, None) => (m.width, m.height),
            (Some(w), Some(h))
                if w >= m.width && h >= m.height && u64::from(w) * u64::from(h) <= 100_000_000 =>
            {
                (w, h)
            }
            _ => return Err(invalid("Invalid Apple RAW original dimensions")),
        };
        if m.width == 0
            || m.height == 0
            || !(1..=8).contains(&m.orientation)
            || !m.baseline_exposure.is_finite()
            || !m.as_shot_temperature.is_finite()
            || m.as_shot_temperature <= 0.
            || !valid_identity(&m.decoder_identity)
            || m.source_revision.len() != 64
            || !m
                .source_revision
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            || float_count
                != pixels
                    .checked_mul(4)
                    .ok_or_else(|| invalid("RGBA size overflow"))?
            || float_count > isize::MAX as usize / std::mem::size_of::<f32>()
            || rgba.is_null()
            || !(rgba as usize).is_multiple_of(std::mem::align_of::<f32>())
        {
            return Err(invalid("Invalid Apple RAW metadata or RGBA buffer"));
        }
        if !fs::metadata(path)?.is_file() {
            return Err(invalid("Apple RAW source must be a regular file"));
        }
        let stamp = Stamp::read(path)?;
        check_dng(path)?;
        if sha256(path, cancel)? != m.source_revision || Stamp::read(path)? != stamp {
            return Err(Error(
                X3F_ERR_CONFLICT,
                "Apple RAW source changed during decode".into(),
            ));
        }
        let mut data = Vec::new();
        data.try_reserve_exact(pixels * 3)
            .map_err(|_| invalid("Cannot allocate Apple RAW RGB buffer"))?;
        // SAFETY: count, alignment and size are checked. The caller guarantees
        // that this many initialized floats remain readable for this call.
        let rgba = unsafe { std::slice::from_raw_parts(rgba, float_count) };
        for chunk in rgba.chunks(4 * 4096) {
            check(cancel)?;
            for p in chunk.as_chunks::<4>().0 {
                if p[3] != 1. || p[..3].iter().any(|c| !c.is_finite()) {
                    return Err(invalid("Apple RAW pixels must be finite with alpha one"));
                }
                data.extend_from_slice(&p[..3]);
            }
        }
        let prepared = PreparedImage::new(
            SceneLinearImage {
                data,
                width: m.width,
                height: m.height,
                orientation: m.orientation,
                white_balance: calibration(),
                color_mode_calibration: None,
            },
            cancel,
        )?
        .with_dng_source(false);
        check(cancel)?;
        if Stamp::read(path)? != stamp
            || sha256(path, cancel)? != m.source_revision
            || Stamp::read(path)? != stamp
        {
            return Err(Error(
                X3F_ERR_CONFLICT,
                "Apple RAW source changed during preparation".into(),
            ));
        }
        let default = EditRecipe {
            film: None,
            denoise: 0,
            sharpen: 50.,
            seed: u32::from_str_radix(&m.source_revision[..8], 16).unwrap_or(0),
            ..Default::default()
        };
        let size = if (5..=8).contains(&m.orientation) {
            (original.1, original.0)
        } else {
            original
        };
        let logical_dimensions = (original != (m.width, m.height)).then_some(original);
        let session = Session {
            path: path.into(),
            kind: Kind::Dng,
            revision: m.source_revision,
            profiles: Default::default(),
            prepared_key: scene_key(&default),
            default,
            size,
            as_shot: (m.as_shot_temperature, 0.),
            prepared: Some(prepared),
            stamp,
            decoder_identity: Some(m.decoder_identity),
            logical_dimensions,
        };
        session.check_recipe(&session.default)?;
        // SAFETY: out was checked and owns the new session after return.
        unsafe {
            *out = Box::into_raw(Box::new(X3fSession(Mutex::new(session))));
        }
        Ok(())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    struct Fixture(PathBuf);
    impl Fixture {
        fn new(name: &str) -> Self {
            let path =
                std::env::temp_dir().join(format!("apple-raw-{}-{name}.dng", std::process::id()));
            // A TIFF IFD0 with the required four-byte DNGVersion.
            fs::write(
                &path,
                [
                    b'I', b'I', 42, 0, 8, 0, 0, 0, 1, 0, 0x12, 0xc6, 1, 0, 4, 0, 0, 0, 1, 4, 0, 0,
                    0, 0, 0, 0,
                ],
            )
            .unwrap();
            Self(path)
        }
        fn metadata(&self) -> Value {
            json!({"width":2,"height":2,"orientation":1,
                "sourceRevision":sha256(&self.0,&AtomicBool::new(false)).unwrap(),
                "decoderIdentity":"apple-raw-v1:27.0-build:8.dng",
                "baselineExposure":0.,"asShotTemperature":6500.})
        }
        fn open(&self, pixels: &[f32], metadata: Value) -> std::result::Result<Session, i32> {
            let path = CString::new(self.0.to_str().unwrap()).unwrap();
            let meta = CString::new(metadata.to_string()).unwrap();
            let mut out = ptr::null_mut();
            let mut error = ptr::null_mut();
            let status = unsafe {
                x3f_session_open_apple_raw(
                    path.as_ptr(),
                    pixels.as_ptr(),
                    pixels.len(),
                    meta.as_ptr(),
                    ptr::null(),
                    &mut out,
                    &mut error,
                )
            };
            if status != X3F_OK {
                assert!(out.is_null());
                unsafe {
                    x3f_string_free(error);
                }
                return Err(status);
            }
            Ok(unsafe { Box::from_raw(out) }.0.into_inner().unwrap())
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_file(&self.0);
        }
    }
    fn rgba() -> Vec<f32> {
        [0.1, 0.2, 0.4, 1.].repeat(4)
    }

    #[test]
    fn full_and_reduced_render_keep_effect_geometry() {
        let f = Fixture::new("effects");
        let mut meta = f.metadata();
        meta["width"] = json!(63);
        meta["height"] = json!(47);
        meta["orientation"] = json!(6);
        let mut full = f
            .open(&[0.1, 0.2, 0.4, 1.].repeat(63 * 47), meta.clone())
            .unwrap();
        meta["originalWidth"] = json!(63);
        meta["originalHeight"] = json!(47);
        meta["width"] = json!(32);
        meta["height"] = json!(24);
        let mut proxy = f.open(&[0.1, 0.2, 0.4, 1.].repeat(32 * 24), meta).unwrap();
        let recipe = EditRecipe {
            rotation: 1,
            straighten: 7.,
            pitch: 9.,
            yaw: -4.,
            crop: Some(Crop {
                x: 0.13,
                y: 0.21,
                width: 0.67,
                height: 0.53,
            }),
            effects: Some(x3f_render::EffectsSettings {
                grain: true,
                halation: true,
                ..Default::default()
            }),
            ..full.default.clone()
        };
        let json = edits::canonical(&recipe);
        let options = RenderOptions {
            max_dimension: Some(12),
            rgba8: true,
            ..Default::default()
        };
        let cancel = AtomicBool::new(false);
        let a = full.render_with(&json, options, &cancel).unwrap();
        let b = proxy.render_with(&json, options, &cancel).unwrap();
        let baseline = full
            .render_with(
                &edits::canonical(&EditRecipe {
                    effects: None,
                    ..recipe.clone()
                }),
                options,
                &cancel,
            )
            .unwrap();
        assert_ne!(a.data, baseline.data);
        assert_eq!(
            (a.width, a.height, a.full_width, a.full_height),
            (b.width, b.height, b.full_width, b.full_height)
        );
        let (Pixels::Rgba8(a), Pixels::Rgba8(b)) = (a.data, b.data) else {
            panic!("Expected previews")
        };
        assert_eq!(&a[..FRAME_HEADER], &b[..FRAME_HEADER]);
        assert!(a[FRAME_HEADER..]
            .iter()
            .zip(&b[FRAME_HEADER..])
            .all(|(a, b)| a.abs_diff(*b) <= 1));
    }

    #[test]
    fn proxy_metadata_documents_and_export_contract() {
        let f = Fixture::new("proxy");
        let full = f.open(&rgba(), f.metadata()).unwrap();
        let doc = edits::new_document(&full.revision, full.default.clone(), 1, 0).unwrap();
        let mut doc = doc;
        doc.version = 3;
        doc.decoder_identity = full.decoder_identity.clone();
        assert!(full.logical_dimensions.is_none());
        for orientation in 1..=8 {
            let mut meta = f.metadata();
            meta["originalWidth"] = json!(9503);
            meta["originalHeight"] = json!(6337);
            meta["orientation"] = json!(orientation);
            let mut proxy = f.open(&rgba(), meta).unwrap();
            assert_eq!(proxy.decoder_identity, full.decoder_identity);
            assert!(proxy.document(&doc.to_json()).is_ok());
            let info: Value = serde_json::from_str(&proxy.info().unwrap()).unwrap();
            let expected = if orientation < 5 {
                (9503, 6337)
            } else {
                (6337, 9503)
            };
            assert_eq!(
                (
                    info["width"].as_u64().unwrap(),
                    info["height"].as_u64().unwrap()
                ),
                expected
            );
            assert_eq!(info["isProxy"], true);
            let path = std::env::temp_dir()
                .join(format!("apple-proxy-{}-{orientation}", std::process::id()));
            let cancel = AtomicBool::new(false);
            assert_eq!(
                proxy
                    .export_jpeg("{}", &path, 90, true, &cancel)
                    .unwrap_err()
                    .0,
                X3F_ERR_UNSUPPORTED
            );
            assert_eq!(
                proxy
                    .export_tiff("{}", &path, Default::default(), false, true, &cancel)
                    .unwrap_err()
                    .0,
                X3F_ERR_UNSUPPORTED
            );
            assert!(!path.exists());
            fs::write(&path, b"preserve").unwrap();
            assert!(proxy.export_jpeg("{}", &path, 90, true, &cancel).is_err());
            assert!(proxy
                .export_tiff("{}", &path, Default::default(), false, true, &cancel)
                .is_err());
            assert_eq!(fs::read(&path).unwrap(), b"preserve");
            fs::remove_file(path).unwrap();
        }
        for (w, h) in [
            (Some(4), None),
            (None, Some(4)),
            (Some(1), Some(4)),
            (Some(10001), Some(10000)),
            (Some(0), Some(0)),
        ] {
            let mut meta = f.metadata();
            if let Some(w) = w {
                meta["originalWidth"] = json!(w);
            }
            if let Some(h) = h {
                meta["originalHeight"] = json!(h);
            }
            assert_eq!(f.open(&rgba(), meta).err(), Some(X3F_ERR_INVALID));
        }
        let mut meta = f.metadata();
        meta["originalWidth"] = json!(2);
        meta["originalHeight"] = json!(2);
        let full = f.open(&rgba(), meta).unwrap();
        assert!(full.check_full_resolution().is_ok());
    }

    #[test]
    fn invalid_bridge_inputs_and_cancel() {
        let f = Fixture::new("invalid");
        let m = f.metadata();
        for (key, value) in [
            ("width", json!(0)),
            ("height", json!(24_000_001)),
            ("orientation", json!(9)),
            ("sourceRevision", json!("bad")),
            ("decoderIdentity", json!("apple-raw-v1:")),
            ("extra", json!(1)),
        ] {
            let mut bad = m.clone();
            bad[key] = value;
            assert_eq!(f.open(&rgba(), bad).err(), Some(X3F_ERR_INVALID), "{key}");
        }
        let mut bad = m.clone();
        bad["sourceRevision"] = json!("a".repeat(64));
        assert_eq!(f.open(&rgba(), bad).err(), Some(X3F_ERR_CONFLICT));
        for (i, v) in [
            (0, f32::NAN),
            (1, f32::INFINITY),
            (2, f32::NEG_INFINITY),
            (3, 0.5),
        ] {
            let mut p = rgba();
            p[i] = v;
            assert_eq!(f.open(&p, m.clone()).err(), Some(X3F_ERR_INVALID));
        }
        assert_eq!(
            f.open(&rgba()[..15], m.clone()).err(),
            Some(X3F_ERR_INVALID)
        );
        let path = CString::new(f.0.to_str().unwrap()).unwrap();
        let meta = CString::new(m.to_string()).unwrap();
        let mut out = ptr::null_mut();
        for p in [ptr::null(), ptr::dangling::<u8>().cast::<f32>()] {
            assert_eq!(
                unsafe {
                    x3f_session_open_apple_raw(
                        path.as_ptr(),
                        p,
                        16,
                        meta.as_ptr(),
                        ptr::null(),
                        &mut out,
                        ptr::null_mut(),
                    )
                },
                X3F_ERR_INVALID
            );
        }
        let cancel = x3f_cancel_new();
        unsafe {
            x3f_cancel_set(cancel);
        }
        assert!(unsafe { x3f_cancel_is_set(cancel) });
        assert!(!unsafe { x3f_cancel_is_set(ptr::null()) });
        assert_eq!(
            unsafe {
                x3f_session_open_apple_raw(
                    path.as_ptr(),
                    rgba().as_ptr(),
                    16,
                    meta.as_ptr(),
                    cancel,
                    &mut out,
                    ptr::null_mut(),
                )
            },
            X3F_ERR_CANCELLED
        );
        unsafe {
            x3f_cancel_free(cancel);
        }
        fs::write(&f.0, b"II*\0\0\0\0\0").unwrap();
        assert!(f.open(&rgba(), f.metadata()).is_err());
    }

    #[test]
    fn dng_recipe_document_and_source_contract() {
        let f = Fixture::new("contract");
        let mut p = rgba();
        p[0] = -0.25;
        p[1] = 2.;
        let s = f.open(&p, f.metadata()).unwrap();
        assert_eq!(
            &s.prepared.as_ref().unwrap().image().data[..3],
            &[-0.25, 2., 0.4]
        );
        let info: Value = serde_json::from_str(&s.info().unwrap()).unwrap();
        assert_eq!(info["kind"], "dng");
        assert_eq!(info["cameraProfiles"], json!([]));
        let base = serde_json::to_value(&s.default).unwrap();
        let mut changes = vec![
            ("temperature", json!(6500)),
            ("tint", json!(1)),
            ("whiteBalanceGains", json!([1, 1, 1])),
            ("cameraProfile", json!("Standard")),
            ("denoise", json!(1)),
            ("fillLight", json!(1)),
            ("x3iSource", json!("merge")),
            (
                "rawColor",
                json!({"gains":[1,1,1],"matrix":[1,0,0,0,1,0,0,0,1]}),
            ),
        ];
        for mode in [
            "default", "amaze", "dcb", "ahd", "eahd", "hphd", "igv", "lmmse", "vng", "ppg",
            "linear", "mono",
        ] {
            changes.push(("dngDemosaic", json!(mode)));
        }
        let mut options = base["denoiseOptions"].clone();
        let object = options.as_object_mut().unwrap();
        let key = object.keys().next().unwrap().clone();
        let old = object[&key].clone();
        object.insert(
            key,
            if old.is_boolean() {
                json!(!old.as_bool().unwrap())
            } else {
                json!(999)
            },
        );
        changes.push(("denoiseOptions", options));
        for (key, val) in changes {
            let mut bad = base.clone();
            bad[key] = val;
            assert!(s.recipe(&bad.to_string()).is_err(), "{key}");
        }
        let dir = std::env::temp_dir();
        let path = dir.join(format!("apple-raw-{}.json", std::process::id()));
        let document = s.write_sidecar(&path, &base.to_string(), 1, None).unwrap();
        assert_eq!(document.version, 3);
        assert_eq!(document.decoder_identity, s.decoder_identity);
        assert!(s.document(&document.to_json()).is_ok());
        let mut bad = serde_json::to_value(&document).unwrap();
        bad["decoderIdentity"] = json!("apple-raw-v1:other:8.dng");
        assert!(s.document(&bad.to_string()).is_err());
        fs::write(&path, bad.to_string()).unwrap();
        assert!(s.write_sidecar(&path, &base.to_string(), 2, None).is_err());
        assert_eq!(fs::read_to_string(&path).unwrap(), bad.to_string());
        let mut unsupported = serde_json::to_value(&document).unwrap();
        unsupported["recipe"]["denoise"] = json!(10);
        fs::write(&path, unsupported.to_string()).unwrap();
        assert!(s.document(&unsupported.to_string()).is_err());
        assert!(s.write_sidecar(&path, &base.to_string(), 2, None).is_err());
        assert_eq!(fs::read_to_string(&path).unwrap(), unsupported.to_string());
        let mut desktop = serde_json::to_value(&document).unwrap();
        desktop["version"] = json!(2);
        desktop.as_object_mut().unwrap().remove("decoderIdentity");
        assert!(s.document(&desktop.to_string()).is_err());
        assert_eq!(
            s.export_dng(
                &dir.join("never.dng"),
                None,
                false,
                false,
                &AtomicBool::new(false)
            )
            .unwrap_err()
            .0,
            X3F_ERR_UNSUPPORTED
        );
        fs::write(&f.0, b"changed").unwrap();
        assert_eq!(
            s.check_source(&AtomicBool::new(false)).unwrap_err().0,
            X3F_ERR_CONFLICT
        );
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn render_preserves_as_shot_rgb_and_orientation() {
        let f = Fixture::new("render");
        // Distinct colors expose channel swaps, orientation, repeated EV and WB.
        let p: Vec<f32> = [0.1, 0.2, 0.3, 0.4, 0.5, 0.7]
            .into_iter()
            .flat_map(|v| [v, v * 0.7, v * 0.4, 1.])
            .collect();
        let encode = |v: f32| ((1.055 * v.powf(1. / 2.4) - 0.055) * 255.).round() as u8;
        for orientation in 1..=8 {
            let mut meta = f.metadata();
            meta["orientation"] = json!(orientation);
            meta["height"] = json!(3);
            meta["baselineExposure"] = json!(2.);
            let mut s = f.open(&p, meta).unwrap();
            let r = EditRecipe {
                sharpen: 0.,
                ..s.default.clone()
            };
            let wb = x3f_render::recipe_white_balance(&calibration(), &r).unwrap();
            assert_eq!(wb.gains, [1.; 3]);
            let (frame, w, h) = s
                .render(&edits::canonical(&r), 3, &AtomicBool::new(false))
                .unwrap();
            assert_eq!((w, h), if orientation < 5 { (2, 3) } else { (3, 2) });
            let order = match orientation {
                1 => [0, 1, 2, 3, 4, 5],
                2 => [1, 0, 3, 2, 5, 4],
                3 => [5, 4, 3, 2, 1, 0],
                4 => [4, 5, 2, 3, 0, 1],
                5 => [0, 2, 4, 1, 3, 5],
                6 => [4, 2, 0, 5, 3, 1],
                7 => [5, 3, 1, 4, 2, 0],
                8 => [1, 3, 5, 0, 2, 4],
                _ => unreachable!(),
            };
            for (actual, i) in frame[FRAME_HEADER..].as_chunks::<4>().0.iter().zip(order) {
                let expected = [encode(p[i * 4]), encode(p[i * 4 + 1]), encode(p[i * 4 + 2])];
                assert!(
                    actual[..3]
                        .iter()
                        .zip(expected)
                        .all(|(v, e)| v.abs_diff(e) <= 1),
                    "orientation {orientation}: {actual:?} expected {expected:?}"
                );
                assert_eq!(actual[3], 255);
            }
        }
    }
}
