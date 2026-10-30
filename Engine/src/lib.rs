//! C ABI for the X3Fuse iOS editor. See `include/x3fuse_engine.h`.
//!
//! The engine prepares the RAW the same way as the desktop editor: highlight
//! recovery on, the recipe denoise, the camera calibration from the file, and
//! `Renderer::render_prepared`.
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    ffi::{c_char, c_void, CStr, CString},
    fs,
    io::{Read, Write},
    panic::{catch_unwind, AssertUnwindSafe},
    path::{Path, PathBuf},
    ptr,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
};
use x3f_core::{SceneLinearOptions, X3iSource};
use x3f_render::{
    Crop, EditRecipe, Pixels, PreparedImage, RenderError, RenderOptions, Renderer, FRAME_HEADER,
    RENDER_VERSION,
};

pub const X3F_OK: i32 = 0;
pub const X3F_ERR_INVALID: i32 = 1;
pub const X3F_ERR_UNSUPPORTED: i32 = 2;
pub const X3F_ERR_CANCELLED: i32 = 3;
pub const X3F_ERR_GPU: i32 = 4;
pub const X3F_ERR_IO: i32 = 5;
pub const X3F_ERR_INTERNAL: i32 = 6;
pub const X3F_ERR_EXISTS: i32 = 7;

#[derive(Debug)]
pub struct Error(i32, String);
type Result<T> = std::result::Result<T, Error>;

fn invalid(message: impl Into<String>) -> Error {
    Error(X3F_ERR_INVALID, message.into())
}
impl From<RenderError> for Error {
    fn from(e: RenderError) -> Self {
        let code = match e {
            RenderError::Invalid(_) => X3F_ERR_INVALID,
            RenderError::Gpu(_) => X3F_ERR_GPU,
            RenderError::Cancelled => X3F_ERR_CANCELLED,
            RenderError::Io(_) => X3F_ERR_IO,
            RenderError::Image(_) => X3F_ERR_INTERNAL,
        };
        Self(code, e.to_string())
    }
}
impl From<x3f_core::Error> for Error {
    fn from(e: x3f_core::Error) -> Self {
        let code = match e {
            x3f_core::Error::Cancelled => X3F_ERR_CANCELLED,
            x3f_core::Error::Gpu(_) => X3F_ERR_GPU,
            x3f_core::Error::OpenInput { .. } => X3F_ERR_IO,
            _ => X3F_ERR_INVALID,
        };
        Self(code, e.to_string())
    }
}
impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Self(X3F_ERR_IO, e.to_string())
    }
}

fn check(cancel: &AtomicBool) -> Result<()> {
    if cancel.load(Ordering::SeqCst) {
        Err(Error(X3F_ERR_CANCELLED, "Cancelled".into()))
    } else {
        Ok(())
    }
}

/// One GPU device for all sessions. A GPU error drops it, so that the next
/// call makes a new one, as after a device loss in the background.
static RENDERER: Mutex<Option<Arc<Renderer>>> = Mutex::new(None);

fn renderer() -> Result<Arc<Renderer>> {
    let mut slot = RENDERER
        .lock()
        .map_err(|_| Error(X3F_ERR_INTERNAL, "Renderer unavailable".into()))?;
    if slot.is_none() {
        *slot = Some(Arc::new(Renderer::new()?));
    }
    Ok(slot.clone().unwrap())
}

fn forget_renderer_on_gpu_error<T>(result: Result<T>) -> Result<T> {
    if matches!(result, Err(Error(X3F_ERR_GPU, _))) {
        if let Ok(mut slot) = RENDERER.lock() {
            *slot = None;
        }
    }
    result
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    X3f,
    X3i,
}

/// Reads the magic bytes. Only X3F and X3I open.
pub fn source_kind(path: &Path) -> Result<Kind> {
    let mut magic = [0; 4];
    fs::File::open(path)?
        .read_exact(&mut magic)
        .map_err(|_| Error(X3F_ERR_UNSUPPORTED, "Unsupported file: too short".into()))?;
    match &magic {
        b"FOVb" => Ok(Kind::X3f),
        b"FOVi" => Ok(Kind::X3i),
        _ => Err(Error(
            X3F_ERR_UNSUPPORTED,
            "Unsupported file: only X3F and X3I open".into(),
        )),
    }
}

