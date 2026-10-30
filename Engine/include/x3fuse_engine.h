/*
 * X3Fuse engine C ABI.
 *
 * Rules:
 * - Functions that return X3fStatus write *error only on failure. The error is
 *   an owned UTF-8 string. Free it with x3f_string_free. Pass NULL for error to
 *   ignore it. Owned JSON outputs are also freed with x3f_string_free.
 * - open, info, render and export block. Never call them on the main thread.
 *   Call them from one serial worker.
 * - Keep one live session at a time on iOS. Free the old session before you
 *   open the next one. All sessions share one GPU device.
 * - Free a session only after every call on it has returned.
 * - Use a new X3fCancel for each job. x3f_cancel_set is safe from any thread.
 *   The engine only reads the token and does not keep it after a call returns.
 * - x3f_frame_free and x3f_string_free are safe from any thread.
 * - Strings in and out are UTF-8 and NUL terminated.
 *
 * Recipes:
 * - A recipe is the desktop EditRecipe JSON object. A missing key takes the
 *   EditRecipe default, as on the desktop: "film" missing means film ON with
 *   default settings, "cameraProfile" missing means none, "sharpen" missing
 *   means 0. It is not the session defaultRecipe.
 * - Start from defaultRecipe (x3f_session_info), a sidecar recipe, or the
 *   output of x3f_recipe_normalize, x3f_recipe_patch or x3f_recipe_apply_look.
 *   Store the canonical JSON the engine returns. Do not rebuild a recipe from
 *   a subset of fields.
 * - Unknown keys are rejected everywhere.
 */
#ifndef X3FUSE_ENGINE_H
#define X3FUSE_ENGINE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    X3F_OK = 0,
    X3F_ERR_INVALID = 1,     /* Bad argument, recipe or document JSON, range. */
    X3F_ERR_UNSUPPORTED = 2, /* Not X3F or X3I middle exposure, X3I merge,
                                or an incompatible edit decoder/version. */
    X3F_ERR_CANCELLED = 3,
    X3F_ERR_GPU = 4,         /* No GPU, device lost, or app in background. */
    X3F_ERR_IO = 5,
    X3F_ERR_INTERNAL = 6,    /* Engine panic, caught at the boundary. */
    X3F_ERR_EXISTS = 7,      /* Export target exists and replace is false. */
    X3F_ERR_CONFLICT = 8,    /* Edit document for other source contents, a
                                newer revision, an equal revision with a
                                different recipe, or an unreadable existing
                                document that the engine keeps. */
} X3fStatus;

typedef enum {
    X3F_PROFILE_SRGB = 0,
    X3F_PROFILE_ADOBE_RGB = 1,
    X3F_PROFILE_PROPHOTO_RGB = 2,
} X3fColorProfile;

typedef struct X3fSession X3fSession;
typedef struct X3fCancel X3fCancel;

/* Rows top-down. Each pixel is R, G, B, A (A = 255), sRGB. */
typedef struct {
    const uint8_t *bytes; /* stride * height bytes. */
    size_t len;
    uint32_t width;
    uint32_t height;
    uint32_t stride;      /* Bytes per row, width * 4. */
    void *owner;          /* Engine use only. */
} X3fFrame;

/* Renderer output version. Use it only in preview cache keys. */
uint32_t x3f_render_version(void);

X3fCancel *x3f_cancel_new(void);
/* Requests cancel. A cancelled call returns X3F_ERR_CANCELLED. */
void x3f_cancel_set(const X3fCancel *cancel);
void x3f_cancel_free(X3fCancel *cancel);
/* Returns false for NULL. Safe to call while another thread requests cancel. */
bool x3f_cancel_is_set(const X3fCancel *cancel);

/*
 * Opens externally decoded Apple RAW DNG. Borrow rgba until this call returns.
 * It contains exactly width * height * 4 initialized, aligned floats, tightly
 * packed, top-down, extended-linear sRGB. RGB must be finite; alpha must be 1.
 * Keep negative and above-one RGB. Force decode orientation up; pass the source
 * EXIF orientation separately. Pixels must cover the native default-cropped frame and have
 * as-shot WB and file BaselineExposure applied exactly once. Swift must validate
 * DNG crop, scale, active area and decoder settings before this call.
 * metadata_json requires: width:u32, height:u32, orientation:1..8,
 * sourceRevision:lowercase file SHA256, decoderIdentity:apple-raw-v1:<OS/build>:<decoder>,
 * baselineExposure:finite number (evidence only), asShotTemperature:positive f32.
 * Identity is printable ASCII without spaces, at most 256 bytes, with nonempty
 * OS/build and decoder fields. Encode OS spaces as underscores.
 * Append :default-crop-v1 for default-crop or implicit-geometry interpretation.
 * Preserve the exact existing identity for explicit full-area interpretation.
 * Optional paired originalWidth/originalHeight:u32 give the unscaled, un-oriented
 * default-cropped frame size, not the sensor active frame size;
 * omit both for full buffers. Source size must cover the decoded dimensions
 * and be at most 100,000,000 pixels. Decoded buffers are at most 24,000,000 pixels.
 * Reduced buffers cover the same default-cropped frame. Identity must not include scale.
 * Session info width/height give oriented original size; isProxy marks reduction.
 * JPEG/TIFF export from reduced buffers is unsupported. Reopen full pixels first.
 * No unknown keys. The engine copies RGB, checks the
 * source hash and stable stamp, and does not retain rgba. out is NULL on error.
 * DNG sessions require denoise=0, default denoiseOptions, as-shot WB and no
 * Foveon controls or explicit dngDemosaic. Sigma DNG export is unavailable.
 * DNG documents use native-only version 3 with decoderIdentity. Desktop version
 * 1/2 documents are incompatible. Do not offer desktop sidecar exchange.
 */
