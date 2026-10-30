/*
 * X3Fuse engine C ABI.
 *
 * Rules:
 * - Functions that return X3fStatus write *error only on failure. The error is
 *   an owned UTF-8 string. Free it with x3f_string_free. Pass NULL for error to
 *   ignore it.
 * - open, info, render and export block. Never call them on the main thread.
 *   Call them from one serial worker.
 * - Keep one live session at a time on iOS. Free the old session before you
 *   open the next one. All sessions share one GPU device.
 * - Free a session only after every call on it has returned.
 * - Use a new X3fCancel for each job. x3f_cancel_set is safe from any thread.
 *   The engine only reads the token and does not keep it after a call returns.
 * - x3f_frame_free and x3f_string_free are safe from any thread.
 * - Strings in and out are UTF-8 and NUL terminated.
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
    X3F_ERR_INVALID = 1,     /* Bad argument, recipe JSON or range. */
    X3F_ERR_UNSUPPORTED = 2, /* Not an X3F or X3I middle exposure. */
    X3F_ERR_CANCELLED = 3,
    X3F_ERR_GPU = 4,         /* No GPU, device lost, or app in background. */
    X3F_ERR_IO = 5,
    X3F_ERR_INTERNAL = 6,    /* Engine panic, caught at the boundary. */
    X3F_ERR_EXISTS = 7,      /* Export target exists and replace is false. */
} X3fStatus;

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

/* Renderer output version. Mix into preview cache keys. */
uint32_t x3f_render_version(void);

X3fCancel *x3f_cancel_new(void);
/* Requests cancel. A cancelled call returns X3F_ERR_CANCELLED. */
void x3f_cancel_set(const X3fCancel *cancel);
void x3f_cancel_free(X3fCancel *cancel);

/*
 * Opens and prepares the RAW at path: X3F, or the middle exposure of X3I.
 * Other formats (DNG, JPEG, PNG, TIFF) return X3F_ERR_UNSUPPORTED. Open one
 * session per source. cancel can be NULL.
 */
X3fStatus x3f_session_open(const char *path, const X3fCancel *cancel,
                           X3fSession **out, char **error);

/*
 * Writes owned JSON to *out_json:
 * {"sourceRevision": "<sha256 hex>", "renderVersion": 20,
 *  "kind": "x3f" | "x3i",
 *  "width": u32, "height": u32,          oriented, before crop
 *  "asShotTemperature": f32, "asShotTint": f32,
 *  "cameraProfiles": [{"id": "Standard", "name": "Standard"}, ...],
 *  "asShotProfile": "Standard",
 *  "defaultRecipe": { full EditRecipe }}
 */
X3fStatus x3f_session_info(X3fSession *session, char **out_json, char **error);

/*
 * recipe_json is a JSON object. Its top-level keys replace the same keys of
 * the session defaultRecipe, so {"exposure": 1} keeps camera calibration and
 * as-shot white balance. A nested object (crop, curves, film, monochrome)
 * replaces the default value as a whole. "temperature": null is as shot.
 * Unknown keys are rejected.
 *
 * Renders recipe_json as an RGBA8 preview. max_edge is 1..4096. Free *out with x3f_frame_free.
 */
X3fStatus x3f_session_render(X3fSession *session, const char *recipe_json,
                             uint32_t max_edge, const X3fCancel *cancel,
                             X3fFrame *out, char **error);

/*
 * Renders recipe_json (same merge as render) at full resolution in 16 bits,
 * then writes an sRGB JPEG with an ICC profile and no EXIF to out_path. The
 * orientation is applied to the pixels. The engine writes a temporary file in
 * the out_path directory, then renames it. It removes the temporary file on
 * error or cancel. quality is 1..100.
 *
 * With replace false, an existing out_path is kept and the call returns
 * X3F_ERR_EXISTS. Pass true only after the user approved the replacement.
 * out_path can never be the source RAW (X3F_ERR_INVALID).
 */
X3fStatus x3f_session_export_jpeg(X3fSession *session, const char *recipe_json,
                                  const char *out_path, uint8_t quality,
                                  bool replace, const X3fCancel *cancel,
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