fn sha256(path: &Path, cancel: &AtomicBool) -> Result<String> {
    let mut file = fs::File::open(path)?;
    let mut digest = Sha256::new();
    let mut bytes = vec![0; 1 << 20];
    loop {
        check(cancel)?;
        let n = file.read(&mut bytes)?;
        if n == 0 {
            return Ok(format!("{:x}", digest.finalize()));
        }
        digest.update(&bytes[..n]);
    }
}

/// The preparation settings that change the scene.
fn scene_key(recipe: &EditRecipe) -> String {
    serde_json::to_string(&(recipe.denoise, recipe.denoise_options)).unwrap_or_default()
}

pub struct Session {
    path: PathBuf,
    kind: Kind,
    revision: String,
    profiles: x3f_render::CameraProfiles,
    default: EditRecipe,
    /// Oriented size before crop, and the as-shot temperature and tint.
    size: (u32, u32),
    as_shot: (f32, f32),
    /// None after a failed or cancelled preparation. The next render retries.
    prepared: Option<PreparedImage>,
    prepared_key: String,
}

fn prepare(
    path: &Path,
    recipe: &EditRecipe,
    profiles: &x3f_render::CameraProfiles,
    cancel: &AtomicBool,
) -> Result<PreparedImage> {
    let options = SceneLinearOptions {
        denoise_intensity: recipe.denoise,
        denoise_options: recipe.denoise_options,
        highlight_recovery: true,
        x3i_source: X3iSource::MiddleExposure,
        ..Default::default()
    };
    let scene = x3f_core::prepare_scene_linear(path, &options, cancel, |_| ())?;
    Ok(PreparedImage::new(scene, cancel)?.with_camera_profiles(profiles.clone()))
}

impl Session {
    pub fn open(path: &Path, cancel: &AtomicBool) -> Result<Self> {
        let kind = source_kind(path)?;
        let revision = sha256(path, cancel)?;
        let profiles = x3f_render::read_camera_profiles(path, cancel)?;
        let crop = x3f_core::read_as_shot_crop(path)?.map(|[x, y, width, height]| Crop {
            x,
            y,
            width,
            height,
        });
        // The desktop editor's as-shot recipe (editor.rs `as_shot_recipe`).
        let default = EditRecipe {
            camera_profile: Some(profiles.as_shot.clone()),
            film: None,
            monochrome: (profiles.as_shot == "Monochrome")
                .then(x3f_render::MonochromeSettings::default),
            crop,
            sharpen: 50.,
            seed: u32::from_str_radix(&revision[..8], 16).unwrap_or(0),
            ..Default::default()
        };
        default.validate().map_err(invalid)?;
        let prepared = prepare(path, &default, &profiles, cancel)?;
        check(cancel)?;
        let size = x3f_render::output_dimensions(
            prepared.image(),
            &EditRecipe {
                crop: None,
                ..default.clone()
            },
        )?;
        Ok(Self {
            path: path.into(),
            kind,
            revision,
            prepared_key: scene_key(&default),
            profiles,
            default,
            size,
            as_shot: prepared.as_shot_white_balance(),
            prepared: Some(prepared),
        })
    }

    pub fn info(&self) -> Result<String> {
        let (width, height) = self.size;
        let (temperature, tint) = self.as_shot;
        Ok(json!({
            "sourceRevision": self.revision,
            "renderVersion": RENDER_VERSION,
            "kind": match self.kind { Kind::X3f => "x3f", Kind::X3i => "x3i" },
            "width": width,
            "height": height,
            "asShotTemperature": temperature,
            "asShotTint": tint,
            "cameraProfiles": self.profiles.available,
            "asShotProfile": self.profiles.as_shot,
            "defaultRecipe": self.default,
        })
        .to_string())
    }