X3fStatus x3f_session_open_apple_raw(const char *source_path, const float *rgba,
                                    size_t float_count, const char *metadata_json,
                                    const X3fCancel *cancel, X3fSession **out,
                                    char **error);

/*
 * Opens and prepares the RAW at path: X3F, or the middle exposure of X3I.
 * Other formats (DNG, JPEG, PNG, TIFF) return X3F_ERR_UNSUPPORTED. Open one
 * session per source. cancel can be NULL.
 */
X3fStatus x3f_session_open(const char *path, const X3fCancel *cancel,
                           X3fSession **out, char **error);

/*
 * Writes owned JSON to *out_json:
 * {"sourceRevision": "<sha256 hex of the file>", "renderVersion": 20,
 *  "kind": "x3f" | "x3i" | "dng",
 *  "decoderIdentity": null | "apple-raw-v1:<OS/build>:<decoder>",
 *  "width": u32, "height": u32,          oriented, before crop
 *  "asShotTemperature": f32, "asShotTint": f32,
 *  "cameraProfiles": [{"id": "Standard", "name": "Standard"}, ...],
 *  "asShotProfile": "Standard",
 *  "defaultRecipe": { canonical EditRecipe, the camera defaults }}
 */
X3fStatus x3f_session_info(X3fSession *session, char **out_json, char **error);

/*
 * ---- Recipes and documents. ----
 * They do not touch the GPU. Without a session they run on any thread. With a
 * session they wait while that session renders, so call them on the worker.
 */

/*
 * Parses recipe_json with desktop defaults, validates it, and writes the
 * canonical JSON. With a session, it also applies the source rules (X3I
 * merge and dngDemosaic are rejected). session can be NULL.
 */
X3fStatus x3f_recipe_normalize(const X3fSession *session,
                               const char *recipe_json, char **out_json,
                               char **error);

/*
 * Applies patch_json to the canonical form of recipe_json and writes the
 * canonical result. An object in the patch merges into the object at the
 * same key, key by key. Any other value, also null and arrays, replaces it.
 * Example: {"film": {"film": 5}} changes the stock and keeps other film
 * settings. {"film": null} turns film off.
 */
X3fStatus x3f_recipe_patch(const char *recipe_json, const char *patch_json,
                           char **out_json, char **error);

/*
 * Applies a look as the desktop look picker does and writes the canonical
 * recipe. look_id is a camera profile id from session info cameraProfiles
 * (film off, the camera look) or a film stock key from the catalog (film on,
 * with that stock's paper, grain, halation and boost defaults). Other fields
 * are kept.
 */
X3fStatus x3f_recipe_apply_look(const char *recipe_json, const char *look_id,
                                char **out_json, char **error);

/*
 * True in *edited when recipe_json differs from the session camera defaults,
 * as the desktop decides (a zero-strength wheel hue is not an edit).
 */
X3fStatus x3f_recipe_edited(const X3fSession *session, const char *recipe_json,
                            bool *edited, char **error);

/*
 * Writes the film catalog:
 * {"films": [{"index", "key", "name", "family": "negativeFilm" | "slideFilm"
 *             | "cinemaFilm" | "bwFilm", "isPositive", "monochrome",
 *             "antihalation", "use", "paper": paper index}],  desktop order
 *  "papers": [{"index", "key", "name", "monochrome"}],
 *  "defaultFilm": { canonical FilmSettings }}
 */
X3fStatus x3f_film_catalog(char **out_json, char **error);

/* ---- Desktop edit documents (<original name>.x3fuse.json). ---- */

/*
 * A document is {"version", "sourceRevision", "revision", "updatedMs",
 * "recipe"}, as the desktop writes it. The engine accepts versions 1 and 2,
 * up to 1 MiB. DNG uses native-only version 3 with decoderIdentity; the session
 * requires the same decoder identity. Version 1/2 documents are Sigma-only.
 *
 * Validates document_json for the session source and writes a version 2 (Sigma)
 * or version 3 (Apple RAW DNG)
 * document to *out_json and its canonical recipe to *out_recipe_json (can be
 * NULL; store these bytes, do not re-encode the recipe). *edited (can be NULL) is
 * false when the recipe is the camera defaults. A version 1 document that
 * holds the old default film look also counts as unedited; its recipe is
 * then the camera defaults, as on the desktop.
 * Errors: X3F_ERR_INVALID (bad JSON, unknown key, bad recipe or revision),
 * X3F_ERR_UNSUPPORTED (newer version), X3F_ERR_CONFLICT (other source).
 */
