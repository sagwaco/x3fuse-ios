//! C ABI for the X3Fuse iOS editor. See `include/x3fuse_engine.h`.
//!
//! The engine prepares Sigma RAW as the desktop editor does: highlight
//! recovery on, the recipe denoise, the camera calibration from the file, and
//! `Renderer::render_prepared`. Apple RAW supplies validated decoded RGB.
mod apple_raw;
mod edits;
pub use apple_raw::x3f_session_open_apple_raw;
pub use edits::Document;
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{
    ffi::{c_char, c_void, CStr, CString},
    fs,
    io::Read,
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
pub const X3F_ERR_CONFLICT: i32 = 8;

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
    Dng,
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
    /// The source file identity when it was hashed.
    stamp: Stamp,
    decoder_identity: Option<String>,
    logical_dimensions: Option<(u32, u32)>,
}

/// Size, times and identity. A change means the hash must be read again.
#[derive(PartialEq, Eq)]
struct Stamp(u64, i64, i64, u64, u64, i64, i64);

impl Stamp {
    fn read(path: &Path) -> Result<Self> {
        use std::os::unix::fs::MetadataExt;
        let m = fs::metadata(path)?;
        Ok(Self(
            m.len(),
            m.mtime(),
            m.mtime_nsec(),
            m.dev(),
            m.ino(),
            m.ctime(),
            m.ctime_nsec(),
        ))
    }
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
        let stamp = Stamp::read(path)?;
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
            stamp,
            decoder_identity: None,
            logical_dimensions: None,
        })
    }

    pub fn info(&self) -> Result<String> {
        let (width, height) = self.size;
        let (temperature, tint) = self.as_shot;
        Ok(json!({
            "sourceRevision": self.revision,
            "decoderIdentity": self.decoder_identity,
            "renderVersion": RENDER_VERSION,
            "kind": match self.kind { Kind::X3f => "x3f", Kind::X3i => "x3i", Kind::Dng => "dng" },
            "width": width,
            "height": height,
            "isProxy": self.logical_dimensions.is_some(),
            "asShotTemperature": temperature,
            "asShotTint": tint,
            "cameraProfiles": self.profiles.available,
            "asShotProfile": self.profiles.as_shot,
            "defaultRecipe": self.default,
        })
        .to_string())
    }

    /// Parses a full recipe (a missing key takes `EditRecipe::default()`)
    /// and applies the rules of this source.
    pub fn recipe(&self, json: &str) -> Result<EditRecipe> {
        let recipe = edits::parse(json)?;
        self.check_recipe(&recipe)?;
        Ok(recipe)
    }

    fn check_recipe(&self, recipe: &EditRecipe) -> Result<()> {
        if self.kind == Kind::Dng {
            recipe.validate_dng(false).map_err(invalid)?;
            if recipe.temperature.is_some()
                || recipe.tint != 0.
                || recipe.white_balance_gains.is_some()
                || recipe.dng_demosaic.is_some()
            {
                return Err(invalid(
                    "Apple RAW supports only as-shot white balance and demosaic",
                ));
            }
            return Ok(());
        }
        if recipe.dng_demosaic.is_some() {
            return Err(invalid("dngDemosaic applies only to DNG"));
        }
        if recipe.x3i_source != X3iSource::MiddleExposure {
            return Err(Error(
                X3F_ERR_UNSUPPORTED,
                "X3I merging is unavailable on iOS. Use the middle exposure.".into(),
            ));
        }
        Ok(())
    }

    fn check_document_decoder(&self, document: &Document) -> Result<()> {
        if document.decoder_identity != self.decoder_identity
            || (self.kind == Kind::Dng) != (document.version == 3)
        {
            return Err(Error(
                X3F_ERR_UNSUPPORTED,
                "Incompatible edit decoder. The saved file has been preserved.".into(),
            ));
        }
        Ok(())
    }

    pub fn edited(&self, recipe: &EditRecipe) -> bool {
        !edits::matches_defaults(recipe, &self.default, false)
    }

    /// Checks a document for this source. Returns the source document version,
    /// and whether it holds an edit.
    pub fn document(&self, json: &str) -> Result<(Document, bool)> {
        let mut document = edits::parse_document(json)?;
        if document.source_revision != self.revision {
            return Err(Error(
                X3F_ERR_CONFLICT,
                "The saved edits belong to different source contents. The file has been preserved."
                    .into(),
            ));
        }
        self.check_recipe(&document.recipe)?;
        self.check_document_decoder(&document)?;
        let legacy = document.version == 1;
        let edited = !edits::matches_defaults(&document.recipe, &self.default, legacy);
        if !edited {
            document.recipe = self.default.clone();
        }
        document.version = if self.kind == Kind::Dng { 3 } else { 2 };
        Ok((document, edited))
    }

    /// Reads a document file of at most 1 MiB. None when there is no file.
    fn read_document_file(path: &Path) -> Result<Option<String>> {
        let file = match fs::File::open(path) {
            Ok(file) => file,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e.into()),
        };
        let mut bytes = Vec::new();
        file.take(edits::JSON_LIMIT as u64 + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() > edits::JSON_LIMIT {
            return Err(invalid("Edit document exceeds 1 MiB"));
        }
        String::from_utf8(bytes)
            .map(Some)
            .map_err(|_| invalid("Edit document is not UTF-8"))
    }

    pub fn read_sidecar(&self, path: &Path) -> Result<Option<(Document, bool)>> {
        Self::read_document_file(path)?
            .map(|json| self.document(&json))
            .transpose()
    }

    /// Fails when the source file no longer has the session hash.
    fn check_source(&self, cancel: &AtomicBool) -> Result<()> {
        if Stamp::read(&self.path)? != self.stamp && sha256(&self.path, cancel)? != self.revision {
            return Err(Error(
                X3F_ERR_CONFLICT,
                "Source contents changed; reopen the photo before saving".into(),
            ));
        }
        Ok(())
    }

    /// Check the file at `path` and `previous`, then save a document atomically.
    pub fn write_sidecar(
        &self,
        path: &Path,
        recipe: &str,
        revision: u64,
        previous: Option<&str>,
    ) -> Result<Document> {
        let recipe = self.recipe(recipe)?;
        edits::check_revision(revision)?;
        let target = self.target(path)?;
        let mut previous_ms = 0;
        let mut previous_documents = Vec::new();
        if let Some(json) = previous {
            previous_documents.push(edits::parse_document(json)?);
        }
        if let Some(json) = Self::read_document_file(&target)? {
            previous_documents.push(edits::parse_document(&json).map_err(|e| {
                Error(
                    X3F_ERR_CONFLICT,
                    format!(
                        "Cannot read the existing edits ({}). The file has been preserved.",
                        e.1
                    ),
                )
            })?);
        }
        for document in &previous_documents {
            self.check_document_decoder(document)?;
            self.check_recipe(&document.recipe)?;
            edits::check_previous(document, &self.revision, &recipe, revision)?;
            previous_ms = previous_ms.max(document.updated_ms);
        }
        self.check_source(&AtomicBool::new(false))?;
        let mut document = edits::new_document(&self.revision, recipe, revision, previous_ms)?;
        if self.kind == Kind::Dng {
            document.version = 3;
            document.decoder_identity = self.decoder_identity.clone();
        }
        let bytes = document.to_json();
        publish(&target, true, &AtomicBool::new(false), |temp| {
            fs::write(temp, bytes.as_bytes())?;
            Ok(())
        })?;
        Ok(document)
    }

    /// The canonical output path. Fails for the source RAW, also through
    /// another name.
    fn target(&self, out: &Path) -> Result<PathBuf> {
        let name = out
            .file_name()
            .ok_or_else(|| invalid("Output path has no file name"))?;
        let dir = out
            .parent()
            .filter(|d| !d.as_os_str().is_empty())
            .ok_or_else(|| invalid("Output path needs a directory"))?
            .canonicalize()?;
        let target = dir.join(name);
        let source = fs::metadata(&self.path)?;
        let same_file = |m: &fs::Metadata| {
            use std::os::unix::fs::MetadataExt;
            m.dev() == source.dev() && m.ino() == source.ino()
        };
        if target == self.path.canonicalize()? || fs::metadata(&target).is_ok_and(|m| same_file(&m))
        {
            return Err(invalid("Output cannot replace the source file"));
        }
        Ok(target)
    }

    fn render_with(
        &mut self,
        json: &str,
        mut options: RenderOptions,
        cancel: &AtomicBool,
    ) -> Result<x3f_render::RenderedImage> {
        options.logical_dimensions = self.logical_dimensions;
        let recipe = self.recipe(json)?;
        if self.kind == Kind::Dng {
            self.check_source(cancel)?;
        }
        let key = scene_key(&recipe);
        if self.prepared.is_none() || key != self.prepared_key {
            if self.kind == Kind::Dng {
                return Err(invalid("Reopen the DNG to change preparation"));
            }
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

    fn check_full_resolution(&self) -> Result<()> {
        if self.logical_dimensions.is_some() {
            return Err(Error(
                X3F_ERR_UNSUPPORTED,
                "Reopen the full-resolution source before export".into(),
            ));
        }
        Ok(())
    }

    pub fn export_jpeg(
        &mut self,
        json: &str,
        out: &Path,
        quality: u8,
        replace: bool,
        cancel: &AtomicBool,
    ) -> Result<()> {
        self.check_full_resolution()?;
        if !(1..=100).contains(&quality) {
            return Err(invalid("JPEG quality must be 1..100"));
        }
        let target = self.target(out)?;
        exists(&target, replace)?;
        let image = self.render_with(json, RenderOptions::default(), cancel)?;
        check(cancel)?;
        let bytes = image.jpeg(quality)?;
        drop(image);
        publish(&target, replace, cancel, |temp| {
            fs::write(temp, &bytes)?;
            Ok(())
        })
    }

    pub fn export_tiff(
        &mut self,
        json: &str,
        out: &Path,
        color_profile: x3f_render::ColorProfile,
        compress: bool,
        replace: bool,
        cancel: &AtomicBool,
    ) -> Result<()> {
        self.check_full_resolution()?;
        let target = self.target(out)?;
        exists(&target, replace)?;
        let image = self.render_with(
            json,
            RenderOptions {
                color_profile,
                ..Default::default()
            },
            cancel,
        )?;
        check(cancel)?;
        publish(&target, replace, cancel, |temp| {
            image.write_tiff(temp, compress, cancel)?;
            Ok(())
        })
    }

    /// The desktop batch DNG (conversion.rs `process_options` and `convert`).
    /// Returns the warnings.
    pub fn export_dng(
        &self,
        out: &Path,
        opcodes: Option<&Path>,
        highlight_recovery: bool,
        replace: bool,
        cancel: &AtomicBool,
    ) -> Result<Vec<String>> {
        if self.kind == Kind::Dng {
            return Err(Error(
                X3F_ERR_UNSUPPORTED,
                "DNG inputs cannot use Sigma DNG export".into(),
            ));
        }
        use x3f_core::ColorMode::{AsShot, Standard};
        if !highlight_recovery && opcodes.is_none_or(|dir| !dir.is_dir()) {
            return Err(invalid(
                "DNG export needs the opcodes folder for lens correction",
            ));
        }
        let target = self.target(out)?;
        exists(&target, replace)?;
        let mut options = x3f_core::ProcessOptions {
            color_encoding: x3f_core::ColorEncoding::Srgb,
            denoise_intensity: 10,
            denoise_options: Default::default(),
            compress: false,
            dng_highlight_recovery: highlight_recovery,
            color_mode: Some(AsShot),
            opcodes_dir: (!highlight_recovery).then(|| opcodes.unwrap().to_owned()),
            x3i_source: X3iSource::MiddleExposure,
            ..Default::default()
        };
        // Frame 0 holds the camera metadata of an X3I.
        let modes = match self.kind {
            Kind::Dng => return Err(invalid("DNG conversion requires a Sigma source")),
            Kind::X3f => x3f_core::Reader::open(&self.path),
            Kind::X3i => x3f_core::X3iContainer::open(&self.path).and_then(|c| c.open_frame(0)),
        }
        .and_then(|mut reader| reader.available_color_modes());
        if !modes.is_ok_and(|modes| modes.contains(&Standard)) {
            // As shot is the DNG default, so no Color Modes is not a warning.
            options.color_mode = None;
        }
        let mut warnings = Vec::new();
        publish(&target, replace, cancel, |temp| {
            let report = loop {
                match x3f_core::convert_file(
                    &self.path,
                    temp,
                    x3f_core::OutputFormat::Dng,
                    &options,
                    cancel,
                    |_| (),
                ) {
                    // Core reports an unusable mode as invalid data.
                    Err(x3f_core::Error::InvalidData(error)) if options.color_mode.is_some() => {
                        let used = (options.color_mode != Some(Standard)).then_some(Standard);
                        warnings.push(match used {
                            Some(_) => {
                                format!("Used the Standard color mode instead of as shot: {error}")
                            }
                            None => format!("Exported without a color mode: {error}"),
                        });
                        options.color_mode = used;
                    }
                    result => break result?,
                }
            };
            warnings.extend(report.warnings);
            Ok(())
        })?;
        Ok(warnings)
    }
}

/// Fails when `target` exists and `replace` is false.
fn exists(target: &Path, replace: bool) -> Result<()> {
    if !replace && fs::symlink_metadata(target).is_ok() {
        return Err(Error(X3F_ERR_EXISTS, "Export file exists".into()));
    }
    Ok(())
}

/// Writes through `write` to a temporary file next to `target`, syncs it,
/// then moves it to `target`. Without `replace`, an existing target is kept.
/// Removes the temporary file on error or cancel.
fn publish(
    target: &Path,
    replace: bool,
    cancel: &AtomicBool,
    write: impl FnOnce(&Path) -> Result<()>,
) -> Result<()> {
    let name = target.file_name().expect("target has a name");
    let mut temp_name = std::ffi::OsString::from(".");
    temp_name.push(name);
    temp_name.push(format!(".{}.partial", std::process::id()));
    let temp = target.with_file_name(temp_name);
    let _ = fs::remove_file(&temp);
    let written = (|| {
        write(&temp)?;
        fs::File::open(&temp)?.sync_all()?;
        check(cancel)?;
        if replace {
            fs::rename(&temp, target)?;
        } else {
            // A hard link fails when the target exists, so a file made since
            // the first check is kept.
            fs::hard_link(&temp, target).map_err(|e| match e.kind() {
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

/// Writes an owned string to `out`.
fn put(out: *mut *mut c_char, what: &str, value: String) -> Result<()> {
    if out.is_null() {
        return Err(invalid(format!("{what} is NULL")));
    }
    let value = CString::new(value).map_err(|e| invalid(e.to_string()))?;
    // SAFETY: checked for NULL.
    unsafe { *out = value.into_raw() };
    Ok(())
}

/// Sets an optional output pointer to NULL before work starts.
fn clear(out: *mut *mut c_char) {
    if !out.is_null() {
        // SAFETY: the caller passes a writable pointer or NULL.
        unsafe { *out = ptr::null_mut() };
    }
}

fn session<'a>(session: *const X3fSession) -> Result<std::sync::MutexGuard<'a, Session>> {
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
/// `cancel` is NULL or a live token.
#[no_mangle]
pub unsafe extern "C" fn x3f_cancel_is_set(cancel: *const X3fCancel) -> bool {
    // SAFETY: the caller keeps a non-NULL token alive.
    unsafe { cancel.as_ref() }.is_some_and(|c| c.0.load(Ordering::SeqCst))
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

/// # Safety
/// See the header.
#[no_mangle]
pub unsafe extern "C" fn x3f_session_export_tiff(
    s: *mut X3fSession,
    recipe_json: *const c_char,
    out_path: *const c_char,
    color_profile: u32,
    compress: bool,
    replace: bool,
    cancel: *const X3fCancel,
    error: *mut *mut c_char,
) -> i32 {
    ffi(error, || {
        // SAFETY: the caller passes strings or NULL.
        let json = unsafe { text(recipe_json, "recipe_json") }?;
        // SAFETY: as above.
        let out = unsafe { text(out_path, "out_path") }?;
        let profile = match color_profile {
            0 => x3f_render::ColorProfile::Srgb,
            1 => x3f_render::ColorProfile::AdobeRgb,
            2 => x3f_render::ColorProfile::ProPhotoRgb,
            _ => return Err(invalid("Unknown color profile")),
        };
        let none = AtomicBool::new(false);
        session(s)?.export_tiff(
            json,
            Path::new(out),
            profile,
            compress,
            replace,
            token(cancel, &none),
        )
    })
}

/// # Safety
/// See the header.
#[no_mangle]
pub unsafe extern "C" fn x3f_session_export_dng(
    s: *mut X3fSession,
    out_path: *const c_char,
    opcodes_dir: *const c_char,
    highlight_recovery: bool,
    replace: bool,
    cancel: *const X3fCancel,
    warnings_json: *mut *mut c_char,
    error: *mut *mut c_char,
) -> i32 {
    clear(warnings_json);
    ffi(error, || {
        // SAFETY: the caller passes strings or NULL.
        let out = unsafe { text(out_path, "out_path") }?;
        let opcodes = if opcodes_dir.is_null() {
            None
        } else {
            // SAFETY: as above.
            Some(Path::new(unsafe { text(opcodes_dir, "opcodes_dir") }?))
        };
        let none = AtomicBool::new(false);
        let warnings = session(s)?.export_dng(
            Path::new(out),
            opcodes,
            highlight_recovery,
            replace,
            token(cancel, &none),
        )?;
        if !warnings_json.is_null() {
            put(warnings_json, "warnings_json", json!(warnings).to_string())?;
        }
        Ok(())
    })
}

/// # Safety
/// See the header.
#[no_mangle]
pub unsafe extern "C" fn x3f_recipe_normalize(
    s: *const X3fSession,
    recipe_json: *const c_char,
    out_json: *mut *mut c_char,
    error: *mut *mut c_char,
) -> i32 {
    clear(out_json);
    ffi(error, || {
        // SAFETY: the caller passes a string or NULL.
        let json = unsafe { text(recipe_json, "recipe_json") }?;
        let recipe = if s.is_null() {
            edits::parse(json)?
        } else {
            session(s)?.recipe(json)?
        };
        put(out_json, "out_json", edits::canonical(&recipe))
    })
}

/// # Safety
/// See the header.
#[no_mangle]
pub unsafe extern "C" fn x3f_recipe_patch(
    recipe_json: *const c_char,
    patch_json: *const c_char,
    out_json: *mut *mut c_char,
    error: *mut *mut c_char,
) -> i32 {
    clear(out_json);
    ffi(error, || {
        // SAFETY: the caller passes strings or NULL.
        let recipe = unsafe { text(recipe_json, "recipe_json") }?;
        // SAFETY: as above.
        let patch = unsafe { text(patch_json, "patch_json") }?;
        put(
            out_json,
            "out_json",
            edits::canonical(&edits::patch(recipe, patch)?),
        )
    })
}

/// # Safety
/// See the header.
#[no_mangle]
pub unsafe extern "C" fn x3f_recipe_apply_look(
    recipe_json: *const c_char,
    look_id: *const c_char,
    out_json: *mut *mut c_char,
    error: *mut *mut c_char,
) -> i32 {
    clear(out_json);
    ffi(error, || {
        // SAFETY: the caller passes strings or NULL.
        let recipe = unsafe { text(recipe_json, "recipe_json") }?;
        // SAFETY: as above.
        let look = unsafe { text(look_id, "look_id") }?;
        put(
            out_json,
            "out_json",
            edits::canonical(&edits::apply_look(recipe, look)?),
        )
    })
}

/// # Safety
/// See the header.
#[no_mangle]
pub unsafe extern "C" fn x3f_recipe_edited(
    s: *const X3fSession,
    recipe_json: *const c_char,
    edited: *mut bool,
    error: *mut *mut c_char,
) -> i32 {
    ffi(error, || {
        // SAFETY: the caller passes a string or NULL.
        let json = unsafe { text(recipe_json, "recipe_json") }?;
        // SAFETY: the caller passes a writable pointer or NULL.
        let edited = unsafe { edited.as_mut() }.ok_or_else(|| invalid("edited is NULL"))?;
        let session = session(s)?;
        *edited = session.edited(&session.recipe(json)?);
        Ok(())
    })
}

/// # Safety
/// See the header.
#[no_mangle]
pub unsafe extern "C" fn x3f_film_catalog(
    out_json: *mut *mut c_char,
    error: *mut *mut c_char,
) -> i32 {
    clear(out_json);
    ffi(error, || put(out_json, "out_json", edits::catalog()))
}

/// Writes a document, its canonical recipe and the edited flag.
fn put_document(
    document: &Document,
    is_edited: bool,
    out_json: *mut *mut c_char,
    out_recipe_json: *mut *mut c_char,
    edited: *mut bool,
) -> Result<()> {
    put(out_json, "out_json", document.to_json())?;
    if !out_recipe_json.is_null() {
        put(
            out_recipe_json,
            "out_recipe_json",
            edits::canonical(&document.recipe),
        )?;
    }
    // SAFETY: the caller passes a writable pointer or NULL.
    if let Some(edited) = unsafe { edited.as_mut() } {
        *edited = is_edited;
    }
    Ok(())
}

/// Frees what an output pointer holds after a failure.
fn release(out: *mut *mut c_char) {
    if !out.is_null() {
        // SAFETY: the caller passes a writable pointer; the value is NULL or ours.
        unsafe {
            x3f_string_free(*out);
            *out = ptr::null_mut();
        }
    }
}

/// # Safety
/// See the header.
#[no_mangle]
pub unsafe extern "C" fn x3f_document_validate(
    s: *const X3fSession,
    document_json: *const c_char,
    out_json: *mut *mut c_char,
    out_recipe_json: *mut *mut c_char,
    edited: *mut bool,
    error: *mut *mut c_char,
) -> i32 {
    clear(out_json);
    clear(out_recipe_json);
    let status = ffi(error, || {
        // SAFETY: the caller passes a string or NULL.
        let json = unsafe { text(document_json, "document_json") }?;
        let (document, is_edited) = session(s)?.document(json)?;
        put_document(&document, is_edited, out_json, out_recipe_json, edited)
    });
    if status != X3F_OK {
        release(out_json);
        release(out_recipe_json);
    }
    status
}

/// # Safety
/// See the header.
#[no_mangle]
pub unsafe extern "C" fn x3f_document_check_previous(
    previous_json: *const c_char,
    incoming_json: *const c_char,
    error: *mut *mut c_char,
) -> i32 {
    ffi(error, || {
        // SAFETY: the caller passes strings or NULL.
        let previous = edits::parse_document(unsafe { text(previous_json, "previous_json") }?)?;
        // SAFETY: as above.
        let incoming = edits::parse_document(unsafe { text(incoming_json, "incoming_json") }?)?;
        if previous.decoder_identity != incoming.decoder_identity {
            return Err(Error(
                X3F_ERR_CONFLICT,
                "Edit decoder identity differs".into(),
            ));
        }
        edits::check_previous(
            &previous,
            &incoming.source_revision,
            &incoming.recipe,
            incoming.revision,
        )
    })
}

/// # Safety
/// See the header.
#[no_mangle]
pub unsafe extern "C" fn x3f_sidecar_read(
    s: *const X3fSession,
    path: *const c_char,
    out_json: *mut *mut c_char,
    out_recipe_json: *mut *mut c_char,
    edited: *mut bool,
    error: *mut *mut c_char,
) -> i32 {
    clear(out_json);
    clear(out_recipe_json);
    let status = ffi(error, || {
        // SAFETY: the caller passes a string or NULL.
        let path = unsafe { text(path, "path") }?;
        if out_json.is_null() {
            return Err(invalid("out_json is NULL"));
        }
        match session(s)?.read_sidecar(Path::new(path))? {
            Some((document, is_edited)) => {
                put_document(&document, is_edited, out_json, out_recipe_json, edited)
            }
            None => Ok(()),
        }
    });
    if status != X3F_OK {
        release(out_json);
        release(out_recipe_json);
    }
    status
}

/// # Safety
/// See the header.
#[no_mangle]
pub unsafe extern "C" fn x3f_sidecar_write(
    s: *const X3fSession,
    path: *const c_char,
    recipe_json: *const c_char,
    revision: u64,
    previous_json: *const c_char,
    out_json: *mut *mut c_char,
    error: *mut *mut c_char,
) -> i32 {
    clear(out_json);
    ffi(error, || {
        // SAFETY: the caller passes strings or NULL.
        let path = unsafe { text(path, "path") }?;
        // SAFETY: as above.
        let recipe = unsafe { text(recipe_json, "recipe_json") }?;
        let previous = if previous_json.is_null() {
            None
        } else {
            // SAFETY: as above.
            Some(unsafe { text(previous_json, "previous_json") }?)
        };
        let document = session(s)?.write_sidecar(Path::new(path), recipe, revision, previous)?;
        if !out_json.is_null() {
            put(out_json, "out_json", document.to_json())?;
        }
        Ok(())
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