    /// Replaces the top-level keys of the default recipe with those of `json`.
    pub fn recipe(&self, json: &str) -> Result<EditRecipe> {
        let edits: serde_json::Map<String, Value> =
            serde_json::from_str(json).map_err(|e| invalid(format!("Recipe JSON: {e}")))?;
        let Value::Object(mut recipe) =
            serde_json::to_value(&self.default).map_err(|e| invalid(e.to_string()))?
        else {
            unreachable!("a struct serializes as an object")
        };
        recipe.extend(edits);
        let recipe: EditRecipe = serde_json::from_value(Value::Object(recipe))
            .map_err(|e| invalid(format!("Recipe: {e}")))?;
        recipe.validate().map_err(invalid)?;
        if recipe.dng_demosaic.is_some() {
            return Err(invalid("dngDemosaic applies only to DNG"));
        }
        if self.kind == Kind::X3i && recipe.x3i_source != X3iSource::MiddleExposure {
            return Err(Error(
                X3F_ERR_UNSUPPORTED,
                "X3I merging is unavailable on iOS. Use the middle exposure.".into(),
            ));
        }
        Ok(recipe)
    }

    fn render_with(
        &mut self,
        json: &str,
        options: RenderOptions,
        cancel: &AtomicBool,
    ) -> Result<x3f_render::RenderedImage> {
        let recipe = self.recipe(json)?;
        let key = scene_key(&recipe);
        if self.prepared.is_none() || key != self.prepared_key {
            // Free the old scene and its GPU texture first to bound memory.
            self.prepared = None;
            self.prepared = Some(prepare(&self.path, &recipe, &self.profiles, cancel)?);
            self.prepared_key = key;
        }
        let prepared = self.prepared.as_ref().unwrap();
        let renderer = renderer()?;
        forget_renderer_on_gpu_error(
            renderer
                .render_prepared(prepared, &recipe, options, cancel)
                .map_err(Error::from),
        )
    }

    /// Returns the RGBA8 frame with its `FRAME_HEADER`, width and height.
    pub fn render(
        &mut self,
        json: &str,
        max_edge: u32,
        cancel: &AtomicBool,
    ) -> Result<(Vec<u8>, u32, u32)> {
        if !(1..=4096).contains(&max_edge) {
            return Err(invalid("max_edge must be 1..4096"));
        }
        let image = self.render_with(
            json,
            RenderOptions {
                max_dimension: Some(max_edge),
                rgba8: true,
                ..Default::default()
            },
            cancel,
        )?;
        let Pixels::Rgba8(frame) = image.data else {
            return Err(Error(X3F_ERR_INTERNAL, "Expected an RGBA8 frame".into()));
        };
        if frame.len() != FRAME_HEADER + image.width as usize * image.height as usize * 4 {
            return Err(Error(X3F_ERR_INTERNAL, "Frame size mismatch".into()));
        }
        Ok((frame, image.width, image.height))
    }

    pub fn export_jpeg(
        &mut self,
        json: &str,
        out: &Path,
        quality: u8,
        replace: bool,
        cancel: &AtomicBool,
    ) -> Result<()> {
        if !(1..=100).contains(&quality) {
            return Err(invalid("JPEG quality must be 1..100"));
        }
        let name = out
            .file_name()
            .ok_or_else(|| invalid("Output path has no file name"))?;
        let dir = out
            .parent()
            .filter(|d| !d.as_os_str().is_empty())
            .ok_or_else(|| invalid("Output path needs a directory"))?
            .canonicalize()?;
        let target = dir.join(name);
        // Never write over the source RAW, also through another name.
        let source = fs::metadata(&self.path)?;
        let same_file = |m: &fs::Metadata| {
            use std::os::unix::fs::MetadataExt;
            m.dev() == source.dev() && m.ino() == source.ino()
        };
        if target == self.path.canonicalize()? || fs::metadata(&target).is_ok_and(|m| same_file(&m))
        {
            return Err(invalid("Export cannot replace the source file"));
        }
        if !replace && fs::symlink_metadata(&target).is_ok() {
            return Err(Error(X3F_ERR_EXISTS, "Export file exists".into()));
        }
        let image = self.render_with(json, RenderOptions::default(), cancel)?;
        check(cancel)?;
        let bytes = image.jpeg(quality)?;
        drop(image);
        let mut temp_name = std::ffi::OsString::from(".");
        temp_name.push(name);
        temp_name.push(format!(".{}.partial", std::process::id()));
        let temp = dir.join(temp_name);
        let written = (|| {
            let mut file = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&temp)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
            check(cancel)?;
            if replace {
                fs::rename(&temp, &target)?;
            } else {
                // A hard link fails when the target exists, so a file made
                // since the check above is kept.
                fs::hard_link(&temp, &target).map_err(|e| match e.kind() {
                    std::io::ErrorKind::AlreadyExists => {
                        Error(X3F_ERR_EXISTS, "Export file exists".into())
                    }
                    _ => e.into(),
                })?;
                fs::remove_file(&temp)?;
            }
            Ok(())
        })();
        if written.is_err() {
            let _ = fs::remove_file(&temp);
        }
        written
    }
}