X3fStatus x3f_document_validate(const X3fSession *session,
                                const char *document_json, char **out_json,
                                char **out_recipe_json, bool *edited,
                                char **error);

/*
 * The desktop save check: X3F_OK when incoming can replace previous.
 * X3F_ERR_CONFLICT when the sourceRevision values differ, previous has a
 * newer revision, or the revisions are equal with different recipes.
 * Both are documents; recipes are compared as parsed values.
 */
X3fStatus x3f_document_check_previous(const char *previous_json,
                                      const char *incoming_json, char **error);

/*
 * Reads and validates the document at path, as x3f_document_validate.
 * A missing file gives X3F_OK with *out_json NULL. Never changes the file.
 */
X3fStatus x3f_sidecar_read(const X3fSession *session, const char *path,
                           char **out_json, char **out_recipe_json,
                           bool *edited, char **error);

/*
 * Writes a version 2 document for recipe_json and revision (1..2^53-1) to
 * path, pretty printed as the desktop does, through a temporary file and a
 * rename. updatedMs is max(now, previous updatedMs + 1).
 * Before it writes, the engine checks that the source file still has the
 * session sourceRevision, and runs the save check against the document at
 * path and against previous_json (can be NULL; pass your current document so
 * that an import cannot erase a newer edit). An existing file at path that
 * cannot be read as a document is kept (X3F_ERR_CONFLICT).
 * path can never be the source RAW. Writes the document to *out_json (can be
 * NULL).
 * Known limit: a writer that changes path between the check and the rename is
 * overwritten. Use one serial worker and a folder only this app writes.
 */
X3fStatus x3f_sidecar_write(const X3fSession *session, const char *path,
                            const char *recipe_json, uint64_t revision,
                            const char *previous_json, char **out_json,
                            char **error);

/* ---- Rendering and export. ---- */

/* Renders recipe_json as an RGBA8 preview. max_edge is 1..4096. */
X3fStatus x3f_session_render(X3fSession *session, const char *recipe_json,
                             uint32_t max_edge, const X3fCancel *cancel,
                             X3fFrame *out, char **error);

/*
 * Export rules for all formats:
 * - The engine writes a temporary file ".<name>.<pid>.partial" in the
 *   out_path directory, then renames it. It removes the temporary file on
 *   error or cancel.
 * - With replace false, an existing out_path is kept and the call returns
 *   X3F_ERR_EXISTS. Pass true only after the user approved the replacement.
 * - out_path can never be the source RAW (X3F_ERR_INVALID).
 */

/*
 * Renders at full resolution in 16 bits, then writes an sRGB JPEG with an
 * ICC profile and no EXIF. The orientation is in the pixels. quality 1..100.
 */
X3fStatus x3f_session_export_jpeg(X3fSession *session, const char *recipe_json,
                                  const char *out_path, uint8_t quality,
                                  bool replace, const X3fCancel *cancel,
                                  char **error);

/*
 * Renders at full resolution and writes a 16-bit RGB TIFF with the ICC
 * profile of color_profile. compress uses lossless compression. No EXIF.
 */
X3fStatus x3f_session_export_tiff(X3fSession *session, const char *recipe_json,
                                  const char *out_path,
                                  X3fColorProfile color_profile, bool compress,
                                  bool replace, const X3fCancel *cancel,
                                  char **error);

/*
 * Converts the original RAW to DNG with x3f-core, as the desktop batch does:
 * all camera Color Mode profiles with as shot as the default, metadata from
 * x3f-core only (no ExifTool tags). Recipes do not apply. X3I uses the middle
 * exposure.
 * - highlight_recovery false: the engine embeds the flat-field lens
 *   correction from opcodes_dir (the bundled opcodes folder). opcodes_dir
 *   must not be NULL. This is the desktop default. Bodies without a correction file (Quattro, for
 *   example) are converted without it, as on the desktop; a Merrill body
 *   without its file gives a warning.
 * - highlight_recovery true: recovers highlights and embeds no opcodes, as
 *   the desktop does. The desktop offers it for Merrill and Quattro bodies
 *   only. The engine does not know the body, so it does not check this.
 * *warnings_json (can be NULL) gets an owned JSON array of strings.
 */
X3fStatus x3f_session_export_dng(X3fSession *session, const char *out_path,
                                 const char *opcodes_dir,
                                 bool highlight_recovery, bool replace,
                                 const X3fCancel *cancel, char **warnings_json,
                                 char **error);

/* Frees the pixels and sets the frame to zero. NULL and a zero frame are safe. */
void x3f_frame_free(X3fFrame *frame);
/* Frees GPU and RAW memory. Do not use the session after this. NULL is safe. */
void x3f_session_free(X3fSession *session);
void x3f_string_free(char *string);

#ifdef __cplusplus
}
#endif

#endif /* X3FUSE_ENGINE_H */