// C boundary.

pub struct X3fSession(Mutex<Session>);
pub struct X3fCancel(AtomicBool);

#[repr(C)]
pub struct X3fFrame {
    pub bytes: *const u8,
    pub len: usize,
    pub width: u32,
    pub height: u32,
    pub stride: u32,
    pub owner: *mut c_void,
}

/// Runs `f`, catches a panic, and writes an owned error message.
fn ffi(error: *mut *mut c_char, f: impl FnOnce() -> Result<()>) -> i32 {
    let (code, message) = match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(())) => return X3F_OK,
        Ok(Err(Error(code, message))) => (code, message),
        Err(_) => (X3F_ERR_INTERNAL, "Engine panic".into()),
    };
    if !error.is_null() {
        let message = CString::new(message.replace('\0', " ")).unwrap_or_default();
        // SAFETY: the caller passes a writable pointer or NULL.
        unsafe { *error = message.into_raw() };
    }
    code
}

/// # Safety
/// `s` is NULL or a valid NUL-terminated string.
unsafe fn text<'a>(s: *const c_char, what: &str) -> Result<&'a str> {
    if s.is_null() {
        return Err(invalid(format!("{what} is NULL")));
    }
    // SAFETY: checked for NULL; the caller guarantees NUL termination.
    unsafe { CStr::from_ptr(s) }
        .to_str()
        .map_err(|_| invalid(format!("{what} is not UTF-8")))
}

fn token(cancel: *const X3fCancel, none: &AtomicBool) -> &AtomicBool {
    // SAFETY: the caller keeps a non-NULL token alive during the call.
    unsafe { cancel.as_ref() }.map_or(none, |c| &c.0)
}

fn session<'a>(session: *mut X3fSession) -> Result<std::sync::MutexGuard<'a, Session>> {
    // SAFETY: the caller passes a live session or NULL.
    let session = unsafe { session.as_ref() }.ok_or_else(|| invalid("session is NULL"))?;
    session
        .0
        .lock()
        .map_err(|_| Error(X3F_ERR_INTERNAL, "Session unusable after a panic".into()))
}

#[no_mangle]
pub extern "C" fn x3f_render_version() -> u32 {
    RENDER_VERSION
}

#[no_mangle]
pub extern "C" fn x3f_cancel_new() -> *mut X3fCancel {
    Box::into_raw(Box::new(X3fCancel(AtomicBool::new(false))))
}

/// # Safety
/// `cancel` is NULL or a live token.
#[no_mangle]
pub unsafe extern "C" fn x3f_cancel_set(cancel: *const X3fCancel) {
    // SAFETY: see above.
    if let Some(cancel) = unsafe { cancel.as_ref() } {
        cancel.0.store(true, Ordering::SeqCst);
    }
}

/// # Safety
/// `cancel` is NULL or a token from `x3f_cancel_new` that no call still uses.
#[no_mangle]
pub unsafe extern "C" fn x3f_cancel_free(cancel: *mut X3fCancel) {
    if !cancel.is_null() {
        // SAFETY: see above.
        drop(unsafe { Box::from_raw(cancel) });
    }
}

/// # Safety
/// See the header.
#[no_mangle]
pub unsafe extern "C" fn x3f_session_open(
    path: *const c_char,
    cancel: *const X3fCancel,
    out: *mut *mut X3fSession,
    error: *mut *mut c_char,
) -> i32 {
    ffi(error, || {
        if out.is_null() {
            return Err(invalid("out is NULL"));
        }
        // SAFETY: checked for NULL.
        unsafe { *out = ptr::null_mut() };
        // SAFETY: the caller passes a string or NULL.
        let path = unsafe { text(path, "path") }?;
        let none = AtomicBool::new(false);
        let session = Session::open(Path::new(path), token(cancel, &none))?;
        // SAFETY: checked for NULL.
        unsafe { *out = Box::into_raw(Box::new(X3fSession(Mutex::new(session)))) };
        Ok(())
    })
}

/// # Safety
/// See the header.
#[no_mangle]
pub unsafe extern "C" fn x3f_session_info(
    s: *mut X3fSession,
    out_json: *mut *mut c_char,
    error: *mut *mut c_char,
) -> i32 {
    ffi(error, || {
        if out_json.is_null() {
            return Err(invalid("out_json is NULL"));
        }
        let json = CString::new(session(s)?.info()?).map_err(|e| invalid(e.to_string()))?;
        // SAFETY: checked for NULL.
        unsafe { *out_json = json.into_raw() };
        Ok(())
    })
}

/// # Safety
/// See the header.
#[no_mangle]
pub unsafe extern "C" fn x3f_session_render(
    s: *mut X3fSession,
    recipe_json: *const c_char,
    max_edge: u32,
    cancel: *const X3fCancel,
    out: *mut X3fFrame,
    error: *mut *mut c_char,
) -> i32 {
    ffi(error, || {
        // SAFETY: the caller passes a writable frame or NULL.
        let out = unsafe { out.as_mut() }.ok_or_else(|| invalid("out is NULL"))?;
        *out = X3fFrame::EMPTY;
        // SAFETY: the caller passes a string or NULL.
        let json = unsafe { text(recipe_json, "recipe_json") }?;
        let none = AtomicBool::new(false);
        let (frame, width, height) = session(s)?.render(json, max_edge, token(cancel, &none))?;
        let frame = Box::new(frame);
        *out = X3fFrame {
            bytes: frame[FRAME_HEADER..].as_ptr(),
            len: frame.len() - FRAME_HEADER,
            width,
            height,
            stride: width * 4,
            owner: Box::into_raw(frame).cast(),
        };
        Ok(())
    })
}

/// # Safety
/// See the header.
#[no_mangle]
pub unsafe extern "C" fn x3f_session_export_jpeg(
    s: *mut X3fSession,
    recipe_json: *const c_char,
    out_path: *const c_char,
    quality: u8,
    replace: bool,
    cancel: *const X3fCancel,
    error: *mut *mut c_char,
) -> i32 {
    ffi(error, || {
        // SAFETY: the caller passes strings or NULL.
        let json = unsafe { text(recipe_json, "recipe_json") }?;
        // SAFETY: as above.
        let out = unsafe { text(out_path, "out_path") }?;
        let none = AtomicBool::new(false);
        session(s)?.export_jpeg(json, Path::new(out), quality, replace, token(cancel, &none))
    })
}

impl X3fFrame {
    const EMPTY: Self = Self {
        bytes: ptr::null(),
        len: 0,
        width: 0,
        height: 0,
        stride: 0,
        owner: ptr::null_mut(),
    };
}

/// # Safety
/// `frame` is NULL or a frame from `x3f_session_render`, zero or not.
#[no_mangle]
pub unsafe extern "C" fn x3f_frame_free(frame: *mut X3fFrame) {
    // SAFETY: see above.
    let Some(frame) = (unsafe { frame.as_mut() }) else {
        return;
    };
    if !frame.owner.is_null() {
        // SAFETY: owner is the boxed frame from `x3f_session_render`.
        drop(unsafe { Box::from_raw(frame.owner.cast::<Vec<u8>>()) });
    }
    *frame = X3fFrame::EMPTY;
}

/// # Safety
/// `s` is NULL or a session with no call in progress.
#[no_mangle]
pub unsafe extern "C" fn x3f_session_free(s: *mut X3fSession) {
    if !s.is_null() {
        // SAFETY: see above.
        drop(unsafe { Box::from_raw(s) });
    }
}

/// # Safety
/// `string` is NULL or a string from this engine.
#[no_mangle]
pub unsafe extern "C" fn x3f_string_free(string: *mut c_char) {
    if !string.is_null() {
        // SAFETY: see above.
        drop(unsafe { CString::from_raw(string) });
    }
}
